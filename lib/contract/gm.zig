//! An `f64` (or, for exp, log and pow, a vector of them) in, a transcendental
//! out, on every target VerA's devices compile for, including NVPTX and
//! AMDGCN, which have no libm. Used by the scalar paths of generated code
//! (the §4.5.15 limiters), by `RefFamily`, and by the compiler's constant
//! folds and the prover's bounds (`kernels/fold.zig`, `prove/transfer.zig`):
//! exp, log and pow fold at compile time to the bits a device computes at
//! run time, so changing their arithmetic changes folded constants. On the
//! host the others are the Zig builtin or `std.math` call; on a GPU target
//! each is a self-contained musl port (<= 1 ulp, `gm/musl.zig`).
//! Cites: VAMS-2023 §4.3.2 Tables 4-14/4-15 (the C function behind each
//! analog function); C99 F.10 (special cases); the bounds are
//! docs/specification/Vague_Decisions.md VD-123 and "Host math".
//!
//! ponytail: only the functions device code reaches are ported. A model that
//! reaches another builtin on a GPU fails its kernel compile; extend this
//! file then.
//!
//! Contents:
//! - `pub const gpu: bool`
//! - `pub const hexp`, `pub const hlog`, `pub const powV`: the scalar-or-vector forms
//! - `pub const armExp`, `pub const armLog`, `pub const armPow`: the scalar forms
//! - `pub inline fn exp(x: anytype) @TypeOf(x)`, `pub inline fn log(x: anytype) @TypeOf(x)`
//! - `pub inline fn pow(x: f64, y: f64) f64`
//! - `pub inline fn tanh(x: f64) f64`, `sinh`, `cosh`, `sin`, `cos`, `expm1`, `log1p`, `atan`
//! - `pub fn tan(x: f64) f64`, `asinh`, `acosh`, `atanh`, `log10`
//! - `pub fn atan2(y: f64, x: f64) f64`

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const arm_exp = @import("gm/arm_exp.zig");
const arm_log = @import("gm/arm_log.zig");
const arm_pow = @import("gm/arm_pow.zig");
const bits = @import("gm/bits.zig");
const musl = @import("gm/musl.zig");

/// Whether this compilation is a GPU kernel (NVPTX or AMDGCN): no libm and
/// no host memory, so the musl ports run and host tables are unreachable.
pub const gpu = switch (builtin.target.cpu.arch) {
    .nvptx64, .amdgcn => true,
    else => false,
};

/// exp(x) for `f64` or `@Vector(n, f64)`, lane for lane `armExp`'s bits.
pub const hexp = arm_exp.hexp;
/// log(x) for `f64` or `@Vector(n, f64)`, lane for lane `armLog`'s bits.
pub const hlog = arm_log.hlog;
/// x^y for `f64` or `@Vector(n, f64)` bases, lane for lane `armPow`'s bits.
pub const powV = arm_pow.powV;
/// exp(x): <= 0.52 ulp, never negative, the specials of C99 F.10.3.1.
pub const armExp = arm_exp.armExp;
/// log(x): <= 0.52 ulp, the specials of C99 F.10.3.7.
pub const armLog = arm_log.armLog;
/// x^y: <= 0.54 ulp, the specials of C99 F.10.4.4.
pub const armPow = arm_pow.armPow;

/// ln 2 in f128, for the accuracy tests' oracle.
const ln2_q: f128 = 0x1.62e42fefa39ef35793c7673007e6p-1;

