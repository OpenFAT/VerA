//! The processes of a native design -> how `rt.State` schedules each: the
//! slots anything can wait on (a store to any other is a plain store), and
//! under `static` a role per process with its tables: combinational nodes in
//! topological order with the bits that dirty them, and the watchers of
//! processes with one fixed event control. Which process can be a node is
//! `plan_nodes.zig`'s; which slots are dead at a step boundary
//! `step_local.zig`'s.
//! Cites: IEEE 1364-2005 §11.4.2 (active events in any order), §9.7.2,
//! §9.7.3, §9.7.5, §9.7.6, §9.7.7, §10.3, §14.3.3, §17.1.3, §18; VAMS
//! §9.22.5 (refused).
//!
//! Contents:
//! - `pub const Reach = rt.Reach`
//! - `pub const Schedule = enum { fifo, static }`
//! - `pub const Term = struct`
//! - `pub const Role = union(enum)`
//! - `pub const Proc = struct`
//! - `pub const Plan = struct`
//! - `pub fn dumps(r: *const Run) bool`
//! - `pub fn terms(em: *Emitter, e: Ast.ExprId, out: *std.ArrayList(Term)) Error!void`
//! - `pub fn waitTerms(em: *Emitter, pc: u32, out: *std.ArrayList(Term)) Error!void`
//! - `pub fn build(em: *Emitter, procs: []Proc, schedule: Schedule) Error!Plan`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Ast = @import("frontend").Ast;
const sim = @import("sim");
const Run = sim.digital.Run;
const compile = sim.digital.for_emitter.compile;
const rt = sim.rt;
const Edge = rt.Edge;
const Watcher = rt.Watcher;
const Sense = rt.Sense;
const Emitter = @import("Emitter.zig");
const Error = Emitter.Error;
const plan_nodes = @import("plan_nodes.zig");
const plane_words = @import("plane_words.zig");

/// `rt`'s own rows, which the emitted `rt.Design` holds; decided here.
pub const Reach = rt.Reach;

/// `vera --schedule=`: same-time events in the interpreter's FIFO order
/// (`fifo`), or combinational processes levelized into topological nodes
/// (`static`, the default; §11.4.2 lets active events run in any order).
pub const Schedule = enum { fifo, static };

/// One term of an event control, as the native runtime waits on it.
pub const Term = struct {
    slot: u32,
    edge: Edge,
    /// §9.7.3: an indexed event watches every element, but selects which
    /// occurrence resumes it at run time. Its index is not a value event.
    count: u32 = 1,
    event_select: Ast.ExprId = .none,
    /// §9.7.2 a constant select term (`compile.selectTerm`): it watches
    /// bits `[lo, lo + width)` of `slot`; width 0 is the whole slot.
    lo: u32 = 0,
    width: u32 = 0,
};

/// How the runtime schedules one process under `static` (`fifo` leaves
/// every process `general`).
pub const Role = union(enum) {
    /// Queued and woken by the interpreter's rules.
    general,
    /// Suspends only at its entry, an event control whose terms are
    /// static; `rt.State.waiting[n]` holds its suspension stamp there,
    /// 0 while it runs.
    triggered: u32,
    /// Combinational node n: run by a settle event in topological order,
    /// never queued after time 0.
    comb: u32,
};

/// One emitted process: the pc it starts at, every pc it can reach (its
/// switch's prongs, ascending, `pcs[0] == entry` for a process), and its role.
pub const Proc = struct { entry: u32, pcs: []const u32, role: Role = .general };

// Emit-time rows, one per wait term and per process, walked once per pass;
// 3 of Term's and 4 of Proc's bytes are padding no narrower range removes.
comptime {
    assert(@sizeOf(Term) == 24);
    assert(@sizeOf(Proc) <= 32);
}

/// `build`'s result, the tables `rt.Design` is emitted from, in the
/// emitter's arena unless a field says otherwise. The `_start` columns are
/// CSR offsets: slot `s`'s run is `x[x_start[s]..x_start[s + 1]]`.
pub const Plan = struct {
    /// Per slot: an event control, driver or node may wait on it.
    watched: []const bool,
    /// Per slot: what a change of it can wake.
    reach: []const Reach,
    /// Per node, the pc its evaluation starts at.
    node_pc: []const u32 = &.{},
    /// Per slot, the bits its node readers read, ascending by word
    /// (`rt.Design.comb`).
    comb_start: []const u32 = &.{},
    comb: []const Sense = &.{},
    /// Per slot, the triggered processes it wakes (`rt.Design.watchers`).
    watch_start: []const u32 = &.{},
    watchers: []const Watcher = &.{},
    /// The number of triggered processes.
    triggered: u32 = 0,
    /// `Run.waits.fan_start`/`fan` themselves under `fifo` (not copies):
    /// per slot, the pcs of the continuous drivers and controlled switches
    /// reading it.
    fan_start: []const u32,
    fan: []const u32,
};

