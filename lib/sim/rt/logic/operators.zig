//! Operands as `T(w)` in; the value `Integer.Literal`'s operator of the same name computes out (its tests are the oracle). Under `--two-state` an x or z an operator would make is 0.
//! Cites: IEEE 1364-2005 §5.1.5 to §5.1.14 with Tables 5-12 to 5-21.
//!
//! Contents:
//! - `pub const Bitwise = enum`
//! - `pub const Shift = enum`
//! - `pub const Relational = enum`
//! - `pub const Equality = enum`
//! - `pub const Reduction = enum`
//! - `pub const Logical = enum`
//! - `pub inline fn not(a: anytype, comptime w: u32) T(w)`
//! - `pub inline fn neg(a: anytype, comptime w: u32) T(w)`
//! - `pub inline fn bitwise(comptime op: Bitwise, a: anytype, b: @TypeOf(a), comptime w: u32) T(w)`
//! - `pub inline fn arith(comptime op: Arith, a: anytype, b: @TypeOf(a), comptime w: u32, comptime signed: bool) T(w)`
//! - `pub fn pow(a: anytype, comptime w: u32, comptime signed: bool, e: anytype, comptime ew: u32, comptime esigned: bool) T(w)`
//! - `pub inline fn shift(comptime op: Shift, a: anytype, comptime w: u32, comptime signed: bool, b: anytype) T(w)`
//! - `pub inline fn rel(comptime op: Relational, a: anytype, b: @TypeOf(a), comptime w: u32, comptime signed: bool) Bit`
//! - `pub inline fn eq(comptime op: Equality, a: anytype, b: @TypeOf(a)) Bit`
//! - `pub inline fn reduce(comptime op: Reduction, a: anytype, comptime w: u32) Bit`
//! - `pub inline fn truth(a: anytype) Bit`
//! - `pub inline fn invert(b: Bit) Bit`
//! - `pub inline fn logical(comptime op: Logical, a: Bit, b: Bit) Bit`
//! - `pub inline fn cond(c: Bit, y: anytype, n: @TypeOf(y)) @TypeOf(y)`
//! - `pub fn check(comptime w: u32, comptime signed: bool, a: T(w), b: T(w)) !void`
//! - `pub fn randomW(rand: std.Random, comptime w: u32) T(w)`

const std = @import("std");
const assert = std.debug.assert;
const Int = @import("kernels").Integer;
const selects = @import("selects.zig");
const values = @import("values.zig");
const Bit = values.Bit;
const T = values.T;
const W = values.W;
const Wide = values.Wide;
const anyX = values.anyX;
const asInt = selects.asInt;
const field = selects.field;
const join = selects.join;
const mask = values.mask;
const narrow = values.narrow;
const ones = values.ones;
const orX = values.orX;
const planesOf = values.planesOf;
const rep = selects.rep;
const rs = values.rs;
const sext = values.sext;
const top = values.top;
const two = values.two;
const wide = values.wide;
const words = values.words;
const wordsOf = values.wordsOf;
const xs = values.xs;

/// §5.1.10's binary bitwise operators, Tables 5-12 to 5-15.
pub const Bitwise = enum { @"and", @"or", xor, xnor };

/// §5.1.12's four shift operators.
pub const Shift = enum { left, right, arithmetic_left, arithmetic_right };

/// §5.1.7's four relational operators.
pub const Relational = enum { lt, le, gt, ge };

/// §5.1.8: logical (`==`, `!=`) and case (`===`, `!==`) equality.
pub const Equality = enum { eq, neq, case_eq, case_neq };

/// §5.1.11's six reduction operators.
pub const Reduction = enum { @"and", nand, @"or", nor, xor, xnor };

/// §5.1.9's binary logical operators `&&` and `||`.
pub const Logical = enum { @"and", @"or" };

/// §5.1.5's binary arithmetic operators but `**` (`pow`).
const Arith = enum { add, sub, mul, div, mod };

