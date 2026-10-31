//! §4.2.1 type coercion: a `TypedValue` and the type its consumer wants in,
//! the converted `Mir.Value` out (emitting the cast when one is needed).
//! §4.2.1.1 real to integer rounds (`fi_cast`), §4.2.1.2 integer to real
//! (`if_cast`), §2.7 a string literal is an unsigned integer, and §3.3 draws
//! the one line no conversion crosses: a string value into an integral slot.
//!
//! Cites: §2.7, §3.2, §3.3 (Table 3-3), §3.4.1, §4.2.1, §4.2.1.1, §4.2.1.2,
//! §4.2.8, §4.2.13.
//!
//! Contents:
//! - `pub const strToInt` (`kernels.fold.strToInt`)
//! - `pub fn strNum(self: *Lower, tv: TypedValue) Oom!TypedValue`
//! - `pub fn toReal(self: *Lower, tv0: TypedValue) Oom!Mir.Value`
//! - `pub fn toInt(self: *Lower, tv0: TypedValue) Oom!Mir.Value`
//! - `pub fn coerceTo(self: *Lower, e: Ast.ExprId, ty: Ty, tv: TypedValue) Oom!Mir.Value`
//! - `pub fn toBool(self: *Lower, tv: TypedValue) Oom!Mir.Value`
//! - `pub fn unify(a: Ty, b: Ty) Ty`
//! - `pub fn astTy(t: Ast.Type) Ty`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Lower = @import("Lower.zig");
const lower_var = @import("var.zig");
const Oom = Lower.Oom;
const Ty = Lower.Ty;
const TypedValue = Lower.TypedValue;
const expectBodyVerdict = Lower.expectBodyVerdict;

/// §2.7 a string literal's integer value: `kernels.fold.strToInt`.
pub const strToInt = @import("kernels").fold.strToInt;

/// Returns `tv` converted to a number when it is a string with compile-time
/// bytes (§2.7 at an operand); everything else is returned untouched, and the
/// caller diagnoses a runtime string.
pub fn strNum(self: *Lower, tv: TypedValue) Oom!TypedValue {
    assert(self.valueValid(tv.v));
    // ponytail: 64 bits, the width of the slot the value lands in. An operand
    // has no declared width (§3.3's assignment case passes its own), so a
    // literal longer than eight characters keeps its low eight.
    if (tv.ty != .string) return tv;
    const out: TypedValue = switch (self.mir.valueDef(tv.v)) {
        .str_const => |s| .{ .v = try self.mir.addIntConst(self.arena, strToInt(s, 64)), .ty = .integer },
        .undef, .float_const, .int_const, .param_ref, .block_param, .inst_result => tv,
    };
    if (out.ty == .string) assert(out.v == tv.v); // a runtime string is the caller's to diagnose
    return out;
}

/// Returns `tv0` as a real (§4.2.1.2 integer→real; §2.7 string→number).
pub fn toReal(self: *Lower, tv0: TypedValue) Oom!Mir.Value {
    assert(self.valueValid(tv0.v));
    const tv = try self.strNum(tv0); // §2.7
    const v = switch (tv.ty) {
        .real => tv.v,
        .integer => try self.emit(.if_cast, &.{tv.v}),
        .string => tv.v, // already diagnosed at the use site
        .wide => unreachable, // `lowerExpr` types no value `.wide`: a whole wide `reg` read is E0222
    };
    assert(self.valueValid(v));
    return v;
}

/// Returns `tv0` as an integer (§4.2.1.1 real→integer rounds; §2.7 string→number).
pub fn toInt(self: *Lower, tv0: TypedValue) Oom!Mir.Value {
    assert(self.valueValid(tv0.v));
    const tv = try self.strNum(tv0); // §2.7
    const v = switch (tv.ty) {
        .integer => tv.v,
        .real => try self.emit(.fi_cast, &.{tv.v}),
        .string => tv.v,
        .wide => unreachable, // `lowerExpr` types no value `.wide`: a whole wide `reg` read is E0222
    };
    assert(self.valueValid(v));
    return v;
}

