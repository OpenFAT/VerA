//! The scalar-family helpers as Zig source text (`codegen/family.zig`): how
//! every body and kernel reaches a family, and device.zig's half of them.
//! `file.wideText` widens both for a device past 64 unknowns.
//! Cites: none of its own (the contract's family, `lib/contract.zig`).
//!
//! Contents:
//! - `pub const family_txt: []const u8`
//! - `pub const family_dev_txt: []const u8`

/// The scalar-family helpers (`codegen/family.zig`), emitted after `ops_txt`:
/// how every body and kernel reaches a family. Masks are narrowed by `zdr`,
/// the device's `deriv_reads` (declared by `family_dev_txt` in device.zig and
/// by the `h.zig` head), so no mask names a lane the host did not ask for.
pub const family_txt =
    \\// ---- the scalar family (`contract.family_fns`) ----
    \\//
    \\// A real is typed `zOf(S, m)`, `m` the unknowns it may depend on.
    \\
    \\fn zOf(comptime S: type, comptime m: u64) type {
    \\    @setEvalBranchQuota(1_000_000);
    \\    return S.Of(m & zdr);
    \\}
    \\/// `a` widened to `zOf(S, m)`: a compile error when `a` carries a lane
    \\/// `m` does not name.
    \\fn zTo(comptime S: type, comptime m: u64, a: anytype) zOf(S, m) {
    \\    return a.to(m & zdr);
    \\}
    \\fn zV(a: anytype) f64 {
    \\    return a.val();
    \\}
    \\/// §4.3.1 "abs(x) is equivalent to (x > 0) x : -x": a family carries no
    \\/// `abs`, so the conditional is spelled here.
    \\fn zAbs(comptime S: type, a: anytype) @TypeOf(a) {
    \\    return S.sel(S.con(0.0).lt(a), a, a.neg());
    \\}
    \\/// `zOf(S, m)` as one scalar type, for the kernels above, which are
    \\/// written against one: every operation of the kernel runs at mask `m`.
    \\/// min, max, abs and the slew clamps are §4.3.1's conditionals.
    \\fn zL(comptime S: type, comptime m: u64) type {
    \\    return struct {
    \\        v: zOf(S, m),
    \\        const T = @This();
    \\        fn w(a: anytype) T { return .{ .v = zTo(S, m, a) }; }
    \\        pub fn con(c: f64) T { return w(S.con(c)); }
    \\        pub fn val(a: T) f64 { return a.v.val(); }
    \\        pub fn ddxAt(a: T, comptime u: usize) f64 { return a.v.ddxAt(u); }
    \\        pub fn add(a: T, b: T) T { return .{ .v = a.v.add(b.v) }; }
    \\        pub fn sub(a: T, b: T) T { return .{ .v = a.v.sub(b.v) }; }
    \\        pub fn mul(a: T, b: T) T { return .{ .v = a.v.mul(b.v) }; }
    \\        pub fn div(a: T, b: T) T { return .{ .v = a.v.div(b.v) }; }
    \\        pub fn neg(a: T) T { return .{ .v = a.v.neg() }; }
    \\        pub fn scale(a: T, c: f64) T { return .{ .v = a.v.scale(c) }; }
    \\        pub fn addC(a: T, c: f64) T { return .{ .v = a.v.addC(c) }; }
    \\        pub fn exp(a: T) T { return .{ .v = a.v.exp() }; }
    \\        pub fn log(a: T) T { return .{ .v = a.v.log() }; }
    \\        pub fn expm1(a: T) T { return .{ .v = a.v.expm1() }; }
    \\        pub fn log1p(a: T) T { return .{ .v = a.v.log1p() }; }
    \\        pub fn sqrt(a: T) T { return .{ .v = a.v.sqrt() }; }
    \\        pub fn sin(a: T) T { return .{ .v = a.v.sin() }; }
    \\        pub fn cos(a: T) T { return .{ .v = a.v.cos() }; }
    \\        pub fn tanh(a: T) T { return .{ .v = a.v.tanh() }; }
    \\        pub fn sinh(a: T) T { return .{ .v = a.v.sinh() }; }
    \\        pub fn cosh(a: T) T { return .{ .v = a.v.cosh() }; }
    \\        pub fn atan(a: T) T { return .{ .v = a.v.atan() }; }
    \\        pub fn pow(a: T, c: f64) T { return .{ .v = a.v.pow(c) }; }
    \\        pub fn lt(a: T, b: T) T { return w(a.v.lt(b.v)); }
    \\        pub fn le(a: T, b: T) T { return w(a.v.le(b.v)); }
    \\        pub fn eq(a: T, b: T) T { return w(a.v.eq(b.v)); }
    \\        pub fn sel(c: T, a: T, b: T) T { return .{ .v = S.sel(c.v, a.v, b.v) }; }
    \\        pub fn min(a: T, b: T) T { return a.lt(b).sel(a, b); }
    \\        pub fn max(a: T, b: T) T { return b.lt(a).sel(a, b); }
    \\        pub fn abs(a: T) T { return con(0.0).lt(a).sel(a, a.neg()); }
    \\        pub fn minC(a: T, c: f64) T { return con(c).lt(a).sel(con(c), a); }
    \\        pub fn maxC(a: T, c: f64) T { return a.lt(con(c)).sel(con(c), a); }
    \\    };
    \\}
    \\/// `zPow` at mask `m`; a batch family (`batch_lead`) runs it once per
    \\/// point on its scalar `Lane` family, since it steers on both values.
    \\fn zPowL(comptime S: type, comptime m: u64, a: zOf(S, m), b: zOf(S, m), comptime ve: bool) zOf(S, m) {
    \\    if (comptime @hasDecl(S, "Lane")) {
    \\        var ls: [S.lane_count]zOf(S.Lane, m) = undefined;
    \\        inline for (0..S.lane_count) |w| ls[w] = zPowL(S.Lane, m, S.laneOf(a, w), S.laneOf(b, w), ve);
    \\        return S.fromLanes(m & zdr, ls);
    \\    }
    \\    return zLu(S, m, zPow(zL(S, m), zLw(S, m, a), zLw(S, m, b), ve));
    \\}
    \\fn zLw(comptime S: type, comptime m: u64, a: anytype) zL(S, m) {
    \\    return .{ .v = zTo(S, m, a) };
    \\}
    \\fn zLu(comptime S: type, comptime m: u64, a: zL(S, m)) zOf(S, m) {
    \\    return a.v;
    \\}
    \\
    \\
