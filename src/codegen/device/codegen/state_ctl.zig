//! The `Instance` fields `updateState` advances (`Gen.hist`) -> `State`'s
//! twins and `stateCtl`, which commits, reverts and compares them: the
//! §5.6.1.2 staged path latches, the §5.10 held values (whole, or the dirty
//! range of a long in-place array) and the §4.5.7 delay rings.
//! Cites: §4.5.7, §5.6.1.2, §5.10, §5.10.3.
//!
//! Contents:
//! - `pub fn emitStateTwins(self: *Gen, t_prev: bool) Error!void`
//! - `pub fn emitStateCtl(self: *Gen, t_prev: bool) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_unit = @import("unit.zig");
const Lowered = @import("ir").Lowered;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const gen_instance = @import("instance.zig");

/// Emits `State`'s `stateCtl` twins: the §5.6.1.2 staged path-latch operands
/// (`wb__k`/`wq__k`, which `updateState` writes and `stateCtl(.commit)` moves
/// into `Instance.pb__k`/`pq__k`), one twin per `Gen.hist` field, typed and
/// defaulted as that `Instance` field, plus `t_prev__acc` when `t_prev` and
/// each §4.5.7 ring's overwritten sample. Requires `emitInstance` to have run
/// and `z_inst0` (a default `Instance`) to be declared.
pub fn emitStateTwins(self: *Gen, t_prev: bool) Error!void {
    assert(self.core.prev_lo.len == self.core.prev_vals.len);
    assert(self.core.acc_lo.len == self.core.acc_vals.len);
    for (0..self.core.prev_lo.len) |k| try self.w("    wb__{d}: f64 = 0.0, // path_prev staged\n", .{k});
    for (0..self.core.acc_lo.len) |k| try self.w("    wq__{d}: f64 = 0.0, // path_acc staged\n", .{k});
    if (t_prev) try self.w("    t_prev__acc: f64 = 0.0,\n", .{});
    for (self.hist.items) |h| try self.w("    {s}: @TypeOf(z_inst0.{s}) = z_inst0.{s},\n", .{ h, h, h });
    // Not `hist`: `initState` keeps a capture across analyses (VD-095).
    if (self.lowered.table_samples.items.len != 0)
        try self.w("    table_kept: [{d}]bool = @splat(false),\n", .{self.lowered.table_samples.items.len});
    for (self.names.units, 0..) |u, i| {
        if (u.role == .analog_op and u.op == .absdelay)
            try self.w("    {0s}__t__acc: f64 = 0.0,\n    {0s}__v__acc: f64 = 0.0,\n    {0s}__t__acc2: f64 = 0.0,\n    {0s}__v__acc2: f64 = 0.0,\n", .{self.names.unit_names[i]});
    }
}

