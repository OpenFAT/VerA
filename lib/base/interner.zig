//! The string intern table: identifier and string text in, a dense `StrId`
//! out, ids given in insertion order so the same input always gives the same
//! ids; and a `StrId` in, its text out. The AST and the MIR each hold one
//! (`SourceFile.strings`, `Mir.strings`); a `StrId` means something only
//! against the table that issued it. A table may continue another (its
//! base: elaboration's overlay of the parse): its ids start after the base's,
//! so every id the base gave keeps its number and its text.
//!
//! Cites: VAMS-2023 §2.7 (strings), §2.8 (identifiers).
//!
//! Contents:
//! - `pub const StrId = enum(u32) { none = maxInt(u32), _ }`
//! - `pub const StringInterner = struct`
//! - `StringInterner.capacity: u32`
//! - `StringInterner.empty: StringInterner`
//! - `StringInterner.continuing(base: *const StringInterner) StringInterner`
//! - `StringInterner.deinit(self: *StringInterner, gpa: Allocator) void`
//! - `StringInterner.intern(self: *StringInterner, gpa: Allocator, text: []const u8) Allocator.Error!StrId`
//! - `StringInterner.find(self: *const StringInterner, text: []const u8) ?StrId`
//! - `StringInterner.get(self: *const StringInterner, id: StrId) []const u8`
//! - `StringInterner.eql(self: *const StringInterner, id: StrId, text: []const u8) bool`
//! - `StringInterner.len(self: *const StringInterner) u32`
//! - `StringInterner.clone(self: *const StringInterner, gpa: Allocator) Allocator.Error!StringInterner`
//!
//! The private `IdContext` and `TextAdapter` declare `pub fn hash` and
//! `pub fn eql` only because `std.HashMapUnmanaged` looks them up.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Handle into a `StringInterner`: the text's insertion rank. `.none` is the
/// absent name and is never issued.
pub const StrId = enum(u32) { none = std.math.maxInt(u32), _ };

