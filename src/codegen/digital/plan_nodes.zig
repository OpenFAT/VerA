//! A native design's processes -> the candidates for a `static` settle node
//! and the processes that are `triggered` (one fixed event control): a
//! plain continuous driver, or a process that suspends only at its entry on
//! value changes of plain names and writes only whole vectors or selects,
//! with the bits each one's evaluation reads (§5.2.1 constant selects read
//! only the bits they name).
//! Cites: IEEE 1364-2005 §5.2.1, §5.2.2, §6.1, §9.7.2, §9.7.3, §9.7.5,
//! §10.3, §11.4.2.
//!
//! Contents:
//! - `pub const Bits = std.AutoHashMapUnmanaged(u32, ?[]u64)`
//! - `pub const Cand = struct`
//! - `pub const Candidates = struct`
//! - `pub fn candidates(em: *Emitter, procs: []plan.Proc) Error!Candidates`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const sim_digital = @import("sim").digital;
const compile = sim_digital.for_emitter.compile;
const evaluate = sim_digital.for_emitter.evaluate;
const Emitter = @import("Emitter.zig");
const Error = Emitter.Error;
const expr = @import("expr.zig");
const nets = @import("nets.zig");
const plan = @import("plan.zig");
const plane_words = @import("plane_words.zig");

/// Per slot, the bits an expression reads, one mask per plane word; null
/// when it reads the whole slot.
pub const Bits = std.AutoHashMapUnmanaged(u32, ?[]u64);

/// A candidate for a node: its process (an index into `procs`), the slots it
/// reads and writes, and the bits of each it reads (`null`: a node re-runs
/// on any change of an input).
pub const Cand = struct { proc: u32, inputs: []const u32, outputs: []const u32, bits: ?Bits = null };

/// `candidates`' result: the candidates in process order, per pc the process
/// it belongs to (meaningful for the processes' own pcs only), and how many
/// processes are triggered.
pub const Candidates = struct { items: []Cand, proc_of: []const u32, triggered: u32 };

const Range = struct { lo: u32, hi: u32 };

/// Returns the node candidates of `procs` and sets each triggered process's
/// role. Asserts that every process is `general`.
pub fn candidates(em: *Emitter, procs: []plan.Proc) Error!Candidates {
    const r = em.r;
    const a = em.arena;
    const code = r.program.code.items;
    const fan_start = r.waits.fan_start;
    const fan = r.waits.fan;
    // One per process at most.
    var cands: std.ArrayList(Cand) = try .initCapacity(a, procs.len);
    const proc_of = try a.alloc(u32, code.len);
    for (procs, 0..) |p, i| for (p.pcs) |pc| {
        proc_of[pc] = @intCast(i);
    };
    // Per process, the slots it is in the fan-out of, ascending: a counting
    // sort of `fan` by process.
    const reads = try a.alloc([]u32, procs.len);
    {
        const fill_at = try a.alloc(u32, procs.len + 1);
        @memset(fill_at, 0);
        for (0..fan_start.len -| 1) |s| for (fan[fan_start[s]..fan_start[s + 1]]) |pc| {
            fill_at[proc_of[pc] + 1] += 1;
        };
        for (fill_at[1..], 0..) |*c, k| c.* += fill_at[k];
        const flat = try a.alloc(u32, fill_at[procs.len]);
        for (reads, fill_at[0..procs.len], fill_at[1..]) |*l, lo, hi| l.* = flat[lo..hi];
        for (0..fan_start.len -| 1) |s| for (fan[fan_start[s]..fan_start[s + 1]]) |pc| {
            flat[fill_at[proc_of[pc]]] = @intCast(s);
            fill_at[proc_of[pc]] += 1;
        };
    }
    var triggered: u32 = 0;
    const ranges = try disableRanges(em);
    for (procs, 0..) |*p, i| {
        assert(p.role == .general);
        switch (code[p.entry]) {
            // A resolved net's driver is queued: `rt.net` delays or folds it.
            .continuous => |d| if (nets.plainDriver(r, em.forced.select_forced, d)) cands.appendAssumeCapacity(.{
                .proc = @intCast(i),
                .inputs = reads[i],
                .outputs = try a.dupe(u32, &.{r.netlist.nets[r.netlist.drivers[d].net].slot}),
                .bits = try driverBits(em, d),
            }),
            .wait_event, .wait_slots => if (!disabled(ranges, p.*) and try fixedWait(em, p.*)) {
                p.role = .{ .triggered = triggered };
                triggered += 1;
                if (try combinational(em, p.*)) |io| cands.appendAssumeCapacity(.{
                    .proc = @intCast(i),
                    .inputs = io.inputs,
                    .outputs = io.outputs,
                    // §9.7.5: `@*` lists every slot its body reads, so the body
                    // is a function of the bits it reads. An explicit list may
                    // omit one, and then any change of a listed slot must re-run it.
                    .bits = if (code[p.entry] == .wait_slots) try bodyBits(em, p.*) else null,
                });
            },
            else => {}, // else: anything else suspends where the interpreter says
        }
    }
    assert(cands.items.len <= procs.len);
    assert(triggered <= procs.len);
    return .{ .items = cands.items, .proc_of = proc_of, .triggered = triggered };
}

