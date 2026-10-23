//! If-conversion: MIR → the same MIR with each pure CFG diamond or triangle
//! replaced by straight-line code and one §4.2.12 `select` per join phi, to a
//! fixpoint. Two passes (`Mode`). Before the proof an arm converts only when
//! every instruction is a pure value op (no call, `opt_barrier`, store or
//! domain-restricted op), so §4.2.3's "side effects shall not occur" holds by
//! construction. After a proof that rated every unit `.strict`, `.speculate`
//! also converts arms of several blocks and arms holding a domain-restricted
//! op, each such row guarded (`Mir.guard_of`) so it reports and runs out of
//! its domain only where the source ran it. Moved rows are relinked; orphaned
//! terminators and emptied arm blocks stay behind, unreachable.
//!
//! LRM clauses this file's code cites: §2.9, §4.2.4, §4.2.5, §4.2.8, §4.3.2,
//! §5.2.1, §5.10.2.

const std = @import("std");
const Mir = @import("ir").Mir;
const proof = @import("proof.zig");

/// Which arms a pass converts.
pub const Mode = enum {
    /// Before the proof: pure arms of one block each.
    pure,
    /// After a proof that rated every unit `.strict` (`src/Compilation.zig`), where a
    /// discarded arm's NaN or inf is IEEE-defined: also arms that run through
    /// a chain of single-entry blocks (a nested conversion leaves its old
    /// block and join behind as two) and arms holding a domain-restricted op,
    /// on a condition that varies with the solve. A condition the model card
    /// alone decides keeps its branch: every evaluation takes the same arm.
    speculate,
};

/// Converts every pure diamond, to a fixpoint, and returns how many converted.
/// Blocks are visited in index order, so equal MIR converts identically.
/// `gpa` backs one temporary per-block pred count and the emitted rows.
/// Invalidates every `Mir.InstIterator` and any `Analysis` built over `mir`.
pub fn run(gpa: std.mem.Allocator, mir: *Mir) !u32 {
    return runMode(gpa, mir, .pure, null);
}

/// `run` under `mode`. `.speculate` also writes `mir.guard_of`, and leaves
/// a diamond alone when `keep` holds one of its join phis (`keepSlice`).
pub fn runMode(gpa: std.mem.Allocator, mir: *Mir, mode: Mode, keep: ?*const std.DynamicBitSetUnmanaged) !u32 {
    const nb = mir.blockCount();
    if (nb == 0) return 0;
    const preds = try gpa.alloc(u32, nb);
    defer gpa.free(preds);

    var converted: u32 = 0;
    var changed = true;
    while (changed) {
        changed = false;
        countPreds(mir, preds);
        var b: u32 = 0;
        while (b < nb) : (b += 1) {
            if (try tryConvert(gpa, mir, @fromBackingInt(@intCast(b)), preds, mode, keep)) {
                converted += 1;
                // Each conversion retires one block's branch and adds none.
                std.debug.assert(converted <= nb);
                changed = true;
            }
        }
    }
    return converted;
}

/// The values `roots` read, transitively: operands, call arguments and phi
/// incomings, one bit per `Mir.Value`. `src/Compilation.zig` passes it to
/// `.speculate` for the `.optimized` units' contributions, whose code may
/// run a speculated arm under fast-math, where an out-of-domain NaN is
/// poison. Caller owns the set.
pub fn keepSlice(gpa: std.mem.Allocator, mir: *const Mir, roots: []const Mir.Value) !std.DynamicBitSetUnmanaged {
    var seen = try std.DynamicBitSetUnmanaged.initEmpty(gpa, mir.defs.len + Mir.Value.first_dynamic);
    errdefer seen.deinit(gpa);
    var stack: std.ArrayList(Mir.Value) = .empty;
    defer stack.deinit(gpa);
    try stack.appendSlice(gpa, roots);
    while (stack.pop()) |v0| {
        const v = mir.resolveAlias(v0);
        const i = @backingInt(v);
        if (seen.isSet(i)) continue;
        seen.set(i);
        const def = mir.valueDef(v);
        if (def != .inst_result) continue;
        const inst = def.inst_result;
        switch (mir.instData(inst)) {
            .unary => |u| try stack.append(gpa, u.operand),
            .binary => |d| try stack.appendSlice(gpa, &.{ d.lhs, d.rhs }),
            .ternary => |d| try stack.appendSlice(gpa, &.{ d.cond, d.then_val, d.else_val }),
            .call => |d| try stack.appendSlice(gpa, d.args),
            .load => |d| try stack.appendSlice(gpa, &.{ d.arr, d.index }),
            .store => |d| try stack.appendSlice(gpa, &.{ d.arr, d.index, d.value }),
            .phi => |d| for (0..d.count) |k| try stack.append(gpa, mir.phiPair(inst, @intCast(k)).value),
            .anew, .branch, .jump => {},
        }
    }
    return seen;
}

/// §5.2.1 `analog initial` and §5.10.2 `initial_step`: the branch on the
/// first-evaluation flag stays a branch. Its join phi, `phi(held read,
/// assigned value)`, is what codegen's setup split recognises as initial-only
/// work and computes once; a `select` on the flag would run every evaluation.
fn firstPoint(mir: *const Mir, cond: Mir.Value) bool {
    const def = mir.valueDef(mir.resolveAlias(cond));
    if (def != .inst_result or mir.instOp(def.inst_result) != .call) return false;
    const d = mir.instData(def.inst_result).call;
    // VerA's `vera_timepoint` (§2.9): a select would run the cached arm.
    return d.callee == .analog_initial or d.callee == .@"$tp_hit" or (d.callee == .initial_step and d.args.len == 0);
}