/// Identifier and string intern table.
///
/// Data: in, text slices (§2.8 identifiers, §2.7 strings, generated
/// hierarchical names); out, ids. About 4,000 per table on the largest
/// compact models (3,640 on psp103), at most `capacity`. `intern` hashes and
/// compares text; `get` reads one row's pointer and length together, so a row
/// is one slice. One writer; no table is shared between threads while it
/// grows.
///
/// The text is borrowed, never copied: a slice `get` returns stays valid
/// while the table grows, which every stage relies on (it holds names across
/// further interning). So every text passed to `intern` must outlive the
/// table (source substrings, or arena copies).
pub const StringInterner = struct {
    /// The table this one continues, which it reads and never writes: the
    /// base's ids are this table's first `base.len()`, and a text the base
    /// holds keeps its id. Null for a table of its own. Set only by
    /// `continuing`. A pointer, not a handle: the two tables live in
    /// different owners (the parse and elaboration) with no table above both.
    base: ?*const StringInterner = null,
    /// The text of each id this table added, at `@backingInt(id) - base.len()`.
    /// Callers read it; only `intern` appends to it.
    texts: std.ArrayList([]const u8) = .empty,
    /// The set of this table's own ids, hashed by their text. The key is the
    /// 4-byte id, not the 16-byte slice `texts` already holds: 5 bytes a slot
    /// instead of 21 (3,640 names in 8,192 slots on psp103).
    map: std.HashMapUnmanaged(StrId, void, IdContext, std.hash_map.default_max_load_percentage) = .empty,

    /// The most ids one table and its base hold together. The next id would
    /// be `StrId.none`. Unreachable from a source under 4 GiB: that many
    /// distinct names need more text than the source and its arena hold.
    pub const capacity: u32 = std.math.maxInt(u32);

    /// A table of its own, holding no id.
    pub const empty: StringInterner = .{};

    /// Returns an empty table that continues `base`: `base`'s ids read
    /// through it, and its own start at `base.len()`. `base` must outlive it
    /// and must not grow while it lives.
    /// Asserts that `base` continues no table itself.
    pub fn continuing(base: *const StringInterner) StringInterner {
        assert(base.base == null);
        const self: StringInterner = .{ .base = base };
        assert(self.len() == base.len());
        return self;
    }

    /// Frees this table's rows and map, never the base's or the texts
    /// (which are borrowed).
    pub fn deinit(self: *StringInterner, gpa: Allocator) void {
        assert(self.map.count() == self.texts.items.len);
        self.texts.deinit(gpa);
        self.map.deinit(gpa);
        self.* = .empty;
    }

    /// Returns the id of `text`: the base's or this table's existing one, or
    /// a new one, `len()` before the call. `text` is borrowed and must outlive
    /// the table. On `error.OutOfMemory` the table is unchanged.
    /// Invalidates slices of `texts.items` when it adds.
    /// Asserts that the table holds fewer than `capacity` ids when it adds.
    pub fn intern(self: *StringInterner, gpa: Allocator, text: []const u8) Allocator.Error!StrId {
        if (self.base) |b| if (b.find(text)) |id| return id;
        // Room for the text first, so a failed append can never leave the
        // map holding an id with no text.
        try self.texts.ensureUnusedCapacity(gpa, 1);
        const own = self.texts.items;
        const offset = self.baseLen();
        const gop = try self.map.getOrPutContextAdapted(
            gpa,
            text,
            TextAdapter{ .texts = own, .offset = offset },
            IdContext{ .texts = own, .offset = offset },
        );
        if (gop.found_existing) return gop.key_ptr.*;
        assert(offset + own.len < capacity);
        const id: StrId = @fromBackingInt(@intCast(offset + own.len));
        gop.key_ptr.* = id;
        self.texts.appendAssumeCapacity(text);
        assert(self.map.count() == self.texts.items.len);
        assert(@backingInt(id) + 1 == self.len());
        return id;
    }

    /// Returns the id of `text` without adding it, or null when neither this
    /// table nor its base holds it. O(text.len).
    pub fn find(self: *const StringInterner, text: []const u8) ?StrId {
        if (self.base) |b| if (b.find(text)) |id| return id;
        const id = self.map.getKeyAdapted(text, TextAdapter{ .texts = self.texts.items, .offset = self.baseLen() }) orelse return null;
        assert(@backingInt(id) >= self.baseLen());
        assert(@backingInt(id) < self.len());
        return id;
    }

    /// Returns the text of `id`, borrowed from whoever interned it; it stays
    /// valid while the table grows.
    /// Asserts that `id` is not `.none` and was issued by this table or its
    /// base.
    pub fn get(self: *const StringInterner, id: StrId) []const u8 {
        assert(id != .none);
        assert(@backingInt(id) < self.len());
        const offset = self.baseLen();
        if (@backingInt(id) < offset) return self.base.?.get(id);
        return self.texts.items[@backingInt(id) - offset];
    }

    /// Returns whether `id` names `text`; false for `.none`.
    /// Asserts that any other `id` was issued by this table or its base.
    pub fn eql(self: *const StringInterner, id: StrId, text: []const u8) bool {
        return id != .none and std.mem.eql(u8, self.get(id), text);
    }

    /// Returns how many ids the table reads, its base's included.
    pub fn len(self: *const StringInterner) u32 {
        const own: u32 = @intCast(self.texts.items.len);
        assert(own == self.map.count());
        return self.baseLen() + own;
    }

    /// Returns a copy that issues the same ids and grows on its own; the
    /// texts stay borrowed. Caller owns the copy and frees it with
    /// `deinit(gpa)`. On `error.OutOfMemory` nothing is left allocated.
    /// Asserts that the table continues no other.
    pub fn clone(self: *const StringInterner, gpa: Allocator) Allocator.Error!StringInterner {
        assert(self.base == null);
        var texts = try self.texts.clone(gpa);
        errdefer texts.deinit(gpa);

        const map = try self.map.cloneContext(gpa, IdContext{ .texts = self.texts.items });
        const copy: StringInterner = .{ .texts = texts, .map = map };
        assert(copy.len() == self.len());
        return copy;
    }

    // ---- private ----

    /// Hashes an id by its text, for the map's own rehashing. `offset` is the
    /// base's `len()`: the map holds only this table's own ids.
    const IdContext = struct {
        texts: []const []const u8,
        offset: u32 = 0,

        pub fn hash(c: IdContext, id: StrId) u64 {
            return std.hash_map.hashString(c.texts[@backingInt(id) - c.offset]);
        }

        pub fn eql(_: IdContext, a: StrId, b: StrId) bool {
            return a == b;
        }
    };

    /// Looks a text up among the ids without interning it.
    const TextAdapter = struct {
        texts: []const []const u8,
        offset: u32 = 0,

        pub fn hash(_: TextAdapter, text: []const u8) u64 {
            return std.hash_map.hashString(text);
        }

        pub fn eql(a: TextAdapter, text: []const u8, id: StrId) bool {
            return std.mem.eql(u8, text, a.texts[@backingInt(id) - a.offset]);
        }
    };

    /// Returns the base's id count: where this table's own ids start.
    fn baseLen(self: *const StringInterner) u32 {
        const b = self.base orelse return 0;
        assert(b.base == null);
        return @intCast(b.texts.items.len);
    }
};