/// §5.1.10 Table 5-16 `~`: x and z bits invert to x.
pub inline fn not(a: anytype, comptime w: u32) T(w) {
    comptime assert(w >= 1);
    if (w <= 64) return .{ .v = (~a.v | a.x) & mask(w), .x = a.x };
    // `@Vector` for the reason `orX` gives.
    const V = @Vector(words(w), u64);
    var o: T(w) = .{ .v = ~@as(V, a.v) | @as(V, a.x), .x = a.x };
    o.v[words(w) - 1] &= top(w);
    return o;
}

/// Any unknown bit makes all of it x.
pub inline fn neg(a: anytype, comptime w: u32) T(w) {
    comptime assert(w >= 1);
    if (w > 64) return negWide(w, a);
    const unk = 0 -% @as(u64, @intFromBool(a.x != 0));
    return .{ .v = ((0 -% a.v) | unk) & mask(w), .x = unk & mask(w) };
}

/// `a op b` per bit (§5.1.10): a known 0 decides `&`, a known 1 decides
/// `|`, and any unknown bit makes `^`/`~^` x. Both operands already `w` wide.
pub inline fn bitwise(comptime op: Bitwise, a: anytype, b: @TypeOf(a), comptime w: u32) T(w) {
    comptime assert(w >= 1);
    if (w > 64) {
        var o: T(w) = undefined;
        for (&o.v, &o.x, a.v, a.x, b.v, b.x) |*ov, *ox, av, ax, bv, bx| {
            const r = bitwise(op, W{ .v = av, .x = ax }, W{ .v = bv, .x = bx }, 64);
            ov.* = r.v;
            ox.* = r.x;
        }
        o.v[words(w) - 1] &= top(w);
        return o;
    }
    return switch (op) {
        .@"and" => blk: {
            const x = (a.x | b.x) & (a.v | a.x) & (b.v | b.x);
            break :blk .{ .v = (a.v & b.v) | x, .x = x };
        },
        .@"or" => blk: {
            const x = (a.x | b.x) & ~((a.v & ~a.x) | (b.v & ~b.x));
            break :blk .{ .v = a.v | b.v | x, .x = x };
        },
        .xor => .{ .v = (a.v ^ b.v) | a.x | b.x, .x = a.x | b.x },
        .xnor => .{ .v = (~(a.v ^ b.v) | a.x | b.x) & mask(w), .x = a.x | b.x },
    };
}

/// `Literal.arithmetic` at one word: any unknown bit, and `/` or `%` by 0,
/// is all x (§5.1.5).
pub inline fn arith(comptime op: Arith, a: anytype, b: @TypeOf(a), comptime w: u32, comptime signed: bool) T(w) {
    comptime assert(w >= 1);
    if (w > 64) return switch (op) {
        .add, .sub => addWide(op == .sub, w, a, b),
        .mul => big(w, signed, a, b, w, signed, .multiply),
        .div => big(w, signed, a, b, w, signed, .divide),
        .mod => big(w, signed, a, b, w, signed, .remainder),
    };
    const av = if (signed) sext(a.v, w) else a.v;
    const bv = if (signed) sext(b.v, w) else b.v;
    const zero = (op == .div or op == .mod) and bv == 0;
    const unk = 0 -% @as(u64, @intFromBool((a.x | b.x) != 0 or zero));
    const d = bv | @intFromBool(bv == 0); // never divides by zero; `unk` covers it
    const r: u64 = switch (op) {
        .add => av +% bv,
        .sub => av -% bv,
        .mul => av *% bv,
        .div, .mod => if (!signed)
            (if (op == .div) av / d else av % d)
        else if (d == std.math.maxInt(u64))
            (if (op == .div) 0 -% av else 0)
        else
            @bitCast(if (op == .div) @divTrunc(@as(i64, @bitCast(av)), @as(i64, @bitCast(d))) else @rem(@as(i64, @bitCast(av)), @as(i64, @bitCast(d)))),
    };
    if (two) return .{ .v = r & ~unk & mask(w), .x = 0 };
    return .{ .v = (r | unk) & mask(w), .x = unk & mask(w) };
}

