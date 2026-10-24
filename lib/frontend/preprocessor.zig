//! Preprocessor: raw source text and include dirs in, preprocessed text out,
//! with comments stripped (newlines kept), macros expanded, `include inlined,
//! and each directive whose state outlives its line published as an event list.
//! LRM §2.4, §10.1-§10.7, annex D; IEEE 1364 §19.1-§19.10.
//! Every deleted byte leaves its newlines behind, and a `diag.SourceMap` maps
//! each output offset back to its file, include or macro origin.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diag = @import("diag");
const deep_stack = @import("base").deep_stack;
/// Annex E.2 `.MODEL`/`.SUBCKT` reader; its modules follow the prelude.
const spice_cards = @import("spice_cards.zig");

/// Inputs to `process`. Every slice is borrowed for the call.
pub const Options = struct {
    /// Searched in order for `include, before the built-in annex D files.
    include_dirs: []const []const u8 = &.{},
    /// Name the compilation unit is registered under; `__FILE__` expands to it.
    file_name: []const u8 = "<source>",
    /// Prepend annex D.2 constants.vams + annex D.1 disciplines.vams.
    std_defs: bool = true,
    /// The prepended annex D files serve only a source that `include`s them:
    /// a D.2 macro without `include "constants.vams"` is
    /// E0115, and elaboration hides the D.1 disciplines without
    /// `include "disciplines.vams"` (`Output.disciplines_included`). The
    /// Table E.1 primitives still read both. `vera` and `--lsp` set it.
    require_std_includes: bool = false,
    /// Annex E.2 SPICE netlist text, one card per line. Each `.MODEL` and
    /// `.SUBCKT` becomes a module appended after the Table E.1 prelude; empty
    /// appends nothing. Read only with `std_defs`, because a model card's
    /// interface comes from a Table E.1 primitive.
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
};

/// One of `Options.more`: the name it registers under in the bag (and
/// `__FILE__` reads), and its raw text. Both are borrowed for the call and
/// must outlive the bag.
pub const File = struct { name: []const u8, text: []const u8 };

/// `PreprocessFailed` means the diagnostic is already in `Options.bag`;
/// `OutOfMemory` means an allocation failed and nothing was reported.
pub const Error = Allocator.Error || error{PreprocessFailed};

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

/// Every directive whose state outlives its own line, as `Region` event lists
/// in text-stream order. Only a later stage can apply them, so each consumer
/// looks up its own output offset.
pub const Directives = struct {
    /// §10.2 `default_discipline, for §7.4 discipline resolution.
    disciplines: []const DefaultDiscipline = &.{},
    /// §10.3 `default_transition, for §4.5.8's rise/fall defaulting.
    transitions: []const DefaultTransition = &.{},
    /// IEEE 1364 §19.8 `timescale; a null value is §19.6's `resetall.
    timescales: []const TimescaleEvent = &.{},
    /// IEEE 1364 §19.2 `default_nettype, for §3.6.5 implicit-net creation
    /// (`Lower.rejectImplicitNet`).
    nettypes: []const NetTypeRegion = &.{},
    /// IEEE 1364 §19.1 `celldefine/`endcelldefine (`Mir.is_cell`).
    cells: []const CellRegion = &.{},
    /// IEEE 1364 §19.9 `unconnected_drive/`nounconnected_drive, for §6.2.2's
    /// blank port connections (`Lower.applyUnconnectedDrive`).
    drives: []const DriveRegion = &.{},

    /// Returns the `timescale in force at the end of the stream, or null if
    /// none is. Read by §9.15 Table 9-27's "timeUnit" and "timePrecision".
    ///
    /// ponytail: the last one wins, so every module of one file shares it,
    /// although the directive scopes to the design elements that follow it.
    /// Look the module's own offset up with `TimescaleEvent.inForce` once a
    /// fixture puts a `timescale between two modules.
    pub fn timescale(self: Directives) ?Timescale {
        return if (self.timescales.len == 0) null else self.timescales[self.timescales.len - 1].value;
    }
};

/// The longest text the lexer and every later stage can address: offsets
/// are u32 (`Lexer.TokenList.start`, `diag.Span`). A source file, an
/// `include file, a `--spice` netlist and the preprocessed text past it are
/// E1013 (a file) or E0150 (the text macros expand to). Not a policy bound:
/// widening every offset to 64 bits would double the token table of every
/// compilation for files no tool writes.
pub const max_text_bytes: usize = std.math.maxInt(u32);

/// Native recursion levels (`include and macro-expansion nesting) one stack
/// segment holds; past them the next level runs on a fresh `deep_stack`
/// segment (`Pp.nested`), so nesting is bounded by memory.
pub const segment_levels = 1024;
/// Levels the caller's own stack holds before the first segment: the old
/// macro-expansion cap, which every caller's stack held.
pub const caller_levels = 128;

/// Reads the whole file at `path` (relative to `dir`) into `gpa` memory.
/// `error.StreamTooLong` for a file past `max_text_bytes`, known from its
/// size before anything is read; a stream with no size (a pipe, /dev/zero)
/// is read until it passes the bound.
pub fn readText(io: std.Io, dir: std.Io.Dir, path: []const u8, gpa: Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    const st = try file.stat(io);
    if (st.kind == .file and st.size > max_text_bytes) return error.StreamTooLong;
    var r = file.reader(io, &.{});
    return r.interface.allocRemaining(gpa, .limited(max_text_bytes +| 1)) catch |e| switch (e) {
        error.ReadFailed => return r.err.?,
        else => |other| return other,
    };
}

