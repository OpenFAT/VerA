//! A lane table in, the reference scalar family out: `RefFamily(L, lane,
//! opts)`, a value in `f64` with one derivative lane of float type `L` per
//! carried unknown, computing the numerics table below. Also the decls every
//! host family must carry (`family_fns`, `family_primitives`, `checkFamily`)
//! and a family value as a dense matrix row (`denseRow`).
//! Cites: VAMS-2023 §4.3.1 (min, max and abs as conditionals), §4.5.14
//! (`ddx`), §5.6.5 (collapse); IEEE 754-2008 (the value half is bit-exact).
//!
//! Contents:
//! - `pub const family_fns: [5][]const u8`
//! - `pub const family_primitives: [25][]const u8`
//! - `pub const no_lane: u8`
//! - `pub const RefOptions = struct { collapse_applied: bool }`
//! - `pub fn checkFamily(comptime S: type) void`
//! - `pub fn RefFamily(comptime L: type, comptime lane: anytype, comptime opts: RefOptions) type`,
//!   whose decls are `collapse_applied`, `V`, `con`, `probe`, `sel` and `Of(m)`,
//!   a value with `mask` and the primitives `to`, `val`, `ddxAt`, `add`, `sub`,
//!   `neg`, `mul`, `div`, `scale`, `addC`, `exp`, `log`, `expm1`, `log1p`,
//!   `sqrt`, `sin`, `cos`, `tanh`, `sinh`, `cosh`, `atan`, `pow`, `lt`, `le`, `eq`
//! - `pub fn denseRow(comptime n: usize, a: anytype) [n]f64`

const std = @import("std");
const assert = std.debug.assert;
const build_config = @import("build_config.zig");
const gm = @import("gm.zig");
const masks = @import("masks.zig");
const MaskOf = masks.MaskOf;
const testing = std.testing;

// The device asks the host for `S.Of(mask)`, the scalar carrying the
// derivative lanes of exactly the unknowns `mask` names, and types each value
// by the unknowns it can depend on.
//
// The numerics, pinned per primitive so every family computes the same thing.
// Values are bit-exact except the transcendentals (exp log expm1 sin cos tanh
// sinh cosh atan pow), whose last ulp is the host's. Lanes follow the formula
// with one rounding per listed operation; FMA is optional.
//
//   add sub neg      IEEE; a lane present in one operand is copied (negated for sub)
//   mul              a·b; lanes mulAdd(b.d, a.v, a.d·b.v), a one-sided operand one product
//   div              IEEE q = a/b; lanes mulAdd(b.d, −q, a.d)·(1/b.v), an `Of(0)` divisor a.d·(1/b.v)
//   scale addC       a·c, a+c; lanes a.d·c, a.d
//   exp log expm1    d·e, d·(1/v), d·exp(v)
//   log1p sqrt       d·(1/(1+v)), d·(0.5/s) (0 unless s > 0)
//   sin cos          d·cos, d·(−sin)
//   tanh sinh cosh   d·(1−th²), d·cosh, d·sinh
//   atan             d·(1/(1+v²))
//   pow(x, c)        host pow; lanes d·(c·p/x), or d·(c·pow(0, c−1)) at x = 0; a non-finite slope is 0
//   lt le eq         IEEE compare → 1.0/0.0 (NaN gives 0), no lanes: `Of(0)`
//   sel(c, a, b)     c ≠ 0 ? a : b (a NaN c picks a), the winner's lanes widened to both
//   to(m)            the same value, lanes widened to `m`; the new ones are exactly +0
//
// §4.3.1 spells min, max and abs as conditionals, and so does the device:
// min = (x < y) ? x : y, max = (x > y) ? x : y, abs = (x > 0) ? x : −x, the
// slew clamps (c < a) ? c : a and (a < c) ? c : a, each over lt and sel and
// carrying the selected operand's lanes.

