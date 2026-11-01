//! A device's noise declarations in, the PSD tables and rows a host
//! integrates out: one generator per `noise_gens` row (`NoiseGen`), its
//! density at a state vector (`PsdTerm`), and the §4.6.4.3/.4 tabulated
//! spectra (`NoiseTable`, `noiseTable`, `noiseTableAt`). Also the rules
//! `validate` applies to these tables.
//! Cites: VAMS-2023 §4.6.4 (noise), §4.6.4.1 (a generator in a potential
//! contribution), §4.6.4.3 `noise_table`, §4.6.4.4 `noise_table_log`,
//! §4.6.4.6 (correlation).
//!
//! Contents:
//! - `pub fn NoiseGen(comptime D: type) type`
//! - `pub const NoiseTable = struct`
//! - `pub const PsdTerm = struct`
//! - `pub fn sortNoiseTable(pts: [][2]f64) void`
//! - `pub fn noiseTable(comptime D: type, model: *const D.Model, k: usize) NoiseTable`
//! - `pub fn noiseTableAt(t: NoiseTable, f: f64) f64`
//! - `pub fn noiseGensError(comptime D: type) ?[]const u8`
//! - `pub fn noisePsdError(comptime D: type) ?[]const u8`
//! - `pub fn noiseTablesError(comptime D: type) ?[]const u8`

const std = @import("std");
const assert = std.debug.assert;
const masks = @import("masks.zig");
const shape = @import("validate_shape.zig");
const nU = masks.nU;
const testing = std.testing;
const mocks = @import("mock_devices.zig");

/// §4.6.4.3 `noise_table` / §4.6.4.4 `noise_table_log`: one generator's PSD as
/// a piecewise (frequency, power) table. Position k of the device's optional
/// `noise_tables` is what `NoiseGen.table == k` names. Comptime data, so a
/// host that integrates a spectrum gets the knots.
///
/// `validate` guarantees: at least one point, frequencies strictly ascending
/// and > 0, powers >= 0, and > 0 in a `.log` table. When the device declares
/// `noiseTablePoints`, these are only the parameter defaults; a host reads a
/// generator's table through `noiseTable`, which gives the card's knots.
pub const NoiseTable = struct {
    /// §4.6.4.3 linear in (f, p); §4.6.4.4 linear in (log f, log p).
    interp: enum(u8) { linear, log },
    /// (frequency [Hz], power [units²/Hz]) pairs, ascending in frequency.
    points: []const [2]f64,
};

/// One generator's PSD at a state vector, position k of `noisePsd`'s result
/// (generator `noise_gens[k]`). The density generator k contributes is
///
///     S_k(f) = coeff² · (white + flicker/f^ef)                                   parametric row
///     S_k(f) = coeff² · noiseTableAt(noiseTable(D, &model, noise_gens[k].table.?), f)  table row
///
/// A table row's `white` and `flicker` are zero, so a host that adds both
/// shapes is right for every row. The device computes `white` itself.
pub const PsdTerm = struct {
    white: f64,
    flicker: f64 = 0,
    ef: f64 = 1,
    /// A generator this one is correlated with (BSIM4 tnoiMod, PSP igid), and
    /// the real correlation coefficient.
    corr_with: ?u8 = null,
    corr: f64 = 0,
    /// §4.6.4.6 the signed factor the contribution applies to this generator
    /// (the `c1` of `V(a,b) <+ c1*n`); it may depend on the bias. A host must
    /// apply it: the density is `coeff²` times the shape above, and the cross
    /// term of two rows sharing a `source` is `coeff_i · coeff_j` times the
    /// shared spectrum, whose sign distinguishes correlation from
    /// anti-correlation. 1.0 when the use reduces to no single factor.
    coeff: f64 = 1,
};

comptime {
    // Budget: `noisePsd` returns one per generator per frequency point (16
    // on psp103, 768 bytes a call); five f64 and a one-byte index.
    assert(@sizeOf(PsdTerm) <= 48);
}

