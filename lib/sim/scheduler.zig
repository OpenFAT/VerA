//! Scheduled payloads -> the VAMS-2023 §8.5 / IEEE 1364-2005 §11 order
//! they run in: time, then region. A payload indexes a caller-owned record;
//! this module evaluates no HDL.
//! Clauses: VAMS-2023 §8.4.4, §8.5.1, §8.5.2, §8.5.3.6, §8.5.3.7; IEEE
//! 1364-2005 §10.3, §11.4.1, §11.4.2, §26.6.25; VAMS §9.23 (the pending-driver
//! queries `pendingPayloads` serves).
const std = @import("std");

/// Integer ticks at the design's finest time precision. Scaling/rounding belongs
/// to elaboration; all 64 bits are retained, including times above 2^53.
pub const Time = u64;

/// Six current-time regions. The future heap is the seventh logical region.
/// VAMS §8.5.1 and §8.5.3.6 put explicit D2A before inactive; §8.5.2's
/// pseudocode reverses these two. We follow the explicit normative ordering;
/// the LRM's §8.5.2 editorial note (docs/specification/VAMS-LRM-2023.pdf) records the discrepancy.
pub const Region = enum(u3) { active, explicit_d2a, inactive, nba, analog, monitor };
/// The region a future event lands in when its time comes: §8.5.1 lets only
/// `#d` resumptions (inactive) and delayed nonblocking updates (nba) wait
/// for a later time.
const FutureKind = enum(u1) {
    inactive,
    nba,

    fn region(self: FutureKind) Region {
        return switch (self) {
            .inactive => .inactive,
            .nba => .nba,
        };
    }
};

const SlotId = enum(u32) { none = std.math.maxInt(u32), _ };
/// One scheduled event, for `cancel` and `payloadOf`. Stale once its event
/// dispatches or is cancelled: the generation no longer matches, so a stale
/// handle cancels nothing and never aliases the slot's next event.
pub const Handle = struct { slot: SlotId, generation: u32 };
/// One dispatched event as `next` returns it: `time` is `now`, `payload`
/// the caller's row, and `handle` already stale.
pub const Event = struct {
    time: Time,
    region: Region,
    payload: u32,
    handle: Handle,

    // Budget: one per dispatch, returned by value. 21 bytes of fields, 3 of
    // tail padding.
    comptime {
        std.debug.assert(@sizeOf(Handle) == 8);
        std.debug.assert(@sizeOf(Event) == 24);
    }
};
/// One live event as `Scheduler.pendingPayloads` reports it.
pub const Live = struct { time: Time, payload: u32 };

const State = enum(u2) { pending, cancelled, free, retired };
// MultiArrayList separates queue traversal/cancellation from payload dispatch.
const Slot = struct {
    next: SlotId = .none,
    payload: u32,
    generation: u32 = 0,
    region: Region,
    state: State = .pending,
};

// Heap entries move together; comparisons read the time/order key, and removal
// reads the slot. Slot storage cannot be reused while its entry is in the heap.
const Future = struct {
    time: Time,
    order: u64,
    slot: SlotId,

    fn compare(_: void, a: Future, b: Future) std.math.Order {
        return if (a.time == b.time) std.math.order(a.order, b.order) else std.math.order(a.time, b.time);
    }

    // Budget: one heap entry per future event; every sift reads time and
    // order, so the row stays three words.
    comptime {
        std.debug.assert(@sizeOf(Future) == 24);
    }
};

