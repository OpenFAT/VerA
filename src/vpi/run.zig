//! The digital run a VPI application's time callbacks live in: the engine's
//! IEEE 1364 §11.4 loop (`lib/sim/digital`), driven one time queue at a time
//! with §12.31.2's callback moments cut into it, plus §12.15 vpi_get_time,
//! §12.36 vpi_sim_control (vpiReset: IEEE 1364-2005 C.7) and §11.6.25 time
//! queues.

const std = @import("std");
const sim = @import("sim");
const root = @import("root.zig");
const property = @import("property.zig");
const iterate = @import("iterate.zig");
const handle = @import("handle.zig");
const callback = @import("callback.zig");
const value = @import("value.zig");
const analog = @import("analog.zig");
const va = @import("va.zig");
const code = @import("code.zig");

/// `varargs.c`, for the tests below.
extern fn vpi_sim_control(operation: c_int, ...) c_int;

const digital = sim.digital;
const Time = callback.Time;
const vpiHandle = root.vpiHandle;

var engine: ?*digital.Run = null;
var clock: u64 = 0;

/// Returns the clock in engine ticks. After the run it holds the time the run
/// ended at, so a cbEndOfSimulation reads that.
pub fn now() u64 {
    return clock;
}

/// Binds the engine an `openDigital` model was built over, at its current
/// time (0: §12.31.4's cbStartOfSimulation is "beginning of time 0").
pub fn attach(r: *digital.Run) void {
    engine = r;
    clock = r.scheduler.now;
    // §12.31.1 cbForce/cbRelease/cbAssign/cbDeassign/cbDisable on design
    // statements; a callback registered before elaboration counts too.
    r.done_hook = callback.onDone;
    // VAMS 12.31.4 cbTchkViolation on the engine's timing checks.
    r.tchk_hook = callback.onTchk;
}

/// Unbinds the engine and invalidates every time-queue handle.
pub fn detach() void {
    engine = null;
    clock = 0;
    started = false;
    reset_request = null;
    var it = queues.valueIterator();
    while (it.next()) |q| gpa.destroy(q.*);
    queues.clearAndFree(gpa);
    queue_live.clearAndFree(gpa);
}

/// The run `attach` installed (`root.openDigital`), until `detach`; null for
/// the analog model.
pub fn attached() ?*digital.Run {
    return engine;
}

/// Runs the attached design to `$finish`, an empty queue, or an application's
/// vpiFinish, then fires §12.31.4's cbEndOfSimulation. Each time `t` that
/// holds an event or a time callback (§12.31.2: "even if no event is
/// present") runs, in order:
///
///   cbNextSimTime                     "before execution of events in the
///                                     next event queue"
///   cbAtStartOfSimTime, cbAfterDelay  before the queue's events, even empty
///   every event at t                  `runUntil(t)`
///   cbReadWriteSynch                  after the events; what it schedules
///                                     at t runs before t is left
///   cbReadOnlySynch                   the same, with writes refused
///
/// An application's vpiReset stops the queue it was asked in; the run is
/// then reset (IEEE 1364-2005 C.7) and either goes on from time 0 or ends.
///
/// A design that calls a registered system task as a function
/// (`systf.misuse`, IEEE 1364-2005 §20.3) does not run: DigitalFailed.
pub fn simulate() digital.Error!void {
    const r = engine orelse return;
    if (@import("systf.zig").misuse != null) return error.DigitalFailed;
    callback.startOfSimulation();
    started = false;
    var resets: u32 = 0;
    while (true) {
        try timeSteps(r);
        // §12.36 vpiReset, "upon return of user VPI function".
        const go = reset_request orelse break;
        reset_request = null;
        // An application that asks again on every run would never let it
        // end; neither 12.36 nor C.7 bounds the count (Vague_Decisions §7).
        if (resets == max_resets) {
            const e = r.fail(0, "more than {d} vpiReset requests in one run: an application that resets every run never lets it end", .{max_resets});
            callback.runError(e);
            return e;
        }
        resets += 1;
        callback.startOfReset();
        r.reset() catch |e| {
            callback.runError(e);
            return e;
        };
        value.dropScheduled();
        clock = 0;
        started = false;
        callback.endOfReset();
        // C.7: "A value of 0 or no argument causes interactive mode to be
        // entered after resetting the tool", which a batch run has not, so
        // it ends there as $stop does (VD-070, VD-106).
        if (!go) {
            r.scheduler.finish();
            break;
        }
    }
    callback.endOfSimulation();
}

/// The vpiResets `simulate` performs in one run before it refuses the next
/// request (E1100). Each reset re-elaborates the design and keeps the old
/// run's memory (VD-106), so the cap also bounds that.
pub const max_resets: u32 = 1000;

/// A §12.36 vpiReset an application asked for: whether the run goes on
/// after it (a nonzero stop_value). `simulate` performs it once the
/// application's routine has returned and the engine has stopped.
var reset_request: ?bool = null;