/// `Literal.power`: the base in context, the exponent self-determined
/// (§5.1.5 Table 5-6).
pub fn pow(a: anytype, comptime w: u32, comptime signed: bool, e: anytype, comptime ew: u32, comptime esigned: bool) T(w) {
    comptime assert(w >= 1);
    comptime assert(ew >= 1);
    if (w > 64 or ew > 64) return big(w, signed, a, e, ew, esigned, null);
    if (a.x != 0 or e.x != 0) return xs(w);
    const m = mask(w);
    const ev = e.v & mask(ew);
    if (ev == 0) return .{ .v = 1, .x = 0 };
    const negative = esigned and (ev >> (ew - 1)) & 1 == 1;
    const b = a.v & m;
    if (b == 0) return if (negative) xs(w) else .{ .v = 0, .x = 0 };
    if (b == 1 or (signed and b == m)) return .{ .v = if (b == 1 or ev & 1 == 0) 1 else m, .x = 0 };
    if (negative) return .{ .v = 0, .x = 0 };
    var result: u64 = 1;
    var base = b;
    var rest = ev;
    while (rest != 0) : (rest >>= 1) {
        if (rest & 1 == 1) result *%= base;
        base *%= base;
    }
    return .{ .v = result & m, .x = 0 };
}

/// `Literal.shift`: an unknown amount is all x; an amount of at least the
/// width leaves only the fill (§5.1.12).
pub inline fn shift(comptime op: Shift, a: anytype, comptime w: u32, comptime signed: bool, b: anytype) T(w) {
    comptime assert(w >= 1);
    if (comptime w > 64 or wordsOf(@TypeOf(b)) > 1) return shiftWide(op, w, signed, wide(a), wide(b));
    if (b.x != 0) return xs(w);
    const fill = op == .arithmetic_right and signed;
    if (b.v >= w) return if (fill)
        .{ .v = 0 -% ((a.v >> (w - 1)) & 1) & mask(w), .x = 0 -% ((a.x >> (w - 1)) & 1) & mask(w) }
    else
        .{ .v = 0, .x = 0 };
    const n: u6 = @intCast(b.v);
    return switch (op) {
        .left, .arithmetic_left => .{ .v = (a.v << n) & mask(w), .x = (a.x << n) & mask(w) },
        .right, .arithmetic_right => if (fill) .{
            .v = @as(u64, @bitCast(@as(i64, @bitCast(sext(a.v, w))) >> n)) & mask(w),
            .x = @as(u64, @bitCast(@as(i64, @bitCast(sext(a.x, w))) >> n)) & mask(w),
        } else .{ .v = a.v >> n, .x = a.x >> n },
    };
}

/// Any unknown bit makes the relation x (§5.1.7).
pub inline fn rel(comptime op: Relational, a: anytype, b: @TypeOf(a), comptime w: u32, comptime signed: bool) Bit {
    comptime assert(w >= 1);
    if (w > 64) return relWide(op, w, signed, a, b);
    if ((a.x | b.x) != 0) return .x;
    const ord = if (signed)
        std.math.order(@as(i64, @bitCast(sext(a.v, w))), @as(i64, @bitCast(sext(b.v, w))))
    else
        std.math.order(a.v, b.v);
    return if (switch (op) {
        .lt => ord == .lt,
        .le => ord != .gt,
        .gt => ord == .gt,
        .ge => ord != .lt,
    }) .one else .zero;
}

/// Both operands already in their common type (§5.1.8).
pub inline fn eq(comptime op: Equality, a: anytype, b: @TypeOf(a)) Bit {
    var different: u64 = 0;
    var unknown: u64 = 0;
    const sa = wide(a);
    const sb = wide(b);
    for (sa.v, sa.x, sb.v, sb.x) |av, ax, bv, bx| {
        different |= switch (op) {
            .case_eq, .case_neq => (av ^ bv) | (ax ^ bx),
            .eq, .neq => (av ^ bv) & ~(ax | bx),
        };
        unknown |= ax | bx;
    }
    const r: Bit = if (different != 0) .zero else switch (op) {
        .case_eq, .case_neq => .one,
        .eq, .neq => if (unknown != 0) .x else .one,
    };
    return if (op == .neq or op == .case_neq) invert(r) else r;
}

