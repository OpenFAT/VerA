//! §9.13 probabilistic distributions: a seed and a distribution's arguments
//! in, the variate or the seed it leaves behind out. Device text
//! (`text.rng`) for every device that calls one of Table 9-10's names, and
//! host Zig for elaboration's literal folds (`elab/clone.zig`) and the
//! digital engine's IEEE 1364 §17.9 `$dist_*`, so every path draws the same
//! sequence from a seed.
//! Cites: VAMS §9.13.1-§9.13.3, Tables 9-10 and 9-26; IEEE 1364-2005
//! §17.9.2, §17.9.3 (the C listing).
//!
//! The algorithm is §17.9.3's listing verbatim, ported from two independent
//! reproductions cross-checked constant by constant (Icarus Verilog
//! `vpi/sys_random.c`, Verilator `include/verilated_probdist.cpp`) and held
//! bit-exact to the compiled C by `tests/rng_reference.zig`: the LCG
//! `seed' = 69069·seed + 1` on a wrapping 32-bit word, the zero-seed escape
//! 259341593, the mantissa fill `1 + (seed >> 9)·2^-23` (the float-punning
//! original, spelled arithmetically), and `c = c + c·2^-23`.
//!
//! Every draw is a pure function of the incoming seed. A residual is
//! re-evaluated many times at one operating point, so a draw that changed
//! between iterations would make Newton chase a moving target; §9.13.2 makes
//! that free ("the system functions shall always return the same value given
//! the same seed", and the seed is an inout source variable). Lowering splits
//! one source call into the variate (`zRng*`) and the updated seed
//! (`zRng*Next`); each `*Next` replays its own routine, because a routine
//! consumes a data-dependent number of LCG steps and the reference stream is
//! only reproduced if the write-back walks exactly as far as the variate did.
//! Omitted seeds are `Instance` latches advanced by `zRngNext` once per
//! accepted point.
//!
//! Counts follow the listing's positive signed-32 domain. §9.13.2 also
//! permits a real df or stage count; the listing has no fractional
//! algorithm, so those are refused at the call (E0816), as is every
//! argument outside §9.13.2's domain: "otherwise an error shall be
//! reported". The run ends with status 1, as `$table_model`'s `E` ends it.
//!
//! Contents:
//! - `pub const zRngRandNext = zRngNext`
//! - `pub fn zRngCheck(previous: f64, rules: u4, a: f64, b: f64) f64`
//! - `pub fn zRngNext(seed: i64) f64`
//! - `pub fn zRngRand(seed: i64) f64`
//! - `pub fn zRngIUniform(seed: i64, start: f64, end: f64) f64`
//! - `pub fn zRngIUniformNext(seed: i64, start: f64, end: f64) f64`
//! - `pub fn zRngUniform(seed: i64, start: f64, end: f64) f64`
//! - `pub fn zRngUniformNext(seed: i64, start: f64, end: f64) f64`
//! - `pub fn zRngNormal(seed: i64, mean: f64, sd: f64) f64`
//! - `pub fn zRngNormalNext(seed: i64, mean: f64, sd: f64) f64`
//! - `pub fn zRngExponential(seed: i64, mean: f64) f64`
//! - `pub fn zRngExponentialNext(seed: i64, mean: f64) f64`
//! - `pub fn zRngPoisson(seed: i64, mean: f64) f64`
//! - `pub fn zRngPoissonNext(seed: i64, mean: f64) f64`
//! - `pub fn zRngChiSquare(seed: i64, df: f64) f64`
//! - `pub fn zRngChiSquareNext(seed: i64, df: f64) f64`
//! - `pub fn zRngT(seed: i64, df: f64) f64`
//! - `pub fn zRngTNext(seed: i64, df: f64) f64`
//! - `pub fn zRngErlang(seed: i64, k_stage: f64, mean: f64) f64`
//! - `pub fn zRngErlangNext(seed: i64, k_stage: f64, mean: f64) f64`

const zrstd = @import("std");

// ---- device text ----

/// The seed after `zRngRand`'s draw: one uniform step, so it is `zRngNext`.
pub const zRngRandNext = zRngNext;

/// 2^-23, the listing's `d`.
const zr_d: f64 = 0.00000011920928955078125;