/// Whether `v` is computed from constants and model parameters alone, so
/// every evaluation of one card branches the same way on it. A probe, call,
/// phi or load answers false, and so does a tree past `budget` visits: false
/// only costs a branch its `.speculate` refusal.
fn cardOnly(mir: *const Mir, v0: Mir.Value, budget: *u32) bool {
    if (budget.* == 0) return false;
    budget.* -= 1;
    const v = mir.resolveAlias(v0);
    return switch (mir.valueDef(v)) {
        .float_const, .int_const, .str_const, .param_ref => true,
        .undef, .block_param => false,
        .inst_result => |inst| switch (mir.instData(inst)) {
            .unary => |u| cardOnly(mir, u.operand, budget),
            .binary => |d| cardOnly(mir, d.lhs, budget) and cardOnly(mir, d.rhs, budget),
            .ternary => |d| cardOnly(mir, d.cond, budget) and cardOnly(mir, d.then_val, budget) and
                cardOnly(mir, d.else_val, budget),
            .phi, .call, .anew, .load, .store, .branch, .jump => false,
        },
    };
}

fn countPreds(mir: *const Mir, preds: []u32) void {
    @memset(preds, 0);
    for (0..preds.len) |b| {
        var it = mir.blockInsts(@fromBackingInt(@intCast(b)));
        while (it.next()) |inst| {
            switch (mir.instData(inst)) {
                .branch => |d| {
                    preds[@backingInt(d.then_block)] += 1;
                    preds[@backingInt(d.else_block)] += 1;
                },
                .jump => |d| preds[@backingInt(d.target)] += 1,
                .unary, .binary, .ternary, .phi, .call, .anew, .load, .store => {},
            }
        }
    }
}

/// One side of a diamond: the blocks from the arm's head to `last`, which
/// jumps to `join`.
const Side = struct { last: Mir.Block, join: Mir.Block };

/// Validate one side: a single-pred all-pure block ending in a jump, or under
/// `.speculate` a chain of them (each jumping to the next, the next entered
/// only from there). Returns null on any disqualifier. Does not mutate: both
/// sides validate before either moves.
fn classifyChain(mir: *const Mir, x: Mir.Block, head: Mir.Block, preds: []const u32, mode: Mode) ?Side {
    var b = head;
    // A chain visits each block once: one more step than blocks is a cycle.
    for (0..preds.len) |_| {
        const next = classifyArm(mir, x, b, preds, mode) orelse return null;
        if (mode == .pure or preds[@backingInt(next)] != 1) return .{ .last = b, .join = next };
        b = next;
    }
    return null;
}

/// Validates one block of an arm; returns the block it jumps to.
fn classifyArm(mir: *const Mir, x: Mir.Block, arm: Mir.Block, preds: []const u32, mode: Mode) ?Mir.Block {
    if (arm == x) return null; // back edge to the branching block itself
    if (preds[@backingInt(arm)] != 1) return null;
    var join: ?Mir.Block = null;
    var it = mir.blockInsts(arm);
    while (it.next()) |inst| {
        // A collapsed phi row is dead wherever it sits (ssa.zig mints phis
        // after the terminator), so `.speculate` moves it with the block.
        if (mode == .speculate and mir.instOp(inst) == .phi and
            mir.resolveAlias(mir.instResult(inst)) != mir.instResult(inst)) continue;
        if (join != null) return null; // an inst after the terminator (live phi rows land here)
        switch (mir.instData(inst)) {
            .unary => |u| if (u.op == .opt_barrier) return null,
            // §3.2.2 a load is a pure read of the version it names, so it may
            // move into X. A store may not: both arms' versions would be live
            // at the join, and a `select` of two versions of one storage has
            // nothing to select between (`Mir.Opcode.store`).
            .binary, .ternary, .load => {},
            .anew, .store => return null,
            .jump => |d| join = d.target,
            // A collapsed phi row is dead (the alias is the rewrite); a live one
            // in a single-pred block cannot exist (trivial-phi removal), so it
            // disqualifies rather than being trusted never to happen.
            .phi => if (mir.resolveAlias(mir.instResult(inst)) == mir.instResult(inst)) return null,
            .call, .branch => return null,
        }
        // §4.2.12 before the proof a domain-restricted op (ln, sqrt, pow,
        // integer /, …) keeps its diamond: as a CFG arm the edge guards every
        // value it dominates, which `Prover.markSelectArms` cannot, and the
        // proof's verdict (a unit's float mode, an E06xx refusal) reads that
        // evidence. After it, `.speculate` moves the op and guards it.
        if (mode == .pure and proof.domainOf(mir.instOp(inst)) != .all) return null;
    }
    const j = join orelse return null;
    if (j == x or j == arm) return null;
    return j;
}