/// Returns whether the design calls a §18 dump task.
pub fn dumps(r: *const Run) bool {
    for (r.program.code.items) |ins| if (ins == .task and ins.task.task == .dump) return true;
    return false;
}

/// Appends `exec.suspendOn`'s terms of the event expression `e`, in its
/// order. Recursion follows an `or` chain, whose depth the reserved stack
/// of `deep_stack.runGuarded` bounds.
pub fn terms(em: *Emitter, e: Ast.ExprId, out: *std.ArrayList(Term)) Error!void {
    assert(e != .none);
    const r = em.r;
    const ex = &r.file.exprs;
    const before = out.items.len;
    const edge: Edge = switch (ex.tag(e)) {
        .event_or => {
            try terms(em, ex.lhs(e), out);
            return terms(em, ex.rhs(e), out);
        },
        .event_posedge => .posedge,
        .event_negedge => .negedge,
        .event_function => return em.refuse("a VAMS analog event in a digital event control"),
        .event_driver_update => return em.refuse("VAMS §9.22.5 driver_update"),
        else => .any, // else: a name, or an expression checkEvent gave a slot
    };
    const watched = if (edge == .any) e else ex.lhs(e);
    if (ex.tag(watched) == .index) {
        const base = r.slot(r.chainBase(watched).base) catch return em.refuse("an indexed event term the engine resolves only at run time");
        if (r.decls.events.contains(base)) return out.append(em.arena, .{
            .slot = base,
            .edge = .any,
            .count = r.decls.arrays.get(base).?.count,
            .event_select = watched,
        });
    }
    if (compile.selectTerm(r, watched) catch return em.refuse("an event term the engine resolves only at run time")) |sel|
        return out.append(em.arena, .{ .slot = sel.slot, .edge = edge, .lo = sel.first, .width = sel.count });
    const at = r.termSlot(watched) catch return em.refuse("an event term the engine resolves only at run time");
    try out.append(em.arena, .{ .slot = at, .edge = edge });
    assert(out.items.len == before + 1);
}

/// Sets `out` to the terms the instruction at `pc` waits on when a process
/// suspends there: an event control (§9.7.2), an `@*` (§9.7.5), a `wait`'s
/// operands (§9.7.6), an intra-assignment event control (§9.7.7); empty for
/// every other instruction. Sets `em.r.scope` to `pc`'s.
pub fn waitTerms(em: *Emitter, pc: u32, out: *std.ArrayList(Term)) Error!void {
    const r = em.r;
    assert(pc < r.program.code.items.len);
    r.scope = r.program.scope_of.items[pc];
    out.clearRetainingCapacity();
    switch (r.program.code.items[pc]) {
        .wait_event => |e| try terms(em, e, out),
        .wait_slots => |slots| for (r.program.wordsOf(slots)) |s| try out.append(em.arena, .{ .slot = s, .edge = .any }),
        .wait_level => |x| for (r.program.wordsOf(x.slots)) |s| try out.append(em.arena, .{ .slot = s, .edge = .any }),
        .sample => |x| {
            const st = r.file.stmt(x.statement).assign;
            if (!st.timing_is_delay and !compile.parksOnly(st)) try terms(em, st.timing, out);
        },
        else => {}, // else: only these four wait on a slot's value
    }
    for (out.items) |t| assert(t.slot + t.count <= r.values.len);
}

