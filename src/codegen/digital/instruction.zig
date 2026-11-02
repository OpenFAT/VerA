//! One bytecode instruction at a pc -> the body of its prong in its
//! process's `switch`, `exec.execute`'s arm for arm: stores, control flow,
//! suspensions, triggers, disables, calls, forks, the §9.3 procedural
//! continuous assignments and the §7.6 switch controls. A system task is
//! `tasks.zig`'s, a continuous driver `drivers.zig`'s.
//! Cites: IEEE 1364-2005 §7.6, §9.2, §9.3, §9.3.2, §9.4, §9.5, §9.6, §9.7.1,
//! §9.7.2, §9.7.3, §9.7.6, §9.7.7, §9.8.2, §10.2.2, §10.2.3, §10.3, §17.5.
//!
//! Contents:
//! - `pub fn instruction(em: *Emitter, pc: u32) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const sim_digital = @import("sim").digital;
const Run = sim_digital.Run;
const compile = sim_digital.for_emitter.compile;
const Emitter = @import("Emitter.zig");
const Error = Emitter.Error;
const assign = @import("assign.zig");
const calls = @import("calls.zig");
const drivers = @import("drivers.zig");
const expr = @import("expr.zig");
const expr_select = @import("expr_select.zig");
const layout = @import("layout.zig");
const plan = @import("plan.zig");
const plane_words = @import("plane_words.zig");
const tasks = @import("tasks.zig");
const timing = @import("timing.zig");

const disable_inside = "a §10.3 disable from inside a block other processes may still be inside";

const Override = @FieldType(compile.Instruction, "override_eval");

const Release = @FieldType(compile.Instruction, "override_off");