/// §4.6.4 one noise generator: position k of `noise_gens` is a generator of
/// `kind` on the (row, col) branch, and position k of `noisePsd`'s result is
/// its PSD. A current generator (a noise function in a flow contribution)
/// has `row` and `col` as its nodes, or `row == col` for one to the
/// reference. A voltage generator (§4.6.4.1, a noise function in a potential
/// contribution) is in series with its branch: `row == col` is the branch's
/// current unknown (`U.@"flow(a,b)"`), and the generator enters that
/// unknown's own equation row, `V(a,b) − <value>`, with the row's sign
/// already in `PsdTerm.coeff`. A host adds `coeff·n` to row `row` and, when
/// `col` differs, subtracts it from `col`, whichever kind the unknown is.
/// A `.table` generator's PSD is its table at the card,
/// `noiseTable(D, &model, table.?)`; its `noisePsd` entry reads zero. The per-use scale factor is
/// `PsdTerm.coeff`, because it may depend on the bias.
pub fn NoiseGen(comptime D: type) type {
    const n = nU(D);
    comptime assert(n >= 1);
    return struct {
        row: std.math.IntFittingRange(0, n - 1),
        col: std.math.IntFittingRange(0, n - 1),
        kind: enum { thermal, shot, flicker, table },
        /// §4.6.4.6 correlation: rows with the same non-null `source` are one
        /// generator contributed to several branches, fully correlated.
        /// Distinct values, and null, are independent generators.
        source: ?u16 = null,
        /// §4.6.4.3/.4 index into the device's `noise_tables`. Non-null exactly
        /// when `kind == .table`; `validate` checks both halves.
        table: ?u16 = null,
        /// §4.6.4.1-.3 the optional `name` argument, empty when absent. A host
        /// groups its noise contribution REPORT by it. It says nothing about
        /// correlation: two rows may share a name and have different `source`
        /// values, and are then independent.
        name: []const u8 = "",
    };
}

/// Sorts `pts` by frequency in place (§4.6.4.3 "the simulator shall internally
/// sort the pairs into ascending frequency"). For the knots `noiseTablePoints`
/// returns, which a card computes, so any may be NaN: those sort last, where
/// `noiseTableAt` answers NaN between them. `noise_tables` arrives sorted.
pub fn sortNoiseTable(pts: [][2]f64) void {
    std.mem.sort([2]f64, pts, {}, struct {
        // A total order: `<` with NaN above every number.
        fn lt(_: void, a: [2]f64, b: [2]f64) bool {
            return a[0] < b[0] or (!std.math.isNan(a[0]) and std.math.isNan(b[0]));
        }
    }.lt);
    if (pts.len > 1) assert(!(pts[pts.len - 1][0] < pts[0][0]));
    if (pts.len > 1) assert(!std.math.isNan(pts[0][0]) or std.math.isNan(pts[pts.len - 1][0]));
}

/// Returns table `k` of `D` (`noise_gens[i].table == k`) as card `model` sets
/// it. For a table whose knots are model parameters (§4.6.4.3 "an array
/// parameter", or a pattern of parameters) that is the row's own sorted copy,
/// `model.noise_table_points__`, which `derive` writes from `noiseTablePoints`
/// after every card: `points` then points INTO `model`, so it lives as long as
/// the row and moves with it, and a host that copies or shares rows (a GPU, a
/// row tape) copies the knots with them. Any other table is `noise_tables[k]`.
/// A device with `noiseTablePoints` but no such field is from an earlier VerA,
/// and is a compile error here rather than its declared defaults.
pub fn noiseTable(comptime D: type, model: *const D.Model, k: usize) NoiseTable {
    assert(k < D.noise_tables.len);
    const t = D.noise_tables[k];
    if (comptime !@hasField(D.Model, "noise_table_points__")) {
        if (comptime @hasDecl(D, "noiseTablePoints"))
            @compileError(@typeName(D) ++ " has `noiseTablePoints` but no `Model.noise_table_points__`; " ++
                "regenerate it with this contract's VerA, or read `noiseTablePoints` directly");
        return t;
    }
    var off: usize = 0;
    for (D.noise_tables[0..k]) |t0| off += t0.points.len;
    assert(off + t.points.len <= model.noise_table_points__.len);
    return .{ .interp = t.interp, .points = model.noise_table_points__[off..][0..t.points.len] };
}

