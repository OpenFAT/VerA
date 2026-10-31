//! A store of a slot in, the new planes and the waiters it wakes out:
//! `waiters.store`'s rule (nothing happens unless the value changes), and
//! the dirty marks the settle event reads.
//! Cites: IEEE 1364-2005 §4.8 (reals change by value), §9.2.1, §9.3.2, §11.4.2.
//!
//! Contents:
//! - `pub inline fn get(self: *const State, off: u32) W`
//! - `pub inline fn getw(self: *const State, off: u32, comptime n: u32) logic.Wide(n)`
//! - `pub inline fn set(self: *State, off: u32, a: anytype, m: anytype) void`
//! - `pub inline fn view(self: *State) View`
//! - `pub inline fn put(self: *State, comptime reach: Reach, slot: u32, off: u32, a: anytype, m: anytype) Error!void`
//! - `pub inline fn putWord(self: *State, comptime reach: Reach, slot: u32, off: u32, j: u32, a: W, m: u64) Error!void`
//! - `pub inline fn putWordAs(self: *State, comptime k: bool, comptime reach: Reach, slot: u32, off: u32, j: u32, a: W, m: u64) Error!void`
//! - `pub fn putReal(self: *State, slot: u32, off: u32, a: W, m: u64) Error!void`
//! - `pub fn store(self: *State, slot: u32, off: u32, v: []const u64, x: []const u64, m: []const u64) Error!void`
//! - `pub fn markReaders(self: *State, slot: u32) void`
//! - `pub inline fn sensed(self: *const State, slot: u32) bool`
//! - `pub fn dirtyReaders(self: *State, slot: u32) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const State = @import("State.zig");
const design = @import("design.zig");
const logic = @import("logic/root.zig");
const planes = @import("planes.zig");
const records = @import("records.zig");
const Error = design.Error;
const Reach = design.Reach;
const one_slot = design.one_slot;
const wide_slot = design.wide_slot;
const settle_payload = records.settle_payload;
const peek = planes.peek;
const peekw = planes.peekw;
const poke = planes.poke;
const View = planes.View;
const W = logic.W;
const two = logic.two;
const quietState = State.quietState;
const testing = std.testing;

const no_limit = std.math.maxInt(u64);

/// The value of at most 64 bits at word `off`.
pub inline fn get(self: *const State, off: u32) W {
    assert(off < self.v.len);
    return peek(two, self.v.ptr, self.x.ptr, off);
}

/// The `n`-word value at word `off`.
pub inline fn getw(self: *const State, off: u32, comptime n: u32) logic.Wide(n) {
    comptime assert(n >= 1);
    assert(off + n <= self.v.len);
    return peekw(self.v.ptr, self.x.ptr, off, n);
}

/// The bits `m` of the value at word `off` become `a`'s, for a slot no
/// event control, driver or node can be waiting on.
pub inline fn set(self: *State, off: u32, a: anytype, m: anytype) void {
    assert(off < self.v.len);
    poke(two, self.v.ptr, self.x.ptr, off, a, m);
}

/// The settle event's hold on the planes and dirty words.
pub inline fn view(self: *State) View {
    return .{ .s = self, .v = self.v.ptr, .x = self.x.ptr, .dirty = self.dirty.ptr };
}

/// `waiters.store` of the bits `m` of `slot`, whose words start at `off`:
/// nothing happens unless the value changes; then every waiter it
/// matches wakes, of those `reach` names. `a` is a `logic.T`, `m` the
/// `logic.M` of its width.
pub inline fn put(self: *State, comptime reach: Reach, slot: u32, off: u32, a: anytype, m: anytype) Error!void {
    if (@TypeOf(a) != W) return self.store(slot, off, &a.v, &a.x, &m);
    return self.putWord(reach, slot, off, 0, a, m);
}

