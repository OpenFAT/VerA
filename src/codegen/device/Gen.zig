//! The emitter's state for one device: the inputs `generate` hands it, the
//! device plans `prepare.zig` writes once, the output text, the state of the
//! one declaration being written (`Decl`, reset per unit) and the facts
//! emission accumulates for the tables written after the units. Every
//! emitter takes `*Gen`; `file.emitFile` is the spine that drives them.
//! Cites: none of its own (the fields cite the clause they serve).
//!
//! Contents:
//! - fields (inputs, plans, output, `cur: Decl`, accumulated tables)
//! - `pub const Decl = struct`
//! - `pub const SystfSite = struct`
//! - `pub const max_indent: u32`
//! - `pub fn input(self: *const Gen) Input`
//! - `pub fn poison(self: *Gen, msg: []const u8) void`
//! - `pub fn w(self: *Gen, comptime fmt: []const u8, args: anytype) Error!void`
//! - `pub fn b(self: *Gen, comptime fmt: []const u8, args: anytype) Error!void`
//! - `pub fn heldArg(self: *const Gen, held: bool) []const u8`
//! - `pub fn ind(self: *Gen, n: u32) Error!void`
//! - `pub fn indWidth(n: u32) u32`
//! - `pub fn arrMask(self: *const Gen, id: usize) []u64`
//! - `F64Context.hash`, `F64Context.eql` (the `f64_cache` context)
//! - method aliases: `probeInstance`, `rootRef`, `emitFile`, `fmtF64`,
//!   `renderVal`, `f64Const`, `f64Expr`, `abort`, `strArg`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const Analysis = @import("prove").Analysis;
const Input = @import("prove").Input;
const proof = @import("prove").proof;
const plan_setup = @import("prove").setup;
const diag = @import("diag");
const UnitPlan = @import("codegen/plan/unit.zig");
const plan_args = @import("codegen/plan/args.zig");
const plan_names = @import("codegen/plan/names.zig");
const plan_topo = @import("codegen/plan/topology.zig");
const plan_limit = @import("codegen/plan/limit.zig");
const plan_noise = @import("codegen/plan/noise.zig");
const plan_jobs = @import("codegen/plan/jobs.zig");
const plan_core = @import("codegen/plan/core.zig");
const plan_qsite = @import("codegen/plan/qsite.zig");
const float_mode = @import("codegen/float/mode.zig");
const cg_filters = @import("cg_filters.zig");
const cg_display = @import("cg_display.zig");
const cg_say = @import("cg_say.zig");
const gen_setup = @import("codegen/setup.zig");
const gen_file = @import("codegen/file.zig");
const gen_unit = @import("codegen/unit.zig");
const gen_unit_body = @import("codegen/unit_body.zig");
const gen_render = @import("codegen/render.zig");
const gen_host = @import("codegen/host_expr.zig");
const gen_call = @import("codegen/call.zig");
const gen_dispatch = @import("codegen/dispatch.zig");

const Error = @import("codegen.zig").Error;
const Display = plan_args.Display;

// ---- inputs: set by `generate`, never written -------------------------------

/// Owns `out` and nothing else (see `generate`).
gpa: Allocator,
/// The per-compilation arena: every table below lives on it.
arena: Allocator,
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

