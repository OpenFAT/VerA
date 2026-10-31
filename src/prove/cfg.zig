//! The CFG tables of `Analysis`: a `Mir`'s block chains in; the flat
//! instruction pool, terminators and successors, reverse postorder,
//! predecessors, immediate dominators (Cooper, Harvey and Kennedy), the
//! dominator tree with its Euler tour, the phi and statement pools, and the
//! natural loops out. The one writer of every table `Analysis` lists above
//! `ipdom`. Every walk is iterative: a chain of 10,000 `if`s is a tree that
//! deep, which the native stack does not hold.
//!
//! LRM clauses this file's code cites: §5.9.
//!
//! Contents:
//! - `pub fn build(an: *Analysis, arena: Allocator) Analysis.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const Analysis = @import("Analysis.zig");

const none = Analysis.none;

/// Fills the CFG tables of `an` from `an.mir`, in `arena`. Asserts that the
/// MIR has its entry block, fewer than `Analysis.blocks_max` blocks, and
/// every row on at most one chain.
pub fn build(an: *Analysis, arena: Allocator) Analysis.Error!void {
    const nb = an.mir.blockCount();
    assert(nb > 0); // the entry block roots the DFS and the dominator tree
    assert(nb < Analysis.blocks_max);
    an.nb = nb;
    an.i_op = an.mir.insts.items(.op);
    an.i_res = an.mir.insts.items(.result);
    try flattenChains(an, arena);
    try linkSuccessors(an, arena);
    try orderBlocks(an, arena);
    try linkPredecessors(an, arena);
    try findDominators(an, arena);
    try buildDomTree(an, arena);
    try buildPools(an, arena);
    try findLoops(an, arena);
    assert(an.rpo[0] == 0);
    assert(an.idom[0] == 0);
}

// ---- private ----

/// `inst_off`/`inst_pool`: the intrusive `next` chain, once, counted then
/// filled so the pool never grows. Chain order is emission order and so
/// load-bearing.
fn flattenChains(an: *Analysis, arena: Allocator) Analysis.Error!void {
    const nb = an.nb;
    const rows_max = an.mir.instCount();
    an.inst_off = try arena.alloc(u32, nb + 1);
    var n: u32 = 0;
    for (0..nb) |bi| {
        an.inst_off[bi] = n;
        var it = an.mir.blockInsts(@fromBackingInt(@intCast(bi)));
        while (it.next()) |_| {
            n += 1;
            assert(n <= rows_max); // a row on two chains, or a chain that cycles
        }
    }
    an.inst_off[nb] = n;
    an.inst_pool = try arena.alloc(Mir.Inst, n);
    var k: u32 = 0;
    for (0..nb) |bi| {
        var it = an.mir.blockInsts(@fromBackingInt(@intCast(bi)));
        while (it.next()) |inst| {
            an.inst_pool[k] = inst;
            k += 1;
        }
    }
    assert(k == n);
}

/// `term` and `succ_off`/`succ_pool`. A phi may sit anywhere in the chain
/// (ssa.zig mints them on demand), so the terminator is found by opcode, not
/// by position; the last one on the chain wins.
fn linkSuccessors(an: *Analysis, arena: Allocator) Analysis.Error!void {
    const nb = an.nb;
    an.term = try arena.alloc(Mir.Inst, nb);
    an.succ_off = try arena.alloc(u32, nb + 1);
    const pool = try arena.alloc(u32, 2 * @as(usize, nb)); // a branch has two
    var n: u32 = 0;
    for (0..nb) |bi| {
        an.term[bi] = .none;
        var s: [2]u32 = undefined;
        var ns: u32 = 0;
        for (an.blockInstsFlat(@intCast(bi))) |inst| switch (Mir.opClass(an.mir.instOp(inst))) {
            .branch => {
                const d = an.mir.instData(inst).branch;
                an.term[bi] = inst;
                s = .{ @backingInt(d.then_block), @backingInt(d.else_block) };
                ns = 2;
            },
            .jump => {
                an.term[bi] = inst;
                s[0] = @backingInt(an.mir.instData(inst).jump.target);
                ns = 1;
            },
            .unary, .binary, .ternary, .phi, .call, .anew, .load, .store => {},
        };
        an.succ_off[bi] = n;
        @memcpy(pool[n..][0..ns], s[0..ns]);
        n += ns;
    }
    an.succ_off[nb] = n;
    an.succ_pool = pool[0..n];
    assert(n <= 2 * nb);
}

