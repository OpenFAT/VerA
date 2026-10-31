//! A `State`'s value planes in, a value of a slot out (and back): the reads
//! and masked writes the emitted code makes, in the 4-state and the 2-state
//! phase of `--state=auto`, and the settle event's `View`.
//! Cites: IEEE 1364-2005 §3.2, §4.1 (4-state values), §9.6 (repeat counts).
//!
//! Contents:
//! - `pub const View = struct`
//! - `View.get(self: View, off: u32) W`
//! - `View.getw(self: View, off: u32, comptime n: u32) logic.Wide(n)`
//! - `View.set(self: View, off: u32, a: anytype, m: anytype) void`
//! - `View.take(self: View, n: u32) bool`
//! - `View.putNode(self: View, comptime reach: Reach, slot: u32, off: u32, a: anytype, comptime senses: []const Sense) Error!void`
//! - `pub inline fn peek(comptime k: bool, v: [*]const u64, x: [*]const u64, off: u32) W`
//! - `pub inline fn peekw(v: [*]const u64, x: [*]const u64, off: u32, comptime n: u32) logic.Wide(n)`
//! - `pub inline fn poke(comptime k: bool, v: [*]u64, x: [*]u64, off: u32, a: anytype, m: anytype) void`
//! - `pub fn Phase(comptime k: bool) type`
//! - `Phase.get(s: anytype, off: u32) W`
//! - `Phase.getw(s: anytype, off: u32, comptime n: u32) logic.Wide(n)`
//! - `Phase.set(s: anytype, off: u32, a: anytype, m: anytype) Error!void`
//! - `Phase.put(s: *State, comptime reach: Reach, slot: u32, off: u32, a: anytype, m: anytype) Error!void`
//! - `Phase.putCold(s: *State, comptime reach: Reach, slot: u32, off: u32, a: anytype, m: anytype) Error!void`
//! - `Phase.setCold(s: *State, off: u32, a: anytype, m: anytype) Error!void`
//! - `Phase.putWord(s: *State, comptime reach: Reach, slot: u32, off: u32, j: u32, a: W, m: u64) Error!void`
//! - `Phase.putNode(s: View, comptime reach: Reach, slot: u32, off: u32, a: anytype, comptime senses: []const Sense) Error!void`
//! - `Phase.nba(s: *State, comptime reach: Reach, slot: u32, off: u32, a: anytype, m: anytype) Error!void`
//! - `Phase.nbaAfter(s: *State, comptime reach: Reach, after: u64, slot: u32, off: u32, a: anytype, m: anytype) Error!void`
//! - `pub inline fn planeV(s: anytype) [*]u64`
//! - `pub inline fn known(a: anytype, m: anytype) Error!void`
//! - `pub fn repeatCount(a: anytype, comptime w: u32, comptime signed: bool) u64`

const std = @import("std");
const State = @import("State.zig");
const design = @import("design.zig");
const logic = @import("logic/root.zig");
const Sense = design.Sense;
const Error = design.Error;
const Reach = design.Reach;
const one_slot = design.one_slot;
const W = logic.W;
const two = logic.two;
const quietState = State.quietState;
const testing = std.testing;

