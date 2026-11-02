//! Scheduled payloads in, the VAMS-2023 §8.5 / IEEE 1364-2005 §11 order they
//! dispatch in out: time first, then region, then the order each region keeps.
//! A payload is a `u32` row of a table the caller owns; this file evaluates no
//! HDL and reads no payload.
//! Cites: VAMS-2023 §8.4.4, §8.5.1, §8.5.2, §8.5.3.6, §8.5.3.7; IEEE 1364-2005
//! §10.3, §11.4.1, §11.4.2, §26.6.25; VAMS §9.23 (the pending-driver queries
//! `pendingPayloads` serves).
//!
//! Contents:
//! - `pub const Time = u64`
//! - `pub const Region = enum(u3)`
//! - `pub const FutureKind = enum(u1)`
//! - `pub const Handle = struct`
//! - `pub const Event = struct`
//! - `pub const Live = struct`
//! - `pub const Scheduler = struct`
//! - `Scheduler.empty: Scheduler`, `Scheduler.Phase = union(enum)`, `Scheduler.Error`, `Scheduler.MutationError`,
//!   `Scheduler.RestoreError`, `Scheduler.slots_max`
//! - `Scheduler.deinit(self: *Scheduler, gpa: Allocator) void`
//! - `Scheduler.schedule(self: *Scheduler, gpa: Allocator, region: Region, payload: u32) Error!Handle`
//! - `Scheduler.scheduleFirst(self: *Scheduler, gpa: Allocator, region: Region, payload: u32) Error!Handle`
//! - `Scheduler.scheduleAfter(self: *Scheduler, gpa: Allocator, delay: Time, kind: FutureKind, payload: u32) Error!Handle`
//! - `Scheduler.cancel(self: *Scheduler, handle: Handle) MutationError!bool`
//! - `Scheduler.cancelRange(self: *Scheduler, lo: u32, hi: u32) MutationError!bool`
//! - `Scheduler.payloadOf(self: *const Scheduler, handle: Handle) ?u32`
//! - `Scheduler.finish(self: *Scheduler) void`
//! - `Scheduler.finishStep(self: *Scheduler) void`
//! - `Scheduler.next(self: *Scheduler) ?Event`
//! - `Scheduler.nextUntil(self: *Scheduler, limit: Time) ?Event`
//! - `Scheduler.peekTime(self: *Scheduler) ?Time`
//! - `Scheduler.pendingPayloads(self: *const Scheduler, gpa: Allocator, out: *std.ArrayList(Live)) Allocator.Error!void`
//! - `Scheduler.save(self: *const Scheduler, w: *std.Io.Writer) std.Io.Writer.Error!void`
//! - `Scheduler.restore(self: *Scheduler, gpa: Allocator, r: *std.Io.Reader) RestoreError!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const t = std.testing;

/// Integer ticks at the design's finest time precision. Scaling and rounding
/// belong to elaboration; all 64 bits are kept, so times above 2^53 are exact.
pub const Time = u64;

/// The six current-time regions, in dispatch order; the future heap is the
/// seventh. VAMS §8.5.1 and §8.5.3.6 put explicit D2A before inactive, and
/// §8.5.2's pseudocode reverses the two. This follows the normative text; the
/// LRM's §8.5.2 editorial note (docs/specification/VAMS-LRM-2023.pdf) records
/// the discrepancy.
pub const Region = enum(u3) { active, explicit_d2a, inactive, nba, analog, monitor };

/// The region a future event joins when its time comes. §8.5.1 lets only a
/// `#d` resumption (inactive) and a delayed nonblocking update (nba) wait for
/// a later time.
pub const FutureKind = enum(u1) {
    inactive,
    nba,

    /// Returns the current-time region this kind joins.
    pub fn region(kind: FutureKind) Region {
        return switch (kind) {
            .inactive => .inactive,
            .nba => .nba,
        };
    }
};

/// One scheduled event, for `cancel` and `payloadOf`. Stale once its event
/// dispatches or is cancelled: the generation no longer matches, so a stale
/// handle cancels nothing and never names the slot's next event.
pub const Handle = struct { slot: SlotId, generation: u32 };

/// One dispatched event as `next` returns it: `time` is `now`, `payload` the
/// caller's row, and `handle` already stale.
pub const Event = struct {
    time: Time,
    region: Region,
    payload: u32,
    handle: Handle,
};

/// One live event as `Scheduler.pendingPayloads` reports it.
pub const Live = struct { time: Time, payload: u32 };