/// The event queue of one simulation: a FIFO per current-time region plus a
/// heap of future events, over one pool of slots (`slots`) that a `Handle`
/// names. Capacity: 2^32 - 1 slots, the most events pending at once
/// (`error.TooManyEvents` beyond). Owns its memory, from `allocator`.
pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    /// The current simulation time; only `nextUntil` advances it.
    now: Time = 0,
    slots: std.MultiArrayList(Slot) = .empty,
    heads: [6]SlotId = @splat(.none),
    tails: [6]SlotId = @splat(.none),
    future: std.PriorityQueue(Future, void, Future.compare) = .empty,
    free: SlotId = .none,
    sequence: u64 = 0,
    phase: union(enum) { idle, dispatch: Region, stopped } = .idle,
    /// VAMS §8.5.1 a VPI read-write callback is an inactive event: when set
    /// to `now`, `nextUntil` returns null at this time's inactive point (after
    /// active, explicit D2A and inactive, before the NBA updates) and sets
    /// `synced`. Written only by the VPI host (`src/vpi/run.zig`).
    sync_at: ?Time = null,
    synced: bool = false,

    /// `TooManyEvents`: 2^32 - 1 slots are live. `SequenceOverflow`: 2^64
    /// future events were ever scheduled, so FIFO order among equal times can
    /// no longer be kept. `TimeOverflow`: `now + delay` passes 2^64 - 1.
    /// `TimeInPast`: an absolute time before `now`. `MonitorMutation`: a
    /// schedule or cancel while a monitor-region event is being dispatched,
    /// which reads the settled step and must not change it. `Stopped`: after
    /// `finish`.
    pub const Error = std.mem.Allocator.Error || error{
        TooManyEvents,
        SequenceOverflow,
        TimeOverflow,
        TimeInPast,
        MonitorMutation,
        Stopped,
    };

    /// An empty queue at time 0. Allocates nothing until the first event.
    pub fn init(allocator: std.mem.Allocator) Scheduler {
        return .{ .allocator = allocator };
    }

    /// Frees every slot and heap entry; invalidates every `Handle`.
    pub fn deinit(self: *Scheduler) void {
        self.slots.deinit(self.allocator);
        self.future.deinit(self.allocator);
        self.* = undefined;
    }

    /// Schedule at now. A2D notifications use ordinary active events; the caller
    /// posts analog requests when an implicit/explicit D2A dependency needs one.
    /// May allocate one slot; invalidates no `Handle`. `MonitorMutation`
    /// while a monitor event is dispatched, `Stopped` after `finish`.
    pub fn schedule(self: *Scheduler, region: Region, payload: u32) Error!Handle {
        try self.checkMutation();
        const handle = try self.allocate(region, payload);
        self.append(region, handle.slot);
        return handle;
    }

    /// Future work has precisely the two categories specified by §8.5.1.
    /// At the current time, inactive means #0; NBA stays in the NBA region.
    /// `TimeInPast` for a `time` before `now`; on any error nothing is queued.
    fn scheduleAt(self: *Scheduler, time: Time, kind: FutureKind, payload: u32) Error!Handle {
        try self.checkMutation();
        if (time < self.now) return error.TimeInPast;
        if (time == self.now) return self.schedule(kind.region(), payload);
        if (self.sequence == std.math.maxInt(u64)) return error.SequenceOverflow;
        const handle = try self.allocate(kind.region(), payload);
        errdefer self.release(handle.slot);
        try self.future.push(self.allocator, .{ .time = time, .order = self.sequence, .slot = handle.slot });
        self.sequence += 1;
        return handle;
    }

    /// `scheduleAt(now + delay)`; `TimeOverflow` when that sum passes 2^64 - 1.
    pub fn scheduleAfter(self: *Scheduler, delay: Time, kind: FutureKind, payload: u32) Error!Handle {
        try self.checkMutation();
        const time = std.math.add(Time, self.now, delay) catch return error.TimeOverflow;
        return self.scheduleAt(time, kind, payload);
    }

    /// A handle only cancels its original pending event. Cancellation is lazy:
    /// its queue retains the slot until removal, preventing reuse under a heap
    /// entry or FIFO link. Cancelled future entries never advance the clock.
    pub fn cancel(self: *Scheduler, handle: Handle) Error!bool {
        try self.checkMutation();
        if (self.payloadOf(handle) == null) return false;
        self.slots.items(.state)[@backingInt(handle.slot)] = .cancelled;
        return true;
    }

    /// Cancel every pending event whose payload is in `[lo, hi)`; whether
    /// any was. O(events ever allocated): IEEE 1364-2005 §10.3 `disable`
    /// of a native design, whose payloads are the pcs its processes resume at.
    pub fn cancelRange(self: *Scheduler, lo: u32, hi: u32) Error!bool {
        try self.checkMutation();
        var hit = false;
        for (self.slots.items(.state), self.slots.items(.payload)) |*state, payload| {
            if (state.* != .pending or payload < lo or payload >= hi) continue;
            state.* = .cancelled;
            hit = true;
        }
        return hit;
    }

    /// The payload `handle` was scheduled with while its event is still
    /// pending, or null once it has dispatched or been cancelled. A caller that
    /// recycles payload rows asks this before cancelling, to learn which row
    /// the cancel frees.
    pub fn payloadOf(self: *const Scheduler, handle: Handle) ?u32 {
        const index = @backingInt(handle.slot);
        if (index >= self.slots.len or self.slots.items(.generation)[index] != handle.generation or
            self.slots.items(.state)[index] != .pending) return null;
        return self.slots.items(.payload)[index];
    }

    /// Explicit termination discards pending dispatches; deinit releases their
    /// storage. This does not synthesize analog final_step or HDL finalization.
    pub fn finish(self: *Scheduler) void {
        self.phase = .stopped;
    }

    /// Complete the preceding dispatch and return one active event. Promotion
    /// moves a whole region into active; newly scheduled active work joins its
    /// tail. FIFO is one order §11.4.2 permits among active events; NBA
    /// updates keep the order §11.4.1 requires.
    ///
    /// During a returned monitor event, schedule/cancel reject mutation until
    /// the caller invokes next again. Empty returns null without changing time.
    pub fn next(self: *Scheduler) ?Event {
        return self.nextUntil(std.math.maxInt(Time));
    }

    /// `next`, bounded: time never advances past `limit`. Once every region
    /// at `now` is empty and the earliest future event lies after `limit`,
    /// this returns null and leaves `now` and the future heap untouched, so a
    /// later call with a larger limit resumes exactly where this one stopped.
    /// The bound lets a caller outside the queue (VAMS §8.4.4's "common
    /// global time") hold the digital engine at a tick.
    pub fn nextUntil(self: *Scheduler, limit: Time) ?Event {
        if (self.phase == .stopped) return null;
        self.phase = .idle;
        while (true) {
            while (self.take(.active)) |slot| {
                const index = @backingInt(slot);
                if (self.slots.items(.state)[index] == .cancelled) {
                    self.release(slot);
                    continue;
                }
                const event: Event = .{
                    .time = self.now,
                    .region = self.slots.items(.region)[index],
                    .payload = self.slots.items(.payload)[index],
                    .handle = .{ .slot = slot, .generation = self.slots.items(.generation)[index] },
                };
                if (event.region == .analog) self.consumeAnalog(event.payload);
                self.release(slot);
                self.phase = .{ .dispatch = event.region };
                return event;
            }
            var promoted = false;
            inline for (.{ Region.explicit_d2a, Region.inactive, Region.nba, Region.analog, Region.monitor }) |region| {
                if (!promoted and self.heads[@backingInt(region)] != .none) {
                    // VAMS §8.5.1: the inactive point is reached once active,
                    // explicit D2A and inactive are empty, before the NBA
                    // updates (`sync_at`).
                    if (comptime region == .nba or region == .analog or region == .monitor)
                        if (self.syncHere()) return null;
                    self.heads[0] = self.heads[@backingInt(region)];
                    self.tails[0] = self.tails[@backingInt(region)];
                    self.heads[@backingInt(region)] = .none;
                    self.tails[@backingInt(region)] = .none;
                    promoted = true;
                }
            }
            if (promoted) continue;
            if (self.syncHere()) return null;
            if (!self.advance(limit)) return null;
        }
    }

    /// Whether `nextUntil` stops at this time's inactive point: `sync_at` is
    /// `now` and no event of `now` is still in the future heap (a caller that
    /// set `now` itself, as the VPI loop does, leaves them there until
    /// `advance`). Clears the request and sets `synced`, which the caller reads.
    fn syncHere(self: *Scheduler) bool {
        const at = self.sync_at orelse return false;
        if (at != self.now) return false;
        self.purgeCancelled();
        if (self.future.peek()) |entry| if (entry.time == self.now) return false;
        self.sync_at = null;
        self.synced = true;
        return true;
    }

    /// The time of the event `next` would return, or null when nothing is
    /// pending. `now` while any current-time region holds a live event.
    /// Cancelled future minima are purged first, so a cancelled event never
    /// reports a phantom time (the same rule `advance` keeps).
    pub fn peekTime(self: *Scheduler) ?Time {
        if (self.phase == .stopped) return null;
        for (self.heads) |head| {
            var cursor = head;
            while (cursor != .none) : (cursor = self.slots.items(.next)[@backingInt(cursor)]) {
                if (self.slots.items(.state)[@backingInt(cursor)] == .pending) return self.now;
            }
        }
        self.purgeCancelled();
        return if (self.future.peek()) |entry| entry.time else null;
    }

    /// Every live event as (time, payload), in no particular order; a
    /// current-time event reports `now`. Read-only: the future heap is
    /// scanned, not popped. Readers: VAMS §9.23's pending-driver queries
    /// (lib/sim/digital/driver.zig) and IEEE 1364 §26.6.25's `vpiTimeQueue`
    /// iteration (src/vpi/run.zig). Appends to `out`, which the caller owns
    /// and frees with `a`; on `OutOfMemory` it holds what was appended. A
    /// stopped queue appends nothing. O(events ever pending at once).
    pub fn pendingPayloads(self: *const Scheduler, a: std.mem.Allocator, out: *std.ArrayList(Live)) std.mem.Allocator.Error!void {
        if (self.phase == .stopped) return;
        const state = self.slots.items(.state);
        const links = self.slots.items(.next);
        const payloads = self.slots.items(.payload);
        for (self.heads) |head| {
            var cursor = head;
            while (cursor != .none) : (cursor = links[@backingInt(cursor)]) {
                if (state[@backingInt(cursor)] == .pending) try out.append(a, .{ .time = self.now, .payload = payloads[@backingInt(cursor)] });
            }
        }
        for (self.future.items) |entry| {
            if (state[@backingInt(entry.slot)] == .pending) try out.append(a, .{ .time = entry.time, .payload = payloads[@backingInt(entry.slot)] });
        }
    }

    /// The whole queue as bytes `restore` reads back: every slot, so a
    /// `Handle` taken before `save` names the same event after `restore`;
    /// the region lists; the future heap in its array order; the clock.
    /// Its length is O(the most events ever pending at once). The bytes are
    /// this build's layout of the slots and heap entries: only `restore` in
    /// the same build reads them.
    pub fn save(self: *const Scheduler, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const lens = [2]u32{ @intCast(self.slots.len), @intCast(self.future.items.len) };
        try w.writeAll(std.mem.asBytes(&lens));
        inline for (.{ &self.now, &self.heads, &self.tails, &self.free, &self.sequence, &self.phase }) |f| try w.writeAll(std.mem.asBytes(f));
        inline for (comptime std.enums.values(std.MultiArrayList(Slot).Field)) |f| try w.writeAll(std.mem.sliceAsBytes(self.slots.items(f)));
        try w.writeAll(std.mem.sliceAsBytes(self.future.items));
    }

    /// The queue `save` wrote to `r`, replacing every slot, region list and
    /// heap entry; `allocator` is kept. A queue `restore` failed on is partly
    /// overwritten: `deinit` it, never run it.
    pub fn restore(self: *Scheduler, r: *std.Io.Reader) (std.Io.Reader.Error || std.mem.Allocator.Error)!void {
        var lens: [2]u32 = undefined;
        try r.readSliceAll(std.mem.asBytes(&lens));
        inline for (.{ &self.now, &self.heads, &self.tails, &self.free, &self.sequence, &self.phase }) |f| try r.readSliceAll(std.mem.asBytes(f));
        try self.slots.resize(self.allocator, lens[0]);
        inline for (comptime std.enums.values(std.MultiArrayList(Slot).Field)) |f| try r.readSliceAll(std.mem.sliceAsBytes(self.slots.items(f)));
        try self.future.ensureTotalCapacity(self.allocator, lens[1]);
        self.future.items.len = lens[1];
        try r.readSliceAll(std.mem.sliceAsBytes(self.future.items));
    }

    fn checkMutation(self: *const Scheduler) Error!void {
        switch (self.phase) {
            .stopped => return error.Stopped,
            .dispatch => |region| if (region == .monitor) return error.MonitorMutation,
            .idle => {},
        }
    }

    fn allocate(self: *Scheduler, region: Region, payload: u32) Error!Handle {
        const slot = if (self.free != .none) blk: {
            const id = self.free;
            const index = @backingInt(id);
            self.free = self.slots.items(.next)[index];
            self.slots.items(.next)[index] = .none;
            self.slots.items(.payload)[index] = payload;
            self.slots.items(.region)[index] = region;
            self.slots.items(.state)[index] = .pending;
            break :blk id;
        } else blk: {
            if (self.slots.len == std.math.maxInt(u32)) return error.TooManyEvents;
            const id: SlotId = @fromBackingInt(@intCast(self.slots.len));
            try self.slots.append(self.allocator, .{ .payload = payload, .region = region });
            break :blk id;
        };
        return .{ .slot = slot, .generation = self.slots.items(.generation)[@backingInt(slot)] };
    }

    fn release(self: *Scheduler, slot: SlotId) void {
        const index = @backingInt(slot);
        if (self.slots.items(.generation)[index] == std.math.maxInt(u32)) {
            // Exhausted generations retire permanently; stale handles never alias.
            self.slots.items(.state)[index] = .retired;
            return;
        }
        self.slots.items(.generation)[index] += 1;
        self.slots.items(.state)[index] = .free;
        self.slots.items(.next)[index] = self.free;
        self.free = slot;
    }

    fn append(self: *Scheduler, region: Region, slot: SlotId) void {
        const r = @backingInt(region);
        if (self.tails[r] == .none) {
            self.heads[r] = slot;
        } else self.slots.items(.next)[@backingInt(self.tails[r])] = slot;
        self.tails[r] = slot;
    }

    fn take(self: *Scheduler, region: Region) ?SlotId {
        const r = @backingInt(region);
        const slot = self.heads[r];
        if (slot == .none) return null;
        self.heads[r] = self.slots.items(.next)[@backingInt(slot)];
        if (self.heads[r] == .none) self.tails[r] = .none;
        self.slots.items(.next)[@backingInt(slot)] = .none;
        return slot;
    }

    fn purgeCancelled(self: *Scheduler) void {
        while (self.future.peek()) |entry| {
            if (self.slots.items(.state)[@backingInt(entry.slot)] != .cancelled) break;
            _ = self.future.pop();
            self.release(entry.slot);
        }
    }

    fn advance(self: *Scheduler, limit: Time) bool {
        // Purge dead minima before choosing a time: cancellation must not cause
        // a phantom timestep, including when every future event was cancelled.
        self.purgeCancelled();
        const first = self.future.peek() orelse return false;
        if (first.time > limit) return false;
        self.now = first.time;
        while (self.future.peek()) |entry| {
            if (entry.time != self.now) break;
            _ = self.future.pop();
            const index = @backingInt(entry.slot);
            if (self.slots.items(.state)[index] == .cancelled) {
                self.release(entry.slot);
            } else self.append(self.slots.items(.region)[index], entry.slot);
        }
        return true;
    }

    fn consumeAnalog(self: *Scheduler, payload: u32) void {
        // §8.5.3.7 consumes all ACTIVE requests for this macro-process in one
        // solve. A later request remains eligible for a new solve after feedback.
        // ponytail: linear scan of this active wave; a per-macro index if
        // large analog waves make it matter.
        var previous: SlotId = .none;
        var cursor = self.heads[0];
        while (cursor != .none) {
            const index = @backingInt(cursor);
            const following = self.slots.items(.next)[index];
            if (self.slots.items(.region)[index] == .analog and self.slots.items(.payload)[index] == payload) {
                if (previous == .none) self.heads[0] = following else self.slots.items(.next)[@backingInt(previous)] = following;
                if (self.tails[0] == cursor) self.tails[0] = previous;
                self.release(cursor);
            } else previous = cursor;
            cursor = following;
        }
    }
};