fn tryConvert(gpa: std.mem.Allocator, mir: *Mir, x: Mir.Block, preds: []u32, mode: Mode, keep: ?*const std.DynamicBitSetUnmanaged) !bool {
    const term = terminator(mir, x) orelse return false;
    if (mir.instOp(term) != .branch) return false;
    const br = mir.instData(term).branch;
    if (br.then_block == br.else_block) return false;
    if (firstPoint(mir, br.cond)) return false;
    if (mode == .speculate) {
        var budget: u32 = 256;
        if (cardOnly(mir, br.cond, &budget)) return false;
    }

    // Resolve the two sides. At least one must be a real arm; the other may be
    // the join itself (triangle from `&&`/`||` and one-armed `if`).
    const then_c = classifyChain(mir, x, br.then_block, preds, mode);
    const else_c = classifyChain(mir, x, br.else_block, preds, mode);
    var join: Mir.Block = undefined;
    var then_arm: ?Side = null;
    var else_arm: ?Side = null;
    if (then_c != null and else_c != null and then_c.?.join == else_c.?.join) {
        join = then_c.?.join;
        then_arm = then_c;
        else_arm = else_c;
    } else if (then_c != null and then_c.?.join == br.else_block) {
        join = br.else_block; // triangle: else edge is direct
        then_arm = then_c;
    } else if (else_c != null and else_c.?.join == br.then_block) {
        join = br.then_block; // triangle: then edge is direct
        else_arm = else_c;
    } else return false;
    std.debug.assert(join != x); // `classifyArm` refuses a join back into X

    // Validate every live phi in the join: it must carry a pair for each side
    // of this diamond, or the conversion cannot rewrite it.
    const then_key: Mir.Block = if (then_arm) |a| a.last else x;
    const else_key: Mir.Block = if (else_arm) |a| a.last else x;
    {
        var it = mir.blockInsts(join);
        while (it.next()) |inst| {
            if (mir.instOp(inst) != .phi) continue;
            const r = mir.instResult(inst);
            if (mir.resolveAlias(r) != r) continue; // collapsed: dead row
            if (mir.phiIn(inst, then_key) == null) return false;
            if (mir.phiIn(inst, else_key) == null) return false;
            if (keep) |k| if (k.isSet(@backingInt(r))) return false;
        }
    }

    // ---- mutation ----------------------------------------------------------
    // Emitted rows inherit the branch's provenance token.
    mir.cur_tok = mir.instTok(term);

    // The cond is peeled of `toBool` wrappers first: a select condition means
    // "nonzero ⇒ then" (codegen's renderCond), which is exactly what
    // `ine(x, 0)` asserts of x, so the wrapper adds nothing, and peeling it
    // leaves the bare comparison as the select's cond, where codegen can
    // render it as a lane-true S mask instead of an i64 round-trip.
    const cond = peelToBool(mir, br.cond);

    // Drop the branch row from X's chain, then splice each arm's blocks in,
    // in order. Late phi rows after the branch stay linked. Each block's jump
    // is orphaned with the branch. Under `.speculate` a domain-restricted row
    // takes this arm's literal as the outermost of its guard.
    mir.unlink(x, term);
    for ([_]Mir.Block{ br.then_block, br.else_block }, [_]?Side{ then_arm, else_arm }, [_]bool{ true, false }) |head, arm, taken| if (arm) |a| {
        var b = head;
        for (0..preds.len) |_| {
            const jmp = terminator(mir, b).?;
            const next = mir.instData(jmp).jump.target;
            if (mode == .speculate) {
                var it = mir.blockInsts(b);
                while (it.next()) |inst| if (proof.domainOf(mir.instOp(inst)) != .all)
                    try mir.addGuardLit(gpa, inst, cond, taken);
            }
            mir.unlink(b, jmp);
            mir.splice(x, b);
            if (b == a.last) break;
            b = next;
        } else unreachable; // `classifyChain` walked this chain to `a.last`
    };

    // One select per live join phi, then the fall-through jump.
    var phis = mir.blockInsts(join);
    while (phis.next()) |phi| {
        if (mir.instOp(phi) != .phi) continue;
        const result = mir.instResult(phi);
        if (mir.resolveAlias(result) != result) continue;
        const vt = mir.phiIn(phi, then_key).?;
        const ve = mir.phiIn(phi, else_key).?;
        const sel = try mir.emit(gpa, x, .select, &.{ cond, vt, ve });
        // emit may relocate the borrowed column; the cursor itself is an index.
        phis.next_col = mir.insts.items(.next);
        rewritePhi(mir, phi, then_key, else_key, x, sel);
    }
    _ = try mir.emitJump(gpa, x, join);
    return true;
}

/// Strip nested `ine(x, 0)` wrappers, but only when x is itself a predicate
/// (§4.2.5/§4.2.8 comparison or lognot). Value-wise any peel is safe, but
/// the prover's `condFacts` mines a bare `ine(x, 0)` for the §4.2.4
/// nonzero-divisor fact; peeling a non-predicate x would silently un-guard
/// `b != 0 ? a/b : 0`.
fn peelToBool(mir: *const Mir, cond0: Mir.Value) Mir.Value {
    var cond = cond0;
    while (true) {
        const def = mir.valueDef(mir.resolveAlias(cond));
        if (def != .inst_result) return cond;
        if (mir.instOp(def.inst_result) != .ine) return cond;
        const d = mir.instData(def.inst_result).binary;
        if (mir.resolveAlias(d.rhs) != .zero) return cond;
        if (!proof.isPredicateValue(mir, d.lhs)) return cond;
        cond = d.lhs;
    }
}

/// `b`'s branch or jump, found by opcode and not by position: a phi row can
/// sit after the terminator (ssa.zig mints phis on demand), which is also why
/// analysis.buildCfg searches the same way.
fn terminator(mir: *const Mir, b: Mir.Block) ?Mir.Inst {
    var it = mir.blockInsts(b);
    while (it.next()) |inst| switch (Mir.opClass(mir.instOp(inst))) {
        .branch, .jump => return inst,
        .unary, .binary, .ternary, .phi, .call, .anew, .load, .store => {},
    };
    return null;
}