/// exp, log and pow are VerA's own, one implementation on every target
/// (host, NVPTX, AMDGCN): faithful (< 1 ulp; docs/specification/Vague_Decisions.md, "Host
/// math"), fma-free so every target rounds alike (`exact_everywhere`).
/// `exp`/`log` take `f64` or `@Vector(n, f64)`; `powV` is pow's vector
/// form.
pub inline fn exp(x: anytype) @TypeOf(x) {
    return arm_exp.hexp(x);
}
/// log(x), `f64` or `@Vector(n, f64)`; specials as `armLog` lists them.
pub inline fn log(x: anytype) @TypeOf(x) {
    return arm_log.hlog(x);
}
/// x^y for one `f64` base; C99 F.10.4.4's special cases (`armPow`).
pub inline fn pow(x: f64, y: f64) f64 {
    return arm_pow.armPow(x, y);
}
/// tanh, sinh and cosh: `std.math`'s on the host; on a GPU a port over
/// `armExp`, not bit-identical to the host's.
pub inline fn tanh(x: f64) f64 {
    if (comptime !gpu) return std.math.tanh(x);
    // Cephes rational below 0.625, else 1 - 2/(e^2|x| + 1).
    const ax = @abs(x);
    if (ax < 0.625) {
        const z = x * x;
        const p = ((-9.64399179425052238628e-1 * z +
            -9.92877231001918586564e1) * z + -1.61468768441708447952e3) * z;
        const q = ((z + 1.12811678491632931402e2) * z +
            2.23548839060100448583e3) * z + 4.84406305325125486048e3;
        return x + x * (p / q);
    }
    const r = 1 - 2.0 / (arm_exp.armExp(2 * ax) + 1);
    return if (x < 0) -r else r;
}
/// sinh(x); on a GPU a Taylor series below 0.5, else (e^|x| - e^-|x|)/2.
pub inline fn sinh(x: f64) f64 {
    if (comptime !gpu) return std.math.sinh(x);
    const ax = @abs(x);
    if (ax < 0.5) {
        const z = x * x;
        return x * (1 + z * (1.0 / 6.0 + z * (1.0 / 120.0 +
            z * (1.0 / 5040.0 + z * (1.0 / 362880.0 +
                z * (1.0 / 39916800.0 + z * (1.0 / 6227020800.0)))))));
    }
    const e = arm_exp.armExp(ax);
    const r = 0.5 * e - 0.5 / e;
    return if (x < 0) -r else r;
}
/// cosh(x); on a GPU (e^|x| + e^-|x|)/2.
pub inline fn cosh(x: f64) f64 {
    if (comptime !gpu) return std.math.cosh(x);
    const e = arm_exp.armExp(@abs(x));
    return 0.5 * e + 0.5 / e;
}
/// sin and cos: the builtins on the host; on a GPU musl's k_sin/k_cos,
/// whose phase accuracy decays past |x| ~ 1.6e6 rad (`remPio2`).
pub inline fn sin(x: f64) f64 {
    return if (comptime gpu) musl.sin(x) else @sin(x);
}
/// cos(x), with `sin`'s accuracy on each target.
pub inline fn cos(x: f64) f64 {
    return if (comptime gpu) musl.cos(x) else @cos(x);
}
// std's port raises the subnormal underflow flag through
// `std.mem.doNotOptimizeAway` (`asm volatile ("" :: "rm" (v))`), which the
// AMDGPU backend cannot match. The device branch is std's algorithm with
// that line dropped; it only set a flag, so every value is identical.
/// e^x - 1 without cancellation near 0; every value equals `std.math`'s
/// on every target.
pub inline fn expm1(x: f64) f64 {
    return if (comptime gpu) musl.expm1(x) else std.math.expm1(x);
}
/// ln(1 + x) without cancellation near 0; every value equals
/// `std.math`'s on every target (`expm1`'s AMDGCN hole, at |x| < 2^-53).
pub inline fn log1p(x: f64) f64 {
    return if (comptime gpu) musl.log1p(x) else std.math.log1p(x);
}
// Same AMDGCN hole as `expm1`, dodged through `std.math.atan`'s vector
// path, which never reaches the idiom. Two lanes because `@Vector(1, f64)`
// crashes the compiler; the second is discarded. ponytail: port
// `atanBinary64` minus its bad line if device atan reaches a profile.
/// atan: `std.math`'s on the host; on a GPU std's vector body, within
/// 2·eps relative of the host's.
pub inline fn atan(x: f64) f64 {
    if (comptime !gpu) return std.math.atan(x);
    const v: @Vector(2, f64) = @splat(x);
    return std.math.atan(v)[0];
}

