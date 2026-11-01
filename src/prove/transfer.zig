//! The prover's transfer functions: an opcode and its operands' intervals in,
//! the result's interval and finite bit out (`Abstract`). Pure arithmetic on
//! `Interval`: no MIR walk, no allocation, no diagnostics. A bound is the
//! value the device computes: exp, log and pow are `contract.gm`'s.
//!
//! LRM clauses this file's code cites: §2.7, §2.9, §3.2, §3.4.2, §4.2.4,
//! §4.2.5, §4.2.8, §4.3.1, §4.3.2, §4.5.4, §4.5.13, §4.6.1, §5.2.1, §5.10.2,
//! §5.10.3, §9.5, §9.5.1, §9.10, §9.13, §9.15, §9.18; Tables 4-14 (§4.3.1) and
//! 4-15 (§4.3.2).
//! IEEE 1364-2005 clauses cited: §5.4.
//!
//! Contents:
//! - `pub const Abstract = struct { iv: Interval, finite: bool }`
//! - `pub fn integerIv(op: Mir.Opcode) Interval`
//! - `pub fn unaryTransfer(op: Mir.Opcode, a: Interval, af: bool) Abstract`
//! - `pub fn binaryTransfer(op: Mir.Opcode, x: Interval, y: Interval, f: bool) Abstract`
//! - `pub fn callAbstract(c: Mir.Callee) Abstract`
//! - `pub fn combine(x: Interval, y: Interval, f: *const fn (f64, f64) f64) Interval`
//! - `pub fn mulOp(a: f64, b: f64) f64`

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const Mir = @import("ir").Mir;
/// The devices' exp/log/pow, so a bound is the value a device computes.
const gm = @import("contract").gm;
const Interval = @import("Interval.zig");

/// A value's abstract state: its interval for the domain proof, and the
/// separate finiteness fact (the rules on `proof.FloatMode`) that sets the
/// float mode.
pub const Abstract = struct { iv: Interval, finite: bool };

// §3.2 an integer is an i64 in the device: every one lies in this range.
const int_range: Interval = .{ .lo = -9.223372036854776e18, .hi = 9.223372036854776e18 };

/// Integer results (§3.2): clamp to the i64 range so an integer expression
/// can never make a unit `.strict`. Relational/logical results are 0/1.
pub fn integerIv(op: Mir.Opcode) Interval {
    assert(Mir.opIsInteger(op));
    const r: Interval = if (Mir.opcode.get(op).bool01) .{ .lo = 0, .hi = 1 } else int_range;
    assert(r.bounded());
    assert(!r.isEmpty());
    return r;
}

/// Returns unary `op` over an operand with interval `a` and finite bit `af`.
/// A monotone function maps the endpoints; an opcode with no rule answers
/// top and not finite, which is sound and only loses precision. A NaN-free
/// operand gives a NaN-free result.
pub fn unaryTransfer(op: Mir.Opcode, a: Interval, af: bool) Abstract {
    const out = unaryRaw(op, a, af);
    if (out.finite) assert(af); // finiteness flows only from a finite operand
    if (nanFree(a)) assert(nanFree(out.iv));
    if (out.iv.nonzero) assert(a.nonzero); // only `fabs` passes the hole on
    if (op == .tan) assert(!out.finite);
    return out;
}

/// Returns binary `op` over `x` and `y`; `f` is both operands' finite bit.
/// Rule 3 on `proof.FloatMode` keeps `+ - * /` finite on finite operands,
/// except a divisor that can be zero. No rule: top, not finite. NaN-free
/// operands give a NaN-free result.
pub fn binaryTransfer(op: Mir.Opcode, x: Interval, y: Interval, f: bool) Abstract {
    const out = binaryRaw(op, x, y, f);
    if (out.finite) assert(f);
    if (nanFree(x) and nanFree(y)) assert(nanFree(out.iv));
    assert(!out.iv.nonzero); // no binary rule proves a hole
    if (op == .fdiv and !y.excludesZero()) assert(!out.finite);
    return out;
}

