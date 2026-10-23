//! Unknown sets at the device's width: a mask is `w` u64 words (`Gen.mw`,
//! prove's `dep_words`, `max(1, ceil(n_u / 64))`), bit `u` in word `u / 64`.
//! In: the analysis' dependency words and the emitter's unions of them. Out:
//! the literal text and Zig type of `contract.MaskOf(n_u)`, `u64` up to 64
//! unknowns and `u<n_u>` past them, so a device of at most 64 unknowns emits
//! exactly the one-word text it always did.

const std = @import("std");
const assert = std.debug.assert;

/// Returns `w` zero words from `a`.
pub fn zero(a: std.mem.Allocator, w: u32) error{OutOfMemory}![]u64 {
    const m = try a.alloc(u64, w);
    @memset(m, 0);
    return m;
}

/// Sets unknown `u`. Asserts it is inside the mask.
pub fn set(m: []u64, u: u32) void {
    assert(u / 64 < m.len);
    m[u / 64] |= @as(u64, 1) << @intCast(u % 64);
}

/// Whether unknown `u` is set; false past the mask.
pub fn has(m: []const u64, u: usize) bool {
    if (u / 64 >= m.len) return false;
    return (m[u / 64] >> @intCast(u % 64)) & 1 != 0;
}

/// `dst |= src`. Asserts equal widths.
pub fn orIn(dst: []u64, src: []const u64) void {
    assert(dst.len == src.len);
    for (dst, src) |*d, s| d.* |= s;
}

/// `dst &= src`. Asserts equal widths.
pub fn andIn(dst: []u64, src: []const u64) void {
    assert(dst.len == src.len);
    for (dst, src) |*d, s| d.* &= s;
}

/// Returns `a | b` from `arena`.
pub fn join(arena: std.mem.Allocator, a: []const u64, b: []const u64) error{OutOfMemory}![]u64 {
    const m = try arena.dupe(u64, a);
    orIn(m, b);
    return m;
}

/// Whether every bit of `a` is in `b`.
pub fn subset(a: []const u64, b: []const u64) bool {
    assert(a.len == b.len);
    for (a, b) |x, y| if (x & ~y != 0) return false;
    return true;
}

pub fn count(m: []const u64) usize {
    var n: usize = 0;
    for (m) |x| n += @popCount(x);
    return n;
}

/// Lexicographic order from the top word: the numeric order of the literal.
pub fn lessThan(_: void, a: []const u64, b: []const u64) bool {
    assert(a.len == b.len);
    var i = a.len;
    while (i > 0) {
        i -= 1;
        if (a[i] != b[i]) return a[i] < b[i];
    }
    return false;
}

/// The Zig type of a mask over `n_u` unknowns, `contract.MaskOf(n_u)`.
pub fn typeName(buf: *[16]u8, n_u: u32) []const u8 {
    return std.mem.print(buf, "u{d}", .{@max(64, n_u)}) catch unreachable;
}

/// `{f}` of `m` as one hex literal without its `0x`: the top word unpadded,
/// every lower word 16 digits; `pad` pads the top word to 16 digits too.
pub fn hex(m: []const u64, pad: bool) Hex {
    return .{ .m = m, .pad = pad };
}

pub const Hex = struct {
    m: []const u64,
    pad: bool,
    pub fn format(h: Hex, w: *std.Io.Writer) std.Io.Writer.Error!void {
        assert(h.m.len != 0);
        var i = h.m.len - 1;
        // ponytail: leading zero words print as 16 zeros; only the top word drops them.
        if (h.pad) try w.print("{x:0>16}", .{h.m[i]}) else try w.print("{x}", .{h.m[i]});
        while (i > 0) {
            i -= 1;
            try w.print("{x:0>16}", .{h.m[i]});
        }
    }
};

test "a one-word mask prints as the u64 literal did, a wider one as one literal" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("3", try std.mem.print(&buf, "{f}", .{hex(&.{3}, false)}));
    try std.testing.expectEqualStrings("0000000000000003", try std.mem.print(&buf, "{f}", .{hex(&.{3}, true)}));
    try std.testing.expectEqualStrings("10000000000000002", try std.mem.print(&buf, "{f}", .{hex(&.{ 2, 1 }, false)}));
    var tb: [16]u8 = undefined;
    try std.testing.expectEqualStrings("u64", typeName(&tb, 3));
    try std.testing.expectEqualStrings("u130", typeName(&tb, 130));
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
