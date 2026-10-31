//! §4.5 analog operators, §5.10.3 monitored events and §9.17 kernel control:
//! the operator set and the facts every stage reads about it (`acDynamic`,
//! `needsInput`, `enableArg`), one exhaustive switch each. The callee →
//! `OpKind` mapping is `callee.opKind`; the backend's per-operator rows
//! (`Instance` fields, `dt`) are `src/codegen/device/codegen/op_zig.zig`, a table total
//! over this enum.
//!
//! Cites: §4.5.4, §4.5.5, §4.5.7, §4.5.8, §4.5.9, §4.5.10, §4.5.11, §4.5.12,
//! §4.5.13, §4.5.14, §5.10.3.1, §9.17.1, §9.17.2.
//!
//! Contents:
//! - `pub const OpKind = enum(u8)`
//! - `pub fn acDynamic(k: OpKind) bool`
//! - `pub fn needsInput(k: OpKind) bool`
//! - `pub fn enableArg(k: OpKind) ?u8`

const std = @import("std");
const assert = std.debug.assert;

/// Every operator that owns per-instance state or a monitored event.
/// `names.enumerateUnits` gives each occurrence of one a unit; `.none` is the
/// answer for every other `call` callee.
///
/// §4.5.13 `limexp` and §4.5.14 `ddx` are not here: they are pure functions of
/// their argument, so they own no state and get no unit.
pub const OpKind = enum(u8) {
    none,
    idt_hold, // §4.5.4 assert
    idtmod, // §4.5.5
    absdelay, // §4.5.7
    transition, // §4.5.8
    slew, // §4.5.9
    last_crossing, // §4.5.10
    laplace, // §4.5.11
    zi, // §4.5.12
    cross, // §5.10.3
    above, // §5.10.3
    timer, // §5.10.3
    bound_step, // §9.17.2
    discontinuity, // §9.17.1
};

/// Returns whether the operator's small-signal response depends on frequency:
/// §4.5.7 `absdelay` is e^(−jω·td), §4.5.11 `laplace_*` is H(jω) and §4.5.12
/// `zi_*` is H(e^(jωT)). Every other operator is flat in ω (§4.5.8
/// `transition` is unity, §4.5.9 `slew` 1 or 0) or has no small-signal path.
pub fn acDynamic(k: OpKind) bool {
    const dynamic = switch (k) {
        .absdelay, .laplace, .zi => true,
        .none, .idt_hold, .idtmod, .transition, .slew, .last_crossing, .cross, .above, .timer, .bound_step, .discontinuity => false,
    };
    // A frequency-dependent response is a response to the input.
    if (dynamic) assert(needsInput(k));
    return dynamic;
}

/// Returns whether the operator's kernel reads the current input rather than
/// answering from `Instance` alone. `emitOperator` and `UnitPlan.analyze`
/// both read this, so they agree.
///
/// `cross` and `timer` compare the current input (`timer`: its `start_time`)
/// against `__prev` in `eval` (§5.10.3). `zi` needs it for the §4.5.12 static
/// branch. `absdelay` needs it for the §4.5.7 DC pass-through and for a delay
/// shorter than the accepted step. §4.5.10 `last_crossing` compares it as
/// `cross` does, to report a crossing inside the step being evaluated, and the
/// §9.17 requests evaluate their own argument.
pub fn needsInput(k: OpKind) bool {
    const needs = switch (k) {
        .idt_hold, .idtmod, .absdelay, .transition, .slew, .last_crossing, .laplace, .zi, .cross, .above, .timer => true,
        .none, .bound_step, .discontinuity => false,
    };
    if (k == .none) assert(!needs);
    return needs;
}

/// Returns the index of the §5.10.3 `enable` argument, or null: the one
/// control argument that stays a runtime expression, so `UnitPlan` keeps it
/// live while every other control argument folds at codegen time. `?u8`, the
/// narrowest type the range allows.
pub fn enableArg(k: OpKind) ?u8 {
    const arg: ?u8 = switch (k) {
        .cross => 4, // cross(expr, dir, time_tol, expr_tol, enable)
        .above => 3, // above(expr, time_tol, expr_tol, enable)
        .timer => 3, // timer(start, period, time_tol, enable)
        .none, .idt_hold, .idtmod, .absdelay, .transition, .slew, .last_crossing, .laplace, .zi, .bound_step, .discontinuity => null,
    };
    // Only a §5.10.3 event takes an `enable`, and it reads its input.
    if (arg != null) assert(needsInput(k));
    return arg;
}

test needsInput {
    // §4.5.10 `last_crossing` and §5.10.3.1 `cross` compare the current input
    // against the previous one; §9.17.2 `$bound_step` evaluates its own.
    try std.testing.expect(needsInput(.last_crossing));
    try std.testing.expect(needsInput(.cross));
    try std.testing.expect(needsInput(.absdelay));
    try std.testing.expect(!needsInput(.bound_step));
}

test enableArg {
    // An `enable` is the LAST argument of the three §5.10.3 forms; nothing
    // else has one.
    try std.testing.expectEqual(@as(?u8, 4), enableArg(.cross));
    try std.testing.expectEqual(@as(?u8, 3), enableArg(.above));
    try std.testing.expectEqual(@as(?u8, 3), enableArg(.timer));
    for (std.enums.values(OpKind)) |k| {
        if (enableArg(k) != null) try std.testing.expect(k == .cross or k == .above or k == .timer);
    }
}

test acDynamic {
    // §4.5.7 e^(−jω·td), §4.5.11 H(jω) and §4.5.12 H(e^(jωT)) vary with ω.
    try std.testing.expect(acDynamic(.absdelay) and acDynamic(.laplace) and acDynamic(.zi));
    // §4.5.8 `transition` is unity in small signal and §4.5.9 `slew` 1 or 0;
    // the events and §9.17 tasks have no small-signal path at all.
    for ([_]OpKind{ .none, .transition, .slew, .idt_hold, .idtmod, .cross, .timer, .bound_step }) |k|
        try std.testing.expect(!acDynamic(k));
}
