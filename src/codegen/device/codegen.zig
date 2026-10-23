//! Mir + Lowered + proof.Verdict -> device.zig: one Zig function per source
//! unit, then the `eval`/`q` dispatchers, the §4.5.2 state machine and the
//! decls `contract.validate` checks (LRM §5, §4.5, Clause 9, §8.3).
//! Each unit has a stable name (`ir/names.zig`) and a uniform signature, so
//! `zig -fincremental` re-analyses only what changed. Identical MIR gives
//! byte-identical output. Control flow is rebuilt by codegen/cfg.zig.

const std = @import("std");
const Mir = @import("ir").Mir;
const Analysis = @import("prove").Analysis;
const UnitPlan = @import("codegen/plan/unit.zig");
const cg_filters = @import("cg_filters.zig");
const cg_display = @import("cg_display.zig");
const Lowered = @import("ir").Lowered;
const proof = @import("prove").proof;
const diag = @import("diag");
/// The pure planners (codegen/plan/): inputs in, a plan value out, no writer.
/// What they read (`prove.Input`) and the setup tiers (`prove.setup`) are
/// `prove`'s: codegen reads the tiers as a value and never writes `Lowered`.
const Input = @import("prove").Input;
/// The float mode and lanes of the emitted device (codegen/float/).
const float_mode = @import("codegen/float/mode.zig");
const float_lanes = @import("codegen/float/lanes.zig");
const plan_names = @import("codegen/plan/names.zig");
const plan_topo = @import("codegen/plan/topology.zig");
const plan_limit = @import("codegen/plan/limit.zig");
const plan_noise = @import("codegen/plan/noise.zig");
const plan_jobs = @import("codegen/plan/jobs.zig");
const plan_core = @import("codegen/plan/core.zig");
const plan_args = @import("codegen/plan/args.zig");
const plan_setup = @import("prove").setup;
const plan_qsite = @import("codegen/plan/qsite.zig");
const plan_jac = @import("codegen/plan/jac.zig");
const gen_mask = @import("codegen/mask.zig");
const gen_family = @import("codegen/family.zig");
/// The backend half of the Opcode table: how each opcode is spelled in Zig.
pub const opcode_zig = @import("codegen/opcode_zig.zig");

/// Every way `generate` fails. Out of memory aside, each is a refusal of
/// the whole device: no partial `Output` is returned. A refusal confined to
/// one unit is not an error here but a `@compileError` body plus `fatal_out`.
pub const Error = std.mem.Allocator.Error || error{
    /// proof.zig rejected the model. `generate` returns this before emitting
    /// a byte.
    DomainErrors,
    /// A numeric parameter default cannot follow host-written dependencies.
    UnsupportedParameterDefault,
};

/// Sentinel for "no index" in the u32 columns (`Hoist.idx`, a non-held array).
pub const none_u32 = std.math.maxInt(u32);

/// The generated device and its per-unit ranges: the value `zigbuild`
/// writes and builds, defined there (`zigbuild.Output`) so the build never
/// imports codegen. `generate` produces it.
pub const Output = @import("zigbuild").Output;

/// §9.4: whether display tasks are dropped or emitted (plan/args.zig).
pub const Display = plan_args.Display;

/// Settings that change what is generated.
pub const Options = struct {
    /// §9.4: `.emit` builds the testbench's `display` unit; `.record` a solver
    /// device whose `say` records its display tasks for the host; `.drop` a
    /// solver device without one.
    display: Display = .drop,
    /// Emits `pub const jac_f32 = true`: the host may carry the derivative half
    /// of S in single precision. Changes no emitted arithmetic, since every
    /// primitive takes and returns f64 at the boundary. The device states it
    /// because only the physics knows whether its unknowns fit in f32's ~7
    /// digits. A permission, not an order: a host may take it on one
    /// instantiation and decline it on another.
    jac_f32: bool = false,
    /// Also emits `pub const jac_f32_host = true`: the host should take the
    /// permission on its CPU instantiation too. Implies `jac_f32`;
    /// `lib/contract.zig` rejects it without the permission.
    jac_f32_host: bool = false,
    /// Where a codegen-stage diagnostic (E0515) goes. With none, a refusal is
    /// reported through `fatal_out` alone. This is the caller's bag, alive as
    /// long as the `CompileResult`; `lower.bag` is not, because `root.finish`
    /// has already detached it by the time codegen runs.
    diags: ?*diag.Bag = null,
    /// Emits `vpiContribs` and its row tables: both halves of every §5.6
    /// contribution by `Lowered.contributions` index, for a host answering
    /// §12.10 `vpi_get_analog_value` on a branch flow; and, when instances
    /// share a row, `vpiShares` and `vpi_share_row`: each one's own share
    /// (`Lowered.contrib_shares`).
    vpi_contribs: bool = false,
};

