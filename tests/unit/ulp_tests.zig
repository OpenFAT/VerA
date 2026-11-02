//! L3 math oracle: every f64 function `contract.gm`
//! exports, against an f128 reference, in units of the last place of an f64
//! at the reference's magnitude. In: hard cases (specials, range ends,
//! reduction seams, subnormals) and seeded random arguments; out: each
//! function's worst error, asserted against the bound measured on 2026-10-08
//! and written beside it. The references are compiler_rt's binary128 `@exp`,
//! `@log`, `@sin`, `@cos`, `@sqrt` and `std.math.atan`/`asin`/`acos`'s
//! binary128 paths, with a series wherever a difference would cancel; none
//! of it is `gm`'s code, and pow's and atan2's special cases are C99
//! F.10.4.4's and F.10.1.4's lists, transcribed here. asin and acos are
//! `std.math`'s f64 functions, the ones a device and the folder call (#60).
//!
//! Host only: `gm`'s GPU branches (the tanh/sinh/cosh/sin/cos ports) are
//! private and compile only for NVPTX and AMDGCN, so their bound is not
//! measured here. On the host tanh, sinh, cosh, expm1 and atan are
//! `std.math`'s and sin/cos the builtins; their rows pin what a device built
//! for the host gets.

const std = @import("std");
const gm = @import("contract").gm;

const Q = f128;
const inf = std.math.inf(f64);
const nan = std.math.nan(f64);

/// |got - ref| in units of 2^(e-52), where 2^e <= |ref| < 2^(e+1), e clamped
/// to f64's normal range [-1022, 1023] (so below 2^-1022 the unit is the
/// least subnormal). An infinite `got` stands for 2^1024, one unit past the
/// largest double, and is exact when |ref| is at least that. NaN must meet NaN.
fn ulpErr(got: f64, ref: Q) f64 {
    if (std.math.isNan(ref) or std.math.isNan(got))
        return if (std.math.isNan(ref) and std.math.isNan(got)) 0 else inf;
    const big: Q = 0x1p1024;
    var g: Q = got;
    if (std.math.isInf(got)) {
        if (@abs(ref) >= big and std.math.signbit(got) == std.math.signbit(ref)) return 0;
        g = std.math.copysign(big, @as(Q, got));
    }
    const a = @abs(ref);
    const e: i32 = if (a < 0x1p-1022) -1022 else @min(std.math.ilogb(a), 1023);
    return @floatCast(@abs(g - ref) / std.math.ldexp(@as(Q, 1), e - 52));
}

// ---- the references ------------------------------------------------------

fn expQ(x: f64) Q {
    return @exp(@as(Q, x));
}
fn logQ(x: f64) Q {
    return @log(@as(Q, x));
}
fn sinQ(x: f64) Q {
    return @sin(@as(Q, x));
}
fn cosQ(x: f64) Q {
    return @cos(@as(Q, x));
}
fn atanQ(x: f64) Q {
    return std.math.atan(@as(Q, x));
}

/// e^x - 1 = Σ x^n/n! (n >= 1), summed: no cancellation near 0.
fn expm1Series(x: f64) Q {
    const q: Q = x;
    var term = q;
    var sum: Q = 0;
    var n: Q = 1;
    while (n < 40) : (n += 1) {
        sum += term;
        term = term * q / (n + 1);
    }
    return sum;
}

/// sinh x = Σ x^n/n! (n odd), summed for the same reason.
fn sinhSeries(x: f64) Q {
    const q: Q = x;
    var term = q;
    var sum: Q = 0;
    var n: Q = 1;
    while (n < 60) : (n += 2) {
        sum += term;
        term = term * q * q / ((n + 1) * (n + 2));
    }
    return sum;
}