/// The time queues of one run, from its current time to `$finish`, an empty
/// queue, a vpiFinish or a vpiReset.
fn timeSteps(r: *digital.Run) digital.Error!void {
    // Passes of the loop below at one time. A time callback that registers
    // another at its own time (a cbReadWriteSynch from a cbReadWriteSynch)
    // brings the loop back to `t` with no event the engine's budget counts,
    // so the passes are counted against that budget themselves.
    var passes: u64 = 0;
    var pass_time: ?u64 = null;
    while (!stopped(r)) {
        const ev = r.scheduler.peekTime();
        const due = callback.nextDue(clock, true);
        const t = earliest(ev, due) orelse break;
        if (pass_time != t) {
            pass_time = t;
            passes = 0;
        }
        passes += 1;
        if (passes > r.budget) {
            const e = r.fail(0, "more than {d} callback passes at time {d}: a time callback that registers another at its own time keeps simulation time from advancing", .{ r.budget, t });
            callback.runError(e);
            return e;
        }
        if (t > clock) {
            // Every event at or before `clock` has run and the next is at `t`,
            // so moving the clock to `t` skips nothing. The engine's own clock
            // moves with it: a delay an application schedules from a
            // start-of-time callback counts from `t`, not from the last queue.
            clock = t;
            r.scheduler.now = t;
            started = false;
            callback.fireNext(t);
        }
        callback.fireDue(callback.cbAtStartOfSimTime, t);
        started = true;
        callback.fireDue(callback.cbAfterDelay, t);
        if (stopped(r)) break;
        // VAMS §8.5.1: a read-write callback "shall be treated as inactive
        // events": after the active events at `t`, before its nonblocking
        // updates. A due one asks the engine to stop at `t`'s inactive point
        // (`Scheduler.sync_at`), where it runs. What is left of `t` (the
        // updates, work a callback scheduled, a callback a change registered)
        // is another pass of this loop, so the pass budget above bounds a
        // callback that keeps registering another at its own time.
        if (callback.isDue(callback.cbReadWriteSynch, t)) r.scheduler.sync_at = t;
        const stop = try runUntil(r, t);
        r.scheduler.sync_at = null;
        if (stopped(r)) break;
        if (stop == .vpi_sync or callback.isDue(callback.cbReadWriteSynch, t)) {
            callback.fireDue(callback.cbReadWriteSynch, t);
            continue;
        }
        read_only = true;
        callback.fireDue(callback.cbReadOnlySynch, t);
        read_only = false;
    }
}

/// True inside a cbReadOnlySynch dispatch, where §12.31.2 forbids "writing
/// values or scheduling events".
pub var read_only: bool = false;

/// True once the current time slice has passed its cbAtStartOfSimTime
/// callbacks (IEEE 1364-2005 §27.33.2 "progressed into a time slice").
pub var started: bool = false;

/// The engine's events at `t`; a failure fires cbError first (IEEE 1364-2005
/// §27.33.3 "Simulation run-time error occurred").
fn runUntil(r: *digital.Run, t: u64) digital.Error!digital.Stop {
    return r.runUntil(t) catch |e| {
        callback.runError(e);
        return e;
    };
}

fn stopped(r: *digital.Run) bool {
    return r.scheduler.phase == .stopped;
}

fn earliest(a: ?u64, b: ?u64) ?u64 {
    if (a == null) return b;
    if (b == null) return a;
    return @min(a.?, b.?);
}

/// The time scale of `obj`'s module (IEEE 1364 §19.8: each definition has
/// its own), as engine ticks per time unit. A module object is in its own
/// scope; any other object in the scope that declares it.
fn scale(obj: vpiHandle) ?sim.time.Scale {
    const r = engine orelse return null;
    const o = root.asObj(obj) orelse return r.scale;
    // `timeOf` takes the ENGINE's scope id, which a lexical engine scope (a
    // generate iteration, a task frame) can set apart from the model's index.
    const sc = if (o.kind == .module) o.scope else o.owner.get() orelse 0;
    return r.timeOf(root.design.?.scopes[sc].engine).scale;
}

/// A §12.15 time structure as engine ticks. vpiSimTime is ticks already.
/// vpiScaledRealTime is in the time unit of `obj`'s module — "the indicated
/// time shall be in the timescale associated with the object" (§12.30) — or,
/// with no object, in "the simulation time unit" (§12.15), which is a tick.
/// Null, with the error recorded, when the value is not a time.
pub fn ticksOf(t: Time, obj: vpiHandle) ?u64 {
    if (t.type == callback.vpiSimTime) return (@as(u64, t.high) << 32) | t.low;
    if (!std.math.isFinite(t.real) or t.real < 0) {
        root.fail("BADTIME", "{d} is not a time", .{t.real});
        return null;
    }
    if (obj != null) if (scale(obj)) |s| return s.realDelay(t.real) catch {
        root.fail("BADTIME", "{d} cannot be represented in engine ticks", .{t.real});
        return null;
    };
    const ticks = @round(t.real);
    // A tick count is a u64: 2^64 and past are no tick this run reaches.
    if (ticks >= 18446744073709551616.0) {
        root.fail("BADTIME", "{d} is past the last engine tick", .{t.real});
        return null;
    }
    return @intFromFloat(ticks);
}

