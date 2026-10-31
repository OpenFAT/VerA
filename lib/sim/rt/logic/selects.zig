//! A vector and an index in, its bit-select, part-select, concatenation or case match out, and a selected value placed back.
//! Cites: IEEE 1364-2005 §5.2.1 (packed selects), §5.1.14 (concatenation), §9.5.1 (casez/casex), §17.11 ($clog2).
//!
//! Contents:
//! - `pub const CaseKind = enum`
//! - `pub inline fn join(hi: anytype, comptime hw: u32, lo: anytype, comptime lw: u32) T(hw + lw)`
//! - `pub inline fn asInt(a: anytype, comptime w: u32, comptime signed: bool) ?i64`
//! - `pub inline fn asIndex(a: anytype, comptime w: u32, comptime signed: bool) ?i128`
//! - `pub inline fn bitAt(a: anytype, index: ?i128, comptime msb: i64, comptime lsb: i64, comptime w: u32) W`
//! - `pub inline fn selectShift(index: ?i128, comptime msb: i64, comptime lsb: i64, comptime count: u32, comptime ascending: bool) ?i64`
//! - `pub inline fn partAt(a: anytype, shift_: ?i64, comptime count: u32, comptime sw: u32) T(count)`
//! - `pub inline fn part(a: anytype, shift_: i64, comptime count: u32, comptime sw: u32) T(count)`
//! - `pub fn field(shift_: i64, comptime count: u32, comptime sw: u32) M(sw)`
//! - `pub inline fn place(a: anytype, shift_: i64, comptime count: u32, comptime sw: u32) T(sw)`
//! - `pub inline fn up(a: W, p: u32, comptime sw: u32) T(sw)`
//! - `pub inline fn bit(p: u32, comptime sw: u32) M(sw)`
//! - `pub inline fn pos(index: ?i128, comptime msb: i64, comptime lsb: i64, comptime w: u32) ?u32`
//! - `pub inline fn rep(a: anytype, comptime w: u32, comptime count: u32) T(w * count)`
//! - `pub inline fn clog2(a: anytype, comptime w: u32) u64`
//! - `pub inline fn caseMatch(comptime kind: CaseKind, a: anytype, b: @TypeOf(a)) bool`

const std = @import("std");
const assert = std.debug.assert;
const Int = @import("kernels").Integer;
const operators = @import("operators.zig");
const values = @import("values.zig");
const M = values.M;
const T = values.T;
const W = values.W;
const Wide = values.Wide;
const anyX = values.anyX;
const eq = operators.eq;
const funnel = values.funnel;
const k = values.k;
const mask = values.mask;
const narrow = values.narrow;
const ones = values.ones;
const orAt = values.orAt;
const planesOf = values.planesOf;
const randomW = operators.randomW;
const rs = values.rs;
const sext = values.sext;
const span = values.span;
const top = values.top;
const two = values.two;
const wide = values.wide;
const words = values.words;
const xs = values.xs;

/// §9.5 `case` and §9.5.1's `casez` and `casex`.
pub const CaseKind = enum { normal, casez, casex };

/// `{hi, lo}`, `hi` being `hw` bits wide and `lo` `lw`.
pub inline fn join(hi: anytype, comptime hw: u32, lo: anytype, comptime lw: u32) T(hw + lw) {
    if (hw + lw <= 64) return .{ .v = hi.v << lw | lo.v, .x = hi.x << lw | lo.x };
    var o: Wide(words(hw + lw)) = .{ .v = @splat(0), .x = @splat(0) };
    const sl = wide(lo);
    const sh = wide(hi);
    orAt(&o.v, &sl.v, 0);
    orAt(&o.x, &sl.x, 0);
    orAt(&o.v, &sh.v, lw);
    orAt(&o.x, &sh.x, lw);
    return o;
}

/// The integer a self-determined index reads as, or null when it has an
/// unknown bit or is wider than 64 bits (`Literal.asInt`).
pub inline fn asInt(a: anytype, comptime w: u32, comptime signed: bool) ?i64 {
    comptime assert(w >= 1);
    if (w > 64) return null;
    if (a.x != 0) return null;
    return @bitCast(if (signed) sext(a.v, w) else a.v);
}