const t = std.testing;

test "seven logical regions follow normative AMS order and integer future time" {
    var scheduler = Scheduler.init(t.allocator);
    defer scheduler.deinit();
    // Deliberately enqueue in reverse region order. Future NBA was enqueued
    // before future inactive, but the latter resumes before the NBA updates.
    _ = try scheduler.scheduleAt(7, .nba, 8);
    _ = try scheduler.scheduleAt(7, .inactive, 7);
    _ = try scheduler.schedule(.monitor, 6);
    _ = try scheduler.schedule(.analog, 5);
    _ = try scheduler.schedule(.nba, 4);
    _ = try scheduler.schedule(.inactive, 3);
    _ = try scheduler.schedule(.explicit_d2a, 2);
    _ = try scheduler.schedule(.active, 1);
    const regions = [_]Region{ .active, .explicit_d2a, .inactive, .nba, .analog, .monitor, .inactive, .nba };
    for (regions, 1..) |region, payload| {
        const event = scheduler.next().?;
        try t.expectEqual(payload, event.payload);
        try t.expectEqual(region, event.region);
        try t.expectEqual(@as(Time, if (payload < 7) 0 else 7), event.time);
    }
    try t.expect(scheduler.next() == null);
    try t.expectEqual(@as(Time, 7), scheduler.now);
}

