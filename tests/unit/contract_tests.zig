const std = @import("std");
const contract = @import("contract");
const testing = std.testing;

test "sortNoiseTable sorts by frequency; noiseTableAt propagates a NaN frequency" {
    // §4.6.4.3: "the simulator shall internally sort the pairs".
    var pts = [_][2]f64{ .{ 3, 1 }, .{ 1, 2 }, .{ 2, 3 } };
    contract.sortNoiseTable(&pts);
    try testing.expectEqualSlices([2]f64, &.{ .{ 1, 2 }, .{ 2, 3 }, .{ 3, 1 } }, &pts);
    // NaN is below no knot and above none: outside the precondition, NaN out.
    const t: contract.NoiseTable = .{ .interp = .linear, .points = &pts };
    try testing.expect(std.math.isNan(contract.noiseTableAt(t, std.math.nan(f64))));
}

test "§4.6.4.3 a card's NaN knot or a host's NaN frequency gives NaN, never a crash" {
    // Input, not a contract: a card knot is whatever the card computes
    // (`sqrt` of a negative parameter is NaN, no range forbids it) and `f` is
    // whatever the host asks. Oracle: §4.6.4.3 defines no PSD for a NaN, so
    // the answer is NaN (IEEE 754 §6.2 propagation); the defined clamps and
    // segments a NaN knot does not touch keep their values, as the clause's
    // own arithmetic gives them.
    const nan = std.math.nan(f64);
    // [5, NaN, 3]: the comparison sort leaves a NaN mid-table, with 3 after 5.
    var knots = [_][2]f64{ .{ 5, 1.0 }, .{ nan, 2.0 }, .{ 3, 3.0 } };
    contract.sortNoiseTable(&knots);
    try testing.expectEqual(@as(f64, 3), knots[0][0]);
    try testing.expectEqual(@as(f64, 5), knots[1][0]);
    try testing.expect(std.math.isNan(knots[2][0]));
    const t: contract.NoiseTable = .{ .interp = .linear, .points = &knots };
    try testing.expectEqual(@as(f64, 3.0), contract.noiseTableAt(t, 1)); // below the lowest knot
    try testing.expectApproxEqAbs(@as(f64, 2.0), contract.noiseTableAt(t, 4), 1e-15); // (3,3) -> (5,1)
    try testing.expect(std.math.isNan(contract.noiseTableAt(t, 6))); // the segment into the NaN knot
    try testing.expect(std.math.isNan(contract.noiseTableAt(t, nan)));
    // A one-point table is constant on every frequency the host can name,
    // and NaN on the one it cannot.
    const one: contract.NoiseTable = .{ .interp = .log, .points = &.{.{ 5, 3.0 }} };
    try testing.expectEqual(@as(f64, 3.0), contract.noiseTableAt(one, 1e9));
    try testing.expect(std.math.isNan(contract.noiseTableAt(one, nan)));
    // Every knot NaN: nothing is defined.
    var all = [_][2]f64{ .{ nan, 1.0 }, .{ nan, 2.0 } };
    contract.sortNoiseTable(&all);
    try testing.expect(std.math.isNan(contract.noiseTableAt(.{ .interp = .linear, .points = &all }, 1)));
}
