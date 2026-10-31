//! A process continuation in, a scheduler event out; and the §10
//! activations a subroutine call enters and leaves, with the automatic
//! frames they set aside.
//! Cites: IEEE 1364-2005 §9.7.1, §10.2.2, §10.2.3, §10.4.
//!
//! Contents:
//! - `pub const Calls = struct`
//! - `pub fn run(self: *State, pc: u32, after: ?u64) Error!void`
//! - `pub fn runIn(self: *State, pc: u32, ctx: u32, after: ?u64) Error!void`
//! - `pub fn runPlain(self: *State, pc: u32, after: ?u64) Error!void`
//! - `pub fn schedFail(self: *State, e: Scheduler.Error) Error`
//! - `pub fn timeFail(self: *State, e: Scheduler.Error) Error`
//! - `pub fn enter(self: *State, sub: u32, lo: u32, fill: []const u64) Error!void`
//! - `pub fn leave(self: *State, sub: u32, lo: u32, n: u32) void`
//! - `pub fn callTimed(self: *State, sub: u32, ret_pc: u32, lo: u32, fill: []const u64) Error!void`
//! - `pub fn returnTimed(self: *State) Error!u32`
//! - `pub fn evict(self: *State, sub: u32) Error!void`
//! - `pub fn makeResident(self: *State, ctx: u32) Error!void`
//! - `pub fn eventContext(self: *const State, sub: u32, from: u32) u32`
//! - `pub fn selectIn(self: *State, select: *const EventSelect, ctx: u32) Error!?u32`

const std = @import("std");
const Resume = @import("records.zig").Resume;
const assert = std.debug.assert;
const deep = @import("base").deep_stack;
const digital = @import("../digital/root.zig");
const Scheduler = @import("../scheduler.zig").Scheduler;
const State = @import("State.zig");
const design = @import("design.zig");
const logic = @import("logic/root.zig");
const records = @import("records.zig");
const Error = design.Error;
const activations = design.activations;
const two_slots = design.two_slots;
const Act = records.Act;
const EventSelect = records.EventSelect;
const late_base = records.late_base;
const resume_base = records.resume_base;
const show_base = records.show_base;
const W = logic.W;
const two = logic.two;
const quietState = State.quietState;
const testing = std.testing;

/// A native run's §10 subroutine activations: per subroutine the synchronous
/// ones running and how deep they nest, the automatic frames set aside, and
/// §10.2.3's timed activations with their queued continuations.
pub const Calls = struct {
    /// §10: per subroutine, its synchronous activations running; the one a
    /// `disable` is unwinding; how deep they nest; the automatic frames
    /// they set aside, both planes, innermost last.
    active: []u32 = &.{},
    depth: u32 = 0,
    saved: std.ArrayList(u64) = .empty,
    acts: std.ArrayList(Act) = .empty,
    free_acts: std.ArrayList(u32) = .empty,
    resident: []u32 = &.{},
    resumes: std.ArrayList(Resume) = .empty,
    free_resumes: std.ArrayList(u32) = .empty,
    act_events: []const u32 = &.{},
};

/// Queues the running process's continuation at `pc`, in its activation
/// (`ctx`): now (active), or `after` ticks later (inactive).
pub fn run(self: *State, pc: u32, after: ?u64) Error!void {
    return self.runIn(pc, if (activations) self.ctx else 0, after);
}

/// `run` in activation `ctx` (`exec.resumption`).
pub fn runIn(self: *State, pc: u32, ctx: u32, after: ?u64) Error!void {
    if (!activations or ctx == 0) return self.runPlain(pc, after);
    assert(ctx < self.calls.acts.items.len);
    const k = self.calls.free_resumes.pop() orelse blk: {
        try self.calls.resumes.append(self.gpa, undefined);
        break :blk @as(u32, @intCast(self.calls.resumes.items.len - 1));
    };
    assert(k < late_base - resume_base); // The payload stays inside its band.
    self.calls.resumes.items[k] = .{ .pc = pc, .ctx = ctx, .live = true };
    _ = (if (after) |t|
        self.sched.scheduleAfter(self.gpa, t, .inactive, resume_base + k) catch |e| return self.timeFail(e)
    else
        self.sched.schedule(self.gpa, .active, resume_base + k) catch |e| return self.schedFail(e));
}

/// Queues the process at `pc` outside any activation: now (active), or
/// `after` ticks later (inactive).
pub fn runPlain(self: *State, pc: u32, after: ?u64) Error!void {
    assert(pc < show_base); // A process payload is its pc.
    _ = (if (after) |t|
        self.sched.scheduleAfter(self.gpa, t, .inactive, pc) catch |e| return self.timeFail(e)
    else
        self.sched.schedule(self.gpa, .active, pc) catch |e| return self.schedFail(e));
}