// ---- device plans: written once by `prepare.zig` ----------------------------

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
sinv: plan_setup.Invariance = .{},
/// §5.6.1.2 the charge sites `q` returns and the rows they stamp
/// (`plan/qsite.zig`).
qs: plan_qsite.QSites = .{},
/// Every unit target the core returns, in insert-tolerant order (`plan/jobs.zig`).
jobs: plan_jobs.Jobs = .{},
/// The shared core's live-outs, latches, name and float mode (`plan/core.zig`).
/// Swapped for a slice while a slice's caller is written (`unit.sliceCore`).
core: plan_core.Core = .{},
/// §3.2.2 per `Lowered.mem_arrays` row: does some load read a version a
/// derivative-carrying store reached (`Analysis.dFree` of the version)?
/// Then the storage is `S`; otherwise plain `f64`, and a store keeps only
/// the value, since no load could see what it dropped.
arr_s: []bool = &.{},
/// Words per unknown mask (`codegen/mask.zig`): `max(1, ceil(n_u / 64))`.
mw: u32 = 1,
/// `Analysis.deps` and `Analysis.acdyn` at `mw` words per value (the
/// analysis' own slices when they are that wide); `acdyn` empty when the
/// module has no frequency-dependent operator. `family.mask` and
/// `family.acDyn` read them.
deps: []const u64 = &.{},
acdyn: []const u64 = &.{},
/// `mw` zero words.
zero_mask: []const u64 = &.{},
/// The mask of each `Lowered.mem_arrays` row's storage, `mw` words per row.
arr_mask: []u64 = &.{},
/// The setup roots and `setup`'s emission state (`codegen/setup.zig`).
su: gen_setup.Setup = .{},
/// §9.4 the display tasks a `.record` device's `say` records
/// (`cg_say.planSay`), in `say_sites` order. Empty otherwise.
say: []const cg_say.SaySite = &.{},
/// §9.4.1/§9.5.9 a printing artifact's display unit runs in passes
/// (`contract.SayPass`): set when it has a `$debug`, `$fdebug` or `$fatal`,
/// the tasks that run at every iteration (`cg_say.planPasses`).
passes: bool = false,
/// §5.2.1 the calls an `analog initial` block makes: a pass performs its
/// §9.5 and `$debug`/`$fdebug` ones once per analysis, and a §9.7
/// diagnostic among them reports initialization (`cg_display.emitWhen`).
init_calls: []const Mir.Inst = &.{},
/// VerA's `vera_timepoint` (§2.9) per MIR block: the innermost statement
/// whose miss arm holds it (`Lowered.TpBlock`), or `none_u32`. Its stores
/// to an array the statement caches write the cache slot in place
/// (`instance.tpInPlace`). Empty when no slot is in place.
tp_of_block: []const u32 = &.{},
/// The full core's value → field map (`plan_core.Core.lo_idx`), which
/// `instance.tpInPlace` reads while a slice's plan is in force.
tp_lo_idx: []const u32 = &.{},

// ---- output -----------------------------------------------------------------

out: std.ArrayList(u8) = .empty,
/// Rendered text of every float constant seen, keyed on its bit pattern.
/// See `fmtF64`.
f64_cache: std.HashMapUnmanaged(u64, []const u8, F64Context, std.hash_map.default_max_load_percentage) = .empty,
/// One row per emitted top-level unit declaration, in emission order; the
/// columns become `Output.names`/`unit_lo`/`unit_fn`/`unit_hi`. Appended by
/// `file.recordUnitFile`.
files: std.MultiArrayList(gen_file.UnitFile) = .empty,
/// See `Output.prelude` / `Output.helpers`. Built by `emitFile`, which is
/// where the conditionally-emitted helper blocks are already decided.
prelude: []const u8 = "",
helpers: []const u8 = "",
/// `cg_strcap`'s memo: the capacity of each string Value asked about.
str_caps: std.AutoHashMapUnmanaged(Mir.Value, u64) = .empty,
/// `cg_strcap.heldCap` per `Lowered.held_vars` row, solved on first use.
held_caps: ?[]u64 = null,

// ---- the declaration being written ------------------------------------------

/// Reset per unit declaration; see `Decl`.
cur: Decl = .{},
/// The float mode and lane state of the body being written (`codegen/float/`).
/// `float.jac` is a device setting and `float.pinned` accumulates across
/// bodies, so it is no `Decl` field.
float: float_mode.Float = .{},
/// Distinguishes one emitted systf block's `break` label from another's.
/// Blocks nest, so the label has to be unique within a unit; it counts over
/// the whole device, which is the cheapest unique thing.
systf_sites: u32 = 0,

// ---- accumulated across declarations, for the tables emitted after ----------

