//! Emitted timer devices -> a host's accepted/rejected timepoints, VAMS
//! §5.10.3.3. The fixed device compares the static and live breakpoint hooks:
//! both describe the same schedule, so they must agree bit for bit even after
//! thousands of events. This is an ABI consistency assertion, not a claim that
//! the LRM requires exact decimal timepoints (it permits at or just beyond).
//!
//! The dynamic device changes its period at a scheduled event: 0, 2, 4 ns
//! followed by 8 and 12 ns when the period becomes 4 ns at 4 ns. Its rejection
//! test makes the same change on a discarded trial: retrying with 2 ns must
//! restore the old grid, including all hidden scheduling state.
//! device tests/verilog-a/ch05_analog_behavior/timer_fixed.va
//! device tests/verilog-a/ch05_analog_behavior/timer_dynamic.va
//! device tests/verilog-a/ch05_analog_behavior/timer_controls.va
//! device tests/verilog-a/ch05_analog_behavior/timer_body_controls.va
//! device tests/verilog-a/ch05_analog_behavior/timer_body_reg_controls.va
//! device tests/verilog-a/ch05_analog_behavior/timer_body_clog2_controls.va
//! device tests/verilog-a/ch05_analog_behavior/timer_body_array_controls.va
//! device tests/verilog-a/ch05_analog_behavior/timer_body_index_controls.va
//! device tests/verilog-a/ch05_analog_behavior/timer_body_function_controls.va
//! device tests/verilog-a/ch05_analog_behavior/timer_body_context_controls.va
//! device tests/verilog-a/ch05_analog_behavior/timer_body_array_function_controls.va
//! device tests/verilog-a/ch05_analog_behavior/timer_body_effect_controls.va
//! device tests/verilog-a/ch05_analog_behavior/timer_body_constant_effect_controls.va
//! device tests/verilog-a/ch05_analog_behavior/timer_body_precomputed_controls.va

const std = @import("std");
const contract = @import("contract");
const D = @import("device");
const n_u = @typeInfo(D.U).@"enum".field_names.len;
const S = contract.RefFamily(f64, &@as([n_u]u8, @splat(contract.no_lane)), .{});
const fixed = @hasDecl(D, "nextBreakpoint");
const controlled = @hasField(D.U, "period_ctl");
const body_controlled = @hasField(D.U, "body");

const Controls = struct { value: f64 = 0, start: f64 = 0, period: f64 = 1, enable: f64 = 1 };

const Run = struct {
    model: D.Model,
    inst: D.Instance = .{},
    state: D.State = .{},
    time: f64 = 0,
    initialized: bool = false,
    calls: f64 = 0,
    mark: f64 = 0,

    fn init(model: D.Model) Run {
        var r: Run = .{ .model = model };
        if (@hasDecl(D, "setup")) D.setup(S, &r.model);
        if (@hasDecl(D, "setupInstance")) D.setupInstance(&r.model, &r.inst);
        r.state = D.initState(&r.model, &r.inst);
        return r;
    }

    fn attempt(r: *Run, t: f64, control: f64) f64 {
        return r.attemptWith(t, .{ .value = control });
    }

    fn attemptWith(r: *Run, t: f64, control: Controls) f64 {
        var x: [n_u]f64 = @splat(0.0);
        if (comptime @hasField(D.U, "ctl")) x[@backingInt(D.U.ctl)] = control.value;
        if (comptime controlled) {
            x[@backingInt(D.U.start_ctl)] = control.start;
            x[@backingInt(D.U.period_ctl)] = control.period;
            x[@backingInt(D.U.enable_ctl)] = control.enable;
        }
        const sim: contract.SimState = .{
            .t = t,
            .dt = t - r.time,
            .kind = if (r.initialized) .tran else .dc,
            .initial_step = !r.initialized,
            .analog_initial = !r.initialized,
        };
        const residual = D.eval(S, &x, &r.model, &r.inst, sim);
        if (comptime @hasField(D.U, "calls")) {
            r.calls = residual[@backingInt(D.U.calls)].v;
            r.mark = residual[@backingInt(D.U.mark)].v;
        }
        if (comptime body_controlled) std.debug.assert(residual[@backingInt(D.U.body)].v == residual[@backingInt(D.U.out)].v);
        _ = D.updateState(S, &r.model, &r.inst, x, &r.state, sim);
        return residual[@backingInt(D.U.out)].v;
    }

    fn accept(r: *Run, t: f64, control: f64) f64 {
        return r.acceptWith(t, .{ .value = control });
    }

    fn acceptWith(r: *Run, t: f64, control: Controls) f64 {
        const count = r.attemptWith(t, control);
        _ = D.stateCtl(&r.model, &r.inst, &r.state, .commit);
        r.time = t;
        r.initialized = true;
        return count;
    }
};

