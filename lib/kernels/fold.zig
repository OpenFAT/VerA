//! The §4.2 value folds: one operator (or §4.3 function) over folded
//! constants in, a `Const` out, or null when the result has no constant
//! value. Pure: no allocation, no AST. The constant_expression walker
//! (`frontend/constfold.zig`) and the MIR folder (`ir/opcode.zig`) call
//! these, so a parameter default and a folded opcode answer alike, and each
//! §4.3 function is the one a device computes (`contract.gm`, or the
//! `std.math` call `codegen/kernel_text.zig` makes).
//! Cites: VAMS §2.7 (string operands), §3.2 (the 32-bit integer wrap),
//! §3.3 (Table 3-3), §4.2.1.1, §4.2.1.3, §4.2.4-§4.2.12, §4.3 (Tables 4-14
//! and 4-15), A.8.6; IEEE 1364-2005 §5.1.5 (Table 5-6), §5.1.12, §17.11.1
//! (`$clog2`).
//!
//! Contents:
//! - `pub const UnaryOp = enum(u8)`, `pub const BinaryOp = enum(u8)` (A.8.6)
//! - `pub const Const = union(enum) { int: i64, real: f64, str: []const u8 }` (`asReal`, `asIntExact`, `asInt`, `isTrue`)
//! - `pub const MathFn = enum` (`fromName(name: []const u8) ?MathFn`, `arity(f: MathFn) usize`, `arity_max`)
//! - `pub fn wrap32(x: i64) i64`
//! - `pub fn ipow32(b: i64, n: i64) ?i64`
//! - `pub fn unary(op: UnaryOp, a: Const) ?Const`
//! - `pub fn binary(op: BinaryOp, a: Const, b: Const, lhs_signed: ?bool) ?Const`
//! - `pub fn math(f: MathFn, args: []const Const) ?Const`
//! - `pub fn clog2(value: i64, width: u32) i64`
//! - `pub fn strToInt(s: []const u8, bits: u8) i64`

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
/// The devices' math (`contract.gm`): a fold gives the bits the device computes.
const gm = @import("contract").gm;

/// A.8.6 unary_operator. Stored in the `extra` column of an Ast `.unary` node.
pub const UnaryOp = enum(u8) {
    plus, // +      §4.2.4
    minus, // -      §4.2.4
    logical_not, // !      §4.2.8
    bit_not, // ~      §4.2.9
    reduce_and, // &      §4.2.10
    reduce_nand, // ~&     §4.2.10
    reduce_or, // |      §4.2.10
    reduce_nor, // ~|     §4.2.10
    reduce_xor, // ^      §4.2.10
    reduce_xnor, // ~^ ^~  §4.2.10
};

/// A.8.6 binary_operator. Stored in the `extra` column of an Ast `.binary` node.
pub const BinaryOp = enum(u8) {
    add, // +    §4.2.4
    sub, // -    §4.2.4
    mul, // *    §4.2.4
    div, // /    §4.2.4
    mod, // %    §4.2.4
    pow, // **   §4.2.4
    eq, // ==   §4.2.7
    neq, // !=   §4.2.7
    case_eq, // ===  §4.2.6 (digital; rejected in the analog subset, annex C)
    case_neq, // !==  §4.2.6
    lt, // <    §4.2.5
    le, // <=   §4.2.5
    gt, // >    §4.2.5
    ge, // >=   §4.2.5
    logical_and, // &&   §4.2.8
    logical_or, // ||   §4.2.8
    bit_and, // &    §4.2.9
    bit_or, // |    §4.2.9
    bit_xor, // ^    §4.2.9
    bit_xnor, // ~^ ^~ §4.2.9
    shl, // <<   §4.2.11
    shr, // >>   §4.2.11
    ashl, // <<<  §4.2.11
    ashr, // >>>  §4.2.11
};

/// A folded constant (§4.2 constant_expression). Genvars (§3.5) and parameter
/// defaults live here so `for (i=0;i<N;i=i+1)` can unroll (§6.6.1).
pub const Const = union(enum) {
    int: i64,
    real: f64,
    str: []const u8,

    /// Returns the value as a real; a string is 0.
    pub fn asReal(c: Const) f64 {
        return switch (c) {
            .int => |i| @floatFromInt(i),
            .real => |r| r,
            .str => 0,
        };
    }
    /// Returns the value as an integer, rounding a real to nearest with ties
    /// away from zero (LRM §4.2.1.1). Null for a NaN, an infinity or a real
    /// outside i64, which §4.2.1.1 gives no value; a string is 0. A caller
    /// holding a real the user wrote must use this and diagnose the null.
    pub fn asIntExact(c: Const) ?i64 {
        return switch (c) {
            .int => |i| i,
            .real => |r| blk: {
                const v = @round(r);
                if (!std.math.isFinite(v)) break :blk null;
                // Compared against 2^63 and not maxInt(i64): 2^63 is exactly
                // representable as an f64 and maxInt(i64) is not, so rounding
                // the bound itself would let 2^63 through as "in range".
                if (v >= 9223372036854775808.0 or v < -9223372036854775808.0) break :blk null;
                break :blk @intFromFloat(v);
            },
            .str => 0,
        };
    }
    /// `asIntExact`, saturating out-of-range reals and mapping NaN to 0. Never
    /// panics. Only for operands already known to be in range; a real the
    /// user wrote goes through `asIntExact`.
    pub fn asInt(c: Const) i64 {
        // A bare `@intFromFloat` on an out-of-range double is illegal behavior,
        // so this saturates instead.
        return c.asIntExact() orelse blk: {
            const r = c.asReal();
            if (std.math.isNan(r)) break :blk 0;
            break :blk if (r > 0) std.math.maxInt(i64) else std.math.minInt(i64);
        };
    }
    /// Returns the truth value: nonzero, or a non-empty string.
    pub fn isTrue(c: Const) bool {
        return switch (c) {
            .int => |i| i != 0,
            .real => |r| r != 0,
            .str => |s| s.len != 0,
        };
    }
};