// asinh, acosh, atanh, log10, atan2:
// Tables 4-14/4-15 name the C function for each. These are musl's
// algorithms as `std.math` (asinh, acosh, atanh, atan2) and compiler_rt
// (log10) carry them, with `@log` read as `hlog` and `std.math.atan` as
// `atan`, so they need no libm (NVPTX, AMDGCN) and one function serves the
// compiler's folds (`kernels/fold.zig`), the prover's bounds
// (`prove/transfer.zig`) and a device's value (`kernel_text.zig`).
// An exact f64 model against mpmath (docs/specification/Vague_Decisions.md
// VD-123): under 2 ulp (acosh near 1 the worst, 1.94); log10 0.67 ulp
// and exact at every power of ten. `tests/unit.zig` holds the bounds.

/// tan(x) as a device's `zTan` computes it from its family's sin and
/// cos: the quotient, within 2 ulp of the exact tangent (VD-123).
pub fn tan(x: f64) f64 {
    const r = sin(x) / cos(x);
    assert(!std.math.isNan(x) or std.math.isNan(r));
    return r;
}
/// asinh(x) = sign(x)·ln(|x| + sqrt(x² + 1)), without the cancellation
/// (x < 0) or the overflow (|x| > 1e154) of that formula.
pub fn asinh(x: f64) f64 {
    const u: u64 = @bitCast(x);
    const e = (u >> 52) & 0x7FF;
    var rx: f64 = @bitCast(u & (std.math.maxInt(u64) >> 1));
    if (e >= 0x3FF + 26) {
        rx = arm_log.hlog(rx) + 0.693147180559945309417232121458176568;
    } else if (e >= 0x3FF + 1) {
        rx = arm_log.hlog(2 * rx + 1 / (@sqrt(rx * rx + 1) + rx));
    } else if (e >= 0x3FF - 26) {
        rx = log1p(rx + rx * rx / (@sqrt(rx * rx + 1) + 1));
    }
    const r = if (u >> 63 != 0) -rx else rx;
    assert(std.math.isNan(r) or std.math.signbit(r) == std.math.signbit(x)); // Odd.
    return r;
}
/// acosh(x) = ln(x + sqrt(x² − 1)) for x >= 1; NaN below.
pub fn acosh(x: f64) f64 {
    const r = acoshBody(x);
    assert(!(r < 0.0)); // ln of a value >= 1, or NaN below 1.
    assert(!(x < 1.0) or std.math.isNan(r));
    return r;
}
/// atanh(x) = ½·ln((1 + x)/(1 − x)) for |x| < 1, ±inf at ±1, NaN past.
pub fn atanh(x: f64) f64 {
    const u: u64 = @bitCast(x);
    const e = (u >> 52) & 0x7FF;
    var y: f64 = @bitCast(u & (std.math.maxInt(u64) >> 1));
    if (y == 1.0) return std.math.copysign(std.math.inf(f64), x);
    if (e < 0x3FF - 1) {
        if (e >= 0x3FF - 32) y = 0.5 * log1p(2 * y + 2 * y * y / (1 - y));
    } else {
        y = 0.5 * log1p(2 * (y / (1 - y)));
    }
    const r = if (u >> 63 != 0) -y else y;
    assert(std.math.isNan(r) or std.math.signbit(r) == std.math.signbit(x)); // Odd.
    return r;
}
/// log10(x): -inf at ±0, NaN below 0, exact at every power of ten.
pub fn log10(x_: f64) f64 {
    const ivln10hi: f64 = 4.34294481878168880939e-01;
    const ivln10lo: f64 = 2.50829467116452752298e-11;
    const log10_2hi: f64 = 3.01029995663611771306e-01;
    const log10_2lo: f64 = 3.69423907715893078616e-13;
    const Lg1: f64 = 6.666666666666735130e-01;
    const Lg2: f64 = 3.999999999940941908e-01;
    const Lg3: f64 = 2.857142874366239149e-01;
    const Lg4: f64 = 2.222219843214978396e-01;
    const Lg5: f64 = 1.818357216161805012e-01;
    const Lg6: f64 = 1.531383769920937332e-01;
    const Lg7: f64 = 1.479819860511658591e-01;
    var x = x_;
    var ix: u64 = @bitCast(x);
    var hx: u32 = @intCast(ix >> 32);
    var k: i32 = 0;
    if (hx < 0x00100000 or hx >> 31 != 0) {
        if (ix << 1 == 0) return -std.math.inf(f64); // log(+-0) = -inf
        if (hx >> 31 != 0) return std.math.nan(f64); // log(-#) = nan
        // subnormal, scale x
        k -= 54;
        x *= 0x1.0p54;
        // Both words of the scaled value: the low word joins `hx` below.
        ix = @bitCast(x);
        hx = @intCast(ix >> 32);
    } else if (hx >= 0x7FF00000) {
        return x;
    } else if (hx == 0x3FF00000 and ix << 32 == 0) {
        return 0;
    }
    // x into [sqrt(2) / 2, sqrt(2)]
    hx += 0x3FF00000 - 0x3FE6A09E;
    k += @as(i32, @intCast(hx >> 20)) - 0x3FF;
    hx = (hx & 0x000FFFFF) + 0x3FE6A09E;
    ix = (@as(u64, hx) << 32) | (ix & 0xFFFFFFFF);
    x = @bitCast(ix);
    const f = x - 1.0;
    const hfsq = 0.5 * f * f;
    const s = f / (2.0 + f);
    const z = s * s;
    const w = z * z;
    const t1 = w * (Lg2 + w * (Lg4 + w * Lg6));
    const t2 = z * (Lg1 + w * (Lg3 + w * (Lg5 + w * Lg7)));
    const R = t2 + t1;
    // hi + lo = f - hfsq + s * (hfsq + R) ~ log(1 + f)
    var hi = f - hfsq;
    hi = @bitCast(@as(u64, @bitCast(hi)) & (@as(u64, std.math.maxInt(u64)) << 32));
    const lo = f - hi - hfsq + s * (hfsq + R);
    // val_hi + val_lo ~ log10(1 + f) + k * log10(2)
    var val_hi = hi * ivln10hi;
    const dk: f64 = @floatFromInt(k);
    const y = dk * log10_2hi;
    var val_lo = dk * log10_2lo + (lo + hi) * ivln10lo + lo * ivln10hi;
    const ww = y + val_hi;
    val_lo += (y - ww) + val_hi;
    val_hi = ww;
    const r = val_lo + val_hi;
    assert(std.math.isFinite(r)); // A positive finite x past every early return.
    return r;
}
/// atan2(y, x) in (-pi, pi], with C99 F.10.1.4's signed zeros and
/// infinities: atan2(±0, -0) = ±pi, atan2(±0, +0) = ±0. Table 4-15's
/// "atan2(0,0) = 0" is the +0, +0 case.
pub fn atan2(y: f64, x: f64) f64 {
    const r = atan2Body(y, x);
    assert(std.math.isNan(r) or @abs(r) <= std.math.pi);
    return r;
}

