//! The digital `Run` and the analog solver stepped together: the tentative
//! and finished solutions, the D2A events each solve carries, and the digital
//! ticks run between solves (`State(A)`, which `run.run` drives).
//! Cites: VAMS §7.3.6.3, §7.3.6.4, §7.3.6.5, §8.4.1, §8.4.2, §8.4.3.2, §8.4.7, §8.5.1, §8.5.3.6.
//!
//! Contents:
//! - `pub fn State(comptime A: type) type`
//! - `State.Error`
//! - `State.monValue`
//! - `State.monArgAt`
//! - `State.refreshTimers`
//! - `State.absdeltaArgs`
//! - `State.refreshAbsdelta`
//! - `State.observeAbsdelta`
//! - `State.nextAbsdelta`
//! - `State.drainAbsdelta`
//! - `State.active`
//! - `State.timeOf(s: *const Self, k: Tick, target: f64, horizon: Tick) f64`
//! - `State.tickNear(s: *const Self, t: f64) Tick`
//! - `State.nowTime(s: *const Self) f64`
//! - `State.solve(s: *Self, t: f64) Error!void`
//! - `State.accept(s: *Self, t: f64) Error!void`
//! - `State.solveCarrying(s: *Self, t: f64, comptime settle: bool) Error!void`
//! - `State.settleA2d(s: *Self, horizon: Tick) Error!void`
//! - `State.explicitD2a(s: *Self) Error!void`
//! - `State.step(s: *Self, t_end: f64) Error!void`
//! - `State.runDigital(s: *Self, horizon: Tick) Error!void`
//! - `State.probeHook(ctx: *anyopaque, n1: []const u8, n2: ?[]const u8) digital.Error!f64`

const std = @import("std");
const assert = std.debug.assert;
const digital = @import("../digital/root.zig");
const Tick = digital.Tick;
const time = @import("../time.zig");
const tickAtOrBefore = time.tickAtOrBefore;
const crosses = time.crosses;
const ulps = time.ulps;
const monitors = @import("monitors.zig");
const Mon = monitors.Mon;
const run = @import("run.zig");
const Options = run.Options;
const max_rejects = run.max_rejects;
const max_secant = run.max_secant;
const max_cuts = run.max_cuts;

