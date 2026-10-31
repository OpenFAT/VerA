//! The analysis spine: Verilog-A/AMS source text and `Settings` in, a
//! `Result` (proven MIR, lowering's tables, the AST) and the caller's copy of
//! the diagnostics out. The stages, in order: preprocess (§10), the annex C.4
//! check, lex and parse (both resumed after the cached annex D/E prelude),
//! the IEEE 1364 §8.1.1 UDP check, the overlay elaboration writes, then on a
//! `deep_stack` sized for the parse's nesting: the annex E SPICE case rule,
//! the §3.7/§6.5.3 wreal rules, lowering, `held.prune` (§3.2), if-conversion
//! (§4.2.12), the proof (§4.3.2), speculation (#81) and the §9.4/§9.5 W0850
//! warnings. The MIR verifier runs after each stage that writes the MIR
//! (Debug and ReleaseSafe). Codegen is not here: `Result.generate`.
//!
//! Cites: §3.2, §3.4, §3.7, §4.2.12, §4.3.2, §6.2, §6.5.3, §7.6, §9.4,
//! §9.5.1, §9.7.3, annex C.4, annex E.2, A.1.2; IEEE 1364-2005 §8.1.1.
//!
//! Contents:
//! - `pub const Error = Allocator.Error || error{ CompileFailed, NoModule, NothingToElaborate }`
//! - `pub fn analyze(gpa: Allocator, source: []const u8, settings: Settings, bag: ?*diag.Bag) Error!Result`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const BigArena = @import("base").BigArena;
const deep_stack = @import("base").deep_stack;
const diag = @import("diag");
const frontend = @import("frontend");
const preprocessor = frontend.preprocessor;
const prelude = frontend.prelude;
const lexer = frontend.lexer;
const Parser = frontend.Parser;
const Ast = frontend.Ast;
const elab = @import("elab");
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const Lower = @import("analog").Lower;
const prove = @import("prove");
const proof = prove.proof;
const ifconv = prove.ifconv;
const held = prove.held;
const verify = prove.verify;
const device = @import("device");
const Display = device.Display;
const Settings = @import("Settings.zig");
const Result = @import("Result.zig");

/// Every way `analyze` fails. After any of them the arena is freed and the
/// caller's bag, when one was given, holds every diagnostic of the run.
pub const Error = Allocator.Error || error{
    /// A stage reported an error, or a `--deny` made a warning one.
    CompileFailed,
    /// The source declares no `module` of its own (§6.2); the annex D/E
    /// prelude and a SPICE netlist's modules do not count.
    NoModule,
    /// `Settings.empty_unit_ok`: the source was checked and holds no module
    /// to elaborate (A.1.2 admits that source_text). The bag holds warnings.
    NothingToElaborate,
};

/// The source after the parse: what the stages on the deep stack read.
const Parsed = struct {
    file: *Ast.SourceFile,
    text: []const u8,
    starts: []const u32,
    directives: frontend.directive_events.Directives,
    nesting: u32,
};