/// Directives handled here. LRM §10 Table 10-1.
pub const Directive = enum {
    define, // §10.4
    undef, // §10.4
    ifdef, // IEEE 1364 §19.4
    ifndef, // IEEE 1364 §19.4
    elsif, // IEEE 1364 §19.4
    @"else", // IEEE 1364 §19.4
    endif, // IEEE 1364 §19.4
    include, // IEEE 1364 §19.5
    resetall, // IEEE 1364 §19.6: directive state only; §19.3 keeps macros
    keywords, // §10.6: emitted verbatim, handled by the parser
    default_discipline, // §10.2: parsed here, applied by discipline resolution
    default_transition, // §10.3: parsed here, applied by §4.5.8 codegen
    line, // IEEE 1364 §19.7: remaps §10.7 `__LINE__` / `__FILE__`
    timescale, // IEEE 1364 §19.8: read back by §9.15 Table 9-27
    default_nettype, // IEEE 1364 §19.2: read by implicit-net creation
    celldefine, // IEEE 1364 §19.1: cell membership, `endcelldefine closes it
    endcelldefine,
    unconnected_drive, // IEEE 1364 §19.9: read by §6.2.2 port binding
    nounconnected_drive,
    pragma, // IEEE 1364 §19.10: no effect, except §28's `protect` (E0146)
};

/// §10.2 Syntax 10-1:
///
///   default_discipline_directive ::=
///       `default_discipline [ discipline_identifier [ qualifier ] ]
///   qualifier ::= integer | real | reg | wreal | wire | tri | wand | triand
///               | wor | trior | trireg | tri0 | tri1 | supply0 | supply1
///
/// A closed list of fifteen names, so anything else in that slot is a syntax
/// error, not a second discipline (E0127).
pub const Qualifier = enum { integer, real, reg, wreal, wire, tri, wand, triand, wor, trior, trireg, tri0, tri1, supply0, supply1 };

/// One `default_discipline, or the `resetall or bare form that withdraws one.
/// §10.2 applies it "to all discrete signals without a discipline declaration
/// that appear in the text stream following the use of the directive", so §7.4
/// discipline resolution looks each net's declaration offset up against the
/// events.
///
/// `at` is an offset into the preprocessed output, the unit every later stage
/// reports in, so it compares directly against a token start.
pub const DefaultDiscipline = struct {
    at: u32,
    /// Syntax 10-1's optional qualifier; null when the directive named none.
    qualifier: ?Qualifier,
    /// "" withdraws every default in force from `at` on. §10.2: "In addition
    /// to `resetall, if this directive is used without a discipline name,
    /// discipline resolution will not use a default discipline for nets
    /// declared after this directive is encountered in the text stream."
    discipline: []const u8,

    /// The default in force at offset `at` of `events` for a signal of type
    /// `qualifier`, or null. The most recent directive wins, and one naming
    /// `qualifier` wins over an unqualified one however old it is ("the more
    /// specific directives have higher precedence"). A directive naming
    /// another qualifier does not apply: "more than one `default_discipline
    /// directive can be in force simultaneously, provided each differs in
    /// qualifier".
    pub fn inForce(events: []const DefaultDiscipline, at: u32, qualifier: ?Qualifier) ?[]const u8 {
        var fallback: ?[]const u8 = null;
        var i = events.len;
        return while (i > 0) {
            i -= 1;
            const e = events[i];
            if (e.at > at) continue;
            // §10.2: the bare form and `resetall withdraw the default outright,
            // so nothing older than one of those is still in force.
            if (e.discipline.len == 0) break fallback;
            if (e.qualifier != null and e.qualifier == qualifier) break e.discipline;
            if (e.qualifier == null and fallback == null) fallback = e.discipline;
        } else fallback;
    }
};

/// One §10.3 `` `default_transition ``. `value` is the transition time in
/// seconds, used for both rise and fall; null after `resetall. A filter takes
/// its default from "the directive which immediately precedes the transition
/// filter" (§10.3), which is `Region.inForce` at the filter's offset.
pub const DefaultTransition = Region(?f64);

/// One IEEE 1364 §19.8 `` `timescale <unit> / <precision> ``; null after
/// `resetall. Nothing rescales time (§9.10 `$abstime` is always seconds); the
/// operands exist to be read back by §9.15 Table 9-27.
pub const TimescaleEvent = Region(?Timescale);

/// A `timescale's two operands, in seconds (`base`'s).
pub const Timescale = @import("base").Timescale;

/// One positional directive event: the output offset where its value
/// changed, and the new value (`base`'s, so `Lowered` holds the lists
/// without importing the frontend).
pub const Region = @import("base").Region;

/// IEEE 1364 §19.2 `default_nettype_value`, a closed list. `supply0` and
/// `supply1` are net types but not ones §19.2 lets an implicit net have.
/// `.none` withdraws implicit nets, so an undeclared identifier used as a net
/// is an error instead of a new wire.
pub const NetType = enum {
    wire,
    tri,
    tri0,
    tri1,
    wand,
    triand,
    wor,
    trior,
    trireg,
    uwire,
    none,

    /// IEEE 1364 §19.2: "If no `default_nettype directive is present or if the
    /// `resetall directive is used, implicit nets are of type wire."
    pub const default: NetType = .wire;
};