/// Returns the §4.6.4.3/.4 tabulated PSD at `f`. Outside the table it clamps
/// to the end power, as both clauses require; a one-point table is constant;
/// a NaN `f` gives NaN, and so does a segment ending in a NaN knot (a card's
/// knots sort NaN last, `sortNoiseTable`). Asserts that `t` has a point; the
/// rest of the declared tables' invariants are `validate`'s to check.
pub fn noiseTableAt(t: NoiseTable, f: f64) f64 {
    const p = t.points;
    assert(p.len >= 1);
    if (std.math.isNan(f)) return f;
    if (f <= p[0][0] or p.len == 1) return p[0][1];
    const top = p[p.len - 1];
    if (f >= top[0]) return top[1];
    // ponytail: linear scan. A noise table is a handful of points (the LRM's
    // own example is seven); a binary search is worth it at hundreds.
    // The scan stops at the first knot above `f` or at the top; a NaN knot
    // is above no frequency, so it stops there too.
    var i: usize = 1;
    while (i < p.len - 1 and p[i][0] <= f) i += 1;
    assert(i >= 1);
    assert(i < p.len);
    const a = p[i - 1];
    const b = p[i];
    return switch (t.interp) {
        .linear => a[1] + (b[1] - a[1]) * (f - a[0]) / (b[0] - a[0]),
        // §4.6.4.4's base-10 formula; the base cancels in the ratio.
        .log => @exp(@log(a[1]) + (@log(b[1]) - @log(a[1])) *
            (@log(f) - @log(a[0])) / (@log(b[0]) - @log(a[0]))),
    };
}

/// `noise_gens` is `[k]NoiseGen(D)`, and `noisePsd` comes with it.
pub fn noiseGensError(comptime D: type) ?[]const u8 {
    // A device without generators may have no unknowns (a display-only
    // module), and `NoiseGen` needs one to index.
    if (!@hasDecl(D, "noise_gens")) return shape.requireWithError(D, "noisePsd", "noise_gens");
    if (shape.arrayError(D, "noise_gens", NoiseGen(D))) |m| return m;
    return shape.requireWithError(D, "noisePsd", "noise_gens");
}

/// Noise PSDs: a pure function of any state vector. Only the weak direction
/// is checked (a PSD needs a generator); whether a generator without a PSD
/// is acceptable is the host's call.
pub fn noisePsdError(comptime D: type) ?[]const u8 {
    if (!@hasDecl(D, "noisePsd")) return null;
    return shape.genericError(D, "noisePsd", 5, "fn (comptime S: type, [n_u]f64, *const Model, *const Instance, SimState) [noise_gens.len]PsdTerm");
}

