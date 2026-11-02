//! A device's unknowns and its optional mask declarations in, the bit masks
//! over `U` a host and a family read out: which unknowns carry a derivative
//! lane (`derivReads`), which `limit` reads and writes, which `ddx` reads,
//! the lanes each residual row and charge site carries, and the exact
//! constant partials of the columns without a lane (`jacConst`). Also the
//! rules `validate` applies to these declarations.
//! Cites: VAMS-2023 §4.5.14 (`ddx`), §5.6 (the structural Jacobian),
//! §5.6.5 (collapsible branches), §9.17.3 (limiting).
//!
//! Contents:
//! - `pub fn nU(comptime D: type) comptime_int`
//! - `pub fn MaskOf(comptime n: usize) type`
//! - `pub fn Mask(comptime D: type) type`
//! - `pub fn derivReads(comptime D: type) Mask(D)`
//! - `pub fn limitReads(comptime D: type) Mask(D)`
//! - `pub fn limitWrites(comptime D: type) Mask(D)`
//! - `pub fn ddxReads(comptime D: type) Mask(D)`
//! - `pub fn JacConst(comptime U: type) type`
//! - `pub const JacWhen = struct { flag: []const u8, collapse_open: bool }`
//! - `pub fn jacConstApplies(comptime D: type, comptime e: JacConst(D.U), model: *const D.Model, collapsed: bool) bool`
//! - `pub fn jacConst(comptime D: type) []const JacConst(D.U)`
//! - `pub fn unknownsMask(comptime D: type) Mask(D)`
//! - `pub fn denseMask(comptime D: type) Mask(D)`
//! - `pub fn rowMask(comptime D: type, comptime r: usize) Mask(D)`
//! - `pub fn siteMask(comptime D: type, comptime k: usize) Mask(D)`
//! - `pub const LaneUse = struct { mask: u64, uses: u32 }`
//! - `pub fn laneMasks(comptime D: type) []const LaneUse`
//! - `pub fn derivReadsError(comptime D: type, comptime n: usize) ?[]const u8`
//! - `pub fn rowMaskError(comptime D: type, comptime name: []const u8, comptime decl: []const u8, comptime half: []const u8) ?[]const u8`

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const mocks = @import("mock_devices.zig");

/// The guard on a `jac_const` entry, for a partial that is constant per model
/// card and host rather than per device (a §5.6.5 collapsible branch's KCL
/// stamps). The entry applies iff `@field(model, flag)` is nonzero and
/// `collapse_open == !collapsed`, where `collapsed` is the family's
/// `collapse_applied`. `flag` is a `Model` field name; VerA's are
/// `<flow unknown>__retained` fields that `derive` fills, so the host must
/// call `derive` first.
pub const JacWhen = struct { flag: []const u8, collapse_open: bool };

/// One distinct `Of` mask a device declares reals at, and how many it
/// declares: data for a host's width policy (`laneMasks`), never a width.
pub const LaneUse = struct { mask: u64, uses: u32 };

/// Returns |U|, the device's number of unknowns.
pub fn nU(comptime D: type) comptime_int {
    return @typeInfo(D.U).@"enum".field_names.len;
}

/// The mask type over `n` unknowns, one bit per unknown: `u64` up to 64
/// unknowns, `u<n>` past them.
pub fn MaskOf(comptime n: usize) type {
    return @Int(.unsigned, @max(64, n));
}

/// `D`'s mask type: the type of its `deriv_reads` (`MaskOf(|U|)`, which
/// `validate` checks), or `u64` when it declares none. A device past 64
/// unknowns that declares no masks keeps the dense `u64` default, so a host
/// that only handles `u64` masks still gets every device it got before; one
/// that declares `deriv_reads` names its other masks (`ddx_reads`,
/// `jac_pattern`, `rowMask`) in the same type.
pub fn Mask(comptime D: type) type {
    return if (@hasDecl(D, "deriv_reads")) @TypeOf(D.deriv_reads) else u64;
}