/// A settle event's hold on a `State`: its planes and dirty words as
/// pointers read once, which stay in registers across the event's stores;
/// through `State` each is read again after every store. Neither moves
/// while a design runs.
pub const View = struct {
    s: *State,
    v: [*]u64,
    x: [*]u64,
    dirty: [*]u64,

    /// `State.get` through the held pointers.
    pub inline fn get(self: View, off: u32) W {
        return peek(two, self.v, self.x, off);
    }

    /// `State.getw` through the held pointers.
    pub inline fn getw(self: View, off: u32, comptime n: u32) logic.Wide(n) {
        return peekw(self.v, self.x, off, n);
    }

    /// `State.set` through the held pointers.
    pub inline fn set(self: View, off: u32, a: anytype, m: anytype) void {
        poke(two, self.v, self.x, off, a, m);
    }

    /// Clear combinational node `n`'s dirty bit; whether it was set. The
    /// settle event takes every node in topological order, so a node only
    /// ever dirties one it has not reached yet.
    pub inline fn take(self: View, n: u32) bool {
        const bit = @as(u64, 1) << @intCast(n % 64);
        const was = self.dirty[n / 64] & bit != 0;
        self.dirty[n / 64] &= ~bit;
        return was;
    }

    /// `put` of the whole of a combinational node's output while the
    /// settle event runs it, whether or not an input changed: the value is
    /// stored as is, and the readers in `senses` (`word` counted from `off`)
    /// whose bits moved are marked dirty here, without a branch; `reach` is
    /// woken as `put` wakes it. A node reached in topological order only
    /// marks later ones.
    pub inline fn putNode(self: View, comptime reach: Reach, slot: u32, off: u32, a: anytype, comptime senses: []const Sense) Error!void {
        return self.putNodeAs(two, reach, slot, off, a, senses);
    }

    /// `putNode`; `k` as `poke`'s.
    inline fn putNodeAs(self: View, comptime k: bool, comptime reach: Reach, slot: u32, off: u32, a: anytype, comptime senses: []const Sense) Error!void {
        if (self.s.held(slot)) return;
        const s = logic.wide(a);
        const n = s.v.len;
        const before = logic.low(peek(k, self.v, self.x, off));
        var d: [n]u64 = undefined;
        inline for (0..n) |j| {
            const o = peek(k, self.v, self.x, off + j);
            d[j] = (s.v[j] ^ o.v) | (s.x[j] ^ o.x);
            self.v[off + j] = s.v[j];
            if (!k) self.x[off + j] = s.x[j];
        }
        inline for (senses) |e| self.dirty[e.node / 64] |= @as(u64, @intFromBool(d[e.word] & e.mask != 0)) << @intCast(e.node % 64);
        if (@as(u8, @bitCast(reach)) == 0) return;
        var moved: u64 = 0;
        for (d) |e| moved |= e;
        if (moved != 0) try self.s.wakeOf(reach, slot, before, logic.low(peek(k, self.v, self.x, off)));
    }
};

/// `get` of planes `v`, `x`; `k` as `poke`'s.
pub inline fn peek(comptime k: bool, v: [*]const u64, x: [*]const u64, off: u32) W {
    return .{ .v = v[off], .x = if (k) 0 else x[off] };
}

/// `getw` of planes `v`, `x`.
pub inline fn peekw(v: [*]const u64, x: [*]const u64, off: u32, comptime n: u32) logic.Wide(n) {
    return .{ .v = v[off..][0..n].*, .x = if (two) @splat(0) else x[off..][0..n].* };
}

/// `set` of planes `v`, `x`; `k`: the x plane is zero and stays so, and
/// is not written.
pub inline fn poke(comptime k: bool, v: [*]u64, x: [*]u64, off: u32, a: anytype, m: anytype) void {
    if (@TypeOf(a) != W) {
        for (v[off..][0..a.v.len], a.v, m) |*ov, av, am| ov.* = (ov.* & ~am) | (av & am);
        if (!k) for (x[off..][0..a.v.len], a.x, m) |*ox, ax, am| {
            ox.* = (ox.* & ~am) | (ax & am);
        };
        return;
    }
    const bits: u64 = m;
    v[off] = (v[off] & ~bits) | (a.v & bits);
    if (!k) x[off] = (x[off] & ~bits) | (a.x & bits);
}