/// Fill `t` with the current time in the format `t.type` names: §12.15
/// "using the time scale of the object. If obj is NULL, the simulation time is
/// retrieved using the simulation time unit."
pub fn timeNow(obj: vpiHandle, t: *Time) void {
    fillTime(clock, obj, t);
}

/// Fills both of `t`'s forms from `ticks`: high/low in ticks, and `real` in
/// `obj`'s module time unit (in ticks when `obj` is NULL).
fn fillTime(ticks: u64, obj: vpiHandle, t: *Time) void {
    t.high = @truncate(ticks >> 32);
    t.low = @truncate(ticks);
    t.real = if (obj != null) unitsOf(ticks, obj) else @floatFromInt(ticks);
}

/// `ticks` in the time unit of `obj`'s module, the inverse of `ticksOf`'s
/// scaled form; in ticks when no digital run gives it a scale.
pub fn unitsOf(ticks: u64, obj: vpiHandle) f64 {
    return if (scale(obj)) |s| s.realAt(ticks) else @floatFromInt(ticks);
}

// ---------------------------------------------------------------------------
// §12.15 vpi_get_time
// ---------------------------------------------------------------------------

/// §11.6.25's object type, Annex G numbering.
pub const vpiTimeQueue: c_int = 64;

/// "shall retrieve the current simulation time, using the time scale of the
/// object. If obj is NULL, the simulation time is retrieved using the
/// simulation time unit." A §11.6.25 time queue answers ITS time — which is
/// how an application reads the pending times it iterated.
pub export fn vpi_get_time(obj: vpiHandle, time_p: ?*Time) void {
    if (root.refused("vpi_get_time")) return;
    const t = time_p orelse {
        root.fail("BADTIME", "vpi_get_time: time_p is NULL", .{});
        return;
    };
    // §12.15 analog time: the §12.9 value, in seconds whatever the object.
    if (t.type == callback.vpiAnalogTime) {
        t.real = analog.vpi_get_analog_time();
        return;
    }
    if (t.type != callback.vpiSimTime and t.type != callback.vpiScaledRealTime) {
        root.fail("BADTIME", "vpi_get_time: time type {d} is not vpiSimTime, vpiScaledRealTime or vpiAnalogTime", .{t.type});
        return;
    }
    if (obj == null) return fillTime(clock, null, t);
    if (asQueue(obj)) |q| return fillTime(q.time, null, t);
    _ = root.asObj(obj) orelse {
        root.fail("BADHANDLE", "vpi_get_time: that handle is not an object", .{});
        return;
    };
    fillTime(clock, obj, t);
}

// ---------------------------------------------------------------------------
// §12.36 vpi_sim_control
// ---------------------------------------------------------------------------

// §12.36 operations, Annex G numbering.
pub const vpiStop: c_int = 66;
pub const vpiFinish: c_int = 67;
pub const vpiReset: c_int = 68;
pub const vpiSetInteractiveScope: c_int = 69;
/// VAMS §12.36 names it and gives no number; VerA allocates it (vpi_user.h).
pub const vpiRejectTransientStep: c_int = 730;
/// VAMS §12.36, likewise VerA's number.
pub const vpiTransientFailConverge: c_int = 731;

