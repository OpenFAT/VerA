//! §4.5 analog operators: the current S-valued input and the operator's
//! accepted state in, the operator's value (with its analytic derivative)
//! out, plus `transition`'s accepted-step bookkeeping. Device text only
//! (`text.ops`): every function is private there, so nothing here compiles
//! as host code and only AstGen checks this file. The accepted state is the
//! caller's (`Instance` fields).
//! Cites: VAMS §4.5.4, §4.5.5, §4.5.8, §4.5.9, §4.5.10, §5.10.3.1.
//!
//! Contents: none (device text only, every function private).

const zostd = @import("std");

// ---- device text ----

// ---- private ----

/// §4.5.4 `idt`: the accepted integral plus this step's rectangle. A static
/// analysis returns the initial condition, the DC value §4.5.4 gives it.
fn zIdt(comptime S: type, v: S, acc: f64, dt: f64, ic: f64) S {
    if (dt <= 0.0) return S.con(ic);
    return v.scale(dt).addC(acc);
}

/// §4.5.4 `idt` with an assert argument: "idt() returns the initial
/// conditions ... whenever assert is nonzero".
fn zIdtHold(comptime S: type, v: S, off: f64, ic: f64, assert_: f64) S {
    if (assert_ != 0.0) return S.con(ic);
    return v.addC(-off);
}

/// `zIdt` on the accepted solution, where no derivative is wanted.
fn zIdtAcc(v: f64, acc: f64, dt: f64, ic: f64) f64 {
    if (dt <= 0.0) return ic;
    return acc + v * dt;
}

/// §4.5.5 `idtmod`: `zIdt` wrapped into [o, o + m). The wrap subtracts a
/// piecewise-constant multiple of the modulus, so the wrapped integral's
/// derivative is the raw one's.
fn zIdtmod(comptime S: type, v: S, acc: f64, dt: f64, ic: f64, m: f64, o: f64) S {
    const raw = zIdt(S, v, acc, dt, ic);
    if (!(m > 0.0)) return raw;
    return raw.addC(-m * @floor((raw.val() - o) / m));
}

/// §4.5.5 the `idtmod` wrap of an accepted value.
fn zWrap(x: f64, modulus: f64, offset: f64) f64 {
    if (!(modulus > 0.0)) return x;
    return x - modulus * @floor((x - offset) / modulus);
}

/// §4.5.9 `slew`: the input, clamped to the rates `rise` and `fall` allow
/// from the previous accepted output. A static analysis passes it through.
fn zSlew(comptime S: type, v: S, prev: f64, dt: f64, rise: f64, fall: f64) S {
    if (dt <= 0.0) return v;
    return v.minC(prev + rise * dt).maxC(prev - fall * dt);
}

/// §4.5.10 `last_crossing` at the point being evaluated: where the input
/// `crossed` since the last accepted point, `Gen.lastCrossTime`'s
/// interpolation in the same operation order (so the latch reads the same
/// bits), whose zero moves with `v` and so carries `v`'s derivative;
/// otherwise the latched `t_last`, a constant.
fn zLastCross(comptime S: type, v: S, prev: f64, t: f64, dt: f64, t_last: f64, crossed: bool) S {
    if (!crossed) return S.con(t_last);
    return S.con(prev).div(S.con(prev).sub(v)).scale(dt).addC(t - dt);
}

/// §5.10.3.1/§4.5.10 the crossing test for a direction that is a parameter
/// (so codegen cannot pick the comparison at emit time): +1 rising only, -1
/// falling only, 0 either, any other value disables `cross()`. The exact
/// decode `Gen.crossTest` applies to a folded direction, so overriding the
/// parameter to its default's value changes nothing.
fn zCrossDir(dir: f64, prev: f64, in: f64) bool {
    if (dir == 1.0) return prev <= 0.0 and in > 0.0;
    if (dir == -1.0) return prev >= 0.0 and in < 0.0;
    if (dir != 0.0) return false;
    return (prev <= 0.0 and in > 0.0) or (prev >= 0.0 and in < 0.0);
}

