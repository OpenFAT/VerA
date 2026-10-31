//! The compilation arena: allocator calls in, blocks out, every one freed by
//! one `deinit`. Small blocks are bumped from a `std.heap.ArenaAllocator`;
//! large ones are passed through to the backing allocator and remembered so
//! `deinit` frees them with the rest.
//!
//! Why: a plain arena can grow only its latest allocation in place, so every
//! list that doubles on it leaves its previous buffer behind until the arena
//! dies. The compile's big tables (MIR rows, the AST stores, codegen's text
//! buffers) all grow that way, and the dead copies were a third of the
//! compile's resident memory on hisimhv. Passed through, a large buffer grows
//! by the backing allocator's `remap` (an `mremap` for `smp_allocator`, which
//! moves page mappings and copies nothing) and a buffer it gives up is
//! returned at once.
//!
//! The split is by length alone: every live block of `large` bytes or more is
//! the backing allocator's, every smaller one the arena's. A resize that would
//! cross the line is refused, so the caller moves the data, and a block never
//! changes sides. Not threadsafe.
//!
//! Owners: `vera.CompileResult` (one per compilation) and `src/main.zig`'s
//! `.v` design arena.
//!
//! Cites: no standard (memory management).
//!
//! Contents:
//! - `pub const large: usize`
//! - `pub fn init(child: Allocator) BigArena`
//! - `pub fn deinit(self: *BigArena) void`
//! - `pub fn allocator(self: *BigArena) Allocator`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// The length from which a block is the backing allocator's. From 64 KiB up
/// `smp_allocator` maps pages and remaps them in place; from 16 KiB to 64 KiB
/// it serves a slab size class, so a grown list still copies, but its old
/// buffer goes back to the slab at once instead of lying dead in the arena.
// Measured 2026-10-03 against 64 KiB (ReleaseFast `--emit-zig`, peak RSS,
// best of 3): psp103 -7.9%, bsim4va -11.4%, hisimhv -6.2%, at equal user
// instructions. 4, 8 and 32 KiB each saved less.
pub const large = 16 * 1024;

/// The arena every small block is bumped from.
small: std.heap.ArenaAllocator,
/// The backing allocator: every large block's, and `small`'s and `blocks`'s.
child: Allocator,
/// Address → extent of every live large block, for `deinit`. Few entries:
/// one per large table, not per allocation (at most 50 live on hisimhv,
/// counted at the 64 KiB threshold), so the map's per-entry cost is
/// immaterial. Callers read it only to test it.
blocks: std.AutoHashMapUnmanaged(usize, Block) = .empty,

const BigArena = @This();

/// A large block's extent, as `free` must pass it back to `child`.
const Block = struct { len: usize, alignment: Alignment };

comptime {
    // A block is large from one `large` up; zero-length blocks never are.
    assert(large > 0);
    assert(std.math.isPowerOfTwo(large));
}

/// Returns an empty arena over `child`, which must outlive it.
pub fn init(child: Allocator) BigArena {
    const self: BigArena = .{ .small = .init(child), .child = child };
    assert(self.blocks.count() == 0);
    return self;
}

/// Frees every block, large and small, and invalidates every pointer the
/// arena handed out and every allocator taken from it.
pub fn deinit(self: *BigArena) void {
    var it = self.blocks.iterator();
    var freed: u32 = 0;
    while (it.next()) |e| : (freed += 1) {
        assert(e.value_ptr.len >= large);
        // SAFETY: the key is the address `alloc` or `remap` returned for this
        // live block, recorded with its length; nothing else writes the map.
        const p: [*]u8 = @ptrFromInt(e.key_ptr.*);
        self.child.rawFree(p[0..e.value_ptr.len], e.value_ptr.alignment, @returnAddress());
    }
    assert(freed == self.blocks.count());
    self.blocks.deinit(self.child);
    self.small.deinit();
    self.* = undefined;
}

/// Returns the allocator interface. Its `ptr` is `self`, so the arena must
/// not move while anything holds an allocator taken from it. A `free` returns
/// a large block to the backing allocator at once and a small one only when
/// it was the arena's latest allocation. A `resize` or `remap` that would take
/// a block across `large` fails, so the caller copies (`realloc` does).
/// Asserts (on each call through it) that a large block passed back is one
/// it handed out and has not freed.
pub fn allocator(self: *BigArena) Allocator {
    return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
}

// ---- private ----

