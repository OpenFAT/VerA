//! A continuous driver -> the Zig statements of its `.continuous` arm: a
//! plain driver stores its net (`resolution.plainCopy`); any other hands its
//! value to `rt.net`, which delays it (§6.1.3) or resolves the net (§7.9).
//! Also a plain logic gate's value from its terminals, and the §14.2.4.1
//! module path conditions `rt.net` evaluates.
//! Cites: IEEE 1364-2005 §6.1, §6.1.3, §7.1.6, §7.8.5 (gate truth tables),
//! §5.1.10, §7.9, §7.14 (delay3), §12.3.6 (port windows), §14.2.4.1.
//!
//! Contents:
//! - `pub fn continuous(em: *Emitter, pc: u32, i: u32) Error!void`
//! - `pub fn driverValue(em: *Emitter, e: Ast.ExprId, slice: ?Slice, net_slot: u32) Error!void`
//! - `pub fn gateInputs(em: *Emitter, ins: []const Ast.ExprId, lane: ?u32) Error!void`
//! - `pub fn gateLogic(em: *Emitter, kind: Ast.GateKind, n: usize) Error!void`
//! - `pub fn bits(em: *Emitter, ins: []const Ast.ExprId, lane: ?u32) Error!void`
//! - `pub fn pathConds(em: *Emitter) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const sim_digital = @import("sim").digital;
const compile = sim_digital.for_emitter.compile;
const Delay = sim_digital.for_emitter.net.Delay;
const Slice = sim_digital.for_emitter.net.Slice;
const Type = compile.Type;
const Emitter = @import("Emitter.zig");
const Error = Emitter.Error;
const assign = @import("assign.zig");
const expr = @import("expr.zig");
const nets = @import("nets.zig");
const plane_words = @import("plane_words.zig");

/// Writes `.continuous` (`exec`'s arm) of driver `i` at `pc`: its value,
/// then it re-arms on its operands unless it is a settle node.
pub fn continuous(em: *Emitter, pc: u32, i: u32) Error!void {
    const r = em.r;
    assert(i < r.netlist.drivers.len);
    const d = r.netlist.drivers[i];
    const n = r.netlist.nets[d.net];
    r.scope = d.scope;
    const nw = em.slotWidth(n.slot);
    if (nets.plainDriver(r, em.forced.select_forced, i)) {
        if (em.site.role == .comb and em.pure_nodes[em.site.role.comb]) {
            // Only the time-0 queue runs this process (`plan.Role.comb`):
            // one out-of-line store serves every node of its width.
            if (em.watched[n.slot])
                try em.print("            try M.putCold(s, {f}, {d}, {d}, ", .{ assign.fmtReach(em.reach[n.slot]), n.slot, em.planes.off[n.slot] })
            else
                try em.print("            try M.setCold(s, {d}, ", .{em.planes.off[n.slot]});
            try em.print("val{d}(s.view()), {f});\n            return;\n", .{ em.site.role.comb, plane_words.full(nw) });
            return;
        }
        if (d.source == .gate) try gateInputs(em, d.source.gate.ins, d.source.gate.lane);
        try em.print("            ", .{});
        try assign.store(em, n.slot, .blocking);
        switch (d.source) {
            .expr => |x| try driverValue(em, x.e, x.slice, n.slot),
            .gate => |g| try gateLogic(em, g.kind, g.ins.len),
            .bridge, .udp, .mos, .pull => unreachable, // `plainDriver` admits these two
        }
        try em.print(", {f});\n", .{plane_words.full(nw)});
    } else {
        const k = em.rt.driverRow(i).?;
        // `--two-state` keeps a delay or a logic gate: neither gives an x or
        // z meaning. Strength, several drivers, three states do.
        if (em.caresX()) try keepsX(em, i);
        switch (d.source) {
            .expr => |x| {
                try em.print("            const p = L.planesOf(", .{});
                try driverValue(em, x.e, x.slice, n.slot);
                try em.print(");\n            try s.drive({d}, &p, false);\n", .{k});
            },
            .gate => |g| {
                try bits(em, g.ins, g.lane);
                try em.print("            try s.gate({d}, .{t}, &b);\n", .{ k, g.kind });
            },
            .udp => |u| {
                try bits(em, u.ins, u.lane);
                try em.print("            try s.udp({d}, &b);\n", .{k});
            },
            .mos => |m| {
                if (nw != 1) return em.refuse("a MOS switch driving a vector");
                try bits(em, &.{ m.data, m.gate }, null);
                try em.print("            try s.mos({d}, b[0], b[1]);\n", .{k});
            },
            .bridge => try em.print("            try s.bridge({d});\n", .{k}),
            .pull => try em.print("            try s.pull({d});\n", .{k}),
        }
    }
    // A node is run by its settle event, not re-queued by its operands.
    if (em.site.role != .comb) try em.print("            s.armed[{d}] = true;\n", .{pc});
    try em.print("            return;\n", .{});
}

/// Writes a continuous assignment's value in its net's type; with `slice`,
/// the window of a §12.3.6 concatenated port it asserts.
pub fn driverValue(em: *Emitter, e: Ast.ExprId, slice: ?Slice, net_slot: u32) Error!void {
    assert(e != .none);
    if (slice) |sl| {
        const t = compile.typeOf(em.r, e);
        const ctx: Type = .{ .width = @max(t.width, sl.total), .signed = t.signed };
        try em.print("L.part(", .{});
        try expr.value(em, e, ctx);
        return em.print(", {d}, {d}, {d})", .{ sl.lo, em.slotWidth(net_slot), ctx.width });
    }
    assert(slice == null);
    try expr.assigned(em, e, em.r.slotType(net_slot));
}

