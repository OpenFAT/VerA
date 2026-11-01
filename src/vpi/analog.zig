//! The analog point the routines answer for: the analysis running, its
//! time, step and frequency, and which `Binding` is bound; plus the device
//! library's C interface (`Lib`) and the analyses a host runs.
//! Cites: VAMS-2023 §12.7-§12.9, §12.18, §12.36; §5.10.3.3.
//!
//! Contents:
//! - `pub const Lib = struct`
//! - `pub const HostCall = *const fn (?*anyopaque, usize, usize, [*]const f64, usize...`
//! - `pub const HostOut = *const fn (?*anyopaque, usize, usize, usize, [*]const f64...`
//! - `pub const Kind = enum`
//! - `pub const Analysis = struct`
//! - `pub var active: ?*Binding`
//! - `pub var installed: ?*Binding`
//! - `pub var current: ?Analysis`
//! - `pub var t_now: f64`
//! - `pub var delta: f64`
//! - `pub var freq: f64`
//! - `pub const Error = error`
//! - `pub const OneCall = struct`
//! - `pub fn OneCall.zero() callconv(.c) usize`
//! - `pub const OneCall.lib: Lib`
//! - `pub fn OneCall.design(full: []const u8) !Design`
//! - `pub fn kindOrdinal(k: Kind) u8`
//! - `pub fn bound() ?*Binding`
//! - `pub fn enter(b: *Binding) ?*Binding`
//! - `pub fn leave(b: *Binding, prev: ?*Binding) void`
//! - `pub fn rejectStep() bool`
//! - `pub fn failConverge() bool`
//! - `pub fn setPoint(a: ?Analysis, t: f64, dt: f64, f: f64) void`
//! - `pub fn analysis() ?Analysis`
//! - `pub fn time() f64`
//! - `pub fn acceptedTime() f64`
//! - `pub fn sameTime(a: f64, b: f64) bool`

const std = @import("std");
const analog_call = @import("analog_call.zig");
const analog_value = @import("analog_value.zig");
const session = @import("session.zig");
const status = @import("status.zig");
const systf = @import("systf.zig");
const trust = @import("trust.zig");
const user = @import("vpi_user.zig");
const Binding = @import("Binding.zig");
const Design = @import("Design.zig");
const abi = @import("abi.zig");
const schema = @import("schema.zig");
const AnalogSystfData = abi.AnalogSystfData;
const AnalogValue = abi.AnalogValue;
const CbData = abi.CbData;
const Cold = schema.Cold;
const List = schema.List;
const Obj = schema.Obj;

/// `tb.renderVpiLib`'s C interface.
pub const Lib = struct {
    open: *const fn (u8) callconv(.c) void,
    solve: *const fn (f64, f64, bool, bool) callconv(.c) bool,
    accept: *const fn () callconv(.c) void,
    x: *const fn () callconv(.c) [*]const f64,
    n_u: *const fn () callconv(.c) usize,
    n_rows: *const fn () callconv(.c) usize,
    row: *const fn (usize, *[4]i32) callconv(.c) void,
    rows: *const fn ([*]f64) callconv(.c) void,
    n_shares: *const fn () callconv(.c) usize,
    shares: *const fn ([*]f64) callconv(.c) void,
    /// Hands the library the hop its `contract.SystfHost` forwards through,
    /// and the `ctx` (the `Binding`) to pass back first.
    systf: *const fn (?*anyopaque, ?HostCall, ?HostOut) callconv(.c) void,
    n_systf: *const fn () callconv(.c) usize,
    systf_name: *const fn (usize, *usize) callconv(.c) [*]const u8,
    systf_tok: *const fn (usize) callconv(.c) u32,
    systf_outs: *const fn (usize) callconv(.c) u64,
    ac: *const fn (f64, [*]f64, [*]f64) callconv(.c) bool,
    /// §5.10.3.3 the device's next timer instant after `t`, or inf: "the
    /// analog simulator places a time point within time_tol of an event".
    breakpoint: *const fn (f64) callconv(.c) f64,
    /// The `x` index of the unknown named so, or -1 (a mixed design's
    /// digital probes, §7.3.3).
    node: *const fn ([*]const u8, usize) callconv(.c) isize,
};

