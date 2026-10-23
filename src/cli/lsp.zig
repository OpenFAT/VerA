//! `vera --lsp`: a Language Server Protocol 3.17 session on stdin/stdout ->
//! the compiler's diagnostics as `textDocument/publishDiagnostics`, and its
//! fix-its as `quickfix` code actions.
//!
//! Every open Verilog-A document is linted (`vera --lint`'s pipeline:
//! preprocess, parse, lower, prove) from the editor's text on open and on
//! every change; an `include is read from disk, so an unsaved header is not
//! seen. Diagnostics inside an included file are published on that file's
//! URI. The flags are this command line's, then the workspace root's
//! `.vera-flags` (whitespace-separated `vera` flags, `-I` relative to the
//! root), read once at `initialize`.
//!
//! Positions are UTF-8 when the client offers it (`positionEncoding`), else
//! UTF-16, converted in one place (`position`). A `.v` document, and every
//! document under `-Dlanguage=verilog`, gets no diagnostics yet.
//!
//! Clauses: none of the LRM's; the protocol is LSP 3.17's.

const std = @import("std");
const ams = @import("build_options").ams;
const vera = @import("vera");
const args = @import("args.zig");
const diag = vera.diag;
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The largest message body read. A `didOpen` carries the whole document, and
/// the compiler takes no source past `Preprocessor.max_text_bytes`; a body
/// past this is refused and the session ends (the stream cannot be resynced).
pub const max_message_bytes: usize = 1 << 28;

const Position = struct { line: u32, character: u32 };
const Range = struct { start: Position, end: Position };

/// A fix-it, carried in the diagnostic's `data` so `codeAction` needs no
/// state: the client sends the diagnostic back as it got it.
const Fix = struct { title: []const u8, uri: []const u8, range: Range, newText: []const u8 };

const Related = struct {
    location: struct { uri: []const u8, range: Range },
    message: []const u8,
};

const Diagnostic = struct {
    range: Range,
    /// 1 error, 2 warning, 3 information.
    severity: u8,
    code: ?[]const u8 = null,
    source: []const u8 = "vera",
    message: []const u8,
    relatedInformation: []const Related = &.{},
    data: struct { fixes: []const Fix = &.{} } = .{},
};

const Doc = struct {
    /// gpa-owned.
    text: []u8,
    /// Other URIs (included files) the last lint published on; gpa-owned.
    /// Cleared when a later lint does not publish on them again.
    extra: std.ArrayList([]u8) = .empty,

    fn deinit(d: *Doc, gpa: Allocator) void {
        gpa.free(d.text);
        for (d.extra.items) |u| gpa.free(u);
        d.extra.deinit(gpa);
    }
};

const Server = struct {
    gpa: Allocator,
    io: Io,
    out: *Io.Writer,
    cli: *args.Cli,
    utf16: bool = true,
    shutdown: bool = false,
    /// `initialize` answered: a second one reads no `.vera-flags`, whose
    /// flags `cli` already holds and whose bytes it borrows.
    initialized: bool = false,
    /// URI (gpa-owned key) -> document.
    docs: std.StringHashMapUnmanaged(Doc) = .empty,
    /// `.vera-flags`' bytes, which `cli` borrows; gpa-owned.
    flags_text: []u8 = &.{},
    /// Absolute `-I` dirs made from relative ones; `cli` borrows them.
    abs_dirs: std.ArrayList([]u8) = .empty,

    fn deinit(s: *Server) void {
        var it = s.docs.iterator();
        while (it.next()) |e| {
            s.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(s.gpa);
        }
        s.docs.deinit(s.gpa);
        s.gpa.free(s.flags_text);
        for (s.abs_dirs.items) |d| s.gpa.free(d);
        s.abs_dirs.deinit(s.gpa);
    }

    fn send(s: *Server, arena: Allocator, msg: anytype) !void {
        var aw: Io.Writer.Allocating = .init(arena);
        // An allocating writer fails only when its allocator does.
        std.json.Stringify.value(msg, .{ .emit_null_optional_fields = false }, &aw.writer) catch return error.OutOfMemory;
        try s.out.print("Content-Length: {d}\r\n\r\n", .{aw.written().len});
        try s.out.writeAll(aw.written());
        try s.out.flush();
    }

    fn reply(s: *Server, arena: Allocator, id: std.json.Value, result: anytype) !void {
        try s.send(arena, .{ .jsonrpc = "2.0", .id = id, .result = result });
    }

    fn showMessage(s: *Server, arena: Allocator, text: []const u8) !void {
        try s.send(arena, .{ .jsonrpc = "2.0", .method = "window/showMessage", .params = .{ .type = 1, .message = text } });
    }
};