/// Writes `const w<j>`: bit `lane` (0 without one) of each terminal in
/// `ins`, as a one-bit value.
pub fn gateInputs(em: *Emitter, ins: []const Ast.ExprId, lane: ?u32) Error!void {
    assert(ins.len != 0);
    for (ins, 0..) |in, j| {
        const nt = compile.typeOf(em.r, in);
        try em.print("            const w{d} = ", .{j});
        // `selfDetermined` reads a real as a 64-bit integer.
        if (nt.real or nt.width > 1) try em.print("L.part(", .{});
        const t = try expr.selfDetermined(em, in);
        if (t.width > 1) try em.print(", {d}, 1, {d})", .{ lane orelse 0, t.width });
        try em.print(";\n", .{});
    }
}

/// Writes a plain logic gate's output from `gateInputs`' `n` inputs:
/// §7.8.5's tables for these eight are the §5.1.10 bitwise operators folded
/// from their identity, which read z as x as the tables do.
pub fn gateLogic(em: *Emitter, kind: Ast.GateKind, n: usize) Error!void {
    assert(n != 0);
    const op, const invert = switch (kind) {
        .g_and, .g_buf => .{ "and", false },
        .g_nand => .{ "and", true },
        .g_or => .{ "or", false },
        .g_nor => .{ "or", true },
        .g_xor => .{ "xor", false },
        .g_xnor, .g_not => .{ "xor", true },
        .g_bufif0, .g_bufif1, .g_notif0, .g_notif1 => unreachable, // `plainDriver` admits none
    };
    if (invert) try em.print("L.not(", .{});
    for (0..n) |_| try em.print("L.bitwise(.@\"{s}\", ", .{op});
    try em.print("L.k({d}, 0)", .{@intFromBool(std.mem.eql(u8, op, "and"))});
    for (0..n) |j| try em.print(", w{d}, 1)", .{j});
    if (invert) try em.print(", 1)", .{});
}

/// Writes `const b`: bit `lane` (0 without one) of each terminal in `ins`,
/// as `resolution.gateValue` reads it.
pub fn bits(em: *Emitter, ins: []const Ast.ExprId, lane: ?u32) Error!void {
    assert(ins.len != 0);
    for (ins, 0..) |in, j| {
        try em.print("            const in{d} = ", .{j});
        const t = try expr.selfDetermined(em, in);
        try em.print(";\n", .{});
        if (t.width > 1) try em.print("            const bit{d} = L.low(L.part(in{d}, {d}, 1, {d}));\n", .{ j, j, lane orelse 0, t.width }) else try em.print("            const bit{d} = L.low(in{d});\n", .{ j, j });
    }
    try em.print("            const b = [_]L.Bit{{", .{});
    for (0..ins.len) |j| try em.print(" bit{d},", .{j});
    try em.print(" }};\n", .{});
}

/// Writes IEEE 1364-2005 §14.2.4.1 each conditional module path of the `rt`
/// nets, in `design_table`'s order, as `fn pathCond<i>`: "If the
/// conditional expression evaluates to x or z, it shall be treated as true.
/// If [it] evaluates to multiple bits, the least significant bit shall
/// represent the result." Restores `em.r.scope`.
pub fn pathConds(em: *Emitter) Error!void {
    const r = em.r;
    const scope = r.scope;
    defer r.scope = scope;
    var i: u32 = 0;
    for (em.rt.nets) |k| for (r.netCold(r.netlist.nets[k]).paths) |p| if (p.cond != .none) {
        r.scope = p.scope;
        try em.print("pub fn pathCond{d}(s: *S) rt.Error!bool {{\n    _ = &s;\n    return L.low(", .{i});
        _ = try expr.selfDetermined(em, p.cond);
        try em.print(") != .zero;\n}}\n\n", .{});
        i += 1;
    };
    assert(i <= std.math.maxInt(u32));
}

// ---- private ----

/// `xMeaning` of driver `i` when x or z decides its net's value: §7.9
/// resolution, several drivers, a three-state or a §7.14 delay chosen by
/// the value transitioned to.
fn keepsX(em: *Emitter, i: u32) Error!void {
    const r = em.r;
    assert(em.caresX());
    const d = r.netlist.drivers[i];
    const n = r.netlist.nets[d.net];
    const two_ok = switch (n.kind) {
        .wire, .tri, .uwire => r.netDrivers(d.net).len == 1 and !n.strength_read and r.netCold(n).trans.len == 0 and d.s0 == .strong and d.s1 == .strong,
        .tri0, .tri1, .trireg, .wand, .wor, .triand, .trior, .supply0, .supply1, .wreal => false,
    } and switch (d.source) {
        .expr => true,
        .gate => |g| nets.logicGate(g.kind),
        .udp, .mos, .bridge, .pull => false,
    };
    if (!two_ok) try em.xMeaning("a §7.9 net resolved from strengths or several drivers, or a three-state, switch, UDP, port-window or pull driver", null);
    // §7.14 picks the delay by the value transitioned to: with three
    // different ones, an x or z decides when a value lands.
    for ([_]Delay{ d.delay, r.netCold(n).delay }) |dl| if (dl.present and (dl.rise != dl.fall or dl.fall != dl.off))
        try em.xMeaning("a `delay3` whose rise, fall and turn-off differ, chosen by an x or z", null);
}
