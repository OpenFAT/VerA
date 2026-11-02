//! A §9.7 timing control -> Zig text: a delay as `rt` ticks (folded when
//! constant), a suspension's watched terms, the entry of a process the plan
//! made triggered or a node, and the §9.7.3 selectors of indexed named
//! events.
//! Cites: IEEE 1364-2005 §9.7.1 (delays; a negative one is its 64-bit two's
//! complement), §9.7.2, §9.7.3, §9.7.5; §4.8.2 (a real delay rounds).
//!
//! Contents:
//! - `pub fn delay(em: *Emitter, amount: Ast.ExprId) Error!void`
//! - `pub fn waitFixed(em: *Emitter) Error!bool`
//! - `pub fn eventWatches(em: *Emitter, ts: []const plan.Term) Error!void`
//! - `pub fn eventSelectors(em: *Emitter) Error!void`
//! - `pub fn selectedEvents(em: *Emitter, two_phase: bool) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const sim_digital = @import("sim").digital;
const compile = sim_digital.for_emitter.compile;
const evaluate = sim_digital.for_emitter.evaluate;
const Emitter = @import("Emitter.zig");
const Error = Emitter.Error;
const expr = @import("expr.zig");
const expr_real = @import("expr_real.zig");
const expr_select = @import("expr_select.zig");
const plan = @import("plan.zig");

/// Writes `exec.delayOf` of `amount`, in ticks: folded when constant, else
/// `s.ticks`/`s.realTicks` of the value read now.
pub fn delay(em: *Emitter, amount: Ast.ExprId) Error!void {
    assert(amount != .none);
    const r = em.r;
    const scale = r.timeOf(r.scope).scale;
    const t = compile.typeOf(em.r, amount);
    if (t.real) {
        // A constant no tick count holds fails at run time, as the
        // interpreter's does, through `s.realTicks`: a `return` here would
        // sit in the argument list of the call that schedules the delay.
        if (compile.constantExpression(r, amount)) fold: {
            const v = evaluate.evalReal(r, em.arena, amount) catch return em.refuse("a delay the engine does not fold");
            const ticks = scale.realDelay(v) catch break :fold;
            return em.print("{d}", .{ticks});
        }
        try em.print("try s.realTicks(", .{});
        try expr_real.real(em, amount);
        return em.print(", .{{ .local_per_unit = {d}, .global_per_local = {d} }})", .{ scale.local_per_unit, scale.global_per_local });
    }
    if (t.width > 64) return em.refuse("a delay wider than 64 bits");
    assert(t.width <= 64);
    if (compile.constantExpression(r, amount)) fold: {
        const v = evaluate.eval(r, em.arena, amount, 0) catch return em.refuse("a delay the engine does not fold");
        // `--two-state` computes an unknown constant from its 0-valued leaves.
        if (em.logic == .two and v.hasUnknown()) break :fold;
        const ticks = if (v.hasUnknown()) 0 else (if (v.signed) scale.signedDelay(v.asInt().?) else scale.unsignedDelay(v.values()[0])) catch break :fold;
        return em.print("{d}", .{ticks});
    }
    // `s.ticks` reads the 64-bit word as a time: a narrower signed delay is
    // sign-extended to it first, so a negative one is the §9.7.1 64-bit
    // two's complement `exec.delayOf` takes, not its own width's.
    try em.print("try s.ticks(", .{});
    if (t.signed and t.width < 64) {
        try em.print("L.rs(", .{});
        try expr.value(em, amount, t);
        try em.print(", {d}, 64, true)", .{t.width});
    } else try expr.value(em, amount, t);
    try em.print(", {}, .{{ .local_per_unit = {d}, .global_per_local = {d} }})", .{ t.signed, scale.local_per_unit, scale.global_per_local });
}

/// Writes the entry of a triggered process or node, and returns whether the
/// process being emitted has one: it waits by being listed in
/// `rt.Design.watchers` or `comb`, so arriving here only says so (a
/// triggered process records its suspension stamp, `rt.State.stamp`).
pub fn waitFixed(em: *Emitter) Error!bool {
    switch (em.site.role) {
        .general => return false,
        .triggered => |t| try em.print("            s.waiting[{d}] = s.stamp();\n            return;\n", .{t}),
        .comb => try em.print("            return;\n", .{}),
    }
    assert(em.site.role != .general);
    return true;
}

/// Writes the filing of a wait's terms on suspension `id`. Ordinary terms
/// keep the direct slot path; an event array carries an emitted selector
/// and the full range of element slots.
pub fn eventWatches(em: *Emitter, ts: []const plan.Term) Error!void {
    for (ts) |t| {
        assert(t.count != 0);
        if (t.width != 0) {
            try em.print("            try s.watchBits(id, {d}, {d}, {d}, {d}, .{t});\n", .{ t.slot, em.planes.off[t.slot], t.lo, t.width, t.edge });
            continue;
        }
        if (t.event_select == .none) {
            try em.print("            try s.watch(id, {d}, .{t});\n", .{ t.slot, t.edge });
            continue;
        }
        const index = em.event_selects.items.len;
        try em.event_selects.append(em.arena, .{ .e = t.event_select, .scope = em.r.scope });
        try em.print("            try s.watchSelected(id, {d}, {d}, selectedEvent{d});\n", .{ t.slot, t.count, index });
    }
}

/// Writes `fn eventSelect<i>` of each indexed event term `eventWatches`
/// filed, inside `Code` so its ordinary expressions use `M`. Restores
/// `em.r.scope`.
pub fn eventSelectors(em: *Emitter) Error!void {
    const scope = em.r.scope;
    defer em.r.scope = scope;
    for (em.event_selects.items, 0..) |select, i| {
        assert(select.e != .none);
        em.r.scope = select.scope;
        try em.print("fn eventSelect{d}(s: *S) rt.Error!?u32 {{\n    _ = &s;\n    return ", .{i});
        try expr_select.address(em, select.e, em.label());
        try em.print(";\n}}\n\n", .{});
    }
}

/// Writes `fn selectedEvent<i>`, outside `Code`: a suspension may survive
/// the 4 -> 2 state transition, so its selector uses the phase of the
/// occurrence, not the phase that armed it.
pub fn selectedEvents(em: *Emitter, two_phase: bool) Error!void {
    if (two_phase) assert(em.logic == .auto);
    for (em.event_selects.items, 0..) |_, i| {
        try em.print("fn selectedEvent{d}(s: *S) rt.Error!?u32 {{\n", .{i});
        if (two_phase) try em.print("    if (s.two) return Code(true).eventSelect{d}(s);\n", .{i});
        try em.print("    return Code(false).eventSelect{d}(s);\n}}\n\n", .{i});
    }
}