/// §5.1.11 Tables 5-17 to 5-19: one bit from every bit of the `w`-bit `a`; a
/// decisive known bit wins over x and z, else any unknown bit is x.
pub inline fn reduce(comptime op: Reduction, a: anytype, comptime w: u32) Bit {
    comptime assert(w >= 1);
    var zeros: u64 = 0;
    var known1: u64 = 0;
    var unknown: u64 = 0;
    var parity: u64 = 0;
    const s = wide(a);
    for (s.v, s.x, 0..) |v, x, i| {
        zeros |= ~(v | x) & (if (i == s.v.len - 1) top(w) else ones);
        known1 |= v & ~x;
        unknown |= x;
        parity ^= @popCount(v);
    }
    const r: Bit = switch (op) {
        .@"and", .nand => if (zeros != 0) .zero else if (unknown != 0) .x else .one,
        .@"or", .nor => if (known1 != 0) .one else if (unknown != 0) .x else .zero,
        .xor, .xnor => if (unknown != 0) .x else if (parity & 1 == 1) .one else .zero,
    };
    return switch (op) {
        .nand, .nor, .xnor => invert(r),
        else => r,
    };
}

/// §5.1.9: any known 1 makes it true, even beside x or z.
pub inline fn truth(a: anytype) Bit {
    var known1: u64 = 0;
    var unknown: u64 = 0;
    const s = wide(a);
    for (s.v, s.x) |v, x| {
        known1 |= v & ~x;
        unknown |= x;
    }
    return if (known1 != 0) .one else if (unknown != 0) .x else .zero;
}

/// §5.1.9 `!` of one truth: x and z are x.
pub inline fn invert(b: Bit) Bit {
    return switch (b) {
        .zero => .one,
        .one => .zero,
        .x, .z => .x,
    };
}

/// `Literal.logical` of two one-bit truths.
pub inline fn logical(comptime op: Logical, a: Bit, b: Bit) Bit {
    return switch (op) {
        .@"and" => if (a == .zero or b == .zero) .zero else if (a == .one and b == .one) .one else .x,
        .@"or" => if (a == .one or b == .one) .one else if (a == .zero and b == .zero) .zero else .x,
    };
}

/// §5.1.13 Table 5-21: under an ambiguous condition only matching known
/// bits survive. Both arms already in the context type.
pub inline fn cond(c: Bit, y: anytype, n: @TypeOf(y)) @TypeOf(y) {
    return switch (c) {
        .one => y,
        .zero => n,
        .x, .z => blk: {
            if (@FieldType(@TypeOf(y), "v") == u64) {
                const x = y.x | n.x | (y.v ^ n.v);
                break :blk .{ .v = y.v | x, .x = x };
            }
            var o: @TypeOf(y) = undefined;
            for (&o.v, &o.x, y.v, y.x, n.v, n.x) |*ov, *ox, yv, yx, nv, nx| {
                ox.* = yx | nx | (yv ^ nv);
                ov.* = yv | ox.*;
            }
            break :blk o;
        },
    };
}

