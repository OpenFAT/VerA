//! A §10 task or function call -> the Zig statements of one activation: the
//! inputs read in the caller, an automatic frame set aside and made fresh,
//! the body, the outputs copied back unless a `disable` ended it; a timed
//! task's activation is a process of its own (`rt.State.callTimed`).
//! Cites: IEEE 1364-2005 §4.8 (a real starts 0), §10.2.1, §10.2.2
//! (copy-in, copy-out), §10.2.3 (automatic storage starts x; timed tasks),
//! §10.3 (disable), §10.4 (function results).
//!
//! Contents:
//! - `pub fn call(em: *Emitter, idx: u32, args: []const Ast.ExprId, lb: u32) Error!void`
//! - `pub fn callTimed(em: *Emitter, pc: u32, idx: u32, args: []const Ast.ExprId) Error!void`
//! - `pub fn returnCell(em: *Emitter, at: u32) Error!u32`
//! - `pub fn fillTable(em: *Emitter, name: []const u8, idx: u32, f: Frame) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const sim_digital = @import("sim").digital;
const Frame = sim_digital.Frame;
const Emitter = @import("Emitter.zig");
const Error = Emitter.Error;
const assign = @import("assign.zig");
const expr = @import("expr.zig");
const layout = @import("layout.zig");
const plane_words = @import("plane_words.zig");

/// Writes `exec.callSync` of subroutine `idx` with `args`, as statements in
/// the caller's scope (§10.2.2, §10.2.3, §10.3), and queues its body for
/// emission once. A function's value is left in `r<lb>`.
pub fn call(em: *Emitter, idx: u32, args: []const Ast.ExprId, lb: u32) Error!void {
    const r = em.r;
    assert(idx < em.sub_seen.bit_length);
    const sub = r.routines.rows.items[idx];
    assert(args.len == sub.decl.ports.len);
    const f = sub.frame;
    if (!em.sub_seen.isSet(idx)) {
        em.sub_seen.set(idx);
        try em.subs_todo.append(em.arena, idx);
    }
    for (sub.decl.ports, args, f.ports, 0..) |p, arg, at, i| if (p.direction != .output) {
        try em.print("            const i{d}_{d} = ", .{ lb, i });
        try expr.assigned(em, arg, r.slotType(at));
        try em.print(";\n", .{});
    };
    const lo = em.planes.slotOff(f.first);
    try em.print("            try s.enter({d}, {d}, ", .{ idx, lo });
    if (sub.decl.automatic) try em.print("&fill{d});\n", .{idx}) else try em.print("&.{{}});\n", .{});
    for (sub.decl.ports, f.ports, 0..) |p, at, i| if (p.direction != .output)
        try em.print("            try M.set(s, {d}, i{d}_{d}, {f});\n", .{ em.planes.off[at], lb, i, plane_words.full(em.slotWidth(at)) });
    try em.print("            try proc{d}(s, {d});\n", .{ sub.entry, sub.entry });
    if (sub.decl.is_function) {
        try em.print("            const r{d} = ", .{lb});
        try em.get(f.result);
        try em.print(";\n", .{});
    }
    var outs = false;
    for (sub.decl.ports) |p| outs = outs or p.direction != .input;
    if (outs) {
        // `leave` restores recursive caller locals and can finish a disable;
        // preserve both the output values and whether they may be copied.
        try em.print("            const copy{d} = s.unwind == null;\n", .{lb});
        for (sub.decl.ports, f.ports, 0..) |p, at, i| if (p.direction != .input) {
            try em.print("            const o{d}_{d} = ", .{ lb, i });
            try em.get(at);
            try em.print(";\n", .{});
        };
    }
    try em.print("            s.leave({d}, {d}, {d});\n", .{ idx, lo, if (sub.decl.automatic) em.planes.slotOff(f.first + f.count) - lo else 0 });
    if (outs) {
        try em.print("            if (copy{d}) {{\n", .{lb});
        for (sub.decl.ports, args, f.ports, 0..) |p, arg, at, i| if (p.direction != .input)
            try assign.assignment(em, arg, .{ .captured = .{ .call = lb, .port = i, .ty = r.slotType(at) } }, .blocking);
        try em.print("            }}\n", .{});
    }
}

/// Writes `exec.callTimed` at `pc` and, when `s.returned`, the end of
/// `exec.returnTimed`: the inputs read in the caller, a new activation
/// (`rt.State.callTimed`) with the formals set, and a jump to the body; on
/// return, the outputs copied to the actuals in the caller's restored
/// activation (§10.2.2, §10.2.3).
pub fn callTimed(em: *Emitter, pc: u32, idx: u32, args: []const Ast.ExprId) Error!void {
    const r = em.r;
    const sub = r.routines.rows.items[idx];
    assert(args.len == sub.decl.ports.len);
    const f = sub.body.?.frame;
    try em.print("            if (s.returned) {{\n                s.returned = false;\n", .{});
    for (sub.decl.ports, args, f.ports) |p, arg, at| if (p.direction != .input)
        try assign.assignment(em, arg, .{ .stored = .{ .off = try returnCell(em, at), .ty = r.slotType(at) } }, .blocking);
    try em.print("                continue :sw {d};\n            }}\n", .{pc + 1});
    const lb = em.label();
    for (sub.decl.ports, args, f.ports, 0..) |p, arg, at, i| if (p.direction != .output) {
        try em.print("            const i{d}_{d} = ", .{ lb, i });
        try expr.assigned(em, arg, r.slotType(at));
        try em.print(";\n", .{});
    };
    const lo = em.planes.slotOff(f.first);
    try em.print("            try s.callTimed({d}, {d}, {d}, ", .{ idx, pc, lo });
    if (sub.decl.automatic) try em.print("&tfill{d});\n", .{idx}) else try em.print("&.{{}});\n", .{});
    for (sub.decl.ports, f.ports, 0..) |p, at, i| if (p.direction != .output)
        try em.print("            try M.set(s, {d}, i{d}_{d}, {f});\n", .{ em.planes.off[at], lb, i, plane_words.full(em.slotWidth(at)) });
    try em.print("            s.jump = {d};\n            return;\n", .{sub.body.?.entry});
}

/// Returns the cell a timed task's output formal `at` waits in between its
/// activation's return and its call site's copy-out.
pub fn returnCell(em: *Emitter, at: u32) Error!u32 {
    assert(at < em.r.values.len);
    const cell = try layout.cellOf(&em.planes, em.arena, layout.returnCell(at), em.slotWidth(at));
    assert(cell >= em.planes.slot_words);
    return cell;
}

/// Writes `const <name><idx>`: automatic frame `f`'s fresh value, plane word
/// by word. §§10.2.3, 4.8: integral automatic storage starts x, real zero.
pub fn fillTable(em: *Emitter, name: []const u8, idx: u32, f: Frame) Error!void {
    const r = em.r;
    assert(name.len != 0);
    assert(f.first + f.count <= r.values.len);
    try em.print("const {s}{d} = [_]u64{{", .{ name, idx });
    for (r.values[f.first..][0..f.count], f.first..) |v, at| for (0..plane_words.words(v.width)) |j| {
        const top = if (j + 1 == plane_words.words(v.width)) plane_words.maskOf(v.width - 64 * @as(u32, @intCast(j))) else std.math.maxInt(u64);
        try em.print(" 0x{x},", .{if (em.logic == .two or r.decls.reals.contains(@intCast(at))) 0 else top});
    };
    try em.print(" }};\n\n", .{});
}
