//! A digital `Run` and an analog solver -> one mixed-signal analysis on a
//! common global time (VAMS §8.4.4, §7.3.6).
//!
//! The analog side is a comptime interface (`run`'s `A`), so the tests below
//! drive the real digital engine against a fake solver.
//! Clauses: VAMS §7.3.5, §7.3.6, §8.4, §8.5, §5.10.3; IEEE 1364-2005 §17.1.3.
// ponytail: the analog never steps past the next digital event (Figure 8-7's
// conservative half), so nothing is ever rolled back (§8.4.6) and an A2D is
// delivered once, from the solution that is kept. A step the analog device
// itself would reject (an analog-context `cross`) is not cut here: only the
// monitored events cut, through the host's own re-solve.
const std = @import("std");
const digital = @import("digital/root.zig");
const Tick = digital.Tick;
const time = @import("time.zig");
const tickAtOrBefore = time.tickAtOrBefore;
const crosses = time.crosses;
const ulps = time.ulps;
const timer = @import("kernels").timer_kernels;

/// One analysis's timeline, as `run` reads it.
pub const Options = struct {
    /// The declared analog timepoints, in seconds, ascending. `times[0]` is the
    /// DC point that opens the analysis (§8.4.2); the rest are transient
    /// points. Implicit D2A points are inserted between them.
    times: []const f64,
    /// One scheduler tick, in seconds: the design's finest time precision.
    tick: f64,
};

/// Runs one analysis over `opts.times`.
///
/// Digital to analog: the solve at `t` sees every tick <= `t` (§7.3.6.5); a
/// change of a value the analog block reads forces a solve at its own time,
/// on or off the declared grid (§8.5, §8.4.7), once per tick after the
/// tick's nonblocking updates (§8.5.1 region 3b); activity at or before the
/// first time is settled into the DC point (§8.4.2). A solution is final
/// only once every tick at or before it has run, so a later D2A at the same
/// time re-solves it instead of adding a point.
///
/// Analog to digital: a `cross`/`above` in a digital event control is
/// checked against every tentative solution, and a step that jumps a
/// crossing is cut back to within its `time_tol` and `expr_tol` (§7.3.5,
/// §5.10.3.1); the
/// event is delivered at the nearest tick, never before the current digital
/// time (§7.3.6.1, §8.4.3.3); a probe reads the solution interpolated at the
/// promoted digital time (§7.3.6.3).
///
/// `A` provides these methods, each fallible:
///   setInputs(a, dig, fired)      copy the discrete inputs the analog block reads
///                                 out of `dig` (§7.3.1 Table 7-1 conversion is A's),
///                                 and raise the explicit D2A terms in `fired`
///                                 (bit = `digital.D2aSite.site`) for this solve
///   snapshot(a, dig)              region 1b (§8.5.3.6): keep, for the next
///                                 setInputs, the values the statements guarded
///                                 by an explicit D2A event read
///   latch(a)                      commit what the tentative solution's explicit
///                                 D2A event statements assigned, and nothing
///                                 else: one region-1b evaluation (§8.5.3.6)
///   solveAt(a, t, dt, first, last) a TENTATIVE solution at `t`; `first` opens the
///                                 analysis (dt = 0), `last` is its final point
///   finish(a)                     the last tentative solution is final: report it
///                                 (§9.4 strobes) and commit its state (§4.5.2)
///   probe(a, t, n1, n2)           V(n1, n2) (n2 null: V(n1)) of the tentative
///                                 solution when `t` is null, else interpolated
///                                 at `t` between the last finished solution and
///                                 the tentative one (§7.3.6.3)
/// and installs its own `digital.Run.watchAnalog` on every slot it reads,
/// which is what makes a change of one of them an implicit D2A.
pub fn run(comptime A: type, a: *A, dig: *digital.Run, opts: Options) !void {
    std.debug.assert(opts.times.len != 0);
    var s: State(A) = .{ .a = a, .dig = dig, .opts = opts, .final = opts.times[opts.times.len - 1] };
    // §7.3.5 / §7.3.6.3: a monitored analog event or a probe needs the analog
    // solution at every digital event time, so the analog steps to each one
    // before the digital engine runs it (Figure 8-7's conservative half).
    const sync = dig.monitors.items.len != 0 or dig.has_probes;
    if (sync) {
        dig.probe = State(A).probeHook;
        dig.probe_ctx = &s;
        s.mons = try dig.arena.alloc(Mon, dig.monitors.items.len);
        for (s.mons, dig.monitors.items, 0..) |*m, mon, j| {
            if (mon.kind == .timer) {
                // Controls may read a probe. Initialize after the first solve,
                // when those arguments have an analog value (§5.10.3.3).
                m.* = .{ .kind = .{ .timer = .{} } };
                continue;
            }
            if (mon.kind == .absdelta) {
                // Its arguments can change at runtime. In particular, no
                // probe is meaningful until the initial analog solve exists.
                m.* = .{ .kind = .{ .absdelta = .{} } };
                continue;
            }
            const above = mon.kind == .above;
            // §5.10.3.1 cross(expr, dir, time_tol, expr_tol, ...);
            // §5.10.3.2 above(expr, time_tol, expr_tol, ...).
            const dir = if (above) 1.0 else (try dig.monitorArg(j, 1)) orelse 0.0;
            const tol = (try dig.monitorArg(j, if (above) 1 else 2)) orelse 0.0;
            const etol = (try dig.monitorArg(j, if (above) 2 else 3)) orelse 0.0;
            m.* = .{ .kind = .{ .crossing = .{
                .dir = dir,
                .tol = if (tol > 0) tol else @min(default_time_tol, opts.tick / 2),
                .etol = if (etol > 0) etol else std.math.inf(f64),
                .enable = if (above) 3 else 4,
            } } };
        }
    }
    for (opts.times, 0..) |target, i| {
        const horizon = tickAtOrBefore(target, opts.tick);
        s.target = target;
        s.dc = i == 0;
        // §8.4.1 "a one time execution of nodeset statements (3.6.3.2), then
        // the procedural statements in analog initial block, and then the
        // procedural statements in the Verilog initial block for time zero":
        // a tentative solution runs the analog initial block before any
        // digital process, so a digital read of a continuous variable or a
        // probe at time zero sees it. No digital value exists yet (no
        // `setInputs`: the inputs keep their defaults, and §5.2.1 keeps them
        // out of the analog initial block). `acc` stays null: the DC point is
        // still solved below, with the time-zero digital values (§8.4.2).
        if (i == 0 and dig.has_probes) try a.solveAt(target, 0.0, true, target == s.final);
        if (sync and i > 0) {
            while (s.acc.? < target) {
                var t_end = target;
                if (dig.scheduler.peekTime()) |k| if (k <= horizon) {
                    t_end = @min(t_end, s.timeOf(k, target, horizon));
                };
                // §5.10.3.3 a timer places a point at its firing time, whether
                // it is monitored here or only the device's (`nextBreakpoint`).
                for (s.mons) |m| if (m.kind == .timer and m.kind.timer.next > s.acc.?) {
                    t_end = @min(t_end, m.kind.timer.next);
                };
                if (@hasDecl(A, "breakpoint")) if (a.breakpoint(s.acc.?)) |b| if (b > s.acc.?) {
                    t_end = @min(t_end, b);
                };
                try s.step(t_end);
            }
            continue;
        }
        // Every tick up to the horizon, one at a time, so an implicit D2A at
        // tick k is solved at k's own time and not at the next declared point.
        while (dig.scheduler.peekTime()) |k| {
            if (k > horizon) break;
            while (true) {
                switch (try dig.runUntil(k)) {
                    .idle => break,
                    .explicit_d2a => {
                        try s.explicitD2a();
                        continue;
                    },
                    .analog => {},
                    .vpi_sync => unreachable, // only `src/vpi` queues the marker
                }
                const t = s.timeOf(k, target, horizon);
                // §8.4.2: activity before the first analog time is settled
                // into the DC point, not given solutions of its own.
                if (i == 0 and t < target) continue;
                try s.accept(t);
            }
        }
        // The declared point itself, unless a D2A at this very time already
        // solved it with the tick's final values (region 3b follows 1-3).
        if (s.acc == null or s.acc.? != target) try s.accept(target);
        // §5.10.3.4 absdelta "generates events ... During initialization".
        if (sync and i == 0) {
            for (s.mons, 0..) |*m, j| if (m.kind == .absdelta) {
                const ad = &m.kind.absdelta;
                ad.initialized = true;
                ad.last = try s.monValue(j);
                ad.extreme = ad.last;
                ad.last_time = target;
            };
            _ = try s.refreshAbsdelta(target);
            _ = try s.refreshTimers(target);
            try s.runDigital(horizon);
        }
    }
    try a.finish();
}