/// One IEEE 1364 §19.2 `default_nettype (or the `resetall that restores
/// `.wire`).
pub const NetTypeRegion = Region(NetType);

/// IEEE 1364 §19.1 `` `celldefine ``/`` `endcelldefine ``: whether the design
/// elements at this point are cell modules. The tag is metadata only; it does
/// not change what a module means.
pub const CellRegion = Region(bool);

/// IEEE 1364 §19.9 `` `unconnected_drive pull1 | pull0 `` and
/// `` `nounconnected_drive ``: how an unconnected input port of a module
/// declared in this region is driven.
pub const Drive = enum {
    /// `` `nounconnected_drive ``, and the state before either directive: the
    /// port is left floating.
    float,
    pull0,
    pull1,

    pub const default: Drive = .float;
};

/// One IEEE 1364 §19.9 drive directive (or the `resetall that restores
/// `.float`).
pub const DriveRegion = Region(Drive);

/// Directive name, without its backtick, to kind.
pub const directive_map = std.StaticStringMap(Directive).initComptime(.{
    .{ "define", .define },
    .{ "undef", .undef },
    .{ "ifdef", .ifdef },
    .{ "ifndef", .ifndef },
    .{ "elsif", .elsif },
    .{ "else", .@"else" },
    .{ "endif", .endif },
    .{ "include", .include },
    .{ "resetall", .resetall },

    // §10.6: which annex B words are reserved, and whether the directive sits
    // "outside of a design element", are parse-time questions. Emitted verbatim
    // so the lexer can tag them (`dir_begin_keywords`) and the parser can act.
    .{ "begin_keywords", .keywords },
    .{ "end_keywords", .keywords },

    // §10.2 and IEEE 1364 §19.7: both carry state past their own line, so both
    // are parsed here and published (`Directives`, `Pp.line_*`).
    .{ "default_discipline", .default_discipline },
    .{ "line", .line },
    .{ "default_transition", .default_transition }, // §10.3, read by §4.5.8

    .{ "timescale", .timescale }, // IEEE 1364 §19.8, read back by §9.15

    // The three IEEE 1364 directives that, like §10.2's, carry state past their
    // own line: §19.2 decides whether an undeclared name may become a net at
    // all, §19.1 tags the modules that follow, §19.9 drives their unconnected
    // inputs. All three are published as `Region` event lists.
    .{ "default_nettype", .default_nettype },
    .{ "celldefine", .celldefine },
    .{ "endcelldefine", .endcelldefine },
    .{ "unconnected_drive", .unconnected_drive },
    .{ "nounconnected_drive", .nounconnected_drive },

    // §10.1 lists `pragma and IEEE 1364 §19.10 leaves its content to the tool.
    // VerA defines no pragma, and §19.10 says an unrecognized one "shall have
    // no effect".
    .{ "pragma", .pragma },
});

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

