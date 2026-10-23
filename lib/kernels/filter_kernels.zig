// §4.5.11 / §4.5.12 filter kernels — EMITTED VERBATIM into every device that
// uses a `laplace_*` or `zi_*` operator (`kernel_text.filt_txt` is `@embedFile` of
// this file) and `@import`ed by codegen's tests and `tests/unit.zig`. One
// source, so the numerics the tests check are the numerics the device runs.
//
// A filter is a CASCADE of sections, `H = ∏ num[i]/den[i]`, each section a
// polynomial ratio in `s` (§4.5.11) or `z⁻¹` (§4.5.12) with ascending
// coefficients. A proper §4.5.11 section runs as continuous-time states
// stepped by the trapezoidal rule (`zSsForm`, `zSsStep`): the bilinear
// transform, without forming the ill-conditioned z-domain coefficients. A
// §4.5.12 section and an improper §4.5.11 one run in direct form I: the state
// is the section's own past inputs and outputs. Either way a static analysis
// seeds the state with the steady state, so the first transient step starts
// consistent.
//
// Nothing here allocates or depends on the enclosing device — `NS` (sections)
// and `D` (degree) are structural constants from the flattened call, while
// every COEFFICIENT is a runtime read of Model. Two things read which
// coefficients are zero, neither a per-sample branch: `zH0`, the static gain
// (a pole at s = 0 has no DC value), and a LOOP BOUND: `zDeg` reads each
// section's effective
// degree off its coefficients, and `zBilin` transforms at that degree, so a
// coefficient vector padded with zeros (`parameter real d[0:15]`, three
// nonzero) runs as the low-order section it is rather than as a degree-15
// one whose `(1+z⁻¹)ᴰ⁻ᵈ` factors put cancelling poles on z = −1.

/// A section's effective degree: the highest power with a nonzero
/// coefficient on EITHER side, so numerator and denominator are cleared by
/// the same `(1+z⁻¹)ᵈ` and stay a matched pair. 0 for a bare gain.
pub fn zDeg(comptime D: usize, sec: [2][D + 1]f64) usize {
    var d: usize = 0;
    for (1..D + 1) |j| d = if (sec[0][j] != 0.0 or sec[1][j] != 0.0) j else d;
    return d;
}

/// Trapezoidal (bilinear) transform of `P(s) = Σ pᵢsⁱ` into `Σ qⱼz⁻ʲ`:
/// substitute `s = k(1−z⁻¹)/(1+z⁻¹)` and clear the denominator by `(1+z⁻¹)ᵈ`,
/// so a section's numerator and denominator stay a matched pair. `k = 2/dt`.
/// `d <= D` is the section's `zDeg`: `p[d+1..]` must be zero, and `q[d+1..]`
/// comes back zero. At `d == D` the operations are the full-degree ones, in
/// the same order.
pub fn zBilin(comptime D: usize, p: [D + 1]f64, k: f64, d: usize) [D + 1]f64 {
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
        for (0..D + 1) |j| qz[j] += t[j];
        ki *= k;
    }
    return qz;
}

/// One direct-form-I section on already-DISCRETE coefficients, in the solver's
/// scalar interface. Linear in `u` with gain `b[0]/a[0]`, so the derivative the
/// solver sees is the exact one.
pub fn zSec(comptime S: type, comptime D: usize, u: S, b: [D + 1]f64, a: [D + 1]f64, uh: []const f64, yh: []const f64) S {
    var acc: f64 = 0.0;
    for (1..D + 1) |j| acc += b[j] * uh[j - 1] - a[j] * yh[j - 1];
    return u.scale(b[0]).addC(acc).scale(1.0 / a[0]);
}

/// The same section on the accepted solution, where no derivative is wanted.
pub fn zSecR(comptime D: usize, u: f64, b: [D + 1]f64, a: [D + 1]f64, uh: []const f64, yh: []const f64) f64 {
    var acc = b[0] * u;
    for (1..D + 1) |j| acc += b[j] * uh[j - 1] - a[j] * yh[j - 1];
    return acc / a[0];
}

