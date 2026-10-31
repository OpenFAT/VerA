//! A change of a slot in, the processes it wakes out: the event-control
//! terms in suspension order, the triggered processes, the constant select
//! terms and the continuous drivers.
//! Cites: IEEE 1364-2005 §9.7.1, §9.7.2 Table 9-1, §9.7.3, §10.2.1, §11.6.3.
//!
//! Contents:
//! - `pub fn wake(self: *State, slot: u32, before: Bit, after: Bit) Error!void`
//! - `pub inline fn wakeOf(self: *State, comptime reach: Reach, slot: u32, before: Bit, after: Bit) Error!void`
//! - `pub fn wakeTerms(self: *State, comptime reach: Reach, slot: u32, before: Bit, after: Bit) Error!void`
//! - `pub fn wakeWatchers(self: *State, slot: u32, before: Bit, after: Bit, bound: u64) Error!void`
//! - `pub fn wakes(self: *const State, slot: u32) std.EnumSet(Edge)`
//! - `pub inline fn stamp(self: *State) u64`
//! - `pub fn park(self: *State, pc: u32) Error!u32`
//! - `pub fn watch(self: *State, id: u32, slot: u32, edge: Edge) Error!void`
//! - `pub fn watchSelected(self: *State, id: u32, first: u32, elements: u32, select: *const EventSelect) Error!void`
//! - `pub fn watchTerm(self: *State, id: u32, slot: u32, edge: Edge, select: ?*const EventSelect) Error!void`
//! - `pub fn watchBits(self: *State, id: u32, slot: u32, off: u32, lo: u32, width: u32, edge: Edge) Error!void`
//! - `pub fn bits(self: *const State, r: Rec) W`
//! - `pub fn recChanged(self: *State, k: u32, edge: Edge) bool`
//! - `pub inline fn dropRec(self: *State, t: Term) void`
//! - `pub fn retire(self: *State, id: u32) void`

const std = @import("std");
const assert = std.debug.assert;
const State = @import("State.zig");
const design = @import("design.zig");
const logic = @import("logic/root.zig");
const net = @import("net/root.zig");
const records = @import("records.zig");
const Edge = design.Edge;
const Error = design.Error;
const Reach = design.Reach;
const activations = design.activations;
const one_slot = design.one_slot;
const wide_slot = design.wide_slot;
const EventSelect = records.EventSelect;
const Term = records.Term;
const Rec = records.Rec;
const no_rec = records.no_rec;
const W = logic.W;
const Bit = logic.Bit;
const two = logic.two;
const quietState = State.quietState;
const testing = std.testing;

const no_limit = std.math.maxInt(u64);

/// `waiters.wake`: the continuous drivers reading `slot` first, then the
/// event controls in the order they suspended. Under the static
/// schedule the nodes reading it come before them, and the triggered
/// processes take their place in that order by `stamp`. A change of a
/// slot the monitor watches asks for its line (§17.1.3).
pub fn wake(self: *State, slot: u32, before: Bit, after: Bit) Error!void {
    return self.wakeOf(.all, slot, before, after);
}

/// `wake` of what `reach` names alone.
pub inline fn wakeOf(self: *State, comptime reach: Reach, slot: u32, before: Bit, after: Bit) Error!void {
    assert(slot < self.terms.len);
    if (reach.path) net.pathSeen(self, slot);
    if (reach.mon and self.monitored.len != 0 and self.monitored[slot]) try self.requestMonitor();
    if (reach.dump and self.dumped.len != 0 and self.dumped[slot]) try self.requestDump();
    if (reach.fan and slot + 1 < self.fan_start.len) for (self.fan[self.fan_start[slot]..self.fan_start[slot + 1]]) |pc| if (self.armed[pc]) {
        self.armed[pc] = false;
        try self.runPlain(pc, null);
    };
    if (reach.comb and self.sensed(slot)) try self.dirtyReaders(slot);
    if (reach.terms) return self.wakeTerms(reach, slot, before, after);
    if (reach.watch) try self.wakeWatchers(slot, before, after, std.math.maxInt(u64));
}