/// The C function the library forwards `contract.SystfHost.call` to:
/// `(ctx, inst, k, args, n, partials)`, `Binding.call` across a C ABI. `ctx`
/// is the one `Lib.systf` handed over; `inst` the host's instance of the
/// device (any value unique per instance, a key and nothing else).
pub const HostCall = *const fn (?*anyopaque, usize, usize, [*]const f64, usize, [*]f64) callconv(.c) f64;

/// The C function the library forwards `contract.SystfHost.out` to:
/// `(ctx, inst, k, j, args, n, partials)`, `Binding.output` across a C ABI.
pub const HostOut = *const fn (?*anyopaque, usize, usize, usize, [*]const f64, usize, [*]f64) callconv(.c) f64;

/// The analyses a host can run: a DC operating point, a transient, or a
/// small-signal AC sweep around an operating point.
pub const Kind = enum { op, tran, ac };

/// One `analysis` line: §12.18's vpiStartTime/vpiEndTime/vpiTransientMaxStep
/// and vpiStartFrequency/vpiEndFrequency are its fields. An AC sweep takes
/// `points` frequencies, evenly spaced from `fstart` to `fstop`.
pub const Analysis = struct {
    kind: Kind,
    start: f64 = 0,
    stop: f64 = 0,
    max_step: f64 = 0,
    fstart: f64 = 0,
    fstop: f64 = 0,
    points: u32 = 1,
};

/// The binding whose call or walk is running (`enter`), else null.
pub var active: ?*Binding = null;

/// The binding attached to the installed design, which the routines answer
/// for outside any call or walk (a cbEndOfSimulation reading a value after
/// VerA's walk); null when none is.
pub var installed: ?*Binding = null;

/// The analysis running, or null between analyses.
pub var current: ?Analysis = null;

/// The time of the solution being attempted, or of the latest accepted one.
pub var t_now: f64 = 0;

/// The step being attempted, or the one the accepted solution was reached by.
pub var delta: f64 = 0;

/// §12.8 the frequency of the small-signal solution an AC sweep stands on,
/// 0 elsewhere (its operating point included).
pub var freq: f64 = 0;

/// `Binding.run`'s failures: `NoLibrary`, not attached; `BackupExhausted`,
/// see `run`; `Singular`, an AC point whose small-signal system has no
/// solution. A solve that does not converge is no error: `attempt` discards
/// `Lib.solve`'s result.
pub const Error = error{ NoLibrary, BackupExhausted, Singular };

/// A calls-only library (#83's stub) of one call, `$c` at source token 5,
/// whose argument 1 the device reads back.
pub const OneCall = struct {
    const none = [0]f64{};
    fn open(_: u8) callconv(.c) void {}
    fn solve(_: f64, _: f64, _: bool, _: bool) callconv(.c) bool {
        return true;
    }
    fn accept() callconv(.c) void {}
    fn x() callconv(.c) [*]const f64 {
        return &none;
    }
    pub fn zero() callconv(.c) usize {
        return 0;
    }
    fn one() callconv(.c) usize {
        return 1;
    }
    fn row(_: usize, _: *[4]i32) callconv(.c) void {}
    fn rows(_: [*]f64) callconv(.c) void {}
    fn hooks(_: ?*anyopaque, _: ?HostCall, _: ?HostOut) callconv(.c) void {}
    fn name(_: usize, len: *usize) callconv(.c) [*]const u8 {
        len.* = 2;
        return "$c";
    }
    fn tok(_: usize) callconv(.c) u32 {
        return 5;
    }
    fn readBack(_: usize) callconv(.c) u64 {
        return 1;
    }
    fn ac(_: f64, _: [*]f64, _: [*]f64) callconv(.c) bool {
        return false;
    }
    fn noBreakpoint(_: f64) callconv(.c) f64 {
        return std.math.inf(f64);
    }
    fn noNode(_: [*]const u8, _: usize) callconv(.c) isize {
        return -1;
    }
    pub const lib: Lib = .{
        .open = open,
        .solve = solve,
        .accept = accept,
        .x = x,
        .n_u = zero,
        .n_rows = zero,
        .row = row,
        .rows = rows,
        .n_shares = zero,
        .shares = rows,
        .systf = hooks,
        .n_systf = one,
        .systf_name = name,
        .systf_tok = tok,
        .systf_outs = readBack,
        .ac = ac,
        .breakpoint = noBreakpoint,
        .node = noNode,
    };
    const arg = [_]List{.{ .tag = user.vpiArgument, .items = &.{.at(1)} }};

    /// A design holding that call (object 0, full name `full`) and its
    /// argument (object 1): the same name, token and index in every design
    /// it builds, so only the binding tells two apart.
    pub fn design(full: []const u8) !Design {
        const a = std.testing.allocator;
        const objs = try a.alloc(Obj, 2);
        objs[0] = .{ .kind = .code, .owner = .none, .name = "$c", .full = full, .vtype = user.vpiSysFuncCall, .in_analog = true, .src_tok = 5, .lists = &arg };
        objs[1] = .{ .kind = .code, .owner = .none, .name = "x", .full = "x" };
        return .{ .gpa = a, .arena = .init(a), .objects = objs, .scopes = &.{}, .top_modules = &.{}, .by_name = .empty, .iters = .empty };
    }

    /// The registration's calltf: records the design it ran in, and puts
    /// 1 (library "A") or 2 (any other), plus 10 per host instance, on
    /// argument 1.
    var seen_full: []const u8 = "";
    var seen_objects: [*]Obj = undefined;
    fn calltf(cb: *CbData) callconv(.c) c_int {
        const d = &session.design.?;
        const o = trust.asObj(cb.obj).?;
        seen_full = o.full;
        seen_objects = d.objects.ptr;
        const tag: f64 = if (o.full[0] == 'A') 1 else 2;
        _ = analog_call.putArg(d.obj(.at(1)), tag + 10 * @as(f64, @floatFromInt(systf.active_inst)));
        return 0;
    }
};