/// Replace this phi's diamond pairs with one `(x, sel)` pair; if that leaves a
/// single incoming value the phi collapses to an alias, exactly like ssa.zig's
/// trivial-phi removal.
fn rewritePhi(mir: *Mir, phi: Mir.Inst, then_key: Mir.Block, else_key: Mir.Block, x: Mir.Block, sel: Mir.Value) void {
    std.debug.assert(then_key != else_key); // two distinct edges into the join
    const d = mir.instData(phi).phi;
    var count: u32 = 0;
    // Validation found both edges: replacing them by one always fits. Payload
    // regions belong to individual instructions; compact only this phi's region.
    for (0..d.count) |k| {
        const p = mir.phiPair(phi, @intCast(k));
        if (p.block == then_key or p.block == else_key) continue;
        mir.extra.items[d.start + count * 2] = @backingInt(p.block);
        mir.extra.items[d.start + count * 2 + 1] = @backingInt(p.value);
        count += 1;
    }
    std.debug.assert(count + 2 <= d.count); // both edges' pairs were dropped
    mir.extra.items[d.start + count * 2] = @backingInt(x);
    mir.extra.items[d.start + count * 2 + 1] = @backingInt(sel);
    mir.insts.items(.a)[@backingInt(phi)] = count + 1; // a phi's pair count
    // Even dead phis must hold the new pairs: proof evaluates their operands.
    if (count == 0) mir.setAlias(mir.instResult(phi), sel);
}

test "phi compaction preserves unrelated edges and neighboring payloads" {
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    const entry = try mir.addBlock(a);
    const left = try mir.addBlock(a);
    const right = try mir.addBlock(a);
    const join = try mir.addBlock(a);
    const result = try mir.emitPhi(a, join, &.{
        .{ .block = left, .value = .zero },
        .{ .block = entry, .value = .one },
        .{ .block = right, .value = .one },
    });
    const phi = mir.valueDef(result).inst_result;
    const neighbor = try mir.addExtra(a, &.{ 17, 23 });
    const size = mir.extra.items.len;
    rewritePhi(&mir, phi, left, right, join, .zero);
    try std.testing.expectEqual(size, mir.extra.items.len);
    try std.testing.expectEqual(@as(u32, 2), mir.instData(phi).phi.count);
    try std.testing.expectEqual(Mir.PhiPair{ .block = entry, .value = .one }, mir.phiPair(phi, 0));
    try std.testing.expectEqual(Mir.PhiPair{ .block = join, .value = .zero }, mir.phiPair(phi, 1));
    try std.testing.expectEqual(result, mir.resolveAlias(result));
    rewritePhi(&mir, phi, entry, join, entry, .one);
    try std.testing.expectEqual(Mir.Value.one, mir.resolveAlias(result));
    try std.testing.expectEqual(Mir.PhiPair{ .block = entry, .value = .one }, mir.phiPair(phi, 0));
    try std.testing.expectEqual(size, mir.extra.items.len);
    try std.testing.expectEqualSlices(u32, &.{ 17, 23 }, mir.extra.items[neighbor..]);
}

test "if conversion refreshes phi iterator when select emission grows instruction columns" {
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    const entry = try mir.addBlock(a);
    const left = try mir.addBlock(a);
    const right = try mir.addBlock(a);
    const join = try mir.addBlock(a);
    const cond = try mir.addBlockParam(a, 0);
    _ = try mir.emitBranch(a, entry, cond, left, right);
    const lv = try mir.emit(a, left, .fadd, &.{ .f_one, .f_two });
    _ = try mir.emitJump(a, left, join);
    const rv = try mir.emit(a, right, .fmul, &.{ .f_two, .f_two });
    _ = try mir.emitJump(a, right, join);
    const left_values = [_]Mir.Value{ lv, .f_one };
    const right_values = [_]Mir.Value{ rv, .f_two };
    var results: [2]Mir.Value = undefined;
    for (&results, left_values, right_values) |*result, l, r| result.* = try mir.emitPhi(a, join, &.{
        .{ .block = left, .value = l },
        .{ .block = right, .value = r },
    });

    // The first select must grow the SoA allocation. A cached .next slice
    // then points into freed/relocated columns while more join phis remain.
    try mir.insts.setCapacity(a, mir.insts.len);
    const old_capacity = mir.insts.capacity;
    try std.testing.expectEqual(mir.insts.len, old_capacity);
    try std.testing.expectEqual(@as(u32, 1), try run(a, &mir));
    try std.testing.expect(mir.insts.capacity > old_capacity);

    for (results, left_values, right_values) |result, l, r| {
        const selected = mir.resolveAlias(result);
        try std.testing.expect(selected != result);
        const inst = mir.valueDef(selected).inst_result;
        try std.testing.expectEqual(Mir.Opcode.select, mir.instOp(inst));
        const select = mir.instData(inst).ternary;
        try std.testing.expectEqual(cond, select.cond);
        try std.testing.expectEqual(l, select.then_val);
        try std.testing.expectEqual(r, select.else_val);
    }
    var selects: u32 = 0;
    var insts = mir.blockInsts(entry);
    while (insts.next()) |inst| if (mir.instOp(inst) == .select) {
        selects += 1;
    };
    try std.testing.expectEqual(@as(u32, 2), selects);
    try std.testing.expectEqual(join, mir.instData(terminator(&mir, entry).?).jump.target);
}

