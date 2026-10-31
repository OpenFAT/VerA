//! §4.2 operators: a unary or binary expression in, the opcode its operand
//! types pick (§4.2.1: one real operand makes the operation real) out, or a
//! diagnostic for an operator the analog context does not carry (§4.2.10's
//! reductions, §4.2.11's arithmetic shifts, a string operand §3.3 gives no
//! arithmetic).
//!
//! Cites: A.8.6, §2.6.3, §2.7, §3.2, §3.3 (Table 3-3), §4.2, §4.2.1 (Table
//! 4-2, Table 4-3), §4.2.1.3, §4.2.3, §4.2.4, §4.2.5, §4.2.6, §4.2.7, §4.2.8,
//! §4.2.9, §4.2.10, §4.2.11, §4.3.1, §7.3.2; IEEE 1364-2005 §5.1.8.
//!
//! Contents:
//! - `pub fn lowerUnary(self: *Lower, e: Ast.ExprId, plan: ?constfold.IntPlan, sized: bool) Oom!TypedValue`
//! - `pub fn lowerBinary(self: *Lower, e: Ast.ExprId, plan: ?constfold.IntPlan, sized: bool) Oom!TypedValue`
//! - `pub fn resizeInt(self: *Lower, v: Mir.Value, context: constfold.IntContext) Oom!Mir.Value`
//! - `pub fn cmp(self: *Lower, op: Ast.BinaryOp, a: TypedValue, b: TypedValue) Oom!Mir.Value`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const constfold = @import("frontend").constfold;
const Mir = @import("ir").Mir;
const diag = @import("diag");
const Lower = @import("Lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_sysfunc = @import("sysfunc.zig");
const lower_systask = @import("systask.zig");
const lower_expr = @import("expr.zig");
const lower_expr_case = @import("expr_case.zig");
const lower_expr_cond = @import("expr_cond.zig");
const lower_display = @import("display.zig");
const lower_sysfunc_args = @import("sysfunc_args.zig");
const Oom = Lower.Oom;
const TypedValue = Lower.TypedValue;
const poison = Lower.poison;
const unify = Lower.unify;

/// A.8.6 unary operators. §4.2.3 (+/-), §4.2.7 (!), §4.2.9 (~).
pub fn lowerUnary(self: *Lower, e: Ast.ExprId, plan: ?constfold.IntPlan, sized: bool) Oom!TypedValue {
    assert(e == .none or self.exprValid(e));
    assert(self.blockValid(self.cur));
    const ex = &self.file.exprs;
    var a = try lower_expr.lowerOperand(self, ex.lhs(e), plan, sized, 0);
    switch (ex.unOp(e)) {
        .plus, .minus => if (a.ty == .string) {
            // §2.7: a literal is a number; §3.3 Table 3-3: a string-typed operand is not.
            if (ex.tag(ex.lhs(e)) != .str_literal) {
                try self.err(ex.mainTok(e), .E0321, "a string variable or parameter is not a number; §3.3 Table 3-3 gives it no arithmetic", .{});
                return poison;
            }
            a = try self.strNum(a);
        },
        .logical_not, .bit_not, .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => {},
    }
    switch (ex.unOp(e)) {
        .plus => return a,
        .minus => {
            // §4.2.3. Fold a literal here instead of emitting `ineg(3)`: the
            // §4.2.8 divisor proof (`integerIv`) has no transfer function for
            // `ineg`, so `11 % -3` would fail to prove its divisor non-zero
            // (E0601). A negative literal is a constant however it is spelled.
            switch (self.mir.valueDef(self.mir.resolveAlias(a.v))) {
                // §3.2 through the one constant kernel: -(-2^31) is -2^31.
                .int_const => |x| return .{ .v = try self.mir.addIntConst(self.arena, constfold.unary(.minus, .{ .int = x }).?.int), .ty = a.ty },
                .float_const => |x| return .{ .v = try self.mir.addFloatConst(self.arena, -x), .ty = a.ty },
                .undef, .str_const, .param_ref, .block_param, .inst_result => {},
            }
            return .{
                .v = try self.emit(if (a.ty == .real) .fneg else .ineg, &.{a.v}),
                .ty = a.ty,
            };
        },
        .logical_not => return .{ .v = try self.emit(.lognot, &.{try self.toBool(a)}), .ty = .integer },
        .bit_not => {
            if (a.ty != .integer) {
                try self.err(self.file.exprs.mainTok(e), .E0318, "`~` on a {s}", .{@tagName(a.ty)});
                return poison;
            }
            return .{ .v = try self.emit(.bitnot, &.{a.v}), .ty = .integer };
        },
        // §4.2.10, the whole clause: "The reduction operators can not be used
        // inside the analog block and only have meaning when used in the
        // digital context." There is no carve-out and no analog form.
        //
        // Unconditional: every expression lowering sees is in the analog
        // block (see `isDigitalOnlySysFunc`).
        .reduce_and, .reduce_nand, .reduce_or, .reduce_nor => {
            // §4.2.1 first: a real operand has no bits to fold at all, and
            // E0319 names the operand rather than the context.
            if (a.ty != .integer) {
                try self.err(self.file.exprs.mainTok(e), .E0319, "got a {s}", .{@tagName(a.ty)});
                return poison;
            }
            try self.err(self.file.exprs.mainTok(e), .E0348, "", .{});
            return poison;
        },
        // §4.2.10 xor reduction is a parity, which has no analog equivalent
        // and no MIR opcode.
        .reduce_xor, .reduce_xnor => {
            try self.err(self.file.exprs.mainTok(e), .E0320, "", .{});
            return poison;
        },
    }
}

/// A.8.6 binary operators. LRM Table 4-3 precedence is the parser's job; this
/// only picks the opcode family from the operand types (§4.2.1).
pub fn lowerBinary(self: *Lower, e: Ast.ExprId, plan: ?constfold.IntPlan, sized: bool) Oom!TypedValue {
    assert(e == .none or self.exprValid(e));
    assert(self.blockValid(self.cur));
    const ex = &self.file.exprs;
    const op = ex.binOp(e);
    // §4.2.7 && and || short-circuit: the rhs must not be evaluated when the
    // lhs already decides the result, so this needs real control flow.
    if (op == .logical_and or op == .logical_or) return lower_expr_cond.lowerShortCircuit(self, e, op, plan, sized);

    // §3.3 Table 3-3: "If both operands are string literals, the operator is
    // the same Verilog equality operator as for integer types." Each literal
    // is its packed bytes (§2.6.3), NULs included, and the shorter is
    // zero-extended — which is byte equality once leading NULs are dropped.
    // The literal's LEXICAL bytes, because string storage removes NULs.
    const eq_op = op == .eq or op == .neq or op == .case_eq or op == .case_neq;
    if (eq_op and ex.tag(ex.lhs(e)) == .str_literal and ex.tag(ex.rhs(e)) == .str_literal) {
        const sa = (try lower_sysfunc_args.outputLiteral(self, ex.lhs(e))) orelse self.file.str(ex.strOf(ex.lhs(e)));
        const sb = (try lower_sysfunc_args.outputLiteral(self, ex.rhs(e))) orelse self.file.str(ex.strOf(ex.rhs(e)));
        const same = std.mem.eql(u8, std.mem.trimStart(u8, sa, "\x00"), std.mem.trimStart(u8, sb, "\x00"));
        const want_same = op == .eq or op == .case_eq;
        return .{ .v = if (same == want_same) .one else .zero, .ty = .integer };
    }
    if (op == .case_eq or op == .case_neq) if (try lower_expr_case.caseEquality(self, ex.lhs(e), ex.rhs(e))) |same|
        return .{ .v = if (op == .case_eq) same else try self.emit(.lognot, &.{same}), .ty = .integer };
    var a = try lower_expr.lowerOperand(self, ex.lhs(e), plan, sized, 0);
    var b = try lower_expr.lowerOperand(self, ex.rhs(e), plan, sized, 1);
    // §2.7 makes a string LITERAL an unsigned integer, so a MIXED pair with a
    // literal is arithmetic and not a string operation. Two strings stay
    // strings: Table 3-3's relational row is a string comparison and
    // `{a, " ", b}` is a concatenation, and both would be destroyed by
    // converting either side.
    if ((a.ty == .string) != (b.ty == .string)) {
        // A string-typed operand (variable, parameter, function result) is no
        // number: §3.3 Table 3-3 gives it only ==, !=, the relational operators,
        // concatenation and replication, each against another string or a
        // literal, and "A string cannot be assigned to an integral type". The
        // test is the expression's shape, as `numOperand`'s: a variable
        // assigned a literal carries the literal's constant and is still a string.
        const str_side = if (a.ty == .string) ex.lhs(e) else ex.rhs(e);
        if (ex.tag(str_side) != .str_literal) {
            const other = @tagName(if (a.ty == .string) b.ty else a.ty);
            switch (op) {
                .bit_and, .bit_or, .bit_xor, .bit_xnor, .shl, .shr, .ashl, .ashr => try self.err(ex.mainTok(e), .E0322, "got a string and {s}", .{other}),
                .add, .sub, .mul, .div, .mod, .pow => try self.err(ex.mainTok(e), .E0321, "a string variable or parameter is not a number; §3.3 Table 3-3 gives it no arithmetic", .{}),
                .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge => try self.err(ex.mainTok(e), .E0321, "§3.3 Table 3-3 compares a string only with a string or a string literal; the other operand is {s}", .{other}),
                .logical_and, .logical_or => unreachable, // `lowerShortCircuit` returned for both at the top
            }
            return poison;
        }
        a = try self.strNum(a);
        b = try self.strNum(b);
    }

    switch (op) {
        .add, .sub, .mul, .div, .mod => {
            const ty = unify(a.ty, b.ty);
            if (ty == .string) {
                try self.err(self.file.exprs.mainTok(e), .E0321, "", .{});
                return poison;
            }
            const real = ty == .real;
            const opc: Mir.Opcode = switch (op) {
                .add => if (real) .fadd else .iadd,
                .sub => if (real) .fsub else .isub,
                .mul => if (real) .fmul else .imul,
                .div => if (real) .fdiv else .idiv,
                .mod => if (real) .fmod else .imod,
                else => unreachable, // else: the enclosing prong admits only these five
            };
            const lv = if (real) try self.toReal(a) else a.v;
            const rv = if (real) try self.toReal(b) else b.v;
            const result = try self.emit(opc, &.{ lv, rv });
            if (opc == .imod and self.runtime_error_phase != .none) {
                const divisor = self.mir.valueDef(self.mir.resolveAlias(rv));
                // A literal nonzero divisor cannot fail. All other evaluated
                // remainders stay on the guarded effect chain (§4.2.3), even
                // if their assigned value is dead. The chain's numeric sum is
                // not observable; its dependencies and CFG edges are.
                if (divisor != .int_const or divisor.int_const == 0) {
                    const value = try self.toReal(.{ .v = result, .ty = .integer });
                    if (self.runtime_error_phase == .display) {
                        try lower_display.chainCondDisplay(self, value);
                        return .{ .v = result, .ty = ty };
                    }
                    const place = try self.effectPlace();
                    const previous = try self.builder.readVariable(place, self.cur);
                    try self.builder.writeVariable(place, self.cur, try self.emit(.fadd, &.{ previous, value }));
                }
            }
            return .{ .v = result, .ty = ty };
        },
        // §4.2.1.3: "If either operand is real, the other operand is converted
        // to real" — so two integers stay integer, and `7/(2**k)` divides by
        // an integer. §4.3.1's `pow()` FUNCTION is the real-valued one.
        .pow => return if (a.ty == .integer and b.ty == .integer)
            .{ .v = try self.emit(.ipow, &.{ a.v, b.v }), .ty = .integer }
        else
            .{ .v = try self.emit(.pow, &.{ try self.toReal(a), try self.toReal(b) }), .ty = .real },
        .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge => {
            // §7.3.2 lists `===` and `!==` among the features the analog
            // context supports, and §4.2.6 defers their meaning to IEEE 1364
            // §5.1.8: x and z compare as bits. Every operand that reaches here
            // is two-state (an x/z literal is E0130, a four-state net read is
            // E0315), and on two-state bits the case operators ARE `==` and
            // `!=`. §4.2.1 still bars them from a real operand: Table 4-2, the
            // operators legal on reals, has no `===` or `!==`.
            const case = op == .case_eq or op == .case_neq;
            if (case and (a.ty == .real or b.ty == .real)) {
                var d = self.errWith(self.file.exprs.mainTok(e), .E0369);
                d.help("use `==`; for reals prefer `abs(a - b) < tol`", .{});
                try d.emit();
                return poison;
            }
            const op_cmp: Ast.BinaryOp = if (!case) op else if (op == .case_eq) .eq else .neq;
            if (sized and a.ty == .integer and b.ty == .integer) if (plan) |p| if (p.operands[0]) |c| {
                if (!c.signed and c.width == 64) {
                    a.v = try extendUnsigned(self, a.v, null, true);
                    b.v = try extendUnsigned(self, b.v, null, true);
                }
                return .{ .v = try cmp(self, op_cmp, a, b), .ty = .integer };
            };
            // §4.2.9's unsigned comparison: each operand zero-extended from
            // its own width. See `constfold.UnsignedCompare`.
            if (a.ty == .integer and b.ty == .integer) if (lower_constfold.unsignedCompare(self, e)) |u| {
                const az: TypedValue = .{ .v = try extendUnsigned(self, a.v, u.mask[0], u.flip), .ty = .integer };
                const bz: TypedValue = .{ .v = try extendUnsigned(self, b.v, u.mask[1], u.flip), .ty = .integer };
                return .{ .v = try cmp(self, op_cmp, az, bz), .ty = .integer };
            };
            return .{ .v = try cmp(self, op_cmp, a, b), .ty = .integer };
        },
        .bit_and, .bit_or, .bit_xor, .bit_xnor, .shl, .shr => {
            if (a.ty != .integer or b.ty != .integer) {
                try self.err(self.file.exprs.mainTok(e), .E0322, "got {s} and {s}", .{ @tagName(a.ty), @tagName(b.ty) });
                return poison;
            }
            // A logical right shift clears the sign extension before shifting
            // the source-width bit pattern; its result keeps the result type.
            if (sized and op == .shr) if (plan) |p| if (p.operands[0]) |c| {
                a.v = try resizeInt(self, a.v, .{ .width = c.width, .signed = false });
            };
            const opc: Mir.Opcode = switch (op) {
                .bit_and => .bitand,
                .bit_or => .bitor,
                .bit_xor => .bitxor,
                .bit_xnor => .bitxnor,
                .shl => .shl,
                .shr => .shr,
                else => unreachable, // else: the enclosing prong admits only these six
            };
            return .{ .v = try self.emit(opc, &.{ a.v, b.v }), .ty = .integer };
        },
        // §4.2.11 arithmetic shifts have no MIR opcode: a Verilog-A `integer`
        // is signed, so `<<<`/`>>>` would need a separate signed-shift op.
        .ashl, .ashr => {
            var d = self.errWith(self.file.exprs.mainTok(e), .E0324);
            d.help("use `<<` and `>>`", .{});
            try d.emit();
            return poison;
        },
        // `lowerShortCircuit` returned for both at the top.
        .logical_and, .logical_or => unreachable,
    }
}

/// IntContext.normalize without any width-erasing arithmetic opcode.
pub fn resizeInt(self: *Lower, v: Mir.Value, context: constfold.IntContext) Oom!Mir.Value {
    assert(self.valueValid(v));
    assert(self.blockValid(self.cur));
    if (context.width >= 64) return v;
    const mask: i64 = @intCast((@as(u64, 1) << @intCast(context.width)) - 1);
    const bits = try self.emit(.bitand, &.{ v, try self.mir.addIntConst(self.arena, mask) });
    if (!context.signed) return bits;
    std.debug.assert(context.width >= 1); // `IntContext`: every context comes from an operand width
    const sign = try self.emit(.bitand, &.{ bits, try self.mir.addIntConst(self.arena, @as(i64, 1) << @intCast(context.width - 1)) });
    const negative = try self.emit(.bitor, &.{ bits, try self.mir.addIntConst(self.arena, ~mask) });
    return self.emit(.select, &.{ try self.toBool(.{ .v = sign, .ty = .integer }), negative, bits });
}

/// §4.2.4 relational / §4.2.5 equality — integer 0/1 result either way.
pub fn cmp(self: *Lower, op: Ast.BinaryOp, a: TypedValue, b: TypedValue) Oom!Mir.Value {
    assert(self.valueValid(a.v));
    assert(self.valueValid(b.v));
    assert(self.blockValid(self.cur));
    const real = unify(a.ty, b.ty) == .real;
    const opc: Mir.Opcode = switch (op) {
        .eq => if (real) .feq else .ieq,
        .neq => if (real) .fne else .ine,
        .lt => if (real) .flt else .ilt,
        .le => if (real) .fle else .ile,
        .gt => if (real) .fgt else .igt,
        .ge => if (real) .fge else .ige,
        else => unreachable, // else: both callers pass a relational or `==`/`!=` operator
    };
    const lv = if (real) try self.toReal(a) else a.v;
    const rv = if (real) try self.toReal(b) else b.v;
    return self.emit(opc, &.{ lv, rv });
}

// ---- private ----

/// `constfold.UnsignedCompare.extend` as MIR.
fn extendUnsigned(self: *Lower, v: Mir.Value, mask: ?i64, flip: bool) Oom!Mir.Value {
    assert(self.valueValid(v));
    assert(self.blockValid(self.cur));
    var z = v;
    if (mask) |m| z = try self.emit(.bitand, &.{ z, try self.mir.addIntConst(self.arena, m) });
    if (flip) z = try self.emit(.bitxor, &.{ z, try self.mir.addIntConst(self.arena, std.math.minInt(i64)) });
    return z;
}

test "lowerUnary/lowerBinary: §4.2 an operator takes only the operand types its table lists" {
    const cases = [_]struct { body: []const u8, want: ?diag.Code }{
        // §4.2.9 bitwise operators are integer operators.
        .{ .body = "    k = ~k;", .want = null },
        .{ .body = "    y = ~r;", .want = .E0318 },
        .{ .body = "    k = k & 3;", .want = null },
        .{ .body = "    y = r & 3;", .want = .E0322 },
        // §4.2.10 the reductions are digital only: E0319 on a real operand,
        // E0348 on an integer one, E0320 for the parity forms.
        .{ .body = "    k = &r;", .want = .E0319 },
        .{ .body = "    k = &k;", .want = .E0348 },
        .{ .body = "    k = ^k;", .want = .E0320 },
        // §4.2.11 the arithmetic shifts have no analog form.
        .{ .body = "    k = k <<< 1;", .want = .E0324 },
        // §4.2.1 Table 4-2 has no `===` on reals.
        .{ .body = "    k = (k === 1);", .want = null },
        .{ .body = "    k = (r === 1.0);", .want = .E0369 },
        // §2.7 a string literal is a number; §3.3 a string value is not.
        .{ .body = "    y = \"A\" + 1;", .want = null },
        .{ .body = "    y = -\"A\";", .want = null },
        .{ .body = "    y = s + 1;", .want = .E0321 },
        .{ .body = "    y = -s;", .want = .E0321 },
        .{ .body = "    k = (s == 1);", .want = .E0321 },
    };
    for (cases) |c| try Lower.expectBodyVerdict(lower_expr.test_decls, c.body, c.want);
}