/// The incoming envelope: a request has an `id` and a `method`, a
/// notification only a `method`; a response (to a server request, which this
/// server never makes) is ignored.
const Message = struct {
    id: ?std.json.Value = null,
    method: ?[]const u8 = null,
    params: ?std.json.Value = null,
};

const parse_opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

/// Runs one session: reads framed messages from `in` until `exit`, answering
/// on `out`. `cli` holds the command line's flags; `.vera-flags` is parsed
/// into it at `initialize`, so it must outlive the call; the strings that
/// file added to `cli` are freed when the call returns. Returns the process
/// exit status: 0 after `shutdown` then `exit`, 1 for an `exit` without a
/// `shutdown`, a closed input, or a malformed frame (reason on `err`).
pub fn serve(gpa: Allocator, io: Io, cli: *args.Cli, in: *Io.Reader, out: *Io.Writer, err: *Io.Writer) !u8 {
    var s: Server = .{ .gpa = gpa, .io = io, .out = out, .cli = cli };
    defer s.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    while (true) {
        // Not `.retain_capacity`: that would pin the largest `didOpen` (up to
        // `max_message_bytes`) for the session, and its regrow swallows an
        // allocation failure. One chunk per message is noise beside a lint.
        _ = arena_state.reset(.free_all);
        const arena = arena_state.allocator();

        // Header: `Content-Length: N\r\n`, maybe other fields, then `\r\n`.
        var len: ?usize = null;
        while (true) {
            const line = in.takeDelimiterInclusive('\n') catch |e| switch (e) {
                error.EndOfStream => return 1,
                else => {
                    try err.print("error: --lsp: reading a header failed: {t}\n", .{e});
                    return 1;
                },
            };
            const field = std.mem.trimEnd(u8, line, "\r\n");
            if (field.len == 0) break;
            const key = "content-length:";
            if (field.len > key.len and std.ascii.eqlIgnoreCase(field[0..key.len], key))
                len = std.fmt.parseInt(usize, std.mem.trim(u8, field[key.len..], " \t"), 10) catch null;
        }
        const n = len orelse {
            try err.writeAll("error: --lsp: a message without a valid Content-Length\n");
            return 1;
        };
        if (n > max_message_bytes) {
            try err.print("error: --lsp: a {d}-byte message is past the {d}-byte limit\n", .{ n, max_message_bytes });
            return 1;
        }
        const body = in.readAllocAll(arena, n) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try err.print("error: --lsp: reading a {d}-byte message failed: {t}\n", .{ n, e });
                return 1;
            },
        };

        const msg = std.json.parseFromSliceLeaky(Message, arena, body, parse_opts) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            try s.send(arena, .{ .jsonrpc = "2.0", .id = null, .@"error" = .{ .code = -32700, .message = "parse error" } });
            continue;
        };
        const method = msg.method orelse continue;
        const params = msg.params orelse .null;
        if (std.mem.eql(u8, method, "exit")) return if (s.shutdown) 0 else 1;
        // A params shape the server cannot read is the client's bug: answer
        // a request with InvalidParams, drop a notification.
        dispatch(&s, arena, method, msg.id, params) catch |e| switch (e) {
            error.OutOfMemory, error.WriteFailed => |x| return x,
            else => if (msg.id) |id| try s.send(arena, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = -32602, .message = @errorName(e) } }),
        };
    }
}

