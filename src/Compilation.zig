//! The compiler's module index and pipeline driver: Verilog-A source text in,
//! MIR and a generated `device.zig` out (preprocess, lex, parse, lower, prove,
//! codegen), then the artifacts a `Request` asks for. Re-exports each stage
//! and owns `CompileResult`, the root every per-compilation allocation hangs
//! off. `build.zig`'s `module_specs` makes `lib/` a dependency of `src/`,
//! never the reverse.
//!
//! `compile` is the spine `vera` calls for a `.va`: read the SPICE netlist
//! and the `//!` directives, compile (twice when the testbench's shape cards
//! change a parameter), then one block per target: `--emit-verilog`, the
//! OSDI checks (§4.6.4.6, VD-102), `--expect-module`, codegen, `--check`,
//! `--emit-exe`, `--emit-so`/`--emit-osdi`, `--emit-zig`. It returns an
//! `Outcome` and prints nothing. The pipeline itself is `compileInArena`:
//! preprocess, lex, parse, the §3.7 wreal check, lower, `pruneHeld` (`prove`)
//! and `dropHeld` (lowering), if-conversion (each followed by the MIR
//! verifier under runtime safety), prove, then the §9.4 drop warnings.
//! Codegen runs later and lazily, from `CompileResult.generateOutput`.
//! This file's pub declarations are the `vera` module's API (`src/main.zig`,
//! `src/vpi`, `tests/*`), so their names and meanings are frozen.
//!
//! Clauses its code cites: §3.2, §3.4, §3.6.2, §3.7, §4.2.12, §4.3.2, §4.6.4.6,
//! §5.6, §6, §6.2, §6.5.3, §6.7, §7.4.4, §7.6, §9.4, §9.4.1, §9.5, §9.5.1,
//! §9.7.3, §9.15, §9.16, §9.21.1, §10, §10.1, §12.32.1, annex D.1, D.2, E.1
//! and E.2; IEEE 1364-2005 §19.1 and §19.6.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The VerA release (`contract.vera_version`), which every generated device
/// carries and `vera --version` prints.
pub const version = @import("kernels").vera_version;
/// The compilation arena (`CompileResult.arena`); `src/cli/digital.zig` also
/// keeps a `.v` design's tables in one.
pub const BigArena = @import("base").BigArena;
/// §10 preprocessing (`Preprocessor.process`), for callers that need the
/// text without a compilation.
pub const Preprocessor = @import("frontend").Preprocessor;
/// IEEE 1364-2005 §19.6 library map files (`--libmap`).
pub const libmap = @import("frontend").libmap;
/// A `--param name=value` compile-time override (`Options.param_overrides`, LRM §3.4).
pub const ParamOverride = Lower.ParamOverride;
/// §7.4.4 resolution mode, `Options.discipline_resolution`.
pub const DisciplineResolution = @import("elab").Elaborate.DisciplineResolution;
/// The keyword set a `--std=` selects (`Options.language`).
pub const KeywordSet = token.KeywordSet;
/// The language family a `--sim=` selects (`Options.sim`).
pub const Sim = token.Sim;
/// Diagnostic codes, the `Bag` every stage reports into, and rendering.
pub const diag = @import("diag");
/// MIR to device.zig (`CompileResult.generateOutput`).
pub const codegen = @import("device").codegen;
/// The `zigbuild` module under its pre-Phase-7 name: device.zig to a
/// versioned `.so` (`buildArtifact`), and the testbench build `tb` re-exports.
pub const orchestrator = @import("zigbuild");
/// The fixture testbench: `//!` directives, runner text and its build.
pub const tb = @import("exe");
/// Hierarchy flattening, AST → one flat module (§6) (`elab`): the type of
/// `CompileResult.unit_paths` and the §6.7 `sep` the VPI reads, which
/// `ir.Elaborate` re-exported until Phase 11.
pub const Elaborate = @import("elab").Elaborate;

const Lower = @import("analog").Lower;
const ifconv = @import("prove").ifconv;
const proof = @import("prove").proof;
const verify = @import("prove").verify;
const beh_verilog = @import("verilog");
const osdi = @import("codegen/osdi.zig");
const token = @import("frontend").token;
const Lexer = @import("frontend").Lexer;
const Ast = @import("frontend").Ast;
const Parser = @import("frontend").Parser;
const deep_stack = @import("base").deep_stack;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const naming = @import("ir").names;
const cg_display = @import("device").cg_display;
const cg_filters = @import("device").cg_filters;

/// How far the pipeline runs. The Zig optimize mode and backend are
/// `orchestrator.Options.optimize` and `.backend`, set independently.
pub const Target = enum {
    /// Parse, lower and run the finiteness proof, then report diagnostics.
    /// No codegen and no `zig` child process.
    lint,
    /// Through codegen; `buildArtifact` can make a `.so`.
    build,
};

/// Failures of `compileSource` and `CompileResult.generateDevice`.
pub const Error = codegen.Error || error{
    /// One or more stages reported diagnostics. They are in the caller's
    /// `Options.diags` when one was supplied.
    CompileFailed,
    /// The source declared no `module` (LRM §6.2).
    NoModule,
    /// `.lint` produces no artifact by definition.
    NoArtifact,
};

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

/// Settings for one `compileSourceOpts` call.
pub const Options = struct {
    /// The name diagnostics print for the top-level source.
    file_name: []const u8 = "<source>",
    /// Searched in order for `include, ahead of the built-in annex D files.
    include_dirs: []const []const u8 = &.{},
    /// §3.4 compile-time values for the top module's parameters (`--param`).
    /// A shape parameter (`Lower.ParamInfo.shape`) is compiled to this value
    /// and its card may not move it; any other stays a run-time card value
    /// whose default this replaces.
    param_overrides: []const Lower.ParamOverride = &.{},
    /// §7.4.4 basic or detail discipline resolution
    /// (`--discipline-resolution=`); see `Elaborate.DisciplineResolution`.
    discipline_resolution: Elaborate.DisciplineResolution = .basic,
    /// Prepend annex D.2 constants.vams + annex D.1 disciplines.vams (§3.6.2).
    std_defs: bool = true,
    /// The source must `include` the annex D files it uses
    /// (`Preprocessor.Options.require_std_includes`): a D.2 macro without
    /// constants.vams is E0115, a D.1 discipline without disciplines.vams is
    /// E0371. The convention of the conformance suite and of `vera` (every
    /// mode: `--check`, `--lint`, `--run`, the emitters, `--lsp`), all of
    /// which set it, as does the suite's harness. Off by default, so a
    /// library caller compiling text it generated (a testbench, a unit test)
    /// keeps the implicit prelude.
    require_std_includes: bool = false,
    /// The source language, `vera --std=`. See `Parser.setLanguage`.
    language: KeywordSet = token.default_keyword_set,
    /// `vera --sim=`: all of Verilog-AMS, or annex C's Verilog-A subset, in
    /// which a digital or mixed-signal construct is E0250. `.verilog` never
    /// reaches this spine: a `.v` design goes through `sim.digital`.
    sim: Sim = .verilog_ams,
    /// Receives every diagnostic of the run, errors and warnings, so a
    /// successful compilation may still fill it (W0650, the finiteness
    /// warning). Detached from the compilation arena before the call returns,
    /// so it stays valid after the `CompileResult` is freed; the caller must
    /// `deinit(gpa)` it. The bag must own nothing on entry (fresh from
    /// `Bag.init`, or after `deinit`): the call overwrites it without freeing
    /// what it held. A successful result keeps the pointer, and codegen
    /// reports into the bag (E0515), so it must outlive the result.
    diags: ?*diag.Bag = null,
    /// Per-code lint levels (`--allow=W0650`, `--deny=W0651`). An error
    /// code cannot be allowed away; see `diag.Levels.set`. Borrowed, not
    /// copied: the bag in `diags` reads it until that bag is freed, so it
    /// must outlive the bag.
    lint: diag.Levels = .empty,
    /// Class-6 knobs (solver compliance bound, overflow model). See proof.zig.
    proof: proof.Options = .{},
    /// SPICE netlist text (annex E.2) whose `.MODEL` and `.SUBCKT` cards this
    /// compilation may resolve module names against (E.1.1's antecedent: "if a
    /// simulator ... is also able to read SPICE netlists"). One card per line,
    /// `+` continuations included; see `spice_cards.synthesize` for the subset
    /// that is read. Empty is the default and reads nothing.
    spice_netlist: []const u8 = "",
    /// The file `spice_netlist` came from, so its `.INCLUDE`, `.LIB` and
    /// `.HDL` cards find files beside it; "" resolves them against the
    /// working directory.
    spice_path: []const u8 = "",
    /// What to do with the model's display tasks (LRM §9.4). `.record` makes a
    /// device whose `say` records them for its host (`contract.SaySite`), and
    /// `.drop` one without it: either way no text and no syscall in the
    /// Newton loop, and a W0850 for each task dropped. `.emit` makes an
    /// executable whose prints are the output. See `codegen.Display`.
    display: codegen.Display = .drop,
    /// Emits `pub const jac_f32 = true`: the device tolerates a host scalar S
    /// whose derivative half is single precision. See `codegen.Options.jac_f32`.
    jac_f32: bool = false,
    /// Also emits `pub const jac_f32_host = true`: the host should take that
    /// permission on its CPU instantiation, not only where f32 is free. Implies
    /// `jac_f32`. See `codegen.Options.jac_f32_host`.
    jac_f32_host: bool = false,
    /// Also emits `vpiContribs`, the §5.6 contribution rows a Clause 12
    /// analog host reads, and `vpiShares`, each instance's share of a row
    /// several share. See `codegen.Options.vpi_contribs`.
    vpi_contribs: bool = false,
    /// §12.32.1 the user analog system functions registered with sysfunctype
    /// vpiIntFunc: a call to one returns an integer. A VPI host that ran its
    /// startup routines before building the device passes them; with none,
    /// every unresolved `$name` returns a real.
    int_systfs: []const []const u8 = &.{},
};