fn expm1Q(x: f64) Q {
    if (@abs(x) < 0.25) return expm1Series(x);
    return @exp(@as(Q, x)) - 1;
}
fn sinhQ(x: f64) Q {
    if (std.math.isInf(x)) return x;
    if (@abs(x) < 0.25) return sinhSeries(x);
    const e = @exp(@as(Q, x));
    return (e - 1 / e) / 2;
}
fn coshQ(x: f64) Q {
    if (std.math.isInf(x)) return inf;
    const e = @exp(@as(Q, x));
    return (e + 1 / e) / 2;
}
fn tanhQ(x: f64) Q {
    if (std.math.isInf(x)) return std.math.copysign(@as(Q, 1), @as(Q, x));
    if (@abs(x) > 40) return std.math.copysign(@as(Q, 1), @as(Q, x)) * (1 - 2 * @exp(-2 * @abs(@as(Q, x))));
    return sinhQ(x) / coshQ(x);
}

/// The inverse hyperbolics and log10 in binary128, from `@log` and `@sqrt`:
/// 113 bits leave each formula's cancellation (asinh at x < 0 is taken at
/// |x|; acosh's x² - 1 as (x - 1)(x + 1), exact near 1) far below an f64
/// ulp, and below 2^-30 the odd ones are their series.
fn asinhQ(x: f64) Q {
    if (std.math.isNan(x) or std.math.isInf(x)) return x;
    const a: Q = @abs(@as(Q, x));
    const r = if (a < 0x1p-30) a - a * a * a / 6 else @log(a + @sqrt(a * a + 1));
    return std.math.copysign(r, @as(Q, x));
}
fn acoshQ(x: f64) Q {
    if (std.math.isNan(x) or x < 1) return nan;
    if (std.math.isInf(x)) return inf;
    const q: Q = x;
    return @log(q + @sqrt((q - 1) * (q + 1)));
}
fn atanhQ(x: f64) Q {
    if (std.math.isNan(x) or @abs(x) > 1) return nan;
    if (@abs(x) == 1) return std.math.copysign(@as(Q, inf), @as(Q, x));
    const a: Q = @abs(@as(Q, x));
    const r = if (a < 0x1p-30) a + a * a * a / 3 else @log((1 + a) / (1 - a)) / 2;
    return std.math.copysign(r, @as(Q, x));
}
fn log10Q(x: f64) Q {
    if (std.math.isNan(x) or x < 0) return nan;
    if (x == 0) return -inf;
    if (std.math.isInf(x)) return inf;
    return @log(@as(Q, x)) / @log(@as(Q, 10));
}
fn tanQ(x: f64) Q {
    return @sin(@as(Q, x)) / @cos(@as(Q, x));
}
/// atan2 by quadrant from `atanQ`, with C99 F.10.1.4's zeros and infinities.
fn atan2Q(y: f64, x: f64) Q {
    if (std.math.isNan(x) or std.math.isNan(y)) return nan;
    const pi: Q = std.math.pi;
    const yq: Q = y;
    const xq: Q = x;
    if (y == 0) return if (std.math.signbit(x)) std.math.copysign(pi, yq) else yq;
    if (x == 0) return std.math.copysign(pi / 2, yq);
    if (std.math.isInf(x) or std.math.isInf(y)) {
        const a: Q = if (std.math.isInf(x) and std.math.isInf(y)) pi / 4 else if (std.math.isInf(y)) pi / 2 else 0;
        const r = if (x < 0) pi - a else a;
        return std.math.copysign(r, yq);
    }
    const z = std.math.atan(@abs(yq / xq));
    return if (x > 0) std.math.copysign(z, yq) else std.math.copysign(pi - z, yq);
}

fn isInt(y: f64) bool {
    return std.math.isFinite(y) and @trunc(y) == y;
}
fn isOdd(y: f64) bool {
    return isInt(y) and @abs(y) < 0x1p53 and @mod(y, 2) == 1;
}

/// C99 F.10.4.4, row by row; null when x and y are finite, x is not ±0 and
/// not 1, and the result is an ordinary power.
fn powSpecial(x: f64, y: f64) ?f64 {
    if (x == 1 or y == 0) return 1; // "even if" the other is a NaN
    if (std.math.isNan(x) or std.math.isNan(y)) return nan;
    if (x == 0) {
        if (y < 0) return if (isOdd(y)) std.math.copysign(inf, x) else inf;
        return if (isOdd(y)) x else 0;
    }
    if (std.math.isInf(y)) {
        if (x == -1) return 1;
        return if ((@abs(x) < 1) == (y < 0)) inf else 0;
    }
    if (std.math.isInf(x)) {
        if (x < 0) {
            if (y < 0) return if (isOdd(y)) -0.0 else 0;
            return if (isOdd(y)) -inf else inf;
        }
        return if (y < 0) 0 else inf;
    }
    if (x < 0 and !isInt(y)) return nan;
    return null;
}

