// §4.5.15 SPICE voltage-limiting kernels — EMITTED VERBATIM into every device
// that honours a `$limit` call (`kernel_text.limit_txt` is `@embedFile` of this
// file) and `@import`ed by codegen.zig's tests, for the same reason
// `filter_kernels.zig` is: the numerics the tests check are the numerics the
// device runs. Until this file existed they were a string literal in
// `cg_limit.zig` and nothing could call them.
//
// Transcribed from ngspice `src/spicelib/devices/devsup.c` — which is what the
// `"pnjlim"`/`"fetlim"`/`"limvds"` identifiers in a `.va` name. §4.5.15 leaves
// the algorithm implementation-defined, so the LRM fixes nothing here except
// §9.17.3's "when the simulator has converged, the return value of the $limit()
// function is the value of the access function reference" — i.e. a converged
// bias must come back UNCHANGED. That transparency is the property the
// `annex_e_spice/limit_*.va` fixtures assert and the one `tests/unit.zig` pins.
//
// BRANCHLESS (simd-first T7): the `*Clamp` bodies compute every candidate
// unconditionally and combine with selects, so the predictor sees constant
// behaviour whether or not the clamp fires — the ngspice control flow survives
// only in the `*Oracle` transcriptions in `tests/unit.zig`, kept as the
// differential-test reference (T8 step 5).
//
// EACH KERNEL IS A HOT/COLD PAIR, and the split is the shape, not a tweak. The
// public name is an `inline fn` holding nothing but the §9.17.3 TRANSPARENT
// test — the overwhelming majority of iterates near convergence — and the
// branchless ladder lives in a separate `*Clamp` reached through
// `@call(.never_inline, ...)`. Both halves matter:
//
//   * The transparent test INLINES, so the caller's hot path is a handful of
//     compares and a return, which is what ngspice's `DEVfetlim` compiles to
//     at its call site. Before the split `zFetlim` was one function big enough
//     that LLVM refused to inline it at all: `-femit-asm` showed a real `call`
//     with six caller-saved spills around it, 20 Ir per MOSFET per Newton
//     iterate for a fast path worth ten.
//   * The ladder stays OUT of line, so its `sel` chain and (for `zPnjlim`) its
//     three `@log` LIBCALLS never enter the caller's register pressure. Before
//     the split `zPnjlim` and `zLimvds` inlined *whole*, ladder included.
//
// Each guard is a SUFFICIENT condition for "the oracle assigns nothing", so the
// early return IS the select chain's own `vnew0` arm, bit for bit, and a guard
// that does not fire falls into an unchanged branchless body. A GPU has no
// predictor to win and no libcall to save, so `k_dev` routes straight to the
// `*Clamp` body, which then inlines into its single caller as before.
//
// MEASURED, mos1 at inverter-chain bias, Ir per instance per Newton iterate on
// a standalone rig (the whole pass, gather included): 174 before, 148 after the
// split, 143 with cg_limit's hoisted sign, 119 with the host's masked walk.
// ngspice's own ladder on the same rig and the same data: 71. Every step is
// bit-identical — same `chk` sum over the limited plane.
//
// Two rules make the branchless bodies exact:
//
//   * CLAMP BEFORE LOG. A branchless kernel evaluates its dead paths, so every
//     `@log` argument is clamped with `@max(x, 0.0)` FIRST — never log a
//     negative on a dead path and lean on the select to mask the NaN
//     (proof.zig's guard-fact license demands the clamp; a masked NaN is one
//     maxnum-semantics change away from escaping). The floor is 0.0, not some
//     epsilon, because it must be invisible on every LIVE path: the guards
//     bound live arguments to ≥ 0 but division/subtraction rounding can land
//     them EXACTLY on 0 (`(vnew-vold)/vt` rounding down to 2.0 makes
//     `arg-2.0 == 0`), where the oracle takes `@log(0) = -inf` — and so does
//     the clamped kernel, bit-identically. An epsilon floor would differ there.
//     The clamp is only sound on the physical domain `vt > 0`, `vcrit > 0`
//     (vcrit = vt·ln(vt/(√2·Is)) is positive whenever vt > √2·Is): outside it
//     the ORACLE itself logs a negative and returns NaN, which no clamp can
//     reproduce. cg_limit only ever passes physical vt/vcrit.
//
//   * SAME FORMULA, SAME ORDER. Each candidate is the oracle's expression
//     verbatim, and equal-value ties resolve through the identical builtin
//     (`@max`/`@min`/select), so damped results are bit-identical too, and a
//     path the oracle leaves untouched returns `vnew0` BIT-IDENTICALLY —
//     `cg_limit.emitClamp` reads "the clamp fired" off the returned value
//     differing from the one passed in, which is only a truthful convergence
//     flag under that exact transparency.
//
// Nothing here allocates or reads the enclosing device: each is a pure f64
// function of the new iterate, the previous one, and the algorithm's own
// constants.

