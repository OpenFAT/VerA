//! An analysis over a bound library: an `Analysis` -> the solutions it
//! walks, every §12.31.3 callback delivered, forced times solved at and
//! rejected solutions backed up from; and the mixed-signal transient's analog
//! side for `sim.mixed.run`.
//! Cites: VAMS-2023 §5.10.3.3, §7.3.3, §7.3.6.3, §8.4, §12.18, §12.31.3,
//! §12.36.
//!
//! Contents:
//! - `pub fn Mixed.setInputs(_: *Mixed, _: *sim.digital.Run, fired: u64) !void`
//! - `pub fn Mixed.snapshot(_: *Mixed, _: *sim.digital.Run) !void {}`
//! - `pub fn Mixed.latch(_: *Mixed) !void {}`
//! - `pub fn Mixed.solveAt(m: *Mixed, t: f64, dt: f64, first: bool, last: bool) !void`
//! - `pub fn Mixed.rejected(m: *Mixed) !bool`
//! - `pub fn Mixed.finish(m: *Mixed) !void`
//! - `pub fn Mixed.breakpoint(m: *Mixed, t: f64) ?f64`
//! - `pub fn Mixed.probe(m: *Mixed, t: ?f64, n1: []const u8, n2: ?[]const u8) !f64`
//! - `pub fn run(b: *Binding, a: Analysis) Error!void`
//! - `pub fn runMixed(b: *Binding, a: Analysis, dig: *sim.digital.Run, tick: f64, probe_names: []const []const u8, probe_nodes: []const [2][]const u8) (Error || anyerror)!void`
//! - `pub fn sweep(b: *Binding, l: Lib, a: Analysis) Error!void`
//! - `pub fn attempt(b: *Binding, l: Lib, t: f64, dt: f64, first: bool, last: bool) Error!void`
//! - `pub fn accept(b: *Binding, l: Lib, first: bool, last: bool) void`
//! - `pub fn refreshRows(b: *Binding, l: Lib) void`

const std = @import("std");
const sim = @import("sim");
const gpa = std.heap.smp_allocator;
const analog = @import("analog.zig");
const callback_fire = @import("callback_fire.zig");
const user = @import("vpi_user.zig");
const Binding = @import("Binding.zig");
const Analysis = analog.Analysis;
const Error = analog.Error;
const Lib = analog.Lib;

/// `sim.mixed.run`'s analog side for `Binding.runMixed`: the library's
/// solve behind the VPI walk's callbacks. The analog block reads no digital
/// value here (`host.zig` refuses a design whose block does), so there are no
/// inputs to set and no explicit D2A event to latch.
const Mixed = struct {
    b: *Binding,
    l: Lib,
    probe_names: []const []const u8,
    probe_nodes: []const [2][]const u8,
    /// The last finished solution and its time, for §7.3.6.3's
    /// interpolation; `t_prev` null before the first.
    x_prev: []f64,
    t_prev: ?f64 = null,
    /// The tentative solution's time.
    t_now: f64 = 0,
    first: bool = false,
    last: bool = false,
    /// The application rejected the solution `solveAt` last made.
    rejected_now: bool = false,

    pub fn setInputs(_: *Mixed, _: *sim.digital.Run, fired: u64) !void {
        std.debug.assert(fired == 0);
    }
    pub fn snapshot(_: *Mixed, _: *sim.digital.Run) !void {}
    pub fn latch(_: *Mixed) !void {}

    /// A tentative solution, passed to acbConvergenceTest; §12.36's
    /// vpiTransientFailConverge solves the same time again.
    pub fn solveAt(m: *Mixed, t: f64, dt: f64, first: bool, last: bool) !void {
        var tries: u32 = 0;
        while (true) : (tries += 1) {
            if (tries == 60) return error.BackupExhausted;
            try m.b.attempt(m.l, t, dt, first, last);
            const vetoed = callback_fire.convergenceRejected() or m.b.reject_step;
            if (!m.b.fail_converge) {
                m.rejected_now = vetoed and !first;
                break;
            }
        }
        m.first = first;
        m.last = last;
        m.t_now = t;
    }

    pub fn rejected(m: *Mixed) !bool {
        defer m.rejected_now = false;
        return m.rejected_now;
    }

    pub fn finish(m: *Mixed) !void {
        m.b.accept(m.l, m.first, m.last);
        @memcpy(m.x_prev, m.l.x()[0..m.x_prev.len]);
        m.t_prev = m.t_now;
    }

    /// §5.10.3.3 the device's next timer instant, if it has one.
    pub fn breakpoint(m: *Mixed, t: f64) ?f64 {
        const bp = m.l.breakpoint(t);
        return if (std.math.isInf(bp)) null else bp;
    }

    /// §7.3.3 V(n1) or V(n1, n2) of the tentative solution when `t` is
    /// null, else §7.3.6.3's value at `t`, interpolated between the last
    /// finished solution and the tentative one.
    pub fn probe(m: *Mixed, t: ?f64, n1: []const u8, n2: ?[]const u8) !f64 {
        const now = m.l.x()[0..m.x_prev.len];
        const v_now = m.terminal(now, n1) - if (n2) |b| m.terminal(now, b) else 0.0;
        const at = t orelse return v_now;
        const t0 = m.t_prev orelse return v_now;
        if (!(m.t_now > t0)) return v_now;
        const v0 = m.terminal(m.x_prev, n1) - if (n2) |b| m.terminal(m.x_prev, b) else 0.0;
        const w = std.math.clamp((at - t0) / (m.t_now - t0), 0.0, 1.0);
        return v0 + (v_now - v0) * w;
    }

    /// A probe terminal, as the mixed testbench reads one (`runner_text`
    /// `terminal`): the node pair lowering resolved it to, else a node by
    /// name; a name that is no unknown of the device is ground.
    // ponytail: names compared as written; a node whose `D.U` spelling is
    // sanitized (an escaped identifier) reads as ground.
    fn terminal(m: *const Mixed, x: []const f64, name: []const u8) f64 {
        for (m.probe_names, m.probe_nodes) |n, pair| if (std.mem.eql(u8, n, name))
            return m.nodeValue(x, pair[0]) - m.nodeValue(x, pair[1]);
        return m.nodeValue(x, name);
    }

    fn nodeValue(m: *const Mixed, x: []const f64, name: []const u8) f64 {
        const k = m.l.node(name.ptr, name.len);
        return if (k < 0) 0.0 else x[@intCast(k)];
    }
};