/// `put` of the bits `m` of word `j` alone: a bit-select of a wide slot
/// touches one word. An edge is its least significant bit's (§9.7.2),
/// which only word 0 holds.
pub inline fn putWord(self: *State, comptime reach: Reach, slot: u32, off: u32, j: u32, a: W, m: u64) Error!void {
    return self.putWordAs(two, reach, slot, off, j, a, m);
}

/// `putWord`; `k` as `poke`'s.
pub inline fn putWordAs(self: *State, comptime k: bool, comptime reach: Reach, slot: u32, off: u32, j: u32, a: W, m: u64) Error!void {
    assert(slot < self.terms.len);
    if (self.held(slot)) return;
    const at = off + j;
    assert(at < self.v.len);
    const o = peek(k, self.v.ptr, self.x.ptr, at);
    const nv = (o.v & ~m) | (a.v & m);
    const nx = (o.x & ~m) | (a.x & m);
    const d = (nv ^ o.v) | (nx ^ o.x);
    if (comptime reach == Reach{ .comb = true }) {
        // Only nodes read the slot: the store does not branch on the
        // data, and only its first change of the step reaches `dirtyReaders`.
        self.v[at] = nv;
        if (!k) self.x[at] = nx;
        self.diff[at] |= d;
        if (!self.pending[slot] and d != 0) try self.dirtyReaders(slot);
        return;
    }
    if (d == 0) return;
    const before = logic.low(peek(k, self.v.ptr, self.x.ptr, off));
    self.v[at] = nv;
    if (!k) self.x[at] = nx;
    if (reach.comb and self.sensed(slot)) self.diff[at] |= d;
    try self.wakeOf(reach, slot, before, logic.low(peek(k, self.v.ptr, self.x.ptr, off)));
}

/// `put` of a real (§4.8, `waiters.store`): it changes when its value
/// does, so -0.0 over 0.0 is no change and a NaN always is one. No
/// change still stores the bits (VD-032): only the event is suppressed.
/// `m` is ignored: a real is stored whole.
pub fn putReal(self: *State, slot: u32, off: u32, a: W, m: u64) Error!void {
    _ = m; // A real is stored whole.
    assert(slot < self.terms.len);
    assert(off < self.v.len);
    if (self.held(slot)) return;
    if (logic.real(self.get(off)) == logic.real(a)) {
        self.v[off] = a.v;
        return;
    }
    const before = logic.low(self.get(off));
    self.v[off] = a.v;
    if (!two) self.x[off] = 0;
    if (self.sensed(slot)) self.diff[off] = std.math.maxInt(u64);
    assert(self.v[off] == a.v);
    try self.wake(slot, before, logic.low(a));
}

/// `put` of the bits `m` of an `n`-word value at runtime width.
pub fn store(self: *State, slot: u32, off: u32, v: []const u64, x: []const u64, m: []const u64) Error!void {
    assert(v.len == x.len);
    assert(v.len == m.len);
    assert(v.len != 0);
    assert(off + v.len <= self.v.len);
    if (self.held(slot)) return;
    if (self.two) for (x, m) |a, b| if (a & b != 0) return error.Rerun;
    const sv = self.v[off..][0..v.len];
    const sx = self.x[off..][0..v.len];
    const before = logic.low(W{ .v = sv[0], .x = sx[0] });
    const sense = self.sensed(slot);
    var changed: u64 = 0;
    for (sv, sx, v, x, m, 0..) |*ov, *ox, av, ax, am_, i| {
        // §9.3.2 a forced select of a net keeps its bits; the rest resolve.
        const am = am_ & ~self.forcedBits(slot, i);
        const nv = (ov.* & ~am) | (av & am);
        const nx = (ox.* & ~am) | (ax & am);
        const d = (nv ^ ov.*) | (nx ^ ox.*);
        changed |= d;
        if (sense) self.diff[off + i] |= d;
        ov.* = nv;
        ox.* = nx;
    }
    if (changed == 0) return;
    try self.wake(slot, before, logic.low(W{ .v = sv[0], .x = sx[0] }));
}

