//! A monitored analog event in, its A2D deliveries out: the `cross`/`above`
//! cut of a step (§5.10.3.1, §5.10.3.2), the `timer` grid (§5.10.3.3) and the
//! `absdelta` ramp (§5.10.3.4), each read through `digital.Run.monitorArg`.
//! Cites: VAMS §5.10.3.1 to §5.10.3.4, §7.3.5, §7.3.6.1, §8.4.3.3.
//!
//! Contents:
//! - `pub const Mon = struct`
//! - `pub fn Monitors(comptime Self: type) type`
//! - `Monitors.monValue(s: *Self, j: usize) Self.Error!f64`
//! - `Monitors.monArgAt(s: *Self, j: usize, k: usize, t: ?f64) Self.Error!?f64`
//! - `Monitors.refreshTimers(s: *Self, t: f64) Self.Error!bool`
//! - `Monitors.AbsdeltaArgs = struct`
//! - `Monitors.absdeltaArgs(s: *Self, j: usize, t: ?f64) Self.Error!AbsdeltaArgs`
//! - `Monitors.refreshAbsdelta(s: *Self, t: f64) Self.Error!bool`
//! - `Monitors.observeAbsdelta(s: *Self, j: usize) Self.Error!void`
//! - `Monitors.AbsdeltaEvent = struct`
//! - `Monitors.nextAbsdelta(s: *Self, j: usize, base: f64, cursor: f64) Self.Error!?AbsdeltaEvent`
//! - `Monitors.drainAbsdelta(s: *Self, base: f64, horizon: Tick) Self.Error!void`
//! - `Monitors.active(s: *Self, enable: u8, j: usize) Self.Error!bool`

const std = @import("std");
const assert = std.debug.assert;
const digital = @import("../digital/root.zig");
const Tick = digital.Tick;
const timer = @import("kernels").timer_kernels;
const run = @import("run.zig");
const default_time_tol = run.default_time_tol;
const default_expr_tol = run.default_expr_tol;

/// One monitored analog event (`digital.Run.analog.monitors`): what its kind needs,
/// and its value on the last final solution (`v0`, unused by a timer).
pub const Mon = struct {
    v0: f64 = 0,
    kind: union(enum) {
        /// §5.10.3.1 cross / §5.10.3.2 above: the direction, the time and
        /// expression tolerances (`etol` inf when absent), and the argument
        /// index of `enable`, whose zero makes the event inactive.
        crossing: struct { dir: f64, tol: f64, etol: f64, enable: u8 },
        /// §5.10.3.3 the latest absolute grid and its pending event. A digital
        /// body can change controls at this point after the event was already
        /// delivered; consumed prevents that change from delivering it twice.
        timer: struct {
            start: f64 = std.math.nan(f64),
            period: f64 = std.math.nan(f64),
            next: f64 = std.math.inf(f64),
            consumed: f64 = std.math.nan(f64),
        },
        /// §5.10.3.4: event history is distinct from observed extrema, so
        /// reversals smaller than expr_tol accumulate without losing a peak.
        absdelta: struct {
            initialized: bool = false,
            enabled: bool = false,
            last: f64 = 0,
            last_time: f64 = 0,
            direction: f64 = 0,
            extreme: f64 = 0,
            observed_event: bool = false,
        },
    },

    // Budget: every analog step walks `mons` reading `v0` and the tag; the
    // largest payload (absdelta, 4 f64 + 3 bools) sets 40 + tag 8 + v0 8.
    comptime {
        std.debug.assert(@sizeOf(Mon) == 56);
    }
};