/// A scheduling failure as `error.OutOfMemory`, or an E1100 refusal.
pub fn schedFail(self: *State, e: Scheduler.Error) Error {
    assert(e != error.TimeOverflow); // Only a delay overflows: `timeFail`.
    return if (e == error.OutOfMemory) error.OutOfMemory else self.fail("digital scheduling failure: {t}", .{e});
}

/// `schedFail` of a failure to schedule a delay.
pub fn timeFail(self: *State, e: Scheduler.Error) Error {
    return if (e == error.OutOfMemory) error.OutOfMemory else self.fail("digital timing failure: {t}", .{e});
}

/// §10.2.2 a synchronous activation of subroutine `sub` begins. An
/// automatic one (§10.2.3) sets its frame, `fill.len` words from `lo`,
/// aside and makes it x (`fill`, the x of each word); `leave` puts it back.
/// `error.Failed` once the activations exhaust the stack `deep.runGuarded`
/// reserved; `error.Rerun` for an automatic frame in the 2-state phase.
pub fn enter(self: *State, sub: u32, lo: u32, fill: []const u64) Error!void {
    assert(sub < self.calls.active.len);
    if (deep.exhausted()) return self.fail(deep.message, .{deep.mib()});
    self.calls.depth += 1;
    self.calls.active[sub] += 1;
    if (fill.len == 0) return;
    if (self.two) return error.Rerun;
    try self.calls.saved.appendSlice(self.gpa, self.v[lo..][0..fill.len]);
    try self.calls.saved.appendSlice(self.gpa, self.x[lo..][0..fill.len]);
    @memcpy(self.v[lo..][0..fill.len], fill);
    if (!two) @memcpy(self.x[lo..][0..fill.len], fill);
    assert(self.calls.saved.items.len >= 2 * fill.len);
}

/// The activation `enter` began has returned. Restore the caller before
/// its actuals receive captured outputs; a `disable` of `sub` ends with
/// its outermost activation. Asserts it pairs with an `enter` of `sub`
/// whose `fill.len` was `n`.
pub fn leave(self: *State, sub: u32, lo: u32, n: u32) void {
    std.debug.assert(self.calls.depth > 0);
    std.debug.assert(self.calls.active[sub] > 0);
    std.debug.assert(self.calls.saved.items.len >= 2 * n);
    self.calls.depth -= 1;
    self.calls.active[sub] -= 1;
    if (n != 0) {
        const at = self.calls.saved.items.len - 2 * n;
        @memcpy(self.v[lo..][0..n], self.calls.saved.items[at..][0..n]);
        @memcpy(self.x[lo..][0..n], self.calls.saved.items[at + n ..][0..n]);
        self.calls.saved.shrinkRetainingCapacity(at);
    }
    if (self.unwind == sub and self.calls.active[sub] == 0) self.unwind = null;
    if (self.calls.depth == 0) assert(self.calls.saved.items.len == 0);
}

/// `exec.callTimed`: §10.2.2 task `sub` begins a new activation, whose
/// caller resumes at its call site `ret_pc`. An automatic task (§10.2.3)
/// sets the resident activation's frame aside and starts its own as
/// `fill`, `fill.len` words from `lo`; the emitted call then copies the
/// inputs in and jumps to the body.
pub fn callTimed(self: *State, sub: u32, ret_pc: u32, lo: u32, fill: []const u64) Error!void {
    assert(sub < self.calls.resident.len or fill.len == 0);
    if (self.calls.acts.items.len == 0) try self.calls.acts.append(self.gpa, .{ .sub = 0, .ret_pc = 0, .ret_ctx = 0, .lo = 0, .n = 0 }); // 0 is "no activation"
    const act: Act = .{ .sub = sub, .ret_pc = ret_pc, .ret_ctx = self.ctx, .lo = lo, .n = @intCast(fill.len) };
    const id: u32 = if (self.calls.free_acts.pop()) |k| blk: {
        const storage = self.calls.acts.items[k].storage;
        self.calls.acts.items[k] = act;
        self.calls.acts.items[k].storage = storage;
        break :blk k;
    } else blk: {
        try self.calls.acts.append(self.gpa, act);
        break :blk @intCast(self.calls.acts.items.len - 1);
    };
    if (fill.len != 0) {
        try self.evict(sub);
        @memcpy(self.v[lo..][0..fill.len], fill);
        if (!two) @memcpy(self.x[lo..][0..fill.len], fill);
        self.calls.resident[sub] = id;
    }
    assert(id != 0); // Row 0 is "no activation".
    self.ctx = id;
}