// ---------------------------------------------------------------------------
// CompileResult
// ---------------------------------------------------------------------------

/// The output of one compilation: source to MIR, and optionally to device.zig.
///
/// Owns every allocation of the run. Preprocessed text, tokens, AST, MIR and
/// lowering's tables live in `arena`, a `BigArena`: its large tables are the
/// gpa's own blocks, grown in place and freed with it. Only
/// `verdict.unit_modes` and `device.text` are gpa-owned (the device text can
/// reach hundreds of megabytes, and an arena cannot grow a buffer in place).
/// `deinit` frees all three. The value is freely movable.
pub const CompileResult = struct {
    /// The allocator the result was compiled with; `deinit` frees with it.
    gpa: Allocator,
    // Heap-allocated because the AST stores and `Ssa.SsaBuilder` hold an
    // `Allocator` whose `ptr` is this arena's address: moving it by
    // value would dangle them.
    arena: *BigArena,
    /// Preprocessed source (arena). Every AST/MIR string borrows from it.
    source: []const u8,
    /// The top module's MIR (arena), if-converted and proven.
    mir: *Mir,
    /// Lowering's output. The `Lower` that built it is gone: nothing after
    /// stage 4 can reach a symbol table, a scope or the SSA builder.
    lowered: *const Lowered,
    /// The parsed and elaborated AST (arena), which `lowered` does not hold:
    /// the VPI's object model (`vpi.open`) walks it, and no compiler stage
    /// after lowering reads it.
    file: *const Ast.SourceFile,
    /// The module lowered (§6.2), elaboration's flattened top
    /// (`Lower.Output.module`); null only if lowering never reached it.
    module: ?*const Ast.ModuleDecl = null,
    /// §9.15/§9.16 the module and instance path of each inlined analog
    /// block, by `Ast.AnalogBlock.unit` (`Lower.Output.unit_paths`).
    unit_paths: []const Elaborate.UnitPath = &.{},
    /// The compilation's diagnostics (arena): its file table and source map
    /// turn a `Lowered.tok_starts` offset into a file and line, the VPI's
    /// IEEE 1364-2005 §26.3.3 vpiLineNo. The messages go to the caller's
    /// `Options.diags` copy when one was asked for; this bag keeps its own.
    diags: *const diag.Bag,
    /// Its `unit_modes` slice is gpa-owned.
    verdict: proof.Verdict,
    /// What the caller asked for; `buildArtifact` refuses a `.lint` result.
    target: Target,
    /// Codegen output; empty until the first successful `generateOutput`,
    /// which the pipeline itself never calls. `text` is gpa-owned and freed
    /// by `deinit`; consumers borrow it.
    /// `names`, `unit_lo` and `unit_hi` are the per-unit file map the
    /// orchestrator writes (see `codegen.Output`).
    device: codegen.Output = .{ .text = "" },
    /// Whether codegen refused any construct, including metadata failures
    /// without an `@compileError` unit. Callers must not consume failed output.
    device_has_compile_error: bool = false,
    /// Settings that change what codegen generates.
    codegen_opts: codegen.Options = .{},
    /// The source's nesting depth (`Parser.deepest`): codegen's walks run on
    /// a `deep_stack` reserved for it.
    nesting: u32 = 0,

    /// Frees the arena and the two gpa-owned buffers; invalidates every slice
    /// borrowed from the result.
    pub fn deinit(self: *CompileResult) void {
        self.gpa.free(self.device.text);
        self.verdict.deinit(self.gpa);
        freeArena(self.gpa, self.arena);
        self.* = undefined;
    }

    /// Runs codegen and returns the device text. Idempotent: the text is
    /// cached on the result, so a second call costs nothing and returns the
    /// same slice. The slice is borrowed and lives until `deinit`. A failed
    /// call caches nothing, so the next call runs codegen again.
    pub fn generateDevice(self: *CompileResult) codegen.Error![]const u8 {
        return (try self.generateOutput()).text;
    }

    /// Runs codegen (once, as `generateDevice`) and returns the text with the
    /// per-unit file map the orchestrator needs. Every slice in the returned
    /// value is borrowed from the result and lives until `deinit`.
    pub fn generateOutput(self: *CompileResult) codegen.Error!codegen.Output {
        if (self.device.text.len == 0) {
            // A stack the system will not reserve is memory it will not give;
            // the compile already reserved one this deep, so this is rare.
            self.device = deep_stack.run(self.nesting, codegen.generate, .{
                self.gpa,
                self.arena.allocator(),
                self.mir,
                self.lowered,
                self.verdict,
                &self.device_has_compile_error,
                self.codegen_opts,
            }) catch |err| switch (err) {
                error.DeepStackUnavailable => return error.OutOfMemory,
                else => |e| return e,
            };
        }
        return self.device;
    }
};

// ---------------------------------------------------------------------------
// Compilation
// ---------------------------------------------------------------------------

/// Compiles `source` to MIR with default `Options`: preprocess, lex, parse,
/// lower and prove. For `.lint` this is the whole job. The caller must
/// `deinit` the result.
pub fn compileSource(gpa: Allocator, source: []const u8, target: Target) Error!CompileResult {
    return compileSourceOpts(gpa, source, target, .{});
}

