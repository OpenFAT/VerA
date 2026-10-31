//! §4.5.11/§4.5.12 filters: a cascade's section coefficients, its input and
//! its accepted history in, the filter's output (with its exact derivative)
//! and the advanced history out. Device text (`text.filter`) for every
//! device that uses a `laplace_*` or `zi_*` operator. Nothing allocates or
//! reads the device: `NS` (sections) and `D` (degree) are structural
//! constants of the flattened call, every coefficient is a run-time read of
//! `Model`, and the histories are `Instance` slices the caller passes.
//! Cites: VAMS §4.5.11, §4.5.12; docs/specification/Vague_Decisions.md §6.
//!
//! A filter is a cascade `H = ∏ num[i]/den[i]` of polynomial ratios in `s`
//! (§4.5.11) or `z⁻¹` (§4.5.12), ascending coefficients. A proper §4.5.11
//! section runs as continuous-time states stepped by the trapezoidal rule
//! (`zSsForm`, `zSsStep`): the bilinear transform without the
//! ill-conditioned z-domain coefficients. A §4.5.12 section and an improper
//! §4.5.11 one run in direct form I on their own past inputs and outputs.
//! A static analysis seeds the state with the steady state, so the first
//! transient step starts consistent. Which coefficients are zero is read
//! twice, neither per sample: `zH0` (a pole at s = 0 has no DC value) and a
//! loop bound, `zDeg`, so a zero-padded coefficient vector runs at its own
//! low order rather than as a degree-D section with cancelling poles at
//! z = -1.
//!
//! Contents:
//! - `pub const zroot_tol: f64`
//! - `pub const ZSs = struct { off: usize, m: usize }`
//! - `pub fn zLaplace(comptime S: type, comptime NS: usize, comptime D: usize, uin: S, sec: [NS][2][D + 1]f64, dt: f64, uh: []const f64, yh: []const f64) S`
//! - `pub fn zLaplaceStep(comptime NS: usize, comptime D: usize, uin: f64, sec: [NS][2][D + 1]f64, dt: f64, uh: []f64, yh: []f64) void`
//! - `pub fn zLaplaceH0(comptime NS: usize, comptime D: usize, sec: [NS][2][D + 1]f64) [NS][2]f64`
//! - `pub fn zH0(comptime D: usize, sec: [2][D + 1]f64) [2]f64`
//! - `pub fn zSsForm(comptime D: usize, sec: [2][D + 1]f64) ?ZSs`
//! - `pub fn zSsStep(comptime D: usize, f: ZSs, sec: [2][D + 1]f64, x: []const f64, ua: f64, ub: f64, dt: f64, xn: ?[]f64) [2]f64`
//! - `pub fn zDeg(comptime D: usize, sec: [2][D + 1]f64) usize`
//! - `pub fn zBilin(comptime D: usize, p: [D + 1]f64, k: f64, d: usize) [D + 1]f64`
//! - `pub fn zSec(comptime S: type, comptime D: usize, u: S, b: [D + 1]f64, a: [D + 1]f64, uh: []const f64, yh: []const f64) S`
//! - `pub fn zSecR(comptime D: usize, u: f64, b: [D + 1]f64, a: [D + 1]f64, uh: []const f64, yh: []const f64) f64`
//! - `pub fn zPush(uh: []f64, yh: []f64, u: f64, y: f64) void`
//! - `pub fn zRootSecs(comptime M: usize, comptime z: bool, r: [2 * M]f64) [(M + 1) / 2][3]f64`
//! - `pub fn zZiEval(comptime S: type, comptime NS: usize, comptime D: usize, uin: S, sec: [NS][2][D + 1]f64, dt: f64, out: f64, t: f64, nk: f64, period: f64, uh: []const f64, yh: []const f64) S`
//! - `pub fn zZiEvalRamp(comptime S: type, comptime NS: usize, comptime D: usize, uin: S, sec: [NS][2][D + 1]f64, dt: f64, out: f64, from: f64, ts: f64, t: f64, nk: f64, period: f64, t0: f64, tau: f64, uh: []const f64, yh: []const f64) S`
//! - `pub fn zZiStep(comptime NS: usize, comptime D: usize, uin: f64, sec: [NS][2][D + 1]f64, uh: []f64, yh: []f64) f64`
//! - `pub fn zZiDue(t: f64, nk: f64, period: f64) u32`
//! - `pub fn zZiRamp(from: f64, to: f64, ts: f64, tau: f64, t: f64) f64`
//! - `pub fn zZiGain(comptime NS: usize, comptime D: usize, sec: [NS][2][D + 1]f64) f64`