/// `exec.returnTimed`: the running activation has ended (the emitted
/// body has put its outputs aside); its caller's activation becomes
/// resident, and the call site it returns to is the result.
pub fn returnTimed(self: *State) Error!u32 {
    const done = self.ctx;
    assert(done != 0); // A timed return runs inside an activation.
    assert(done < self.calls.acts.items.len);
    const act = self.calls.acts.items[done];
    if (self.calls.resident[act.sub] == done) self.calls.resident[act.sub] = 0; // dead: nothing to save
    try self.calls.free_acts.append(self.gpa, done);
    self.ctx = act.ret_ctx;
    try self.makeResident(self.ctx);
    self.returned = true;
    return act.ret_pc;
}

/// Save the resident activation of automatic task `sub`, freeing its frame.
pub fn evict(self: *State, sub: u32) Error!void {
    const id = self.calls.resident[sub];
    if (id == 0) return;
    const act = &self.calls.acts.items[id];
    assert(act.sub == sub);
    if (act.storage.len != 2 * act.n) {
        self.gpa.free(act.storage);
        act.storage = &.{};
        act.storage = try self.gpa.alloc(u64, 2 * act.n);
    }
    @memcpy(act.storage[0..act.n], self.v[act.lo..][0..act.n]);
    @memcpy(act.storage[act.n..], self.x[act.lo..][0..act.n]);
    self.calls.resident[sub] = 0;
    assert(act.storage.len == 2 * act.n);
}

/// `exec.makeResident`: activation `ctx`'s storage in its task's frame.
pub fn makeResident(self: *State, ctx: u32) Error!void {
    if (ctx == 0) return;
    assert(ctx < self.calls.acts.items.len);
    const act = self.calls.acts.items[ctx];
    if (act.n == 0 or self.calls.resident[act.sub] == ctx) return;
    try self.evict(act.sub);
    @memcpy(self.v[act.lo..][0..act.n], act.storage[0..act.n]);
    @memcpy(self.x[act.lo..][0..act.n], act.storage[act.n..]);
    self.calls.resident[act.sub] = ctx;
    assert(act.storage.len == 2 * act.n);
}

/// `waiters.eventContext`: the live activation of automatic task `sub`
/// that activation `from` runs inside, or 0.
pub fn eventContext(self: *const State, sub: u32, from: u32) u32 {
    assert(from < self.calls.acts.items.len or from == 0);
    var ctx = from;
    var steps: usize = 0;
    while (ctx != 0) : (steps += 1) {
        assert(steps < self.calls.acts.items.len); // The caller chain has no cycle.
        if (self.calls.acts.items[ctx].sub == sub) return ctx;
        ctx = self.calls.acts.items[ctx].ret_ctx;
    }
    return 0;
}

/// `waiters.selectedEvent`: §9.7.3 the element `select` names, read in the
/// waiter's activation `ctx`; the running one is resident again after.
pub fn selectIn(self: *State, select: *const EventSelect, ctx: u32) Error!?u32 {
    if (!activations or ctx == self.ctx) return select(self);
    assert(ctx < self.calls.acts.items.len);
    const running = self.ctx;
    self.ctx = ctx;
    try self.makeResident(ctx);
    const at = select(self);
    self.ctx = running;
    try self.makeResident(running);
    assert(self.ctx == running);
    return at;
}

test "§10.2.3 enter sets an automatic frame aside as x and leave restores it, at any depth" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try quietState(arena.allocator(), &two_slots, -9);
    const all = std.math.maxInt(u64);
    try s.enter(0, 0, &.{ all, all });
    try testing.expectEqual(W{ .v = all, .x = all }, s.get(1));
    s.leave(0, 0, 2);
    try testing.expectEqual(W{ .v = 7, .x = 0 }, s.get(0));
    try testing.expectEqual(W{ .v = 9, .x = 0 }, s.get(1));
    // One past the old 1024 and well past it: no count bounds the depth,
    // only the stack (`deep.exhausted`), which these calls do not grow.
    for (0..100000) |_| try s.enter(0, 0, &.{});
    for (0..100000) |_| s.leave(0, 0, 0);
    try testing.expectEqual(@as(u32, 0), s.calls.depth);
    try testing.expectEqual(@as(u32, 0), s.calls.active[0]);
}
