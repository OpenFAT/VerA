//! An `f64` in, the libm function's value out, for the targets with no libm
//! (NVPTX, AMDGCN): musl's expm1.c and log1p.c (by way of `std.math`, minus
//! the one `doNotOptimizeAway` the AMDGPU backend cannot match), and musl's
//! k_sin.c, k_cos.c and the medium branch of __rem_pio2.c for sin and cos.
//! `gm.zig` calls them only on a GPU target; its tests pin them on the host.
//! Cites: C99 F.10.3.3 (expm1), F.10.3.9 (log1p), F.10.1.6/F.10.1.5 (sin,
//! cos).
//!
//! Contents:
//! - `pub fn expm1(x: f64) f64`
//! - `pub fn log1p(x: f64) f64`
//! - `pub fn sin(x: f64) f64`
//! - `pub fn cos(x: f64) f64`

const std = @import("std");
const assert = std.debug.assert;

const ln2hi = 6.93147180369123816490e-01;
const ln2lo = 1.90821492927058770002e-10;
const log2e = 1.44269504088896338700;
// musl k_sin.c / k_cos.c and the medium branch of __rem_pio2.
const pio4 = 0x1.921fb54442d18p-1;
const pio2 = 0x1.921fb54442d18p+0;
const invpio2 = 6.36619772367581382433e-01;
const pio2_1 = 1.57079632673412561417e+00;
const pio2_1t = 6.07710050650619224932e-11;
const pio2_2 = 6.07710050630396597660e-11;
const pio2_2t = 2.02226624879595063154e-21;
const pio2_3 = 2.02226624871116645580e-21;
const pio2_3t = 8.47842766036889956997e-32;
const tau_hi = 6.28318530717958623200e+00;
const tau_lo = 2.44929359829470635445e-16;

const S1 = -1.66666666666666324348e-01;
const S2 = 8.33333333332248946124e-03;
const S3 = -1.98412698298579493134e-04;
const S4 = 2.75573137070700676789e-06;
const S5 = -2.50507602534068634195e-08;
const S6 = 1.58969099521155010221e-10;

const C1 = 4.16666666666666019037e-02;
const C2 = -1.38888888888741095749e-03;
const C3 = 2.48015872894767294178e-05;
const C4 = -2.75573143513906633035e-07;
const C5 = 2.08757232129817482790e-09;
const C6 = -1.13596475577881948265e-11;

/// e^x - 1 without cancellation near 0; every value equals `std.math.expm1`'s.
pub fn expm1(x: f64) f64 {
    const r = softExpm1(x);
    assert(!(r < -1.0)); // e^x > 0 for every x.
    assert(std.math.isNan(r) == std.math.isNan(x));
    return r;
}

/// ln(1 + x) without cancellation near 0; every value equals
/// `std.math.log1p`'s.
pub fn log1p(x: f64) f64 {
    const r = softLog1p(x);
    assert(!(x > -1.0) or !std.math.isNan(r)); // Defined above -1.
    return r;
}

/// sin(x); the phase accuracy decays past |x| ~ 1.6e6 rad (`remPio2`).
pub fn sin(x: f64) f64 {
    const r = softSin(x);
    assert(!(@abs(r) > 1.0));
    return r;
}

/// cos(x), with `sin`'s accuracy.
pub fn cos(x: f64) f64 {
    const r = softCos(x);
    assert(!(@abs(r) > 1.0));
    return r;
}

// ---- private ----

