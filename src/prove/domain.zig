//! Domain proofs: one instruction and its operands' intervals in, whether
//! its LRM domain (Tables 4-14/4-15, §4.2.4) is proven out, with a coded
//! error for a provably outside argument (E0601-E0607, E0609) and W0653 for
//! an integer `/` whose divisor may be zero. LRM §4.3.2: "Input values outside
//! of the valid range for the operator shall report an error." That obliges
//! reporting a value that is out of range, not rejecting a program whose
//! values might be, so the check is three-way:
//!
//!   provably outside the domain -> compile error
//!   provably inside             -> true, may stay `.optimized`
//!   straddles or unprovable     -> accepted, false: the result is not finite
//!                                  and its unit goes `.strict`
//!
//! This keeps VerA's accepted set equal to the LRM's: interval arithmetic
//! cannot decide `x = V/(1+abs(V))` (it would have to correlate two
//! occurrences of V), so a two-way check would reject legal models.
//!
//! LRM clauses this file's code cites: §4.2.1.2, §4.2.4, §4.3.1, §4.3.2.
//! IEEE 1364-2005 clauses cited: §5.1.5.
//!
//! Contents:
//! - `pub const Error = Allocator.Error`
//! - `pub fn check(p: *Prover, inst: Mir.Inst) Error!bool`

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const diag = @import("diag");
const Interval = @import("Interval.zig");
const Prover = @import("Prover.zig");
const message = @import("message.zig");

/// Fails only on allocation, in the arena or the diagnostics bag.
pub const Error = Allocator.Error;

/// Returns true when `inst`'s domain is proven or it has none; reports a
/// provable violation and returns false; returns false, silently, when the
/// domain is unprovable. Asserts that the fact environment is built.
pub fn check(p: *Prover, inst: Mir.Inst) Error!bool {
    assert(p.civ.len != 0 or p.an.nv == 0);
    const op = p.mir.instOp(inst);
    const dom = Mir.opcode.get(op).domain;
    const errors_before = p.error_count;
    const proven = switch (dom) {
        .all => true,
        .nonzero_divisor => try divisor(p, inst, op),
        .pow_sign => try powSign(p, inst),
        .tan_poles => tanPoles(p, inst),
        .positive, .gt_neg_one, .non_negative, .unit_closed, .unit_open, .ge_one => try unaryDomain(p, inst, op, dom),
    };
    if (proven) assert(p.error_count == errors_before); // a proof reports nothing
    return proven;
}

// ---- private ----

/// Integer `/`, and `%` of either type (§4.2.4). "It shall be an error to
/// pass zero (0) as the second argument to the modulus operator" applies when
/// the divisor is zero, so a provably-zero divisor is E0601 and an unprovable
/// one is accepted and forfeits `finite`:
///   - real `%`: `zFmod` reports E0601 at execution (or traps in a solver
///     device), as the integer `%` does;
///   - integer `/`: codegen guards it (`render.zig`'s `.idiv`), since
///     `@divTrunc(i64, 0)` is illegal behavior in Zig, and a zero divisor
///     yields 0, which W0653 announces;
///   - integer `%`: codegen reports E0601 at execution, without evaluating
///     Zig's `%` by zero.
fn divisor(p: *Prover, inst: Mir.Inst, op: Mir.Opcode) Error!bool {
    assert(Mir.opClass(op) == .binary);
    assert(op == p.mir.instOp(inst));
    const d = p.mir.instData(inst).binary;
    const y = p.ivOf(d.rhs);
    if (y.excludesZero() or y.isEmpty()) return true;
    const what = if (op == .fmod or op == .imod) "`%` divisor" else "`/` divisor";
    if (y.lo == 0 and y.hi == 0)
        return violated(p, inst, .E0601, what, d.rhs, y, "is provably zero", "a zero divisor is an error (§4.2.4); check the expression or the parameter's range");
    // Legal, but not silent: the guarded device division yields 0 for a zero
    // divisor, a value the LRM does not give.
    if (op == .idiv) try warnIntDivisor(p, inst, d.rhs, y);
    return false;
}