/// Returns the abstract value of a `call` whose range the LRM fixes. Everything else is top
/// and not finite: an unmodelled call costs `.strict`, never a wrong `.optimized`.
pub fn callAbstract(c: Mir.Callee) Abstract {
    const positive: Interval = .{ .lo = 0, .lo_open = true, .nonzero = true };
    const non_negative: Interval = .{ .lo = 0 };
    // §9.5 the descriptor family is finite: every §9.5 call is integer-valued
    // (`callee.ty`), and in a residual unit, the only kind `proof` rates,
    // the emitter renders it as the literal 0 §9.5.1 reserves; the descriptor
    // operation happens only in the display unit (`codegen.Gen.emitting_display`).
    // No interval: §9.5.1's fd has bit 31 set, so there is nothing useful to bound.
    if (Mir.callee.isFileCall(c)) return .{ .iv = .top, .finite = true };
    // §3.2 an integer-valued call (`callee.ty`) is an i64 in the device, and
    // §2.7 a string never reaches a float operation: neither is inf or NaN.
    switch (Mir.callee.ty(c)) {
        .int => return .{ .iv = int_range, .finite = true },
        // A string, and an IEEE 1364 §5.4 wide integer, never reach a float
        // operation either; neither has an interval.
        .str, .wide => return .{ .iv = .top, .finite = true },
        .real => {},
    }
    const r: Abstract = switch (c) {
        // §4.6.1 analysis(), the §5.2.1 `analog initial` flag, the §5.10.2
        // initial_step/final_step events, the §5.10.3 cross/above/timer
        // events and §4.5.4's static-solve test render as 0.0 or 1.0
        // (`codegen/call.zig`). An event's arguments are still compared, so
        // the unit's slice still reads them.
        .analysis, .analog_initial, .initial_step, .final_step, .cross, .above, .timer, .@"op$static" => .{ .iv = .{ .lo = 0, .hi = 1 }, .finite = true },
        // §9.10 environment parameter functions; §9.18 $mfactor. `limexp` is
        // not here: its range is its argument's (`Prover.callTransfer`).
        .@"$vt", // thermal voltage kT/q > 0, argument-free; see callTransfer
        .@"$temperature", // absolute temperature, kelvin
        .@"$mfactor", // multiplicity factor > 0
        => .{ .iv = positive, .finite = true },
        .@"$abstime", .@"$realtime" => .{ .iv = non_negative, .finite = true },
        // §9.13 reference algorithms can overflow or underflow (Erlang's product,
        // Student-t's divisor, and unbounded real scale parameters). A distribution
        // name alone proves no finite value; retain strict floating-point mode.
        else => .{ .iv = .top, .finite = false }, // else: the prover models no other call's range
    };
    assert(nanFree(r.iv));
    assert(!r.iv.isEmpty());
    if (r.finite) assert(r.iv.ge(0)); // every modelled real call is a flag, a scale or a time
    return r;
}

/// Returns the hull of `f` at the four corners of the box, closed (openness does not carry
/// through a product). A NaN corner (0*inf, 0/0, inf/inf) returns `top`.
/// Precondition: `f` is monotone in each argument separately over the box. `*` always is;
/// `/` only for a one-signed divisor (the `.fdiv` transfer checks); `pow` only for x >= 0
/// (`powIv` checks).
pub fn combine(x: Interval, y: Interval, f: *const fn (f64, f64) f64) Interval {
    const c: @Vector(4, f64) = .{ f(x.lo, y.lo), f(x.lo, y.hi), f(x.hi, y.lo), f(x.hi, y.hi) };
    if (@reduce(.Or, c != c)) return .top; // a NaN corner
    const r: Interval = .{ .lo = @reduce(.Min, c), .hi = @reduce(.Max, c) };
    assert(r.lo <= r.hi); // four non-NaN corners
    assert(!r.lo_open);
    assert(!r.hi_open);
    assert(r.contains(c[0]));
    assert(r.contains(c[3]));
    return r;
}

/// `a * b`, the `combine` kernel of `*`.
pub fn mulOp(a: f64, b: f64) f64 {
    const r = a * b;
    if (math.isNan(r)) assert(math.isNan(a) or math.isNan(b) or math.isInf(a) or math.isInf(b));
    return r;
}

// ---- private ----