/// `wake` of the event controls filed under `slot`, in the order they
/// suspended, each after the triggered processes that suspended before
/// it: `vera --run`'s order, so a process woken here suspends again
/// before they store what it waits for next.
pub fn wakeTerms(self: *State, comptime reach: Reach, slot: u32, before: Bit, after: Bit) Error!void {
    assert(slot < self.terms.len);
    const list = &self.terms[slot];
    const len_before = list.items.len;
    // §10.2.1: an automatic task's event is one per activation, so only
    // a waiter in the activation that triggers it wakes.
    const owner: u32 = if (activations and self.act_events.len != 0) self.act_events[slot] else 0;
    const event_ctx = if (owner != 0) self.eventContext(owner - 1, self.ctx) else 0;
    var keep: usize = 0;
    for (list.items) |t| {
        const s = &self.susps.items[t.susp];
        if (s.gen != t.gen) {
            self.dropRec(t);
            continue;
        }
        // Only named-event lists carry selectors. IEEE §10.4.4(f)
        // forbids a function from triggering an event, so a selector
        // cannot recursively compact this same list. Its blocking
        // writes may wake ordinary value lists below.
        const selected = (owner == 0 or event_ctx == self.eventContext(owner - 1, s.ctx)) and
            if (t.select) |select| (try self.selectIn(select, s.ctx)) == slot else true;
        // A selector can call an HDL function whose writes resume this
        // suspension through another term of its event-or expression.
        if (s.gen != t.gen) continue;
        const hit = if (t.rec == no_rec) t.edge.matches(before, after) else self.recChanged(t.rec, t.edge);
        if (!hit or !selected) {
            list.items[keep] = t;
            keep += 1;
            continue;
        }
        self.dropRec(t);
        if (reach.watch) try self.wakeWatchers(slot, before, after, s.seq);
        const pc = s.pc;
        const ctx = s.ctx;
        self.retire(t.susp);
        try self.runIn(pc, ctx, null);
    }
    // A selector's own wakes may append to this list while it is walked;
    // `keep` never passes the length the walk started with.
    assert(keep <= len_before);
    list.shrinkRetainingCapacity(keep);
    if (reach.watch) try self.wakeWatchers(slot, before, after, std.math.maxInt(u64));
}

/// `wake` of the triggered processes watching `slot` that suspended
/// before stamp `bound`.
pub fn wakeWatchers(self: *State, slot: u32, before: Bit, after: Bit, bound: u64) Error!void {
    assert(bound != 0); // Stamps start at 1 (`stamp`).
    if (slot + 1 >= self.watch_start.len) return;
    assert(self.watch_start[slot] <= self.watch_start[slot + 1]);
    for (self.watchers[self.watch_start[slot]..self.watch_start[slot + 1]]) |w| {
        const since = self.waiting[w.proc];
        if (since == 0 or since >= bound or !w.edge.matches(before, after)) continue;
        self.waiting[w.proc] = 0;
        try self.runPlain(w.pc, null);
    }
}

/// What a change of `slot` would wake now: `.any` when a continuous
/// driver, a node or an any-change term reads it, and the edge of each
/// edge term waiting on it (§9.7.2: of its least significant bit). The
/// monitor and the dump are left out.
pub fn wakes(self: *const State, slot: u32) std.EnumSet(Edge) {
    assert(slot < self.terms.len);
    var e: std.EnumSet(Edge) = .empty;
    if (self.sensed(slot) or (slot + 1 < self.fan_start.len and self.fan_start[slot] != self.fan_start[slot + 1])) e.insert(.any);
    // A select term's edge is of a bit other than the slot's LSB.
    for (self.terms[slot].items) |t| if (self.susps.items[t.susp].gen == t.gen) e.insert(if (t.rec == no_rec) t.edge else .any);
    if (slot + 1 < self.watch_start.len) for (self.watchers[self.watch_start[slot]..self.watch_start[slot + 1]]) |w| {
        if (self.waiting[w.proc] != 0) e.insert(w.edge);
    };
    return e;
}