test "nextUntil never advances past its limit; peekTime reports what next would" {
    var scheduler = Scheduler.init(t.allocator);
    defer scheduler.deinit();
    try t.expectEqual(@as(?Time, null), scheduler.peekTime());
    _ = try scheduler.schedule(.nba, 1);
    const late = try scheduler.scheduleAt(5, .inactive, 2);
    _ = try scheduler.scheduleAt(9, .inactive, 3);
    try t.expectEqual(@as(?Time, 0), scheduler.peekTime());
    try t.expectEqual(@as(u32, 1), scheduler.nextUntil(4).?.payload);
    // Time 0 drained; 5 is past the limit, so null and `now` stays.
    try t.expect(scheduler.nextUntil(4) == null);
    try t.expectEqual(@as(Time, 0), scheduler.now);
    try t.expectEqual(@as(?Time, 5), scheduler.peekTime());
    // A cancelled minimum is not a time anything happens at.
    try t.expect(try scheduler.cancel(late));
    try t.expectEqual(@as(?Time, 9), scheduler.peekTime());
    try t.expect(scheduler.nextUntil(8) == null);
    const e = scheduler.nextUntil(9).?;
    try t.expectEqual(@as(u32, 3), e.payload);
    try t.expectEqual(@as(Time, 9), e.time);
    try t.expectEqual(@as(?Time, null), scheduler.peekTime());
}