/// Sticky: generation failed, even outside a unit body. Reported out so
/// callers do not have to substring-search generated text for a refusal.
any_fatal: bool = false,
/// What the shared core reads of `SimState` (`unit.scanSimReads`), written
/// out as `sim_reads`. All false when there is no core.
sim_reads: gen_unit.SimReads = .{},
/// §2.8.3/§12.32: the `$name` call sites this backend did not resolve, in
/// first-call order. Becomes `systf_calls`, so the index is the host's
/// binding index. One entry per source call (name and token), not per name:
/// §12.32.1's calltf runs for "each" invocation with
/// `vpi_handle(vpiSysTfCall, NULL)` naming that call, so the host must know
/// which call it is. A unit that renders one call twice reuses its entry.
/// Linear scan: the list is tiny.
systf_names: std.ArrayList(SystfSite) = .empty,
/// The `Instance` fields `updateState` advances, in declaration order
/// (`file.emitInstance` fills it). `stateCtl` commits each to, and reverts it
/// from, the `State` field of the same name.
hist: std.ArrayList([]const u8) = .empty,
/// §5.10 per `Lowered.mem_arrays` row: the held array `updateState` stores in
/// place and whose `<field>__dirty` range `stateCtl` copies
/// (`state.inPlaceArrays`). Set by `emitInstance`; empty when none.
held_in_place: []const bool = &.{},
/// Value → field of `limit`'s slice of the core, or `none_u32`
/// (`cg_limit.emitCore`); empty when `limit` reads nothing off the core.
lim_idx: []u32 = &.{},
/// The core as `updateState` reads it: its slice (`gen_state.emitCore`), or
/// `.{}` when `updateState` reads nothing off the core.
state_core: plan_core.Core = .{},
/// The core as `noisePsd` reads it: its slice (`gen_noise.emitNoiseCore`), or
/// `.{}` when `noisePsd` reads nothing off the core.
noise_core: plan_core.Core = .{},
/// Whether `noise_core` reads a §4.5.14 `ddx` lane, so `noisePsd` seeds its
/// inputs as `eval` does (`zProbe`) instead of value-only (#32).
noise_reads_ddx: bool = false,
/// The core as `opVars` reads it: its slice (`gen_opvars.emitOpVarCore`), or
/// `.{}` when the module has no operating-point variable to compute.
opvar_core: plan_core.Core = .{},
/// Whether `opvar_core` reads a §4.5.14 `ddx` lane, as `noise_reads_ddx`.
opvar_reads_ddx: bool = false,
/// The core as `advanceIteration` and `checkConvergence` read it: their slice
/// (`gen_state.emitIterCore`), or `.{}` when they read nothing off it.
iter_core: plan_core.Core = .{},
/// The Jacobian evidence the dispatchers and the renderer leave behind
/// (`dispatch.Jac`): patterns, written rows, lane reads and constant
/// coefficients.
jac: gen_dispatch.Jac = .{},
/// The raw mask of every real declared, for `family.emitLaneMasks`.
fam_masks: std.ArrayList([]const u64) = .empty,

