//! `assign`/`force` and `disable` in, the slots held against every other
//! writer and the processes stopped out.
//! Cites: IEEE 1364-2005 §9.3, §9.3.2 (forced selects), §10.3 (disable).
//!
//! Contents:
//! - `pub fn disable(self: *State, lo: u32, hi: u32, end: u32) Error!void`
//! - `pub fn stop(self: *State, lo: u32, hi: u32) Error!bool`
//! - `pub inline fn held(self: *const State, slot: u32) bool`
//! - `pub fn overrideOn(self: *State, slot: u32, force: bool, start: u32, end: u32) Error!void`
//! - `pub inline fn forcedBits(self: *const State, slot: u32, j: usize) u64`
//! - `pub fn overrideBits(self: *State, slot: u32, k: u32, lo: u32, width: u32, start: u32, end: u32) Error!void`
//! - `pub fn releaseBits(self: *State, slot: u32, k: u32) Error!void`
//! - `pub fn putBits(self: *State, slot: u32, off: u32, comptime lo: u32, comptime bw: u32, comptime sw: u32, a: anytype) Error!void`
//! - `pub fn forced(self: *const State, slot: u32) bool`
//! - `pub fn release(self: *State, slot: u32, force: bool) Error!bool`

const std = @import("std");
const assert = std.debug.assert;
const State = @import("State.zig");
const design = @import("design.zig");
const logic = @import("logic/root.zig");
const records = @import("records.zig");
const Error = design.Error;
const Reach = design.Reach;
const overrides = design.overrides;
const activations = design.activations;
const one_slot = design.one_slot;
const resume_base = records.resume_base;
const W = logic.W;
const quietState = State.quietState;
const testing = std.testing;

const no_limit = std.math.maxInt(u64);

/// §10.3 `disable` of the named block or task copy at pcs `[lo, hi)`:
/// every suspension and queued resumption inside it is dropped, and if
/// there was one, its process continues at `end` (`exec.disableRange`).
pub fn disable(self: *State, lo: u32, hi: u32, end: u32) Error!void {
    assert(lo <= hi);
    assert(end >= hi or end < lo); // The block's end is outside the block.
    if (try self.stop(lo, hi)) try self.runPlain(end, null);
}

/// `exec.stopRange`: end every process suspended or queued in pcs
/// [lo, hi); whether there was one.
pub fn stop(self: *State, lo: u32, hi: u32) Error!bool {
    assert(lo <= hi);
    var hit = false;
    for (self.susps.items, 0..) |sp, id| if (sp.alive and sp.pc >= lo and sp.pc < hi) {
        self.retire(@intCast(id));
        hit = true;
    };
    if (self.sched.cancelRange(lo, hi) catch |e| return self.schedFail(e)) hit = true;
    if (activations) for (self.calls.resumes.items, 0..) |*row, k| if (row.live and row.pc >= lo and row.pc < hi) {
        const at = resume_base + @as(u32, @intCast(k));
        _ = self.sched.cancelRange(at, at + 1) catch |e| return self.schedFail(e);
        row.live = false;
        try self.calls.free_resumes.append(self.gpa, @intCast(k));
        hit = true;
    };
    return hit;
}

/// §9.3: an `assign` or `force` holds `slot` and blocks every write but
/// its own process's (`waiters.store`'s guard; an `assign` holds only a
/// variable, which `compile` ensures).
pub inline fn held(self: *const State, slot: u32) bool {
    if (!overrides or self.overriding) return false;
    assert(slot < self.layers.len);
    const l = self.layers[slot];
    return l.assign != null or l.force != null;
}

/// `exec` `.override_on`: the `assign` (or `force`) whose process is pcs
/// [start, end) now holds `slot`, replacing the one before it.
pub fn overrideOn(self: *State, slot: u32, force: bool, start: u32, end: u32) Error!void {
    assert(start < end);
    const l = &self.layers[slot];
    const layer = if (force) &l.force else &l.assign;
    if (layer.*) |old| _ = try self.stop(old.start, old.end);
    layer.* = .{ .start = start, .end = end };
    assert(self.held(slot) or self.overriding);
    try self.runPlain(start, null);
}

/// The bits of word `j` of `slot` that a forced select holds against
/// every writer but the force's own process.
pub inline fn forcedBits(self: *const State, slot: u32, j: usize) u64 {
    if (!overrides or self.overriding) return 0;
    var m: u64 = 0;
    if (slot + 1 >= self.part_start.len) return 0;
    for (self.parts[self.part_start[slot]..self.part_start[slot + 1]]) |p| if (p.range != null) {
        m |= logic.span(j, p.lo, @as(i64, p.lo) + p.width);
    };
    return m;
}

