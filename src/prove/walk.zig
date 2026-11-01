//! The walk: every instruction in dominator-tree preorder in, each computed
//! Value's interval and finite bit out (`Prover.iv`, `finite`, `def_pos`,
//! `def_seq`), with every evaluated domain checked on the way
//! (`domain.check`). A guard pushed on the edge into a block holds for the
//! subtree it dominates and is popped on the way out. SSA puts every non-phi
//! operand before its use; a phi operand from an unprocessed predecessor (a
//! §5.9 loop back edge) is still `top` and not finite, so loops widen to top
//! at once: sound and terminating.
//!
//! LRM clauses this file's code cites: §3.2, §3.2.2, §4.2.3, §4.2.5, §4.2.8,
//! §4.2.12, §4.5, §4.5.13, §5.8, §5.9, §6.6.1, §9.15.
//!
//! Contents:
//! - `pub const Error = Allocator.Error`
//! - `pub fn walk(p: *Prover) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const Interval = @import("Interval.zig");
const Prover = @import("Prover.zig");
const transfer = @import("transfer.zig");
const guards = @import("guards.zig");
const domain = @import("domain.zig");
const none = Prover.none;

/// Fails only on allocation.
pub const Error = Allocator.Error;

/// Evaluates every instruction: reachable blocks in dominator-tree preorder,
/// then the unreachable ones with their runtime domains off (§4.2.3:
/// unreachable source was parsed and type checked already). Asserts that it
/// runs once, after `guards.markSelectArms`.
// ponytail: immediate widening loses loop-carried bounds. Upgrade path if a
// real model needs them: an ascending-chain worklist from bottom, widening
// after k rounds, iterating only the natural loop body (`Analysis.loop_of`).
// Genvar loops (§6.6.1) unroll, so this bites `while` only.
pub fn walk(p: *Prover) Error!void {
    assert(p.uses.len == p.an.nv);
    assert(p.visited_block.len == 0); // once
    const nb = p.an.nb;
    p.visited_block = try p.arena.alloc(bool, nb);
    @memset(p.visited_block, false);

    try walkDom(p);

    p.domain_active = false;
    for (0..nb) |b| if (!p.visited_block[b]) try walkBlock(p, @intCast(b));
    p.domain_active = true;
    assert(std.mem.allEqual(bool, p.visited_block, true));
    assert(p.saved.items.len == 0); // every fact popped
}

// ---- private ----

/// The dominator-tree preorder from block 0, on a heap stack: a chain of
/// 10,000 sequential `if`s is a tree that deep. Each row restores the facts
/// and `domain_active` its block's edge set once its subtree is done. The
/// stack is on `gpa`, not the arena: growing there beside `saved` stopped
/// `saved` growing in place, and the copies it left behind doubled a deep
/// chain's peak (5,000 else-ifs in Debug: 2.6 GB, 4.8 GB on the arena).
fn walkDom(p: *Prover) Error!void {
    const Frame = struct { b: u32, mark: usize, active: bool, kid: u32 = 0 };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(p.gpa);
    const mark0 = p.saved.items.len;
    try stack.append(p.gpa, .{ .b = 0, .mark = p.saved.items.len, .active = p.domain_active });
    try enterDom(p, 0);
    var entered: u32 = 1;
    while (stack.items.len != 0) {
        const top = &stack.items[stack.items.len - 1];
        const kids = p.an.domKids(top.b);
        if (top.kid < kids.len) {
            const c = kids[top.kid];
            top.kid += 1;
            try stack.append(p.gpa, .{ .b = c, .mark = p.saved.items.len, .active = p.domain_active });
            assert(stack.items.len <= p.an.nb); // a dominator path holds each block once
            try enterDom(p, c);
            entered += 1;
            continue;
        }
        const done = stack.pop().?;
        guards.popFacts(p, done.mark);
        p.domain_active = done.active;
    }
    assert(entered == p.an.rpo.len); // each reachable block once
    assert(p.saved.items.len == mark0); // every edge's facts popped
}

/// Pushes the facts of the edge into `b` and walks `b`'s own instructions.
/// Requiring `b`'s ONLY predecessor to be the branching block is what makes
/// "dominated by b" imply "the branch went this way".
fn enterDom(p: *Prover, b: u32) Error!void {
    assert(p.an.rpo_num[b] != none);
    if (b != 0) edge: {
        const parent = p.an.idom[b];
        if (parent == none or p.an.predsOf(b).len != 1) break :edge;
        assert(parent != b); // only the entry is its own idom
        const term = p.an.term[parent];
        if (term == .none or p.mir.instOp(term) != .branch) break :edge;
        const br = p.mir.instData(term).branch;
        const taken = @backingInt(br.then_block) == b;
        if (!taken and @backingInt(br.else_block) != b) break :edge;
        if (p.an.foldConst(br.cond, false)) |c| {
            if ((c != 0) != taken) p.domain_active = false;
        }
        var raw: [2]Prover.Fact = undefined;
        try guards.pushFacts(p, guards.condFacts(p, br.cond, taken, &raw));
    }
    try walkBlock(p, b);
    assert(p.visited_block[b]);
}

fn walkBlock(p: *Prover, b: u32) Error!void {
    assert(b < p.visited_block.len);
    assert(!p.visited_block[b]);
    p.visited_block[b] = true;
    for (p.an.blockInstsFlat(b)) |inst| try evalInst(p, inst);
}