// ---- private ----

fn atan2Body(y: f64, x: f64) f64 {
    const pi: f64 = 3.1415926535897931160E+00;
    const pi_lo: f64 = 1.2246467991473531772E-16;
    if (std.math.isNan(x) or std.math.isNan(y)) return x + y;
    const ux: u64 = @bitCast(x);
    var ix: u32 = @intCast(ux >> 32);
    const lx: u32 = @intCast(ux & 0xFFFFFFFF);
    const uy: u64 = @bitCast(y);
    var iy: u32 = @intCast(uy >> 32);
    const ly: u32 = @intCast(uy & 0xFFFFFFFF);
    if ((ix -% 0x3FF00000) | lx == 0) return atan(y); // x = 1.0
    // 2 * sign(x) + sign(y)
    const m = ((iy >> 31) & 1) | ((ix >> 30) & 2);
    ix &= 0x7FFFFFFF;
    iy &= 0x7FFFFFFF;
    if (iy | ly == 0) return switch (m) {
        0, 1 => y, // atan(+-0, +...)
        2 => pi, // atan(+0, -...)
        else => -pi, // else: m is 3, atan(-0, -...)
    };
    if (ix | lx == 0) return if (m & 1 != 0) -pi / 2.0 else pi / 2.0;
    if (ix == 0x7FF00000) {
        if (iy == 0x7FF00000) return switch (m) {
            0 => pi / 4.0,
            1 => -pi / 4.0,
            2 => 3.0 * pi / 4.0,
            else => -3.0 * pi / 4.0, // else: m is 3
        };
        return switch (m) {
            0 => 0.0,
            1 => -0.0,
            2 => pi,
            else => -pi, // else: m is 3
        };
    }
    // |y / x| > 0x1p64
    if (ix +% (64 << 20) < iy or iy == 0x7FF00000) return if (m & 1 != 0) -pi / 2.0 else pi / 2.0;
    // z = atan(|y / x|) with correct underflow
    const z = if ((m & 2) != 0 and iy +% (64 << 20) < ix) 0.0 else atan(@abs(y / x));
    return switch (m) {
        0 => z,
        1 => -z,
        2 => pi - (z - pi_lo),
        else => (z - pi_lo) - pi, // else: m is 3
    };
}