// Returns unary `op` over an operand with interval `a` and finite bit `af`.
// A monotone function maps the endpoints; an opcode with no rule answers
// top and not finite, which is sound and only loses precision.
fn unaryRaw(op: Mir.Opcode, a: Interval, af: bool) Abstract {
    if (monotoneAt(op, a.lo)) |lo| {
        const hi = monotoneAt(op, a.hi).?;
        // A NaN endpoint means the operand straddles the function's domain
        // edge (ln(-1), sqrt(-4), asin(2), acosh(0.5)), and the endpoints
        // then do not span the in-domain range: sqrt over [-4,9] is [0,3],
        // not [3,+inf]. checkDomain has already refused to prove this
        // operand, so the only sound interval is top. Endpoints at the edge
        // stay exact and wide: ln(0) = -inf and atanh(1) = +inf are not NaN.
        if (math.isNan(lo) or math.isNan(hi)) return .{ .iv = .top, .finite = false };
        // An open end stays open only where the device's rounding keeps it
        // open. f is non-decreasing as computed, so every double past an open
        // end maps past f(end) exactly when the next double does. Underflow
        // (exp(-800) = 0), saturation (tanh(20) = 1) and flat steps (floor)
        // all close the end; a NaN there (past the domain edge) closes it too.
        // ponytail: trusts the computed f to be monotone. A faithful libm may
        // step back one ulp; covering that means widening every end by an ulp.
        const inf = math.inf(f64);
        const iv: Interval = .{
            .lo = @min(lo, hi),
            .hi = @max(lo, hi),
            .lo_open = a.lo_open and monotoneAt(op, math.nextAfter(f64, a.lo, inf)).? > lo,
            .hi_open = a.hi_open and monotoneAt(op, math.nextAfter(f64, a.hi, -inf)).? < hi,
        };
        assert(iv.lo <= iv.hi); // both ends checked non-NaN above
        if (iv.lo_open) assert(a.lo_open);
        if (iv.hi_open) assert(a.hi_open);
        const overflows = op == .exp or op == .expm1 or op == .sinh;
        return .{ .iv = iv, .finite = af and (!overflows or iv.bounded()) };
    }
    return switch (op) {
        .fneg => .{ .iv = .{
            .lo = -a.hi,
            .hi = -a.lo,
            .lo_open = a.hi_open,
            .hi_open = a.lo_open,
        }, .finite = af },
        .fabs => .{ .iv = absIv(a), .finite = af },
        // §4.3.2 acos is decreasing on [-1,1]. Same straddle rule as the
        // monotone path above: an out-of-domain endpoint (acos(2) = NaN)
        // voids the endpoint claim.
        .acos => blk: {
            const lo = math.acos(a.hi);
            const hi = math.acos(a.lo);
            if (math.isNan(lo) or math.isNan(hi)) break :blk .{ .iv = .top, .finite = false };
            break :blk .{ .iv = .{ .lo = lo, .hi = hi }, .finite = af };
        },
        // §4.3.2 cosh is even and grows: bounded only if |x| is bounded.
        .cosh => blk: {
            const m = absIv(a);
            const iv: Interval = .{ .lo = 1, .hi = math.cosh(m.hi) };
            break :blk .{ .iv = iv, .finite = af and iv.bounded() };
        },
        .sin, .cos => .{ .iv = .{ .lo = -1, .hi = 1 }, .finite = af },
        // §4.3.2 tan is unbounded between poles; the domain check has
        // already run, so only finiteness is left and it is not provable.
        .tan => .{ .iv = .top, .finite = false },
        else => .{ .iv = .top, .finite = false }, // else: ⊤, not finite, is sound for any opcode; only precision is lost
    };
}

