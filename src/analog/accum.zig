const std = @import("std");
const assert = std.debug.assert;
const Lower = @import("Lower.zig");
const lower_branch = @import("branch.zig");
const lower_hier_name = @import("hier_name.zig");
const lower_expr_access = @import("expr_access.zig");
const lower_contrib = @import("contrib.zig");
const lower_source_check = @import("source_check.zig");
const State = lower_contrib.State;
const Target = lower_branch.Target;
const Oom = Lower.Oom;
const Kind = Lower.Kind;
const Accum = Lower.Accum;

/// Returns the contribution index for a target, creating its entry and
/// accumulator on first use. A pair that receives both a potential and a flow
/// contribution (in different arms) is the §5.6.5 switch branch: two entries,
/// one per access. Asserts that a row already keyed for `t` is the
/// `.direct` row of `t`'s access and branch.
pub fn contribIndex(self: *Lower, t: Target, tok: u32) Oom!u32 {
    // §5.6.7.2 an indirectly-assigned branch is never an accumulation target,
    // so its entry can never absorb a `<+` (which `lowerIndirect` rejects
    // outright anyway): only `.direct` entries are keyed. §5.4.1: the pair
    // does not identify the branch, so `br` is part of the key. Two named
    // branches over one pair get one accumulator each; every spelling of the
    // pair's UNNAMED branch shares the one §5.4.1 Example 2 allows it.
    const st = &self.contrib_state;
    const key: State.Key = .{ .access = t.access, .hi = t.hi, .lo = t.lo, .br = t.br };
    if (st.direct.get(key)) |row| {
        const c = &self.out.contributions.items[row];
        // Only `newContrib(.direct, t)` rows are keyed, under their own key.
        assert(c.kind == .direct);
        assert(c.access == t.access);
        assert(c.br == t.br);
        if (c.unit != self.cur_unit) {
            c.shared = true;
            const gop = try st.sharers.getOrPut(self.arena, .{ .row = row, .unit = self.cur_unit });
            if (!gop.found_existing) try self.out.contrib_sharers.append(self.arena, .{ .row = row, .unit = self.cur_unit });
        }
        return row;
    }
    const row = try newContrib(self, .direct, t, tok);
    try st.direct.put(self.arena, key, row);
    return row;
}

/// §5.4.1/§5.6.8.1 one instance's share of an unnamed-branch row. Flattening
/// stamps every instance's unnamed branch over one node pair as one row (the
/// node equations only see the sum), but each instance's branch is its own,
/// so its flow read (`lower_expr_access.flowAccum`) is what THAT instance's branch
/// carries: its own `<+` plus §5.6.8.2's hierarchical contributions aimed at
/// it. Seeded in the entry block like `accum`.
///
/// Kept only once a row is shared (`Contribution.shared`): until then the row
/// IS its one writer's branch. On first use the row's own writer gets a share
/// holding everything the row accumulated so far, which was all its.
/// Asserts that `row` is shared.
pub fn unitAccum(self: *Lower, row: u32, unit: u32) Oom!Accum {
    assert(self.out.contributions.items[row].shared);
    const first = self.out.contributions.items[row].unit;
    if (!self.unit_accum.contains(.{ .row = row, .unit = first })) {
        const full = self.accum.items[row];
        const own = try unitAccumSeeded(self, row, first);
        try self.builder.writeVariable(own.resist, self.cur, try self.builder.readVariable(full.resist, self.cur));
        try self.builder.writeVariable(own.react, self.cur, try self.builder.readVariable(full.react, self.cur));
    }
    return unitAccumSeeded(self, row, unit);
}

fn unitAccumSeeded(self: *Lower, row: u32, unit: u32) Oom!Accum {
    const gop = try self.unit_accum.getOrPut(self.arena, .{ .row = row, .unit = unit });
    if (!gop.found_existing) gop.value_ptr.* = try newAccum(self);
    return gop.value_ptr.*;
}