/// Returns the unknowns that need a derivative lane, as a bit mask over `U`
/// (bit i is `@backingInt` value i): `D.deriv_reads`, or all ones when
/// undeclared. A superset.
///
/// For every unknown outside the mask, each ∂eval[row]/∂x[u] and ∂q[row]/∂x[u]
/// is a compile-time constant, and `jacConst` holds its exact value; the device
/// reads such an unknown with `S.con`, so no lane carries its partial. A host
/// stamps `jacConst` for those columns. Their matrix slots stay in
/// `jac_pattern`/`q_pattern` and `jac_rows`/`q_rows`.
///
/// `validate` enforces (`derivReadsError`): (a) a declared mask is
/// `MaskOf(|U|)`; (b) on a device with `limit`, `limitWrites ⊆ derivReads`,
/// because the host's limiting correction is lane-indexed; (c) `jac_const` is
/// sorted by (row, col), has no duplicate, no all-zero entry and no column
/// inside the mask, and a guard's `when.flag` names a `Model` field; (d)
/// `ddxReads ⊆ derivReads`.
pub fn derivReads(comptime D: type) Mask(D) {
    return if (@hasDecl(D, "deriv_reads")) D.deriv_reads else ~@as(u64, 0);
}

/// Returns the unknowns `limit` loads from `cur`/`old`, as a bit mask over `U`:
/// `D.limit_reads`, or all ones when undeclared. A superset.
pub fn limitReads(comptime D: type) Mask(D) {
    return if (@hasDecl(D, "limit_reads")) D.limit_reads else ~@as(Mask(D), 0);
}

/// Returns the unknowns `limit`/`seed` can store, as a bit mask over `U`:
/// `D.limit_writes`, or all ones when undeclared. A superset. An unknown
/// outside it is never limited, so its previous limited value is the host's
/// own previous iterate, not the plane `limit` writes into.
pub fn limitWrites(comptime D: type) Mask(D) {
    return if (@hasDecl(D, "limit_writes")) D.limit_writes else ~@as(Mask(D), 0);
}

/// Returns the unknowns whose partial §4.5.14 `ddx` reads, as a bit mask over
/// `U`: `D.ddx_reads`, or all ones when undeclared. The device calls
/// `S.ddxAt(u)` with `u` an unknown index and uses the result as a value, so a
/// family must map `u` to its own lane; a wrong map is a wrong residual.
pub fn ddxReads(comptime D: type) Mask(D) {
    return if (@hasDecl(D, "ddx_reads")) D.ddx_reads else ~@as(Mask(D), 0);
}

/// One constant entry of the local Jacobian, for a column outside
/// `derivReads`: `g` is ∂eval[row]/∂x[col] and `c` is ∂q[row]/∂x[col], both
/// exact. An absent entry is exactly 0 in both. A guarded entry (`when`
/// non-null) applies only as `jacConstApplies` says.
pub fn JacConst(comptime U: type) type {
    return struct { row: U, col: U, g: f64, c: f64, when: ?JacWhen = null };
}

/// Returns whether `jac_const` entry `e` applies to `model` under a host whose
/// collapse state is `collapsed` (see `JacWhen`). An unguarded entry always
/// applies.
pub fn jacConstApplies(comptime D: type, comptime e: JacConst(D.U), model: *const D.Model, collapsed: bool) bool {
    const w = e.when orelse return true;
    if (w.collapse_open == collapsed) return false;
    const v = @field(model, w.flag);
    return if (@TypeOf(v) == bool) v else v != 0;
}

/// Returns the device's `jac_const`, sorted by (row, col), or empty when it
/// declares none.
pub fn jacConst(comptime D: type) []const JacConst(D.U) {
    return if (@hasDecl(D, "jac_const")) D.jac_const[0..] else &.{};
}

/// Every unknown of `D` as a mask: the low |U| bits.
pub fn unknownsMask(comptime D: type) Mask(D) {
    const M = Mask(D);
    const m: M = if (nU(D) >= @bitSizeOf(M)) ~@as(M, 0) else (@as(M, 1) << nU(D)) - 1;
    comptime assert(@popCount(m) == @min(nU(D), @bitSizeOf(M)));
    return m;
}

