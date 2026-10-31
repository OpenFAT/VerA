const Lower = @import("Lower.zig");
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const naming = @import("ir").names;
const lower_expr = @import("expr.zig");
const lower_expr_name = @import("expr_name.zig");
const lower_expr_op = @import("expr_op.zig");
const Oom = Lower.Oom;

/// §7.3.2 a four-state operand as its two planes (IEEE 1364 §5.1.8: z is value
/// 0 / unknown 1, x is 1 / 1): an x/z literal, or a discrete input read through
/// `===`/`!==`/`case` (`Lowered.discrete_xz`). Null for anything two-state.
const Planes = struct { value: Mir.Value, unknown: Mir.Value };

fn fourState(self: *Lower, e: Ast.ExprId) Oom!?Planes {
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .logic_literal => {
            const lit = ex.logicValue(e);
            if (lit.width > 63) return null; // the E0130 the ordinary lowering reports
            const value: i64 = lit.asInt() orelse @bitCast(lit.values()[0]);
            return .{
                .value = try self.mir.addIntConst(self.arena, value),
                .unknown = try self.mir.addIntConst(self.arena, @bitCast(lit.unknowns()[0])),
            };
        },
        .ident => {
            const name = self.file.str(ex.strOf(e));
            if (self.in_d2a_body or !self.out.discrete_xz.contains(name)) return null;
            const xz = self.param_index.get(try naming.xzField(self.arena, name)).?;
            return .{ .value = (try lower_expr_name.lookupName(self, e, name)).v, .unknown = self.param_values.items[xz] };
        },
        else => return null, // else: every other operand is two-state
    }
}

/// §7.3.2 / IEEE 1364 §5.1.8 `a === b` when either side is four-state: both
/// planes compare, and the result is never x. A two-state side has no unknown
/// bits. Null when neither side is four-state (the ordinary `==` path).
pub fn caseEquality(self: *Lower, l: Ast.ExprId, r: Ast.ExprId) Oom!?Mir.Value {
    const pl = try fourState(self, l);
    const pr = try fourState(self, r);
    if (pl == null and pr == null) return null;
    const a = pl orelse Planes{ .value = try twoState(self, l), .unknown = .zero };
    const b = pr orelse Planes{ .value = try twoState(self, r), .unknown = .zero };
    const same_value = try lower_expr_op.cmp(self, .eq, .{ .v = a.value, .ty = .integer }, .{ .v = b.value, .ty = .integer });
    const same_unknown = try lower_expr_op.cmp(self, .eq, .{ .v = a.unknown, .ty = .integer }, .{ .v = b.unknown, .ty = .integer });
    return try self.emit(.logand, &.{ same_value, same_unknown });
}

/// §7.3.2 "the case, casex, and casez statements": one case item against the
/// subject. `case` is `caseEquality`; IEEE 1364 §9.5.1 makes a z bit of
/// either side a don't-care under `casez`, and an x or z bit under `casex`.
/// Null when neither side is four-state: two-state operands have no
/// don't-care bits, so all three are `==`.
pub fn caseMatch(self: *Lower, kind: Ast.CaseKind, l: Ast.ExprId, r: Ast.ExprId) Oom!?Mir.Value {
    if (kind == .normal) return caseEquality(self, l, r);
    const pl = try fourState(self, l);
    const pr = try fourState(self, r);
    if (pl == null and pr == null) return null;
    const a = pl orelse Planes{ .value = try twoState(self, l), .unknown = .zero };
    const b = pr orelse Planes{ .value = try twoState(self, r), .unknown = .zero };
    // A z is value 0 / unknown 1 (`Planes`), so `unknown & ~value` is its bits.
    const dont_care = switch (kind) {
        .casex => try self.emit(.bitor, &.{ a.unknown, b.unknown }),
        .casez => try self.emit(.bitor, &.{
            try self.emit(.bitand, &.{ a.unknown, try self.emit(.bitnot, &.{a.value}) }),
            try self.emit(.bitand, &.{ b.unknown, try self.emit(.bitnot, &.{b.value}) }),
        }),
        .normal => unreachable,
    };
    const diff = try self.emit(.bitor, &.{ try self.emit(.bitxor, &.{ a.value, b.value }), try self.emit(.bitxor, &.{ a.unknown, b.unknown }) });
    const masked = try self.emit(.bitand, &.{ diff, try self.emit(.bitnot, &.{dont_care}) });
    return try lower_expr_op.cmp(self, .eq, .{ .v = masked, .ty = .integer }, .{ .v = .zero, .ty = .integer });
}

/// §4.2.1 Table 4-2: `===` is not an operator on reals (E0369, as on the
/// two-state path).
fn twoState(self: *Lower, e: Ast.ExprId) Oom!Mir.Value {
    const tv = try lower_expr.lowerExpr(self, e);
    if (tv.ty != .real) return self.toInt(tv);
    var d = self.errWith(self.file.exprs.mainTok(e), .E0369);
    d.help("use `==`; for reals prefer `abs(a - b) < tol`", .{});
    try d.emit();
    return .zero;
}
