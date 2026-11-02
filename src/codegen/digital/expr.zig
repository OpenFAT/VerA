//! An AST expression in `Emitter.r.scope`, and its context's type -> Zig
//! text over `rt.logic` whose value is what `evaluate.evalContext` computes.
//! The walk is `evalContext`'s arm for arm, so operand sizing and signedness
//! match it, and `evalContext` itself folds every constant. Reals are
//! `expr_real.zig`'s, selects `expr_select.zig`'s, system functions
//! `expr_system.zig`'s. Recursion follows the expression, whose depth the
//! reserved stack of `deep_stack.runGuarded` bounds.
//! Cites: IEEE 1364-2005 §5.5.1 Table 5-22, §5.5.2, §5.5.3, §5.1 operators
//! (§5.1.8, §5.1.13, §5.1.14), §9.4, §9.5, §9.5.1 case labels, §10.4
//! function results.
//!
//! Contents:
//! - `pub fn selfDetermined(em: *Emitter, e: Ast.ExprId) Error!Type`
//! - `pub fn truth(em: *Emitter, e: Ast.ExprId) Error!void`
//! - `pub fn assigned(em: *Emitter, e: Ast.ExprId, target: Type) Error!void`
//! - `pub fn value(em: *Emitter, e: Ast.ExprId, ty: Type) Error!void`
//! - `pub fn int64(em: *Emitter, e: Ast.ExprId) Error!void`
//! - `pub fn int(em: *Emitter, e: Ast.ExprId) Error!void`
//! - `pub fn functionValue(em: *Emitter, e: Ast.ExprId) Error!void`
//! - `pub fn calls(em: *Emitter, e: Ast.ExprId) bool`
//! - `pub fn effects(em: *Emitter, e: Ast.ExprId) bool`
//! - `pub fn caseLabel(em: *Emitter, e: Ast.ExprId, ty: Type, kind: Ast.CaseKind) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Literal = @import("kernels").Integer.Literal;
const sim_digital = @import("sim").digital;
const compile = sim_digital.for_emitter.compile;
const evaluate = sim_digital.for_emitter.evaluate;
const Type = compile.Type;
const Emitter = @import("Emitter.zig");
const Error = Emitter.Error;
const calls_emit = @import("calls.zig");
const expr_real = @import("expr_real.zig");
const expr_select = @import("expr_select.zig");
const expr_system = @import("expr_system.zig");
const plane_words = @import("plane_words.zig");

/// Writes `evaluate.eval(e, 0)`: `e` in its own type, a real as its §4.8.2
/// 64-bit integer. Returns that type.
pub fn selfDetermined(em: *Emitter, e: Ast.ExprId) Error!Type {
    assert(e != .none);
    var t = compile.typeOf(em.r, e);
    if (t.real) t = .{ .width = 64, .signed = true };
    try value(em, e, t);
    assert(!t.real);
    return t;
}

/// Writes `evaluate.truthOf(e)` as a `logic.Bit` (§9.4): a real is true
/// when not 0.
pub fn truth(em: *Emitter, e: Ast.ExprId) Error!void {
    assert(e != .none);
    if (compile.typeOf(em.r, e).real) {
        try em.print("L.realTruth(", .{});
        try expr_real.real(em, e);
        return em.print(")", .{});
    }
    try em.print("L.truth(", .{});
    _ = try selfDetermined(em, e);
    try em.print(")", .{});
}

/// Writes `evaluate.evalFor(e, target)` of an integral target: `e` in the
/// context the assignment gives it, truncated to the target (§5.5.3).
pub fn assigned(em: *Emitter, e: Ast.ExprId, target: Type) Error!void {
    assert(e != .none);
    if (target.real) return value(em, e, target);
    const n = compile.typeOf(em.r, e);
    const ctx: Type = .{ .width = @max(n.width, target.width), .signed = n.signed };
    assert(ctx.width >= target.width);
    try em.print("L.rs(", .{});
    try value(em, e, ctx);
    try em.print(", {d}, {d}, false)", .{ ctx.width, target.width });
}