/// The built-in math functions of §4.3 Tables 4-14 and 4-15, named by their
/// source spelling. `log` is the decimal logarithm (§4.3.1); `ln` the natural.
pub const MathFn = enum {
    abs,
    min,
    max,
    pow,
    hypot,
    atan2,
    sqrt,
    exp,
    expm1,
    ln,
    ln1p,
    log,
    floor,
    ceil,
    sin,
    cos,
    tan,
    asin,
    acos,
    atan,
    sinh,
    cosh,
    tanh,
    asinh,
    acosh,
    atanh,

    /// Returns the function spelled `name`, or null for any other name.
    pub fn fromName(name: []const u8) ?MathFn {
        return std.meta.stringToEnum(MathFn, name);
    }
    /// Returns how many arguments §4.3's tables give `f`: 1 or 2.
    pub fn arity(f: MathFn) usize {
        return switch (f) {
            .min, .max, .pow, .hypot, .atan2 => 2,
            .abs, .sqrt, .exp, .expm1, .ln, .ln1p, .log, .floor, .ceil => 1,
            .sin, .cos, .tan, .asin, .acos, .atan, .sinh, .cosh, .tanh, .asinh, .acosh, .atanh => 1,
        };
    }

    /// The most arguments any function takes: `foldContext` folds a call's
    /// arguments into a buffer this long, and `math` reads `args[0]` always.
    pub const arity_max = 2;
    comptime {
        for (std.enums.values(MathFn)) |f| {
            std.debug.assert(f.arity() >= 1);
            std.debug.assert(f.arity() <= arity_max);
        }
    }
};

/// Truncates an integer arithmetic result to §3.2's 32-bit two's complement
/// and widens it back: an `integer` "can hold values ranging from -2^31 to
/// 2^31-1", so `2147483647 + 1` is -2147483648 (LRM §3.2).
///
/// The width is imposed on the operation, not the storage: an `integer` stays
/// in an i64 slot. This is exact because both operands of an integer operation
/// are already in range (a §2.5.1 literal or another wrapped result).
///
/// Three sites must agree: this file's `binary`, `analysis.foldConst` and
/// codegen's `intBin32`. Otherwise one expression would answer differently
/// in a parameter default than at run time.
///
/// Not applied to a literal: §2.5.1's `-2147483648` negates the unsigned
/// 2147483648, and wrapping the operand first would make the result positive.
pub fn wrap32(x: i64) i64 {
    const r: i64 = @as(i32, @truncate(x));
    assert(r >= std.math.minInt(i32));
    assert(r <= std.math.maxInt(i32));
    return r;
}

/// §4.2.1.3 `b ** n` with both operands integer: "a common data type for each
/// operand is determined before the operator is applied", and with neither
/// real that type is integer. IEEE 1364-2005 §5.1.5 supplies the values: for
/// n >= 0 the power at §3.2's 32-bit width ("The result value is 1 if the
/// second operand is zero"), and for n < 0 Table 5-6's row: 1 for base 1,
/// ±1 by parity for base -1, 0 for every other base (the true value lies
/// strictly between -1 and 1 and an integer truncates it). A zero base under a
/// negative exponent is Table 5-6's 'bx, which an analog integer cannot hold:
/// null here, E0609 from the prover when it is provable, and 0 at run time.
///
/// Same three sites as `wrap32`: `binary`, `analysis.foldConst`, and
/// codegen's `ipow_fn`, which is this function as device text.
pub fn ipow32(b: i64, n: i64) ?i64 {
    if (n < 0) return switch (b) {
        0 => null,
        1 => 1,
        -1 => if (@rem(n, 2) == 0) 1 else -1,
        else => 0, // else: every |b| > 1 truncates to 0, Table 5-6's "negative" row
    };
    assert(n >= 0);
    var x: i32 = @truncate(b);
    var e = n;
    var r: i32 = 1;
    // Square-and-multiply: one pass per exponent bit, at most 63.
    while (e > 0) : (e >>= 1) {
        if (e & 1 != 0) r *%= x;
        x *%= x;
    }
    return r;
}