/// Every unknown `D` reads a lane of, as the one mask a hand-written device
/// computes at: `S.Of(denseMask(D))` is a whole dense value.
pub fn denseMask(comptime D: type) Mask(D) {
    return derivReads(D) & unknownsMask(D);
}

/// The lanes residual row `r` carries: `jac_pattern[r]` inside
/// `derivReads`, every read lane when the device declares no pattern.
/// Asserts that `r` is a row of `D`.
pub fn rowMask(comptime D: type, comptime r: usize) Mask(D) {
    comptime assert(r < nU(D));
    const p: Mask(D) = if (@hasDecl(D, "jac_pattern")) D.jac_pattern[r] else ~@as(Mask(D), 0);
    return p & denseMask(D);
}

/// The lanes charge site `k` carries: `q_site_pattern[k]` inside `derivReads`.
pub fn siteMask(comptime D: type, comptime k: usize) Mask(D) {
    const p: Mask(D) = if (@hasDecl(D, "q_site_pattern")) D.q_site_pattern[k] else ~@as(Mask(D), 0);
    return p & denseMask(D);
}

/// Returns `D.lane_masks`, or one dense entry (`derivReads`) for a device
/// without it.
pub fn laneMasks(comptime D: type) []const LaneUse {
    if (@hasDecl(D, "lane_masks")) return &D.lane_masks;
    // `comptime`: called at run time, the literal would be a stack temporary
    // and the slice would dangle.
    const dense = comptime [_]LaneUse{.{ .mask = denseMask(D), .uses = 0 }};
    return &dense;
}

/// `derivReads`' rules (a)-(d), returned rather than raised so each is
/// testable. `n` is |U|, passed in so rule (a) is testable without a
/// 65-member enum.
pub fn derivReadsError(comptime D: type, comptime n: usize) ?[]const u8 {
    const name = @typeName(D);
    if (@hasDecl(D, "deriv_reads")) {
        if (@TypeOf(D.deriv_reads) != MaskOf(n)) return name ++ ".deriv_reads must be a " ++ @typeName(MaskOf(n)) ++ " mask over U (contract.MaskOf(|U|))";
    }
    if (@hasDecl(D, "limit") and (limitWrites(D) & ~derivReads(D)) != 0)
        return name ++ ".limit_writes has a bit deriv_reads does not: the limiting correction needs that lane";
    if (@hasDecl(D, "ddx_reads") and @TypeOf(D.ddx_reads) != Mask(D)) return name ++ ".ddx_reads must be a " ++ @typeName(Mask(D)) ++ " mask over U, deriv_reads' type";
    if ((ddxReads(D) & ~derivReads(D)) != 0)
        return name ++ ".ddx_reads has a bit deriv_reads does not: ddx() reads that lane";
    if (!@hasDecl(D, "jac_const")) return null;
    const mask = derivReads(D);
    const t = jacConst(D);
    for (t, 0..) |e, k| {
        const r: usize = @backingInt(e.row);
        const c: usize = @backingInt(e.col);
        if (c < @bitSizeOf(@TypeOf(mask)) and (mask >> @intCast(c)) & 1 != 0)
            return name ++ ".jac_const: column `" ++ @tagName(e.col) ++ "` is in deriv_reads, so its partials are not constant";
        if (e.g == 0 and e.c == 0)
            return name ++ ".jac_const: an all-zero entry — an absent entry already means exactly 0";
        if (e.when) |w| if (!@hasField(D.Model, w.flag))
            return name ++ ".jac_const: `when.flag` \"" ++ w.flag ++ "\" is not a field of Model";
        if (k == 0) continue;
        const pr: usize = @backingInt(t[k - 1].row);
        const pc: usize = @backingInt(t[k - 1].col);
        if (r < pr or (r == pr and c <= pc))
            return name ++ ".jac_const must be sorted by (row, col) with no duplicates";
    }
    return null;
}