/// Returns the plan of `procs`; under `static` each one's `role` is set too.
/// Asserts that every process is still `general`.
pub fn build(em: *Emitter, procs: []Proc, schedule: Schedule) Error!Plan {
    for (procs) |p| assert(p.role == .general);
    const r = em.r;
    const a = em.arena;
    const fan_start = r.waits.fan_start;
    const fan = r.waits.fan;
    // The slots anything waits on, and the monitor's (§17.1.3).
    const watched, const mon = try watchedSlots(em, procs);
    if (schedule == .fifo) return .{
        .watched = watched,
        .reach = try reachOf(em, procs, mon, fan_start, &.{}, &.{}),
        .fan_start = fan_start,
        .fan = fan,
    };

    // The candidates for a node; the triggered processes get their roles.
    var cands = try plan_nodes.candidates(em, procs);
    // A node whose output an event control waits on stays a queued driver
    // or triggered process. `vera --run` queues each level of logic behind
    // what was queued before it ran, so a process started in between waits
    // before the output changes; one settle event would change it first.
    const waited = try reachOf(em, procs, mon, &.{}, &.{}, &.{});
    var kept: usize = 0;
    for (cands.items) |c| {
        if (for (c.outputs) |o| {
            if (waited[o].terms) break true;
        } else false) continue;
        cands.items[kept] = c;
        kept += 1;
    }
    cands.items = cands.items[0..kept];
    const order = try kahnConeOrder(a, cands.items);
    const node_pc = try a.alloc(u32, order.len);
    const node_of = try a.alloc(?u32, procs.len);
    @memset(node_of, null);
    for (order, 0..) |ci, n| {
        const p = &procs[cands.items[ci].proc];
        p.role = .{ .comb = @intCast(n) };
        node_of[cands.items[ci].proc] = @intCast(n);
        node_pc[n] = if (r.program.code.items[p.entry] == .continuous) p.entry else p.entry + 1;
    }

    // Per slot: the nodes it dirties, the watchers it wakes, the drivers
    // still queued by the interpreter's fan-out.
    const n_slots = r.values.len;
    const comb_lists = try a.alloc(std.ArrayList(Sense), n_slots);
    @memset(comb_lists, .empty);
    for (cands.items) |c| if (node_of[c.proc]) |n| for (c.inputs) |s| {
        // A slot the walk did not see is read whole.
        const masks: ?[]const u64 = if (c.bits) |b| (b.get(s) orelse null) else null;
        for (0..plane_words.words(r.values[s].width)) |j| {
            const m = if (masks) |ms| ms[j] else std.math.maxInt(u64);
            if (m != 0) try comb_lists[s].append(a, .{ .node = n, .word = em.planes.off[s] + @as(u32, @intCast(j)), .mask = m });
        }
    };
    for (comb_lists) |l| std.mem.sort(Sense, l.items, {}, struct {
        fn lt(_: void, x: Sense, y: Sense) bool {
            return x.word < y.word or (x.word == y.word and x.node < y.node);
        }
    }.lt);
    const comb = try csr(Sense, a, comb_lists);

    // A subset of `r.waits.fan`, in its order: at most `fan.len` rows.
    const queued = queued: {
        const n_fan = fan_start.len -| 1;
        const start = try a.alloc(u32, n_fan + 1);
        var items: std.ArrayList(u32) = try .initCapacity(a, fan.len);
        for (start[0..n_fan], 0..) |*at, s| {
            at.* = @intCast(items.items.len);
            for (fan[fan_start[s]..fan_start[s + 1]]) |pc| if (node_of[cands.proc_of[pc]] == null) items.appendAssumeCapacity(pc);
        }
        start[n_fan] = @intCast(items.items.len);
        break :queued .{ .start = start, .items = items.items };
    };

    const watch_lists = try a.alloc(std.ArrayList(Watcher), n_slots);
    @memset(watch_lists, .empty);
    var ts: std.ArrayList(Term) = .empty;
    for (procs) |p| switch (p.role) {
        .triggered => |t| {
            // `fixedWait` admits only a `wait_event` or `wait_slots` entry.
            try waitTerms(em, p.entry, &ts);
            for (ts.items) |term| try watch_lists[term.slot].append(a, .{ .proc = t, .pc = p.entry + 1, .edge = term.edge });
        },
        .general, .comb => {},
    };
    const watch = try csr(Watcher, a, watch_lists);
    assert(comb.start.len == n_slots + 1);
    assert(watch.start.len == n_slots + 1);

    return .{
        .watched = watched,
        .reach = try reachOf(em, procs, mon, queued.start, comb.start, watch.start),
        .node_pc = node_pc,
        .comb_start = comb.start,
        .comb = comb.items,
        .watch_start = watch.start,
        .watchers = watch.items,
        .triggered = cands.triggered,
        .fan_start = queued.start,
        .fan = queued.items,
    };
}

// ---- private ----