test "§5.10.3.3 live and static periodic schedules do not accumulate drift" {
    if (comptime !fixed) return error.SkipZigTest;
    var r = Run.init(.{ .start = 2e-6, .period = 1e-3 });
    try std.testing.expectEqual(0.0, r.accept(0, 0));
    // The historical failure appeared around 19 ms. This host follows the
    // public schedule through 4 s and observes every event through eval.
    for (0..4096) |i| {
        const want = D.nextBreakpoint(&r.model, r.time).?;
        const got = D.pendingBreakpoint(&r.inst, r.time).?;
        try std.testing.expectEqual(want, got);
        try std.testing.expectEqual(@as(f64, @floatFromInt(i + 1)), r.accept(got, 0));
    }
}

test "§5.10.3.3 small periods retain a representable future breakpoint" {
    if (comptime !fixed) return error.SkipZigTest;
    const epsilon = std.math.floatEps(f64);
    for ([_]f64{ epsilon, epsilon / 16, 1e-320 }) |period| {
        var r = Run.init(.{ .start = 1, .period = period });
        try std.testing.expectEqual(0.0, r.accept(0, 0));
        try std.testing.expectEqual(1.0, r.accept(1, 0));
        for (0..16) |i| {
            const want = std.math.nextAfter(f64, r.time, std.math.inf(f64));
            // There is at least one real event between consecutive f64 times.
            // The next representable time is at/just beyond that event; none
            // may be returned at or before the host's current time.
            const future = D.nextBreakpoint(&r.model, r.time);
            try std.testing.expect(future != null);
            try std.testing.expectEqual(want, future.?);
            try std.testing.expectEqual(future, D.pendingBreakpoint(&r.inst, r.time));
            try std.testing.expectEqual(@as(f64, @floatFromInt(i + 2)), r.accept(future.?, 0));
        }
    }
}

test "§5.10.3.3 a periodic origin before zero keeps its absolute phase" {
    if (comptime !fixed) return error.SkipZigTest;
    var r = Run.init(.{ .start = -1, .period = 2 });
    // Only the -1 second event is past: subsequent multiples are 1 and 3,
    // rather than the 0,2,4 grid produced by clamping the origin to zero.
    try std.testing.expectEqual(0.0, r.accept(0, 0));
    for ([_]f64{ 1, 3 }, 0..) |want, k| {
        try std.testing.expectEqual(want, D.nextBreakpoint(&r.model, r.time).?);
        try std.testing.expectEqual(want, D.pendingBreakpoint(&r.inst, r.time).?);
        try std.testing.expectEqual(@as(f64, @floatFromInt(k + 1)), r.accept(want, 0));
    }
}

test "§5.10.3.3 an exhausted finite-time schedule has no future breakpoint" {
    if (comptime !fixed) return error.SkipZigTest;
    const max = std.math.floatMax(f64);
    for ([_]D.Model{
        .{ .start = 1, .period = 0 },
        .{ .start = 1, .period = -1 },
        .{ .start = 0.75 * max, .period = max },
    }) |model| {
        try std.testing.expectEqual(@as(?f64, null), D.nextBreakpoint(&model, model.start));
    }
    const tiny: D.Model = .{ .start = 1, .period = 1e-320 };
    try std.testing.expectEqual(@as(?f64, null), D.nextBreakpoint(&tiny, max));
}

