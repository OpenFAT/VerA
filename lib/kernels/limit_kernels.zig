//! §4.5.15 SPICE voltage limiting: a Newton iterate, the previous one and the
//! algorithm's constants in, the damped iterate out. Device text
//! (`text.limit`) for every device that honours a `$limit` call; pure f64
//! functions, no allocation, no device state.
//! Cites: VAMS §4.5.15, §9.17.3; ngspice `src/spicelib/devices/devsup.c`
//! (`DEVpnjlim`, `DEVfetlim`, `DEVlimvds`), `B4SOIlimit`, hisim `limit_dx`.
//!
//! §4.5.15 leaves the algorithm implementation-defined; the `"pnjlim"`,
//! `"fetlim"` and `"limvds"` a `.va` names are ngspice's. The LRM fixes one
//! property, §9.17.3's: "when the simulator has converged, the return value
//! of the $limit() function is the value of the access function reference",
//! so a converged bias comes back bit-identical. `cg_limit.emitClamp` reads
//! "the clamp fired" off the returned bits differing from the ones passed in.
//!
//! Each kernel is a hot/cold pair. The `pub` name holds only the transparent
//! test (`inline`, so the caller's hot path is a few compares and a return);
//! the branchless ladder is a separate `*Clamp`, kept out of line on a host
//! so its select chain and `@log` libcalls never enter the caller's register
//! pressure. A GPU has no predictor to win and no libcall to save, so there
//! the public name is the ladder. Measured (mos1 at inverter-chain bias, Ir
//! per instance per Newton iterate): 174 one-piece, 148 after the split, 119
//! with the host's masked walk; ngspice's own ladder 71; every step
//! bit-identical. The ngspice control flow survives only as the oracles in
//! `tests/unit.zig`, which hold these to it bit for bit.
//!
//! Probe: `zig build test-probe` holds `zFetlimClamp`, `zLimvdsClamp` and
//! `zPnjlimClamp` to 0 conditional jumps (`tests/codegen_probe.zig`'s
//! `expect:` lines, ReleaseFast, x86_64_v3, `tools/asm_probe.py`). Measured
//! on 0.18.0-dev.349: 66, 27 and 85 instructions (the last with its three
//! `log` calls), and each public name compiles to its compares and one tail
//! jump to its ladder: the `sel` barrier keeps the ladders branchless and
//! the Debug-only `zl_verify` check leaves nothing in a release build.
//!
//! Two rules make the branchless bodies exact. CLAMP BEFORE LOG: a dead path
//! is evaluated, so every `@log` argument is `@max(x, 0.0)` first, an
//! invisible floor on every live path (the guards bound live arguments to
//! >= 0, and rounding can land one exactly on 0, where the oracle also takes
//! log(0) = -inf). Sound on the physical domain `vt > 0`, `vcrit > 0`, the
//! only one `cg_limit` passes. SAME FORMULA, SAME ORDER: each candidate is the
//! oracle's expression verbatim and ties resolve through the same builtin.
//!
//! Contents:
//! - `pub inline fn zPnjlim(vnew0: f64, vold: f64, vt: f64, vcrit: f64) f64`
//! - `pub inline fn zFetlim(vnew0: f64, vold: f64, vto: f64) f64`
//! - `pub inline fn zLimvds(vnew0: f64, vold: f64) f64`
//! - `pub fn zSteplim(vnew0: f64, vold: f64, lim: f64) f64`

const zlstd = @import("std");

// ---- device text ----

/// A GPU target: no branch predictor to defend, so no hot/cold split.
const k_dev = switch (@import("builtin").target.cpu.arch) {
    .nvptx64, .amdgcn => true,
    else => false,
};

/// Debug builds check each transparent arm against its ladder: the arm is
/// only correct while it returns exactly what the ladder would. A comptime
/// gate, because the ladder's asm barrier would keep the check alive in a
/// release build.
const zl_verify = switch (@import("builtin").mode) {
    .debug => true,
    else => false,
};