// Returns binary `op` over `x` and `y`; `f` is both operands' finite bit.
// Rule 3 on `proof.FloatMode` keeps `+ - * /` finite on finite operands,
// except a divisor that can be zero. No rule: top, not finite.
fn binaryRaw(op: Mir.Opcode, x: Interval, y: Interval, f: bool) Abstract {
    // Rule 3 on `FloatMode`: `+ - * /` on finite operands stay finite.
    switch (op) {
        // A sum's end is open only if the smallest (largest) sum the open
        // operand ends admit still rounds past it: the rounded sum is
        // monotone in each operand, so testing the doubles just inside the
        // open ends decides it. 0.5 + 1e20 rounds to 1e20, so (0:1] + 1e20 is
        // [1e20, 1e20], not (1e20, 1e20].
        .fadd => {
            const lo = addLo(x.lo, y.lo);
            const hi = addHi(x.hi, y.hi);
            const iv: Interval = .{
                .lo = lo,
                .hi = hi,
                .lo_open = (x.lo_open or y.lo_open) and addLo(inLo(x), inLo(y)) > lo,
                .hi_open = (x.hi_open or y.hi_open) and addHi(inHi(x), inHi(y)) < hi,
            };
            if (iv.lo_open) assert(x.lo_open or y.lo_open);
            if (iv.hi_open) assert(x.hi_open or y.hi_open);
            return .{ .iv = iv, .finite = f };
        },
        .fsub => {
            const lo = addLo(x.lo, -y.hi);
            const hi = addHi(x.hi, -y.lo);
            const iv: Interval = .{
                .lo = lo,
                .hi = hi,
                .lo_open = (x.lo_open or y.hi_open) and addLo(inLo(x), -inHi(y)) > lo,
                .hi_open = (x.hi_open or y.lo_open) and addHi(inHi(x), -inLo(y)) < hi,
            };
            if (iv.lo_open) assert(x.lo_open or y.hi_open);
            if (iv.hi_open) assert(x.hi_open or y.lo_open);
            return .{ .iv = iv, .finite = f };
        },
        .fmul => {
            const iv = combine(x, y, mulOp);
            return .{ .iv = iv, .finite = f };
        },
        .fdiv => {
            // A divisor that can be zero yields ±inf (§4.2.4 permits it;
            // only `%` errors). That is not an overflow, so rule 3
            // must not apply, or an
            // inf-producing value would be marked finite under `.optimized`.
            if (!y.excludesZero()) return .{ .iv = .top, .finite = false };
            // A §3.4.2 puncture (`exclude 0` on a sign-spanning range)
            // proves the divisor nonzero but not one-signed, and corner
            // combination is sound for `/` only on a one-signed divisor:
            // 1/y over [-10,10]\{0} is (-inf,-0.1] ∪ [0.1,+inf), while the
            // corners 1/±10 give its complement [-0.1,0.1]. The nonzero fact
            // still stands for finiteness (±inf only via overflow, rule 3);
            // only the interval claim is void.
            // An open end at 0 is approached from the divisor's own side, so
            // its corner divides by that signed zero: 1/(-inf, 0) is
            // (0, +inf], and a +0 end would give the corner -inf instead.
            var yd = y;
            if (y.lt(0) and y.hi == 0) yd.hi = -0.0;
            if (y.gt(0) and y.lo == 0) yd.lo = 0.0;
            assert(yd.excludesZero()); // the signed zero keeps the end open
            const iv = if (y.gt(0) or y.lt(0)) combine(x, yd, divOp) else Interval.top;
            return .{ .iv = iv, .finite = f };
        },
        // §4.2.4 modulus: |result| < |divisor|, sign of the dividend.
        .fmod => {
            const m = absIv(y).hi;
            const iv: Interval = if (math.isFinite(m))
                .{ .lo = if (x.ge(0)) 0 else -m, .hi = if (x.le(0)) 0 else m }
            else
                .top;
            if (math.isFinite(m)) assert(iv.bounded());
            return .{ .iv = iv, .finite = f };
        },
        .pow => {
            const iv = powIv(x, y);
            return .{ .iv = iv, .finite = f and iv.bounded() };
        },
        .hypot => {
            const iv: Interval = .{ .lo = 0, .hi = addHi(absIv(x).hi, absIv(y).hi) };
            assert(!math.isNan(iv.hi));
            return .{ .iv = iv, .finite = f };
        },
        .atan2 => return .{ .iv = .{ .lo = -math.pi, .hi = math.pi }, .finite = f },
        .fmin => return .{ .iv = .{
            .lo = @min(x.lo, y.lo),
            .hi = @min(x.hi, y.hi),
        }, .finite = f },
        .fmax => return .{ .iv = .{
            .lo = @max(x.lo, y.lo),
            .hi = @max(x.hi, y.hi),
        }, .finite = f },
        else => return .{ .iv = .top, .finite = false }, // else: ⊤, not finite, is sound for any opcode; only precision is lost
    }
}

fn nanFree(i: Interval) bool {
    const r = !math.isNan(i.lo) and !math.isNan(i.hi);
    if (!r) assert(!i.bounded());
    return r;
}