/// The device's `AnalysisKind` ordinals (`static, ic, nodeset, dc, tran, ac,
/// noise`): an operating point is a DC analysis, a transient a transient.
/// The library evaluates a transient's first solution (dt = 0) as `.ic`,
/// Table 4-22's TRAN OP column (`atPoint` in `tb/runner_text.zig`), so this
/// host passes the analysis and `Lib.solve` passes dt. An AC sweep's operating point is "static" (Table 4-21: "the DC analysis
/// which precedes an AC or noise analysis"): the device's `ac_stim` is live
/// in every `.ac` evaluation, and is zero here (§4.6.1); the sweep itself
/// evaluates as `.ac` (`Lib.ac`).
pub fn kindOrdinal(k: Kind) u8 {
    return switch (k) {
        .op => 3,
        .tran => 4,
        .ac => 0,
    };
}

/// The binding the routines answer for now.
pub fn bound() ?*Binding {
    return active orelse installed;
}

/// Makes `b` the binding the routines answer for and, when it owns a
/// design, that design the installed one, until `leave(b, <the result>)`.
/// Entering the binding already entered changes nothing; entries nest LIFO.
pub fn enter(b: *Binding) ?*Binding {
    const prev = active;
    if (prev == b) return prev;
    if (b.owns) std.mem.swap(?Design, &session.design, &b.design);
    active = b;
    return prev;
}

/// Undoes the `enter(b)` that returned `prev`.
pub fn leave(b: *Binding, prev: ?*Binding) void {
    if (prev == b) return;
    std.debug.assert(active == b);
    if (b.owns) std.mem.swap(?Design, &session.design, &b.design);
    active = prev;
}

/// §12.36 vpiRejectTransientStep: "cause the current analog simulation time
/// point to be rejected". The walk backs up as for an acbConvergenceTest
/// rejection. False when no rejectable solution is open: outside an analysis,
/// on the first solution (no earlier time to back up to), or once accepted.
pub fn rejectStep() bool {
    const b = bound() orelse return false;
    if (current == null or !b.open_step) return false;
    b.reject_step = true;
    return true;
}

/// §12.36 vpiTransientFailConverge: "cause the current analog simulation to
/// continue iterating for a (valid) solution". The walk solves the same time
/// again from the solution it has, with no backup and no acceptance between.
/// False when no solution is awaiting acceptance.
pub fn failConverge() bool {
    const b = bound() orelse return false;
    if (current == null or !b.awaiting) return false;
    b.fail_converge = true;
    return true;
}

