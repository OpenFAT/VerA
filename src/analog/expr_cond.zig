const std = @import("std");
const Lower = @import("Lower.zig");
const lower_analog_op = @import("analog_op.zig");
const lower_control = @import("control.zig");
const lower_hier_name = @import("hier_name.zig");
const Ast = @import("frontend").Ast;
const constfold = @import("frontend").constfold;
const Mir = @import("ir").Mir;
const naming = @import("ir").names;
const lower_expr = @import("expr.zig");
const Oom = Lower.Oom;
const TypedValue = Lower.TypedValue;
const unify = Lower.unify;

/// §4.2.3 names three short-circuiting operators, "&&, ||, and ?:", and says of
/// all three that "any side effects or runtime errors that would have occurred
/// due to evaluation of the short-circuited operand expression shall not occur";
/// §4.2.12 says the same from the value side, naming only the arm it selects.
/// So the arms are branches, not operands of a `select`: an inlined function
/// that writes an `inout` formal (§4.7.2.4) must not run in the arm that was not
/// chosen, and neither must a division the condition exists to guard.
///
/// The shape is `lowerShortCircuit`'s — one place, one phi at the join. The one
/// difference is the type: `&&` is integer by definition, while §4.2.1 makes a
/// ternary's type the unification of both arms, and neither arm's type is known
/// until it has been lowered. So the then-arm is left unterminated while the
/// else-arm is lowered, and both are finished afterwards, once `ty` is settled
/// and the `.itof` each arm may need can still be emitted before its jump.
/// Nothing between the two reads the then-arm's terminator: the SSA builder
/// walks predecessors, and the else-arm has none of the then-arm's blocks.
pub fn lowerTernary(self: *Lower, e: Ast.ExprId, plan: ?constfold.IntPlan, sized: bool) Oom!TypedValue {
    const ex = &self.file.exprs;
    const cond = ex.lhs(e);
    const c = try self.toBool(try lower_expr.lowerOperand(self, cond, plan, sized, 0));

    // §4.5.15 "Analog operators shall not be used inside conditional (if, case,
    // or ?:) statements unless the conditional expression controlling the
    // statement consists of terms which can not change their value during the
    // course of a simulation." `?:` is in that list because an operator in an
    // arm loses its history on every step the arm is off. The two counters
    // `lowerCondBody` raises for an `if` body are raised here too, so E0514 in
    // `lowerFilter` sees it.
    const static = lower_control.isAnalysisOrConst(self, cond) or try lower_control.isStaticValue(self, c);
    self.cond_depth += 1;
    self.static_cond_depth += @intFromBool(static);
    defer {
        self.cond_depth -= 1;
        self.static_cond_depth -= @intFromBool(static);
    }

    const then_b = try self.mir.addBlock(self.arena);
    const else_b = try self.mir.addBlock(self.arena);
    const join = try self.mir.addBlock(self.arena);
    try self.branchTo(c, then_b, else_b, true);

    const pure = lower_control.isAnalysisOrConst(self, cond);
    self.cur = then_b;
    try lower_hier_name.pushCond(self, .{ .e = cond, .pol = true, .pure = pure });
    const t = try lower_expr.lowerOperand(self, ex.rhs(e), plan, sized, 1);
    lower_hier_name.popCond(self);
    const then_end = self.cur; // an arm may have branched on its own (`&&`, a nested `?:`)

    self.cur = else_b;
    try lower_hier_name.pushCond(self, .{ .e = cond, .pol = false, .pure = pure });
    const f = try lower_expr.lowerOperand(self, ex.ternaryElse(e), plan, sized, 2);
    lower_hier_name.popCond(self);
    const else_end = self.cur;

    const ty = unify(t.ty, f.ty);
    const place = self.builder.newPlace();
    try self.builder.writeVariable(place, else_end, if (ty == .real) try self.toReal(f) else f.v);
    try self.gotoBlock(join);

    self.cur = then_end;
    try self.builder.writeVariable(place, then_end, if (ty == .real) try self.toReal(t) else t.v);
    try self.gotoBlock(join);

    try self.builder.sealBlock(join);
    self.cur = join;
    return .{ .v = try self.builder.readVariable(place, join), .ty = ty };
}