/// Three fresh places, each seeded 0 in the entry block, which dominates
/// everything: a contribution that only happens on one arm of an `if` reads 0
/// on the other (§5.8), and per §5.6.1.3 retains nothing there, which is what
/// `wrote` starts as.
fn newAccum(self: *Lower) Oom!Accum {
    const acc: Accum = .{
        .resist = self.builder.newPlace(),
        .react = self.builder.newPlace(),
        .wrote = self.builder.newPlace(),
    };
    try self.builder.writeVariable(acc.resist, .entry, .f_zero);
    try self.builder.writeVariable(acc.react, .entry, .f_zero);
    try self.builder.writeVariable(acc.wrote, .entry, .f_zero);
    return acc;
}

/// Appends a contribution and its accumulator; the two lists stay parallel, so
/// a contribution's index is its accumulator's index.
pub fn newContrib(self: *Lower, kind: Kind, t: Target, tok: u32) Oom!u32 {
    try lower_hier_name.refuseRuntime(self, tok, t.hi, t.lo);
    assert(self.accum.items.len == self.out.contributions.items.len);
    const idx: u32 = @intCast(self.out.contributions.items.len);
    try self.out.contributions.append(self.arena, .{
        .access = t.access,
        .br = t.br,
        .tok = tok,
        .hi = t.hi,
        .lo = t.lo,
        .kind = kind,
        .unit = self.cur_unit,
    });
    if (kind == .indirect) try self.contrib_state.indirect.put(self.arena, lower_source_check.pairKey(t.hi, t.lo), {});
    try self.accum.append(self.arena, try newAccum(self));
    assert(self.accum.items.len == idx + 1);
    assert(self.out.contributions.items.len == idx + 1);
    return idx;
}

/// §5.6.1.3 "Contributing a flow to a branch which already has a value retained
/// for the potential results in the potential being discarded and the branch
/// being converted to a flow source. Similarly, contributing a potential to a
/// branch which already has a flow retained results in the flow being
/// discarded." Only contributions of the SAME kind are additive, so a kind
/// mismatch replaces rather than accumulates — which is the whole difference
/// between the clause's own worked example answering 7.0 (1 discarded by the
/// flow, the flow discarded by the 3, then 3 + 4) and answering 8.0.
///
/// Zeroing the other accumulator is enough: codegen emits no row for a
/// contribution whose value folds to zero. Under a conditional the discard and
/// the cleared `wrote` flag survive as phis, which is the §5.6.5 switch branch:
/// codegen picks the row's content at run time from both flags.
pub fn discardOpposite(self: *Lower, t: Target) Oom!void {
    // §5.6.1.3 is stated of "a branch", so only the OTHER quantity of THIS
    // branch is discarded: `br` is in the key, and a parallel named branch over
    // the same pair is a different source that keeps what it retained.
    const ci = lower_contrib.directRow(self, lower_contrib.oppositeKey(t)) orelse return;
    // So is a parallel instance over the same pair. §5.4.1 gives branch
    // identity per module instance, and flattening collapses every
    // instance's unnamed branch onto the node pair: without this, a load
    // wired across a source would delete the source.
    if (self.out.contributions.items[ci].unit != self.cur_unit) return;
    const acc = self.accum.items[ci];
    try self.builder.writeVariable(acc.resist, self.cur, .f_zero);
    try self.builder.writeVariable(acc.react, self.cur, .f_zero);
    try self.builder.writeVariable(acc.wrote, self.cur, .f_zero);
    if (self.unit_accum.get(.{ .row = ci, .unit = self.cur_unit })) |pa| {
        try self.builder.writeVariable(pa.resist, self.cur, .f_zero);
        try self.builder.writeVariable(pa.react, self.cur, .f_zero);
    }
    // The discarded charge goes with its sites.
    for (self.out.charge_sites.items, self.site_places.items) |s, p| {
        if (s.contrib == ci) try self.builder.writeVariable(p, self.cur, .f_zero);
    }
}
