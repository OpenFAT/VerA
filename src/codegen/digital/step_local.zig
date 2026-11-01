//! A native design's processes -> the slots `rt.Design.dead` names for
//! `--state=auto`. At a time-step boundary every process is suspended; a
//! slot is dead there when each read of it, in every activation, follows a
//! whole-slot blocking write in that activation, so the value it holds at
//! the boundary is never read (`rt.State.boundary`). A forward "must be
//! written" dataflow over the bytecode, one bit per candidate slot.
//! Cites: IEEE 1364-2005 §9.2.1 (blocking writes), §9.7 (suspensions),
//! §9.8.2 (fork), §10.2.2 (copy-in), §10.2.3, §10.3.
//!
//! Contents:
//! - `pub fn stepLocal(em: *Emitter, procs: []const plan.Proc) Error![]const u32`
//! - private `StmtReads.expr`, `StmtReads.stmt`: the `stmtEdges` visitor

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Ast = @import("frontend").Ast;
const Emitter = @import("Emitter.zig");
const Error = Emitter.Error;
const plan = @import("plan.zig");

/// The dataflow's state: per pc `nw` words of "written on every path in",
/// whether the pc was reached, and the pcs whose set changed.
const Flow = struct {
    in: []u64,
    seen: []bool,
    nw: usize,
    work: std.ArrayList(u32) = .empty,

    /// `in[to] &= set`; `to` is queued when that is its first set or
    /// changes it.
    fn meet(f: *Flow, a: Allocator, to: u32, set: []const u64) Allocator.Error!void {
        assert(set.len == f.nw);
        assert(to < f.seen.len);
        // The bits `set` clears, or-ed: no branch in the loop.
        var lost: u64 = 0;
        for (f.in[to * f.nw ..][0..f.nw], set) |*w, s| {
            lost |= w.* & ~s;
            w.* &= s;
        }
        if (!f.seen[to] or lost != 0) try f.work.append(a, to);
        f.seen[to] = true;
    }
};

/// `readsAt` of a statement's own expressions, both edges: a target's
/// selects are read, and reading its base too only keeps more alive.
const StmtReads = struct {
    em: *Emitter,
    out: *std.ArrayList(u32),
    ok: bool = true,

    pub fn expr(v: *StmtReads, e: Ast.ExprId, _: Ast.SourceFile.Edge) Error!void {
        if (v.ok) v.ok = try exprReads(v.em, e, v.out);
    }

    pub fn stmt(_: *StmtReads, _: Ast.StmtId) Error!void {}
};