/// Natural log: the devices' own (`contract.gm.log`, one implementation on
/// host, NVPTX and AMDGCN; log(0) = -inf, so the clamp-at-0 behaviour is
/// unchanged). This file is both spliced into generated devices and
/// `@import`ed by the `kernels` module, which imports `contract` for it.
const k_dev = switch (@import("builtin").target.cpu.arch) {
    .nvptx64, .amdgcn => true,
    else => false,
};
inline fn klog(x: f64) f64 {
    return @import("contract").gm.log(x);
}

/// Two-way pick, BIT-SELECT spelling: mask is all-ones/all-zeros from the
/// bool, result is exactly `a`'s or `b`'s bit pattern. NOT `if (c) a else b`,
/// and not a bare `(m & a) | (~m & b)` either — LLVM folds both back into a
/// `select` and then branch-lowers every keep-vs-modify one (verified:
/// `-femit-asm` showed `ja`/`jbe` inside the kernels guarding the arm's
/// computation) because it likes sinking a one-use arm behind a jump. The
/// empty asm makes each arm's bits opaque, so there is no instruction to sink
/// and the select stays data-flow. `"r"` is a GPR on every target Zig names.
inline fn sel(c: bool, a: f64, b: f64) f64 {
    var av: u64 = @bitCast(a);
    var bv: u64 = @bitCast(b);
    // Host-only fence: NVPTX spells a 64-bit GPR "l", not "r", and a GPU has
    // no branch predictor to defend — predicated select IS the good lowering
    // there, so the device build just skips the barrier.
    if (comptime !k_dev) {
        asm volatile (""
            : [av] "+r" (av),
              [bv] "+r" (bv),
        );
    }
    const m = @as(u64, 0) -% @intFromBool(c);
    return @bitCast((m & av) | (~m & bv));
}

/// SPICE3 `DEVpnjlim`: damp a p-n junction's exponential. `vt` is the
/// junction's thermal voltage and `vcrit` the bias where its exponential
/// starts to outrun Newton, i.e. `vt*ln(vt/(sqrt(2)*is))`. Branchless; see
/// header. Requires the physical domain `vt > 0`, `vcrit > 0`.
pub inline fn zPnjlim(vnew0: f64, vold: f64, vt: f64, vcrit: f64) f64 {
    if (comptime !k_dev) {
        if (!(vnew0 > vcrit and @abs(vnew0 - vold) > vt + vt)) {
            // The oracle's `else if` arm, BRANCHY and inline. Two `sel`s here
            // cost four GPR round trips through the asm barrier for a pick a
            // predictor gets right, and the arm is already behind a branch.
            // Bit-identical: `vnew0 >= 0.0` is exactly the select's `vnew0`
            // arm, and below zero this is `sel(vnew0 < floor, floor, vnew0)`
            // with the same two floor formulas in the same order.
            if (vnew0 >= 0.0) return vnew0;
            const fl = if (vold > 0.0) -vold - 1.0 else 2.0 * vold - 1.0;
            return if (vnew0 < fl) fl else vnew0;
        }
        return @call(.never_inline, zPnjlimClamp, .{ vnew0, vold, vt, vcrit });
    }
    return zPnjlimClamp(vnew0, vold, vt, vcrit);
}

