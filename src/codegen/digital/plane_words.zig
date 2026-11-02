//! A value's width -> the 64-bit words it takes in `rt.State`'s two planes,
//! and the masks the emitted stores pass: one word per 64 bits, the top
//! word's unused bits clear.
//! Cites: IEEE 1364-2005 §3.2 (a vector of `w` bits, 4-state: one value and
//! one unknown plane).
//!
//! Contents:
//! - `pub fn words(w: u32) u32`
//! - `pub fn maskOf(w: u32) u64`
//! - `pub fn full(w: u32) std.fmt.Alt(u32, fullText)`

const std = @import("std");
const assert = std.debug.assert;

/// Returns the 64-bit plane words a `w`-bit value occupies in `rt.State`.
pub fn words(w: u32) u32 {
    const n = w / 64 + @intFromBool(w % 64 != 0);
    assert(@as(u64, n) * 64 >= w);
    assert(n == 0 or @as(u64, n - 1) * 64 < w);
    return n;
}

/// Returns the low `w` bits set; all 64 for `w` >= 64.
pub fn maskOf(w: u32) u64 {
    const m = if (w >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(w)) - 1;
    assert(@popCount(m) == @min(w, 64));
    return m;
}

/// Formats every bit of a `w`-bit slot as `rt.State.put`'s mask: a hex word
/// up to 64 bits, `L.full(w)` past them.
pub fn full(w: u32) std.fmt.Alt(u32, fullText) {
    return .{ .data = w };
}

// ---- private ----

fn fullText(w: u32, out: *std.Io.Writer) std.Io.Writer.Error!void {
    if (w <= 64) return out.print("0x{x}", .{maskOf(w)});
    try out.print("L.full({d})", .{w});
}

test words {
    try std.testing.expectEqual(@as(u32, 0), words(0));
    try std.testing.expectEqual(@as(u32, 1), words(64));
    try std.testing.expectEqual(@as(u32, 2), words(65));
}

test maskOf {
    try std.testing.expectEqual(@as(u64, 0), maskOf(0));
    try std.testing.expectEqual(@as(u64, 1), maskOf(1));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u63)), maskOf(63));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), maskOf(64));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), maskOf(65));
}