comptime {
    // `map`'s 5-byte slot is this id plus the metadata byte.
    assert(@sizeOf(StrId) == 4);
}

test "StringInterner: dense ids in insertion order; find never inserts" {
    const gpa = testing.allocator;
    var t: StringInterner = .empty;
    defer t.deinit(gpa);
    const a = try t.intern(gpa, "a");
    const b = try t.intern(gpa, "b");
    try testing.expectEqual(@as(u32, 0), @backingInt(a));
    try testing.expectEqual(@as(u32, 1), @backingInt(b));
    try testing.expectEqual(a, try t.intern(gpa, "a"));
    try testing.expectEqual(@as(?StrId, null), t.find("c"));
    try testing.expectEqual(@as(usize, 2), t.texts.items.len);
    try testing.expectEqual(b, t.find("b").?);
    // The key is the text, not the slice: equal bytes elsewhere are the same id.
    const elsewhere: []const u8 = "ab"[1..];
    try testing.expectEqual(b, try t.intern(gpa, elsewhere));
    try testing.expect(t.eql(a, "a"));
    try testing.expect(!t.eql(a, "b"));
    try testing.expect(!t.eql(.none, ""));
    // The empty string is a name like any other.
    const e = try t.intern(gpa, "");
    try testing.expectEqual(@as(u32, 2), @backingInt(e));
    try testing.expectEqualStrings("", t.get(e));
}

test "StringInterner: ids survive the map's rehashes, and a clone grows alone" {
    const gpa = testing.allocator;
    var names: [300][8]u8 = undefined;
    var t: StringInterner = .empty;
    defer t.deinit(gpa);
    for (&names, 0..) |*n, i| {
        // 8 bytes hold "n" and seven digits of any i below 300.
        _ = std.mem.print(n, "n{d:0>7}", .{i}) catch unreachable;
        try testing.expectEqual(@as(u32, @intCast(i)), @backingInt(try t.intern(gpa, n)));
    }
    for (&names, 0..) |*n, i| try testing.expectEqual(@as(u32, @intCast(i)), @backingInt(t.find(n).?));

    var c = try t.clone(gpa);
    defer c.deinit(gpa);
    try testing.expectEqual(@as(u32, 300), @backingInt(try c.intern(gpa, "only-in-clone")));
    try testing.expectEqual(@as(?StrId, null), t.find("only-in-clone"));
    try testing.expectEqual(@as(usize, 300), t.texts.items.len);
    for (&names, 0..) |*n, i| try testing.expectEqual(@as(u32, @intCast(i)), @backingInt(c.find(n).?));
}

test "StringInterner.continuing: the base's ids keep their numbers, new ones follow" {
    const gpa = testing.allocator;
    var base: StringInterner = .empty;
    defer base.deinit(gpa);
    const a = try base.intern(gpa, "a");
    const b = try base.intern(gpa, "b");
    var over: StringInterner = .continuing(&base);
    defer over.deinit(gpa);
    // A text the base holds is the base's id, and nothing is added.
    try testing.expectEqual(b, try over.intern(gpa, "b"));
    try testing.expectEqual(@as(u32, 2), over.len());
    const c = try over.intern(gpa, "c");
    try testing.expectEqual(c, try over.intern(gpa, "c"));
    try testing.expectEqualStrings("a", over.get(a));
    try testing.expectEqualStrings("c", over.get(c));
    try testing.expectEqual(a, over.find("a").?);
    try testing.expectEqual(c, over.find("c").?);
    try testing.expect(over.eql(c, "c"));
    // The base never grows.
    try testing.expectEqual(@as(?StrId, null), base.find("c"));
    try testing.expectEqual(@as(u32, 2), base.len());
    // The ids one table gives the same texts in the same order (the oracle).
    var one: StringInterner = .empty;
    defer one.deinit(gpa);
    for ([_][]const u8{ "a", "b", "b", "c" }) |t| _ = try one.intern(gpa, t);
    try testing.expectEqual(one.find("c").?, c);
}