/// Writes `evaluate.evalContext(e, ty)`.
pub fn value(em: *Emitter, e: Ast.ExprId, ty: Type) Error!void {
    assert(e != .none);
    const r = em.r;
    const ex = &r.file.exprs;
    const w = ty.width;
    const sg = ty.signed;
    if (compile.constantExpression(r, e)) fold: {
        if (em.caresX()) try everyCaseEq(em, e);
        const v = evaluate.evalContext(r, em.arena, e, ty) catch return em.refuse("a constant the engine does not fold");
        // `--two-state`: a literal's x or z bit is 0; an operator of known
        // operands then computes what 4-state computes wherever that has no
        // x (every operator but `===` is monotone in x, and `===` against
        // an x is refused), so only a constant whose value keeps an x is
        // computed from its 0-valued leaves instead.
        var buf: [3]Ast.ExprId = undefined;
        if (em.logic == .two and v.hasUnknown() and ex.children(e, &buf).len != 0) break :fold;
        if (v.hasUnknown()) em.keepFour("a constant with an x or z bit", ex.mainTok(e));
        return constant(em, v, w, em.logic == .two);
    }
    // §4.8: a real context holds the value's bits; a real operand in an
    // integral one is its §4.8.2 integer.
    if (ty.real) {
        try em.print("L.realBits(", .{});
        try expr_real.real(em, e);
        return em.print(")", .{});
    }
    if (compile.typeOf(em.r, e).real) {
        try em.print("L.ofRealTo(", .{});
        try expr_real.real(em, e);
        return em.print(", {d})", .{w});
    }
    switch (ex.tag(e)) {
        .ident, .hier_ident => {
            const at = try em.slot(e);
            try em.print("L.rs(", .{});
            try em.get(at);
            try em.print(", {d}, {d}, {})", .{ em.slotWidth(at), w, sg });
        },
        .index => try expr_select.index(em, e, ty),
        .unary => switch (ex.unOp(e)) {
            .plus => try value(em, ex.lhs(e), ty),
            .minus, .bit_not => |op| {
                try em.print("L.{s}(", .{if (op == .minus) "neg" else "not"});
                try value(em, ex.lhs(e), ty);
                try em.print(", {d})", .{w});
            },
            .logical_not => {
                try em.print("L.ctx(L.invert(", .{});
                try truth(em, ex.lhs(e));
                try em.print("), {d}, {})", .{ w, sg });
            },
            .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => |op| {
                try em.print("L.ctx(L.reduce(.{s}, ", .{switch (op) {
                    .reduce_and => "@\"and\"",
                    .reduce_nand => "nand",
                    .reduce_or => "@\"or\"",
                    .reduce_nor => "nor",
                    .reduce_xor => "xor",
                    else => "xnor", // else: `~^`, the sixth reduction
                }});
                const t = try selfDetermined(em, ex.lhs(e));
                try em.print(", {d}), {d}, {})", .{ t.width, w, sg });
            },
        },
        .binary => try binary(em, e, ty),
        // §5.1.13: both arms are read; `cond` keeps the one the truth picks,
        // or merges them under an x or z condition.
        .ternary => if (calls(em, ex.rhs(e)) or calls(em, ex.ternaryElse(e))) {
            // A call has effects: a known condition runs one arm.
            const lb = em.label();
            try em.print("t{d}: {{ const c{d} = ", .{ lb, lb });
            try truth(em, ex.lhs(e));
            try em.print("; break :t{d} if (c{d} == .one) ", .{ lb, lb });
            try value(em, ex.rhs(e), ty);
            try em.print(" else if (c{d} == .zero) ", .{lb});
            try value(em, ex.ternaryElse(e), ty);
            try em.print(" else L.cond(c{d}, ", .{lb});
            try value(em, ex.rhs(e), ty);
            try em.print(", ", .{});
            try value(em, ex.ternaryElse(e), ty);
            try em.print("); }}", .{});
        } else {
            try em.print("L.cond(", .{});
            try truth(em, ex.lhs(e));
            try em.print(", ", .{});
            try value(em, ex.rhs(e), ty);
            try em.print(", ", .{});
            try value(em, ex.ternaryElse(e), ty);
            try em.print(")", .{});
        },
        .sys_call => try expr_system.value(em, e, ty),
        .concat => {
            // §5.1.14: self-determined operands, leftmost most significant;
            // a zero replication contributes no bits.
            var parts: std.ArrayList(Ast.ExprId) = try .initCapacity(em.arena, ex.args(e).len);
            for (ex.args(e)) |arg| if (compile.typeOf(r, arg).width != 0) parts.appendAssumeCapacity(arg);
            const n = compile.typeOf(em.r, e);
            try em.print("L.rs(", .{});
            for (parts.items[1..]) |_| try em.print("L.join(", .{});
            var acc = (try selfDetermined(em, parts.items[0])).width;
            for (parts.items[1..]) |arg| {
                try em.print(", {d}, ", .{acc});
                const t = try selfDetermined(em, arg);
                try em.print(", {d})", .{t.width});
                acc += t.width;
            }
            try em.print(", {d}, {d}, {})", .{ n.width, w, sg });
        },
        .multi_concat => {
            const n = compile.typeOf(em.r, e);
            const count = r.typing.replications.get(.{ .spec = r.specOf(r.scope), .e = e }).?;
            try em.print("L.rs(L.rep(", .{});
            const t = try selfDetermined(em, ex.rhs(e));
            try em.print(", {d}, {d}), {d}, {d}, {})", .{ t.width, count, n.width, w, sg });
        },
        // §10.4 a function call: one synchronous activation (`exec.callSync`).
        .call => {
            const n = compile.typeOf(em.r, e);
            try em.print("L.rs(", .{});
            try functionValue(em, e);
            try em.print(", {d}, {d}, {})", .{ n.width, w, sg });
        },
        else => return em.refuse("this expression form"), // else: every other form infer admits is a constant (folded above) or real (`real`)
    }
}