fn dispatch(s: *Server, arena: Allocator, method: []const u8, id: ?std.json.Value, params: std.json.Value) !void {
    const eql = std.mem.eql;
    if (eql(u8, method, "initialize")) {
        const p = try std.json.parseFromValueLeaky(struct {
            rootUri: ?[]const u8 = null,
            capabilities: struct {
                general: struct { positionEncodings: []const []const u8 = &.{} } = .{},
            } = .{},
        }, arena, params, parse_opts);
        for (p.capabilities.general.positionEncodings) |e| {
            if (eql(u8, e, "utf-8")) s.utf16 = false;
        }
        if (!s.initialized) if (p.rootUri) |u| if (try uriToPath(arena, u)) |root| try readFlags(s, arena, root);
        s.initialized = true;
        try s.reply(arena, id orelse return, .{
            .capabilities = .{
                .positionEncoding = if (s.utf16) "utf-16" else "utf-8",
                // Full text on every change (1); `save` is not asked for.
                .textDocumentSync = .{ .openClose = true, .change = 1 },
                .codeActionProvider = .{ .codeActionKinds = &[_][]const u8{"quickfix"} },
            },
            .serverInfo = .{ .name = "vera" },
        });
    } else if (eql(u8, method, "shutdown")) {
        s.shutdown = true;
        try s.reply(arena, id orelse return, null);
    } else if (eql(u8, method, "textDocument/didOpen")) {
        const p = try std.json.parseFromValueLeaky(struct {
            textDocument: struct { uri: []const u8, text: []const u8 },
        }, arena, params, parse_opts);
        try setText(s, arena, p.textDocument.uri, p.textDocument.text);
    } else if (eql(u8, method, "textDocument/didChange")) {
        const p = try std.json.parseFromValueLeaky(struct {
            textDocument: struct { uri: []const u8 },
            contentChanges: []const struct { text: []const u8 },
        }, arena, params, parse_opts);
        // Full sync: the last change is the whole document.
        if (p.contentChanges.len == 0) return;
        try setText(s, arena, p.textDocument.uri, p.contentChanges[p.contentChanges.len - 1].text);
    } else if (eql(u8, method, "textDocument/didClose")) {
        const p = try std.json.parseFromValueLeaky(struct {
            textDocument: struct { uri: []const u8 },
        }, arena, params, parse_opts);
        const kv = s.docs.fetchRemove(p.textDocument.uri) orelse return;
        var doc = kv.value;
        defer {
            s.gpa.free(kv.key);
            doc.deinit(s.gpa);
        }
        try publish(s, arena, kv.key, &.{});
        for (doc.extra.items) |u| try publish(s, arena, u, &.{});
    } else if (eql(u8, method, "textDocument/codeAction")) {
        const p = try std.json.parseFromValueLeaky(struct {
            context: struct { diagnostics: []const struct { data: struct { fixes: []const Fix = &.{} } = .{} } },
        }, arena, params, parse_opts);
        const Edit = struct { range: Range, newText: []const u8 };
        const Action = struct {
            title: []const u8,
            kind: []const u8 = "quickfix",
            edit: struct { changes: std.json.ArrayHashMap([]const Edit) },
        };
        var actions: std.ArrayList(Action) = .empty;
        for (p.context.diagnostics) |d| for (d.data.fixes) |f| {
            var changes: std.json.ArrayHashMap([]const Edit) = .{};
            try changes.map.put(arena, f.uri, try arena.dupe(Edit, &.{.{ .range = f.range, .newText = f.newText }}));
            try actions.append(arena, .{ .title = f.title, .edit = .{ .changes = changes } });
        };
        try s.reply(arena, id orelse return, actions.items);
    } else if (id) |rid| {
        try s.send(arena, .{ .jsonrpc = "2.0", .id = rid, .@"error" = .{ .code = -32601, .message = "method not found" } });
    }
    // Any other notification (`initialized`, `$/cancelRequest`, `didSave`, ...) needs nothing.
}

/// `.vera-flags` at `root`, after this command line's flags; a relative `-I`
/// is made relative to `root`. A flag `vera` refuses is shown to the user,
/// and the flags before it stay.
fn readFlags(s: *Server, arena: Allocator, root: []const u8) !void {
    const path = try std.fs.path.join(arena, &.{ root, ".vera-flags" });
    s.flags_text = vera.Preprocessor.readText(s.io, .cwd(), path, s.gpa) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return, // no `.vera-flags`: the command line's flags alone
    };
    var iter = std.mem.tokenizeAny(u8, s.flags_text, " \t\r\n");
    const dirs_before = s.cli.include_dirs.items.len;
    var discard: Io.Writer.Discarding = .init(&.{});
    var why: Io.Writer.Allocating = .init(arena);
    if (try args.parse(s.cli, s.gpa, &iter, &discard.writer, &why.writer) != null)
        try s.showMessage(arena, try arena.print("vera: {s}: {s}", .{ path, std.mem.trimEnd(u8, why.written(), "\n") }));
    for (s.cli.include_dirs.items[dirs_before..]) |*d| if (!std.fs.path.isAbsolute(d.*)) {
        try s.abs_dirs.ensureUnusedCapacity(s.gpa, 1);
        const abs = try std.fs.path.join(s.gpa, &.{ root, d.* });
        s.abs_dirs.appendAssumeCapacity(abs);
        d.* = abs;
    };
}