// ---- private ----

/// Whether `p` suspends only at its entry, returning there after every pass.
fn fixedWait(em: *Emitter, p: plan.Proc) Error!bool {
    assert(p.pcs.len != 0);
    // An indexed named event re-evaluates its index at each occurrence;
    // its suspension therefore needs a selector, not a fixed watcher. A
    // select term remembers its bits per suspension (`rt.State.watchBits`).
    // ponytail: such a process is general, not triggered; give `Watcher`
    // a bit window if a levelized design needs it.
    var ts: std.ArrayList(plan.Term) = .empty;
    try plan.waitTerms(em, p.entry, &ts);
    for (ts.items) |t| if (t.event_select != .none or t.width != 0) return false;
    for (p.pcs) |pc| {
        if (pc == p.entry) continue;
        switch (em.r.program.code.items[pc]) {
            .restart => |x| if (x.target != p.entry) return false,
            .delay, .wait_event, .wait_slots, .wait_level, .continuous, .stop => return false,
            // A synchronous call runs to completion (`calls.call`).
            .assign, .task, .branch, .jump, .case_select, .repeat_start, .repeat_next, .trigger, .init_var, .call => {},
            .sample, .deposit, .disable_block, .disable_task, .copy_out, .call_timed, .task_return, .pla_start, .fork, .join_arm, .override_on, .override_eval, .override_off, .switch_ctrl => return false,
        }
    }
    return true;
}

/// The pc ranges a `disable` (§10.3) stops: a process reaching into one
/// keeps the interpreter's queued resumptions, which a disable cancels by pc.
fn disableRanges(em: *Emitter) Error![]const Range {
    const r = em.r;
    var out: std.ArrayList(Range) = .empty;
    for (r.program.code.items) |ins| switch (ins) {
        .disable_block => |b| try out.append(em.arena, .{ .lo = b.start, .hi = b.end }),
        .disable_task => |idx| for (r.routines.rows.items[idx].ranges.items) |rg| try out.append(em.arena, .{ .lo = rg.start, .hi = rg.end }),
        else => {}, // else: no other instruction stops another process
    };
    for (out.items) |rg| assert(rg.lo <= rg.hi);
    return out.items;
}

/// Whether some pc of `p` lies in a disabled range.
fn disabled(ranges: []const Range, p: plan.Proc) bool {
    assert(p.pcs.len != 0);
    for (ranges) |rg| for (p.pcs) |pc| if (pc >= rg.lo and pc < rg.hi) return true;
    return false;
}

/// A fixed-wait process that is a node: every term is a plain name (any
/// change) of a value, not a named event, its body writes only whole vectors
/// or selects of them, and it prints nothing. Its inputs are its terms; its
/// outputs what it writes. A system function that writes (`$random`'s seed)
/// would write what is not an output, so a body that calls one is no node.
fn combinational(em: *Emitter, p: plan.Proc) Error!?struct { inputs: []const u32, outputs: []const u32 } {
    const r = em.r;
    const ex = &r.file.exprs;
    r.scope = r.program.scope_of.items[p.entry];
    const inputs: []const u32 = switch (r.program.code.items[p.entry]) {
        .wait_event => |e| inputs: {
            var ts: std.ArrayList(plan.Term) = .empty;
            try plan.terms(em, e, &ts);
            // One input per term.
            const in = try em.arena.alloc(u32, ts.items.len);
            for (ts.items, in) |t, *i| {
                // §9.7.3 a named event holds no value, so no change of one
                // would ever dirty a node.
                if (t.edge != .any or r.decls.events.contains(t.slot)) return null;
                i.* = t.slot;
            }
            break :inputs in;
        },
        // §9.7.5 an `@*` over a body that reads nothing never wakes; a
        // settle node would run it once.
        .wait_slots => |slots| if (slots.len == 0) return null else try em.arena.dupe(u32, r.program.wordsOf(slots)),
        else => return null,
    };
    // At most one output per instruction.
    var outputs: std.ArrayList(u32) = try .initCapacity(em.arena, p.pcs.len);
    for (p.pcs) |pc| {
        r.scope = r.program.scope_of.items[pc];
        switch (r.program.code.items[pc]) {
            .assign => |x| {
                if (expr.effects(em, x.value) or expr.effects(em, x.target)) return null;
                const t = if (ex.tag(x.target) == .index) ex.lhs(x.target) else x.target;
                if (ex.tag(t) != .ident and ex.tag(t) != .hier_ident) return null;
                if (try em.element(x.target)) return null;
                outputs.appendAssumeCapacity(r.slot(t) catch return null);
            },
            .task, .trigger, .init_var, .call => return null,
            .branch => |b| if (expr.effects(em, b.condition)) return null,
            .case_select => |c| if (expr.effects(em, r.file.stmt(c.statement).case_stmt.scrutinee)) return null,
            .repeat_start => |x| if (expr.effects(em, x.count)) return null,
            else => {}, // else: `fixedWait` already refused every suspension
        }
    }
    assert(outputs.items.len <= p.pcs.len);
    return .{ .inputs = inputs, .outputs = outputs.items };
}