/// §4.3.1 Table 4-14. The two provable violations (E0609) are held to the
/// same three-way standard as E0602-E0607: reject only when every admitted
/// value pair violates.
fn powSign(p: *Prover, inst: Mir.Inst) Error!bool {
    assert(Mir.opClass(p.mir.instOp(inst)) == .binary);
    const d = p.mir.instData(inst).binary;
    const x = p.ivOf(d.lhs);
    const y = p.ivOf(d.rhs);
    if (x.isEmpty() or y.isEmpty()) return true;
    if (x.gt(0)) return true; // x > 0, all y
    if (x.ge(0) and y.gt(0)) return true; // x = 0, y > 0
    // x == 0 always, y < 0 always: pow is +inf on every execution ("if x =
    // 0, all y > 0"). Checked before the integer-exponent accept, whose
    // clause is the x < 0 row and does not rescue a zero base. (y = 0 is left
    // alone: IEEE pow(0,0) = 1, the leniency `x/0.0` gets.)
    if (x.lo == 0 and x.hi == 0 and !x.nonzero and y.lt(0))
        return violated(p, inst, .E0609, "pow() exponent", d.rhs, y, "must be >= 0 — the base is provably zero", "constrain the exponent with `from [0:inf)`, or the base with `exclude 0`");
    if (provablyInteger(p, d.rhs)) return true; // x < 0, integer y
    // x < 0 always, y fractional always: pow is NaN on every execution ("if
    // x < 0, all integer y").
    if (x.lt(0) and provablyNonInteger(y))
        return violated(p, inst, .E0609, "pow() exponent", d.rhs, y, "must be an integer — the base is provably negative", "use `pow(abs(x), y)` with an explicit sign, or constrain the base with `from [0:inf)`");
    // Straddling either clause is NaN-capable but not provably violating:
    // IEEE-defined under `.strict`, so accept and forfeit finiteness.
    return false;
}

/// §4.3.2 tan: x != n(pi/2), n odd. No reject arm: the poles are irrational
/// and every double is rational, so even a point interval is never provably
/// at one. Unprovable -> `.strict`, where a pole yields an IEEE infinity.
fn tanPoles(p: *const Prover, inst: Mir.Inst) bool {
    assert(Mir.opClass(p.mir.instOp(inst)) == .unary);
    const a = p.ivOf(p.mir.instData(inst).unary.operand);
    if (a.isEmpty()) return true;
    if (!a.bounded()) return false;
    // The pole-free branch containing a.lo is (k*pi - pi/2, k*pi + pi/2).
    // The f64 pole is exact to ~1 ulp; a model running that close to a tan
    // pole is not proven, which is the conservative direction.
    const k = @floor((a.lo + math.pi / 2.0) / math.pi);
    const lo_pole = k * math.pi - math.pi / 2.0;
    const hi_pole = k * math.pi + math.pi / 2.0;
    return a.gt(lo_pole) and a.lt(hi_pole);
}

/// The one-argument domains of Table 4-15. Each arm: proven inside -> true;
/// proven outside -> report, false; straddling -> false, no diagnostic.
fn unaryDomain(p: *Prover, inst: Mir.Inst, op: Mir.Opcode, dom: Mir.opcode.Domain) Error!bool {
    assert(Mir.opClass(op) == .unary);
    assert(Mir.opcode.get(op).domain == dom);
    const d = p.mir.instData(inst).unary;
    const a = p.ivOf(d.operand);
    if (a.isEmpty()) return true;
    const name = Mir.opcode.label(op);
    return switch (dom) {
        .positive => if (a.gt(0)) true else if (a.le(0))
            violated(p, inst, .E0602, name, d.operand, a, "must be > 0", "add a range like `from (0:inf)` to the parameter, or guard the call with `if (x > 0)`")
        else
            false,
        .gt_neg_one => if (a.gt(-1)) true else if (a.le(-1))
            violated(p, inst, .E0603, name, d.operand, a, "must be > -1", "add a range like `from (-1:inf)` to the parameter, or guard the call with `if (x > -1)`")
        else
            false,
        .non_negative => if (a.ge(0)) true else if (a.lt(0))
            violated(p, inst, .E0604, name, d.operand, a, "must be >= 0", "add a range like `from [0:inf)` to the parameter, or write `sqrt(abs(x))` if magnitude is what the model means")
        else
            false,
        .unit_closed => if (a.ge(-1) and a.le(1)) true else if (a.gt(1) or a.lt(-1))
            violated(p, inst, .E0605, name, d.operand, a, "must satisfy -1 <= x <= 1", "add a range like `from [-1:1]` to the parameter, or clamp with `min`/`max` before the call")
        else
            false,
        .unit_open => if (a.gt(-1) and a.lt(1)) true else if (a.ge(1) or a.le(-1))
            violated(p, inst, .E0606, name, d.operand, a, "must satisfy -1 < x < 1", "add a range like `from (-1:1)` to the parameter — round brackets exclude the poles")
        else
            false,
        .ge_one => if (a.ge(1)) true else if (a.lt(1))
            violated(p, inst, .E0607, name, d.operand, a, "must be >= 1", "add a range like `from [1:inf)` to the parameter, or guard the call")
        else
            false,
        .all, .nonzero_divisor, .pow_sign, .tan_poles => unreachable, // `check` routes these elsewhere
    };
}