/// §5.10.3.1 "the event shall occur after the threshold crossing, and while
/// the signal remains in the box defined by actual crossing and expr_tol and
/// time_tol": for a crossing found in the step ending at `t`, null when `t`
/// is inside that box, else a time inside it just past the crossing (the
/// zero of the line through (`t - dt`, `v0`) and (`t`, `v1`), as
/// `Gen.lastCrossTime` has it). A zero tolerance is the tool's (VD-066: the
/// grid), so it does not bound the box.
fn zCrossRetry(v0: f64, v1: f64, t: f64, dt: f64, ttol: f64, etol: f64) ?f64 {
    const tc = (t - dt) + v0 / (v0 - v1) * dt;
    const late = (ttol > 0.0 and t - tc > ttol) or (etol > 0.0 and @abs(v1) > etol);
    if (!late) return null;
    var d = if (ttol > 0.0) ttol else t - tc;
    if (etol > 0.0) d = @min(d, etol * dt / @abs(v1 - v0));
    return tc + d / 2.0;
}

/// §4.5.8 the fraction of the current excursion the ramp has traversed:
/// "transition() forces all positive transitions of expr to occur over
/// rise_time and all negative transitions to occur in fall_time", piecewise
/// linear, so (t - t0)/tt clamped into [0, 1] with tt picked by the
/// excursion's direction. A zero transition time is §4.5.8's degenerate
/// case, left to the simulator: an instantaneous edge, fraction 1.
fn zTransFrac(target: f64, from: f64, t0: f64, t: f64, rise: f64, fall: f64) f64 {
    const tt = if (target >= from) rise else fall;
    if (!(tt > 0.0)) return 1.0;
    const f = @min(@max((t - t0) / tt, 0.0), 1.0);
    zostd.debug.assert(f >= 0.0);
    zostd.debug.assert(f <= 1.0);
    return f;
}

/// §4.5.8 `transition`. A static analysis passes the input through ("In DC
/// analysis, transition() passes the value of the expr directly to its
/// output"). In a transient the output is a function of the input's past
/// alone: the excursion in flight was armed by the accepted step that saw
/// the input change, so it ramps from `from` to `to`, never to the current
/// input (which would arm every ramp one accepted step early).
fn zTransition(comptime S: type, v: S, from: f64, to: f64, t0: f64, t: f64, dt: f64, rise: f64, fall: f64) S {
    if (dt <= 0.0) return v;
    return S.con(from + (to - from) * zTransFrac(to, from, t0, t, rise, fall));
}

/// §4.5.8 accepted-step bookkeeping: "a transition is created when the input
/// expression changes, and at this point it uses the value of td,
/// rise_time, fall_time and time_tol to determine the new pending transition
/// operator". `to` is the armed destination and so the last accepted input,
/// which makes `in != to` that sentence's test. An unchanged input leaves the
/// excursion alone: re-arming the origin every step would shrink the
/// remaining distance by a constant factor, an exponential wearing a ramp's
/// coefficients. On return `to` holds `in`.
fn zTransStep(in: f64, from: *f64, to: *f64, t0: *f64, t: f64, dt: f64, td: f64, rise: f64, fall: f64) void {
    defer zostd.debug.assert(to.* == in or in != in);
    if (dt <= 0.0) { // the DC point: the output is the input
        from.* = in;
        to.* = in;
        t0.* = t;
        return;
    }
    if (in == to.*) return;
    // "td models transport delay": the ramp begins td after the change, from
    // where the old trajectory will be at t + td.
    const te = t + td;
    const f = zTransFrac(to.*, from.*, t0.*, te, rise, fall);
    const vi = from.* + (to.* - from.*) * f;
    // §4.5.8's four interruption paragraphs (Figures 4-7 to 4-12): a change
    // inside the active region is "not ... a new transition, but rather a
    // readjustment" whose slope uses "either the original transition's
    // origin or destination as the new origin". The reference is the
    // destination when the new direction opposes the original and the origin
    // when it agrees:
    //   rising,  v3 < vi -> opposes -> (v3-v2)/tf3    rising,  v3 > vi -> (v3-v1)/tr3
    //   falling, v3 > vi -> opposes -> (v3-v2)/tr3    falling, v3 < vi -> (v3-v1)/tf3
    // "applied from the point of interruption (ti,vi)", spelled as the
    // shifted origin (t4,v4): v4 the reference level, t4 where the slope line
    // through (te,vi) reaches it; zTransFrac then finds the arrival t3.
    // Outside the active region it is a new transition from where the
    // output is.
    if (f < 1.0 and in != vi) {
        const tt3 = if (in > vi) rise else fall;
        const vref = if ((in > vi) != (to.* > from.*)) to.* else from.*;
        const slope = if (tt3 > 0.0) (in - vref) / tt3 else 0.0;
        if (slope != 0.0) {
            from.* = vref;
            to.* = in;
            t0.* = te + (vref - vi) / slope;
            return;
        }
    }
    from.* = vi;
    to.* = in;
    t0.* = te;
}