const zqstd = @import("std");

// ---- device text ----

/// The relative distance within which two roots are each other's conjugate
/// (`zRootSecs`): a fitted model prints its pairs to about 1e-12, and 1e-9 is
/// still far below any two distinct roots a fit keeps apart.
pub const zroot_tol: f64 = 1e-9;

/// A proper §4.5.11 section's state-space shape (`zSsForm`): `off` common
/// powers of s cancelled from both sides, `m` the denominator degree left.
/// `off + m <= D`.
pub const ZSs = struct { off: usize, m: usize };

/// NaN as a bit pattern: `zRootSecs`' answer for an unpaired complex root.
const zq_nan: f64 = @bitCast(@as(u64, 0x7ff8000000000000));

/// Returns the §4.5.11 cascade's output in the residual. `uh`/`yh` are the
/// sections' histories, `D` slots per section. A static analysis
/// (`dt <= 0`) is the DC gain `H(0) = ∏ zH0(section)`, the transfer
/// function's exact value at s = 0 wherever it has one.
/// Asserts that each history holds `NS * D` slots.
pub fn zLaplace(
    comptime S: type,
    comptime NS: usize,
    comptime D: usize,
    uin: S,
    sec: [NS][2][D + 1]f64,
    dt: f64,
    uh: []const f64,
    yh: []const f64,
) S {
    zqstd.debug.assert(uh.len >= NS * D);
    zqstd.debug.assert(yh.len >= NS * D);
    var y = uin;
    for (0..NS) |i| {
        if (!(dt > 0.0)) {
            const h = zH0(D, sec[i]);
            y = y.scale(h[0] / h[1]);
            continue;
        }
        if (zSsForm(D, sec[i])) |f| {
            const xs = yh[i * D ..][0..D];
            const ua = if (D == 0 or f.m == 0) 0.0 else uh[i * D];
            const r = zSsStep(D, f, sec[i], xs, ua, y.val(), dt, null);
            // Linear in ub: the value from the states, the slope `r[1]`.
            y = y.scale(r[1]).addC(r[0] - r[1] * y.val());
            continue;
        }
        const k = 2.0 / dt;
        const d = zDeg(D, sec[i]);
        y = zSec(S, D, y, zBilin(D, sec[i][0], k, d), zBilin(D, sec[i][1], k, d), uh[i * D ..][0..D], yh[i * D ..][0..D]);
    }
    return y;
}

/// Advances the §4.5.11 cascade once the step is accepted. A static point
/// is a steady state, so it fills every history slot with its (input,
/// output); a single push would leave a degree-2 section's older slot at 0
/// and the first transient step answering a step the input never took.
/// Asserts that each history holds `NS * D` slots.
pub fn zLaplaceStep(
    comptime NS: usize,
    comptime D: usize,
    uin: f64,
    sec: [NS][2][D + 1]f64,
    dt: f64,
    uh: []f64,
    yh: []f64,
) void {
    zqstd.debug.assert(uh.len >= NS * D);
    zqstd.debug.assert(yh.len >= NS * D);
    var u = uin;
    for (0..NS) |i| {
        const us = uh[i * D ..][0..D];
        const ys = yh[i * D ..][0..D];
        const ss = zSsForm(D, sec[i]);
        if (!(dt > 0.0)) {
            const h = zH0(D, sec[i]);
            const y = u * h[0] / h[1];
            @memset(us, u);
            if (ss) |f| zqSsRest(D, f, sec[i], u, ys) else @memset(ys, y);
            u = y;
            continue;
        }
        if (ss) |f| {
            // `us[0]` is the accepted input, `ys[0..m]` the states.
            const ua = if (D == 0 or f.m == 0) 0.0 else us[0];
            const y = zSsStep(D, f, sec[i], ys, ua, u, dt, ys)[0];
            if (D != 0 and f.m != 0) us[0] = u;
            u = y;
            continue;
        }
        const k = 2.0 / dt;
        const d = zDeg(D, sec[i]);
        const y = zSecR(D, u, zBilin(D, sec[i][0], k, d), zBilin(D, sec[i][1], k, d), us, ys);
        zPush(us, ys, u, y);
        u = y;
    }
}