/// Per slot: an event control, a driver or a node may wait on it; and the
/// slots the §17.1.3 monitor reads, in the order it reads them.
fn watchedSlots(em: *Emitter, procs: []const Proc) Error!struct { []const bool, []const u32 } {
    const r = em.r;
    const code = r.program.code.items;
    const watched = try em.arena.alloc(bool, r.values.len);
    @memset(watched, false);
    const fan_start = r.waits.fan_start;
    for (0..fan_start.len -| 1) |s| watched[s] = fan_start[s] != fan_start[s + 1];
    var ts: std.ArrayList(Term) = .empty;
    for (procs) |p| for (p.pcs) |pc| {
        // A held slot is never `set`: the store must meet `rt`'s guard.
        if (code[pc] == .override_eval) watched[code[pc].override_eval.slot] = true;
        try waitTerms(em, pc, &ts);
        for (ts.items) |t| @memset(watched[t.slot..][0..t.count], true);
    };
    // §17.1.3 a change of a slot the monitor reads asks it to print; a
    // monitor may sit in any subroutine, so every one is looked at.
    var mon: std.ArrayList(u32) = .empty;
    for (code, 0..) |ins, pc| if (ins == .task and ins.task.task == .monitor) {
        r.scope = r.program.scope_of.items[pc];
        for (r.program.exprs(ins.task.args)) |arg| if (arg != .none and r.file.exprs.tag(arg) != .str_literal)
            compile.sensitivity(r, arg, &mon) catch return em.refuse("a monitor argument the engine resolves only at run time");
    };
    for (mon.items) |s| watched[s] = true;
    // §14.3.3 a module path source's every transition reaches `rt.net.pathSeen`.
    for (r.netlist.cold.items) |c| for (c.paths) |p| {
        watched[p.src] = true;
    };
    // §18: which slots a `$dumpvars` selects is known only at run time, and
    // a dumped change must reach `rt`'s hook, which `set` bypasses.
    // ponytail: every slot of a dumping design; the catalog's alone if it matters.
    if (dumps(r)) @memset(watched, true);
    assert(watched.len == r.values.len);
    return .{ watched, mon.items };
}

/// Kahn's order over the candidates, reordered by `coneOrder`; one on or
/// downstream of a cycle never reaches in-degree 0 and stays event-driven.
/// ponytail: downstream of a cycle is demoted too; Tarjan keeps those if a design needs it.
fn kahnConeOrder(a: Allocator, cands: []const plan_nodes.Cand) Error![]const u32 {
    var readers: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty;
    for (cands, 0..) |c, ci| for (c.inputs) |s| {
        const g = try readers.getOrPut(a, s);
        if (!g.found_existing) g.value_ptr.* = .empty;
        try g.value_ptr.append(a, @intCast(ci));
    };
    const indeg = try a.alloc(u32, cands.len);
    @memset(indeg, 0);
    for (cands) |c| for (c.outputs) |s| if (readers.get(s)) |rs| for (rs.items) |ci| {
        indeg[ci] += 1;
    };
    // Each candidate enters once, when its in-degree reaches 0.
    var queue: std.ArrayList(u32) = try .initCapacity(a, cands.len);
    for (indeg, 0..) |d, ci| if (d == 0) queue.appendAssumeCapacity(@intCast(ci));
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        assert(head < cands.len);
        for (cands[queue.items[head]].outputs) |s| if (readers.get(s)) |rs| for (rs.items) |ci| {
            indeg[ci] -= 1;
            if (indeg[ci] == 0) queue.appendAssumeCapacity(ci);
        };
    }
    assert(queue.items.len <= cands.len);
    return coneOrder(a, cands, queue.items);
}

/// The CSR table of `lists`: list `i` is `items[start[i]..start[i + 1]]`.
fn csr(comptime E: type, a: Allocator, lists: []const std.ArrayList(E)) Allocator.Error!struct { start: []u32, items: []E } {
    const start = try a.alloc(u32, lists.len + 1);
    var n: u32 = 0;
    for (lists, start[0..lists.len]) |l, *at| {
        at.* = n;
        n += @intCast(l.items.len);
    }
    start[lists.len] = n;
    const items = try a.alloc(E, n);
    for (lists, start[0..lists.len]) |l, at| @memcpy(items[at..][0..l.items.len], l.items);
    assert(start[0] == 0);
    assert(items.len == start[lists.len]);
    return .{ .start = start, .items = items };
}