/// `compileSource` with explicit settings. Caller owns the result and frees
/// it with `deinit`. When `opts.diags` is set it receives every diagnostic
/// even on failure, and the caller must `deinit(gpa)` it; on any failure
/// that bag is the only thing the call leaves allocated.
/// Fails with `error.CompileFailed` when a stage reported an error, or when a
/// `--deny` promoted a warning even if every stage succeeded;
/// `error.NoModule` when the source declares no module of its own (the
/// annex D/E prelude and a SPICE netlist's modules do not count).
pub fn compileSourceOpts(
    gpa: Allocator,
    source: []const u8,
    target: Target,
    opts: Options,
) Error!CompileResult {
    const arena_state = try gpa.create(BigArena);
    arena_state.* = .init(gpa);

    // In the arena, not on this stack: the result keeps it (`CompileResult.diags`).
    const bag = arena_state.allocator().create(diag.Bag) catch |err| {
        freeArena(gpa, arena_state);
        return err;
    };
    bag.* = diag.Bag.init(arena_state.allocator());
    bag.levels = opts.lint;

    const result = compileInArena(gpa, arena_state, source, target, opts, bag);

    // A `--deny`ed warning is an error, so a compilation that only tripped one
    // still fails. Read before detaching, which moves the bag out.
    const denied = bag.failed();

    // The bag's messages, labels and file texts live in the compilation arena,
    // so they are copied out before the arena can be freed. This is why no
    // stage frees the arena on error. A COPY is detached: the arena bag stays
    // whole for `CompileResult.diags`.
    if (opts.diags) |out| {
        var copy = bag.*;
        copy.detach(gpa) catch |err| {
            if (result) |r| {
                var ok = r;
                ok.deinit();
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
        ok.deinit();
        return error.CompileFailed;
    }
    return ok;
}

/// Runs every stage through the proof. Never frees `arena_state`: on success
/// it goes to the `CompileResult`, on failure the caller frees it once the bag
/// is detached.
fn compileInArena(
    gpa: Allocator,
    arena_state: *BigArena,
    source: []const u8,
    target: Target,
    opts: Options,
    bag: *diag.Bag,
) Error!CompileResult {
    const arena = arena_state.allocator();
    const pp = Preprocessor.process(arena, source, .{
        .include_dirs = opts.include_dirs,
        .file_name = opts.file_name,
        .std_defs = opts.std_defs,
        .require_std_includes = opts.require_std_includes,
        .spice_netlist = opts.spice_netlist,
        .spice_path = opts.spice_path,
        .bag = bag,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // The message is already in the bag with its own file and span: the
        // preprocessor registers every file it opens, so a failure inside an
        // `include names that header rather than the top-level unit.
        error.PreprocessFailed => return error.CompileFailed,
    };
    const text = pp.text;
    const netlist_modules = pp.netlist_modules;
    // Annex C.4: Verilog-A has no `default_discipline; each one is reported
    // where it stands, and the parse below adds the constructs it refuses.
    if (opts.sim == .verilog_a) for (pp.directives.disciplines) |d| {
        try bag.add(.parse, .E0250, .{ .start = d.at, .end = d.at }, "`default_discipline under --sim=verilogA", .{});
    };

    // The annex D.2/D.1/E.1 prelude is a fixed byte prefix of `text` whenever
    // `std_defs` is on, so its tokens are lexed once per process and copied in
    // (`Preprocessor.preludeTokens`). Re-lexing it dominated a small `.lint`.
    var tokens = try Lexer.Lexer.tokenizeSeeded(arena, text, try Preprocessor.preludeTokens(opts.std_defs));
    const tags = tokens.items(.tag);
    const starts = tokens.items(.start);

    // Likewise the prelude's AST is parsed once per process and parsing resumes
    // at the token after it; `Preprocessor.preludeAst` carries the soundness
    // argument. Both seeds come from one snapshot gated on the same
    // `std_defs`, so `tags` begins with the prelude's tokens here too.
    const seed = try Preprocessor.preludeAst(opts.std_defs);
    var p = try Parser.Parser.initSeeded(arena, text, tags, starts, bag, seed);
    p.setLanguage(opts.language);
    p.verilog_a = opts.sim == .verilog_a;
    const parse = try arena.create(Ast.SourceFile);
    // The Table E.1 primitives (annex E) are the first declarations in `text`,
    // and the annex E.2 netlist modules follow them before the user's source,
    // so together they lead `file.modules`. This is the one place that knows
    // whether the prelude was prepended; see `Ast.SourceFile.builtin_modules`.
    const builtins: u32 = if (opts.std_defs) Preprocessor.spice_module_count + netlist_modules else 0;
    parse.* = p.parseSourceFile() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseError => {
            // The parser recovers at top level, so a diagnosed parse still
            // tells whether a §6.2 `module` was found. When none was (the file
            // held only `library`, `primitive`, `paramset` or `connectrules`),
            // NoModule is what the caller acts on; the reason is in the bag.
            // Prelude modules do not count.
            //
            // `connectmodule` and `macromodule` are A.1.2 `module_keyword`
            // alternatives and land in `file.modules`. A file of only connect
            // modules gets NoModule later, from `elaborate.pickTop` (§7.6).
            if (p.file.modules.len <= builtins) return error.NoModule;
            return error.CompileFailed;
        },
    };
    if (bag.failed()) return error.CompileFailed;
    // Every later stage reads, and elaboration writes, an overlay of the
    // parse: the parse itself is never written, and its
    // ids keep their numbers through the overlay.
    const parsed: *const Ast.SourceFile = parse;
    const file = try arena.create(Ast.SourceFile);
    file.* = parsed.overlay(.{
        .builtin_modules = builtins,
        .builtin_natures = if (seed) |sd| @intCast(sd.file.natures.len) else 0,
        .annex_d_included = pp.annex_d_included,
        // The prelude's D.1 disciplines lead `disciplines`; without the
        // include a source may not name them (`resolve.checkNetDisciplines`).
        .hidden_disciplines = if (opts.require_std_includes and !pp.disciplines_included) if (seed) |sd| @intCast(sd.file.disciplines.len) else 0 else 0,
        .netlist_modules = netlist_modules,
        .netlist_unsupported = pp.netlist_unsupported,
    });
    // Every stage from here walks the AST by recursion, so it runs on a stack
    // reserved for the nesting the parser measured (`deep_stack`).
    return deep_stack.run(p.deepest, lowerAndProve, .{ gpa, arena_state, file, text, starts, pp.directives, p.deepest, target, opts, bag }) catch |err| switch (err) {
        error.DeepStackUnavailable => {
            try bag.add(.lower, .E0241, .{}, "{d} levels deep", .{p.deepest});
            return error.CompileFailed;
        },
        else => |e| return e,
    };
}

/// The stages after the parse, through the proof, on the `deep_stack` thread
/// `compileInArena` starts; `nesting` is the parser's `deepest`.
fn lowerAndProve(
    gpa: Allocator,
    arena_state: *BigArena,
    file: *Ast.SourceFile,
    text: []const u8,
    starts: []const u32,
    directives: Preprocessor.Directives,
    nesting: u32,
    target: Target,
    opts: Options,
    bag: *diag.Bag,
) Error!CompileResult {
    const arena = arena_state.allocator();
    try Elaborate.spiceCase(arena, file);
    // §3.7/§6.5.3 wreal structure rules. The digital runner calls the same
    // check, so both routes refuse the same wirings.
    try @import("frontend").wreal.check(file, starts, bag);
    if (bag.failed()) return error.CompileFailed;

    const mir = try arena.create(Mir);
    mir.* = .{};
    const lowered = try arena.create(Lowered);
    const out = Lower.lower(arena, mir, file, text, starts, bag, .{
        .directives = directives,
        .include_dirs = opts.include_dirs, // §9.21.1 a $table_model data file
        .param_overrides = opts.param_overrides, // §3.4 `--param`
        .displays_dropped = opts.display == .drop, // §3.2 retention, see `Exposed`
        .discipline_resolution = opts.discipline_resolution,
        .int_systfs = opts.int_systfs, // §12.32.1 vpiIntFunc
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoModule => {
            try bag.add(.lower, .E1001, .{}, "", .{});
            return error.NoModule;
        },
        error.DiagnosticsReported => return error.CompileFailed,
    };
    lowered.* = out.lowered;

    // The MIR's postcondition after each stage that writes it (Debug and
    // ReleaseSafe only). The proof and codegen take it `*const`.
    try verify.check(mir, lowered, "lowering");

    // §3.2: drop the held slots no card can observe. Runs before ifconv,
    // whose selects would hide the merges it reads. `prove` decides and
    // rewrites the MIR; lowering, `Lowered`'s one writer, drops the rows.
    if (try @import("prove").setup.pruneHeld(arena, mir, lowered)) |keep| Lower.dropHeld(lowered, keep);
    try verify.check(mir, lowered, "pruneHeld");

    // If-convert pure diamonds to §4.2.12 selects before the proof: a
    // select's guard facts come from markSelectArms, so the proof sees the
    // evidence the CFG edge carried and codegen can emit proven-total
    // conditionals as `S.sel`. Arena, because ifconv appends to MIR tables.
    _ = try ifconv.run(arena, mir);
    try verify.check(mir, lowered, "ifconv");

    // The proof gates every target and is the source of the W0650 finiteness
    // warning, which is why `.lint` runs it too.
    const verdict = try proof.proveOpts(gpa, mir, lowered, opts.proof, bag);
    errdefer verdict.deinit(gpa);
    // §4.3.2: a domain violation is a compile error on every target.
    if (!verdict.ok()) return error.CompileFailed;

    // #81: in `.strict` code a speculated arm's NaN or inf is IEEE-defined,
    // so the arms the proof needed as CFG (several blocks, a domain-restricted
    // op) become selects too, their domain rows guarded (`Mir.guard_of`).
    // After the proof, which read the CFG's evidence; the verdict holds only
    // unit modes, which this does not move. What an `.optimized` unit reads
    // keeps its branches.
    {
        var roots: std.ArrayList(Mir.Value) = .empty;
        for (verdict.unit_modes, lowered.contributions.items) |m, c| if (m == .optimized)
            try roots.appendSlice(arena, &.{ c.resist_val, c.react_val });
        var keep = try ifconv.keepSlice(arena, mir, roots.items);
        _ = try ifconv.runMode(arena, mir, .speculate, &keep);
        try verify.check(mir, lowered, "ifconv.speculate");
    }

    // §9.4/§9.5. Reported here, not in lowering, because whether a side effect
    // is kept depends on what the caller asked to build. The model is legal
    // either way, so these are warnings.
    try warnDroppedDisplays(bag, lowered, opts.display);

    return .{
        .gpa = gpa,
        .arena = arena_state,
        .source = text,
        .mir = mir,
        .lowered = lowered,
        .file = file,
        .module = out.module,
        .unit_paths = out.unit_paths,
        .diags = bag,
        .verdict = verdict,
        .target = target,
        .nesting = nesting,
        // `opts.diags`, not this bag: codegen runs after compileSourceOpts
        // detached the messages, so the caller's bag is the only one alive
        // when E0515 is raised.
        .codegen_opts = .{
            .display = opts.display,
            .jac_f32 = opts.jac_f32,
            .jac_f32_host = opts.jac_f32_host,
            .vpi_contribs = opts.vpi_contribs,
            .diags = opts.diags,
        },
    };
}

/// Reports a W0850 for every display or file task in `lowered.displays` that
/// the device `display` asks for will not perform. `.emit` drops none.
fn warnDroppedDisplays(bag: *diag.Bag, lowered: *const Lowered, display: codegen.Display) Allocator.Error!void {
    if (display == .emit) return;
    for (lowered.displays.items) |d| {
        const c: Mir.Callee = .fromName(d.name);
        // §9.7.3 a device reports these through its status channel
        // (`contract.StatusSite`): kept, not dropped.
        if (c == .@"$fatal" or c == .@"$error") continue;
        // §9.4 a `.record` device's `say` records these; codegen names one
        // it cannot (`cg_display.planSay`).
        if (display == .record and cg_display.sayRecords(c)) continue;
        const span = lowered.tokenSpan(d.tok);
        // A §9.5 file task is kept for sequencing, not text; its answer is
        // §9.5.1's zero descriptor rather than a dropped print.
        if (Mir.callee.isFileCall(c))
            try bag.add(.lower, .W0850, span, "`{s}` — a device has no host file table, so §9.5.1's zero descriptor is the answer", .{d.name})
        else if (display == .record)
            try bag.add(.lower, .W0850, span, "`{s}` — a device's `say` records the printing tasks, not this one", .{d.name})
        else
            try bag.add(.lower, .W0850, span, "`{s}`", .{d.name});
    }
}

// ---------------------------------------------------------------------------
// Artifact build
// ---------------------------------------------------------------------------

/// Generates the device and builds it cold into a shared library
/// (`orchestrator.compileRelease`), `lib<name>.<generation>.so` in
/// `o.work_dir`. The host owns loading it and all simulation state. Caller
/// owns the returned `orchestrator.Result` and frees it with `deinit(gpa)`.
/// Fails with `error.NoArtifact` on a `.lint` result, before anything runs.
pub fn buildArtifact(
    gpa: Allocator,
    io: std.Io,
    result: *CompileResult,
    o: orchestrator.Options,
    generation: u32,
    // Inferred error set: the orchestrator's failures are the open-ended OS
    // errors of a child process and its pipe.
) !orchestrator.Result {
    if (result.target == .lint) return error.NoArtifact;
    return orchestrator.compileRelease(gpa, io, o, try result.generateOutput(), generation);
}

// ---------------------------------------------------------------------------
// The spine
// ---------------------------------------------------------------------------

/// What one `compile` call builds: the compilation's settings, then one field
/// per target. With no target on, the call is `vera --lint`: the pipeline
/// through the proof, then the diagnostics.
pub const Request = struct {
    /// The compilation's settings; `file_name` names the source in every
    /// message. `compile` sets `diags` to its bag and the SPICE fields from
    /// `spice_path`, appends the testbench's shape cards after
    /// `param_overrides`, and makes `display` `.record` for a testbench whose
    /// `//! display record` asks for the device a host gets.
    options: Options = .{},
    /// `--spice`: an annex E.2 netlist, read whole beside the source.
    spice_path: ?[]const u8 = null,
    /// `--emit-verilog`: the behavioural module, and nothing else.
    verilog: ?Verilog = null,
    /// `--emit-osdi`, with `so` and the OSDI dyn as `build.dyn`: refuses what
    /// OSDI 0.4 cannot carry (E1099; W1098 warns) before `so` builds, and
    /// copies the library to `out_path`, else `<module>.osdi`.
    osdi: bool = false,
    /// `--expect-module`: refuses a top module of another name.
    expect_module: ?[]const u8 = null,
    /// `--check`: type-checks the device under the contract's checks.
    check: bool = false,
    /// `--emit-exe`/`--run`: builds the testbench `Outcome.exe` names.
    exe: ?Exe = null,
    /// `--emit-so`: builds the device into a library (`Outcome.path`).
    so: bool = false,
    /// `--emit-zig`: the device text, in `out_path` or on `Outcome.text`.
    zig: bool = false,
    /// `-o`: where `zig`, `verilog`, `exe` or `osdi` writes its artifact.
    out_path: ?[]const u8 = null,
    /// How `check`, `exe` and `so` run `zig`.
    build: Build = .{},

    /// `--emit-verilog`'s pins and supply.
    pub const Verilog = struct {
        /// `--digital-pins`: a file of port names when one exists, else the list.
        digital_pins: ?[]const u8 = null,
        power_pins: bool = false,
        /// Logic-high potential in volts.
        vdd: f64 = 1.8,
    };

    /// `--emit-exe`'s testbench settings.
    pub const Exe = struct {
        /// `--validate-contract`: the contract's checks on in the testbench.
        validate_contract: bool = false,
    };

    /// The `zig` children's settings.
    pub const Build = struct {
        /// The `contract` module root. `check`, `exe` and `so` need it.
        contract: ?[]const u8 = null,
        /// The `dyn` module root (`so`).
        dyn: ?[]const u8 = null,
        /// Scratch and artifact directory; `exe` and `osdi` default to
        /// `.zig-cache/vera-tb`, and `so` without `osdi` needs one.
        work_dir: ?[]const u8 = null,
        zig_exe: []const u8 = "zig",
        optimize: std.lang.Optimize = .fast,
        backend: orchestrator.Backend = .llvm,
        /// Keep DWARF in a release artifact.
        debug_info: bool = false,
        /// `orchestrator.Options.artifact_cache` for an `osdi` build.
        artifact_cache: ?[]const u8 = null,
    };
};

/// What `compile` did, for its caller to print: stdout gets `path`, then
/// `text`; stderr gets `err` and the bag in the order `report` says. The
/// slices live in the arena `compile` was given, or in `result`, which
/// `deinit` frees. Start it as `.{}`.
pub const Outcome = struct {
    /// Exit status: 0 built, 1 refused or failed, 2 a request this source
    /// cannot take.
    status: u8 = 0,
    /// The library `so` built (`osdi`: where it was copied).
    path: ?[]const u8 = null,
    /// The device (`zig`) or the Verilog module (`verilog`) when no
    /// `out_path` took it.
    text: []const u8 = "",
    /// The testbench `exe` built.
    exe: ?[]const u8 = null,
    /// The refusal; empty when there is none.
    err: []const u8 = "",
    /// Whether the bag's diagnostics are printed, and where.
    report: Report = .none,
    /// The compilation, once one succeeded; `text` may borrow from it.
    result: ?CompileResult = null,

    /// Where the bag's diagnostics go relative to `err` on stderr.
    pub const Report = union(enum) {
        /// `err` alone: the call stopped before the diagnostics were final.
        none,
        /// `err`, then the bag.
        after,
        /// The compilation failed: the bag, then this error's name unless
        /// the bag explains it (`CompileFailed`, `NoModule`).
        failed: Error,
    };

    /// Frees `result`; invalidates every slice borrowed from it.
    pub fn deinit(o: *Outcome) void {
        if (o.result) |*r| r.deinit();
        o.* = undefined;
    }

    fn done(o: *Outcome, status: u8) void {
        o.status = status;
    }
};

/// The compile spine: `source` through the pipeline, then one block per
/// target `req` asks for, in a fixed order (verilog, osdi, expect_module,
/// codegen, check, exe, so, zig). `bag` receives every diagnostic (fresh from
/// `Bag.init`; the caller `deinit`s it after `o`). `o` is the caller's,
/// filled even when this returns an error: `o.report` then says whether the
/// bag is final. `arena` holds every message and slice in `o`; it must
/// outlive `o`. Spawns `zig` for `check`, `exe` and `so`, writes `out_path`,
/// prints nothing.
pub fn compile(
    gpa: Allocator,
    io: std.Io,
    arena: Allocator,
    source: []const u8,
    req: Request,
    bag: *diag.Bag,
    o: *Outcome,
) !void {
    var ew: std.Io.Writer.Allocating = .init(arena);
    const err = &ew.writer;
    defer o.err = ew.written();
    const in_path = req.options.file_name;
    const b = req.build;

    // E.1.1's antecedent, made true from the command line: "if a simulator which
    // supports Verilog-AMS HDL is also able to read SPICE netlists ... certain
    // objects defined in that flavor of SPICE netlist can be referenced from
    // within a Verilog-AMS HDL structural description". Read whole, because
    // `spice_cards.synthesize` works on the text and a `+` continuation makes a
    // card longer than a line.
    const netlist: []const u8 = if (req.spice_path) |p|
        Preprocessor.readText(io, .cwd(), p, arena) catch |e| {
            try readFailed(err, p, e);
            return o.done(2);
        }
    else
        "";

    // --emit-exe's `//!` directives, read up front: a `//! param` card value
    // for a SHAPE parameter is a compile-time value (below). The directive
    // tables and the runner text are a web of small slices with one lifetime;
    // an arena is the whole memory management here.
    const directives: tb.Directives = if (req.exe == null) .{} else tb.parse(arena, source) catch |e| {
        try err.print("error: {s}: `//!` directive: {t}\n", .{ in_path, e });
        return o.done(2);
    };

    var opts = req.options;
    opts.spice_netlist = netlist;
    opts.spice_path = req.spice_path orelse "";
    opts.diags = bag;
    // `//! display record` asks a testbench for the device a host gets.
    if (directives.display_record) opts.display = .record;
    const target: Target = if (req.verilog == null and !req.check and req.exe == null and !req.so and !req.zig) .lint else .build;
    o.result = compileSourceOpts(gpa, source, target, opts) catch |e| {
        o.report = .{ .failed = e };
        return o.done(1);
    };
    const result = &o.result.?;

    // §3.4 the testbench's card values for shape parameters are compile-time
    // values (`tb.shapeOverrides`); a `--param` of the same name wins.
    const typed = req.options.param_overrides;
    var overrides: std.ArrayList(Lower.ParamOverride) = .empty;
    try overrides.appendSlice(arena, typed);
    for (try tb.shapeOverrides(arena, directives, result.lowered)) |card| {
        for (overrides.items) |ov| {
            if (std.mem.eql(u8, ov.name, card.name)) break;
        } else try overrides.append(arena, card);
    }
    if (overrides.items.len != typed.len) {
        bag.deinit(gpa); // the first pass's; the second says it all again
        bag.* = .init(gpa);
        opts.param_overrides = overrides.items;
        const again = compileSourceOpts(gpa, source, target, opts) catch |e| {
            o.report = .{ .failed = e };
            return o.done(1);
        };
        result.deinit();
        result.* = again;
    }

    // `--param` names a top-module, non-local scalar parameter, and gives a
    // numeric one a number. A misspelling would otherwise compile the default shape.
    for (typed) |ov| {
        const p = for (result.lowered.params.items) |p| {
            if (std.mem.eql(u8, p.name, ov.name) and !p.is_local) break p;
        } else {
            try err.print("error: --param {s}: `{s}` declares no parameter `{s}` that --param may set\n", .{ ov.name, result.mir.name, ov.name });
            return o.done(2);
        };
        if (p.ty != .string and (p.folded == null or p.folded.? != .str) and std.math.isNan(ov.value)) {
            try err.print("error: --param {s}={s}: `{s}` is not a number\n", .{ ov.name, ov.text, ov.text });
            return o.done(2);
        }
    }

    // Warnings on a successful compile go out after every exit below:
    // codegen reports too (E0515), and the bag is printed whole.
    o.report = .after;

    if (target == .lint) return;
    if (req.verilog) |v| return emitVerilog(io, arena, result, v, req.out_path, in_path, err, o);

    // What OSDI 0.4 cannot carry is named before a library is built.
    if (req.osdi) {
        try osdi.check(bag, result.lowered);
        if (bag.failed()) return o.done(1);
    }

    // The catalogue that consumes the generated file keys devices by the name
    // the BUILD chose, while the netlist dispatch and the generated type name
    // come from the MODULE name. A mismatch silently breaks lookup, so it is
    // caught here rather than three cache steps downstream.
    //
    // NOTE: a vendored file declaring several modules (VBIC ships 4T/5T in one
    // file) trips this — VerA lowers one of them, not necessarily the one
    // the file is named after. A module selector is the fix.
    if (req.expect_module) |want| {
        if (!std.mem.eql(u8, result.mir.name, want)) {
            try err.print(
                "error: {s}: Verilog-A module is `{s}` but `{s}` was expected — rename one of them\n",
                .{ in_path, result.mir.name, want },
            );
            return o.done(1);
        }
    }

    const device = result.generateDevice() catch |e| {
        try err.print("error: {s}: codegen failed: {t}\n", .{ in_path, e });
        return o.done(1);
    };

    // A fatal generation error is a refusal: writing the file anyway would
    // move the message to whoever compiles it, away from the .va.
    if (result.device_has_compile_error) {
        try err.print(
            "error: {s}: codegen refused a construct; generated output is not usable\n",
            .{in_path},
        );
        return o.done(1);
    }

    // --check: type-check the generated Zig here, where the .va that
    // produced it can still be named. --emit-so runs the same check only
    // after its build fails: the build reports the same errors, and a
    // separate pass before it is pure wall time.
    if (req.check) {
        if (try orchestrator.typeCheck(gpa, io, err, b.zig_exe, b.contract.?, device, in_path)) |code| return o.done(code);
    }

    // --emit-exe: the same device with real display tasks, driven by a
    // generated runner over the operating points its `//!` lines declare.
    if (req.exe) |x| {
        const wd = b.work_dir orelse ".zig-cache/vera-tb";
        var dm = directives;
        dm.mixed = tb.mixedPlan(result.lowered, result.mir);
        dm.op_states = try tb.opStates(arena, result.lowered);
        dm.mem_bytes = tb.memBytes(result.lowered);
        dm.validate_contract = x.validate_contract;
        try tb.warnGridEvents(bag, result.lowered, result.mir);
        // Runner diagnostics obey --deny/--forbid before an artifact is
        // built or its simulation starts, just like compiler diagnostics.
        if (bag.failed()) return o.done(1);
        const runner = tb.renderRunner(arena, std.fs.path.stem(in_path), dm) catch |e| switch (e) {
            error.TooManyPoints => {
                try err.print("error: {s}: `//!` directive: the sweeps expand to more than {d} points\n", .{ in_path, tb.max_points });
                return o.done(2);
            },
            else => |y| return y,
        };
        const built = tb.buildExe(gpa, io, device, runner, .{
            .work_dir = wd,
            .contract = b.contract.?,
            .name = result.mir.name,
            .out_path = req.out_path,
            .zig_exe = b.zig_exe,
            .mixed = dm.mixed != null,
            .optimize = b.optimize,
            .backend = b.backend,
            .debug_info = b.debug_info,
        }) catch |e| {
            try err.print("error: {s}: building the testbench failed: {t}\n", .{ in_path, e });
            return o.done(1);
        };
        defer built.deinit(gpa);
        switch (built) {
            .failed => |text| {
                try err.print(
                    "error: {s}: the generated testbench does not compile — this is an " ++
                        "engine bug, not a problem with the model:\n",
                    .{in_path},
                );
                try err.writeAll(text);
                return o.done(1);
            },
            .ok => |p| o.exe = try arena.dupe(u8, p),
        }
        return;
    }

    if (req.so) {
        const wd = b.work_dir orelse if (req.osdi) ".zig-cache/vera-tb" else {
            try err.writeAll("error: --emit-so needs --work-dir DIR\n");
            return o.done(2);
        };
        const dyn = b.dyn orelse {
            try err.writeAll("error: --emit-so needs --dyn PATH\n");
            return o.done(2);
        };
        const modules = [_]orchestrator.Module{
            .{ .name = "contract", .root = b.contract.? },
            .{ .name = "dyn", .root = dyn, .deps = &.{"contract"} },
        };
        var r = buildArtifact(gpa, io, result, .{
            .work_dir = wd,
            .name = try orchestrator.fileStem(arena, result.mir.name),
            .optimize = b.optimize,
            .backend = b.backend,
            .modules = &modules,
            .zig_exe = b.zig_exe,
            .debug_info = b.debug_info,
            // `osdi_dyn` keeps every per-iterate callback in `.eval`.
            .cold_self_hosted = req.osdi,
            .artifact_cache = if (req.osdi) b.artifact_cache else null,
        }, 1) catch |e| {
            try err.print("error: {s}: building the device failed: {t}\n", .{ in_path, e });
            return o.done(1);
        };
        defer r.deinit(gpa);
        switch (r) {
            .ok => |a| if (req.osdi) {
                const dest = req.out_path orelse try arena.print("{s}.osdi", .{result.mir.name});
                std.Io.Dir.cwd().copyFile(a.so_path, std.Io.Dir.cwd(), dest, io, .{}) catch |e| {
                    try err.print("error: cannot write `{s}`: {t}\n", .{ dest, e });
                    return o.done(1);
                };
                o.path = dest;
            } else {
                o.path = try arena.dupe(u8, a.so_path);
            },
            .failed => |bundle| {
                // An error typeCheck can see is the device's own (an engine
                // bug), reported against the .va as a check would have.
                if (try orchestrator.typeCheck(gpa, io, err, b.zig_exe, b.contract.?, device, in_path)) |code| return o.done(code);
                try err.print("error: {s}: the generated device did not compile:\n", .{in_path});
                try bundle.renderToWriter(.{}, err);
                return o.done(1);
            },
        }
    }

    if (req.zig) {
        if (req.out_path) |p| {
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = device }) catch |e| {
                try err.print("error: cannot write `{s}`: {t}\n", .{ p, e });
                return o.done(1);
            };
        } else o.text = device;
    }
}

/// `--emit-verilog`: the behavioural module to `out_path`, else
/// `o.text`. A model the abstraction cannot take is refused (status 1) with
/// nothing written.
fn emitVerilog(
    io: std.Io,
    arena: Allocator,
    result: *const CompileResult,
    v: Request.Verilog,
    out_path: ?[]const u8,
    in_path: []const u8,
    err: *std.Io.Writer,
    o: *Outcome,
) !void {
    // `--digital-pins` names a file of pins when one exists, else is the list.
    var digital: std.ArrayList([]const u8) = .empty;
    if (v.digital_pins) |spec| {
        // `readFailed`'s E1013 names `max_text_bytes`, so that is the limit.
        const text = Preprocessor.readText(io, .cwd(), spec, arena) catch |e| switch (e) {
            error.FileNotFound => spec,
            else => {
                try readFailed(err, spec, e);
                return o.done(2);
            },
        };
        var it = std.mem.tokenizeAny(u8, text, ", \t\r\n");
        while (it.next()) |n| try digital.append(arena, n);
    }
    var why: []const u8 = "";
    const text = beh_verilog.emit(arena, result.mir, result.lowered, .{
        .digital = digital.items,
        .power_pins = v.power_pins,
        .vdd = v.vdd,
        .source = std.fs.path.basename(in_path),
    }, &why) catch |e| switch (e) {
        error.Refused => {
            try err.print("error: {s}: --emit-verilog: {s}\n", .{ in_path, why });
            return o.done(1);
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (out_path) |p| {
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = text }) catch |e| {
            try err.print("error: cannot write `{s}`: {t}\n", .{ p, e });
            return o.done(1);
        };
    } else o.text = text;
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Writes the one-line error for a source `path` that could not be read:
/// E1013 for a file past `Preprocessor.max_text_bytes` (the u32 offsets the
/// lexer uses), else the error's name. The text is user-visible and frozen.
pub fn readFailed(w: *std.Io.Writer, path: []const u8, e: anyerror) std.Io.Writer.Error!void {
    if (e == error.StreamTooLong)
        try w.print("error[E1013]: `{s}` is larger than {d} bytes; see `vera --explain E1013`\n", .{ path, Preprocessor.max_text_bytes })
    else
        try w.print("error: cannot read `{s}`: {t}\n", .{ path, e });
}

fn freeArena(gpa: Allocator, a: *BigArena) void {
    a.deinit();
    gpa.destroy(a);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test readFailed {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // 2^32 - 1 is 4294967295 bytes.
    try readFailed(&w, "big.va", error.StreamTooLong);
    try readFailed(&w, "gone.va", error.FileNotFound);
    try std.testing.expectEqualStrings("error[E1013]: `big.va` is larger than 4294967295 bytes; see `vera --explain E1013`\n" ++
        "error: cannot read `gone.va`: FileNotFound\n", w.buffered());
}

const test_resistor =
    \\module res(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  parameter real r = 1000.0 from (0.0:inf);
    \\  analog I(p, n) <+ V(p, n) / r;
    \\endmodule
;

test "lint: source → MIR, arena freed clean" {
    var res = try compileSource(std.testing.allocator, test_resistor, .lint);
    defer res.deinit();

    try std.testing.expectEqualStrings("res", res.mir.name);
    try std.testing.expectEqual(@as(u16, 2), res.lowered.num_ports);
    try std.testing.expect(res.verdict.ok());
    try std.testing.expectEqual(proof.unitCount(res.lowered), res.verdict.unit_modes.len);
}

test compile {
    // The targets that spawn no `zig`: `--lint`, `--emit-zig` to stdout, a
    // misspelt `--param` (status 2, before the diagnostics are final) and a
    // failed compilation (the bag explains it, so no error name).
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Case = struct { src: []const u8, req: Request, status: u8, report: std.meta.Tag(Outcome.Report), text: bool, err: []const u8 };
    for ([_]Case{
        .{ .src = test_resistor, .req = .{}, .status = 0, .report = .after, .text = false, .err = "" },
        .{ .src = test_resistor, .req = .{ .zig = true }, .status = 0, .report = .after, .text = true, .err = "" },
        .{
            .src = test_resistor,
            .req = .{ .options = .{ .file_name = "res.va", .param_overrides = &.{.{ .name = "rr", .value = 1 }} } },
            .status = 2,
            .report = .none,
            .text = false,
            .err = "error: --param rr: `res` declares no parameter `rr` that --param may set\n",
        },
        .{ .src = "module bad(p); inout p; electrical p; analog I(p) <+ ;\nendmodule\n", .req = .{}, .status = 1, .report = .failed, .text = false, .err = "" },
        // Refused before any pipeline stage.
        .{ .src = test_resistor, .req = .{ .spice_path = "/nonexistent/x.sp" }, .status = 2, .report = .none, .text = false, .err = "error: cannot read `/nonexistent/x.sp`: FileNotFound\n" },
        // Refused after the compile, before codegen or a `zig` child.
        .{ .src = test_resistor, .req = .{ .zig = true, .expect_module = "cap" }, .status = 1, .report = .after, .text = false, .err = "error: <source>: Verilog-A module is `res` but `cap` was expected — rename one of them\n" },
        .{ .src = test_resistor, .req = .{ .so = true }, .status = 2, .report = .after, .text = false, .err = "error: --emit-so needs --work-dir DIR\n" },
        .{ .src = test_resistor, .req = .{ .so = true, .build = .{ .work_dir = "wd" } }, .status = 2, .report = .after, .text = false, .err = "error: --emit-so needs --dyn PATH\n" },
        .{ .src = test_resistor, .req = .{ .verilog = .{} }, .status = 0, .report = .after, .text = true, .err = "" },
    }) |c| {
        var bag: diag.Bag = .init(gpa);
        defer bag.deinit(gpa);
        var o: Outcome = .{};
        defer o.deinit();
        try compile(gpa, std.testing.io, arena, c.src, c.req, &bag, &o);
        try std.testing.expectEqual(c.status, o.status);
        try std.testing.expectEqual(c.report, std.meta.activeTag(o.report));
        try std.testing.expectEqual(c.text, o.text.len != 0);
        try std.testing.expectEqualStrings(c.err, o.err);
        try std.testing.expect(o.path == null and o.exe == null);
    }
}

test "IEEE 1364 §19.1 cell membership survives the preprocessor" {
    // The module's cell tag survives after the directives are gone from the
    // text. No fixture can check this: §19.1 tags a module and changes no
    // value a model can print.
    const gpa = std.testing.allocator;
    {
        var res = try compileSource(gpa, "`celldefine\n" ++ test_resistor ++ "\n`endcelldefine\n", .lint);
        defer res.deinit();
        try std.testing.expect(res.mir.is_cell);
    }
    {
        var res = try compileSource(gpa, test_resistor, .lint);
        defer res.deinit();
        try std.testing.expect(!res.mir.is_cell);
    }
    {
        // §10.1 scope: the region ends at the closing directive, so a module
        // below `endcelldefine is not a cell.
        var res = try compileSource(gpa, "`celldefine\n`endcelldefine\n" ++ test_resistor, .lint);
        defer res.deinit();
        try std.testing.expect(!res.mir.is_cell);
    }
}

test "--sim=verilogA: annex C.4's `default_discipline is E0250, and the rest compiles" {
    const gpa = std.testing.allocator;
    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    try std.testing.expectError(error.CompileFailed, compileSourceOpts(gpa, "`default_discipline logic\n" ++ test_resistor, .lint, .{ .sim = .verilog_a, .diags = &bag }));
    try std.testing.expectEqual(diag.Code.E0250, bag.at(0).code);
    var res = try compileSourceOpts(gpa, test_resistor, .lint, .{ .sim = .verilog_a });
    res.deinit();
}

test "diagnostics outlive the compilation arena" {
    const gpa = std.testing.allocator;
    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);

    try std.testing.expectError(error.CompileFailed, compileSourceOpts(
        gpa,
        "module bad(p); inout p; electrical p; analog I(p) <+ ;\nendmodule\n",
        .lint,
        .{ .diags = &bag },
    ));
    // The arena is gone by now; reading the messages must still be valid.
    try std.testing.expect(!bag.isEmpty());
    try std.testing.expect(bag.failed());
    for (0..bag.count()) |i| try std.testing.expect(diag.info(bag.at(i).code).title.len != 0);

    // So must rendering, which reads the file text the bag detached.
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try diag.render(&bag, &aw.writer, .{});
    try std.testing.expect(std.mem.find(u8, aw.writer.buffered(), "-->") != null);
}

fn compileBadWithDiags(gpa: Allocator) !void {
    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    const src = "module bad(p); inout p; electrical p; analog I(p) <+ ;\nendmodule\n";
    _ = compileSourceOpts(gpa, src, .lint, .{ .diags = &bag }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    return error.TestUnexpectedResult;
}

test "an allocation failure while detaching diagnostics leaks nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compileBadWithDiags, .{});
}

test "a clean compilation reports no diagnostics but still hands back the bag" {
    const gpa = std.testing.allocator;
    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);

    var res = try compileSourceOpts(
        gpa,
        "module r(p, n); inout p, n; electrical p, n;\n" ++
            "  parameter real rs = 1.0 from (0:inf);\n" ++
            "  analog I(p, n) <+ V(p, n) / rs;\n" ++
            "endmodule\n",
        .lint,
        .{ .diags = &bag },
    );
    defer res.deinit();
    try std.testing.expect(!bag.failed());
    // A fully-ranged resistor is provably finite, so not even W0650 fires.
    try std.testing.expect(bag.isEmpty());
    try std.testing.expectEqual(proof.FloatMode.optimized, res.verdict.unit_modes[0]);
}

test "lint levels: --deny promotes a warning into a hard failure" {
    const gpa = std.testing.allocator;
    const src =
        \\module amp(a, c); inout a, c; electrical a, c;
        \\  analog I(a, c) <+ exp(V(a, c));
        \\endmodule
        \\
    ;

    // Default: W0650 fires, but a warning does not fail a compilation.
    {
        var bag: diag.Bag = .init(gpa);
        defer bag.deinit(gpa);
        var res = try compileSourceOpts(gpa, src, .lint, .{ .diags = &bag });
        defer res.deinit();
        try std.testing.expect(!bag.failed());
        try std.testing.expectEqual(@as(u32, 1), bag.warn_count);
    }

    // --deny=W0650: same diagnostic, now an error, and the compile fails.
    {
        var levels: diag.Levels = .empty;
        defer levels.deinit(gpa);
        try levels.set(gpa, .W0650, .deny);

        var bag: diag.Bag = .init(gpa);
        defer bag.deinit(gpa);
        try std.testing.expectError(error.CompileFailed, compileSourceOpts(
            gpa,
            src,
            .lint,
            .{ .diags = &bag, .lint = levels },
        ));
        try std.testing.expect(bag.failed());
        try std.testing.expectEqual(@as(u32, 1), bag.err_count);
    }

    // --allow=W0650: not collected at all, and still a clean compile.
    {
        var levels: diag.Levels = .empty;
        defer levels.deinit(gpa);
        try levels.set(gpa, .W0650, .allow);

        var bag: diag.Bag = .init(gpa);
        defer bag.deinit(gpa);
        var res = try compileSourceOpts(gpa, src, .lint, .{ .diags = &bag, .lint = levels });
        defer res.deinit();
        try std.testing.expect(bag.isEmpty());
        // Silencing the lint does not change the generated code.
        try std.testing.expectEqual(proof.FloatMode.strict, res.verdict.unit_modes[0]);
    }
}

test "determinism: a no-op recompile reproduces identical device.zig" {
    const gpa = std.testing.allocator;
    var a = try compileSource(gpa, test_resistor, .build);
    defer a.deinit();
    var b = try compileSource(gpa, test_resistor, .build);
    defer b.deinit();
    try std.testing.expectEqualStrings(try a.generateDevice(), try b.generateDevice());
}

/// A module whose analog block holds `pre`, then `n` copies of `open`, `mid`,
/// `n` copies of `close`, and `post`.
fn deepSource(gpa: Allocator, n: usize, c: DeepCase) ![]u8 {
    var src: std.ArrayList(u8) = .empty;
    errdefer src.deinit(gpa);
    try src.appendSlice(gpa, "module deep(p, n); inout p, n; electrical p, n; real r; integer k; analog begin ");
    try src.appendSlice(gpa, c.pre);
    for (0..n) |_| try src.appendSlice(gpa, c.open);
    try src.appendSlice(gpa, c.mid);
    for (0..n) |_| try src.appendSlice(gpa, c.close);
    try src.appendSlice(gpa, c.post);
    try src.appendSlice(gpa, " I(p, n) <+ r * V(p, n); end endmodule");
    return src.toOwnedSlice(gpa);
}

/// `device = false`: lint only, because the "10,000-level ?: chain" test
/// below takes that shape through codegen at the same depth.
const DeepCase = struct { pre: []const u8 = "", open: []const u8, mid: []const u8, close: []const u8 = "", post: []const u8 = "", device: bool = true };

test "nesting has no bound: 10,000 levels lint and generate a device" {
    // Every stage after the parse recurses per AST level and runs on a
    // `deep_stack` sized from `Parser.deepest`; 10,000 levels is past the
    // 8 MiB stack the pipeline had (it overflowed near 3,000). 100,000 took
    // 70 s in Debug, half of `zig build test`'s critical path. The if
    // and ?: chains are the worst case of the per-branch walks: every level
    // pushes a prover guard fact on one congruence class (`V(p) > 1`), climbs
    // the SSA arms above it and the setup plan's dominators, each quadratic
    // in the depth until #29 (Debug, 2026-10-15: about 20 s and 0.6-2.2 GB a
    // lint here).
    const gpa = std.testing.allocator;
    for ([_]DeepCase{
        .{ .pre = "r = 1.0", .open = "", .mid = "", .close = " + 1.0", .post = ";" },
        .{ .pre = "r = ", .open = "(", .mid = "1.0", .close = ")", .post = ";" },
        .{ .pre = "r = ", .open = "-(", .mid = "1.0", .close = ")", .post = ";" }, // A.8.3: a unary operand is a primary
        .{ .pre = "k = ", .open = "{", .mid = "1'b1", .close = "}", .post = "; r = k;" },
        .{ .open = "begin ", .mid = "r = 1.0;", .close = " end" },
        .{ .pre = "r = ", .open = "V(p) > 1 ? 1 : ", .mid = "0", .post = ";", .device = false },
        .{ .open = "if (V(p) > 1) r = 1; else ", .mid = "r = 0;", .device = false },
        .{ .pre = "r = 0; ", .open = "if (V(p) > 1) ", .mid = "r = 1;", .device = false },
    }) |c| {
        for ([_]Target{ .lint, .build }) |target| {
            if (target == .build and !c.device) continue;
            const src = try deepSource(gpa, 10_000, c);
            defer gpa.free(src);
            var res = try compileSource(gpa, src, target);
            defer res.deinit();
            if (target == .build) {
                _ = try res.generateDevice();
                try std.testing.expect(!res.device_has_compile_error);
            }
        }
    }
}

test "a later stage whose stack cannot be reserved is E0241, naming the depth" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const src = try deepSource(gpa, 10, .{ .open = "begin ", .mid = "r = 1.0;", .close = " end" });
    defer gpa.free(src);
    deep_stack.refuse_for_test = true;
    defer deep_stack.refuse_for_test = false;
    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    try std.testing.expectError(error.CompileFailed, compileSourceOpts(gpa, src, .lint, .{ .diags = &bag }));
    try std.testing.expectEqual(diag.Code.E0241, bag.at(0).code);
    try std.testing.expect(std.mem.find(u8, bag.at(0).message, "levels deep") != null);
}

test "10,000 sequential ifs compile: SSA, the prover and codegen walk them on no native stack per if" {
    // Each `if` is a join the next one's block is dominated by, so the
    // dominator tree, the SSA read of `x` and the emitted chain are all
    // 10,000 deep. `sqrt` keeps every diamond out of if-conversion (its
    // domain needs the guard, which the prover reads off the edge); `+ 1.0`
    // is converted to selects, which leaves a chain of jumps instead.
    const gpa = std.testing.allocator;
    for ([_]bool{ true, false }) |guarded| {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(gpa);
        try src.appendSlice(gpa, "module seq(p); inout p; electrical p; real x;\nanalog begin\nx = 0.0;\n");
        for (1..10_001) |i| {
            if (guarded)
                try src.print(gpa, "if (V(p) > -{d}.0) x = x + sqrt(V(p) + {d}.0);\n", .{ i, i })
            else
                try src.print(gpa, "if (V(p) > -{d}.0) x = x + 1.0;\n", .{i});
        }
        try src.appendSlice(gpa, "I(p) <+ x;\nend\nendmodule\n");
        var res = try compileSource(gpa, src.items, .build);
        defer res.deinit();
        const text = try res.generateDevice();
        try std.testing.expect(!res.device_has_compile_error);
        const branches = std.mem.count(u8, text, "} else {");
        try std.testing.expectEqual(@as(usize, if (guarded) 10_000 else 0), branches);
    }
}

test "10,000-level ?: chain, else-if chain and nested ifs: device text is linear in the nesting" {
    // The parser and lowering run on a `deep_stack`, codegen on heap stacks
    // (`cfg.emitTree`, `Gen.max_indent`), and the prover, the SSA reads and
    // the setup plan are linear in it (#29), so none of them bounds the depth.
    const gpa = std.testing.allocator;
    // ponytail: 10,000 levels, not 100,000 (72 s in Debug): the indentation
    // cap and the size bound hold at any depth; a quadratic pass shows as a
    // slow test only at the larger one.
    const n = 10_000;
    for ([_]enum { ternary, else_if, nested }{ .ternary, .else_if, .nested }) |shape| {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(gpa);
        try src.appendSlice(gpa, "module deep(p); inout p; electrical p; real x;\nanalog begin\nx = 0.0;\n");
        switch (shape) {
            .ternary => {
                try src.appendSlice(gpa, "x = ");
                for (1..n + 1) |i| try src.print(gpa, "V(p) > -{d}.0 ? ", .{i});
                try src.appendSlice(gpa, "1.0");
                for (1..n + 1) |i| try src.print(gpa, " : {d}.0", .{n + 1 - i});
                try src.appendSlice(gpa, ";\n");
            },
            .else_if => {
                for (1..n + 1) |i| try src.print(gpa, "{s}if (V(p) > {d}.0) x = {d}.0;\n", .{ if (i > 1) "else " else "", i, i });
                try src.appendSlice(gpa, "else x = 0.5;\n");
            },
            .nested => {
                for (1..n + 1) |i| try src.print(gpa, "if (V(p) > -{d}.0) begin x = x + 1.0;\n", .{i});
                for (0..n) |_| try src.appendSlice(gpa, "end\n");
            },
        }
        try src.appendSlice(gpa, "I(p) <+ x * V(p);\nend\nendmodule\n");
        var res = try compileSource(gpa, src.items, .build);
        defer res.deinit();
        const text = try res.generateDevice();
        try std.testing.expect(!res.device_has_compile_error);
        // 1000 levels measured 0.6-1.6 KB a level. Indentation that grew
        // with the depth is what the per-line check below catches.
        try std.testing.expect(text.len < 4096 * n);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |l| {
            const lead = l.len - std.mem.trimStart(u8, l, " ").len;
            try std.testing.expect(lead <= codegen.Gen.indWidth(std.math.maxInt(u32)));
        }
    }
}

test "generateDevice runs codegen once and hands back the cached text" {
    const gpa = std.testing.allocator;
    var res = try compileSource(gpa, test_resistor, .build);
    defer res.deinit();
    // The pipeline itself never runs codegen.
    try std.testing.expectEqual(@as(usize, 0), res.device.text.len);

    const first = try res.generateDevice();
    try std.testing.expect(first.len != 0);
    try std.testing.expect(!res.device_has_compile_error);
    // Same slice, not an equal copy: the second call did not run codegen
    // (a second run would allocate a second gpa buffer).
    const second = try res.generateDevice();
    try std.testing.expect(first.ptr == second.ptr and first.len == second.len);
    const out = try res.generateOutput();
    try std.testing.expect(out.text.ptr == first.ptr);
}

test buildArtifact {
    // `.lint` is refused before codegen or the orchestrator runs, so these
    // options are never read: no directory, no child process.
    const gpa = std.testing.allocator;
    var res = try compileSource(gpa, test_resistor, .lint);
    defer res.deinit();
    try std.testing.expectError(error.NoArtifact, buildArtifact(gpa, std.testing.io, &res, .{
        .work_dir = "",
        .name = "res",
        .optimize = .debug,
        .backend = .self_hosted,
        .modules = &.{},
    }, 0));
    try std.testing.expectEqual(@as(usize, 0), res.device.text.len);
}

test "a source with no module of its own is NoModule, with or without the prelude" {
    // §6.2. `compileInArena` sets `builtin_modules` to the annex E prelude's
    // count; were it short, a Table E.1 primitive would be taken as the top
    // and this would compile.
    const gpa = std.testing.allocator;
    for ([_]bool{ true, false }) |std_defs| {
        var bag: diag.Bag = .init(gpa);
        defer bag.deinit(gpa);
        try std.testing.expectError(error.NoModule, compileSourceOpts(gpa, "", .lint, .{
            .diags = &bag,
            .std_defs = std_defs,
        }));
        // Lowering finds no module and says so, once.
        var e1001: usize = 0;
        for (0..bag.count()) |i| {
            if (bag.at(i).code == .E1001) e1001 += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), e1001);
    }
}