/// Writes `evaluate.eval(e, 0).asInt()` as a Zig `?i64`.
pub fn int64(em: *Emitter, e: Ast.ExprId) Error!void {
    assert(e != .none);
    try em.print("L.asInt(", .{});
    const t = try selfDetermined(em, e);
    assert(!t.real);
    try em.print(", {d}, {})", .{ t.width, t.signed });
}

/// Writes `evaluate.eval(e, 0).asInt() orelse 0` as a Zig `i64`.
pub fn int(em: *Emitter, e: Ast.ExprId) Error!void {
    assert(e != .none);
    try em.print("(L.asInt(", .{});
    const t = try selfDetermined(em, e);
    assert(!t.real);
    try em.print(", {d}, {}) orelse 0)", .{ t.width, t.signed });
}

/// Writes §10.4 call `e`'s result, captured before restoring the caller's
/// automatic frame, in the result variable's representation (real bits or
/// integer).
pub fn functionValue(em: *Emitter, e: Ast.ExprId) Error!void {
    const r = em.r;
    assert(r.file.exprs.tag(e) == .call);
    const idx = r.routines.base.get(r.instanceOf(r.scope)).? + r.routines.calls.get(e).?;
    assert(idx < r.routines.rows.items.len);
    const lb = em.label();
    try em.print("c{d}: {{\n", .{lb});
    try calls_emit.call(em, idx, r.file.exprs.args(e), lb);
    try em.print("            break :c{d} r{d};\n            }}", .{ lb, lb });
}

/// Returns whether `e` calls a function, or a system function with an effect.
pub fn calls(em: *Emitter, e: Ast.ExprId) bool {
    assert(e != .none);
    const ex = &em.r.file.exprs;
    if (ex.tag(e) == .call) return true;
    // This node only: the walk below visits every child, as `effects` would
    // again at every level.
    if (ex.tag(e) == .sys_call) if (em.r.typing.sys_calls[@backingInt(e)]) |f| if (f.effects()) return true;
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (c != .none and calls(em, c)) return true;
    return false;
}