// f(x) for each unary op the device computes as a non-decreasing function,
// null for every other op. NaN means x is outside f's domain.
fn monotoneAt(op: Mir.Opcode, x: f64) ?f64 {
    return switch (op) {
        .exp => gm.exp(x),
        .expm1 => math.expm1(x),
        .ln => gm.log(x),
        .ln1p => math.log1p(x),
        .log10 => gm.log10(x),
        .sqrt => @sqrt(x),
        .sinh => math.sinh(x),
        .tanh => math.tanh(x),
        .asinh => gm.asinh(x),
        .atan => math.atan(x),
        .asin => math.asin(x),
        .atanh => gm.atanh(x),
        .acosh => gm.acosh(x),
        .floor => @floor(x),
        .ceil => @ceil(x),
        // .path_prev/.path_acc take `else` (unbounded): the latch holds a
        // value from an EARLIER solve, which current branch guards do not
        // constrain, so an identity interval here would be too narrow.
        // `dstop` (§2.9 `vera_nodiff`) is its operand's value with no
        // derivative lanes.
        .if_cast, .opt_barrier, .dstop => x,
        else => null, // else: not monotone, or no transfer: `unaryTransfer`'s switch
    };
}

// Endpoint arithmetic: a NaN sum (inf-inf) folds to the wide side. A unary NaN
// endpoint is not folded: it means the operand straddles the domain edge, and
// `unaryTransfer` answers top.

fn addLo(a: f64, b: f64) f64 {
    const r = a + b;
    const out = if (math.isNan(r)) -math.inf(f64) else r;
    assert(!math.isNan(out));
    return out;
}

fn addHi(a: f64, b: f64) f64 {
    const r = a + b;
    const out = if (math.isNan(r)) math.inf(f64) else r;
    assert(!math.isNan(out));
    return out;
}

// The least member of `i` as a double: `lo`, or the next double up when `lo`
// is open. `inHi` is the greatest.
fn inLo(i: Interval) f64 {
    const r = if (i.lo_open) math.nextAfter(f64, i.lo, math.inf(f64)) else i.lo;
    assert(!(r < i.lo));
    return r;
}
fn inHi(i: Interval) f64 {
    const r = if (i.hi_open) math.nextAfter(f64, i.hi, -math.inf(f64)) else i.hi;
    assert(!(r > i.hi));
    return r;
}

fn divOp(a: f64, b: f64) f64 {
    return a / b;
}
fn powOp(a: f64, b: f64) f64 {
    return gm.pow(a, b);
}

/// §4.3.1 Table 4-14 pow(x,y) over a box. Corner combination is sound only where pow is
/// monotone in each argument separately, which fails in the ways a negative base admits:
///   - even integer exponent: interior minimum at x = 0 (the corners of pow([-2,2], 2) are
///     all 4, while the range is [0,4]);
///   - non-integer exponent: pow(neg, frac) is NaN (§4.3.1's "if x < 0, all integer y"),
///     which corners at integer endpoints never see;
///   - negative exponent: pole at x = 0, and IEEE pow(+0,-odd) = +inf is the wrong side of
///     the two-sided pole a base interval reaching 0 straddles.
fn powIv(x: Interval, y: Interval) Interval {
    // x >= 0: pow = exp(y·ln x) is monotone in x for fixed y and in y for
    // fixed x, so box extrema sit at corners; IEEE fills the x = 0 edge
    // (pow(0,neg)=+inf, pow(0,0)=1) on the corners too. `combine`'s NaN guard
    // covers the exotic corners.
    if (x.ge(0)) return combine(x, y, powOp);
    // Base can be negative: only an exponent pinned to one known integer k
    // supports any claim (an integer-valued range mixes parities, and a
    // possibly-fractional exponent means possible NaN); otherwise top.
    const k = y.lo;
    if (!(y.lo == y.hi and math.isFinite(k) and k == @trunc(k))) return .top;
    assert(math.isFinite(k));
    assert(!x.ge(0));
    if (k >= 0) {
        // Even k: x^k = |x|^k exactly, monotone in |x|; absIv restores the
        // interior 0 a sign-spanning base reaches. Odd k: monotone on all of R.
        // (Doubles >= 2^53 are all even integers, so @mod stays honest there.)
        if (@mod(k, 2) == 0) {
            const m = absIv(x);
            return .{ .lo = powOp(m.lo, k), .hi = powOp(m.hi, k) };
        }
        return .{ .lo = powOp(x.lo, k), .hi = powOp(x.hi, k) };
    }
    assert(k < 0);
    // k < 0: pole at 0. Sound only for a strictly negative base (x.hi < 0; an
    // open-at-0 bound is not enough: IEEE pow(+0, -odd) is +inf while the
    // one-sided limit from below is -inf). x^k is then monotone on the side.
    if (x.hi < 0) {
        const a = powOp(x.lo, k);
        const b = powOp(x.hi, k);
        return .{ .lo = @min(a, b), .hi = @max(a, b) };
    }
    // Punctured or zero-touching negative base with a negative exponent: the
    // same two-sided pole as the fdiv puncture, so top.
    return .top;
}