test "a phi row after the branch neither blocks the conversion nor leaves the chain" {
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    const pre = try mir.addBlock(a);
    const entry = try mir.addBlock(a);
    const left = try mir.addBlock(a);
    const right = try mir.addBlock(a);
    const join = try mir.addBlock(a);
    const cond = try mir.addBlockParam(a, 0);
    _ = try mir.emitJump(a, pre, entry);
    _ = try mir.emitBranch(a, entry, cond, left, right);
    // A phi minted on demand sits after the terminator.
    const late = try mir.emitPhi(a, entry, &.{.{ .block = pre, .value = cond }});
    const lv = try mir.emit(a, left, .fadd, &.{ .f_one, .f_two });
    _ = try mir.emitJump(a, left, join);
    const rv = try mir.emit(a, right, .fmul, &.{ .f_two, .f_two });
    _ = try mir.emitJump(a, right, join);
    _ = try mir.emitPhi(a, join, &.{ .{ .block = left, .value = lv }, .{ .block = right, .value = rv } });

    try std.testing.expectEqual(@as(u32, 1), try run(a, &mir));
    var saw_late = false;
    var it = mir.blockInsts(entry);
    while (it.next()) |inst| {
        if (mir.instResult(inst) == late) saw_late = true;
        try std.testing.expect(mir.instOp(inst) != .branch);
    }
    try std.testing.expect(saw_late);
    try std.testing.expectEqual(join, mir.instData(terminator(&mir, entry).?).jump.target);
}

/// Test scaffold: `entry: branch (p > 0) then else; arm: one row, jump join;
/// join: phi`. An arm of kind `.direct` is the edge straight to the join (a
/// triangle), carrying a value computed in the entry block.
const Shape = struct {
    mir: Mir = .{},
    entry: Mir.Block = .entry,
    then_b: Mir.Block = .entry,
    else_b: Mir.Block = .entry,
    join: Mir.Block = .entry,
    phi: Mir.Value = .undef,
    then_val: Mir.Value = .undef,
    else_val: Mir.Value = .undef,

    const Arm = enum { direct, value, call, store, barrier, sqrt, fmod, fdiv };

    fn init(a: std.mem.Allocator, then_arm: Arm, else_arm: Arm) !Shape {
        var s: Shape = .{};
        errdefer s.mir.deinit(a);
        const m = &s.mir;
        s.entry = try m.addBlock(a);
        const p = try m.addBlockParam(a, 0);
        const c = try m.emit(a, s.entry, .fgt, &.{ p, .f_zero });
        const entry_val = try m.emit(a, s.entry, .fneg, &.{p});
        s.join = try m.addBlock(a);
        s.then_b = if (then_arm == .direct) s.join else try m.addBlock(a);
        s.else_b = if (else_arm == .direct) s.join else try m.addBlock(a);
        _ = try m.emitBranch(a, s.entry, c, s.then_b, s.else_b);
        s.then_val = if (then_arm == .direct) entry_val else try fillArm(a, m, s.then_b, s.join, p, then_arm);
        s.else_val = if (else_arm == .direct) entry_val else try fillArm(a, m, s.else_b, s.join, p, else_arm);
        s.phi = try m.emitPhi(a, s.join, &.{
            .{ .block = if (then_arm == .direct) s.entry else s.then_b, .value = s.then_val },
            .{ .block = if (else_arm == .direct) s.entry else s.else_b, .value = s.else_val },
        });
        return s;
    }

    fn fillArm(a: std.mem.Allocator, m: *Mir, arm: Mir.Block, join: Mir.Block, p: Mir.Value, kind: Arm) !Mir.Value {
        const v = switch (kind) {
            .direct => unreachable,
            .value => try m.emit(a, arm, .fmul, &.{ p, .f_two }),
            .call => try m.emitCall(a, arm, try m.internString(a, "$abstime"), &.{}),
            // The pass reads only the opcode, so the operands need not be an
            // array version.
            .store => try m.emit(a, arm, .store, &.{ p, .zero, p }),
            .barrier => try m.emit(a, arm, .opt_barrier, &.{p}),
            .sqrt => try m.emit(a, arm, .sqrt, &.{p}),
            .fmod => try m.emit(a, arm, .fmod, &.{ p, .f_two }),
            .fdiv => try m.emit(a, arm, .fdiv, &.{ .f_one, p }),
        };
        _ = try m.emitJump(a, arm, join);
        return v;
    }

    /// The select the join phi now aliases to, or null if it is still a phi.
    fn select(s: *const Shape) ?Mir.InstData {
        const r = s.mir.resolveAlias(s.phi);
        if (r == s.phi) return null;
        return s.mir.instData(s.mir.valueDef(r).inst_result);
    }
};

test "if-conversion: a diamond and both triangles become one select" {
    const a = std.testing.allocator;
    // §4.2.12: `cond ? then : else`, with a direct edge's value read in X.
    for ([_][2]Shape.Arm{ .{ .value, .value }, .{ .value, .direct }, .{ .direct, .value } }) |arms| {
        var s = try Shape.init(a, arms[0], arms[1]);
        defer s.mir.deinit(a);
        try std.testing.expectEqual(@as(u32, 1), try run(a, &s.mir));
        const sel = s.select().?.ternary;
        try std.testing.expectEqual(s.then_val, sel.then_val);
        try std.testing.expectEqual(s.else_val, sel.else_val);
        // X now jumps to the join, and no branch is left in it.
        try std.testing.expectEqual(s.join, s.mir.instData(terminator(&s.mir, .entry).?).jump.target);
        // A second run finds nothing more: the pass is at its fixpoint.
        try std.testing.expectEqual(@as(u32, 0), try run(a, &s.mir));
    }
}

test "if-conversion: an arm that is not pure value code keeps its branch" {
    const a = std.testing.allocator;
    // A call, a §3.2.2 store, the optimization fence and the domain-restricted
    // `sqrt` and `%` refuse; IEEE `x/0` is not a domain error, so `/` converts.
    const cases = [_]struct { Shape.Arm, u32 }{
        .{ .call, 0 },
        .{ .store, 0 },
        .{ .barrier, 0 },
        .{ .sqrt, 0 },
        .{ .fmod, 0 },
        .{ .fdiv, 1 },
    };
    for (cases) |c| {
        errdefer std.debug.print("arm `{s}`\n", .{@tagName(c[0])});
        var s = try Shape.init(a, c[0], .value);
        defer s.mir.deinit(a);
        try std.testing.expectEqual(c[1], try run(a, &s.mir));
        try std.testing.expectEqual(c[1] == 1, s.select() != null);
    }
}