/// SPICE3 `DEVpnjlim`: damps a p-n junction's exponential. `vt` is the
/// thermal voltage and `vcrit` the bias where the exponential starts to
/// outrun Newton, `vt*ln(vt/(sqrt(2)*is))`. Requires the physical domain
/// `vt > 0`, `vcrit > 0`; outside it the result is the ladder's, which is
/// not ngspice's.
pub inline fn zPnjlim(vnew0: f64, vold: f64, vt: f64, vcrit: f64) f64 {
    if (comptime k_dev) return zPnjlimClamp(vnew0, vold, vt, vcrit);
    if (!(vnew0 > vcrit and @abs(vnew0 - vold) > vt + vt)) {
        // The oracle's `else if` arm, branchy and inline: two `sel`s here
        // cost four GPR round trips through the barrier for a pick a
        // predictor gets right. `vnew0 >= 0.0` is exactly the select's
        // `vnew0` arm; below zero the same two floor formulas, same order.
        const r = if (vnew0 >= 0.0)
            vnew0
        else r: {
            const fl = if (vold > 0.0) -vold - 1.0 else 2.0 * vold - 1.0;
            break :r if (vnew0 < fl) fl else vnew0;
        };
        if (comptime zl_verify) zlstd.debug.assert(zlSame(r, zPnjlimClamp(vnew0, vold, vt, vcrit)));
        return r;
    }
    return @call(.never_inline, zPnjlimClamp, .{ vnew0, vold, vt, vcrit });
}

/// SPICE3 `DEVfetlim`: keeps a gate bias from stepping across threshold in
/// one Newton iteration. `vto` is the threshold voltage. Exact on all finite
/// inputs: no logs, no domain caveat.
pub inline fn zFetlim(vnew0: f64, vold: f64, vto: f64) f64 {
    if (comptime k_dev) return zFetlimClamp(vnew0, vold, vto);
    // The transparent arm. `vtsthi >= 2` and `vtstlo = vtsthi/2 + 2 >= 3`
    // for every (vold, vto), so a step of at most 2 V trips neither step
    // bound and only the absolute bound of its region is left:
    //   vold >= vtox: the floor at vto+2;
    //   vto <= vold: MAX at vto-0.5 going off, MIN at vto+4 staying on;
    //   vold < vto: going off clamps by vtsthi alone, going on needs the
    //   vto+0.5 ceiling clear.
    // Each is sufficient for the oracle's no-assignment path.
    const d = vnew0 - vold;
    if (d >= -2.0 and d <= 2.0) {
        const keep = if (vold >= vto + 3.5)
            vnew0 > vto + 2.0
        else if (vold >= vto)
            vnew0 > vto - 0.5 and vnew0 < vto + 4.0
        else
            d <= 0.0 or vnew0 <= vto + 0.5;
        if (keep) {
            if (comptime zl_verify) zlstd.debug.assert(zlSame(vnew0, zFetlimClamp(vnew0, vold, vto)));
            return vnew0;
        }
    }
    return @call(.never_inline, zFetlimClamp, .{ vnew0, vold, vto });
}

/// SPICE3 `DEVlimvds`: bounds a drain-source step. The numbers are the
/// algorithm; exact on all finite inputs.
pub inline fn zLimvds(vnew0: f64, vold: f64) f64 {
    if (comptime k_dev) return zLimvdsClamp(vnew0, vold);
    // The transparent arm. Below 3.5 V the only bounds are -0.5 and 4.0. At
    // or above it the upper bound `3*vold + 2` exceeds `vold`, so it covers
    // the `vnew <= vold` arm too, and the lower bound is the flat 2.0.
    const keep = if (vold < 3.5)
        vnew0 >= -0.5 and vnew0 <= 4.0
    else
        vnew0 >= 2.0 and vnew0 <= 3.0 * vold + 2.0;
    if (keep) {
        if (comptime zl_verify) zlstd.debug.assert(zlSame(vnew0, zLimvdsClamp(vnew0, vold)));
        return vnew0;
    }
    return @call(.never_inline, zLimvdsClamp, .{ vnew0, vold });
}

/// ngspice `B4SOIlimit` / hisim `limit_dx`: the absolute per-iteration step
/// clamp |vnew - vold| <= lim. A NaN or infinite `vnew0` lands on a step
/// bound (`@min`/`@max` are maxnum), so there is no separate non-finite
/// reset. Fixed-point preserving.
pub fn zSteplim(vnew0: f64, vold: f64, lim: f64) f64 {
    const r = @max(vold - lim, @min(vold + lim, vnew0));
    if (lim >= 0.0 and zlstd.math.isFinite(vold) and zlstd.math.isFinite(lim)) {
        zlstd.debug.assert(r >= vold - lim);
        zlstd.debug.assert(r <= vold + lim);
    }
    return r;
}

// ---- private ----

/// Bit-identical, NaN payload included: what "transparent" means here.
fn zlSame(a: f64, b: f64) bool {
    return @as(u64, @bitCast(a)) == @as(u64, @bitCast(b));
}

/// The devices' natural log (`contract.gm.log`): one implementation on
/// host, NVPTX and AMDGCN, with log(0) = -inf.
inline fn klog(x: f64) f64 {
    return @import("contract").gm.log(x);
}