fn powQ(x: f64, y: f64) Q {
    if (powSpecial(x, y)) |s| return s;
    const m = @exp(@as(Q, y) * @log(@abs(@as(Q, x))));
    return if (x < 0 and isOdd(y)) -m else m;
}

// ---- the functions under test -------------------------------------------

fn exp(x: f64) f64 {
    return gm.exp(x);
}
fn log(x: f64) f64 {
    return gm.log(x);
}
fn expm1(x: f64) f64 {
    return gm.expm1(x);
}
fn sinh(x: f64) f64 {
    return gm.sinh(x);
}
fn cosh(x: f64) f64 {
    return gm.cosh(x);
}
fn tanh(x: f64) f64 {
    return gm.tanh(x);
}
fn sin(x: f64) f64 {
    return gm.sin(x);
}
fn cos(x: f64) f64 {
    return gm.cos(x);
}
fn atan(x: f64) f64 {
    return gm.atan(x);
}
fn asinh(x: f64) f64 {
    return gm.asinh(x);
}
fn acosh(x: f64) f64 {
    return gm.acosh(x);
}
fn atanh(x: f64) f64 {
    return gm.atanh(x);
}
fn log10(x: f64) f64 {
    return gm.log10(x);
}
fn tan(x: f64) f64 {
    return gm.tan(x);
}
fn expV(x: @Vector(4, f64)) @Vector(4, f64) {
    return gm.exp(x);
}
fn logV(x: @Vector(4, f64)) @Vector(4, f64) {
    return gm.log(x);
}

// ---- argument generators -------------------------------------------------

/// ±2^u·(1 + frac), u uniform in [lo, hi]: every binade equally often.
fn binade(r: std.Random, lo: i32, hi: i32) f64 {
    const m = 1 + r.float(f64);
    const v = std.math.ldexp(m, r.intRangeAtMost(i32, lo, hi));
    return if (r.boolean()) -v else v;
}
fn uniform(r: std.Random, lo: f64, hi: f64) f64 {
    return lo + (hi - lo) * r.float(f64);
}

fn genExp(r: std.Random) f64 {
    return switch (r.uintLessThan(u8, 10)) {
        0, 1 => binade(r, -1074, -1),
        // exp's reduction table has 128 entries per ln 2: land on its seams.
        2 => @as(f64, @floatFromInt(r.intRangeAtMost(i32, -137000, 131000))) * (std.math.ln2 / 128.0) * (1 + uniform(r, -1e-15, 1e-15)),
        else => uniform(r, -745.2, 709.8),
    };
}
fn genLog(r: std.Random) f64 {
    return switch (r.uintLessThan(u8, 10)) {
        0, 1, 2, 3, 4 => @bitCast(r.intRangeAtMost(u64, 1, 0x7fefffffffffffff)),
        5, 6 => 1 + uniform(r, -0x1p-4, 0x1p-4),
        7 => 1 + std.math.ldexp(uniform(r, -1, 1), -r.intRangeAtMost(i32, 5, 60)),
        else => uniform(r, 0.5, 2),
    };
}
fn genExpm1(r: std.Random) f64 {
    return switch (r.uintLessThan(u8, 10)) {
        0, 1, 2 => binade(r, -1074, -2),
        3, 4 => uniform(r, -1, 1),
        else => uniform(r, -40, 709.8),
    };
}
fn genHyp(r: std.Random) f64 {
    return switch (r.uintLessThan(u8, 10)) {
        0, 1 => binade(r, -1074, -2),
        2, 3, 4 => uniform(r, -2, 2),
        else => uniform(r, -710.4, 710.4),
    };
}
fn genTanh(r: std.Random) f64 {
    return switch (r.uintLessThan(u8, 10)) {
        0, 1 => binade(r, -1074, -2),
        2, 3 => uniform(r, -1, 1),
        else => uniform(r, -25, 25),
    };
}
fn genTrig(r: std.Random) f64 {
    return switch (r.uintLessThan(u8, 10)) {
        0 => binade(r, -1074, -2),
        1, 2, 3 => uniform(r, -1e6, 1e6),
        else => uniform(r, -10, 10),
    };
}
fn genAtan(r: std.Random) f64 {
    return switch (r.uintLessThan(u8, 10)) {
        0, 1, 2, 3, 4 => binade(r, -1074, 1023),
        else => uniform(r, -4, 4),
    };
}