/// The design's plane accessors in one phase of a `--state=auto`
/// executable (`auto`). `Phase(false)` is `State`'s and `View`'s own.
/// `Phase(true)` runs only while the x plane is zero (`State.two`): a
/// read's x half is the constant 0, so every operator's x half folds away
/// where it is compiled, and a store of an x or z bit, the one way an x
/// could reach the planes again, fails with `error.Rerun` before it lands.
/// The operators stay IEEE 1364's, so an x a known operand makes (`/` by
/// 0, an out-of-range select) is printed or compared exactly; only
/// storing it ends the phase. `s` is a `*State` or a `View`.
pub fn Phase(comptime k: bool) type {
    return struct {
        /// `State.get`; the x half is 0 in the 2-state phase.
        pub inline fn get(s: anytype, off: u32) W {
            var a = s.get(off);
            if (k) a.x = 0;
            return a;
        }

        /// `State.getw`; the x half is 0 in the 2-state phase.
        pub inline fn getw(s: anytype, off: u32, comptime n: u32) logic.Wide(n) {
            var a = s.getw(off, n);
            if (k) a.x = @splat(0);
            return a;
        }

        /// `State.set`; `error.Rerun` on an x or z in the 2-state phase.
        pub inline fn set(s: anytype, off: u32, a: anytype, m: anytype) Error!void {
            if (!k) return s.set(off, a, m);
            try known(a, m);
            poke(true, planeV(s), undefined, off, a, m);
        }

        /// `State.put`; `error.Rerun` on an x or z in the 2-state phase.
        pub inline fn put(s: *State, comptime reach: Reach, slot: u32, off: u32, a: anytype, m: anytype) Error!void {
            if (k) try known(a, m);
            if (@TypeOf(a) != W) return s.store(slot, off, &a.v, &a.x, &m);
            return s.putWordAs(k, reach, slot, off, 0, a, m);
        }

        /// `put` out of line, for code that runs once.
        pub noinline fn putCold(s: *State, comptime reach: Reach, slot: u32, off: u32, a: anytype, m: anytype) Error!void {
            return put(s, reach, slot, off, a, m);
        }

        /// `set` out of line.
        pub noinline fn setCold(s: *State, off: u32, a: anytype, m: anytype) Error!void {
            return set(s, off, a, m);
        }

        /// `State.putWord`; `error.Rerun` on an x or z in the 2-state phase.
        pub inline fn putWord(s: *State, comptime reach: Reach, slot: u32, off: u32, j: u32, a: W, m: u64) Error!void {
            if (k) try known(a, m);
            return s.putWordAs(k, reach, slot, off, j, a, m);
        }

        /// `View.putNode`; `error.Rerun` on an x or z in the 2-state phase.
        pub inline fn putNode(s: View, comptime reach: Reach, slot: u32, off: u32, a: anytype, comptime senses: []const Sense) Error!void {
            if (k) try known(a, @as(@TypeOf(a.x), if (@TypeOf(a) == W) std.math.maxInt(u64) else @splat(std.math.maxInt(u64))));
            return s.putNodeAs(k, reach, slot, off, a, senses);
        }

        /// `State.nba`; `error.Rerun` on an x or z in the 2-state phase.
        pub inline fn nba(s: *State, comptime reach: Reach, slot: u32, off: u32, a: anytype, m: anytype) Error!void {
            if (k) try known(a, m);
            return @call(.always_inline, State.nba, .{ s, reach, slot, off, a, m });
        }

        /// `State.nbaAfter`; `error.Rerun` on an x or z in the 2-state phase.
        pub inline fn nbaAfter(s: *State, comptime reach: Reach, after: u64, slot: u32, off: u32, a: anytype, m: anytype) Error!void {
            if (k) try known(a, m);
            return s.nbaAfter(reach, after, slot, off, a, m);
        }
    };
}

/// The `v` plane of a `*State` or a `View`, as a many-pointer.
pub inline fn planeV(s: anytype) [*]u64 {
    return if (@TypeOf(s) == View) s.v else s.v.ptr;
}

/// `error.Rerun` if a bit `m` selects of `a` is x or z.
pub inline fn known(a: anytype, m: anytype) Error!void {
    var any: u64 = 0;
    if (@TypeOf(a) == W) any = a.x & m else for (a.x, m) |x, b| {
        any |= x & b;
    }
    if (any != 0) {
        @branchHint(.cold);
        return error.Rerun;
    }
}

/// §9.6/§9.7.7 a `repeat` count of `w` bits (`exec` `.repeat_start`): x, z
/// or a signed count below 0 is 0 times, at any width; past 64 bits it
/// saturates, as 2^64 passes never end.
pub fn repeatCount(a: anytype, comptime w: u32, comptime signed: bool) u64 {
    const c = logic.wide(a);
    for (c.x) |x| if (x != 0) return 0;
    if (signed and (c.v[(w - 1) / 64] >> @intCast((w - 1) % 64)) & 1 != 0) return 0;
    for (c.v[1..]) |v| if (v != 0) return std.math.maxInt(u64);
    return c.v[0];
}

test "the 2-state phase refuses an x or z store only where the mask selects it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try quietState(arena.allocator(), &one_slot, -9);
    const P = Phase(true);
    try P.set(s, 0, W{ .v = 5, .x = 2 }, @as(u64, 0b101));
    try testing.expectEqual(@as(u64, 5), s.v[0]);
    try testing.expectError(error.Rerun, P.set(s, 0, W{ .v = 5, .x = 2 }, @as(u64, 0b111)));
    try testing.expectError(error.Rerun, P.put(s, Reach.all, 0, 0, logic.Wide(2){ .v = .{ 0, 0 }, .x = .{ 0, 1 } }, [2]u64{ 0, 1 }));
    // The 4-state phase stores it.
    try Phase(false).set(s, 0, W{ .v = 0, .x = 2 }, @as(u64, 2));
    try testing.expectEqual(@as(u64, 2), s.x[0]);
}