/// Returns the dead slots. Activations follow `processes.reach`'s control
/// flow: a suspension, a fork, a `disable` resumes a process in a new one,
/// which starts knowing nothing written; a subroutine body starts knowing
/// its inputs (§10.2.2 copy-in). A slot something outside the processes
/// reads (`Plan.watched`: an event control, a driver, a node, the monitor, a
/// dump) is never dead. Reads `em.watched`, so it runs after `plan.build`.
pub fn stepLocal(em: *Emitter, procs: []const plan.Proc) Error![]const u32 {
    const r = em.r;
    const a = em.arena;
    const code = r.program.code.items;
    const n = code.len;
    assert(em.watched.len == r.values.len);
    // The candidates: slots some instruction writes whole, as bit indices.
    const bit = try a.alloc(?u32, r.values.len);
    @memset(bit, null);
    // Each slot once (`bit`), from at most one write per pc.
    var cands: std.ArrayList(u32) = try .initCapacity(a, @min(n, r.values.len));
    const writes = try a.alloc(?u32, n);
    for (writes, 0..) |*w, pc| {
        w.* = null;
        const at = wholeWrite(em, @intCast(pc)) orelse continue;
        if (em.watched[at] or r.decls.reals.contains(at)) continue;
        if (bit[at] == null) {
            bit[at] = @intCast(cands.items.len);
            cands.appendAssumeCapacity(at);
        }
        w.* = bit[at];
    }
    if (cands.items.len == 0) return &.{};
    const nw = (cands.items.len + 63) / 64;
    // Per pc, the candidates written on every path into it this activation.
    // ponytail: pcs x candidates bits; per-process sets if that outgrows memory.
    var flow: Flow = .{
        .in = try a.alloc(u64, n * nw),
        .seen = try a.alloc(bool, n),
        .nw = nw,
    };
    @memset(flow.in, std.math.maxInt(u64));
    @memset(flow.seen, false);
    const none = try a.alloc(u64, nw);
    @memset(none, 0);
    for (procs) |p| try flow.meet(a, p.entry, none);
    for (em.subs_todo.items) |idx| {
        const sub = r.routines.rows.items[idx];
        const known = try a.dupe(u64, none);
        for (sub.decl.ports, sub.frame.ports) |port, at| if (port.direction != .output) if (bit[at]) |b| {
            known[b / 64] |= @as(u64, 1) << @intCast(b % 64);
        };
        try flow.meet(a, sub.entry, known);
    }
    const out = try a.alloc(u64, nw);
    // A pc is queued again only when its set shrinks, which it does at most
    // once per candidate bit.
    const pops_max = n * (cands.items.len + 2);
    var pops: usize = 0;
    while (flow.work.pop()) |pc| : (pops += 1) {
        assert(pops < pops_max);
        @memcpy(out, flow.in[pc * nw ..][0..nw]);
        if (writes[pc]) |b| out[b / 64] |= @as(u64, 1) << @intCast(b % 64);
        for (em.block_ends.of(pc)) |e| try flow.meet(a, e, none);
        const next = pc + 1;
        switch (code[pc]) {
            .stop, .continuous => {},
            .jump => |t| try flow.meet(a, t, out),
            .restart => |x| try flow.meet(a, x.target, out),
            .branch => |b| for ([_]u32{ next, b.otherwise }) |t| try flow.meet(a, t, out),
            .case_select => |c| {
                try flow.meet(a, c.fallback, out);
                const arms = r.file.stmt(c.statement).case_stmt.arms.len;
                for (r.program.case_targets.items[c.targets..][0..arms]) |t| try flow.meet(a, t, out);
            },
            .repeat_start => |x| for ([_]u32{ next, x.end }) |t| try flow.meet(a, t, out),
            .repeat_next => |x| for ([_]u32{ next, x.body }) |t| try flow.meet(a, t, out),
            .task => |t| if (t.task != .finish) try flow.meet(a, next, out),
            .assign, .init_var, .trigger, .deposit, .call, .copy_out, .override_eval, .override_off => try flow.meet(a, next, out),
            .delay, .wait_event, .wait_slots, .wait_level, .sample => try flow.meet(a, next, none),
            .disable_block => |b| {
                try flow.meet(a, next, out);
                if (pc >= b.start and pc < b.end) try flow.meet(a, b.end, out);
            },
            .disable_task => |idx| {
                try flow.meet(a, next, out);
                for (r.routines.rows.items[idx].ranges.items) |rg| if (pc >= rg.start and pc < rg.end) try flow.meet(a, rg.end, out);
            },
            .pla_start => |p| for ([_]u32{ next, p.at }) |t| try flow.meet(a, t, none),
            .fork => |f| for (if (f.arms.len == 0) &[_]u32{f.end} else r.program.wordsOf(f.arms)) |t| try flow.meet(a, t, none),
            .join_arm => |j| try flow.meet(a, j.end, none),
            .override_on => |o| {
                try flow.meet(a, next, out);
                try flow.meet(a, o.start, none);
            },
            .switch_ctrl => {},
            .call_timed, .task_return => return &.{}, // ponytail: §10.2.3 activations swap frames at run time; nothing is called dead
        }
    }
    // A read of a candidate not written before it in its activation keeps
    // the candidate's boundary value alive.
    const live = try a.alloc(bool, cands.items.len);
    @memset(live, false);
    var reads: std.ArrayList(u32) = .empty;
    for (0..n) |pc| if (flow.seen[pc]) {
        reads.clearRetainingCapacity();
        if (!try readsAt(em, @intCast(pc), &reads)) return &.{};
        for (reads.items) |at| if (at < bit.len) if (bit[at]) |b| {
            if (flow.in[pc * nw + b / 64] >> @intCast(b % 64) & 1 == 0) live[b] = true;
        };
    };
    var dead: std.ArrayList(u32) = try .initCapacity(a, cands.items.len);
    for (cands.items, live) |at, l| if (!l) dead.appendAssumeCapacity(at);
    assert(dead.items.len <= cands.items.len);
    return dead.items;
}

// ---- private ----

/// Returns the slot the instruction at `pc` writes whole with a blocking
/// write, or null.
fn wholeWrite(em: *Emitter, pc: u32) ?u32 {
    const r = em.r;
    const ex = &r.file.exprs;
    assert(pc < r.program.code.items.len);
    r.scope = r.program.scope_of.items[pc];
    const target = switch (r.program.code.items[pc]) {
        .init_var => |x| return x.slot,
        .assign => |x| if (x.nonblocking) return null else x.target,
        .copy_out => |x| x.target,
        else => return null, // else: only these three write a slot at their own pc
    };
    if (ex.tag(target) != .ident and ex.tag(target) != .hier_ident) return null;
    return r.slot(target) catch null;
}

