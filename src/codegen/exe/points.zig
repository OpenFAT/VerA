//! Operating points: a `Bench`'s sweep columns in, the cartesian product
//! out, one point at a time and without allocating. Column order is the
//! `sweeps` then the `psweeps`, the last column varying fastest, so the
//! runner's text is in the order its directives read.
//! Cites: §8.2 (each `psweep` point is a sub-task with its own card).
//!
//! Contents:
//! - `pub fn pointCount(bench: *const Bench) error{TooManyPoints}!u32`
//! - `pub fn columnCount(bench: *const Bench) usize`
//! - `pub fn column(bench: *const Bench, k: usize) Sweep`
//! - `pub const Row = struct`, `Row.init(bench: *const Bench, count: u32, n: u32) Row`, `Row.next(r: *Row) ?f64`

const std = @import("std");
const spec = @import("spec.zig");
const assert = std.debug.assert;
const Bench = spec.Bench;
const Sweep = spec.Sweep;

/// Point `n`'s column values, first column first: the mixed-radix digits of
/// `n`, each column's length its radix.
pub const Row = struct {
    bench: *const Bench,
    n: u32,
    /// The next column to yield.
    k: usize = 0,
    /// How many points one step of column `k` spans: the product of the
    /// lengths after it.
    stride: u32,

    /// Starts point `n` of the `count` that `pointCount(bench)` returned.
    /// Asserts that `n < count`.
    pub fn init(bench: *const Bench, count: u32, n: u32) Row {
        assert(n < count);
        assert(count <= spec.points_max);
        const first = if (columnCount(bench) == 0) 1 else column(bench, 0).values.len;
        assert(count % first == 0);
        return .{ .bench = bench, .n = n, .stride = count / @as(u32, @intCast(first)) };
    }

    /// Returns the next column's value, or null after the last column.
    pub fn next(r: *Row) ?f64 {
        if (r.k == columnCount(r.bench)) return null;
        const vals = column(r.bench, r.k).values;
        assert(r.stride != 0);
        const v = vals[(r.n / r.stride) % vals.len];
        r.k += 1;
        if (r.k < columnCount(r.bench)) {
            const len: u32 = @intCast(column(r.bench, r.k).values.len);
            assert(r.stride % len == 0);
            r.stride /= len;
        } else assert(r.stride == 1);
        return v;
    }
};

/// Returns how many points the sweeps expand to: the product of every
/// column's length, 1 with no column. Fails past `points_max`. Asserts that
/// no column is empty.
pub fn pointCount(bench: *const Bench) error{TooManyPoints}!u32 {
    var total: u32 = 1;
    for (0..columnCount(bench)) |k| {
        const len = column(bench, k).values.len;
        assert(len != 0); // `numbers` refuses an empty list.
        if (len > spec.points_max) return error.TooManyPoints;
        total *= @intCast(len);
        if (total > spec.points_max) return error.TooManyPoints;
    }
    assert(total != 0);
    assert(total <= spec.points_max);
    return total;
}

/// Returns the number of columns a point has: the unknown sweeps, then the
/// parameter sweeps.
pub fn columnCount(bench: *const Bench) usize {
    return bench.sweeps.len + bench.psweeps.len;
}

/// Column `k` of a point: `sweeps[k]`, then the `psweeps`. Asserts that
/// `k < columnCount(bench)`.
pub fn column(bench: *const Bench, k: usize) Sweep {
    assert(k < columnCount(bench));
    return if (k < bench.sweeps.len) bench.sweeps[k] else bench.psweeps[k - bench.sweeps.len];
}

test "a point is the mixed-radix digits of its index, the last column fastest" {
    // Oracle: the product written out by hand.
    const bench: Bench = .{
        .sweeps = &.{ .{ .name = "a", .values = &.{ 0, 1 } }, .{ .name = "b", .values = &.{ 10, 20, 30 } } },
        .psweeps = &.{.{ .name = "r", .values = &.{ 5, 6 } }},
    };
    const want = [_][3]f64{
        .{ 0, 10, 5 }, .{ 0, 10, 6 }, .{ 0, 20, 5 }, .{ 0, 20, 6 }, .{ 0, 30, 5 }, .{ 0, 30, 6 },
        .{ 1, 10, 5 }, .{ 1, 10, 6 }, .{ 1, 20, 5 }, .{ 1, 20, 6 }, .{ 1, 30, 5 }, .{ 1, 30, 6 },
    };
    const count = try pointCount(&bench);
    try std.testing.expectEqual(want.len, count);
    for (want, 0..) |w, n| {
        var row: Row = .init(&bench, count, @intCast(n));
        for (w) |v| try std.testing.expectEqual(v, row.next().?);
        try std.testing.expectEqual(null, row.next());
    }
}