/// musl expm1.c, by way of `std.math.expm1`, minus its one
/// `doNotOptimizeAway`, see `gm.expm1`.
///
/// Not `exp(x) - 1`: the whole point is that the `-1` happens INSIDE
/// the reduced-argument polynomial, where the subtraction would otherwise
/// cancel away most of the significand for small x.
fn softExpm1(x_: f64) f64 {
    if (std.math.isNan(x_)) return std.math.nan(f64);
    const Q1 = -3.33333333333331316428e-02;
    const Q2 = 1.58730158725481460165e-03;
    const Q3 = -7.93650757867487942473e-05;
    const Q4 = 4.00821782732936239552e-06;
    const Q5 = -2.01099218183624371326e-07;

    var x = x_;
    const ux: u64 = @bitCast(x);
    const hx: u32 = @as(u32, @intCast(ux >> 32)) & 0x7FFFFFFF;
    const sign = ux >> 63;

    if (std.math.isNegativeInf(x)) return -1.0;
    if (hx >= 0x4043687A) { // |x| >= 56 ln2
        if (hx > 0x7FF00000) return x; // nan
        if (sign != 0) return -1;
        if (x > 7.09782712893383973096e+02) return std.math.inf(f64);
    }

    // SAFETY: musl's branches below set hi, lo and c wherever k is not 0,
    // and k on every path that reaches the polynomial.
    var hi: f64 = undefined;
    var lo: f64 = undefined;
    var c: f64 = undefined;
    var k: i32 = undefined;
    if (hx > 0x3FD62E42) { // |x| > 0.5 ln2
        if (hx < 0x3FF0A2B2) { // |x| < 1.5 ln2
            if (sign == 0) {
                hi = x - ln2hi;
                lo = ln2lo;
                k = 1;
            } else {
                hi = x + ln2hi;
                lo = -ln2lo;
                k = -1;
            }
        } else {
            var kf = log2e * x;
            if (sign != 0) kf -= 0.5 else kf += 0.5;
            k = @intFromFloat(kf);
            const t = @as(f64, @floatFromInt(k));
            hi = x - t * ln2hi;
            lo = t * ln2lo;
        }
        x = hi - lo;
        c = (hi - x) - lo;
    } else if (hx < 0x3C900000) {
        // |x| < 2^-54, where expm1(x) == x. std raises the underflow flag
        // for a subnormal here; that is the line this port drops.
        return x;
    } else {
        k = 0;
    }

    const hfx = 0.5 * x;
    const hxs = x * hfx;
    const r1 = 1.0 + hxs * (Q1 + hxs * (Q2 + hxs * (Q3 + hxs * (Q4 + hxs * Q5))));
    const t = 3.0 - r1 * hfx;
    var e = hxs * ((r1 - t) / (6.0 - x * t));

    if (k == 0) return x - (x * e - hxs);
    e = x * (e - c) - c;
    e -= hxs;
    if (k == -1) return 0.5 * (x - e) - 0.5;
    if (k == 1) {
        if (x < -0.25) return -2.0 * (e - (x + 0.5));
        return 1.0 + 2.0 * (x - e);
    }

    const twopk: f64 = @bitCast(@as(u64, @intCast(0x3FF +% k)) << 52);
    if (k < 0 or k > 56) {
        var y = x - e + 1.0;
        if (k == 1024) y = y * 2.0 * 0x1.0p1023 else y = y * twopk;
        return y - 1.0;
    }
    const uf: f64 = @bitCast(@as(u64, @intCast(0x3FF -% k)) << 52);
    if (k < 20) return (x - e + (1 - uf)) * twopk;
    return (x - (e + uf) + 1) * twopk;
}

/// musl log1p.c, by way of `std.math.log1p`, minus its one
/// `doNotOptimizeAway`, see `gm.log1p`.
fn softLog1p(x: f64) f64 {
    const Lg1: f64 = 6.666666666666735130e-01;
    const Lg2: f64 = 3.999999999940941908e-01;
    const Lg3: f64 = 2.857142874366239149e-01;
    const Lg4: f64 = 2.222219843214978396e-01;
    const Lg5: f64 = 1.818357216161805012e-01;
    const Lg6: f64 = 1.531383769920937332e-01;
    const Lg7: f64 = 1.479819860511658591e-01;
    const ix: u64 = @bitCast(x);
    const hx: u32 = @intCast(ix >> 32);
    var k: i32 = 1;
    var c: f64 = 0;
    var f: f64 = 0;
    if (hx < 0x3FDA827A or hx >> 31 != 0) {
        if (ix == 0xBFF0000000000000) return x / 0.0; // log1p(-1) = -inf
        if (hx >= 0xBFF00000) return (x - x) / 0.0; // x < -1: NaN
        if ((hx << 1) < (0x3CA00000 << 1)) return x; // |x| < 2^-53
        if (hx <= 0xBFD2BEC4) {
            k = 0;
            c = 0;
            f = x;
        }
    } else if (hx >= 0x7FF00000) return x;
    if (k != 0) {
        const uf = 1 + x;
        const hu: u64 = @bitCast(uf);
        var iu: u32 = @intCast(hu >> 32);
        iu += 0x3FF00000 - 0x3FE6A09E;
        k = @as(i32, @intCast(iu >> 20)) - 0x3FF;
        if (k < 54) {
            c = if (k >= 2) 1 - (uf - x) else x - (uf - 1);
            c /= uf;
        } else c = 0;
        iu = (iu & 0x000FFFFF) + 0x3FE6A09E;
        f = @as(f64, @bitCast((@as(u64, iu) << 32) | (hu & 0xFFFFFFFF))) - 1;
    }
    const hfsq = 0.5 * f * f;
    const s = f / (2.0 + f);
    const z = s * s;
    const w = z * z;
    const t1 = w * (Lg2 + w * (Lg4 + w * Lg6));
    const t2 = z * (Lg1 + w * (Lg3 + w * (Lg5 + w * Lg7)));
    const R = t2 + t1;
    const dk: f64 = @floatFromInt(k);
    return s * (hfsq + R) + (dk * ln2lo + c) - hfsq + f + dk * ln2hi;
}