/// The LCG's period on the 32-bit word. A rejection loop that has not
/// accepted within one period never will, so it bounds every loop below.
const zr_period: u64 = 1 << 32;

/// The live effect of an otherwise unused distribution call: its argument
/// checks, with no draw. `rules` bit 0/1: `a`/`b` must be positive; bit 2:
/// `a` is a count; bit 3: `a < b`. `previous` is the preceding effect, an
/// operand only so the emitter sequences the two. Returns 0; exits with
/// E0816 on a violated rule.
pub fn zRngCheck(previous: f64, rules: u4, a: f64, b: f64) f64 {
    _ = previous;
    if (rules & 1 != 0) zRngPositive(a);
    if (rules & 2 != 0) zRngPositive(b);
    if (rules & 4 != 0) _ = zRngDf(a);
    if (rules & 8 != 0 and !(a < b))
        zRngDomain("random uniform start shall be smaller than end");
    return 0;
}

/// Returns the seed after one plain `uniform()` step: the seedless forms'
/// `Instance` latch, advanced once per accepted point. The step has no fixed
/// point on the 32-bit word (`69069·s + 1 = s (mod 2^32)` has no solution),
/// so the latch always moves.
pub fn zRngNext(seed: i64) f64 {
    var s = zRngS32(seed);
    _ = zRngUniformCore(&s, 0.0, 1.0);
    return zRngSOut(s);
}

/// §9.13.1 `$random`/`$arandom`: "the random number returned is a 32-bit
/// signed integer; it can be positive or negative".
pub fn zRngRand(seed: i64) f64 {
    var s = zRngS32(seed);
    return zRngRandCore(&s);
}

/// IEEE 1364 §17.9.2 `$dist_uniform(seed, start, end)`: an integer in the
/// closed range [start, end]; `start >= end` gives `start`, as the listing
/// does.
pub fn zRngIUniform(seed: i64, start: f64, end: f64) f64 {
    var s = zRngS32(seed);
    return zRngIUniformCore(&s, start, end);
}

/// The seed `zRngIUniform` leaves behind, for §9.13's inout write-back.
pub fn zRngIUniformNext(seed: i64, start: f64, end: f64) f64 {
    var s = zRngS32(seed);
    _ = zRngIUniformCore(&s, start, end);
    return zRngSOut(s);
}

/// §9.13.2 `$rdist_uniform`, Table 9-26's `uniform`, on real bounds.
/// Exits with E0816 unless `start < end`.
pub fn zRngUniform(seed: i64, start: f64, end: f64) f64 {
    if (!(start < end)) zRngDomain("random uniform start shall be smaller than end");
    var s = zRngS32(seed);
    return zRngUniformCore(&s, start, end);
}

/// The seed `zRngUniform` leaves behind. Exits with E0816 unless
/// `start < end`.
pub fn zRngUniformNext(seed: i64, start: f64, end: f64) f64 {
    if (!(start < end)) zRngDomain("random uniform start shall be smaller than end");
    var s = zRngS32(seed);
    _ = zRngUniformCore(&s, start, end);
    return zRngSOut(s);
}

/// §9.13.2 `$rdist_normal` / `$dist_normal`, Table 9-26's `normal`. The
/// integer twin's `(r + 0.5)` rounding is lowering's `fi_cast`, §4.2.1.1's
/// identical half-away-from-zero rule.
pub fn zRngNormal(seed: i64, mean: f64, sd: f64) f64 {
    var s = zRngS32(seed);
    return zRngNormalCore(&s, mean, sd);
}

/// The seed `zRngNormal` leaves behind.
pub fn zRngNormalNext(seed: i64, mean: f64, sd: f64) f64 {
    var s = zRngS32(seed);
    _ = zRngNormalCore(&s, mean, sd);
    return zRngSOut(s);
}

/// §9.13.2 `$rdist_exponential`, Table 9-26's `exponential`. Exits with
/// E0816 unless `mean > 0`.
pub fn zRngExponential(seed: i64, mean: f64) f64 {
    zRngPositive(mean);
    var s = zRngS32(seed);
    return zRngExponentialCore(&s, mean);
}