/// Returns `tv` converted for a §5.7 store into a slot of type `ty`.
/// §4.2.1.1/§4.2.1.2 convert between integer and real; §3.3 draws the one line
/// no conversion crosses, between a string literal and a string value:
///
///   "A string literal can be assigned to a string or an integral type. ...
///    A string cannot be assigned to an integral type."
///
/// So `integer code = "A";` is legal and `code = label;` (label a `string`) is
/// not: the test is the shape of expression `e`, not its lowered type. Every
/// write to a declared variable goes through this.
pub fn coerceTo(self: *Lower, e: Ast.ExprId, ty: Ty, tv: TypedValue) Oom!Mir.Value {
    assert(self.exprValid(e));
    assert(self.valueValid(tv.v));
    // ponytail: the mirror direction, a numeric into a `string` slot (which
    // §3.4.1 forbids too), is unchecked; the arm to add it to is `.string`.
    if (tv.ty == .string and ty != .string) {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.arena);
        if (!try strLitBytes(self, e, &bytes, 0)) {
            try self.err(self.file.exprs.mainTok(e), .E0354, "assigning a string to {s}", .{@tagName(ty)});
            return lower_var.zeroOf(ty);
        }
        // §3.3's "right justified and either truncated on the left or zero
        // filled on the left" is measured against the declared type, and §3.2
        // fixes `integer` at 32 bits: "hello" is 40 bits and loses its 'h'.
        if (ty == .integer) return self.mir.addIntConst(self.arena, strToInt(bytes.items, 32));
    }
    const v = switch (ty) {
        .real => try self.toReal(tv),
        .integer => try self.toInt(tv),
        .string => tv.v,
        .wide => unreachable, // `resolveLvalue` types a wide `reg` `.integer`, and nothing else coerces to one
    };
    assert(self.valueValid(v));
    return v;
}

/// Returns `tv` as integer 0/1: §4.2.8, a condition is "true" when non-zero. Normalized to integer 0/1 so
/// `logand`/`logor`/`branch` all see the same shape.
pub fn toBool(self: *Lower, tv: TypedValue) Oom!Mir.Value {
    assert(self.valueValid(tv.v));
    const v = switch (tv.ty) {
        .integer => try self.emit(.ine, &.{ tv.v, .zero }),
        .real => try self.emit(.fne, &.{ tv.v, .f_zero }),
        .string => .zero,
        .wide => unreachable, // `lowerExpr` types no value `.wide`: a whole wide `reg` read is E0222
    };
    assert(self.valueValid(v));
    return v;
}

/// Returns the operation type of two operands: §4.2.1, one real operand makes
/// the operation real; a string operand makes it a string.
pub fn unify(a: Ty, b: Ty) Ty {
    assert(a != .wide); // `lowerExpr` types no value `.wide`
    assert(b != .wide);
    if (a == .string or b == .string) return .string;
    return if (a == .real or b == .real) .real else .integer;
}

/// Returns the lowering type of a declared AST type (`.unspecified` is real).
pub fn astTy(t: Ast.Type) Ty {
    const ty: Ty = switch (t) {
        .real, .unspecified => .real,
        .integer => .integer,
        .string => .string,
    };
    assert(ty != .wide); // `.wide` is a `reg`'s, never a declared AST type's
    return ty;
}

// ---- private ----