test "StringInterner: a seeded op sequence matches a first-seen-order model, through an overlay" {
    // Model: the distinct texts in the order first seen, kept by a linear
    // scan (no hashing). A text's id is its index there: the base's texts
    // first, then the overlay's. Each op interns or finds a name drawn from a
    // small alphabet, so names repeat, collide in the map and force its
    // rehashes. Seeded: a failure replays.
    const Model = struct {
        texts: [64 * 3][]const u8 = undefined,
        len: u32 = 0,

        fn step(m: *@This(), gpa: Allocator, table: *StringInterner, rand: std.Random, pool: *const [64][3]u8) !void {
            const text: []const u8 = pool[rand.uintLessThan(usize, pool.len)][0 .. rand.uintLessThan(usize, 3) + 1];
            var want: ?u32 = null;
            for (m.texts[0..m.len], 0..) |seen, k| {
                if (std.mem.eql(u8, seen, text)) want = @intCast(k);
            }
            if (rand.boolean()) {
                const got = table.find(text);
                try testing.expectEqual(want, if (got) |id| @backingInt(id) else null);
            } else {
                const got = try table.intern(gpa, text);
                if (want == null) {
                    m.texts[m.len] = text;
                    m.len += 1;
                }
                try testing.expectEqual(want orelse m.len - 1, @backingInt(got));
            }
            try testing.expectEqual(m.len, table.len());
        }
    };

    const gpa = testing.allocator;
    var pool: [64][3]u8 = undefined;
    for (&pool, 0..) |*n, i| n.* = .{ 'a' + @as(u8, @intCast(i % 8)), 'a' + @as(u8, @intCast(i / 8)), '_' };
    var model: Model = .{};
    var prng: std.Random.DefaultPrng = .init(0x1d_5eed);
    const rand = prng.random();

    var base: StringInterner = .empty;
    defer base.deinit(gpa);
    for (0..60) |_| try model.step(gpa, &base, rand, &pool);
    const base_len = model.len;
    try testing.expectEqual(base_len, base.len());

    // The base is frozen from here on, as `continuing` requires.
    var over: StringInterner = .continuing(&base);
    defer over.deinit(gpa);
    for (0..2_000) |_| try model.step(gpa, &over, rand, &pool);
    try testing.expectEqual(base_len, base.len());
    try testing.expect(model.len > base_len); // The overlay added ids of its own.
    for (model.texts[0..model.len], 0..) |m, k| try testing.expectEqualStrings(m, over.get(@fromBackingInt(@intCast(k))));
}

test "StringInterner.intern leaves the table unchanged on OOM" {
    const S = struct {
        fn internSome(gpa: Allocator) !void {
            var names: [40][4]u8 = undefined;
            var t: StringInterner = .empty;
            defer t.deinit(gpa);
            for (&names, 0..) |*n, i| {
                // 4 bytes hold "s" and three digits of any i below 40.
                _ = std.mem.print(n, "s{d:0>3}", .{i}) catch unreachable;
                const before = t.texts.items.len;
                const id = t.intern(gpa, n) catch |err| {
                    // No id without its text, and no text without its id.
                    try testing.expectEqual(before, t.texts.items.len);
                    try testing.expectEqual(@as(u32, @intCast(before)), t.map.count());
                    try testing.expectEqual(@as(?StrId, null), t.find(n));
                    return err;
                };
                try testing.expectEqual(@as(u32, @intCast(i)), @backingInt(id));
            }
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, S.internSome, .{});
}

test "StringInterner.clone and an overlay's intern leak nothing and stay consistent on OOM" {
    const S = struct {
        fn cloneAndOverlay(gpa: Allocator) !void {
            var t: StringInterner = .empty;
            defer t.deinit(gpa);
            for ([_][]const u8{ "a", "b", "c" }) |s| _ = try t.intern(gpa, s);
            var c = try t.clone(gpa);
            defer c.deinit(gpa);
            try testing.expectEqual(t.find("c"), c.find("c"));
            // An overlay's failed add leaves its own rows and the base unchanged.
            var over: StringInterner = .continuing(&t);
            defer over.deinit(gpa);
            for ([_][]const u8{ "b", "d", "e", "d" }) |s| {
                const before = over.len();
                _ = over.intern(gpa, s) catch |err| {
                    try testing.expectEqual(before, over.len());
                    try testing.expectEqual(@as(u32, before - t.len()), over.map.count());
                    try testing.expectEqual(@as(?StrId, null), over.find(s));
                    return err;
                };
            }
            try testing.expectEqual(@as(u32, 5), over.len());
            try testing.expectEqual(@as(u32, 3), t.len());
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, S.cloneAndOverlay, .{});
}