// ponytail: the analog never steps past the next digital event (Figure 8-7's
// conservative half), so nothing is ever rolled back (§8.4.6) and an A2D is
// delivered once, from the solution that is kept. A step the analog device
// itself would reject (an analog-context `cross`) is not cut here: only the
// monitored events cut, through the host's own re-solve.
/// One analysis in flight over analog solver `A` (`run.run`'s interface).
/// Borrows `a` and `dig` for the analysis; owns nothing.
pub fn State(comptime A: type) type {
    return struct {
        const Self = @This();
        /// `run.RunError(A)`: what every step of the analysis can raise.
        pub const Error = run.RunError(A);
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

        // The monitor half lives in monitors.zig; these are its methods.
        const mon_methods = monitors.Monitors(Self);
        /// `monitors.monValue`: monitor `j`'s expression on the tentative solution.
        pub const monValue = mon_methods.monValue;
        /// `monitors.monArgAt`: argument `k` of monitor `j`, probes read at `t`.
        pub const monArgAt = mon_methods.monArgAt;
        /// `monitors.refreshTimers`: §5.10.3.3 timers due at `t` delivered.
        pub const refreshTimers = mon_methods.refreshTimers;
        const AbsdeltaArgs = mon_methods.AbsdeltaArgs;
        /// `monitors.absdeltaArgs`: §5.10.3.4 arguments of monitor `j`, checked.
        pub const absdeltaArgs = mon_methods.absdeltaArgs;
        /// `monitors.refreshAbsdelta`: an enable transition is an event.
        pub const refreshAbsdelta = mon_methods.refreshAbsdelta;
        /// `monitors.observeAbsdelta`: a reversal past `expr_tol` recorded.
        pub const observeAbsdelta = mon_methods.observeAbsdelta;
        const AbsdeltaEvent = mon_methods.AbsdeltaEvent;
        /// `monitors.nextAbsdelta`: monitor `j`'s next delta crossing in the step.
        pub const nextAbsdelta = mon_methods.nextAbsdelta;
        /// `monitors.drainAbsdelta`: the step's absdelta events, interleaved with digital work.
        pub const drainAbsdelta = mon_methods.drainAbsdelta;
        /// `monitors.active`: §5.10.3.1 whether a `cross`'s enable is nonzero.
        pub const active = mon_methods.active;

        /// Returns tick `k` in seconds; the horizon tick within rounding of
        /// `target` is `target` exactly. Asserts that `k <= horizon`.
        pub fn timeOf(s: *const Self, k: Tick, target: f64, horizon: Tick) f64 {
            assert(k <= horizon);
            assert(s.opts.tick > 0);
            const tk = @as(f64, @floatFromInt(k)) * s.opts.tick;
            return if (k == horizon and @abs(tk - target) <= ulps * target) target else tk;
        }

        /// Returns the tick nearest `t` seconds. Asserts that `t` is at or
        /// after 0 and below 2^64 ticks, as every time on `run`'s checked
        /// timeline is (`run.checkTimeline`).
        pub fn tickNear(s: *const Self, t: f64) Tick {
            assert(t >= 0);
            assert(t / s.opts.tick < 0x1p64);
            return @intFromFloat(@round(t / s.opts.tick));
        }

        /// The analog time of the digital tick being run: the tentative
        /// solution's when that is at or past this tick (time never runs
        /// back), else as `run` would solve it
        /// (§8.4.2: the DC point's before it opens the analysis).
        pub fn nowTime(s: *const Self) f64 {
            if (s.dc) return s.target;
            assert(s.opts.tick > 0);
            const k = s.dig.scheduler.now;
            if (s.acc) |ta| if (tickAtOrBefore(ta, s.opts.tick) >= k) return ta;
            return s.timeOf(k, s.target, tickAtOrBefore(s.target, s.opts.tick));
        }

        /// A solution at `t`, tentative: `acc` moves, `prev` does not. One
        /// the host rejects (`A.rejected`) halves the step from `prev` and is
        /// solved again; the first solution of the analysis has no earlier
        /// time to back up to.
        pub fn solve(s: *Self, t: f64) Error!void {
            if (s.prev) |p| assert(t >= p); // Time never runs back.
            var at = t;
            var tries: u32 = 0;
            while (true) : (tries += 1) {
                try s.a.setInputs(s.dig, s.fired);
                try s.a.solveAt(at, if (s.prev) |p| at - p else 0.0, s.prev == null, at == s.final);
                if (comptime !@hasDecl(A, "rejected")) break;
                const p = s.prev orelse break;
                if (!try s.a.rejected()) break;
                if (tries == max_rejects) return error.BackupExhausted;
                at = p + (at - p) / 2;
            }
            s.acc = at;
            if (s.prev) |p| assert(at >= p);
        }

        /// The solution at `t`: a new time finishes the tentative one first.
        pub fn accept(s: *Self, t: f64) Error!void {
            return s.solveCarrying(t, true);
        }

        /// A solution at `t` carrying the pending explicit D2A terms. A new
        /// time finishes the tentative one first and, when `settle`, runs
        /// the A2D writes of that finished point (`settleA2d`).
        pub fn solveCarrying(s: *Self, t: f64, comptime settle: bool) Error!void {
            if (s.acc) |ta| if (ta != t) {
                try s.a.finish();
                s.prev = ta;
                s.fired = 0;
                if (settle) try s.settleA2d(tickAtOrBefore(ta, s.opts.tick));
            };
            s.fired |= s.pending;
            s.pending = 0;
            try s.solve(t);
            assert(s.pending == 0);
        }

        /// VAMS §7.3.6.4: `finish` wrote the analog variables a digital
        /// expression reads (`digital.Run.a2dWrite`), each an A2D event at the
        /// finished time. The digital engine runs them now, so the next solve
        /// reads what they drive.
        // ponytail: the finished point is not re-solved for an implicit D2A
        // they cause (§8.4.3.2 "accept at wake-up time"); the next point is.
        /// Runs the digital ticks up to `horizon` that the finished point's
        /// A2D writes queued. Asserts that it does not nest.
        pub fn settleA2d(s: *Self, horizon: Tick) Error!void {
            assert(!s.settling);
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
        /// Region 1b: the pending explicit D2A terms evaluated, and this
        /// event's terms made pending (`digital.Run.d2a_fired`).
        pub fn explicitD2a(s: *Self) Error!void {
            if (s.pending != 0 and !s.settling) {
                try s.solveCarrying(s.nowTime(), false);
                try s.a.latch();
                s.fired = 0;
            }
            s.pending |= s.dig.analog.d2a_fired;
            s.dig.analog.d2a_fired = 0;
            assert(s.dig.analog.d2a_fired == 0);
            try s.a.snapshot(s.dig);
        }

        /// One analog step toward `t_end`, which lies before the next digital
        /// event: §5.10.3.1 / §8.4.7 cut it at the first monitored crossing,
        /// deliver the A2D events it carries (§7.3.6.1, rounded per §8.4.3.3),
        /// then run the digital ticks at or before the step and re-solve at
        /// it for every D2A they cause (§8.4.3.2 "accept at wake-up time"),
        /// and re-check a `$monitor` that probes the solution at its tick.
        pub fn step(s: *Self, t_end: f64) Error!void {
            const base = s.acc.?;
            assert(t_end >= base); // `run` steps forward from the tentative time.
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
            const tick = s.tickNear(s.acc.?);
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
            assert(s.acc.? >= base);
        }

        /// The digital ticks at or before `horizon`, re-solving at the current
        /// analog time for every D2A they cause.
        // ponytail: a D2A caused by interpolated A2D still re-solves the
        // endpoint; §8.4.6 needs rollback to the event and rejection of later
        // interpolated events from the old solution.
        /// Runs the digital ticks at or before `horizon`, re-solving for every
        /// D2A they cause. Asserts that a tentative solution exists.
        pub fn runDigital(s: *Self, horizon: Tick) Error!void {
            assert(s.acc != null);
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

        /// `digital.Run.analog.probe`: §7.3.6.3 V(n1, n2) for a digital read, at the
        /// promoted digital time. `ctx` is the `*Self` `run` installed.
        pub fn probeHook(ctx: *anyopaque, n1: []const u8, n2: ?[]const u8) digital.Error!f64 {
            // SAFETY: `run` sets `probe_ctx` to its own `*Self` with this hook.
            const s: *Self = @ptrCast(@alignCast(ctx));
            assert(s.dig.analog.probe_ctx == ctx);
            // §7.3.6.3 "the analog value calculated for the time corresponding
            // to a real promotion of the digital time".
            const t: ?f64 = if (s.mon_eval) s.mon_time else if (s.acc == null) null else @as(f64, @floatFromInt(s.dig.scheduler.now)) * s.opts.tick;
            return s.a.probe(t, n1, n2) catch |e| s.dig.fail(0, "the analog solution has no V({s}{s}{s}): {t}", .{ n1, if (n2 != null) ", " else "", n2 orelse "", e });
        }
    };
}