test "restore replays the events save saw, and a handle cancels the same event" {
    var s = Scheduler.init(t.allocator);
    defer s.deinit();
    _ = try s.schedule(.nba, 1);
    const h = try s.scheduleAt(5, .inactive, 2);
    _ = try s.scheduleAt(5, .nba, 3);
    _ = try s.scheduleAt(9, .inactive, 4);
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try s.save(&w);
    var first: [4]u32 = undefined;
    for (&first) |*p| p.* = s.next().?.payload;
    _ = try s.scheduleAt(20, .inactive, 99);
    var r: std.Io.Reader = .fixed(w.buffered());
    try s.restore(&r);
    try t.expect(try s.cancel(h));
    try t.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, &first);
    for ([_]u32{ 1, 3, 4 }) |p| try t.expectEqual(p, s.next().?.payload);
    try t.expect(s.next() == null);
    try t.expectEqual(@as(Time, 9), s.now);
}

test "NBA batch, inactive reentry and analog feedback settle before monitor" {
    var scheduler = Scheduler.init(t.allocator);
    defer scheduler.deinit();
    var value: u32 = 0;
    _ = try scheduler.schedule(.monitor, 10);
    _ = try scheduler.schedule(.analog, 6);
    _ = try scheduler.schedule(.nba, 1);
    _ = try scheduler.schedule(.nba, 2);
    var trace: [10]u32 = undefined;
    var count: usize = 0;
    while (scheduler.next()) |event| {
        trace[count] = event.payload;
        count += 1;
        switch (event.payload) {
            1 => {
                value = 1;
                _ = try scheduler.schedule(.active, 3);
            },
            2 => {
                value = 2;
                _ = try scheduler.schedule(.inactive, 4);
            },
            3 => try t.expectEqual(@as(u32, 2), value),
            4 => {
                _ = try scheduler.schedule(.nba, 5);
            },
            5 => value = 3,
            6 => {
                try t.expectEqual(@as(u32, 3), value);
                // The analog consumer publishes an ordinary active A2D event.
                _ = try scheduler.schedule(.active, 7);
            },
            7 => {
                value = 4;
                _ = try scheduler.schedule(.analog, 9);
                _ = try scheduler.schedule(.explicit_d2a, 8);
            },
            8, 9, 10 => try t.expectEqual(@as(u32, 4), value),
            else => unreachable,
        }
        try t.expectEqual(@as(Time, 0), event.time);
    }
    try t.expectEqualSlices(u32, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }, trace[0..count]);
}

