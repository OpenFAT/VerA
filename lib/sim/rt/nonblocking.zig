//! A nonblocking assignment in, a row the NBA region applies out (or a
//! delayed row applied when its time comes).
//! Cites: IEEE 1364-2005 §9.2.2, §11.4.1 (the update order), §4.8.
//!
//! Contents:
//! - `pub fn nba(self: *State, comptime reach: Reach, slot: u32, off: u32, a: anytype, m: anytype) Error!void`
//! - `pub fn nbaReal(self: *State, slot: u32, off: u32, a: W, m: u64) Error!void`
//! - `pub fn nbaValue(self: *State, comptime is_real: bool, comptime reach: Reach, slot: u32, off: u32, a: anytype, m: anytype) Error!void`
//! - `pub fn nbaAfter(self: *State, comptime reach: Reach, after: u64, slot: u32, off: u32, a: anytype, m: anytype) Error!void`
//! - `pub fn nbaRealAfter(self: *State, after: u64, slot: u32, off: u32, a: W, m: u64) Error!void`
//! - `pub fn nbaAfterValue(self: *State, comptime is_real: bool, comptime reach: Reach, after: u64, slot: u32, off: u32, a: anytype, m: anytype) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const State = @import("State.zig");
const design = @import("design.zig");
const logic = @import("logic/root.zig");
const records = @import("records.zig");
const Error = design.Error;
const Reach = design.Reach;
const one_slot = design.one_slot;
const nba_payload = records.nba_payload;
const show_base = records.show_base;
const late_base = records.late_base;
const W = logic.W;
const quietState = State.quietState;
const testing = std.testing;

const no_limit = std.math.maxInt(u64);

/// §9.2.2: schedule the bits `m` of `slot` (words from `off`) to become
/// `a` in the NBA region.
pub fn nba(self: *State, comptime reach: Reach, slot: u32, off: u32, a: anytype, m: anytype) Error!void {
    return self.nbaValue(false, reach, slot, off, a, m);
}

/// §9.2.2 NBA of a §4.8 real, retaining numeric change detection.
pub fn nbaReal(self: *State, slot: u32, off: u32, a: W, m: u64) Error!void {
    return self.nbaValue(true, .all, slot, off, a, m);
}

/// `nba` and `nbaReal`: appends the row, and queues the one NBA-region
/// event that applies every row when the row is the step's first.
/// Invalidates element pointers of `rows` and `words` if more memory is needed.
pub fn nbaValue(self: *State, comptime is_real: bool, comptime reach: Reach, slot: u32, off: u32, a: anytype, m: anytype) Error!void {
    assert(slot < self.terms.len);
    assert(off < self.v.len);
    const quiet = reach == Reach{};
    const rows_before = self.rows.items.len;
    if (@TypeOf(a) == W) {
        // Grown out of line, appended in line: with two phases' call
        // sites LLVM otherwise outlines the whole `append`.
        if (self.rows.items.len == self.rows.capacity) try self.rows.ensureUnusedCapacity(self.gpa, 1);
        self.rows.appendAssumeCapacity(.{ .slot = slot, .off = off, .n = 1, .at = 0, .quiet = quiet, .real = is_real, .one = .{ a.v, a.x, m } });
    } else {
        const at: u32 = @intCast(self.words.items.len);
        try self.words.appendSlice(self.gpa, &(a.v ++ a.x ++ m));
        try self.rows.append(self.gpa, .{ .slot = slot, .off = off, .n = a.v.len, .at = at, .quiet = quiet, .real = is_real });
    }
    assert(self.rows.items.len == rows_before + 1);
    // One NBA-region event applies every row: it is queued with the first.
    if (self.rows.items.len == 1) _ = self.sched.schedule(self.gpa, .nba, nba_payload) catch |e| return self.schedFail(e);
}

