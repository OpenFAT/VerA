//! Unknown sets at the device's width: a mask is `w` u64 words (`Gen.mw`,
//! prove's `dep_words`, `max(1, ceil(n_u / 64))`), bit `u` in word `u / 64`.
//! In: the analysis' dependency words and the emitter's unions of them. Out:
//! the set algebra over them, and the literal text and Zig type of
//! `contract.MaskOf(n_u)`, `u64` up to 64 unknowns and `u<n_u>` past them, so
//! a device of at most 64 unknowns emits exactly the one-word text it always
//! did.
//! Cites: none (it realises `contract.MaskOf`).
//!
//! Contents:
//! - `pub const Hex = struct { m: []const u64, pad: bool }`
//! - `pub fn format(h: Hex, w: *std.Io.Writer) std.Io.Writer.Error!void` (on `Hex`)
//! - `pub fn zero(a: Allocator, w: u32) Allocator.Error![]u64`
//! - `pub fn set(m: []u64, u: u32) void`
//! - `pub fn has(m: []const u64, u: usize) bool`
//! - `pub fn orIn(dst: []u64, src: []const u64) void`
//! - `pub fn andIn(dst: []u64, src: []const u64) void`
//! - `pub fn join(arena: Allocator, a: []const u64, b: []const u64) Allocator.Error![]u64`
//! - `pub fn subset(a: []const u64, b: []const u64) bool`
//! - `pub fn count(m: []const u64) usize`
//! - `pub fn lessThan(_: void, a: []const u64, b: []const u64) bool`
//! - `pub fn typeName(buf: *[16]u8, n_u: u32) []const u8`
//! - `pub fn hex(m: []const u64, pad: bool) Hex`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// `{f}` of a mask as one hex literal without its `0x` (`hex` builds it).
/// Borrows `m`: it must outlive the format call.
pub const Hex = struct {
    m: []const u64,
    /// Pads the top word to 16 digits too.
    pad: bool,

    /// Writes the top word, then every lower word as 16 digits.
    /// Asserts that the mask has at least one word.
    pub fn format(h: Hex, w: *std.Io.Writer) std.Io.Writer.Error!void {
        assert(h.m.len != 0);
        const top = h.m.len - 1;
        // ponytail: leading zero words print as 16 zeros; only the top word drops them.
        if (h.pad) try w.print("{x:0>16}", .{h.m[top]}) else try w.print("{x}", .{h.m[top]});
        for (0..top) |k| try w.print("{x:0>16}", .{h.m[top - 1 - k]});
    }
};

comptime {
    // `set`/`has` split an unknown index into a word and a bit by 64.
    assert(@bitSizeOf(u64) == 64);
}

/// Returns `w` zero words, owned by `a`. `w` may be 0 (a device with no
/// array storage asks for an empty column).
pub fn zero(a: Allocator, w: u32) Allocator.Error![]u64 {
    const m = try a.alloc(u64, w);
    @memset(m, 0);
    assert(m.len == w);
    assert(count(m) == 0);
    return m;
}

/// Sets unknown `u`. Asserts that `u` is inside the mask.
pub fn set(m: []u64, u: u32) void {
    assert(u / 64 < m.len);
    m[u / 64] |= @as(u64, 1) << @intCast(u % 64);
    assert(has(m, u));
}

/// Returns whether unknown `u` is set; false past the mask.
pub fn has(m: []const u64, u: usize) bool {
    if (u / 64 >= m.len) return false;
    return (m[u / 64] >> @intCast(u % 64)) & 1 != 0;
}

/// Ors `src` into `dst`. Asserts that the widths are equal.
pub fn orIn(dst: []u64, src: []const u64) void {
    assert(dst.len == src.len);
    for (dst, src) |*d, s| d.* |= s;
    assert(subset(src, dst));
}

/// Ands `src` into `dst`. Asserts that the widths are equal.
pub fn andIn(dst: []u64, src: []const u64) void {
    assert(dst.len == src.len);
    for (dst, src) |*d, s| d.* &= s;
    assert(subset(dst, src));
}

/// Returns `a | b`, owned by `arena`. Asserts that the widths are equal.
pub fn join(arena: Allocator, a: []const u64, b: []const u64) Allocator.Error![]u64 {
    assert(a.len == b.len);
    const m = try arena.dupe(u64, a);
    orIn(m, b);
    assert(m.len == a.len);
    return m;
}

/// Returns whether every bit of `a` is in `b`. Asserts that the widths are
/// equal.
pub fn subset(a: []const u64, b: []const u64) bool {
    assert(a.len == b.len);
    for (a, b) |x, y| if (x & ~y != 0) return false;
    return true;
}

/// Returns how many unknowns are set.
pub fn count(m: []const u64) usize {
    var n: usize = 0;
    for (m) |x| n += @popCount(x);
    assert(n <= m.len * 64);
    return n;
}

/// Orders masks lexicographically from the top word: the numeric order of
/// the literal `hex` writes. Asserts that the widths are equal.
pub fn lessThan(_: void, a: []const u64, b: []const u64) bool {
    assert(a.len == b.len);
    for (0..a.len) |k| {
        const i = a.len - 1 - k;
        if (a[i] != b[i]) return a[i] < b[i];
    }
    return false;
}

/// Returns the Zig type of a mask over `n_u` unknowns,
/// `contract.MaskOf(n_u)`, written into `buf`.
pub fn typeName(buf: *[16]u8, n_u: u32) []const u8 {
    const name = std.mem.print(buf, "u{d}", .{@max(64, n_u)}) catch unreachable;
    assert(name.len >= 3);
    assert(name[0] == 'u');
    return name;
}

/// Returns `{f}` text of `m` as one hex literal without its `0x`: the top word
/// unpadded, every lower word 16 digits; `pad` pads the top word to 16
/// digits too. Borrows `m`. Asserts that `m` has at least one word.
pub fn hex(m: []const u64, pad: bool) Hex {
    assert(m.len != 0);
    return .{ .m = m, .pad = pad };
}

test "a one-word mask prints as the u64 literal did, a wider one as one literal" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("3", try std.mem.print(&buf, "{f}", .{hex(&.{3}, false)}));
    try std.testing.expectEqualStrings("0000000000000003", try std.mem.print(&buf, "{f}", .{hex(&.{3}, true)}));
    try std.testing.expectEqualStrings("10000000000000002", try std.mem.print(&buf, "{f}", .{hex(&.{ 2, 1 }, false)}));
    // Three words: the middle one keeps its leading zeros.
    try std.testing.expectEqualStrings("1" ++ "0000000000000000" ++ "000000000000000a", try std.mem.print(&buf, "{f}", .{hex(&.{ 10, 0, 1 }, false)}));
    var tb: [16]u8 = undefined;
    try std.testing.expectEqualStrings("u64", typeName(&tb, 3));
    try std.testing.expectEqualStrings("u130", typeName(&tb, 130));
    try std.testing.expectEqualStrings("u4294967295", typeName(&tb, std.math.maxInt(u32)));
}

test "set/has/orIn/subset/lessThan agree on bits past 64" {
    var a: [3]u64 = @splat(0);
    var b: [3]u64 = @splat(0);
    set(&a, 0);
    set(&a, 130);
    set(&b, 130);
    try std.testing.expect(has(&a, 130) and !has(&a, 129) and !has(&a, 500));
    try std.testing.expect(subset(&b, &a) and !subset(&a, &b));
    try std.testing.expect(lessThan({}, &b, &a));
    orIn(&b, &a);
    try std.testing.expect(std.mem.eql(u64, &a, &b));
    try std.testing.expectEqual(@as(usize, 2), count(&a));
}