/// Runs one analysis to its end, delivering every §12.31.3 callback.
///
/// `tran` walks a grid of `max_step` (default (stop - start)/50) plus
/// every forced time; each tentative solution passes acbConvergenceTest
/// before it is accepted, and a rejection (or §12.36
/// vpiRejectTransientStep) halves the step from the last accepted point.
/// `op` is one DC solution, first and last at once. `ac` is that
/// solution (acbInitialStep, at frequency 0), then one small-signal
/// solution per frequency, each an acbAcceptedPoint and the last also
/// acbFinalStep (`Vague_Decisions.md` VD-098). A rejected solution
/// leaves no history. §12.36 vpiTransientFailConverge solves the same
/// time again. `BackupExhausted`: 60 rejections or re-solves of one step.
pub fn run(b: *Binding, a: Analysis) Error!void {
    const l = b.lib orelse return error.NoLibrary;
    const prev = analog.enter(b);
    defer analog.leave(b, prev);
    l.open(analog.kindOrdinal(a.kind));
    @memset(b.prev_react, 0);
    var run_a = a;
    // §12.18 vpiTransientMaxStep is the step this walk takes.
    if (run_a.kind == .tran and run_a.max_step <= 0) run_a.max_step = (a.stop - a.start) / 50.0;
    analog.setPoint(run_a, a.start, 0, 0);
    defer analog.setPoint(null, analog.t_now, analog.delta, 0);
    b.t_accepted = a.start;
    const last0 = a.kind == .op or (a.kind == .tran and a.stop <= a.start);
    // The first solution has no earlier time to back up to; §12.31.3's
    // rejection is honoured from the next one on. §12.36's
    // vpiTransientFailConverge needs none, so it is honoured here too.
    var first_tries: u32 = 0;
    while (true) : (first_tries += 1) {
        if (first_tries == 60) return error.BackupExhausted;
        try b.attempt(l, a.start, 0, true, last0);
        _ = callback_fire.convergenceRejected();
        if (!b.fail_converge) break;
    }
    b.accept(l, true, last0);
    if (last0) return;
    if (a.kind == .ac) return b.sweep(l, a);

    const h = run_a.max_step;
    while (!analog.sameTime(b.t_accepted, a.stop) and b.t_accepted < a.stop) {
        // The next grid point strictly after t, by index rather than by
        // accumulation, so a thousand steps do not drift off `stop`.
        const k = @floor((b.t_accepted - a.start) / h + 1e-9) + 1;
        var target = @min(a.start + k * h, a.stop);
        if (callback_fire.nextForced(b.t_accepted, target)) |f| target = f;
        // §5.10.3.3 "places a time point within time_tol of an event": a
        // timer instant before the grid point is solved at itself.
        const bp = l.breakpoint(b.t_accepted);
        if (bp > b.t_accepted and bp < target and !analog.sameTime(bp, b.t_accepted)) target = bp;
        if (a.stop - target < h * 1e-6) target = a.stop;
        var tries: u32 = 0;
        while (true) : (tries += 1) {
            if (tries == 60) return error.BackupExhausted;
            try b.attempt(l, target, target - b.t_accepted, false, analog.sameTime(target, a.stop));
            const rejected = callback_fire.convergenceRejected() or b.reject_step;
            if (!(rejected or b.fail_converge)) break;
            // "backup to an earlier time": half the step, from the same
            // accepted solution. A vpiTransientFailConverge alone keeps
            // the time and iterates again.
            if (rejected) target = b.t_accepted + (target - b.t_accepted) / 2;
        }
        b.accept(l, false, analog.sameTime(target, a.stop));
    }
}