/// §4.6.4.3/.4 tables: `noiseTableAt`'s preconditions, checked here because
/// a violation otherwise surfaces as a NaN spectrum; a `.table` generator
/// names a table and only it does; and the card's knots
/// (`noiseTablePoints`, `Model.noise_table_points__`) cover every table.
pub fn noiseTablesError(comptime D: type) ?[]const u8 {
    if (shape.arrayError(D, "noise_tables", NoiseTable)) |m| return m;
    if (shape.requireWithError(D, "noise_tables", "noise_gens")) |m| return m;
    if (!@hasDecl(D, "noise_gens")) return null;
    const name = @typeName(D);
    const tables: []const NoiseTable = if (@hasDecl(D, "noise_tables")) &D.noise_tables else &.{};
    for (D.noise_gens) |g| {
        if ((g.kind == .table) != (g.table != null))
            return name ++ ".noise_gens: `.table` is set exactly on a `.table` generator";
        if (g.table) |k| if (k >= tables.len)
            return name ++ ".noise_gens: `.table` index is out of range of `noise_tables`";
    }
    for (tables) |t| {
        if (t.points.len == 0) return name ++ ".noise_tables: an empty table has no PSD to state";
        for (t.points, 0..) |p, i| {
            if (!(p[0] > 0)) return name ++ ".noise_tables: frequency must be positive";
            if (!(p[1] >= 0)) return name ++ ".noise_tables: power must be non-negative";
            if (t.interp == .log and !(p[1] > 0))
                return name ++ ".noise_tables: a log table interpolates log(power), so power must be positive";
            if (i != 0 and !(p[0] > t.points[i - 1][0]))
                return name ++ ".noise_tables: frequencies must be sorted and unique";
        }
    }
    // §4.6.4.3 array-parameter tables: `noise_tables` holds the declared
    // defaults, and this returns the card's knots, one flat array over
    // every table in `noise_tables` order.
    if (@hasDecl(D, "noiseTablePoints")) {
        var total: usize = 0;
        for (tables) |t| total += t.points.len;
        if (shape.fnError(D, "noiseTablePoints", fn (*const D.Model) [total][2]f64)) |m| return m;
        // The row's own sorted copy of those knots, which `derive` writes
        // and `noiseTable` reads. Optional.
        if (@hasField(D.Model, "noise_table_points__") and @FieldType(D.Model, "noise_table_points__") != [total][2]f64)
            return name ++ ".Model.noise_table_points__ must be [" ++
                std.fmt.comptimePrint("{d}", .{total}) ++ "][2]f64, the knots of every table in `noise_tables` order";
    } else if (@hasField(D.Model, "noise_table_points__"))
        return name ++ ".Model.noise_table_points__ without `noiseTablePoints`: nothing defines its knots";
    return null;
}

test "§4.6.4.3 noise_table interpolates linearly BETWEEN the pairs" {
    // Every `want` below is the clause's own arithmetic done by hand, not
    // whatever the evaluator returns: the segment [100, 200] rises 4 -> 10, so
    // a quarter of the way along it is 4 + 6/4 and half of it is 4 + 3.
    const t: NoiseTable = .{ .interp = .linear, .points = &.{ .{ 100, 4.0 }, .{ 200, 10.0 } } };
    try testing.expectApproxEqAbs(@as(f64, 5.5), noiseTableAt(t, 125), 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 7.0), noiseTableAt(t, 150), 1e-15);
    // The knots themselves, which no interpolation may move.
    try testing.expectEqual(@as(f64, 4.0), noiseTableAt(t, 100));
    try testing.expectEqual(@as(f64, 10.0), noiseTableAt(t, 200));
    // "for frequencies lower than the lowest frequency … returns the power
    // specified for the lowest frequency", and the same for the highest: a
    // clamp, never an extrapolated 1.0 below or 16.0 above.
    try testing.expectEqual(@as(f64, 4.0), noiseTableAt(t, 50));
    try testing.expectEqual(@as(f64, 4.0), noiseTableAt(t, 1e-9));
    try testing.expectEqual(@as(f64, 10.0), noiseTableAt(t, 1000));

    // Three points: the SECOND segment has to be the one that answers f = 3.
    const u: NoiseTable = .{ .interp = .linear, .points = &.{ .{ 1, 1.0 }, .{ 2, 4.0 }, .{ 4, 8.0 } } };
    try testing.expectApproxEqAbs(@as(f64, 2.5), noiseTableAt(u, 1.5), 1e-15);
    try testing.expectEqual(@as(f64, 4.0), noiseTableAt(u, 2));
    try testing.expectApproxEqAbs(@as(f64, 6.0), noiseTableAt(u, 3), 1e-15);

    // One pair is a legal table and a constant PSD: both clamps answer it.
    const one: NoiseTable = .{ .interp = .linear, .points = &.{.{ 5, 3.0 }} };
    try testing.expectEqual(@as(f64, 3.0), noiseTableAt(one, 1));
    try testing.expectEqual(@as(f64, 3.0), noiseTableAt(one, 5));
    try testing.expectEqual(@as(f64, 3.0), noiseTableAt(one, 1e9));
}