fn alloc(ctx: *anyopaque, n: usize, a: Alignment, ra: usize) ?[*]u8 {
    // SAFETY: `allocator` sets `ptr` to a live `*BigArena`.
    const self: *BigArena = @ptrCast(@alignCast(ctx));
    if (n < large) return self.small.allocator().rawAlloc(n, a, ra);
    // The entry is reserved before the block, so a failure of either leaves
    // nothing half-recorded.
    self.blocks.ensureUnusedCapacity(self.child, 1) catch return null;
    const p = self.child.rawAlloc(n, a, ra) orelse return null;
    assert(a.check(@intFromPtr(p)));
    self.blocks.putAssumeCapacityNoClobber(@intFromPtr(p), .{ .len = n, .alignment = a });
    return p;
}

fn resize(ctx: *anyopaque, m: []u8, a: Alignment, n: usize, ra: usize) bool {
    // SAFETY: `allocator` sets `ptr` to a live `*BigArena`.
    const self: *BigArena = @ptrCast(@alignCast(ctx));
    if ((m.len < large) != (n < large)) return false;
    if (m.len < large) return self.small.allocator().rawResize(m, a, n, ra);
    const block = self.blocks.getPtr(@intFromPtr(m.ptr)).?; // Live: the caller's contract.
    assert(block.len == m.len);
    if (!self.child.rawResize(m, a, n, ra)) return false;
    block.len = n;
    return true;
}

fn remap(ctx: *anyopaque, m: []u8, a: Alignment, n: usize, ra: usize) ?[*]u8 {
    // SAFETY: `allocator` sets `ptr` to a live `*BigArena`.
    const self: *BigArena = @ptrCast(@alignCast(ctx));
    if ((m.len < large) != (n < large)) return null;
    if (m.len < large) return self.small.allocator().rawRemap(m, a, n, ra);
    assert(self.blocks.get(@intFromPtr(m.ptr)).?.len == m.len);
    // Room for the moved key first: after a successful remap the old address
    // is gone, and failing then would lose the block.
    self.blocks.ensureUnusedCapacity(self.child, 1) catch return null;
    const p = self.child.rawRemap(m, a, n, ra) orelse return null;
    assert(self.blocks.remove(@intFromPtr(m.ptr)));
    self.blocks.putAssumeCapacityNoClobber(@intFromPtr(p), .{ .len = n, .alignment = a });
    return p;
}

fn free(ctx: *anyopaque, m: []u8, a: Alignment, ra: usize) void {
    // SAFETY: `allocator` sets `ptr` to a live `*BigArena`.
    const self: *BigArena = @ptrCast(@alignCast(ctx));
    if (m.len < large) return self.small.allocator().rawFree(m, a, ra);
    const block = self.blocks.fetchRemove(@intFromPtr(m.ptr)).?; // The pair of `alloc`'s put.
    assert(block.value.len == m.len);
    assert(block.value.alignment == a);
    self.child.rawFree(m, a, ra);
}

test "big arena: large blocks grow, move and free through the backing allocator" {
    var arena: BigArena = .init(std.testing.allocator);
    defer arena.deinit(); // the testing allocator fails the test on a leak
    const a = arena.allocator();

    var list: std.ArrayList(u32) = .empty;
    for (0..100_000) |i| try list.append(a, @intCast(i)); // crosses `large`
    for (list.items, 0..) |x, i| try std.testing.expectEqual(@as(u32, @intCast(i)), x);
    try std.testing.expectEqual(@as(u32, 1), arena.blocks.count());

    const kept = try list.toOwnedSlice(a); // shrink of a large block stays large
    try std.testing.expectEqual(@as(u32, 99_999), kept[kept.len - 1]);
    _ = try a.alloc(u8, 10); // small, from the arena
    const big = try a.alloc(u8, large);
    a.free(big); // given back at once
    try std.testing.expectEqual(@as(u32, 1), arena.blocks.count());
    // `kept` and the small block are freed by `deinit`.
}

test "big arena: the split is at `large` exactly" {
    var arena: BigArena = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const below = try a.alloc(u8, large - 1);
    try std.testing.expectEqual(@as(u32, 0), arena.blocks.count());
    const at = try a.alloc(u8, large);
    try std.testing.expectEqual(@as(u32, 1), arena.blocks.count());
    try std.testing.expectEqual(large, arena.blocks.get(@intFromPtr(at.ptr)).?.len);
    try std.testing.expect(!arena.blocks.contains(@intFromPtr(below.ptr)));
}