fn absIv(a: Interval) Interval {
    if (a.ge(0)) return a;
    if (a.le(0)) {
        const r: Interval = .{ .lo = -a.hi, .hi = -a.lo, .lo_open = a.hi_open, .hi_open = a.lo_open };
        assert(r.ge(0));
        return r;
    }
    const r: Interval = .{ .lo = 0, .hi = @max(@abs(a.lo), @abs(a.hi)) };
    assert(r.ge(0));
    return r;
}

// Test support. The oracle is the device: each transfer's interval must hold
// every value the device computes (`opcode_zig.zig`'s host spelling) at points
// inside its operands' intervals, and a `finite` claim must hold at every
// in-domain point.

/// `Interval.contains`, with one double of slack past a closed end: exp, log and pow are
/// faithful (< 1 ulp), not correctly rounded, so a value between two corners
/// may round one double past the corners' own rounding. An open end gets no
/// slack: the bugs it guards are device values landing exactly on it.
fn admits(i: Interval, y: f64) bool {
    if (i.nonzero and y == 0) return false;
    const inf = math.inf(f64);
    const above = y > i.lo or (!i.lo_open and y >= math.nextAfter(f64, i.lo, -inf));
    const below = y < i.hi or (!i.hi_open and y <= math.nextAfter(f64, i.hi, inf));
    // `contains` plus the slack.
    if (i.contains(y)) assert(above);
    if (i.contains(y)) assert(below);
    if (above and below) assert(!math.isNan(y));
    return above and below;
}

/// Points of `a` a test evaluates at: each closed end, the double just inside
/// each end, the midpoint, and whichever of `extra` lie inside.
fn samplePoints(a: Interval, extra: []const f64, buf: []f64) []const f64 {
    const inf = math.inf(f64);
    var n: usize = 0;
    const ends = [_]f64{ a.lo, a.hi, math.nextAfter(f64, a.lo, inf), math.nextAfter(f64, a.hi, -inf), a.lo / 2 + a.hi / 2 };
    for (ends) |x| if (!math.isNan(x) and a.contains(x) and n < buf.len) {
        buf[n] = x;
        n += 1;
    };
    for (extra) |x| if (a.contains(x) and n < buf.len) {
        buf[n] = x;
        n += 1;
    };
    assert(n <= buf.len);
    for (buf[0..n]) |x| assert(a.contains(x));
    return buf[0..n];
}

/// Every interval with ends in `ends` (lo <= hi) and each openness pair in `opens`.
fn intervals(ends: []const f64, opens: []const [2]bool, buf: []Interval) []const Interval {
    var n: usize = 0;
    for (ends) |lo| for (ends) |hi| {
        if (lo > hi) continue;
        for (opens) |o| {
            buf[n] = .{ .lo = lo, .hi = hi, .lo_open = o[0], .hi_open = o[1] };
            n += 1;
        }
    };
    assert(n <= buf.len);
    for (buf[0..n]) |i| assert(!(i.lo > i.hi));
    return buf[0..n];
}

