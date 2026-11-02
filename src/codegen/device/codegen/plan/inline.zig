//! A unit's slice (`UnitPlan.needed`) -> which values render inline at
//! their use instead of taking a slot: use counts (eager uses and select-arm
//! uses apart), single-use values fused into their reader, the inline depth
//! bounded so no expression nests past `max_inline_depth`, and the
//! `pow`-exponent and §4.2.12 select-arm rules that keep a value lazy.
//! Cites: §4.2.12, §4.3.
//!
//! Contents:
//! - `pub const max_inline_depth = 256`
//! - `pub fn countUses(self: *UnitPlan, target: Mir.Value) void`
//! - `pub fn addUses(self: *UnitPlan, inst: Mir.Inst, undo: bool) void`
//! - `pub fn boundInlineDepth(self: *UnitPlan) void`
//! - `pub fn fuseSingleUse(self: *UnitPlan) void`
//! - `pub fn foldedExponent(self: *const UnitPlan, d: anytype) bool`

const std = @import("std");
const Mir = @import("ir").Mir;
const cg = @import("args.zig");
const assert = std.debug.assert;
const UnitPlan = @import("unit.zig");

/// The deepest chain of inlined operands one statement may render.
pub const max_inline_depth = 256;

const none_u32 = std.math.maxInt(u32);

/// Counts every read of the slice's values, eager and arm apart, into
/// `eager_use`/`arm_use`. Asserts that the slice is closed: outside the common
/// declaration `target` itself is in it.
pub fn countUses(self: *UnitPlan, target: Mir.Value) void {
    assert(self.eager_use.len == self.arm_use.len);
    assert(self.eager_use.len == self.an.nv);
    if (!self.in_common) assert(self.needed.isSet(@backingInt(self.an.rv(target))));
    if (self.in_common) {
        for (self.lo_vals) |v| self.eager_use[@backingInt(v)] += 1;
    } else {
        self.eager_use[@backingInt(self.an.rv(target))] += 1;
    }
    for (self.live.items) |lv| {
        // A leaf: its operands are not here.
        if (self.cached(lv) or self.isRoot(lv) or self.literal(lv)) continue;
        const def = self.mir.valueDef(lv);
        if (def != .inst_result) continue;
        addUses(self, def.inst_result, false);
    }
    if (self.straight) return;
    for (self.an.rpo) |bi| {
        const t = self.an.term[bi];
        if (t == .none) continue;
        if (self.mir.instOp(t) != .branch) continue;
        // A dead branch emits no `if`, so its condition has no use here. It
        // must not be counted, or the value would be slotted and assigned
        // with nothing reading it, which Zig rejects.
        if (self.dead_branch.isSet(bi)) continue;
        const cond = self.an.rv(self.mir.instData(t).branch.cond);
        if (!self.tested(cond)) continue;
        self.eager_use[@backingInt(cond)] += 1;
    }
}

/// `undo = false` counts, `undo = true` moves this instruction's eager uses
/// into arm uses (called when the instruction itself became lazy).
pub fn addUses(self: *UnitPlan, inst: Mir.Inst, undo: bool) void {
    assert(@backingInt(inst) < self.mir.instCount());
    assert(self.eager_use.len == self.an.nv);
    const bump = struct {
        fn f(g: *UnitPlan, v: Mir.Value, arm: bool, un: bool) void {
            const i = @backingInt(g.an.rv(v));
            assert(i < g.an.nv);
            if (!g.needed.isSet(i)) return;
            if (un) {
                if (arm) return; // already an arm use
                if (g.eager_use[i] > 0) g.eager_use[i] -= 1;
                g.arm_use[i] += 1;
            } else if (arm) {
                g.arm_use[i] += 1;
            } else {
                g.eager_use[i] += 1;
            }
        }
    }.f;
    switch (self.mir.instData(inst)) {
        .unary => |d| bump(self, d.operand, false, undo),
        .binary => |d| {
            bump(self, d.lhs, false, undo);
            if (!foldedExponent(self, d)) bump(self, d.rhs, false, undo);
        },
        .ternary => |d| {
            bump(self, d.cond, false, undo);
            bump(self, d.then_val, true, undo);
            bump(self, d.else_val, true, undo);
        },
        .call => |d| for (d.args, 0..) |a, i| {
            if (cg.callArgIsValue(d.callee, i, self.dispHere())) bump(self, a, false, undo);
        },
        .phi => |d| {
            var i: u32 = 0;
            while (i < d.count) : (i += 1) bump(self, self.mir.phiPair(inst, i).value, false, undo);
        },
        .branch, .jump, .anew => {},
        .load => |d| {
            bump(self, d.arr, false, undo);
            bump(self, d.index, false, undo);
        },
        .store => |d| {
            bump(self, d.arr, false, undo);
            bump(self, d.index, false, undo);
            bump(self, d.value, false, undo);
        },
    }
}

