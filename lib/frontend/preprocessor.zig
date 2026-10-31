//! Preprocessor: raw source text and include dirs in, preprocessed text out,
//! with comments stripped (newlines kept), macros expanded, `include inlined,
//! and each directive whose state outlives its line published as an event list
//! (`Output.directives`, pp/events.zig). Every deleted byte leaves its newlines
//! behind, and a `diag.SourceMap` maps each output offset back to its file,
//! include or macro origin. `process` is the spine: prelude, command-line
//! macros, the compilation unit, the files beside it, then publication.
//! Cites: LRM §2.4, §10.1-§10.7, annex D, annex E.2; IEEE 1364-2005
//! §13.4.1, §19.1-§19.10, §28.
//!
//! Contents:
//! - `pub const Options = struct`
//! - `pub const File = struct`
//! - `pub const Error = Allocator.Error || error{PreprocessFailed}`
//! - `pub const ReadError`
//! - `pub const Output = struct`
//! - `pub const max_text_bytes: usize`
//! - `pub const segment_levels: u32`
//! - `pub const caller_levels: u32`
//! - `pub const predefined_macros: [3][]const u8`
//! - `pub fn process(arena: Allocator, source: []const u8, opts: Options) Error!Output`
//! - `pub fn readText(io: std.Io, dir: std.Io.Dir, path: []const u8, gpa: Allocator) ReadError![]u8`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const diag = @import("diag");
const spice_cards = @import("spice_cards.zig");
const Pp = @import("pp/Pp.zig");
const protect = @import("pp/protect.zig");
const Directives = @import("pp/events.zig").Directives;

/// Inputs to `process`. Every slice is borrowed for the call.
pub const Options = struct {
    /// Searched in order for `include, before the built-in annex D files.
    include_dirs: []const []const u8 = &.{},
    /// Command-line macros (`vera -D`), each `NAME` or `NAME=TEXT`: defined
    /// after the prelude and before the compilation unit, as `define NAME TEXT
    /// would be; a bare `NAME` is `1`, as iverilog's `-D` defines it.
    defines: []const []const u8 = &.{},
    /// Name the compilation unit is registered under; `__FILE__` expands to it.
    file_name: []const u8 = "<source>",
    /// Prepend annex D.2 constants.vams + annex D.1 disciplines.vams.
    std_defs: bool = true,
    /// With `std_defs` off, still prepend the Table E.1 primitives (and read
    /// `spice_netlist`): E.2 makes them built-ins "in the same manner ... as
    /// built-in primitives of gate- and switch-level modeling", not part of
    /// the annex D prelude. Their `electrical` ports bind to the source's
    /// own discipline of that name. The Verilog-AMS spine sets it; a 1364
    /// design has no use for them.
    spice_primitives: bool = false,
    /// The prepended annex D files serve only a source that `include`s them:
    /// a D.2 macro without `include "constants.vams"` is
    /// E0115, and elaboration hides the D.1 disciplines without
    /// `include "disciplines.vams"` (`Output.disciplines_included`). The
    /// Table E.1 primitives still read both. `vera` and `--lsp` set it.
    require_std_includes: bool = false,
    /// Annex E.2 SPICE netlist text, one card per line. Each `.MODEL` and
    /// `.SUBCKT` becomes a module appended after the Table E.1 prelude; empty
    /// appends nothing. Read only with `std_defs` or `spice_primitives`, because a
    /// model card's interface comes from a Table E.1 primitive.
    spice_netlist: []const u8 = "",
    /// The file `spice_netlist` was read from, or "": its `.INCLUDE`, `.LIB`
    /// and `.HDL` names are looked for beside it (`spice_cards.Reader`).
    spice_path: []const u8 = "",
    /// Files that follow the compilation unit in the same text stream, in
    /// order, as files given together on a command line are (IEEE 1364-2005
    /// §13.4.1). A directive's effect carries across the boundary.
    more: []const File = &.{},
    /// Receives diagnostics, the file table and the source map.
    bag: *diag.Bag,
    /// E0150's bound on the preprocessed text. Only tests lower it, to reach
    /// the diagnostic without 4 GiB of text.
    text_limit: usize = max_text_bytes,
    /// The unit is compiled as IEEE 1364 (`--std=1364-*`). IEEE 1800-2017
    /// §22.5.1's macro text forms (`" `\`" ``) are accepted under every
    /// standard, and under 1364, whose Syntax 19-3 lacks them, each `define
    /// that uses one warns W0151.
    std_1364: bool = false,
    /// IEEE 1364-2005 §28.2: the keys "supplied by the user" for decryption
    /// envelopes (`vera --protect-keys`). None: an envelope is E0152.
    protect_keys: protect.Keys = .{},
};