test "if-conversion: a first-evaluation guard stays a branch" {
    // §5.2.1 `analog initial`, VerA's `$tp_hit` cache, and an argument-less
    // §5.10.2 `initial_step`; `initial_step("tran")` is an ordinary condition.
    const a = std.testing.allocator;
    const guards = [_]struct { []const u8, bool, u32 }{
        .{ "analog_initial", false, 0 },
        .{ "$tp_hit", true, 0 },
        .{ "initial_step", false, 0 },
        .{ "initial_step", true, 1 },
    };
    for (guards) |g| {
        errdefer std.debug.print("guard `{s}`\n", .{g[0]});
        var mir: Mir = .{};
        defer mir.deinit(a);
        const entry = try mir.addBlock(a);
        const arg = try mir.addStrConst(a, "tran");
        const args: []const Mir.Value = if (g[1]) &.{arg} else &.{};
        const cond = try mir.emitCall(a, entry, try mir.internString(a, g[0]), args);
        const p = try mir.addBlockParam(a, 0);
        const t = try mir.addBlock(a);
        const e = try mir.addBlock(a);
        const j = try mir.addBlock(a);
        _ = try mir.emitBranch(a, entry, cond, t, e);
        const tv = try mir.emit(a, t, .fneg, &.{p});
        _ = try mir.emitJump(a, t, j);
        const ev = try mir.emit(a, e, .fmul, &.{ p, p });
        _ = try mir.emitJump(a, e, j);
        _ = try mir.emitPhi(a, j, &.{ .{ .block = t, .value = tv }, .{ .block = e, .value = ev } });
        try std.testing.expectEqual(g[2], try run(a, &mir));
    }
}

test "if-conversion: shapes that are not a diamond are left alone" {
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    const entry = try mir.addBlock(a);
    const t = try mir.addBlock(a);
    const e = try mir.addBlock(a);
    const j = try mir.addBlock(a);
    const other = try mir.addBlock(a);
    const p = try mir.addBlockParam(a, 0);
    _ = try mir.emitBranch(a, entry, p, t, e);
    const tv = try mir.emit(a, t, .fneg, &.{p});
    _ = try mir.emitJump(a, t, j);
    const ev = try mir.emit(a, e, .fneg, &.{tv});
    _ = try mir.emitJump(a, e, j);
    // The join phi has no pair for the else arm: there is nothing to select.
    _ = try mir.emitPhi(a, j, &.{ .{ .block = t, .value = tv }, .{ .block = other, .value = ev } });
    try std.testing.expectEqual(@as(u32, 0), try run(a, &mir));

    // Both edges to one block; an arm that loops back to X; an arm another
    // block also jumps into.
    var m2: Mir = .{};
    defer m2.deinit(a);
    const x = try m2.addBlock(a);
    const arm = try m2.addBlock(a);
    const out = try m2.addBlock(a);
    const y = try m2.addBlock(a);
    const shared = try m2.addBlock(a);
    const z = try m2.addBlock(a);
    const w = try m2.addBlock(a);
    const q = try m2.addBlockParam(a, 0);
    _ = try m2.emitBranch(a, x, q, arm, arm);
    _ = try m2.emitBranch(a, arm, q, x, out);
    _ = try m2.emitBranch(a, out, q, shared, y);
    _ = try m2.emitJump(a, y, z);
    _ = try m2.emitJump(a, shared, z);
    _ = try m2.emitJump(a, w, shared); // `shared` now has two predecessors
    try std.testing.expectEqual(@as(u32, 0), try run(a, &m2));
}

test "if-conversion: a `toBool` wrapper on a comparison is peeled off the select" {
    // `ine(flt(p, 0), 0)` asserts nothing `flt` does not; `ine(iadd, 0)` is
    // the §4.2.4 nonzero fact the prover mines, so it stays.
    const a = std.testing.allocator;
    for ([_]bool{ true, false }) |predicate| {
        var mir: Mir = .{};
        defer mir.deinit(a);
        const entry = try mir.addBlock(a);
        const t = try mir.addBlock(a);
        const j = try mir.addBlock(a);
        const p = try mir.addBlockParam(a, 0);
        const inner = if (predicate)
            try mir.emit(a, entry, .flt, &.{ p, .f_zero })
        else
            try mir.emit(a, entry, .iadd, &.{ .one, .one });
        const cond = try mir.emit(a, entry, .ine, &.{ inner, .zero });
        _ = try mir.emitBranch(a, entry, cond, t, j);
        const tv = try mir.emit(a, t, .fneg, &.{p});
        _ = try mir.emitJump(a, t, j);
        const phi = try mir.emitPhi(a, j, &.{ .{ .block = t, .value = tv }, .{ .block = entry, .value = p } });
        try std.testing.expectEqual(@as(u32, 1), try run(a, &mir));
        const sel = mir.instData(mir.valueDef(mir.resolveAlias(phi)).inst_result).ternary;
        try std.testing.expectEqual(if (predicate) inner else cond, sel.cond);
    }
}