/// The decls of the family a host passes as `comptime S`: `Of(comptime m: u64)
/// type`; `V`, the type of one unknown's value (`f64`, or a vector for a
/// family that evaluates several operating points at once); `con(f64) Of(0)`
/// and, when `V` is not `f64`, `lift(V) Of(0)`; `probe(comptime u: usize, V)
/// Of(1 << u)`; `sel(c, a, b)` joining `a` and `b`.
///
/// The device probes only unknowns in `derivReads` and names only masks inside
/// it. A family may carry more lanes than a mask names, or map several
/// unknowns to one lane. Masks are `Mask(D)`, so past 64 unknowns too each
/// unknown has its own bit. A `V` other than `f64` is sound only for a device
/// that declares `batch_ok`.
///
/// Optional trait: `collapse_applied: bool = true` promises the host applied
/// the device's `collapse()` aliases to its gather and scatter maps; the
/// device then omits the collapsed branches' cancelling stamps.
pub const family_fns = [_][]const u8{ "Of", "V", "con", "probe", "sel" };

/// The methods every `Of(m)` value carries, with the numerics pinned in the
/// table above. A binary operation takes any `Of(m')` operand and returns
/// `Of(m | m')`; a unary one keeps `Of(m)`; `lt`/`le`/`eq` return `Of(0)`;
/// `to(comptime m2)` widens and is a compile error unless `m ⊆ m2`;
/// `ddxAt(comptime u)` is lane `u`, or 0 off the mask. Constants and results
/// cross as `f64` (`con`, `scale`, `addC`, `val`, `ddxAt`) and device code
/// never opens a value, so lanes may be narrower than `f64` (`jac_f32`).
pub const family_primitives = [_][]const u8{
    "addC",  "scale", "add",  "sub", "neg", "mul",   "div",  "exp",  "log",
    "expm1", "log1p", "sqrt", "pow", "sin", "cos",   "tanh", "sinh", "cosh",
    "atan",  "lt",    "le",   "eq",  "val", "ddxAt", "to",
};

// ---- the lead protocol (`batch_lead`) ----
//
// A device that declares `batch_lead` decides on per-point values: it
// compares reals, rounds them to integers, strips their lanes, or runs a

/// The `RefFamily` `lane[u]` entry for an unknown the family does not carry,
/// in a `u8` table. A wider table spells it as its element type's maximum.
pub const no_lane: u8 = std.math.maxInt(u8);

/// Options for `RefFamily`.
pub const RefOptions = struct {
    /// The family's `collapse_applied` trait (see `family_fns`).
    collapse_applied: bool = false,
};

/// `RefFamily`'s internal "not carried": `lane` normalized by `laneTable`.
const lane_none: u32 = std.math.maxInt(u32);

/// Whether the lanes' `mul` and `div` fuse (one rounding): the numerics table
/// makes FMA optional, so the target decides.
const fma_lanes = switch (@import("builtin").target.cpu.arch) {
    .x86_64 => std.Target.x86.featureSetHas(@import("builtin").target.cpu.features, .fma),
    .aarch64, .nvptx64, .amdgcn => true,
    else => false,
};

comptime {
    // Every primitive name is distinct, and the protocol decls too.
    for (family_primitives, 0..) |a, i| for (family_primitives[i + 1 ..]) |b| assert(!std.mem.eql(u8, a, b));
    assert(family_fns.len == 5);
}

/// Checks family `S` at comptime: its `family_fns` decls, and the
/// `family_primitives` of `Of(0)` and `Of(1)`. A no-op unless `validating`.
pub fn checkFamily(comptime S: type) void {
    if (!build_config.validating) return;
    if (@hasDecl(S, "collapse_applied") and @TypeOf(S.collapse_applied) != bool)
        @compileError(@typeName(S) ++ ": family collapse_applied must be bool");
    inline for (family_fns) |f| {
        if (!@hasDecl(S, f)) @compileError(@typeName(S) ++ ": family is missing `" ++ f ++ "`");
    }
    inline for (.{ S.Of(0), S.Of(1) }) |T| inline for (family_primitives) |p| {
        if (!@hasDecl(T, p)) @compileError(@typeName(T) ++ ": family value is missing primitive `" ++ p ++ "`");
    };
}

/// Returns the reference family: the numerics table above, lanes of float type `L`
/// (`f64`, or `f32` under `jac_f32`) beside an `f64` value. `Of(m)` carries
/// exactly the lanes of `m`'s unknowns that `lane` carries, in unknown order;
/// its masks are `MaskOf(lane.len)`. `lane` says only which unknowns are
/// carried: an entry is carried unless it is `no_lane`. It is a table (a
/// slice or a pointer to an array or tuple) of any unsigned element type:
/// `u8` with `no_lane` up to 255 entries, a wider element past them, where
/// the element's maximum is "not carried". A lane-free family (no entry
/// carried) runs every entry point on plain values. A host that indexes a
/// row at run time reads it through `denseRow`. Transcendentals go through
/// `gm`, so the family compiles for NVPTX and AMDGCN too.
pub fn RefFamily(comptime L: type, comptime lane: anytype, comptime opts: RefOptions) type {
    comptime assert(@typeInfo(L) == .float);
    return RefSparse(L, comptime laneTable(lane), opts.collapse_applied);
}

