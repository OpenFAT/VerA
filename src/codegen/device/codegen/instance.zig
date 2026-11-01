//! The device's per-instance state -> §4.5 `Instance` (environment, one
//! field group per stateful operator keyed by its stable unit name, §5.6.1.2
//! path latches, §5.10 held variables, `vera_timepoint` caches and the
//! §9.7.3 status latch), its `State` twin and `stateCtl`, which commits and
//! reverts every field `updateState` advances (`Gen.hist`). Field order is
//! part of the incremental-build contract: a new operator moves no existing
//! field.
//! LRM: §2.9, §4.5, §4.5.7, §4.5.11, §4.5.12, §5.6.1.2, §5.10, §9.7.3, §9.10,
//! §9.12, §9.13.1, §9.17.1, §9.17.2, §9.21.1.
//!
//! Contents:
//! - `pub fn emitInstance(self: *Gen) Error!void`
//! - `pub fn dirtyTracked(self: *const Gen, id: u32) bool`
//! - `pub fn pathLatches(self: *const Gen) bool`
//! - `pub fn heldString(self: *const Gen) bool`
//! - `pub fn histLen(self: *const Gen, i: usize) usize`

const std = @import("std");
const assert = std.debug.assert;
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const operator_ctrl = @import("operator_ctrl.zig");
const gen_file = @import("file.zig");
const gen_state = @import("state.zig");
const gen_wide = @import("wide.zig");
const opdb = @import("op_zig.zig");
const cg_filters = @import("../cg_filters.zig");
const cg_strcap = @import("../cg_strcap.zig");
const Lowered = @import("ir").Lowered;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const gen_status = @import("status.zig");
const gen_timepoint = @import("timepoint.zig");

/// Length of the §4.5.7 absdelay history ring, in samples, of a site with no
/// constant `maxdelay`.
// ponytail: a fixed 1024 samples with linear interpolation. SPICE's
// maxstep = min(tstep, span/50) already allows td/dt = 100 steps per delay,
// and ch04_expressions/a04_05 needs 515. A ring that fills while its oldest
// sample is still inside the window is thinned (`hist_kernels.zHistThin`),
// never cut: §4.5.7 bounds no lookback, so dropping a sample the window needs
// would silently shorten the delay. The ring stays inline in `Instance` so
// value copies, `stateCtl` twins and batch lanes keep working on a GPU too.
const hist_len: usize = 1024;

/// The step a `maxdelay` site's ring is sized for: `ceil(maxdelay /
/// hist_min_step) + 2` samples, within [`hist_len`, `hist_max`]. 1 ps is
/// the step a transmission line with a 1-5 ns delay is resolved at.
const hist_min_step: f64 = 1e-12;

/// The largest ring a `maxdelay` sizes: 16384 samples, 256 KiB of
/// `Instance` per site (16.4 ns of delay at `hist_min_step`).
const hist_max: usize = 16384;

/// Shortest held array `dirtyTracked` keeps a range for (elements).
const dirty_min_len = 64;

comptime {
    assert(hist_len < hist_max);
    assert(hist_min_step > 0.0);
}