fn setText(s: *Server, arena: Allocator, uri: []const u8, text: []const u8) !void {
    // Every allocation first: a failure leaves the old document whole.
    const owned = try s.gpa.dupe(u8, text);
    const gop = s.docs.getOrPut(s.gpa, uri) catch |e| {
        s.gpa.free(owned);
        return e;
    };
    if (gop.found_existing) {
        s.gpa.free(gop.value_ptr.text);
    } else {
        gop.key_ptr.* = s.gpa.dupe(u8, uri) catch |e| {
            s.docs.removeByPtr(gop.key_ptr);
            s.gpa.free(owned);
            return e;
        };
        gop.value_ptr.* = .{ .text = &.{} };
    }
    gop.value_ptr.text = owned;
    try lintAndPublish(s, arena, gop.key_ptr.*, gop.value_ptr);
}

// ponytail: a full lint per keystroke, no debounce or cancellation; add a
// frontend-only pass on change when a large model makes typing lag.
fn lintAndPublish(s: *Server, arena: Allocator, uri: []const u8, doc: *Doc) !void {
    var bag: diag.Bag = .init(s.gpa);
    defer bag.deinit(s.gpa);
    const path = try uriToPath(arena, uri);
    const is_va = if (path) |p| !std.mem.eql(u8, std.fs.path.extension(p), ".v") else true;
    if (ams and is_va and s.cli.sim != .verilog) {
        const cli = s.cli;
        if (vera.compileSourceOpts(s.gpa, doc.text, .lint, .{
            .file_name = path orelse "<untitled>",
            .include_dirs = cli.include_dirs.items,
            .std_defs = cli.std_defs,
            .require_std_includes = true, // the source includes the annex D files it uses
            .language = cli.language,
            .sim = cli.sim,
            .diags = &bag,
            .lint = cli.levels,
            .proof = .{ .unknown_bound = cli.unknown_bound },
            .discipline_resolution = cli.discipline_resolution,
            .param_overrides = cli.overrides.items,
        })) |r| {
            var ok = r;
            ok.deinit();
        } else |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {}, // the bag says why
        }
    }
    const by_uri = try diagnostics(arena, &bag, uri, s.utf16);

    // Clear the included files this lint no longer reports on.
    for (doc.extra.items) |u| if (!by_uri.contains(u)) try publish(s, arena, u, &.{});
    for (doc.extra.items) |u| s.gpa.free(u);
    doc.extra.clearRetainingCapacity();
    var it = by_uri.iterator();
    while (it.next()) |e| {
        try publish(s, arena, e.key_ptr.*, e.value_ptr.items);
        if (!std.mem.eql(u8, e.key_ptr.*, uri)) try doc.extra.append(s.gpa, try s.gpa.dupe(u8, e.key_ptr.*));
    }
}

fn publish(s: *Server, arena: Allocator, uri: []const u8, ds: []const Diagnostic) !void {
    try s.send(arena, .{
        .jsonrpc = "2.0",
        .method = "textDocument/publishDiagnostics",
        .params = .{ .uri = uri, .diagnostics = ds },
    });
}

const ByUri = std.StringArrayHashMapUnmanaged(std.ArrayList(Diagnostic));