/// The seed `zRngExponential` leaves behind. Exits with E0816 unless
/// `mean > 0`.
pub fn zRngExponentialNext(seed: i64, mean: f64) f64 {
    var s = zRngS32(seed);
    zRngPositive(mean);
    _ = zRngExponentialCore(&s, mean);
    return zRngSOut(s);
}

/// §9.13.2 `$rdist_poisson`, Table 9-26's `poisson`. Exits with E0816 unless
/// `mean > 0`.
pub fn zRngPoisson(seed: i64, mean: f64) f64 {
    zRngPositive(mean);
    var s = zRngS32(seed);
    return zRngPoissonCore(&s, mean);
}

/// The seed `zRngPoisson` leaves behind. Exits with E0816 unless `mean > 0`.
pub fn zRngPoissonNext(seed: i64, mean: f64) f64 {
    var s = zRngS32(seed);
    zRngPositive(mean);
    _ = zRngPoissonCore(&s, mean);
    return zRngSOut(s);
}

/// §9.13.2 `$rdist_chi_square`, Table 9-26's `chi_square`. Exits with E0816
/// unless `df` is a whole number in [1, 2^31 - 1].
pub fn zRngChiSquare(seed: i64, df: f64) f64 {
    const n = zRngDf(df);
    var s = zRngS32(seed);
    return zRngChiSquareCore(&s, n);
}

/// The seed `zRngChiSquare` leaves behind; `zRngChiSquare`'s domain.
pub fn zRngChiSquareNext(seed: i64, df: f64) f64 {
    var s = zRngS32(seed);
    _ = zRngChiSquareCore(&s, zRngDf(df));
    return zRngSOut(s);
}

/// §9.13.2 `$rdist_t`, Table 9-26's `t`; `zRngChiSquare`'s domain.
pub fn zRngT(seed: i64, df: f64) f64 {
    const n = zRngDf(df);
    var s = zRngS32(seed);
    return zRngTCore(&s, n);
}

/// The seed `zRngT` leaves behind; `zRngChiSquare`'s domain.
pub fn zRngTNext(seed: i64, df: f64) f64 {
    var s = zRngS32(seed);
    const n = zRngDf(df);
    _ = zRngTCore(&s, n);
    return zRngSOut(s);
}

/// §9.13.2 `$rdist_erlang`, Table 9-26's `erlang` (the listing's
/// `erlangian`). Exits with E0816 unless `k_stage` is a whole number in
/// [1, 2^31 - 1] and `mean > 0`.
pub fn zRngErlang(seed: i64, k_stage: f64, mean: f64) f64 {
    const k = zRngDf(k_stage);
    zRngPositive(mean);
    var s = zRngS32(seed);
    return zRngErlangCore(&s, k, mean);
}

/// The seed `zRngErlang` leaves behind; `zRngErlang`'s domain.
pub fn zRngErlangNext(seed: i64, k_stage: f64, mean: f64) f64 {
    var s = zRngS32(seed);
    const k = zRngDf(k_stage);
    zRngPositive(mean);
    _ = zRngErlangCore(&s, k, mean);
    return zRngSOut(s);
}

// ---- private ----

/// The i64 the LRM's `integer` seed carries, folded onto the listing's
/// 32-bit word: its low 32 bits, what assigning an `int32_t*` through the VPI
/// did in the reference's callers.
fn zRngS32(seed: i64) u32 {
    return @truncate(@as(u64, @bitCast(seed)));
}

/// The updated word read back as the signed value the listing's `long *seed`
/// stored. Real-typed because every emitted `$rng$*` callee is, and exact:
/// an i32 is far below 2^53.
fn zRngSOut(s: u32) f64 {
    const r: f64 = @floatFromInt(@as(i32, @bitCast(s)));
    // Pair of zRngS32: the real carries the word back unchanged.
    zrstd.debug.assert(zRngS32(@intFromFloat(r)) == s);
    return r;
}