/// The bits plain driver `d`'s expression reads; null for a gate or switch.
fn driverBits(em: *Emitter, d: u32) Error!?Bits {
    const r = em.r;
    assert(d < r.netlist.drivers.len);
    const x = switch (r.netlist.drivers[d].source) {
        .expr => |x| x,
        .bridge, .gate, .udp, .mos, .pull => return null,
    };
    r.scope = r.netlist.drivers[d].scope;
    var out: Bits = .empty;
    try readBits(em, x.e, &out);
    return out;
}

/// The bits a combinational body reads: every expression of every
/// instruction `combinational` admits, `compile.readSlots`'s walk; null
/// when one is not walked.
fn bodyBits(em: *Emitter, p: plan.Proc) Error!?Bits {
    const r = em.r;
    const ex = &r.file.exprs;
    assert(p.pcs.len != 0);
    var out: Bits = .empty;
    for (p.pcs) |pc| {
        r.scope = r.program.scope_of.items[pc];
        switch (r.program.code.items[pc]) {
            .assign => |x| {
                try readBits(em, x.value, &out);
                var t = x.target;
                while (ex.tag(t) == .index) : (t = ex.lhs(t)) try readBits(em, ex.rhs(t), &out);
            },
            .branch => |b| try readBits(em, b.condition, &out),
            .case_select => |c| {
                const case = r.file.stmt(c.statement).case_stmt;
                try readBits(em, case.scrutinee, &out);
                for (case.arms) |arm| for (arm.labels) |lb| try readBits(em, lb, &out);
            },
            .repeat_start => |x| try readBits(em, x.count, &out),
            .jump, .repeat_next, .restart, .wait_event, .wait_slots => {},
            .delay, .task, .continuous, .wait_level, .sample, .deposit, .trigger, .disable_block, .init_var, .call, .copy_out, .disable_task, .call_timed, .task_return, .pla_start, .fork, .join_arm, .override_on, .override_eval, .override_off, .switch_ctrl, .stop => return null,
        }
    }
    return out;
}

/// Records in `out` the bits `e` reads (`compile.sensitivity`'s walk): a
/// constant select of a vector reads the bits it names (§5.2.1), anything
/// else the whole of every slot it names. Recursion follows the expression,
/// whose depth the reserved stack of `deep_stack.runGuarded` bounds.
fn readBits(em: *Emitter, e: Ast.ExprId, out: *Bits) Error!void {
    assert(e != .none);
    const r = em.r;
    const ex = &r.file.exprs;
    switch (ex.tag(e)) {
        .ident, .hier_ident => try out.put(em.arena, r.slot(e) catch return em.refuse("a name the engine resolves only at run time"), null),
        .index => if (try em.element(e)) {
            // An element names a slot only at run time: `sensitivity` lists
            // every element, and those it reads whole.
            var x = e;
            while (ex.tag(x) == .index) : (x = ex.lhs(x)) try readBits(em, ex.rhs(x), out);
        } else {
            if (ex.tag(ex.lhs(e)) == .index) {
                // The selected word can vary at run time. Its array slots
                // keep whole-slot sensitivity, and both addressing stages
                // contribute their own input reads (§5.2.2).
                try readBits(em, ex.lhs(e), out);
                return readBits(em, ex.rhs(e), out);
            }
            const at = r.slot(ex.lhs(e)) catch return em.refuse("a name the engine resolves only at run time");
            const rg = ex.rhs(e);
            const width = r.values[at].width;
            const base = if (ex.tag(rg) == .indexed_range) ex.lhs(rg) else rg;
            const sel: ?evaluate.Sel = if (ex.tag(rg) == .range or compile.constantExpression(r, base)) blk: {
                // Share the interpreter's direction/width calculation,
                // including constant indexed ranges. Null names no bit.
                break :blk (evaluate.selection(r, em.arena, e) catch return em.refuse("a constant select the engine does not fold")) orelse .{ .first = 0, .count = 0 };
            } else null;
            const g = try out.getOrPut(em.arena, at);
            const s = sel orelse {
                g.value_ptr.* = null;
                return readBits(em, rg, out);
            };
            if (!g.found_existing) {
                const ms = try em.arena.alloc(u64, plane_words.words(width));
                @memset(ms, 0);
                g.value_ptr.* = ms;
            }
            const ms = g.value_ptr.* orelse return;
            for (0..s.count) |i| {
                const p = s.first + @as(i64, @intCast(i));
                if (p < 0 or p >= width) continue;
                ms[@intCast(@divFloor(p, 64))] |= @as(u64, 1) << @intCast(@mod(p, 64));
            }
        },
        .int_literal, .logic_literal, .str_literal, .real_literal => {},
        else => { // else: every other form reads what its operands read
            var buf: [3]Ast.ExprId = undefined;
            for (ex.children(e, &buf)) |c| if (c != .none) try readBits(em, c, out);
        },
    }
}