/// Returns whether `e` or an operand of it calls a system function with an
/// effect (`SysFn.effects`: file I/O, a seeded draw, a PLI function). A user
/// function call alone is not one; `calls` covers those.
pub fn effects(em: *Emitter, e: Ast.ExprId) bool {
    assert(e != .none);
    const ex = &em.r.file.exprs;
    if (ex.tag(e) == .sys_call) if (em.r.typing.sys_calls[@backingInt(e)]) |f| if (f.effects()) return true;
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (c != .none and effects(em, c)) return true;
    return false;
}

/// Writes a `case` label in the scrutinee's type (§9.5). Under
/// `--two-state` a casez/casex label keeps its z (and x) bits, which are
/// wildcards there (§9.5.1), and a `case` label with one is refused: it
/// matches only an x or z, which a two-state run never holds.
pub fn caseLabel(em: *Emitter, e: Ast.ExprId, ty: Type, kind: Ast.CaseKind) Error!void {
    assert(e != .none);
    if (!em.caresX() or !compile.constantExpression(em.r, e)) return value(em, e, ty);
    if (em.logic == .auto) {
        // A casez/casex label's z (and x) bits are wildcards (§9.5.1),
        // which keep nothing 4-state.
        const kept = em.four;
        try value(em, e, ty);
        if (kind != .normal) em.four = kept;
        return;
    }
    assert(em.logic == .two);
    try em.fits(ty);
    const v = evaluate.evalContext(em.r, em.arena, e, ty) catch return em.refuse("a constant the engine does not fold");
    if (kind == .normal and v.hasUnknown()) return em.refuse("a `case` label with an x or z bit, which only an x or z matches");
    return constant(em, v, ty.width, false);
}

// ---- private ----

/// A §5.1 binary operator in context `ty` (Table 5-22's operand sizing).
fn binary(em: *Emitter, e: Ast.ExprId, ty: Type) Error!void {
    const r = em.r;
    const ex = &r.file.exprs;
    assert(ex.tag(e) == .binary);
    const w = ty.width;
    const sg = ty.signed;
    const op = ex.binOp(e);
    switch (op) {
        .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge => {
            if (em.caresX()) try twoStateMeaning(em, e);
            const ot = compile.common(compile.typeOf(r, ex.lhs(e)), compile.typeOf(r, ex.rhs(e)));
            if (ot.real) {
                try em.print("L.ctx(if (", .{});
                try expr_real.real(em, ex.lhs(e));
                try em.print(" {s} ", .{switch (op) {
                    .eq => "==",
                    .neq => "!=",
                    .lt => "<",
                    .le => "<=",
                    .gt => ">",
                    .ge => ">=",
                    else => return em.refuse("`===` on a real"), // else: infer refuses `===` on a real
                }});
                try expr_real.real(em, ex.rhs(e));
                return em.print(") .one else .zero, {d}, {})", .{ w, sg });
            }
            const eq = op == .eq or op == .neq or op == .case_eq or op == .case_neq;
            try em.print("L.ctx(L.{s}(.{s}, ", .{ if (eq) "eq" else "rel", @tagName(op) });
            try value(em, ex.lhs(e), ot);
            try em.print(", ", .{});
            try value(em, ex.rhs(e), ot);
            if (eq) try em.print(")", .{}) else try em.print(", {d}, {})", .{ ot.width, ot.signed });
            try em.print(", {d}, {})", .{ w, sg });
        },
        // Both truths are read: with no side effect in either operand the
        // short circuit is not observable, and `logical` of a deciding left
        // side is what the short circuit returns.
        .logical_and, .logical_or => if (calls(em, ex.rhs(e))) {
            // A call has effects: the right side runs only when the left
            // does not decide (`evaluate.evalContext`).
            const lb = em.label();
            try em.print("L.ctx(sc{d}: {{ const l{d} = ", .{ lb, lb });
            try truth(em, ex.lhs(e));
            try em.print("; if (l{d} == .{s}) break :sc{d} l{d}; break :sc{d} L.logical(.{s}, l{d}, ", .{
                lb, if (op == .logical_and) "zero" else "one", lb, lb, lb, if (op == .logical_and) "@\"and\"" else "@\"or\"", lb,
            });
            try truth(em, ex.rhs(e));
            try em.print("); }}, {d}, {})", .{ w, sg });
        } else {
            try em.print("L.ctx(L.logical(.{s}, ", .{if (op == .logical_and) "@\"and\"" else "@\"or\""});
            try truth(em, ex.lhs(e));
            try em.print(", ", .{});
            try truth(em, ex.rhs(e));
            try em.print("), {d}, {})", .{ w, sg });
        },
        .shl, .shr, .ashl, .ashr => {
            try em.print("L.shift(.{s}, ", .{switch (op) {
                .shl => "left",
                .shr => "right",
                .ashl => "arithmetic_left",
                else => "arithmetic_right", // else: `>>>`, the fourth shift
            }});
            try value(em, ex.lhs(e), ty);
            try em.print(", {d}, {}, ", .{ w, sg });
            _ = try selfDetermined(em, ex.rhs(e));
            try em.print(")", .{});
        },
        .pow => {
            try em.print("L.pow(", .{});
            try value(em, ex.lhs(e), ty);
            try em.print(", {d}, {}, ", .{ w, sg });
            const t = try selfDetermined(em, ex.rhs(e));
            try em.print(", {d}, {})", .{ t.width, t.signed });
        },
        .add, .sub, .mul, .div, .mod => {
            try em.print("L.arith(.{s}, ", .{@tagName(op)});
            try value(em, ex.lhs(e), ty);
            try em.print(", ", .{});
            try value(em, ex.rhs(e), ty);
            try em.print(", {d}, {})", .{ w, sg });
        },
        .bit_and, .bit_or, .bit_xor, .bit_xnor => {
            try em.print("L.bitwise(.{s}, ", .{switch (op) {
                .bit_and => "@\"and\"",
                .bit_or => "@\"or\"",
                .bit_xor => "xor",
                else => "xnor", // else: `~^`, the fourth bitwise operator
            }});
            try value(em, ex.lhs(e), ty);
            try em.print(", ", .{});
            try value(em, ex.rhs(e), ty);
            try em.print(", {d})", .{w});
        },
    }
}