/// Writes the prong body of the instruction at `pc`. Asserts that `em.r`'s
/// scope and pc are `pc`'s.
pub fn instruction(em: *Emitter, pc: u32) Error!void {
    const r = em.r;
    assert(r.pc == pc);
    assert(r.scope == r.program.scope_of.items[pc]);
    const next = pc + 1;
    switch (r.program.code.items[pc]) {
        .stop => try em.print("            return;\n", .{}),
        .init_var => |x| {
            try em.print("            ", .{});
            try assign.store(em, x.slot, .blocking);
            try expr.assigned(em, x.value, r.slotType(x.slot));
            try em.print(", {f});\n            continue :sw {d};\n", .{ plane_words.full(em.slotWidth(x.slot)), next });
        },
        .assign => |x| {
            try assign.assignment(em, x.target, .{ .expr = x.value }, if (x.nonblocking) .nba else .blocking);
            try em.print("            continue :sw {d};\n", .{next});
        },
        .delay => |x| {
            try em.print("            try s.run({d}, ", .{next});
            try timing.delay(em, x.amount);
            try em.print(");\n            return;\n", .{});
        },
        .task => |t| try tasks.systemTask(em, pc, t),
        // A backward jump is one pass of a loop: `exec.loopIteration`.
        .jump => |t| try em.print("{s}            continue :sw {d};\n", .{ if (t <= pc) "            try s.loopIteration();\n" else "", t }),
        .branch => |b| {
            // Two constant `continue`s: each is a direct jump, where one
            // `continue` of a selected pc is a jump through the table.
            try em.print("            if (", .{});
            try expr.truth(em, b.condition);
            try em.print(" == .one) continue :sw {d};\n            continue :sw {d};\n", .{ next, b.otherwise });
        },
        .case_select => |c| {
            const case = r.file.stmt(c.statement).case_stmt;
            try em.fits(c.ty);
            try em.print("            const v = ", .{});
            try expr.value(em, case.scrutinee, c.ty);
            try em.print(";\n", .{});
            // A case of only `default` reads its scrutinee and nothing else.
            for (case.arms) |arm| {
                if (arm.labels.len != 0) break;
            } else try em.print("            _ = v;\n", .{});
            for (case.arms, 0..) |arm, i| for (arm.labels) |lb| {
                try em.print("            if (L.caseMatch(.{t}, v, ", .{case.kind});
                try expr.caseLabel(em, lb, c.ty, case.kind);
                try em.print(")) continue :sw {d};\n", .{r.program.case_targets.items[c.targets + i]});
            };
            try em.print("            continue :sw {d};\n", .{c.fallback});
        },
        .repeat_start => |x| {
            try em.print("            const n = rt.repeatCount(", .{});
            const ty = try expr.selfDetermined(em, x.count);
            try em.print(", {d}, {});\n            s.repeats[{d}] = n;\n            if (n == 0) continue :sw {d};\n            continue :sw {d};\n", .{ ty.width, ty.signed, x.counter, x.end, next });
        },
        .repeat_next => |x| try em.print("            s.repeats[{d}] -= 1;\n            if (s.repeats[{d}] != 0) {{\n                try s.loopIteration();\n                continue :sw {d};\n            }}\n            continue :sw {d};\n", .{ x.counter, x.counter, x.body, next }),
        .wait_event => |e| {
            if (try timing.waitFixed(em)) return;
            try em.print("            const id = try s.park({d});\n", .{next});
            var ts: std.ArrayList(plan.Term) = .empty;
            try plan.terms(em, e, &ts);
            try timing.eventWatches(em, ts.items);
            try em.print("            return;\n", .{});
        },
        .wait_slots => |slots| {
            if (try timing.waitFixed(em)) return;
            // An `assign` or `force` of a constant waits on nothing.
            if (slots.len == 0) return em.print("            _ = try s.park({d});\n            return;\n", .{next});
            try em.print("            const id = try s.park({d});\n", .{next});
            for (r.program.wordsOf(slots)) |at| try em.print("            try s.watch(id, {d}, .any);\n", .{at});
            try em.print("            return;\n", .{});
        },
        .wait_level => |x| {
            // Its slots were never planned as watched.
            if (em.site.in_sub) return em.refuse("a `wait` in a task with no other timing control");
            try em.print("            if (", .{});
            try expr.truth(em, x.cond);
            // An empty list suspends with nothing to wake it (IEEE 1364-2005 §9.7.6).
            if (x.slots.len == 0) return em.print(" == .one) continue :sw {d};\n            _ = try s.park({d});\n            return;\n", .{ next, pc });
            try em.print(" == .one) continue :sw {d};\n            const id = try s.park({d});\n", .{ next, pc });
            for (r.program.wordsOf(x.slots)) |at| try em.print("            try s.watch(id, {d}, .any);\n", .{at});
            try em.print("            return;\n", .{});
        },
        .trigger => |event| switch (event) {
            .slot => |at| try em.print("            {s}try s.wake({d}, .x, .x);\n            continue :sw {d};\n", .{ if (plan.dumps(r)) try em.arena.print("s.fire({d});\n            ", .{at}) else "", at, next }),
            .indexed => |e| {
                try em.print("            if (", .{});
                try expr_select.address(em, e, em.label());
                try em.print(") |at| {{\n", .{});
                if (plan.dumps(r)) try em.print("                s.fire(at);\n", .{});
                try em.print("                try s.wake(at, .x, .x);\n            }}\n            continue :sw {d};\n", .{next});
            },
        },
        .restart => |x| try em.print(
            \\            if (restarted) try s.loopIteration();
            \\            restarted = true;
            \\            continue :sw {d};
            \\
        , .{x.target}),
        .continuous => |i| try drivers.continuous(em, pc, i),
        .sample => |x| try sample(em, pc, x.statement, x.cell),
        // The target is resolved when the process resumes (§9.7.7).
        .deposit => |x| {
            const st = r.file.stmt(x.statement).assign;
            const ty = try assign.targetType(em, st.target);
            try assign.assignment(em, st.target, .{ .stored = .{ .off = try layout.cellOf(&em.planes, em.arena, x.cell, ty.width), .ty = .{ .width = ty.width, .signed = false } } }, if (st.nonblocking) .nba else .blocking);
            try em.print("            continue :sw {d};\n", .{next});
        },
        // §10.3: a disable inside the block it names continues after it.
        .disable_block => |b| {
            if (pc >= b.start and pc < b.end and hostsOthers(r, b.start, b.end)) return em.refuse(disable_inside);
            try em.print("            try s.disable({d}, {d}, {d});\n            continue :sw {d};\n", .{
                b.start, b.end, b.end, if (pc >= b.start and pc < b.end) b.end else next,
            });
        },
        // §10.3 every activation of the task ends: each inlined copy, and
        // the synchronous ones, which unwind back to their callers.
        .disable_task => |idx| {
            var after = next;
            for (r.routines.rows.items[idx].ranges.items) |rg| {
                if (pc >= rg.start and pc < rg.end and hostsOthers(r, rg.start, rg.end)) return em.refuse(disable_inside);
                try em.print("            try s.disable({d}, {d}, {d});\n", .{ rg.start, rg.end, rg.end });
                if (pc >= rg.start and pc < rg.end) after = rg.end;
            }
            try em.print("            if (s.calls.active[{d}] != 0) {{\n                s.unwind = {d};\n                return;\n            }}\n            continue :sw {d};\n", .{ idx, idx, after });
        },
        .call => |c| {
            try calls.call(em, c.sub, r.program.exprs(c.args), em.label());
            try em.print("            continue :sw {d};\n", .{next});
        },
        // §10.2.2 an inlined task's output, copied back in the caller's scope.
        .copy_out => |c| {
            try assign.assignment(em, c.target, .{ .stored = .{ .off = em.planes.off[c.slot], .ty = r.slotType(c.slot) } }, .blocking);
            try em.print("            continue :sw {d};\n", .{next});
        },
        // §9.8.2: every arm starts now; the last one back resumes the parent.
        .fork => |f| {
            if (f.arms.len == 0) return em.print("            continue :sw {d};\n", .{f.end});
            try em.print("            s.joins[{d}] = {d};\n", .{ f.join, f.arms.len });
            for (r.program.wordsOf(f.arms)) |arm| try em.print("            try s.run({d}, null);\n", .{arm});
            try em.print("            return;\n", .{});
        },
        .join_arm => |j| try em.print("            s.joins[{d}] -= 1;\n            if (s.joins[{d}] == 0) try s.run({d}, null);\n            return;\n", .{ j.join, j.join, j.end }),
        // §17.5 an asynchronous array's own process starts now. `exec`'s
        // `now` start is a nested dispatch: the child parks first.
        .pla_start => |p| if (p.now)
            try em.print("            try dispatch(s, {d});\n            continue :sw {d};\n", .{ p.at, next })
        else
            try em.print("            try s.run({d}, null);\n            continue :sw {d};\n", .{ p.at, next }),
        .override_on => |o| if (o.bits.some()) |b|
            try em.print("            try s.overrideBits({d}, {d}, {d}, {d}, {d}, {d});\n            continue :sw {d};\n", .{ o.slot, em.forced.partOf(o.slot, b).?, b.lo, b.width, o.start, o.end, next })
        else
            try em.print("            try s.overrideOn({d}, {}, {d}, {d});\n            continue :sw {d};\n", .{ o.slot, o.force, o.start, o.end, next }),
        .override_eval => |o| try overrideEval(em, next, o),
        .override_off => |o| try overrideOff(em, next, o),
        // §7.6 a controlled pass switch: read the control, re-resolve both
        // sides (`rt.net.switchCtrl`), and re-arm on the control's operands.
        .switch_ctrl => |sc| {
            try drivers.bits(em, &.{r.netlist.switches[sc.tran].ctrl}, 0);
            try em.print("            try s.switchCtrl({d}, b[0]);\n            s.armed[{d}] = true;\n            return;\n", .{ sc.tran, pc });
        },
        .call_timed => |c| try calls.callTimed(em, pc, c.sub, r.program.exprs(c.args)),
        // §10.2.2 the outputs are put aside (`calls.returnCell`) while this
        // activation's storage is still resident; the call site copies them.
        .task_return => |idx| {
            const sub = r.routines.rows.items[idx];
            for (sub.decl.ports, sub.body.?.frame.ports) |p, at| if (p.direction != .input) {
                try em.print("            try M.set(s, {d}, ", .{try calls.returnCell(em, at)});
                try em.get(at);
                try em.print(", {f});\n", .{plane_words.full(em.slotWidth(at))});
            };
            try em.print("            s.jump = try s.returnTimed();\n            return;\n", .{});
        },
    }
}