fn genAsinh(r: std.Random) f64 {
    return switch (r.uintLessThan(u8, 10)) {
        0, 1, 2, 3 => binade(r, -1074, 1023),
        4, 5 => binade(r, -30, 2),
        else => uniform(r, -4, 4),
    };
}
fn genAcosh(r: std.Random) f64 {
    return switch (r.uintLessThan(u8, 10)) {
        0, 1, 2 => @abs(binade(r, 0, 1023)),
        3, 4, 5 => 1 + std.math.ldexp(r.float(f64), -r.intRangeAtMost(i32, 1, 52)),
        else => uniform(r, 1, 4),
    };
}
fn genAtanh(r: std.Random) f64 {
    return switch (r.uintLessThan(u8, 10)) {
        0, 1, 2 => binade(r, -1074, -1),
        3, 4 => std.math.copysign(1 - std.math.ldexp(r.float(f64), -r.intRangeAtMost(i32, 1, 52)), uniform(r, -1, 1)),
        else => uniform(r, -1, 1),
    };
}
fn genUnit(r: std.Random) f64 {
    return switch (r.uintLessThan(u8, 10)) {
        0, 1 => binade(r, -1074, -1),
        2, 3 => std.math.copysign(1 - std.math.ldexp(r.float(f64), -r.intRangeAtMost(i32, 1, 52)), uniform(r, -1, 1)),
        else => uniform(r, -1, 1),
    };
}
fn asin(x: f64) f64 {
    return std.math.asin(x);
}
fn acos(x: f64) f64 {
    return std.math.acos(x);
}
fn asinQ(x: f64) Q {
    if (std.math.isNan(x) or @abs(x) > 1) return nan;
    return std.math.asin(@as(Q, x));
}
fn acosQ(x: f64) Q {
    if (std.math.isNan(x) or @abs(x) > 1) return nan;
    return std.math.acos(@as(Q, x));
}

// ---- the judge -----------------------------------------------------------

const Worst = struct {
    ulp: f64 = 0,
    x: f64 = 0,
    y: f64 = 0,

    fn see(w: *Worst, e: f64, x: f64, y: f64) void {
        if (e > w.ulp or std.math.isNan(e)) w.* = .{ .ulp = e, .x = x, .y = y };
    }

    /// Whether the worst case is within `bound`; prints it when not, so
    /// one run reports every function.
    fn within(w: Worst, name: []const u8, limit: f64) bool {
        if (w.ulp <= limit) return true;
        std.debug.print("ulp: {s}: {d:.4} ulp at x = {e} (y = {e}), over the bound {d}\n", .{ name, w.ulp, w.x, w.y, limit });
        return false;
    }
};

const n_random = 250_000;

/// Hard cases every unary function sees besides its own.
const common = [_]f64{
    0,         -0.0,      inf,                     -inf,         nan,    0x1p-1074,              -0x1p-1074,
    0x1p-1022, 0x1p-1023, 0x1.fffffffffffffp-1023, 1,            -1,     0.5,                    -0.5,
    2,         -2,        std.math.pi,             -std.math.pi, 1e-300, std.math.floatMax(f64), -std.math.floatMax(f64),
};