/// Per slot, what its change can wake: the tables' rows, an event control a
/// process files (every wait but a triggered process's or a node's entry; a
/// subroutine a process calls never waits), the monitor, a dump.
fn reachOf(em: *Emitter, procs: []const Proc, mon: []const u32, fan_start: []const u32, comb_start: []const u32, watch_start: []const u32) Error![]const Reach {
    const r = em.r;
    const reach = try em.arena.alloc(Reach, r.values.len);
    @memset(reach, .{});
    for (reach, 0..) |*x, s| {
        x.fan = has(fan_start, s);
        x.comb = has(comb_start, s);
        x.watch = has(watch_start, s);
    }
    var ts: std.ArrayList(Term) = .empty;
    for (procs) |p| for (p.pcs) |pc| {
        if (pc == p.entry and p.role != .general) continue;
        try waitTerms(em, pc, &ts);
        for (ts.items) |t| for (reach[t.slot..][0..t.count]) |*item| {
            item.terms = true;
        };
    };
    for (mon) |s| reach[s].mon = true;
    for (r.netlist.cold.items) |c| for (c.paths) |p| {
        reach[p.src].path = true;
    };
    if (dumps(r)) for (reach) |*x| {
        x.dump = true;
    };
    assert(reach.len == r.values.len);
    return reach;
}

/// Whether CSR row `s` of `start` holds anything; an empty table holds nothing.
fn has(start: []const u32, s: usize) bool {
    if (s + 1 < start.len) assert(start[s] <= start[s + 1]);
    return s + 1 < start.len and start[s] != start[s + 1];
}

/// `acyclic` (Kahn's order of the candidates that are nodes) reordered cone
/// by cone: a depth-first post-order over each node's writers, deepest
/// first, from the last node back, so a node lands just after the nodes it
/// reads, and mostly in their dirty word. Any topological order is one
/// §11.4.2 permits for the settle event.
fn coneOrder(a: Allocator, cands: []const plan_nodes.Cand, acyclic: []const u32) Error![]const u32 {
    var writers: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty;
    for (acyclic) |ci| for (cands[ci].outputs) |s| {
        const g = try writers.getOrPut(a, s);
        if (!g.found_existing) g.value_ptr.* = .empty;
        try g.value_ptr.append(a, ci);
    };
    // Per node, the nodes that write what it reads, by longest path from a
    // source, deepest first: the chain a node ends is laid down before the
    // shallow inputs that join it.
    const level = try a.alloc(u32, cands.len);
    const preds = try a.alloc([]u32, cands.len);
    var edges: usize = 0;
    for (acyclic) |ci| {
        var n: usize = 0;
        for (cands[ci].inputs) |s| if (writers.get(s)) |l| {
            n += l.items.len;
        };
        var ps: std.ArrayList(u32) = try .initCapacity(a, n);
        level[ci] = 0;
        for (cands[ci].inputs) |s| if (writers.get(s)) |l| for (l.items) |w| {
            ps.appendAssumeCapacity(w);
            level[ci] = @max(level[ci], level[w] + 1);
        };
        preds[ci] = ps.items;
        edges += n;
    }
    for (acyclic) |ci| std.mem.sort(u32, preds[ci], level, struct {
        fn deeper(lv: []const u32, x: u32, y: u32) bool {
            return lv[x] > lv[y];
        }
    }.deeper);
    const done = try a.alloc(bool, cands.len);
    @memset(done, false);
    const Frame = struct { ci: u32, next: u32 = 0 };
    // Every node is pushed once (`done`) and popped into `order` once.
    var stack: std.ArrayList(Frame) = try .initCapacity(a, acyclic.len);
    var order: std.ArrayList(u32) = try .initCapacity(a, acyclic.len);
    var steps: usize = 0;
    var i = acyclic.len;
    while (i > 0) {
        i -= 1;
        if (done[acyclic[i]]) continue;
        done[acyclic[i]] = true;
        stack.appendAssumeCapacity(.{ .ci = acyclic[i] });
        while (stack.items.len != 0) : (steps += 1) {
            // A step pops a frame or advances along one edge.
            assert(steps <= 2 * acyclic.len + edges);
            const f = &stack.items[stack.items.len - 1];
            if (f.next == preds[f.ci].len) {
                order.appendAssumeCapacity(f.ci);
                _ = stack.pop();
                continue;
            }
            const w = preds[f.ci][f.next];
            f.next += 1;
            if (done[w]) continue;
            done[w] = true;
            stack.appendAssumeCapacity(.{ .ci = w });
        }
    }
    assert(order.items.len == acyclic.len);
    return order.items;
}