/// The device's value of unary `op` at `x`.
fn device1(op: Mir.Opcode, x: f64) f64 {
    return switch (op) {
        .exp => gm.exp(x),
        .expm1 => math.expm1(x),
        .ln => gm.log(x),
        .ln1p => math.log1p(x),
        .log10 => gm.log10(x),
        .sqrt => @sqrt(x),
        .sinh => math.sinh(x),
        .cosh => math.cosh(x),
        .tanh => math.tanh(x),
        .asinh => gm.asinh(x),
        .acosh => gm.acosh(x),
        .atanh => gm.atanh(x),
        .asin => math.asin(x),
        .acos => math.acos(x),
        .atan => math.atan(x),
        .sin => @sin(x),
        .cos => @cos(x),
        .floor => @floor(x),
        .ceil => @ceil(x),
        .fneg => -x,
        .fabs => @abs(x),
        .if_cast, .opt_barrier, .dstop => x,
        else => unreachable, // else: a test helper, called only with `unary_ops`
    };
}

/// Whether `x` is in the LRM domain of unary `op` (Tables 4-14/4-15).
fn inDomain1(op: Mir.Opcode, x: f64) bool {
    return switch (Mir.opcode.get(op).domain) {
        .all => true,
        .positive => x > 0,
        .gt_neg_one => x > -1,
        .non_negative => x >= 0,
        .unit_closed => -1 <= x and x <= 1,
        .unit_open => -1 < x and x < 1,
        .ge_one => x >= 1,
        .nonzero_divisor, .tan_poles, .pow_sign => unreachable, // no op in `unary_ops`
    };
}

/// The device's value of binary `op` at `(x, y)`.
fn device2(op: Mir.Opcode, x: f64, y: f64) f64 {
    return switch (op) {
        .fadd => x + y,
        .fsub => x - y,
        .fmul => x * y,
        .fdiv => x / y,
        .fmod => @rem(x, y),
        .pow => gm.pow(x, y),
        .hypot => math.hypot(x, y),
        .atan2 => gm.atan2(x, y),
        .fmin => if (x < y) x else y, // `zMinF`
        .fmax => if (x > y) x else y, // `zMaxF`
        else => unreachable, // else: a test helper, called only with `binary_ops`
    };
}

test unaryTransfer {
    const all_opens = [_][2]bool{ .{ false, false }, .{ true, false }, .{ false, true }, .{ true, true } };
    const unary_ops = [_]Mir.Opcode{ .exp, .expm1, .ln, .ln1p, .log10, .sqrt, .sinh, .cosh, .tanh, .asinh, .acosh, .atanh, .asin, .acos, .atan, .sin, .cos, .floor, .ceil, .fneg, .fabs, .if_cast, .opt_barrier, .dstop };
    // Ends where the device's rounding collapses an open bound: exp and expm1
    // underflow below about -745, tanh saturates to ±1 past about ±19.1, floor
    // and ceil are flat between integers, atan reaches ±pi/2 at ±maxFloat.
    const inf = math.inf(f64);
    const ends = [_]f64{ -inf, -800, -20, -2, -1, -0.5, 0, 0.5, 1, 2, 20, 800, inf };
    const extra = [_]f64{ -799, -19.9, -0.7, 0.7, 1.5, 2.5, 19.9, 799 };
    var ivs: [ends.len * ends.len * all_opens.len]Interval = undefined;
    var buf: [16]f64 = undefined;
    for (unary_ops) |op| for (intervals(&ends, &all_opens, &ivs)) |a| {
        const out = unaryTransfer(op, a, true);
        for (samplePoints(a, &extra, &buf)) |x| {
            const y = device1(op, x);
            if (math.isNan(y)) continue; // outside the domain: `checkDomain`'s, not the interval's
            if (!admits(out.iv, y)) {
                std.debug.print("{s} over [{d}:{d}] open {any}/{any}: f({d}) = {d} outside [{d}:{d}] open {any}/{any}\n", .{ @tagName(op), a.lo, a.hi, a.lo_open, a.hi_open, x, y, out.iv.lo, out.iv.hi, out.iv.lo_open, out.iv.hi_open });
                return error.TestUnsoundInterval;
            }
            if (out.finite and math.isFinite(x) and inDomain1(op, x)) try std.testing.expect(math.isFinite(y));
        }
    };
}

test "unaryTransfer: dstop is its operand's value (vera_nodiff, §2.9)" {
    const a: Interval = .{ .lo = 1, .hi = 2, .hi_open = true };
    const out = unaryTransfer(.dstop, a, true);
    try std.testing.expectEqual(a, out.iv);
    try std.testing.expect(out.finite);
}