/// Emits the `stateCtl` hook; every `updateState` has one. `query` compares
/// the held state a `cross`/`above` FSM writes (`fsmStateCtl`) and nothing
/// else, since other history moving is not a step-reject condition. `commit`
/// latches the §5.6.1.2 path latches (`pb = wb`, `pq += wq`, `wq = 0`) and
/// copies every field `updateState` advances into its `State` twin
/// (`emitStateTwins`); `revert` copies the twins back, so a rejected step
/// leaves the device as the last accepted point did (§4.5). A §4.5.7 ring
/// keeps only the sample the next push overwrites, which is exact while one
/// `updateState` runs between `stateCtl` calls. Tag order mirrors
/// contract.StateCtlOp, which the host converts by ordinal.
pub fn emitStateCtl(self: *Gen, t_prev: bool) Error!void {
    assert(self.names.held_names.len == self.lowered.held_vars.items.len);
    const fsm = fsmStateCtl(self);
    try self.w(
        \\/// §4.5 the step decision after `updateState` (`contract.StateCtlOp`):
        \\/// `.commit` latches the path latches and copies the history into
        \\/// `state`; `.revert` copies it back, so a rejected step leaves the
        \\/// instance as the last accepted point did. Returns true only for a
        \\/// `.query` whose accepted solution flipped a `cross`/`above` latch.
        \\
    , .{});
    try self.w("pub fn stateCtl(_: *const Model, ", .{});
    const at_inst = self.out.items.len;
    try self.w("inst: *Instance, ", .{});
    const at_state = self.out.items.len;
    try self.w(
        \\state: *State, op: contract.StateCtlOp) bool {{
        \\    if (op == .query) {{
        \\        return
    , .{});
    const body = self.out.items.len;
    // VerA's `vera_timepoint` (§2.9): a commit or a revert moves the held
    // state a cached statement reads.
    const tp_drop = if (self.lowered.timepoints.items.len != 0) "        zTpDrop(inst);\n" else "";
    // §9.21.1 (VD-095) the kept captures are history; the working ones of
    // the last evaluation are dropped either way, as the next evaluation
    // would drop them.
    const tables = self.lowered.table_samples.items.len != 0;
    const tbl_commit = if (tables) "        state.table_kept = inst.table_kept;\n        inst.table_ready = inst.table_kept;\n" else "";
    const tbl_revert = if (tables) "        inst.table_kept = state.table_kept;\n        inst.table_ready = inst.table_kept;\n" else "";
    var first = true;
    for (self.names.held_names, self.lowered.held_vars.items) |n, h| {
        if (!fsm) break;
        if (h.why != .event) continue;
        // §3.2.2 a held array (and a wide `reg`) compares element by element;
        // a string by text.
        if (h.array != none_u32 or h.ty == .wide)
            try self.w("{s}!std.meta.eql(inst.{s}, state.{s})", .{ if (first) " " else "\n            or ", n, n })
        else if (h.ty == .string)
            try self.w("{s}!std.mem.eql(u8, inst.{s}.get(), state.{s}.get())", .{ if (first) " " else "\n            or ", n, n })
        else
            try self.w("{s}(inst.{s} != state.{s})", .{ if (first) " " else "\n            or ", n, n });
        first = false;
    }
    if (first) try self.w(" false", .{});
    try self.w(
        \\;
        \\    }}
        \\    if (op == .commit) {{
        \\{s}{s}
    , .{ tp_drop, tbl_commit });
    if (self.lowered.limit_slots.items.len != 0) try self.w(
        "        state.limiter_previous = inst.limiter_previous;\n",
        .{},
    );
    for (0..self.core.prev_lo.len) |k| try self.w("        inst.pb__{d} = state.wb__{d};\n", .{ k, k });
    for (0..self.core.acc_lo.len) |k| try self.w("        inst.pq__{d} += state.wq__{d};\n        state.wq__{d} = 0.0;\n", .{ k, k, k });
    for (self.hist.items) |h| {
        if (heldNamed(self, h)) |hv| if (dirtyArray(self, hv) != null) {
            try self.w("        zArrSync({1s}, &state.{0s}, &inst.{0s}, &inst.{0s}__dirty);\n", .{ h, elemTy(self, hv) });
            continue;
        };
        try self.w("        state.{s} = inst.{s};\n", .{ h, h });
    }
    for (self.names.units, 0..) |u, i| {
        if (u.role == .analog_op and u.op == .absdelay) try self.w(
            "        state.{0s}__t__acc = inst.{0s}__t[@intCast(inst.{0s}__head % {1d})];\n        state.{0s}__v__acc = inst.{0s}__v[@intCast(inst.{0s}__head % {1d})];\n" ++
                // The sample a thinning push overwrites (`zHistRevert`).
                "        state.{0s}__t__acc2 = inst.{0s}__t[@intCast((inst.{0s}__head + 1) % {1d})];\n        state.{0s}__v__acc2 = inst.{0s}__v[@intCast((inst.{0s}__head + 1) % {1d})];\n",
            .{ self.names.unit_names[i], gen_instance.histLen(self, i) },
        );
    }
    if (t_prev) try self.w("        state.t_prev__acc = state.t_prev;\n", .{});
    try self.w("    }} else {{\n{s}{s}", .{ tp_drop, tbl_revert });
    // The count the rejected push left, before `__head` is restored.
    for (self.names.units, 0..) |u, i| {
        if (u.role == .analog_op and u.op == .absdelay)
            try self.w("        const zh{d} = inst.{s}__head;\n", .{ i, self.names.unit_names[i] });
    }
    if (self.lowered.limit_slots.items.len != 0) try self.w(
        "        inst.limiter_previous = state.limiter_previous;\n",
        .{},
    );
    for (self.hist.items) |h| {
        if (heldNamed(self, h)) |hv| if (dirtyArray(self, hv) != null) {
            try self.w("        zArrSync({1s}, &inst.{0s}, &state.{0s}, &inst.{0s}__dirty);\n", .{ h, elemTy(self, hv) });
            continue;
        };
        try self.w("        inst.{s} = state.{s};\n", .{ h, h });
    }
    // After `__head` is back: the slot the rejected push overwrote, and a
    // thinning it did undone (`zHistRevert`).
    for (self.names.units, 0..) |u, i| {
        if (u.role == .analog_op and u.op == .absdelay) try self.w(
            "        zHistRevert(&inst.{0s}__t, &inst.{0s}__v, inst.{0s}__head, zh{1d}, state.{0s}__t__acc, state.{0s}__v__acc, state.{0s}__t__acc2, state.{0s}__v__acc2);\n",
            .{ self.names.unit_names[i], i },
        );
    }
    if (t_prev) try self.w("        state.t_prev = state.t_prev__acc;\n", .{});
    try self.w(
        \\    }}
        \\    return false;
        \\}}
        \\
        \\
    , .{});
    // A device whose only accepted-step work is constant (the §9.17 resets)
    // or `$vera_reject_step` has nothing to commit.
    gen_unit.patchUnless(self, at_state, body, "state");
    gen_unit.patchUnless(self, at_inst, body, "inst");
}