/// Secant cuts `step` tries before it halves the step instead.
const max_secant = 64;
/// Cuts one step can take: `max_secant`, then bisections. Each bisection
/// halves acc - base or ends the loop, and an f64 interval shrinks to one ulp
/// in at most 2098 + 52 halvings (the exponent range plus the mantissa).
const max_cuts = max_secant + 2150;

/// §5.10.3.1 leaves an absent `time_tol` to the tool.
const default_time_tol = 1e-12;
/// §5.10.3.4 lets the tool choose an absent/zero expression tolerance.
const default_expr_tol = 1e-12;

/// One monitored analog event (`digital.Run.monitors`): what its kind needs,
/// and its value on the last final solution (`v0`, unused by a timer).
const Mon = struct {
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

fn State(comptime A: type) type {
    return struct {
        const Self = @This();
        a: *A,
        dig: *digital.Run,
        opts: Options,
        final: f64,
        /// The declared point being stepped toward (`timeOf`'s `target`).
        target: f64 = 0,
        /// Settling the activity at or before the first time into its DC point.
        dc: bool = false,
        /// `settleA2d` is running: the tentative solution is already finished.
        settling: bool = false,
        /// Time of the tentative, not yet finished, solution.
        acc: ?f64 = null,
        /// Time of the last finished solution: the base of `dt`.
        prev: ?f64 = null,
        /// Explicit D2A terms (bit = site) that occurred since the last solve,
        /// and those delivered to the tentative solution at `acc`. A term is
        /// delivered to exactly one finished solution: a re-solve at the same
        /// time keeps it, the next time point drops it.
        pending: u64 = 0,
        fired: u64 = 0,
        mons: []Mon = &.{},
        /// A monitor is being evaluated: probes read the tentative solution.
        mon_eval: bool = false,
        /// An absdelta enable transition at a consumed digital event reads
        /// the interpolated analog value at that event, not the future endpoint.
        mon_time: ?f64 = null,

        fn timeOf(s: *const Self, k: Tick, target: f64, horizon: Tick) f64 {
            const tk = @as(f64, @floatFromInt(k)) * s.opts.tick;
            return if (k == horizon and @abs(tk - target) <= ulps * target) target else tk;
        }

        /// The analog time of the digital tick being run: the tentative
        /// solution's when that is at or past this tick (time never runs
        /// back), else as `run` would solve it
        /// (§8.4.2: the DC point's before it opens the analysis).
        fn nowTime(s: *const Self) f64 {
            if (s.dc) return s.target;
            const k = s.dig.scheduler.now;
            if (s.acc) |ta| if (tickAtOrBefore(ta, s.opts.tick) >= k) return ta;
            return s.timeOf(k, s.target, tickAtOrBefore(s.target, s.opts.tick));
        }

        /// A solution at `t`, tentative: `acc` moves, `prev` does not.
        fn solve(s: *Self, t: f64) !void {
            try s.a.setInputs(s.dig, s.fired);
            try s.a.solveAt(t, if (s.prev) |p| t - p else 0.0, s.prev == null, t == s.final);
            s.acc = t;
        }

        /// The solution at `t`: a new time finishes the tentative one first.
        fn accept(s: *Self, t: f64) !void {
            return s.solveCarrying(t, true);
        }

        /// A solution at `t` carrying the pending explicit D2A terms. A new
        /// time finishes the tentative one first and, when `settle`, runs
        /// the A2D writes of that finished point (`settleA2d`).
        fn solveCarrying(s: *Self, t: f64, comptime settle: bool) !void {
            if (s.acc) |ta| if (ta != t) {
                try s.a.finish();
                s.prev = ta;
                s.fired = 0;
                if (settle) try s.settleA2d(tickAtOrBefore(ta, s.opts.tick));
            };
            s.fired |= s.pending;
            s.pending = 0;
            try s.solve(t);
        }

        /// VAMS §7.3.6.4: `finish` wrote the analog variables a digital
        /// expression reads (`digital.Run.a2dWrite`), each an A2D event at the
        /// finished time. The digital engine runs them now, so the next solve
        /// reads what they drive.
        // ponytail: the finished point is not re-solved for an implicit D2A
        // they cause (§8.4.3.2 "accept at wake-up time"); the next point is.
        fn settleA2d(s: *Self, horizon: Tick) !void {
            s.settling = true;
            defer s.settling = false;
            while (true) switch (try s.dig.runUntil(horizon)) {
                .idle => break,
                .explicit_d2a => try s.explicitD2a(),
                .analog => {},
                .vpi_sync => unreachable, // only `src/vpi` queues the marker
            };
        }

        /// §8.5.3.6 "An explicit D2A event is processed by evaluating the
        /// analog block": one evaluation per region-1b event. The terms of
        /// one 1b are delivered together to the next solve, so an earlier 1b
        /// of this tick still pending (a #0 delta cycle later) is evaluated
        /// first, with its own snapshot, and what its statements assigned is
        /// committed before this one's values replace the snapshot. That is
        /// `solveCarrying` without `settleA2d`: the tick is mid-flight, so the A2D
        /// writes of a point it finishes run with the rest of the tick.
        // ponytail: that evaluation reads the unguarded inputs as they are now,
        // not as they were at its 1b, and one pending while the finished point
        // settles its A2D writes stays coalesced with the next.
        fn explicitD2a(s: *Self) anyerror!void {
            if (s.pending != 0 and !s.settling) {
                try s.solveCarrying(s.nowTime(), false);
                try s.a.latch();
                s.fired = 0;
            }
            s.pending |= s.dig.d2a_fired;
            s.dig.d2a_fired = 0;
            try s.a.snapshot(s.dig);
        }

        fn monValue(s: *Self, j: usize) !f64 {
            return (try s.monArgAt(j, 0, null)).?;
        }

        fn monArgAt(s: *Self, j: usize, k: usize, t: ?f64) !?f64 {
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
        fn refreshTimers(s: *Self, t: f64) !bool {
            var posted = false;
            for (s.mons, 0..) |*m, j| if (m.kind == .timer) {
                const tm = &m.kind.timer;
                const start = (try s.monArgAt(j, 0, t)).?;
                const period = (try s.monArgAt(j, 1, t)) orelse 0;
                const ttol = (try s.monArgAt(j, 2, t)) orelse 0;
                const enable = (try s.monArgAt(j, 3, t)) orelse 1;
                const tok = s.dig.file.exprs.mainTok(s.dig.monitors.items[j].expr);
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
                try s.dig.deliverA2d(j, @intFromFloat(@round(t / s.opts.tick)));
                posted = true;
            };
            return posted;
        }

        const AbsdeltaArgs = struct { delta: f64, time_tol: f64, expr_tol: f64, enabled: bool };

        fn absdeltaArgs(s: *Self, j: usize, t: ?f64) !AbsdeltaArgs {
            const delta = (try s.monArgAt(j, 1, t)).?;
            const ttol = (try s.monArgAt(j, 2, t)) orelse 0;
            const etol = (try s.monArgAt(j, 3, t)) orelse 0;
            const enable = (try s.monArgAt(j, 4, t)) orelse 1;
            const tok = s.dig.file.exprs.mainTok(s.dig.monitors.items[j].expr);
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
        fn refreshAbsdelta(s: *Self, t: f64) !bool {
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
                try s.dig.deliverA2d(j, @intFromFloat(@round(t / s.opts.tick)));
                posted = true;
            };
            return posted;
        }

        /// Record only observed changes here. A numeric control changing while
        /// expr is constant must not itself create an event (§5.10.3.4).
        fn observeAbsdelta(s: *Self, j: usize) !void {
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

        const AbsdeltaEvent = struct { monitor: usize, t: f64, value: f64, observed: bool = false };

        fn nextAbsdelta(s: *Self, j: usize, base: f64, cursor: f64) !?AbsdeltaEvent {
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
        fn drainAbsdelta(s: *Self, base: f64, horizon: Tick) !void {
            var cursor = base;
            while (true) {
                var next: ?AbsdeltaEvent = null;
                for (s.mons, 0..) |m, j| if (m.kind == .absdelta) {
                    if (try s.nextAbsdelta(j, base, cursor)) |candidate| {
                        if (next == null or candidate.t < next.?.t) next = candidate;
                    }
                };
                const event_tick: ?Tick = if (next) |e| @intFromFloat(@round(e.t / s.opts.tick)) else null;
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
        fn active(s: *Self, enable: u8, j: usize) !bool {
            return ((try s.monArgAt(j, enable, null)) orelse 1) != 0;
        }

        /// One analog step toward `t_end`, which lies before the next digital
        /// event: §5.10.3.1 / §8.4.7 cut it at the first monitored crossing,
        /// deliver the A2D events it carries (§7.3.6.1, rounded per §8.4.3.3),
        /// then run the digital ticks at or before the step and re-solve at
        /// it for every D2A they cause (§8.4.3.2 "accept at wake-up time"),
        /// and re-check a `$monitor` that probes the solution at its tick.
        fn step(s: *Self, t_end: f64) !void {
            const base = s.acc.?;
            for (s.mons, 0..) |*m, j| if (m.kind != .timer) {
                m.v0 = try s.monValue(j);
            };
            try s.accept(t_end);
            // Secant cuts: a linear crossing is found by the first. A curve the
            // secant only creeps toward is halved instead after `max_secant`,
            // which closes on any sign change, so every crossing is cut to
            // within its time_tol, and its expr_tol: "both tolerances shall be
            // satisfied at the crossing" (§5.10.3.1). A cut must land strictly
            // inside (base, acc): when none does, base and acc are adjacent
            // floats and no tighter box exists, so the crossing is delivered
            // from acc (a time_tol below one ulp of the time; Vague_Decisions
            // §7). Each cut then moves acc down, and each bisection at least
            // halves acc - base, so the loop ends within `max_cuts`.
            var cuts: u32 = 0;
            while (true) : (cuts += 1) {
                std.debug.assert(cuts <= max_cuts);
                var cut: ?f64 = null;
                for (s.mons, 0..) |m, j| {
                    const c = switch (m.kind) {
                        .crossing => |c| c,
                        .timer, .absdelta => continue,
                    };
                    if (!try s.active(c.enable, j)) continue;
                    const v1 = try s.monValue(j);
                    if (!crosses(c.dir, m.v0, v1)) continue;
                    const tc = base + m.v0 / (m.v0 - v1) * (s.acc.? - base);
                    const late = s.acc.? - tc;
                    // ponytail: expr_tol stops binding within a few ulps of
                    // tc, where a jump in the expression can never meet it.
                    const off = @abs(v1) > c.etol and late > 4 * std.math.floatEps(f64) * @abs(tc);
                    if (late > c.tol or off) {
                        const slope = @abs(v1 - m.v0) / (s.acc.? - base);
                        const at = tc + @min(c.tol, c.etol / slope) / 2;
                        cut = @min(cut orelse at, at);
                    }
                }
                const c = cut orelse break;
                const t = if (cuts < max_secant) c else base + (s.acc.? - base) / 2;
                // Also false for a NaN `t`.
                if (!(t > base and t < s.acc.?)) break;
                try s.solve(t);
            }
            const tick: Tick = @intFromFloat(@round(s.acc.? / s.opts.tick));
            for (s.mons, 0..) |*m, j| switch (m.kind) {
                .timer => {}, // Refreshed together below, using current controls.
                .absdelta => try s.observeAbsdelta(j),
                .crossing => |c| if (try s.active(c.enable, j) and crosses(c.dir, m.v0, try s.monValue(j))) try s.dig.deliverA2d(j, tick),
            };
            _ = try s.refreshTimers(s.acc.?);
            const k = tickAtOrBefore(s.acc.?, s.opts.tick);
            try s.drainAbsdelta(base, k);
            // §8.4, IEEE 1364-2005 §17.1.3: this solution may move what a
            // probing `$monitor` reads although no digital event shares its
            // tick, so the tick is a time step of its own (`analogPoint`).
            // ponytail: a solution between ticks whose lower tick has run
            // is reported at the next tick a solution reaches.
            if (try s.dig.analogPoint(k)) try s.runDigital(k);
        }

        /// The digital ticks at or before `horizon`, re-solving at the current
        /// analog time for every D2A they cause.
        // ponytail: a D2A caused by interpolated A2D still re-solves the
        // endpoint; §8.4.6 needs rollback to the event and rejection of later
        // interpolated events from the old solution.
        fn runDigital(s: *Self, horizon: Tick) !void {
            while (true) switch (try s.dig.runUntil(horizon)) {
                .idle => {
                    const t = @as(f64, @floatFromInt(s.dig.scheduler.now)) * s.opts.tick;
                    const absdelta_posted = try s.refreshAbsdelta(t);
                    // A timer controls analog timepoints. Its probes read the
                    // current solution, even when the last digital tick was
                    // earlier (or rounded just before this analog time).
                    const timer_posted = try s.refreshTimers(s.acc.?);
                    if (absdelta_posted or timer_posted) continue;
                    break;
                },
                .explicit_d2a => try s.explicitD2a(),
                .analog => try s.accept(s.acc.?),
                .vpi_sync => unreachable, // only `src/vpi` queues the marker
            };
        }

        fn probeHook(ctx: *anyopaque, n1: []const u8, n2: ?[]const u8) digital.Error!f64 {
            const s: *Self = @ptrCast(@alignCast(ctx));
            // §7.3.6.3 "the analog value calculated for the time corresponding
            // to a real promotion of the digital time".
            const t: ?f64 = if (s.mon_eval) s.mon_time else if (s.acc == null) null else @as(f64, @floatFromInt(s.dig.scheduler.now)) * s.opts.tick;
            return s.a.probe(t, n1, n2) catch |e| s.dig.fail(0, "the analog solution has no V({s}{s}{s}): {t}", .{ n1, if (n2 != null) ", " else "", n2 orelse "", e });
        }
    };
}

// ---- tests: the real digital engine against a fake analog --------------------

const testing = std.testing;
const diag = @import("diag");

/// Reads one digital variable, and records every solve and every finish.
const Fake = struct {
    slot: u32,
    input: i64 = -1,
    fired: u64 = 0,
    snap: i64 = -1,
    slope: f64 = 0,
    power: f64 = 1,
    /// When set, the node is a step instead: -1 V before `jump`, 3 V from it.
    jump: ?f64 = null,
    timer_grid: ?struct { start: f64, period: f64 } = null,
    t: f64 = 0,
    solves: std.ArrayList(Point) = .empty,
    points: std.ArrayList(Point) = .empty,
    latched: std.ArrayList(Point) = .empty,
    gpa: std.mem.Allocator,
    const Point = struct { t: f64, dt: f64, v: i64, first: bool, last: bool, fired: u64 = 0, snap: i64 = -1 };

    pub fn setInputs(f: *Fake, dig: *digital.Run, fired: u64) !void {
        f.input = dig.values[f.slot].asInt() orelse -1;
        f.fired = fired;
    }
    pub fn snapshot(f: *Fake, dig: *digital.Run) !void {
        f.snap = dig.values[f.slot].asInt() orelse -1;
    }
    pub fn latch(f: *Fake) !void {
        try f.latched.append(f.gpa, f.solves.items[f.solves.items.len - 1]);
    }
    pub fn solveAt(f: *Fake, t: f64, dt: f64, first: bool, last: bool) !void {
        f.t = t;
        try f.solves.append(f.gpa, .{ .t = t, .dt = dt, .v = f.input, .first = first, .last = last, .fired = f.fired, .snap = f.snap });
    }
    /// The fake analog's one node follows `slope` volts per second, raised
    /// to `power`.
    pub fn probe(f: *Fake, t: ?f64, _: []const u8, _: ?[]const u8) !f64 {
        if (f.jump) |j| return if ((t orelse f.t) >= j) 3 else -1;
        return std.math.pow(f64, f.slope * (t orelse f.t), f.power);
    }
    pub fn finish(f: *Fake) !void {
        try f.points.append(f.gpa, f.solves.items[f.solves.items.len - 1]);
    }
    pub fn breakpoint(f: *Fake, t: f64) ?f64 {
        const grid = f.timer_grid orelse return null;
        return timer.zNextTimer(grid.start, grid.period, t);
    }
};

fn drive(arena: std.mem.Allocator, source: []const u8, name: []const u8, times: []const f64) !Fake {
    var bag = diag.Bag.init(arena);
    var out = std.Io.Writer.Allocating.init(arena);
    var dig = try digital.elaborate(arena, source, .{}, &bag, &out.writer);
    const slot = dig.slotOf(name).?;
    dig.watchAnalog(slot);
    var f: Fake = .{ .slot = slot, .gpa = arena };
    try run(Fake, &f, &dig, .{ .times = times, .tick = 1e-9 });
    return f;
}

fn expectPoints(f: Fake, want: []const [2]f64) !void {
    try testing.expectEqual(want.len, f.points.items.len);
    for (want, f.points.items) |w, p| {
        try testing.expectApproxEqAbs(w[0], p.t, 1e-18);
        try testing.expectEqual(@as(i64, @intFromFloat(w[1])), p.v);
    }
}

test "§7.3.6.5 the solve at t reads the greatest tick <= t, not the next and not the one before" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try drive(arena.allocator(),
        \\`timescale 1ns/1ns
        \\module m; reg [3:0] code;
        \\initial begin code = 4'd1; #10 code = 4'd5; #10 code = 4'd9; end
        \\endmodule
    , "code", &.{ 5e-9, 10e-9, 15e-9, 20e-9, 25e-9 });
    try expectPoints(f, &.{ .{ 5e-9, 1 }, .{ 10e-9, 5 }, .{ 15e-9, 5 }, .{ 20e-9, 9 }, .{ 25e-9, 9 } });
    // The first point is the DC point and the last carries final_step.
    try testing.expect(f.points.items[0].first and f.points.items[0].dt == 0);
    try testing.expect(f.points.items[4].last and !f.points.items[3].last);
}

test "§8.4.2 a run of one declared time is its DC point, first and last at once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // `v` is never assigned: x, which the fake reads as -1.
    const f = try drive(arena.allocator(),
        \\`timescale 1ns/1ns
        \\module m; reg v;
        \\endmodule
    , "v", &.{0});
    try expectPoints(f, &.{.{ 0, -1 }});
    const p = f.points.items[0];
    try testing.expect(p.first and p.last and p.dt == 0);
    try testing.expectEqual(@as(usize, 1), f.solves.items.len);
}

test "digital activity after the last declared time never reaches a solution" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try drive(arena.allocator(),
        \\`timescale 1ns/1ns
        \\module m; reg v;
        \\initial begin v = 0; #30 v = 1; end
        \\endmodule
    , "v", &.{ 0, 10e-9 });
    try expectPoints(f, &.{ .{ 0, 0 }, .{ 10e-9, 0 } });
}

test "§8.5.1 two writes in one tick reach one solution, with the tick's last value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try drive(arena.allocator(),
        \\`timescale 1ns/1ns
        \\module m; reg [3:0] v;
        \\initial begin v = 0; #4 v = 1; v = 2; end
        \\endmodule
    , "v", &.{ 0, 10e-9 });
    try expectPoints(f, &.{ .{ 0, 0 }, .{ 4e-9, 2 }, .{ 10e-9, 2 } });
    // One solve per point: region 3b runs once per tick (§8.5.1).
    try testing.expectEqual(@as(usize, 3), f.solves.items.len);
}

test "§8.4.7 an implicit D2A off the declared grid is an analog solution of its own" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try drive(arena.allocator(),
        \\`timescale 1ns/1ns
        \\module m; reg v;
        \\initial begin v = 0; #4 v = 1; end
        \\endmodule
    , "v", &.{ 0, 10e-9 });
    try expectPoints(f, &.{ .{ 0, 0 }, .{ 4e-9, 1 }, .{ 10e-9, 1 } });
    try testing.expectApproxEqAbs(@as(f64, 6e-9), f.points.items[2].dt, 1e-18);
}

test "§8.5.1 the region-3b solve sees the tick's nonblocking update, once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try drive(arena.allocator(),
        \\`timescale 1ns/1ns
        \\module m; reg clk, q;
        \\initial begin clk = 0; q = 0; #4 clk = 1; end
        \\always @(posedge clk) q <= 1;
        \\endmodule
    , "q", &.{ 0, 2e-9, 4e-9, 6e-9 });
    try expectPoints(f, &.{ .{ 0, 0 }, .{ 2e-9, 0 }, .{ 4e-9, 1 }, .{ 6e-9, 1 } });
    // One solve per point: `clk` is not an input, and 3b runs once per tick.
    try testing.expectEqual(@as(usize, 4), f.solves.items.len);
}

test "§8.4.2 time-zero digital activity settles before the DC solve" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try drive(arena.allocator(),
        \\`timescale 1ns/1ns
        \\module m; reg a; wire b, c;
        \\initial a = 1'b1;
        \\assign b = ~a;
        \\assign c = ~b;
        \\endmodule
    , "c", &.{0});
    try expectPoints(f, &.{.{ 0, 1 }});
}

test "digital activity before the first analog time folds into the DC point" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try drive(arena.allocator(),
        \\`timescale 1ns/1ns
        \\module m; reg [3:0] v;
        \\initial begin v = 1; #2 v = 2; #10 v = 3; end
        \\endmodule
    , "v", &.{ 5e-9, 20e-9 });
    try expectPoints(f, &.{ .{ 5e-9, 2 }, .{ 12e-9, 3 }, .{ 20e-9, 3 } });
}

test "§8.5.3.6 an explicit D2A reads region 1b's values and forces a solution at its tick" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag = diag.Bag.init(arena);
    var out = std.Io.Writer.Allocating.init(arena);
    var dig = try digital.elaborate(arena,
        \\`timescale 1ns/1ns
        \\module m; reg clk; integer da;
        \\initial begin clk = 0; da = 0; #4 clk = 1; end
        \\always @(posedge clk) begin da = 3; da <= 9; end
        \\endmodule
    , .{}, &bag, &out.writer);
    // The analog block waits on `posedge clk` (site 0) and reads `da` only
    // under it: `da` is snapshotted, not watched.
    try dig.watchEvent(dig.slotOf("clk").?, .posedge, 0);
    var f: Fake = .{ .slot = dig.slotOf("da").?, .gpa = arena };
    try run(Fake, &f, &dig, .{ .times = &.{ 0, 2e-9, 6e-9 }, .tick = 1e-9 });
    // 4 ns is a solution of its own (§8.4.7), carrying the event and da = 3
    // (after region 1, before the region-3 `da <= 9`); the next point does not
    // carry the event again.
    try testing.expectEqual(@as(usize, 4), f.points.items.len);
    const p = f.points.items[2];
    try testing.expectApproxEqAbs(@as(f64, 4e-9), p.t, 1e-18);
    try testing.expectEqual(@as(u64, 1), p.fired);
    try testing.expectEqual(@as(i64, 3), p.snap);
    try testing.expectEqual(@as(u64, 0), f.points.items[1].fired);
    try testing.expectEqual(@as(u64, 0), f.points.items[3].fired);
}

test "§8.5.3.6 an explicit D2A in each delta cycle of a tick is evaluated once each, with its own region-1b values" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag = diag.Bag.init(arena);
    var out = std.Io.Writer.Allocating.init(arena);
    var dig = try digital.elaborate(arena,
        \\`timescale 1ns/1ns
        \\module m; integer d;
        \\initial begin d = 1; #4 d = 2; #0 d = 3; end
        \\endmodule
    , .{}, &bag, &out.writer);
    try dig.watchEvent(dig.slotOf("d").?, .any, 0);
    var f: Fake = .{ .slot = dig.slotOf("d").?, .gpa = arena };
    try run(Fake, &f, &dig, .{ .times = &.{ 0, 2e-9, 6e-9 }, .tick = 1e-9 });
    // The cycle-1 event is evaluated at 4 ns with d = 2 and committed alone;
    // the cycle-2 event reaches the tick's own solution with d = 3.
    try testing.expectEqual(@as(usize, 1), f.latched.items.len);
    const l = f.latched.items[0];
    try testing.expectApproxEqAbs(@as(f64, 4e-9), l.t, 1e-18);
    try testing.expectEqual(@as(u64, 1), l.fired);
    try testing.expectEqual(@as(i64, 2), l.snap);
    try testing.expectEqual(@as(usize, 4), f.points.items.len);
    const p = f.points.items[2];
    try testing.expectApproxEqAbs(@as(f64, 4e-9), p.t, 1e-18);
    try testing.expectEqual(@as(u64, 1), p.fired);
    try testing.expectEqual(@as(i64, 3), p.snap);
}

test "§8.4.3.3 A2D crossings at 5.2 ns and 7.6 ns reach ticks 5 and 8; §7.3.6.3 a probe reads the promoted tick" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag = diag.Bag.init(arena);
    var out = std.Io.Writer.Allocating.init(arena);
    var dig = try digital.elaborate(arena,
        \\discipline electrical potential Voltage; flow Current; enddiscipline
        \\module m(vi);
        \\  inout vi; electrical vi;
        \\  integer lo, hi; real at;
        \\  initial begin lo = 0; hi = 0; at = 0.0; end
        \\  always @(cross(V(vi) - 0.52, +1, 1p)) begin lo = $time; at = V(vi); end
        \\  always @(cross(V(vi) - 0.76, +1, 1p)) hi = $time;
        \\endmodule
    , .{ .mixed = .{ .top = "m", .timescales = &.{.{ .at = 0, .value = .{ .unit = 1e-9, .precision = 1e-9 } }} } }, &bag, &out.writer);
    // V(vi) = 0.1 V/ns, so the crossings are at 5.2 ns and 7.6 ns.
    var f: Fake = .{ .slot = dig.slotOf("lo").?, .gpa = arena, .slope = 1e8 };
    dig.watchAnalog(f.slot);
    try run(Fake, &f, &dig, .{ .times = &.{ 0, 5e-9, 6e-9, 7e-9, 8e-9, 10e-9 }, .tick = 1e-9 });
    // The step to 6 ns was cut to within time_tol after 5.2 ns.
    const cut = for (f.points.items) |p| {
        if (p.t > 5.2e-9 and p.t <= 5.2e-9 + 1e-12) break p;
    } else return error.TestExpectedCut;
    // 5.2 rounds DOWN to tick 5, which the digital engine has passed: the A2D
    // runs at once and `lo` reaches the very solution that carried it.
    try testing.expectEqual(@as(i64, 5), cut.v);
    try testing.expectEqual(@as(?i64, 8), dig.values[dig.slotOf("hi").?].asInt());
    // The probe in the same process read V(vi) at 5.0 ns, the promoted tick,
    // not at 5.2 ns where the event was detected.
    const at: f64 = @bitCast(dig.values[dig.slotOf("at").?].values()[0]);
    try testing.expectApproxEqAbs(@as(f64, 0.5), at, 1e-12);
}

