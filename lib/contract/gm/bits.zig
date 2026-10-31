//! An `f64` or `@Vector(n, f64)` operating point in, its IEEE bit fields out:
//! the scalar-or-vector helpers `arm_exp.zig`, `arm_pow.zig` and
//! `arm_log.zig` write their arithmetic once over, so a vector lane is the
//! scalar call's bits. Also the ulp distance the accuracy tests measure in.
//! Cites: IEEE 754-2008 §3.4 (binary64's sign, exponent and fraction fields).
//!
//! Contents:
//! - `pub fn UOf(comptime T: type) type`
//! - `pub fn IOf(comptime T: type) type`
//! - `pub inline fn sp(comptime T: type, c: anytype) T`
//! - `pub inline fn shl(v: anytype, comptime n: u6) @TypeOf(v)`
//! - `pub inline fn shrU(v: anytype, comptime n: u6) @TypeOf(v)`
//! - `pub inline fn gather(comptime E: type, tab: []const E, idx: anytype) Gathered(E, @TypeOf(idx))`
//! - `pub fn Gathered(comptime E: type, comptime Idx: type) type`
//! - `pub inline fn top12(x: f64) u32`
//! - `pub inline fn asF(u: u64) f64`
//! - `pub inline fn asU(f: f64) u64`
//! - `pub fn ulps(a: f64, b: f64) u64`

const std = @import("std");
const assert = std.debug.assert;

/// The unsigned bit type of `T`: `u64`, or `@Vector(n, u64)` for a vector.
pub fn UOf(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .vector => |v| @Vector(v.len, u64),
        else => u64,
    };
}

/// The signed bit type of `T`: `i64`, or `@Vector(n, i64)` for a vector.
pub fn IOf(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .vector => |v| @Vector(v.len, i64),
        else => i64,
    };
}

/// `c` as a `T`: itself for a scalar, splatted for a vector.
pub inline fn sp(comptime T: type, c: anytype) T {
    return switch (@typeInfo(T)) {
        .vector => @splat(c),
        else => c,
    };
}

/// `v << n`, lane by lane for a vector.
pub inline fn shl(v: anytype, comptime n: u6) @TypeOf(v) {
    return switch (@typeInfo(@TypeOf(v))) {
        .vector => |t| v << @as(@Vector(t.len, u6), @splat(n)),
        else => v << n,
    };
}

/// `v >> n` (logical), lane by lane for a vector.
pub inline fn shrU(v: anytype, comptime n: u6) @TypeOf(v) {
    return switch (@typeInfo(@TypeOf(v))) {
        .vector => |t| v >> @as(@Vector(t.len, u6), @splat(n)),
        else => v >> n,
    };
}

/// What `gather` returns for an index of type `Idx`: one `E`, or a vector.
pub fn Gathered(comptime E: type, comptime Idx: type) type {
    return switch (@typeInfo(Idx)) {
        .vector => |v| @Vector(v.len, E),
        else => E,
    };
}

/// `tab[idx]` lane by lane: a gather. Asserts (as the slice index does)
/// that every index is below `tab.len`.
pub inline fn gather(comptime E: type, tab: []const E, idx: anytype) Gathered(E, @TypeOf(idx)) {
    assert(tab.len > 0);
    switch (@typeInfo(@TypeOf(idx))) {
        .vector => |v| {
            // SAFETY: the loop below writes every one of the v.len lanes.
            var out: @Vector(v.len, E) = undefined;
            inline for (0..v.len) |l| out[l] = tab[@intCast(idx[l])];
            return out;
        },
        else => return tab[@intCast(idx)],
    }
}

/// The sign and exponent field of `x`: its top 12 bits.
pub inline fn top12(x: f64) u32 {
    return @intCast(@as(u64, @bitCast(x)) >> 52);
}

/// The double whose bits are `u`.
pub inline fn asF(u: u64) f64 {
    return @bitCast(u);
}

/// The bits of `f`.
pub inline fn asU(f: f64) u64 {
    return @bitCast(f);
}

/// How many doubles lie between `a` and `b` on the number line (0 when
/// equal, `+0` and `-0` included); `maxInt(u64)` for operands of different
/// sign that are not both zero.
pub fn ulps(a: f64, b: f64) u64 {
    const ia: i64 = @bitCast(a);
    const ib: i64 = @bitCast(b);
    if ((ia < 0) != (ib < 0)) return if (a == b) 0 else std.math.maxInt(u64);
    const d = @abs(ia - ib);
    assert(d != 0 or a == b or std.math.isNan(a));
    return d;
}

test ulps {
    try std.testing.expectEqual(@as(u64, 0), ulps(0.0, -0.0));
    try std.testing.expectEqual(@as(u64, 1), ulps(1.0, std.math.nextAfter(f64, 1.0, 2.0)));
    try std.testing.expectEqual(std.math.maxInt(u64), ulps(-1.0, 1.0));
}

test gather {
    const tab = [_]u64{ 10, 20, 30 };
    try std.testing.expectEqual(@as(u64, 30), gather(u64, &tab, @as(u64, 2)));
    const v = gather(u64, &tab, @Vector(2, u64){ 1, 0 });
    try std.testing.expectEqual(@Vector(2, u64){ 20, 10 }, v);
}