/// Test oracle: every operator on `a`, `b` equals `Integer.Literal`'s.
pub fn check(comptime w: u32, comptime signed: bool, a: T(w), b: T(w)) !void {
    // Not `std.testing.allocator`: the arena frees everything anyway, and its
    // per-allocation stack capture is most of these tests' run time.
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const la = try lit(al, a, w, signed);
    const lb = try lit(al, b, w, signed);
    try same(try la.bitwiseNot(al), not(a, w));
    try same(try la.negate(al), neg(a, w));
    inline for (.{ .@"and", .@"or", .xor, .xnor }, .{ .and_bits, .or_bits, .xor_bits, .xnor_bits }) |op, iop|
        try same(try la.bitwise(al, iop, lb), bitwise(op, a, b, w));
    inline for (.{ .add, .sub, .mul, .div, .mod }, .{ .add, .subtract, .multiply, .divide, .remainder }) |op, iop|
        try same(try la.arithmetic(al, iop, lb), arith(op, a, b, w, signed));
    inline for (.{ .left, .right, .arithmetic_left, .arithmetic_right }) |op|
        try same(try la.shift(al, @field(Int.Shift, @tagName(op)), lb), shift(op, a, w, signed, b));
    try same(try la.power(al, lb), pow(a, w, signed, b, w, signed));
    inline for (.{ .lt, .le, .gt, .ge }, .{ .less, .less_equal, .greater, .greater_equal }) |op, iop|
        try std.testing.expectEqual(bitOf(la.relational(iop, lb)), rel(op, a, b, w, signed));
    inline for (.{ .eq, .neq, .case_eq, .case_neq }, .{ .equal, .not_equal, .case_equal, .case_not_equal }) |op, iop|
        try std.testing.expectEqual(bitOf(la.equality(iop, lb)), eq(op, a, b));
    inline for (.{ .@"and", .nand, .@"or", .nor, .xor, .xnor }, .{ .and_bits, .nand_bits, .or_bits, .nor_bits, .xor_bits, .xnor_bits }) |op, iop|
        try std.testing.expectEqual(bitOf(la.reduce(iop)), reduce(op, a, w));
    try std.testing.expectEqual(bitOf(la.truth()), truth(a));
    try same(try la.conditional(al, la, lb), cond(truth(a), a, b));
    inline for (.{ 1, w, w + 3, 63, 64, 65, 130 }) |to| {
        try same(try la.resize(al, to, if (signed) .sign else .zero), rs(a, w, to, signed));
    }
    try same(try Int.Literal.concatenate(al, &.{ la, lb }), join(a, w, b, w));
    try same(try la.replicate(al, 3), rep(a, w, 3));
    try std.testing.expectEqual(if (w > 64) null else la.asInt(), asInt(a, w, signed));
}

/// Test generator: a random `w`-bit four-state value.
pub fn randomW(rand: std.Random, comptime w: u32) T(w) {
    // Mostly known, so arithmetic is exercised past its all-x early exit.
    var o: Wide(words(w)) = undefined;
    const known = rand.uintLessThan(u8, 3) != 0;
    for (&o.v, &o.x) |*v, *x| {
        v.* = rand.int(u64);
        x.* = if (known) 0 else rand.int(u64);
    }
    o.v[words(w) - 1] &= top(w);
    o.x[words(w) - 1] &= top(w);
    return narrow(w, o);
}

// ---- private ----

fn negWide(comptime w: u32, a: T(w)) T(w) {
    comptime assert(w >= 1);
    var r: [words(w)]u64 = undefined;
    var borrow: u1 = 0;
    for (&r, a.v) |*d, v| {
        const s = @subWithOverflow(0, v);
        const t = @subWithOverflow(s[0], borrow);
        d.* = t[0];
        borrow = s[1] | t[1];
    }
    return orX(w, r, anyX(a));
}

/// A carry (or borrow) chain: `+` and `-` at any width wrap the same way
/// signed or not.
fn addWide(comptime sub: bool, comptime w: u32, a: T(w), b: T(w)) T(w) {
    comptime assert(w >= 1);
    var r: [words(w)]u64 = undefined;
    var c: u1 = 0;
    for (&r, a.v, b.v) |*d, av, bv| {
        const s = if (sub) @subWithOverflow(av, bv) else @addWithOverflow(av, bv);
        const t = if (sub) @subWithOverflow(s[0], c) else @addWithOverflow(s[0], c);
        d.* = t[0];
        c = s[1] | t[1];
    }
    return orX(w, r, anyX(a) or anyX(b));
}