/// Returns `zH0` of every section, for `zAcLaplace`'s operating-point value.
pub fn zLaplaceH0(comptime NS: usize, comptime D: usize, sec: [NS][2][D + 1]f64) [NS][2]f64 {
    var h: [NS][2]f64 = undefined;
    for (&h, sec) |*hi, si| hi.* = zH0(D, si);
    return h;
}

/// Returns a §4.5.11 section's gain at s = 0 as the pair (n, d) a static
/// point scales by, in the order `n / d`. With `den[0] != 0` that is
/// `num[0]/den[0]`. Otherwise the denominator's lowest power `sⁿ` decides:
/// a numerator with a lower nonzero power leaves a pole at s = 0, answered
/// 0 (VerA's choice, as for §4.5.4's `idt` with no loop: the integrator
/// starts at 0; Vague_Decisions.md §6), and one without cancels `sⁿ`
/// (`s/(s + s²)` is 1). An all-zero denominator divides by zero, as a zero
/// resistance does.
pub fn zH0(comptime D: usize, sec: [2][D + 1]f64) [2]f64 {
    if (sec[1][0] != 0.0) return .{ sec[0][0], sec[1][0] };
    var n: usize = 1;
    while (n <= D and sec[1][n] == 0.0) n += 1;
    if (n > D) return .{ sec[0][0], 0.0 };
    zqstd.debug.assert(sec[1][n] != 0.0);
    for (0..n) |j| if (sec[0][j] != 0.0) return .{ 0.0, 1.0 }; // the pole
    return .{ sec[0][n], sec[1][n] };
}

/// Returns the state-space form of a proper §4.5.11 section, or null for
/// one the form cannot hold (an all-zero denominator, or an improper
/// section: a numerator of higher degree than the denominator), which runs
/// in direct form I on its bilinear coefficients instead. Direct form loses
/// the DC gain when a pole is slow against the step: with k = 2/dt, Σ a_z of
/// a degree-d section is O((ω·dt)^d) of its terms, so Σb/Σa is roundoff (a
/// 3 kHz pole at dt = 0.1 ns settled 0.6% low). The state-space step is the
/// same trapezoidal rule, written as an increment of continuous-time states,
/// and an input held at its value leaves A·x + B·u = 0 where it is, so the
/// steady output is N(0)/D(0) to rounding.
pub fn zSsForm(comptime D: usize, sec: [2][D + 1]f64) ?ZSs {
    var off: usize = 0;
    while (off <= D and sec[0][off] == 0.0 and sec[1][off] == 0.0) off += 1;
    var m: ?usize = null;
    var n: usize = 0;
    for (0..D + 1) |j| {
        if (sec[1][j] != 0.0) m = j;
        if (sec[0][j] != 0.0) n = j;
    }
    const top = m orelse return null;
    if (n > top) return null;
    // The denominator's top power is nonzero, so it is not cancelled.
    zqstd.debug.assert(off <= top);
    zqstd.debug.assert(top <= D);
    return .{ .off = off, .m = top - off };
}