/// The bag as LSP diagnostics, grouped by the URI each lands on; `uri`, the
/// linted document's, is always the first key. A diagnostic in a file that
/// is not on disk (the annex D prelude) lands on `uri`'s first character,
/// its own place named in the message. Sorts the bag.
fn diagnostics(arena: Allocator, bag: *diag.Bag, uri: []const u8, utf16: bool) !ByUri {
    bag.sort();
    var by_uri: ByUri = .empty;
    try by_uri.put(arena, uri, .empty);
    var lines: Lines = .{ .bag = bag, .arena = arena, .utf16 = utf16 };

    for (0..bag.count()) |row| {
        const e = bag.at(row);
        const meta = diag.info(e.code);
        const at = try lines.place(e.span, e.file, uri);
        var msg: Io.Writer.Allocating = .init(arena);
        const w = &msg.writer;
        if (at.elsewhere) |where| try w.print("{s}: ", .{where});
        // The text renderer's headline, then what it draws at the caret.
        try w.writeAll(meta.title);
        if (e.message.len != 0) try w.print(": {s}", .{e.message});
        // `--explain`'s citation: an annex is a letter.
        if (meta.lrm.len != 0) try w.print(" (LRM {s}{s})", .{ if (std.ascii.isUpper(meta.lrm[0])) "annex " else "", meta.lrm });
        if (e.point.len != 0) try w.print("\n{s}", .{e.point});

        var nbuf: [diag.max_children]diag.Note = undefined;
        var fixes: std.ArrayList(Fix) = .empty;
        for (bag.notes(e, &nbuf)) |n| {
            try w.print("\n{t}: {s}", .{ n.kind, n.text });
            const f = n.fix orelse continue;
            const fp = try lines.place(f.span, e.file, uri);
            if (fp.elsewhere != null) continue; // nothing on disk to edit
            try fixes.append(arena, .{ .title = n.text, .uri = fp.uri, .range = fp.range, .newText = f.replacement });
        }

        var lbuf: [diag.max_children]diag.Label = undefined;
        const labels = bag.labels(e, &lbuf);
        const related = try arena.alloc(Related, labels.len);
        for (labels, related) |l, *r| {
            const lp = try lines.place(l.span, e.file, uri);
            r.* = .{ .location = .{ .uri = lp.uri, .range = lp.range }, .message = l.text };
        }

        const gop = try by_uri.getOrPut(arena, at.uri);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, .{
            .range = at.range,
            .severity = switch (e.severity) {
                .err => 1,
                .warning => 2,
            },
            .code = e.code.name(),
            .message = msg.written(),
            .relatedInformation = related,
            .data = .{ .fixes = fixes.items },
        });
    }
    if (bag.suppressed != 0) try by_uri.getPtr(uri).?.append(arena, .{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
        .severity = 3,
        .message = try arena.print("{d} more diagnostics not shown: a run stops at its cap", .{bag.suppressed}),
    });
    return by_uri;
}

/// Span -> (URI, range), with one line index per file, built on first use.
const Lines = struct {
    bag: *const diag.Bag,
    arena: Allocator,
    utf16: bool,
    index: std.AutoHashMapUnmanaged(diag.FileId, diag.LineIndex) = .empty,

    const Place = struct {
        uri: []const u8,
        range: Range,
        /// `file:line:col` of a span in a file not on disk, which is then
        /// placed at the start of the document.
        elsewhere: ?[]const u8 = null,
    };

    fn place(l: *Lines, span: diag.Span, file: ?diag.FileId, doc_uri: []const u8) !Place {
        const zero: Range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } };
        if (span.isNone()) return .{ .uri = doc_uri, .range = zero };
        const a = l.bag.locate(span, file);
        const b = l.bag.locate(.at(span.end), file);
        const text = l.bag.sourceText(a.file);
        const gop = try l.index.getOrPut(l.arena, a.file);
        if (!gop.found_existing) gop.value_ptr.* = try .build(l.arena, text);
        const start = @min(l.bag.toSourceOffset(a.file, a.offset), text.len);
        // An end in another file (a span across an `include or out of a
        // macro) is cut to the start.
        const end = if (b.file == a.file) @max(start, @min(l.bag.toSourceOffset(b.file, b.offset), text.len)) else start;
        const range: Range = .{
            .start = position(text, gop.value_ptr.*, @intCast(start), l.utf16),
            .end = position(text, gop.value_ptr.*, @intCast(end), l.utf16),
        };
        if (a.file == .root) return .{ .uri = doc_uri, .range = range };
        const name = l.bag.fileName(a.file);
        if (!std.fs.path.isAbsolute(name)) return .{
            .uri = doc_uri,
            .range = zero,
            .elsewhere = try l.arena.print("{s}:{d}:{d}", .{ name, range.start.line + 1, range.start.character + 1 }),
        };
        return .{ .uri = try pathToUri(l.arena, name), .range = range };
    }
};

/// Byte offset `off` of `text` -> 0-based line and character, the character
/// counted in UTF-16 code units when `utf16`, else in bytes. Invalid UTF-8
/// counts a unit per non-continuation byte.
fn position(text: []const u8, index: diag.LineIndex, off: u32, utf16: bool) Position {
    const loc = index.loc(off);
    const line_start = index.starts[loc.line - 1];
    if (!utf16) return .{ .line = loc.line - 1, .character = off - line_start };
    var units: u32 = 0;
    for (text[line_start..off]) |c| {
        if (c & 0xc0 != 0x80) units += 1; // a lead byte starts a code point
        if (c >= 0xf0) units += 1; // a 4-byte sequence is a surrogate pair
    }
    return .{ .line = loc.line - 1, .character = units };
}

