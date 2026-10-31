//! Interval: the prover's abstract value, a real interval with open or closed
//! ends and the one hole a divisor proof needs. Pure values: meet, join and
//! the membership predicates, no MIR walk, no allocation, no diagnostics.
//! `contains` is the definition every predicate here and every transfer in
//! `transfer.zig` is tested against.
//!
//! LRM clauses this file's code cites: §3.4.2, §4.2.4.
//!
//! Contents:
//! - `pub const Interval = @This()` (fields `lo`, `hi`, `lo_open`, `hi_open`, `nonzero`)
//! - `pub const top: Interval`
//! - `pub fn point(x: f64) Interval`
//! - `pub fn bounded(i: Interval) bool`, `pub fn isEmpty(i: Interval) bool`, `pub fn excludesInf(i: Interval) bool`
//! - `pub fn gt(i: Interval, k: f64) bool`, `ge`, `lt`, `le`, `pub fn excludesZero(i: Interval) bool`
//! - `pub fn meet(a: Interval, b: Interval) Interval`, `pub fn join(a: Interval, b: Interval) Interval`
//! - `pub fn contains(i: Interval, x: f64) bool`

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;

/// File-as-struct. `top` is `(-inf, inf)` closed, which is also the "no
/// evidence" element, so a zero-initialised pass is sound. NaN never appears
/// as a bound: a NaN constant widens to `top`, and the transfer functions
/// answer `top` for a NaN endpoint. Empty (`lo > hi`) means unreachable and
/// vacuously satisfies every domain, which is right for a contradictory
/// guard. Every predicate is sound, not exact: `true` is a proof about every
/// member, `false` only the absence of one.
pub const Interval = @This();

// Stays AoS (24 bytes): every consumer reads a whole interval, and packing
// the three flags only moves the padding. `seedValues`' fill, ReleaseFast,
// ns per fill (min of 25):
//     n:            38      210      929    24578
//     AoS @memset   14.5     76.7    349.7  17174.6   <- ships
//     SoA 3x@memset 14.1     70.6    320.5  10745.2
//     SoA @Vector   11.9     57.3    253.6  15615.8   <- loses to @memset at 24578
// Corpus MIR is small (median 26 values), so neither split pays.
lo: f64 = -math.inf(f64),
hi: f64 = math.inf(f64),
/// `true`: the bound itself is excluded (§3.4.2 `(`/`)`); likewise `hi_open`.
lo_open: bool = false,
hi_open: bool = false,
/// §3.4.2 `exclude 0` on an otherwise unbounded parameter: a hole an interval
/// cannot represent, but the one hole a §4.2.4 divisor proof needs.
nonzero: bool = false,

/// `(-inf, inf)`: no evidence.
pub const top: Interval = .{};

comptime {
    assert(@sizeOf(Interval) == 24);
}

/// Returns the one-point interval `[x, x]`, or `top` for NaN.
pub fn point(x: f64) Interval {
    if (math.isNan(x)) return top;
    const r: Interval = .{ .lo = x, .hi = x };
    assert(r.contains(x));
    return r;
}

/// Returns whether both bounds are finite, so every member is a finite double.
pub fn bounded(i: Interval) bool {
    return math.isFinite(i.lo) and math.isFinite(i.hi);
}

/// Returns whether no value satisfies the bounds (unreachable). A `nonzero`
/// `[0, 0]` has no member either but reads non-empty.
pub fn isEmpty(i: Interval) bool {
    return i.lo > i.hi or (i.lo == i.hi and (i.lo_open or i.hi_open));
}

/// Returns whether the interval excludes ±inf; an open infinite bound does.
pub fn excludesInf(i: Interval) bool {
    const lo_ok = math.isFinite(i.lo) or (i.lo == -math.inf(f64) and i.lo_open);
    const hi_ok = math.isFinite(i.hi) or (i.hi == math.inf(f64) and i.hi_open);
    return lo_ok and hi_ok;
}

/// Returns whether every member x satisfies x > k.
pub fn gt(i: Interval, k: f64) bool {
    return i.lo > k or (i.lo == k and i.lo_open);
}

/// Returns whether every member x satisfies x >= k.
pub fn ge(i: Interval, k: f64) bool {
    return i.lo >= k;
}

/// Returns whether every member x satisfies x < k.
pub fn lt(i: Interval, k: f64) bool {
    return i.hi < k or (i.hi == k and i.hi_open);
}

/// Returns whether every member x satisfies x <= k.
pub fn le(i: Interval, k: f64) bool {
    return i.hi <= k;
}

/// Returns whether 0 is provably not a member (a sign, or the §3.4.2
/// `exclude 0` hole).
pub fn excludesZero(i: Interval) bool {
    return i.nonzero or i.gt(0) or i.lt(0);
}

/// Returns the intersection; guard evidence is applied this way. Exact:
/// a member of the result is a member of both.
pub fn meet(a: Interval, b: Interval) Interval {
    var r = a;
    if (b.lo > r.lo) {
        r.lo = b.lo;
        r.lo_open = b.lo_open;
    } else if (b.lo == r.lo) {
        r.lo_open = r.lo_open or b.lo_open;
    }
    if (b.hi < r.hi) {
        r.hi = b.hi;
        r.hi_open = b.hi_open;
    } else if (b.hi == r.hi) {
        r.hi_open = r.hi_open or b.hi_open;
    }
    r.nonzero = r.nonzero or b.nonzero;
    // Negated so a NaN bound from a user's range literal passes: an assert
    // must not test outside data.
    assert(!(r.lo < a.lo));
    assert(!(r.hi > a.hi));
    return r;
}