test "a parse error is NoModule only when no module of the source's own was parsed" {
    // `endmodule` with no `module` is E0201; the parser recovers at top level,
    // so in the second source it still parses `res`, and the failure is the
    // diagnosed parse, not a missing module.
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.NoModule, compileSource(gpa, "endmodule\n", .lint));
    try std.testing.expectError(error.CompileFailed, compileSource(gpa, "endmodule\n" ++ test_resistor, .lint));
}

test "without the prelude, a source that includes the annex D files itself compiles" {
    // `std_defs = false` drops the prepended annex D.1/D.2 text and the
    // Table E.1 primitives with it, so nothing is a builtin module and the
    // user's `res` is the top.
    const gpa = std.testing.allocator;
    var res = try compileSourceOpts(gpa, "`include \"disciplines.vams\"\n" ++ test_resistor, .lint, .{ .std_defs = false });
    defer res.deinit();
    try std.testing.expectEqualStrings("res", res.mir.name);
    try std.testing.expect(res.verdict.ok());
}

const test_netlist =
    \\.SUBCKT RDIV IN OUT
    \\R1 IN OUT 1K
    \\.ENDS RDIV
    \\
;

test "annex E.2: a SPICE netlist's modules lead the file but are never the top" {
    // The `.SUBCKT` becomes `module rdiv`, placed before the source. Counted
    // among the builtins it is not a candidate top: `res` is. Were it left
    // out of the count, `rdiv` (first, and instantiated by nothing) would be
    // the top, and an empty source would compile.
    const gpa = std.testing.allocator;
    {
        var res = try compileSourceOpts(gpa, test_resistor, .lint, .{ .spice_netlist = test_netlist });
        defer res.deinit();
        try std.testing.expectEqualStrings("res", res.mir.name);
    }
    try std.testing.expectError(error.NoModule, compileSourceOpts(gpa, "", .lint, .{ .spice_netlist = test_netlist }));
}