/// Returns one trapezoidal step of `sec`'s controllable canonical form (`f`,
/// denominator monic): x_i' = x_{i+1}, x_{m-1}' = u - Σ α_i x_i,
/// y = Σ γ_i x_i + β_m u, with α_i = a_i/a_m, β_i = n_i/a_m and
/// γ_i = β_i - β_m α_i (indices past `off`). From (x, ua) to ub over `dt`:
/// (I - cA) Δ = c(2(A x + B ua) + B (ub - ua)), c = dt/2, solved by back
/// substitution along the companion chain in O(m). Writes x + Δ into `xn`
/// when given; returns the new output and its gain ∂y/∂ub, the derivative
/// the solver sees. `xn` may be `x` itself.
/// Asserts that `f` fits `D` and `x` (and `xn`) hold `f.m` states.
pub fn zSsStep(comptime D: usize, f: ZSs, sec: [2][D + 1]f64, x: []const f64, ua: f64, ub: f64, dt: f64, xn: ?[]f64) [2]f64 {
    zqstd.debug.assert(f.off + f.m <= D);
    zqstd.debug.assert(x.len >= f.m);
    if (xn) |o| zqstd.debug.assert(o.len >= f.m);
    const m = f.m;
    const am = sec[1][f.off + m];
    const bm = sec[0][f.off + m] / am;
    if (D == 0 or m == 0) return .{ bm * ub, bm };
    const c = 0.5 * dt;
    // Back substitution: Δ_i = P_i + Q_i Δ_{m-1}, P_{m-1} = 0, Q_{m-1} = 1.
    var p: [D]f64 = undefined;
    var qz: [D]f64 = undefined;
    p[m - 1] = 0.0;
    qz[m - 1] = 1.0;
    var i = m - 1;
    while (i > 0) {
        i -= 1;
        p[i] = 2.0 * c * x[i + 1] + c * p[i + 1];
        qz[i] = c * qz[i + 1];
    }
    var fm = ua;
    var sp: f64 = 0.0;
    var sq: f64 = 0.0;
    for (0..m) |j| {
        const al = sec[1][f.off + j] / am;
        fm -= al * x[j];
        sp += al * p[j];
        sq += al * qz[j];
    }
    const den = 1.0 + c * sq;
    const dl = (c * (2.0 * fm + (ub - ua)) - c * sp) / den;
    var y = bm * ub;
    var g: f64 = 0.0;
    for (0..m) |j| {
        const ga = sec[0][f.off + j] / am - bm * (sec[1][f.off + j] / am);
        const xj = x[j] + (p[j] + qz[j] * dl);
        if (xn) |o| o[j] = xj;
        y += ga * xj;
        g += ga * qz[j];
    }
    return .{ y, bm + g * c / den };
}

/// Returns a section's effective degree: the highest power with a nonzero
/// coefficient on either side, so numerator and denominator are cleared by
/// the same `(1+z⁻¹)ᵈ` and stay a matched pair. 0 for a bare gain.
pub fn zDeg(comptime D: usize, sec: [2][D + 1]f64) usize {
    var d: usize = 0;
    for (1..D + 1) |j| d = if (sec[0][j] != 0.0 or sec[1][j] != 0.0) j else d;
    zqstd.debug.assert(d <= D);
    return d;
}

/// Returns the trapezoidal (bilinear) transform of `P(s) = Σ pᵢsⁱ` as
/// `Σ qⱼz⁻ʲ`: `s = k(1−z⁻¹)/(1+z⁻¹)` substituted and the denominator
/// cleared by `(1+z⁻¹)ᵈ`, `k = 2/dt`. `d` is the section's `zDeg`: `p[d+1..]`
/// must be zero, and `q[d+1..]` comes back zero. At `d == D` the operations
/// are the full-degree ones, in the same order. Asserts that `d <= D`.
pub fn zBilin(comptime D: usize, p: [D + 1]f64, k: f64, d: usize) [D + 1]f64 {
    zqstd.debug.assert(d <= D);
    var qz: [D + 1]f64 = @splat(0.0);
    var ki: f64 = 1.0; // kⁱ
    for (0..d + 1) |i| {
        var t: [D + 1]f64 = @splat(0.0);
        t[0] = p[i] * ki;
        var deg: usize = 0;
        for (0..i) |_| { // × (1 − z⁻¹)
            var j = deg + 1;
            while (j > 0) : (j -= 1) t[j] -= t[j - 1];
            deg += 1;
        }
        for (0..d - i) |_| { // × (1 + z⁻¹)
            var j = deg + 1;
            while (j > 0) : (j -= 1) t[j] += t[j - 1];
            deg += 1;
        }
        zqstd.debug.assert(deg == d);
        for (0..D + 1) |j| qz[j] += t[j];
        ki *= k;
    }
    return qz;
}