/// sin on [-pi/4, pi/4]; `y` is the low half of a double-double argument.
fn kernelSin(x: f64, y: f64, tail: bool) f64 {
    const z = x * x;
    const w = z * z;
    const r = S2 + z * (S3 + z * S4) + z * w * (S5 + z * S6);
    const v = z * x;
    if (!tail) return x + v * (S1 + z * r);
    return x - ((z * (0.5 * y - v * r) - y) - v * S1);
}

/// cos on [-pi/4, pi/4]; `y` is the low half of a double-double argument.
fn kernelCos(x: f64, y: f64) f64 {
    const z = x * x;
    const zz = z * z;
    const r = z * (C1 + z * (C2 + z * C3)) + zz * zz * (C4 + z * (C5 + z * C6));
    const hz = 0.5 * z;
    const w = 1.0 - hz;
    return w + (((1.0 - w) - hz) + (z * r - x * y));
}

/// x = y[0] + y[1] + n*(pi/2), with |y[0]| <= pi/4. Returns n.
fn remPio2(x: f64, y: *[2]f64) i32 {
    // ponytail: no Payne-Hanek. Past 2^20*(pi/2) ~= 1.6e6 rad the
    // Cody-Waite splits stop being exact, so pre-reduce mod 2pi in
    // double-double instead; phase accuracy then decays ~1 bit per
    // octave. Exact phase beyond that wants musl's __rem_pio2_large.
    var xr = x;
    if (@abs(xr) >= 0x1p20 * pio2) {
        const q0 = @round(xr / (tau_hi + tau_lo));
        xr = (xr - q0 * tau_hi) - q0 * tau_lo;
    }

    var q: f64 = @round(xr * invpio2);
    var n: i32 = @intFromFloat(q);
    var r = xr - q * pio2_1;
    var w = q * pio2_1t; // 1st round, good to 85 bits
    if (r - w < -pio4) {
        n -= 1;
        q -= 1;
        r = xr - q * pio2_1;
        w = q * pio2_1t;
    } else if (r - w > pio4) {
        n += 1;
        q += 1;
        r = xr - q * pio2_1;
        w = q * pio2_1t;
    }
    y[0] = r - w;

    const ex = expOf(xr);
    if (ex - expOf(y[0]) > 16) { // 2nd round, good to 118 bits
        const t = r;
        w = q * pio2_2;
        r = t - w;
        w = q * pio2_2t - ((t - r) - w);
        y[0] = r - w;
        if (ex - expOf(y[0]) > 49) { // 3rd round, covers the rest
            const t3 = r;
            w = q * pio2_3;
            r = t3 - w;
            w = q * pio2_3t - ((t3 - r) - w);
            y[0] = r - w;
        }
    }
    y[1] = (r - y[0]) - w;
    return n;
}

fn expOf(x: f64) i32 {
    return @intCast(@as(u64, @bitCast(x)) >> 52 & 0x7ff);
}

fn softSin(x: f64) f64 {
    const ax = @abs(x);
    if (ax < pio4) return if (ax < 0x1p-27) x else kernelSin(x, 0.0, false);
    if (!std.math.isFinite(x)) return std.math.nan(f64);
    // SAFETY: `remPio2` writes both halves.
    var y: [2]f64 = undefined;
    const n = remPio2(x, &y);
    return switch (@as(u32, @bitCast(n)) & 3) {
        0 => kernelSin(y[0], y[1], true),
        1 => kernelCos(y[0], y[1]),
        2 => -kernelSin(y[0], y[1], true),
        else => -kernelCos(y[0], y[1]),
    };
}

fn softCos(x: f64) f64 {
    const ax = @abs(x);
    if (ax < pio4) return if (ax < 0x1p-27) 1.0 else kernelCos(x, 0.0);
    if (!std.math.isFinite(x)) return std.math.nan(f64);
    // SAFETY: `remPio2` writes both halves.
    var y: [2]f64 = undefined;
    const n = remPio2(x, &y);
    return switch (@as(u32, @bitCast(n)) & 3) {
        0 => kernelCos(y[0], y[1]),
        1 => -kernelSin(y[0], y[1], true),
        2 => -kernelCos(y[0], y[1]),
        else => kernelSin(y[0], y[1], true),
    };
}
