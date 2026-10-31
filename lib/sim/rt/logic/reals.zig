//! A real operand in, its integral value out, and back: the conversions and real operators of a native executable.
//! Cites: IEEE 1364-2005 §4.8.2 (conversion), §17.8 ($rtoi, $itor).
//!
//! Contents:
//! - `pub inline fn toReal(a: anytype, comptime w: u32, comptime signed: bool) f64`
//! - `pub fn wordsToReal(v: []const u64, x: []const u64, width: u32, signed: bool) f64`
//! - `pub inline fn ofReal(r: f64) W`
//! - `pub fn ofRealTo(r: f64, comptime to: u32) T(to)`
//! - `pub inline fn rtoi(r: f64) W`
//! - `pub inline fn itorReal(r: f64) f64`
//! - `pub inline fn realBits(r: f64) W`
//! - `pub inline fn real(a: W) f64`
//! - `pub inline fn word0(a: anytype) u64`
//! - `pub inline fn realCond(c: Bit, y: f64, n: f64) f64`
//! - `pub inline fn realTruth(r: f64) Bit`

const std = @import("std");
const assert = std.debug.assert;
const Int = @import("kernels").Integer;
const operators = @import("operators.zig");
const selects = @import("selects.zig");
const values = @import("values.zig");
const Bit = values.Bit;
const T = values.T;
const W = values.W;
const bit = selects.bit;
const low = values.low;
const narrow = values.narrow;
const neg = operators.neg;
const ones = values.ones;
const sext = values.sext;
const top = values.top;
const wide = values.wide;
const words = values.words;
const xs = values.xs;

/// §4.8.2 integer to real (`evaluate.realOfInt`): the value read by its own
/// signedness, each x or z bit as 0.
pub inline fn toReal(a: anytype, comptime w: u32, comptime signed: bool) f64 {
    comptime assert(w >= 1);
    const lo = wide(a).v[0] & ~wide(a).x[0];
    if (w <= 64) return if (signed) @floatFromInt(@as(i64, @bitCast(sext(lo, w)))) else @floatFromInt(lo);
    return wordsToReal(&wide(a).v, &wide(a).x, w, signed);
}

/// §4.8.2 integer to real at any width: the `width`-bit value in `v` (bits
/// set in `x` read as 0), by its signedness, rounded once to nearest even
/// (C's conversion; iverilog converts pr2913404's 2^64 exactly); +-inf past
/// the f64 range.
pub fn wordsToReal(v: []const u64, x: []const u64, width: u32, signed: bool) f64 {
    const Mag = struct {
        v: []const u64,
        x: []const u64,
        width: u32,
        neg: bool = false,
        /// The lowest nonzero word: a negative value's two's complement is
        /// 0 below it, -b at it and ~b above it.
        low: usize = 0,
        fn raw(m: @This(), i: usize) u64 {
            const b = m.v[i] & ~m.x[i];
            return if (i == words(m.width) - 1 and m.width % 64 != 0) b & ((@as(u64, 1) << @intCast(m.width % 64)) - 1) else b;
        }
        fn get(m: @This(), i: usize) u64 {
            if (!m.neg) return m.raw(i);
            const r = if (i < m.low) 0 else if (i == m.low) 0 -% m.raw(i) else ~m.raw(i);
            return if (i == words(m.width) - 1 and m.width % 64 != 0) r & ((@as(u64, 1) << @intCast(m.width % 64)) - 1) else r;
        }
    };
    const n = words(width);
    var mag: Mag = .{ .v = v, .x = x, .width = width };
    mag.neg = signed and (mag.raw(n - 1) >> @intCast((width - 1) % 64)) & 1 != 0;
    if (mag.neg) mag.low = for (0..n) |i| {
        if (mag.raw(i) != 0) break i;
    } else n;
    var t: usize = n;
    while (t > 0 and mag.get(t - 1) == 0) t -= 1;
    if (t == 0) return 0;
    const hi = mag.get(t - 1);
    const lead: u32 = 63 - @clz(hi);
    const msb: u32 = @as(u32, @intCast(t - 1)) * 64 + lead;
    const r: f64 = if (msb < 64) @floatFromInt(hi) else blk: {
        // The 64 bits from the msb down, and a sticky bit for any lower one,
        // so the one rounding to 53 bits is the exact value's.
        const sh: u32 = 63 - lead;
        const next = mag.get(t - 2);
        var top64 = if (sh == 0) hi else (hi << @intCast(sh)) | (next >> @intCast(64 - sh));
        var sticky = (if (sh == 0) next else next << @intCast(sh)) != 0;
        for (0..t - 2) |i| sticky = sticky or mag.get(i) != 0;
        if (sticky) top64 |= 1;
        break :blk std.math.ldexp(@as(f64, @floatFromInt(top64)), @intCast(msb - 63));
    };
    return if (mag.neg) -r else r;
}