/// Analyses `source` and returns the result, which the caller frees with
/// `Result.deinit(gpa)`. Prints nothing and runs no child process.
/// `bag`, when given, receives a gpa-owned copy of every diagnostic of the
/// run, errors and warnings, even when this fails: a clean result may still
/// carry warnings (W0650). The caller frees it with `bag.deinit(gpa)`.
/// Asserts that `bag` holds nothing on entry (fresh from `Bag.init`): it is
/// overwritten, not appended to. Asserts that `source` is at most
/// `preprocessor.max_text_bytes`, the bound `preprocessor.readText` enforces
/// at the file boundary.
pub fn analyze(gpa: Allocator, source: []const u8, settings: Settings, bag: ?*diag.Bag) Error!Result {
    if (bag) |b| assert(b.isEmpty());
    assert(source.len <= preprocessor.max_text_bytes);
    const arena_state = try gpa.create(BigArena);
    arena_state.* = .init(gpa);

    // In the arena, not on this stack: the result keeps it (`Result.diags`).
    const own = arena_state.allocator().create(diag.Bag) catch |err| {
        freeArena(gpa, arena_state);
        return err;
    };
    own.* = .init(arena_state.allocator());
    own.levels = settings.lint;

    const result = stages(gpa, arena_state, source, settings, own);
    // A `--deny`ed warning is an error, so a run that only tripped one still
    // fails. Read before the copy below.
    const denied = own.failed();

    // The messages, labels and file texts live in the arena, so the caller's
    // copy is detached before the arena can be freed. The arena bag stays
    // whole for `Result.diags`.
    if (bag) |out| {
        var copy = own.*;
        copy.detach(gpa) catch |err| {
            if (result) |r| {
                var dead = r;
                dead.deinit(gpa);
            } else |_| freeArena(gpa, arena_state);
            return err;
        };
        out.* = copy;
    }

    var ok = result catch |err| {
        freeArena(gpa, arena_state);
        return err;
    };
    if (denied) {
        ok.deinit(gpa);
        return error.CompileFailed;
    }
    assert(ok.verdict.ok());
    return ok;
}

// ---- private ----

/// Runs every stage through the proof. Never frees `arena_state`: on success
/// it goes to the `Result`, on failure `analyze` frees it once the bag is
/// copied out.
fn stages(gpa: Allocator, arena_state: *BigArena, source: []const u8, settings: Settings, bag: *diag.Bag) Error!Result {
    const parsed = try front(arena_state.allocator(), source, settings, bag);
    assert(parsed.starts.len != 0); // The lexer ends every stream with an EOF token.
    // Every stage from here walks the AST by recursion, so it runs on a stack
    // reserved for the nesting the parser measured.
    return deep_stack.run(parsed.nesting, back, .{ gpa, arena_state, parsed, settings, bag }) catch |err| switch (err) {
        error.DeepStackUnavailable => {
            try bag.add(.lower, .E0241, .{}, "{d} levels deep", .{parsed.nesting});
            return error.CompileFailed;
        },
        else => |e| return e,
    };
}