test "§4.6.4.3 noiseTable reads the card's knots from the Model row, and they move with it" {
    // mocks.MockAll's second knot power is 1e-18·g: the card's, not the default.
    var m: mocks.MockAll.Model = .{ .g = 2e-3 };
    mocks.MockAll.derive(f64, &m);
    const t = noiseTable(mocks.MockAll, &m, 0);
    try testing.expect(t.interp == .log);
    try testing.expectEqual(@as(usize, 2), t.points.len);
    try testing.expectEqual(1e-18 * @as(f64, m.g), t.points[0][1]);
    try testing.expect(t.points[0][1] != mocks.MockAll.noise_tables[0].points[0][1]);
    // The slice is the row's own storage, so a copied row carries the knots.
    try testing.expectEqual(@intFromPtr(&m.noise_table_points__), @intFromPtr(t.points.ptr));
    const copy = m;
    try testing.expectEqual(t.points[0][1], noiseTable(mocks.MockAll, &copy, 0).points[0][1]);
    // A row that never saw a card holds the declared defaults.
    const fresh: mocks.MockAll.Model = .{};
    try testing.expectEqualSlices([2]f64, mocks.MockAll.noise_tables[0].points, noiseTable(mocks.MockAll, &fresh, 0).points);
}

test "§4.6.4.4 noise_table_log is a straight line on a log-log plot" {
    // §4.6.4.4's own worked example: `noise_table_log('{1,1, 1e6,1e-6})`.
    // log10(p) falls 0 -> -6 while log10(f) rises 0 -> 6, so the line is
    // p = 1/f and every interior decade is exactly a decade down.
    const t: NoiseTable = .{ .interp = .log, .points = &.{ .{ 1, 1.0 }, .{ 1e6, 1e-6 } } };
    for ([_]f64{ 1e1, 1e2, 1e3, 1e4, 1e5 }) |f|
        try testing.expectApproxEqRel(1.0 / f, noiseTableAt(t, f), 1e-12);

    // Figure 4-14 is this difference: on the SAME two points the linear form
    // bows, and at 1 kHz it reads 1 + (1e-6 - 1)*(999/999999), nowhere near
    // the 1e-3 the log form gives.
    const lin: NoiseTable = .{ .interp = .linear, .points = t.points };
    const want = 1.0 + (1e-6 - 1.0) * (1e3 - 1.0) / (1e6 - 1.0);
    try testing.expectApproxEqRel(want, noiseTableAt(lin, 1e3), 1e-12);
    try testing.expect(noiseTableAt(lin, 1e3) > 0.9);

    // A slope that is not -1, and a knot that is not a decade boundary: the
    // line through (10, 1e-2) and (1000, 1e-6) is p = f^-2.
    const s: NoiseTable = .{ .interp = .log, .points = &.{ .{ 10, 1e-2 }, .{ 1000, 1e-6 } } };
    try testing.expectApproxEqRel(@as(f64, 1e-4), noiseTableAt(s, 100), 1e-12);
    try testing.expectApproxEqRel(@as(f64, 1.0 / (31.62277660168379 * 31.62277660168379)), noiseTableAt(s, 31.62277660168379), 1e-12);
    // Knots and clamps behave as in the linear mode.
    try testing.expectEqual(@as(f64, 1e-2), noiseTableAt(s, 10));
    try testing.expectEqual(@as(f64, 1e-6), noiseTableAt(s, 1000));
    try testing.expectEqual(@as(f64, 1e-2), noiseTableAt(s, 1));
    try testing.expectEqual(@as(f64, 1e-6), noiseTableAt(s, 1e9));

    // A flat log table is flat, not NaN: log(p2) - log(p1) = 0 is a legal line.
    const flat: NoiseTable = .{ .interp = .log, .points = &.{ .{ 1, 2e-9 }, .{ 100, 2e-9 } } };
    try testing.expectApproxEqRel(@as(f64, 2e-9), noiseTableAt(flat, 7), 1e-12);
}