/// Value `a` of a `RefFamily` family as one column per unknown, `n` of them:
/// each lane at its unknown's column, +0 on every other. The row a host's
/// matrix indexes at run time (a Newton plane, a gate, an AC system).
/// Asserts (at comptime) that every lane's unknown is below `n`.
pub fn denseRow(comptime n: usize, a: anytype) [n]f64 {
    const m = @TypeOf(a).mask;
    const cols = comptime laneCols(m);
    comptime assert(cols.len == 0 or cols[cols.len - 1] < n);
    const lanes: [cols.len]@typeInfo(@TypeOf(a.d)).vector.child = a.d;
    var out: [n]f64 = @splat(0.0);
    for (cols, lanes) |u, l| out[u] = l;
    return out;
}

// ---- private ----

/// `lane` as `u32` entries, each element type's maximum (`no_lane` in a `u8`
/// table) mapped to `lane_none`. A `comptime_int` entry is always a lane.
fn laneTable(comptime lane: anytype) []const u32 {
    comptime {
        // `&std.simd.iota(u8, n)`: a pointer to a vector has no `.len`.
        const P = @typeInfo(@TypeOf(lane));
        if (P == .pointer and @typeInfo(P.pointer.child) == .vector) {
            const v = @typeInfo(P.pointer.child).vector;
            const a: [v.len]v.child = lane.*;
            return laneTable(&a);
        }
        @setEvalBranchQuota(10 * lane.len + 1000);
        var out: [lane.len]u32 = undefined;
        for (&out, 0..) |*o, u| {
            const l = lane[u];
            const E = @TypeOf(l);
            o.* = if (E != comptime_int and l == std.math.maxInt(E)) lane_none else l;
        }
        const final = out;
        assert(final.len == lane.len);
        return &final;
    }
}

/// The unknown each lane of mask `m` belongs to, in lane order.
fn laneCols(comptime m: anytype) [@popCount(m)]u32 {
    @setEvalBranchQuota(10 * @bitSizeOf(@TypeOf(m)) + 1000);
    var cols: [@popCount(m)]u32 = undefined;
    var j: usize = 0;
    for (0..@bitSizeOf(@TypeOf(m))) |u| if ((m >> u) & 1 != 0) {
        cols[j] = u;
        j += 1;
    };
    assert(j == cols.len);
    return cols;
}

inline fn laneFma(comptime T: type, a: T, b: T, c: T) T {
    return if (fma_lanes) @mulAdd(T, a, b, c) else a * b + c;
}

/// `pow`'s lane coefficient (§7[2]): c·p/x off zero, c·pow(0, c−1) at it, 0
/// when that is not finite.
fn powSlope(x: f64, c: f64, p: f64) f64 {
    const s = if (x != 0.0) c * p / x else c * gm.pow(x, c - 1.0);
    const slope = if (std.math.isFinite(s)) s else 0.0;
    assert(std.math.isFinite(slope));
    return slope;
}

/// `sqrt`'s lane coefficient: 0.5/s, and 0 unless s > 0.
fn sqrtSlope(s: f64) f64 {
    const slope = if (s > 0.0) 0.5 / s else 0.0;
    assert(!(slope < 0.0));
    return slope;
}

