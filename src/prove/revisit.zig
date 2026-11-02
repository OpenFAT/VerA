//! A fixpoint's worklist over blocks: which blocks a round visits, given what
//! each block's last visit read and which blocks have changed since. Block
//! indices in, the visit order out: every round in index order, a block due
//! again once a block it read changes (later this round when it sits after
//! the change, else next round). `ifconv.run`'s schedule.
//!
//! Cites nothing: a scheduling structure.
//!
//! Contents:
//! - `pub const Revisit = struct`
//! - members: `Revisit.none`, `Revisit.init`, `Revisit.deinit`, `Revisit.next`,
//!   `Revisit.listen`, `Revisit.notify`, `Revisit.nextRound`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// The worklist. Each block keeps the list of blocks whose last visit read it;
/// a change to the block makes them due and empties the list (a visit lists
/// itself again under what it reads now). Stale entries only cost a visit.
pub const Revisit = struct {
    /// This round's blocks still to visit, lowest index first.
    due: Queue = .empty,
    in_due: std.DynamicBitSetUnmanaged,
    /// The next round's.
    later: Queue = .empty,
    in_later: std.DynamicBitSetUnmanaged,
    /// Per block, the newest entry of its reader list in `edges`, or `none`.
    first: []u32,
    edges: std.ArrayList(Reader) = .empty,

    /// `notify`'s position past every block: every reader goes to the next round.
    pub const none = std.math.maxInt(u32);

    const Reader = struct { block: u32, next: u32 };
    const Queue = std.PriorityQueue(u32, void, lowerFirst);

    /// Every one of `nb` blocks due in the first round, which is a full scan.
    /// Asserts that `nb` is positive.
    pub fn init(gpa: Allocator, nb: u32) Allocator.Error!Revisit {
        assert(nb > 0);
        assert(nb < none);
        const first = try gpa.alloc(u32, nb);
        errdefer gpa.free(first);
        @memset(first, none);
        var in_due = try std.DynamicBitSetUnmanaged.initFull(gpa, nb);
        errdefer in_due.deinit(gpa);
        var in_later = try std.DynamicBitSetUnmanaged.initEmpty(gpa, nb);
        errdefer in_later.deinit(gpa);
        var r: Revisit = .{ .in_due = in_due, .in_later = in_later, .first = first };
        errdefer r.due.deinit(gpa);
        try r.due.ensureTotalCapacity(gpa, nb);
        for (0..nb) |b| r.due.push(gpa, @intCast(b)) catch unreachable; // capacity reserved above
        assert(r.due.count() == nb);
        return r;
    }

    pub fn deinit(r: *Revisit, gpa: Allocator) void {
        assert(r.first.len > 0); // `init` ran
        assert(r.in_due.bit_length == r.first.len);
        gpa.free(r.first);
        r.due.deinit(gpa);
        r.later.deinit(gpa);
        r.in_due.deinit(gpa);
        r.in_later.deinit(gpa);
        r.edges.deinit(gpa);
    }

    /// Returns this round's next block to visit, lowest index first, or null
    /// once the round is done.
    pub fn next(r: *Revisit) ?u32 {
        const b = r.due.pop() orelse return null;
        assert(r.in_due.isSet(b));
        assert(b < r.first.len);
        r.in_due.unset(b);
        return b;
    }

    /// Records that block `b`'s visit just now read each of `reads`.
    /// Asserts that it read something and that every block is in range.
    pub fn listen(r: *Revisit, gpa: Allocator, b: u32, reads: []const u32) Allocator.Error!void {
        assert(b < r.first.len);
        assert(reads.len > 0);
        try r.edges.ensureUnusedCapacity(gpa, reads.len);
        for (reads) |t| {
            assert(t < r.first.len);
            r.edges.appendAssumeCapacity(.{ .block = b, .next = r.first[t] });
            r.first[t] = @intCast(r.edges.items.len - 1);
        }
        assert(r.edges.items.len >= reads.len);
    }

    /// Makes due every block whose last visit read `t`: this round when it
    /// sits after `pos` (the block being visited), else the next round.
    pub fn notify(r: *Revisit, gpa: Allocator, t: u32, pos: u32) Allocator.Error!void {
        assert(t < r.first.len);
        var e = r.first[t];
        r.first[t] = none;
        // A reader list is a chain of distinct entries of `edges`.
        for (0..r.edges.items.len) |_| {
            if (e == none) return;
            const reader = r.edges.items[e];
            assert(reader.block < r.first.len);
            if (reader.block > pos) {
                if (!r.in_due.isSet(reader.block)) try r.due.push(gpa, reader.block);
                r.in_due.set(reader.block);
            } else {
                if (!r.in_later.isSet(reader.block)) try r.later.push(gpa, reader.block);
                r.in_later.set(reader.block);
            }
            e = reader.next;
        }
        assert(e == none);
    }

    /// Starts the next round. Returns whether any block is due in it.
    /// Asserts that this round is done.
    pub fn nextRound(r: *Revisit) bool {
        assert(r.due.count() == 0);
        assert(r.in_due.count() == 0);
        std.mem.swap(Queue, &r.due, &r.later);
        std.mem.swap(std.DynamicBitSetUnmanaged, &r.in_due, &r.in_later);
        assert(r.later.count() == 0);
        return r.due.count() != 0;
    }

    // ---- private ----

    fn lowerFirst(_: void, a: u32, b: u32) std.math.Order {
        return std.math.order(a, b);
    }
};

test "revisit: a change reaches the readers after it this round, the rest next round" {
    // Oracle: the order worked by hand. Round 0 is a full scan: 1 and 3 read
    // block 2, and 2 changes while 2 is visited, so 1 is due in round 1 (3,
    // after 2, was due already). In round 1, 1 reads 2 and changes it: 3 sits
    // after 1, so it is due in round 1 too; 1 itself is due in round 2.
    const gpa = std.testing.allocator;
    var r = try Revisit.init(gpa, 4);
    defer r.deinit(gpa);
    var seen: std.ArrayList(u32) = .empty;
    defer seen.deinit(gpa);
    var round: u32 = 0;
    while (true) : (round += 1) {
        try std.testing.expect(round < 4);
        while (r.next()) |b| {
            try seen.append(gpa, b);
            if (round == 0 and b != 2 and b != 0) try r.listen(gpa, b, &.{2});
            if (round == 0 and b == 2) try r.notify(gpa, 2, 2);
            if (round == 1 and b == 1) {
                try r.listen(gpa, 1, &.{2});
                try r.notify(gpa, 2, 1);
            }
        }
        if (!r.nextRound()) break;
    }
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 1, 3, 1 }, seen.items);
}