test "if-conversion preserves what the module computes (differential)" {
    // Oracle: a direct interpreter over the pure opcodes, run on a copy that
    // is not converted. Two shapes: a diamond, and a triangle nested in one
    // arm of a diamond, every input sign combination. The converted MIR must
    // also still pass `verify`.
    const a = std.testing.allocator;
    const Lowered = @import("ir").Lowered;
    const verify = @import("verify.zig");
    const T = struct {
        fn build(m: *Mir, shape: u32) !Mir.Value {
            const al = std.testing.allocator;
            const entry = try m.addBlock(al);
            const p0 = try m.addBlockParam(al, 0);
            const p1 = try m.addBlockParam(al, 1);
            const b1 = try m.addBlock(al);
            const b2 = try m.addBlock(al);
            const j = try m.addBlock(al);
            const c1 = try m.emit(al, entry, .flt, &.{ p0, p1 });
            _ = try m.emitBranch(al, entry, c1, b1, b2);
            var v1: Mir.Value = undefined;
            var from1 = b1;
            if (shape == 0) {
                v1 = try m.emit(al, b1, .fmul, &.{ p0, .f_two });
            } else {
                // A triangle inside the then arm: `if (p0 > 0) v = p0 * 10`.
                const inner = try m.addBlock(al);
                const ij = try m.addBlock(al);
                const c2 = try m.emit(al, b1, .fgt, &.{ p0, .f_zero });
                _ = try m.emitBranch(al, b1, c2, inner, ij);
                const iv = try m.emit(al, inner, .fmul, &.{ p0, .f_ten });
                _ = try m.emitJump(al, inner, ij);
                v1 = try m.emitPhi(al, ij, &.{ .{ .block = inner, .value = iv }, .{ .block = b1, .value = p1 } });
                from1 = ij;
            }
            _ = try m.emitJump(al, from1, j);
            const v2 = try m.emit(al, b2, .fsub, &.{ p1, p0 });
            _ = try m.emitJump(al, b2, j);
            const ph = try m.emitPhi(al, j, &.{ .{ .block = from1, .value = v1 }, .{ .block = b2, .value = v2 } });
            return m.emit(al, j, .fadd, &.{ ph, .f_one });
        }

        fn eval(m: *const Mir, vals: []const f64, x: [2]f64, v: Mir.Value) f64 {
            const r = m.resolveAlias(v);
            return switch (m.valueDef(r)) {
                .float_const => |f| f,
                .int_const => |i| @floatFromInt(i),
                .block_param => |u| x[u],
                .inst_result => vals[@backingInt(r)],
                .undef, .str_const, .param_ref => unreachable,
            };
        }

        fn interpret(m: *const Mir, x: [2]f64, out: Mir.Value) !f64 {
            const vals = try std.testing.allocator.alloc(f64, m.defs.len + Mir.Value.first_dynamic);
            defer std.testing.allocator.free(vals);
            @memset(vals, std.math.nan(f64));
            var prev: Mir.Block = .entry;
            var cur: Mir.Block = .entry;
            for (0..64) |_| {
                // Phis first, as a parallel copy from the edge taken.
                var it = m.blockInsts(cur);
                var buf: [8]struct { Mir.Value, f64 } = undefined;
                var n: usize = 0;
                while (it.next()) |inst| if (m.instOp(inst) == .phi) {
                    const res = m.instResult(inst);
                    if (m.resolveAlias(res) != res) continue;
                    const d = m.instData(inst).phi;
                    for (0..d.count) |k| {
                        const pp = m.phiPair(inst, @intCast(k));
                        if (pp.block == prev) {
                            buf[n] = .{ res, eval(m, vals, x, pp.value) };
                            n += 1;
                        }
                    }
                };
                for (buf[0..n]) |e| vals[@backingInt(e[0])] = e[1];
                var next: ?Mir.Block = null;
                it = m.blockInsts(cur);
                while (it.next()) |inst| {
                    const res = m.instResult(inst);
                    switch (m.instData(inst)) {
                        .phi => {},
                        .unary => |u| vals[@backingInt(res)] = switch (u.op) {
                            .fneg => -eval(m, vals, x, u.operand),
                            else => unreachable, // else: the shapes use no other unary op
                        },
                        .binary => |b| {
                            const l = eval(m, vals, x, b.lhs);
                            const rr = eval(m, vals, x, b.rhs);
                            vals[@backingInt(res)] = switch (b.op) {
                                .fadd => l + rr,
                                .fsub => l - rr,
                                .fmul => l * rr,
                                .flt => @floatFromInt(@intFromBool(l < rr)),
                                .fgt => @floatFromInt(@intFromBool(l > rr)),
                                else => unreachable, // else: the shapes use no other binary op
                            };
                        },
                        .ternary => |t| vals[@backingInt(res)] = if (eval(m, vals, x, t.cond) != 0)
                            eval(m, vals, x, t.then_val)
                        else
                            eval(m, vals, x, t.else_val),
                        .branch => |br| next = if (eval(m, vals, x, br.cond) != 0) br.then_block else br.else_block,
                        .jump => |jp| next = jp.target,
                        .call, .anew, .load, .store => unreachable,
                    }
                    if (next != null) break;
                }
                prev = cur;
                cur = next orelse return eval(m, vals, x, out);
            }
            return error.TestInterpreterDidNotStop;
        }
    };
    const inputs = [_]f64{ -2, 0, 3 };
    for (0..2) |shape| {
        var plain: Mir = .{};
        defer plain.deinit(a);
        var conv: Mir = .{};
        defer conv.deinit(a);
        const out_plain = try T.build(&plain, @intCast(shape));
        const out_conv = try T.build(&conv, @intCast(shape));
        try std.testing.expect(try run(a, &conv) >= 1);
        var lw: Lowered = .{};
        defer lw.nodes.deinit(a);
        for (0..2) |_| try lw.nodes.append(a, .{ .name = "n", .kind = .net, .disc = "", .dir = .unspecified });
        if (try verify.verify(&conv, &lw)) |v| {
            std.debug.print("verify: `{s}`: {s}\n", .{ @tagName(v.invariant), v.what });
            return error.TestUnexpectedResult;
        }
        for (inputs) |x0| for (inputs) |x1| {
            const want = try T.interpret(&plain, .{ x0, x1 }, out_plain);
            const got = try T.interpret(&conv, .{ x0, x1 }, out_conv);
            try std.testing.expectEqual(want, got);
        };
    }
}