test "§8.4 / IEEE 1364-2005 §17.1.3 a probing $monitor reports at each analog solution no digital event shares" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag = diag.Bag.init(arena);
    var out = std.Io.Writer.Allocating.init(arena);
    var dig = try digital.elaborate(arena,
        \\discipline electrical potential Voltage; flow Current; enddiscipline
        \\module m(vi);
        \\  inout vi; electrical vi; integer u;
        \\  initial begin u = 0; $monitor("%0d %0d", $time, V(vi) > 1.5); end
        \\endmodule
    , .{ .mixed = .{ .top = "m", .timescales = &.{.{ .at = 0, .value = .{ .unit = 1e-9, .precision = 1e-9 } }} } }, &bag, &out.writer);
    // V(vi) = 1 V/ns. Nothing digital happens after time 0, so each report
    // past it comes from an analog solution's own tick. V(vi) is the operand:
    // it moves at 1 ns and 3 ns too, where `V(vi) > 1.5` does not.
    var f: Fake = .{ .slot = dig.slotOf("u").?, .gpa = arena, .slope = 1e9 };
    try run(Fake, &f, &dig, .{ .times = &.{ 0, 1e-9, 2e-9, 3e-9 }, .tick = 1e-9 });
    try testing.expectEqualStrings("0 0\n1 0\n2 1\n3 1\n", out.written());
}

