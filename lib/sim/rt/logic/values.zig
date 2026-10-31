//! A value's width in, the planes it is carried in out: `W` up to 64 bits, `Wide(n)` above, the masks, sign and zero extension (§5.5.2) and the one-bit reads every operator and the emitted code share. Under `--two-state` the x plane is the constant 0.
//! Cites: IEEE 1364-2005 §3.2, §4.1 (the four values), §5.5.2 (extension).
//!
//! Contents:
//! - `pub const two`
//! - `pub const W = struct`
//! - `pub const Bit = enum(u2)`
//! - `pub const ones`
//! - `pub fn Wide(comptime n: u32) type`
//! - `pub fn words(w: u32) u32`
//! - `pub fn T(comptime w: u32) type`
//! - `pub fn M(comptime w: u32) type`
//! - `pub inline fn wide(a: anytype) Wide(wordsOf(@TypeOf(a)))`
//! - `pub fn full(comptime w: u32) M(w)`
//! - `pub fn xs(comptime w: u32) T(w)`
//! - `pub fn span(j: usize, lo: i64, hi: i64) u64`
//! - `pub fn mask(comptime w: u32) u64`
//! - `pub inline fn k(v: u64, x: u64) W`
//! - `pub inline fn low(a: anytype) Bit`
//! - `pub inline fn rs(a: anytype, comptime from: u32, comptime to: u32, comptime sign: bool) T(to)`
//! - `pub inline fn ctx(b: Bit, comptime w: u32, comptime sign: bool) T(w)`
//! - `pub fn planesOf(a: anytype) [2 * wordsOf(@TypeOf(a))]u64`
//! - `pub fn top(comptime w: u32) u64`
//! - `pub fn wordsOf(comptime A: type) u32`
//! - `pub inline fn narrow(comptime w: u32, a: Wide(words(w))) T(w)`
//! - `pub fn funnel(p: []const u64, at: i64) u64`
//! - `pub fn orAt(dst: []u64, src: []const u64, at: u32) void`
//! - `pub fn anyX(a: anytype) bool`
//! - `pub fn orX(comptime w: u32, r: [words(w)]u64, unk: bool) T(w)`
//! - `pub fn sext(v: u64, comptime w: u32) u64`

const std = @import("std");
const assert = std.debug.assert;
const Int = @import("kernels").Integer;
const operators = @import("operators.zig");
const selects = @import("selects.zig");
const bit = selects.bit;
const shift = operators.shift;

/// `vera --emit-exe --two-state`: not IEEE 1364 §3.2/§4.1 4-state logic.
pub const two = blk: {
    const root = @import("root");
    break :blk if (@hasDecl(root, "vera_two_state")) root.vera_two_state else false;
};

/// A value of at most 64 bits as two planes, VPI-encoded per bit: (v, x) =
/// 00/10/11/01 for 0/1/x/z. Bits at and above the width are 0 in both.
pub const W = struct { v: u64, x: u64 };

/// One bit, as `Integer.Bit` encodes it: `v | x << 1`.
pub const Bit = enum(u2) { zero = 0, one = 1, z = 2, x = 3 };

/// A word of all ones.
pub const ones = std.math.maxInt(u64);

/// A value of more than 64 bits: `n` words per plane, least significant
/// first, encoded and zero-padded above the width as `W` is.
pub fn Wide(comptime n: u32) type {
    return struct { v: [n]u64, x: [n]u64 };
}

/// The words per plane of a `w`-bit value.
pub fn words(w: u32) u32 {
    return (w + 63) / 64;
}

/// The type a `w`-bit value is carried in.
pub fn T(comptime w: u32) type {
    return if (w <= 64) W else Wide(words(w));
}

/// The type of a `w`-bit plane mask: what `State.put` takes beside a `T(w)`.
pub fn M(comptime w: u32) type {
    return if (w <= 64) u64 else [words(w)]u64;
}

/// `a` as words, one when it is a `W`.
pub inline fn wide(a: anytype) Wide(wordsOf(@TypeOf(a))) {
    if (@FieldType(@TypeOf(a), "v") == u64) return .{ .v = .{a.v}, .x = .{a.x} };
    return .{ .v = a.v, .x = a.x };
}

/// Every bit of a `w`-bit value.
pub fn full(comptime w: u32) M(w) {
    comptime assert(w >= 1);
    if (w <= 64) return mask(w);
    var m: [words(w)]u64 = @splat(ones);
    m[words(w) - 1] = top(w);
    return m;
}

/// A `w`-bit value of all x; all 0 under `--two-state`.
pub fn xs(comptime w: u32) T(w) {
    comptime assert(w >= 1);
    const f = if (two) std.mem.zeroes(M(w)) else full(w);
    return .{ .v = f, .x = f };
}