test "whole inactive promotion uses FIFO active choice and permits another delta" {
    var scheduler = Scheduler.init(t.allocator);
    defer scheduler.deinit();
    _ = try scheduler.scheduleAfter(0, .inactive, 1);
    _ = try scheduler.schedule(.inactive, 2);
    try t.expectEqual(@as(u32, 1), scheduler.next().?.payload);
    _ = try scheduler.schedule(.active, 3);
    _ = try scheduler.schedule(.inactive, 4);
    // Once promoted, the remaining inactive event is an active event too.
    for ([_]u32{ 2, 3, 4 }) |payload| try t.expectEqual(payload, scheduler.next().?.payload);
    try t.expect(scheduler.next() == null);
    try t.expectEqual(@as(Time, 0), scheduler.now);
}

test "analog solve consumes active duplicates but later feedback requests run" {
    var scheduler = Scheduler.init(t.allocator);
    defer scheduler.deinit();
    _ = try scheduler.schedule(.analog, 10);
    _ = try scheduler.schedule(.analog, 20);
    const duplicate = try scheduler.schedule(.analog, 10);
    _ = try scheduler.schedule(.analog, 10);
    try t.expectEqual(@as(u32, 10), scheduler.next().?.payload);
    try t.expect(!try scheduler.cancel(duplicate));
    _ = try scheduler.schedule(.analog, 10); // new request after the first solve
    _ = try scheduler.schedule(.active, 30);
    for ([_]u32{ 20, 30, 10 }) |payload| try t.expectEqual(payload, scheduler.next().?.payload);
    try t.expect(scheduler.next() == null);
}

test "monitor dispatch rejects event mutation until the caller completes it" {
    var scheduler = Scheduler.init(t.allocator);
    defer scheduler.deinit();
    const later = try scheduler.scheduleAt(10, .inactive, 3);
    _ = try scheduler.schedule(.monitor, 1);
    _ = try scheduler.schedule(.monitor, 2);
    for ([_]u32{ 1, 2 }) |payload| {
        try t.expectEqual(payload, scheduler.next().?.payload);
        try t.expectError(error.MonitorMutation, scheduler.schedule(.active, 99));
        try t.expectError(error.MonitorMutation, scheduler.scheduleAt(20, .inactive, 99));
        try t.expectError(error.MonitorMutation, scheduler.cancel(later));
    }
    try t.expectEqual(@as(u32, 3), scheduler.next().?.payload);
    _ = try scheduler.schedule(.active, 4);
    try t.expectEqual(@as(u32, 4), scheduler.next().?.payload);
    try t.expect(scheduler.next() == null);
}

test "cancelling earliest or all future events does not create phantom times" {
    var scheduler = Scheduler.init(t.allocator);
    defer scheduler.deinit();
    const first = try scheduler.scheduleAt(2, .inactive, 1);
    const second = try scheduler.scheduleAt(3, .nba, 2);
    _ = try scheduler.scheduleAt(9, .nba, 3);
    try t.expectEqual(@as(?u32, 1), scheduler.payloadOf(first));
    try t.expect(try scheduler.cancel(first));
    try t.expectEqual(@as(?u32, null), scheduler.payloadOf(first));
    try t.expect(try scheduler.cancel(second));
    try t.expect(!try scheduler.cancel(first));
    const event = scheduler.next().?;
    try t.expectEqual(@as(u32, 3), event.payload);
    try t.expectEqual(@as(Time, 9), event.time);
    try t.expect(!try scheduler.cancel(event.handle));
    try t.expectEqual(@as(?u32, null), scheduler.payloadOf(event.handle));
    const last = try scheduler.scheduleAt(100, .inactive, 4);
    try t.expect(try scheduler.cancel(last));
    try t.expect(scheduler.next() == null);
    try t.expectEqual(@as(Time, 9), scheduler.now);
}

test "current cancellation and generation retirement cannot alias new events" {
    var scheduler = Scheduler.init(t.allocator);
    defer scheduler.deinit();
    const old = try scheduler.schedule(.active, 1);
    try t.expect(try scheduler.cancel(old));
    try t.expect(scheduler.next() == null);
    const replacement = try scheduler.schedule(.active, 2);
    try t.expectEqual(old.slot, replacement.slot);
    try t.expect(old.generation != replacement.generation);
    try t.expect(!try scheduler.cancel(old));
    try t.expectEqual(@as(u32, 2), scheduler.next().?.payload);
    var exhausted = try scheduler.schedule(.active, 3);
    exhausted.generation = std.math.maxInt(u32);
    scheduler.slots.items(.generation)[@backingInt(exhausted.slot)] = exhausted.generation;
    try t.expect(try scheduler.cancel(exhausted));
    try t.expect(scheduler.next() == null);
    const fresh = try scheduler.schedule(.active, 4);
    try t.expect(fresh.slot != exhausted.slot);
    try t.expect(!try scheduler.cancel(exhausted));
    try t.expectEqual(@as(u32, 4), scheduler.next().?.payload);
}