/// Appends every slot the instruction at `pc` reads; false when a name does
/// not resolve to one.
fn readsAt(em: *Emitter, pc: u32, out: *std.ArrayList(u32)) Error!bool {
    const r = em.r;
    const ex = &r.file.exprs;
    assert(pc < r.program.code.items.len);
    r.scope = r.program.scope_of.items[pc];
    switch (r.program.code.items[pc]) {
        .assign => |x| {
            if (ex.tag(x.target) != .ident and ex.tag(x.target) != .hier_ident) if (!try exprReads(em, x.target, out)) return false;
            return exprReads(em, x.value, out);
        },
        .copy_out => |x| {
            try out.append(em.arena, x.slot);
            if (ex.tag(x.target) != .ident and ex.tag(x.target) != .hier_ident) return exprReads(em, x.target, out);
            return true;
        },
        .init_var => |x| return exprReads(em, x.value, out),
        .delay => |x| return exprReads(em, x.amount, out),
        .task => |t| for (r.program.exprs(t.args)) |e| if (!try exprReads(em, e, out)) return false,
        .branch => |b| return exprReads(em, b.condition, out),
        .case_select => |c| {
            const cs = r.file.stmt(c.statement).case_stmt;
            if (!try exprReads(em, cs.scrutinee, out)) return false;
            for (cs.arms) |arm| for (arm.labels) |l| if (!try exprReads(em, l, out)) return false;
        },
        .repeat_start => |x| return exprReads(em, x.count, out),
        .wait_event => |e| return exprReads(em, e, out),
        .wait_level => |x| return exprReads(em, x.cond, out),
        .sample => |x| return stmtReads(em, x.statement, out),
        .deposit => |x| return stmtReads(em, x.statement, out),
        .call => |x| for (r.program.exprs(x.args)) |e| if (!try exprReads(em, e, out)) return false,
        .override_eval => |x| return exprReads(em, x.value, out),
        .trigger => |event| switch (event) {
            .slot => {},
            .indexed => |e| return exprReads(em, e, out),
        },
        .continuous, .wait_slots, .restart, .jump, .stop, .disable_block, .disable_task, .fork, .join_arm, .pla_start, .override_on, .override_off, .repeat_next, .switch_ctrl, .call_timed, .task_return => {},
    }
    return true;
}

/// `readsAt` of a statement's own expressions.
fn stmtReads(em: *Emitter, s: Ast.StmtId, out: *std.ArrayList(u32)) Error!bool {
    assert(s != .none);
    var v: StmtReads = .{ .em = em, .out = out };
    try em.r.file.stmtEdges(s, &v);
    return v.ok;
}

/// Appends every slot `e` reads, a function call's result among them;
/// false when a name does not resolve to one.
fn exprReads(em: *Emitter, e: Ast.ExprId, out: *std.ArrayList(u32)) Error!bool {
    if (e == .none) return true;
    const r = em.r;
    const ex = &r.file.exprs;
    switch (ex.tag(e)) {
        .ident, .hier_ident => {
            try out.append(em.arena, r.slot(e) catch return false);
            return true;
        },
        .call => {
            const idx = r.routines.base.get(r.instanceOf(r.scope)).? + r.routines.calls.get(e).?;
            try out.append(em.arena, r.routines.rows.items[idx].frame.result);
        },
        else => {}, // else: every other form reads only through its children
    }
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (!try exprReads(em, c, out)) return false;
    return true;
}

test "Flow.meet: against the short-circuit loop it replaced" {
    // 0..200 words, at offset `to` 0 and 1 (a start not on a 32-byte line),
    // seen or not; half the cases `set` covers `in`, so nothing changes.
    var prng: std.Random.DefaultPrng = .init(1);
    const rand = prng.random();
    var in: [400]u64 = undefined;
    var old: [400]u64 = undefined;
    var set: [200]u64 = undefined;
    for (0..201) |nw| for ([_]u32{ 0, 1 }) |to| for ([_]bool{ false, true }) |was| {
        rand.bytes(std.mem.sliceAsBytes(&in));
        rand.bytes(std.mem.sliceAsBytes(&set));
        if (rand.boolean()) for (set[0..nw], in[to * nw ..][0..nw]) |*s, w| {
            s.* |= w;
        };
        old = in;
        var changed = !was;
        for (old[to * nw ..][0..nw], set[0..nw]) |*w, s| {
            changed = changed or w.* & s != w.*;
            w.* &= s;
        }
        var seen = [2]bool{ was, was };
        var f: Flow = .{ .in = &in, .seen = &seen, .nw = nw };
        defer f.work.deinit(std.testing.allocator);
        try f.meet(std.testing.allocator, to, set[0..nw]);
        try std.testing.expectEqualSlices(u64, &old, &in);
        try std.testing.expectEqual(changed, f.work.items.len == 1);
        try std.testing.expect(seen[to]);
    };
}