/// Emits the whole device.zig (LRM §5, §8.3).
///
/// `arena` must be the per-compilation arena: every scratch table lives on it
/// and this pass has no deinit. `gpa` owns `Output.text` and nothing else; the
/// caller frees it (`CompileResult.deinit`). The other `Output` slices are
/// arena-owned. The text is on the gpa because it grows without bound and an
/// arena regrows anything but its latest allocation by copying.
/// Returns `error.DomainErrors` without emitting when `verdict` rejects the model.
/// Deterministic: nothing on this path iterates a hash map.
pub fn generate(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    mir: *const Mir,
    lowered: *const Lowered,
    verdict: proof.Verdict,
    /// Set for any fatal generation failure, including metadata outside units.
    fatal_out: *bool,
    opts: Options,
) Error!Output {
    if (!verdict.ok()) return error.DomainErrors;
    // §6.2: the port list is optional, so a module with no ports or nets is
    // valid. It yields a device with `num_ports == 0` and an empty `U`.

    const an = try Analysis.build(arena, mir, lowered);
    var g: Gen = .{
        .gpa = gpa,
        .an = &an,
        .arena = arena,
        .mir = mir,
        .lowered = lowered,
        .verdict = verdict,
        .display = opts.display,
        .float = .{ .jac = .of(opts.jac_f32, opts.jac_f32_host) },
        .diags = opts.diags,
        .vpi_contribs = opts.vpi_contribs,
    };
    errdefer g.out.deinit(gpa);
    try g.prepare();
    try g.emitFile();
    fatal_out.* = g.any_fatal or (if (opts.diags) |bag| bag.failed() else false);
    const files = g.files.slice();
    return .{
        .text = try g.out.toOwnedSlice(gpa),
        .names = files.items(.name),
        .unit_lo = files.items(.lo),
        .unit_fn = files.items(.fn_at),
        .unit_hi = files.items(.hi),
        .prelude = g.prelude,
        .helpers = g.helpers,
        .setup_chunks = g.su.chunks,
    };
}

// ===========================================================================
// Value typing: every MIR Value is emitted either as an `S` (real) or as a
// plain `i64` (LRM §3.2 integer). §4.2.1.1/§4.2.1.2 conversions are inserted at
// the use site, so a typing miss degrades to a redundant cast, never to code
// that does not compile.
// ===========================================================================

/// The value-type lattice lives with the analysis that computes it.
pub const VTy = Analysis.VTy;

/// Hash context for `Gen.f64_cache`. The key is an f64's bit pattern, so an
/// integer mix is enough where `AutoContext` would run Wyhash over its bytes.
const F64Context = struct {
    /// Mixes the bit pattern; distinct NaN payloads stay distinct keys.
    pub fn hash(_: F64Context, k: u64) u64 {
        return std.hash.int(k);
    }
    /// Bitwise: `-0.0` and `0.0` are different keys (they render differently).
    pub fn eql(_: F64Context, a: u64, b: u64) bool {
        return a == b;
    }
};

// ===========================================================================
// The generator
// ===========================================================================

/// One `systf_calls` entry: a `$name` call, the token it was lowered from,
/// and whether it is a task (a statement) rather than a function.
const SystfSite = struct { name: []const u8, tok: u32, task: bool };