/// `rpo_num` and `rpo`: an iterative DFS from the entry in successor order,
/// so the order is deterministic.
fn orderBlocks(an: *Analysis, arena: Allocator) Analysis.Error!void {
    const nb = an.nb;
    an.rpo_num = try arena.alloc(u32, nb);
    @memset(an.rpo_num, none);
    const post = try arena.alloc(u32, nb);
    var n_post: u32 = 0;
    const seen = try arena.alloc(bool, nb);
    @memset(seen, false);
    const Frame = struct { b: u32, i: u32 };
    // `seen` admits each block once: at most `nb` frames.
    var stack: std.ArrayList(Frame) = try .initCapacity(arena, nb);
    stack.appendAssumeCapacity(.{ .b = 0, .i = 0 });
    seen[0] = true;
    while (stack.items.len != 0) {
        const top = &stack.items[stack.items.len - 1];
        const ss = an.succsOf(top.b);
        if (top.i < ss.len) {
            const s = ss[top.i];
            top.i += 1;
            if (seen[s]) continue;
            seen[s] = true;
            stack.appendAssumeCapacity(.{ .b = s, .i = 0 });
        } else {
            post[n_post] = top.b;
            n_post += 1;
            _ = stack.pop();
        }
    }
    an.rpo = try arena.alloc(u32, n_post);
    for (post[0..n_post], 0..) |bi, i| {
        const r = n_post - 1 - @as(u32, @intCast(i));
        an.rpo_num[bi] = r;
        an.rpo[r] = bi;
    }
    assert(n_post >= 1);
    assert(an.rpo[0] == 0); // the DFS root finishes last
}

/// `pred_off`/`pred_pool` (reachable sources only, filled in RPO order) and
/// `is_merge`.
fn linkPredecessors(an: *Analysis, arena: Allocator) Analysis.Error!void {
    const nb = an.nb;
    an.pred_off = try arena.alloc(u32, nb + 1);
    @memset(an.pred_off, 0);
    for (an.rpo) |bi| for (an.succsOf(bi)) |s| {
        an.pred_off[s + 1] += 1;
    };
    for (1..nb + 1) |b| an.pred_off[b] += an.pred_off[b - 1];
    an.pred_pool = try arena.alloc(u32, an.pred_off[nb]);
    const fill = try arena.dupe(u32, an.pred_off[0..nb]);
    for (an.rpo) |bi| for (an.succsOf(bi)) |s| {
        an.pred_pool[fill[s]] = bi;
        fill[s] += 1;
    };
    an.is_merge = try arena.alloc(bool, nb);
    for (an.is_merge, 0..) |*m, bi| m.* = an.predsOf(@intCast(bi)).len > 1;
    an.is_merge[0] = false; // the entry is never re-entered
    for (0..nb) |b| assert(fill[b] == an.pred_off[b + 1]);
}

/// `idom`: Cooper, Harvey and Kennedy's iteration over reverse postorder.
fn findDominators(an: *Analysis, arena: Allocator) Analysis.Error!void {
    const nb = an.nb;
    an.idom = try arena.alloc(u32, nb);
    @memset(an.idom, none);
    an.idom[0] = 0;
    // Bound: a block's idom is set once from `none`, then only climbs its
    // final dominator chain, at most `nb` times; every round but the last
    // changes one, so at most `nb * nb + 1` rounds.
    const rounds_max = @as(usize, nb) * nb + 1;
    var rounds: usize = 0;
    var changed = true;
    while (changed) : (rounds += 1) {
        assert(rounds < rounds_max);
        changed = false;
        for (an.rpo[1..]) |bi| {
            var new: u32 = none;
            for (an.predsOf(bi)) |p| {
                if (an.idom[p] == none and p != 0) continue;
                new = if (new == none) p else intersect(an, new, p);
            }
            if (new != none and an.idom[bi] != new) {
                an.idom[bi] = new;
                changed = true;
            }
        }
    }
    assert(an.idom[0] == 0);
}

fn intersect(an: *const Analysis, x0: u32, y0: u32) u32 {
    assert(an.rpo_num[x0] != none);
    assert(an.rpo_num[y0] != none);
    var x = x0;
    var y = y0;
    // Bound: each pass moves a finger up the tree; each can rise `nb` times.
    var passes: usize = 0;
    while (x != y) : (passes += 1) {
        assert(passes < 2 * @as(usize, an.nb));
        while (an.rpo_num[x] > an.rpo_num[y]) x = an.idom[x];
        while (an.rpo_num[y] > an.rpo_num[x]) y = an.idom[y];
    }
    return x;
}