/// Sets the point §12.7-§12.9 and §12.18 answer for: the analysis `a` (null
/// between analyses), the time `t` of the solution attempted, the step `dt`
/// that reaches it, and the small-signal frequency `f` (0 outside an AC
/// sweep's small-signal points). `run` calls it at every point it walks; a
/// host that walks its own analysis and binds VerA only for the calls (a
/// `Lib` with no solution, `vpi_get_analog_value` then refuses NOSOLUTION)
/// calls it before each `contract.SystfHost.call`, so a calltf reads the
/// host's point. One point per process, for every binding: §12.7-§12.9 take
/// no argument. `a.kind` decides which values the routines report (§12.9:
/// zero time outside a transient); its bounds are §12.18's.
pub fn setPoint(a: ?Analysis, t: f64, dt: f64, f: f64) void {
    current = a;
    t_now = t;
    delta = dt;
    freq = f;
}

/// The analysis `run` is walking, its default `max_step` filled in; null
/// outside `run`. §12.18's vpi_get_real reads its bounds.
pub fn analysis() ?Analysis {
    return current;
}

/// §12.9's value: the attempted solution's time, or the latest accepted.
pub fn time() f64 {
    return t_now;
}

/// Where acbElapsedTime counts from: "the current solution".
pub fn acceptedTime() f64 {
    const b = bound() orelse return 0;
    return if (current != null) b.t_accepted else 0;
}

/// Two analog instants are one when they differ by rounding only: a forced
/// point is solved at exactly the requested double, but a grid point is
/// `start + k·step` and need not be bit-equal to a time an application
/// computed another way.
pub fn sameTime(a: f64, b: f64) bool {
    return @abs(a - b) <= 1e-12 * @max(1.0, @max(@abs(a), @abs(b))) or @abs(a - b) <= 1e-21;
}

test "sameTime: one instant up to rounding, symmetric, and no wider" {
    // Relative 1e-12 of the larger magnitude, at least 1e-12 absolute.
    try std.testing.expect(sameTime(1, 1 + 1e-13));
    try std.testing.expect(sameTime(1 + 1e-13, 1));
    try std.testing.expect(!sameTime(1, 1 + 1e-11));
    try std.testing.expect(sameTime(1e9, 1e9 + 1e-4));
    try std.testing.expect(!sameTime(1e9, 1e9 + 1e-2));
    try std.testing.expect(sameTime(0, 1e-13));
    try std.testing.expect(!sameTime(0, 1e-11));
}

test "§12.7-§12.9, §12.18 setPoint: the routines answer the point a host set, by its kind" {
    setPoint(null, 0, 0, 0);
    defer setPoint(null, 0, 0, 0);
    // A transient point at 2 ms reached by a 1 us step: §12.9 the time, §12.7
    // the step, §12.8 zero outside a small-signal analysis.
    setPoint(.{ .kind = .tran, .stop = 5e-3 }, 2e-3, 1e-6, 0);
    try std.testing.expectEqual(@as(f64, 2e-3), analog_value.vpi_get_analog_time());
    try std.testing.expectEqual(@as(f64, 1e-6), analog_value.vpi_get_analog_delta());
    try std.testing.expectEqual(@as(f64, 0), analog_value.vpi_get_analog_freq());
    try std.testing.expectEqual(@as(f64, 5e-3), analysis().?.stop);
    // An AC point at 1 kHz: time and step are zero there (§12.7, §12.9
    // "during DC"; the sweep stands on a DC operating point), freq is it.
    setPoint(.{ .kind = .ac }, 2e-3, 1e-6, 1e3);
    try std.testing.expectEqual(@as(f64, 0), analog_value.vpi_get_analog_time());
    try std.testing.expectEqual(@as(f64, 0), analog_value.vpi_get_analog_delta());
    try std.testing.expectEqual(@as(f64, 1e3), analog_value.vpi_get_analog_freq());
    // Null: between analyses, no bounds to read.
    setPoint(null, 0, 0, 0);
    try std.testing.expect(analysis() == null);
}