/// The emitter's state for one device. Built and driven by `generate`.
///
/// Fields are grouped by who writes them and when: the inputs (never
/// written), the device plans (`prepare`, once), the output, the state of the
/// one declaration being written (reset per unit), and the facts emission
/// accumulates for the tables written after the units. Every slice is
/// arena-owned except `out`.
pub const Gen = struct {
    // ---- inputs: set by `generate`, never written -------------------------

    /// Owns `out` and nothing else (see `generate`).
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    mir: *const Mir,
    lowered: *const Lowered,
    /// The derived facts this emitter reads and never writes: CFG, dominators,
    /// loops, block pools, instruction columns, value types, aliases
    /// (prove/analysis.zig). Policy (naming, hoisting, inlining) stays below.
    an: *const Analysis,
    verdict: proof.Verdict,
    /// §9.4. `.drop` ⇒ nothing below ever looks at `lower.display_root`.
    display: Display = .drop,
    /// `Options.vpi_contribs`.
    vpi_contribs: bool = false,
    /// `Options.diags`: where E0515 goes, when the caller kept a bag.
    diags: ?*diag.Bag = null,

    // ---- device plans: written once by `prepare` --------------------------

    /// Every declared identifier and the unknowns behind them (`plan/names.zig`).
    names: plan_names.Names = .{},
    /// Free branch flows and collapsible switch branches (`plan/topology.zig`).
    topo: plan_topo.Topology = .{},
    /// §4.5.11/§4.5.12 each filter operator's plan, by unit index (`null` for
    /// every other unit). Filled once by `cg_filters.planAll`.
    filters: []?cg_filters.FilterPlan = &.{},
    /// §4.5.15 the honoured and declined `$limit` sites (`plan/limit.zig`).
    limits: plan_limit.Limits = .{},
    /// §4.6.3/§4.6.4 the small-signal source rows and tables (`plan/noise.zig`).
    noise: plan_noise.Noise = .{},
    /// Solve invariance per value, block and loop (`prove/setup.zig`).
    sinv: plan_setup.Sinv = .{},
    /// §5.6.1.2 the charge sites `q` returns and the rows they stamp
    /// (`plan/qsite.zig`).
    qs: plan_qsite.QSites = .{},
    // The shared core (plan/core.zig says why it exists).
    /// Every unit target the core returns, in insert-tolerant order (`plan/jobs.zig`).
    jobs: plan_jobs.Jobs = .{},
    /// The shared core's live-outs, latches, name and float mode (`plan/core.zig`).
    core: plan_core.Core = .{},
    /// §3.2.2 per `Lowered.mem_arrays` row: does some load read a version a
    /// derivative-carrying store reached (`Analysis.dFree` of the version)?
    /// Then the storage is `S`; otherwise plain `f64`, and a store keeps only
    /// the value, since no load could see what it dropped. See `prepare`.
    arr_s: []bool = &.{},
    /// Words per unknown mask (`codegen/mask.zig`): `max(1, ceil(n_u / 64))`.
    mw: u32 = 1,
    /// `Analysis.deps` and `Analysis.acdyn` at `mw` words per value (the
    /// analysis' own slices when they are that wide); `acdyn` empty when
    /// the module has no frequency-dependent operator. `family.mask` and
    /// `family.acDyn` read them.
    deps: []const u64 = &.{},
    acdyn: []const u64 = &.{},
    /// `mw` zero words.
    zero_mask: []const u64 = &.{},
    /// The mask of each `Lowered.mem_arrays` row's storage, `mw` words per
    /// row (`prepare`).
    arr_mask: []u64 = &.{},
    /// The setup roots and `setup`'s emission state (`codegen/setup.zig`).
    su: gen_setup.Setup = .{},

    // ---- output -----------------------------------------------------------

    out: std.ArrayList(u8) = .empty,
    /// Rendered text of every float constant seen, keyed on its bit pattern.
    /// See `fmtF64`.
    f64_cache: std.HashMapUnmanaged(u64, []const u8, F64Context, std.hash_map.default_max_load_percentage) = .empty,
    /// One row per emitted top-level unit declaration, in emission order; the
    /// columns become `Output.names`/`unit_lo`/`unit_fn`/`unit_hi`. Appended
    /// by `file.recordUnitFile`.
    files: std.MultiArrayList(gen_file.UnitFile) = .empty,
    /// See `Output.prelude` / `Output.helpers`. Built by `emitFile`, which is
    /// where the conditionally-emitted helper blocks are already decided.
    prelude: []const u8 = "",
    helpers: []const u8 = "",
    /// `cg_strcap`'s memo: the capacity of each string Value asked about.
    str_caps: std.AutoHashMapUnmanaged(Mir.Value, u64) = .empty,
    /// `cg_strcap.heldCap` per `Lowered.held_vars` row, solved on first use.
    held_caps: ?[]u64 = null,

    // ---- the declaration being written: reset per unit --------------------

    /// Per-unit state: the slice, use counts, inline decisions and slots for the
    /// declaration being written. Reset in full by every `analyze`.
    plan: UnitPlan = undefined,
    /// Which uniform parameters the body read (`unit.Uses`).
    uses: gen_unit.Uses = .{},
    /// `out` ranges of the final emission's `then` arms of a §5.10.2
    /// `initial_step` branch (`cfg.emitTerm`), for `unit.scanSimReads`.
    init_arms: std.ArrayList([2]usize) = .empty,
    /// What the shared core reads of `SimState` (`unit.scanSimReads`),
    /// written out as `sim_reads`. All false when there is no core.
    sim_reads: gen_unit.SimReads = .{},
    /// Set when the unit asks for a value the LRM fixes and this backend
    /// cannot produce (§4.5's non-constant control argument, E0515; a §3.6.2.2
    /// signal-flow contribution). The whole body collapses to one
    /// `@compileError`: a substitute would contradict the clause, and a
    /// per-statement error would bury the reason in a cascade.
    /// An unregistered system function (W0852) does not come here: the language
    /// defines no value for it, so 0.0 contradicts nothing.
    fatal: ?[]const u8 = null,
    /// Token of the §4.5 operator call whose arguments are being rendered: the
    /// fallback span for E0515 when the offending argument is a leaf with no
    /// instruction of its own (a node probe has no token).
    // ponytail: one field set at the two places that render operator arguments,
    // rather than threading a token through `argF64`'s six call sites.
    // Ceiling: it is only ever read on the E0515 path, which refuses the unit.
    ctrl_tok: u32 = Mir.no_tok,
    /// Token of the innermost call `emitCall` is rendering: the span
    /// `gen_call.abort` reports its refusal at.
    call_tok: u32 = Mir.no_tok,
    /// Distinguishes one emitted systf block's `break` label from another's.
    /// Blocks nest, so the label has to be unique within a unit and a counter
    /// is the cheapest thing that is.
    systf_sites: u32 = 0,
    /// The float mode and lane state of the body being written (`codegen/float/`).
    float: float_mode.Float = .{},
    /// The operand of the guarded row being rendered (`Mir.guard_of`) that
    /// `renderVal` swaps for its domain's safe value when the guard is false.
    /// Set and cleared around one `renderOp` (`render.renderInst`).
    subst: ?gen_render.Subst = null,
    /// Set while the core is emitted. The core slices from every target at
    /// once and computes each value; the §9.4 display unit, the only other
    /// body, slices from one target and reads the rest.
    emitting_common: bool = false,
    /// Set while the §9.4/§9.5 display unit is emitted; read by
    /// `call.zig`'s §9.5 dispatch. A §9.5 call opens files, moves read
    /// positions and appends bytes, while `eval` must stay a pure function of
    /// x for Newton to converge. So the file kernels run only in the display
    /// unit, which `plan_core.plan` keeps out of the shared core. §9.5.9: "if a
    /// file is being written to during an iterative solve, then the file write
    /// operations shall not be performed unless the iteration is accepted."
    emitting_display: bool = false,
    /// §9.4 the display tasks a `.record` device's `say` records
    /// (`cg_display.planSay`), in `say_sites` order. Empty otherwise.
    say: []const cg_display.SaySite = &.{},
    /// §9.4.1/§9.5.9 a printing artifact's display unit runs in passes
    /// (`contract.SayPass`): set when it has a `$debug` or `$fdebug`, the
    /// tasks that show output at every iteration (`cg_display.planPasses`).
    passes: bool = false,
    /// §5.2.1 the calls an `analog initial` block makes: a pass performs its
    /// §9.5 and `$debug`/`$fdebug` ones once per analysis, and a §9.7
    /// diagnostic among them reports initialization (`cg_display.emitWhen`).
    init_calls: []const Mir.Inst = &.{},
    /// Set while the caller owns the `core` call (`zResidual`'s `m`, `acceptQ`'s
    /// hoisted line), so `emitStamps` must not open its own.
    core_hoisted: bool = false,
    /// Set by `emitStamps` when it wanted a core call. Under `core_hoisted` it
    /// is the only record that one is needed.
    core_wanted: bool = false,
    /// The dry run that places each slot's declaration (`unit.Probe`).
    probe: gen_unit.Probe = .{},
    /// The surviving hoisted slots and their arrays (`unit.Hoist`).
    hoist: gen_unit.Hoist = .{},

    // ---- accumulated across declarations, for the tables emitted after ----

    /// Sticky: generation failed, even outside a unit body. Reported out so
    /// callers do not have to substring-search generated text for a refusal.
    any_fatal: bool = false,
    /// §2.8.3/§12.32: the `$name` call sites this backend did not resolve, in
    /// first-call order. Becomes `systf_calls`, so the index is the host's
    /// binding index. One entry per source call (name and token), not per
    /// name: §12.32.1's calltf runs for "each" invocation with
    /// `vpi_handle(vpiSysTfCall, NULL)` naming that call, so the host must
    /// know which call it is. A unit that renders one call twice reuses its
    /// entry. Linear scan: the list is tiny.
    systf_names: std.ArrayList(SystfSite) = .empty,
    /// The `Instance` fields `updateState` advances, in declaration order
    /// (`file.emitInstance` fills it). `stateCtl` commits each to, and reverts
    /// it from, the `State` field of the same name.
    hist: std.ArrayList([]const u8) = .empty,
    /// §5.10 per `Lowered.mem_arrays` row: the held array `updateState`
    /// stores in place and whose `<field>__dirty` range `stateCtl` copies
    /// (`state.inPlaceArrays`). Set by `emitInstance`; empty when none.
    held_in_place: []const bool = &.{},
    /// VerA's `vera_timepoint` (§2.9) per MIR block: the innermost statement
    /// whose miss arm holds it (`Lowered.TpBlock`), or `none_u32`. Its stores
    /// to an array the statement caches write the cache slot in place
    /// (`instance.tpInPlace`). Set by `prepare`; empty when no slot is in place.
    tp_of_block: []const u32 = &.{},
    /// The full core's value → field map (`plan_core.Core.lo_idx`), which
    /// `instance.tpInPlace` reads while a slice's plan is in force. Set by
    /// `prepare`.
    tp_lo_idx: []const u32 = &.{},
    /// Value → field of `limit`'s slice of the core, or `none_u32`
    /// (`cg_limit.emitCore`); empty when `limit` reads nothing off the core.
    lim_idx: []u32 = &.{},
    /// The core as `updateState` reads it: its slice (`gen_state.emitCore`),
    /// or `.{}` when `updateState` reads nothing off the core.
    state_core: plan_core.Core = .{},
    /// The core as `noisePsd` reads it: its slice (`gen_noise.emitNoiseCore`),
    /// or `.{}` when `noisePsd` reads nothing off the core.
    noise_core: plan_core.Core = .{},
    /// Whether `noise_core` reads a §4.5.14 `ddx` lane, so `noisePsd` seeds
    /// its inputs as `eval` does (`zProbe`) instead of value-only (#32).
    noise_reads_ddx: bool = false,
    /// The core as `advanceIteration` and `checkConvergence` read it: their
    /// slice (`gen_state.emitIterCore`), or `.{}` when they read nothing off it.
    iter_core: plan_core.Core = .{},
    /// The Jacobian evidence the dispatchers and the renderer leave behind
    /// (`dispatch.Jac`): patterns, written rows, lane reads and constant
    /// coefficients.
    jac: gen_dispatch.Jac = .{},
    /// The raw mask of every real declared, for `family.emitLaneMasks`.
    fam_masks: std.ArrayList([]const u64) = .empty,

    /// The one fact `plan_jobs` needs from the renderer: does a §4.5 control
    /// argument (or §4.6.3 stimulus) render host-side, or only off the core?
    const DynCtrl = struct {
        g: *Gen,
        /// Whether `v` renders only off the core (`host_expr.ctrlIsDynamic`).
        pub fn isDynamic(d: DynCtrl, v: Mir.Value) Error!bool {
            return gen_host.ctrlIsDynamic(d.g, v);
        }
    };

    /// Returns what a `plan/` function reads (`prove/input.zig`).
    pub fn input(self: *const Gen) Input {
        return .{ .arena = self.arena, .mir = self.mir, .an = self.an, .lowered = self.lowered };
    }

    /// Fails generation (`any_fatal`) and collapses the current unit to a
    /// `@compileError` naming `msg`, unless an earlier refusal already named it.
    pub fn poison(self: *Gen, msg: []const u8) void {
        self.any_fatal = true;
        if (self.fatal == null) self.fatal = msg;
    }

    // ---- the writer: every emitted byte goes through these ----

    /// Appends formatted file-scaffolding text to the output.
    pub fn w(self: *Gen, comptime fmt: []const u8, args: anytype) Error!void {
        try self.out.print(self.gpa, fmt, args);
    }

    /// Appends formatted body text. Same destination as `w`, since the
    /// signature is back-patched (`emitUnit`); the name marks body call sites.
    pub fn b(self: *Gen, comptime fmt: []const u8, args: anytype) Error!void {
        try self.out.print(self.gpa, fmt, args);
    }

    /// Returns the §5.10 trailing argument of a core call: nothing for a core
    /// without held-only stores, else whether this caller keeps the held
    /// arrays' end-of-block values (`updateState`, `acceptQ`) or not (`eval`/`q`).
    pub fn heldArg(self: *const Gen, held: bool) []const u8 {
        if (self.core.held_only.len == 0) return "";
        return if (held) ", true" else ", false";
    }

    /// Writes `n` levels of four-space indentation, at most `max_indent`.
    pub fn ind(self: *Gen, n: u32) Error!void {
        try self.out.appendNTimes(self.gpa, ' ', indWidth(n));
    }

    /// The deepest level `ind` indents to. Nesting has no bound (an
    /// `if`/`?:` chain the source nests 100,000 deep is a block that deep),
    /// and indenting each level further would make the text quadratic in
    /// it: 8000 nested `?:` were 2.4 GB of device. Past this the lines stay
    /// at one column, so the text is linear; Zig does not read indentation,
    /// and the emitted device is never `zig fmt`-checked. No fixture nests
    /// this deep, so every device that fits is byte-identical.
    pub const max_indent = 32;

    /// The spaces `ind(n)` writes.
    pub fn indWidth(n: u32) u32 {
        return @as(u32, @min(n, max_indent)) * 4;
    }

    // ------------------------------------------------------------------ setup

    /// `col` (`w` words per value) at `mw` words per value: `col` itself when
    /// `w == mw`, else a zero-extended copy from `arena`.
    fn widen(arena: std.mem.Allocator, col: []const u64, words: u32, mw: u32) Error![]const u64 {
        std.debug.assert(words <= mw);
        if (words == mw) return col;
        const n = col.len / words;
        const out = try gen_mask.zero(arena, @intCast(n * mw));
        for (0..n) |i| @memcpy(out[i * mw ..][0..words], col[i * words ..][0..words]);
        return out;
    }

    /// Array `id`'s storage mask: `mw` words of `arr_mask`.
    pub fn arrMask(self: *const Gen, id: usize) []u64 {
        return self.arr_mask[id * self.mw ..][0..self.mw];
    }

    fn prepare(self: *Gen) Error!void {
        // The emitted Zig runs about 24 bytes per MIR instruction; one guess
        // up front saves a dozen doublings.
        try self.out.ensureTotalCapacity(self.gpa, self.mir.insts.len * 24 + 4096);
        // Per-unit scratch, owned by plan/unit.zig.
        self.plan = try UnitPlan.init(self.arena, self.mir, self.an, self.display);
        self.arr_s = try self.arena.alloc(bool, self.lowered.mem_arrays.items.len);
        @memset(self.arr_s, false);
        if (self.arr_s.len != 0) for (self.an.i_op, 0..) |op, ii| {
            if (op != .fload) continue;
            const arr: Mir.Value = @fromBackingInt(@intCast(self.mir.insts.items(.a)[ii]));
            if (!self.an.dFree(arr)) self.arr_s[self.an.arrOf(arr).?] = true;
        };
        self.names = try plan_names.plan(self.input(), self.verdict.unit_modes.len);
        self.mw = @intCast(@max(1, std.math.divCeil(u32, self.names.n_u, 64) catch unreachable));
        self.deps = try widen(self.arena, self.an.deps, self.an.dep_words, self.mw);
        self.acdyn = try widen(self.arena, self.an.acdyn, self.an.dep_words, self.mw);
        self.zero_mask = try gen_mask.zero(self.arena, self.mw);
        try gen_dispatch.alloc(self);
        // One storage holds every version of its array, so its elements are
        // typed by the union of their masks.
        self.arr_mask = try gen_mask.zero(self.arena, @intCast(self.arr_s.len * self.mw));
        if (self.arr_mask.len != 0) for (0..self.an.nv) |v| {
            const id = self.an.arrOf(@fromBackingInt(@intCast(v))) orelse continue;
            gen_mask.orIn(self.arrMask(id), gen_family.mask(self, @fromBackingInt(@intCast(v))));
        };
        // After `plan_names.plan`, which fills the `branch_u` that `freeFlows`
        // subtracts.
        self.topo = try plan_topo.plan(self.input(), self.names.branch_u);
        try cg_filters.planAll(self);
        // Before `buildJobs`: §4.5.15 the algorithm arguments of every honoured
        // `$limit` become core live-outs, and `buildJobs` is what queues them.
        self.limits = try plan_limit.plan(self.input(), self.names.u_names);
        // Before `buildJobs`: §4.6.4 the PSD arguments become core live-outs
        // too, and `buildJobs` is what queues them.
        self.noise = try plan_noise.plan(self.input());
        for (self.noise.refusals.items) |r| {
            if (self.diags) |bag| try bag.add(.codegen, r.code, self.lowered.tokenSpan(r.tok), "{s}", .{r.msg});
            self.any_fatal = true;
        }
        // VerA's `vera_timepoint` (§2.9): a cached statement may read nothing
        // a Newton iteration moves.
        for (self.lowered.timepoints.items) |t| {
            const v = try plan_setup.timepointVarying(self.input(), t) orelse continue;
            self.any_fatal = true;
            const bag = self.diags orelse continue;
            var d = bag.build(.codegen, .E0531, self.lowered.tokenSpan(t.tok));
            // The value's own source token, when it has one.
            const def = self.mir.valueDef(v);
            const tok = if (def == .inst_result) self.mir.insts.items(.tok)[@backingInt(def.inst_result)] else Mir.no_tok;
            if (tok != Mir.no_tok) d.label(self.lowered.tokenSpan(tok), "this value can change between iterations", .{});
            try d.emit();
        }
        // Solve invariance first: the charge-site plan reads it to leave the
        // time-constant charges out of `q`, and the jobs queue what it keeps.
        self.sinv = try plan_setup.plan(self.input());
        self.qs = try plan_qsite.plan(self.input(), self.names.branch_u, self.topo, self.sinv.val);
        if (self.display == .record) self.say = try cg_display.planSay(self);
        if (self.display == .emit) try cg_display.planPasses(self);
        self.jobs = try plan_jobs.plan(self.input(), .{
            .names = &self.names,
            .unit_modes = self.verdict.unit_modes,
            .limits = self.limits.calls,
            .noise = &self.noise,
            .emit_display = self.display == .emit,
            .record_display = self.say.len != 0,
            .q_sites = self.qs.sites,
            .vpi = self.vpi_contribs,
        }, DynCtrl{ .g = self });
        self.core = try plan_core.plan(self.input(), self.jobs.list);
        // §5.10 a held array's storage carries a derivative only for a load
        // `eval`/`q` returns something from: the rest are read by the value-
        // only consumers (`updateState` and `acceptQ` read `.val()`), so
        // the lanes such a load would carry are never observed. Except by a
        // §4.5.14 `ddx` in a display task: the display unit is a consumer
        // `eval_need` does not see, and it reads lanes.
        const display_ddx = (self.display == .emit or self.say.len != 0) and for (self.an.i_op, 0..) |op, ii| {
            if (op == .call and self.mir.instData(@fromBackingInt(@intCast(ii))).call.callee == .ddx) break true;
        } else false;
        if (self.core.eval_need.len != 0 and !display_ddx) for (self.arr_s, 0..) |*s, id| {
            if (!s.* or self.lowered.mem_arrays.items[id].held == none_u32) continue;
            s.* = for (self.an.i_op, 0..) |op, ii| {
                if (op != .fload) continue;
                const arr: Mir.Value = @fromBackingInt(@intCast(self.mir.insts.items(.a)[ii]));
                if (self.an.arrOf(arr).? != id or self.an.dFree(arr)) continue;
                if (self.core.eval_need[@backingInt(self.an.rv(self.an.i_res[ii]))]) break true;
            } else false;
        };
        // After the core planner, which is what fills them. Stable for the
        // rest of the compilation; `cached` reads them per unit.
        self.plan.lo_idx = self.core.lo_idx;
        self.plan.lo_vals = self.core.lo_vals;
        self.plan.arr_lanes = self.arr_s;
        // Reads the full core's `lo_idx` and the final `arr_s`.
        self.tp_lo_idx = self.core.lo_idx;
        self.tp_of_block = try gen_instance.tpBlocks(self);
        // Last, and before any emission: the roots are what the core's slice
        // reaches, and `emitInstance` sizes `Setup` from them.
        try gen_setup.planSetup(self);
    }

    // ---- the emitter sub-files ----
    //
    // The `pub` aliases below are the sub-file API the `cg_*.zig` emitters
    // call (`g.renderVal(...)`); everything else stays file-private.

    // Setup: the solve-invariant slice, computed once per card (codegen/setup.zig)
    const gen_setup = @import("codegen/setup.zig");
    /// `setup.probeInstance`: the instance an auxiliary core sweep passes. May
    /// write a `var table_probe` declaration to `out` first.
    pub const probeInstance = gen_setup.probeInstance;
    /// `setup.rootRef`: the text reading a setup root's `Model.su` field.
    pub const rootRef = gen_setup.rootRef;

    // --------------------------------------------------------------- units ----

    // File assembly, the spine: the device.zig skeleton (§1.3.1 `U`, §3.4 `Model`), codegen/file.zig
    const gen_file = @import("codegen/file.zig");
    /// `file.emitFile`, the codegen spine. Asserts nothing was emitted yet.
    pub const emitFile = gen_file.emitFile;
    /// `file.fmtF64`: an f64 as Zig literal text, arena-owned and memoized.
    pub const fmtF64 = gen_file.fmtF64;

    // §4.5 `Instance`, its `State` twin and `stateCtl`, codegen/instance.zig
    const gen_instance = @import("codegen/instance.zig");

    // Units: one function per source unit and the body it computes, codegen/unit.zig
    const gen_unit = @import("codegen/unit.zig");

    // Control-flow reconstruction: MIR CFG -> structured Zig, codegen/cfg.zig
    const gen_cfg = @import("codegen/cfg.zig");

    // Value and instruction rendering: MIR value -> Zig expression (§4.2.1 conversions), codegen/render.zig
    const gen_render = @import("codegen/render.zig");
    /// `render.renderVal`: appends a value's Zig expression, converted to the
    /// requested LRM type (§4.2.1.1/§4.2.1.2).
    pub const renderVal = gen_render.renderVal;

    // Host expressions: a parameter or control argument -> plain f64/i64 text over `model`, codegen/host_expr.zig
    const gen_host = @import("codegen/host_expr.zig");
    /// `host_expr.f64Const`: plain-f64 text over `model`, or null.
    pub const f64Const = gen_host.f64Const;
    /// `host_expr.f64Expr`: `f64Const`, or E0515 and a poisoned unit.
    pub const f64Expr = gen_host.f64Expr;

    // Calls: §4.5 analog operators, §4.6 noise, Clause 9 system functions, codegen/call.zig
    const gen_call = @import("codegen/call.zig");
    /// `call.abort`: reports a refusal at the call being rendered and poisons
    /// the unit.
    pub const abort = gen_call.abort;
    /// `call.strArg`: the string literal at `args[i]`, or null.
    pub const strArg = gen_call.strArg;

    // Dispatchers: §5.6 residual assembly, §1.3.1.2 reference directions, codegen/dispatch.zig
    const gen_dispatch = @import("codegen/dispatch.zig");

    // §4.6.3/§4.6.4 small-signal source tables, codegen/noise.zig
    const gen_noise = @import("codegen/noise.zig");

    // §4.5.2 the analog-operator state machine and §5.6.5 zero-parasitic collapse, codegen/state.zig
    const gen_state = @import("codegen/state.zig");
};