/// `kid_off`/`kid_pool` (dominator children in RPO order), `mk_off`/`mk_pool`
/// (the merge-block ones) and the Euler tour `dom_in`/`dom_out`.
fn buildDomTree(an: *Analysis, arena: Allocator) Analysis.Error!void {
    const nb = an.nb;
    an.kid_off = try arena.alloc(u32, nb + 1);
    @memset(an.kid_off, 0);
    for (an.rpo[1..]) |bi| an.kid_off[an.idom[bi] + 1] += 1;
    for (1..nb + 1) |b| an.kid_off[b] += an.kid_off[b - 1];
    an.kid_pool = try arena.alloc(u32, an.kid_off[nb]);
    const fill = try arena.dupe(u32, an.kid_off[0..nb]);
    for (an.rpo[1..]) |bi| {
        const p = an.idom[bi];
        an.kid_pool[fill[p]] = bi;
        fill[p] += 1;
    }
    assert(an.kid_pool.len + 1 == an.rpo.len);

    an.mk_off = try arena.alloc(u32, nb + 1);
    var n_mk: u32 = 0;
    for (0..nb) |bi| {
        an.mk_off[bi] = n_mk;
        for (an.domKids(@intCast(bi))) |k| n_mk += @intFromBool(an.is_merge[k]);
    }
    an.mk_off[nb] = n_mk;
    an.mk_pool = try arena.alloc(u32, n_mk);
    var mk: u32 = 0;
    for (0..nb) |bi| for (an.domKids(@intCast(bi))) |k| {
        if (!an.is_merge[k]) continue;
        an.mk_pool[mk] = k;
        mk += 1;
    };
    assert(mk == n_mk);

    an.dom_in = try arena.alloc(u32, nb);
    an.dom_out = try arena.alloc(u32, nb);
    @memset(an.dom_in, none);
    @memset(an.dom_out, none);
    const Frame = struct { node: u32, kid: u32 };
    // Each tree node is pushed once: at most `nb` frames.
    const stack = try arena.alloc(Frame, nb);
    var sp: usize = 1;
    var clock: u32 = 0;
    stack[0] = .{ .node = 0, .kid = 0 };
    an.dom_in[0] = clock;
    clock += 1;
    while (sp > 0) {
        const f = &stack[sp - 1];
        const kids = an.domKids(f.node);
        if (f.kid < kids.len) {
            const k = kids[f.kid];
            f.kid += 1;
            an.dom_in[k] = clock;
            clock += 1;
            stack[sp] = .{ .node = k, .kid = 0 };
            sp += 1;
        } else {
            an.dom_out[f.node] = clock;
            clock += 1;
            sp -= 1;
        }
    }
    assert(clock == 2 * an.rpo.len);
}

/// `phi_off`/`phi_pool` and `stmt_off`/`stmt_pool`, counted then filled.
fn buildPools(an: *Analysis, arena: Allocator) Analysis.Error!void {
    const nb = an.nb;
    an.phi_off = try arena.alloc(u32, nb + 1);
    an.stmt_off = try arena.alloc(u32, nb + 1);
    var n_phis: u32 = 0;
    var n_stmts: u32 = 0;
    for (0..nb) |bi| {
        an.phi_off[bi] = n_phis;
        an.stmt_off[bi] = n_stmts;
        for (an.blockInstsFlat(@intCast(bi))) |inst| {
            n_phis += @intFromBool(livePhi(an, inst));
            n_stmts += @intFromBool(liveStmt(an, inst));
        }
    }
    an.phi_off[nb] = n_phis;
    an.stmt_off[nb] = n_stmts;
    an.phi_pool = try arena.alloc(Mir.Inst, n_phis);
    an.stmt_pool = try arena.alloc(Mir.Inst, n_stmts);
    var kp: u32 = 0;
    var ks: u32 = 0;
    for (an.inst_pool) |inst| {
        if (livePhi(an, inst)) {
            an.phi_pool[kp] = inst;
            kp += 1;
        }
        if (liveStmt(an, inst)) {
            an.stmt_pool[ks] = inst;
            ks += 1;
        }
    }
    assert(kp == n_phis);
    assert(ks == n_stmts);
}

/// A phi whose result survives aliasing.
fn livePhi(an: *const Analysis, inst: Mir.Inst) bool {
    if (an.i_op[@backingInt(inst)] != .phi) return false;
    const r = an.i_res[@backingInt(inst)];
    return an.rv(r) == r;
}