test binaryTransfer {
    const binary_ops = [_]Mir.Opcode{ .fadd, .fsub, .fmul, .fdiv, .fmod, .pow, .hypot, .atan2, .fmin, .fmax };
    // 1e20 absorbs every operand below 2^14 in a sum, so an open end next to it
    // is not open after rounding.
    const inf = math.inf(f64);
    const ends = [_]f64{ -inf, -1, 0, 0.5, 1, 2, 1e20, inf };
    const opens = [_][2]bool{ .{ false, false }, .{ true, true } };
    const extra = [_]f64{ -0.7, 0.7 };
    var ivs: [ends.len * ends.len * opens.len]Interval = undefined;
    const all = intervals(&ends, &opens, &ivs);
    var xb: [8]f64 = undefined;
    var yb: [8]f64 = undefined;
    for (binary_ops) |op| for (all) |a| for (all) |b| {
        const out = binaryTransfer(op, a, b, true);
        for (samplePoints(a, &extra, &xb)) |x| for (samplePoints(b, &extra, &yb)) |y| {
            const z = device2(op, x, y);
            if (math.isNan(z)) continue; // 0/0, inf-inf, x % 0, pow(neg, frac): no value to bound
            if (!admits(out.iv, z)) {
                std.debug.print("{s}([{d}:{d}] {any}/{any}, [{d}:{d}] {any}/{any}) at ({d}, {d}) = {d} outside [{d}:{d}] {any}/{any}\n", .{ @tagName(op), a.lo, a.hi, a.lo_open, a.hi_open, b.lo, b.hi, b.lo_open, b.hi_open, x, y, z, out.iv.lo, out.iv.hi, out.iv.lo_open, out.iv.hi_open });
                return error.TestUnsoundInterval;
            }
            // Rule 3 (`proof.FloatMode`) is an axiom for `+ - * /`, and hypot
            // follows it; the other finite claims must hold outright.
            const checked = switch (op) {
                .pow => x > 0 or (x == 0 and y > 0) or (x < 0 and y == @trunc(y)),
                .fmod => y != 0,
                .atan2, .fmin, .fmax => true,
                else => false, // else: rule 3 covers every other op in `binary_ops`
            };
            if (out.finite and checked and math.isFinite(x) and math.isFinite(y)) try std.testing.expect(math.isFinite(z));
        };
    };
}

test combine {
    const out = combine(.{ .lo = -1, .hi = 2 }, .{ .lo = 3, .hi = 4 }, mulOp);
    try std.testing.expectEqual(@as(f64, -4), out.lo);
    try std.testing.expectEqual(@as(f64, 8), out.hi);
    // 0 * inf at a corner has no value: no evidence, not a narrow claim.
    try std.testing.expectEqual(Interval.top, combine(.point(0), .{ .lo = 1 }, mulOp));
}

test callAbstract {
    // §9.10 the environment is positive or non-negative, and finite.
    const t = callAbstract(.@"$temperature");
    try std.testing.expect(t.finite and t.iv.gt(0) and t.iv.excludesZero());
    const at = callAbstract(.@"$abstime");
    try std.testing.expect(at.finite and at.iv.ge(0));
    // §9.5 descriptor functions are integer-valued.
    try std.testing.expect(callAbstract(.@"$fopen").finite);
    // §3.2: an integer-valued call (`callee.ty`) is an i64, never inf or NaN.
    try std.testing.expect(callAbstract(.@"$param_given").finite);
    try std.testing.expect(callAbstract(.@"$port_connected").finite);
    try std.testing.expect(callAbstract(.@"$rtoi").finite);
    // §4.6.1 analysis() and the §5.2.1/§5.10.2 flags render as 0.0 or 1.0
    // (`codegen/call.zig`).
    for ([_]Mir.Callee{ .analysis, .initial_step, .final_step, .analog_initial }) |c| {
        const f = callAbstract(c);
        try std.testing.expect(f.finite and f.iv.ge(0) and f.iv.le(1));
    }
    // An unmodelled real call stays unknown.
    try std.testing.expect(!callAbstract(.@"$simparam").finite);
}

test "proof: random distribution names do not prove finite results" {
    for ([_][]const u8{ "$rng$uniform", "$rng$normal", "$rng$exponential", "$rng$poisson", "$rng$chi_square", "$rng$t", "$rng$erlang" }) |name|
        try std.testing.expect(!callAbstract(Mir.Callee.fromName(name)).finite);
}