fn judge1(comptime f: fn (f64) f64, comptime ref: fn (f64) Q, hard: []const f64, comptime gen: fn (std.Random) f64, seed: u64) Worst {
    var w: Worst = .{};
    for (common) |x| w.see(ulpErr(f(x), ref(x)), x, 0);
    for (hard) |x| w.see(ulpErr(f(x), ref(x)), x, 0);
    var prng: std.Random.DefaultPrng = .init(seed);
    for (0..n_random) |_| {
        const x = gen(prng.random());
        w.see(ulpErr(f(x), ref(x)), x, 0);
    }
    return w;
}

/// The vector form, four random lanes at a time, every lane judged.
fn judgeV(comptime f: fn (@Vector(4, f64)) @Vector(4, f64), comptime ref: fn (f64) Q, comptime gen: fn (std.Random) f64, seed: u64) Worst {
    var w: Worst = .{};
    var prng: std.Random.DefaultPrng = .init(seed);
    for (0..n_random / 4) |_| {
        var v: @Vector(4, f64) = undefined;
        inline for (0..4) |l| v[l] = gen(prng.random());
        const got = f(v);
        inline for (0..4) |l| w.see(ulpErr(got[l], ref(v[l])), v[l], 0);
    }
    return w;
}

/// exp's seams: the overflow and underflow thresholds, and the last
/// argument whose result is normal.
const exp_hard = [_]f64{
    0x1.62e42fefa39efp9,  0x1.62e42fefa39f0p9,  -0x1.74910d52d3051p9, -0x1.74910d52d3052p9,
    -0x1.6232bdd7abcd2p9, -0x1.6232bdd7abcd3p9, 709.7,                -708.4,
    -745.0,               1e-17,                -1e-17,               0x1p-53,
};
const log_hard = [_]f64{
    0x1.0000000000001p0,  0x1.fffffffffffffp-1, 0x1.0000000000002p0, 0x1.ffffffffffffep-1,
    0x1.6a09e667f3bcdp-1, 0x1.6a09e667f3bccp-1, 0x1p-1060,           1e-310,
    std.math.e,           10,                   0x1p1023,            1.0000001,
};
const expm1_hard = [_]f64{
    0x1p-60, -0x1p-60, 0x1p-54, -0x1p-54, 0.3465,  -0.3465, 0.3466, -0.3466, 1.0397, -1.0397,
    1.0398,  -1.0398,  0.25,    -0.25,    -0.2501, 38.8,    -38.8,  38.9,    709.78, 710,
    -745,
};
const hyp_hard = [_]f64{ 0.625, -0.625, 0.6249999999999999, 22, -22, 710.4, 710.5, -710.5, 0x1p-28, 20, 40.5 };
const trig_hard = [_]f64{
    std.math.pi / 2.0, -std.math.pi / 2.0, std.math.pi / 4.0, 3.0 * std.math.pi / 2.0, 1e5, 1.6e6, 1e9, 1e22, 1e300, 0x1p-28,
};
const atan_hard = [_]f64{ 0.4375, 0.6875, 1.1875, 2.4375, 0x1p66, -0x1p66, 0x1p-27, 7.0 / 16.0, 39.0 / 16.0 };
/// The musl branch seams (|x| = 2^-26, 2, 2^26; acosh's 2 and 2^26;
/// atanh's 2^-32 and 0.5), and #60's values.
const asinh_hard = [_]f64{ 0x1p-26, -0x1p-26, 0x1.fffffffffffffp-27, 2, -2, 0x1.fffffffffffffp0, 0x1p26, -0x1p26, 1e154, 1e155, -1e8, -1e3, 1e-10, 1e300 };
const acosh_hard = [_]f64{ 0x1.0000000000001p0, 0x1.0000000000002p0, 1.0000000001, 0x1.fffffffffffffp0, 0x1p26, 0x1.fffffffffffffp25, 1e154, 1e300, 0.5, 0x1.fffffffffffffp-1 };
const atanh_hard = [_]f64{ 0x1p-32, 0x1.fffffffffffffp-33, 0.5, 0x1.fffffffffffffp-2, -0.5, 0x1.fffffffffffffp-1, -0x1.fffffffffffffp-1, 1e-10, 0.9999999999 };
const log10_hard = [_]f64{ 1e15, 1e-15, 10, 100, 1e22, 1e-300, 1e300, 0x1.6a09e667f3bcdp-1, 0x1.0000000000001p0, 0x1.fffffffffffffp-1, 0x1p-1060 };