/// Marks dirty the nodes that read a bit of `slot` changed since the
/// last call, then forgets those changes.
pub fn markReaders(self: *State, slot: u32) void {
    assert(slot + 1 < self.comb_start.len);
    const senses = self.comb[self.comb_start[slot]..self.comb_start[slot + 1]];
    // Held here, not re-read from `self` after each store to `dirty`.
    const diff = self.diff;
    const dirty = self.dirty;
    for (senses) |e| {
        const hit = diff[e.word] & e.mask != 0;
        dirty[e.node / 64] |= @as(u64, @intFromBool(hit)) << @intCast(e.node % 64);
    }
    if (senses.len == 0) return;
    @memset(diff[senses[0].word .. senses[senses.len - 1].word + 1], 0);
    assert(diff[senses[0].word] == 0); // `comb` is ascending by word per slot.
}

/// Whether a node reads some bit of `slot`.
pub inline fn sensed(self: *const State, slot: u32) bool {
    return slot + 1 < self.comb_start.len and self.comb_start[slot] != self.comb_start[slot + 1];
}

/// `slot` changed: its node readers run in the settle event, which is
/// queued now if it is not already.
pub fn dirtyReaders(self: *State, slot: u32) Error!void {
    assert(slot < self.pending.len);
    assert(self.changed.items.len <= self.pending.len);
    switch (self.settle) {
        .running => self.markReaders(slot),
        .queued => if (!self.pending[slot]) {
            self.pending[slot] = true;
            self.changed.appendAssumeCapacity(slot);
        },
        .idle => {
            self.pending[slot] = true;
            self.changed.appendAssumeCapacity(slot);
            self.settle = .queued;
            _ = self.sched.schedule(self.gpa, .active, settle_payload) catch |e| return self.schedFail(e);
        },
    }
}

test "§4.8 a real store of -0.0 over 0.0 is no event but keeps its bits; NaN always is one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try quietState(arena.allocator(), &one_slot, -9);
    const id = try s.park(4);
    try s.watch(id, 0, .any);
    try s.putReal(0, 0, logic.realBits(-0.0), std.math.maxInt(u64));
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, -0.0))), s.v[0]);
    try testing.expectEqual(@as(?u32, null), try s.next(no_limit));
    try s.putReal(0, 0, logic.realBits(std.math.nan(f64)), std.math.maxInt(u64));
    try testing.expectEqual(@as(?u32, 4), try s.next(no_limit));
    const again = try s.park(5);
    try s.watch(again, 0, .any);
    try s.putReal(0, 0, logic.realBits(std.math.nan(f64)), std.math.maxInt(u64));
    try testing.expectEqual(@as(?u32, 5), try s.next(no_limit));
}

test "a node's store wakes on a change in any word of a wide value, and on none without one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try quietState(arena.allocator(), &wide_slot, -9);
    const v = s.view();
    const same: logic.Wide(2) = .{ .v = .{ 0, 0 }, .x = .{ 0, 0 } };
    var id = try s.park(3);
    try s.watch(id, 0, .any);
    try v.putNode(Reach.all, 0, 0, same, &.{});
    try testing.expectEqual(@as(?u32, null), try s.next(no_limit));
    // Only the high word moves: still a change of the slot.
    try v.putNode(Reach.all, 0, 0, logic.Wide(2){ .v = .{ 0, 0 }, .x = .{ 0, 4 } }, &.{});
    try testing.expectEqual(@as(?u32, 3), try s.next(no_limit));
    try testing.expectEqual(@as(u64, 4), s.x[1]);
    id = try s.park(4);
    try s.watch(id, 0, .any);
    try v.putNode(Reach.all, 0, 0, logic.Wide(2){ .v = .{ 2, 0 }, .x = .{ 0, 4 } }, &.{});
    try testing.expectEqual(@as(?u32, 4), try s.next(no_limit));
}