/// One of `Options.more`: the name it registers under in the bag (and
/// `__FILE__` reads), and its raw text. Both are borrowed for the call and
/// must outlive the bag.
pub const File = struct { name: []const u8, text: []const u8 };

/// `PreprocessFailed` means the diagnostic is already in `Options.bag`;
/// `OutOfMemory` means an allocation failed and nothing was reported.
pub const Error = Allocator.Error || error{PreprocessFailed};

/// Every way `readText` fails: the file cannot be opened, stat'ed or read,
/// memory ran out, or it is past `max_text_bytes` (`StreamTooLong`). Nothing
/// is returned on error.
pub const ReadError = std.Io.File.OpenError || std.Io.File.StatError || std.Io.File.Reader.Error || std.Io.Reader.LimitedAllocError;

/// What `process` publishes. Every slice is owned by the caller's arena.
pub const Output = struct {
    /// The preprocessed bytes, the lexer's input.
    text: []const u8,
    /// How many modules `Options.spice_netlist` contributed. E.2.1's
    /// case-insensitive fallback applies to this tail of the prelude only.
    netlist_modules: u32 = 0,
    /// `spice_cards.Synthesized.unsupported`: the netlist's `.MODEL` cards of
    /// a type VerA has no primitive for.
    netlist_unsupported: []const []const u8 = &.{},
    /// The positional directive events, each list in text-stream order.
    directives: Directives = .{},
    /// Where each of `Options.more` begins in `text`.
    more_starts: []const u32 = &.{},
    /// An `include resolved to the built-in annex D.1 (`disciplines.vams`, or
    /// VD-093's `discipline.h`): the source asked for annex D itself, so its
    /// natures join §3.13.2's uniqueness rule (specification/Vague_Decisions.md VD-096).
    annex_d_included: bool = false,
    /// The source `include`d `disciplines.vams` (or `discipline.h`), from an
    /// include directory or built in. Read with `Options.require_std_includes`.
    disciplines_included: bool = false,
};

/// The longest text the lexer and every later stage can address: offsets
/// are u32 (`lexer.TokenList.start`, `diag.Span`). A source file, an
/// `include file, a `--spice` netlist and the preprocessed text past it are
/// E1013 (a file) or E0150 (the text macros expand to). Not a policy bound:
/// widening every offset to 64 bits would double the token table of every
/// compilation for files no tool writes.
pub const max_text_bytes: usize = std.math.maxInt(u32);

/// Native recursion levels (`include and macro-expansion nesting) one stack
/// segment holds; past them the next level runs on a fresh `deep_stack`
/// segment (`Pp.nested`), so nesting is bounded by memory.
pub const segment_levels: u32 = 1024;

/// Levels the caller's own stack holds before the first segment: the old
/// macro-expansion cap, which every caller's stack held.
pub const caller_levels: u32 = 128;

/// LRM §10.5. Defined for every compilation; `undef on these has no effect.
pub const predefined_macros = [_][]const u8{
    "__VAMS_ENABLE__",
    "__VAMS_COMPACT_MODELING__",
    // §10.5: "Verilog-AMS simulators shall also provide a predefined macro so
    // that the module can conditionally include (or exclude) portions of the
    // source text specific to a particular simulator." The spelling is ours;
    // it avoids the `__VAMS_` prefix §10.4 reserves.
    "__VERA__",
};