/// The bounds: each function's worst case on 2026-10-08 with this file's
/// seeds, rounded up in the third decimal. `gm`'s own promise is "faithful
/// (< 1 ulp)" for exp, log and pow; a change that moves a bound moves it here.
const bound = struct {
    const exp = 0.507; // 0.5062 at 163.57479821851769 (vector: 0.5052)
    const log = 0.515; // 0.5142 at 1.0843856890111225, a vector lane (scalar: 0.5112)
    const pow = 0.506; // 0.5059 at (-143136349.3604563, 21), scalar and powV
    // On the host the rest are std.math's and compiler_rt's, which promise
    // no bound; sinh, cosh and tanh are not faithful.
    const expm1 = 0.810; // 0.8094 at 0.35354502149644396
    const sinh = 1.739; // 1.7386 at 0.6943002823977769
    const cosh = 1.200; // 1.1992 at -1.0407498633762968
    const tanh = 2.030; // 2.0294 at 0.2498982405738699
    const sin = 0.747; // 0.7463 at 7.080094367729739
    const cos = 0.733; // 0.7327 at -3.863213591144243
    const atan = 0.751; // 0.7507 at 2.680128387647313
    // #60's rows (asinh, acosh, atanh, log10, atan2, tan: `gm`'s musl ports
    // and sin/cos quotient; asin/acos: `std.math`, what a device calls),
    // measured by this file on 2026-10-18 (ReleaseSafe, x86_64).
    const asinh = 1.524; // 1.5239 at 0.51700870116405
    const acosh = 2.016; // 2.0151 at 1.001887151218172
    const atanh = 1.505; // 1.5049 at -0.12030145777284262
    const log10 = 0.630; // 0.6297 at 1.374951715281116
    const tan = 2.006; // 2.0055 at -145126.64517723466
    const asin = 0.817; // 0.8162 at -0.5042767798999156
    const acos = 0.864; // 0.8632 at -0.5232333655933563
    const atan2 = 1.441; // 1.4405 at y = 0.06365036518777245
};

test "L3 ulp: gm.asinh, acosh, atanh, log10 and tan, and std's asin and acos (#60)" {
    var ok = judge1(asinh, asinhQ, &asinh_hard, genAsinh, 13).within("asinh", bound.asinh);
    ok = judge1(acosh, acoshQ, &acosh_hard, genAcosh, 14).within("acosh", bound.acosh) and ok;
    ok = judge1(atanh, atanhQ, &atanh_hard, genAtanh, 15).within("atanh", bound.atanh) and ok;
    ok = judge1(log10, log10Q, &log10_hard, genLog, 16).within("log10", bound.log10) and ok;
    ok = judge1(tan, tanQ, &trig_hard, genTrig, 17).within("tan", bound.tan) and ok;
    ok = judge1(asin, asinQ, &atanh_hard, genUnit, 18).within("asin", bound.asin) and ok;
    ok = judge1(acos, acosQ, &atanh_hard, genUnit, 19).within("acos", bound.acos) and ok;
    try std.testing.expect(ok);
    // C's log10 is exact at every power of ten, and floor(log10(x)) is how
    // a model counts decades: ln(x)/ln(10) gave 14.999999999999998 at 1e15.
    var p: f64 = 1;
    for (0..23) |k| {
        try std.testing.expectEqual(@as(f64, @floatFromInt(k)), gm.log10(p));
        p *= 10;
    }
    // The values #60 found wrong, from mpmath at 50 digits, correctly rounded
    // or within the bound above: asinh(-1e8) cancelled to -inf, asinh and
    // acosh of 1e300 overflowed x², asinh(1e-10) lost 7 digits.
    try std.testing.expectEqual(@as(f64, -19.11382792451231), gm.asinh(-1e8));
    try std.testing.expect(std.math.approxEqRel(f64, gm.asinh(1e300), 691.4686750787737, 3e-16));
    try std.testing.expect(std.math.approxEqRel(f64, gm.acosh(1e300), 691.4686750787737, 3e-16));
    try std.testing.expectEqual(@as(f64, 1e-10), gm.asinh(1e-10));
    try std.testing.expectEqual(@as(f64, 1e-10), gm.atanh(1e-10));
    // The odd ones keep the sign of zero; atanh's poles are infinities.
    inline for (.{ asinh, atanh }) |f| try std.testing.expect(std.math.signbit(f(-0.0)));
    try std.testing.expectEqual(inf, gm.atanh(1.0));
    try std.testing.expectEqual(-inf, gm.atanh(-1.0));
    // A subnormal argument is scaled by 2^54 first; both words of the scaled
    // value must be used (the first run of this file found 3.75e6 ulp at
    // 3.74e-309). References: CPython's math.log10.
    try std.testing.expect(std.math.approxEqRel(f64, gm.log10(3.74288017396525e-309), -308.426794076337, 4e-16));
    try std.testing.expect(std.math.approxEqRel(f64, gm.log10(0x1p-1074), -323.3062153431158, 4e-16));
    try std.testing.expect(std.math.approxEqRel(f64, gm.log10(2.2250738585072009e-308), -307.6526555685888, 4e-16));
    try std.testing.expectEqual(-inf, gm.log10(0.0));
    try std.testing.expect(std.math.isNan(gm.log10(-1.0)));
    try std.testing.expect(std.math.isNan(gm.acosh(0.5)));
}