/// §12.36: returns 1 on success, 0 on failure.
///
/// vpiFinish ends the run where it is: a callback sits between dispatches, so
/// finishing now is "upon return of user function", and cbEndOfSimulation
/// fires at the request's time. The diagnostic-level argument is ignored.
/// vpiStop is "$stop ... upon return", and a VerA run has no interactive mode
/// to suspend into, so its $stop ends the run as the analog one does
/// (`cg_display.emitSimCtl`): vpiStop is vpiFinish here.
///
/// vpiSetInteractiveScope (one vpiHandle of the scope class) fires IEEE
/// 1364-2005 §27.33.3's cbInteractiveScopeChange with the new scope.
/// ponytail: the scope is not kept, because nothing here reads an
/// interactive scope (no interactive mode, no $scope); keep it when one does.
///
/// vpiReset (stop_value, reset_value, diagnostic_level) is IEEE 1364-2005
/// C.7's $reset "upon return": the engine stops dispatching, and once the
/// routine has returned `simulate` resets the run (`digital.Run.reset`: time
/// 0, every reg and net at its initial value, every process from its first
/// statement, every scheduled event gone) and goes on from time 0 when
/// stop_value is nonzero, else ends the run (C.7's interactive mode, which a
/// batch run reads as $stop). Registered callbacks stand; cbStartOfSimulation
/// does not fire again (VD-106). IEEE 1364-2005 §27.33.3's cbStartOfReset
/// fires just before the reset and cbEndOfReset just after it.
///
/// vpiRejectTransientStep (one double: the current timestep) rejects the
/// analog solution being attempted (`analog.rejectStep`), and fails when none
/// is. vpiTransientFailConverge (no argument) solves the awaiting solution's
/// time again (`analog.failConverge`), and fails when none is awaiting.
///
/// The body of `varargs.c`'s vpi_sim_control and of vpi_control, the same
/// routine under its IEEE 1364-2005 §27.3 name.
export fn vera_vpi_control(operation: c_int, ap: *va.List) c_int {
    root.clearError();
    switch (operation) {
        vpiFinish, vpiStop => {
            _ = va.arg(ap, c_int); // the diagnostic level, as $finish(n) / $stop(n)
            const r = engine orelse {
                root.fail("NORUN", "vpi_sim_control({s}): no simulation is running", .{if (operation == vpiStop) "vpiStop" else "vpiFinish"});
                return 0;
            };
            r.scheduler.finish();
            return 1;
        },
        vpiSetInteractiveScope => {
            const h = va.arg(ap, ?*anyopaque);
            const o = root.asObj(h) orelse {
                root.fail("BADHANDLE", "vpi_sim_control(vpiSetInteractiveScope): the argument is not a handle to an object", .{});
                return 0;
            };
            const scope = o.kind == .module or (o.kind == .code and (o.vtype == code.vpiTask or o.vtype == code.vpiFunction or
                o.vtype == code.vpiNamedBegin or o.vtype == code.vpiNamedFork or o.vtype == code.vpiGenScope));
            if (!scope) {
                root.fail("NOTSCOPE", "vpi_sim_control(vpiSetInteractiveScope): `{s}` is not a scope", .{o.full});
                return 0;
            }
            callback.interactiveScopeChange(o);
            return 1;
        },
        vpiRejectTransientStep => {
            _ = va.arg(ap, f64); // the current timestep, as vpi_get_analog_delta
            if (analog.rejectStep()) return 1;
            root.fail("NOSTEP", "vpi_sim_control(vpiRejectTransientStep): no analog solution after the first is awaiting acceptance", .{});
            return 0;
        },
        vpiTransientFailConverge => {
            if (analog.failConverge()) return 1;
            root.fail("NOSTEP", "vpi_sim_control(vpiTransientFailConverge): no analog solution is awaiting acceptance", .{});
            return 0;
        },
        vpiReset => {
            const stop_value = va.arg(ap, c_int);
            _ = va.arg(ap, c_int); // reset_value: what $reset_value returns, which VerA does not have (VD-106)
            _ = va.arg(ap, c_int); // diagnostic_level: VerA prints no reset diagnostics
            const r = engine orelse {
                root.fail("NORUN", "vpi_sim_control(vpiReset): no digital simulation is running", .{});
                return 0;
            };
            reset_request = stop_value != 0;
            // The engine dispatches nothing more of the run being reset.
            r.scheduler.finish();
            return 1;
        },
        else => {
            root.fail("NOCONTROL", "vpi_sim_control: {d} is not a §12.36 operation", .{operation});
            return 0;
        },
    }
}

// ---------------------------------------------------------------------------
// §11.6.25 time queues
// ---------------------------------------------------------------------------

/// One pending time. Interned per time, so two iterations hand out the same
/// handle for the same queue and vpi_compare_objects can say so.
pub const Queue = struct { time: u64 };

const gpa = std.heap.smp_allocator;
var queues: std.AutoHashMapUnmanaged(u64, *Queue) = .empty;
var queue_live: std.AutoHashMapUnmanaged(usize, *Queue) = .empty;

/// Returns `h` as a live time-queue handle, or null; never dereferences a
/// foreign pointer.
pub fn asQueue(h: vpiHandle) ?*Queue {
    const p = h orelse return null;
    return queue_live.get(@intFromPtr(p));
}

/// The first pending time strictly after `after`. A cbNextSimTime has no
/// due time of its own (§27.33.2); §26.6.39 associates it with this queue.
pub fn nextTime(after: u64, a: std.mem.Allocator) !?u64 {
    var best = callback.nextDue(after, false);
    if (engine) |r| {
        var pending: std.ArrayList(sim.scheduler.Live) = .empty;
        defer pending.deinit(a);
        try r.scheduler.pendingPayloads(a, &pending);
        for (pending.items) |e| {
            if (e.time > after and (best == null or e.time < best.?)) best = e.time;
        }
    }
    return best;
}