/// The full numeric index, retaining bases just outside an i64 declaration
/// for partially overlapping indexed selects. Shared with the interpreter.
pub inline fn asIndex(a: anytype, comptime w: u32, comptime signed: bool) ?i128 {
    comptime assert(w >= 1);
    var planes = planesOf(a);
    const literal: Int.Literal = .{ .width = w, .signed = signed, .sized = true, .planes = &planes };
    return literal.asIndex();
}

/// `exec.position` then `readSelect` of one bit: bit `index` of a vector
/// declared `[msb:lsb]`, x when the index is x/z or outside it (§5.2.1).
pub inline fn bitAt(a: anytype, index: ?i128, comptime msb: i64, comptime lsb: i64, comptime w: u32) W {
    comptime assert(w >= 1);
    const p = pos(index, msb, lsb, w) orelse return xs(1);
    const s = wide(a);
    const n: u6 = @intCast(p % 64);
    return .{ .v = (s.v[p / 64] >> n) & 1, .x = (s.x[p / 64] >> n) & 1 };
}

/// The least-significant storage position of an indexed part-select.
/// `+:` ascends declared indices and `-:` descends them (§5.2.1); the
/// declaration determines which selected end is least significant.
pub inline fn selectShift(index: ?i128, comptime msb: i64, comptime lsb: i64, comptime count: u32, comptime ascending: bool) ?i64 {
    const i = index orelse return null;
    const p = if (msb >= lsb) i -| lsb else lsb -| i;
    return std.math.lossyCast(i64, if ((msb >= lsb) == ascending) p else p -| (count - 1));
}

/// A runtime part-select, all x for an x/z base (§5.2.1).
pub inline fn partAt(a: anytype, shift_: ?i64, comptime count: u32, comptime sw: u32) T(count) {
    return part(a, shift_ orelse return xs(count), count, sw);
}

/// A constant or runtime part-select of an `sw`-bit vector:
/// bit i of the `count`-bit result is bit `i + shift` of `a` where that bit
/// exists, else x (§5.2.1).
pub inline fn part(a: anytype, shift_: i64, comptime count: u32, comptime sw: u32) T(count) {
    if (shift_ >= sw or shift_ <= -@as(i64, count)) return xs(count);
    const lo: i64 = @max(0, -shift_);
    const hi: i64 = @min(count, @as(i64, sw) - shift_);
    if (count > 64 or sw > 64) {
        const s = wide(a);
        var o: Wide(words(count)) = undefined;
        for (&o.v, &o.x, 0..) |*v, *x, j| {
            const at = shift_ + @as(i64, @intCast(64 * j));
            const valid = span(j, lo, hi);
            const holes = if (two) 0 else ~valid & (if (j == words(count) - 1) top(count) else ones);
            v.* = (funnel(&s.v, at) & valid) | holes;
            x.* = (funnel(&s.x, at) & valid) | holes;
        }
        return narrow(count, o);
    }
    const valid = span(0, lo, hi);
    const v = if (shift_ >= 64 or shift_ <= -64) 0 else if (shift_ >= 0) a.v >> @intCast(shift_) else a.v << @intCast(-shift_);
    const x = if (shift_ >= 64 or shift_ <= -64) 0 else if (shift_ >= 0) a.x >> @intCast(shift_) else a.x << @intCast(-shift_);
    const holes = if (two) 0 else ~valid & mask(count);
    return .{ .v = (v & valid) | holes, .x = (x & valid) | holes };
}

/// The slot bits a part-select of `count` bits at `shift` names
/// in an `sw`-bit vector: the mask `place`'s value is stored under.
pub fn field(shift_: i64, comptime count: u32, comptime sw: u32) M(sw) {
    if (shift_ >= sw or shift_ <= -@as(i64, count)) return std.mem.zeroes(M(sw));
    const lo: i64 = @max(0, shift_);
    const hi: i64 = @min(sw, shift_ + count);
    if (sw <= 64) return span(0, lo, hi);
    var m: [words(sw)]u64 = undefined;
    for (&m, 0..) |*w, j| w.* = span(j, lo, hi);
    return m;
}

