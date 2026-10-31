//! Accepted-step emission: the stateful operator calls in; `State`,
//! `initState`, `updateState`, `acceptQ`, `advanceIteration`, the collapse
//! hooks and the breakpoint hooks out. Advances each operator's `Instance`
//! slots once per accepted timepoint (§4.5.2) and emits §5.6.5 collapse.
//! LRM clauses cited: §2.9, §4.5.2, §4.5.7, §4.5.10, §4.5.12, §5.6.1.3, §5.6.5,
//! §5.10.3, §5.10.5, §9.13.1, §9.17.
//!
//! Contents:
//! - `pub const Accept = struct`
//! - `pub fn secStep(self: *Gen, n: []const u8, p: cg_filters.FilterPlan, dt: []const u8) Error![]const u8`
//! - `pub fn emitCore(self: *Gen) Error!void`
//! - `pub fn inPlaceArrays(self: *Gen) Error![]const bool`
//! - `pub fn emitIterCore(self: *Gen) Error!void`
//! - `pub fn emitStateMachine(self: *Gen) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const operator_ctrl = @import("operator_ctrl.zig");
const gen_dispatch = @import("dispatch.zig");
const gen_file = @import("file.zig");
const gen_instance = @import("instance.zig");
const gen_state_ctl = @import("state_ctl.zig");
const gen_timepoint = @import("timepoint.zig");
const gen_status = @import("status.zig");
const gen_setup = @import("setup.zig");
const gen_unit = @import("unit.zig");
const render_array = @import("render_array.zig");
const Mir = @import("ir").Mir;
const opdb = @import("op_zig.zig");
const cg_filters = @import("../cg_filters.zig");
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const gen_accept = @import("accept.zig");

/// What the accepted-step body needs, decided once for `updateState` and
/// `acceptQ` alike.
pub const Accept = struct {
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

/// Returns filter unit `n`'s `__sec` call in `updateState`'s frame. A filter
/// with §4.5.14 sampled coefficients first gets their latch: "the value of
/// the dynamic expression at the start of the analysis", taken at the static
/// point (`dt`, the step its kernel tests for one) and read after it.
pub fn secStep(self: *Gen, n: []const u8, p: cg_filters.FilterPlan, dt: []const u8) Error![]const u8 {
    assert(n.len != 0);
    assert(dt.len != 0);
    if (p.sampled.len == 0) return self.arena.print("{s}__sec(model)", .{n});
    try self.w("        if (!({s} > 0.0)) inst.{s}__k = .{{ ", .{ dt, n });
    for (p.sampled, 0..) |v, j| {
        if (j != 0) try self.w(", ", .{});
        try self.w("{s}", .{try operator_ctrl.ctrlStep(self, &.{v}, 0, "0.0")});
    }
    try self.w(" }};\n", .{});
    return self.arena.print("{s}__sec(model, inst.{s}__k)", .{ n, n });
}

/// Emits `<core>__state`, the core's slice computing only what `updateState`
/// reads: the path-latch operands, every stateful operator's arguments the
/// core carries, and the held values. Called from `emitUnits`, so its range
/// tiles with the other unit declarations.
pub fn emitCore(self: *Gen) Error!void {
    assert(self.state_core.name.len == 0);
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
    assert(self.arr_s.len == self.lowered.mem_arrays.items.len);
    if (self.lowered.table_samples.items.len != 0) return &.{};
    const n = self.lowered.mem_arrays.items.len;
    const flags = try self.arena.alloc(bool, n);
    for (flags, 0..) |*f, id| f.* = render_array.cow(self, @intCast(id));
    for (0..self.mir.insts.len) |ii| {
        const inst: Mir.Inst = @fromBackingInt(@intCast(ii));
        if (self.mir.instOp(inst) != .anew) continue;
        const d = self.mir.instData(inst).anew;
        const tp = d.tp orelse continue;
        if (!gen_timepoint.tpInPlace(self, self.lowered.timepoints.items[tp.block].slots[tp.slot])) flags[d.array] = false;
    }
    if (std.mem.findScalar(bool, flags, true) == null) return &.{};
    return flags;
}

/// Emits `<core>__iter`, the core's slice computing only the §9.17.3
/// limiter values `advanceIteration` stores once per Newton iterate.
pub fn emitIterCore(self: *Gen) Error!void {
    assert(self.iter_core.name.len == 0);
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
    assert(self.core.held_idx.len == self.lowered.held_vars.items.len);
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
    try gen_state_ctl.emitStateTwins(self, acc.reads_t_prev);
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
    , .{if (tp or dirty or restart or gen_status.hasStatus(self)) "inst" else "_"});
    for (self.hist.items) |h| try self.w("    inst.{s} = z_inst0.{s};\n", .{ h, h });
    for (0..self.core.prev_lo.len) |k| try self.w("    inst.pb__{d} = z_inst0.pb__{d};\n", .{ k, k });
    for (0..self.core.acc_lo.len) |k| try self.w("    inst.pq__{d} = z_inst0.pq__{d};\n", .{ k, k });
    // The §4.5.7 ring is not `hist` (only its head is), but a new analysis
    // starts it empty too.
    for (self.names.units, self.names.unit_names) |u, n| if (u.role == .analog_op and u.op == .absdelay)
        try self.w("    inst.{0s}__t = z_inst0.{0s}__t;\n    inst.{0s}__v = z_inst0.{0s}__v;\n", .{n});
    if (tp) try self.w("    zTpDrop(inst);\n", .{});
    if (gen_status.hasStatus(self)) try self.w(gen_status.status_drop, .{});
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
    if (gen_status.hasStatus(self)) try self.w("    if (inst.vera_status__ != 0) return .ok;\n", .{});
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
    try gen_accept.emitAcceptBody(self, acc);
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
    try gen_state_ctl.emitStateCtl(self, acc.reads_t_prev);
    try emitAdvanceIteration(self);
    try gen_accept.emitAcceptQ(self, acc);
}