test "Binding: two libraries at once, each call in its own design, each (library, instance) its own outputs (VerA #84)" {
    session.close();
    defer session.close();
    session.design = try OneCall.design("A.$c");
    var tf = "$c".*;
    const reg: AnalogSystfData = .{ .type = user.vpiAnalogSysFunc, .sysfunctype = user.vpiRealFunc, .tfname = &tf, .calltf = OneCall.calltf, .compiletf = null, .sizetf = null, .derivtf = null, .user_data = null };
    try std.testing.expect(systf.vpi_register_analog_systf(&reg) != null);
    var a: Binding = .{};
    defer a.detach();
    var b: Binding = .{};
    defer b.detach();
    try a.attach(OneCall.lib, null);
    try b.attach(OneCall.lib, try OneCall.design("B.$c"));

    const args = [1]f64{0.5};
    var p: [1]f64 = undefined;
    // A's call runs in the installed design; B's in its own, swapped in for
    // the call and back out after it.
    _ = a.call(0, 0, &args, &p);
    try std.testing.expectEqualStrings("A.$c", OneCall.seen_full);
    try std.testing.expect(OneCall.seen_objects == session.design.?.objects.ptr);
    _ = b.call(0, 0, &args, &p);
    try std.testing.expectEqualStrings("B.$c", OneCall.seen_full);
    try std.testing.expect(OneCall.seen_objects != session.design.?.objects.ptr);
    try std.testing.expectEqualStrings("A.$c", session.design.?.obj(.at(0)).full);
    _ = a.call(1, 0, &args, &p);

    // Each (library, instance) reads back what its own calltf put: a value
    // with no partial.
    try std.testing.expectEqual(@as(f64, 1), a.output(0, 0, 1, &args, &p));
    try std.testing.expectEqual(@as(f64, 0), p[0]);
    try std.testing.expectEqual(@as(f64, 11), a.output(1, 0, 1, &args, &p));
    try std.testing.expectEqual(@as(f64, 2), b.output(0, 0, 1, &args, &p));
    // B's instance 1 never ran: its argument keeps its value, partial 1.
    try std.testing.expectEqual(@as(f64, 0.5), b.output(1, 0, 1, &args, &p));
    try std.testing.expectEqual(@as(f64, 1), p[0]);
    // Outside any call the routines answer for A, on the installed design.
    try std.testing.expect(bound().? == &a);
}

test "§12.10 vpiStringVal: the real part's %g choice is the format reported, whatever the imaginary part chose" {
    session.close();
    defer session.close();
    const a = std.testing.allocator;
    // A potential quantity (object 0) of a branch (object 1) from unknown 0
    // to ground.
    const objs = try a.alloc(Obj, 2);
    objs[0] = .{ .kind = .quantity, .owner = .none, .name = "", .full = "", .cold = 0 };
    objs[1] = .{ .kind = .branch, .owner = .none, .name = "b", .full = "b", .cold = 1 };
    const colds = try a.alloc(Cold, 2);
    colds[0] = .{ .branch = .at(1) };
    colds[1] = .{ .hi_row = 0 };
    session.design = .{ .gpa = a, .arena = .init(a), .objects = objs, .cold = colds, .scopes = &.{}, .top_modules = &.{}, .by_name = .empty, .iters = .empty };
    // An AC point whose phasor is 2.5 + 1e-7 j: %g spells the real part as a
    // decimal and the imaginary part with an exponent.
    var ac_x = [2]f64{ 2.5, 1e-7 };
    var b: Binding = .{ .lib = OneCall.lib, .n_x = 1, .ac_x = &ac_x, .have_solution = true };
    installed = &b;
    defer installed = null;
    setPoint(.{ .kind = .ac }, 0, 0, 1e3);
    defer setPoint(null, 0, 0, 0);
    var v: AnalogValue = .{ .format = user.vpiStringVal, .real = .{ .real = 0 }, .imaginary = .{ .real = 0 } };
    analog_value.vpi_get_analog_value(trust.handleOf(session.design.?.obj(.at(0))), &v);
    try std.testing.expectEqual(@as(c_int, 0), status.vpi_chk_error(null));
    try std.testing.expectEqualStrings("2.5", std.mem.span(v.real.str));
    try std.testing.expectEqualStrings("1e-07", std.mem.span(v.imaginary.str));
    try std.testing.expectEqual(user.vpiDecStrVal, v.format);
    // The real-only formats keep their format.
    v.format = user.vpiRealVal;
    analog_value.vpi_get_analog_value(trust.handleOf(session.design.?.obj(.at(0))), &v);
    try std.testing.expectEqual(@as(f64, 1e-7), v.imaginary.real);
    try std.testing.expectEqual(user.vpiRealVal, v.format);
}