/// §4.3.1 Table 4-14's E0609 direction: the exponent interval fits inside
/// one integer-free open cell (k, k+1), so every value it admits is
/// fractional. The failure mode is "not provable", which keeps a
/// possibly-integer exponent on the accept-as-`.strict` path.
fn provablyNonInteger(iv: Interval) bool {
    const fractional = iv.bounded() and @floor(iv.lo) == @floor(iv.hi) and iv.lo != @floor(iv.lo);
    if (fractional) assert(iv.hi != @floor(iv.hi) or iv.hi < iv.lo); // no integer end either
    return fractional;
}

/// §4.3.1 pow with a negative base needs "all integer y".
fn provablyInteger(p: *const Prover, v: Mir.Value) bool {
    switch (p.mir.valueDef(p.an.rv(v))) {
        .int_const => return true,
        .float_const => |c| return math.isFinite(c) and c == @trunc(c),
        .param_ref => |pi| return pi < p.lowered.params.items.len and
            p.lowered.params.items[pi].ty == .integer,
        // §4.2.1.2 integer→real conversion preserves integrality.
        .inst_result => |inst| {
            const op = p.mir.instOp(inst);
            return Mir.opIsInteger(op) or op == .if_cast;
        },
        .undef, .str_const, .block_param => return false,
    }
}

/// Reports a provably out-of-domain argument (§4.3.2) and returns false, so
/// the caller clears `finite`. `requirement` is the text beside the caret;
/// the rule and citation live in the code catalogue.
fn violated(
    p: *Prover,
    inst: Mir.Inst,
    code: diag.Code,
    what: []const u8,
    operand: Mir.Value,
    iv: Interval,
    requirement: []const u8,
    fix: []const u8,
) Error!bool {
    assert(requirement.len != 0);
    assert(fix.len != 0);
    var b = try message.violation(p, inst, code, operand, iv, what);
    b.point("{s}", .{requirement});
    b.help("{s}", .{fix});
    try message.emitError(p, &b);
    return false;
}

/// W0653: an integer `/` whose divisor the prover cannot show nonzero.
/// Accepted (§4.2.4 has no zero rule for `/`), but the device's guarded
/// division yields 0 where IEEE 1364 §5.1.5 would yield `x`, which an analog
/// integer cannot hold. Does not touch `error_count`.
fn warnIntDivisor(p: *Prover, inst: Mir.Inst, divisor_v: Mir.Value, iv: Interval) Error!void {
    if (!p.bag.enabled(.W0653)) return;
    const errors_before = p.error_count;
    var b = try message.violation(p, inst, .W0653, divisor_v, iv, "integer `/` divisor");
    b.point("cannot be proven non-zero; if it is zero at run time the result is 0", .{});
    b.help("give the parameter `exclude 0` or `from [1:inf)`, guard the division with an `if` the prover can see, or pass `--allow=W0653`", .{});
    try b.emit();
    assert(p.error_count == errors_before);
}