/// Everything a unit body may emit as a statement: phis are block headers,
/// terminators are the emitter's, and an aliased result was rewritten away.
fn liveStmt(an: *const Analysis, inst: Mir.Inst) bool {
    switch (Mir.opClass(an.i_op[@backingInt(inst)])) {
        .phi, .branch, .jump => return false,
        .unary, .binary, .ternary, .call, .anew, .load, .store => {},
    }
    const r = an.i_res[@backingInt(inst)];
    return r != .undef and an.rv(r) == r;
}

/// `is_loop` (a header dominates one of its predecessors) and `loop_of`, the
/// natural loop body of every header, for the §5.9 loop fixpoint: walk the
/// predecessors back from each back edge, stopping at the header. Not
/// "everything the header dominates": that also covers the region past the
/// loop's exit. `rpo` visits an outer header before an inner one and the
/// first write wins, so `loop_of` names the outermost nest.
fn findLoops(an: *Analysis, arena: Allocator) Analysis.Error!void {
    const nb = an.nb;
    an.is_loop = try arena.alloc(bool, nb);
    an.loop_of = try arena.alloc(u32, nb);
    @memset(an.is_loop, false);
    @memset(an.loop_of, none);
    for (an.rpo) |bi| for (an.predsOf(bi)) |p| {
        if (an.dominates(bi, p)) an.is_loop[bi] = true;
    };
    // A block is pushed only as its `loop_of` is first set: one row each.
    var body: std.ArrayList(u32) = try .initCapacity(arena, nb);
    for (an.rpo) |h| {
        if (!an.is_loop[h]) continue;
        if (an.loop_of[h] == none) an.loop_of[h] = h;
        for (an.predsOf(h)) |p| {
            if (!an.dominates(h, p)) continue; // not a back edge
            if (an.loop_of[p] != none and p != h) continue;
            if (p != h) {
                an.loop_of[p] = an.loop_of[h];
                body.appendAssumeCapacity(p);
            }
            while (body.pop()) |cur| for (an.predsOf(cur)) |q| {
                if (an.loop_of[q] != none) continue;
                an.loop_of[q] = an.loop_of[h];
                body.appendAssumeCapacity(q);
            };
        }
    }
    for (an.rpo) |h| if (an.is_loop[h]) assert(an.loop_of[h] != none);
}