fn acoshBody(x: f64) f64 {
    const e = (@as(u64, @bitCast(x)) >> 52) & 0x7FF;
    // musl reads |x|'s exponent and leaves the sign to the formulas, which
    // give NaN for x in (-2, 1) but a finite value at x <= -2 (acosh(-12345.678)
    // was -8.05): C99 F.10.2.1 and Table 4-14 make every x < 1 a domain error.
    if (x < 0 and e >= 0x3FF + 1) return std.math.nan(f64);
    if (e < 0x3FF + 1) return log1p(x - 1 + @sqrt((x - 1) * (x - 1) + 2 * (x - 1)));
    if (e < 0x3FF + 26) return arm_log.hlog(2 * x - 1 / (x + @sqrt(x * x - 1)));
    return arm_log.hlog(x) + 0.693147180559945309417232121458176568;
}

// The accuracy bound's oracle: exp and log in f128, by series.
fn expQ(t: f128) f128 {
    const k = @round(t / ln2_q);
    const r = t - k * ln2_q;
    var term: f128 = 1;
    var sum: f128 = 1;
    var n: f128 = 1;
    while (n < 36) : (n += 1) {
        term = term * r / n;
        sum += term;
    }
    return std.math.ldexp(sum, @intFromFloat(k));
}
fn logQ(x: f64) f128 {
    const fr = std.math.frexp(@as(f128, x));
    var m = fr.significand;
    var e: f128 = @floatFromInt(fr.exponent);
    if (m < 0.70710678) {
        m *= 2;
        e -= 1;
    }
    const u = (m - 1) / (m + 1);
    const uu = u * u;
    var term = u;
    var sum: f128 = 0;
    var k: f128 = 1;
    while (k < 100) : (k += 2) {
        sum += term / k;
        term *= uu;
    }
    return 2 * sum + e * ln2_q;
}
/// `f(x)` evaluated by the compiler (comptime IEEE arithmetic).
fn folds(comptime f: fn (f64) f64, comptime x: f64) f64 {
    @setEvalBranchQuota(1_000_000);
    return f(x);
}
/// `x` as a run-time value, so the call below is not folded.
fn rt(x: f64) f64 {
    var v = x;
    std.mem.doNotOptimizeAway(&v);
    return v;
}
/// |got - ref| in units of the last place of the double nearest ref.
fn ulpQ(got: f64, ref: f128) f64 {
    const rd: f64 = @floatCast(ref);
    const e = @max(std.math.ilogb(rd) - 52, -1074);
    return @floatCast(@abs(@as(f128, got) - ref) / std.math.ldexp(@as(f128, 1.0), e));
}

test "exp/log/pow stay within the documented bound of an f128 oracle" {
    // docs/specification/Vague_Decisions.md: exp <= 0.52, log <= 0.52, pow <= 0.55 ulp
    // (measured maxima 0.507, 0.500, 0.505; the margin is the bound ARM
    // proves). A fixed sample, so the test is reproducible.
    var prng = std.Random.DefaultPrng.init(0x7a11);
    const r = prng.random();
    var worst = [3]f64{ 0, 0, 0 };
    for (0..1500) |_| {
        const x = r.float(f64) * 1440.0 - 735.0;
        worst[0] = @max(worst[0], ulpQ(armExp(x), expQ(x)));
        const lx: f64 = @bitCast((r.int(u64) % 0x7fe0000000000000) + 0x0010000000000000);
        worst[1] = @max(worst[1], ulpQ(armLog(lx), logQ(lx)));
        const px = std.math.pow(f64, 10.0, r.float(f64) * 15.0 - 3.0);
        const py = r.float(f64) * 21.0 - 3.0;
        worst[2] = @max(worst[2], ulpQ(armPow(px, py), expQ(@as(f128, py) * logQ(px))));
    }
    try std.testing.expect(worst[0] <= 0.52);
    try std.testing.expect(worst[1] <= 0.52);
    try std.testing.expect(worst[2] <= 0.55);
}