/// The monitor half of `coordinator.State(A)`: `Self` is that type, and
/// `State` declares each of these as its own method.
pub fn Monitors(comptime Self: type) type {
    return struct {
        /// Returns monitor `j`'s expression on the tentative solution.
        /// Asserts that `j` names a monitor.
        pub fn monValue(s: *Self, j: usize) Self.Error!f64 {
            assert(j < s.mons.len);
            return (try s.monArgAt(j, 0, null)).?;
        }

        /// Returns argument `k` of monitor `j`, its probes read at `t` (null:
        /// the tentative solution); null for an absent argument.
        pub fn monArgAt(s: *Self, j: usize, k: usize, t: ?f64) Self.Error!?f64 {
            assert(!s.mon_eval); // Monitor evaluations do not nest.
            s.mon_eval = true;
            defer s.mon_eval = false;
            s.mon_time = t;
            defer s.mon_time = null;
            return s.dig.monitorArg(j, k);
        }

        /// Refresh after each analog solve and digital control change. With
        /// unchanged controls a point just beyond the deadline still delivers
        /// the pending event. A changed start/period first replaces that
        /// deadline from its latest absolute grid, which may cancel an old
        /// event or place a new one at this very time (§5.10.3.3).
        pub fn refreshTimers(s: *Self, t: f64) Self.Error!bool {
            var posted = false;
            for (s.mons, 0..) |*m, j| if (m.kind == .timer) {
                const tm = &m.kind.timer;
                const start = (try s.monArgAt(j, 0, t)).?;
                const period = (try s.monArgAt(j, 1, t)) orelse 0;
                const ttol = (try s.monArgAt(j, 2, t)) orelse 0;
                const enable = (try s.monArgAt(j, 3, t)) orelse 1;
                const tok = s.dig.file.exprs.mainTok(s.dig.analog.monitors.items[j].expr);
                if (!(ttol >= 0))
                    return s.dig.failWith(.E0517, tok, "`timer()` time_tol shall be non-negative", .{});
                if (!std.math.isFinite(enable) or enable != @round(enable))
                    return s.dig.failWith(.E0517, tok, "`timer()` enable shall evaluate to an integer", .{});
                // We choose the deadline itself, satisfying every positive
                // tolerance and the absent/zero at-or-just-beyond default.
                tm.next = timer.zTimerPending(start, period, t, tm.start, tm.period, tm.next);
                tm.start = start;
                tm.period = period;
                if (t < tm.next) continue;
                tm.next = timer.zNextTimer(start, period, t) orelse std.math.inf(f64);
                if (tm.consumed == t) continue;
                tm.consumed = t;
                if (enable == 0) continue;
                try s.dig.deliverA2d(j, s.tickNear(t));
                posted = true;
            };
            return posted;
        }

        /// §5.10.3.4 absdelta's arguments, defaulted and checked.
        pub const AbsdeltaArgs = struct { delta: f64, time_tol: f64, expr_tol: f64, enabled: bool };

        /// Returns monitor `j`'s absdelta arguments; E0517 on a negative
        /// tolerance or a non-integral enable (they are design values).
        pub fn absdeltaArgs(s: *Self, j: usize, t: ?f64) Self.Error!AbsdeltaArgs {
            assert(s.mons[j].kind == .absdelta);
            const delta = (try s.monArgAt(j, 1, t)).?;
            const ttol = (try s.monArgAt(j, 2, t)) orelse 0;
            const etol = (try s.monArgAt(j, 3, t)) orelse 0;
            const enable = (try s.monArgAt(j, 4, t)) orelse 1;
            const tok = s.dig.file.exprs.mainTok(s.dig.analog.monitors.items[j].expr);
            if (!(delta >= 0 and ttol >= 0 and etol >= 0))
                return s.dig.failWith(.E0517, tok, "`absdelta()` delta and tolerances shall be non-negative", .{});
            if (!std.math.isFinite(enable) or enable != @round(enable))
                return s.dig.failWith(.E0517, tok, "`absdelta()` enable shall evaluate to an integer", .{});
            return .{
                .delta = delta,
                .time_tol = @max(if (ttol > 0) ttol else default_time_tol, s.opts.tick),
                .expr_tol = if (etol > 0) etol else default_expr_tol,
                .enabled = enable != 0,
            };
        }

        /// Initialization and 0 -> nonzero enable are events even when expr
        /// has not moved. Disabled observations never advance the event baseline.
        pub fn refreshAbsdelta(s: *Self, t: f64) Self.Error!bool {
            var posted = false;
            for (s.mons, 0..) |*m, j| if (m.kind == .absdelta) {
                const ad = &m.kind.absdelta;
                if (!ad.initialized) continue;
                const args = try s.absdeltaArgs(j, t);
                if (args.enabled == ad.enabled) continue;
                ad.enabled = args.enabled;
                ad.observed_event = false;
                if (!args.enabled) continue;
                ad.last = (try s.monArgAt(j, 0, t)).?;
                ad.last_time = t;
                ad.direction = 0;
                ad.extreme = ad.last;
                try s.dig.deliverA2d(j, s.tickNear(t));
                posted = true;
            };
            return posted;
        }

        /// Record only observed changes here. A numeric control changing while
        /// expr is constant must not itself create an event (§5.10.3.4).
        pub fn observeAbsdelta(s: *Self, j: usize) Self.Error!void {
            const m = &s.mons[j];
            const ad = &m.kind.absdelta;
            ad.observed_event = false;
            const args = try s.absdeltaArgs(j, null);
            if (!ad.enabled or !args.enabled) return;
            const v = try s.monValue(j);
            if (args.delta == 0) {
                ad.observed_event = v != m.v0;
                ad.direction = 0;
                ad.extreme = v;
                return;
            }
            // A smaller expr_tol can make an old, ignored excursion large
            // enough. It still needs a NEW change of expr to cause an event.
            if (v == m.v0) return;
            const change = v - ad.extreme;
            if (change == 0) return;
            const dir = std.math.sign(change);
            if (ad.direction == 0 or dir == ad.direction) {
                ad.direction = dir;
                ad.extreme = v;
            } else if (@abs(change) >= args.expr_tol) {
                ad.observed_event = true;
                ad.direction = dir;
                ad.extreme = v;
            }
        }

        /// One absdelta event candidate: its monitor, time and value.
        pub const AbsdeltaEvent = struct { monitor: usize, t: f64, value: f64, observed: bool = false };

        /// Returns monitor `j`'s next event in `[cursor, acc]` of the step from
        /// `base`, or null. Asserts that `cursor >= base`.
        pub fn nextAbsdelta(s: *Self, j: usize, base: f64, cursor: f64) Self.Error!?AbsdeltaEvent {
            assert(cursor >= base);
            const m = &s.mons[j];
            const ad = &m.kind.absdelta;
            if (!ad.enabled) return null;
            const args = try s.absdeltaArgs(j, null);
            if (!args.enabled) return null;
            const end = s.acc.?;
            const v1 = try s.monValue(j);
            const observed: ?AbsdeltaEvent = if (ad.observed_event)
                .{ .monitor = j, .t = end, .value = v1, .observed = true }
            else
                null;
            if (args.delta == 0 or cursor >= end or v1 == m.v0 or @abs(v1 - ad.last) <= args.delta)
                return observed;
            const level = ad.last + std.math.sign(v1 - ad.last) * args.delta;
            const frac = std.math.clamp((level - m.v0) / (v1 - m.v0), 0, 1);
            // time_tol filters minimum event spacing. Pick the exact delta
            // crossing when eligible, otherwise the first eligible time. No
            // solver breakpoint is requested for either interpolated time.
            const t = @max(@max(base + frac * (end - base), ad.last_time + args.time_tol), cursor);
            if (t > end) return observed;
            const value = m.v0 + (v1 - m.v0) * ((t - base) / (end - base));
            return .{ .monitor = j, .t = t, .value = value, .observed = t == end and ad.observed_event };
        }

        /// Consume one candidate at a time, interleaved with existing digital
        /// work. A monitor body can disable itself or change its controls;
        /// pre-queuing the rest of the ramp would execute stale events.
        pub fn drainAbsdelta(s: *Self, base: f64, horizon: Tick) Self.Error!void {
            var cursor = base;
            while (true) {
                var next: ?AbsdeltaEvent = null;
                for (s.mons, 0..) |m, j| if (m.kind == .absdelta) {
                    if (try s.nextAbsdelta(j, base, cursor)) |candidate| {
                        if (next == null or candidate.t < next.?.t) next = candidate;
                    }
                };
                const event_tick: ?Tick = if (next) |e| s.tickNear(e.t) else null;
                if (s.dig.scheduler.peekTime()) |queued| {
                    if (queued <= horizon and (event_tick == null or queued < event_tick.?)) {
                        try s.runDigital(queued);
                        cursor = @max(cursor, @as(f64, @floatFromInt(queued)) * s.opts.tick);
                        continue;
                    }
                }
                const e = next orelse break;
                const ad = &s.mons[e.monitor].kind.absdelta;
                ad.last = e.value;
                ad.last_time = e.t;
                if (e.observed) ad.observed_event = false;
                try s.dig.deliverA2d(e.monitor, event_tick.?);
                if (event_tick.? <= horizon) try s.runDigital(event_tick.?);
                cursor = @max(cursor, e.t);
            }
            _ = try s.refreshAbsdelta(s.acc.?);
            try s.runDigital(horizon);
        }

        /// §5.10.3.1: "If enable argument is specified and it is zero, then
        /// cross() is inactive, meaning that it does not generate an event at
        /// threshold crossings and does not act to control the timestep."
        pub fn active(s: *Self, enable: u8, j: usize) Self.Error!bool {
            return ((try s.monArgAt(j, enable, null)) orelse 1) != 0;
        }
    };
}