/// `Integer.Literal`'s operator itself, for the wide `* / % **`: rare, and
/// already exact at every width.
fn big(comptime w: u32, comptime signed: bool, a: anytype, b: anytype, comptime bw: u32, comptime bsigned: bool, comptime op: ?Int.Arithmetic) T(w) {
    comptime assert(w >= 1);
    comptime assert(bw >= 1);
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    var pa = planesOf(a);
    var pb = planesOf(b);
    const la: Int.Literal = .{ .width = w, .signed = signed, .sized = true, .planes = &pa };
    const lb: Int.Literal = .{ .width = bw, .signed = bsigned, .sized = true, .planes = &pb };
    const r = (if (op) |o| la.arithmetic(arena.allocator(), o, lb) else la.power(arena.allocator(), lb)) catch @panic("out of memory");
    var o: Wide(words(w)) = undefined;
    @memcpy(&o.v, r.values()[0..words(w)]);
    @memcpy(&o.x, r.unknowns()[0..words(w)]);
    if (two) for (&o.v, &o.x) |*v, *x| {
        v.* &= ~x.*;
        x.* = 0;
    };
    return narrow(w, o);
}

fn shiftWide(comptime op: Shift, comptime w: u32, comptime signed: bool, a: Wide(words(w)), b: anytype) T(w) {
    comptime assert(w >= 1);
    if (anyX(b)) return xs(w);
    var hi: u64 = 0;
    for (b.v[1..]) |v| hi |= v;
    // `Literal.shift`: an amount of at least the width leaves only the fill.
    const amount: u32 = if (hi != 0) w else @intCast(@min(b.v[0], w));
    const fill = op == .arithmetic_right and signed;
    const n = comptime words(w);
    const sb: u6 = (w - 1) % 64;
    var o: Wide(n) = undefined;
    inline for (.{ &o.v, &o.x }, .{ a.v, a.x }) |out, src_| {
        var src = src_;
        const f: u64 = if (fill) 0 -% ((src[n - 1] >> sb) & 1) else 0;
        src[n - 1] |= f & ~top(w);
        const q = amount / 64;
        const bs: u6 = @intCast(amount % 64);
        for (out, 0..) |*d, i| {
            if (op == .left or op == .arithmetic_left) {
                d.* = if (i >= q) src[i - q] << bs else 0;
                if (bs != 0 and i > q) d.* |= src[i - q - 1] >> @intCast(64 - @as(u7, bs));
            } else {
                const lo = if (i + q < n) src[i + q] else f;
                const up_ = if (i + q + 1 < n) src[i + q + 1] else f;
                d.* = lo >> bs;
                if (bs != 0) d.* |= up_ << @intCast(64 - @as(u7, bs));
            }
        }
        out[n - 1] &= top(w);
    }
    return narrow(w, o);
}

/// Word order from the top, the sign bit biased so unsigned order is
/// two's-complement order (`Literal.relational`).
fn relWide(comptime op: Relational, comptime w: u32, comptime signed: bool, a: T(w), b: T(w)) Bit {
    comptime assert(w >= 1);
    if (anyX(a) or anyX(b)) return .x;
    var lt: u1 = 0;
    var gt: u1 = 0;
    var decided: u1 = 0;
    var i: usize = words(w);
    while (i > 0) {
        i -= 1;
        const bias: u64 = if (signed and i == words(w) - 1) @as(u64, 1) << ((w - 1) % 64) else 0;
        const av = a.v[i] ^ bias;
        const bv = b.v[i] ^ bias;
        lt |= ~decided & @intFromBool(av < bv);
        gt |= ~decided & @intFromBool(av > bv);
        decided |= @intFromBool(av != bv);
    }
    return if (switch (op) {
        .lt => lt == 1,
        .le => gt == 0,
        .gt => gt == 1,
        .ge => lt == 0,
    }) .one else .zero;
}

fn lit(a: std.mem.Allocator, v: anytype, w: u32, signed: bool) !Int.Literal {
    return .{ .width = w, .sized = true, .signed = signed, .planes = try a.dupe(u64, &planesOf(v)) };
}

fn same(want: Int.Literal, got: anytype) !void {
    const g = wide(got);
    try std.testing.expectEqualSlices(u64, want.values(), &g.v);
    try std.testing.expectEqualSlices(u64, want.unknowns(), &g.x);
}

fn bitOf(b: Int.Bit) Bit {
    return @fromBackingInt(@intCast(@backingInt(b)));
}

