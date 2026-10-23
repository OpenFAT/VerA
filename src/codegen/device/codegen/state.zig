//! Accepted-step emission: the stateful operator calls in; `State`,
//! `initState`, `updateState`, `acceptQ`, `advanceIteration`, the collapse
//! hooks and the breakpoint hooks out. Advances each operator's `Instance`
//! slots once per accepted timepoint (§4.5.2) and emits §5.6.5 collapse.
//! LRM clauses cited: §2.9, §4.5.2, §4.5.7, §4.5.10, §4.5.12, §5.6.1.3, §5.6.5,
//! §5.10.3, §5.10.5, §9.13.1, §9.17.

const std = @import("std");
const CollapsePair = @import("plan/topology.zig").CollapsePair;
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_call = @import("call.zig");
const cg_strcap = @import("../cg_strcap.zig");
const gen_host = @import("host_expr.zig");
const gen_dispatch = @import("dispatch.zig");
const gen_file = @import("file.zig");
const gen_instance = @import("instance.zig");
const gen_setup = @import("setup.zig");
const gen_unit = @import("unit.zig");
const gen_render = @import("render.zig");
const Mir = @import("ir").Mir;
const opdb = @import("op_zig.zig");
const cg_filters = @import("../cg_filters.zig");
const assert = std.debug.assert;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const plan_args = @import("plan/args.zig");

/// What the accepted-step body needs, decided once for `updateState` and
/// `acceptQ` alike.
const Accept = struct {
    /// Some operator steps on `dt = sim.t - state.t_prev`.
    uses_dt: bool = false,
    /// Some operator input, held variable or path latch is a core field.
    uses_core: bool = false,
    /// `State.t_prev` has a reader: `dt`, or a §4.5.7 `absdelay` freezing its
    /// td at the first evaluation. Without one the field and its store are
    /// not emitted, and a path-latch-only `State` holds only the staged
    /// latch operands.
    reads_t_prev: bool = false,
};

fn scanAccept(self: *Gen) Error!Accept {
    var a: Accept = .{};
    for (self.names.units, 0..) |u, i| {
        if (u.role != .analog_op) continue;
        const k = u.op;
        a.uses_dt = a.uses_dt or opdb.get(k).needs_dt;
        if (k == .absdelay and (try gen_call.absdelayFreezes(self, self.names.opArgs(self.mir, i)) or
            try gen_call.absdelayMaxdSampled(self, self.names.opArgs(self.mir, i)))) a.reads_t_prev = true;
        if (k == .none) continue;
        a.uses_core = a.uses_core or gen_unit.opInputIdx(self, @intCast(i)) != none_u32;
    }
    for (self.core.held_idx) |k| a.uses_core = a.uses_core or k != none_u32;
    a.uses_core = a.uses_core or gen_instance.pathLatches(self);
    a.uses_core = a.uses_core or rejectStepIdx(self) != null;
    a.reads_t_prev = a.reads_t_prev or a.uses_dt;
    return a;
}

/// Returns filter unit `n`'s `__sec` call in `updateState`'s frame. A filter
/// with §4.5.14 sampled coefficients first gets their latch: "the value of
/// the dynamic expression at the start of the analysis", taken at the static
/// point (`dt`, the step its kernel tests for one) and read after it.
fn secStep(self: *Gen, n: []const u8, p: cg_filters.FilterPlan, dt: []const u8) Error![]const u8 {
    if (p.sampled.len == 0) return self.arena.print("{s}__sec(model)", .{n});
    try self.w("        if (!({s} > 0.0)) inst.{s}__k = .{{ ", .{ dt, n });
    for (p.sampled, 0..) |v, j| {
        if (j != 0) try self.w(", ", .{});
        try self.w("{s}", .{try gen_call.ctrlStep(self, &.{v}, 0, "0.0")});
    }
    try self.w(" }};\n", .{});
    return self.arena.print("{s}__sec(model, inst.{s}__k)", .{ n, n });
}

/// The core field of VerA's `$vera_reject_step` retry time, in `self.core`.
fn rejectStepIdx(self: *const Gen) ?u32 {
    if (self.lowered.reject_step == .undef) return null;
    return gen_dispatch.coreIdx(self, self.an.rv(self.lowered.reject_step));
}

/// Emits `<core>__state`, the core's slice computing only what `updateState`
/// reads: the path-latch operands, every stateful operator's arguments the
/// core carries, and the held values. Called from `emitUnits`, so its range
/// tiles with the other unit declarations.
pub fn emitCore(self: *Gen) Error!void {
    if (!(try scanAccept(self)).uses_core) return;
    const keep = try self.arena.alloc(bool, self.core.lo_vals.len);
    @memset(keep, false);
    for (self.core.prev_lo) |k| keep[k] = true;
    for (self.core.acc_lo) |k| keep[k] = true;
    for (self.core.held_idx) |k| if (k != none_u32) {
        keep[k] = true;
    };
    if (rejectStepIdx(self)) |k| keep[k] = true;
    for (self.names.units, 0..) |u, i| {
        if (u.role != .analog_op or u.op == .none) continue;
        const inst = self.names.opInstOf(@intCast(i)) orelse continue;
        for (self.mir.instData(inst).call.args) |a| {
            const k = self.core.lo_idx[@backingInt(self.an.rv(a))];
            if (k != none_u32) keep[k] = true;
        }
        if (self.lowered.timer_controls.get(inst)) |latest| for (latest) |a| {
            const k = self.core.lo_idx[@backingInt(self.an.rv(a))];
            if (k != none_u32) keep[k] = true;
        };
    }
    self.core.in_place = self.held_in_place;
    defer self.core.in_place = &.{};
    self.state_core = try gen_unit.sliceCore(self, "state", keep,
        \\/// §4.5.2 what `updateState` reads off the core, and only what that
        \\/// reads: the accepted point's operator inputs, latches and held values.
        \\
    );
}