/// Returns one direct-form-I section on discrete coefficients, in the
/// solver's scalar interface: linear in `u` with gain `b[0]/a[0]`, so the
/// derivative the solver sees is exact. Asserts that each history holds `D`
/// slots.
pub fn zSec(comptime S: type, comptime D: usize, u: S, b: [D + 1]f64, a: [D + 1]f64, uh: []const f64, yh: []const f64) S {
    zqstd.debug.assert(uh.len >= D);
    zqstd.debug.assert(yh.len >= D);
    var acc: f64 = 0.0;
    for (1..D + 1) |j| acc += b[j] * uh[j - 1] - a[j] * yh[j - 1];
    return u.scale(b[0]).addC(acc).scale(1.0 / a[0]);
}

/// Returns `zSec` on the accepted solution, where no derivative is wanted.
/// Asserts that each history holds `D` slots.
pub fn zSecR(comptime D: usize, u: f64, b: [D + 1]f64, a: [D + 1]f64, uh: []const f64, yh: []const f64) f64 {
    zqstd.debug.assert(uh.len >= D);
    zqstd.debug.assert(yh.len >= D);
    var acc = b[0] * u;
    for (1..D + 1) |j| acc += b[j] * uh[j - 1] - a[j] * yh[j - 1];
    return acc / a[0];
}

/// Pushes one accepted (input, output) pair, newest first; an empty history
/// is a no-op. Asserts that the histories have one length.
pub fn zPush(uh: []f64, yh: []f64, u: f64, y: f64) void {
    zqstd.debug.assert(uh.len == yh.len);
    if (uh.len == 0) return;
    var j = uh.len;
    while (j > 1) : (j -= 1) {
        uh[j - 1] = uh[j - 2];
        yh[j - 1] = yh[j - 2];
    }
    uh[0] = u;
    yh[0] = y;
}

/// Returns a root vector the model card sets (§4.5.11/§4.5.12 parameter
/// arrays, `M` roots as (re, im) pairs) as `(M + 1) / 2` real sections of
/// degree <= 2, ascending, the polynomial 1 where unused; `z` picks
/// §4.5.12's z⁻¹ factors over §4.5.11's s ones. Read on every evaluation, so
/// the section structure is fixed and only values move. A root whose
/// imaginary part is exactly 0 is real ("if a root is real, the imaginary
/// part shall be specified as zero"); real roots pair in vector order, a
/// leftover one into a degree-1 section, and a zero root is §4.5.11's `s` or
/// §4.5.12's z⁻¹. A complex a + jb takes the first unused root within
/// `zroot_tol`·|a + jb| of a - jb. A complex root with no partner breaks
/// "its conjugate shall also be present": every coefficient is NaN, so the
/// filter's output is NaN rather than another filter's.
pub fn zRootSecs(comptime M: usize, comptime z: bool, r: [2 * M]f64) [(M + 1) / 2][3]f64 {
    var out: [(M + 1) / 2][3]f64 = @splat(.{ 1.0, 0.0, 0.0 });
    var used: [M]bool = @splat(false);
    var k: usize = 0;
    var pend: ?[2]f64 = null;
    for (0..M) |i| {
        if (used[i]) continue;
        used[i] = true;
        const a = r[2 * i];
        const b = r[2 * i + 1];
        if (b == 0.0) {
            // §4.5.11 (1 − s/ρ), §4.5.12 (1 − z⁻¹ρ); ρ = 0 is `s` / z⁻¹.
            const f: [2]f64 = if (a == 0.0) .{ 0.0, 1.0 } else if (z) .{ 1.0, -a } else .{ 1.0, -1.0 / a };
            if (pend) |p| {
                out[k] = .{ p[0] * f[0], p[0] * f[1] + p[1] * f[0], p[1] * f[1] };
                k += 1;
                pend = null;
            } else pend = f;
            continue;
        }
        const tol = zroot_tol * @sqrt(a * a + b * b);
        const j = for (0..M) |c| {
            if (!used[c] and @abs(r[2 * c] - a) <= tol and @abs(r[2 * c + 1] + b) <= tol) break c;
        } else return @splat(@splat(zq_nan));
        used[j] = true;
        // (1 − s/ρ)(1 − s/ρ*) and (1 − z⁻¹ρ)(1 − z⁻¹ρ*) on this root's a, b.
        const mag = a * a + b * b;
        out[k] = if (z) .{ 1.0, -2.0 * a, mag } else .{ 1.0, -2.0 * a / mag, 1.0 / mag };
        k += 1;
    }
    // Each section consumed two roots, the pending one at most one more.
    zqstd.debug.assert(2 * k + @intFromBool(pend != null) <= M);
    if (pend) |p| out[k] = .{ p[0], p[1], 0.0 };
    return out;
}