test "§4.6.4.3 noiseTable: the declared table without the row's knots; table k's own slice with them" {
    const Declared = struct {
        pub const Model = struct {};
        pub const noise_tables = [_]NoiseTable{
            .{ .interp = .linear, .points = &.{.{ 1, 2 }} },
            .{ .interp = .log, .points = &.{ .{ 1, 1 }, .{ 10, 0.1 } } },
        };
    };
    const t = noiseTable(Declared, &.{}, 1);
    try testing.expect(t.interp == .log);
    try testing.expectEqual(@as(usize, 2), t.points.len);
    const Card = struct {
        pub const Model = struct { noise_table_points__: [3][2]f64 = .{ .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 } } };
        pub const noise_tables = [_]NoiseTable{
            .{ .interp = .linear, .points = &.{.{ 1, 0 }} },
            .{ .interp = .linear, .points = &.{ .{ 2, 0 }, .{ 3, 0 } } },
        };
    };
    const m: Card.Model = .{};
    // Table 0 holds one knot, so table 1 starts at the row's second.
    try testing.expectEqualSlices([2]f64, &.{ .{ 2, 6 }, .{ 3, 7 } }, noiseTable(Card, &m, 1).points);
}

test "sortNoiseTable sorts by frequency; noiseTableAt propagates a NaN frequency" {
    // §4.6.4.3: "the simulator shall internally sort the pairs".
    var pts = [_][2]f64{ .{ 3, 1 }, .{ 1, 2 }, .{ 2, 3 } };
    sortNoiseTable(&pts);
    try testing.expectEqualSlices([2]f64, &.{ .{ 1, 2 }, .{ 2, 3 }, .{ 3, 1 } }, &pts);
    // NaN is below no knot and above none: outside the precondition, NaN out.
    const t: NoiseTable = .{ .interp = .linear, .points = &pts };
    try testing.expect(std.math.isNan(noiseTableAt(t, std.math.nan(f64))));
}

test "noiseGensError: a device with no unknowns and no generators validates" {
    // Oracle: VAMS §4.6.4 (noise is optional) and the development contract,
    // which validated retained_builtin_constant_display.va's zero-unknown device.
    const D = struct {
        pub const U = enum(u8) {};
    };
    try std.testing.expectEqual(@as(?[]const u8, null), comptime noiseGensError(D));
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
    sortNoiseTable(&knots);
    try testing.expectEqual(@as(f64, 3), knots[0][0]);
    try testing.expectEqual(@as(f64, 5), knots[1][0]);
    try testing.expect(std.math.isNan(knots[2][0]));
    const t: NoiseTable = .{ .interp = .linear, .points = &knots };
    try testing.expectEqual(@as(f64, 3.0), noiseTableAt(t, 1)); // below the lowest knot
    try testing.expectApproxEqAbs(@as(f64, 2.0), noiseTableAt(t, 4), 1e-15); // (3,3) -> (5,1)
    try testing.expect(std.math.isNan(noiseTableAt(t, 6))); // the segment into the NaN knot
    try testing.expect(std.math.isNan(noiseTableAt(t, nan)));
    // A one-point table is constant on every frequency the host can name,
    // and NaN on the one it cannot.
    const one: NoiseTable = .{ .interp = .log, .points = &.{.{ 5, 3.0 }} };
    try testing.expectEqual(@as(f64, 3.0), noiseTableAt(one, 1e9));
    try testing.expect(std.math.isNan(noiseTableAt(one, nan)));
    // Every knot NaN: nothing is defined.
    var all = [_][2]f64{ .{ nan, 1.0 }, .{ nan, 2.0 } };
    sortNoiseTable(&all);
    try testing.expect(std.math.isNan(noiseTableAt(.{ .interp = .linear, .points = &all }, 1)));
}