const test_unbounded_exp =
    \\module amp(a, c); inout a, c; electrical a, c;
    \\  analog I(a, c) <+ exp(V(a, c));
    \\endmodule
    \\
;

test "a --deny fails the compilation even with no bag to report into, and frees it" {
    // The denied W0650 lands in the arena's own bag, which is freed with the
    // arena; the testing allocator fails the test on a leak.
    const gpa = std.testing.allocator;
    var levels: diag.Levels = .empty;
    defer levels.deinit(gpa);
    try levels.set(gpa, .W0650, .deny);
    try std.testing.expectError(error.CompileFailed, compileSourceOpts(gpa, test_unbounded_exp, .lint, .{ .lint = levels }));
}

test "a failed compilation with no bag leaks nothing" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.CompileFailed, compileSource(
        gpa,
        "module bad(p); inout p; electrical p; analog I(p) <+ ;\nendmodule\n",
        .lint,
    ));
}

/// Lints `src` with `display` and returns how many W0850 rows have a
/// headline containing `needle` ("" counts every W0850 row).
fn countW0850(src: []const u8, display: codegen.Display, needle: []const u8) !usize {
    const gpa = std.testing.allocator;
    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    var res = try compileSourceOpts(gpa, src, .lint, .{ .diags = &bag, .display = display });
    defer res.deinit();
    var n: usize = 0;
    for (0..bag.count()) |i| {
        const e = bag.at(i);
        if (e.code == .W0850 and std.mem.find(u8, e.message, needle) != null) n += 1;
    }
    return n;
}