/// Preprocess, lex, parse, check, overlay: text to the AST every later stage
/// reads. A diagnosed stage stops here with `error.CompileFailed`.
fn front(arena: Allocator, source: []const u8, settings: Settings, bag: *diag.Bag) Error!Parsed {
    const pp = preprocessor.process(arena, source, .{
        .include_dirs = settings.include_dirs,
        .defines = settings.defines,
        .file_name = settings.file_name,
        .std_defs = settings.std_defs,
        // Annex E.2: Table E.1 is built in, with or without annex D.
        .spice_primitives = true,
        .require_std_includes = settings.require_std_includes,
        .spice_netlist = settings.spice_netlist,
        .spice_path = settings.spice_path,
        .bag = bag,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Already in the bag with its own file and span: the preprocessor
        // registers every file it opens.
        error.PreprocessFailed => return error.CompileFailed,
    };
    // Annex C.4: Verilog-A has no `default_discipline; each is reported where
    // it stands, and the parse below adds the constructs it refuses.
    if (settings.sim == .verilog_a) for (pp.directives.disciplines) |d| {
        try bag.add(.parse, .E0250, .{ .start = d.at, .end = d.at }, "`default_discipline under --sim=verilogA", .{});
    };

    // The annex D.2/D.1/E.1 prelude is a fixed byte prefix of the text when
    // `std_defs` is on, so its tokens and AST are made once per process and
    // copied in; both seeds come from one snapshot gated on `std_defs`.
    var tokens = try lexer.tokenize(arena, pp.text, try prelude.preludeTokens(settings.std_defs));
    const tags = tokens.items(.tag);
    const starts = tokens.items(.start);
    const seed = try prelude.preludeAst(settings.std_defs);
    var p = try Parser.Parser.initSeeded(arena, pp.text, tags, starts, bag, seed);
    p.setLanguage(settings.language);
    p.verilog_a = settings.sim == .verilog_a;
    // The Table E.1 primitives lead the text, the annex E.2 netlist modules
    // follow them before the source, so together they lead `file.modules`.
    // This is the one place that knows how many the netlist added.
    const builtins: u32 = frontend.annex_e.spice_module_count + pp.netlist_modules;
    const parse = try arena.create(Ast.SourceFile);
    parse.* = p.parseSourceFile() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // The parser recovers at top level, so a diagnosed parse still tells
        // whether a module of the source's own was found. A file of only
        // `connectmodule`s gets NoModule later, from elaboration (§7.6).
        error.ParseError => return if (p.file.modules.len <= builtins) error.NoModule else error.CompileFailed,
    };
    assert(parse.modules.len >= builtins);

    // IEEE 1364-2005 §8.1.1 on every UDP, as the digital route checks it:
    // one output, and it is the first port.
    for (parse.udps) |u| if (u.outputs != 1 or u.ports.len == 0 or u.output != u.ports[0]) {
        const at = starts[u.main_tok];
        try bag.add(.parse, .E1100, .{ .start = at, .end = at }, "§8.1.1: a UDP has exactly one output port, and it is the first port", .{});
    };
    if (bag.failed()) return error.CompileFailed;

    // Elaboration writes an overlay of the parse, never the parse itself,
    // and its ids keep their numbers through it.
    const seed_natures: u32 = if (seed) |sd| @intCast(sd.file.natures.len) else 0;
    const seed_disciplines: u32 = if (seed) |sd| @intCast(sd.file.disciplines.len) else 0;
    const file = try arena.create(Ast.SourceFile);
    file.* = @as(*const Ast.SourceFile, parse).overlay(.{
        .builtin_modules = builtins,
        .builtin_natures = seed_natures,
        .annex_d_included = pp.annex_d_included,
        // The prelude's D.1 disciplines lead `disciplines`; without the
        // include a source may not name them.
        .hidden_disciplines = if (settings.require_std_includes and !pp.disciplines_included) seed_disciplines else 0,
        .netlist_modules = pp.netlist_modules,
        .netlist_unsupported = pp.netlist_unsupported,
    });
    return .{ .file = file, .text = pp.text, .starts = starts, .directives = pp.directives, .nesting = p.deepest };
}