/// Returns a unary operator folded over a folded operand, or null for the
/// reductions, which need a width a `Const` does not carry; `fold` answers
/// them from the literal.
pub fn unary(op: UnaryOp, a: Const) ?Const {
    return switch (op) {
        .plus => a,
        .minus => switch (a) {
            // `-%` because a 64-bit literal can be minInt(i64).
            .int => |i| .{ .int = wrapFrom(i, 0 -% i) },
            .real => |r| .{ .real = -r },
            .str => null,
        },
        .logical_not => Const{ .int = @intFromBool(!a.isTrue()) },
        .bit_not => Const{ .int = ~a.asInt() },
        .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => null,
    };
}

/// Returns a binary operator folded over two folded operands, or null when the
/// result has no constant value here: an integer zero divisor or a zero
/// modulus, a string beside a number or under an operator Table 3-3 does not
/// define, a shift count outside 0..63, a real under `<<<`, `>>>`, `===` or
/// `!==`, and `0 ** negative`. `lhs_signed` is the left operand's
/// signedness, read only by `>>>` (IEEE 1364-2005 §5.1.12); null makes `>>>`
/// decline.
pub fn binary(op: BinaryOp, a: Const, b: Const, lhs_signed: ?bool) ?Const {
    // Strings first: `asReal` is 0 for every string, so a numeric compare
    // would make `"slow" == "fast"` true.
    if (a == .str or b == .str) return strBinary(op, a, b);
    // §4.2.1 integer arithmetic only when both operands are integer.
    const int = a == .int and b == .int;
    const x = a.asReal();
    const y = b.asReal();
    // §3.2's 32-bit two's complement result (`wrap32`). `%` needs none: a
    // remainder is never wider than its operands.
    return switch (op) {
        .add => if (int) Const{ .int = wrap32(a.asInt() +% b.asInt()) } else Const{ .real = x + y },
        .sub => if (int) Const{ .int = wrap32(a.asInt() -% b.asInt()) } else Const{ .real = x - y },
        .mul => if (int) Const{ .int = wrap32(a.asInt() *% b.asInt()) } else Const{ .real = x * y },
        // A literal can occupy the full i64 carrier, and its minInt/-1
        // quotient needs 65 bits before the wrap.
        .div => if (int)
            (if (b.asInt() == 0) null else Const{ .int = @as(i32, @truncate(@divTrunc(@as(i65, a.asInt()), @as(i65, b.asInt())))) })
        else
            Const{ .real = x / y },
        // §4.2.4: "It shall be an error to pass zero (0) as the second
        // argument to the modulus operator", for either type, so a zero
        // divisor has no value to fold to; the prover's E0601 reports it.
        .mod => if (int)
            (if (b.asInt() == 0) null else Const{ .int = @intCast(@rem(@as(i65, a.asInt()), @as(i65, b.asInt()))) })
        else if (y == 0)
            null
        else
            Const{ .real = @rem(x, y) },
        // `ipow32`; its 'bx corner (0 ** negative) declines to fold.
        .pow => if (int) (if (ipow32(a.asInt(), b.asInt())) |r| Const{ .int = r } else null) else Const{ .real = gm.pow(x, y) },
        .eq => .{ .int = @intFromBool(if (int) a.int == b.int else x == y) },
        .neq => .{ .int = @intFromBool(if (int) a.int != b.int else x != y) },
        .lt => .{ .int = @intFromBool(if (int) a.int < b.int else x < y) },
        .le => .{ .int = @intFromBool(if (int) a.int <= b.int else x <= y) },
        .gt => .{ .int = @intFromBool(if (int) a.int > b.int else x > y) },
        .ge => .{ .int = @intFromBool(if (int) a.int >= b.int else x >= y) },
        .logical_and => .{ .int = @intFromBool(a.isTrue() and b.isTrue()) },
        .logical_or => .{ .int = @intFromBool(a.isTrue() or b.isTrue()) },
        .bit_and => .{ .int = a.asInt() & b.asInt() },
        .bit_or => .{ .int = a.asInt() | b.asInt() },
        .bit_xor => .{ .int = a.asInt() ^ b.asInt() },
        .bit_xnor => .{ .int = ~(a.asInt() ^ b.asInt()) },
        .shl, .shr => blk: {
            const sh = b.asInt();
            if (sh < 0 or sh > 63) break :blk null;
            // §4.2.11 `<<` zero-fills from the right; §3.2's width is what makes
            // `1 << 31` negative and `1 << 32` zero rather than 2^31 and 2^32.
            if (op == .shl) break :blk Const{ .int = wrap32(a.asInt() << @as(u6, @intCast(sh))) };
            // §4.2.11 `>>` fills the vacated positions with zeroes, over
            // §3.2.1's 32-bit `integer`. Must agree with codegen's
            // `shrLogical`, or a constant and a computed operand differ.
            if (sh == 0) break :blk a;
            if (sh > 31) break :blk Const{ .int = 0 };
            const lo: u32 = @bitCast(@as(i32, @truncate(a.asInt())));
            break :blk Const{ .int = lo >> @as(u5, @intCast(sh)) };
        },
        // §4.2.11 keeps `<<<`/`>>>` out of the analog BLOCK only; a constant
        // expression outside it is IEEE 1364-2005 §5.1.12's: `<<<` is `<<`,
        // and `>>>` fills with the sign bit "if the result type is signed",
        // with zeroes otherwise, so an operand of unknown signedness declines.
        .ashl, .ashr => blk: {
            if (!int) break :blk null;
            const sh = b.asInt();
            if (sh < 0 or sh > 63) break :blk null;
            if (op == .ashl) break :blk Const{ .int = wrap32(a.asInt() << @as(u6, @intCast(sh))) };
            const signed = lhs_signed orelse break :blk null;
            const v: i32 = @truncate(a.asInt());
            if (signed) break :blk Const{ .int = v >> @as(u5, @intCast(@min(sh, 31))) };
            if (sh > 31) break :blk Const{ .int = 0 };
            break :blk Const{ .int = @as(u32, @bitCast(v)) >> @as(u5, @intCast(sh)) };
        },
        // §4.2.5 case equality on two-state operands is `==`/`!=` (x and z
        // cannot occur), which is how lowering lowers it (VAMS §7.3.2). A real
        // operand is refused there (E0369), so it does not fold here either.
        .case_eq => if (int) Const{ .int = @intFromBool(a.int == b.int) } else null,
        .case_neq => if (int) Const{ .int = @intFromBool(a.int != b.int) } else null,
    };
}