test "§5.10.3.3 changed period at a common grid point" {
    if (comptime fixed or controlled or body_controlled) return error.SkipZigTest;
    var r = Run.init(.{});
    const p = r.model.period;
    try std.testing.expectEqual(1.0, r.accept(0, 0));
    try std.testing.expectEqual(2.0, r.accept(p, 0));
    try std.testing.expectEqual(3.0, r.accept(2 * p, 1));
    const next = D.pendingBreakpoint(&r.inst, r.time).?;
    try std.testing.expectEqual(4 * p, next);
    try std.testing.expectEqual(3.0, r.accept(3 * p, 1));
    try std.testing.expectEqual(4.0, r.accept(next, 1));
    try std.testing.expectEqual(6 * p, D.pendingBreakpoint(&r.inst, r.time).?);
}

test "§5.10.3.3 a rejected period change restores the schedule" {
    if (comptime fixed or controlled or body_controlled) return error.SkipZigTest;
    var r = Run.init(.{});
    const p = r.model.period;
    _ = r.accept(0, 0);
    _ = r.accept(p, 0);
    const accepted_inst = r.inst;
    const accepted_state = r.state;
    try std.testing.expectEqual(3.0, r.attempt(2 * p, 1));
    try std.testing.expectEqual(4 * p, D.pendingBreakpoint(&r.inst, 2 * p).?);
    _ = D.stateCtl(&r.model, &r.inst, &r.state, .revert);
    try std.testing.expectEqualDeep(accepted_inst, r.inst);
    try std.testing.expectEqualDeep(accepted_state, r.state);
    try std.testing.expectEqual(3.0, r.accept(2 * p, 0));
    try std.testing.expectEqual(3 * p, D.pendingBreakpoint(&r.inst, r.time).?);
}

test "§5.10.3.3 between-fire changes replace the absolute grid before delivery" {
    if (comptime !controlled) return error.SkipZigTest;
    var r = Run.init(.{});
    const p = r.model.period;
    try std.testing.expectEqual(1.0, r.acceptWith(0, .{}));
    try std.testing.expectEqual(2.0, r.acceptWith(p, .{}));
    // At 4 ns the latest period becomes 3 ns BEFORE the event test. Four is
    // not on 0 + k*3, so the obsolete event is canceled; the next is 6 ns.
    try std.testing.expectEqual(2.0, r.acceptWith(2 * p, .{ .period = 1.5 }));
    try std.testing.expectEqual(3 * p, D.pendingBreakpoint(&r.inst, r.time).?);
    try std.testing.expectEqual(3.0, r.acceptWith(3 * p, .{ .period = 1.5 }));
    // At 7 ns extend to a 5 ns period: latest grid 0,5,10,..., next 10.
    try std.testing.expectEqual(3.0, r.acceptWith(3.5 * p, .{ .period = 2.5 }));
    try std.testing.expectEqual(5 * p, D.pendingBreakpoint(&r.inst, r.time).?);
    // At 8 ns shorten to 2 ns: now IS on the new grid, so it fires now.
    try std.testing.expectEqual(4.0, r.acceptWith(4 * p, .{}));
    try std.testing.expectEqual(5 * p, D.pendingBreakpoint(&r.inst, r.time).?);
}

test "§5.10.3.3 disable and re-enable preserve the running absolute grid" {
    if (comptime !controlled) return error.SkipZigTest;
    var r = Run.init(.{});
    const p = r.model.period;
    try std.testing.expectEqual(0.0, r.acceptWith(0, .{ .start = 0.5 }));
    try std.testing.expectEqual(1.0, r.acceptWith(0.5 * p, .{ .start = 0.5 }));
    try std.testing.expectEqual(1.0, r.acceptWith(1.5 * p, .{ .start = 0.5, .enable = 0 }));
    try std.testing.expectEqual(1.0, r.acceptWith(2 * p, .{ .start = 0.5 }));
    const next = D.pendingBreakpoint(&r.inst, r.time).?;
    try std.testing.expectEqual(0.5 * p + 2 * p, next);
    try std.testing.expectEqual(2.0, r.acceptWith(next, .{ .start = 0.5 }));
}

