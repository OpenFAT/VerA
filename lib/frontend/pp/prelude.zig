//! Prelude snapshot: the embedded annex D.2, D.1 and Table E.1 text in, its
//! preprocessed output, macros, tokens and parse out, built once per process
//! and replayed into every compilation that uses the standard definitions.
//! Cites: LRM annex D, annex E, §10.5.
//!
//! Contents:
//! - `pub const Prelude = struct`
//! - `pub fn preludeTokens(std_defs: bool) Allocator.Error!?lexer.Seed`
//! - `pub fn preludeAst(std_defs: bool) Allocator.Error!?*const Parser.Parser.Seed`
//! - `pub fn preludeSnapshot() Allocator.Error!*const Prelude`
//! - `pub fn buildPrelude() Allocator.Error!*const Prelude`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const diag = @import("diag");
const lexer = @import("../lexer.zig");
const keyword = @import("../keyword.zig");
const token = @import("../token.zig");
const Parser = @import("../parser.zig");
const predefined_macros = @import("../preprocessor.zig").predefined_macros;
const Pp = @import("Pp.zig");
const Macro = Pp.Macro;
const Events = @import("events.zig").Events;
const pp_annex_d = @import("annex_d.zig");
const pp_annex_e = @import("annex_e.zig");

/// Annex D.2, D.1 and Table E.1, preprocessed, lexed and parsed once per
/// process.
///
/// Keyed on nothing: the three files are compile-time constants with no
/// `include, and the macros their conditionals test (`CONSTANTS_VAMS,
/// `DISCIPLINES_VAMS, the `*_ABSTOL overrides) can only come from user text,
/// which runs after them. The annex E.2 netlist tail varies and is appended by
/// `process` after the replay. Preprocessing the prelude per compilation
/// dominated the preprocessor stage.
///
/// Holds everything the three `runFile` calls write into `Pp` (output bytes,
/// source-map segments, macros, and the file registrations the segments index
/// by position), plus the lexed tokens (`preludeTokens`) and the parse
/// (`preludeAst`). A `Pp` or `Parser` field the prelude can write must be
/// added here too; the equivalence tests in tests/unit.zig's preprocessor_tests catch a miss.
///
/// Lifetime: process-long, never freed, immutable after publication. Thread
/// safe: published by a release compare-exchange and read by an acquire load.
/// Threads racing the first compilation each build one; the losers' arenas
/// leak, bounded by the number of racing threads.
pub const Prelude = struct {
    text: []const u8,
    /// `text`'s tokens, `.eof` excluded (see `preludeTokens`). Two columns, the
    /// shape `lexer.Seed` takes.
    tags: []const token.Tag,
    starts: []const u32,
    /// The parse of the same tokens (see `preludeAst`).
    ast: Parser.Parser.Seed,
    segs: []const diag.Segment,
    macros: []const Def,
    /// In registration order, so the `FileId`s in `segs` (indices into
    /// `Bag.files`) mean the same thing on replay as on capture.
    files: [3]File,

    const Def = struct { name: []const u8, macro: Macro };
    const File = struct {
        name: []const u8,
        raw: []const u8,
        stripped: []const u8,
        /// The stripped→raw offset map `stripComments` left on the bag, so a
        /// replayed registration renders exactly like a fresh one.
        marks: []const diag.StripMark,
    };
};

var prelude_snapshot: std.atomic.Value(?*const Prelude) = .init(null);

/// Returns the prelude's tokens for `lexer.tokenize`'s seed, so a compilation
/// lexes only the bytes after the prelude; null when `std_defs` is off.
///
/// Sound because `process` writes the prelude first, so `Prelude.text` is a
/// byte-exact prefix of every preprocessed text with `std_defs`, and
/// `lexer.Lexer.next` reads no state but the cursor. The columns are
/// process-lifetime and immutable (see `Prelude`); the caller copies them.
pub fn preludeTokens(std_defs: bool) Allocator.Error!?lexer.Seed {
    if (!std_defs) return null;
    const p = try preludeSnapshot();
    assert(p.tags.len == p.starts.len);
    // `.eof` was dropped: every start lies inside the prelude's text.
    if (p.starts.len != 0) assert(p.starts[p.starts.len - 1] < p.text.len);
    return .{ .tags = p.tags, .starts = p.starts, .len = @intCast(p.text.len) };
}

/// Returns the parser state the prelude's tokens leave, for
/// `Parser.initSeeded`, so a compilation parses only the tokens after the
/// prelude; null when `std_defs` is off.
///
/// Sound because every id (`StrId`, `ExprId`, `StmtId`, pool offsets) is an
/// index into an append-only column, so the prelude's ids are the same prefix
/// in every compilation. The declaration arrays are shared, since nothing
/// below the parser writes them; the stores are copied, since §6.7 flattening
/// appends to them (see `Ast.SourceFile.seedFrom`). The seed's interned names
/// borrow `Prelude.text`; the interner compares by content, so that is
/// invisible. Lifetime and thread safety are `Prelude`'s.
pub fn preludeAst(std_defs: bool) Allocator.Error!?*const Parser.Parser.Seed {
    if (!std_defs) return null;
    const p = try preludeSnapshot();
    // The parse stopped on `.eof`: its cursor is the token count.
    assert(p.ast.pos == p.tags.len);
    return &p.ast;
}