/// The renderer recurses once per inlined operand, so a fused chain as long
/// as the source (4096 summed contributions) overflows the compiler's stack.
/// Past `max_inline_depth` a FUSED value keeps its own statement, which is
/// where it stood before `fuseSingleUse` moved it. An arm-inlined value stays
/// inlined: it is lazy on purpose (§4.2.12).
pub fn boundInlineDepth(self: *UnitPlan) void {
    assert(self.inl_depth.len == self.eager_use.len);
    // Ascending value order is a topological order for everything that
    // inlines (operands are created before their results; a phi never
    // inlines), so every inlined operand's depth is already written.
    for (self.live.items) |lv| {
        const v = @backingInt(lv);
        if (v < Mir.Value.first_dynamic or !self.inlined.isSet(v)) continue;
        const ops: [3]Mir.Value = switch (self.mir.instData(self.mir.valueDef(lv).inst_result)) {
            .unary => |d| .{ d.operand, .undef, .undef },
            .binary => |d| .{ d.lhs, d.rhs, .undef },
            .ternary => |d| .{ d.cond, d.then_val, d.else_val },
            .load => |d| .{ d.arr, d.index, .undef },
            // A storage version renders as its array's name.
            .call, .phi, .branch, .jump, .anew, .store => @splat(.undef),
        };
        var d: u16 = 1;
        for (ops) |o0| {
            const o = @backingInt(self.an.rv(o0));
            // Saturating: an arm-inlined chain may run past a u16, and every
            // depth over `max_inline_depth` already decides the same way.
            if (o >= Mir.Value.first_dynamic and self.inlined.isSet(o)) d = @max(d, self.inl_depth[o] +| 1);
        }
        if (d > max_inline_depth and self.eager_use[v] != 0) {
            self.inlined.unset(v);
            d = 0;
        }
        // A value still inlined has a depth; a fused one past the cut kept
        // its statement, and only an arm-inlined value may run past it.
        if (self.inlined.isSet(v)) assert(d >= 1);
        if (!self.inlined.isSet(v)) assert(d == 0);
        if (self.eager_use[v] != 0) assert(d <= max_inline_depth);
        self.inl_depth[v] = d;
    }
}