test "§5.10.3.3 solved non-positive periods are one-shots and can be rearmed" {
    if (comptime !controlled) return error.SkipZigTest;
    var r = Run.init(.{});
    const p = r.model.period;
    try std.testing.expectEqual(0.0, r.acceptWith(0, .{ .start = -1, .period = -1 }));
    try std.testing.expectEqual(@as(?f64, null), D.pendingBreakpoint(&r.inst, 0));
    try std.testing.expectEqual(0.0, r.acceptWith(p, .{ .start = 2, .period = 0 }));
    try std.testing.expectEqual(2 * p, D.pendingBreakpoint(&r.inst, p).?);
    try std.testing.expectEqual(1.0, r.acceptWith(2 * p, .{ .start = 2, .period = 0 }));
    try std.testing.expectEqual(@as(?f64, null), D.pendingBreakpoint(&r.inst, 2 * p));
    // A changed start can be NOW; a spent past start cannot.
    try std.testing.expectEqual(2.0, r.acceptWith(3 * p, .{ .start = 3, .period = 0 }));
    try std.testing.expectEqual(2.0, r.acceptWith(4 * p, .{ .start = 2, .period = -1 }));
}

test "§5.10.3.3 an event-body change schedules from its final value exactly once" {
    if (comptime !body_controlled) return error.SkipZigTest;
    var r = Run.init(.{});
    const p = r.model.period;
    try std.testing.expectEqual(1.0, r.accept(0, 0));
    // Every form (scalar, array, function and precomputed effect) must roll
    // back its changed dependencies together with the timer's pending event.
    try std.testing.expectEqual(2.0, r.attempt(p, 0));
    _ = D.stateCtl(&r.model, &r.inst, &r.state, .revert);
    try std.testing.expectEqual(p, D.pendingBreakpoint(&r.inst, r.time).?);
    try std.testing.expectEqual(2.0, r.accept(p, 0));
    const next = D.pendingBreakpoint(&r.inst, r.time).?;
    try std.testing.expectEqual(1.5 * p, next);
    try std.testing.expectEqual(3.0, r.accept(next, 0));
    try std.testing.expectEqual(3 * p, D.pendingBreakpoint(&r.inst, r.time).?);
}

test "§5.10.3.3 final function dependencies retain host parameter overrides" {
    if (comptime !@hasField(D.Model, "gain")) return error.SkipZigTest;
    var r = Run.init(.{ .period = 4e-9, .gain = 2 });
    // period*gain begins at 8 ns. The second body's rate=1.5 makes the
    // latest absolute grid 0,12,24 ns, retaining the delivered 8 ns event.
    try std.testing.expectEqual(1.0, r.accept(0, 0));
    try std.testing.expectEqual(8e-9, D.pendingBreakpoint(&r.inst, 0).?);
    try std.testing.expectEqual(2.0, r.accept(8e-9, 0));
    const next = D.pendingBreakpoint(&r.inst, r.time).?;
    try std.testing.expectApproxEqAbs(12e-9, next, 1e-23);
    try std.testing.expectEqual(3.0, r.accept(next, 0));
    try std.testing.expectApproxEqAbs(24e-9, D.pendingBreakpoint(&r.inst, r.time).?, 1e-23);
}

test "§4.7.2.3/.4 final timer controls do not repeat output or inout effects, including retries" {
    if (comptime !@hasField(D.U, "calls")) return error.SkipZigTest;
    var r = Run.init(.{});
    const p = r.model.period;
    try std.testing.expectEqual(1.0, r.accept(0, 0));
    try std.testing.expectEqual(1.0, r.calls);
    try std.testing.expectEqual(101.0, r.mark);
    try std.testing.expectEqual(2.0, r.attempt(p, 0));
    try std.testing.expectEqual(2.0, r.calls);
    try std.testing.expectEqual(102.0, r.mark);
    _ = D.stateCtl(&r.model, &r.inst, &r.state, .revert);
    try std.testing.expectEqual(2.0, r.accept(p, 0));
    try std.testing.expectEqual(2.0, r.calls);
    try std.testing.expectEqual(102.0, r.mark);
    const next = D.pendingBreakpoint(&r.inst, r.time).?;
    try std.testing.expectEqual(1.5 * p, next);
    try std.testing.expectEqual(3.0, r.accept(next, 0));
    try std.testing.expectEqual(3.0, r.calls);
    try std.testing.expectEqual(103.0, r.mark);
}