test "timestamps exceed float precision and overflow cannot wrap into the past" {
    var scheduler = Scheduler.init(t.allocator);
    defer scheduler.deinit();
    const large: Time = (1 << 53) + 1;
    _ = try scheduler.scheduleAt(large + 1, .inactive, 2);
    _ = try scheduler.scheduleAt(large, .inactive, 1);
    try t.expectEqual(large, scheduler.next().?.time);
    try t.expectEqual(large + 1, scheduler.next().?.time);
    try t.expectError(error.TimeInPast, scheduler.scheduleAt(large, .nba, 3));
    _ = try scheduler.scheduleAt(std.math.maxInt(Time), .nba, 4);
    try t.expectEqual(std.math.maxInt(Time), scheduler.next().?.time);
    try t.expectError(error.TimeOverflow, scheduler.scheduleAfter(1, .inactive, 5));
    _ = try scheduler.scheduleAfter(0, .nba, 6);
    try t.expectEqual(@as(u32, 6), scheduler.next().?.payload);
    try t.expect(scheduler.next() == null);
}

test "future NBA insertion order is preserved even with recycled slots" {
    var scheduler = Scheduler.init(t.allocator);
    defer scheduler.deinit();
    _ = try scheduler.schedule(.active, 0);
    _ = try scheduler.schedule(.active, 0);
    _ = scheduler.next();
    _ = scheduler.next();
    const first = try scheduler.scheduleAt(10, .nba, 1);
    const second = try scheduler.scheduleAt(10, .nba, 2);
    try t.expect(@backingInt(first.slot) > @backingInt(second.slot));
    try t.expectEqual(@as(u32, 1), scheduler.next().?.payload);
    try t.expectEqual(@as(u32, 2), scheduler.next().?.payload);
    try t.expect(scheduler.next() == null);
}

test "finish is terminal and does not advance or dispatch queued events" {
    var scheduler = Scheduler.init(t.allocator);
    defer scheduler.deinit();
    const pending = try scheduler.schedule(.active, 1);
    _ = try scheduler.scheduleAt(50, .nba, 2);
    scheduler.finish();
    try t.expect(scheduler.next() == null);
    try t.expectEqual(@as(Time, 0), scheduler.now);
    try t.expectError(error.Stopped, scheduler.schedule(.active, 3));
    try t.expectError(error.Stopped, scheduler.cancel(pending));
    scheduler.finish();
}

fn allocationExercise(allocator: std.mem.Allocator) !void {
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    for (0..64) |i| {
        _ = try scheduler.schedule(.active, @intCast(i));
        _ = try scheduler.scheduleAt(1 + @as(Time, @intCast(i)), .nba, @intCast(i));
    }
    // `restore` grows a fresh queue to the saved one's size.
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try scheduler.save(&w);
    var copy = Scheduler.init(allocator);
    defer copy.deinit();
    var r: std.Io.Reader = .fixed(w.buffered());
    try copy.restore(&r);
    var count: usize = 0;
    while (copy.next() != null) count += 1;
    try t.expectEqual(@as(usize, 128), count);
}

test "allocation failure releases queue storage, partial future insertion and a partial restore" {
    try t.checkAllAllocationFailures(t.allocator, allocationExercise, .{});
}

test "failed future allocation leaves prior queue work and reusable slots intact" {
    var failing = t.FailingAllocator.init(t.allocator, .{});
    var scheduler = Scheduler.init(failing.allocator());
    defer scheduler.deinit();
    _ = try scheduler.schedule(.active, 1);
    _ = try scheduler.schedule(.active, 2);
    _ = scheduler.next(); // one reusable slot; the other event stays pending
    failing.fail_index = failing.alloc_index;
    try t.expectError(error.OutOfMemory, scheduler.scheduleAt(10, .nba, 99));
    failing.fail_index = std.math.maxInt(usize);
    _ = try scheduler.schedule(.active, 3);
    for ([_]u32{ 2, 3 }) |payload| try t.expectEqual(payload, scheduler.next().?.payload);
    try t.expect(scheduler.next() == null);
    try t.expectEqual(@as(Time, 0), scheduler.now);
    _ = try scheduler.scheduleAt(10, .nba, 4);
    try t.expectEqual(@as(u32, 4), scheduler.next().?.payload);
}

test "future sequence exhaustion reports before changing queued work" {
    var scheduler = Scheduler.init(t.allocator);
    defer scheduler.deinit();
    _ = try scheduler.schedule(.active, 1);
    scheduler.sequence = std.math.maxInt(u64);
    try t.expectError(error.SequenceOverflow, scheduler.scheduleAt(10, .nba, 99));
    try t.expectEqual(@as(u32, 1), scheduler.next().?.payload);
    try t.expect(scheduler.next() == null);
    try t.expectEqual(@as(Time, 0), scheduler.now);
}

test "pendingPayloads lists the live events and skips cancelled ones" {
    var s = Scheduler.init(std.testing.allocator);
    defer s.deinit();
    _ = try s.scheduleAt(5, .inactive, 0);
    const dead = try s.scheduleAt(7, .inactive, 1);
    _ = try s.scheduleAt(9, .nba, 2);
    _ = try s.cancel(dead);
    var out: std.ArrayList(Live) = .empty;
    defer out.deinit(std.testing.allocator);
    try s.pendingPayloads(std.testing.allocator, &out);
    std.mem.sort(Live, out.items, {}, byTime);
    try std.testing.expectEqualSlices(Live, &.{ .{ .time = 5, .payload = 0 }, .{ .time = 9, .payload = 2 } }, out.items);
    _ = try s.schedule(.active, 3);
    out.clearRetainingCapacity();
    try s.pendingPayloads(std.testing.allocator, &out);
    std.mem.sort(Live, out.items, {}, byTime);
    try std.testing.expectEqualSlices(Live, &.{ .{ .time = 0, .payload = 3 }, .{ .time = 5, .payload = 0 }, .{ .time = 9, .payload = 2 } }, out.items);
}