/// §5.10 the copy-on-write held arrays (`render.cow`) the `updateState` slice
/// may write in place. `updateState` stores every held value back
/// unconditionally, so storing into the `Instance` field as the block runs
/// leaves the same end state as copying it into a local on the first store,
/// returning it and storing it back, without those three whole-array copies
/// (txl's 5 x 2048 history: updateState 19.4k -> 0.2k cycles, bit-exact,
/// `git show 6e59b3d4^:docs/measurements/device-runtime-2026-10-01.md`). Loads already read through
/// `p<id>`, and a load never reads a version past a later store
/// (`plan/unit.zig`), so every load sees the same value either way. Not when
/// the slice runs on a §9.21.1 `table_probe` copy of the instance
/// (`setup.probeInstance`). An array a `vera_timepoint` cache re-points at
/// its `tp` slot qualifies only when the slot is in place
/// (`instance.tpInPlace`): the statement's join then copies a cached version
/// back into the field (`zTpHeld`), so later stores write the field (#82).
/// Empty when no array qualifies.
pub fn inPlaceArrays(self: *Gen) Error![]const bool {
    if (self.lowered.table_samples.items.len != 0) return &.{};
    const n = self.lowered.mem_arrays.items.len;
    const flags = try self.arena.alloc(bool, n);
    for (flags, 0..) |*f, id| f.* = gen_render.cow(self, @intCast(id));
    for (0..self.mir.insts.len) |ii| {
        const inst: Mir.Inst = @fromBackingInt(@intCast(ii));
        if (self.mir.instOp(inst) != .anew) continue;
        const d = self.mir.instData(inst).anew;
        const tp = d.tp orelse continue;
        if (!gen_instance.tpInPlace(self, self.lowered.timepoints.items[tp.block].slots[tp.slot])) flags[d.array] = false;
    }
    if (std.mem.findScalar(bool, flags, true) == null) return &.{};
    return flags;
}

/// Returns whether `text` reads a field of the core result `m` (`m.f<k>`).
fn readsM(text: []const u8) bool {
    var at: usize = 0;
    while (std.mem.findPos(u8, text, at, "m.f")) |i| : (at = i + 1) {
        if (i == 0 or !(std.ascii.isAlphanumeric(text[i - 1]) or text[i - 1] == '_')) return true;
    }
    return false;
}

/// Emits `<core>__iter`, the core's slice computing only the §9.17.3
/// limiter values `advanceIteration` stores once per Newton iterate.
pub fn emitIterCore(self: *Gen) Error!void {
    const keep = try self.arena.alloc(bool, self.core.lo_vals.len);
    @memset(keep, false);
    var any = false;
    for (self.lowered.limit_slots.items) |slot| if (gen_dispatch.coreIdx(self, self.an.rv(slot.final))) |k| {
        keep[k] = true;
        any = true;
    };
    if (!any) return;
    self.iter_core = try gen_unit.sliceCore(self, "iter", keep,
        \\/// §9.17 what the per-iterate hooks read off the core, and only what
        \\/// that reads.
        \\
    );
}

/// Writes `State`, `initState`, `updateState`, `state_class`, `stateCtl`,
/// `advanceIteration` and `acceptQ`. Operator history lives in `Instance`
/// (eval reads it); `State` carries the contract's bookkeeping and the
/// accepted copies, which `eval` never reads.
pub fn emitStateMachine(self: *Gen) Error!void {
    const acc = try scanAccept(self);
    const uses_core = acc.uses_core;
    try self.w(
        \\const z_inst0: Instance = .{{}};
        \\
        \\/// §4.5.2 accepted-step bookkeeping for the analog operators, and
        \\/// `stateCtl`'s accepted copy of the history `updateState` advances.
        \\/// One per instance, beside its `Instance`; `eval`, `q` and `evalQ`
        \\/// never read it, so it is the cold half of the instance's state.
        \\pub const State = struct {{
        \\
    , .{});
    if (acc.reads_t_prev) try self.w("    t_prev: f64 = 0.0,\n", .{});
    if (self.lowered.limit_slots.items.len != 0) try self.w(
        "    limiter_previous: [{d}]f64 = @splat(0.0),\n",
        .{self.lowered.limit_slots.items.len},
    );
    try gen_instance.emitStateTwins(self, acc.reads_t_prev);
    // VerA's `vera_timepoint` (§2.9): a fresh state is a fresh cache. A
    // dirty-tracked held array (`instance.dirtyTracked`): the fresh `State`
    // differs from `inst` anywhere, so its range is the whole array.
    var dirty = false;
    for (self.lowered.held_vars.items) |h| dirty = dirty or (h.array != none_u32 and gen_instance.dirtyTracked(self, h.array));
    const tp = self.lowered.timepoints.items.len != 0;
    const restart = self.hist.items.len + self.core.prev_lo.len + self.core.acc_lo.len != 0;
    try self.w(
        \\}};
        \\
        \\/// Returns an instance's first `State`: once per instance before its
        \\/// first solve, and again to restart its history from the defaults.
        \\/// §4.6.2 "Variables shall be re-initialized to zero ... at the start
        \\/// of each new analysis": so does every field `updateState` advances.
        \\pub fn initState(_: *const Model, {s}: *Instance) State {{
        \\
    , .{if (tp or dirty or restart or gen_instance.hasStatus(self)) "inst" else "_"});
    for (self.hist.items) |h| try self.w("    inst.{s} = z_inst0.{s};\n", .{ h, h });
    for (0..self.core.prev_lo.len) |k| try self.w("    inst.pb__{d} = z_inst0.pb__{d};\n", .{ k, k });
    for (0..self.core.acc_lo.len) |k| try self.w("    inst.pq__{d} = z_inst0.pq__{d};\n", .{ k, k });
    // The §4.5.7 ring is not `hist` (only its head is), but a new analysis
    // starts it empty too.
    for (self.names.units, self.names.unit_names) |u, n| if (u.role == .analog_op and u.op == .absdelay)
        try self.w("    inst.{0s}__t = z_inst0.{0s}__t;\n    inst.{0s}__v = z_inst0.{0s}__v;\n", .{n});
    if (tp) try self.w("    zTpDrop(inst);\n", .{});
    if (gen_instance.hasStatus(self)) try self.w(gen_instance.status_drop, .{});
    for (self.lowered.held_vars.items, self.names.held_names) |h, n| {
        if (h.array == none_u32 or !gen_instance.dirtyTracked(self, h.array)) continue;
        try self.w("    inst.{s}__dirty = .{{ 0, {d} }};\n", .{ n, self.lowered.mem_arrays.items[h.array].len - 1 });
    }
    try self.w(
        \\    return .{{}};
        \\}}
        \\
        \\/// §4.5.2 the accepted-point pass at the solution `x`: advances every
        \\/// operator's history and writes the §5.10 held variables into `inst`,
        \\/// and stages the §5.6.1.2 path latches in `state`. Only here: a write
        \\/// from `eval` would latch a Newton iterate the solver may discard.
        \\/// The host then calls `stateCtl(.commit)`, or `.revert` to reject
        \\/// the step.
        \\pub fn updateState(comptime
    , .{});
    // Each goes unread when the only accepted-step work is §9.13.1's
    // internal-seed advance, a function of the seed alone.
    const at_s = self.out.items.len + 1;
    try self.w(" S: type, ", .{});
    const at_model = self.out.items.len;
    try self.w("model: *const Model, inst: *Instance, ", .{});
    const at_x = self.out.items.len;
    try self.w("x: [n_u]f64, ", .{});
    const at_state = self.out.items.len;
    try self.w("state: *State, ", .{});
    const at_sim = self.out.items.len;
    try self.w("sim: contract.SimState) contract.UpdateResult {{\n", .{});
    const body = self.out.items.len;
    // §9.7.3 a latched status: the device stopped, so its state stays put.
    if (gen_instance.hasStatus(self)) try self.w("    if (inst.vera_status__ != 0) return .ok;\n", .{});
    // §9.21.1 + §9.3 (VD-095): a `$table_model` capture becomes the
    // instance's at an accepted point. The core runs once more at `x`; each
    // first call it makes captures, and those are kept. Every evaluation
    // starts from `table_kept` (`unit.tableReset`), so a capture made by an
    // iterate the host discards, or by a step it rejects, leaves nothing.
    // ponytail: one extra core evaluation per accepted point while a site is
    // uncaptured, every point for a site never called; a per-site flag the
    // core returns is the upgrade if a model measures it.
    if (self.lowered.table_samples.items.len != 0 and self.core.lo_vals.len != 0) try self.w(
        \\    if (std.mem.findScalar(bool, &inst.table_kept, false) != null) {{
        \\        _ = {s}(S, zVals(S, &x), model, inst, sim{s});
        \\        inst.table_kept = inst.table_ready;
        \\    }}
        \\
    , .{ self.core.name, self.heldArg(false) });
    // One slice evaluation serves every operator's input.
    const full = self.core;
    var at_m: ?usize = null;
    if (uses_core) {
        self.core = self.state_core;
        at_m = self.out.items.len + "    ".len;
        try self.w("    const m = {s}(S, zVals(S, &x), model, {s}, sim{s});\n", .{ self.core.name, try gen_setup.probeInstance(self), self.heldArg(true) });
    }
    const after_m = self.out.items.len;
    try emitAcceptBody(self, acc);
    // VerA's `$vera_reject_step`: in a transient, a retry time before this
    // point rejects it. A static solve has no step to shorten.
    if (rejectStepIdx(self)) |k| try self.w(
        \\    {{
        \\        const retry = m.f{d}.val();
        \\        if (sim.kind == .tran and retry < sim.t) return .{{ .request_reject_at = retry }};
        \\    }}
        \\
    , .{k});
    // A slice whose only work is in-place held arrays (`plan.Core.in_place`)
    // leaves `m` unread: the call stays, for its stores.
    if (at_m) |at| if (!readsM(self.out.items[after_m..]))
        self.out.replaceRangeAssumeCapacity(at, "const m = ".len, "_ = ");
    self.core = full;
    gen_unit.patchUnless(self, at_s, body, "S");
    gen_unit.patchUnless(self, at_model, body, "model");
    gen_unit.patchUnless(self, at_x, body, "x");
    gen_unit.patchUnless(self, at_state, body, "state");
    gen_unit.patchUnless(self, at_sim, body, "sim");
    try self.w(
        \\    return .ok;
        \\}}
        \\
        \\
    , .{});
    try emitStateClass(self);
    try gen_instance.emitStateCtl(self, acc.reads_t_prev);
    try emitAdvanceIteration(self);
    try emitAcceptQ(self, acc);
}