test "L3 ulp: gm.atan2, with C99 F.10.1.4's signed zeros (#60)" {
    var w: Worst = .{};
    var prng: std.Random.DefaultPrng = .init(20);
    const r = prng.random();
    for (0..n_random) |i| {
        const y = if (i % 3 == 0) binade(r, -1074, 1023) else uniform(r, -4, 4);
        const x = if (i % 5 == 0) binade(r, -1074, 1023) else uniform(r, -4, 4);
        w.see(ulpErr(gm.atan2(y, x), atan2Q(y, x)), y, x);
    }
    const sp = [_]f64{ 0, -0.0, 1, -1, 0.5, -2, inf, -inf, nan, 0x1p-1074, 1e300 };
    for (sp) |y| for (sp) |x| {
        const want = atan2Q(y, x);
        const got = gm.atan2(y, x);
        w.see(ulpErr(got, want), y, x);
        // A zero carries its sign, which ulpErr cannot see.
        if (want == 0 and std.math.signbit(got) != std.math.signbit(want)) {
            std.debug.print("ulp: atan2({e}, {e}) = {e}, C99 F.10.1.4 says {e}\n", .{ y, x, got, @as(f64, @floatCast(want)) });
            return error.UlpBound;
        }
    };
    try std.testing.expect(w.within("atan2", bound.atan2));
    // Table 4-15's atan2(0,0) = 0 is C's +0, +0; the others are C's.
    try std.testing.expectEqual(@as(f64, 0), gm.atan2(0.0, 0.0));
    try std.testing.expectEqual(-std.math.pi, gm.atan2(-0.0, -1.0));
    try std.testing.expectEqual(std.math.pi, gm.atan2(0.0, -0.0));
    try std.testing.expectEqual(-std.math.pi, gm.atan2(-0.0, -0.0));
    try std.testing.expectEqual(std.math.pi / 2.0, gm.atan2(1.0, 0.0));
}

test "L3 ulp: gm.exp and its vector form stay within the measured bound of an f128 reference" {
    var ok = judge1(exp, expQ, &exp_hard, genExp, 1).within("exp", bound.exp);
    ok = judgeV(expV, expQ, genExp, 2).within("exp (vector)", bound.exp) and ok;
    try std.testing.expect(ok);
}