/// `file://` URI -> path, percent-decoded (`file:///C:/x` -> `C:/x`); null
/// for any other scheme (`untitled:`).
fn uriToPath(arena: Allocator, uri: []const u8) Allocator.Error!?[]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    const buf = try arena.dupe(u8, uri[prefix.len..]);
    const p = std.Uri.percentDecodeInPlace(buf);
    if (p.len >= 3 and p[0] == '/' and p[2] == ':') return p[1..]; // a Windows drive
    return p;
}

/// Absolute path -> `file://` URI, percent-encoding all but RFC 3986's
/// unreserved bytes and `/`. A Windows path's `\` becomes `/`.
fn pathToUri(arena: Allocator, path: []const u8) ![]const u8 {
    var w: Io.Writer.Allocating = .init(arena);
    try w.writer.writeAll(if (path.len >= 2 and path[1] == ':') "file:///" else "file://");
    for (path) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '/' => try w.writer.writeByte(c),
        '\\' => try w.writer.writeByte('/'),
        else => try w.writer.print("%{X:0>2}", .{c}),
    };
    return w.written();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn frame(arena: Allocator, json: []const u8) ![]const u8 {
    return arena.print("Content-Length: {d}\r\n\r\n{s}", .{ json.len, json });
}

test "a session: initialize, a missing `;` diagnosed with its fix, the fix as a code action, shutdown" {
    if (!ams) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // E0207 at `endmodule`, with "insert `;`" after the `1` of line 2:
    // `  analog /*é*/ x = 1` is 21 bytes (the `é` in the comment is 2), so the
    // insertion is at character 21 in UTF-8.
    const src = "module m;\\n  real x;\\n  analog /*é*/ x = 1\\nendmodule\\n";
    var input: std.ArrayList(u8) = .empty;
    for ([_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"general":{"positionEncodings":["utf-8","utf-16"]}}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///nonexistent/m.va\",\"languageId\":\"verilogams\",\"version\":1,\"text\":\"" ++ src ++ "\"}}}",
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///nonexistent/m.va"},"range":{"start":{"line":3,"character":0},"end":{"line":3,"character":0}},"context":{"diagnostics":[{"range":{"start":{"line":3,"character":0},"end":{"line":3,"character":9}},"message":"x","data":{"fixes":[{"title":"insert `;`","uri":"file:///nonexistent/m.va","range":{"start":{"line":2,"character":21},"end":{"line":2,"character":21}},"newText":";"}]}}]}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
    }) |m| try input.appendSlice(arena, try frame(arena, m));

    var in: Io.Reader = .fixed(input.items);
    var out: Io.Writer.Allocating = .init(arena);
    var err: Io.Writer.Allocating = .init(arena);
    var cli: args.Cli = .{};
    defer cli.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), try serve(gpa, std.testing.io, &cli, &in, &out.writer, &err.writer));
    try std.testing.expectEqualStrings("", err.written());

    const got = out.written();
    const has = struct {
        fn f(hay: []const u8, needle: []const u8) !void {
            if (std.mem.find(u8, hay, needle) == null) {
                std.debug.print("missing {s}\nin {s}\n", .{ needle, hay });
                return error.TestUnexpectedResult;
            }
        }
    }.f;
    try has(got, "\"positionEncoding\":\"utf-8\"");
    try has(got, "\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///nonexistent/m.va\"");
    try has(got, "\"code\":\"E0207\",\"source\":\"vera\",\"message\":\"unexpected token: found `endmodule` (LRM annex A.1.2)\\nexpected `;`\\nhelp: insert `;` after the previous statement\"");
    // The fix's range, in UTF-8 bytes: after `1` on line 2.
    try has(got, "\"data\":{\"fixes\":[{\"title\":\"insert `;` after the previous statement\",\"uri\":\"file:///nonexistent/m.va\",\"range\":{\"start\":{\"line\":2,\"character\":21},\"end\":{\"line\":2,\"character\":21}},\"newText\":\";\"}]}");
    try has(got, "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":[{\"title\":\"insert `;`\",\"kind\":\"quickfix\",\"edit\":{\"changes\":{\"file:///nonexistent/m.va\":[{\"range\":{\"start\":{\"line\":2,\"character\":21},\"end\":{\"line\":2,\"character\":21}},\"newText\":\";\"}]}}}]}");
    try has(got, "{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32601");
    try has(got, "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":null}");
}

test "exit without shutdown, and a closed input, are status 1" {
    const gpa = std.testing.allocator;
    var cli: args.Cli = .{};
    defer cli.deinit(gpa);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    var exit: Io.Reader = .fixed("Content-Length: 33\r\n\r\n{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");
    try std.testing.expectEqual(@as(u8, 1), try serve(gpa, std.testing.io, &cli, &exit, &out.writer, &err.writer));
    var closed: Io.Reader = .fixed("");
    try std.testing.expectEqual(@as(u8, 1), try serve(gpa, std.testing.io, &cli, &closed, &out.writer, &err.writer));
    var bad: Io.Reader = .fixed("Content-Type: x\r\n\r\n{}");
    try std.testing.expectEqual(@as(u8, 1), try serve(gpa, std.testing.io, &cli, &bad, &out.writer, &err.writer));
    try std.testing.expectEqualStrings("error: --lsp: a message without a valid Content-Length\n", err.written());
    // The header's name is case-insensitive; the body's size is bounded.
    var big: Io.Reader = .fixed("content-length: 268435457\r\n\r\n");
    try std.testing.expectEqual(@as(u8, 1), try serve(gpa, std.testing.io, &cli, &big, &out.writer, &err.writer));
    try std.testing.expect(std.mem.endsWith(u8, err.written(), "error: --lsp: a 268435457-byte message is past the 268435456-byte limit\n"));
}

/// A session over a `.v` document (never linted) under `root`, whose
/// `.vera-flags` holds `-I inc`: initialize twice, open, change with no
/// change, change, close, close again, shutdown, exit.
fn vSession(gpa: Allocator, root_uri: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const init_msg = try arena.print("{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{{\"rootUri\":\"{s}\"}}}}", .{root_uri});
    var input: std.ArrayList(u8) = .empty;
    for ([_][]const u8{
        init_msg,
        init_msg,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///x/top.v","text":"module top; endmodule\n"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///x/top.v"},"contentChanges":[]}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///x/top.v"},"contentChanges":[{"text":"a"},{"text":"module top2; endmodule\n"}]}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///x/top.v"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///x/top.v"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
    }) |m| try input.appendSlice(arena, try frame(arena, m));
    var in: Io.Reader = .fixed(input.items);
    var out: Io.Writer.Allocating = .init(arena);
    var err: Io.Writer.Allocating = .init(arena);
    var cli: args.Cli = .{};
    defer cli.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), try serve(gpa, std.testing.io, &cli, &in, &out.writer, &err.writer));
    try std.testing.expectEqualStrings("", err.written());
    // `.vera-flags` is read once. (Its strings died with the session.)
    try std.testing.expectEqual(@as(usize, 1), cli.include_dirs.items.len);
    // Opened, changed once (the empty change is no edit), closed once: three
    // publishes, each empty for a `.v` document.
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, out.written(), "\"diagnostics\":[]"));
}