/// Writes `contract.StateClass`: `.path_latch` when the state is the §5.6.1.2
/// latches alone (no operator history, held variable or §9.13.1 seed),
/// `.history` otherwise.
fn emitStateClass(self: *Gen) Error!void {
    const latch_only = gen_instance.pathLatches(self) and !gen_file.hasStatefulOps(self) and
        self.lowered.rng_auto_seeds.items.len == 0;
    try self.w("/// What `updateState` carries across accepted points (`contract.StateClass`).\npub const state_class: contract.StateClass = .{s};\n\n", .{
        if (latch_only) "path_latch" else "history",
    });
}

/// Writes `acceptQ`: the accepted-point `q` and `updateState` work from one
/// hoisted `core` call (§5.6.1.2, §4.5.2). Emitted only for a device with a
/// reactive half.
fn emitAcceptQ(self: *Gen, acc: Accept) Error!void {
    if (!gen_dispatch.anyQ(self)) return;
    // It returns the charges, so it has no way to carry a
    // `$vera_reject_step` request: such a host calls `q` and `updateState`.
    if (self.lowered.reject_step != .undef) return;
    // §9.7.3 a latched status leaves the state alone, which `updateState`
    // checks first; a status device calls `q` and `updateState`.
    if (gen_instance.hasStatus(self)) return;
    // §9.21.1 (VD-095) `updateState` keeps a table capture from its own core
    // run; a table device's host calls `q` and `updateState`.
    if (self.lowered.table_samples.items.len != 0) return;
    self.uses.x = false;
    self.uses.model = false;
    self.uses.inst = true; // the §9.17 resets below always write it
    self.core_wanted = false;
    self.core_hoisted = true;
    defer self.core_hoisted = false;
    try self.w(
        \\/// §5.6.1.2 + §4.5.2 the accepted-point pass from ONE core evaluation.
        \\/// Returns `q(S, x, model, inst, sim)` and then does what
        \\/// `updateState(S, model, inst, x.*, state, sim)` does, reading the
        \\/// same core result.
        \\
    , .{});
    try self.w("pub fn acceptQ(comptime S: type, ", .{});
    const at_x = self.out.items.len;
    try self.w("x: *const [n_u]S.V, ", .{});
    const at_model = self.out.items.len;
    try self.w("model: *const Model, inst: *Instance, {s}: *State, sim: contract.SimState) contract.Sites(Self, S) {{\n", .{
        if (acc.reads_t_prev or gen_instance.pathLatches(self)) "state" else "_",
    });
    const at_core = self.out.items.len;
    // §5.6.1.2 the charges, one per site (`q`'s layout).
    self.core_wanted = true;
    try self.b("    const qq = ", .{});
    try gen_dispatch.writeSites(self);
    try self.b(";\n", .{});
    try emitAcceptBody(self, acc);
    try self.w("    return qq;\n}}\n\n", .{});
    if (self.core_wanted or acc.uses_core) {
        self.uses.x = true;
        self.uses.model = true;
        try self.out.insertSlice(self.gpa, at_core, try self.arena.print("    const m = @call(.always_inline, core, .{{ S, zProbe(S, x), model, inst, sim{s} }});\n", .{self.heldArg(true)}));
    }
    if (!self.uses.x) gen_unit.patchParam(self, at_x, "x".len);
    if (!self.uses.model) gen_unit.patchParam(self, at_model, "model".len);
}

