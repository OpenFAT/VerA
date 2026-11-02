//! A device's masks and charge-site table in, the types of what `eval` and
//! `q` return out (`Rows`, `Sites`), with the reactive residual's rows from
//! its sites (`qRows`) and a hand-written device's dense-to-typed helpers
//! (`probes`, `rows`, `sites`). Also the rule `validate` applies to the
//! charge-site table.
//! Cites: VAMS-2023 §5.6.1.2 (charge sites: a `ddt` term of a contribution),
//! §4.5.2 (an operator's internal unknown).
//!
//! `q` returns one charge per charge site (a `ddt` term of a contribution,
//! after unrolling and flattening), not one per residual row; `evalQ(...).q`
//! and `acceptQ` return the same `Sites`. Row r of the reactive residual is
//! Σ e.sign · q[e.site] over the `q_stamps` entries with e.row == r (`qRows`).
//! A host integrates and truncation-checks each site on its own, then stamps
//! the currents into rows. `q_lte[k]` says whether site k joins the
//! truncation check (VerA's `vera_lte` attribute clears it). A device without
//! `n_q` and `q_stamps` has one site per row, site k on row k with sign +1,
//! all checked. `jac_const.c`, `q_pattern` and `q_rows` stay per row;
//! `q_site_pattern[k]` is site k's column set. A §4.5.2 operator unknown
//! (each idt site, and a ddt off a contribution's spine) is an ordinary
//! internal `.voltage` unknown with its own row and site.
//!
//! Contents:
//! - `pub fn QStamp(comptime U: type) type`
//! - `pub fn nQ(comptime D: type) comptime_int`
//! - `pub fn qStamps(comptime D: type) []const QStamp(D.U)`
//! - `pub fn qLte(comptime D: type) [nQ(D)]bool`
//! - `pub fn qRowMask(comptime D: type, comptime r: usize) Mask(D)`
//! - `pub fn Rows(comptime D: type, comptime S: type) type`
//! - `pub fn Sites(comptime D: type, comptime S: type) type`
//! - `pub fn QRows(comptime D: type, comptime S: type) type`
//! - `pub fn qRows(comptime D: type, comptime S: type, q: Sites(D, S)) QRows(D, S)`
//! - `pub fn probes(comptime D: type, comptime S: type, x: *const [nU(D)]S.V) [nU(D)]S.Of(denseMask(D))`
//! - `pub fn rows(comptime D: type, comptime S: type, a: [nU(D)]S.Of(denseMask(D))) Rows(D, S)`
//! - `pub fn sites(comptime D: type, comptime S: type, a: [nQ(D)]S.Of(denseMask(D))) Sites(D, S)`
//! - `pub fn qSitesError(comptime D: type) ?[]const u8`

const std = @import("std");
const assert = std.debug.assert;
const masks = @import("masks.zig");
const testing = std.testing;
const mocks = @import("mock_devices.zig");
const family = @import("family.zig");
const Mask = masks.Mask;
const nU = masks.nU;
const denseMask = masks.denseMask;

/// One `q_stamps` entry: reactive row `row` gains `sign · q[site]`.
pub fn QStamp(comptime U: type) type {
    return struct { site: u16, row: U, sign: f64 };
}

/// Returns how many charges `q` returns: `n_q`, or |U| for the per-row layout.
pub fn nQ(comptime D: type) comptime_int {
    return if (@hasDecl(D, "n_q")) D.n_q else nU(D);
}

/// Returns the site-to-row map, sorted by (row, site); the identity for the
/// per-row layout.
pub fn qStamps(comptime D: type) []const QStamp(D.U) {
    if (@hasDecl(D, "q_stamps")) return D.q_stamps[0..];
    const n = nU(D);
    const id = comptime blk: {
        // SAFETY: the loop writes all n entries.
        var t: [n]QStamp(D.U) = undefined;
        for (&t, 0..) |*e, k| e.* = .{ .site = k, .row = @fromBackingInt(@intCast(k)), .sign = 1 };
        break :blk t;
    };
    return &id;
}

/// Returns, per site, whether it joins the truncation-error check: `q_lte`, or
/// all true when undeclared.
pub fn qLte(comptime D: type) [nQ(D)]bool {
    return if (@hasDecl(D, "q_lte")) D.q_lte else @splat(true);
}

/// Returns the lanes reactive row `r` carries: the union of the `siteMask`s
/// of the sites `q_stamps` puts on it. Asserts that `r` is a row of `D`.
pub fn qRowMask(comptime D: type, comptime r: usize) Mask(D) {
    comptime assert(r < nU(D));
    var m: Mask(D) = 0;
    for (qStamps(D)) |e| {
        if (@backingInt(e.row) == r) m |= masks.siteMask(D, e.site);
    }
    return m;
}