fn evalInst(p: *Prover, inst: Mir.Inst) Error!void {
    assert(p.visited_block.len == p.an.nb); // `walk` runs it
    const result = p.mir.instResult(inst);
    const ri = p.idxOf(result);

    // §4.2.12 select-arm guard, scoped to exactly this instruction.
    const mark = p.saved.items.len;
    defer guards.popFacts(p, mark);
    if (result != .undef) {
        const g = p.guard[ri];
        if (g.count != 0) try guards.pushFacts(p, p.facts.items[g.start..][0..g.count]);
    }

    // An unprovable domain is not an error (§4.3.2, `domain.check`); it costs
    // the result its finiteness, which drops the unit to `.strict`.
    const domain_proven = if (p.domain_active) try domain.check(p, inst) else false;
    if (result == .undef) return; // terminator

    const out = transferOf(p, inst);
    // MEET, not assign: a guard pushed on this value's class before its
    // definition (the `if (V>0) … ln(V)` shape) must survive its own
    // transfer, which `ivAt` does by meeting `civ`. Once that guard is popped
    // the value reads its seed again (`def_pos`), so nothing leaks.
    p.iv[ri] = out.iv.meet(p.iv[ri]);
    const top = p.ctop[p.clsOf(ri)];
    p.def_pos[ri] = top;
    if (top != none) p.def_seq[ri] = p.saved.items[top].seq;
    p.finite[ri] = out.finite and domain_proven;
    if (p.finite[ri]) assert(out.finite);
    if (!domain_proven) assert(!p.finite[ri]);
}

/// The transfer of `inst`: intervals for the domain proof, and the separate
/// finite bit (the rules on `proof.FloatMode`) that drives the float mode.
fn transferOf(p: *const Prover, inst: Mir.Inst) transfer.Abstract {
    const op = p.mir.instOp(inst);
    assert(p.iv.len == p.an.nv);
    // §4.2.5/§4.2.8: integer-valued results are finite by construction.
    if (Mir.opIsInteger(op)) return .{ .iv = transfer.integerIv(op), .finite = true };
    return switch (p.mir.instData(inst)) {
        .unary => |u| transfer.unaryTransfer(op, p.ivOf(u.operand), p.isFinite(u.operand)),
        .binary => |b| transfer.binaryTransfer(op, p.ivOf(b.lhs), p.ivOf(b.rhs), p.isFinite(b.lhs) and p.isFinite(b.rhs)),
        // §4.2.12 `?:`: the union of the two arms.
        .ternary => |t| .{
            .iv = p.ivOf(t.then_val).join(p.ivOf(t.else_val)),
            .finite = p.isFinite(t.then_val) and p.isFinite(t.else_val),
        },
        .phi => |ph| phiTransfer(p, inst, ph.count),
        // §4.5 analog operators and ch9 system functions: a known one
        // carries a spec-given range, everything else is top.
        .call => |c| callTransfer(p, c.callee, c.args),
        .branch, .jump => .{ .iv = .top, .finite = false },
        // §3.2.2 an array version's interval covers every element. A fresh
        // local array is all zero (§3.2); a held one holds what the last
        // accepted evaluation stored, which nothing here bounds. A
        // `vera_timepoint` cached start is only ever read by the join phi,
        // which also joins the miss-arm version.
        .anew => |a| if (p.lowered.mem_arrays.items[a.array].held == Lowered.none_u32)
            .{ .iv = Interval.point(0), .finite = true }
        else
            .{ .iv = .top, .finite = false },
        // A store widens by what it stores.
        .store => |st| .{
            .iv = p.ivOf(st.arr).join(p.ivOf(st.value)),
            .finite = p.isFinite(st.arr) and p.isFinite(st.value),
        },
        // An element, or the zero an index outside the array reads.
        .load => |l| .{
            .iv = p.ivOf(l.arr).join(Interval.point(0)),
            .finite = p.isFinite(l.arr),
        },
    };
}

/// §5.8 a join: the hull of its operands, finite when every one is.
fn phiTransfer(p: *const Prover, inst: Mir.Inst, count: u32) transfer.Abstract {
    assert(p.mir.instOp(inst) == .phi);
    if (count == 0) return .{ .iv = .top, .finite = false };
    var acc = p.ivOf(p.mir.phiPair(inst, 0).value);
    var fin = p.isFinite(p.mir.phiPair(inst, 0).value);
    const first_fin = fin;
    for (1..count) |k| {
        const v = p.mir.phiPair(inst, @intCast(k)).value;
        acc = acc.join(p.ivOf(v));
        fin = fin and p.isFinite(v);
    }
    if (fin) assert(first_fin);
    return .{ .iv = acc, .finite = fin };
}

/// `transfer.callAbstract`, plus the two calls whose range depends on their
/// argument: its argument-free claim (positive, nonzero, finite) would be
/// unsound for them, since `1.0/$vt(V(p,n))` and `1.0/limexp(V(p,n))` can
/// divide by zero.
fn callTransfer(p: *const Prover, c: Mir.Callee, args: []const Mir.Value) transfer.Abstract {
    assert(p.finite.len == p.an.nv);
    if (args.len == 1) {
        const a = p.ivOf(args[0]);
        const af = p.isFinite(args[0]);
        switch (c) {
            // §9.15 `$vt(T)` = kT/q: T's sign, T's finiteness; $vt(0) = 0.
            // The factor is codegen's; only its sign matters to a domain proof.
            .@"$vt" => return .{ .iv = transfer.combine(a, Interval.point(8.617333262145179e-5), transfer.mulOp), .finite = af },
            // §4.5.13: "The apparent behavior of limexp() is not
            // distinguishable from exp()", and the device computes it as exp
            // (VD-121): exp's interval and finiteness. exp underflows to 0.0
            // below about -745, so not nonzero, and overflows past ln(DBL_MAX).
            .limexp => return transfer.unaryTransfer(.exp, a, af),
            else => {}, // else: every other range is argument-free, `callAbstract`'s
        }
    }
    return transfer.callAbstract(c);
}