test "if-conversion is deterministic: equal MIR converts to equal MIR" {
    const a = std.testing.allocator;
    var s1 = try Shape.init(a, .value, .direct);
    defer s1.mir.deinit(a);
    var s2 = try Shape.init(a, .value, .direct);
    defer s2.mir.deinit(a);
    _ = try run(a, &s1.mir);
    _ = try run(a, &s2.mir);
    inline for (.{ .op, .a, .b, .result, .next, .block }) |col|
        try std.testing.expectEqualSlices(@TypeOf(s1.mir.insts.items(col)[0]), s1.mir.insts.items(col), s2.mir.insts.items(col));
    try std.testing.expectEqualSlices(u32, s1.mir.extra.items, s2.mir.extra.items);
    try std.testing.expectEqualSlices(Mir.Value, s1.mir.alias.items, s2.mir.alias.items);
}

test "if-conversion: .speculate flattens a nested domain-restricted arm and guards it (#81)" {
    // `if (p0 < p1) { if (p0 > 0) v = sqrt(p0) else v = p1 } else v = p1 - p0`:
    // the l_utsoi shape. `.pure` keeps both branches (a `sqrt` arm, and an
    // arm holding the inner branch). `.speculate` converts the inner one,
    // then the outer one through the two blocks the first left behind, and
    // guards the `sqrt` row with both literals, outermost first.
    const a = std.testing.allocator;
    for ([_]Mode{ .pure, .speculate }) |mode| {
        var m: Mir = .{};
        defer m.deinit(a);
        const entry = try m.addBlock(a);
        const p0 = try m.addBlockParam(a, 0);
        const p1 = try m.addBlockParam(a, 1);
        const b1 = try m.addBlock(a);
        const b2 = try m.addBlock(a);
        const j = try m.addBlock(a);
        const inner = try m.addBlock(a);
        const ij = try m.addBlock(a);
        const c1 = try m.emit(a, entry, .flt, &.{ p0, p1 });
        _ = try m.emitBranch(a, entry, c1, b1, b2);
        const c2 = try m.emit(a, b1, .fgt, &.{ p0, .f_zero });
        _ = try m.emitBranch(a, b1, c2, inner, ij);
        const iv = try m.emit(a, inner, .sqrt, &.{p0});
        _ = try m.emitJump(a, inner, ij);
        const v1 = try m.emitPhi(a, ij, &.{ .{ .block = inner, .value = iv }, .{ .block = b1, .value = p1 } });
        _ = try m.emitJump(a, ij, j);
        const v2 = try m.emit(a, b2, .fsub, &.{ p1, p0 });
        _ = try m.emitJump(a, b2, j);
        const out = try m.emitPhi(a, j, &.{ .{ .block = ij, .value = v1 }, .{ .block = b2, .value = v2 } });

        const n = try runMode(a, &m, mode, null);
        const sqrt_row = m.valueDef(iv).inst_result;
        if (mode == .pure) {
            try std.testing.expectEqual(@as(u32, 0), n);
            try std.testing.expectEqual(@as(?u32, null), m.guardOf(sqrt_row));
            continue;
        }
        try std.testing.expectEqual(@as(u32, 2), n);
        // Straight-line: the result is a select, and the entry block jumps.
        try std.testing.expectEqual(Mir.Opcode.select, m.instOp(m.valueDef(m.resolveAlias(out)).inst_result));
        try std.testing.expectEqual(j, m.instData(terminator(&m, entry).?).jump.target);
        const l0 = m.guard_lits.items[m.guardOf(sqrt_row).?];
        try std.testing.expectEqual(Mir.GuardLit{ .cond = c1, .taken = true, .next = l0.next }, l0);
        const l1 = m.guard_lits.items[l0.next];
        try std.testing.expectEqual(Mir.GuardLit{ .cond = c2, .taken = true, .next = Mir.GuardLit.end }, l1);
        // A total row needs no guard.
        try std.testing.expectEqual(@as(?u32, null), m.guardOf(m.valueDef(v2).inst_result));
    }
}

test "if-conversion: .speculate keeps a branch the model card alone decides, and what `keep` holds" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |card| {
        var s = try Shape.init(a, .sqrt, .value);
        defer s.mir.deinit(a);
        // Re-point the branch at a card-only condition: `1 > 0`.
        const br = terminator(&s.mir, s.entry).?;
        if (card) s.mir.insts.items(.a)[@backingInt(br)] = @backingInt(try s.mir.emit(a, s.entry, .fgt, &.{ .f_one, .f_zero }));
        var keep = try std.DynamicBitSetUnmanaged.initEmpty(a, s.mir.defs.len + Mir.Value.first_dynamic);
        defer keep.deinit(a);
        try std.testing.expectEqual(@as(u32, if (card) 0 else 1), try runMode(a, &s.mir, .speculate, &keep));
    }
    var s = try Shape.init(a, .sqrt, .value);
    defer s.mir.deinit(a);
    var keep = try keepSlice(a, &s.mir, &.{s.phi});
    defer keep.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), try runMode(a, &s.mir, .speculate, &keep));
}