/// §4.8.2 real to integer (`evaluate.intOfReal`): rounded to nearest, halves
/// away from zero, as a 64-bit signed value; x when no such integer exists.
pub inline fn ofReal(r: f64) W {
    const t = @round(r);
    // NaN fails both compares.
    if (!(t >= -0x1p63 and t < 0x1p63)) return xs(64);
    return .{ .v = @bitCast(@as(i64, @intFromFloat(t))), .x = 0 };
}

/// §4.8.2 real to a `to`-bit integer (`evaluate.intOfReal`, then the
/// assignment's truncation): rounded to nearest, halves away from zero, mod
/// 2^to, at any magnitude; x when no such integer exists.
pub fn ofRealTo(r: f64, comptime to: u32) T(to) {
    const n = @round(r);
    if (!std.math.isFinite(n)) return xs(to);
    var v: [words(to)]u64 = @splat(0);
    if (n >= -0x1p63 and n < 0x1p63) {
        const i: i64 = @intFromFloat(n);
        for (&v, 0..) |*w, j| w.* = if (j == 0) @bitCast(i) else if (i < 0) ones else 0;
    } else {
        // An f64 this large is its 53-bit significand shifted left.
        const fr = std.math.frexp(@abs(n));
        const mant: u64 = @intFromFloat(std.math.ldexp(fr.significand, 53));
        const by: u32 = @intCast(fr.exponent - 53);
        const at = by / 64;
        const b: u6 = @intCast(by % 64);
        if (at < v.len) v[at] |= mant << b;
        if (b != 0 and at + 1 < v.len) v[at + 1] |= mant >> @intCast(64 - @as(u7, b));
        if (n < 0) {
            var carry: u1 = 1;
            for (&v) |*w| {
                const sum = @addWithOverflow(~w.*, @as(u64, carry));
                w.* = sum[0];
                carry = sum[1];
            }
        }
    }
    v[v.len - 1] &= top(to);
    return narrow(to, .{ .v = v, .x = @splat(0) });
}

/// §17.8 `$rtoi`: truncated toward zero, a 32-bit signed value, the low 32
/// bits of a larger one (iverilog's itor_rtoi, VD-130); x for an infinity
/// or a NaN.
pub inline fn rtoi(r: f64) W {
    return ofRealTo(@trunc(r), 32);
}

/// §17.8 `$itor` of a real argument (VD-130): the argument converts to an
/// integer first (§4.8.2's rounding), and one with no integer is x, which
/// `$itor` reads as 0.
pub inline fn itorReal(r: f64) f64 {
    const n = @round(r);
    return if (std.math.isFinite(n)) n else 0;
}

/// A real as the 64-bit value a real slot holds: its IEEE 754 bits.
pub inline fn realBits(r: f64) W {
    return .{ .v = @bitCast(r), .x = 0 };
}

/// The real a real slot's value holds.
pub inline fn real(a: W) f64 {
    return @bitCast(a.v);
}

/// The least significant word of `a`'s value plane (`$bitstoreal`).
pub inline fn word0(a: anytype) u64 {
    return wide(a).v[0];
}

/// §5.1.13 a real `?:` under an x or z condition is always zero, after
/// both arms have been evaluated (`evaluate.evalReal`).
pub inline fn realCond(c: Bit, y: f64, n: f64) f64 {
    return switch (c) {
        .one => y,
        .zero => n,
        .x, .z => 0,
    };
}

/// A real's truth (§9.4): not zero.
pub inline fn realTruth(r: f64) Bit {
    return if (r != 0) .one else .zero;
}

test "real to integer rounds half away from zero; one with no 64-bit integer is x (§4.8.2)" {
    const of = struct {
        fn int(i: i64) W {
            return .{ .v = @bitCast(i), .x = 0 };
        }
    }.int;
    try std.testing.expectEqual(of(36), ofReal(35.5));
    try std.testing.expectEqual(of(-2), ofReal(-1.5));
    try std.testing.expectEqual(of(1), ofReal(0.5));
    try std.testing.expectEqual(of(-1), ofReal(-0.5));
    try std.testing.expectEqual(of(0), ofReal(0.49999999999999994));
    // The largest binary64 below 2^63.
    try std.testing.expectEqual(of(0x7fff_ffff_ffff_fc00), ofReal(0x1p63 - 1024));
    // -2^63 is an i64 (§4.8.2).
    try std.testing.expectEqual(of(std.math.minInt(i64)), ofReal(-0x1p63));
    const x64: W = .{ .v = std.math.maxInt(u64), .x = std.math.maxInt(u64) };
    for ([_]f64{ 0x1p63, std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64) }) |r|
        try std.testing.expectEqual(x64, ofReal(r));
}