test "exp/log/pow fold at comptime to the bits they run to: no target-dependent operation" {
    // `exact_everywhere`: no fma, so the routines are plain IEEE f64
    // arithmetic, which Zig's comptime evaluates target-independently.
    // A run that matches the fold matches every target the same code
    // compiles for (host, NVPTX, AMDGCN) unless a backend fuses or
    // reassociates on its own, which none does without contract flags.
    const xs = [_]f64{ -744.9, -700.25, -20.5, -0.75, -1e-9, 0.0, 3e-17, 0.693, 1.0, 22.0, 512.5, 709.7 };
    const ls = [_]f64{ 0x1p-1060, 1e-300, 1e-9, 0.5, 0.999999, 1.0, 1.0000001, 3.0, 1e18, 1e308 };
    inline for (xs) |x| {
        const folded = comptime folds(armExp, x);
        try std.testing.expectEqual(@as(u64, @bitCast(folded)), @as(u64, @bitCast(armExp(rt(x)))));
    }
    inline for (ls) |x| {
        const folded = comptime folds(armLog, x);
        try std.testing.expectEqual(@as(u64, @bitCast(folded)), @as(u64, @bitCast(armLog(rt(x)))));
        const pf = comptime blk: {
            @setEvalBranchQuota(1_000_000);
            break :blk armPow(x, 1.4552480184709202);
        };
        try std.testing.expectEqual(@as(u64, @bitCast(pf)), @as(u64, @bitCast(armPow(rt(x), 1.4552480184709202))));
    }
    // The vector form is the scalar's, lane for lane.
    const v: @Vector(4, f64) = .{ -3.5, 0.25, 7.0, 41.0 };
    const ev = hexp(v);
    const lv = hlog(v * v);
    const pv = powV(v * v, 1.4552480184709202);
    const pn = powV(v, 3.0); // a negative base: lane by lane
    inline for (0..4) |l| {
        try std.testing.expectEqual(@as(u64, @bitCast(armPow(v[l] * v[l], 1.4552480184709202))), @as(u64, @bitCast(pv[l])));
        try std.testing.expectEqual(@as(u64, @bitCast(armPow(v[l], 3.0))), @as(u64, @bitCast(pn[l])));
        try std.testing.expectEqual(@as(u64, @bitCast(armExp(v[l]))), @as(u64, @bitCast(ev[l])));
        try std.testing.expectEqual(@as(u64, @bitCast(armLog(v[l] * v[l]))), @as(u64, @bitCast(lv[l])));
    }
}