/// What `eval` returns for family `S`: row `r` as `S.Of(masks.rowMask(D, r))`,
/// in `U` order.
pub fn Rows(comptime D: type, comptime S: type) type {
    @setEvalBranchQuota(1_000_000);
    // SAFETY: the loop writes every entry.
    var ts: [nU(D)]type = undefined;
    for (&ts, 0..) |*t, r| t.* = S.Of(masks.rowMask(D, r));
    return @Tuple(&ts);
}

/// What `q` returns for family `S`: site `k` as `S.Of(siteMask(D, k))`.
pub fn Sites(comptime D: type, comptime S: type) type {
    @setEvalBranchQuota(1_000_000);
    // SAFETY: the loop writes every entry.
    var ts: [nQ(D)]type = undefined;
    for (&ts, 0..) |*t, k| t.* = S.Of(masks.siteMask(D, k));
    return @Tuple(&ts);
}

/// What `qRows` returns for family `S`: row `r` as `S.Of(qRowMask(D, r))`.
pub fn QRows(comptime D: type, comptime S: type) type {
    @setEvalBranchQuota(1_000_000);
    // SAFETY: the loop writes every entry.
    var ts: [nU(D)]type = undefined;
    for (&ts, 0..) |*t, r| t.* = S.Of(qRowMask(D, r));
    return @Tuple(&ts);
}

/// Returns the reactive residual's rows from the sites' charges:
/// `Σ sign · q[site]` per row, summed from +0 in `q_stamps` order.
pub fn qRows(comptime D: type, comptime S: type, q: Sites(D, S)) QRows(D, S) {
    @setEvalBranchQuota(1_000_000);
    // SAFETY: the first loop writes every row before the second reads one.
    var out: QRows(D, S) = undefined;
    inline for (0..nU(D)) |r| out[r] = S.con(0.0).to(qRowMask(D, r));
    inline for (comptime qStamps(D)) |e| {
        const r = @backingInt(e.row);
        comptime assert(r < nU(D));
        const s = q[e.site];
        out[r] = if (e.sign == 1) out[r].add(s) else if (e.sign == -1) out[r].sub(s) else out[r].add(s.scale(e.sign));
    }
    return out;
}

/// The unknowns as a hand-written device reads them: `probe` on every lane
/// it reads, widened to `denseMask`, and `con` on the rest.
pub fn probes(comptime D: type, comptime S: type, x: *const [nU(D)]S.V) [nU(D)]S.Of(denseMask(D)) {
    // SAFETY: the loop writes every entry.
    var p: [nU(D)]S.Of(denseMask(D)) = undefined;
    inline for (0..nU(D)) |u| p[u] = if (comptime (denseMask(D) >> u) & 1 != 0) S.probe(u, x[u]).to(denseMask(D)) else S.con(x[u]).to(denseMask(D));
    return p;
}

/// `Rows(D, S)` from rows a hand-written device computed at `denseMask`. A
/// compile error when `D` declares a `jac_pattern` narrower than that: the
/// device must then type each row itself.
pub fn rows(comptime D: type, comptime S: type, a: [nU(D)]S.Of(denseMask(D))) Rows(D, S) {
    // SAFETY: the loop writes every row.
    var r: Rows(D, S) = undefined;
    inline for (0..nU(D)) |u| r[u] = a[u].to(masks.rowMask(D, u));
    return r;
}

/// `Sites(D, S)` from charges a hand-written device computed at `denseMask`,
/// on the same terms as `rows`.
pub fn sites(comptime D: type, comptime S: type, a: [nQ(D)]S.Of(denseMask(D))) Sites(D, S) {
    // SAFETY: the loop writes every site.
    var r: Sites(D, S) = undefined;
    inline for (0..nQ(D)) |k| r[k] = a[k].to(masks.siteMask(D, k));
    return r;
}

/// `validate`'s charge-site rules, returned so each is testable: `n_q` and
/// `q_stamps` come together; every entry names a site below `n_q` with a
/// finite nonzero sign; entries are sorted by (row, site) with no repeat;
/// `q_lte` is `[n_q]bool`; `q_site_pattern` is `[n_q]Mask(D)`.
pub fn qSitesError(comptime D: type) ?[]const u8 {
    const name = @typeName(D);
    if (@hasDecl(D, "n_q") != @hasDecl(D, "q_stamps")) return name ++ ": n_q and q_stamps come together";
    if (@hasDecl(D, "q_lte") and @TypeOf(D.q_lte) != [nQ(D)]bool) return name ++ ".q_lte must be [n_q]bool";
    if (@hasDecl(D, "q_site_pattern") and @TypeOf(D.q_site_pattern) != [nQ(D)]Mask(D)) return name ++ ".q_site_pattern must be [n_q]" ++ @typeName(Mask(D)) ++ " (contract.Mask)";
    if (!@hasDecl(D, "q_stamps")) return null;
    if (@TypeOf(D.n_q) != usize and @TypeOf(D.n_q) != comptime_int) return name ++ ".n_q must be a usize";
    const t = qStamps(D);
    for (t, 0..) |e, k| {
        if (e.site >= D.n_q) return name ++ ".q_stamps: a site at or past n_q";
        if (e.sign == 0 or !std.math.isFinite(e.sign)) return name ++ ".q_stamps: a zero or non-finite sign";
        if (k == 0) continue;
        const p = t[k - 1];
        const pr: usize = @backingInt(p.row);
        const r: usize = @backingInt(e.row);
        if (r < pr or (r == pr and e.site <= p.site)) return name ++ ".q_stamps must be sorted by (row, site) with no duplicates";
    }
    return null;
}