fn RefSparse(comptime L: type, comptime lane: []const u32, comptime collapsed: bool) type {
    const M = MaskOf(lane.len);
    return struct {
        pub const collapse_applied = collapsed;
        pub const V = f64;

        pub fn con(c: f64) Of(0) {
            return .{ .v = c, .d = .{} };
        }
        pub fn probe(comptime u: usize, v: f64) Of(@as(M, 1) << u) {
            return .{ .v = v, .d = @splat(1.0) };
        }
        pub fn sel(c: anytype, a: anytype, b: anytype) Of(@TypeOf(a).mask | @TypeOf(b).mask) {
            const r = @TypeOf(a).mask | @TypeOf(b).mask;
            return if (c.v != 0.0) a.to(r) else b.to(r);
        }

        /// The unknowns `lane` carries, one bit each: computed once per family.
        const carried: M = blk: {
            @setEvalBranchQuota(10 * lane.len + 1000);
            var c: M = 0;
            for (lane, 0..) |l, u| if (l != lane_none) {
                c |= @as(M, 1) << @intCast(u);
            };
            break :blk c;
        };

        /// The value type of mask `m`: it carries `m`'s lanes that `lane`
        /// carries, and an unknown it does not carry has no lane (its partial
        /// reads 0), so a lane-free family (every `lane[u]` `no_lane`) runs
        /// any entry point on plain values. O(1) at compile time on purpose:
        /// Zig 0.16 re-evaluates this call at every call site whose return
        /// type names it (`Join`, `zOf`, so every family operation in a
        /// device), not once per mask; the 64-step check loop it replaced was
        /// 39% of psp103's `eval` object build (23.4 -> 14.3 Gi).
        pub fn Of(comptime m: M) type {
            return OfCarried(m & carried);
        }

        fn OfCarried(comptime m: M) type {
            return struct {
                v: f64,
                d: Lanes align(@alignOf(L)),
                pub const mask = m;
                const Lanes = @Vector(@popCount(m), L);
                const T = @This();
                inline fn k(c: f64) Lanes {
                    return @splat(@as(L, @floatCast(c)));
                }
                fn map(a: T, v: f64, c: f64) T {
                    return .{ .v = v, .d = a.d * k(c) };
                }
                fn Join(comptime B: type) type {
                    return Of(m | B.mask);
                }
                inline fn kj(comptime B: type, c: f64) @Vector(@popCount(m | B.mask), L) {
                    return @splat(@as(L, @floatCast(c)));
                }

                /// This value's lanes in `to_m`'s layout; new lanes are exactly +0.
                inline fn spread(a: T, comptime to_m0: M) @Vector(@popCount(to_m0 & carried), L) {
                    const to_m = to_m0 & carried;
                    if (m & ~to_m != 0) @compileError(std.fmt.comptimePrint("RefFamily: mask 0x{x} does not widen to 0x{x}", .{ m, to_m }));
                    if (m == to_m) return a.d;
                    if (m == 0) return @splat(0.0);
                    const idx = comptime blk: {
                        @setEvalBranchQuota(100_000);
                        var idx: [@popCount(to_m)]i32 = undefined;
                        var j: usize = 0;
                        for (0..@bitSizeOf(M)) |u| if ((to_m >> u) & 1 != 0) {
                            idx[j] = if ((m >> u) & 1 != 0) @popCount(m & ((@as(M, 1) << u) - 1)) else -1;
                            j += 1;
                        };
                        break :blk idx;
                    };
                    const z: @Vector(1, L) = @splat(0.0);
                    return @shuffle(L, a.d, z, idx);
                }

                pub fn to(a: T, comptime to_m: M) Of(to_m) {
                    return .{ .v = a.v, .d = a.spread(to_m) };
                }
                pub fn val(a: T) f64 {
                    return a.v;
                }
                pub fn ddxAt(a: T, comptime u: usize) f64 {
                    if ((m >> u) & 1 == 0) return 0.0;
                    return a.d[@popCount(m & ((@as(M, 1) << u) - 1))];
                }

                pub fn add(a: T, b: anytype) Join(@TypeOf(b)) {
                    const r = m | @TypeOf(b).mask;
                    return .{ .v = a.v + b.v, .d = a.spread(r) + b.spread(r) };
                }
                pub fn sub(a: T, b: anytype) Join(@TypeOf(b)) {
                    const r = m | @TypeOf(b).mask;
                    return .{ .v = a.v - b.v, .d = a.spread(r) - b.spread(r) };
                }
                pub fn neg(a: T) T {
                    return .{ .v = -a.v, .d = -a.d };
                }
                pub fn mul(a: T, b: anytype) Join(@TypeOf(b)) {
                    const B = @TypeOf(b);
                    const r = m | B.mask;
                    if (B.mask == 0) return .{ .v = a.v * b.v, .d = a.spread(r) * kj(B, b.v) };
                    if (m == 0) return .{ .v = a.v * b.v, .d = b.spread(r) * kj(B, a.v) };
                    return .{ .v = a.v * b.v, .d = laneFma(@Vector(@popCount(r), L), b.spread(r), kj(B, a.v), a.spread(r) * kj(B, b.v)) };
                }
                pub fn div(a: T, b: anytype) Join(@TypeOf(b)) {
                    const B = @TypeOf(b);
                    const r = m | B.mask;
                    const inv = 1.0 / b.v;
                    const q = a.v / b.v;
                    if (B.mask == 0) return .{ .v = q, .d = a.spread(r) * kj(B, inv) };
                    return .{ .v = q, .d = laneFma(@Vector(@popCount(r), L), b.spread(r), kj(B, -q), a.spread(r)) * kj(B, inv) };
                }
                pub fn scale(a: T, c: f64) T {
                    return map(a, a.v * c, c);
                }
                pub fn addC(a: T, c: f64) T {
                    return .{ .v = a.v + c, .d = a.d };
                }
                pub fn exp(a: T) T {
                    const e = gm.exp(a.v);
                    return map(a, e, e);
                }
                pub fn log(a: T) T {
                    return map(a, gm.log(a.v), 1.0 / a.v);
                }
                pub fn expm1(a: T) T {
                    return map(a, gm.expm1(a.v), gm.exp(a.v));
                }
                pub fn log1p(a: T) T {
                    return map(a, gm.log1p(a.v), 1.0 / (1.0 + a.v));
                }
                pub fn sqrt(a: T) T {
                    const s = @sqrt(a.v);
                    return map(a, s, sqrtSlope(s));
                }
                pub fn sin(a: T) T {
                    return map(a, gm.sin(a.v), gm.cos(a.v));
                }
                pub fn cos(a: T) T {
                    return map(a, gm.cos(a.v), -gm.sin(a.v));
                }
                pub fn tanh(a: T) T {
                    const th = gm.tanh(a.v);
                    return map(a, th, 1.0 - th * th);
                }
                pub fn sinh(a: T) T {
                    return map(a, gm.sinh(a.v), gm.cosh(a.v));
                }
                pub fn cosh(a: T) T {
                    return map(a, gm.cosh(a.v), gm.sinh(a.v));
                }
                pub fn atan(a: T) T {
                    return map(a, gm.atan(a.v), 1.0 / (1.0 + a.v * a.v));
                }
                pub fn pow(a: T, c: f64) T {
                    const p = gm.pow(a.v, c);
                    return map(a, p, powSlope(a.v, c, p));
                }
                pub fn lt(a: T, b: anytype) Of(0) {
                    return con(@floatFromInt(@intFromBool(a.v < b.v)));
                }
                pub fn le(a: T, b: anytype) Of(0) {
                    return con(@floatFromInt(@intFromBool(a.v <= b.v)));
                }
                pub fn eq(a: T, b: anytype) Of(0) {
                    return con(@floatFromInt(@intFromBool(a.v == b.v)));
                }
            };
        }
    };
}