/// Bits `[lo, hi)` of word `j`, clamped to the word.
pub fn span(j: usize, lo: i64, hi: i64) u64 {
    const base: i64 = @intCast(64 * j);
    return below(std.math.clamp(hi - base, 0, 64)) & ~below(std.math.clamp(lo - base, 0, 64));
}

/// The mask of a `w`-bit value. Asserts at comptime that `w` is 1 to 64.
pub fn mask(comptime w: u32) u64 {
    comptime std.debug.assert(w >= 1 and w <= 64);
    return if (w == 64) std.math.maxInt(u64) else (@as(u64, 1) << w) - 1;
}

/// A `W` from its two planes; the caller keeps bits above the width 0.
pub inline fn k(v: u64, x: u64) W {
    return .{ .v = v, .x = x };
}

/// Bit 0 of a `W` or a `Wide`: the bit an edge is of (§9.7.2).
pub inline fn low(a: anytype) Bit {
    const s = wide(a);
    return @fromBackingInt(@intCast(@as(u2, @intCast(s.v[0] & 1)) | @as(u2, @intCast(s.x[0] & 1)) << 1));
}

/// `Literal.resize`: truncate, or extend by `sign` (per plane, so a top x
/// or z replicates as itself).
pub inline fn rs(a: anytype, comptime from: u32, comptime to: u32, comptime sign: bool) T(to) {
    if (from > 64 or to > 64) return rsWide(wide(a), from, to, sign);
    if (to <= from or !sign) return .{ .v = a.v & mask(to), .x = a.x & mask(to) };
    const hi = ~mask(from) & mask(to);
    return .{
        .v = a.v | (hi & (0 -% ((a.v >> (from - 1)) & 1))),
        .x = a.x | (hi & (0 -% ((a.x >> (from - 1)) & 1))),
    };
}

/// A one-bit result in its context (`evaluate.scalarContext`).
pub inline fn ctx(b: Bit, comptime w: u32, comptime sign: bool) T(w) {
    comptime assert(w >= 1);
    const n: u2 = @backingInt(b);
    return rs(W{ .v = n & 1, .x = n >> 1 }, 1, w, sign);
}

/// Both planes of `a`, values first: an `Integer.Literal`'s `planes`.
pub fn planesOf(a: anytype) [2 * wordsOf(@TypeOf(a))]u64 {
    const s = wide(a);
    return s.v ++ s.x;
}

/// The mask of the last word of a `w`-bit value.
pub fn top(comptime w: u32) u64 {
    return if (w % 64 == 0) ones else (@as(u64, 1) << @intCast(w % 64)) - 1;
}

/// Returns the words per plane of a `W` or `Wide(n)` type.
pub fn wordsOf(comptime A: type) u32 {
    const V = @FieldType(A, "v");
    return if (V == u64) 1 else @typeInfo(V).array.len;
}

/// Words back as the `T(w)` they carry.
pub inline fn narrow(comptime w: u32, a: Wide(words(w))) T(w) {
    comptime assert(w >= 1);
    if (w <= 64) return .{ .v = a.v[0], .x = a.x[0] };
    return a;
}

/// The 64 bits of `p` from bit `pos` up; bits outside `p` read 0.
pub fn funnel(p: []const u64, at: i64) u64 {
    const q = @divFloor(at, 64);
    const b: u6 = @intCast(@mod(at, 64));
    const lo = wordAt(p, q) >> b;
    const hi = if (b == 0) 0 else wordAt(p, q + 1) << @intCast(64 - @as(u7, b));
    return lo | hi;
}

/// `dst |= src << at`, bits past `dst` dropped.
pub fn orAt(dst: []u64, src: []const u64, at: u32) void {
    const q = at / 64;
    const b: u6 = @intCast(at % 64);
    for (src, 0..) |w, j| {
        if (q + j < dst.len) dst[q + j] |= w << b;
        if (b != 0 and q + j + 1 < dst.len) dst[q + j + 1] |= w >> @intCast(64 - @as(u7, b));
    }
}

/// Returns whether any bit of `a` is x or z.
pub fn anyX(a: anytype) bool {
    var any: u64 = 0;
    for (wide(a).x) |x| any |= x;
    return any != 0;
}

/// `r` of width `w`, or all x when `unk` (§5.1.5).
pub fn orX(comptime w: u32, r: [words(w)]u64, unk: bool) T(w) {
    comptime assert(w >= 1);
    // `@Vector`, not a loop: with the last word masked, LLVM's SLP pass
    // leaves the loop half scalar at 4+ words (tests/codegen_probe.zig).
    const u = 0 -% @as(u64, @intFromBool(unk));
    const V = @Vector(words(w), u64);
    const uv: V = @splat(u);
    var o: Wide(words(w)) = .{ .v = @as(V, r) | uv, .x = uv };
    o.v[words(w) - 1] &= top(w);
    o.x[words(w) - 1] &= top(w);
    return narrow(w, o);
}