/// The next suspension's order among all of them: `vera --run` wakes
/// the processes waiting on a change in this order (`wakeTerms`).
pub inline fn stamp(self: *State) u64 {
    self.seq += 1;
    assert(self.seq != 0); // 0 is "not waiting" (`State.waiting`).
    return self.seq;
}

/// `waiters.park`: suspend the running process, to resume at `pc`.
pub fn park(self: *State, pc: u32) Error!u32 {
    const id = self.free_susps.pop() orelse blk: {
        try self.susps.append(self.gpa, .{ .pc = 0, .gen = 0, .alive = false });
        try self.free_susps.ensureTotalCapacity(self.gpa, self.susps.items.len);
        break :blk @as(u32, @intCast(self.susps.items.len - 1));
    };
    const s = &self.susps.items[id];
    assert(!s.alive); // Only a retired suspension is on the free list.
    s.pc = pc;
    if (activations) s.ctx = self.ctx;
    s.alive = true;
    s.seq = self.stamp();
    assert(self.free_susps.capacity >= self.susps.items.len); // `retire` cannot fail.
    return id;
}

/// `waiters.watch`: file one term of suspension `id` under `slot`.
pub fn watch(self: *State, id: u32, slot: u32, edge: Edge) Error!void {
    return self.watchTerm(id, slot, edge, null);
}

/// §9.7.3: only an occurrence of the selected element wakes this
/// suspension. Index changes alone neither wake it nor freeze a choice.
/// Inlined automatic invocations already have separate event slots.
pub fn watchSelected(self: *State, id: u32, first: u32, elements: u32, select: *const EventSelect) Error!void {
    assert(elements != 0);
    assert(first + elements <= self.terms.len);
    for (first..first + elements) |slot| try self.watchTerm(id, @intCast(slot), .any, select);
}

/// Files one term of suspension `id` under `slot`, first compacting the
/// list's stale terms when it is full. Asserts that `id` is alive.
pub fn watchTerm(self: *State, id: u32, slot: u32, edge: Edge, select: ?*const EventSelect) Error!void {
    assert(self.susps.items[id].alive);
    const list = &self.terms[slot];
    if (list.items.len == list.capacity and list.capacity != 0) {
        var keep: usize = 0;
        for (list.items) |t| if (self.susps.items[t.susp].gen == t.gen) {
            list.items[keep] = t;
            keep += 1;
        } else self.dropRec(t);
        list.shrinkRetainingCapacity(keep);
        if (keep > list.capacity / 2) try list.ensureTotalCapacity(self.gpa, list.capacity * 2);
    }
    try list.append(self.gpa, .{ .susp = id, .gen = self.susps.items[id].gen, .edge = edge, .select = select });
    assert(list.items[list.items.len - 1].rec == no_rec);
}

/// §9.7.2 a constant select term: bits `[lo, lo + width)` (at most 64)
/// of `slot`, whose words start at `off`. It remembers them, so every
/// update of the slot is tested against them at once (§11.6.3), a
/// pulse that puts them back included.
pub fn watchBits(self: *State, id: u32, slot: u32, off: u32, lo: u32, width: u32, edge: Edge) Error!void {
    assert(width >= 1);
    assert(width <= 64);
    const k = self.free_recs.pop() orelse blk: {
        try self.recs.append(self.gpa, undefined);
        break :blk @as(u32, @intCast(self.recs.items.len - 1));
    };
    // `dropRec` returns it without failing.
    try self.free_recs.ensureTotalCapacity(self.gpa, self.recs.items.len);
    const r = &self.recs.items[k];
    r.* = .{ .word = off + lo / 64, .shift = @intCast(lo % 64), .width = @intCast(width), .v = 0, .x = 0 };
    const now = self.bits(r.*);
    r.v = now.v;
    r.x = now.x;
    try self.watchTerm(id, slot, edge, null);
    const list = &self.terms[slot];
    list.items[list.items.len - 1].rec = k;
    assert(self.free_recs.capacity >= self.recs.items.len); // `dropRec` cannot fail.
}