test "a session over a .v document: `.vera-flags` read once, leak-free under every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".vera-flags", .data = "-I inc\n" });
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    try std.testing.checkAllAllocationFailures(std.testing.allocator, vSession, .{try pathToUri(arena.allocator(), root)});
}

test position {
    // "aé😀b": `b` is byte 7, UTF-16 unit 4 (é is 1 unit, 😀 a surrogate pair).
    const text = "x\naé😀b\n";
    const idx: diag.LineIndex = try .build(std.testing.allocator, text);
    defer std.testing.allocator.free(idx.starts);
    try std.testing.expectEqual(Position{ .line = 1, .character = 7 }, position(text, idx, 9, false));
    try std.testing.expectEqual(Position{ .line = 1, .character = 4 }, position(text, idx, 9, true));
    try std.testing.expectEqual(Position{ .line = 0, .character = 0 }, position(text, idx, 0, true));
}

test "file URIs round-trip, a drive letter and a space included" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    try std.testing.expectEqualStrings("file:///home/x%20y/m.va", try pathToUri(arena, "/home/x y/m.va"));
    try std.testing.expectEqualStrings("/home/x y/m.va", (try uriToPath(arena, "file:///home/x%20y/m.va")).?);
    try std.testing.expectEqualStrings("file:///C%3A/d/m.va", try pathToUri(arena, "C:\\d\\m.va"));
    try std.testing.expectEqualStrings("C:/d/m.va", (try uriToPath(arena, "file:///C%3A/d/m.va")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try uriToPath(arena, "untitled:Untitled-1"));
}