/// §11.6.25 NOTE 3: the pending time queues, in strictly increasing time. A
/// time queue exists wherever the simulation must stop: an event, or a time
/// callback — the data model gives a callback a one-to-one `vpiParent`
/// relationship to its time queue, and §12.31.2 has the loop wake at a
/// callback's time "even if no event is present". cbNextSimTime holds no
/// time of its own ("the time structure is ignored"). Caller owns the slice.
pub fn timeQueues(a: std.mem.Allocator) ![]root.vpiHandle {
    var times: std.ArrayList(u64) = .empty;
    defer times.deinit(a);
    if (engine) |r| {
        var live: std.ArrayList(sim.scheduler.Live) = .empty;
        defer live.deinit(a);
        try r.scheduler.pendingPayloads(a, &live);
        for (live.items) |e| try times.append(a, e.time);
    }
    try callback.pendingTimes(&times, a, clock);
    std.mem.sort(u64, times.items, {}, std.sort.asc(u64));
    // At most one queue per pending time.
    var out: std.ArrayList(root.vpiHandle) = try .initCapacity(a, times.items.len);
    errdefer out.deinit(a);
    var last: ?u64 = null;
    for (times.items) |t| {
        if (t < clock or (last != null and last.? == t)) continue;
        last = t;
        const entry = try queues.getOrPut(gpa, t);
        if (!entry.found_existing) {
            const q = gpa.create(Queue) catch |e| {
                _ = queues.remove(t);
                return e;
            };
            q.* = .{ .time = t };
            // Interned only once it is also live: an entry `asQueue` refused
            // would be handed out by every later iteration.
            queue_live.put(gpa, @intFromPtr(q), q) catch |e| {
                gpa.destroy(q);
                _ = queues.remove(t);
                return e;
            };
            entry.value_ptr.* = q;
        }
        out.appendAssumeCapacity(@ptrCast(entry.value_ptr.*));
    }
    return out.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Tests: a real digital run, driven through the loop above.
// ---------------------------------------------------------------------------

/// Test fixture: elaborates Verilog `source` and opens it as the VPI design.
pub const Harness = struct {
    arena: std.heap.ArenaAllocator,
    bag: @import("vera").diag.Bag,
    out: std.Io.Writer.Allocating,
    run: digital.Run,

    /// Elaborates `source` into `h.run` and installs it as the design. `h`
    /// must not move afterwards: the model holds `&h.run`.
    pub fn init(h: *Harness, source: []const u8) !void {
        h.arena = .init(std.testing.allocator);
        errdefer h.arena.deinit();
        h.bag = .init(h.arena.allocator());
        h.out = .init(h.arena.allocator());
        h.run = try digital.elaborate(h.arena.allocator(), source, .{}, &h.bag, &h.out.writer);
        try root.openDigital(std.testing.allocator, &h.run);
    }

    /// Closes the design (every handle becomes invalid), then frees the run.
    pub fn deinit(h: *Harness) void {
        root.close();
        h.arena.deinit();
    }
};

const timeline =
    \\`timescale 1ns/1ns
    \\module t;
    \\  reg [7:0] s;
    \\  integer k;
    \\  initial begin
    \\    s = 8'h01; k = 3;
    \\    #7 s = 8'h42;
    \\    #3 $display("done");
    \\  end
    \\endmodule
;

var seen: [16]u64 = undefined;
var seen_n: usize = 0;

fn record(d: *callback.CbData) callconv(.c) c_int {
    seen[seen_n] = (@as(u64, d.time.?.high) << 32) | d.time.?.low;
    seen_n += 1;
    return 0;
}

fn register(reason: c_int, low: u32) !void {
    var t: Time = .{ .type = callback.vpiSimTime, .high = 0, .low = low, .real = 0 };
    const d: callback.CbData = .{ .reason = reason, .cb_rtn = record, .obj = null, .time = &t, .value = null, .index = 0, .user_data = null };
    if (callback.vpi_register_cb(&d) == null) return error.TestUnexpectedResult;
}

test "the digital model: one scope per instance, every declaration bound to its slot" {
    var h: Harness = undefined;
    try h.init(
        \\module top;
        \\  reg [3:0] a;
        \\  wire w;
        \\  integer n;
        \\  leaf u();
        \\endmodule
        \\module leaf;
        \\  reg q;
        \\endmodule
    );
    defer h.deinit();
    const d = &root.design.?;
    try std.testing.expectEqual(@as(usize, 2), d.scopes.len);
    try std.testing.expectEqualStrings("leaf", d.scopes[1].def_name);
    const a = root.asObj(handle.vpi_handle_by_name("top.a", null)).?;
    try std.testing.expectEqual(@as(u32, 4), a.size);
    try std.testing.expectEqual(h.run.slotOf("a").?, a.slot.get().?);
    try std.testing.expect(root.asObj(handle.vpi_handle_by_name("top.w", null)).?.kind == .net);
    try std.testing.expectEqual(root.vpiIntegerVar, property.vpi_get(root.vpiType, handle.vpi_handle_by_name("top.n", null)));
    try std.testing.expect(handle.vpi_handle_by_name("top.u.q", null) != null);
}

test "§12.31.2: time callbacks fire at their times, eventless ones included, before and after the queue" {
    var h: Harness = undefined;
    try h.init(timeline);
    defer h.deinit();
    seen_n = 0;
    try register(callback.cbAtStartOfSimTime, 7);
    try register(callback.cbReadOnlySynch, 7);
    // No design event at 5: "A callback can be set for any time, even if no
    // event is present."
    try register(callback.cbAfterDelay, 5);
    try simulate();
    try std.testing.expectEqualSlices(u64, &.{ 5, 7, 7 }, seen[0..seen_n]);
    try std.testing.expectEqual(@as(u64, 10), now());
    try std.testing.expectEqualStrings("done\n", h.out.written());
}

var walked: [8]u64 = undefined;
var walked_n: usize = 0;

fn walk(_: *callback.CbData) callconv(.c) c_int {
    const itr = iterate.vpi_iterate(vpiTimeQueue, null);
    while (iterate.vpi_scan(itr)) |q| {
        var t: Time = .{ .type = callback.vpiSimTime, .high = 0, .low = 0, .real = 0 };
        vpi_get_time(q, &t);
        walked[walked_n] = t.low;
        walked_n += 1;
    }
    return 0;
}

test "§12.15/§11.6.25: vpi_get_time scales by the object, and the time queues are the pending times" {
    var h: Harness = undefined;
    try h.init(
        \\`timescale 1us/1ns
        \\module q;
        \\  reg r;
        \\  initial begin r = 0; #2 r = 1; #3 r = 0; end
        \\endmodule
    );
    defer h.deinit();
    walked_n = 0;
    // At t=1us (1000 ticks at the 1 ns precision), from a start-of-time
    // callback: the design waits at 2us — its 5us step does not exist until
    // the 2us one runs — and a callback of this test's own waits at 7us.
    var t1: Time = .{ .type = callback.vpiScaledRealTime, .high = 0, .low = 0, .real = 1.0 };
    const top = handle.vpi_handle_by_name("q", null);
    const at1: callback.CbData = .{ .reason = callback.cbAtStartOfSimTime, .cb_rtn = walk, .obj = top, .time = &t1, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(callback.vpi_register_cb(&at1) != null);
    try register(callback.cbAtStartOfSimTime, 7000);
    seen_n = 0;
    try simulate();
    try std.testing.expectEqualSlices(u64, &.{ 2000, 7000 }, walked[0..walked_n]);

    // After the run: 7000 ticks. In the module's 1 us unit that is 7.0; with
    // no object it is "the simulation time unit", the tick.
    var t: Time = .{ .type = callback.vpiScaledRealTime, .high = 0, .low = 0, .real = 0 };
    vpi_get_time(top, &t);
    try std.testing.expectEqual(@as(f64, 7.0), t.real);
    vpi_get_time(null, &t);
    try std.testing.expectEqual(@as(f64, 7000.0), t.real);
    t.type = callback.vpiSimTime;
    vpi_get_time(null, &t);
    try std.testing.expectEqual(@as(c_uint, 7000), t.low);
    // A time with no type VerA reads, and a handle that is not an object.
    t.type = callback.vpiSuppressTime;
    vpi_get_time(null, &t);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
    var junk: u32 = 0;
    t.type = callback.vpiSimTime;
    vpi_get_time(@ptrCast(&junk), &t);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
}

