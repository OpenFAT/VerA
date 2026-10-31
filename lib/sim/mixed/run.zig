//! A digital `Run` and an analog solver in, one mixed-signal analysis on a
//! common global time out (VAMS §8.4.4, §7.3.6): `run`, the spine that walks
//! the declared timepoints and hands each step to `coordinator.State(A)`.
//! The analog side is a comptime interface (`run`'s `A`), so the tests below
//! drive the real digital engine against a fake solver.
//! Cites: VAMS §7.3.5, §7.3.6, §8.4, §8.5, §5.10.3; IEEE 1364-2005 §17.1.3.
//!
//! Contents:
//! - `pub const Options = struct`
//! - `pub const max_rejects`
//! - `pub const max_secant`
//! - `pub const max_cuts`
//! - `pub const default_time_tol`
//! - `pub const default_expr_tol`
//! - `Fake.setInputs(f: *Fake, dig: *digital.Run, fired: u64) !void`
//! - `Fake.snapshot(f: *Fake, dig: *digital.Run) !void`
//! - `Fake.latch(f: *Fake) !void`
//! - `Fake.solveAt(f: *Fake, t: f64, dt: f64, first: bool, last: bool) !void`
//! - `Fake.probe(f: *Fake, t: ?f64, _: []const u8, _: ?[]const u8) !f64`
//! - `Fake.finish(f: *Fake) !void`
//! - `Fake.breakpoint(f: *Fake, t: f64) ?f64`
//! - `pub fn run(comptime A: type, a: *A, dig: *digital.Run, opts: Options) !void`

const std = @import("std");
const assert = std.debug.assert;
const digital = @import("../digital/root.zig");
const time = @import("../time.zig");
const tickAtOrBefore = time.tickAtOrBefore;
const timer = @import("kernels").timer_kernels;
const coordinator = @import("coordinator.zig");
const monitors = @import("monitors.zig");
const State = coordinator.State;
const Mon = monitors.Mon;
const testing = std.testing;
const diag = @import("diag");

/// One analysis's timeline, as `run` reads it.
pub const Options = struct {
    /// The declared analog timepoints, in seconds, ascending. `times[0]` is the
    /// DC point that opens the analysis (§8.4.2); the rest are transient
    /// points. Implicit D2A points are inserted between them.
    times: []const f64,
    /// One scheduler tick, in seconds: the design's finest time precision.
    tick: f64,
};

/// Rejections of one tentative solution `solve` backs up from before it
/// gives up, as the VPI walk does (`src/vpi/analog.zig`).
pub const max_rejects = 60;

/// Secant cuts `step` tries before it halves the step instead.
pub const max_secant = 64;

/// Cuts one step can take: `max_secant`, then bisections. Each bisection
/// halves acc - base or ends the loop, and an f64 interval shrinks to one ulp
/// in at most 2098 + 52 halvings (the exponent range plus the mantissa).
pub const max_cuts = max_secant + 2150;

/// §5.10.3.1 leaves an absent `time_tol` to the tool.
pub const default_time_tol = 1e-12;

/// §5.10.3.4 lets the tool choose an absent/zero expression tolerance.
pub const default_expr_tol = 1e-12;

/// Test support: an analog side that reads one digital variable and
/// records every solve and every finish.
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

    /// `run`'s `A.setInputs`, recorded.
    pub fn setInputs(f: *Fake, dig: *digital.Run, fired: u64) !void {
        f.input = dig.values[f.slot].asInt() orelse -1;
        f.fired = fired;
    }
    /// `run`'s `A.snapshot`, recorded.
    pub fn snapshot(f: *Fake, dig: *digital.Run) !void {
        f.snap = dig.values[f.slot].asInt() orelse -1;
    }
    /// `run`'s `A.latch`, recorded.
    pub fn latch(f: *Fake) !void {
        try f.latched.append(f.gpa, f.solves.items[f.solves.items.len - 1]);
    }
    /// `run`'s `A.solveAt`, recorded.
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
    /// `run`'s `A.finish`, recorded.
    pub fn finish(f: *Fake) !void {
        try f.points.append(f.gpa, f.solves.items[f.solves.items.len - 1]);
    }
    /// `run`'s `A.breakpoint`, recorded.
    pub fn breakpoint(f: *Fake, t: f64) ?f64 {
        const grid = f.timer_grid orelse return null;
        return timer.zNextTimer(grid.start, grid.period, t);
    }
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
///   rejected(a)                   optional: whether the host rejected the
///                                 tentative solution `solveAt` just made (VPI
///                                 §12.36 vpiRejectTransientStep, §12.31.3
///                                 acbConvergenceTest); the step is halved and
///                                 solved again before any event reads it, so an
///                                 A2D event of a rejected solution is never
///                                 delivered (§8.4.7)
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

// ---- private ----

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

test "§8.4.7 a rejected tentative solution is solved again halfway back, and its crossing is delivered once" {
    // A host (VPI §12.36 vpiRejectTransientStep) rejects the first solution
    // at or after the crossing: the step halves from the last finished point
    // and the crossing, found again, reaches the digital process once.
    const Rejecting = struct {
        f: Fake,
        at: f64,
        done: bool = false,
        rejected_t: f64 = 0,
        const Self = @This();
        pub fn setInputs(r: *Self, dig: *digital.Run, fired: u64) !void {
            return r.f.setInputs(dig, fired);
        }
        pub fn snapshot(r: *Self, dig: *digital.Run) !void {
            return r.f.snapshot(dig);
        }
        pub fn latch(r: *Self) !void {
            return r.f.latch();
        }
        pub fn solveAt(r: *Self, t: f64, dt: f64, first: bool, last: bool) !void {
            return r.f.solveAt(t, dt, first, last);
        }
        pub fn rejected(r: *Self) !bool {
            if (r.done or r.f.t < r.at) return false;
            r.done = true;
            r.rejected_t = r.f.t;
            return true;
        }
        pub fn probe(r: *Self, t: ?f64, n1: []const u8, n2: ?[]const u8) !f64 {
            return r.f.probe(t, n1, n2);
        }
        pub fn finish(r: *Self) !void {
            return r.f.finish();
        }
    };
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
        \\  always @(cross(V(vi) - 2.5, +1, 1p)) n = n + 1;
        \\endmodule
    , .{ .mixed = .{ .top = "m", .timescales = &.{.{ .at = 0, .value = .{ .unit = 1e-9, .precision = 1e-12 } }} } }, &bag, &out.writer);
    const n = dig.slotOf("n").?;
    var r: Rejecting = .{ .f = .{ .slot = n, .gpa = arena, .slope = 1000 }, .at = 2.5e-3 };
    try run(Rejecting, &r, &dig, .{ .times = &.{ 0, 1e-3, 2e-3, 3e-3, 4e-3, 5e-3 }, .tick = 1e-12 });
    try testing.expect(r.done);
    // The step to the rejected time (3 ms, a declared point solved again
    // later) was halved: the solve after it, and the point finished after
    // 2 ms, are halfway back from 2 ms.
    const half = 2e-3 + (r.rejected_t - 2e-3) / 2;
    const after = for (r.f.solves.items, 0..) |p, i| {
        if (p.t == r.rejected_t) break r.f.solves.items[i + 1].t;
    } else unreachable;
    try testing.expectApproxEqAbs(half, after, 1e-15);
    const next = for (r.f.points.items, 0..) |p, i| {
        if (p.t == 2e-3) break r.f.points.items[i + 1].t;
    } else unreachable;
    try testing.expectApproxEqAbs(half, next, 1e-15);
    try testing.expectEqual(@as(?i64, 1), dig.values[n].asInt());
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