/// The stages after the parse, through the proof, on `stages`' deep stack.
fn back(gpa: Allocator, arena_state: *BigArena, parsed: Parsed, settings: Settings, bag: *diag.Bag) Error!Result {
    const arena = arena_state.allocator();
    try elab.spiceCase(arena, parsed.file);
    // §3.7/§6.5.3: the digital runner calls the same check, so both routes
    // refuse the same wirings.
    try frontend.wreal.check(parsed.file, parsed.starts, bag);
    if (bag.failed()) return error.CompileFailed;

    const mir = try arena.create(Mir);
    mir.* = .{};
    const lowered = try arena.create(Lowered);
    const out = Lower.lower(arena, mir, parsed.file, parsed.text, parsed.starts, bag, .{
        .directives = parsed.directives,
        .include_dirs = settings.include_dirs, // §9.21.1 a $table_model data file
        .param_overrides = settings.param_overrides, // §3.4 `--param`
        .displays_dropped = settings.display == .drop, // §3.2 retention
        .discipline_resolution = settings.discipline_resolution,
        .int_systfs = settings.int_systfs, // §12.32.1 vpiIntFunc
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoModule => {
            // Connect modules are placed by §7.6 insertion, never a root, so a
            // unit of them alone has no top either.
            if (settings.empty_unit_ok) return error.NothingToElaborate;
            try bag.add(.lower, .E1001, .{}, "", .{});
            return error.NoModule;
        },
        error.DiagnosticsReported => return error.CompileFailed,
    };
    lowered.* = out.lowered;
    try verify.check(mir, lowered, "lowering");

    // §3.2: drop the held slots no card can observe, before ifconv's selects
    // hide the merges it reads. `prove` decides and rewrites the MIR;
    // lowering, `Lowered`'s one writer, drops the rows.
    if (try held.prune(arena, mir, lowered)) |keep| Lower.dropHeld(lowered, keep);
    try verify.check(mir, lowered, "held.prune");

    // Pure diamonds to §4.2.12 selects before the proof, which then sees the
    // guard facts the CFG edge carried (`markSelectArms`).
    _ = try ifconv.run(arena, mir, .pure, null);
    try verify.check(mir, lowered, "ifconv");

    // The proof gates every target and raises W0650, which is why a lint runs it.
    const verdict = try proof.prove(gpa, mir, lowered, settings.proof, bag);
    errdefer verdict.deinit(gpa);
    assert(verdict.unit_modes.len == proof.unitCount(lowered));
    // §4.3.2: a domain violation is a compile error on every target.
    if (!verdict.ok()) return error.CompileFailed;

    // #81: in `.strict` code a speculated arm's NaN or inf is IEEE-defined,
    // so the arms the proof needed as CFG become selects too, their domain
    // rows guarded. What an `.optimized` unit reads keeps its branches.
    var roots: std.ArrayList(Mir.Value) = .empty;
    for (verdict.unit_modes, lowered.contributions.items) |m, c| if (m == .optimized)
        try roots.appendSlice(arena, &.{ c.resist_val, c.react_val });
    var keep = try ifconv.keepSlice(arena, mir, roots.items);
    _ = try ifconv.run(arena, mir, .speculate, &keep);
    try verify.check(mir, lowered, "ifconv.speculate");

    // §9.4/§9.5: whether a side effect is kept depends on what the caller
    // builds, so these warnings are raised here and not in lowering.
    try warnDroppedDisplays(bag, lowered, settings.display);

    return .{
        .arena = arena_state,
        .source = parsed.text,
        .file = parsed.file,
        .module = out.module,
        .unit_paths = out.unit_paths,
        .mir = mir,
        .lowered = lowered,
        .diags = bag,
        .verdict = verdict,
        .display = settings.display,
        .nesting = parsed.nesting,
    };
}

/// Reports a W0850 for every display or file task in `lowered.displays` that
/// a device built for `display` will not perform. `.emit` drops none.
fn warnDroppedDisplays(bag: *diag.Bag, lowered: *const Lowered, display: Display) Allocator.Error!void {
    if (display == .emit) return;
    const before = bag.warn_count + bag.err_count + bag.suppressed;
    for (lowered.displays.items) |d| {
        const c: Mir.Callee = .fromName(d.name);
        // §9.7.3: a device reports these through its status channel.
        if (c == .@"$fatal" or c == .@"$error") continue;
        // §9.4: a `.record` device's `say` records these.
        if (display == .record and device.sayRecords(c)) continue;
        const span = lowered.tokenSpan(d.tok);
        // §9.5: a file task is kept for sequencing, and its answer is §9.5.1's
        // zero descriptor rather than a dropped print.
        if (Mir.callee.isFileCall(c))
            try bag.add(.lower, .W0850, span, "`{s}` — a device has no host file table, so §9.5.1's zero descriptor is the answer", .{d.name})
        else if (display == .record)
            try bag.add(.lower, .W0850, span, "`{s}` — a device's `say` records the printing tasks, not this one", .{d.name})
        else
            try bag.add(.lower, .W0850, span, "`{s}`", .{d.name});
    }
    assert(bag.warn_count + bag.err_count + bag.suppressed >= before);
}

fn freeArena(gpa: Allocator, a: *BigArena) void {
    a.deinit();
    gpa.destroy(a);
}