test "denseRow: each lane at its unknown's column, +0 elsewhere, past 64 too" {
    const S = RefFamily(f64, &@as([70]u8, @splat(0)), .{});
    const r = S.probe(2, 1.0).scale(3.0).add(S.probe(66, 2.0).scale(5.0));
    const d = denseRow(70, r);
    try testing.expectEqual(@as(f64, 3.0), d[2]);
    try testing.expectEqual(@as(f64, 5.0), d[66]);
    var nz: usize = 0;
    for (d) |e| nz += @intFromBool(e != 0.0);
    try testing.expectEqual(@as(usize, 2), nz);
}

test "RefFamily sparse: Of(m) carries exactly m's lanes, joins on binary ops" {
    const S = RefFamily(f64, &.{ 0, 1, 2, 3 }, .{});
    try testing.expectEqual(@as(usize, 3 * 8), @sizeOf(S.Of(0b0101))); // the value and two lanes
    const a = S.probe(0, 2.0);
    const c = S.probe(2, 3.0);
    const p = a.mul(c);
    try testing.expect(@TypeOf(p) == S.Of(0b0101));
    try testing.expectEqual(@as(f64, 3.0), p.ddxAt(0));
    try testing.expectEqual(@as(f64, 2.0), p.ddxAt(2));
    try testing.expectEqual(@as(f64, 0.0), p.ddxAt(1));
    // An `Of(0)` divisor contributes no lanes: d(a/k) = da/k.
    const q = c.div(S.con(4.0));
    try testing.expect(@TypeOf(q) == S.Of(0b0100));
    try testing.expectEqual(@as(f64, 0.25), q.ddxAt(2));
    // `sel` widens both arms to the join; `to` pads with +0.
    const s = S.sel(S.con(0.0), a, c);
    try testing.expect(@TypeOf(s) == S.Of(0b0101));
    try testing.expectEqual(@as(f64, 1.0), s.ddxAt(2));
    try testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(s.ddxAt(0))));
}