/// Is `e` a §3.3 string literal, and what are its bytes? The literal itself, or
/// a concatenation of literals — §4.2.13's replication with a literal count is
/// unrolled by the parser, so `{5{"Hi"}}` arrives as five operands.
///
/// A `.multi_concat` is deliberately not one, and that exclusion is the whole
/// rule: Table 3-3's multiplier "can be nonconstant", and a nonconstant one
/// leaves a string with no width at elaboration, which is why §3.3's own
/// example makes `r = {i{"Hi"}}` invalid where `b = {i{"Hi"}}` is fine.
///
/// The test is made on the AST because the SSA builder answers a read of a
/// once-written `string label = "hi"` with the literal's own `str_const`, so
/// by Value `code = label` and `code = "hi"` are indistinguishable.
///
/// Table 3-3's empty-string row is the one place these bytes differ from the
/// string the same expression evaluates to: `""` "is converted to 8'b0", so
/// `{"H", ""}` is "H" as a string and 'H' followed by one zero byte as an
/// integral.
fn strLitBytes(self: *Lower, e: Ast.ExprId, out: *std.ArrayList(u8), depth: u32) Oom!bool {
    assert(self.exprValid(e));
    assert(depth <= self.file.exprs.len()); // a tree's depth is below its node count
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .str_literal => {
            const s = self.file.str(ex.strOf(e));
            try out.appendSlice(self.arena, if (s.len == 0) &[_]u8{0} else s);
            return true;
        },
        .concat => {
            for (ex.args(e)) |el| if (!try strLitBytes(self, el, out, depth + 1)) return false;
            return true;
        },
        else => return false, // else: not a literal or a concatenation of literals, so no compile-time bytes
    }
}

test unify {
    // §4.2.1: one real operand makes the operation real, and §3.3 Table 3-3
    // makes an operation with a string operand a string one.
    const cases = [_]struct { a: Ty, b: Ty, want: Ty }{
        .{ .a = .integer, .b = .integer, .want = .integer },
        .{ .a = .integer, .b = .real, .want = .real },
        .{ .a = .real, .b = .integer, .want = .real },
        .{ .a = .real, .b = .real, .want = .real },
        .{ .a = .string, .b = .integer, .want = .string },
        .{ .a = .integer, .b = .string, .want = .string },
        .{ .a = .string, .b = .real, .want = .string },
        .{ .a = .real, .b = .string, .want = .string },
        .{ .a = .string, .b = .string, .want = .string },
    };
    for (cases) |c| try std.testing.expectEqual(c.want, unify(c.a, c.b));
}

test astTy {
    // §3.4.1: a declaration with no type is real until a value says otherwise.
    try std.testing.expectEqual(Ty.real, astTy(.real));
    try std.testing.expectEqual(Ty.real, astTy(.unspecified));
    try std.testing.expectEqual(Ty.integer, astTy(.integer));
    try std.testing.expectEqual(Ty.string, astTy(.string));
}

test strToInt {
    // §3.3's right justification at widths other than the ordinary 32 and
    // 64: whole bytes only, the leftmost characters dropped first.
    try std.testing.expectEqual(0, strToInt("", 64));
    try std.testing.expectEqual(0, strToInt("AB", 0));
    try std.testing.expectEqual('B', strToInt("AB", 8));
    try std.testing.expectEqual('B', strToInt("AB", 12));
    // Nine characters at 64 bits keep the last eight, 'B' (0x42) to 'I' (0x49).
    try std.testing.expectEqual(0x4243444546474849, strToInt("ABCDEFGHI", 64));
    // §2.7's "unsigned integer constants": unsigned at 32 bits, and the whole
    // 64-bit pattern reinterpreted at the slot's own width.
    try std.testing.expectEqual(4294967295, strToInt("\xff\xff\xff\xff", 32));
    try std.testing.expectEqual(-1, strToInt("\xff\xff\xff\xff\xff\xff\xff\xff", 64));
}

test "coerceTo: §3.3 a string reaches an integral slot only as a literal (E0354)" {
    const decls = "  integer k;\n  string s;\n  parameter integer c = 2;";
    // "A string cannot be assigned to an integral type."
    try expectBodyVerdict(decls, "    s = \"AB\";\n    k = s;", .E0354);
    // "A string literal can be assigned to a string or an integral type."
    try expectBodyVerdict(decls, "    k = \"AB\";", null);
    try expectBodyVerdict(decls, "    k = {\"A\", \"B\"};", null);
    // §3.3's own `r = {i{"Hi"}}`: a multiplier the parser could not unroll
    // leaves the literal no width at elaboration.
    try expectBodyVerdict(decls, "    k = {c{\"A\"}};", .E0354);
}