/// §17.9.3 `uniform(seed, start, end)`, the primitive every other routine
/// draws through: one LCG step and a double on [start, end), up to the
/// listing's own top-sliver overshoot of `end` by about 2^-23·(end - start).
fn zRngUniformCore(s: *u32, start: f64, end: f64) f64 {
    var a = start;
    var b = end;
    if (start >= end) {
        a = 0.0;
        b = 2147483647.0;
    }
    if (s.* == 0) s.* = 259341593;
    s.* = 69069 *% s.* +% 1; // C `long` overflow: a wrapping 32-bit word
    var c: f64 = 1.0 + @as(f64, @floatFromInt(s.* >> 9)) * zr_d;
    zrstd.debug.assert(c >= 1.0);
    zrstd.debug.assert(c < 2.0);
    c = c + (c * zr_d);
    return ((b - a) * (c - 1.0)) + a;
}

/// §17.9.3 `normal(seed, mean, deviation)`: Marsaglia's polar rejection over
/// pairs of `uniform(seed, -1, 1)`, the loop that makes the seed's advance
/// data-dependent.
fn zRngNormalCore(s: *u32, mean: f64, dev: f64) f64 {
    var v1: f64 = 0.0;
    var sq: f64 = 1.0;
    var pairs: u64 = 0;
    while (sq >= 1.0 or sq == 0.0) : (pairs += 1) {
        zrstd.debug.assert(pairs < zr_period);
        v1 = zRngUniformCore(s, -1.0, 1.0);
        const v2 = zRngUniformCore(s, -1.0, 1.0);
        sq = v1 * v1 + v2 * v2;
    }
    zrstd.debug.assert(sq < 1.0);
    return v1 * @sqrt(-2.0 * @log(sq) / sq) * dev + mean;
}

/// §17.9.3 `exponential(seed, mean)`: `-log(uniform(0, 1))·mean`, the
/// listing's `n != 0` guard included.
fn zRngExponentialCore(s: *u32, mean: f64) f64 {
    var n = zRngUniformCore(s, 0.0, 1.0);
    if (n != 0.0) n = -@log(n) * mean;
    return n;
}

/// §17.9.3 `poisson(seed, mean)`: multiplies uniforms into the first until
/// the product drops under exp(-mean); the count of multiplications is the
/// variate. A large mean loses accuracy once exp(-mean) underflows, which
/// is the reference's limit and so ours.
fn zRngPoissonCore(s: *u32, mean: f64) f64 {
    var n: f64 = 0.0;
    const p = @exp(-mean);
    var product = zRngUniformCore(s, 0.0, 1.0);
    // One period multiplies in every word's draw once, a product that
    // underflows to 0, so the loop ends within it.
    var steps: u64 = 0;
    while (p < product) : (steps += 1) {
        zrstd.debug.assert(steps < zr_period);
        n += 1.0;
        product = zRngUniformCore(s, 0.0, 1.0) * product;
    }
    zrstd.debug.assert(n >= 0.0);
    return n;
}

/// §17.9.3 `chi_square(seed, deg_of_free)`: one squared normal for an odd
/// df, then `2·exponential(seed, 1)` per even pair.
fn zRngChiSquareCore(s: *u32, df: u32) f64 {
    zrstd.debug.assert(df >= 1);
    var x: f64 = 0.0;
    if (@rem(df, 2) != 0) {
        const z = zRngNormalCore(s, 0.0, 1.0);
        x = z * z;
    }
    var k: u32 = 2;
    while (k <= df) : (k += 2) x += 2.0 * zRngExponentialCore(s, 1.0);
    return x;
}

// §17.9.3's integer-result rounding, `(long)(r + 0.5)` mirrored through
// zero, is round-half-away-from-zero, §4.2.1.1's rule for `fi_cast`, so the
// `$dist_*` kernels get the reference's `rtl_dist_*` rounding from lowering's
// `toInt` and no `zRng*` spelling of it exists.

/// §17.9.3 `rtl_dist_uniform(seed, INT32_MIN, INT32_MAX)`, the listing's own
/// `$random` caller: the full-range branch, the uniform rescaled from
/// [-2^31, 2^31 - 1] onto [-2^31, 2^31) and floored.
fn zRngRandCore(s: *u32) f64 {
    var r = (zRngUniformCore(s, -2147483648.0, 2147483647.0) + 2147483648.0) / 4294967295.0;
    r = r * 4294967296.0 - 2147483648.0;
    // The listing's `(long)r` / `(long)(r - 1)` pair: truncation toward zero.
    const f = if (r >= 0.0) @trunc(r) else @trunc(r - 1.0);
    // The top 2^-23 sliver lands on 2^31, where the C cast is UB that every
    // shipping compiler resolves to 0x80000000; the i64 round trip makes that
    // defined here.
    const v: f64 = @floatFromInt(@as(i32, @truncate(@as(i64, @intFromFloat(f)))));
    zrstd.debug.assert(v >= -2147483648.0);
    zrstd.debug.assert(v <= 2147483647.0);
    return v;
}