/// Writes the accepted-step body shared by `updateState` and `acceptQ`:
/// stages the path latches, advances every operator, writes the held
/// variables back. The emitted code reads the core result `m`.
fn emitAcceptBody(self: *Gen, acc: Accept) Error!void {
    const val = ".val()";
    const uses_dt = acc.uses_dt;
    // VerA's `vera_timepoint` (§2.9): the held values below move, and a
    // static solve iterates again at the same time when asked to.
    if (self.lowered.timepoints.items.len != 0) try self.w("    zTpDrop(inst);\n", .{});
    // §5.6.1.2 stage the path-latch operands. They commit only at
    // stateCtl(.commit), so a rejected attempt leaves pb/pq untouched and
    // the retry reopens on the accepted charge.
    for (self.core.prev_lo, 0..) |lo, k| {
        try self.w("    state.wb__{d} = m.f{d}{s}; // path_prev staging\n", .{ k, lo, val });
    }
    for (self.core.acc_lo, 0..) |lo, k| {
        try self.w("    state.wq__{d} = m.f{d}{s}; // path_acc staging\n", .{ k, lo, val });
    }
    if (uses_dt) try self.w("    const dt = sim.t - state.t_prev;\n", .{});
    // §9.17 reset first, unconditionally: a `$bound_step` that fired on one
    // arm last step must not keep bounding this one.
    try self.w(
        \\    inst.bound_step = std.math.inf(f64); // §9.17.2
        \\    inst.discontinuity_order = -1; // §9.17.1
        \\
    , .{});
    if (try gen_call.anyCrossLocated(self)) try self.w("    inst.vera_cross_retry__ = std.math.inf(f64); // §5.10.3.1\n", .{});
    // §9.13.1 the internal seed advances only here, once per accepted point,
    // so the residual it feeds is fixed across the Newton loop.
    if (self.lowered.rng_auto_seeds.items.len != 0) try self.w(
        \\    // §9.13.1 "this internal seed gets updated every time the call
        \\    // to $arandom is made" — once per ACCEPTED point, per call site.
        \\    for (&inst.rng_auto) |*rs| rs.* = @intFromFloat(zRngNext(rs.*));
        \\
    , .{});
    for (self.names.units, 0..) |u, i| {
        const k = u.op;
        if (u.role != .analog_op or k == .none) continue;
        const n = self.names.unit_names[i];
        const inst = self.names.opInstOf(@intCast(i)) orelse continue;
        self.ctrl_tok = self.mir.instTok(inst); // E0515's fallback span
        const original_args = self.mir.instData(inst).call.args;
        const latest = self.lowered.timer_controls.get(inst);
        const args: []const Mir.Value = if (latest) |*v| v else original_args;
        const lo = gen_unit.opInputIdx(self, @intCast(i));
        if (latest != null) {
            try self.w("    {{\n        const in = {s};\n", .{try gen_call.ctrlStep(self, args, 0, "0.0")});
        } else if (lo == none_u32) {
            try self.w("    {{\n        const in: f64 = 0.0;\n", .{});
        } else {
            try self.w("    {{\n        const in = m.f{d}{s};\n", .{ lo, val });
        }
        switch (k) {
            // §4.5.4 "Once assert becomes zero, idt() returns the integral
            // of the argument starting from the last instant where assert
            // was nonzero": the row holds s still while assert is nonzero,
            // and the offset latched then makes the value ic(ta) + ∫ from ta.
            .idt_hold => try self.w("        if (({s}) != 0.0) inst.{s}__off = in - ({s});\n", .{
                try gen_call.ctrlStep(self, args, 2, "0.0"), n, try gen_call.ctrlStep(self, args, 1, "0.0"),
            }),
            .idtmod => try self.w("        inst.{s}__acc = zWrap(zIdtAcc(in, inst.{s}__acc, dt, {s}), {s}, {s});\n", .{
                n,                                           n,
                try gen_call.ctrlStep(self, args, 1, "0.0"), try gen_call.ctrlStep(self, args, 2, "0.0"),
                try gen_call.ctrlStep(self, args, 3, "0.0"),
            }),
            .absdelay => {
                // §4.5.7 a full ring keeps its window (`zHistThin`); a revert
                // undoes a thinning push (`zHistRevert`).
                try self.w("        zHistThin(\"{s}.{s}\", &inst.{s}__t, &inst.{s}__v, &inst.{s}__head, sim.t, inst.{s}__w);\n", .{ self.mir.name, n, n, n, n, n });
                try self.w("        zHistPush(&inst.{s}__t, &inst.{s}__v, &inst.{s}__head, sim.t, in);\n", .{ n, n, n });
                // §4.5.7 the window a full ring keeps (`zHistThin`): maxdelay
                // bounds every lookback; without one, td is the lookback.
                try self.w("        inst.{s}__w = {s};\n", .{ n, if (args.len >= 3)
                    (if (try gen_call.absdelayMaxdSampled(self, args))
                        try self.arena.print("inst.{s}__maxd", .{n})
                    else
                        try gen_host.argF64(self, args, 2, "0.0"))
                else
                    try gen_call.absdelayTd(self, n, args, true) });
                // §4.5.7 "the value of td when the absdelay() is first
                // evaluated shall be used": the static point is that first
                // evaluation, and `zAbsdelay` passes its input through there.
                if (try gen_call.absdelayFreezes(self, args)) try self.w(
                    "        if (sim.t <= state.t_prev) inst.{s}__td = {s};\n",
                    .{ n, try gen_call.ctrlStep(self, args, 1, "0.0") },
                );
                // §4.5.14 a dynamic maxdelay: its value at the start of the
                // analysis, latched at the same first evaluation.
                if (try gen_call.absdelayMaxdSampled(self, args)) try self.w(
                    "        if (sim.t <= state.t_prev) inst.{s}__maxd = {s};\n",
                    .{ n, try gen_call.ctrlStep(self, args, 2, "0.0") },
                );
                // §9.17.2 bound the step at td, as the §4.5.12 filter does
                // with its period: a wider step flattens the delay and the
                // ring records nothing finer than the steps taken. `td` may
                // be a model expression, so the bound is computed at run
                // time; only a positive one binds, since 0 would stop time.
                try self.w(
                    "        const zad_td = {s};\n        if (zad_td > 0.0) inst.bound_step = @min(inst.bound_step, zad_td);\n",
                    .{try gen_call.absdelayTd(self, n, args, true)},
                );
            },
            .transition => {
                const t = try gen_call.transitionTimes(self, args);
                try self.w(
                    "        zTransStep(in, &inst.{0s}__from, &inst.{0s}__to, &inst.{0s}__t0, " ++
                        "sim.t, dt, {1s}, {2s}, {3s});\n",
                    .{ n, try gen_host.argF64(self, args, 1, "0.0"), t[0], t[1] },
                );
            },
            .slew => {
                const r = try gen_call.slewRates(self, args);
                try self.w("        inst.{s}__prev = zSlew(zL(S, 0), zL(S, 0).con(in), inst.{s}__prev, dt, {s}, @abs({s})).val();\n", .{
                    n, n, r[0], r[1],
                });
            },
            // §4.5.10 `last_crossing(expr, direction)`: the direction is
            // decoded as §5.10.3 `cross`'s is (+1 rising, -1 falling, 0
            // either). `dt > 0.0` is the seeding rule: `__prev` starts at
            // 0.0, a value the signal never had, so the DC point (dt = 0)
            // only seeds the history. Otherwise a signal at -1 V would read
            // as a crossing at t = 0, not the "negative value" §4.5.10
            // requires before the first real crossing. The time is
            // `lastCrossTime`, the value `eval` already answered with at this
            // point, so the latch never moves it by a rounding.
            .last_crossing => try self.w(
                \\        if (dt > 0.0 and ({1s})) inst.{0s}__t_last = {2s};
                \\        inst.{0s}__prev = in;
                \\
            , .{ n, try gen_call.crossTest(self, n, args, "in"), try gen_call.lastCrossTime(self, n, "in") }),
            // §5.10.3 only the history moves here; `eval` raises the event,
            // so nothing is observed one timepoint late. `enable` gates the
            // event, not the record, so a re-enabled operator never compares
            // against a stale sample.
            // §5.10.3.1 a `cross` with its own tolerance box also says where
            // an event this point found outside the box should have fired,
            // read against `__prev` before it moves.
            .cross, .above => {
                if (k == .cross and try gen_call.crossLocated(self, args)) try self.w(
                    \\        if (sim.kind == .tran and sim.dt > 0.0 and ({1s})) if (zCrossRetry(inst.{0s}__prev, in, sim.t, sim.dt, {2s}, {3s})) |r| {{
                    \\            inst.vera_cross_retry__ = @min(inst.vera_cross_retry__, r);
                    \\        }};
                    \\
                , .{
                    n,
                    try gen_call.crossTest(self, n, args, "in"),
                    try gen_call.ctrlStep(self, args, 2, "0.0"),
                    try gen_call.ctrlStep(self, args, 3, "0.0"),
                });
                try self.w("        inst.{s}__prev = in;\n", .{n});
            },
            // §5.10.3.3 the latest start and period define the absolute grid,
            // including changes BETWEEN fires. Count rather than accumulate,
            // advancing even while enable suppresses delivery.
            .timer => try self.w(
                \\        const period = {1s};
                \\        inst.{0s}__start = in;
                \\        inst.{0s}__per = period;
                \\        inst.{0s}__next = zNextTimer(in, period, sim.t) orelse z_inf;
                \\
            , .{ n, try gen_call.timerPeriod(self, args) }),
            // §9.17.2 "no larger than the smallest $bound_step() argument
            // currently active". `in` is already the minimum over every
            // executed `$bound_step` (lowering accumulates it); `@min` folds
            // it with the §4.5.12 sampling periods written earlier.
            .bound_step => try self.w("        inst.bound_step = @min(inst.bound_step, in);\n", .{}),
            // §9.17.1 `inf` means no announcement. `lossyCast` saturates a
            // huge degree instead of UB in a ReleaseFast artifact.
            .discontinuity => try self.w(
                "        inst.discontinuity_order = if (std.math.isFinite(in)) std.math.lossyCast(i32, in) else -1;\n",
                .{},
            ),
            // §4.5.11 advance the cascade on the accepted solution.
            .laplace => {
                const p = cg_filters.planOf(self, i);
                if (p.err == null) try self.w(
                    "        zLaplaceStep({d}, {d}, in, {s}, dt, &inst.{s}__u, &inst.{s}__y);\n",
                    .{ p.ns, p.deg, try secStep(self, n, p, "dt"), n, n },
                );
            },
            // §4.5.12 the filter runs on its own timebase: sample when the
            // accepted time reaches the next multiple of T, hold between.
            // The step bound keeps the solver from stepping over a sample.
            .zi => {
                const p = cg_filters.planOf(self, i);
                const sec = if (p.err == null) try secStep(self, n, p, "sim.dt") else "";
                // §4.5.12 τ/t0: the samples fall on t0 + k·T, and each starts a
                // τ-long transition from wherever the previous one had reached
                // (`zZiRamp`). Before a positive t0 the output holds the
                // operating point's value, H(1)·in. The step bound keeps the
                // solver inside a transition as well as between samples.
                if (p.err == null and p.tau != null) try self.w(
                    \\        const period = {1s};
                    \\        const zi_t0: f64 = {4s};
                    \\        const zi_tau: f64 = {5s};
                    \\        if (!(sim.dt > 0.0) and inst.{0s}__nk == 0.0 and zi_t0 > 0.0) {{
                    \\            inst.{0s}__out = in * zZiGain({2d}, {3d}, {6s});
                    \\            inst.{0s}__from = inst.{0s}__out;
                    \\        }}
                    \\        var zi_k = zZiDue(sim.t - zi_t0, inst.{0s}__nk, period);
                    \\        if (zi_k > 0) {{
                    \\            const zi_ts = zi_t0 + (inst.{0s}__nk + @as(f64, @floatFromInt(zi_k)) - 1.0) * period;
                    \\            inst.{0s}__from = zZiRamp(inst.{0s}__from, inst.{0s}__out, inst.{0s}__ts, zi_tau, zi_ts);
                    \\            inst.{0s}__ts = zi_ts;
                    \\            inst.{0s}__nk += @as(f64, @floatFromInt(zi_k));
                    \\            while (zi_k > 0) : (zi_k -= 1)
                    \\                inst.{0s}__out = zZiStep({2d}, {3d}, in, {6s}, &inst.{0s}__u, &inst.{0s}__y);
                    \\            // §9.17.1: a step in value, or with τ > 0 a corner in slope.
                    \\            const zi_order: i32 = if (zi_tau > 0.0) 1 else 0;
                    \\            if (inst.discontinuity_order < 0 or inst.discontinuity_order > zi_order) inst.discontinuity_order = zi_order;
                    \\        }}
                    \\        inst.bound_step = @min(inst.bound_step, period);
                    \\        if (zi_tau > 0.0) inst.bound_step = @min(inst.bound_step, zi_tau);
                    \\
                , .{ n, p.period orelse "0.0", p.ns, p.deg, p.t0.?, p.tau.?, sec }) else if (p.err == null) try self.w(
                    \\        const period = {1s};
                    \\        // §4.5.12: "T specifies the sampling period of the filter".
                    \\        // The recurrence runs once per T of SIMULATED TIME, so a step that
                    \\        // crosses k sample instants runs it k times. Stepping it ONCE per
                    \\        // evaluation — which is what this did — makes the output a function
                    \\        // of how densely the host happened to place its timepoints, and the
                    \\        // same filter at the same T returned bit-identical values for 20 us
                    \\        // and 200 us of elapsed time.
                    \\        //
                    \\        // `zZiDue` counts off the k*T GRID, and `eval` calls the identical
                    \\        // function: the two halves of the operator cannot disagree about
                    \\        // which timepoint is a sample instant. A `__next` time re-armed by
                    \\        // `+= zn*T` could and did — three additions of 1e-9 overshoot the
                    \\        // double nearest 3e-9, and the sample at t = 3T was lost for good.
                    \\        var zi_k = zZiDue(sim.t, inst.{0s}__nk, period);
                    \\        if (zi_k > 0) {{
                    \\            inst.{0s}__nk += @as(f64, @floatFromInt(zi_k));
                    \\            while (zi_k > 0) : (zi_k -= 1)
                    \\                inst.{0s}__out = zZiStep({2d}, {3d}, in, {4s}, &inst.{0s}__u, &inst.{0s}__y);
                    \\            inst.discontinuity_order = 0; // §9.17.1 the held output steps
                    \\        }}
                    \\        inst.bound_step = @min(inst.bound_step, period);
                    \\
                , .{ n, p.period orelse "0.0", p.ns, p.deg, sec });
            },
            .none => {},
        }
        try self.w("    }}\n", .{});
    }
    // §5.10 store every held variable back, only here: writing from `eval`
    // would latch a Newton iterate the solver may discard.
    //
    // A string's new text may be a slice of another held string's field
    // (`b = a; a = "x";` in one event body), so every string is copied out
    // before any is stored (#19).
    for (self.lowered.held_vars.items, 0..) |h, i| {
        const k = self.core.held_idx[i];
        if (h.ty == .string and h.array == none_u32 and k != none_u32) {
            try self.w("    const zs{d} = ", .{i});
            try cg_strcap.emitHeldCopy(self, i);
            try self.w("m.f{d});\n", .{k});
        }
    }
    for (self.lowered.held_vars.items, 0..) |h, i| {
        const k = self.core.held_idx[i];
        const n = self.names.held_names[i];
        if (k == none_u32) {
            // Folded away: never assigned outside the §5.10 body, whose
            // value is a literal zero.
            if (h.ty == .wide)
                try self.w("    inst.{s} = zwZero({d});\n", .{ n, h.width })
            else
                try self.w("    inst.{s} = 0;\n", .{n});
        } else if (h.array != none_u32) {
            // §3.2.2 a held array's core field is already its plain values;
            // an in-place one is already in `inst`.
            if (gen_render.inPlace(self, h.array)) continue;
            try self.w("    inst.{s} = m.f{d};\n", .{ n, k });
            if (gen_instance.dirtyTracked(self, h.array))
                try self.w("    inst.{s}__dirty = .{{ 0, {d} }};\n", .{ n, self.lowered.mem_arrays.items[h.array].len - 1 });
        } else {
            // The core field is typed by `vty`, not the declared type, and
            // the two can disagree (a join left at `.real`). The declared
            // type picks the destination, with the §4.2.1 conversion.
            const core_int = self.an.tyOf(self.core.lo_vals[k]) == .int;
            switch (h.ty) {
                .integer => if (core_int)
                    try self.w("    inst.{s} = m.f{d};\n", .{ n, k })
                else
                    try self.w("    inst.{s} = std.math.lossyCast(i64, @round(m.f{d}{s}));\n", .{ n, k, val }),
                .string => try self.w("    inst.{s} = zs{d};\n", .{ n, i }),
                .wide => try self.w("    inst.{s} = m.f{d};\n", .{ n, k }),
                .real => if (core_int)
                    try self.w("    inst.{s} = @floatFromInt(m.f{d});\n", .{ n, k })
                else
                    try self.w("    inst.{s} = m.f{d}{s};\n", .{ n, k, val }),
            }
        }
    }
    if (acc.reads_t_prev) try self.w("    state.t_prev = sim.t;\n", .{});
}