/// A known amount below `n`, as a `w`-bit value.
fn small(rand: std.Random, comptime w: u32, n: u64) T(w) {
    return rs(W{ .v = rand.uintLessThan(u64, n) & mask(@min(w, 64)), .x = 0 }, @min(w, 64), w, false);
}

fn kleene(b: Bit) u2 {
    return switch (b) {
        .zero => 0,
        .x, .z => 1,
        .one => 2,
    };
}

fn fromKleene(level: u2) Bit {
    return switch (level) {
        0 => .zero,
        1 => .x,
        2 => .one,
        3 => unreachable,
    };
}

test "every kernel equals Integer.Literal: all 4^w operand pairs for w in 1..3" {
    inline for (.{ 1, 2, 3 }) |w| inline for (.{ false, true }) |signed| {
        const n: u64 = @as(u64, 1) << (2 * w);
        for (0..n) |i| for (0..n) |j| {
            const a: W = .{ .v = i & mask(w), .x = (i >> w) & mask(w) };
            const b: W = .{ .v = j & mask(w), .x = (j >> w) & mask(w) };
            try check(w, signed, a, b);
        };
    };
}

test "every kernel equals Integer.Literal: random words at block-boundary widths" {
    var prng = std.Random.DefaultPrng.init(0x1364);
    const rand = prng.random();
    inline for (.{ 5, 31, 32, 33, 63, 64 }) |w| inline for (.{ false, true }) |signed| {
        for (0..2000) |_| try check(w, signed, randomW(rand, w), randomW(rand, w));
        // Small shift amounts and exponents, which random words never are.
        for (0..500) |_| try check(w, signed, randomW(rand, w), small(rand, w, w + 2));
    };
}

test "every kernel equals Integer.Literal: random multi-word values" {
    var prng = std.Random.DefaultPrng.init(0x1365);
    const rand = prng.random();
    inline for (.{ 65, 100, 127, 128, 129, 130, 200, 256 }) |w| inline for (.{ false, true }) |signed| {
        for (0..400) |_| try check(w, signed, randomW(rand, w), randomW(rand, w));
        for (0..200) |_| try check(w, signed, randomW(rand, w), small(rand, w, w + 2));
        // Equal high words, so comparison reaches the low ones.
        for (0..200) |_| {
            const a = randomW(rand, w);
            var b = a;
            b.v[0] = rand.int(u64);
            try check(w, signed, a, b);
        }
    };
}

test "a shift of a one-word value by a multi-word amount, and back" {
    var prng = std.Random.DefaultPrng.init(0x5112);
    const rand = prng.random();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    inline for (.{ .{ 8, 100 }, .{ 64, 65 }, .{ 130, 7 } }) |ww| for (0..500) |_| {
        const a = randomW(rand, ww[0]);
        const b = if (rand.boolean()) randomW(rand, ww[1]) else small(rand, ww[1], ww[0] + 2);
        const la = try lit(al, a, ww[0], true);
        const lb = try lit(al, b, ww[1], false);
        inline for (.{ .left, .right, .arithmetic_left, .arithmetic_right }) |op|
            try same(try la.shift(al, @field(Int.Shift, @tagName(op)), lb), shift(op, a, ww[0], true, b));
        try same(try la.power(al, lb), pow(a, ww[0], true, b, ww[1], false));
    };
}

test "&&, || and ! are Kleene's three-valued logic over 0, 1 and unknown (§5.1.9)" {
    const bits = [_]Bit{ .zero, .one, .z, .x };
    for (bits) |a| for (bits) |b| {
        // Kleene: 0, 1/2 for x or z, 1; `and` is the minimum, `or` the maximum.
        const ka = kleene(a);
        const kb = kleene(b);
        try std.testing.expectEqual(fromKleene(@min(ka, kb)), logical(.@"and", a, b));
        try std.testing.expectEqual(fromKleene(@max(ka, kb)), logical(.@"or", a, b));
    };
    for (bits) |a| try std.testing.expectEqual(fromKleene(2 - kleene(a)), invert(a));
}