/// Returns a §4.3 function folded over folded arguments, or null on a wrong
/// arity or a string argument. §4.3.1: `abs`, `min` and `max` are integer
/// when every argument is; every other function is real, `pow` included
/// (§4.2.1.3's integer power is the operator `**`). Out-of-domain
/// arguments fold to what IEEE arithmetic gives (NaN, ±inf); the prover, not
/// the folder, rules on domains.
pub fn math(f: MathFn, args: []const Const) ?Const {
    if (args.len != f.arity()) return null;
    assert(args.len >= 1);
    assert(args.len <= MathFn.arity_max);
    for (args) |a| if (a == .str) return null;
    const x = args[0].asReal();
    const y = if (args.len > 1) args[1].asReal() else 0;
    const int = for (args) |a| {
        if (a != .int) break false;
    } else true;
    return switch (f) {
        // Wrapping, like unary minus: |minInt(i64)| is not an i64.
        .abs => if (int) Const{ .int = wrapFrom(args[0].int, if (args[0].int < 0) 0 -% args[0].int else args[0].int) } else Const{ .real = @abs(x) },
        // §4.3.1 "min(x,y) is equivalent to (x < y) ? x : y", bit for bit:
        // @min/@max drop a NaN and leave a zero's sign open, and run time
        // (kernel_text zMin/zMax) uses the conditional form.
        .min => if (int) Const{ .int = @min(args[0].int, args[1].int) } else Const{ .real = if (x < y) x else y },
        .max => if (int) Const{ .int = @max(args[0].int, args[1].int) } else Const{ .real = if (x > y) x else y },
        .pow => .{ .real = gm.pow(x, y) },
        .hypot => .{ .real = std.math.hypot(x, y) },
        .atan2 => .{ .real = gm.atan2(x, y) },
        .sqrt => .{ .real = @sqrt(x) },
        .exp => .{ .real = gm.exp(x) },
        .expm1 => .{ .real = std.math.expm1(x) },
        .ln => .{ .real = gm.log(x) },
        .ln1p => .{ .real = std.math.log1p(x) },
        .log => .{ .real = gm.log10(x) },
        .floor => .{ .real = @floor(x) },
        .ceil => .{ .real = @ceil(x) },
        .sin => .{ .real = @sin(x) },
        .cos => .{ .real = @cos(x) },
        .tan => .{ .real = gm.tan(x) },
        .asin => .{ .real = std.math.asin(x) },
        .acos => .{ .real = std.math.acos(x) },
        .atan => .{ .real = std.math.atan(x) },
        .sinh => .{ .real = std.math.sinh(x) },
        .cosh => .{ .real = std.math.cosh(x) },
        .tanh => .{ .real = std.math.tanh(x) },
        .asinh => .{ .real = gm.asinh(x) },
        .acosh => .{ .real = gm.acosh(x) },
        .atanh => .{ .real = gm.atanh(x) },
    };
}

/// Returns `$clog2(value)` under §17.11.1's unsigned interpretation at the
/// source operand's `width`: the least k with 2^k at or above the value.
/// Wider signed literals that fit the i64 carrier repeat their sign bit;
/// a negative one is therefore above 2**(width-1) and rounds up to width.
pub fn clog2(value: i64, width: u32) i64 {
    if (width > 64 and value < 0) return width;
    const mask: u64 = if (width >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(width)) - 1;
    const bits = @as(u64, @bitCast(value)) & mask;
    const k: i64 = if (bits <= 1) 0 else 64 - @as(i64, @clz(bits - 1));
    assert(k >= 0);
    assert(k <= 64);
    return k;
}