test "§5.10.3.1 a crossing the secant only creeps toward is still cut to within time_tol" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag = diag.Bag.init(arena);
    var out = std.Io.Writer.Allocating.init(arena);
    var dig = try digital.elaborate(arena,
        \\discipline electrical potential Voltage; flow Current; enddiscipline
        \\module m(vi);
        \\  inout vi; electrical vi;
        \\  integer lo; initial lo = 0;
        \\  always @(cross(V(vi) - 0.5, +1, 1f)) lo = $time;
        \\endmodule
    , .{ .mixed = .{ .top = "m", .timescales = &.{.{ .at = 0, .value = .{ .unit = 1e-9, .precision = 1e-9 } }} } }, &bag, &out.writer);
    // V(vi) = (t / 1 s)^(1/8): steep at 0, flat by the crossing, where
    // (t)^(1/8) = 0.5 puts it at 2^-8 s. From a base at 0 every secant lands
    // after it and closes in far slower than 64 cuts can.
    var f: Fake = .{ .slot = dig.slotOf("lo").?, .gpa = arena, .slope = 1, .power = 0.125 };
    dig.watchAnalog(f.slot);
    try run(Fake, &f, &dig, .{ .times = &.{ 0, 1e-2 }, .tick = 1e-9 });
    const at = 1.0 / 256.0;
    for (f.solves.items) |p| {
        if (p.t > at and p.t <= at + 1e-15) return;
    }
    return error.TestExpectedCut;
}