/// Returns the convex hull; phi and select operands and `from` range lists
/// combine this way. Covers both: a member of either is a member of it.
pub fn join(a: Interval, b: Interval) Interval {
    var r = a;
    if (b.lo < r.lo) {
        r.lo = b.lo;
        r.lo_open = b.lo_open;
    } else if (b.lo == r.lo) {
        r.lo_open = r.lo_open and b.lo_open;
    }
    if (b.hi > r.hi) {
        r.hi = b.hi;
        r.hi_open = b.hi_open;
    } else if (b.hi == r.hi) {
        r.hi_open = r.hi_open and b.hi_open;
    }
    r.nonzero = r.nonzero and b.nonzero;
    assert(!(r.lo > a.lo));
    assert(!(r.hi < a.hi));
    return r;
}

/// Returns whether `x` is a member: the definition of every predicate above.
pub fn contains(i: Interval, x: f64) bool {
    if (i.nonzero and x == 0) return false;
    const above = x > i.lo or (x == i.lo and !i.lo_open);
    const below = x < i.hi or (x == i.hi and !i.hi_open);
    return above and below;
}

test Interval {
    // Exhaustive over a small domain: every interval whose ends are in `ends`
    // (empty ones too), with each openness flag and the `nonzero` hole, against
    // `contains` at each end, the doubles on either side of it, and points between.
    const inf = math.inf(f64);
    const ends = [_]f64{ -inf, -1, 0, 1, inf };
    var pts: [ends.len * 3 + 4]f64 = undefined;
    for (ends, 0..) |e, i| {
        pts[3 * i] = e;
        pts[3 * i + 1] = math.nextAfter(f64, e, -inf);
        pts[3 * i + 2] = math.nextAfter(f64, e, inf);
    }
    pts[ends.len * 3 ..][0..4].* = .{ -2, -0.5, 0.5, 2 };

    var all: [ends.len * ends.len * 8]Interval = undefined;
    var n: usize = 0;
    for (ends) |lo| for (ends) |hi| for (0..8) |bits| {
        all[n] = .{ .lo = lo, .hi = hi, .lo_open = (bits & 1) != 0, .hi_open = (bits & 2) != 0, .nonzero = (bits & 4) != 0 };
        n += 1;
    };

    const ks = [_]f64{ -1, 0, 1 };
    for (all) |a| {
        // Sound: a `true` predicate holds for every member.
        var any = false;
        var all_gt: [ks.len]bool = @splat(true);
        var all_ge: [ks.len]bool = @splat(true);
        var all_lt: [ks.len]bool = @splat(true);
        var all_le: [ks.len]bool = @splat(true);
        var no_inf = true;
        for (pts) |x| {
            if (!a.contains(x)) continue;
            any = true;
            if (math.isInf(x)) no_inf = false;
            if (a.bounded()) try std.testing.expect(math.isFinite(x));
            if (a.excludesZero()) try std.testing.expect(x != 0);
            for (ks, 0..) |k, j| {
                all_gt[j] = all_gt[j] and x > k;
                all_ge[j] = all_ge[j] and x >= k;
                all_lt[j] = all_lt[j] and x < k;
                all_le[j] = all_le[j] and x <= k;
            }
        }
        if (a.isEmpty()) try std.testing.expect(!any);
        if (a.excludesInf()) try std.testing.expect(no_inf);
        for (ks, 0..) |k, j| {
            if (a.gt(k)) try std.testing.expect(all_gt[j]);
            if (a.ge(k)) try std.testing.expect(all_ge[j]);
            if (a.lt(k)) try std.testing.expect(all_lt[j]);
            if (a.le(k)) try std.testing.expect(all_le[j]);
        }
        // Exact where no hole is involved: `false` means some member breaks it.
        if (!a.nonzero and !a.isEmpty()) {
            try std.testing.expect(any);
            try std.testing.expectEqual(no_inf, a.excludesInf());
            for (ks, 0..) |k, j| {
                try std.testing.expectEqual(all_gt[j], a.gt(k));
                try std.testing.expectEqual(all_ge[j], a.ge(k));
                try std.testing.expectEqual(all_lt[j], a.lt(k));
                try std.testing.expectEqual(all_le[j], a.le(k));
            }
        }

        // `meet` is exactly the intersection; `join` covers the union.
        for (all) |b| {
            const m = a.meet(b);
            const u = a.join(b);
            for (pts) |x| {
                try std.testing.expectEqual(a.contains(x) and b.contains(x), m.contains(x));
                if (a.contains(x) or b.contains(x)) try std.testing.expect(u.contains(x));
            }
        }
    }

    // `point` is the one-member interval, and a NaN constant carries no evidence.
    try std.testing.expect(Interval.point(0.5).contains(0.5) and !Interval.point(0.5).contains(1));
    try std.testing.expectEqual(Interval.top, Interval.point(math.nan(f64)));
}