// ---- private ----

/// §9.7.7 the value is read now; a nonblocking update is scheduled at once,
/// a blocking one parked in its cell until the control passes.
fn sample(em: *Emitter, pc: u32, statement: Ast.StmtId, cell: u32) Error!void {
    const r = em.r;
    const next = pc + 1;
    const st = r.file.stmt(statement).assign;
    assert(st.timing != .none);
    if (st.nonblocking and st.timing_is_delay) {
        try assign.assignment(em, st.target, .{ .expr = st.value }, .{ .nba_after = st.timing });
        return em.print("            continue :sw {d};\n", .{next});
    }
    const ty = try assign.targetType(em, st.target);
    try em.print("            try M.set(s, {d}, ", .{try layout.cellOf(&em.planes, em.arena, cell, ty.width)});
    try expr.assigned(em, st.value, ty);
    try em.print(", {f});\n", .{plane_words.full(ty.width)});
    if (compile.parksOnly(st)) return em.print("            continue :sw {d};\n", .{next});
    if (st.timing_is_delay) {
        try em.print("            try s.run({d}, ", .{next});
        try timing.delay(em, st.timing);
        return em.print(");\n            return;\n", .{});
    }
    try em.print("            const id = try s.park({d});\n", .{next});
    var ts: std.ArrayList(plan.Term) = .empty;
    try plan.terms(em, st.timing, &ts);
    try timing.eventWatches(em, ts.items);
    try em.print("            return;\n", .{});
}