/// Returns a §2.7 string literal's integer value. "A string literal used as
/// an operand in expressions and assignments
/// shall be treated as unsigned integer constants represented by a sequence of
/// 8-bit ASCII values, with one 8-bit ASCII value representing one character."
/// A base-256 numeral, most significant character first: "AB" is
/// 'A'*256 + 'B' == 16706, and the one-character "\n" is 10.
///
/// `bits` is §3.3's width rule for the assignment case: "the literal is right
/// justified and either truncated on the left or zero filled on the left".
/// The result is the unsigned value (§2.7 "unsigned integer constants"), so a
/// 32-bit "\377\377\377\377" is 4294967295, not -1; the first arithmetic on
/// it wraps into range.
pub fn strToInt(s: []const u8, bits: u8) i64 {
    const kept = s[s.len - @min(s.len, bits / 8) ..];
    assert(kept.len <= bits / 8);
    var acc: u64 = 0;
    for (kept) |c| acc = acc << 8 | c;
    if (bits <= 32) assert(acc >> 32 == 0); // four bytes at most
    return @bitCast(acc);
}

// ---- private ----

/// §3.2's wrap for unary `-` and `abs`, whose result `r` comes from operand
/// `a`: -(-2^31) is -2^31. An operand wider than 32 bits is a §2.6.1 literal
/// ("at least 32" bits), and its negation keeps that width, as the literal
/// itself does.
fn wrapFrom(a: i64, r: i64) i64 {
    return if (std.math.cast(i32, a) != null) wrap32(r) else r;
}

/// Folds Table 3-3's string operators. "Equality. Checks whether the two
/// strings are equal. Result is 1 if they are equal and 0 if they are not" and
/// "Relational operators return 1 if the corresponding condition is true using
/// the lexicographical ordering of the two strings".
///
/// A mixed string/number pair declines to fold. §2.7 makes a string operand
/// "unsigned integer constants" in an arithmetic context, but that conversion
/// is lowering's (`strNum`), and declining leaves the runtime path to answer.
fn strBinary(op: BinaryOp, a: Const, b: Const) ?Const {
    if (a != .str or b != .str) return null;
    const c = std.mem.order(u8, a.str, b.str);
    return .{
        .int = @intFromBool(switch (op) {
            .eq => c == .eq,
            .neq => c != .eq,
            .lt => c == .lt,
            .le => c != .gt,
            .gt => c == .gt,
            .ge => c != .lt,
            else => return null, // else: Table 3-3 defines only the relations on strings
        }),
    };
}

fn expectInt(want: i64, got: ?Const) !void {
    const c = got orelse return error.TestExpectedEqual;
    try testing.expect(c == .int);
    try testing.expectEqual(want, c.int);
}

fn expectReal(want: f64, got: ?Const) !void {
    const c = got orelse return error.TestExpectedEqual;
    try testing.expect(c == .real);
    try testing.expectEqual(want, c.real);
}

test "ipow32 is IEEE 1364-2005 Table 5-6 at 32 bits" {
    try std.testing.expectEqual(@as(?i64, 8), ipow32(2, 3));
    try std.testing.expectEqual(@as(?i64, 1), ipow32(0, 0)); // "1 if the second operand is zero"
    try std.testing.expectEqual(@as(?i64, 0), ipow32(0, 3));
    try std.testing.expectEqual(@as(?i64, -27), ipow32(-3, 3));
    try std.testing.expectEqual(@as(?i64, 0), ipow32(2, -1)); // |b| > 1, n < 0
    try std.testing.expectEqual(@as(?i64, 0), ipow32(-2, -1));
    try std.testing.expectEqual(@as(?i64, 1), ipow32(1, -5));
    try std.testing.expectEqual(@as(?i64, -1), ipow32(-1, -3));
    try std.testing.expectEqual(@as(?i64, 1), ipow32(-1, -4));
    try std.testing.expectEqual(@as(?i64, null), ipow32(0, -1)); // 'bx
    try std.testing.expectEqual(@as(?i64, -2147483648), ipow32(2, 31)); // §3.2 wrap
    try std.testing.expectEqual(@as(?i64, 0), ipow32(2, 32));
}

test "case equality folds on integers like ==, and declines on reals" {
    const a: Const = .{ .int = 3 };
    const b: Const = .{ .int = 3 };
    const r: Const = .{ .real = 3.0 };
    try std.testing.expectEqual(@as(i64, 1), (binary(.case_eq, a, b, null) orelse unreachable).int);
    try std.testing.expectEqual(@as(i64, 0), (binary(.case_neq, a, b, null) orelse unreachable).int);
    try std.testing.expect(binary(.case_eq, a, r, null) == null);
}