test "q sites: rows are the signed sums of the stamps, and the table's rules refuse their mistakes" {
    // Two charges at the gate row: a per-row host would see one sum, the
    // per-site one sees both.
    const U3 = enum(u8) { g, s, d };
    const Two = struct {
        pub const U = U3;
        pub const n_q: usize = 2;
        pub const q_stamps = [_]QStamp(U3){
            .{ .site = 0, .row = .g, .sign = 1 },
            .{ .site = 1, .row = .g, .sign = 1 },
            .{ .site = 0, .row = .s, .sign = -1 },
            .{ .site = 1, .row = .d, .sign = -1 },
        };
        pub const q_lte = [n_q]bool{ true, false };
    };
    try testing.expect(comptime (qSitesError(Two) == null));
    const Values = family.RefFamily(f64, &@as([3]u8, @splat(family.no_lane)), .{});
    const qr = qRows(Two, Values, .{ Values.con(2.0), Values.con(0.5) });
    try testing.expectEqual(@as(f64, 2.5), qr[0].v);
    try testing.expectEqual(@as(f64, -2.0), qr[1].v);
    try testing.expectEqual(@as(f64, -0.5), qr[2].v);
    try testing.expectEqual([2]bool{ true, false }, qLte(Two));
    // No declaration: the per-row layout, identity stamps, every site checked.
    try testing.expectEqual(@as(usize, 3), qStamps(struct {
        pub const U = U3;
    }).len);
    // Unsorted, a site past n_q, a zero sign, and n_q without q_stamps.
    const Bad = struct {
        fn of(comptime t: []const QStamp(U3)) type {
            return struct {
                pub const U = U3;
                pub const n_q: usize = 2;
                pub const q_stamps = t[0..t.len].*;
            };
        }
    };
    try testing.expect(comptime (qSitesError(Bad.of(&.{ .{ .site = 0, .row = .s, .sign = 1 }, .{ .site = 0, .row = .g, .sign = 1 } })) != null));
    try testing.expect(comptime (qSitesError(Bad.of(&.{.{ .site = 2, .row = .g, .sign = 1 }})) != null));
    try testing.expect(comptime (qSitesError(Bad.of(&.{.{ .site = 0, .row = .g, .sign = 0 }})) != null));
    try testing.expect(comptime (qSitesError(struct {
        pub const U = U3;
        pub const n_q: usize = 1;
    }) != null));
}

test "qRows: a stamp's sign other than ±1 scales its charge" {
    const U1 = enum(u8) { a };
    const Values = family.RefFamily(f64, &@as([1]u8, @splat(family.no_lane)), .{});
    inline for (.{ 0.5, -0.25 }, .{ 2.0, -1.0 }) |sign, want| {
        const Scaled = struct {
            pub const U = U1;
            pub const n_q: usize = 1;
            pub const q_stamps = [_]QStamp(U1){.{ .site = 0, .row = .a, .sign = sign }};
        };
        try testing.expect(comptime qSitesError(Scaled) == null);
        // 4 · sign, the stamp's own product.
        try testing.expectEqual(@as(f64, want), qRows(Scaled, Values, .{Values.con(4.0)})[0].v);
    }
}

test "a family's rows carry the pattern's lanes" {
    const S = family.RefFamily(f64, &.{ 0, 1 }, .{});
    const r = mocks.MockAll.eval(S, &.{ 2.0, 1.0 }, &.{ .g = 0.5 }, &.{}, .{});
    try testing.expect(@TypeOf(r[0]) == S.Of(masks.rowMask(mocks.MockAll, 0)));
    try testing.expectEqual(@as(f64, 0.5), r[0].val());
    try testing.expectEqual(@as(f64, -0.5), r[1].ddxAt(0));
    try testing.expectEqual(@as(f64, 0.5), r[1].ddxAt(1));
    try testing.expectEqual(@as(usize, 1), masks.laneMasks(mocks.MockAll).len);
    // `q_site_pattern` narrows each charge to its own unknown.
    const qs = mocks.MockAll.q(S, &.{ 2.0, 1.0 }, &.{}, &.{}, .{});
    try testing.expect(@TypeOf(qs[1]) == S.Of(0b10));
    const qr = qRows(mocks.MockAll, S, qs);
    try testing.expectEqual(@as(f64, -1e-12), qr[1].ddxAt(1));
}