/// A folded constant; `known` makes its x and z bits 0 (`--two-state`).
fn constant(em: *Emitter, v: Literal, w: u32, known: bool) Error!void {
    const n = plane_words.words(w);
    assert(v.values().len >= n);
    const vs = v.values()[0..n];
    const xs = v.unknowns()[0..n];
    if (w <= 64) return em.print("L.k(0x{x}, 0x{x})", .{ if (known) vs[0] & ~xs[0] else vs[0], if (known) 0 else xs[0] });
    try em.print("L.Wide({d}){{ .v = .{{", .{n});
    for (vs, xs) |x, u| try em.print(" 0x{x},", .{if (known) x & ~u else x});
    try em.print(" }}, .x = .{{", .{});
    for (xs) |x| try em.print(" 0x{x},", .{if (known) 0 else x});
    return em.print(" }} }}", .{});
}

/// `twoStateMeaning` of `e` and of every operand under it.
fn everyCaseEq(em: *Emitter, e: Ast.ExprId) Error!void {
    assert(e != .none);
    var buf: [3]Ast.ExprId = undefined;
    for (em.r.file.exprs.children(e, &buf)) |c| if (c != .none) try everyCaseEq(em, c);
    try twoStateMeaning(em, e);
}

/// `xMeaning` of a `===` or `!==` with an operand that holds x or z: it asks
/// whether a value is unknown (§5.1.8), which a two-state run cannot answer.
fn twoStateMeaning(em: *Emitter, e: Ast.ExprId) Error!void {
    const r = em.r;
    const ex = &r.file.exprs;
    assert(e != .none);
    if (ex.tag(e) != .binary) return;
    const op = ex.binOp(e);
    if (op != .case_eq and op != .case_neq) return;
    for ([_]Ast.ExprId{ ex.lhs(e), ex.rhs(e) }) |side| {
        if (!compile.constantExpression(r, side)) continue;
        const v = evaluate.eval(r, em.arena, side, 0) catch return em.xMeaning("a constant the engine does not fold", ex.mainTok(e));
        if (v.hasUnknown()) return em.xMeaning("`===` or `!==` against an x or z, which asks whether a value is unknown", ex.mainTok(e));
    }
}
