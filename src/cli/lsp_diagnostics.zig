//! A compilation's diagnostic bag -> LSP 3.17 `publishDiagnostics` rows,
//! grouped by the URI each lands on, with each fix-it in the row's `data` for
//! `codeAction`; and the `file://` URI <-> path conversions they place by.
//! Positions are UTF-16 code units or UTF-8 bytes, converted in one place
//! (`position`).
//!
//! Cites: none of the LRM's; LSP 3.17 (positions, `publishDiagnostics`),
//! RFC 3986 (URI percent-encoding).
//!
//! Contents:
//! - `pub const Position`, `pub const Range`, `pub const Fix`,
//!   `pub const Related`, `pub const Diagnostic`, `pub const ByUri`,
//!   `pub const Error = Allocator.Error || Io.Writer.Error`
//! - `pub fn diagnostics(arena: Allocator, bag: *diag.Bag, uri: []const u8, utf16: bool) Error!ByUri`
//! - `pub fn uriToPath(arena: Allocator, uri: []const u8) Allocator.Error!?[]const u8`
//! - `pub fn pathToUri(arena: Allocator, path: []const u8) Error![]const u8`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const vera = @import("vera");
const diag = vera.diag;
const Preprocessor = @import("frontend").Preprocessor;
/// `-Dlanguage=ams`: the parity test needs the analog pipeline.
const ams = @import("build_options").ams;

/// A 0-based line and character, the character in the negotiated encoding.
pub const Position = struct { line: u32, character: u32 };
/// A half-open span of two positions.
pub const Range = struct { start: Position, end: Position };

/// A fix-it, carried in the diagnostic's `data` so `codeAction` needs no
/// state: the client sends the diagnostic back as it got it.
pub const Fix = struct { title: []const u8, uri: []const u8, range: Range, newText: []const u8 };

/// A label of the diagnostic, placed where it points.
pub const Related = struct {
    location: struct { uri: []const u8, range: Range },
    message: []const u8,
};

/// One `publishDiagnostics` row.
pub const Diagnostic = struct {
    range: Range,
    /// 1 error, 2 warning, 3 information.
    severity: u8,
    code: ?[]const u8 = null,
    source: []const u8 = "vera",
    message: []const u8,
    relatedInformation: []const Related = &.{},
    data: struct { fixes: []const Fix = &.{} } = .{},
};

/// Each URI a lint published on, with its rows; the document's own first.
pub const ByUri = std.StringArrayHashMapUnmanaged(std.ArrayList(Diagnostic));

/// Every way `diagnostics` fails: its arena, or a message it formats.
pub const Error = Allocator.Error || Io.Writer.Error;

/// The parity test's name-list helpers.
const names = struct {
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
};

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
        assert(start <= text.len);
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

/// The bag as LSP diagnostics, grouped by the URI each lands on; `uri`, the
/// linted document's, is always the first key. A diagnostic in a file that
/// is not on disk (the annex D prelude) lands on `uri`'s first character,
/// its own place named in the message. Sorts the bag.
pub fn diagnostics(arena: Allocator, bag: *diag.Bag, uri: []const u8, utf16: bool) Error!ByUri {
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
    assert(std.mem.eql(u8, by_uri.keys()[0], uri));
    if (bag.suppressed != 0) try by_uri.getPtr(uri).?.append(arena, .{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
        .severity = 3,
        .message = try arena.print("{d} more diagnostics not shown: a run stops at its cap", .{bag.suppressed}),
    });
    return by_uri;
}

/// `file://` URI -> path, percent-decoded (`file:///C:/x` -> `C:/x`); null
/// for any other scheme (`untitled:`).
pub fn uriToPath(arena: Allocator, uri: []const u8) Allocator.Error!?[]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    const buf = try arena.dupe(u8, uri[prefix.len..]);
    const p = std.Uri.percentDecodeInPlace(buf);
    if (p.len >= 3 and p[0] == '/' and p[2] == ':') return p[1..]; // a Windows drive
    return p;
}

/// Absolute path -> `file://` URI, percent-encoding all but RFC 3986's
/// unreserved bytes and `/`. A Windows path's `\` becomes `/`.
pub fn pathToUri(arena: Allocator, path: []const u8) Error![]const u8 {
    assert(path.len != 0);
    var w: Io.Writer.Allocating = .init(arena);
    try w.writer.writeAll(if (path.len >= 2 and path[1] == ':') "file:///" else "file://");
    for (path) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '/' => try w.writer.writeByte(c),
        '\\' => try w.writer.writeByte('/'),
        else => try w.writer.print("%{X:0>2}", .{c}),
    };
    return w.written();
}