/// Emits `Instance`: environment (§9.10) plus one field group per stateful
/// §4.5 operator, keyed by the stable unit name so adding an unrelated
/// operator never renumbers existing state.
pub fn emitInstance(self: *Gen) Error!void {
    assert(self.hist.items.len == 0);
    assert(self.held_in_place.len == 0);
    self.held_in_place = try gen_state.inPlaceArrays(self);
    if (self.held_in_place.len != 0) assert(self.held_in_place.len == self.lowered.mem_arrays.items.len);
    try self.w(
        \\/// Per-instance state. The host owns every field above the operator
        \\/// block: `mfactor` (§6.3.6); the temperature is `Model.temperature__`.
        \\/// Time, step and analysis reach every entry point as `contract.SimState`.
        \\/// Every per-instance value `eval` reads lives here; what only
        \\/// `updateState` and `stateCtl` read lives in `State`.
        \\pub const Instance = struct {{
        \\    mfactor: f64 = 1.0,
        \\    /// §9.17.2 `$bound_step`: upper bound the model asks for on the
        \\    /// NEXT timestep, in seconds. `inf` = unconstrained. Written by
        \\    /// `updateState`; the host reads it after every accepted step and
        \\    /// shall ignore it outside a time-domain analysis (§9.17.2).
        \\    bound_step: f64 = std.math.inf(f64),
        \\    /// §9.17.1 `$discontinuity`: degree of the announced
        \\    /// discontinuity (0 = the equation itself, 1 = its slope, …), or
        \\    /// -1 for "none announced this step". Written by `updateState`.
        \\    discontinuity_order: i32 = -1,
        \\
    , .{});
    // §2.8.3/§12.32: only a device with a `$name` left to a VPI application
    // has a binding to hold; the slot is 8 bytes on every instance.
    if (self.lowered.uses.contains(.systf)) try self.w(
        "    /// §2.8.3/§12.32 the VPI application. Read only by a `$name`\n" ++
            "    /// this compiler could not resolve; `contract.validateHost`\n" ++
            "    /// is what keeps it non-null when `systf_calls` is not empty.\n" ++
            "    systf: ?*const contract.SystfHost = null,\n",
        .{},
    );
    // §9.17 the two fields `updateState` resets every accepted point are
    // history only where an operator moves them off the reset value; without
    // one they are the same constant before and after any revert, and their
    // `State` twins would be dead copies.
    if (writesSchedule(self, .bound_step)) try self.hist.append(self.arena, "bound_step");
    if (writesSchedule(self, .discontinuity)) try self.hist.append(self.arena, "discontinuity_order");
    if (try operator_ctrl.anyCrossLocated(self)) {
        try self.w(
            \\    /// §5.10.3.1 the earliest time inside its own tolerance box at
            \\    /// which a `cross` the accepted step found late should have
            \\    /// fired (`zCrossRetry`); `inf` = every event was in its box.
            \\    /// Written by `updateState`. The fixed-grid testbench solves a
            \\    /// point there first (VD-066); another host may ignore it.
            \\    vera_cross_retry__: f64 = std.math.inf(f64),
            \\
        , .{});
        try self.hist.append(self.arena, "vera_cross_retry__");
    }
    // §9.12 / IEEE 1364 §17.10: only a model that searches the plusargs has
    // somewhere for the host to write them.
    if (self.lowered.uses.contains(.plusargs)) try self.w(
        "    /// §9.12 the invocation's command-line arguments, in supplied order,\n" ++
            "    /// written by the host. Entries not starting with `+` are skipped.\n" ++
            "    plusargs: []const [:0]const u8 = &.{{}},\n",
        .{},
    );
    // §9.15 Table 9-28: only a model that asks has somewhere for the host to
    // write its working directory and its name for the analysis. A host that
    // cannot put a pointer here (a GPU copy) writes the `Model` indices
    // instead (`emitModel`, `contract.host_strings`).
    if (self.lowered.uses.contains(.host_strings)) try self.w(
        "    /// §9.15 `$simparam$str(\"cwd\")`: the directory the simulator was\n" ++
            "    /// started in, written by the host.\n" ++
            "    cwd: []const u8 = \"\",\n" ++
            "    /// §9.15 `$simparam$str(\"analysis_name\")`: the host's name for the\n" ++
            "    /// current analysis (\"tran1\", \"mydc\"), written before it runs.\n" ++
            "    analysis_name: []const u8 = \"\",\n",
        .{},
    );
    for (self.lowered.table_samples.items, 0..) |count, site| {
        try self.w("    table_{d}: [{d}]f64 = @splat(0.0),\n", .{ site, count });
    }
    // §9.21.1 + §9.3 (VD-095): `table_kept` marks the sites whose capture an
    // accepted point made (`updateState`, committed and reverted by
    // `stateCtl`, kept across analyses); `table_ready` the sites captured so
    // far in the current evaluation, which starts from `table_kept`.
    if (self.lowered.table_samples.items.len != 0) try self.w(
        "    table_ready: [{0d}]bool = @splat(false),\n    table_kept: [{0d}]bool = @splat(false),\n",
        .{self.lowered.table_samples.items.len},
    );
    if (self.lowered.limit_slots.items.len != 0) try self.w(
        "    limiter_previous: [{d}]f64 = @splat(0.0),\n",
        .{self.lowered.limit_slots.items.len},
    );
    // §9.13.1's "internal seed", one slot per seedless call site. The default
    // is a fixed value, not a clock read, so a run is reproducible and
    // §9.13.2's "shall always return the same value given the same seed" can
    // be checked. Distinct per site: the internal seed "gets updated every
    // time the call ... is made", so two call sites are two streams.
    if (self.lowered.rng_auto_seeds.items.len != 0) {
        try self.w(
            "    /// §9.13.1 the internal seed of each seedless `$random`/`$arandom`\n" ++
                "    /// call site. Advanced by `updateState` on the ACCEPTED step and only\n" ++
                "    /// READ by `eval`: a draw that moved between Newton iterations would\n" ++
                "    /// make the residual non-deterministic and the solve would not converge.\n" ++
                "    rng_auto: [{d}]i64 = .{{",
            .{self.lowered.rng_auto_seeds.items.len},
        );
        for (self.lowered.rng_auto_seeds.items, 0..) |seed, k| try self.w("{s}{d}", .{
            if (k == 0) "" else ", ", seed,
        });
        try self.w("}},\n", .{});
        try self.hist.append(self.arena, "rng_auto");
    }
    for (self.names.units, 0..) |u, i| {
        if (u.role != .analog_op) continue;
        const n = self.names.unit_names[i];
        // Operators whose Instance shape is fixed are a table read (op_zig.zig).
        for (opdb.get(u.op).slots) |s| {
            if (s.note.len == 0) {
                try self.w("    {s}__{s}: f64 = {s},\n", .{ n, s.suffix, s.default });
            } else {
                try self.w("    {s}__{s}: f64 = {s}, // {s}\n", .{ n, s.suffix, s.default, s.note });
            }
            try keepHist(self, "{s}__{s}", .{ n, s.suffix });
        }
        // Operators whose field count depends on the call (`shape = .from_args`).
        switch (u.op) {
            .absdelay => {
                try self.w(
                    "    {s}__t: [{d}]f64 = @splat(0.0), // §4.5.7 delay ring\n" ++
                        "    {s}__v: [{d}]f64 = @splat(0.0),\n" ++
                        "    {s}__head: u64 = 0,\n" ++
                        "    {s}__w: f64 = 0.0, // §4.5.7 the window the ring keeps (`zHistThin`)\n",
                    .{ n, histLen(self, i), n, histLen(self, i), n, n },
                );
                // The ring itself is not copied: `stateCtl` keeps the one
                // sample the next push overwrites (`emitStateCtl`).
                try keepHist(self, "{s}__head", .{n});
                // `updateState` rewrites the window, so a revert restores it.
                try keepHist(self, "{s}__w", .{n});
                // §4.5.7 the frozen td of the two-argument form. Emitted only
                // for a signal-valued td; a constant or parameter one is
                // already its own first value.
                if (try operator_ctrl.absdelayFreezes(self, self.names.opArgs(self.mir, i))) {
                    try self.w("    {s}__td: f64 = 0.0, // §4.5.7 td, frozen at the first evaluation\n", .{n});
                    try keepHist(self, "{s}__td", .{n});
                }
                if (try operator_ctrl.absdelayMaxdSampled(self, self.names.opArgs(self.mir, i))) {
                    try self.w("    {s}__maxd: f64 = 0.0, // §4.5.14 maxdelay, sampled at the start of the analysis\n", .{n});
                    try keepHist(self, "{s}__maxd", .{n});
                }
            },
            // §4.5.11/§4.5.12 direct-form-I history of the cascade: `deg`
            // past inputs and past outputs per section, newest first. The
            // shape comes from the flattened call, so it is a codegen-time
            // constant even though every coefficient is a runtime Model read.
            .laplace, .zi => {
                if (self.names.opInstOf(@intCast(i)) == null) continue;
                const p = cg_filters.planOf(self, i);
                if (p.err != null) continue;
                try self.w("    {s}__u: [{d}]f64 = @splat(0.0), // §4.5.{s}\n", .{
                    n, p.ns * p.deg, if (u.op == .zi) "12" else "11",
                });
                try self.w("    {s}__y: [{d}]f64 = @splat(0.0),\n", .{ n, p.ns * p.deg });
                try keepHist(self, "{s}__u", .{n});
                try keepHist(self, "{s}__y", .{n});
                if (p.sampled.len != 0) {
                    try self.w("    {s}__k: [{d}]f64 = @splat(0.0), // §4.5.14 coefficients, sampled at the start of the analysis\n", .{ n, p.sampled.len });
                    try keepHist(self, "{s}__k", .{n});
                }
                // §4.5.12 the filter's clock as a count of samples taken, not
                // the next sample time: `next += zn*T` drifts off the k·T grid
                // by an ulp or two (1e-9 + 1e-9 + 1e-9 > 3e-9 in f64), and a
                // timepoint under the drifted clock loses a sample for good.
                if (u.op == .zi) {
                    try self.w("    {s}__nk: f64 = 0.0, // §4.5.12 samples taken\n    {s}__out: f64 = 0.0,\n", .{ n, n });
                    try keepHist(self, "{s}__nk", .{n});
                    try keepHist(self, "{s}__out", .{n});
                    // §4.5.12 τ/t0: where the running transition starts from,
                    // and when (`zZiEvalRamp`).
                    if (p.tau != null) {
                        try self.w("    {s}__from: f64 = 0.0,\n    {s}__ts: f64 = -std.math.inf(f64),\n", .{ n, n });
                        try keepHist(self, "{s}__from", .{n});
                        try keepHist(self, "{s}__ts", .{n});
                    }
                }
            },
            // Every `.static` and `.none` row: already handled above, or
            // (§9.17) writing the two unconditional fields and no per-unit
            // one at all.
            .none, .idt_hold, .idtmod, .transition, .slew, .last_crossing, .cross, .above, .timer, .bound_step, .discontinuity => {},
        }
    }
    // §5.6.1.2 path-integrated reactive latches (ngspice NIintegrate
    // semantics): pb__k is the ddt operand at the last accepted solve, pq__k
    // the sum of committed A·ΔB increments (the charge base, fixed across one
    // Newton attempt). Zero defaults make the first committed increment A·B,
    // as ngspice MODEINITTRAN seeds qgs = capgs·vgs. `eval` reads these; their
    // staged twins, which only `updateState` and the commit touch, live in
    // `State` (`emitStateTwins`), so they cost `eval` no cache line.
    for (0..self.core.prev_lo.len) |k| {
        try self.w("    pb__{d}: f64 = 0.0, // path_prev latch\n", .{k});
    }
    for (0..self.core.acc_lo.len) |k| {
        try self.w("    pq__{d}: f64 = 0.0, // path_acc latch\n", .{k});
    }
    // §5.10 event-assigned variables. Last, so a model that gains one moves
    // no operator field. The default is the declared initializer, which only
    // the first evaluation (before any `updateState`) can observe.
    for (self.lowered.held_vars.items, 0..) |h, i| {
        // ponytail: a parameter-dependent initializer takes the parameter's
        // spec default, like every §4.5 operator control argument, because a
        // struct field default is comptime and a model card is not. Upgrade
        // path: write it in `initState`, which already takes `*Instance`.
        try self.hist.append(self.arena, self.names.held_names[i]);
        // Why it is held (`HeldVar.Why`), so a reader of the device can tell
        // a latch from retention.
        const note = try self.arena.print("// §5.10 held across evaluations: {t}", .{h.why});
        if (h.array != none_u32) {
            try emitHeldArrayField(self, h, self.names.held_names[i], note);
            if (dirtyTracked(self, h.array)) try self.w(
                "    {s}__dirty: [2]i64 = .{{ 0, {d} }}, // §5.10 elements written since the last stateCtl\n",
                .{ self.names.held_names[i], self.lowered.mem_arrays.items[h.array].len - 1 },
            );
            continue;
        }
        if (h.ty == .string) {
            // §3.3 a string's initial value is "" unless declared. Its own
            // bytes (`ZStrHeld`, #19), never a slice of a `$sformat` site's
            // `zSBuf`, which the site rewrites when it runs again.
            const s = switch (self.mir.valueDef(self.an.rv(h.init))) {
                .str_const => |s| s,
                else => "", // else: a non-literal initializer starts from §3.3's empty string, as a real starts from its spec default
            };
            // Sized for the longest text the model can hold there (`cg_strcap`).
            try self.w("    {s}: ", .{self.names.held_names[i]});
            try cg_strcap.emitHeldType(self, i);
            try self.w(" = ", .{});
            try cg_strcap.emitHeldCopy(self, i);
            try self.w("\"{f}\"), {s}\n", .{ std.zig.fmtString(s), note });
            continue;
        }
        if (h.ty == .wide) {
            // IEEE 1364 §5.4 a wide `reg`: its literal initializer's bits
            // (`gen_wide.emitConstInit`), else zero.
            try self.w("    {s}: {s} = ", .{ self.names.held_names[i], try gen_wide.zigTy(self, h.width) });
            if (!try gen_wide.emitConstInit(self, h.init)) try self.w("zwZero({d})", .{h.width});
            try self.w(", {s}\n", .{note});
            continue;
        }
        const init = self.an.foldConst(self.an.rv(h.init), true);
        const v: f64 = init orelse 0.0;
        if (h.ty == .integer) {
            try self.w("    {s}: i64 = {d}, {s}\n", .{
                // Saturating like every other fold-side real -> int cast: an
                // initializer of `1e300` must not panic the compiler.
                self.names.held_names[i], std.math.lossyCast(i64, @round(v)), note,
            });
        } else {
            try self.w("    {s}: f64 = {s}, {s}\n", .{
                self.names.held_names[i], try gen_file.fmtF64(self, v), note,
            });
        }
    }
    // A `State` with no field at all is zero-sized and comptime-known, and a
    // host that stores it beside its `Instance` (`.{ inst, st }`) can no longer
    // take its bytes: keep the §9.17 twins as its content rather than emit an
    // empty `State`.
    if (self.hist.items.len == 0 and !pathLatches(self) and self.lowered.limit_slots.items.len == 0)
        try self.hist.appendSlice(self.arena, &.{ "bound_step", "discontinuity_order" });
    if (self.hist.items.len == 0) assert(pathLatches(self) or self.lowered.limit_slots.items.len != 0);
    try gen_timepoint.emitTpFields(self);
    if (gen_status.hasStatus(self)) try self.w(
        \\    /// §9.7.3 the first `$fatal`/`$error` reported, `contract.statusSite`'s
        \\    /// code; 0 = ok. Sticky until `initState` or `setupInstance`.
        \\    vera_status__: u32 = 0,
        \\    /// The reported site's numeric arguments (`contract.formatStatus`).
        \\    vera_status_args__: [{d}]f64 = @splat(0.0),
        \\
    , .{Lowered.status_arg_max});
    try self.w("}};\n\n", .{});
    try gen_timepoint.emitTpHelpers(self);
    try gen_status.emitStatusHelpers(self);
}

/// Returns whether held array `id` keeps a `__dirty` index range: it is
/// stored in place (`Gen.held_in_place`) and long enough that `stateCtl`
/// copying only the elements written since the last commit or revert beats
/// copying it whole. Below `dirty_min_len` the per-store range update costs
/// more than the copy it saves (coupled_ltra: updateState +30% with every
/// held array tracked, `git show 6e59b3d4^:docs/measurements/device-runtime-2026-10-01.md`).
pub fn dirtyTracked(self: *const Gen, id: u32) bool {
    assert(id < self.lowered.mem_arrays.items.len);
    if (self.held_in_place.len != 0) assert(self.held_in_place.len == self.lowered.mem_arrays.items.len);
    return self.held_in_place.len != 0 and self.held_in_place[id] and
        self.lowered.mem_arrays.items[id].len >= dirty_min_len;
}

/// Returns whether the module has any path latch. Every gate on the latch
/// machinery tests this, not `acc_lo`: the reactive lowering plants prev+acc
/// pairs, but a source-level `$prev` site arrives alone and still needs its
/// updateState staging and commit advance.
pub fn pathLatches(self: *const Gen) bool {
    assert(self.core.prev_lo.len == self.core.prev_vals.len);
    assert(self.core.acc_lo.len == self.core.acc_vals.len);
    return self.core.acc_lo.len != 0 or self.core.prev_lo.len != 0;
}

/// Returns whether some §5.10 held variable is a string: its `Instance`
/// field is a `ZStrHeld`, which the string kernels define.
pub fn heldString(self: *const Gen) bool {
    assert(self.names.held_names.len == self.lowered.held_vars.items.len);
    for (self.lowered.held_vars.items) |h| {
        if (h.ty == .string) return true;
    }
    return false;
}

/// The ring length of absdelay unit `i`: `hist_len`, or, for a
/// §4.5.7 `maxdelay` that folds (its declared default when a parameter), enough
/// samples to hold that delay at `hist_min_step`, up to
/// `hist_max`. A longer window is kept by thinning (W1051).
pub fn histLen(self: *const Gen, i: usize) usize {
    assert(i < self.names.units.len);
    assert(self.names.units[i].op == .absdelay);
    const args = self.names.opArgs(self.mir, i);
    if (args.len < 3) return hist_len;
    const md = self.an.foldConst(args[2], true) orelse return hist_len;
    const want = md / hist_min_step + 2.0;
    if (!(want > @as(f64, @floatFromInt(hist_len)))) return hist_len;
    if (!(want < @as(f64, @floatFromInt(hist_max)))) return hist_max;
    const n: usize = @intFromFloat(@ceil(want));
    assert(n > hist_len);
    assert(n <= hist_max);
    return n;
}

// ---- private ----

/// Returns whether some operator's accepted-step code writes the §9.17 field
/// `which` names (`.bound_step`: `Instance.bound_step`; `.discontinuity`:
/// `Instance.discontinuity_order`) after `updateState`'s unconditional reset:
/// the operator itself, a §4.5.7 `absdelay` bounding the step at its delay,
/// or a §4.5.12 `zi` filter at its period and on each sample.
fn writesSchedule(self: *const Gen, comptime which: @import("ir").op.OpKind) bool {
    comptime assert(which == .bound_step or which == .discontinuity);
    for (self.names.units) |u| {
        if (u.role != .analog_op) continue;
        switch (u.op) {
            .zi => return true,
            .absdelay => if (which == .bound_step) return true,
            .bound_step => if (which == .bound_step) return true,
            .discontinuity => if (which == .discontinuity) return true,
            .none, .idt_hold, .idtmod, .transition, .slew, .last_crossing, .cross, .above, .timer, .laplace => {},
        }
    }
    return false;
}

/// Records `Instance` field `fmt` as history `stateCtl` commits and reverts.
fn keepHist(self: *Gen, comptime fmt: []const u8, args: anytype) Error!void {
    const len_before = self.hist.items.len;
    defer assert(self.hist.items.len <= len_before + 1);
    try self.hist.append(self.arena, try self.arena.print(fmt, args));
    assert(self.hist.items.len == len_before + 1);
}

/// Emits a §3.2.2/§5.10 held array's `Instance` field: plain values,
/// defaulting element by element to the declared initializer (§3.2's zero
/// where the pattern is silent), the spec default as for a held scalar.
fn emitHeldArrayField(self: *Gen, h: Lowered.HeldVar, name: []const u8, comment: []const u8) Error!void {
    assert(h.array != none_u32);
    assert(name.len != 0);
    assert(h.array < self.lowered.mem_arrays.items.len);
    const m = self.lowered.mem_arrays.items[h.array];
    const ty: []const u8 = if (m.ty == .integer) "i64" else "f64";
    var all_zero = true;
    for (h.inits) |iv| {
        const c = self.an.foldConst(self.an.rv(iv), true) orelse continue;
        if (c != 0.0) all_zero = false;
    }
    if (all_zero) return self.w("    {s}: [{d}]{s} = @splat(0), {s}\n", .{ name, m.len, ty, comment });
    try self.w("    {s}: [{d}]{s} = .{{", .{ name, m.len, ty });
    for (0..m.len) |k| {
        const c = if (k < h.inits.len) self.an.foldConst(self.an.rv(h.inits[k]), true) else null;
        const v: f64 = c orelse 0.0;
        if (k != 0) try self.w(", ", .{});
        if (m.ty == .integer) try self.w("{d}", .{std.math.lossyCast(i64, @round(v))}) else try self.w("{s}", .{try gen_file.fmtF64(self, v)});
    }
    try self.w(" }}, {s}\n", .{comment});
    assert(std.mem.endsWith(u8, self.out.items, "\n"));
}
