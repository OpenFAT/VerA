//! A unit's slice and its CFG -> the branches the unit cannot tell apart
//! (`UnitPlan.dead_branch`: both arms reach the same join with nothing this
//! unit computes, so no `if` is emitted and the condition is never live), how
//! each CFG edge leaves its block once empty blocks are skipped (`edgeAct`),
//! and whether the unit is straight-line code.
//! Cites: §5.8.
//!
//! Contents:
//! - `pub fn isStraightLine(self: *const UnitPlan) bool`
//! - `pub fn planDeadBranches(self: *UnitPlan) void`

const std = @import("std");
const Mir = @import("ir").Mir;
const assert = std.debug.assert;
const UnitPlan = @import("unit.zig");

const none_u32 = std.math.maxInt(u32);

/// How a CFG edge leaves its block once empty blocks are skipped: `continue`
/// to a loop header or `break` to a merge label (`edgeAct`).
const Act = union(enum) { cont: u32, brk: u32 };

/// Returns true when the slice lives entirely in the entry block and uses no
/// phi, so the unit emits flat `const` code. Valid after `analyze` marked the
/// slice.
pub fn isStraightLine(self: *const UnitPlan) bool {
    assert(self.needed.bit_length == self.an.nv);
    for (self.live.items) |lv| {
        const v = @backingInt(lv);
        assert(self.needed.isSet(v)); // `mark` adds to `live` what it marks
        if (v < Mir.Value.first_dynamic) continue;
        // A cache or Instance-field read is a field of a value the body
        // already holds, so it has no block of its own.
        if (self.cached(lv) or self.isRoot(lv)) continue;
        const db = self.homeBlock(v);
        if (db != none_u32 and db != 0) return false;
        const def = self.mir.valueDef(lv);
        if (def == .inst_result and self.mir.instOp(def.inst_result) == .phi) return false;
    }
    return true;
}

/// Marks in `dead_branch` every `branch` this unit cannot tell apart.
///
/// A branch is dead here when both edges reduce to the same control action
/// once the empty blocks between are skipped, and neither copies a phi on the
/// way. The unit then computes the same values and reaches the same place
/// whichever arm runs, so the condition is unobservable and the `if` goes.
pub fn planDeadBranches(self: *UnitPlan) void {
    assert(self.blk_work.bit_length == self.an.nb);
    assert(self.blk_phi.bit_length == self.an.nb);
    assert(self.dead_branch.bit_length == self.an.nb);
    self.blk_work.unsetAll();
    self.blk_phi.unsetAll();
    for (self.live.items) |lv| {
        const v = @backingInt(lv);
        if (v < Mir.Value.first_dynamic) continue;
        const db = self.homeBlock(v);
        if (db == none_u32) continue;
        // A phi marks its block even when cached: `blk_phi` means "the two
        // arms disagree at this SSA join", a property of the CFG and the
        // value, not of whether this unit reads the result from the cache.
        // A setup root's value is the same whichever way the unit goes
        // (`setup` decided every branch it depends on), so neither its phi
        // copies nor its block are work here.
        if (self.isRoot(lv)) continue;
        const def = self.mir.valueDef(lv);
        if (def == .inst_result and self.an.i_op[@backingInt(def.inst_result)] == .phi)
            self.blk_phi.set(db);
        // A cache read has no block of its own.
        if (self.cached(lv)) continue;
        self.blk_work.set(db);
    }
    self.dead_branch.unsetAll();
    // Innermost first (reverse RPO), so an arm whose only content is a branch
    // already found dead reads as the jump it will be emitted as (`edgeAct`).
    var k = self.an.rpo.len;
    while (k > 0) {
        k -= 1;
        const bi = self.an.rpo[k];
        assert(bi < self.an.nb);
        const t = self.an.term[bi];
        if (t == .none or self.mir.instOp(t) != .branch) continue;
        const d = self.mir.instData(t).branch;
        const a = edgeAct(self, bi, @backingInt(d.then_block)) orelse continue;
        const b2 = edgeAct(self, bi, @backingInt(d.else_block)) orelse continue;
        if (std.meta.eql(a, b2)) self.dead_branch.set(bi);
    }
}

// ---- private ----

/// Returns the control action the edge `from0 -> to0` reduces to once empty
/// inline blocks are skipped, or null when the edge copies a phi, does work
/// this unit observes, or nests deeper than the walk tracks. Reads
/// `blk_work`/`blk_phi`/`dead_branch`, so it is valid only inside
/// `planDeadBranches` or after it.
fn edgeAct(self: *const UnitPlan, from0: u32, to0: u32) ?Act {
    assert(from0 < self.an.nb);
    assert(to0 < self.an.nb);
    var from = from0;
    var to = to0;
    var hops: u32 = 0;
    // Merge blocks whose labels a block walked through here opened: the walk
    // reaching one continues into it, because it is emitted INLINE right
    // after its label closes (`cfg.emitTree`), not broken to from outside.
    // ponytail: a fixed 32; a deeper nest answers null, the safe side.
    var opened: [32]u32 = undefined;
    var n_open: usize = 0;
    while (hops <= self.an.nb) : (hops += 1) {
        // A phi in `to` means `emitPhiCopies` copies a value on this edge, which
        // is the one thing the two arms cannot share.
        if (self.blk_phi.isSet(to)) return null;
        if (self.an.is_loop[to] and self.an.dominates(to, from)) return .{ .cont = to };
        if (self.an.is_merge[to] and std.mem.findScalar(u32, opened[0..n_open], to) == null) return .{ .brk = to };
        // Otherwise `to` is emitted INLINE here, so it has to be empty and
        // end in a plain jump for the two arms to stay indistinguishable.
        //
        // §5.9 and NOT inside a loop, even when empty. "Empty of values
        // this unit computes" is not "no effect" on a back edge: the arms
        // decide which loop-carried phi values get copied on the way round,
        // and `blk_phi` only guards a phi's own block. A loop-carried phi the
        // unit reads from the cache leaves it clear, so the two arms are not
        // interchangeable (the hazard `markRecomputedLoops` handles).
        if (self.an.is_loop[to] or self.an.inLoop(to) or self.blk_work.isSet(to)) return null;
        const labels = self.an.mk_pool[self.an.mk_off[to]..self.an.mk_off[to + 1]];
        if (n_open + labels.len > opened.len) return null;
        @memcpy(opened[n_open..][0..labels.len], labels);
        n_open += labels.len;
        assert(n_open <= opened.len);
        const t = self.an.term[to];
        if (t == .none) return null;
        from = to;
        // A dead branch emits as the edge to its `then` block (`emitTerm`).
        to = switch (self.mir.instOp(t)) {
            .jump => @backingInt(self.mir.instData(t).jump.target),
            .branch => if (self.dead_branch.isSet(to)) @backingInt(self.mir.instData(t).branch.then_block) else return null,
            else => return null, // else: a terminator is a jump or a branch; anything else ends the walk
        };
    }
    return null;
}