/// Fixed emitted text: the runtime kernels every device carries (§4.3 math, §4.5 operators, Clause 9), codegen/kernel_text.zig
pub const kernel_text = @import("codegen/kernel_text.zig");
const gen_kernel_text = kernel_text;

/// `setup`'s text as chunks a split build compiles in parallel (its test builds and runs them).
const setup_chunk = @import("codegen/setup_chunk.zig");

/// Test support: a source lowered and generated (codegen/harness.zig).
pub const Harness = @import("codegen/harness.zig").Harness;

test {
    _ = plan_names;
    _ = plan_topo;
    _ = plan_limit;
    _ = plan_noise;
    _ = plan_jobs;
    _ = plan_core;
    _ = plan_args;
    _ = plan_qsite;
    _ = plan_jac;
    _ = UnitPlan;
    _ = float_mode;
    _ = float_lanes;
    _ = Gen.gen_setup;
    _ = setup_chunk;
    _ = Gen.gen_file;
    _ = Gen.gen_instance;
    _ = Gen.gen_unit;
    _ = Gen.gen_cfg;
    _ = Gen.gen_render;
    _ = Gen.gen_host;
    _ = Gen.gen_call;
    _ = Gen.gen_dispatch;
    _ = Gen.gen_noise;
    _ = Gen.gen_state;
    _ = gen_kernel_text;
    _ = opcode_zig;
}