test "armExp/armPow: the contract's special cases, exact cases and 1-ulp agreement" {
    const inf = std.math.inf(f64);
    // exp: specials and range ends.
    try std.testing.expectEqual(@as(f64, 1.0), armExp(0.0));
    try std.testing.expectEqual(@as(f64, 1.0), armExp(-0.0));
    try std.testing.expectEqual(inf, armExp(inf));
    try std.testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(armExp(-inf))));
    try std.testing.expect(std.math.isNan(armExp(std.math.nan(f64))));
    try std.testing.expectEqual(inf, armExp(709.8));
    try std.testing.expect(armExp(709.78) < inf);
    try std.testing.expectEqual(@as(f64, 0.0), armExp(-745.2));
    try std.testing.expect(armExp(-745.0) > 0.0); // gradual underflow
    // The thresholds: the last double whose exp rounds to the least
    // subnormal / to DBL_MAX's neighbourhood, and the next one past it.
    try std.testing.expectEqual(@as(f64, 0x1p-1074), armExp(-0x1.74910d52d3051p9));
    try std.testing.expectEqual(@as(f64, 0.0), armExp(-0x1.74910d52d3052p9));
    try std.testing.expect(armExp(0x1.62e42fefa39efp9) < inf);
    try std.testing.expectEqual(inf, armExp(0x1.62e42fefa39f0p9));
    try std.testing.expectEqual(std.math.e, armExp(1.0));
    // Monotone across a reduction-table seam and against compiler_rt.
    var x: f64 = -745.0;
    var prev: f64 = 0.0;
    while (x < 709.0) : (x += 0.0731) {
        const e = armExp(x);
        try std.testing.expect(e >= prev);
        prev = e;
        if (@exp(x) > 0x1p-1022) try std.testing.expect(bits.ulps(e, @exp(x)) <= 1);
    }
    // pow: C99 F.10.4.4 rows and exact results.
    try std.testing.expectEqual(@as(f64, 1.0), armPow(-3.0, 0.0));
    try std.testing.expectEqual(@as(f64, 1.0), armPow(1.0, std.math.nan(f64)));
    try std.testing.expectEqual(@as(f64, 1024.0), armPow(2.0, 10.0));
    try std.testing.expectEqual(@as(f64, -8.0), armPow(-2.0, 3.0));
    try std.testing.expectEqual(@as(f64, 0.0625), armPow(-2.0, -4.0));
    try std.testing.expectEqual(@as(f64, 2.0), armPow(4.0, 0.5));
    try std.testing.expectEqual(@as(f64, 0.1), armPow(0.1, 1.0));
    try std.testing.expect(std.math.isNan(armPow(-2.0, 0.5)));
    try std.testing.expectEqual(inf, armPow(0.0, -1.0));
    try std.testing.expectEqual(-inf, armPow(-0.0, -1.0));
    try std.testing.expectEqual(@as(u64, 1 << 63), @as(u64, @bitCast(armPow(-0.0, 3.0))));
    try std.testing.expectEqual(@as(f64, 0.0), armPow(0.5, inf));
    try std.testing.expectEqual(inf, armPow(2.0, inf));
    try std.testing.expectEqual(inf, armPow(10.0, 400.0));
    try std.testing.expectEqual(@as(f64, 0.0), armPow(10.0, -400.0));
    var b: f64 = 0.013;
    while (b < 90.0) : (b *= 1.37) {
        var e: f64 = -7.3;
        while (e < 7.3) : (e += 0.61) {
            const want = std.math.pow(f64, b, e);
            // std's pow is the less accurate of the two; a few ulps apart.
            try std.testing.expect(bits.ulps(armPow(b, e), want) <= 4);
        }
    }
}