test "§5.10.3.1 a step crossing with a time_tol below one ulp of time is cut to adjacent floats and delivered" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag = diag.Bag.init(arena);
    var out = std.Io.Writer.Allocating.init(arena);
    var dig = try digital.elaborate(arena,
        \\discipline electrical potential Voltage; flow Current; enddiscipline
        \\module m(vi);
        \\  inout vi; electrical vi;
        \\  integer n; initial n = 0;
        \\  always @(cross(V(vi), +1, 1e-30)) n = n + 1;
        \\endmodule
    , .{ .mixed = .{ .top = "m", .timescales = &.{.{ .at = 0, .value = .{ .unit = 1e-9, .precision = 1e-9 } }} } }, &bag, &out.writer);
    // V(vi) steps from -1 V to 3 V at 1/3 s. No two times 1e-30 s apart
    // exist near it (one ulp of 0.33 s is 5.6e-17 s), so the tightest cut
    // is the pair of adjacent floats around the step, and the crossing is
    // delivered once from there.
    var f: Fake = .{ .slot = dig.slotOf("n").?, .gpa = arena, .jump = 1.0 / 3.0 };
    dig.watchAnalog(f.slot);
    try run(Fake, &f, &dig, .{ .times = &.{ 0, 1 }, .tick = 1e-9 });
    try testing.expectEqual(@as(?i64, 1), dig.values[f.slot].asInt());
}