/// §9.3 an `assign` or `force` re-evaluating its value; an `assign` under
/// a `force` keeps tracking but does not write.
fn overrideEval(em: *Emitter, next: u32, o: Override) Error!void {
    assert(o.slot < em.r.values.len);
    try em.print("            if ({} or !s.forced({d})) {{\n            s.overriding = true;\n            defer s.overriding = false;\n            ", .{ o.force, o.slot });
    if (o.bits.some()) |b| {
        try em.print("try s.putBits({d}, {d}, {d}, {d}, {d}, ", .{ o.slot, em.planes.off[o.slot], b.lo, b.width, em.slotWidth(o.slot) });
        try expr.assigned(em, o.value, .{ .width = b.width, .signed = false });
        return em.print(");\n            }}\n            continue :sw {d};\n", .{next});
    }
    try assign.store(em, o.slot, .blocking);
    // An operand of a §9.3 concatenation target takes its window of the
    // value, evaluated as wide as the whole target.
    if (o.slice.some()) |sl| {
        try em.print("L.part(", .{});
        try expr.assigned(em, o.value, .{ .width = sl.of, .signed = false });
        try em.print(", {d}, {d}, {d})", .{ sl.lo, em.slotWidth(o.slot), sl.of });
    } else try expr.assigned(em, o.value, em.r.slotType(o.slot));
    try em.print(", {f});\n            }}\n            continue :sw {d};\n", .{ plane_words.full(em.slotWidth(o.slot)), next });
}

/// §9.3.2: a released net is its driver's again, at once.
fn overrideOff(em: *Emitter, next: u32, o: Release) Error!void {
    const r = em.r;
    assert(o.slot < r.values.len);
    if (o.bits.some()) |b| {
        // Releasing a select never forced is a no-op (`waiters.releaseBits`).
        if (em.forced.partOf(o.slot, b)) |k| {
            const net = r.netlist.slot_nets.get(o.slot) orelse return em.refuse("a force of a select of a variable");
            try em.print("            try s.releaseBits({d}, {d});\n            try s.resolve({d});\n", .{ o.slot, k, em.rt.netRow(net).? });
        }
        return em.print("            continue :sw {d};\n", .{next});
    }
    if (r.netlist.slot_nets.get(o.slot)) |net| {
        if (em.rt.netRow(net)) |k| {
            try em.print("            if (try s.release({d}, true)) try s.resolve({d});\n            continue :sw {d};\n", .{ o.slot, k, next });
            return;
        }
        const ds = r.netDrivers(net);
        if (ds.len != 1) return em.refuse("releasing a net without exactly one driver");
        const at = for (r.program.code.items, 0..) |ins, i| {
            if (ins == .continuous and ins.continuous == ds[0]) break i;
        } else return em.refuse("releasing a net whose driver is not a process");
        try em.print("            if (try s.release({d}, true)) try proc{d}(s, {d});\n", .{ o.slot, at, at });
    } else try em.print("            _ = try s.release({d}, {});\n", .{ o.slot, o.force });
    try em.print("            continue :sw {d};\n", .{next});
}

/// Whether another process can be suspended or queued inside pcs
/// [start, end) when a `disable` inside them runs: a §9.8.2 fork arm, a
/// process a `pla_start` or `override_on` starts, or a §9.7.2 expression
/// term's tracker, whose first instruction keeps its hidden slot
/// (`compile.exprTerm`). Then `rt.State.disable` would resume the end
/// besides the disabling process, which `exec.disableInside` avoids and `rt`
/// cannot yet.
fn hostsOthers(r: *const Run, start: u32, end: u32) bool {
    assert(start <= end);
    assert(end <= r.program.code.items.len);
    // ponytail: a refusal; `rt` exposing `stop` lets these disables be native.
    for (r.program.code.items[start..end]) |ins| switch (ins) {
        .fork, .pla_start, .override_on => return true,
        .init_var => |x| {
            var it = r.typing.term_slots.valueIterator();
            while (it.next()) |at| if (at.* == x.slot) return true;
        },
        else => {}, // else: every other instruction runs in the process that reaches it
    };
    return false;
}