/// Newest-first push of one accepted (input, output) pair.
pub fn zPush(uh: []f64, yh: []f64, u: f64, y: f64) void {
    if (uh.len == 0) return;
    var j = uh.len;
    while (j > 1) : (j -= 1) {
        uh[j - 1] = uh[j - 2];
        yh[j - 1] = yh[j - 2];
    }
    uh[0] = u;
    yh[0] = y;
}

/// §4.5.11 a section's gain at s = 0, as the pair (n, d) a static point
/// scales by in the order `n / d`. With `den[0] != 0` that is
/// `num[0]/den[0]`, the exact H(0). Otherwise the lowest power of s the
/// denominator has, `sⁿ`, decides: a numerator with a lower nonzero power
/// leaves a POLE at s = 0, and one without cancels `sⁿ` (`s/(s + s²)` is 1).
///
/// §4.5.11 does not say what a filter with a pole at s = 0 returns in a DC
/// analysis. VerA answers 0, the choice it makes for §4.5.4's `idt` with no
/// loop to force its argument: the integrator state starts at 0. A transient
/// then integrates from there (`zLaplaceStep`). docs/specification/Vague_Decisions.md §6.
pub fn zH0(comptime D: usize, sec: [2][D + 1]f64) [2]f64 {
    if (sec[1][0] != 0.0) return .{ sec[0][0], sec[1][0] };
    var n: usize = 1;
    while (n <= D and sec[1][n] == 0.0) n += 1;
    // An all-zero denominator divides by zero, as a zero resistance does.
    if (n > D) return .{ sec[0][0], 0.0 };
    for (0..n) |j| if (sec[0][j] != 0.0) return .{ 0.0, 1.0 }; // the pole
    return .{ sec[0][n], sec[1][n] };
}

/// §4.5.11/§4.5.12 a root vector whose parts the model card sets (parameter
/// arrays), as `(M + 1) / 2` real sections of degree ≤ 2, ascending, the
/// polynomial 1 where unused. `z` selects §4.5.12's z⁻¹ factors over
/// §4.5.11's s ones. Read in `__sec` on every evaluation, like any
/// coefficient, so the section STRUCTURE is fixed and only values move.
///
/// Pairing: a root whose imaginary part is exactly 0 is real ("If a root is
/// real, the imaginary part shall be specified as zero"); real roots combine
/// two at a time in vector order, a leftover one into a degree-1 section. A
/// zero root is §4.5.11's `s` / §4.5.12's z⁻¹ term. A complex a + jb takes
/// the first unused root within `zroot_tol`·|a + jb| of a − jb, and the pair
/// is one real quadratic. A complex root with no partner breaks "its
/// conjugate shall also be present": every coefficient is NaN, so the
/// filter's output is NaN rather than some other filter's.
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
        } else return @splat(@splat(zroot_nan));
        used[j] = true;
        // The constant path's quadratics, (1 − s/ρ)(1 − s/ρ*) and
        // (1 − z⁻¹ρ)(1 − z⁻¹ρ*), on this root's own a and b.
        const mag = a * a + b * b;
        out[k] = if (z) .{ 1.0, -2.0 * a, mag } else .{ 1.0, -2.0 * a / mag, 1.0 / mag };
        k += 1;
    }
    if (pend) |p| out[k] = .{ p[0], p[1], 0.0 };
    return out;
}

/// The relative distance within which two roots are each other's conjugate:
/// a fitted model prints its pairs to ~1e-12, and 1e-9 is still far below any
/// two distinct roots a fit keeps apart.
pub const zroot_tol = 1e-9;
const zroot_nan: f64 = @bitCast(@as(u64, 0x7ff8000000000000));

/// `zH0` of every section, for `zAcLaplace`'s operating-point value.
pub fn zLaplaceH0(comptime NS: usize, comptime D: usize, sec: [NS][2][D + 1]f64) [NS][2]f64 {
    var h: [NS][2]f64 = undefined;
    for (&h, sec) |*hi, si| hi.* = zH0(D, si);
    return h;
}

/// A proper §4.5.11 section's state-space shape (`zSsForm`): `off` common
/// powers of s cancelled from both sides, `m` the denominator degree left.
pub const ZSs = struct { off: usize, m: usize };

