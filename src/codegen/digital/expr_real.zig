//! A real-valued AST expression in `Emitter.r.scope` -> Zig text of an
//! `f64` that is what `evaluate.evalReal` computes: the §4.8 operators, a
//! real variable or array element, a function's real result, and the
//! §17.8 conversions and §17.11.2 / VAMS math system functions.
//! Cites: IEEE 1364-2005 §4.8, §4.8.2, §5.1.13, §5.2.2, §17.7.1
//! (`$realtime`), §17.8, §17.11.2; VAMS `$abstime` (§9.18).
//!
//! Contents:
//! - `pub const user_fn: []const u8`
//! - `pub fn real(em: *Emitter, e: Ast.ExprId) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const sim_digital = @import("sim").digital;
const compile = sim_digital.for_emitter.compile;
const evaluate = sim_digital.for_emitter.evaluate;
const Emitter = @import("Emitter.zig");
const Error = Emitter.Error;
const expr = @import("expr.zig");
const expr_select = @import("expr_select.zig");

/// The refusal of a PLI application's system function or task.
pub const user_fn = "a PLI application's system function, which runs only under a VPI host";

/// Writes `evaluate.evalReal(e)`: `e` as a Zig `f64` (§4.8).
pub fn real(em: *Emitter, e: Ast.ExprId) Error!void {
    assert(e != .none);
    const r = em.r;
    const ex = &r.file.exprs;
    const n = compile.typeOf(em.r, e);
    if (!n.real) {
        try em.print("L.toReal(", .{});
        const t = try expr.selfDetermined(em, e);
        return em.print(", {d}, {})", .{ t.width, t.signed });
    }
    if (compile.constantExpression(r, e)) {
        const v = evaluate.evalReal(r, em.arena, e) catch return em.refuse("a constant the engine does not fold");
        return em.print("@as(f64, @bitCast(@as(u64, 0x{x})))", .{@as(u64, @bitCast(v))});
    }
    assert(n.real);
    switch (ex.tag(e)) {
        .ident, .hier_ident => {
            try em.print("L.real(", .{});
            try em.get(try em.slot(e));
            try em.print(")", .{});
        },
        .index => {
            if (!try em.element(e)) return em.refuse("a real select that is not an array element");
            const lb = em.label();
            const base = try em.slot(r.chainBase(e).base);
            try em.print("(if (", .{});
            try expr_select.address(em, e, lb);
            // §5.2.2's invalid reference is x; the real boundary follows
            // §4.8.2's x-to-zero conversion, not a host NaN bit pattern.
            try em.print(") |a{d}| L.real(M.get(s, {d} + a{d} - {d})) else @as(f64, 0))", .{ lb, em.planes.off[base], lb, base });
        },
        .call => {
            try em.print("L.real(", .{});
            try expr.functionValue(em, e);
            try em.print(")", .{});
        },
        .unary => switch (ex.unOp(e)) {
            .minus => {
                try em.print("-(", .{});
                try real(em, ex.lhs(e));
                try em.print(")", .{});
            },
            else => try real(em, ex.lhs(e)), // else: `+`, the only other real-valued unary
        },
        .binary => {
            const op = ex.binOp(e);
            try em.print("{s}", .{if (op == .pow) "std.math.pow(f64, " else "("});
            try real(em, ex.lhs(e));
            try em.print("{s}", .{switch (op) {
                .add => " + ",
                .sub => " - ",
                .mul => " * ",
                .div => " / ",
                else => ", ", // else: `**`, the one other operator infer types real
            }});
            try real(em, ex.rhs(e));
            try em.print(")", .{});
        },
        .ternary => if (expr.calls(em, ex.rhs(e)) or expr.calls(em, ex.ternaryElse(e))) {
            // §5.1.13 evaluates only the chosen arm for a known condition,
            // both for x/z, whose real result is always zero.
            const lb = em.label();
            try em.print("t{d}: {{ const c{d} = ", .{ lb, lb });
            try expr.truth(em, ex.lhs(e));
            try em.print("; break :t{d} if (c{d} == .one) ", .{ lb, lb });
            try real(em, ex.rhs(e));
            try em.print(" else if (c{d} == .zero) ", .{lb});
            try real(em, ex.ternaryElse(e));
            try em.print(" else L.realCond(c{d}, ", .{lb});
            try real(em, ex.rhs(e));
            try em.print(", ", .{});
            try real(em, ex.ternaryElse(e));
            try em.print("); }}", .{});
        } else {
            try em.print("L.realCond(", .{});
            try expr.truth(em, ex.lhs(e));
            try em.print(", ", .{});
            try real(em, ex.rhs(e));
            try em.print(", ", .{});
            try real(em, ex.ternaryElse(e));
            try em.print(")", .{});
        },
        .sys_call => try systemReal(em, e),
        else => return em.refuse("a real expression of this form"), // else: VAMS branch access and analog-only forms stay with the interpreter
    }
}

// ---- private ----

/// A real-valued system function call: time, conversions, then the math
/// functions by their Zig spelling.
fn systemReal(em: *Emitter, e: Ast.ExprId) Error!void {
    const r = em.r;
    const ex = &r.file.exprs;
    assert(ex.tag(e) == .sys_call);
    const args = ex.args(e);
    const f = r.typing.sys_calls[@backingInt(e)].?;
    switch (f) {
        .realtime => {
            const scale = r.timeOf(r.scope).scale;
            return em.print("s.realtime(.{{ .local_per_unit = {d}, .global_per_local = {d} }})", .{ scale.local_per_unit, scale.global_per_local });
        },
        .abstime => return em.print("s.abstime({d})", .{r.time.finest}),
        .itor => {
            if (!compile.typeOf(r, args[0]).real) return real(em, args[0]);
            try em.print("L.itorReal(", .{});
            try real(em, args[0]);
            return em.print(")", .{});
        },
        .bitstoreal => {
            const t = compile.typeOf(em.r, args[0]);
            try em.print("@as(f64, @bitCast(L.word0(", .{});
            try expr.value(em, args[0], .{ .width = @max(t.width, 64), .signed = t.signed });
            return em.print(")))", .{});
        },
        else => {}, // else: the math functions below, or refused there
    }
    const name: []const u8 = switch (f) {
        .ln => "@log",
        .ln1p => "std.math.log1p",
        .expm1 => "std.math.expm1",
        .log10 => "@log10",
        .exp => "@exp",
        .sqrt => "@sqrt",
        .floor => "@floor",
        .ceil => "@ceil",
        .sin => "@sin",
        .cos => "@cos",
        .tan => "@tan",
        .asin => "std.math.asin",
        .acos => "std.math.acos",
        .atan => "std.math.atan",
        .sinh => "std.math.sinh",
        .cosh => "std.math.cosh",
        .tanh => "std.math.tanh",
        .asinh => "std.math.asinh",
        .acosh => "std.math.acosh",
        .atanh => "std.math.atanh",
        .pow => "std.math.pow",
        .atan2 => "std.math.atan2",
        .hypot => "std.math.hypot",
        .user => return em.refuse(user_fn),
        else => return em.refuse("a VAMS real system function"), // else: driver access, which stays with the interpreter
    };
    assert(name.len != 0);
    try em.print("{s}(", .{name});
    if (f == .pow or f == .atan2 or f == .hypot) try em.print("f64, ", .{});
    for (args, 0..) |arg, i| {
        if (i != 0) try em.print(", ", .{});
        try real(em, arg);
    }
    try em.print(")", .{});
}