;

/// device.zig's half of the family helpers: `zdr`, a row as the family
/// returns it, and the unknowns an entry point hands its core.
pub const family_dev_txt =
    \\const zdr = contract.derivReads(Self);
    \\fn zRow(comptime S: type, comptime r: U, a: anytype) zOf(S, contract.rowMask(Self, @intFromEnum(r))) {
    \\    return zTo(S, contract.rowMask(Self, @intFromEnum(r)), a);
    \\}
    \\fn zRowsZero(comptime S: type) contract.Rows(Self, S) {
    \\    var r: contract.Rows(Self, S) = undefined;
    \\    inline for (0..n_u) |u| r[u] = zTo(S, contract.rowMask(Self, u), S.con(0.0));
    \\    return r;
    \\}
    \\/// The unknowns as an entry point's core reads them: a probe for each
    \\/// lane the device reads, a constant for every other.
    \\fn zX(comptime S: type) type {
    \\    @setEvalBranchQuota(1_000_000);
    \\    var ts: [n_u]type = undefined;
    \\    for (&ts, 0..) |*t, u| t.* = zOf(S, if (u < 64) @as(u64, 1) << u else ~@as(u64, 0));
    \\    return @Tuple(&ts);
    \\}
    \\fn zProbe(comptime S: type, x: *const [n_u]S.V) zX(S) {
    \\    var p: zX(S) = undefined;
    \\    inline for (0..n_u) |u| p[u] = if (comptime u >= 64 or (zdr >> u) & 1 != 0) S.probe(u, x[u]) else if (S.V == f64) S.con(x[u]) else S.lift(x[u]);
    \\    return p;
    \\}
    \\/// The unknowns as values only, for the entry points that read the core
    \\/// without lanes.
    \\fn zVals(comptime S: type, x: *const [n_u]f64) [n_u]zOf(S, 0) {
    \\    var p: [n_u]zOf(S, 0) = undefined;
    \\    for (&p, x) |*o, v| o.* = S.con(v);
    \\    return p;
    \\}
    \\
    \\
;