test "negate and abs wrap a 32-bit operand and keep a wider literal's width" {
    const min32: i64 = std.math.minInt(i32);
    try std.testing.expectEqual(min32, unary(.minus, .{ .int = min32 }).?.int);
    try std.testing.expectEqual(min32, math(.abs, &.{.{ .int = min32 }}).?.int);
    try std.testing.expectEqual(@as(i64, -5000000000), unary(.minus, .{ .int = 5000000000 }).?.int);
    try std.testing.expectEqual(@as(i64, 5000000000), math(.abs, &.{.{ .int = -5000000000 }}).?.int);
}

test "Const conversions: §4.2.1.1 rounding, the i64 range, and truth" {
    // §4.2.1.1: a real converts to an integer by rounding to nearest, ties
    // away from zero.
    try testing.expectEqual(@as(?i64, 3), (Const{ .real = 2.5 }).asIntExact());
    try testing.expectEqual(@as(?i64, -3), (Const{ .real = -2.5 }).asIntExact());
    try testing.expectEqual(@as(?i64, 2), (Const{ .real = 2.4999 }).asIntExact());
    // 2^63 is the first double past i64; -2^63 is minInt itself.
    try testing.expectEqual(@as(?i64, null), (Const{ .real = 9223372036854775808.0 }).asIntExact());
    try testing.expectEqual(@as(?i64, std.math.minInt(i64)), (Const{ .real = -9223372036854775808.0 }).asIntExact());
    try testing.expectEqual(@as(?i64, null), (Const{ .real = std.math.nan(f64) }).asIntExact());
    try testing.expectEqual(@as(?i64, null), (Const{ .real = std.math.inf(f64) }).asIntExact());
    try testing.expectEqual(@as(?i64, 0), (Const{ .str = "12" }).asIntExact());
    try testing.expectEqual(@as(?i64, -7), (Const{ .int = -7 }).asIntExact());
    // `asInt` saturates and maps NaN to 0 instead of failing.
    try testing.expectEqual(std.math.maxInt(i64), (Const{ .real = 1e300 }).asInt());
    try testing.expectEqual(std.math.minInt(i64), (Const{ .real = -1e300 }).asInt());
    try testing.expectEqual(@as(i64, 0), (Const{ .real = std.math.nan(f64) }).asInt());
    try testing.expectEqual(@as(f64, 0), (Const{ .str = "1.5" }).asReal());
    try testing.expectEqual(@as(f64, -4), (Const{ .int = -4 }).asReal());
    try testing.expect(!(Const{ .str = "" }).isTrue());
    try testing.expect((Const{ .str = "0" }).isTrue());
    try testing.expect(!(Const{ .real = -0.0 }).isTrue());
    try testing.expect((Const{ .real = std.math.nan(f64) }).isTrue());
    // §3.2's 32-bit wrap.
    try testing.expectEqual(@as(i64, -2147483648), wrap32(2147483648));
    try testing.expectEqual(@as(i64, 2147483647), wrap32(-2147483649));
    try testing.expectEqual(@as(i64, 0), wrap32(4294967296));
}

test "ipow32 agrees with repeated 32-bit multiplication" {
    // Oracle: n wrapping multiplications of the truncated base, which is
    // what §3.2's 32-bit power is for n >= 0.
    var prng = std.Random.DefaultPrng.init(0x1364_0506);
    const random = prng.random();
    for (0..4000) |i| {
        const b: i64 = if (i < 1000) @as(i64, @intCast(i % 11)) - 5 else random.int(i32);
        const reps: usize = i % 70;
        var want: i32 = 1;
        for (0..reps) |_| want *%= @as(i32, @truncate(b));
        try testing.expectEqual(@as(?i64, want), ipow32(b, @intCast(reps)));
    }
    // A huge even or odd exponent of -1, and of 2 (which wraps to 0).
    try testing.expectEqual(@as(?i64, 1), ipow32(-1, 1 << 40));
    try testing.expectEqual(@as(?i64, -1), ipow32(-1, (1 << 40) + 1));
    try testing.expectEqual(@as(?i64, 0), ipow32(2, 1 << 40));
}

test "unary folds a sign, a logical not and a complement; reductions need a width" {
    try testing.expect(unary(.plus, .{ .str = "s" }).? == .str);
    try testing.expect(unary(.minus, .{ .str = "s" }) == null);
    try expectReal(-1.5, unary(.minus, .{ .real = 1.5 }));
    try expectInt(std.math.minInt(i64), unary(.minus, .{ .int = std.math.minInt(i64) }));
    try expectInt(1, unary(.logical_not, .{ .real = 0.0 }));
    try expectInt(0, unary(.logical_not, .{ .str = "a" }));
    try expectInt(-1, unary(.bit_not, .{ .int = 0 }));
    for ([_]UnaryOp{ .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor }) |op|
        try testing.expect(unary(op, .{ .int = 3 }) == null);
}

