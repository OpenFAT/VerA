//! A host's scalar family in, a verdict against the numerics table out:
//! `expectFamily(S)` evaluates every primitive over an edge-value grid and
//! compares it with `RefFamily`, the reference, at run time.
//! Cites: IEEE 754-2008 (signed zeros, infinities and NaN in the pins); the
//! numerics table in `family.zig`.
//!
//! Contents:
//! - `pub const Error = error{FamilyMismatch}`
//! - `pub fn expectFamily(comptime S: type) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const family = @import("family.zig");
const bits = @import("gm/bits.zig");

/// How `expectFamily` fails. It prints the first mismatch before returning.
pub const Error = error{
    /// A value, a lane, a pin or a mask join of `S` disagrees with the
    /// reference family beyond the documented tolerance.
    FamilyMismatch,
};

/// Checks family `S` against the numerics table at run time: every primitive
/// over an edge-value grid against the reference family in f64, the pinned
/// edge cases of pow, div, the compares and `sel`, and one mask join per
/// binary operation. Values must match bit for bit (transcendentals within 1 ulp);
/// lanes within 1e-6 relative, which admits f32 lanes and an unfused host,
/// and only where the operands, the value and the lane are finite and inside
/// f32's range: past that a dense host's `0·inf` is NaN on a lane a sparse
/// one never computes, and an f32 lane rightly flushes or overflows.
/// Prints the first mismatch and returns `error.FamilyMismatch`.
pub fn expectFamily(comptime S: type) Error!void {
    @setEvalBranchQuota(100_000);
    family.checkFamily(S);
    const Ref = family.RefFamily(f64, &.{ 0, 1 }, .{});
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    const grid = [_]f64{ 0.0, -0.0, 0.5, 1.5, -2.25, 3.0, 1e-310, 1e300, -1e300, inf, -inf, nan };
    // f32 lanes: a lane 1 + 2^-40 rounds to 1.
    const narrow = S.probe(0, 1.0).scale(1.0 + 0x1p-40).ddxAt(0) == 1.0;

    const unary = .{ "neg", "exp", "log", "expm1", "log1p", "sqrt", "sin", "cos", "tanh", "sinh", "cosh", "atan" };
    inline for (unary) |op| for (grid) |x| {
        const got = @field(S.Of(1), op)(S.probe(0, x));
        const want = @field(Ref.Of(1), op)(Ref.probe(0, x));
        try famExpect(op, narrow, x, 0, got, want, !std.mem.eql(u8, op, "neg"));
    };
    for (grid) |x| for ([_]f64{ 3.0, 2.0, 1.0, 0.5, 0.0, -1.0, -2.5 }) |c| {
        try famExpect("pow", narrow, x, c, S.probe(0, x).pow(c), Ref.probe(0, x).pow(c), true);
        try famExpect("scale", narrow, x, c, S.probe(0, x).scale(c), Ref.probe(0, x).scale(c), false);
        try famExpect("addC", narrow, x, c, S.probe(0, x).addC(c), Ref.probe(0, x).addC(c), false);
    };
    const binary = .{ "add", "sub", "mul", "div", "lt", "le", "eq" };
    inline for (binary) |op| for (grid) |x| for (grid) |y| {
        const got = @field(S.Of(1), op)(S.probe(0, x), S.probe(1, y));
        const want = @field(Ref.Of(1), op)(Ref.probe(0, x), Ref.probe(1, y));
        try famExpect(op, narrow, x, y, got, want, false);
        const got0 = @field(S.Of(1), op)(S.probe(0, x), S.con(y));
        const want0 = @field(Ref.Of(1), op)(Ref.probe(0, x), Ref.con(y));
        try famExpect(op, narrow, x, y, got0, want0, false);
        // The join: the operands' lanes land on their own unknowns.
        if (comptime op.len == 3 and @TypeOf(got) != S.Of(0b11)) {
            std.debug.print("expectFamily: {s} of Of(1) and Of(2) is not Of(3)\n", .{op});
            return error.FamilyMismatch;
        }
    };
    for (grid) |c| for (grid) |x| {
        try famExpect("sel", narrow, c, x, S.sel(S.con(c), S.probe(0, x), S.probe(1, 2.0)), Ref.sel(Ref.con(c), Ref.probe(0, x), Ref.probe(1, 2.0)), false);
    };

    // The pinned edge cases (value, lane): signs of zero and infinities exact.
    // `div`'s pins are values only: at a zero or infinite divisor its lanes
    // are not finite, and a dense host's are NaN where a sparse one's are not.
    const Pin = struct { what: []const u8, x: f64, y: f64, v: f64, d: ?f64 };
    const pins = [_]Pin{
        .{ .what = "pow", .x = -2, .y = 3, .v = -8, .d = 12 },
        .{ .what = "pow", .x = -2, .y = 2, .v = 4, .d = -4 },
        .{ .what = "pow", .x = -2, .y = 0.5, .v = nan, .d = 0 },
        .{ .what = "pow", .x = 0, .y = 2, .v = 0, .d = 0 },
        .{ .what = "pow", .x = 0, .y = 1, .v = 0, .d = 1 },
        .{ .what = "pow", .x = 0, .y = 0, .v = 1, .d = 0 },
        .{ .what = "pow", .x = 0, .y = 0.5, .v = 0, .d = 0 },
        .{ .what = "pow", .x = 0, .y = -1, .v = inf, .d = 0 },
        .{ .what = "pow", .x = -0.0, .y = -1, .v = -inf, .d = 0 },
        .{ .what = "div", .x = 0, .y = 0, .v = nan, .d = null },
        .{ .what = "div", .x = 1, .y = 0, .v = inf, .d = null },
        .{ .what = "div", .x = 1, .y = -0.0, .v = -inf, .d = null },
        .{ .what = "div", .x = 1, .y = inf, .v = 0, .d = null },
        .{ .what = "div", .x = inf, .y = inf, .v = nan, .d = null },
        .{ .what = "sel", .x = nan, .y = 5, .v = 5, .d = 1 },
        .{ .what = "lt", .x = nan, .y = 1, .v = 0, .d = 0 },
        .{ .what = "le", .x = 1, .y = nan, .v = 0, .d = 0 },
        .{ .what = "eq", .x = nan, .y = nan, .v = 0, .d = 0 },
    };
    for (pins) |p| {
        const a = S.probe(0, p.y);
        const r = if (std.mem.eql(u8, p.what, "pow"))
            S.probe(0, p.x).pow(p.y).to(0b11)
        else if (std.mem.eql(u8, p.what, "div"))
            S.probe(0, p.x).div(S.con(p.y)).to(0b11)
        else if (std.mem.eql(u8, p.what, "sel"))
            S.sel(S.con(p.x), a, S.con(0.0)).to(0b11)
        else if (std.mem.eql(u8, p.what, "lt"))
            S.probe(0, p.x).lt(S.con(p.y)).to(0b11)
        else if (std.mem.eql(u8, p.what, "le"))
            S.probe(0, p.x).le(S.con(p.y)).to(0b11)
        else
            S.probe(0, p.x).eq(S.con(p.y)).to(0b11);
        if (!famSame(r.val(), p.v) or (p.d != null and !famSame(r.ddxAt(0), p.d.?))) {
            std.debug.print("expectFamily: {s}({e}, {e}) = ({e}, lane {e}), pinned ({e}, lane {?e})\n", .{ p.what, p.x, p.y, r.val(), r.ddxAt(0), p.v, p.d });
            return error.FamilyMismatch;
        }
    }
    // `to`'s new lanes are exactly +0.
    const w = S.con(2.0).to(0b11);
    if (@as(u64, @bitCast(w.ddxAt(0))) != 0 or @as(u64, @bitCast(w.ddxAt(1))) != 0) {
        std.debug.print("expectFamily: to() gave a new lane that is not +0\n", .{});
        return error.FamilyMismatch;
    }
}