/// Built-in annex D files, resolvable by `include even with no include_dirs.
/// All three are self-guarded, so an explicit `include after the prelude
/// expands to nothing. Only D.1 and D.2 are preloaded (see `process`); D.3
/// driver_access.vams must be included. `discipline.h` and `constants.h`
/// are the OVI Verilog-A 1.0 names of D.1 and D.2, which CMC models of that
/// era include (specification/Vague_Decisions.md VD-093).
pub const builtin_includes = std.StaticStringMap([]const u8).initComptime(.{
    .{ "constants.vams", pp_annex_d.constants_vams },
    .{ "disciplines.vams", pp_annex_d.disciplines_vams },
    .{ "constants.h", pp_annex_d.constants_vams },
    .{ "discipline.h", pp_annex_d.disciplines_vams },
    .{ "driver_access.vams", pp_annex_e.driver_access_vams },
});

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
    var pp: Pp = .{ .arena = arena, .scratch = scratch_state.allocator(), .opts = opts };

    // First, so the compilation unit is `.root`. The prelude files register
    // after it, even though they are processed before it.
    const root = try opts.bag.addFile(opts.file_name, source);

    for (predefined_macros) |name| {
        try pp.putMacro(name, .{ .body = "1", .predefined = true });
    }

    var netlist_modules: u32 = 0;
    var netlist_unsupported: []const []const u8 = &.{};
    var hdl: []const []const u8 = &.{};
    if (opts.std_defs) {
        // Replayed from the process-lifetime snapshot (`Prelude`), which
        // pp/test.zig checks against a fresh `runStdDefs`.
        try pp.replayStdDefs();
        // Annex E.2 after Table E.1: a `.MODEL` wrapper instantiates the
        // primitive its type names, so the primitive has to be declared first.
        const cards = try spice_cards.synthesize(arena, opts.spice_netlist, opts.spice_path);
        if (cards.refused.len != 0) {
            // E.1.2: a card inside a definition outside VerA's claimed SPICE
            // subset is refused, not skipped (see `spice_cards`).
            const ids = try pp.scratch.alloc(?diag.FileId, cards.files.len);
            @memset(ids, null);
            for (cards.refused) |r| {
                const id = ids[r.file] orelse try opts.bag.addFile(cards.files[r.file].name, cards.files[r.file].text);
                ids[r.file] = id;
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
            try pp.runFile(cards.text, "spice_netlist.vams", null);
            netlist_modules = cards.modules;
        }
        netlist_unsupported = cards.unsupported;
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
        try pp.runFile(f.text, f.name, null);
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
        try pp.runFile(text, path, null);
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

// The annex D/E prelude, preprocessed once per process (pp/prelude.zig).
const pp_prelude = @import("pp/prelude.zig");
pub const preludeTokens = pp_prelude.preludeTokens;
pub const preludeAst = pp_prelude.preludeAst;
/// The prelude's snapshot itself, for a test that compares a fresh run with it.
pub const preludeSnapshot = pp_prelude.preludeSnapshot;
/// Annex D.1's text, for a test that compares the prelude with its source.
pub const disciplines_vams = pp_annex_d.disciplines_vams;

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

/// One `define (§10.4), the value of `Pp.macros` under its name. Every slice
/// borrows the defining text (a file's stripped text, a macro body on
/// `Pp.scratch`, or the process-lifetime prelude), all of which outlive the
/// table.
pub const Macro = struct {
    /// The formal argument names, in order. Empty and `is_func == false`
    /// means an object-like macro.
    params: []const []const u8 = &.{},
    /// A formal list was written, even an empty one: `M()` takes zero
    /// arguments where object-like `M` takes none at all.
    is_func: bool = false,
    /// The macro text, one logical line, continuations joined (§10.4).
    body: []const u8,
    /// §10.5 predefined: survives `undef and `resetall.
    predefined: bool = false,
    /// Defined by the prelude's annex D.2 constants.vams: under
    /// `Options.require_std_includes` a use needs `include "constants.vams"`.
    annex_d2: bool = false,
    /// Defined by the prelude's annex D.1 disciplines.vams (its guard
    /// `DISCIPLINES_VAMS`): under `Options.require_std_includes` an `ifdef
    /// reads it as undefined until the source includes the file.
    annex_d1: bool = false,

    // Budget: two slices and three flags. A few hundred per compilation (psp103
    // holds 204: 45 prelude, 156 its own, 3 predefined), so packing the slices
    // into pool offsets would save under 4 KB of scratch.
    comptime {
        std.debug.assert(@sizeOf(Macro) <= 40);
    }
};

/// One `ifdef/`ifndef level.
const Cond = struct {
    /// Enclosing levels are all emitting.
    parent_active: bool,
    /// This level emits right now (already includes `parent_active`).
    active: bool,
    /// Some arm of this level was taken, so later `elsif/`else are dead.
    taken: bool,
    /// The level's `else has been read, so another `else or `elsif is E0106.
    seen_else: bool = false,
    /// The `ifdef that opened this level, for E0101's label.
    span: diag.Span = .{},
    file: diag.FileId = .root,

    // Budget: one row per open nesting level, a handful at most, so the four
    // flags stay plain bools rather than a packed set (which saves 4 B).
    comptime {
        std.debug.assert(@sizeOf(Cond) == 16);
    }
};

/// The `Directives` lists while they fill, in text-stream order, on
/// `Pp.scratch`. Field for field the names of `Directives`, which `process`
/// publishes by name.
pub const Events = struct {
    disciplines: std.ArrayList(DefaultDiscipline) = .empty,
    transitions: std.ArrayList(DefaultTransition) = .empty,
    timescales: std.ArrayList(TimescaleEvent) = .empty,
    nettypes: std.ArrayList(NetTypeRegion) = .empty,
    cells: std.ArrayList(CellRegion) = .empty,
    drives: std.ArrayList(DriveRegion) = .empty,
};

/// Preprocessor state for one compilation.
///
/// Two lifetimes. `arena` is the caller's and holds only what outlives
/// `process` through the bag: each file's stripped text and marks, an
/// `include's bytes and path, a suggestion's replacement text, and the
/// published copies `process` makes at the end. Every table below lives on
/// `scratch`, which `process` frees on return; a slice of a macro body (also
/// on scratch) that must outlive it is copied to `arena` where it is stored.
///
/// Offsets are `u32`, the unit `diag.Span` and `diag.Segment` store: an
/// output or a file past 4 GiB is a safety-checked `@intCast` failure, not a
/// diagnostic.
pub const Pp = struct {
    /// The caller's allocator; holds what outlives `process`.
    arena: Allocator,
    /// Freed when `process` returns; holds every table below.
    scratch: Allocator,
    opts: Options,

    // ---- outputs, copied to `arena` by `process` ------------------------
    out: std.ArrayList(u8) = .empty,
    /// Provenance of the output so far. Appended to only, so it stays sorted
    /// by `out_start` and `SourceMap.resolve` can binary-search it.
    segs: std.ArrayList(diag.Segment) = .empty,
    events: Events = .{},
    /// `Output.annex_d_included`, set by `directive.builtin`.
    annex_d_included: bool = false,
    /// An `include named constants.vams (constants.h) / disciplines.vams
    /// (discipline.h), set by `directive.include`; `Output.disciplines_included`.
    constants_included: bool = false,
    disciplines_included: bool = false,
    /// Running text VerA ships (the prelude, a synthesized netlist), which
    /// reads annex D.2 whatever the source includes.
    in_std_defs: bool = false,

    // ---- scan state ------------------------------------------------------
    macros: std.StringHashMapUnmanaged(Macro) = .empty,
    conds: std.ArrayList(Cond) = .empty,
    /// Macro-expansion cycle guard (§10.4): names currently being expanded,
    /// outermost first, and the same names as a set, so a chain of n distinct
    /// macros costs O(n), not O(n^2). A name is pushed only inside a live
    /// `expand` call. A cycle is E0118; any finite chain is legal.
    expanding: std.ArrayList([]const u8) = .empty,
    expanding_set: std.StringHashMapUnmanaged(void) = .empty,
    /// `include stack, innermost last: each open file and the macro state it
    /// was opened in. E0125 refuses an `include that repeats an entry, the
    /// one thing that makes the nesting never end (`directive.handleInclude`).
    includes: std.ArrayList(Open) = .empty,
    /// Order-free hash of the macro table (`macroHash` of every entry,
    /// XORed), kept by `putMacro` and `removeMacro`.
    macro_hash: u64 = 0,
    /// Open `nested` levels, and their count when the current stack
    /// segment began.
    seg: deep_stack.Segments = .{},
    /// IEEE 1364 §19.7 `line remap for §10.7 `__LINE__`; `line_to` is null when
    /// the current file is numbered naturally. `line_from` is the physical
    /// 1-based line after the directive and `line_to` the number §19.7 gives
    /// it, so a later line L reports `to + (L - from)`. Per file: `runFile`
    /// saves and restores both, as §10.7 requires at the end of an `include.
    line_from: u32 = 0,
    line_to: ?u32 = null,
    /// The `line directive's file name, which §10.7 lets replace `__FILE__`.
    /// Null means the current file's real name.
    file_override: ?[]const u8 = null,
    /// The file the current offsets belong to.
    cur_file_id: diag.FileId = .root,
    /// The outermost invocation's offset while a macro body is rescanned.
    /// Offsets inside a body index no file, so diagnostics there report here.
    expand_site: ?u32 = null,
    /// `out` is an actual's own buffer (`expandArg`), not the output, so no
    /// segment may be recorded: the text is mapped when the expansion that
    /// substitutes it is.
    in_actual: bool = false,
    /// Index in `segs` of the outermost expansion's `.macro` segment, valid
    /// while that expansion set `expand_site` outside an actual. `runFile`
    /// repeats it after an `include the expansion reached.
    expansion_seg: u32 = 0,

    /// One open `include: its path with `.` and `..` resolved (the cycle
    /// key), the path it was opened by (`joinChain`), and the macro state and
    /// conditional depth at the `include. The preprocessor's control flow
    /// (which arms are live, which files open) reads only those, so two opens
    /// on one stack that agree on all three repeat forever.
    pub const Open = struct { key: []const u8, path: []const u8, macro_hash: u64, conds: usize };

    /// Defines (or redefines) `name`, keeping `macro_hash`.
    pub fn putMacro(pp: *Pp, name: []const u8, m: Macro) Allocator.Error!void {
        const gop = try pp.macros.getOrPut(pp.scratch, name);
        if (gop.found_existing) pp.macro_hash ^= macroHash(name, gop.value_ptr.*);
        gop.value_ptr.* = m;
        pp.macro_hash ^= macroHash(name, m);
    }

    /// Removes `name` if defined, keeping `macro_hash`.
    pub fn removeMacro(pp: *Pp, name: []const u8) void {
        const kv = pp.macros.fetchRemove(name) orelse return;
        pp.macro_hash ^= macroHash(kv.key, kv.value);
    }

    fn macroHash(name: []const u8, m: Macro) u64 {
        var h: std.hash.Wyhash = .init(0);
        h.update(name);
        h.update(&.{ 0, @intFromBool(m.is_func), @intFromBool(m.predefined) });
        for (m.params) |p| {
            h.update(p);
            h.update(&.{0});
        }
        h.update(&.{1});
        h.update(m.body);
        return h.final();
    }

    /// Calls `f(args)` as one more level of `include or macro-expansion
    /// nesting: on a fresh `deep_stack` segment when this one is full. A
    /// segment that cannot be reserved is E0119 at `span`.
    pub fn nested(pp: *Pp, span: diag.Span, comptime f: anytype, args: anytype) Error!void {
        if (!pp.seg.due(caller_levels, segment_levels)) {
            pp.seg.frames += 1;
            defer pp.seg.frames -= 1;
            return @call(.auto, f, args);
        }
        return pp.seg.segment(segment_levels, f, args) catch |e| switch (e) {
            error.DeepStackUnavailable => pp.fail(span, .E0119, "{d} levels deep", .{pp.seg.frames}),
            else => |other| other,
        };
    }

    /// E0150 when the text built so far (`out`, or an actual's own buffer
    /// while one is expanded) has passed `Options.text_limit`.
    pub fn checkTextSize(pp: *Pp, span: diag.Span) Error!void {
        if (pp.out.items.len > pp.opts.text_limit)
            return pp.fail(span, .E0150, "past {d} bytes", .{pp.opts.text_limit});
    }

    /// Returns whether every enclosing conditional arm is active.
    pub fn emitting(pp: *const Pp) bool {
        const n = pp.conds.items.len;
        return n == 0 or pp.conds.items[n - 1].active;
    }

    /// Appends an event to `list` at the current output length, which is where
    /// the directive's own collapsed text ends and its region begins.
    pub fn mark(pp: *Pp, list: anytype, value: anytype) Allocator.Error!void {
        try list.append(pp.scratch, .{ .at = @intCast(pp.out.items.len), .value = value });
    }

    /// Emits only the newlines in `span`, so dropped text (a dead `ifdef arm,
    /// a collapsed directive) keeps the output's line count.
    pub fn putNewlines(pp: *Pp, span: []const u8) Error!void {
        // Count-then-fill: `std.mem.countScalar` is vectorized.
        try pp.out.appendNTimes(pp.scratch, '\n', std.mem.countScalar(u8, span, '\n'));
    }

    /// Returns a file-local span for `[start, end)` of the text being scanned,
    /// or the invocation site inside a macro body.
    pub fn spanAt(pp: *const Pp, start: usize, end: usize) diag.Span {
        if (pp.expand_site) |s| return .at(s);
        return .{ .start = @intCast(start), .end = @intCast(end) };
    }

    /// Returns the physical 1-based line of `at` in the current file, or of the
    /// invocation site inside a macro body. O(offset): counts newlines.
    pub fn physicalLine(pp: *const Pp, at: usize) u32 {
        const off = pp.expand_site orelse @as(u32, @intCast(at));
        const text = pp.opts.bag.fileText(pp.cur_file_id);
        return @intCast(1 + std.mem.countScalar(u8, text[0..@min(off, text.len)], '\n'));
    }

    /// Returns §10.7 `__LINE__` at `at`: the physical line, remapped by an
    /// IEEE 1364 §19.7 `line when one is in force.
    pub fn currentLine(pp: *const Pp, at: usize) u64 {
        const phys = pp.physicalLine(at);
        const to = pp.line_to orelse return phys;
        // Saturating: a `line whose operand is smaller than the offset it
        // corrects for cannot produce a line 0, let alone a negative one.
        return if (phys >= pp.line_from) @as(u64, to) + (phys - pp.line_from) else to;
    }

    /// Starts a diagnostic in the current file. Preprocessor spans are
    /// file-local, since no preprocessed text exists yet to map them through.
    pub fn failWith(pp: *Pp, span: diag.Span, code: diag.Code) diag.Builder {
        var b = pp.opts.bag.build(.preprocess, code, span);
        b.inFile(pp.cur_file_id);
        return b;
    }

    /// Emits `code` at `span` and returns `error.PreprocessFailed` to propagate.
    pub fn fail(pp: *Pp, span: diag.Span, code: diag.Code, comptime fmt: []const u8, args: anytype) Error {
        var b = pp.failWith(span, code);
        b.msg(fmt, args);
        try b.emit();
        return error.PreprocessFailed;
    }

    /// Records that the output continues from `at` in the current file. Called
    /// after every directive, because a directive that collapses to its
    /// newlines makes the output shorter than the file it came from.
    fn resync(pp: *Pp, at: usize) Error!void {
        // Inside a macro body there is no file offset to resync to; the
        // enclosing `.macro` segment already covers the whole expansion. An
        // actual's buffer is not the output at all.
        if (pp.expand_site != null or pp.in_actual) return;
        try pp.segs.append(pp.scratch, .{
            .out_start = @intCast(pp.out.items.len),
            .in_start = @intCast(at),
            .file = pp.cur_file_id,
            .kind = .verbatim,
        });
    }

    /// Preprocesses annex D.2, D.1 and Table E.1 into `pp`. Called once per
    /// process by `buildPrelude`, and by the snapshot equivalence test.
    pub fn runStdDefs(pp: *Pp) Error!void {
        // annex D.2 first: disciplines.vams reads `*_ABSTOL overrides, and the
        // constants are pure directives (they contribute only newlines here).
        pp.in_std_defs = true;
        defer pp.in_std_defs = false;
        try pp.runFile(pp_annex_d.constants_vams, "constants.vams", null);
        // Every macro so far but the §10.5 predefined ones is D.2's.
        var it = pp.macros.valueIterator();
        while (it.next()) |m| m.annex_d2 = !m.predefined;
        try pp.runFile(pp_annex_d.disciplines_vams, "disciplines.vams", null);
        // What D.1 added (its own guard) is D.1's, for the same rule.
        var d1 = pp.macros.valueIterator();
        while (d1.next()) |m| m.annex_d1 = !m.predefined and !m.annex_d2;
        // Annex E after annex D.1: the primitives' ports are `electrical`, which
        // disciplines.vams declares, and the source rows read `M_TWO_PI, which
        // constants.vams defines. Before the user's source, so nothing the user
        // `defines can reach into a shipped standard file.
        try pp.runFile(pp_annex_e.spice_primitives, "spice_primitives.vams", null);
    }

    /// Copies `runStdDefs`' result out of the process-lifetime snapshot. Must
    /// leave `pp` in exactly the state `runStdDefs` would.
    fn replayStdDefs(pp: *Pp) Error!void {
        const p = try pp_prelude.preludeSnapshot();
        for (p.files, 1..) |f, want_id| {
            const id = try pp.opts.bag.addFile(f.name, f.raw);
            // `Prelude.segs` names files by index, so the three must land at
            // 1, 2, 3: only the compilation unit (`.root`) is registered yet.
            std.debug.assert(@backingInt(id) == want_id);
            // Same state `runFile` leaves: spans index the stripped text and the
            // renderer maps back to the raw text through the marks.
            pp.opts.bag.setStrippedText(id, f.stripped, f.marks);
        }
        try pp.out.appendSlice(pp.scratch, p.text);
        try pp.segs.appendSlice(pp.scratch, p.segs);
        for (p.macros) |d| try pp.putMacro(d.name, d.macro);
    }

    /// Registers `raw`, strips its comments and scans it. Saves and restores
    /// the file context, so an error inside an `include names the right file.
    /// `existing` is the id of an already-registered file (the compilation
    /// unit), or null to register a new one. Fails as `process` does.
    pub fn runFile(pp: *Pp, raw: []const u8, file: []const u8, existing: ?diag.FileId) Error!void {
        const saved_id = pp.cur_file_id;
        defer pp.cur_file_id = saved_id;

        // An `include that a macro expansion reached (IEEE 1364 §19.3.1 puts
        // the expansion in the text stream) opens a real file whose offsets
        // are its own: until it ends, spans and §10.7 `__LINE__` stop
        // reporting the invocation site.
        const saved_site = pp.expand_site;
        const saved_seg = pp.expansion_seg;
        pp.expand_site = null;
        defer {
            pp.expand_site = saved_site;
            pp.expansion_seg = saved_seg;
        }

        // §10.7: at the end of an included file "the expansions of `__FILE__
        // and `__LINE__ revert to the values they had before the `include".
        // `__LINE__` derives from a physical offset, so restoring the remap is
        // all that takes.
        const saved_from = pp.line_from;
        const saved_to = pp.line_to;
        const saved_override = pp.file_override;
        pp.line_from = 0;
        pp.line_to = null;
        pp.file_override = null;
        defer {
            pp.line_from = saved_from;
            pp.line_to = saved_to;
            pp.file_override = saved_override;
        }

        const id = existing orelse try pp.opts.bag.addFile(file, raw);
        pp.cur_file_id = id;

        // Registered raw first so a stripComments failure resolves, then
        // repointed: every later offset indexes the stripped text.
        const s = try pp_comments.stripComments(pp, raw);
        pp.opts.bag.setStrippedText(id, s.text, s.marks);
        const text = s.text;

        // In an actual's buffer the file's text is mapped with the expansion
        // that substitutes it (`resync`).
        if (!pp.in_actual) try pp.segs.append(pp.scratch, .{
            .out_start = @intCast(pp.out.items.len),
            .in_start = 0,
            .file = id,
            .kind = .verbatim,
        });
        try scan(pp, text);
        // Back inside the expansion that reached the `include: the rest of its
        // text maps to the invocation again.
        if (saved_site != null and !pp.in_actual) {
            var seg = pp.segs.items[saved_seg];
            seg.out_start = @intCast(pp.out.items.len);
            try pp.segs.append(pp.scratch, seg);
        }
    }

    /// Returns `stack` and `last` joined as `A -> B -> C`, on `scratch`: for a
    /// diagnostic's format arguments, which the bag copies.
    pub fn joinChain(pp: *Pp, stack: []const []const u8, last: []const u8) Error![]const u8 {
        const sep = " -> ";
        var n = last.len + stack.len * sep.len;
        for (stack) |s| n += s.len;
        var out: std.ArrayList(u8) = try .initCapacity(pp.scratch, n);
        for (stack) |s| {
            out.appendSliceAssumeCapacity(s);
            out.appendSliceAssumeCapacity(sep);
        }
        out.appendSliceAssumeCapacity(last);
        std.debug.assert(out.items.len == n);
        return out.items;
    }
};

// §2.4 comment stripping (pp/comments.zig).
const pp_comments = @import("pp/comments.zig");
/// §2.4 comment stripping on its own, for the differential tests.
pub const stripComments = pp_comments.stripComments;

// ---------------------------------------------------------------------------
// Main scan
// ---------------------------------------------------------------------------

/// The three bytes `scan` branches on: a §2.7 string, a §2.8.1 escaped
/// identifier, and a §10 directive or macro use. Everything else is ordinary.
pub const scan_stops = "\"\\`";

/// Returns the first index at or after `from` whose byte is in `stops`, else
/// `text.len`. O(result - from). Asserts that `from` is at most `text.len`.
pub fn findStop(text: []const u8, from: usize, comptime stops: []const u8) usize {
    std.debug.assert(from <= text.len);
    // `std.mem.findAnyPos` is a scalar loop per (byte, needle); only
    // single-needle searches are vectorized in std. So: splat each stop and OR
    // the compare masks. Most scanned bytes sit in runs of 32 or more, so this
    // pays even though the median run is shorter. The scalar loop below is the
    // tail, the no-vector fallback, and the reference pp/test.zig checks.
    var i = from;
    if (std.simd.suggestVectorLength(u8)) |lanes| {
        const V = @Vector(lanes, u8);
        const Mask = @Int(.unsigned, lanes);
        while (i + lanes <= text.len) : (i += lanes) {
            const block: V = text[i..][0..lanes].*;
            var hit: Mask = 0;
            inline for (stops) |stop| {
                const splat: V = @splat(stop);
                hit |= @as(Mask, @bitCast(block == splat));
            }
            if (hit != 0) return i + @ctz(hit);
        }
    }
    while (i < text.len) : (i += 1) {
        inline for (stops) |stop| {
            if (text[i] == stop) return i;
        }
    }
    return i;
}

/// Copies comment-stripped `text` to `pp.out`, handling directives (§10) and
/// macro uses (§10.4). An inactive conditional arm emits only its newlines.
pub fn scan(pp: *Pp, text: []const u8) Error!void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];

        // §2.7 strings are opaque to macro expansion and to directives.
        if (c == '"') {
            const start = i;
            i = stringStop(text, i);
            const closed = i < text.len and text[i] == '"';
            if (closed) i += 1;
            if (pp.emitting()) {
                try pp.out.appendSlice(pp.scratch, text[start..i]);
            } else {
                // IEEE 1364 §19.4: an ignored group "shall still follow the
                // Verilog HDL lexical conventions"; an emitted one is the
                // lexer's to check.
                // ponytail: of those conventions, only §3.6's one-line string
                // is checked here.
                if (!closed) return pp.fail(pp.spanAt(start, i), .E0138, "", .{});
                try pp.putNewlines(text[start..i]);
            }
            continue;
        }

        // §2.8.1 escaped identifiers are opaque too (they may contain '`').
        if (c == '\\') {
            const start = i;
            i = escapedEnd(text, i + 1);
            if (pp.emitting()) try pp.out.appendSlice(pp.scratch, text[start..i]);
            continue;
        }

        if (c == '`') {
            const at = i;
            i = try pp_directive.directive(pp, text, i);
            std.debug.assert(i > at); // every directive and macro use consumes its '`'
            try pp.resync(i);
            continue;
        }

        // Ordinary text up to the next byte the branches above care about.
        // '\n' is not a stop: `putNewlines` counts it in a dead arm. '/' is
        // not either, since no comment survives `stripComments`.
        const end = findStop(text, i, scan_stops);
        if (pp.emitting()) try pp.out.appendSlice(pp.scratch, text[i..end]) else try pp.putNewlines(text[i..end]);
        // `text[i]` is none of the three, so `end > i`: the loop always moves.
        i = end;
    }
}