test "§5.10.3.4 absdelta interpolates digital events without forcing analog points" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag = diag.Bag.init(arena);
    var out = std.Io.Writer.Allocating.init(arena);
    var dig = try digital.elaborate(arena,
        \\discipline electrical potential Voltage; flow Current; enddiscipline
        \\module m(p);
        \\  inout p; electrical p;
        \\  integer n;
        \\  initial n = 0;
        \\  always @(absdelta(V(p), 0.25, 1p, 1u)) n = n + 1;
        \\endmodule
    , .{ .mixed = .{ .top = "m", .timescales = &.{.{ .at = 0, .value = .{ .unit = 1e-9, .precision = 1e-12 } }} } }, &bag, &out.writer);
    // The fake's 0.1 V/ns ramp has delta crossings at 2.5, 5 and 7.5 ns;
    // at 10 ns the remaining change equals delta, rather than exceeding it.
    // No watchAnalog: none of these A2D events causes a D2A. The only analog
    // solves must therefore be at the two times the host supplied: §8.4.1's
    // initialization (the analog initial block, before the digital ones) and
    // the DC point at 0, then 10 ns.
    var f: Fake = .{ .slot = dig.slotOf("n").?, .gpa = arena, .slope = 1e8 };
    try run(Fake, &f, &dig, .{ .times = &.{ 0, 10e-9 }, .tick = 1e-12 });
    try testing.expectEqual(@as(?i64, 4), dig.values[f.slot].asInt());
    try testing.expectEqual(@as(usize, 3), f.solves.items.len);
    try testing.expectEqual(@as(f64, 0), f.solves.items[1].t);
    try testing.expectEqual(@as(usize, 2), f.points.items.len);
    try testing.expectEqual(@as(f64, 0), f.points.items[0].t);
    try testing.expectEqual(@as(f64, 10e-9), f.points.items[1].t);
}