test "analysis: CFG facts agree with their naive definitions on random structured CFGs" {
    // Oracles, each computed from the terminators alone:
    //   dominance   `a` dominates reachable `x` iff `x` is unreachable once
    //               `a` is removed (unreachable blocks dominate only themselves);
    //   RPO         every edge that is not a back edge goes forward;
    //   loops       a header dominates a predecessor, and its natural loop is
    //               every reachable block that reaches a back-edge source
    //               without passing the header; `loop_of` names the
    //               outermost (lowest-RPO) header whose loop holds the block.
    // The CFGs are lowering's shapes (if/else, one-armed if, loops, straight
    // jumps), so reducible, plus unreachable blocks jumping into them.
    const gpa = std.testing.allocator;
    const lowered: Lowered = .{};
    var prng = std.Random.DefaultPrng.init(0xd0_d0);
    const r = prng.random();

    const Gen = struct {
        mir: *Mir,
        r: std.Random,
        cur: Mir.Block = .entry,

        fn seq(g: *@This(), depth: u32) anyerror!void {
            const al = std.testing.allocator;
            for (0..g.r.uintLessThan(u32, 3)) |_| {
                const kind = if (depth >= 2) 3 else g.r.uintLessThan(u32, 4);
                switch (kind) {
                    0 => {
                        const t = try g.mir.addBlock(al);
                        const e = try g.mir.addBlock(al);
                        const j = try g.mir.addBlock(al);
                        _ = try g.mir.emitBranch(al, g.cur, .one, t, e);
                        g.cur = t;
                        try g.seq(depth + 1);
                        _ = try g.mir.emitJump(al, g.cur, j);
                        g.cur = e;
                        try g.seq(depth + 1);
                        _ = try g.mir.emitJump(al, g.cur, j);
                        g.cur = j;
                    },
                    1 => {
                        const t = try g.mir.addBlock(al);
                        const j = try g.mir.addBlock(al);
                        _ = try g.mir.emitBranch(al, g.cur, .one, t, j);
                        g.cur = t;
                        try g.seq(depth + 1);
                        _ = try g.mir.emitJump(al, g.cur, j);
                        g.cur = j;
                    },
                    2 => {
                        const h = try g.mir.addBlock(al);
                        const body = try g.mir.addBlock(al);
                        const exit = try g.mir.addBlock(al);
                        _ = try g.mir.emitJump(al, g.cur, h);
                        _ = try g.mir.emitBranch(al, h, .one, body, exit);
                        g.cur = body;
                        try g.seq(depth + 1);
                        _ = try g.mir.emitJump(al, g.cur, h);
                        g.cur = exit;
                    },
                    else => {
                        const n = try g.mir.addBlock(al);
                        _ = try g.mir.emitJump(al, g.cur, n);
                        g.cur = n;
                    },
                }
            }
        }
    };
    const Naive = struct {
        fn succs(m: *const Mir, b: u32, buf: *[2]u32) []const u32 {
            var it = m.blockInsts(@fromBackingInt(b));
            while (it.next()) |inst| switch (m.instData(inst)) {
                .branch => |d| {
                    buf.* = .{ @backingInt(d.then_block), @backingInt(d.else_block) };
                    return buf[0..2];
                },
                .jump => |d| {
                    buf[0] = @backingInt(d.target);
                    return buf[0..1];
                },
                .unary, .binary, .ternary, .phi, .call, .anew, .load, .store => {},
            };
            return buf[0..0];
        }

        /// Whether `b` reaches a block with no successor (the exit) without
        /// passing through `avoid`: false makes `avoid` post-dominate `b`.
        fn reachesExit(m: *const Mir, seen: []bool, stack: []u32, b: u32, avoid: u32) bool {
            if (b == avoid) return false;
            @memset(seen, false);
            seen[b] = true;
            stack[0] = b;
            var sp: usize = 1;
            while (sp > 0) {
                sp -= 1;
                var buf: [2]u32 = undefined;
                const ss = succs(m, stack[sp], &buf);
                if (ss.len == 0) return true;
                for (ss) |s| {
                    if (s == avoid or seen[s]) continue;
                    seen[s] = true;
                    stack[sp] = s;
                    sp += 1;
                }
            }
            return false;
        }

        /// Blocks reachable from the entry without passing through `skip`
        /// (`skip` past the last block skips nothing).
        fn reach(m: *const Mir, out: []bool, stack: []u32, skip: u32) void {
            @memset(out, false);
            if (skip == 0) return;
            out[0] = true;
            stack[0] = 0;
            var sp: usize = 1;
            while (sp > 0) {
                sp -= 1;
                const b = stack[sp];
                var buf: [2]u32 = undefined;
                for (succs(m, b, &buf)) |s| {
                    if (s == skip or out[s]) continue;
                    out[s] = true;
                    stack[sp] = s;
                    sp += 1;
                }
            }
        }
    };

    for (0..200) |round| {
        errdefer std.debug.print("analysis model: round {d}\n", .{round});
        var mir: Mir = .{};
        defer mir.deinit(gpa);
        _ = try mir.addBlock(gpa);
        var g: Gen = .{ .mir = &mir, .r = r };
        try g.seq(0);
        for (0..r.uintLessThan(u32, 3)) |_| {
            const dead = try mir.addBlock(gpa);
            const into: Mir.Block = @fromBackingInt(1 + r.uintLessThan(u32, mir.blockCount() - 1));
            _ = try mir.emitJump(gpa, dead, into);
        }

        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const aa = arena.allocator();
        const an = try Analysis.build(aa, &mir, &lowered);
        const nb = mir.blockCount();
        try std.testing.expectEqual(nb, an.nb);

        const stack = try aa.alloc(u32, nb);
        const live = try aa.alloc(bool, nb);
        Naive.reach(&mir, live, stack, nb);
        // dom[a * nb + x]
        const dom = try aa.alloc(bool, @as(usize, nb) * nb);
        const tmp = try aa.alloc(bool, nb);
        for (0..nb) |ai| {
            Naive.reach(&mir, tmp, stack, @intCast(ai));
            for (0..nb) |xi| dom[ai * nb + xi] = if (!live[ai] or !live[xi]) ai == xi else (ai == xi or !tmp[xi]);
        }
        for (0..nb) |ai| for (0..nb) |xi| {
            try std.testing.expectEqual(dom[ai * nb + xi], an.dominates(@intCast(ai), @intCast(xi)));
        };

        // Reachability, successors, predecessors, RPO direction, merges.
        const pred_n = try aa.alloc(u32, nb);
        @memset(pred_n, 0);
        for (0..nb) |ui| {
            try std.testing.expectEqual(live[ui], an.rpo_num[ui] != none);
            var buf: [2]u32 = undefined;
            const ss = Naive.succs(&mir, @intCast(ui), &buf);
            try std.testing.expectEqualSlices(u32, ss, an.succsOf(@intCast(ui)));
            if (!live[ui]) continue;
            for (ss) |v| {
                pred_n[v] += 1;
                try std.testing.expect(std.mem.findScalar(u32, an.predsOf(@intCast(v)), @intCast(ui)) != null);
                if (!dom[v * nb + ui]) try std.testing.expect(an.rpo_num[ui] < an.rpo_num[v]);
            }
        }
        for (0..nb) |v| {
            try std.testing.expectEqual(@as(usize, pred_n[v]), an.predsOf(@intCast(v)).len);
            try std.testing.expectEqual(v != 0 and pred_n[v] >= 2, an.is_merge[v]);
        }

        // Immediate dominators, and the dominator tree's child lists.
        var kids: usize = 0;
        for (0..nb) |x| {
            kids += an.domKids(@intCast(x)).len;
            for (an.domKids(@intCast(x))) |k| try std.testing.expectEqual(@as(u32, @intCast(x)), an.idom[k]);
            if (!live[x]) {
                try std.testing.expectEqual(none, an.idom[x]);
                continue;
            }
            if (x == 0) continue;
            const id = an.idom[x];
            try std.testing.expect(id != x and dom[id * nb + x]);
            for (0..nb) |d| if (d != x and dom[d * nb + x]) try std.testing.expect(dom[d * nb + id]);
        }
        var n_live: usize = 0;
        for (live) |l| n_live += @intFromBool(l);
        try std.testing.expectEqual(n_live - 1, kids);
        try std.testing.expectEqual(n_live, an.rpo.len);

        // Loop headers, natural loops and the outermost owner.
        const owner = try aa.alloc(u32, nb);
        @memset(owner, none);
        const member = try aa.alloc(bool, nb);
        for (an.rpo) |h| {
            var header = false;
            for (0..nb) |p| {
                if (!live[p]) continue;
                var buf: [2]u32 = undefined;
                const ss = Naive.succs(&mir, @intCast(p), &buf);
                if (std.mem.findScalar(u32, ss, h) != null and dom[h * nb + p]) header = true;
            }
            try std.testing.expectEqual(header, an.is_loop[h]);
            if (!header) continue;
            // Every live block that reaches a back-edge source without
            // passing `h`, to a fixpoint.
            @memset(member, false);
            member[h] = true;
            var grew = true;
            while (grew) {
                grew = false;
                for (0..nb) |b| {
                    if (!live[b] or member[b]) continue;
                    var buf: [2]u32 = undefined;
                    for (Naive.succs(&mir, @intCast(b), &buf)) |s| {
                        const back_edge = s == h and dom[h * nb + b];
                        if (back_edge or (s != h and member[s])) {
                            member[b] = true;
                            grew = true;
                            break;
                        }
                    }
                }
            }
            for (0..nb) |b| if (member[b] and owner[b] == none) {
                owner[b] = h;
            };
        }
        for (0..nb) |b| {
            try std.testing.expectEqual(owner[b], an.loop_of[b]);
            try std.testing.expectEqual(owner[b] != none, an.inLoop(@intCast(b)));
        }

        // Immediate post-dominators: every block here reaches the exit, so
        // `x` post-dominates `b` iff `b` cannot reach it avoiding `x`, and
        // `ipdom[b]` (`nb`: the virtual exit) is the nearest strict one. An
        // unreachable block is cut off from the reverse walk and flows to the
        // virtual exit.
        const pd = try aa.alloc(bool, @as(usize, nb) * nb);
        for (0..nb) |x| for (0..nb) |b| {
            pd[x * nb + b] = x == b or !Naive.reachesExit(&mir, tmp, stack, @intCast(b), @intCast(x));
        };
        try std.testing.expectEqual(nb, an.ipdom[nb]);
        for (0..nb) |b| {
            const ip = an.ipdom[b];
            if (!live[b]) {
                try std.testing.expectEqual(nb, ip);
                continue;
            }
            try std.testing.expect(ip != b);
            if (ip != nb) try std.testing.expect(pd[ip * nb + b]);
            for (0..nb) |d| if (d != b and pd[d * nb + b]) {
                try std.testing.expect(ip != nb);
                try std.testing.expect(pd[d * nb + ip]);
            };
        }
    }
}