/// §4.5.15 "It is important to ensure that all analog operators are evaluated
/// every iteration of a simulation to ensure that the internal state is
/// maintained." Whether this subtree holds one of the operators that rule protects.
/// `ddx` and `limexp` are the clause's own exceptions (see `isHistoryless`).
///
/// ponytail: syntactic, and it does not look inside a §4.7 analog function
/// body. An operator there is already E0422; if one becomes legal, compute a
/// per-function flag when the function lowers.
fn hasStatefulOp(self: *const Lower, e: Ast.ExprId) bool {
    if (e == .none) return false;
    const ex = &self.file.exprs;
    const tag = ex.tag(e);
    if (tag == .filter_call and !lower_analog_op.isHistoryless(self.file.str(ex.strOf(e)))) return true;
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (hasStatefulOp(self, c)) return true;
    return false;
}

/// §4.2.7 `&&` / `||` with LRM short-circuit evaluation. The rhs gets its own
/// block, so a guard like `(x != 0) && (1/x > k)` never divides by zero.
pub fn lowerShortCircuit(self: *Lower, e: Ast.ExprId, op: Ast.BinaryOp, plan: ?constfold.IntPlan, sized: bool) Oom!TypedValue {
    const ex = &self.file.exprs;
    // §4.5.15's evaluate-every-iteration rule wins over §4.2.7's skip when the
    // rhs holds an analog operator: a skipped step would feed that operator the
    // branch-local zero, and its state would go "out-of-date" as the clause
    // warns. §4.2.3's "any side effects ... shall not occur" is about side
    // effects and runtime errors, and advancing a required operator is neither.
    // §4.5.15's restriction names only `if`, `case` and `?:`, so this spelling
    // is legal and not diagnosed.
    if (hasStatefulOp(self, ex.rhs(e))) {
        const l = try self.toBool(try lower_expr.lowerOperand(self, ex.lhs(e), plan, sized, 0));
        const r = try self.toBool(try lower_expr.lowerOperand(self, ex.rhs(e), plan, sized, 1));
        // `toBool` normalises both to 0/1, so max is `||` and min is `&&`.
        return .{
            .v = try self.emit(if (op == .logical_and) .imin else .imax, &.{ l, r }),
            .ty = .integer,
        };
    }
    const a = try self.toBool(try lower_expr.lowerOperand(self, ex.lhs(e), plan, sized, 0));
    const place = self.builder.newPlace();
    try self.builder.writeVariable(place, self.cur, a);

    const rhs_b = try self.mir.addBlock(self.arena);
    const join = try self.mir.addBlock(self.arena);
    // `a && b` evaluates b only when a is true; `a || b` only when a is false.
    if (op == .logical_and) {
        _ = try self.mir.emitBranch(self.arena, self.cur, a, rhs_b, join);
    } else {
        _ = try self.mir.emitBranch(self.arena, self.cur, a, join, rhs_b);
    }
    try self.builder.addPredecessor(rhs_b, self.cur);
    try self.builder.addPredecessor(join, self.cur);
    try self.builder.sealBlock(rhs_b);

    self.cur = rhs_b;
    const b = try self.toBool(try lower_expr.lowerOperand(self, ex.rhs(e), plan, sized, 1));
    try self.builder.writeVariable(place, self.cur, b);
    try self.gotoBlock(join);

    try self.builder.sealBlock(join);
    self.cur = join;
    return .{ .v = try self.builder.readVariable(place, join), .ty = .integer };
}

test "lowerShortCircuit: §4.2.7 skips the rhs, unless §4.5.15 must evaluate its operator" {
    const Case = struct { expr: []const u8, imin: bool };
    const cases = [_]Case{
        .{ .expr = "(V(p, n) > 0) && (V(p, n) < 1)", .imin = false },
        .{ .expr = "(V(p, n) > 0) && (ddt(V(p, n)) > 0)", .imin = true },
    };
    for (cases) |c| {
        const src = try std.testing.allocator.print(
            \\module m(p, n);
            \\  inout p, n; electrical p, n;
            \\  integer k;
            \\  analog begin
            \\    k = {s};
            \\    I(p, n) <+ k * V(p, n);
            \\  end
            \\endmodule
        , .{c.expr});
        defer std.testing.allocator.free(src);
        var h: Lower.Harness = undefined;
        try h.init(std.testing.allocator, src);
        defer h.deinit();
        _ = try h.lower() orelse {
            h.dump();
            return error.TestUnexpectedResult;
        };
        const ops = h.mir.insts.items(.op);
        // The skipping form is a branch around the rhs; the evaluating form
        // is `imin` over both sides, normalized to 0/1.
        try std.testing.expectEqual(c.imin, std.mem.countScalar(Mir.Opcode, ops, .imin) != 0);
        if (!c.imin) try std.testing.expect(std.mem.countScalar(Mir.Opcode, ops, .branch) != 0);
    }
}