/// `exec` `.override_on` of a forced select: `parts[k]`, bits
/// [lo, lo + width) of `slot`, is held by the force whose process is pcs
/// [start, end), replacing the force of the same select before it.
/// Asserts `k` is one of `slot`'s selects.
pub fn overrideBits(self: *State, slot: u32, k: u32, lo: u32, width: u32, start: u32, end: u32) Error!void {
    std.debug.assert(k >= self.part_start[slot] and k < self.part_start[slot + 1]);
    const p = &self.parts[k];
    if (p.range) |old| _ = try self.stop(old.start, old.end);
    assert(width >= 1);
    assert(start < end);
    p.* = .{ .lo = lo, .width = width, .range = .{ .start = start, .end = end } };
    try self.runPlain(start, null);
}

/// `waiters.releaseBits`: `parts[k]`, a select of `slot`, is its
/// drivers' again; the design re-resolves the net. Asserts `k` is one of
/// `slot`'s selects.
pub fn releaseBits(self: *State, slot: u32, k: u32) Error!void {
    std.debug.assert(k >= self.part_start[slot] and k < self.part_start[slot + 1]);
    const p = &self.parts[k];
    if (p.range) |old| _ = try self.stop(old.start, old.end);
    p.range = null;
    assert(self.parts[k].range == null);
}

/// A forced select's own write: bits [lo, lo + bw) of the `sw`-bit
/// `slot` at word `off` become `a`.
pub fn putBits(self: *State, slot: u32, off: u32, comptime lo: u32, comptime bw: u32, comptime sw: u32, a: anytype) Error!void {
    comptime assert(bw >= 1);
    comptime assert(lo + bw <= sw);
    const n = comptime logic.words(sw);
    var v: [n]u64 = @splat(0);
    var x: [n]u64 = @splat(0);
    var m: [n]u64 = @splat(0);
    const src = logic.wide(a);
    for (0..bw) |i| {
        const at = lo + i;
        const bit = @as(u64, 1) << @intCast(at % 64);
        if (src.v[i / 64] >> @intCast(i % 64) & 1 != 0) v[at / 64] |= bit;
        if (src.x[i / 64] >> @intCast(i % 64) & 1 != 0) x[at / 64] |= bit;
        m[at / 64] |= bit;
    }
    try self.store(slot, off, &v, &x, &m);
}

/// Is `slot` forced? An `assign` under a force keeps tracking but does
/// not write (`exec` `.override_eval`).
pub fn forced(self: *const State, slot: u32) bool {
    assert(slot < self.layers.len);
    return self.layers[slot].force != null;
}

/// `waiters.release`: §9.3 `deassign` (`force` false) or `release` of
/// `slot`; releasing what is not held is a no-op. A released variable
/// held by an `assign` is that assign's again; true when a released net
/// must be re-resolved from its drivers, which the design does.
pub fn release(self: *State, slot: u32, force: bool) Error!bool {
    assert(slot < self.layers.len);
    const l = &self.layers[slot];
    if (l.assign == null and l.force == null) return false;
    const layer = if (force) &l.force else &l.assign;
    if (layer.*) |old| _ = try self.stop(old.start, old.end);
    layer.* = null;
    assert(if (force) l.force == null else l.assign == null);
    if (!force) return false;
    if (l.assign) |a| try self.runPlain(a.start, null);
    return true;
}

test "§10.3 disable drops what waits or is queued inside its range and continues at its end" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try quietState(arena.allocator(), &one_slot, -9);
    const inside = try s.park(10);
    try s.watch(inside, 0, .any);
    const outside = try s.park(30);
    try s.watch(outside, 0, .any);
    try s.run(12, 5);
    try s.disable(5, 15, 20);
    try testing.expectEqual(@as(?u32, 20), try s.next(no_limit));
    // The resumption at 5 was cancelled: no time step for it.
    try testing.expectEqual(@as(?u32, null), try s.next(no_limit));
    try testing.expectEqual(@as(u64, 0), s.sched.now);
    try s.put(Reach.all, 0, 0, W{ .v = 1, .x = 0 }, @as(u64, 1));
    try testing.expectEqual(@as(?u32, 30), try s.next(no_limit));
    try testing.expectEqual(@as(?u32, null), try s.next(no_limit));
    // A range that holds nothing continues nowhere.
    try s.disable(40, 50, 60);
    try testing.expectEqual(@as(?u32, null), try s.next(no_limit));
}
