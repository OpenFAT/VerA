//! A §5.6.1.3 runtime-selected branch -> its residual row: §5.6.5's switch
//! branch picks, per evaluation, between the potential source that pins the
//! branch current and the flow form, with the card-only constants of a
//! collapsible branch guarded by its retention flag (`Model.<flow>__retained`).
//! Cites: §5.6.1.3, §5.6.5.
//!
//! Contents:
//! - `pub fn emitSwitchRow(self: *Gen, i: usize, c: Lower.Contribution, flag: Mir.Value, react: bool) Error!void`
//! - `pub fn collapsible(self: *const Gen, i: usize) bool`
//! - `pub fn guardField(self: *const Gen, k: u32) Error![]const u8`

const std = @import("std");
const assert = std.debug.assert;
const plan_topo = @import("plan/topology.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const family = @import("family.zig");
const gen_mask = @import("mask.zig");
const Mir = @import("ir").Mir;
const Lower = @import("ir").Lowered;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const gen_stamps = @import("stamps.zig");
const stamp_lin = @import("stamp_lin.zig");

/// Emits the §5.6.1.3 runtime-selected branch row: §5.6.5's switch branch,
/// and the clause's "otherwise the branch is an open circuit" case for a lone
/// conditional potential contribution.
///
/// The matrix structure stays constant: the branch always carries its flow
/// unknown I_b, stamped ±I_b into the two KCL rows, and only the branch row's
/// content is selected per cycle on the retention flags:
///
///     V retained this cycle:  res[u] = V(hi) − V(lo) − c_V   (potential source)
///     else I retained:        res[u] = I_b − c_I             (flow source)
///     else:                   res[u] = I_b                   (open: pins I_b = 0)
///
/// `S.sel` carries the winner's dual, so the Jacobian switches coherently
/// with the row: ±1 on the node columns for the potential form, 1 on the
/// I_b column (and −∂c_I/∂x) for the flow form, a bare 1 on I_b for the
/// open circuit, so never singular. In the q residual the same select runs
/// over the fluxes (−φ, §5.6.1.2), the open case contributing none.
///
/// The flow form's ±c_I KCL stamps are not emitted (`flowIsMerged`): the
/// retained flow reaches KCL through I_b, which the row pins to c_I.
///
/// A collapsible branch (`collapsePairs`) is the exception: `collapse`
/// deletes I_b from the host's maps, so the row is split on the retention
/// flag, a `buildFree` value fixed for the whole simulation (a real `if`):
///
///   flag set (0 V arm, dead short): the host aliased hi, lo and I_b onto
///     one unknown, so ±I_b and `V(hi) − V(lo)` would add and subtract the
///     same slot, and float addition there is not exact. A host that applied
///     the aliases gets no stamps; one that did not keeps the full equations.
///   flag clear: I_b does not exist. The branch is a plain conductance whose
///     flow reaches KCL directly, like an unswitched `.flow` (`switchOpen`).
///
/// The guard (`contract.JacWhen`): when the flag depends on the card alone
/// (`CollapsePair.card`), the flag-set arm's coefficients (±1) are constants
/// per card and leave as `jac_const` entries guarded by the published `Model`
/// field, so ib keeps no lane. Any other runtime row keeps every lane.
pub fn emitSwitchRow(self: *Gen, i: usize, c: Lower.Contribution, flag: Mir.Value, react: bool) Error!void {
    assert(i < self.lowered.contributions.items.len);
    assert(c.access == .potential);
    const u = self.names.branch_u[i];
    const partner = plan_topo.switchFlowOf(self.input(), i);
    const split = collapsible(self, i);
    const guard = guardOf(self, i);
    // Every coefficient on this row, and ib's in KCL, is picked per cycle by
    // a runtime flag, so every unknown it names keeps a lane, as does
    // whatever the row held before, unless the guard states them.
    if (guard) |k| {
        if (!react) {
            try guardTerm(self, c.hi, u, 1, k);
            try guardTerm(self, c.lo, u, -1, k);
            try guardTerm(self, u, c.hi, 1, k);
            try guardTerm(self, u, c.lo, -1, k);
        }
    } else gen_mask.orIn(self.jac.deriv_reads, try gen_stamps.bits(self, &.{ u, c.hi, c.lo }, &.{}));
    stamp_lin.linDynamic(self, u);
    const d: u32 = if (split) 4 else 2;
    if (split) {
        try self.ind(2);
        try self.b("if (", .{});
        try coreRef(self, flag);
        if (self.an.vty[@backingInt(self.an.rv(flag))] == .int)
            try self.b(" != 0) {{\n", .{})
        else
            try self.b(".val() != 0.0) {{\n", .{});
        try self.ind(3);
        try self.b("if (comptime !(@hasDecl(S, \"collapse_applied\") and S.collapse_applied)) {{\n", .{});
    }
    if (!react) {
        try self.ind(d);
        try self.b("const ib = x[@intFromEnum(U.{s})];\n", .{self.names.u_names[u]});
        // Guarded: the constant is `guardTerm`'s, not an unconditional `lin`.
        const col: ?u32 = if (guard == null) u else null;
        try gen_stamps.stamp(self, d, c.hi, .add, "ib", try gen_stamps.bits(self, &.{u}, &.{}), col);
        try gen_stamps.stamp(self, d, c.lo, .sub, "ib", try gen_stamps.bits(self, &.{u}, &.{}), col);
        try self.ind(d);
        gen_stamps.patRow(self, @intCast(u), try gen_stamps.bits(self, &.{ u, c.hi, c.lo }, &.{try switchRowDeps(self, i, c, react)}));
        try gen_stamps.rowSet(self, u);
        try self.b("S.sel(", .{});
        try coreRef(self, flag);
        try self.b(", ", .{});
        try gen_stamps.nodeVoltage(self, c.hi);
        try self.b(".sub(", .{});
        try gen_stamps.nodeVoltage(self, c.lo);
        try self.b(").sub(c), ", .{});
        try switchElse(self, partner, react);
        try self.b(")", .{});
        try gen_stamps.rowEnd(self);
    } else {
        try self.ind(d);
        gen_stamps.patRow(self, @intCast(u), try gen_stamps.bits(self, &.{u}, &.{try switchRowDeps(self, i, c, react)}));
        try gen_stamps.rowSet(self, u);
        try self.b("S.sel(", .{});
        try coreRef(self, flag);
        try self.b(", c.neg(), ", .{});
        try switchElse(self, partner, react);
        try self.b(")", .{});
        try gen_stamps.rowEnd(self);
    }
    if (split) {
        try self.ind(3);
        try self.b("}}\n", .{});
        try self.ind(2);
        try self.b("}} else {{\n", .{});
        try self.ind(3);
        try self.b("const flow = ", .{});
        try switchOpen(self, partner, react);
        try self.b(";\n", .{});
        const deps = try switchRowDeps(self, i, c, react);
        try gen_stamps.stamp(self, 3, c.hi, .add, "flow", deps, null);
        try gen_stamps.stamp(self, 3, c.lo, .sub, "flow", deps, null);
        try self.ind(2);
        try self.b("}}\n", .{});
    }
}

/// Returns whether `collapse` aliases potential contribution `i` away. Keyed on the
/// branch-flow unknown, which `contribIndex` makes unique per branch.
pub fn collapsible(self: *const Gen, i: usize) bool {
    assert(i < self.names.branch_u.len);
    const u = self.names.branch_u[i];
    return u != none_u32 and self.topo.collapsible(u);
}

/// Returns `<flow unknown>__retained`: the `Model` field `derive` publishes
/// pair `k`'s retention flag in, and the name a guarded `jac_const` entry cites.
pub fn guardField(self: *const Gen, k: u32) Error![]const u8 {
    assert(k < self.topo.cpairs.len);
    return self.arena.print("{s}__retained", .{self.names.u_names[self.topo.cpairs[k].flow_u]});
}

// ---- private ----

/// Returns the `cpairs` index whose card-only flag guards contribution `i`'s
/// constants (`emitSwitchRow`), or null.
fn guardOf(self: *const Gen, i: usize) ?u32 {
    assert(i < self.names.branch_u.len);
    const u = self.names.branch_u[i];
    if (u == none_u32) return null;
    for (self.topo.cpairs, 0..) |p, k| if (p.flow_u == u) return if (p.card) @intCast(k) else null;
    return null;
}

/// One guarded constant: `g` at (row, col) of eval, under pair `k`'s guard.
/// Ground has no row and no column.
fn guardTerm(self: *Gen, row: u32, col: u32, g: f64, k: u32) Error!void {
    assert(k < self.topo.cpairs.len);
    assert(!std.math.isNan(g));
    if (row == Lower.ground or col == Lower.ground) return;
    try self.jac.guarded.append(self.arena, .{ .row = row, .col = col, .g = g, .c = 0, .when = k });
}

/// The value the branch row would have PINNED I_b to, for the arm where
/// I_b no longer exists: the partner's retained flow, or zero when nothing
/// is retained (§5.6.1.3's open circuit). `switchElse` writes the same
/// cases as a residual (`I_b − c` and `−φ`); this is that residual solved
/// for I_b, so the signs are the plain `.flow` stamp's.
fn switchOpen(self: *Gen, partner: ?usize, react: bool) Error!void {
    if (partner) |j| assert(j < self.lowered.contributions.items.len);
    const j = partner orelse return self.b("S.con(0.0)", .{});
    const f = self.lowered.contributions.items[j];
    const fv = self.an.rv(if (react) f.react_val else f.resist_val);
    switch (plan_topo.retention(self.input(), f)) {
        .off => try self.b("S.con(0.0)", .{}),
        .on => try coreRef(self, fv),
        .runtime => |fw| {
            try self.b("S.sel(", .{});
            try coreRef(self, fw);
            try self.b(", ", .{});
            try coreRef(self, fv);
            try self.b(", S.con(0.0))", .{});
        },
    }
}

/// The not-a-potential-source-this-cycle half of a selected branch row:
/// the flow form when the switch partner retained one, the open circuit
/// otherwise. `react` picks the residual: I_b/current for eval, flux for q.
fn switchElse(self: *Gen, partner: ?usize, react: bool) Error!void {
    if (partner) |j| assert(j < self.lowered.contributions.items.len);
    const open: []const u8 = if (react) "S.con(0.0)" else "ib";
    const j = partner orelse return self.b("{s}", .{open});
    const f = self.lowered.contributions.items[j];
    const fv = self.an.rv(if (react) f.react_val else f.resist_val);
    switch (plan_topo.retention(self.input(), f)) {
        // Discarded on every path: the partner entry is dead and the else
        // case is §5.6.1.3's open circuit.
        .off => try self.b("{s}", .{open}),
        // Unreachable by construction (a runtime potential flag implies a
        // conditional discard of the partner), but the general form is
        // correct if lowering ever changes: the flow is always retained.
        .on => if (react) {
            try coreRef(self, fv);
            try self.b(".neg()", .{});
        } else {
            try self.b("ib.sub(", .{});
            try coreRef(self, fv);
            try self.b(")", .{});
        },
        .runtime => |fw| {
            try self.b("S.sel(", .{});
            try coreRef(self, fw);
            if (react) {
                try self.b(", ", .{});
                try coreRef(self, fv);
                try self.b(".neg(), {s})", .{open});
            } else {
                try self.b(", ib.sub(", .{});
                try coreRef(self, fv);
                try self.b("), {s})", .{open});
            }
        },
    }
}

/// One value as the residual reads it: a core field, or the inline zero
/// `plan_core.plan` never plans (`.f_zero` has no `m.f<k>`).
fn coreRef(self: *Gen, v: Mir.Value) Error!void {
    assert(self.core.lo_idx.len == self.an.nv);
    if (v == .f_zero) return self.b("S.con(0.0)", .{});
    const k = self.core.lo_idx[@backingInt(v)];
    assert(k != none_u32); // `plan_jobs` queued every non-zero switch value.
    try self.b("m.f{d}", .{k});
}

/// Returns the columns of the row `emitSwitchRow` emits. The `S.sel` arm is
/// chosen at run time, so the row carries every arm's columns: its own
/// value, the switch partner's, and `ib`.
fn switchRowDeps(self: *const Gen, i: usize, c: Lower.Contribution, react: bool) Error![]const u64 {
    assert(i < self.names.branch_u.len);
    const own = family.mask(self, if (react) c.react_val else c.resist_val);
    const j = plan_topo.switchFlowOf(self.input(), i) orelse return gen_stamps.bits(self, &.{self.names.branch_u[i]}, &.{own});
    const f = self.lowered.contributions.items[j];
    return gen_stamps.bits(self, &.{self.names.branch_u[i]}, &.{ own, family.mask(self, if (react) f.react_val else f.resist_val) });
}