/// The state of the one declaration being written. Its lifetime is one unit
/// body: `unit.emitUnit`/`emitCoreDecl` reset `uses`, `fatal` and
/// `init_arms` and re-run `plan.analyze` before each body, and the flags
/// below are set and restored around the body that needs them. `plan`'s
/// storage is allocated once (`prepare`) and reused.
pub const Decl = struct {
    /// The slice, use counts, inline decisions and slots for the declaration
    /// being written (`plan/unit.zig`). `undefined` until `prepare`.
    plan: UnitPlan = undefined,
    /// Which uniform parameters the body read (`unit.Uses`).
    uses: gen_unit.Uses = .{},
    /// `out` ranges of the final emission's `then` arms of a §5.10.2
    /// `initial_step` branch (`cfg.emitTerm`), for `unit.scanSimReads`.
    init_arms: std.ArrayList([2]usize) = .empty,
    /// Set when the unit asks for a value the LRM fixes and this backend
    /// cannot produce (§4.5's non-constant control argument, E0515; a
    /// §3.6.2.2 signal-flow contribution). The whole body collapses to one
    /// `@compileError`: a substitute would contradict the clause, and a
    /// per-statement error would bury the reason in a cascade. An
    /// unregistered system function (W0852) does not come here: the language
    /// defines no value for it, so 0.0 contradicts nothing.
    fatal: ?[]const u8 = null,
    /// Token of the §4.5 operator call whose arguments are being rendered:
    /// the fallback span for E0515 when the offending argument is a leaf with
    /// no instruction of its own (a node probe has no token).
    // ponytail: one field set at the places that render operator arguments,
    // rather than threading a token through `argF64`'s call sites. Ceiling:
    // it is only ever read on the E0515 path, which refuses the unit.
    ctrl_tok: u32 = Mir.no_tok,
    /// Token of the innermost call `emitCall` is rendering: the span
    /// `gen_call.abort` reports its refusal at.
    call_tok: u32 = Mir.no_tok,
    /// The operand of the guarded row being rendered (`Mir.guard_of`) that
    /// `renderVal` swaps for its domain's safe value when the guard is false.
    /// Set and cleared around one `renderOp` (`render.renderInst`).
    subst: ?gen_render.Subst = null,
    /// Set while the core is emitted. The core slices from every target at
    /// once and computes each value; the §9.4 display unit, the only other
    /// body, slices from one target and reads the rest.
    emitting_common: bool = false,
    /// Set while the §9.4/§9.5 display unit is emitted; read by `call.zig`'s
    /// §9.5 dispatch. A §9.5 call opens files, moves read positions and
    /// appends bytes, while `eval` must stay a pure function of x for Newton
    /// to converge. So the file kernels run only in the display unit, which
    /// `plan_core.plan` keeps out of the shared core. §9.5.9: "if a file is
    /// being written to during an iterative solve, then the file write
    /// operations shall not be performed unless the iteration is accepted."
    emitting_display: bool = false,
    /// Set while the caller owns the `core` call (`zResidual`'s `m`,
    /// `acceptQ`'s hoisted line), so `emitStamps` must not open its own.
    core_hoisted: bool = false,
    /// Set by `emitStamps` when it wanted a core call. Under `core_hoisted` it
    /// is the only record that one is needed.
    core_wanted: bool = false,
    /// The dry run that places each slot's declaration (`unit.Probe`).
    probe: gen_unit_body.Probe = .{},
    /// The surviving hoisted slots and their arrays (`unit.Hoist`).
    hoist: gen_unit_body.Hoist = .{},
};

/// One `systf_names` entry: a `$name` call, the token it was lowered from,
/// and whether it is a task (a statement) rather than a function.
pub const SystfSite = struct { name: []const u8, tok: u32, task: bool };

/// The deepest level `ind` indents to. Nesting has no bound (an `if`/`?:`
/// chain the source nests 100,000 deep is a block that deep), and indenting
/// each level further would make the text quadratic in it: 8000 nested `?:`
/// were 2.4 GB of device. Past this the lines stay at one column, so the text
/// is linear; Zig does not read indentation, and the emitted device is never
/// `zig fmt`-checked. No fixture nests this deep, so every device that fits
/// is byte-identical.
pub const max_indent: u32 = 32;

// The sub-file API the `cg_*.zig` emitters call as methods (`g.renderVal(...)`).

/// `setup.probeInstance`: the instance an auxiliary core sweep passes. May
/// write a `var table_probe` declaration to `out` first.
pub const probeInstance = gen_setup.probeInstance;
/// `setup.rootRef`: the text reading a setup root's `Model.su` field.
pub const rootRef = gen_setup.rootRef;
/// `file.emitFile`, the codegen spine. Asserts nothing was emitted yet.
pub const emitFile = gen_file.emitFile;
/// `file.fmtF64`: an f64 as Zig literal text, arena-owned and memoized.
pub const fmtF64 = gen_file.fmtF64;
/// `render.renderVal`: appends a value's Zig expression, converted to the
/// requested LRM type (§4.2.1.1/§4.2.1.2).
pub const renderVal = gen_render.renderVal;
/// `host_expr.f64Const`: plain-f64 text over `model`, or null.
pub const f64Const = gen_host.f64Const;
/// `host_expr.f64Expr`: `f64Const`, or E0515 and a poisoned unit.
pub const f64Expr = gen_host.f64Expr;
/// `call.abort`: reports a refusal at the call being rendered and poisons the
/// unit.
pub const abort = gen_call.abort;
/// `call.strArg`: the string literal at `args[i]`, or null.
pub const strArg = gen_call.strArg;