test "big arena: a resize or remap across `large` is refused, and realloc copies across" {
    var arena: BigArena = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Up: a small block never becomes the backing allocator's.
    const small = try a.alloc(u8, large - 1);
    try std.testing.expect(!a.resize(small, large));
    try std.testing.expect(a.remap(small, large) == null);
    try std.testing.expectEqual(@as(u32, 0), arena.blocks.count());

    // Down: a large block never becomes the arena's, and keeps its entry.
    const big = try a.alloc(u8, large);
    try std.testing.expect(!a.resize(big, large - 1));
    try std.testing.expect(a.remap(big, large - 1) == null);
    try std.testing.expectEqual(large, arena.blocks.get(@intFromPtr(big.ptr)).?.len);

    // `realloc` moves the data instead: the large block is freed, so its
    // entry goes, and the bytes arrive on the small side, then back.
    @memset(big, 0x5a);
    const moved_down = try a.realloc(big, large - 1);
    try std.testing.expectEqual(@as(u32, 0), arena.blocks.count());
    try std.testing.expect(std.mem.allEqual(u8, moved_down, 0x5a));
    const moved_up = try a.realloc(moved_down, 2 * large);
    try std.testing.expectEqual(2 * large, arena.blocks.get(@intFromPtr(moved_up.ptr)).?.len);
    try std.testing.expect(std.mem.allEqual(u8, moved_up[0 .. large - 1], 0x5a));
}

test "big arena: a large resize in place records the new length" {
    // A fixed buffer grows and shrinks its last block in place, always. The
    // map's table is allocated first (`alloc` reserves the entry before the
    // block), so the block is that last one.
    var buf: [3 * large]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    var arena: BigArena = .init(fba.allocator());
    defer arena.deinit();
    const a = arena.allocator();

    const m = try a.alloc(u8, large);
    try std.testing.expect(a.resize(m, 2 * large));
    try std.testing.expectEqual(2 * large, arena.blocks.get(@intFromPtr(m.ptr)).?.len);
    try std.testing.expect(a.resize(m.ptr[0 .. 2 * large], large + 1));
    try std.testing.expectEqual(large + 1, arena.blocks.get(@intFromPtr(m.ptr)).?.len);
    try std.testing.expectEqual(@as(u32, 1), arena.blocks.count());
}

test "big arena: a large remap re-keys the block under its new address" {
    // `std.testing.allocator` whose `remap` always moves the block, so the
    // re-keying half of `remap` runs on every call instead of only when the
    // address space happens to make the backing allocator move.
    const moving: Allocator = .{ .ptr = undefined, .vtable = &.{
        .alloc = struct {
            fn f(_: *anyopaque, n: usize, a: Alignment, ra: usize) ?[*]u8 {
                return std.testing.allocator.rawAlloc(n, a, ra);
            }
        }.f,
        .resize = struct {
            fn f(_: *anyopaque, m: []u8, a: Alignment, n: usize, ra: usize) bool {
                return std.testing.allocator.rawResize(m, a, n, ra);
            }
        }.f,
        .remap = struct {
            fn f(_: *anyopaque, m: []u8, a: Alignment, n: usize, ra: usize) ?[*]u8 {
                const p = std.testing.allocator.rawAlloc(n, a, ra) orelse return null;
                const kept = @min(m.len, n);
                @memcpy(p[0..kept], m[0..kept]);
                std.testing.allocator.rawFree(m, a, ra);
                return p;
            }
        }.f,
        .free = struct {
            fn f(_: *anyopaque, m: []u8, a: Alignment, ra: usize) void {
                std.testing.allocator.rawFree(m, a, ra);
            }
        }.f,
    } };

    var arena: BigArena = .init(moving);
    defer arena.deinit();
    const a = arena.allocator();

    const m = try a.alloc(u8, large);
    @memset(m, 0x3c);
    const old = @intFromPtr(m.ptr);
    const g = a.remap(m, 4 * large) orelse return error.TestUnexpectedResult;
    // The new block was allocated while the old one was live: a new address.
    try std.testing.expect(@intFromPtr(g.ptr) != old);
    try std.testing.expectEqual(@as(u32, 1), arena.blocks.count());
    try std.testing.expect(!arena.blocks.contains(old));
    try std.testing.expectEqual(4 * large, arena.blocks.get(@intFromPtr(g.ptr)).?.len);
    try std.testing.expect(std.mem.allEqual(u8, g[0..large], 0x3c));
    // `deinit` frees the moved block by its new address and length; the
    // testing allocator fails the test if either were stale.
}

test "big arena: a large block keeps its alignment, and deinit frees it with it" {
    var arena: BigArena = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const page = comptime Alignment.fromByteUnits(4096);
    const m = try a.alignedAlloc(u8, page, large);
    try std.testing.expect(page.check(@intFromPtr(m.ptr)));
    try std.testing.expectEqual(page, arena.blocks.get(@intFromPtr(m.ptr)).?.alignment);
}