/// The inverse of `part` for an assignment: `a`'s `count` bits placed at
/// `shift` in an `sw`-bit vector, zero outside `field`.
pub inline fn place(a: anytype, shift_: i64, comptime count: u32, comptime sw: u32) T(sw) {
    if (shift_ >= sw or shift_ <= -@as(i64, count)) return std.mem.zeroes(T(sw));
    const m = field(shift_, count, sw);
    if (count > 64 or sw > 64) {
        const s = wide(a);
        var o: Wide(words(sw)) = undefined;
        for (&o.v, &o.x, 0..) |*v, *x, j| {
            const at = @as(i64, @intCast(64 * j)) - shift_;
            const fm = if (sw <= 64) m else m[j];
            v.* = funnel(&s.v, at) & fm;
            x.* = funnel(&s.x, at) & fm;
        }
        return narrow(sw, o);
    }
    const v = if (shift_ >= 64 or shift_ <= -64) 0 else if (shift_ >= 0) a.v << @intCast(shift_) else a.v >> @intCast(-shift_);
    const x = if (shift_ >= 64 or shift_ <= -64) 0 else if (shift_ >= 0) a.x << @intCast(shift_) else a.x >> @intCast(-shift_);
    return .{ .v = v & m, .x = x & m };
}

/// The one-bit `a` moved up to bit `p` of an `sw`-bit vector: a runtime
/// bit-select's value.
pub inline fn up(a: W, p: u32, comptime sw: u32) T(sw) {
    if (sw <= 64) return .{ .v = a.v << @intCast(p), .x = a.x << @intCast(p) };
    var o: T(sw) = .{ .v = @splat(0), .x = @splat(0) };
    o.v[p / 64] = a.v << @intCast(p % 64);
    o.x[p / 64] = a.x << @intCast(p % 64);
    return o;
}

/// Bit `p` alone of an `sw`-bit vector: a runtime bit-select's mask.
pub inline fn bit(p: u32, comptime sw: u32) M(sw) {
    if (sw <= 64) return @as(u64, 1) << @intCast(p);
    var m: M(sw) = @splat(0);
    m[p / 64] = @as(u64, 1) << @intCast(p % 64);
    return m;
}

/// The bit position a runtime bit-select names, or null (`exec.position`).
pub inline fn pos(index: ?i128, comptime msb: i64, comptime lsb: i64, comptime w: u32) ?u32 {
    comptime assert(w >= 1);
    const i = index orelse return null;
    const p = if (msb >= lsb) i -| lsb else lsb -| i;
    return if (p < 0 or p >= w) null else @intCast(p);
}

/// §5.1.14 `{count{a}}`.
pub inline fn rep(a: anytype, comptime w: u32, comptime count: u32) T(w * count) {
    if (w * count <= 64) {
        var out: W = .{ .v = 0, .x = 0 };
        inline for (0..count) |i| {
            out.v |= a.v << (i * w);
            out.x |= a.x << (i * w);
        }
        return out;
    }
    var o: Wide(words(w * count)) = .{ .v = @splat(0), .x = @splat(0) };
    const s = wide(a);
    for (0..count) |i| {
        orAt(&o.v, &s.v, @intCast(i * w));
        orAt(&o.x, &s.x, @intCast(i * w));
    }
    return o;
}

/// §17.11 `$clog2` of a self-determined operand, x/z read as 0 (`exec`'s
/// `integerCeilingLog2`).
pub inline fn clog2(a: anytype, comptime w: u32) u64 {
    comptime assert(w >= 1);
    if (w > 64) {
        if (anyX(a)) return 0;
        var length: u64 = 0;
        var power_of_two = true;
        for (a.v, 0..) |word, index| {
            if (word == 0) continue;
            if (length != 0 or word & (word - 1) != 0) power_of_two = false;
            length = @as(u64, @intCast(index)) * 64 + 64 - @clz(word);
        }
        return if (length != 0 and power_of_two) length - 1 else length;
    }
    if (a.x != 0 or a.v == 0) return 0;
    const length: u64 = 64 - @clz(a.v);
    return if (a.v & (a.v - 1) == 0) length - 1 else length;
}