/// Returns the STATE-SPACE form of a proper §4.5.11 section. Null for a
/// section the form cannot hold (an all-zero denominator, or a numerator of
/// higher degree than the denominator: an improper section), which runs in
/// direct form I on its bilinear coefficients instead.
///
/// WHY. Direct form on bilinear coefficients loses the DC gain when a pole is
/// slow against the step: with k = 2/dt, Σ a_z of a degree-d section is
/// O((ω·dt)^d) of its terms, so the discrete fixed point Σb/Σa is roundoff
/// (a 3 kHz pole at dt = 0.1 ns in a fitted line settled 0.6% low). The
/// state-space step below is the SAME trapezoidal rule (bilinear transform)
/// written as an increment Δx of continuous-time states, and an input held
/// at its value leaves a state with A·x + B·u = 0 exactly where it is, so the
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
    return .{ .off = off, .m = top - off };
}

/// The controllable canonical form of `sec` with denominator `f.m`, monic:
/// x_i' = x_{i+1}, x_{m-1}' = u − Σ α_i x_i, y = Σ γ_i x_i + β_m u, where
/// α_i = a_i/a_m, β_i = n_i/a_m and γ_i = β_i − β_m α_i (indices past `off`).
/// One trapezoidal step from (x, ua) to ub over `dt`:
///   (I − cA) Δ = c(2(A x + B ua) + B (ub − ua)),  c = dt/2,
/// solved by back substitution along the companion chain in O(m). Writes
/// x + Δ into `xn` when given and returns the new output and its gain
/// ∂y/∂ub, the derivative the solver sees.
pub fn zSsStep(comptime D: usize, f: ZSs, sec: [2][D + 1]f64, x: []const f64, ua: f64, ub: f64, dt: f64, xn: ?[]f64) [2]f64 {
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

/// The steady state of `zSsStep`'s form at a constant input `u`: A x + B u = 0
/// is x_0 = u/α_0 and the rest 0. A pole left at s = 0 (α_0 = 0) has none,
/// and its integrator starts at 0, as `zH0` says.
fn zSsRest(comptime D: usize, f: ZSs, sec: [2][D + 1]f64, u: f64, x: []f64) void {
    @memset(x[0..f.m], 0.0);
    if (D == 0 or f.m == 0) return;
    const a0 = sec[1][f.off];
    if (a0 != 0.0) x[0] = u * sec[1][f.off + f.m] / a0;
}

/// §4.5.11 the cascade, in the residual. `dt <= 0` is a static analysis, where
/// the filter IS its DC gain `H(0) = ∏ zH0(section)` — the exact value of the
/// transfer function at s = 0 wherever it has one.
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

/// §4.5.11 advance the cascade once the step is accepted. A static point is
/// a steady state, so it fills EVERY history slot with its (input, output):
/// pushing it once left a degree-2 section's older slot at 0, and the first
/// transient step answered a step the input never took.
pub fn zLaplaceStep(
    comptime NS: usize,
    comptime D: usize,
    uin: f64,
    sec: [NS][2][D + 1]f64,
    dt: f64,
    uh: []f64,
    yh: []f64,
) void {
    var u = uin;
    for (0..NS) |i| {
        const us = uh[i * D ..][0..D];
        const ys = yh[i * D ..][0..D];
        const ss = zSsForm(D, sec[i]);
        if (!(dt > 0.0)) {
            const h = zH0(D, sec[i]);
            const y = u * h[0] / h[1];
            @memset(us, u);
            if (ss) |f| zSsRest(D, f, sec[i], u, ys) else @memset(ys, y);
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

/// §4.5.12 one SAMPLE of a Z-filter. The sections are already in `z⁻¹`, so
/// there is nothing to discretise — only the filter's own clock advances.
/// Returns the new held output.
pub fn zZiStep(
    comptime NS: usize,
    comptime D: usize,
    uin: f64,
    sec: [NS][2][D + 1]f64,
    uh: []f64,
    yh: []f64,
) f64 {
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

/// §4.5.12 how many samples a filter of period `period` owes at time `t` when
/// `nk` of them have already been taken. "T specifies the sampling period of
/// the filter", so the instants are k·T and the k-th is owed once t reaches it.
///
/// ponytail: the 1e-9 is a RELATIVE tolerance on the sample instant, and it is
/// load-bearing rather than defensive — the residual and the accepted-step
/// sampler reach k·T by two different float routes, and a filter whose two
/// halves disagree about which timepoint IS a sample instant drops that sample
/// for the rest of the run. 1e-9 of a period is some seven orders below any
/// timestep a host takes and seven above f64's own noise at these magnitudes.
/// The upgrade path, if a host ever needs it, is a host-supplied time
/// tolerance the way §4.5.8's `time_tol` is spelled.
pub fn zZiDue(t: f64, nk: f64, period: f64) u32 {
    if (!(period > 0.0)) return 0;
    const n = @floor(t / period + 1e-9) + 1.0 - nk;
    if (!(n >= 1.0)) return 0;
    // ponytail: a step that jumped 4096 sample instants has already aliased
    // the filter beyond what replaying the held input could recover; the
    // ceiling only keeps the replay loop bounded.
    return if (n > 4096.0) 4096 else @intFromFloat(n);
}

/// §4.5.12 "τ specifies the transition time": the output `t` seconds into a
/// linear transition from `from` to `to` that began at `ts`. τ = 0 is "abruptly
/// discontinuous", the held `to` at once.
pub fn zZiRamp(from: f64, to: f64, ts: f64, tau: f64, t: f64) f64 {
    if (!(tau > 0.0) or !(t < ts + tau)) return to;
    if (!(t > ts)) return from;
    return from + (to - from) * ((t - ts) / tau);
}

/// §4.5.12 the DC gain H(1) = ∏ Σ_k num[i][k] / Σ_k den[i][k], `zZiEval`'s
/// static answer as one number.
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

/// §4.5.12 a Z-filter written with τ or t0: `zZiEval` on the sample grid
/// t0 + k·T ("t0 specifies the time of the first transition"), its output
/// reached by a τ-long linear transition (`zZiRamp`) from the value the
/// previous transition had reached when the sample was due. Between samples
/// the output carries no derivative; during the transition a sample's share
/// `w` of it does, which is 0 at the sample instant itself.
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
    return y.scale(w).addC(f * (1.0 - w));
}

/// §4.5.12 the Z-filter as the RESIDUAL sees it, the counterpart of
/// `zZiStep`'s accepted-step side.
///
/// `dt <= 0` is a static analysis: there is no history and no clock, a constant
/// input makes every sample equal, so z = 1 and the filter IS its DC gain
/// H(1) = ∏ Σ_k num[i][k] / Σ_k den[i][k] — the exact value of the transfer
/// function at z = 1, applied to the input so the operating point gets the
/// right Jacobian too. This mirrors `zLaplace`'s H(0) branch.
///
/// THE SAMPLE INSTANT. §4.5.12: "a filter with unity transfer function acts
/// like a simple sample-and-hold which samples every T seconds and EXHIBITS NO
/// DELAY", and with τ = 0 "the output is abruptly discontinuous". So at
/// t = k·T the output is the output OF the k-th sample, not the (k−1)-th. This
/// used to answer `inst.__out`, which `updateState` writes AFTER the timepoint
/// has been evaluated — the whole filter ran one sample period late. The
/// recurrence is therefore evaluated HERE, on a COPY of the history, and
/// `updateState` re-runs the identical `zZiStep` on the accepted solution; the
/// two see the same input and the same sections, so they cannot disagree.
/// Between samples the output is the held constant and carries no derivative.
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
    // The SAME count `updateState`'s sampler takes, so a timepoint is a sample
    // instant for both halves of the operator or for neither.
    var k = zZiDue(t, nk, period);
    if (k == 0) return S.con(out);
    // Replaying the samples a wide step jumped over needs a mutable history,
    // and the residual may not move the accepted state — so it works on a
    // comptime-sized stack copy. Nothing here allocates.
    var ub: [NS * D]f64 = undefined;
    var yb: [NS * D]f64 = undefined;
    @memcpy(&ub, uh);
    @memcpy(&yb, yh);
    while (k > 1) : (k -= 1) _ = zZiStep(NS, D, uin.val(), sec, &ub, &yb);
    // The LAST sample is the one the solver differentiates through: each
    // section is linear in its input with gain b[0]/a[0], and reads its own
    // history un-pushed, exactly as `zZiStep` does.
    var y = uin;
    for (0..NS) |i| y = zSec(S, D, y, sec[i][0], sec[i][1], ub[i * D ..][0..D], yb[i * D ..][0..D]);
    return y;
}