fn byTime(_: void, a: Live, b: Live) bool {
    return a.time < b.time;
}

test "future events dispatch by time, inactive before NBA, then schedule order; cancelled ones never" {
    // A model check: random future events and cancels against the order
    // §8.5.1 states, kept as a plain sorted list.
    const Row = struct { time: Time, kind: FutureKind, seq: u32, handle: Handle, live: bool };
    var prng = std.Random.DefaultPrng.init(0x851);
    const rand = prng.random();
    for (0..200) |_| {
        var s = Scheduler.init(t.allocator);
        defer s.deinit();
        var model: [64]Row = undefined;
        const n = rand.intRangeAtMost(usize, 0, model.len);
        for (model[0..n], 0..) |*row, i| {
            const at = rand.intRangeAtMost(Time, 1, 8);
            const kind: FutureKind = if (rand.boolean()) .inactive else .nba;
            row.* = .{ .time = at, .kind = kind, .seq = @intCast(i), .handle = try s.scheduleAt(at, kind, @intCast(i)), .live = true };
            // Now and then cancel an earlier event, which may be cancelled already.
            if (i != 0 and rand.uintLessThan(u8, 4) == 0) {
                const victim = &model[rand.uintLessThan(usize, i)];
                try t.expectEqual(victim.live, try s.cancel(victim.handle));
                victim.live = false;
            }
        }
        var want: [64]Row = undefined;
        var m: usize = 0;
        for (model[0..n]) |row| if (row.live) {
            want[m] = row;
            m += 1;
        };
        std.mem.sort(Row, want[0..m], {}, struct {
            fn lt(_: void, a: Row, b: Row) bool {
                if (a.time != b.time) return a.time < b.time;
                if (a.kind != b.kind) return a.kind == .inactive;
                return a.seq < b.seq;
            }
        }.lt);
        for (want[0..m]) |row| {
            try t.expectEqual(row.seq, s.payloadOf(row.handle).?);
            const e = s.next().?;
            try t.expectEqual(row.seq, e.payload);
            try t.expectEqual(row.time, e.time);
            try t.expectEqual(row.kind.region(), e.region);
            try t.expectEqual(@as(?u32, null), s.payloadOf(row.handle));
        }
        try t.expect(s.next() == null);
    }
}

test "cancelRange cancels the pending payloads in [lo, hi), now and later, and only those" {
    var s = Scheduler.init(t.allocator);
    defer s.deinit();
    _ = try s.schedule(.active, 4);
    _ = try s.schedule(.active, 5);
    _ = try s.scheduleAt(3, .inactive, 9);
    _ = try s.scheduleAt(3, .inactive, 10);
    try t.expect(try s.cancelRange(5, 10));
    // Nothing pending is left in the range.
    try t.expect(!try s.cancelRange(5, 10));
    try t.expect(!try s.cancelRange(7, 7));
    try t.expectEqual(@as(u32, 4), s.next().?.payload);
    const e = s.next().?;
    try t.expectEqual(@as(u32, 10), e.payload);
    try t.expectEqual(@as(Time, 3), e.time);
    try t.expect(s.next() == null);
}

test "peekTime skips a cancelled current-time event; a stopped queue has nothing pending" {
    var s = Scheduler.init(t.allocator);
    defer s.deinit();
    const h = try s.schedule(.active, 1);
    _ = try s.scheduleAt(5, .nba, 2);
    try t.expect(try s.cancel(h));
    try t.expectEqual(@as(?Time, 5), s.peekTime());
    s.finish();
    try t.expectEqual(@as(?Time, null), s.peekTime());
    var out: std.ArrayList(Live) = .empty;
    defer out.deinit(t.allocator);
    try s.pendingPayloads(t.allocator, &out);
    try t.expectEqual(@as(usize, 0), out.items.len);
}

test "restore into a fresh queue replays the saved one, and a saved finish stays finished" {
    var a = Scheduler.init(t.allocator);
    defer a.deinit();
    _ = try a.schedule(.monitor, 1);
    _ = try a.scheduleAt(4, .nba, 2);
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try a.save(&w);
    var b = Scheduler.init(t.allocator);
    defer b.deinit();
    var r: std.Io.Reader = .fixed(w.buffered());
    try b.restore(&r);
    try t.expectEqual(@as(u32, 1), b.next().?.payload);
    const e = b.next().?;
    try t.expectEqual(@as(u32, 2), e.payload);
    try t.expectEqual(@as(Time, 4), e.time);
    try t.expect(b.next() == null);

    a.finish();
    var w2: std.Io.Writer = .fixed(&buf);
    try a.save(&w2);
    var c = Scheduler.init(t.allocator);
    defer c.deinit();
    var r2: std.Io.Reader = .fixed(w2.buffered());
    try c.restore(&r2);
    try t.expect(c.next() == null);
    try t.expectError(error.Stopped, c.schedule(.active, 3));
}