/// §9.5 / §9.5.1: `case` is `===`; casez/casex skip z (and x) bits of
/// either side.
pub inline fn caseMatch(comptime kind: CaseKind, a: anytype, b: @TypeOf(a)) bool {
    var miss: u64 = 0;
    const sa = wide(a);
    const sb = wide(b);
    for (sa.v, sa.x, sb.v, sb.x) |av, ax, bv, bx| {
        const wild: u64 = switch (kind) {
            .normal => 0,
            .casex => ax | bx,
            .casez => (ax & ~av) | (bx & ~bv),
        };
        miss |= ((av ^ bv) | (ax ^ bx)) & ~wild;
    }
    return miss == 0;
}

// ---- tests: every kernel against `Integer.Literal` --------------------------

test "part, place, up and bitAt move the bits the per-bit rule names" {
    var prng = std.Random.DefaultPrng.init(0x521);
    const rand = prng.random();
    inline for (.{ .{ 130, -3, 70 }, .{ 130, 60, 10 }, .{ 130, 120, 16 }, .{ 70, 0, 70 }, .{ 20, -4, 8 }, .{ 20, 16, 8 }, .{ 200, 64, 65 } }) |c| for (0..200) |_| {
        const sw = c[0];
        const sh = c[1] + rand.intRangeAtMost(i64, -3, 3);
        const count = c[2];
        const a = wide(randomW(rand, sw));
        const got = wide(part(narrow(sw, a), sh, count, sw));
        const val = wide(randomW(rand, count));
        const put = wide(place(narrow(count, val), sh, count, sw));
        const m = field(sh, count, sw);
        for (0..count) |i| {
            const p = @as(i64, @intCast(i)) + sh;
            const want: u2 = if (p < 0 or p >= sw) 3 else @intCast((a.v[@intCast(@divFloor(p, 64))] >> @intCast(@mod(p, 64))) & 1 | ((a.x[@intCast(@divFloor(p, 64))] >> @intCast(@mod(p, 64))) & 1) << 1);
            const g: u2 = @intCast((got.v[i / 64] >> @intCast(i % 64)) & 1 | ((got.x[i / 64] >> @intCast(i % 64)) & 1) << 1);
            try std.testing.expectEqual(want, g);
        }
        for (0..sw) |p| {
            const i = @as(i64, @intCast(p)) - sh;
            const inside = i >= 0 and i < count;
            const mb = ((if (sw <= 64) m else m[p / 64]) >> @intCast(p % 64)) & 1 == 1;
            try std.testing.expectEqual(inside, mb);
            const want: u2 = if (!inside) 0 else @intCast((val.v[@intCast(@divFloor(i, 64))] >> @intCast(@mod(i, 64))) & 1 | ((val.x[@intCast(@divFloor(i, 64))] >> @intCast(@mod(i, 64))) & 1) << 1);
            const g: u2 = @intCast((put.v[p / 64] >> @intCast(p % 64)) & 1 | ((put.x[p / 64] >> @intCast(p % 64)) & 1) << 1);
            try std.testing.expectEqual(want, g);
        }
        const p: u32 = rand.uintLessThan(u32, sw);
        const one = wide(up(W{ .v = 1, .x = 1 }, p, sw));
        const bm = bit(p, sw);
        for (0..words(sw)) |j| {
            const want: u64 = if (j == p / 64) @as(u64, 1) << @intCast(p % 64) else 0;
            try std.testing.expectEqual(want, one.v[j]);
            try std.testing.expectEqual(want, one.x[j]);
            try std.testing.expectEqual(want, if (sw <= 64) bm else bm[j]);
        }
        const b = bitAt(narrow(sw, a), p, sw - 1, 0, sw);
        try std.testing.expectEqual((a.v[p / 64] >> @intCast(p % 64)) & 1, b.v);
        try std.testing.expectEqual((a.x[p / 64] >> @intCast(p % 64)) & 1, b.x);
    };
}