test "L3 ulp: gm.log and its vector form" {
    var ok = judge1(log, logQ, &log_hard, genLog, 3).within("log", bound.log);
    ok = judgeV(logV, logQ, genLog, 4).within("log (vector)", bound.log) and ok;
    try std.testing.expect(ok);
    // The negative half, zero and -inf: NaN and -inf, never a number.
    for ([_]f64{ -1, -0x1p-1074, -inf, -1e300 }) |x| try std.testing.expect(std.math.isNan(gm.log(x)));
    try std.testing.expectEqual(-inf, gm.log(-0.0));
}

test "L3 ulp: gm.pow and powV, with C99 F.10.4.4's special cases bit for bit" {
    var w: Worst = .{};
    var wv: Worst = .{};
    var prng: std.Random.DefaultPrng = .init(5);
    const r = prng.random();
    for (0..n_random) |i| {
        var x: f64 = undefined;
        var y: f64 = undefined;
        switch (i % 5) {
            // Any positive base, an exponent whose result lands anywhere
            // from underflow to overflow.
            0, 1 => {
                x = @abs(binade(r, -1074, 1023));
                y = uniform(r, -1100, 1100) / std.math.log2(x);
            },
            2 => {
                x = @abs(binade(r, -20, 20));
                y = uniform(r, -10, 10);
            },
            // A negative base and an integer exponent.
            3 => {
                x = -@abs(binade(r, -30, 30));
                y = @trunc(uniform(r, -40, 40));
            },
            // Near 1, raised far.
            else => {
                x = 1 + std.math.ldexp(uniform(r, -1, 1), -r.intRangeAtMost(i32, 10, 52));
                y = binade(r, 0, 60);
            },
        }
        w.see(ulpErr(gm.pow(x, y), powQ(x, y)), x, y);
        const v = gm.powV(@as(@Vector(2, f64), .{ x, -x }), y);
        wv.see(ulpErr(v[0], powQ(x, y)), x, y);
        wv.see(ulpErr(v[1], powQ(-x, y)), -x, y);
    }
    const sp = [_]f64{ 0, -0.0, 1, -1, 0.5, -0.5, 2, -2, 3, -3, 2.5, -2.5, inf, -inf, nan, 0x1p53, -0x1p53, 0x1p-1074 };
    for (sp) |x| for (sp) |y| {
        const want = powQ(x, y);
        const got = gm.pow(x, y);
        w.see(ulpErr(got, want), x, y);
        // A zero or an infinity carries its sign: ulpErr cannot see it.
        if (powSpecial(x, y)) |s| if (!std.math.isNan(s) and std.math.signbit(s) != std.math.signbit(got)) {
            std.debug.print("ulp: pow({e}, {e}) = {e}, C99 F.10.4.4 says {e}\n", .{ x, y, got, s });
            return error.UlpBound;
        };
    };
    const ok = w.within("pow", bound.pow);
    try std.testing.expect(wv.within("powV", bound.pow) and ok);
}

test "L3 ulp: gm.expm1, sinh, cosh and tanh" {
    var ok = judge1(expm1, expm1Q, &expm1_hard, genExpm1, 6).within("expm1", bound.expm1);
    ok = judge1(sinh, sinhQ, &hyp_hard, genHyp, 7).within("sinh", bound.sinh) and ok;
    ok = judge1(cosh, coshQ, &hyp_hard, genHyp, 8).within("cosh", bound.cosh) and ok;
    ok = judge1(tanh, tanhQ, &hyp_hard, genTanh, 9).within("tanh", bound.tanh) and ok;
    try std.testing.expect(ok);
}

test "L3 ulp: gm.sin, cos and atan" {
    var ok = judge1(sin, sinQ, &trig_hard, genTrig, 10).within("sin", bound.sin);
    ok = judge1(cos, cosQ, &trig_hard, genTrig, 11).within("cos", bound.cos) and ok;
    ok = judge1(atan, atanQ, &atan_hard, genAtan, 12).within("atan", bound.atan) and ok;
    try std.testing.expect(ok);
}

test "L3 ulp: the odd functions keep the sign of zero" {
    inline for (.{ sin, tanh, sinh, expm1, atan }) |f| {
        try std.testing.expect(std.math.signbit(f(-0.0)));
        try std.testing.expect(!std.math.signbit(f(0.0)));
    }
}