/// Returns the process-wide `Prelude`, building it on first use.
pub fn preludeSnapshot() Allocator.Error!*const Prelude {
    if (prelude_snapshot.load(.acquire)) |p| return p;
    const p = try buildPrelude();
    if (prelude_snapshot.cmpxchgStrong(null, p, .release, .acquire)) |won| return won.?;
    assert(prelude_snapshot.load(.acquire) == p);
    return p;
}

/// Preprocesses, lexes and parses the three files on a never-freed arena and
/// returns what they produced: nobody owns or frees the result. Callers go
/// through `preludeSnapshot`. Asserts the shipped files produce no
/// diagnostic, no positional directive and no open parser state.
pub fn buildPrelude() Allocator.Error!*const Prelude {
    const arena_state = try std.heap.page_allocator.create(std.heap.ArenaAllocator);
    arena_state.* = .init(std.heap.page_allocator);
    const arena = arena_state.allocator();

    var bag: diag.Bag = .init(arena);
    // Both lifetimes are the snapshot's: it keeps the macro table and output.
    var pp: Pp = .{ .arena = arena, .scratch = arena, .opts = .{ .bag = &bag } };
    // The same starting state `process` has: the compilation unit is file 0 and
    // the §10.5 predefined macros are already in scope. Both are observable to a
    // `ifdef in a prelude file, so neither may be skipped here.
    _ = try bag.addFile("<source>", "");
    for (predefined_macros) |name| {
        try pp.putMacro(name, .{ .body = "1", .predefined = true });
    }

    pp.runStdDefs() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // The three files are compile-time constants that this tree's tests
        // preprocess on every run; a diagnostic out of them is a broken build,
        // not a user error, and there is no user bag to report it into.
        error.PreprocessFailed => unreachable,
    };

    // The rest of `Pp`'s output surface is empty: the shipped files hold no
    // positional directive and no unclosed `ifdef. A prelude file that writes
    // one must extend `Prelude` rather than lose the event.
    inline for (@typeInfo(Events).@"struct".field_names) |name| {
        assert(@field(pp.events, name).items.len == 0);
    }
    assert(pp.conds.items.len == 0);

    // `process` inserts the §10.5 predefined macros itself.
    var n_macros: usize = 0;
    var vit = pp.macros.valueIterator();
    while (vit.next()) |m| n_macros += @intFromBool(!m.predefined);
    var macros: std.ArrayList(Prelude.Def) = try .initCapacity(arena, n_macros);
    var it = pp.macros.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.predefined) continue;
        macros.appendAssumeCapacity(.{ .name = e.key_ptr.*, .macro = e.value_ptr.* });
    }
    assert(macros.items.len == n_macros);

    // Lex the same bytes.
    var toks = try lexer.tokenize(arena, pp.out.items, null);
    assert(toks.len > 0);
    assert(toks.items(.tag)[toks.len - 1] == .eof);

    // Parse the whole token list including `.eof`, which `Parser.init`
    // requires. The parse stops on it, so `pos` is the prelude's token count
    // and the first index a resumed parse reads.
    var parser = Parser.Parser.init(arena, pp.out.items, toks.items(.tag), toks.items(.start), &bag);
    const file = parser.parseSourceFile() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // As for `runStdDefs` above.
        error.ParseError => unreachable,
    };
    // The rest of `Parser`'s state is back at its `init` value: the shipped
    // files leave no `begin_keywords, generate region, analog function or
    // connect module open. A prelude file that does must extend `Parser.Seed`.
    assert(!parser.failed);
    assert(bag.isEmpty());
    assert(parser.pos == toks.len - 1);
    assert(parser.kw_set == keyword.default_keyword_set);
    assert(parser.kw_stack.items.len == 0);
    assert(parser.attrs.items.len == 0);
    assert(parser.attr_depth == 0);
    assert(!parser.in_analog_fn);
    assert(!parser.analog_expr);
    assert(!parser.analog_event_block);
    assert(!parser.in_connect_module);
    assert(!parser.in_discrete);
    assert(!parser.in_digital_delay);
    assert(parser.gen_depth == 0);
    assert(parser.gen_construct_depth == 0);

    const access = try arena.alloc([]const u8, parser.access_names.count());
    var ait = parser.access_names.keyIterator();
    for (access) |*a| a.* = ait.next().?.*;
    assert(ait.next() == null);

    // Drop `.eof` from the seed columns: the compilation's buffer ends past the
    // user's source, not here.
    toks.len -= 1;

    const p = try arena.create(Prelude);
    p.* = .{
        .text = pp.out.items,
        .tags = toks.items(.tag),
        .starts = toks.items(.start),
        .ast = .{
            .file = file,
            .access_names = access,
            .pos = parser.pos,
            .gen_construct = parser.gen_construct,
        },
        .segs = pp.segs.items,
        .macros = macros.items,
        .files = .{
            .{ .name = "constants.vams", .raw = pp_annex_d.constants_vams, .stripped = bag.fileText(@fromBackingInt(@intCast(1))), .marks = bag.fileMarks(@fromBackingInt(@intCast(1))) },
            .{ .name = "disciplines.vams", .raw = pp_annex_d.disciplines_vams, .stripped = bag.fileText(@fromBackingInt(@intCast(2))), .marks = bag.fileMarks(@fromBackingInt(@intCast(2))) },
            .{ .name = "spice_primitives.vams", .raw = pp_annex_e.spice_primitives, .stripped = bag.fileText(@fromBackingInt(@intCast(3))), .marks = bag.fileMarks(@fromBackingInt(@intCast(3))) },
        },
    };
    return p;
}