/// A select term's bits now.
pub fn bits(self: *const State, r: Rec) W {
    assert(r.width >= 1);
    assert(r.word < self.v.len);
    const sh = r.shift;
    var v = self.v[r.word] >> sh;
    var x: u64 = if (two) 0 else self.x[r.word] >> sh;
    if (sh != 0 and @as(u32, sh) + r.width > 64) {
        const up: u6 = @intCast(64 - @as(u32, sh));
        v |= self.v[r.word + 1] << up;
        if (!two) x |= self.x[r.word + 1] << up;
    }
    const m = std.math.shl(u64, 1, r.width) -% 1;
    return .{ .v = v & m, .x = x & m };
}

/// Did select term `k`'s bits change in a way `edge` matches (of their
/// least significant bit)? Either way it now remembers them.
pub fn recChanged(self: *State, k: u32, edge: Edge) bool {
    assert(k != no_rec);
    const r = &self.recs.items[k];
    const now = self.bits(r.*);
    if (now.v == r.v and now.x == r.x) return false;
    const before = logic.low(W{ .v = r.v, .x = r.x });
    r.v = now.v;
    r.x = now.x;
    return edge.matches(before, logic.low(now));
}

/// A term leaves its list: its select bits' row is free.
pub inline fn dropRec(self: *State, t: Term) void {
    if (t.rec != no_rec) self.free_recs.appendAssumeCapacity(t.rec);
}

/// Ends suspension `id`: its terms go stale (the generation moves on) and
/// it is free. Asserts that it was alive.
pub fn retire(self: *State, id: u32) void {
    const s = &self.susps.items[id];
    assert(s.alive);
    s.alive = false;
    s.gen +%= 1;
    self.free_susps.appendAssumeCapacity(id);
    assert(self.free_susps.items.len <= self.susps.items.len);
}

test "§9.7.2 a constant select term wakes on its own bits' edge, not the slot's" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try quietState(arena.allocator(), &one_slot, -9);
    const id = try s.park(6);
    try s.watchBits(id, 0, 0, 4, 4, .posedge);
    // A select term's edge is not of the slot's bit 0, so any change of the
    // slot may wake it.
    const woken = s.wakes(0);
    try testing.expect(woken.contains(.any) and !woken.contains(.posedge));
    // Bit 0 rises, bits 4..7 hold: nothing wakes.
    try s.put(Reach.all, 0, 0, W{ .v = 1, .x = 0 }, @as(u64, 1));
    try testing.expectEqual(@as(?u32, null), try s.next(no_limit));
    // Bit 4, the selected bits' least significant, rises.
    try s.put(Reach.all, 0, 0, W{ .v = 0x10, .x = 0 }, @as(u64, 0xf0));
    try testing.expectEqual(@as(?u32, 6), try s.next(no_limit));
}

test "§9.7.2 a select term across a word boundary reads both words; a 64-bit one its whole word" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try quietState(arena.allocator(), &wide_slot, -9);
    // Bits 60..67: word 0's top four, word 1's bottom four.
    const id = try s.park(6);
    try s.watchBits(id, 0, 0, 60, 8, .posedge);
    // Bit 64 moves the selected bits but not their least significant (60).
    try s.putWord(Reach.all, 0, 0, 1, W{ .v = 1, .x = 0 }, 1);
    try testing.expectEqual(@as(?u32, null), try s.next(no_limit));
    try testing.expectEqual(W{ .v = 0x10, .x = 0 }, s.bits(s.recs.items[0]));
    try s.putWord(Reach.all, 0, 0, 0, W{ .v = 1 << 60, .x = 0 }, 1 << 60);
    try testing.expectEqual(@as(?u32, 6), try s.next(no_limit));
    // Width 64 from bit 64: all of word 1.
    const all = try s.park(7);
    try s.watchBits(all, 0, 0, 64, 64, .any);
    try testing.expectEqual(W{ .v = 1, .x = 0 }, s.bits(s.recs.items[s.terms[0].items[s.terms[0].items.len - 1].rec]));
    try s.putWord(Reach.all, 0, 0, 1, W{ .v = 1 << 63, .x = 0 }, 1 << 63);
    try testing.expectEqual(@as(?u32, 7), try s.next(no_limit));
}