test "indexed part-select shifts preserve declaration direction and distant indices" {
    try std.testing.expectEqual(@as(?i64, 0), selectShift(4, 11, 4, 4, true));
    try std.testing.expectEqual(@as(?i64, 4), selectShift(11, 11, 4, 4, false));
    try std.testing.expectEqual(@as(?i64, 4), selectShift(4, 4, 11, 4, true));
    try std.testing.expectEqual(@as(?i64, 0), selectShift(11, 4, 11, 4, false));
    try std.testing.expectEqual(@as(?i64, null), selectShift(null, 7, 0, 4, true));
    for ([_]i64{ std.math.minInt(i64), std.math.maxInt(i64) }) |sh| {
        try std.testing.expectEqual(xs(4), part(W{ .v = 0xa5, .x = 0 }, sh, 4, 8));
        try std.testing.expectEqual(@as(u64, 0), field(sh, 4, 8));
        try std.testing.expectEqual(W{ .v = 0, .x = 0 }, place(W{ .v = 0xf, .x = 0 }, sh, 4, 8));
    }
    try std.testing.expectEqual(@as(?u32, null), pos(std.math.minInt(i64), 11, 4, 8));
}

test "$clog2 of a multi-word value" {
    inline for (.{ 65, 129, 200 }) |w| for (0..w) |e| {
        var a: T(w) = .{ .v = @splat(0), .x = @splat(0) };
        a.v[e / 64] = @as(u64, 1) << @intCast(e % 64);
        try std.testing.expectEqual(@as(u64, e), clog2(a, w));
        a.v[0] |= 1;
        try std.testing.expectEqual(@as(u64, if (e == 0) 0 else e + 1), clog2(a, w));
        a.x[0] = 1;
        try std.testing.expectEqual(@as(u64, 0), clog2(a, w));
    };
}

test "$clog2 of a one-word value is the least k with 2^k >= it; x reads as 0 (§17.11)" {
    for (0..1025) |i| {
        const v: u64 = @intCast(i);
        var want: u64 = 0;
        while (std.math.shl(u64, 1, want) < v) want += 1;
        try std.testing.expectEqual(want, clog2(W{ .v = v, .x = 0 }, 64));
    }
    try std.testing.expectEqual(@as(u64, 64), clog2(W{ .v = std.math.maxInt(u64), .x = 0 }, 64));
    try std.testing.expectEqual(@as(u64, 63), clog2(W{ .v = 1 << 63, .x = 0 }, 64));
    try std.testing.expectEqual(@as(u64, 0), clog2(W{ .v = 1000, .x = 8 }, 64));
}

test "casez/casex agree with the per-bit wildcard rule" {
    var prng = std.Random.DefaultPrng.init(0x951);
    const rand = prng.random();
    for (0..5000) |_| {
        const a = randomW(rand, 6);
        const b = randomW(rand, 6);
        try std.testing.expectEqual(caseMatch(.casez, a, b), caseMatch(.casez, rs(a, 6, 130, false), rs(b, 6, 130, false)));
        try std.testing.expectEqual(caseMatch(.casex, a, b), caseMatch(.casex, rs(a, 6, 130, false), rs(b, 6, 130, false)));
        inline for (.{ .casez, .casex }) |kind| {
            var want = true;
            for (0..6) |i| {
                const ab: u2 = @intCast((a.v >> @intCast(i)) & 1 | ((a.x >> @intCast(i)) & 1) << 1);
                const bb: u2 = @intCast((b.v >> @intCast(i)) & 1 | ((b.x >> @intCast(i)) & 1) << 1);
                const wild = ab == 2 or bb == 2 or (kind == .casex and (ab == 3 or bb == 3));
                if (!wild and ab != bb) want = false;
            }
            try std.testing.expectEqual(want, caseMatch(kind, a, b));
        }
        try std.testing.expectEqual(eq(.case_eq, a, b) == .one, caseMatch(.normal, a, b));
    }
}