/// Writes `advanceIteration` (the host calls it after each Newton iterate,
/// with that iterate's x).
fn emitAdvanceIteration(self: *Gen) Error!void {
    if (self.lowered.limit_slots.items.len == 0) return;
    const full = self.core;
    defer self.core = full;
    if (self.iter_core.lo_vals.len != 0) self.core = self.iter_core;
    var uses_core = false;
    for (self.lowered.limit_slots.items) |slot| uses_core = uses_core or gen_dispatch.coreIdx(self, self.an.rv(slot.final)) != null;
    // `inst` is always named: every limiter slot is stored into it.
    try self.w("pub fn advanceIteration(comptime {s}: type, {s}: *const Model, inst: *Instance, {s}: [n_u]f64, {s}: contract.SimState) void {{\n", .{
        if (uses_core) "S" else "_", if (uses_core) "model" else "_", if (uses_core) "x" else "_", if (uses_core) "sim" else "_",
    });
    if (uses_core) try self.w(
        "    const m = {s}(S, zVals(S, &x), model, {s}, sim{s});\n",
        .{ self.core.name, try gen_setup.probeInstance(self), self.heldArg(true) },
    );
    for (self.lowered.limit_slots.items, 0..) |slot, k| {
        if (gen_dispatch.coreIdx(self, self.an.rv(slot.final))) |lo|
            try self.w("    inst.limiter_previous[{d}] = m.f{d}.val();\n", .{ k, lo })
        else
            try self.w("    inst.limiter_previous[{d}] = 0.0;\n", .{k});
    }
    try self.w("}}\n\n", .{});
}