/// Returns the §4.5.12 Z-filter as the residual sees it, the counterpart of
/// `zZiStep`'s accepted-step side. A static analysis (`dt <= 0`) has no
/// history and no clock: a constant input makes every sample equal, so the
/// filter is its DC gain H(1) = ∏ Σ num / Σ den applied to the input, which
/// gives the operating point its Jacobian too. At a sample instant the
/// output is the output of that sample ("a filter with unity transfer
/// function acts like a simple sample-and-hold which samples every T seconds
/// and exhibits no delay"), so the recurrence runs here on a stack copy of
/// the history, replaying samples a wide step jumped; `updateState` re-runs
/// the identical `zZiStep` on the accepted solution, so the two cannot
/// disagree. Between samples the output is the held `out`, constant.
/// Asserts that each history holds `NS * D` slots.
pub fn zZiEval(
    comptime S: type,
    comptime NS: usize,
    comptime D: usize,
    uin: S,
    sec: [NS][2][D + 1]f64,
    dt: f64,
    out: f64,
    t: f64,
    nk: f64,
    period: f64,
    uh: []const f64,
    yh: []const f64,
) S {
    zqstd.debug.assert(uh.len == NS * D);
    zqstd.debug.assert(yh.len == NS * D);
    if (!(dt > 0.0)) {
        var y = uin;
        for (0..NS) |i| {
            var num: f64 = 0.0;
            var den: f64 = 0.0;
            for (sec[i][0]) |c| num += c;
            for (sec[i][1]) |c| den += c;
            y = y.scale(num / den);
        }
        return y;
    }
    // The same count `updateState`'s sampler takes, so a timepoint is a
    // sample instant for both halves of the operator or for neither.
    var k = zZiDue(t, nk, period);
    if (k == 0) return S.con(out);
    var ub: [NS * D]f64 = undefined;
    var yb: [NS * D]f64 = undefined;
    @memcpy(&ub, uh);
    @memcpy(&yb, yh);
    while (k > 1) : (k -= 1) _ = zZiStep(NS, D, uin.val(), sec, &ub, &yb);
    // The last sample is the one the solver differentiates through: each
    // section is linear in its input with gain b[0]/a[0] and reads its own
    // history un-pushed, exactly as `zZiStep` does.
    var y = uin;
    for (0..NS) |i| y = zSec(S, D, y, sec[i][0], sec[i][1], ub[i * D ..][0..D], yb[i * D ..][0..D]);
    return y;
}

/// Returns a §4.5.12 Z-filter written with τ or t0: `zZiEval` on the grid
/// t0 + k·T ("t0 specifies the time of the first transition"), its output
/// reached by a τ-long linear transition (`zZiRamp`) from the value the
/// previous transition had reached when the sample was due. Between samples
/// the output carries no derivative; during a transition the sample's share
/// `w` of it does, 0 at the sample instant itself.
pub fn zZiEvalRamp(
    comptime S: type,
    comptime NS: usize,
    comptime D: usize,
    uin: S,
    sec: [NS][2][D + 1]f64,
    dt: f64,
    out: f64,
    from: f64,
    ts: f64,
    t: f64,
    nk: f64,
    period: f64,
    t0: f64,
    tau: f64,
    uh: []const f64,
    yh: []const f64,
) S {
    if (!(dt > 0.0)) return zZiEval(S, NS, D, uin, sec, dt, out, t - t0, nk, period, uh, yh);
    const k = zZiDue(t - t0, nk, period);
    if (k == 0) return S.con(zZiRamp(from, out, ts, tau, t));
    const y = zZiEval(S, NS, D, uin, sec, dt, out, t - t0, nk, period, uh, yh);
    const ts_new = t0 + (nk + @as(f64, @floatFromInt(k)) - 1.0) * period;
    const f = zZiRamp(from, out, ts, tau, ts_new);
    const w: f64 = if (tau > 0.0) @min(1.0, @max(0.0, (t - ts_new) / tau)) else 1.0;
    zqstd.debug.assert(w >= 0.0);
    zqstd.debug.assert(w <= 1.0);
    return y.scale(w).addC(f * (1.0 - w));
}