/// Returns the low `w` bits of `v` sign-extended to 64.
pub fn sext(v: u64, comptime w: u32) u64 {
    comptime assert(w >= 1);
    if (w == 64) return v;
    return v | (~mask(w) & (0 -% ((v >> (w - 1)) & 1)));
}

// ---- private ----

fn below(n: i64) u64 {
    // No cast guarded by the branch: Windows' LLVM Debug build ran the cast's
    // safety check at n == 64. A shift by 64 or more is 0, so 0 -% 1 = ones.
    return std.math.shl(u64, 1, n) -% 1;
}

fn wordAt(p: []const u64, i: i64) u64 {
    return if (i < 0 or i >= p.len) 0 else p[@intCast(i)];
}

fn rsWide(s: anytype, comptime from: u32, comptime to: u32, comptime sign: bool) T(to) {
    const nf = comptime words(from);
    const nt = comptime words(to);
    const b: u6 = (from - 1) % 64;
    const fv: u64 = if (sign) 0 -% ((s.v[nf - 1] >> b) & 1) else 0;
    const fx: u64 = if (sign) 0 -% ((s.x[nf - 1] >> b) & 1) else 0;
    var o: Wide(nt) = undefined;
    for (0..nt) |i| {
        o.v[i] = if (i < nf) s.v[i] else fv;
        o.x[i] = if (i < nf) s.x[i] else fx;
    }
    if (nf <= nt) {
        o.v[nf - 1] |= fv & ~top(from);
        o.x[nf - 1] |= fx & ~top(from);
    }
    o.v[nt - 1] &= top(to);
    o.x[nt - 1] &= top(to);
    return narrow(to, o);
}

test "low and ctx read and widen one bit, sign-extended when signed" {
    try std.testing.expectEqual(Bit.one, low(W{ .v = 0b11, .x = 0 }));
    try std.testing.expectEqual(Bit.x, low(W{ .v = 1, .x = 1 }));
    try std.testing.expectEqual(Bit.z, low(W{ .v = 0, .x = 1 }));
    try std.testing.expectEqual(Bit.zero, low(Wide(2){ .v = .{ 2, 1 }, .x = .{ 0, 1 } }));
    // A 1-bit signed 1 is -1: four 1s at 4 bits; unsigned it is 1.
    try std.testing.expectEqual(W{ .v = 0xf, .x = 0 }, ctx(.one, 4, true));
    try std.testing.expectEqual(W{ .v = 1, .x = 0 }, ctx(.one, 4, false));
    try std.testing.expectEqual(W{ .v = 0xf, .x = 0xf }, ctx(.x, 4, true));
    try std.testing.expectEqual(W{ .v = 0, .x = 1 }, ctx(.z, 4, false));
    try std.testing.expectEqual(W{ .v = 0, .x = 0xf }, ctx(.z, 4, true));
    try std.testing.expectEqual(W{ .v = 0, .x = 0 }, ctx(.zero, 4, true));
}

test "span is bits [lo, hi) of word j, clamped: the mask root.forcedBits once built by hand" {
    for (0..3) |j| for (0..200) |lo| for (0..80) |width| {
        const a: i64 = @as(i64, @intCast(lo)) - 64 * @as(i64, @intCast(j));
        const b = a + @as(i64, @intCast(width));
        var want: u64 = 0;
        if (b > 0 and a < 64) {
            const p: u7 = @intCast(@max(a, 0));
            const q: u7 = @intCast(@min(b, 64));
            want = (std.math.shl(u64, 1, q) -% 1) & ~(std.math.shl(u64, 1, p) -% 1);
        }
        try std.testing.expectEqual(want, span(j, @intCast(lo), @intCast(lo + width)));
    };
}

test "xs and full cover exactly the width, at and across word ends" {
    inline for (.{ 1, 63, 64, 65, 128, 130 }) |w| {
        const f = wide(xs(w));
        var bits: u32 = 0;
        for (f.v, f.x) |v, x| {
            try std.testing.expectEqual(v, x);
            bits += @popCount(v);
        }
        try std.testing.expectEqual(@as(u32, w), bits);
        try std.testing.expectEqual(f.v, wide(T(w){ .v = full(w), .x = full(w) }).v);
    }
    // An unknown multi-word amount shifts to all x (§5.1.12).
    const amount: Wide(2) = .{ .v = .{ 1, 0 }, .x = .{ 0, 1 } };
    try std.testing.expectEqual(xs(8), shift(.left, W{ .v = 1, .x = 0 }, 8, false, amount));
}