test "gm exp/log agree with compiler_rt to 1 ulp; the device ports with libm" {
    // exp/log are VerA's (<= 0.52 ulp); compiler_rt's are < 1 ulp, so
    // the two may differ by one ulp, never more. The sin/cos/expm1 device
    // ports are pinned against libm so a transcription slip fails here,
    // not inside a kernel.
    var x: f64 = -700.0;
    while (x <= 700.0) : (x += 13.77) try std.testing.expect(bits.ulps(exp(x), @exp(x)) <= 1);
    var y: f64 = 1e-30;
    while (y < 1e30) : (y *= 3.7) try std.testing.expect(bits.ulps(log(y), @log(y)) <= 1);
    try std.testing.expectEqual(-std.math.inf(f64), log(0.0));
    try std.testing.expect(std.math.isNan(log(-1.0)));
    try std.testing.expectEqual(std.math.inf(f64), exp(710.0));
    try std.testing.expectEqual(@as(f64, 0.0), exp(-746.0));
    var t: f64 = -8.0;
    while (t <= 8.0) : (t += 0.0937) {
        try std.testing.expectEqual(@sin(t), sin(t));
        try std.testing.expectEqual(@cos(t), cos(t));
        const eps = 4 * std.math.floatEps(f64); // abs bound: zeros of sin/cos
        try std.testing.expect(@abs(musl.sin(t) - @sin(t)) <= eps);
        try std.testing.expect(@abs(musl.cos(t) - @cos(t)) <= eps);
    }
    try std.testing.expectApproxEqAbs(@sin(1e9), musl.sin(1e9), 1e-6);
    try std.testing.expect(std.math.isNan(musl.sin(std.math.inf(f64))));
    try std.testing.expectEqual(@as(f64, 1.0), musl.cos(0.0));

    // expm1: the port drops a line that touched only the FP flag register,
    // so every VALUE must equal std's. Bit equality, not a tolerance --
    // anything looser would hide a transcription slip in a branch the
    // sweep happens to straddle. The edges are the reduction boundaries
    // the algorithm actually switches on.
    for ([_]f64{
        0,       -0.0,    0x1p-60, -0x1p-60, 0x1p-54, -0x1p-54, 1e-300,
        0.3465,  -0.3465, 0.3466,  -0.3466,  1.0397,  -1.0397,  1.0398,
        -1.0398, 1,       -1,      0.25,     -0.25,   -0.2501,  2,
        -2,      38.8,    -38.8,   38.9,     709.78,  710,      -745,
    }) |v| {
        try std.testing.expectEqual(
            @as(u64, @bitCast(std.math.expm1(v))),
            @as(u64, @bitCast(musl.expm1(v))),
        );
    }
    var m: f64 = -40.0;
    while (m <= 40.0) : (m += 0.00731) {
        try std.testing.expectEqual(
            @as(u64, @bitCast(std.math.expm1(m))),
            @as(u64, @bitCast(musl.expm1(m))),
        );
    }
    try std.testing.expectEqual(@as(f64, -1), musl.expm1(-std.math.inf(f64)));
    try std.testing.expectEqual(std.math.inf(f64), musl.expm1(std.math.inf(f64)));
    try std.testing.expect(std.math.isNan(musl.expm1(std.math.nan(f64))));
    // log1p: the same one-line drop, so the same bit equality. The edges
    // are its branch points: 2^-53, 1 + x = sqrt(2)/2 and sqrt(2), -1.
    for ([_]f64{
        0,      -0.0,     0x1p-60,  -0x1p-60, 0x1p-53, 1e-310, -1e-310, 0.41421,
        0.4143, -0.29289, -0.29290, -1,       -1.5,    1e300,  0.5,     -0.5,
    }) |v| {
        try std.testing.expectEqual(@as(u64, @bitCast(std.math.log1p(v))), @as(u64, @bitCast(musl.log1p(v))));
    }
    m = -0.999;
    while (m <= 40.0) : (m += 0.00731) {
        try std.testing.expectEqual(@as(u64, @bitCast(std.math.log1p(m))), @as(u64, @bitCast(musl.log1p(m))));
    }
    try std.testing.expectEqual(std.math.inf(f64), musl.log1p(std.math.inf(f64)));
    try std.testing.expect(std.math.isNan(musl.log1p(std.math.nan(f64))));
    // The host branch must still BE std's, so expm1/atan are unchanged
    // for every build that is not a GPU kernel.
    try std.testing.expectEqual(std.math.expm1(@as(f64, 0.7)), expm1(0.7));
    try std.testing.expectEqual(std.math.atan(@as(f64, 0.7)), atan(0.7));

    // atan's device branch is std's own vector body, so it is not
    // bit-identical to the scalar one -- pin the gap at an ulp.
    var a: f64 = -20.0;
    while (a <= 20.0) : (a += 0.0137) {
        const want = std.math.atan(a);
        const got = std.math.atan(@as(@Vector(2, f64), @splat(a)))[0];
        try std.testing.expect(@abs(got - want) <= 2 * @abs(want) * std.math.floatEps(f64));
    }
}

test "acosh is NaN for every x below 1, the far negative side included" {
    // C99 F.10.2.1: a domain error below 1. musl's formulas, which read
    // only |x|'s exponent, gave -8.048412491148412 at -12345.678.
    for ([_]f64{ 0.5, 0.0, -0.0, -1.0, -1.5, -2.0, -2.5, -12345.678, -1e7, -1e300, -std.math.inf(f64) }) |x|
        try std.testing.expect(std.math.isNan(acosh(x)));
    try std.testing.expectEqual(@as(f64, 0.0), acosh(1.0));
    try std.testing.expectEqual(std.math.inf(f64), acosh(std.math.inf(f64)));
    try std.testing.expect(bits.ulps(acosh(10.0), std.math.acosh(@as(f64, 10.0))) <= 2);
}