/// Hash context for `f64_cache`. The key is an f64's bit pattern, so an
/// integer mix is enough where `AutoContext` would run Wyhash over its bytes.
const F64Context = struct {
    /// Mixes the bit pattern; distinct NaN payloads stay distinct keys.
    pub fn hash(_: F64Context, k: u64) u64 {
        return std.hash.int(k);
    }
    /// Bitwise: `-0.0` and `0.0` are different keys (they render differently).
    pub fn eql(_: F64Context, x: u64, y: u64) bool {
        return x == y;
    }
};

const Gen = @This();

comptime {
    // `indWidth` multiplies by 4 in u32: the widest indent fits with room.
    assert(max_indent * 4 < std.math.maxInt(u16));
    assert(max_indent > 0);
}

/// Returns what a `plan/` function reads (`prove/input.zig`). The result
/// borrows `self`'s inputs and must not outlive them.
pub fn input(self: *const Gen) Input {
    return .{ .arena = self.arena, .mir = self.mir, .an = self.an, .lowered = self.lowered };
}

/// Fails generation (`any_fatal`) and collapses the current unit to a
/// `@compileError` naming `msg`, unless an earlier refusal already named it.
/// Asserts that `msg` is not empty.
pub fn poison(self: *Gen, msg: []const u8) void {
    assert(msg.len != 0);
    self.any_fatal = true;
    if (self.cur.fatal == null) self.cur.fatal = msg;
    assert(self.cur.fatal != null);
}

/// Appends formatted file-scaffolding text to the output.
/// Invalidates slices of `out.items` if additional memory is needed.
pub fn w(self: *Gen, comptime fmt: []const u8, args: anytype) Error!void {
    const len_before = self.out.items.len;
    try self.out.print(self.gpa, fmt, args);
    assert(self.out.items.len >= len_before);
}

/// Appends formatted body text. Same destination as `w`, since the signature
/// is back-patched (`emitUnit`); the name marks body call sites.
/// Invalidates slices of `out.items` if additional memory is needed.
pub fn b(self: *Gen, comptime fmt: []const u8, args: anytype) Error!void {
    const len_before = self.out.items.len;
    try self.out.print(self.gpa, fmt, args);
    assert(self.out.items.len >= len_before);
}

/// Returns the §5.10 trailing argument of a core call: nothing for a core
/// without held-only stores, else whether this caller keeps the held arrays'
/// end-of-block values (`updateState`, `acceptQ`) or not (`eval`/`q`).
pub fn heldArg(self: *const Gen, held: bool) []const u8 {
    if (self.core.held_only.len == 0) return "";
    // `held_only` is per Value, so it is as long as the analysis' value table.
    assert(self.core.held_only.len == self.an.nv);
    return if (held) ", true" else ", false";
}

/// Writes `n` levels of four-space indentation, at most `max_indent`.
/// Invalidates slices of `out.items` if additional memory is needed.
pub fn ind(self: *Gen, n: u32) Error!void {
    const len_before = self.out.items.len;
    try self.out.appendNTimes(self.gpa, ' ', indWidth(n));
    assert(self.out.items.len == len_before + indWidth(n));
}

/// Returns the spaces `ind(n)` writes: four per level, capped at `max_indent`.
pub fn indWidth(n: u32) u32 {
    // `@min` narrows to the comptime bound's width; widen before scaling.
    const width = @as(u32, @min(n, max_indent)) * 4;
    assert(width <= max_indent * 4);
    return width;
}

/// Returns array `id`'s storage mask: `mw` words of `arr_mask`.
/// Asserts that `id` is a `Lowered.mem_arrays` row.
pub fn arrMask(self: *const Gen, id: usize) []u64 {
    assert(id < self.arr_s.len);
    assert(self.arr_mask.len == self.arr_s.len * self.mw);
    return self.arr_mask[id * self.mw ..][0..self.mw];
}

test indWidth {
    try std.testing.expectEqual(0, indWidth(0));
    try std.testing.expectEqual(8, indWidth(2));
    // Past the cap every level writes the same width, so deep text stays linear.
    try std.testing.expectEqual(indWidth(max_indent), indWidth(std.math.maxInt(u32)));
}