/// The branchless ladder, ONE body for both targets. On the host it is only
/// reached when the damping arm is live, so it is cold and stays out of line;
/// on a GPU it is the whole kernel and inlines into its single caller.
fn zPnjlimClamp(vnew0: f64, vold: f64, vt: f64, vcrit: f64) f64 {
    const damp = vnew0 > vcrit and @abs(vnew0 - vold) > vt + vt;
    // The negative-excursion floor of the oracle's `else if` arm.
    const floor = sel(vold > 0.0, -vold - 1.0, 2.0 * vold - 1.0);
    const floored = sel(vnew0 < 0.0 and vnew0 < floor, floor, vnew0);
    const arg = (vnew0 - vold) / vt;
    // Damping candidates, all evaluated. Live guards: d_up needs arg ≥ 2 (so
    // arg-2 ≥ 0), d_dn needs arg ≤ -2 (so 2-arg ≥ 4), d_log needs
    // vnew0 > vcrit > 0 (so vnew0/vt ≥ 0 after rounding) — the 0.0 clamp only
    // ever rewrites DEAD arguments.
    const d_up = vold + vt * (2.0 + klog(@max(arg - 2.0, 0.0)));
    const d_dn = vold - vt * (2.0 + klog(@max(2.0 - arg, 0.0)));
    const d_log = vt * klog(@max(vnew0 / vt, 0.0));
    const damped = sel(vold > 0.0, sel(arg > 0.0, d_up, d_dn), d_log);
    return sel(damp, damped, floored);
}

/// SPICE3 `DEVfetlim`: keep a gate bias from stepping across threshold in
/// one Newton iteration. `vto` is the threshold voltage. Branchless; no logs,
/// so no domain caveat — exact on all finite inputs.
pub inline fn zFetlim(vnew0: f64, vold: f64, vto: f64) f64 {
    // HOST ONLY, the transparent arm (see header). `vtsthi >= 2` and
    // `vtstlo = vtsthi/2 + 2 >= 3` for every (vold, vto), so a step of at most
    // 2 V cannot trip EITHER step bound and only the four absolute bounds are
    // left — one per region, and each is a single compare. Everything below is
    // therefore a sufficient condition for the oracle's no-assignment path,
    // which the select chain returns as `vnew0` bit for bit.
    //   vold >= vtox : floor at vto+2 (the `vnew >= vtox` sub-arm only clamps
    //                  by vtstlo, and vnew >= vtox > vto+2 there anyway)
    //   vto <= vold  : MAX at vto-0.5 going off, MIN at vto+4 staying on
    //   vold <  vto  : going off clamps by vtsthi alone; going on needs the
    //                  vto+0.5 ceiling to be clear
    // Checked against `zFetlimOracle` over 20 M draws on the SPICE-realistic
    // grid vto ∈ [-1,1], vold ∈ [-1,6], |delv| ≤ 3: 11.8 M transparent hits,
    // 0 disagreements, and `tests/unit.zig` re-checks it on
    // the log-uniform draws and every boundary tie.
    if (comptime !k_dev) {
        const d = vnew0 - vold;
        if (d >= -2.0 and d <= 2.0) {
            if (vold >= vto + 3.5) {
                if (vnew0 > vto + 2.0) return vnew0;
            } else if (vold >= vto) {
                if (vnew0 > vto - 0.5 and vnew0 < vto + 4.0) return vnew0;
            } else if (d <= 0.0 or vnew0 <= vto + 0.5) return vnew0;
        }
        return @call(.never_inline, zFetlimClamp, .{ vnew0, vold, vto });
    }
    return zFetlimClamp(vnew0, vold, vto);
}