test "binary over integers: §3.2's 32-bit wrap, §4.2.11 shifts, and the cases that have no value" {
    const Case = struct { BinaryOp, i64, i64, ?bool, ?i64 };
    const min32: i64 = std.math.minInt(i32);
    for ([_]Case{
        .{ .add, 2147483647, 1, null, min32 },
        .{ .sub, min32, 1, null, 2147483647 },
        .{ .mul, 65536, 65536, null, 0 },
        // Division truncates toward zero; the remainder has the dividend's sign.
        .{ .div, -7, 2, null, -3 },
        .{ .div, 7, -2, null, -3 },
        .{ .div, 1, 0, null, null },
        // minInt(i64) / -1 is 2^63, whose low 32 bits are 0.
        .{ .div, std.math.minInt(i64), -1, null, 0 },
        .{ .mod, -7, 2, null, -1 },
        .{ .mod, 7, -2, null, 1 },
        .{ .mod, 5, 0, null, null },
        .{ .mod, std.math.minInt(i64), -1, null, 0 },
        .{ .pow, 2, 10, null, 1024 },
        .{ .pow, 0, -1, null, null },
        .{ .eq, 3, 3, null, 1 },
        .{ .neq, 3, 3, null, 0 },
        .{ .lt, -1, 0, null, 1 },
        .{ .le, 0, 0, null, 1 },
        .{ .gt, 0, -1, null, 1 },
        .{ .ge, -1, 0, null, 0 },
        .{ .bit_and, 12, 10, null, 8 },
        .{ .bit_or, 12, 10, null, 14 },
        .{ .bit_xor, 12, 10, null, 6 },
        .{ .bit_xnor, 12, 10, null, -7 },
        .{ .logical_and, 2, 0, null, 0 },
        .{ .logical_or, 0, 3, null, 1 },
        // `1 << 31` is negative and `1 << 32` zero at 32 bits; a count
        // outside 0..63 has no constant value here.
        .{ .shl, 1, 31, null, min32 },
        .{ .shl, 1, 32, null, 0 },
        .{ .shl, 3, 63, null, 0 },
        .{ .shl, 1, -1, null, null },
        .{ .shl, 1, 64, null, null },
        // `>>` zero-fills over 32 bits: -16 >> 2 is 0x3FFFFFFC.
        .{ .shr, -16, 2, null, 1073741820 },
        .{ .shr, -16, 0, null, -16 },
        .{ .shr, -16, 32, null, 0 },
        .{ .shr, 1, 64, null, null },
        .{ .ashl, 1, 31, null, min32 },
        // `>>>` fills with the sign bit only when the operand is signed.
        .{ .ashr, -16, 2, true, -4 },
        .{ .ashr, -16, 40, true, -1 },
        .{ .ashr, -16, 2, false, 1073741820 },
        .{ .ashr, -1, 32, false, 0 },
        .{ .ashr, -16, 2, null, null },
        .{ .ashr, -16, -1, true, null },
        .{ .case_eq, 3, 3, null, 1 },
        .{ .case_neq, 3, 4, null, 1 },
    }) |c| {
        const got = binary(c[0], .{ .int = c[1] }, .{ .int = c[2] }, c[3]);
        if (c[4]) |want| try expectInt(want, got) else try testing.expect(got == null);
    }
}

test "binary over reals and strings: IEEE arithmetic, Table 3-3, and the mixes that decline" {
    try expectReal(std.math.inf(f64), binary(.div, .{ .real = 1 }, .{ .real = 0 }, null));
    try testing.expect(binary(.mod, .{ .real = 5 }, .{ .real = 0 }, null) == null);
    try expectReal(1.5, binary(.mod, .{ .real = 7.5 }, .{ .int = 2 }, null));
    try expectReal(1.5, binary(.add, .{ .int = 1 }, .{ .real = 0.5 }, null));
    try expectInt(1, binary(.lt, .{ .int = 1 }, .{ .real = 1.5 }, null));
    try testing.expect(binary(.ashr, .{ .real = 8 }, .{ .int = 1 }, true) == null);
    try testing.expect(binary(.case_eq, .{ .real = 3 }, .{ .real = 3 }, null) == null);
    const p = binary(.pow, .{ .real = 2 }, .{ .real = 0.5 }, null).?.real;
    try testing.expect(std.math.approxEqRel(f64, std.math.sqrt2, p, 1e-15));
    // Table 3-3: equality and lexicographic order, nothing else.
    try expectInt(1, binary(.lt, .{ .str = "ab" }, .{ .str = "b" }, null));
    try expectInt(1, binary(.eq, .{ .str = "ab" }, .{ .str = "ab" }, null));
    try expectInt(0, binary(.eq, .{ .str = "slow" }, .{ .str = "fast" }, null));
    try expectInt(1, binary(.ge, .{ .str = "b" }, .{ .str = "b" }, null));
    try testing.expect(binary(.add, .{ .str = "a" }, .{ .str = "b" }, null) == null);
    try testing.expect(binary(.eq, .{ .str = "a" }, .{ .int = 1 }, null) == null);
}