// §10.4 `define, `undef and macro expansion (pp/macro.zig).
const pp_macro = @import("pp/macro.zig");

// Directive dispatch, the IEEE 1364 §19.4 conditionals, `include (IEEE 1364
// §19.5), §10.2/§10.3 defaults and the IEEE 1364 §19 directives with
// operands (pp/directive.zig).
const pp_directive = @import("pp/directive.zig");

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

/// Returns the index of the closing quote, an unescaped newline, or EOF.
/// A `\` escapes the byte after it, a newline included. Asserts that
/// `text[start]` is the opening quote.
pub fn stringStop(text: []const u8, start: usize) usize {
    std.debug.assert(text[start] == '"');
    // ponytail: the lexer and `substitute` have their own string scans. The
    // lexer rejects escaped newlines and `substitute` crosses bare ones; share
    // one scan only if those rules converge.
    var i = start + 1;
    while (true) {
        i = findStop(text, i, "\"\n\\");
        if (i == text.len or text[i] != '\\') return i;
        i = @min(i + 2, text.len);
    }
}

/// Cursor over the tail of a directive line.
pub const Rest = struct {
    s: []const u8,
    i: usize = 0,

    /// Returns the byte under the cursor, or null at the end of the line.
    pub fn peek(r: *const Rest) ?u8 {
        return if (r.i < r.s.len) r.s[r.i] else null;
    }
    /// Advances past white space as the lexer classes it (`isSpace`).
    pub fn skipSpace(r: *Rest) void {
        while (r.i < r.s.len and isSpace(r.s[r.i])) r.i += 1;
    }
    /// Returns the next §2.8.1 escaped identifier, skipping leading white
    /// space, or null without consuming anything but that space. Neither
    /// the backslash nor the terminating white space is part of the name, so
    /// the macro is keyed on the same bytes a `` `\name `` use produces.
    pub fn escapedIdent(r: *Rest) ?[]const u8 {
        r.skipSpace();
        if (r.i >= r.s.len or r.s[r.i] != '\\') return null;
        const start = r.i + 1;
        const k = escapedEnd(r.s, start);
        if (k == start) return null;
        r.i = k;
        return r.s[start..k];
    }
    /// Returns the next identifier (§2.8), skipping leading white space.
    pub fn ident(r: *Rest) ?[]const u8 {
        r.skipSpace();
        if (r.i >= r.s.len or !isIdentStart(r.s[r.i])) return null;
        const start = r.i;
        r.i = identEnd(r.s, start);
        return r.s[start..r.i];
    }
};