test "big arena: a failure of any backing allocation is OutOfMemory and leaks nothing" {
    // Oracle: `checkAllAllocationFailures` fails the n-th backing allocation
    // for every n, and fails the test if the failure is swallowed or the
    // bytes allocated and freed differ. The map entry is reserved before the
    // block, so a failure of either leaves nothing half-recorded.
    const S = struct {
        // Five allocations reach `child`, in this order: the map's table, three
        // large blocks, and the small arena's first chunk.
        fn bigArenaSequence(child: Allocator) !void {
            var arena: BigArena = .init(child);
            defer arena.deinit();
            const a = arena.allocator();
            _ = try a.alloc(u8, large);
            const y = try a.alloc(u8, 2 * large);
            _ = try a.alloc(u8, 3 * large);
            a.free(y);
            _ = try a.alloc(u8, 16);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, S.bigArenaSequence, .{});
}

test "big arena: a seeded random op sequence keeps `blocks` equal to the live large blocks" {
    // Model: `slots`, every block the test holds, each filled with a byte of
    // its own. After every op, `blocks` holds exactly the slots of `large`
    // bytes or more, each under its address with its length, and an op that
    // keeps data kept it. At the end every slot still holds its byte. The
    // testing allocator fails the test on a leak, or on a free whose length
    // or alignment is not the allocation's: what `deinit` hands back from
    // `blocks`. Seeded, so a failure replays.
    var arena: BigArena = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Both sides of the line, the line itself, and blocks several times it.
    const sizes = [_]usize{ 1, 100, large - 1, large, large + 1, 3 * large, 5 * large + 7 };
    var slots: [16][]u8 = undefined;
    for (&slots) |*s| s.* = &.{};
    var prng: std.Random.DefaultPrng = .init(0x5eed_b16a);
    const rand = prng.random();

    for (0..600) |_| {
        const s = rand.uintLessThan(usize, slots.len);
        const fill: u8 = @truncate(s *% 37 +% 1);
        const m = slots[s];
        const n = sizes[rand.uintLessThan(usize, sizes.len)];
        if (m.len == 0) {
            slots[s] = try a.alloc(u8, n);
            @memset(slots[s], fill);
        } else switch (rand.uintLessThan(u8, 4)) {
            0 => {
                a.free(m);
                slots[s] = &.{};
            },
            1 => {
                const r = try a.realloc(m, n);
                try std.testing.expect(std.mem.allEqual(u8, r[0..@min(m.len, n)], fill));
                @memset(r, fill);
                slots[s] = r;
            },
            2 => if (a.resize(m, n)) {
                try std.testing.expect((m.len < large) == (n < large));
                slots[s] = m.ptr[0..n];
                @memset(slots[s], fill);
            },
            else => if (a.remap(m, n)) |r| {
                try std.testing.expect((m.len < large) == (n < large));
                try std.testing.expect(std.mem.allEqual(u8, r[0..@min(m.len, n)], fill));
                @memset(r, fill);
                slots[s] = r;
            },
        }

        var n_large: u32 = 0;
        for (slots) |live| if (live.len >= large) {
            n_large += 1;
            const b = arena.blocks.get(@intFromPtr(live.ptr)) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(live.len, b.len);
        };
        try std.testing.expectEqual(n_large, arena.blocks.count());
    }
    for (slots, 0..) |live, s| {
        const fill: u8 = @truncate(s *% 37 +% 1);
        try std.testing.expect(std.mem.allEqual(u8, live, fill));
    }
}

test "big arena: a full `blocks` map that cannot grow refuses the block, and a remap keeps it" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    var arena: BigArena = .init(failing.allocator());
    defer arena.deinit();
    const a = arena.allocator();
    // Fill the map to its load limit, so the next entry needs a larger table.
    var first: ?[]u8 = null;
    while (arena.blocks.count() == 0 or arena.blocks.available != 0) {
        const m = try a.alloc(u8, large);
        if (first == null) first = m;
    }
    const m = first.?;
    @memset(m, 0x7e);
    const count = arena.blocks.count();
    failing.fail_index = failing.alloc_index; // the table's growth fails
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, large));
    try std.testing.expect(a.remap(m, 2 * large) == null);
    try std.testing.expectEqual(count, arena.blocks.count());
    try std.testing.expectEqual(large, arena.blocks.get(@intFromPtr(m.ptr)).?.len);
    try std.testing.expect(std.mem.allEqual(u8, m, 0x7e));
    // A resize needs no new entry, so it still works.
    failing.fail_index = std.math.maxInt(usize);
    _ = a.resize(m, large + 1);
}