/// The branchless ladder, ONE body for both targets — see `zPnjlimClamp`.
fn zFetlimClamp(vnew0: f64, vold: f64, vto: f64) f64 {
    const vtsthi = @abs(2.0 * (vold - vto)) + 2.0;
    const vtstlo = vtsthi * 0.5 + 2.0;
    const vtox = vto + 3.5;
    const delv = vnew0 - vold;
    const down = delv <= 0.0;
    // ngspice's MAX/MIN are `?:` ternaries, i.e. exactly `sel` — NOT Zig's
    // `@max`/`@min`, whose maxnum NaN-fixup select got branch-lowered here.
    // vold ≥ vtox: going off keeps a floor, staying on caps the step.
    const flr = vto + 2.0;
    const hi_dn = sel(vnew0 >= vtox, sel(-delv > vtstlo, vold - vtstlo, vnew0), sel(vnew0 > flr, vnew0, flr));
    const hi_up = sel(delv >= vtsthi, vold + vtsthi, vnew0);
    const r_hi = sel(down, hi_dn, hi_up);
    // vto ≤ vold < vtox: plain clamp about threshold.
    const lo_b = vto - 0.5;
    const hi_b = vto + 4.0;
    const r_mid = sel(down, sel(vnew0 > lo_b, vnew0, lo_b), sel(vnew0 < hi_b, vnew0, hi_b));
    const r_on = sel(vold >= vtox, r_hi, r_mid);
    // vold < vto (off): symmetric step bounds, ceiling at vto+0.5 going on.
    const off_dn = sel(-delv > vtsthi, vold - vtsthi, vnew0);
    const off_up = sel(vnew0 <= vto + 0.5, sel(delv > vtstlo, vold + vtstlo, vnew0), vto + 0.5);
    const r_off = sel(down, off_dn, off_up);
    return sel(vold >= vto, r_on, r_off);
}

/// SPICE3 `DEVlimvds`: bound a drain-source step. Takes no model data —
/// the numbers are the algorithm. Branchless; exact on all finite inputs.
pub inline fn zLimvds(vnew0: f64, vold: f64) f64 {
    // HOST ONLY, the transparent arm (see header). Below 3.5 V the oracle's
    // only bounds are the constants 4.0 and -0.5. At or above it the upper
    // bound is `3*vold + 2`, which exceeds `vold` for every `vold >= 3.5`, so
    // it covers the `vnew <= vold` arm too and the lower bound is the flat 2.0
    // (the `vnew >= 3.5` arm is untouched, and 3.5 > 2.0). 20 M draws against
    // `zLimvdsOracle` on vold ∈ [-2,8], |delv| ≤ 3: 15.2 M hits, 0 disagreements.
    if (comptime !k_dev) {
        if (vold < 3.5) {
            if (vnew0 >= -0.5 and vnew0 <= 4.0) return vnew0;
        } else if (vnew0 >= 2.0 and vnew0 <= 3.0 * vold + 2.0) return vnew0;
        return @call(.never_inline, zLimvdsClamp, .{ vnew0, vold });
    }
    return zLimvdsClamp(vnew0, vold);
}

/// The branchless ladder, ONE body for both targets — see `zPnjlimClamp`.
fn zLimvdsClamp(vnew0: f64, vold: f64) f64 {
    const r_hi = sel(vnew0 > vold, @min(vnew0, 3.0 * vold + 2.0), sel(vnew0 < 3.5, @max(vnew0, 2.0), vnew0));
    const r_lo = sel(vnew0 > vold, @min(vnew0, 4.0), @max(vnew0, -0.5));
    return sel(vold >= 3.5, r_hi, r_lo);
}

/// ngspice `B4SOIlimit` / hisim `limit_dx`: absolute per-iteration step
/// clamp, |vnew − vold| ≤ lim. No explicit non-finite guard (ngspice's
/// "YOU TURKEY" reset): Zig's `@min`/`@max` are maxnum-semantics, so a
/// NaN/±inf vnew collapses to the near step bound — bounded either way,
/// and this file cannot name `std` (embedded verbatim beside the device's own).
/// Trivially fixed-point-preserving.
pub fn zSteplim(vnew0: f64, vold: f64, lim: f64) f64 {
    return @max(vold - lim, @min(vold + lim, vnew0));
}