// The lexer's §2.8 byte classes, so a directive operand splits where a token
// would.
pub const isSpace = @import("lexer.zig").isSpace;
pub const isIdentChar = @import("lexer.zig").isIdentChar;
pub const identEnd = @import("lexer.zig").identEnd;
pub const escapedEnd = @import("lexer.zig").escapedEnd;

/// Reports whether `c` may start a §2.8 simple identifier. Admits `$`, which
/// §2.8 forbids first, because `Rest.ident` also reads system names; a caller
/// that must refuse it (`handleDefine`) checks before calling.
pub fn isIdentStart(c: u8) bool {
    // ponytail: stdlib ASCII classes; `_` and `$` are Verilog's extensions.
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
}

// Annex D standard definition files (pp/annex_d.zig).
const pp_annex_d = @import("pp/annex_d.zig");

// Annex E Table E.1 SPICE primitives as modules (pp/annex_e.zig).
const pp_annex_e = @import("pp/annex_e.zig");
pub const spice_primitives = pp_annex_e.spice_primitives;
pub const spice_module_count = pp_annex_e.spice_module_count;

test {
    _ = pp_prelude;
    _ = pp_comments;
    _ = pp_macro;
    _ = pp_directive;
    _ = pp_annex_d;
    _ = pp_annex_e;
}