test "ams_zero_delta_ignores_tolerances_without_interpolation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag = diag.Bag.init(arena);
    var out = std.Io.Writer.Allocating.init(arena);
    var dig = try digital.elaborate(arena,
        \\discipline electrical potential Voltage; flow Current; enddiscipline
        \\module m(p);
        \\  inout p; electrical p; integer n;
        \\  initial n = 0;
        \\  always @(absdelta(V(p), 0.0, 1.0, 100.0)) begin
        \\    n = n + 1;
        \\    $display("%0d %g", $time, V(p));
        \\  end
        \\endmodule
    , .{ .mixed = .{ .top = "m", .timescales = &.{.{ .at = 0, .value = .{ .unit = 1e-9, .precision = 1e-12 } }} } }, &bag, &out.writer);
    var f: Fake = .{ .slot = dig.slotOf("n").?, .gpa = arena, .slope = 1e8 };
    try run(Fake, &f, &dig, .{ .times = &.{ 0, 10e-9 }, .tick = 1e-12 });
    try testing.expectEqual(@as(?i64, 2), dig.values[f.slot].asInt());
    try testing.expectEqualStrings("0 0\n10 1\n", out.written());
    try testing.expectEqual(@as(usize, 2), f.points.items.len);
    try testing.expectEqual(@as(f64, 0), f.points.items[0].t);
    try testing.expectEqual(@as(f64, 10e-9), f.points.items[1].t);
}

test "§5.10.3.4 invalid absdelta controls assigned at runtime report E0517" {
    for ([_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "delta", .value = "-1.0" },
        .{ .name = "ttol", .value = "-1p" },
        .{ .name = "etol", .value = "-1.0" },
        .{ .name = "en", .value = "0.5" },
    }) |c| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var bag = diag.Bag.init(arena);
        var out = std.Io.Writer.Allocating.init(arena);
        const source = try arena.print(
            \\discipline electrical potential Voltage; flow Current; enddiscipline
            \\module m(p);
            \\  inout p; electrical p;
            \\  integer n;
            \\  real delta, ttol, etol, en;
            \\  initial begin
            \\    n = 0; delta = 0.25; ttol = 1p; etol = 1u; en = 1.0;
            \\    #2 {s} = {s};
            \\  end
            \\  always @(absdelta(V(p), delta, ttol, etol, en)) n = n + 1;
            \\endmodule
        , .{ c.name, c.value });
        var dig = try digital.elaborate(arena, source, .{
            .mixed = .{ .top = "m", .timescales = &.{.{ .at = 0, .value = .{ .unit = 1e-9, .precision = 1e-12 } }} },
        }, &bag, &out.writer);
        try testing.expect(!bag.failed());
        var f: Fake = .{ .slot = dig.slotOf("n").?, .gpa = arena, .slope = 1e8 };
        try testing.expectError(error.DigitalFailed, run(Fake, &f, &dig, .{ .times = &.{ 0, 4e-9 }, .tick = 1e-12 }));
        try testing.expectEqual(@as(usize, 1), bag.count());
        try testing.expectEqual(diag.Code.E0517, bag.at(0).code);
        try testing.expectEqual(@as(?i64, 1), dig.values[f.slot].asInt());
    }
}