test "§4.3 math: integer abs/min/max, the conditional min/max, and arity" {
    try testing.expect(math(.sqrt, &.{ .{ .real = 1 }, .{ .real = 2 } }) == null);
    try testing.expect(math(.min, &.{.{ .int = 1 }}) == null);
    try testing.expect(math(.exp, &.{.{ .str = "1" }}) == null);
    try expectInt(3, math(.abs, &.{.{ .int = -3 }}));
    try expectInt(std.math.minInt(i64), math(.abs, &.{.{ .int = std.math.minInt(i64) }}));
    try expectReal(2.5, math(.abs, &.{.{ .real = -2.5 }}));
    try expectInt(1, math(.min, &.{ .{ .int = 1 }, .{ .int = 2 } }));
    try expectInt(2, math(.max, &.{ .{ .int = 1 }, .{ .int = 2 } }));
    try expectReal(1, math(.min, &.{ .{ .int = 1 }, .{ .real = 2 } }));
    // §4.3.1 "(x < y) ? x : y": a NaN first loses, a NaN second wins, and
    // the second of two zeros is taken.
    const nan = std.math.nan(f64);
    try expectReal(1, math(.min, &.{ .{ .real = nan }, .{ .real = 1 } }));
    try testing.expect(std.math.isNan(math(.min, &.{ .{ .real = 1 }, .{ .real = nan } }).?.real));
    try expectReal(1, math(.max, &.{ .{ .real = nan }, .{ .real = 1 } }));
    try testing.expect(!std.math.signbit(math(.min, &.{ .{ .real = -0.0 }, .{ .real = 0.0 } }).?.real));
    try testing.expect(std.math.signbit(math(.min, &.{ .{ .real = 0.0 }, .{ .real = -0.0 } }).?.real));
    // `log` is decimal (§4.3.1), `ln` natural.
    try testing.expect(std.math.approxEqAbs(f64, 3, math(.log, &.{.{ .int = 1000 }}).?.real, 1e-15));
    try testing.expect(std.math.approxEqAbs(f64, 1, math(.ln, &.{.{ .real = std.math.e }}).?.real, 1e-15));
    try expectReal(-2, math(.floor, &.{.{ .real = -1.5 }}));
    try expectReal(-1, math(.ceil, &.{.{ .real = -1.5 }}));
    try expectReal(5, math(.hypot, &.{ .{ .int = 3 }, .{ .int = 4 } }));
    try testing.expect(std.math.approxEqAbs(f64, std.math.pi, math(.atan2, &.{ .{ .real = 0 }, .{ .real = -1 } }).?.real, 1e-15));
    try testing.expect(std.math.isNan(math(.sqrt, &.{.{ .real = -1 }}).?.real));
    // Every name, and only the five two-argument functions take two.
    for (std.enums.values(MathFn)) |f| {
        try testing.expectEqual(@as(?MathFn, f), MathFn.fromName(@tagName(f)));
        const two = f == .min or f == .max or f == .pow or f == .hypot or f == .atan2;
        try testing.expectEqual(@as(usize, if (two) 2 else 1), f.arity());
    }
    try testing.expectEqual(@as(?MathFn, null), MathFn.fromName("LOG"));
    try testing.expectEqual(@as(?MathFn, null), MathFn.fromName("log10"));
}

test "clog2 is the least k with 2^k at or above the unsigned value" {
    // Oracle: the smallest k for which 2^k >= the value read unsigned at
    // `width`, counted in u128.
    for (1..13) |w| {
        const width: u32 = @intCast(w);
        for (0..@as(usize, 1) << @intCast(w)) |v| {
            var k: i64 = 0;
            while ((@as(u128, 1) << @intCast(k)) < v) k += 1;
            try testing.expectEqual(k, clog2(@intCast(v), width));
        }
        // A negative carrier value is read at `width` bits, unsigned.
        try testing.expectEqual(clog2((@as(i64, 1) << @intCast(w)) - 1, width), clog2(-1, width));
    }
    try testing.expectEqual(@as(i64, 64), clog2(-1, 64));
    try testing.expectEqual(@as(i64, 63), clog2((1 << 62) | 1, 64));
    try testing.expectEqual(@as(i64, 65), clog2(-1, 65));
    try testing.expectEqual(@as(i64, 3), clog2(5, 70));
}

test "§2.7 a string literal is a base-256 numeral, §3.3 justified right" {
    // §2.7's own sentence, at the natural width: most significant character
    // first, and a plain space is a character like any other.
    try std.testing.expectEqual(@as(i64, 10), strToInt("\n", 64));
    try std.testing.expectEqual(@as(i64, 32), strToInt(" ", 64));
    try std.testing.expectEqual(@as(i64, 16706), strToInt("AB", 64));
    // §3.3 into a 32-bit `integer` (§3.2): "hello" is 40 bits and loses its
    // leading 'h' on the LEFT, "A" is zero filled on the left, and Table 3-3's
    // `""` -> 8'b0 is the caller's (`strLitBytes`), so `{"H", ""}` is "H\x00".
    try std.testing.expectEqual(@as(i64, 1701604463), strToInt("hello", 32));
    try std.testing.expectEqual(@as(i64, 65), strToInt("A", 32));
    try std.testing.expectEqual(@as(i64, 18432), strToInt("H\x00", 32));
    try std.testing.expectEqual(@as(i64, 0), strToInt("", 32));
}