/// Fuses a value read exactly once, by a later statement of its own block,
/// into that statement instead of giving it a `const`. Clearing the slot is
/// the fusion: `renderValueRef` falls through to `renderInst` for anything
/// without a slot, so chains collapse transitively.
///
/// Sound because the use is single (`eager_use == 1 and arm_use == 0`; an arm
/// use is re-rendered per arm) and only pure statements lie between, so
/// nothing moves into a loop or past a side effect. Eager uses are not undone:
/// the expression still runs once, eagerly, a little later.
pub fn fuseSingleUse(self: *UnitPlan) void {
    assert(self.eager_use.len == self.arm_use.len);
    assert(self.an.stmt_off.len == self.an.nb + 1);
    assert(self.inlined.bit_length == self.an.nv);
    for (0..self.an.nb) |bi| {
        const stmts = self.an.stmt_pool[self.an.stmt_off[bi]..self.an.stmt_off[bi + 1]];
        if (stmts.len < 2) continue;
        for (stmts[0 .. stmts.len - 1], 0..) |inst, si| {
            const v = @backingInt(self.an.rv(self.an.i_res[@backingInt(inst)]));
            if (v < Mir.Value.first_dynamic) continue;
            if (!self.needed.isSet(v) or self.inlined.isSet(v)) continue;
            if (self.eager_use[v] != 1 or self.arm_use[v] != 0) continue;
            // A live-out is a FIELD of the returned cache (same reason as
            // the sweep above), and a cached value renders as `c.fN`
            // wherever it appears, so neither is ours to fuse.
            if (self.in_common and self.lo_idx[v] != none_u32) continue;
            if (self.cached(@fromBackingInt(@intCast(v)))) continue;
            const op = self.mir.instOp(inst);
            // `call` is an operator/function evaluated once per step (§4.5)
            // and `phi` is materialised as a `var`; neither is an expression.
            if (op == .call or op == .phi) continue;
            // §3.2.2 a load may move later only past what cannot store.
            const is_load = Mir.opClass(op) == .load;
            // The user may sit further down the same block as long as every
            // statement in between is pure: a pure op reads only SSA values,
            // so sliding another past it changes nothing. A `call` or `phi`
            // stops the scan, because §4.5 operators and §9.4 prints are side
            // effects the value must not cross. This lets ifconv's spliced
            // arms sit between a comparison and the select that consumes it.
            for (stmts[si + 1 ..]) |next| {
                if (eagerlyUses(self, next, @fromBackingInt(@intCast(v)))) {
                    self.inlined.set(v);
                    break;
                }
                const nop = self.mir.instOp(next);
                if (nop == .call or nop == .phi) break;
                switch (Mir.opClass(nop)) {
                    .unary, .binary, .ternary, .load => {},
                    // A pure op reads no storage, so it slides past a store;
                    // a load does not.
                    .anew, .store => if (is_load) break,
                    .phi, .branch, .jump, .call => break,
                }
            }
        }
    }
}

/// §4.3.1 `pow(x, k)` with a constant exponent goes through the scalar's
/// `pow(S, f64)`, so the exponent is never materialised as a value.
///
/// `resolve_params = false` mirrors `Gen.renderOp`'s `.pow` arm: a parameter
/// exponent belongs to the model card, so it stays live and renders as
/// `S.con(model.<p>)`. Folding through its declared default would freeze an
/// overridden exponent at that default.
pub fn foldedExponent(self: *const UnitPlan, d: anytype) bool {
    assert(self.an.nv == self.eager_use.len);
    assert(@backingInt(d.rhs) < self.an.nv);
    return d.op == .pow and self.an.foldConst(d.rhs, false) != null;
}

// ---- private ----

/// Does `inst` read `v` in an eager position? Mirrors `addUses`, including
/// its two exclusions (a folded constant exponent is never materialised, and
/// a non-value call argument is not an operand), so the counts it is checked
/// against cannot drift from this answer. A `ternary`'s arms are lazy
/// positions, counted in `arm_use`.
fn eagerlyUses(self: *const UnitPlan, inst: Mir.Inst, v: Mir.Value) bool {
    assert(@backingInt(inst) < self.mir.instCount());
    assert(@backingInt(v) < self.an.nv);
    return switch (self.mir.instData(inst)) {
        .unary => |d| self.an.rv(d.operand) == v,
        .binary => |d| self.an.rv(d.lhs) == v or
            (!foldedExponent(self, d) and self.an.rv(d.rhs) == v),
        .ternary => |d| self.an.rv(d.cond) == v,
        .call => |d| for (d.args, 0..) |a, i| {
            if (cg.callArgIsValue(d.callee, i, self.dispHere()) and self.an.rv(a) == v) break true;
        } else false,
        .phi, .branch, .jump, .anew => false,
        .load => |d| self.an.rv(d.index) == v,
        .store => |d| self.an.rv(d.index) == v or self.an.rv(d.value) == v,
    };
}