/// Why `jac_rows`/`q_rows` (bit `ru` set when `half` ever writes row `ru`)
/// is wrong, or null. Containment runs one way only: a row with a live
/// pattern column must be marked written, never the reverse.
pub fn rowMaskError(
    comptime D: type,
    comptime name: []const u8,
    comptime decl: []const u8,
    comptime half: []const u8,
) ?[]const u8 {
    if (!@hasDecl(D, decl)) return null;
    if (@TypeOf(@field(D, decl)) != Mask(D))
        return name ++ "." ++ decl ++ " must be " ++ @typeName(Mask(D)) ++ " (contract.Mask)";
    if (!@hasDecl(D, half))
        return name ++ "." ++ decl ++ " without a `" ++ half ++ "` residual to describe";
    const pat = if (std.mem.eql(u8, half, "q")) "q_pattern" else "jac_pattern";
    if (!@hasDecl(D, pat)) return null;
    const mask: Mask(D) = @field(D, decl);
    for (@field(D, pat), 0..) |row, ru| {
        if (row == 0) continue;
        if ((mask >> @intCast(ru)) & 1 != 0) continue;
        return name ++ "." ++ decl ++ ": row " ++ std.fmt.comptimePrint("{d}", .{ru}) ++
            " has live " ++ pat ++ " columns but is not marked written";
    }
    return null;
}

test "deriv_reads: the four rules each refuse their own mistake" {
    // (a) the mask is one u64.
    try testing.expect(comptime (derivReadsError(mocks.MockVsrc, 3) == null));
    try testing.expect(comptime (derivReadsError(mocks.MockVsrc, 65) != null)); // a u64 past 64 unknowns
    // (b) a limited unknown needs a live lane.
    const Lim = struct {
        pub const U = enum(u8) { a, b };
        pub const deriv_reads: u64 = 0b01;
        pub const limit_writes: u64 = 0b10;
        pub fn limit() void {}
    };
    try testing.expect(comptime (derivReadsError(Lim, 2) != null));
    // A `limit` with no `limit_writes` writes ALL, so it needs every lane.
    const LimAll = struct {
        pub const U = enum(u8) { a, b };
        pub const deriv_reads: u64 = 0b01;
        pub fn limit() void {}
    };
    try testing.expect(comptime (derivReadsError(LimAll, 2) != null));
    // No `limit`, no constraint: `limitWrites`' all-ones default is not a write.
    const NoLim = struct {
        pub const U = enum(u8) { a, b };
        pub const deriv_reads: u64 = 0;
        pub const ddx_reads: u64 = 0;
    };
    try testing.expect(comptime (derivReadsError(NoLim, 2) == null));
    // (d) a ddx() column needs a live lane, and an undeclared `ddx_reads` is
    // ALL of them, so a device with a narrow mask must declare it.
    const Ddx = struct {
        pub const U = enum(u8) { a, b };
        pub const deriv_reads: u64 = 0b01;
        pub const ddx_reads: u64 = 0b10;
    };
    try testing.expect(comptime (derivReadsError(Ddx, 2) != null));
    const DdxAll = struct {
        pub const U = enum(u8) { a, b };
        pub const deriv_reads: u64 = 0b01;
    };
    try testing.expect(comptime (derivReadsError(DdxAll, 2) != null));
    // (c) unsorted, duplicated, all-zero, and a column that has a lane.
    const U3 = mocks.MockVsrc.U;
    const cases = [_][]const JacConst(U3){
        &.{ .{ .row = .n, .col = .br, .g = -1, .c = 0 }, .{ .row = .p, .col = .br, .g = 1, .c = 0 } },
        &.{ .{ .row = .p, .col = .br, .g = 1, .c = 0 }, .{ .row = .p, .col = .br, .g = 1, .c = 0 } },
        &.{.{ .row = .p, .col = .br, .g = 0, .c = 0 }},
        &.{.{ .row = .p, .col = .br, .g = 1, .c = 0 }},
    };
    const masks = [_]u64{ 0, 0, 0, 0b100 };
    inline for (cases, masks) |t, mk| {
        const Bad = struct {
            pub const U = U3;
            pub const deriv_reads: u64 = mk;
            pub const ddx_reads: u64 = 0;
            pub const jac_const = t;
        };
        try testing.expect(comptime (derivReadsError(Bad, 3) != null));
    }
    // A guard must name a real Model field.
    const Guarded = struct {
        pub const U = U3;
        pub const Model = struct { br__retained: f64 = 1 };
        pub const deriv_reads: u64 = 0;
        pub const ddx_reads: u64 = 0;
        pub const jac_const = [_]JacConst(U3){.{ .row = .p, .col = .br, .g = 1, .c = 0, .when = .{ .flag = "br__retained", .collapse_open = true } }};
    };
    try testing.expect(comptime (derivReadsError(Guarded, 3) == null));
    const Misnamed = struct {
        pub const U = U3;
        pub const Model = struct { br__retained: f64 = 1 };
        pub const deriv_reads: u64 = 0;
        pub const ddx_reads: u64 = 0;
        pub const jac_const = [_]JacConst(U3){.{ .row = .p, .col = .br, .g = 1, .c = 0, .when = .{ .flag = "nope", .collapse_open = true } }};
    };
    try testing.expect(comptime (derivReadsError(Misnamed, 3) != null));
    // And it applies exactly when the flag is set and the host did not collapse.
    const e = Guarded.jac_const[0];
    var gmodel: Guarded.Model = .{};
    try testing.expect(jacConstApplies(Guarded, e, &gmodel, false));
    try testing.expect(!jacConstApplies(Guarded, e, &gmodel, true));
    gmodel.br__retained = 0;
    try testing.expect(!jacConstApplies(Guarded, e, &gmodel, false));
    // And the defaults: nothing declared is all lanes and no table.
    try testing.expectEqual(~@as(u64, 0), derivReads(mocks.MockR));
    try testing.expectEqual(@as(usize, 0), jacConst(mocks.MockR).len);
}