var run_errors: u32 = 0;

fn onRunError(d: *callback.CbData) callconv(.c) c_int {
    if (d.reason == callback.cbError) run_errors += 1;
    return 0;
}

test "IEEE 1364-2005 §27.33.3: a run that stops on an error fires cbError once" {
    var h: Harness = undefined;
    h.arena = .init(std.testing.allocator);
    defer h.arena.deinit();
    h.bag = .init(h.arena.allocator());
    h.out = .init(h.arena.allocator());
    // A zero-delay loop past a budget of 100 events is a run-time error.
    h.run = try digital.elaborate(h.arena.allocator(), "module z; reg r; initial r = 0; always #0 r = ~r; endmodule", .{ .event_budget = 100 }, &h.bag, &h.out.writer);
    try root.openDigital(std.testing.allocator, &h.run);
    defer root.close();
    const on: callback.CbData = .{ .reason = callback.cbError, .cb_rtn = onRunError, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(callback.vpi_register_cb(&on) != null);
    run_errors = 0;
    try std.testing.expectError(error.DigitalFailed, simulate());
    try std.testing.expectEqual(@as(u32, 1), run_errors);
}

var finish_seen: u64 = 0;
var end_seen: u64 = std.math.maxInt(u64);

fn finishNow(_: *callback.CbData) callconv(.c) c_int {
    finish_seen = now();
    if (vpi_sim_control(vpiFinish, @as(c_int, 0)) != 1) finish_seen = 999;
    return 0;
}

fn atEnd(_: *callback.CbData) callconv(.c) c_int {
    end_seen = now();
    return 0;
}

test "§12.36: vpiFinish from a callback ends the run at that time, and the design does no more" {
    var h: Harness = undefined;
    try h.init(timeline);
    defer h.deinit();
    var t: Time = .{ .type = callback.vpiSimTime, .high = 0, .low = 8, .real = 0 };
    const fin: callback.CbData = .{ .reason = callback.cbAtStartOfSimTime, .cb_rtn = finishNow, .obj = null, .time = &t, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(callback.vpi_register_cb(&fin) != null);
    const end: callback.CbData = .{ .reason = callback.cbEndOfSimulation, .cb_rtn = atEnd, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(callback.vpi_register_cb(&end) != null);
    seen_n = 0;
    try simulate();
    try std.testing.expectEqual(@as(u64, 8), finish_seen);
    try std.testing.expectEqual(@as(u64, 8), end_seen);
    // The design's `#3 $display("done")` at t=10 never ran.
    try std.testing.expectEqualStrings("", h.out.written());

    // §12.36 "must support" vpiStop: with no interactive mode it ends the run,
    // as vpiFinish does.
    try std.testing.expectEqual(@as(c_int, 1), vpi_sim_control(vpiStop, @as(c_int, 0)));
    try std.testing.expectEqual(@as(c_int, 0), root.vpi_chk_error(null));
    try std.testing.expectEqual(@as(c_int, 0), vpi_sim_control(12345));
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
}

const restart_source =
    \\`timescale 1ns/1ns
    \\module rs;
    \\  reg [7:0] s;
    \\  initial begin
    \\    $display("start s=%0d", s);
    \\    s = 1;
    \\    #10 $display("end s=%0d", s);
    \\  end
    \\endmodule
;

var reset_stop: c_int = 0;

fn resetNow(_: *callback.CbData) callconv(.c) c_int {
    if (vpi_sim_control(vpiReset, reset_stop, @as(c_int, 0), @as(c_int, 0)) != 1) finish_seen = 999;
    return 0;
}

fn resetAt(stop: c_int) !void {
    reset_stop = stop;
    var t: Time = .{ .type = callback.vpiSimTime, .high = 0, .low = 5, .real = 0 };
    const d: callback.CbData = .{ .reason = callback.cbAfterDelay, .cb_rtn = resetNow, .obj = null, .time = &t, .value = null, .index = 0, .user_data = null };
    if (callback.vpi_register_cb(&d) == null) return error.TestUnexpectedResult;
}

test "§12.36/IEEE 1364-2005 C.7: vpiReset runs the design again from time 0, every reg at x" {
    var h: Harness = undefined;
    try h.init(restart_source);
    defer h.deinit();
    finish_seen = 0;
    // Reset at 5, before `end` at 10, with a nonzero stop_value: the second
    // run starts with s at x again, and the one-shot cbAfterDelay does not
    // ask twice.
    try resetAt(1);
    try simulate();
    try std.testing.expectEqual(@as(u64, 0), finish_seen);
    try std.testing.expectEqualStrings("start s=x\nstart s=x\nend s=1\n", h.out.written());
    try std.testing.expectEqual(@as(u64, 10), now());
}

/// What each reset callback saw: the clock, in firing order.
var reset_log: [4]u64 = undefined;
var reset_n: usize = 0;

fn onReset(d: *callback.CbData) callconv(.c) c_int {
    // Start of reset logs the time it was asked at; end of reset, 1000 + the
    // time after it.
    if (reset_n < reset_log.len) reset_log[reset_n] = now() + @as(u64, if (d.reason == callback.cbEndOfReset) 1000 else 0);
    reset_n += 1;
    return 0;
}

test "IEEE 1364-2005 §27.33.3: cbStartOfReset fires before a vpiReset, cbEndOfReset after it, once each" {
    var h: Harness = undefined;
    try h.init(restart_source);
    defer h.deinit();
    reset_n = 0;
    for ([_]c_int{ callback.cbEndOfReset, callback.cbStartOfReset }) |reason| {
        const d: callback.CbData = .{ .reason = reason, .cb_rtn = onReset, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
        try std.testing.expect(callback.vpi_register_cb(&d) != null);
    }
    try resetAt(1);
    try simulate();
    // Asked at 5; back at 0 after. The registration order does not decide.
    try std.testing.expectEqual(@as(usize, 2), reset_n);
    try std.testing.expectEqualSlices(u64, &.{ 5, 1000 }, reset_log[0..2]);
}

test "IEEE 1364-2005 §27.33.3: a run with no reset delivers neither reset callback" {
    var h: Harness = undefined;
    try h.init(restart_source);
    defer h.deinit();
    reset_n = 0;
    const d: callback.CbData = .{ .reason = callback.cbStartOfReset, .cb_rtn = onReset, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(callback.vpi_register_cb(&d) != null);
    try simulate();
    try std.testing.expectEqual(@as(usize, 0), reset_n);
}

test "§12.36/IEEE 1364-2005 C.7: a reset with stop_value 0 ends a batch run at time 0" {
    var h: Harness = undefined;
    try h.init(restart_source);
    defer h.deinit();
    try resetAt(0);
    try simulate();
    try std.testing.expectEqualStrings("start s=x\n", h.out.written());
    try std.testing.expectEqual(@as(u64, 0), now());
}

fn resetAgain(_: *callback.CbData) callconv(.c) c_int {
    resetAt(1) catch {
        finish_seen = 999;
    };
    return 0;
}

test "§12.36: an application that asks vpiReset on every run fails by name after max_resets" {
    var h: Harness = undefined;
    try h.init(restart_source);
    defer h.deinit();
    finish_seen = 0;
    // Every reset ends by asking for the next one.
    const again: callback.CbData = .{ .reason = callback.cbEndOfReset, .cb_rtn = resetAgain, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(callback.vpi_register_cb(&again) != null);
    try resetAt(1);
    try std.testing.expectError(error.DigitalFailed, simulate());
    try std.testing.expectEqual(@as(u64, 0), finish_seen);
    try std.testing.expectEqual(@as(usize, 1), h.bag.count());
    try std.testing.expect(std.mem.indexOf(u8, h.bag.at(0).message, "more than 1000 vpiReset requests") != null);
}

fn readWriteAgain(_: *callback.CbData) callconv(.c) c_int {
    var t: Time = .{ .type = callback.vpiSimTime, .high = 0, .low = 0, .real = 0 };
    const d: callback.CbData = .{ .reason = callback.cbReadWriteSynch, .cb_rtn = readWriteAgain, .obj = null, .time = &t, .value = null, .index = 0, .user_data = null };
    if (callback.vpi_register_cb(&d) == null) finish_seen = 999;
    return 0;
}

test "§12.31.2: a read-write callback that registers itself at its own time forever fails by name" {
    var h: Harness = undefined;
    try h.init(timeline);
    defer h.deinit();
    h.run.budget = 1000;
    finish_seen = 0;
    var t: Time = .{ .type = callback.vpiSimTime, .high = 0, .low = 7, .real = 0 };
    const d: callback.CbData = .{ .reason = callback.cbReadWriteSynch, .cb_rtn = readWriteAgain, .obj = null, .time = &t, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(callback.vpi_register_cb(&d) != null);
    try std.testing.expectError(error.DigitalFailed, simulate());
    try std.testing.expectEqual(@as(u64, 0), finish_seen);
    try std.testing.expectEqual(@as(u64, 7), now());
    try std.testing.expect(std.mem.indexOf(u8, h.bag.at(0).message, "more than 1000 callback passes at time 7") != null);
}

// ---- the pieces that need no run -------------------------------------------

test "earliest: the sooner of two optional times" {
    try std.testing.expectEqual(@as(?u64, null), earliest(null, null));
    try std.testing.expectEqual(@as(?u64, 3), earliest(3, null));
    try std.testing.expectEqual(@as(?u64, 4), earliest(null, 4));
    try std.testing.expectEqual(@as(?u64, 2), earliest(5, 2));
}

test "§12.15 fillTime: both forms of one tick count, the real in ticks with no object" {
    var t: Time = std.mem.zeroes(Time);
    fillTime((5 << 32) | 7, null, &t);
    try std.testing.expectEqual(@as(c_uint, 5), t.high);
    try std.testing.expectEqual(@as(c_uint, 7), t.low);
    try std.testing.expectEqual(@as(f64, 5 * 4294967296.0 + 7), t.real);
}

test "§12.15 ticksOf: vpiSimTime is ticks, a scaled time rounds, and what is no tick count is refused" {
    root.close();
    try std.testing.expectEqual(@as(?u64, (1 << 32) | 2), ticksOf(.{ .type = callback.vpiSimTime, .high = 1, .low = 2, .real = 0 }, null));
    // With no object a scaled time is in ticks (§12.15 "the simulation time
    // unit"), rounded half away from zero. A tick count is a u64: the
    // largest double below 2^64 is one, 2^64 itself is not.
    for ([_]struct { f64, ?u64 }{
        .{ 2.4, 2 },
        .{ 2.5, 3 },
        .{ 0, 0 },
        .{ 18446744073709549568.0, 18446744073709549568 },
        .{ 18446744073709551616.0, null },
        .{ 1e30, null },
        .{ -1, null },
        .{ std.math.nan(f64), null },
        .{ std.math.inf(f64), null },
    }) |case| try std.testing.expectEqual(case[1], ticksOf(.{ .type = callback.vpiScaledRealTime, .high = 0, .low = 0, .real = case[0] }, null));
}

test "§12.36 with no run: every operation fails and says why" {
    root.close();
    analog.setPoint(null, 0, 0, 0);
    try std.testing.expectEqual(@as(c_int, 0), vpi_sim_control(vpiFinish, @as(c_int, 0)));
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
    try std.testing.expectEqual(@as(c_int, 0), vpi_sim_control(vpiStop, @as(c_int, 0)));
    try std.testing.expectEqual(@as(c_int, 0), vpi_sim_control(vpiReset, @as(c_int, 1), @as(c_int, 0), @as(c_int, 0)));
    try std.testing.expectEqual(@as(c_int, 0), vpi_sim_control(vpiSetInteractiveScope, @as(?*anyopaque, null)));
    try std.testing.expectEqual(@as(c_int, 0), vpi_sim_control(vpiRejectTransientStep, @as(f64, 1e-9)));
    try std.testing.expectEqual(@as(c_int, 0), vpi_sim_control(vpiTransientFailConverge));
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
    // §12.15: a NULL time_p is an error; vpiAnalogTime is answered with no
    // run at all.
    vpi_get_time(null, null);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
    var t: Time = .{ .type = callback.vpiAnalogTime, .high = 0, .low = 0, .real = 5 };
    vpi_get_time(null, &t);
    try std.testing.expectEqual(@as(c_int, 0), root.vpi_chk_error(null));
    try std.testing.expectEqual(@as(f64, 0), t.real);
    // With no run the clock is 0, and no queue is pending.
    try std.testing.expectEqual(@as(u64, 0), now());
    const queues_now = try timeQueues(std.testing.allocator);
    defer std.testing.allocator.free(queues_now);
    try std.testing.expectEqual(@as(usize, 0), queues_now.len);
}