/// §9.2.2 `<= #d`: `nba` of the update `after` ticks later. At 0 it
/// joins this step's rows, the order its own event would take.
pub fn nbaAfter(self: *State, comptime reach: Reach, after: u64, slot: u32, off: u32, a: anytype, m: anytype) Error!void {
    return self.nbaAfterValue(false, reach, after, slot, off, a, m);
}

/// `nbaAfter` retaining the target's real type until the update lands.
pub fn nbaRealAfter(self: *State, after: u64, slot: u32, off: u32, a: W, m: u64) Error!void {
    return self.nbaAfterValue(true, .all, after, slot, off, a, m);
}

/// `nbaAfter` and `nbaRealAfter`: a `late` row owning its words, applied
/// when its event matures (`State.next`). Caller owns nothing returned.
pub fn nbaAfterValue(self: *State, comptime is_real: bool, comptime reach: Reach, after: u64, slot: u32, off: u32, a: anytype, m: anytype) Error!void {
    assert(off < self.v.len);
    if (after == 0) return self.nbaValue(is_real, reach, slot, off, a, m);
    const n: u32 = if (@TypeOf(a) == W) 1 else a.v.len;
    const words = try self.gpa.alloc(u64, 3 * n);
    if (@TypeOf(a) == W) @memcpy(words, &[3]u64{ a.v, a.x, m }) else @memcpy(words, &(a.v ++ a.x ++ m));
    const k = self.free_late.pop() orelse blk: {
        try self.late.append(self.gpa, .{ .slot = 0, .off = 0, .n = 0, .real = false, .words = &.{} });
        break :blk @as(u32, @intCast(self.late.items.len - 1));
    };
    assert(self.late.items[k].words.len == 0); // A free row owns no words.
    self.late.items[k] = .{ .slot = slot, .off = off, .n = n, .real = is_real, .words = words };
    assert(k <= std.math.maxInt(u32) - late_base); // The payload stays inside its band.
    _ = self.sched.scheduleAfter(self.gpa, after, .nba, late_base + k) catch |e| return self.timeFail(e);
}

test "§9.2.2 nonblocking rows land in order after the active region, a $strobe after them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try quietState(arena.allocator(), &one_slot, -9);
    const id = try s.park(3);
    try s.watch(id, 0, .any);
    try s.strobe(7);
    try s.nba(Reach.all, 0, 0, W{ .v = 1, .x = 0 }, @as(u64, 1));
    try s.nba(Reach.all, 0, 0, W{ .v = 0, .x = 0 }, @as(u64, 1));
    try s.run(9, null);
    try testing.expectEqual(@as(?u32, 9), try s.next(no_limit));
    // Both rows are performed, in order: the first wakes 3, the second
    // leaves 0, and 3 runs after the region.
    try testing.expectEqual(@as(?u32, 3), try s.next(no_limit));
    try testing.expectEqual(@as(u64, 0), s.v[0]);
    try testing.expectEqual(@as(?u32, show_base + 7), try s.next(no_limit));
    try testing.expectEqual(@as(?u32, null), try s.next(no_limit));
}

test "§9.2.2 a #0 nonblocking row lands this step, a #5 one at tick 5" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try quietState(arena.allocator(), &one_slot, -9);
    try s.nbaAfter(Reach.all, 5, 0, 0, W{ .v = 0, .x = 0 }, @as(u64, 0b10));
    try s.nbaAfter(Reach.all, 0, 0, 0, W{ .v = 0b11, .x = 0 }, @as(u64, 0b11));
    try testing.expectEqual(@as(?u32, null), try s.next(0));
    try testing.expectEqual(@as(u64, 0b11), s.v[0]);
    try testing.expectEqual(@as(u64, 0), s.sched.now);
    // At 5 only bit 1 is cleared.
    try testing.expectEqual(@as(?u32, null), try s.next(no_limit));
    try testing.expectEqual(@as(u64, 0b01), s.v[0]);
    try testing.expectEqual(@as(u64, 5), s.sched.now);
}