// The oracle is `renderJson`, which places every span by its own walk: for
// every fixture, each primary span `vera --lint --diagnostics=json` reports
// in a file on disk must be the start of a diagnostic the server publishes,
// on the same file at the same line and byte column. Compared as name lists.
test "parity: the server's diagnostics are `--diagnostics=json`'s, on every fixture" {
    if (!ams) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var root = Io.Dir.cwd().openDir(io, "tests/conformance/tests", .{ .iterate = true }) catch return error.SkipZigTest;
    defer root.close(io);
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const inc = try std.fs.path.join(gpa, &.{ cwd, "tests/conformance/tests" });
    defer gpa.free(inc);

    var walker = try root.walk(gpa);
    defer walker.deinit();
    var n: usize = 0;
    var compared: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.basename);
        if (!std.mem.eql(u8, ext, ".va") and !std.mem.eql(u8, ext, ".vams")) continue;
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const path = try std.fs.path.join(arena, &.{ inc, entry.path });
        const text = vera.Preprocessor.readText(io, .cwd(), path, arena) catch continue;

        var bag: diag.Bag = .init(gpa);
        defer bag.deinit(gpa);
        if (vera.compileSourceOpts(gpa, text, .lint, .{
            .file_name = path,
            .include_dirs = &.{inc},
            .diags = &bag,
        })) |r| {
            var ok = r;
            ok.deinit();
        } else |_| {}

        var json: Io.Writer.Allocating = .init(arena);
        try diag.renderJson(&bag, &json.writer);
        var want: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.tokenizeScalar(u8, json.written(), '\n');
        while (lines.next()) |l| {
            const d = try std.json.parseFromSliceLeaky(struct {
                code: []const u8,
                span: ?struct { file: []const u8, line: u32, col: u32 },
            }, arena, l, parse_opts);
            const sp = d.span orelse continue;
            if (!std.fs.path.isAbsolute(sp.file)) continue;
            try want.append(arena, try slashed(arena, "{s} {s}:{d}:{d}", .{ d.code, sp.file, sp.line, sp.col }));
        }

        const doc_uri = try pathToUri(arena, path);
        const by_uri = try diagnostics(arena, &bag, doc_uri, false);
        var got: std.ArrayList([]const u8) = .empty;
        var it = by_uri.iterator();
        while (it.next()) |e| for (e.value_ptr.items) |d| {
            const code = d.code orelse continue;
            const file = (try uriToPath(arena, e.key_ptr.*)).?;
            try got.append(arena, try slashed(arena, "{s} {s}:{d}:{d}", .{ code, file, d.range.start.line + 1, d.range.start.character + 1 }));
        };
        // The JSON's spanless rows and prelude rows are not in `want`; the
        // server puts both at 0:0.
        var kept: std.ArrayList([]const u8) = .empty;
        for (got.items) |g| if (!std.mem.endsWith(u8, g, ":1:1") or containsStr(want.items, g)) try kept.append(arena, g);

        std.mem.sort([]const u8, want.items, {}, lessStr);
        std.mem.sort([]const u8, kept.items, {}, lessStr);
        if (want.items.len != kept.items.len or for (want.items, kept.items) |x, y| {
            if (!std.mem.eql(u8, x, y)) break true;
        } else false) {
            std.debug.print("{s}:\n", .{path});
            for (want.items) |x| std.debug.print("  json: {s}\n", .{x});
            for (kept.items) |x| std.debug.print("  lsp:  {s}\n", .{x});
            return error.TestUnexpectedResult;
        }
        n += 1;
        compared += want.items.len;
    }
    // Fixtures that diagnose nothing would make the comparison vacuous.
    try std.testing.expect(n > 1000 and compared > 500);
}

/// A name-list row with Windows' `\\` as `/`, which a URI path uses.
fn slashed(arena: Allocator, comptime fmt: []const u8, a: anytype) ![]const u8 {
    const row = try arena.print(fmt, a);
    std.mem.replaceScalar(u8, row, '\\', '/');
    return row;
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn containsStr(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}