/// Preprocesses `source`: strips comments (§2.4, newlines kept), runs the
/// conditionals, expands macros (§10.4), inlines `include, and prepends the
/// annex D and Table E.1 definitions when `opts.std_defs` is set.
///
/// Registers `source` as the bag's `.root` file, so the bag must be empty;
/// with `opts.std_defs`, asserts that it was. Sets `opts.bag.map`. Returns
/// output owned by `arena`. Fails with `error.PreprocessFailed` once the
/// diagnostic is in `opts.bag` (the first error ends the call), or with
/// `error.OutOfMemory`. O(output) apart from `__LINE__`, which is O(offset)
/// per use.
pub fn process(arena: Allocator, source: []const u8, opts: Options) Error!Output {
    // Everything that dies with this call (the macro table, the stacks, every
    // expansion's arguments and substituted body, and the output while it
    // grows) lives on scratch, freed on return. What outlives the call is
    // copied to `arena` once, exactly sized, at the end.
    var scratch_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch_state.deinit();
    assert(opts.text_limit <= max_text_bytes);
    var pp: Pp = .{ .arena = arena, .scratch = scratch_state.allocator(), .opts = opts };

    // First, so the compilation unit is `.root`. The prelude files register
    // after it, even though they are processed before it.
    const root = try pp.addFile(opts.file_name, source);

    for (predefined_macros) |name| {
        try pp.putMacro(name, .{ .body = "1", .predefined = true });
    }

    var netlist_modules: u32 = 0;
    var netlist_unsupported: []const []const u8 = &.{};
    var hdl: []const []const u8 = &.{};
    if (opts.std_defs or opts.spice_primitives) {
        // Replayed from the process-lifetime snapshot (`Prelude`), which
        // tests/unit.zig's preprocessor_tests check against a fresh
        // `runStdDefs`.
        if (opts.std_defs) try pp.replayStdDefs() else try pp.runSpicePrimitives();
        // Annex E.2 after Table E.1: a `.MODEL` wrapper instantiates the
        // primitive its type names, so the primitive has to be declared first.
        const cards = try spice_cards.synthesize(arena, opts.spice_netlist, opts.spice_path);
        if (cards.refused.len != 0) {
            // E.1.2: a card inside a definition outside VerA's claimed SPICE
            // subset is refused, not skipped (see `spice_cards`).
            const ids = try pp.scratch.alloc(diag.FileId, cards.files.len);
            @memset(ids, .none);
            for (cards.refused) |r| {
                if (ids[r.file] == .none) ids[r.file] = try pp.addFile(cards.files[r.file].name, cards.files[r.file].text);
                const id = ids[r.file];
                var b = opts.bag.build(.preprocess, switch (r.code) {
                    .E0928 => .E0928,
                    .E0953 => .E0953,
                }, .{ .start = r.at, .end = r.at + r.len });
                b.inFile(id);
                b.msg("{s}", .{r.why});
                try b.emit();
            }
            return error.PreprocessFailed;
        }
        hdl = cards.hdl;
        if (cards.modules != 0) {
            pp.in_std_defs = true;
            defer pp.in_std_defs = false;
            try pp.runFile(cards.text, "spice_netlist.vams", .none);
            netlist_modules = cards.modules;
        }
        netlist_unsupported = cards.unsupported;
    }

    for (opts.defines) |d| {
        const eq = std.mem.findScalar(u8, d, '=');
        try pp.putMacro(d[0 .. eq orelse d.len], .{ .body = if (eq) |i| d[i + 1 ..] else "1" });
    }

    // The compilation unit's output is about its own length (comments out,
    // expansions in), so reserve that once instead of regrowing.
    try pp.out.ensureUnusedCapacity(pp.scratch, source.len);
    try pp.runFile(source, opts.file_name, root);
    const more_starts = try arena.alloc(u32, opts.more.len);
    for (opts.more, more_starts) |f, *at| {
        // A file need not end in a newline, and its last word must not join
        // the next file's first.
        try pp.out.append(pp.scratch, '\n');
        at.* = @intCast(pp.out.items.len);
        try pp.runFile(f.text, f.name, .none);
    }
    // HSPICE `.HDL "model.va"` in the netlist: a Verilog-A source of the
    // design, read after the compilation unit like a file given beside it on
    // the command line (IEEE 1364-2005 §13.4.1), so its modules are the
    // user's and E.3.3 selects them by name.
    for (hdl) |path| {
        const io = std.Io.Threaded.global_single_threaded.io();
        const text = readText(io, .cwd(), path, arena) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                var b = opts.bag.build(.preprocess, .E0126, .{ .start = 0, .end = 0 });
                b.inFile(root);
                b.msg("\"{s}\", named by the netlist's `.hdl` card ({t})", .{ path, e });
                try b.emit();
                return error.PreprocessFailed;
            },
        };
        try pp.out.append(pp.scratch, '\n');
        try pp.runFile(text, path, .none);
    }

    if (pp.conds.items.len != 0) {
        const top = pp.conds.items[pp.conds.items.len - 1];
        pp.cur_file_id = top.file;
        pp.expand_site = null;
        // The catalogue's contract for E0101: point at end of source, name the
        // unclosed directive in a label.
        const text = opts.bag.fileText(top.file);
        var b = pp.failWith(.{ .start = @intCast(text.len), .end = @intCast(text.len) }, .E0101);
        b.msg("", .{});
        b.label(top.span, "unclosed", .{});
        try b.emit();
        return error.PreprocessFailed;
    }

    // Publish: each scratch table is copied to `arena` by name, so a new event
    // list is one field in `Directives` and the same field in `Events`.
    var directives: Directives = .{};
    const fields = @typeInfo(Directives).@"struct";
    inline for (fields.field_names, fields.field_types) |name, F| {
        @field(directives, name) = try arena.dupe(@typeInfo(F).pointer.child, @field(pp.events, name).items);
    }
    opts.bag.map = .{ .segs = try arena.dupe(diag.Segment, pp.segs.items) };
    assert(pp.conds.items.len == 0);
    assert(pp.expanding.items.len == 0);
    return .{
        .text = try arena.dupe(u8, pp.out.items),
        .netlist_modules = netlist_modules,
        .netlist_unsupported = netlist_unsupported,
        .directives = directives,
        .more_starts = more_starts,
        .annex_d_included = pp.annex_d_included,
        .disciplines_included = pp.disciplines_included,
    };
}