test "pow and sqrt lane coefficients at the edges the numerics table pins" {
    try testing.expectEqual(@as(f64, 12), powSlope(2, 3, 8)); // c·p/x
    try testing.expectEqual(@as(f64, 1), powSlope(0, 1, 0)); // c·pow(0, 0)
    try testing.expectEqual(@as(f64, 0), powSlope(0, 2, 0)); // c·pow(0, 1)
    try testing.expectEqual(@as(f64, 0), powSlope(0, 0.5, 0)); // 0.5·pow(0, -0.5) = inf
    try testing.expectEqual(@as(f64, 0), powSlope(std.math.nan(f64), 2, std.math.nan(f64)));
    try testing.expectEqual(@as(f64, 0.125), sqrtSlope(4)); // 0.5/4
    try testing.expectEqual(@as(f64, 0), sqrtSlope(0));
    try testing.expectEqual(@as(f64, 0), sqrtSlope(std.math.nan(f64)));
    try testing.expectEqualSlices(u32, &.{ lane_none, lane_none }, comptime laneTable(&[_]u8{ no_lane, no_lane }));
    try testing.expectEqualSlices(u32, &.{ 3, lane_none }, comptime laneTable(&[_]u8{ 3, no_lane }));
    // Past 255 entries a wider table: 255 is a lane, its maximum is not (#29).
    try testing.expectEqualSlices(u32, &.{ 255, lane_none }, comptime laneTable(&[_]u16{ 255, std.math.maxInt(u16) }));
}

test "RefFamily: every derivative lane matches a central difference of its value" {
    // Certificate: d/dx f(x) from the family against (f(x+h) - f(x-h)) / 2h
    // of the family's own VALUE half, which runs no lane arithmetic. A wrong
    // slope in a primitive is a wrong Jacobian with no crash; this sees it.
    const S = RefFamily(f64, &.{0}, .{});
    const xs = [_]f64{ 0.3, 0.9, 1.7, 2.6 };
    const unary = .{ "exp", "log", "expm1", "log1p", "sqrt", "sin", "cos", "tanh", "sinh", "cosh", "atan" };
    inline for (unary) |op| for (xs) |x| {
        const h = 1e-6 * @max(1.0, @abs(x));
        const up = @field(S.Of(0), op)(S.con(x + h)).val();
        const dn = @field(S.Of(0), op)(S.con(x - h)).val();
        const fd = (up - dn) / (2.0 * h);
        const got = @field(S.Of(1), op)(S.probe(0, x)).ddxAt(0);
        try testing.expectApproxEqRel(fd, got, 1e-6);
    };
    for (xs) |x| for ([_]f64{ 2.0, 0.5, -1.5 }) |c| {
        const h = 1e-6 * x;
        const fd = (S.con(x + h).pow(c).val() - S.con(x - h).pow(c).val()) / (2.0 * h);
        try testing.expectApproxEqRel(fd, S.probe(0, x).pow(c).ddxAt(0), 1e-6);
    };
    // Binary: the product and quotient rules, both operands live.
    const T = RefFamily(f64, &.{ 0, 1 }, .{});
    const a: f64 = 1.3;
    const b: f64 = -0.7;
    const h: f64 = 1e-6;
    const q = T.probe(0, a).div(T.probe(1, b));
    try testing.expectApproxEqRel(((a + h) / b - (a - h) / b) / (2 * h), q.ddxAt(0), 1e-6);
    try testing.expectApproxEqRel((a / (b + h) - a / (b - h)) / (2 * h), q.ddxAt(1), 1e-6);
    const p = T.probe(0, a).mul(T.probe(1, b));
    try testing.expectApproxEqRel(b, p.ddxAt(0), 1e-15);
    try testing.expectApproxEqRel(a, p.ddxAt(1), 1e-15);
}