test "§7.8.4 an inserted bridge's digital half runs, and the analog reads it by its §6.7 path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag = diag.Bag.init(arena);
    var out = std.Io.Writer.Allocating.init(arena);
    // The source holds no bridge: `inserts` is the analog compile's §7.8.4
    // insertion, re-pointing u.q at the segment `y__d2a__ddiscrete.cm`.
    var dig = try digital.elaborate(arena,
        \\discipline electrical potential Voltage; flow Current; enddiscipline
        \\discipline ddiscrete domain discrete; enddiscipline
        \\connectmodule d2a(cm, el); input cm; output el; ddiscrete cm; electrical el; reg lvl;
        \\  always @(cm) lvl = cm;
        \\endmodule
        \\module src(q); output q; ddiscrete q; reg q; initial #4 q = 1'b1; endmodule
        \\module m; electrical y; src u(y); endmodule
    , .{ .mixed = .{
        .top = "m",
        .timescales = &.{.{ .at = 0, .value = .{ .unit = 1e-9, .precision = 1e-9 } }},
        .inserts = &.{.{ .path = "", .inst = "u", .port = "q", .module = "d2a", .name = "y__d2a__ddiscrete", .upper_port = "el", .lower_port = "cm" }},
    } }, &bag, &out.writer);
    var f: Fake = .{ .slot = dig.slotOf("y__d2a__ddiscrete.lvl").?, .gpa = arena };
    dig.watchAnalog(f.slot);
    try run(Fake, &f, &dig, .{ .times = &.{ 0, 10e-9 }, .tick = 1e-9 });
    // x (-1) until the child's write crosses the segment into the bridge.
    try expectPoints(f, &.{ .{ 0, -1 }, .{ 4e-9, 1 }, .{ 10e-9, 1 } });
    try testing.expect(dig.slotOf("y__d2a__ddiscrete.cm") != null);
}

test "§5.10.4 / §7.3.6.1 an analog timer's `-> ev` reaches `always @(ev)` at each firing, with a point there" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag = diag.Bag.init(arena);
    var out = std.Io.Writer.Allocating.init(arena);
    var dig = try digital.elaborate(arena,
        \\discipline electrical potential Voltage; flow Current; enddiscipline
        \\module m(p);
        \\  inout p; electrical p; event ev; integer hits;
        \\  initial hits = 0;
        \\  always @(ev) hits = hits + 1;
        \\  analog begin @(timer(5n, 10n)) -> ev; I(p) <+ 1m * hits; end
        \\endmodule
    , .{ .mixed = .{ .top = "m", .timescales = &.{.{ .at = 0, .value = .{ .unit = 1e-9, .precision = 1e-9 } }} } }, &bag, &out.writer);
    var f: Fake = .{ .slot = dig.slotOf("hits").?, .gpa = arena };
    dig.watchAnalog(f.slot);
    try run(Fake, &f, &dig, .{ .times = &.{ 0, 10e-9, 20e-9 }, .tick = 1e-9 });
    try expectPoints(f, &.{ .{ 0, 0 }, .{ 5e-9, 1 }, .{ 10e-9, 1 }, .{ 15e-9, 2 }, .{ 20e-9, 2 } });
}

test "§5.10.3.3 a monitored timer agrees with the host grid without duplicate analog points" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag = diag.Bag.init(arena);
    var out = std.Io.Writer.Allocating.init(arena);
    var dig = try digital.elaborate(arena,
        \\discipline electrical potential Voltage; flow Current; enddiscipline
        \\module m(p);
        \\  inout p; electrical p; event ev; integer hits;
        \\  initial hits = 0;
        \\  always @(ev) hits = hits + 1;
        \\  analog @(timer(2u, 1m)) -> ev;
        \\endmodule
    , .{ .mixed = .{ .top = "m", .timescales = &.{.{ .at = 0, .value = .{ .unit = 1e-3, .precision = 1e-9 } }} } }, &bag, &out.writer);
    var f: Fake = .{ .slot = dig.slotOf("hits").?, .gpa = arena, .timer_grid = .{ .start = 2e-6, .period = 1e-3 } };
    dig.watchAnalog(f.slot);
    try run(Fake, &f, &dig, .{ .times = &.{ 0, 4.096 }, .tick = 1e-9 });
    // The two host-supplied endpoints plus k=0..4095. A counted monitor
    // agrees with the host's closed-form schedule bit for bit; accumulation
    // used to create two neighboring analog points for one physical event.
    try testing.expectEqual(@as(?i64, 4096), dig.values[f.slot].asInt());
    try testing.expectEqual(@as(usize, 4098), f.points.items.len);
    for (f.points.items[1..4097], 0..) |p, k|
        try testing.expectEqual(2e-6 + @as(f64, @floatFromInt(k)) * 1e-3, p.t);
}

test "§5.10.3.3 runtime-invalid timer controls report E0517" {
    for ([_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "ttol", .value = "-1p" },
        .{ .name = "en", .value = "0.5" },
    }) |c| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var bag = diag.Bag.init(arena);
        var out = std.Io.Writer.Allocating.init(arena);
        const source = try arena.print(
            \\discipline electrical potential Voltage; flow Current; enddiscipline
            \\module m(p);
            \\  inout p; electrical p; event ev; integer hits;
            \\  real ttol, en;
            \\  initial begin hits = 0; ttol = 1p; en = 1; #2 {s} = {s}; end
            \\  always @(ev) hits = hits + 1;
            \\  analog @(timer(1n, 2n, ttol, en)) -> ev;
            \\endmodule
        , .{ c.name, c.value });
        var dig = try digital.elaborate(arena, source, .{
            .mixed = .{ .top = "m", .timescales = &.{.{ .at = 0, .value = .{ .unit = 1e-9, .precision = 1e-12 } }} },
        }, &bag, &out.writer);
        try testing.expect(!bag.failed());
        var f: Fake = .{ .slot = dig.slotOf("hits").?, .gpa = arena };
        try testing.expectError(error.DigitalFailed, run(Fake, &f, &dig, .{ .times = &.{ 0, 4e-9 }, .tick = 1e-12 }));
        try testing.expectEqual(@as(usize, 1), bag.count());
        try testing.expectEqual(diag.Code.E0517, bag.at(0).code);
        try testing.expectEqual(@as(?i64, 1), dig.values[f.slot].asInt());
    }
}