test "jac_rows: an empty pattern row may still be written; a live one may not be unwritten" {
    // `isource`'s shape, and the whole reason the declaration exists: the DC
    // current depends on no unknown, so both column masks are empty while both
    // rows are written. A host that inferred "row dead" from "columns dead"
    // would delete it, so this direction has to stay legal.
    const Isrc = struct {
        pub const jac_pattern = [2]u64{ 0, 0 };
        pub const jac_rows: u64 = 0b11;
        pub fn eval() void {}
    };
    try testing.expect(comptime (rowMaskError(Isrc, "Isrc", "jac_rows", "eval") == null));

    // The unsound direction: row 1 has a live partial, so it is unarguably
    // written, and claiming otherwise deletes a real Jacobian entry.
    const Bad = struct {
        pub const jac_pattern = [2]u64{ 0, 0b10 };
        pub const jac_rows: u64 = 0b01;
        pub fn eval() void {}
    };
    try testing.expect(comptime (rowMaskError(Bad, "Bad", "jac_rows", "eval") != null));

    // And a mask with no residual to describe.
    const Orphan = struct {
        pub const q_rows: u64 = 0b11;
    };
    try testing.expect(comptime (rowMaskError(Orphan, "Orphan", "q_rows", "q") != null));
}

test "unknownsMask: 63 unknowns are the low 63 bits; 64 fill the u64 with no shift past it" {
    try testing.expectEqual(@as(u64, std.math.maxInt(u63)), comptime unknownsMask(mocks.MockN(63)));
    try testing.expectEqual(~@as(u64, 0), comptime unknownsMask(mocks.MockN(64)));
    try testing.expectEqual(@as(u64, 1), comptime denseMask(mocks.MockN(1)));
    try testing.expectEqual(@as(u64, 0), comptime denseMask(mocks.MockVsrc));
}

test "nU" {
    try testing.expectEqual(@as(comptime_int, 2), comptime nU(mocks.MockR));
}