/// The event queue of one simulation: a FIFO per current-time region and a
/// heap of future events, over one pool of slots a `Handle` names.
/// Invariants: a slot is on at most one list (a region FIFO, the heap or the
/// free list); a slot under a heap entry or a FIFO link is never reused, so a
/// cancel is lazy and the queue drops the slot when it reaches it.
/// The caller owns the memory: every growing call takes `gpa`, and `deinit`
/// frees with the same one.
pub const Scheduler = struct {
    /// The current simulation time. Only `nextUntil` advances it, except that
    /// the VPI host (src/vpi/run.zig) and the contract device (rt/device.zig)
    /// set it to a time they hold the queue at.
    now: Time = 0,
    slots: std.MultiArrayList(Slot) = .empty,
    heads: [region_count]SlotId = @splat(.none),
    tails: [region_count]SlotId = @splat(.none),
    future: std.PriorityQueue(Future, void, Future.compare) = .empty,
    free: SlotId = .none,
    /// Future events ever scheduled: the tie-break that keeps equal times in
    /// schedule order (§11.4.1 for nonblocking updates).
    sequence: u64 = 0,
    /// Read by the VPI host (`phase == .stopped`); written only here.
    phase: Phase = .idle,
    /// `finishStep` ran: the current time's regions drain, then the queue
    /// stops instead of advancing.
    finishing: bool = false,
    /// VAMS §8.5.1: a VPI read-write callback is an inactive event. When this
    /// is `now`, `nextUntil` returns null at this time's inactive point (after
    /// active, explicit D2A and inactive, before the NBA updates) and sets
    /// `synced`. Written by the VPI host (src/vpi/run.zig); `synced` is
    /// cleared by its reader (digital/root.zig).
    sync_at: ?Time = null,
    synced: bool = false,

    /// An empty queue at time 0; allocates nothing until the first event.
    pub const empty: Scheduler = .{};

    /// Most slots live at once: one below the `SlotId.none` sentinel.
    pub const slots_max: u32 = std.math.maxInt(u32) - 1;

    /// What the queue is doing between two calls.
    pub const Phase = union(enum) {
        /// No event is being dispatched.
        idle,
        /// The caller is running an event `next` returned from this region.
        /// During a monitor event the step has settled, and nothing may be
        /// scheduled or cancelled until the next `next`.
        dispatch: Region,
        /// `finish` ran, or `finishStep`'s time drained: nothing dispatches again.
        stopped,
    };

    /// Every way a schedule fails. On any error nothing is queued and every
    /// earlier `Handle` still names its event.
    pub const Error = Allocator.Error || MutationError || error{
        /// `slots_max` events are pending at once.
        TooManyEvents,
        /// 2^64 future events were ever scheduled, so FIFO order among equal
        /// times can no longer be kept.
        SequenceOverflow,
        /// `now + delay` passes 2^64 - 1.
        TimeOverflow,
    };

    /// Why the queue refuses a change: it is read-only, or it is over.
    pub const MutationError = error{
        /// A schedule or cancel while a monitor-region event is dispatched,
        /// which reads the settled step and must not change it.
        MonitorMutation,
        /// The queue stopped (`finish`, or `finishStep`'s time drained).
        Stopped,
    };

    /// Every way `restore` fails. A queue `restore` failed on is partly
    /// overwritten: `deinit` it, never run it.
    pub const RestoreError = std.Io.Reader.Error || Allocator.Error;

    /// Frees every slot and heap entry; invalidates every `Handle`.
    pub fn deinit(self: *Scheduler, gpa: Allocator) void {
        assert(self.future.items.len <= self.slots.len);
        self.slots.deinit(gpa);
        self.future.deinit(gpa);
        self.* = undefined;
    }

    /// Queues `payload` at `now` behind every event already in `region`.
    /// An A2D notification is an ordinary active event; the caller posts an
    /// analog request when an implicit or explicit D2A dependency needs one.
    /// May allocate one slot; invalidates no `Handle`.
    pub fn schedule(self: *Scheduler, gpa: Allocator, region: Region, payload: u32) Error!Handle {
        try self.checkMutation();
        const handle = try self.allocate(gpa, region, payload);
        self.append(region, handle.slot);
        assert(self.tails[@backingInt(region)] == handle.slot);
        assert(self.payloadOf(handle).? == payload);
        return handle;
    }

    /// `schedule`, but ahead of every event already in `region`.
    pub fn scheduleFirst(self: *Scheduler, gpa: Allocator, region: Region, payload: u32) Error!Handle {
        try self.checkMutation();
        const handle = try self.allocate(gpa, region, payload);
        const r = @backingInt(region);
        self.slots.items(.next)[@backingInt(handle.slot)] = self.heads[r];
        if (self.heads[r] == .none) self.tails[r] = handle.slot;
        self.heads[r] = handle.slot;
        assert(self.tails[r] != .none);
        assert(self.payloadOf(handle).? == payload);
        return handle;
    }

    /// Queues `payload` at `now + delay` in `kind`'s region. A zero delay is
    /// `schedule` at `now`: inactive means `#0`, and a nonblocking update
    /// stays in the NBA region. Equal future times keep schedule order. On
    /// any error nothing is queued.
    pub fn scheduleAfter(self: *Scheduler, gpa: Allocator, delay: Time, kind: FutureKind, payload: u32) Error!Handle {
        try self.checkMutation();
        const time = std.math.add(Time, self.now, delay) catch return error.TimeOverflow;
        if (time == self.now) return self.schedule(gpa, kind.region(), payload);
        if (self.sequence == std.math.maxInt(u64)) return error.SequenceOverflow;
        const handle = try self.allocate(gpa, kind.region(), payload);
        errdefer self.release(handle.slot);
        const entries_before = self.future.items.len;
        try self.future.push(gpa, .{ .time = time, .order = self.sequence, .slot = handle.slot });
        self.sequence += 1;
        assert(self.future.items.len == entries_before + 1);
        assert(time > self.now);
        return handle;
    }

    /// Cancels the event `handle` names; whether it was still pending. A
    /// stale handle cancels nothing. Lazy: the slot stays on its list until
    /// the queue reaches it, and a cancelled future minimum never advances
    /// the clock.
    pub fn cancel(self: *Scheduler, handle: Handle) MutationError!bool {
        try self.checkMutation();
        if (self.payloadOf(handle) == null) return false;
        const state = &self.slots.items(.state)[@backingInt(handle.slot)];
        assert(state.* == .pending);
        state.* = .cancelled;
        assert(self.payloadOf(handle) == null);
        return true;
    }

    /// Cancels every pending event whose payload is in `[lo, hi)`; whether any
    /// was. IEEE 1364-2005 §10.3 `disable` of a native design, whose payloads
    /// are the pcs its processes resume at. O(slots ever allocated).
    /// Asserts that `lo <= hi`.
    pub fn cancelRange(self: *Scheduler, lo: u32, hi: u32) MutationError!bool {
        assert(lo <= hi);
        try self.checkMutation();
        var hit = false;
        for (self.slots.items(.state), self.slots.items(.payload)) |*state, payload| {
            if (state.* != .pending or payload < lo or payload >= hi) continue;
            state.* = .cancelled;
            hit = true;
        }
        if (lo == hi) assert(!hit);
        return hit;
    }

    /// The payload `handle` was scheduled with while its event is pending;
    /// null once it has dispatched or been cancelled. A caller that recycles
    /// payload rows asks this before cancelling, to learn which row the cancel
    /// frees.
    pub fn payloadOf(self: *const Scheduler, handle: Handle) ?u32 {
        const index = @backingInt(handle.slot);
        if (index >= self.slots.len) return null;
        if (self.slots.items(.generation)[index] != handle.generation) return null;
        if (self.slots.items(.state)[index] != .pending) return null;
        return self.slots.items(.payload)[index];
    }

    /// Stops the queue: nothing pending dispatches again, and every schedule
    /// or cancel fails with `error.Stopped`. `deinit` still frees the storage.
    /// This runs no analog final step and no HDL finalization.
    pub fn finish(self: *Scheduler) void {
        self.phase = .stopped;
        assert(self.phase == .stopped);
    }

    /// Stops once every region of the current time is empty: what this time
    /// step has queued still dispatches, no later time does.
    pub fn finishStep(self: *Scheduler) void {
        self.finishing = true;
        assert(self.finishing);
    }

    /// `nextUntil` with no limit.
    pub fn next(self: *Scheduler) ?Event {
        return self.nextUntil(std.math.maxInt(Time));
    }

    /// Completes the preceding dispatch and returns the next event, advancing
    /// time no further than `limit`. Promotion moves a whole region into
    /// active, and active work scheduled during a dispatch joins its tail:
    /// FIFO is one order §11.4.2 permits among active events, and NBA updates
    /// keep the order §11.4.1 requires. Returns null, with `now` and the heap
    /// untouched, when every region at `now` is empty and the earliest future
    /// event lies after `limit`, so a later call with a larger limit resumes
    /// where this one stopped (VAMS §8.4.4's common global time). Also null at
    /// `sync_at`'s inactive point (`synced` is then set) and once stopped.
    /// While a returned monitor event runs, schedule and cancel fail with
    /// `error.MonitorMutation`. Cost: O(1) amortized per event, plus one scan
    /// of the active list per analog dispatch.
    pub fn nextUntil(self: *Scheduler, limit: Time) ?Event {
        if (self.phase == .stopped) return null;
        self.phase = .idle;
        // Each pass dispatches, releases a cancelled slot, promotes a
        // non-empty list or moves heap entries, so the passes before a return
        // are bounded by twice the slots plus the final checks.
        const passes_max = 2 * self.slots.len + 2;
        var passes: usize = 0;
        while (true) : (passes += 1) {
            assert(passes <= passes_max);
            if (self.dispatchActive()) |event| return event;
            if (self.promote()) |promoted| {
                if (!promoted) return null; // `sync_at`'s inactive point.
                continue;
            }
            if (self.syncHere()) return null;
            if (self.finishing) {
                self.phase = .stopped;
                return null;
            }
            if (!self.advance(limit)) return null;
        }
    }

    /// The time of the event `next` would return, or null when nothing is
    /// pending. `now` while any current-time region holds a live event.
    /// Cancelled future minima are purged first, so a cancelled event never
    /// reports a phantom time (the rule `advance` keeps). O(current-time events).
    pub fn peekTime(self: *Scheduler) ?Time {
        if (self.phase == .stopped) return null;
        if (self.livePresent()) return self.now;
        self.purgeCancelled();
        const entry = self.future.peek() orelse return null;
        assert(entry.time >= self.now);
        return entry.time;
    }

    /// Appends every live event as (time, payload), in no particular order; a
    /// current-time event reports `now`. Read-only: the heap is scanned, not
    /// popped. Readers: VAMS §9.23's pending-driver queries
    /// (digital/driver.zig) and IEEE 1364 §26.6.25's `vpiTimeQueue` iteration
    /// (src/vpi/run.zig). On `OutOfMemory`, `out` holds what was appended. A
    /// stopped queue appends nothing. O(slots).
    /// Invalidates element pointers of `out` if additional memory is needed.
    pub fn pendingPayloads(self: *const Scheduler, gpa: Allocator, out: *std.ArrayList(Live)) Allocator.Error!void {
        if (self.phase == .stopped) return;
        const len_before = out.items.len;
        const state = self.slots.items(.state);
        const links = self.slots.items(.next);
        const payloads = self.slots.items(.payload);
        for (self.heads) |head| {
            var cursor = head;
            var steps: usize = 0;
            while (cursor != .none) : (cursor = links[@backingInt(cursor)]) {
                steps += 1;
                assert(steps <= self.slots.len);
                const i = @backingInt(cursor);
                if (state[i] == .pending) try out.append(gpa, .{ .time = self.now, .payload = payloads[i] });
            }
        }
        for (self.future.items) |entry| {
            const i = @backingInt(entry.slot);
            if (state[i] == .pending) try out.append(gpa, .{ .time = entry.time, .payload = payloads[i] });
        }
        assert(out.items.len - len_before <= self.slots.len);
    }

    /// Writes the whole queue as bytes `restore` reads back: every slot, so a
    /// `Handle` taken before `save` names the same event after `restore`; the
    /// region lists; the heap in its array order; the clock. O(slots) bytes,
    /// in this build's layout: only `restore` in the same build reads them.
    pub fn save(self: *const Scheduler, w: *std.Io.Writer) std.Io.Writer.Error!void {
        assert(self.future.items.len <= self.slots.len);
        const lens = [2]u32{ @intCast(self.slots.len), @intCast(self.future.items.len) };
        try w.writeAll(std.mem.asBytes(&lens));
        inline for (.{ &self.now, &self.heads, &self.tails, &self.free, &self.sequence, &self.phase, &self.finishing }) |field|
            try w.writeAll(std.mem.asBytes(field));
        inline for (comptime std.enums.values(std.MultiArrayList(Slot).Field)) |field|
            try w.writeAll(std.mem.sliceAsBytes(self.slots.items(field)));
        try w.writeAll(std.mem.sliceAsBytes(self.future.items));
    }

    /// Replaces every slot, region list and heap entry with the queue `save`
    /// wrote to `r`. Asserts that the bytes are `save`'s: the heap fits in the
    /// slots. Invalidates element pointers into the slots and the heap.
    pub fn restore(self: *Scheduler, gpa: Allocator, r: *std.Io.Reader) RestoreError!void {
        var lens: [2]u32 = undefined;
        try r.readSliceAll(std.mem.asBytes(&lens));
        assert(lens[1] <= lens[0]); // Pair of `save`'s entry assert.
        inline for (.{ &self.now, &self.heads, &self.tails, &self.free, &self.sequence, &self.phase, &self.finishing }) |field|
            try r.readSliceAll(std.mem.asBytes(field));
        try self.slots.resize(gpa, lens[0]);
        inline for (comptime std.enums.values(std.MultiArrayList(Slot).Field)) |field|
            try r.readSliceAll(std.mem.sliceAsBytes(self.slots.items(field)));
        try self.future.ensureTotalCapacity(gpa, lens[1]);
        self.future.items.len = lens[1];
        try r.readSliceAll(std.mem.sliceAsBytes(self.future.items));
        assert(self.slots.len == lens[0]);
    }

    // ---- private ----

    fn checkMutation(self: *const Scheduler) MutationError!void {
        switch (self.phase) {
            .stopped => return error.Stopped,
            .dispatch => |region| if (region == .monitor) return error.MonitorMutation,
            .idle => {},
        }
    }

    fn allocate(self: *Scheduler, gpa: Allocator, region: Region, payload: u32) Error!Handle {
        const slot: SlotId = if (self.free != .none) reused: {
            const id = self.free;
            const index = @backingInt(id);
            assert(self.slots.items(.state)[index] == .free);
            self.free = self.slots.items(.next)[index];
            self.slots.items(.next)[index] = .none;
            self.slots.items(.payload)[index] = payload;
            self.slots.items(.region)[index] = region;
            self.slots.items(.state)[index] = .pending;
            break :reused id;
        } else fresh: {
            if (self.slots.len == slots_max) return error.TooManyEvents;
            const id: SlotId = @fromBackingInt(@intCast(self.slots.len));
            try self.slots.append(gpa, .{ .payload = payload, .region = region });
            break :fresh id;
        };
        assert(slot != .none);
        return .{ .slot = slot, .generation = self.slots.items(.generation)[@backingInt(slot)] };
    }

    fn release(self: *Scheduler, slot: SlotId) void {
        const index = @backingInt(slot);
        assert(self.slots.items(.state)[index] != .free);
        assert(self.slots.items(.next)[index] == .none);
        if (self.slots.items(.generation)[index] == std.math.maxInt(u32)) {
            // An exhausted generation retires its slot for good, so a stale
            // handle can never name a new event.
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
        assert(self.slots.items(.next)[@backingInt(slot)] == .none);
        if (self.tails[r] == .none) {
            assert(self.heads[r] == .none);
            self.heads[r] = slot;
        } else self.slots.items(.next)[@backingInt(self.tails[r])] = slot;
        self.tails[r] = slot;
    }

    /// Pops active slots until one is pending and returns it as an event;
    /// releases the cancelled ones it passes. Null when active is empty.
    fn dispatchActive(self: *Scheduler) ?Event {
        var steps: usize = 0;
        while (self.take(.active)) |slot| {
            steps += 1;
            assert(steps <= self.slots.len);
            const index = @backingInt(slot);
            if (self.slots.items(.state)[index] == .cancelled) {
                self.release(slot);
                continue;
            }
            assert(self.slots.items(.state)[index] == .pending);
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
        assert(self.heads[0] == .none);
        return null;
    }

    /// Moves the first non-empty region after active into active: true when
    /// one moved, false when the queue holds at `sync_at`'s inactive point
    /// first, null when every region is empty.
    fn promote(self: *Scheduler) ?bool {
        assert(self.heads[@backingInt(Region.active)] == .none);
        inline for (.{ Region.explicit_d2a, Region.inactive, Region.nba, Region.analog, Region.monitor }) |region| {
            const r = @backingInt(region);
            if (self.heads[r] != .none) {
                // VAMS §8.5.1: the inactive point is reached once active,
                // explicit D2A and inactive are empty, before the NBA updates.
                if (comptime region == .nba or region == .analog or region == .monitor)
                    if (self.syncHere()) return false;
                self.heads[0] = self.heads[r];
                self.tails[0] = self.tails[r];
                self.heads[r] = .none;
                self.tails[r] = .none;
                assert(self.heads[0] != .none);
                return true;
            }
        }
        return null;
    }

    /// Whether `nextUntil` stops at this time's inactive point: `sync_at` is
    /// `now` and no event of `now` is still in the heap (a caller that set
    /// `now` itself, as the VPI loop does, leaves them there until `advance`).
    /// Clears the request and sets `synced`, which the caller reads.
    fn syncHere(self: *Scheduler) bool {
        const at = self.sync_at orelse return false;
        if (at != self.now) return false;
        self.purgeCancelled();
        if (self.future.peek()) |entry| if (entry.time == self.now) return false;
        self.sync_at = null;
        self.synced = true;
        return true;
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

    fn livePresent(self: *const Scheduler) bool {
        const state = self.slots.items(.state);
        const links = self.slots.items(.next);
        for (self.heads) |head| {
            var cursor = head;
            var steps: usize = 0;
            while (cursor != .none) : (cursor = links[@backingInt(cursor)]) {
                steps += 1;
                assert(steps <= self.slots.len);
                if (state[@backingInt(cursor)] == .pending) return true;
            }
        }
        return false;
    }

    fn purgeCancelled(self: *Scheduler) void {
        const entries_max = self.future.items.len;
        var purged: usize = 0;
        while (self.future.peek()) |entry| : (purged += 1) {
            assert(purged <= entries_max);
            if (self.slots.items(.state)[@backingInt(entry.slot)] != .cancelled) break;
            _ = self.future.pop();
            self.release(entry.slot);
        }
    }

    /// Moves every heap entry of the earliest live future time onto its
    /// region list and makes it `now`; false when there is none or it lies
    /// after `limit`.
    fn advance(self: *Scheduler, limit: Time) bool {
        // Purge dead minima first: a cancellation must not make a phantom
        // time step, also when every future event was cancelled.
        self.purgeCancelled();
        const first = self.future.peek() orelse return false;
        if (first.time > limit) return false;
        assert(first.time >= self.now);
        self.now = first.time;
        const entries_max = self.future.items.len;
        var moved: usize = 0;
        while (self.future.peek()) |entry| : (moved += 1) {
            assert(moved <= entries_max);
            if (entry.time != self.now) break;
            _ = self.future.pop();
            const index = @backingInt(entry.slot);
            if (self.slots.items(.state)[index] == .cancelled) {
                self.release(entry.slot);
            } else self.append(self.slots.items(.region)[index], entry.slot);
        }
        assert(moved > 0);
        return true;
    }

    /// §8.5.3.7: one solve consumes every active request of its
    /// macro-process; a request posted after the solve's feedback stays
    /// eligible for a new one.
    // ponytail: linear scan of this active wave; a per-macro index if large
    // analog waves make it matter.
    fn consumeAnalog(self: *Scheduler, payload: u32) void {
        var previous: SlotId = .none;
        var cursor = self.heads[0];
        var steps: usize = 0;
        while (cursor != .none) {
            steps += 1;
            assert(steps <= self.slots.len);
            const index = @backingInt(cursor);
            const following = self.slots.items(.next)[index];
            if (self.slots.items(.region)[index] == .analog and self.slots.items(.payload)[index] == payload) {
                if (previous == .none) self.heads[0] = following else self.slots.items(.next)[@backingInt(previous)] = following;
                if (self.tails[0] == cursor) self.tails[0] = previous;
                self.slots.items(.next)[index] = .none;
                self.release(cursor);
            } else previous = cursor;
            cursor = following;
        }
        assert(self.tails[0] == previous);
    }
};

const region_count = std.enums.values(Region).len;

/// A slot of the pool; `none` is the sentinel of every link.
const SlotId = enum(u32) { none = std.math.maxInt(u32), _ };

const SlotState = enum(u2) { pending, cancelled, free, retired };

/// One row of the slot pool. SoA: list walks read `next` and `state`,
/// dispatch reads `payload`, `region` and `generation`.
const Slot = struct {
    next: SlotId = .none,
    payload: u32,
    generation: u32 = 0,
    region: Region,
    state: SlotState = .pending,
};

/// One heap entry per future event. Every sift reads `time` and `order`
/// together, so the entry stays one 24-byte row.
const Future = struct {
    time: Time,
    order: u64,
    slot: SlotId,

    fn compare(_: void, a: Future, b: Future) std.math.Order {
        if (a.time != b.time) return std.math.order(a.time, b.time);
        return std.math.order(a.order, b.order);
    }
};

comptime {
    assert(@sizeOf(SlotId) == 4);
    assert(@sizeOf(Handle) == 8);
    // One per dispatch, returned by value: 21 bytes of fields, 3 of padding.
    assert(@sizeOf(Event) == 24);
    assert(@sizeOf(Future) == 24);
    assert(region_count == 6);
    assert(Scheduler.slots_max < @backingInt(SlotId.none));
}

// ---- private ----

fn allocationExercise(gpa: Allocator) !void {
    var scheduler: Scheduler = .empty;
    defer scheduler.deinit(gpa);
    for (0..64) |i| {
        _ = try scheduler.schedule(gpa, .active, @intCast(i));
        _ = try scheduler.scheduleAfter(gpa, 1 + @as(Time, @intCast(i)), .nba, @intCast(i));
    }
    // `restore` grows a fresh queue to the saved one's size.
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try scheduler.save(&w);
    var copy: Scheduler = .empty;
    defer copy.deinit(gpa);
    var r: std.Io.Reader = .fixed(w.buffered());
    try copy.restore(gpa, &r);
    var count: usize = 0;
    while (copy.next() != null) count += 1;
    try t.expectEqual(@as(usize, 128), count);
}

fn byTime(_: void, a: Live, b: Live) bool {
    return a.time < b.time;
}

test "seven logical regions follow normative AMS order and integer future time" {
    var scheduler: Scheduler = .empty;
    defer scheduler.deinit(t.allocator);
    const gpa = t.allocator;
    // Deliberately enqueue in reverse region order. Future NBA was enqueued
    // before future inactive, but the latter resumes before the NBA updates.
    _ = try scheduler.scheduleAfter(gpa, 7, .nba, 8);
    _ = try scheduler.scheduleAfter(gpa, 7, .inactive, 7);
    _ = try scheduler.schedule(gpa, .monitor, 6);
    _ = try scheduler.schedule(gpa, .analog, 5);
    _ = try scheduler.schedule(gpa, .nba, 4);
    _ = try scheduler.schedule(gpa, .inactive, 3);
    _ = try scheduler.schedule(gpa, .explicit_d2a, 2);
    _ = try scheduler.schedule(gpa, .active, 1);
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
    var scheduler: Scheduler = .empty;
    defer scheduler.deinit(t.allocator);
    const gpa = t.allocator;
    try t.expectEqual(@as(?Time, null), scheduler.peekTime());
    _ = try scheduler.schedule(gpa, .nba, 1);
    const late = try scheduler.scheduleAfter(gpa, 5, .inactive, 2);
    _ = try scheduler.scheduleAfter(gpa, 9, .inactive, 3);
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
    var s: Scheduler = .empty;
    defer s.deinit(t.allocator);
    const gpa = t.allocator;
    _ = try s.schedule(gpa, .nba, 1);
    const h = try s.scheduleAfter(gpa, 5, .inactive, 2);
    _ = try s.scheduleAfter(gpa, 5, .nba, 3);
    _ = try s.scheduleAfter(gpa, 9, .inactive, 4);
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try s.save(&w);
    var first: [4]u32 = undefined;
    for (&first) |*p| p.* = s.next().?.payload;
    _ = try s.scheduleAfter(gpa, 11, .inactive, 99);
    var r: std.Io.Reader = .fixed(w.buffered());
    try s.restore(gpa, &r);
    try t.expect(try s.cancel(h));
    try t.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, &first);
    for ([_]u32{ 1, 3, 4 }) |p| try t.expectEqual(p, s.next().?.payload);
    try t.expect(s.next() == null);
    try t.expectEqual(@as(Time, 9), s.now);
}

test "NBA batch, inactive reentry and analog feedback settle before monitor" {
    var scheduler: Scheduler = .empty;
    defer scheduler.deinit(t.allocator);
    const gpa = t.allocator;
    var value: u32 = 0;
    _ = try scheduler.schedule(gpa, .monitor, 10);
    _ = try scheduler.schedule(gpa, .analog, 6);
    _ = try scheduler.schedule(gpa, .nba, 1);
    _ = try scheduler.schedule(gpa, .nba, 2);
    var trace: [10]u32 = undefined;
    var count: usize = 0;
    while (scheduler.next()) |event| {
        trace[count] = event.payload;
        count += 1;
        switch (event.payload) {
            1 => {
                value = 1;
                _ = try scheduler.schedule(gpa, .active, 3);
            },
            2 => {
                value = 2;
                _ = try scheduler.schedule(gpa, .inactive, 4);
            },
            3 => try t.expectEqual(@as(u32, 2), value),
            4 => {
                _ = try scheduler.schedule(gpa, .nba, 5);
            },
            5 => value = 3,
            6 => {
                try t.expectEqual(@as(u32, 3), value);
                // The analog consumer publishes an ordinary active A2D event.
                _ = try scheduler.schedule(gpa, .active, 7);
            },
            7 => {
                value = 4;
                _ = try scheduler.schedule(gpa, .analog, 9);
                _ = try scheduler.schedule(gpa, .explicit_d2a, 8);
            },
            8, 9, 10 => try t.expectEqual(@as(u32, 4), value),
            else => unreachable,
        }
        try t.expectEqual(@as(Time, 0), event.time);
    }
    try t.expectEqualSlices(u32, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }, trace[0..count]);
}

test "whole inactive promotion uses FIFO active choice and permits another delta" {
    var scheduler: Scheduler = .empty;
    defer scheduler.deinit(t.allocator);
    const gpa = t.allocator;
    _ = try scheduler.scheduleAfter(gpa, 0, .inactive, 1);
    _ = try scheduler.schedule(gpa, .inactive, 2);
    try t.expectEqual(@as(u32, 1), scheduler.next().?.payload);
    _ = try scheduler.schedule(gpa, .active, 3);
    _ = try scheduler.schedule(gpa, .inactive, 4);
    // Once promoted, the remaining inactive event is an active event too.
    for ([_]u32{ 2, 3, 4 }) |payload| try t.expectEqual(payload, scheduler.next().?.payload);
    try t.expect(scheduler.next() == null);
    try t.expectEqual(@as(Time, 0), scheduler.now);
}

test "analog solve consumes active duplicates but later feedback requests run" {
    var scheduler: Scheduler = .empty;
    defer scheduler.deinit(t.allocator);
    const gpa = t.allocator;
    _ = try scheduler.schedule(gpa, .analog, 10);
    _ = try scheduler.schedule(gpa, .analog, 20);
    const duplicate = try scheduler.schedule(gpa, .analog, 10);
    _ = try scheduler.schedule(gpa, .analog, 10);
    try t.expectEqual(@as(u32, 10), scheduler.next().?.payload);
    try t.expect(!try scheduler.cancel(duplicate));
    _ = try scheduler.schedule(gpa, .analog, 10); // A new request after the first solve.
    _ = try scheduler.schedule(gpa, .active, 30);
    for ([_]u32{ 20, 30, 10 }) |payload| try t.expectEqual(payload, scheduler.next().?.payload);
    try t.expect(scheduler.next() == null);
}

test "monitor dispatch rejects event mutation until the caller completes it" {
    var scheduler: Scheduler = .empty;
    defer scheduler.deinit(t.allocator);
    const gpa = t.allocator;
    const later = try scheduler.scheduleAfter(gpa, 10, .inactive, 3);
    _ = try scheduler.schedule(gpa, .monitor, 1);
    _ = try scheduler.schedule(gpa, .monitor, 2);
    for ([_]u32{ 1, 2 }) |payload| {
        try t.expectEqual(payload, scheduler.next().?.payload);
        try t.expectError(error.MonitorMutation, scheduler.schedule(gpa, .active, 99));
        try t.expectError(error.MonitorMutation, scheduler.scheduleAfter(gpa, 20, .inactive, 99));
        try t.expectError(error.MonitorMutation, scheduler.cancel(later));
    }
    try t.expectEqual(@as(u32, 3), scheduler.next().?.payload);
    _ = try scheduler.schedule(gpa, .active, 4);
    try t.expectEqual(@as(u32, 4), scheduler.next().?.payload);
    try t.expect(scheduler.next() == null);
}

test "cancelling earliest or all future events does not create phantom times" {
    var scheduler: Scheduler = .empty;
    defer scheduler.deinit(t.allocator);
    const gpa = t.allocator;
    const first = try scheduler.scheduleAfter(gpa, 2, .inactive, 1);
    const second = try scheduler.scheduleAfter(gpa, 3, .nba, 2);
    _ = try scheduler.scheduleAfter(gpa, 9, .nba, 3);
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
    const last = try scheduler.scheduleAfter(gpa, 91, .inactive, 4);
    try t.expect(try scheduler.cancel(last));
    try t.expect(scheduler.next() == null);
    try t.expectEqual(@as(Time, 9), scheduler.now);
}

test "current cancellation and generation retirement cannot alias new events" {
    var scheduler: Scheduler = .empty;
    defer scheduler.deinit(t.allocator);
    const gpa = t.allocator;
    const old = try scheduler.schedule(gpa, .active, 1);
    try t.expect(try scheduler.cancel(old));
    try t.expect(scheduler.next() == null);
    const replacement = try scheduler.schedule(gpa, .active, 2);
    try t.expectEqual(old.slot, replacement.slot);
    try t.expect(old.generation != replacement.generation);
    try t.expect(!try scheduler.cancel(old));
    try t.expectEqual(@as(u32, 2), scheduler.next().?.payload);
    var exhausted = try scheduler.schedule(gpa, .active, 3);
    exhausted.generation = std.math.maxInt(u32);
    scheduler.slots.items(.generation)[@backingInt(exhausted.slot)] = exhausted.generation;
    try t.expect(try scheduler.cancel(exhausted));
    try t.expect(scheduler.next() == null);
    const fresh = try scheduler.schedule(gpa, .active, 4);
    try t.expect(fresh.slot != exhausted.slot);
    try t.expect(!try scheduler.cancel(exhausted));
    try t.expectEqual(@as(u32, 4), scheduler.next().?.payload);
}

test "timestamps exceed float precision and overflow cannot wrap into the past" {
    var scheduler: Scheduler = .empty;
    defer scheduler.deinit(t.allocator);
    const gpa = t.allocator;
    const large: Time = (1 << 53) + 1;
    _ = try scheduler.scheduleAfter(gpa, large + 1, .inactive, 2);
    _ = try scheduler.scheduleAfter(gpa, large, .inactive, 1);
    try t.expectEqual(large, scheduler.next().?.time);
    try t.expectEqual(large + 1, scheduler.next().?.time);
    _ = try scheduler.scheduleAfter(gpa, std.math.maxInt(Time) - scheduler.now, .nba, 4);
    try t.expectEqual(std.math.maxInt(Time), scheduler.next().?.time);
    try t.expectError(error.TimeOverflow, scheduler.scheduleAfter(gpa, 1, .inactive, 5));
    _ = try scheduler.scheduleAfter(gpa, 0, .nba, 6);
    try t.expectEqual(@as(u32, 6), scheduler.next().?.payload);
    try t.expect(scheduler.next() == null);
}

test "future NBA insertion order is preserved even with recycled slots" {
    var scheduler: Scheduler = .empty;
    defer scheduler.deinit(t.allocator);
    const gpa = t.allocator;
    _ = try scheduler.schedule(gpa, .active, 0);
    _ = try scheduler.schedule(gpa, .active, 0);
    _ = scheduler.next();
    _ = scheduler.next();
    const first = try scheduler.scheduleAfter(gpa, 10, .nba, 1);
    const second = try scheduler.scheduleAfter(gpa, 10, .nba, 2);
    try t.expect(@backingInt(first.slot) > @backingInt(second.slot));
    try t.expectEqual(@as(u32, 1), scheduler.next().?.payload);
    try t.expectEqual(@as(u32, 2), scheduler.next().?.payload);
    try t.expect(scheduler.next() == null);
}

test "finishStep drains the current time's regions and never advances" {
    var scheduler: Scheduler = .empty;
    defer scheduler.deinit(t.allocator);
    const gpa = t.allocator;
    _ = try scheduler.schedule(gpa, .active, 1);
    _ = try scheduler.schedule(gpa, .monitor, 2);
    _ = try scheduler.scheduleAfter(gpa, 5, .inactive, 3);
    scheduler.finishStep();
    try t.expectEqual(@as(u32, 1), scheduler.next().?.payload);
    try t.expectEqual(@as(u32, 2), scheduler.next().?.payload);
    try t.expect(scheduler.next() == null);
    try t.expectEqual(@as(Time, 0), scheduler.now);
}

test "finish is terminal and does not advance or dispatch queued events" {
    var scheduler: Scheduler = .empty;
    defer scheduler.deinit(t.allocator);
    const gpa = t.allocator;
    const pending = try scheduler.schedule(gpa, .active, 1);
    _ = try scheduler.scheduleAfter(gpa, 50, .nba, 2);
    scheduler.finish();
    try t.expect(scheduler.next() == null);
    try t.expectEqual(@as(Time, 0), scheduler.now);
    try t.expectError(error.Stopped, scheduler.schedule(gpa, .active, 3));
    try t.expectError(error.Stopped, scheduler.cancel(pending));
    scheduler.finish();
}

test "allocation failure releases queue storage, partial future insertion and a partial restore" {
    try t.checkAllAllocationFailures(t.allocator, allocationExercise, .{});
}

test "failed future allocation leaves prior queue work and reusable slots intact" {
    var failing = t.FailingAllocator.init(t.allocator, .{});
    const gpa = failing.allocator();
    var scheduler: Scheduler = .empty;
    defer scheduler.deinit(gpa);
    _ = try scheduler.schedule(gpa, .active, 1);
    _ = try scheduler.schedule(gpa, .active, 2);
    _ = scheduler.next(); // One reusable slot; the other event stays pending.
    failing.fail_index = failing.alloc_index;
    try t.expectError(error.OutOfMemory, scheduler.scheduleAfter(gpa, 10, .nba, 99));
    failing.fail_index = std.math.maxInt(usize);
    _ = try scheduler.schedule(gpa, .active, 3);
    for ([_]u32{ 2, 3 }) |payload| try t.expectEqual(payload, scheduler.next().?.payload);
    try t.expect(scheduler.next() == null);
    try t.expectEqual(@as(Time, 0), scheduler.now);
    _ = try scheduler.scheduleAfter(gpa, 10, .nba, 4);
    try t.expectEqual(@as(u32, 4), scheduler.next().?.payload);
}

test "future sequence exhaustion reports before changing queued work" {
    var scheduler: Scheduler = .empty;
    defer scheduler.deinit(t.allocator);
    const gpa = t.allocator;
    _ = try scheduler.schedule(gpa, .active, 1);
    scheduler.sequence = std.math.maxInt(u64);
    try t.expectError(error.SequenceOverflow, scheduler.scheduleAfter(gpa, 10, .nba, 99));
    try t.expectEqual(@as(u32, 1), scheduler.next().?.payload);
    try t.expect(scheduler.next() == null);
    try t.expectEqual(@as(Time, 0), scheduler.now);
}

test "pendingPayloads lists the live events and skips cancelled ones" {
    var s: Scheduler = .empty;
    defer s.deinit(t.allocator);
    const gpa = t.allocator;
    _ = try s.scheduleAfter(gpa, 5, .inactive, 0);
    const dead = try s.scheduleAfter(gpa, 7, .inactive, 1);
    _ = try s.scheduleAfter(gpa, 9, .nba, 2);
    _ = try s.cancel(dead);
    var out: std.ArrayList(Live) = .empty;
    defer out.deinit(gpa);
    try s.pendingPayloads(gpa, &out);
    std.mem.sort(Live, out.items, {}, byTime);
    try t.expectEqualSlices(Live, &.{ .{ .time = 5, .payload = 0 }, .{ .time = 9, .payload = 2 } }, out.items);
    _ = try s.schedule(gpa, .active, 3);
    out.clearRetainingCapacity();
    try s.pendingPayloads(gpa, &out);
    std.mem.sort(Live, out.items, {}, byTime);
    try t.expectEqualSlices(Live, &.{ .{ .time = 0, .payload = 3 }, .{ .time = 5, .payload = 0 }, .{ .time = 9, .payload = 2 } }, out.items);
}

test "future events dispatch by time, inactive before NBA, then schedule order; cancelled ones never" {
    // A model check: random future events and cancels against the order
    // §8.5.1 states, kept as a plain sorted list.
    const Row = struct { time: Time, kind: FutureKind, seq: u32, handle: Handle, live: bool };
    var prng = std.Random.DefaultPrng.init(0x851);
    const rand = prng.random();
    const gpa = t.allocator;
    for (0..200) |_| {
        var s: Scheduler = .empty;
        defer s.deinit(gpa);
        var model: [64]Row = undefined;
        const n = rand.intRangeAtMost(usize, 0, model.len);
        for (model[0..n], 0..) |*row, i| {
            const at = rand.intRangeAtMost(Time, 1, 8);
            const kind: FutureKind = if (rand.boolean()) .inactive else .nba;
            row.* = .{ .time = at, .kind = kind, .seq = @intCast(i), .handle = try s.scheduleAfter(gpa, at, kind, @intCast(i)), .live = true };
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
    var s: Scheduler = .empty;
    defer s.deinit(t.allocator);
    const gpa = t.allocator;
    _ = try s.schedule(gpa, .active, 4);
    _ = try s.schedule(gpa, .active, 5);
    _ = try s.scheduleAfter(gpa, 3, .inactive, 9);
    _ = try s.scheduleAfter(gpa, 3, .inactive, 10);
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
    var s: Scheduler = .empty;
    defer s.deinit(t.allocator);
    const gpa = t.allocator;
    const h = try s.schedule(gpa, .active, 1);
    _ = try s.scheduleAfter(gpa, 5, .nba, 2);
    try t.expect(try s.cancel(h));
    try t.expectEqual(@as(?Time, 5), s.peekTime());
    s.finish();
    try t.expectEqual(@as(?Time, null), s.peekTime());
    var out: std.ArrayList(Live) = .empty;
    defer out.deinit(gpa);
    try s.pendingPayloads(gpa, &out);
    try t.expectEqual(@as(usize, 0), out.items.len);
}

test "restore into a fresh queue replays the saved one, and a saved finish stays finished" {
    var a: Scheduler = .empty;
    defer a.deinit(t.allocator);
    const gpa = t.allocator;
    _ = try a.schedule(gpa, .monitor, 1);
    _ = try a.scheduleAfter(gpa, 4, .nba, 2);
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try a.save(&w);
    var b: Scheduler = .empty;
    defer b.deinit(gpa);
    var r: std.Io.Reader = .fixed(w.buffered());
    try b.restore(gpa, &r);
    try t.expectEqual(@as(u32, 1), b.next().?.payload);
    const e = b.next().?;
    try t.expectEqual(@as(u32, 2), e.payload);
    try t.expectEqual(@as(Time, 4), e.time);
    try t.expect(b.next() == null);

    a.finish();
    var w2: std.Io.Writer = .fixed(&buf);
    try a.save(&w2);
    var c: Scheduler = .empty;
    defer c.deinit(gpa);
    var r2: std.Io.Reader = .fixed(w2.buffered());
    try c.restore(gpa, &r2);
    try t.expect(c.next() == null);
    try t.expectError(error.Stopped, c.schedule(gpa, .active, 3));
}

test "sync_at holds the queue at the inactive point, before NBA updates, and sets synced" {
    // Oracle: VAMS §8.5.1's region list: a read-write synch callback runs
    // once active, explicit D2A and inactive are empty, before nba.
    var s: Scheduler = .empty;
    defer s.deinit(t.allocator);
    const gpa = t.allocator;
    _ = try s.schedule(gpa, .nba, 3);
    _ = try s.schedule(gpa, .inactive, 2);
    _ = try s.schedule(gpa, .active, 1);
    s.sync_at = 0;
    try t.expectEqual(@as(u32, 1), s.next().?.payload);
    try t.expectEqual(@as(u32, 2), s.next().?.payload);
    try t.expect(!s.synced);
    try t.expect(s.next() == null);
    try t.expect(s.synced);
    try t.expectEqual(@as(?Time, null), s.sync_at);
    try t.expectEqual(@as(u32, 3), s.next().?.payload);
    try t.expect(s.next() == null);
}