test "§9.4 W0850 names each task the requested device drops, and no other" {
    const strobe =
        \\module d(p, n); inout p, n; electrical p, n;
        \\  analog begin
        \\    I(p, n) <+ V(p, n);
        \\    $strobe("v=%g", V(p, n));
        \\  end
        \\endmodule
        \\
    ;
    // §9.4.1 `$monitor` needs change detection across accepted points, state
    // a device does not keep, so `say` does not record it
    // (`cg_display.sayRecords`; ch09_system_tasks/say_device_records.va).
    const monitor =
        \\module d(p, n); inout p, n; electrical p, n;
        \\  analog begin
        \\    I(p, n) <+ V(p, n);
        \\    $monitor("%g", V(p));
        \\  end
        \\endmodule
        \\
    ;
    const severity =
        \\module d(p, n); inout p, n; electrical p, n;
        \\  analog begin
        \\    if (V(p, n) > 1.0) $error("v=%g", V(p, n));
        \\    I(p, n) <+ V(p, n);
        \\  end
        \\endmodule
        \\
    ;
    const file =
        \\module d(p, n); inout p, n; electrical p, n;
        \\  integer fd;
        \\  analog begin
        \\    fd = $fopen("vera_never_written.dat");
        \\    I(p, n) <+ V(p, n);
        \\  end
        \\endmodule
        \\
    ;
    // `.drop`: the print is gone, and the warning names the task alone.
    try std.testing.expectEqual(1, try countW0850(strobe, .drop, "`$strobe`"));
    try std.testing.expectEqual(0, try countW0850(strobe, .drop, "records"));
    // `.record`: `say` records `$strobe`, but not `$monitor`.
    try std.testing.expectEqual(0, try countW0850(strobe, .record, ""));
    try std.testing.expectEqual(1, try countW0850(monitor, .record, "records the printing tasks"));
    // `.emit`: the executable prints; nothing is dropped.
    try std.testing.expectEqual(0, try countW0850(strobe, .emit, ""));
    try std.testing.expectEqual(0, try countW0850(monitor, .emit, ""));
    // §9.7.3: `$error` reaches the host through the status channel whatever
    // the display mode, so it is never reported as dropped.
    try std.testing.expectEqual(0, try countW0850(severity, .drop, ""));
    try std.testing.expectEqual(0, try countW0850(severity, .record, ""));
    // §9.5.1: a device has no file table; `$fopen` answers the zero
    // descriptor under `.drop` and `.record` alike (a file task is no
    // printing task, so `say` does not take it).
    try std.testing.expectEqual(1, try countW0850(file, .drop, "zero descriptor"));
    try std.testing.expectEqual(1, try countW0850(file, .record, "zero descriptor"));
    try std.testing.expectEqual(0, try countW0850(file, .emit, ""));
}

// Zig analyses lazily, so an unreferenced decl is never type-checked. This
// forces analysis of every top-level pub decl of every stage.
test "every top-level pub decl of every stage type-checks" {
    inline for (.{ @This(), BigArena, token, Preprocessor, Lexer, Ast, Parser, Mir, @import("prove").Analysis, @import("analog").Ssa, Elaborate, Lower, proof, naming, codegen, cg_display, cg_filters, orchestrator }) |stage| {
        std.testing.refAllDecls(stage);
    }
}