/// §17.9.3 `rtl_dist_uniform(seed, start, end)`: an integer in the closed
/// range [start, end], via one `uniform` over the half-open widened
/// interval, floored and clamped: all three of the listing's branches,
/// including the widen-by-one asymmetries at the two int32 extremes.
fn zRngIUniformCore(s: *u32, start_r: f64, end_r: f64) f64 {
    // The reference's arguments are int32; fold the real carrier onto that
    // domain as the C cast did, saturating instead of trapping.
    const start: i32 = @intFromFloat(@max(-2147483648.0, @min(2147483647.0, @trunc(start_r))));
    const end: i32 = @intFromFloat(@max(-2147483648.0, @min(2147483647.0, @trunc(end_r))));
    if (start >= end) return @floatFromInt(start);
    const v: f64 = if (end != 2147483647) v: {
        const r = zRngUniformCore(s, @floatFromInt(start), @floatFromInt(end + 1));
        var i: i64 = @intFromFloat(if (r >= 0.0) @trunc(r) else @trunc(r - 1.0));
        if (i < start) i = start;
        if (i >= end + 1) i = end;
        break :v @floatFromInt(i);
    } else if (start != -2147483648) v: {
        const r = zRngUniformCore(s, @floatFromInt(start - 1), 2147483647.0) + 1.0;
        var i: i64 = @intFromFloat(if (r >= 0.0) @trunc(r) else @trunc(r - 1.0));
        if (i <= start - 1) i = start;
        if (i > end) i = end;
        break :v @floatFromInt(i);
    } else zRngRandCore(s);
    zrstd.debug.assert(v >= @as(f64, @floatFromInt(start)));
    zrstd.debug.assert(v <= @as(f64, @floatFromInt(end)));
    return v;
}

/// §17.9.3 `t(seed, deg_of_free)`: the normal is always drawn, even when the
/// chi-square makes the division non-finite.
fn zRngTCore(s: *u32, df: u32) f64 {
    zrstd.debug.assert(df >= 1);
    const chi2 = zRngChiSquareCore(s, df);
    return zRngNormalCore(s, 0.0, 1.0) / @sqrt(chi2 / @as(f64, @floatFromInt(df)));
}

/// §17.9.3 `erlangian(seed, k, mean)`: minus the log of a product of `k`
/// uniforms, scaled by `mean / k`.
fn zRngErlangCore(s: *u32, k: u32, mean: f64) f64 {
    zrstd.debug.assert(k >= 1);
    var x: f64 = 1.0;
    var i: u32 = 1;
    while (i <= k) : (i += 1) x *= zRngUniformCore(s, 0.0, 1.0);
    return -mean * @log(x) / @as(f64, @floatFromInt(k));
}

/// §9.13.2 "otherwise an error shall be reported": the argument is a
/// run-time value, so the report is here, at the call; E0816 is the same
/// rule's compile-time code.
fn zRngDomain(rule: []const u8) noreturn {
    zrstd.debug.print("error[E0816]: LRM 9.13.2: {s}\n", .{rule});
    zrstd.process.exit(1);
}

fn zRngPositive(value: f64) void {
    if (!(value > 0.0)) zRngDomain("random distribution mean/df/stages shall be greater than zero");
}

/// The exact supported count. Neither truncating a real count nor replacing
/// it with a smaller one is allowed: either would change both the variate
/// and the seed.
fn zRngDf(df: f64) u32 {
    zRngPositive(df);
    if (!(df <= 2147483647.0) or df != @trunc(df))
        zRngDomain("fractional or out-of-range random distribution df/stages are unsupported");
    const n: u32 = @intFromFloat(df);
    zrstd.debug.assert(n >= 1);
    zrstd.debug.assert(n <= 2147483647);
    return n;
}