// ---- private ----

/// Byte offset `off` of `text` -> 0-based line and character, the character
/// counted in UTF-16 code units when `utf16`, else in bytes. Invalid UTF-8
/// counts a unit per non-continuation byte.
fn position(text: []const u8, index: diag.LineIndex, off: u32, utf16: bool) Position {
    assert(off <= text.len);
    const loc = index.loc(off);
    const line_start = index.starts[loc.line - 1];
    assert(line_start <= off);
    if (!utf16) return .{ .line = loc.line - 1, .character = off - line_start };
    var units: u32 = 0;
    for (text[line_start..off]) |c| {
        units += @intFromBool(c & 0xc0 != 0x80); // a lead byte starts a code point
        units += @intFromBool(c >= 0xf0); // a 4-byte sequence is a surrogate pair
    }
    return .{ .line = loc.line - 1, .character = units };
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
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    // The conformance suite's corpus. Its sources include the annex D files
    // themselves, and `include "check.vh"` finds `include/`.
    const tests = try std.fs.path.join(gpa, &.{ cwd, "tests/conformance/tests" });
    defer gpa.free(tests);
    const inc = try std.fs.path.join(gpa, &.{ tests, "include" });
    defer gpa.free(inc);

    var n: usize = 0;
    var compared: usize = 0;
    // `netlist/` is ESPice's decks, not VerA's sources.
    for ([_][]const u8{ "verilog-a", "verilog-ams", "spice", "verilog" }) |lang| {
        const dir = try std.fs.path.join(gpa, &.{ tests, lang });
        defer gpa.free(dir);
        // A missing corpus is a failure, not a skip: AGENTS.md's clone step
        // initializes `tests/conformance`, and a skip would pass the oracle silently.
        var root = try Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
        defer root.close(io);
        var walker = try root.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const ext = std.fs.path.extension(entry.basename);
            if (!std.mem.eql(u8, ext, ".va") and !std.mem.eql(u8, ext, ".vams")) continue;
            var arena_state: std.heap.ArenaAllocator = .init(gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const path = try std.fs.path.join(arena, &.{ dir, entry.path });
            const text = Preprocessor.readText(io, .cwd(), path, arena) catch continue;

            var bag: diag.Bag = .init(gpa);
            defer bag.deinit(gpa);
            if (vera.analyze(gpa, text, .{
                .file_name = path,
                .include_dirs = &.{inc},
                .require_std_includes = true, // as `serve` compiles a document
            }, &bag)) |r| {
                var ok = r;
                ok.deinit(gpa);
            } else |_| {} // A refused fixture still has diagnostics to compare.

            var json: Io.Writer.Allocating = .init(arena);
            try diag.renderJson(&bag, &json.writer);
            var want: std.ArrayList([]const u8) = .empty;
            var lines = std.mem.tokenizeScalar(u8, json.written(), '\n');
            while (lines.next()) |l| {
                const d = try std.json.parseFromSliceLeaky(struct {
                    code: []const u8,
                    span: ?struct { file: []const u8, line: u32, col: u32 },
                }, arena, l, .{ .ignore_unknown_fields = true });
                const sp = d.span orelse continue;
                if (!std.fs.path.isAbsolute(sp.file)) continue;
                try want.append(arena, try names.slashed(arena, "{s} {s}:{d}:{d}", .{ d.code, sp.file, sp.line, sp.col }));
            }

            const doc_uri = try pathToUri(arena, path);
            const by_uri = try diagnostics(arena, &bag, doc_uri, false);
            var got: std.ArrayList([]const u8) = .empty;
            var it = by_uri.iterator();
            while (it.next()) |e| for (e.value_ptr.items) |d| {
                const code = d.code orelse continue;
                const file = (try uriToPath(arena, e.key_ptr.*)).?;
                try got.append(arena, try names.slashed(arena, "{s} {s}:{d}:{d}", .{ code, file, d.range.start.line + 1, d.range.start.character + 1 }));
            };
            // The JSON's spanless rows and prelude rows are not in `want`; the
            // server puts both at 0:0.
            var kept: std.ArrayList([]const u8) = .empty;
            for (got.items) |g| if (!std.mem.endsWith(u8, g, ":1:1") or names.containsStr(want.items, g)) try kept.append(arena, g);

            std.mem.sort([]const u8, want.items, {}, names.lessStr);
            std.mem.sort([]const u8, kept.items, {}, names.lessStr);
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
    }
    // Fixtures that diagnose nothing would make the comparison vacuous.
    try std.testing.expect(n > 1000 and compared > 500);
}