// ---- private ----

fn scanAccept(self: *Gen) Error!Accept {
    assert(self.names.units.len == self.names.unit_names.len);
    var a: Accept = .{};
    for (self.names.units, 0..) |u, i| {
        if (u.role != .analog_op) continue;
        const k = u.op;
        a.uses_dt = a.uses_dt or opdb.get(k).needs_dt;
        if (k == .absdelay and (try operator_ctrl.absdelayFreezes(self, self.names.opArgs(self.mir, i)) or
            try operator_ctrl.absdelayMaxdSampled(self, self.names.opArgs(self.mir, i)))) a.reads_t_prev = true;
        if (k == .none) continue;
        a.uses_core = a.uses_core or gen_unit.opInputIdx(self, @intCast(i)) != none_u32;
    }
    for (self.core.held_idx) |k| a.uses_core = a.uses_core or k != none_u32;
    a.uses_core = a.uses_core or gen_instance.pathLatches(self);
    a.uses_core = a.uses_core or rejectStepIdx(self) != null;
    a.reads_t_prev = a.reads_t_prev or a.uses_dt;
    return a;
}

/// The core field of VerA's `$vera_reject_step` retry time, in `self.core`.
fn rejectStepIdx(self: *const Gen) ?u32 {
    assert(self.core.lo_idx.len == 0 or self.core.lo_idx.len == self.an.nv);
    if (self.lowered.reject_step == .undef) return null;
    return gen_dispatch.coreIdx(self, self.an.rv(self.lowered.reject_step));
}

/// Returns whether `text` reads a field of the core result `m` (`m.f<k>`).
fn readsM(text: []const u8) bool {
    var at: usize = 0;
    // Each match moves `at` past it, so the scan visits each offset once.
    var iterations: usize = 0;
    while (std.mem.findPos(u8, text, at, "m.f")) |i| : (at = i + 1) {
        assert(iterations < text.len);
        iterations += 1;
        if (i == 0 or !(std.ascii.isAlphanumeric(text[i - 1]) or text[i - 1] == '_')) return true;
    }
    return false;
}

/// Writes `contract.StateClass`: `.path_latch` when the state is the §5.6.1.2
/// latches alone (no operator history, held variable or §9.13.1 seed),
/// `.history` otherwise.
fn emitStateClass(self: *Gen) Error!void {
    assert(self.out.items.len != 0);
    const latch_only = gen_instance.pathLatches(self) and !gen_file.hasStatefulOps(self) and
        self.lowered.rng_auto_seeds.items.len == 0;
    try self.w("/// What `updateState` carries across accepted points (`contract.StateClass`).\npub const state_class: contract.StateClass = .{s};\n\n", .{
        if (latch_only) "path_latch" else "history",
    });
}

/// Writes `advanceIteration` (the host calls it after each Newton iterate,
/// with that iterate's x).
fn emitAdvanceIteration(self: *Gen) Error!void {
    assert(self.out.items.len != 0);
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