// ---- private ----

/// Bits equal, or both NaN.
fn famSame(a: f64, b: f64) bool {
    return @as(u64, @bitCast(a)) == @as(u64, @bitCast(b)) or (std.math.isNan(a) and std.math.isNan(b));
}

fn famClose(a: f64, b: f64, rel: f64) bool {
    assert(rel > 0.0);
    if (famSame(a, b) or (a == 0 and b == 0)) return true;
    return std.math.isFinite(a) and std.math.isFinite(b) and @abs(a - b) <= rel * @max(@abs(a), @abs(b));
}

fn inF32(x: f64) bool {
    return x == 0 or (@abs(x) >= std.math.floatMin(f32) and @abs(x) <= std.math.floatMax(f32));
}

fn famExpect(comptime op: []const u8, narrow: bool, x: f64, y: f64, got: anytype, want: anytype, transcendental: bool) Error!void {
    comptime assert(@TypeOf(want).mask >> 2 == 0); // The reference's two unknowns.
    const gv = got.val();
    const wv = want.val();
    const v_ok = famSame(gv, wv) or (transcendental and bits.ulps(gv, wv) <= 1);
    const lanes = std.math.isFinite(x) and std.math.isFinite(y) and std.math.isFinite(wv);
    // Past f32's range an f32 lane rightly flushes or overflows, and so does
    // a coefficient on its way into one.
    const in_range = !narrow or (inF32(x) and inF32(y) and inF32(want.ddxAt(0)) and inF32(want.ddxAt(1)));
    inline for (0..2) |u| {
        // A dense host's `0·inf` on a lane the sparse reference never carries.
        const dense_nan = (@TypeOf(want).mask >> u) & 1 == 0 and std.math.isNan(got.ddxAt(u));
        if (!v_ok or (lanes and in_range and !dense_nan and !famClose(got.ddxAt(u), want.ddxAt(u), 1e-6))) {
            std.debug.print("expectFamily: {s}({e}, {e}) = ({e}, lane{d} {e}), reference ({e}, lane{d} {e})\n", .{ op, x, y, gv, u, got.ddxAt(u), wv, u, want.ddxAt(u) });
            return error.FamilyMismatch;
        }
    }
}

test "RefFamily meets the numerics table: f64 and f32 lanes" {
    const lane = [_]u8{ 0, 1 };
    try expectFamily(family.RefFamily(f64, &lane, .{}));
    try expectFamily(family.RefFamily(f32, &lane, .{}));
    // Lane-free, the value-only family a host may run its value paths on,
    // is still a family, and an unknown it does not carry reads 0.
    const V = family.RefFamily(f64, &.{ family.no_lane, family.no_lane }, .{});
    family.checkFamily(V);
    const x = V.probe(1, 3.0).mul(V.probe(1, 3.0));
    try std.testing.expect(@TypeOf(x) == V.Of(0));
    try std.testing.expectEqual(@as(f64, 9.0), x.val());
    try std.testing.expectEqual(@as(f64, 0.0), x.ddxAt(1));
}