/// Two-way pick, bit-select spelling: the result is exactly `a`'s or `b`'s
/// bit pattern. Not `if (c) a else b` and not a bare `(m & a) | (~m & b)`:
/// LLVM folds both back into a `select` and then branch-lowers it (seen in
/// `-femit-asm`: `ja`/`jbe` guarding an arm's computation). The empty asm
/// makes each arm's bits opaque, so there is nothing to sink behind a jump.
/// `"r"` is a GPR on every host target; NVPTX spells it `"l"`, and a GPU
/// needs no barrier, so the device build skips it.
inline fn sel(c: bool, a: f64, b: f64) f64 {
    var av: u64 = @bitCast(a);
    var bv: u64 = @bitCast(b);
    if (comptime !k_dev) {
        asm volatile (""
            : [av] "+r" (av),
              [bv] "+r" (bv),
        );
    }
    const m = @as(u64, 0) -% @intFromBool(c);
    return @bitCast((m & av) | (~m & bv));
}

/// The `DEVpnjlim` ladder, one body for both targets: cold and out of line
/// on a host, the whole kernel on a GPU.
fn zPnjlimClamp(vnew0: f64, vold: f64, vt: f64, vcrit: f64) f64 {
    const damp = vnew0 > vcrit and @abs(vnew0 - vold) > vt + vt;
    // The negative-excursion floor of the oracle's `else if` arm.
    const floor = sel(vold > 0.0, -vold - 1.0, 2.0 * vold - 1.0);
    const floored = sel(vnew0 < 0.0 and vnew0 < floor, floor, vnew0);
    const arg = (vnew0 - vold) / vt;
    // Every damping candidate, evaluated. Live guards: d_up needs arg >= 2,
    // d_dn arg <= -2, d_log vnew0 > vcrit > 0, so the 0.0 clamp only ever
    // rewrites a dead argument.
    const d_up = vold + vt * (2.0 + klog(@max(arg - 2.0, 0.0)));
    const d_dn = vold - vt * (2.0 + klog(@max(2.0 - arg, 0.0)));
    const d_log = vt * klog(@max(vnew0 / vt, 0.0));
    const damped = sel(vold > 0.0, sel(arg > 0.0, d_up, d_dn), d_log);
    return sel(damp, damped, floored);
}

/// The `DEVfetlim` ladder, one body for both targets (`zPnjlimClamp`).
fn zFetlimClamp(vnew0: f64, vold: f64, vto: f64) f64 {
    const vtsthi = @abs(2.0 * (vold - vto)) + 2.0;
    const vtstlo = vtsthi * 0.5 + 2.0;
    const vtox = vto + 3.5;
    const delv = vnew0 - vold;
    const down = delv <= 0.0;
    // ngspice's MAX/MIN are `?:` ternaries, exactly `sel`: not `@max`/`@min`,
    // whose maxnum NaN fix-up got branch-lowered here.
    // vold >= vtox: going off keeps a floor, staying on caps the step.
    const flr = vto + 2.0;
    const hi_dn = sel(vnew0 >= vtox, sel(-delv > vtstlo, vold - vtstlo, vnew0), sel(vnew0 > flr, vnew0, flr));
    const hi_up = sel(delv >= vtsthi, vold + vtsthi, vnew0);
    const r_hi = sel(down, hi_dn, hi_up);
    // vto <= vold < vtox: a plain clamp about threshold.
    const lo_b = vto - 0.5;
    const hi_b = vto + 4.0;
    const r_mid = sel(down, sel(vnew0 > lo_b, vnew0, lo_b), sel(vnew0 < hi_b, vnew0, hi_b));
    const r_on = sel(vold >= vtox, r_hi, r_mid);
    // vold < vto (off): symmetric step bounds, a ceiling at vto+0.5 going on.
    const off_dn = sel(-delv > vtsthi, vold - vtsthi, vnew0);
    const off_up = sel(vnew0 <= vto + 0.5, sel(delv > vtstlo, vold + vtstlo, vnew0), vto + 0.5);
    const r_off = sel(down, off_dn, off_up);
    return sel(vold >= vto, r_on, r_off);
}

/// The `DEVlimvds` ladder, one body for both targets (`zPnjlimClamp`).
fn zLimvdsClamp(vnew0: f64, vold: f64) f64 {
    const r_hi = sel(vnew0 > vold, @min(vnew0, 3.0 * vold + 2.0), sel(vnew0 < 3.5, @max(vnew0, 2.0), vnew0));
    const r_lo = sel(vnew0 > vold, @min(vnew0, 4.0), @max(vnew0, -0.5));
    return sel(vold >= 3.5, r_hi, r_lo);
}
