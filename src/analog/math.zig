const std = @import("std");
const Lower = @import("Lower.zig");
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const diag = @import("diag");
const lower_expr = @import("expr.zig");
const Oom = Lower.Oom;
const TypedValue = Lower.TypedValue;
const poison = Lower.poison;
const unify = Lower.unify;

/// LRM Table 4-14 §4.3.1 / Table 4-15 §4.3.2 — the real-valued one-argument
/// functions, by their LRM spelling. `log` is base 10 (`log10` in MIR).
pub fn unaryMathOp(name: []const u8) ?Mir.Opcode {
    return unary_math.get(name);
}

/// LRM Table 4-14 — the real-valued two-argument functions.
pub fn binaryMathOp(name: []const u8) ?Mir.Opcode {
    return binary_math.get(name);
}

// File-scope so `unknownCall` can offer `.keys()` as did-you-mean candidates:
// a misspelled built-in is the commonest way to reach E0512, and the LRM's own
// spelling is the answer.
const unary_math = std.StaticStringMap(Mir.Opcode).initComptime(.{
    .{ "sqrt", .sqrt },   .{ "exp", .exp },     .{ "expm1", .expm1 },
    .{ "ln", .ln },       .{ "ln1p", .ln1p },   .{ "log", .log10 },
    .{ "floor", .floor }, .{ "ceil", .ceil },   .{ "sin", .sin },
    .{ "cos", .cos },     .{ "tan", .tan },     .{ "asin", .asin },
    .{ "acos", .acos },   .{ "atan", .atan },   .{ "sinh", .sinh },
    .{ "cosh", .cosh },   .{ "tanh", .tanh },   .{ "asinh", .asinh },
    .{ "acosh", .acosh }, .{ "atanh", .atanh },
});

const binary_math = std.StaticStringMap(Mir.Opcode).initComptime(.{
    .{ "pow", .pow }, .{ "hypot", .hypot }, .{ "atan2", .atan2 },
});

/// Lowers a §4.3 built-in math call. `abs`/`min`/`max` keep integer operands integer
/// (§4.3.1: "if both operands are integer the result is integer").
pub fn lowerBuiltin(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const spelling = self.file.str(ex.strOf(e));
    const name = if (std.mem.startsWith(u8, spelling, "$")) spelling[1..] else spelling;
    const args = ex.args(e);

    if (unaryMathOp(name)) |op| {
        if (args.len != 1) return arityError(self, e, name, 1);
        const a = try numOperand(self, args[0]) orelse return poison;
        return .{ .v = try self.emit(op, &.{try self.toReal(a)}), .ty = .real };
    }
    if (binaryMathOp(name)) |op| {
        if (args.len != 2) return arityError(self, e, name, 2);
        const a = try numOperand(self, args[0]) orelse return poison;
        const b = try numOperand(self, args[1]) orelse return poison;
        return .{ .v = try self.emit(op, &.{ try self.toReal(a), try self.toReal(b) }), .ty = .real };
    }
    if (std.mem.eql(u8, name, "abs")) {
        if (args.len != 1) return arityError(self, e, name, 1);
        const a = try numOperand(self, args[0]) orelse return poison;
        const int = a.ty == .integer;
        return .{ .v = try self.emit(if (int) .iabs else .fabs, &.{a.v}), .ty = a.ty };
    }
    if (std.mem.eql(u8, name, "min") or std.mem.eql(u8, name, "max")) {
        if (args.len != 2) return arityError(self, e, name, 2);
        const a = try numOperand(self, args[0]) orelse return poison;
        const b = try numOperand(self, args[1]) orelse return poison;
        const ty = unify(a.ty, b.ty);
        const is_min = name[1] == 'i';
        const op: Mir.Opcode = if (ty == .real)
            (if (is_min) .fmin else .fmax)
        else
            (if (is_min) .imin else .imax);
        const lv = if (ty == .real) try self.toReal(a) else a.v;
        const rv = if (ty == .real) try self.toReal(b) else b.v;
        return .{ .v = try self.emit(op, &.{ lv, rv }), .ty = ty };
    }
    try unknownCall(self, e, name);
    return poison;
}

/// Lowers one §4.3 built-in operand: §4.3.1 "The operands shall be numeric
/// (integer or real)", §4.3.2 "All operands shall be numeric". A string
/// literal is one (§2.7: an unsigned integer constant); a string variable is
/// not (§3.3 Table 3-3 gives it no arithmetic), and is E0321 with null. The
/// test is the expression's shape: a variable assigned a literal carries the
/// literal's constant value, and is still a string.
fn numOperand(self: *Lower, arg: Ast.ExprId) Oom!?TypedValue {
    const tv = try lower_expr.lowerExpr(self, arg);
    if (tv.ty != .string) return tv;
    if (self.file.exprs.tag(arg) == .str_literal) return try self.strNum(tv);
    try self.err(self.file.exprs.mainTok(arg), .E0321, "a §4.3 math function operand shall be numeric (integer or real); this one is a string", .{});
    return null;
}

/// Reports E0512 with a suggestion drawn from everything that could have been
/// called here: the module's §4.7 analog functions and the §4.3 built-ins of
/// Tables 4-14/4-15, in one candidate list so the single nearest name wins.
pub fn unknownCall(self: *Lower, e: Ast.ExprId, name: []const u8) Oom!void {
    var b = self.errWith(self.file.exprs.mainTok(e), .E0512);
    b.msg("`{s}`", .{name});

    var names: std.ArrayList([]const u8) = .empty;
    if (self.module) |m| {
        for (m.functions) |*fd| try names.append(self.arena, self.file.str(fd.name));
    }
    try names.appendSlice(self.arena, unary_math.keys());
    try names.appendSlice(self.arena, binary_math.keys());
    // §3.13.2 access functions land here too: the parser routes `Vv(p,n)` to a
    // function call because `Vv` is not an access name, so `V` is the
    // answer far more often than any analog function is.
    var it = self.access_kind.keyIterator();
    while (it.next()) |k| try names.append(self.arena, k.*);
    if (diag.didYouMean(name, names.items)) |s| b.suggestHere(s);

    return b.emit();
}

/// Reports E0506 (`name` takes `want` arguments) and returns the poison value.
pub fn arityError(self: *Lower, e: Ast.ExprId, name: []const u8, want: usize) Oom!TypedValue {
    try self.err(self.file.exprs.mainTok(e), .E0506, "`{s}()` takes {d}", .{ name, want });
    return poison;
}

test "lowerBuiltin: §4.3 math functions take numeric operands, as many as their table says" {
    const cases = [_]struct { body: []const u8, want: ?diag.Code }{
        .{ .body = "    y = hypot(3.0, 4.0) + atan2(1.0, 1.0) + log(10.0);", .want = null },
        .{ .body = "    k = abs(-3) + min(k, 2) + max(k, 4);", .want = null },
        .{ .body = "    y = sqrt(\"A\");", .want = null },
        .{ .body = "    y = sqrt(s);", .want = .E0321 },
        .{ .body = "    y = sqrt(1.0, 2.0);", .want = .E0506 },
        .{ .body = "    y = pow(1.0);", .want = .E0506 },
        .{ .body = "    y = abs(1.0, 2.0);", .want = .E0506 },
        .{ .body = "    y = min(1.0);", .want = .E0506 },
    };
    for (cases) |c| try Lower.expectBodyVerdict(lower_expr.test_decls, c.body, c.want);
}