/// Takes one §4.5.12 sample of the Z-filter and returns the new held output.
/// The sections are already in `z⁻¹`, so only the filter's own clock
/// advances. Asserts that each history holds `NS * D` slots.
pub fn zZiStep(
    comptime NS: usize,
    comptime D: usize,
    uin: f64,
    sec: [NS][2][D + 1]f64,
    uh: []f64,
    yh: []f64,
) f64 {
    zqstd.debug.assert(uh.len >= NS * D);
    zqstd.debug.assert(yh.len >= NS * D);
    var u = uin;
    for (0..NS) |i| {
        const us = uh[i * D ..][0..D];
        const ys = yh[i * D ..][0..D];
        const y = zSecR(D, u, sec[i][0], sec[i][1], us, ys);
        zPush(us, ys, u, y);
        u = y;
    }
    return u;
}

/// Returns how many §4.5.12 samples a filter of period `period` owes at time
/// `t` with `nk` already taken: "T specifies the sampling period of the
/// filter", so the instants are k·T and the k-th is owed once t reaches it.
/// At most 4096: a step that jumped more instants has aliased the filter
/// past what replaying the held input recovers, and the cap only bounds the
/// replay loop.
// ponytail: the 1e-9 is a relative tolerance on the sample instant, and it
// is load-bearing: the residual and the accepted-step sampler reach k·T by
// two float routes, and a filter whose halves disagree about which point is
// an instant drops that sample for the rest of the run. 1e-9 of a period is
// seven orders below any host step and seven above f64 noise here. The
// upgrade is a host-supplied time tolerance, as §4.5.8's `time_tol` is.
pub fn zZiDue(t: f64, nk: f64, period: f64) u32 {
    if (!(period > 0.0)) return 0;
    const n = @floor(t / period + 1e-9) + 1.0 - nk;
    if (!(n >= 1.0)) return 0;
    const k: u32 = if (n > 4096.0) 4096 else @intFromFloat(n);
    zqstd.debug.assert(k >= 1);
    zqstd.debug.assert(k <= 4096);
    return k;
}

/// Returns the output `t` seconds into a §4.5.12 linear transition from
/// `from` to `to` that began at `ts` ("τ specifies the transition time").
/// τ = 0 is "abruptly discontinuous": the held `to` at once.
pub fn zZiRamp(from: f64, to: f64, ts: f64, tau: f64, t: f64) f64 {
    if (!(tau > 0.0) or !(t < ts + tau)) return to;
    if (!(t > ts)) return from;
    return from + (to - from) * ((t - ts) / tau);
}

/// Returns §4.5.12's DC gain H(1) = ∏ Σ_k num[i][k] / Σ_k den[i][k],
/// `zZiEval`'s static answer as one number.
pub fn zZiGain(comptime NS: usize, comptime D: usize, sec: [NS][2][D + 1]f64) f64 {
    var g: f64 = 1.0;
    for (0..NS) |i| {
        var num: f64 = 0.0;
        var den: f64 = 0.0;
        for (sec[i][0]) |c| num += c;
        for (sec[i][1]) |c| den += c;
        g *= num / den;
    }
    return g;
}

// ---- private ----

/// Sets `x` to the steady state of `zSsStep`'s form at a constant input `u`:
/// A x + B u = 0 is x_0 = u/α_0 and the rest 0. A pole left at s = 0
/// (α_0 = 0) has none, and its integrator starts at 0, as `zH0` says.
fn zqSsRest(comptime D: usize, f: ZSs, sec: [2][D + 1]f64, u: f64, x: []f64) void {
    zqstd.debug.assert(f.off + f.m <= D);
    zqstd.debug.assert(x.len >= f.m);
    @memset(x[0..f.m], 0.0);
    if (D == 0 or f.m == 0) return;
    const a0 = sec[1][f.off];
    if (a0 != 0.0) x[0] = u * sec[1][f.off + f.m] / a0;
}