/// `run` for a transient of a mixed-signal design (VAMS §8.4): the
/// digital half `dig`, already elaborated and attached (`run.attach`),
/// steps beside the analog solve under `sim.mixed.run`, which owns the
/// time walk; the analog is solved at least at every `max_step` (§12.18)
/// and at each digital event, timer and crossing. Each tentative solution
/// passes acbConvergenceTest, and one the application rejects (§12.36
/// vpiRejectTransientStep) is backed up from with its A2D events, which
/// the digital engine has not consumed (§8.4.7). `tick` is the digital
/// half's tick in seconds; `probe_names` the §7.3.3 probe terminals that
/// stand for a node pair (`probe_nodes`), a named branch or a
/// hierarchical net (`Lowered.discrete_probes`).
pub fn runMixed(b: *Binding, a: Analysis, dig: *sim.digital.Run, tick: f64, probe_names: []const []const u8, probe_nodes: []const [2][]const u8) (Error || anyerror)!void {
    std.debug.assert(probe_names.len == probe_nodes.len);
    std.debug.assert(a.kind == .tran);
    const l = b.lib orelse return error.NoLibrary;
    const prev = analog.enter(b);
    defer analog.leave(b, prev);
    l.open(analog.kindOrdinal(a.kind));
    @memset(b.prev_react, 0);
    var run_a = a;
    if (run_a.max_step <= 0) run_a.max_step = (a.stop - a.start) / 50.0;
    analog.setPoint(run_a, a.start, 0, 0);
    defer analog.setPoint(null, analog.t_now, analog.delta, 0);
    b.t_accepted = a.start;
    // The declared timepoints: the DC point, then the §12.18 grid.
    const steps: usize = @intFromFloat(@max(1, @ceil((a.stop - a.start) / run_a.max_step - 1e-9)));
    const times = try gpa.alloc(f64, steps + 1);
    defer gpa.free(times);
    for (times, 0..) |*t, k| t.* = if (k == steps) a.stop else a.start + @as(f64, @floatFromInt(k)) * run_a.max_step;
    const x_prev = try gpa.alloc(f64, l.n_u());
    defer gpa.free(x_prev);
    var m: Mixed = .{ .b = b, .l = l, .probe_names = probe_names, .probe_nodes = probe_nodes, .x_prev = x_prev };
    try sim.mixed.run(Mixed, &m, dig, .{ .times = times, .tick = tick });
}

/// The AC half of `run`: `a.points` small-signal solutions around the
/// accepted operating point. §12.31.3 names no per-frequency reason, so
/// each is an acbAcceptedPoint, the last also acbFinalStep; §12.8's
/// vpi_get_analog_freq() tells an application which kind of solution it
/// is standing on.
pub fn sweep(b: *Binding, l: Lib, a: Analysis) Error!void {
    defer analog.setPoint(analog.current, analog.t_now, analog.delta, 0);
    const n = @max(a.points, 1);
    for (0..n) |k| {
        const f = if (n == 1) a.fstart else a.fstart + (a.fstop - a.fstart) * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n - 1));
        const u = b.ac_x.len / 2;
        if (!l.ac(2 * std.math.pi * f, b.ac_x.ptr, b.ac_x[u..].ptr)) return error.Singular;
        analog.setPoint(analog.current, analog.t_now, analog.delta, f);
        callback_fire.fireAnalog(user.acbAcceptedPoint);
        if (k == n - 1) callback_fire.fireAnalog(user.acbFinalStep);
    }
}

pub fn attempt(b: *Binding, l: Lib, t: f64, dt: f64, first: bool, last: bool) Error!void {
    analog.setPoint(analog.current, t, dt, 0);
    b.have_solution = true;
    b.open_step = !first;
    b.awaiting = true;
    b.reject_step = false;
    b.fail_converge = false;
    b.vals_fresh = false;
    _ = l.solve(t, dt, first, last);
}

pub fn accept(b: *Binding, l: Lib, first: bool, last: bool) void {
    b.open_step = false;
    b.awaiting = false;
    // Row values are the accepted solution's, read before history moves.
    b.refreshRows(l);
    l.accept();
    b.t_accepted = analog.t_now;
    // §12.31.3 does not say whether the first solution (acbInitialStep)
    // is also an acbAcceptedPoint. VerA says no, so accepted points
    // strictly advance (p03_02 pins this reading); the final one is an
    // accepted point, then acbFinalStep.
    if (first) callback_fire.fireAnalog(user.acbInitialStep);
    callback_fire.fireTimed(b.t_accepted);
    if (!first) callback_fire.fireAnalog(user.acbAcceptedPoint);
    if (last) callback_fire.fireAnalog(user.acbFinalStep);
    // Only now does this solution's charge become the next step's history.
    for (b.prev_react, 0..) |*q, k| q.* = b.now_vals[2 * k + 1];
}

pub fn refreshRows(b: *Binding, l: Lib) void {
    if (b.vals_fresh or b.flow_u.len == 0) return;
    l.rows(b.now_vals.ptr);
    if (b.now_vals.len > 2 * b.flow_u.len) l.shares(b.now_vals[2 * b.flow_u.len ..].ptr);
    b.vals_fresh = true;
}