// ---- private ----

/// Returns whether the module's §5.10 held state is fed by `cross`/`above`
/// edges: a hysteresis FSM (a switch) that gets `stateCtl`
/// (contract.StateCtlOp). The host rejects a converged step whose accepted
/// solution flipped the latch and shrinks toward the crossing, so the
/// discontinuity lands sharp instead of smearing across one step.
fn fsmStateCtl(self: *const Gen) bool {
    assert(self.names.units.len == self.names.unit_names.len);
    for (self.lowered.held_vars.items) |h| {
        if (h.why == .event) break;
    } else return false;
    for (self.names.units) |u| {
        if (u.role != .analog_op) continue;
        switch (u.op) {
            .cross, .above => return true,
            .none, .idt_hold, .idtmod, .absdelay, .transition, .slew, .last_crossing, .laplace, .zi, .timer, .bound_step, .discontinuity => {},
        }
    }
    return false;
}

/// Returns the `Lowered.held_vars` row's array id when it is dirty-tracked.
fn dirtyArray(self: *const Gen, h: Lowered.HeldVar) ?u32 {
    assert(h.name.len != 0);
    if (h.array == none_u32 or !gen_instance.dirtyTracked(self, h.array)) return null;
    return h.array;
}

/// Returns the module's `Lowered.held_vars` row named `name`, if any.
fn heldNamed(self: *const Gen, name: []const u8) ?Lowered.HeldVar {
    assert(name.len != 0);
    for (self.names.held_names, self.lowered.held_vars.items) |n, h| {
        if (std.mem.eql(u8, n, name)) return h;
    }
    return null;
}

/// Returns the element type of held array row `h`'s `Instance` field.
fn elemTy(self: *const Gen, h: Lowered.HeldVar) []const u8 {
    assert(h.array != none_u32);
    return if (self.lowered.mem_arrays.items[h.array].ty == .integer) "i64" else "f64";
}