/// Reads the whole file at `path` (relative to `dir`) into `gpa` memory.
/// `error.StreamTooLong` for a file past `max_text_bytes`, known from its
/// size before anything is read; a stream with no size (a pipe, /dev/zero)
/// is read until it passes the bound. An empty `path` (user-typed: `vera ""`,
/// `--spice=`) is `error.FileNotFound`, the error the OS gave before.
pub fn readText(io: std.Io, dir: std.Io.Dir, path: []const u8, gpa: Allocator) ReadError![]u8 {
    if (path.len == 0) return error.FileNotFound;
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    const st = try file.stat(io);
    if (st.kind == .file and st.size > max_text_bytes) return error.StreamTooLong;
    var r = file.reader(io, &.{});
    const text = r.interface.allocRemaining(gpa, .limited(max_text_bytes +| 1)) catch |e| switch (e) {
        error.ReadFailed => return r.err.?,
        else => |other| return other,
    };
    assert(text.len <= max_text_bytes);
    return text;
}

test "readText: an empty path is FileNotFound, not an assert" {
    // Oracle: development's readText passed "" to openFile, which the OS refuses as not found.
    try std.testing.expectError(error.FileNotFound, readText(std.testing.io, .cwd(), "", std.testing.allocator));
}

test {
    // Every pp/ file, so each one's own tests and declarations compile with
    // this module's.
    _ = @import("pp/Pp.zig");
    _ = @import("pp/scan.zig");
    _ = @import("pp/events.zig");
    _ = @import("pp/comments.zig");
    _ = @import("pp/macro.zig");
    _ = @import("pp/directive.zig");
    _ = @import("pp/include.zig");
    _ = @import("pp/directive_events.zig");
    _ = @import("pp/prelude.zig");
    _ = protect;
    _ = @import("pp/annex_d.zig");
    _ = @import("pp/annex_e.zig");
}