/// Writes `collapse` and `collapse_full` (§5.6.5). `collapse` runs the core
/// at x = 0 and reads the §5.6.1.3 retention flags `eval` selects branch rows
/// on; a set flag is a dead short whose internal node and branch-flow unknown
/// the host aliases onto the far node. The host calls it once, at build, so
/// only `buildFree` flags are admitted.
pub fn emitCollapse(self: *Gen, pairs: []const CollapsePair) Error!void {
    if (pairs.len == 0) return;
    try self.w(
        \\/// Zero-parasitic node collapse (ngspice setup: DIOsetup's
        \\/// `posPrimeNode = posNode` when RS == 0). Applied by the host before
        \\/// matrix build; the flags read here are the §5.6.1.3 retention flags
        \\/// `eval` selects the branch rows on, evaluated at x = 0 like `seed` —
        \\/// sound because codegen admits only build-time-constant flags.
        \\///
        \\/// Dead shorts form CHAINS (BSIM4's rgateMod=0 retains both V(g,gm)=0
        \\/// and V(gm,gi)=0, sharing gm), so aliases are resolved by union-find:
        \\/// every member of a merged set lands on ONE root and each stamp of
        \\/// the set cancels on a single slot. Last-write-wins aliasing left the
        \\/// chain's first link dangling — its KVL row landed on a KCL row as
        \\/// ±1 garbage stamps and the "solution" violated the model equations.
        \\pub fn collapse(comptime S: type, model: *const Model, inst: *const Instance) [n_u]?u8 {{
        \\    const xr: [n_u]zOf(S, 0) = @splat(S.con(0.0));
        \\    // SEEDS ITS OWN SETUP, on a local copy. `collapse` decides
        \\    // TOPOLOGY, so a host must call it while building the matrix —
        \\    // before the batch exists and therefore before the batch runs
        \\    // `setup`. But it answers by evaluating `core` at x = 0, and
        \\    // `core` reads `Model.su`: without this the retention flags
        \\    // are read off unset fields and a device collapses (or fails to)
        \\    // on garbage. `setup` is a pure function of the model, so
        \\    // computing it here is the answer the batch will compute later,
        \\    // and the copies keep the caller's Model and Instance untouched.
        \\{s}    const m = core(S, xr, {s}, {s}, .{{}}{s});
        \\    var parent: [n_u]u8 = undefined;
        \\    for (&parent, 0..) |*p, i| p.* = @intCast(i);
        \\
    , .{
        if (self.su.vals.len != 0 and self.lowered.table_samples.items.len != 0)
            "    var mpin = model.*;\n    setup(S, &mpin);\n    var pin = inst.*;\n"
        else if (self.su.vals.len != 0)
            "    var mpin = model.*;\n    setup(S, &mpin);\n"
        else if (self.lowered.table_samples.items.len != 0)
            "    var pin = inst.*;\n"
        else
            "",
        if (self.su.vals.len != 0) "&mpin" else "model",
        if (self.lowered.table_samples.items.len != 0) "&pin" else "inst",
        self.heldArg(true),
    });
    for (pairs, 0..) |p, pi| {
        const fi = @backingInt(self.an.rv(p.flag));
        const k = self.core.lo_idx[fi];
        assert(k != none_u32); // `buildJobs` queues every runtime retention flag
        if (self.an.vty[fi] == .int)
            try self.w("    const a{d} = (m.f{d} != 0);", .{ pi, k })
        else
            try self.w("    const a{d} = (m.f{d}.val() != 0.0);", .{ pi, k });
        try self.w(" // 0 V arm retained: dead short\n", .{});
        try self.w("    if (a{d}) zCollapseUnion(&parent, @intFromEnum(U.{s}), @intFromEnum(U.{s}));\n", .{
            pi, self.names.u_names[p.victim], self.names.u_names[p.target],
        });
    }
    try emitAliases(self, pairs);
    try self.w("    return out;\n}}\n\n", .{});
    try self.w(
        \\fn zCollapseRoot(parent: *const [n_u]u8, start: u8) u8 {{
        \\    var u = start;
        \\    while (parent[u] != u) u = parent[u];
        \\    return u;
        \\}}
        \\
        \\/// Min-index root wins, so a set's root is always its lowest unknown —
        \\/// the host resolves aliases in ascending order and needs the target
        \\/// resolved before every mover.
        \\fn zCollapseUnion(parent: *[n_u]u8, a: u8, b: u8) void {{
        \\    const ra = zCollapseRoot(parent, a);
        \\    const rb = zCollapseRoot(parent, b);
        \\    if (ra == rb) return;
        \\    if (ra < rb) parent[rb] = ra else parent[ra] = rb;
        \\}}
        \\
        \\
    , .{});
    try emitCollapseFull(self, pairs);
}

/// Writes `collapse_full`: `collapse` with every retention flag set, as a
/// comptime const. A host sizes a reduced derivative basis from it (a type,
/// so it cannot wait for an instance); an instance qualifies exactly when its
/// runtime `collapse` equals this.
fn emitCollapseFull(self: *Gen, pairs: []const CollapsePair) Error!void {
    try self.w(
        \\/// The MAXIMAL collapse: `collapse` with every §5.6.1.3 retention
        \\/// flag set. Comptime, so a host can size a reduced derivative
        \\/// basis for the instances whose runtime `collapse` equals this;
        \\/// any other outcome merges strictly less and must use full width.
        \\pub const collapse_full: [n_u]?u8 = blk: {{
        \\    var parent: [n_u]u8 = undefined;
        \\    for (&parent, 0..) |*p, i| p.* = @intCast(i);
        \\
    , .{});
    for (pairs) |p| {
        try self.w("    zCollapseUnion(&parent, @intFromEnum(U.{s}), @intFromEnum(U.{s}));\n", .{
            self.names.u_names[p.victim], self.names.u_names[p.target],
        });
    }
    try emitAliases(self, pairs);
    try self.w("    break :blk out;\n}};\n\n", .{});
}

/// Writes `collapse`'s and `collapse_full`'s `out` from the union-find
/// `parent` both have built: each unknown's root, then every pair's
/// branch-flow unknown. Unconditional, unlike the union: the flag decides
/// whether the nodes merge, but the branch-flow unknown is aliased either
/// way. Not taken, the branch is a conductance stamped straight into KCL
/// (`emitSwitchRow`), so its current row is never written.
fn emitAliases(self: *Gen, pairs: []const CollapsePair) Error!void {
    try self.w(
        \\    var out: [n_u]?u8 = @splat(null);
        \\    for (0..n_u) |u| {{
        \\        const r = zCollapseRoot(&parent, @intCast(u));
        \\        if (r != u) out[u] = r;
        \\    }}
        \\
    , .{});
    for (pairs) |p| {
        try self.w("    out[@intFromEnum(U.{s})] = zCollapseRoot(&parent, @intFromEnum(U.{s}));\n", .{
            self.names.u_names[p.flow_u], self.names.u_names[p.target],
        });
    }
}

/// Writes `delays`: each §4.5.7 site's transport delay over `Model` alone
/// (a §4.5.14 constant or parameter expression). The host lands an echo
/// breakpoint at t + td and clamps dt_max under the shortest delay. A site
/// whose delay is a solved quantity is skipped.
pub fn emitDelays(self: *Gen) Error!void {
    const saved = self.uses.model;
    defer self.uses.model = saved;
    self.uses.model = false;
    var tds: std.ArrayList([]const u8) = .empty;
    for (self.names.units, 0..) |u, i| {
        if (u.role != .analog_op or u.op != .absdelay) continue;
        const inst = self.names.opInstOf(@intCast(i)) orelse continue;
        const args = self.mir.instData(inst).call.args;
        if (args.len < 2) continue;
        const td = try gen_host.f64Const(self, args[1], 0, false) orelse continue;
        // §4.5.7 "If td becomes greater than maxdelay, maxdelay will be used
        // as a substitute for td", as `call.absdelayTd` runs it in the
        // residual. A solve-time maxdelay is no `Model` expression: td stays.
        const maxd = if (args.len > 2) try gen_host.f64Const(self, args[2], 0, false) else null;
        try tds.append(self.arena, if (maxd) |m| try self.arena.print("@min({s}, {s})", .{ td, m }) else td);
    }
    if (tds.items.len == 0) return;
    try self.w(
        \\/// §4.5.7 transport delays, one per absdelay site. The host lands
        \\/// wavefront breakpoints at corner + td and bounds dt_max under the
        \\/// shortest delay (engine minDelay -> tran echo machinery).
        \\pub fn delays({s}: *const Model) [{d}]f64 {{
        \\    return .{{
    , .{ if (self.uses.model) "model" else "_", tds.items.len });
    for (tds.items, 0..) |td, k| try self.w("{s} {s}", .{ if (k == 0) "" else ",", td });
    try self.w(" }};\n}}\n\n\n", .{});
}

/// Writes `pendingBreakpoint` (the live per-instance schedule) and
/// `nextBreakpoint` (the §5.10.5 `timer` fire times, recomputed from `Model`
/// alone): the host places a timepoint on each fire instead of across it.
///
/// All or nothing: if any timer's start or period does not render over
/// `Model`, `nextBreakpoint` is omitted. A missing hook costs accuracy; a
/// subset would tell the host this device wants no other timepoints.
pub fn emitNextBreakpoint(self: *Gen) Error!void {
    // ponytail: `enable` is honoured only when it folds to a constant zero (the
    // timer never fires) or renders over `Model` (a runtime guard). A solved
    // enable keeps its breakpoints: an extra timepoint costs a step, never an
    // answer.
    if (!gen_file.usesOp(self, .timer)) return;

    // §5.10.3.3 the live schedule: a start_time computed during the solve
    // exists only as `__next`. Every timer is listed; a disabled one costs
    // the host a timepoint, never an answer.
    try self.w(
        \\/// §5.10.3.3 the earliest timer event this instance has scheduled
        \\/// strictly after `t` — re-armed start times included.
        \\pub fn pendingBreakpoint(inst: *const Instance, t: f64) ?f64 {{
        \\    var best = std.math.inf(f64);
        \\
    , .{});
    for (self.names.units, 0..) |u, i| {
        if (u.role != .analog_op or u.op != .timer) continue;
        try self.w("    if (inst.{0s}__next > t) best = @min(best, inst.{0s}__next);\n", .{self.names.unit_names[i]});
    }
    try self.w(
        \\    return if (best == std.math.inf(f64)) null else best;
        \\}}
        \\
        \\
    , .{});

    // Render first: `f64Const` sets `uses.model`, and an unused `model`
    // parameter does not compile.
    const saved = self.uses.model;
    defer self.uses.model = saved;
    self.uses.model = false;

    const Timer = struct { start: []const u8, period: []const u8, guard: ?[]const u8 };
    var timers: std.ArrayList(Timer) = .empty;
    for (self.names.units, 0..) |u, i| {
        if (u.role != .analog_op or u.op != .timer) continue;
        const inst = self.names.opInstOf(@intCast(i)) orelse return;
        const args = self.mir.instData(inst).call.args;
        // §5.10.3.3 "if enable is specified and it is zero, then timer() is
        // inactive": such a timer adds no breakpoint and vetoes no other.
        var guard: ?[]const u8 = null;
        if (@import("ir").op.enableArg(.timer)) |ei| {
            if (ei < args.len) {
                if (self.an.foldConst(args[ei], false)) |c| {
                    if (c.f == 0.0) continue;
                } else if (try gen_host.f64Const(self, args[ei], 0, false)) |e| {
                    guard = e;
                }
            }
        }
        // No diagnostic: an unrenderable period already has one, and a solved
        // start_time is legal Verilog-A this hook cannot describe.
        const start = try gen_host.f64Const(self, if (args.len > 0) args[0] else .zero, 0, false) orelse return;
        const period = try gen_host.f64Const(self, if (args.len > 1) args[1] else .zero, 0, false) orelse return;
        try timers.append(self.arena, .{ .start = start, .period = period, .guard = guard });
    }
    if (timers.items.len == 0) return;

    try self.w(
        \\/// §5.10.5 the earliest `timer` fire strictly after `t`, so the host
        \\/// puts a timepoint ON the discontinuity instead of across it.
        \\pub fn nextBreakpoint({s}: *const Model, t: f64) ?f64 {{
        \\    var best = std.math.inf(f64);
        \\
    , .{if (self.uses.model) "model" else "_"});
    for (timers.items) |tm| {
        if (tm.guard) |g| try self.w("    if (({s}) != 0.0) {{\n    ", .{g});
        try self.w("    if (zNextTimer({s}, {s}, t)) |b| best = @min(best, b);\n", .{ tm.start, tm.period });
        if (tm.guard != null) try self.w("    }}\n", .{});
    }
    try self.w(
        \\    return if (best == std.math.inf(f64)) null else best;
        \\}}
        \\
        \\
    , .{});
}

test readsM {
    try std.testing.expect(readsM("const in = m.f0.val();"));
    try std.testing.expect(readsM("m.f12"));
    try std.testing.expect(readsM("(m.f2.val())"));
    // `m.f` inside a longer name is not the core result.
    try std.testing.expect(!readsM("const m = zm.f0;"));
    try std.testing.expect(!readsM("_m.f1"));
    try std.testing.expect(!readsM("m.x"));
    try std.testing.expect(!readsM(""));
}