test "$rtoi truncates toward zero into 32 bits, the low 32 of a larger value; inf and NaN are x (§17.8, VD-130)" {
    try std.testing.expectEqual(W{ .v = 2, .x = 0 }, rtoi(2.9));
    try std.testing.expectEqual(W{ .v = 0xffff_fffe, .x = 0 }, rtoi(-2.9));
    try std.testing.expectEqual(W{ .v = 0x7fff_ffff, .x = 0 }, rtoi(2147483647.9));
    // -2^31 is an i32, and so is what truncates to it.
    try std.testing.expectEqual(W{ .v = 0x8000_0000, .x = 0 }, rtoi(-0x1p31));
    try std.testing.expectEqual(W{ .v = 0x8000_0000, .x = 0 }, rtoi(-2147483648.9));
    const x32: W = .{ .v = 0xffff_ffff, .x = 0xffff_ffff };
    for ([_]f64{ std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64) }) |r|
        try std.testing.expectEqual(x32, rtoi(r));
    // Oracle: iverilog's itor_rtoi gold (Overflow(0) = 0, Overflow(1) = 1).
    try std.testing.expectEqual(W{ .v = 0x8000_0000, .x = 0 }, rtoi(0x1p31));
    try std.testing.expectEqual(W{ .v = 1, .x = 0 }, rtoi(0x1p32 + 1));
    try std.testing.expectEqual(W{ .v = 0x7fff_ffff, .x = 0 }, rtoi(-2147483649.0));
    try std.testing.expectEqual(@as(f64, -2), itorReal(-1.5));
    try std.testing.expectEqual(@as(f64, 0), itorReal(std.math.nan(f64)));
}

test "integer to real reads the operand's own signedness, x and z bits as 0 (§4.8.2)" {
    try std.testing.expectEqual(@as(f64, -1), toReal(W{ .v = 0xff, .x = 0 }, 8, true));
    try std.testing.expectEqual(@as(f64, 255), toReal(W{ .v = 0xff, .x = 0 }, 8, false));
    // 2'b1x: the x bit is 0, so 2.
    try std.testing.expectEqual(@as(f64, 2), toReal(W{ .v = 0b11, .x = 0b01 }, 2, false));
    // 4'bx000 signed: its sign bit is x, read as 0.
    try std.testing.expectEqual(@as(f64, 0), toReal(W{ .v = 0b1000, .x = 0b1000 }, 4, true));
    // A real slot's bits round-trip.
    try std.testing.expectEqual(@as(f64, -0.0), real(realBits(-0.0)));
    try std.testing.expect(std.math.signbit(real(realBits(-0.0))));
    // A real `?:` under an unknown condition is 0 (§5.1.13); a real's truth
    // is "not zero", -0.0 included.
    try std.testing.expectEqual(@as(f64, 0), realCond(.x, 1, 2));
    try std.testing.expectEqual(@as(f64, 0), realCond(.z, 1, 2));
    try std.testing.expectEqual(@as(f64, 1), realCond(.one, 1, 2));
    try std.testing.expectEqual(@as(f64, 2), realCond(.zero, 1, 2));
    try std.testing.expectEqual(Bit.zero, realTruth(-0.0));
    try std.testing.expectEqual(Bit.one, realTruth(1e-300));
}

test wordsToReal {
    // 2^64 and -2^64 as 65-bit values (pr2913404), and a sticky bit that
    // breaks a tie: 2^64 + 2^11 + 1 rounds up to 2^64 + 2^12.
    try std.testing.expectEqual(@as(f64, 0x1p64), wordsToReal(&.{ 0, 1 }, &.{ 0, 0 }, 65, false));
    try std.testing.expectEqual(@as(f64, -0x1p64), wordsToReal(&.{ 0, 1 }, &.{ 0, 0 }, 65, true));
    try std.testing.expectEqual(@as(f64, 0x1p64 + 0x1p12), wordsToReal(&.{ 0x801, 1 }, &.{ 0, 0 }, 65, false));
    try std.testing.expectEqual(@as(f64, 0x1p64), wordsToReal(&.{ 0x800, 1 }, &.{ 0, 0 }, 65, false));
    // -1 at 128 bits, and x bits read as 0.
    try std.testing.expectEqual(@as(f64, -1), wordsToReal(&.{ ones, ones }, &.{ 0, 0 }, 128, true));
    try std.testing.expectEqual(@as(f64, 0x1p64), wordsToReal(&.{ 5, 1 }, &.{ 5, 0 }, 100, false));
    // Past the f64 range.
    var huge: [17]u64 = @splat(0);
    huge[16] = 1;
    try std.testing.expect(std.math.isInf(wordsToReal(&huge, &@as([17]u64, @splat(0)), 1088, false)));
}
