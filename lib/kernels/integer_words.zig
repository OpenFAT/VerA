//! The plane arithmetic every `Literal` operation shares: a width in, its
//! word count and last-word mask out; a literal's plane and a word index in,
//! that word extended past the width out; and the padding and allocation
//! rules that keep the bits above `width` zero. Internal to `integer*.zig`:
//! `root.zig` does not re-export it.
//! Cites: IEEE 1364-2005 §5.5 (extension by the propagated signedness),
//! Table 5-16 (`invert`).
//!
//! Contents:
//! - `pub const Extension = enum(u1) { zero, sign }`
//! - `pub fn wordCount(width: u32) usize`
//! - `pub fn mask(width: u32) u64`
//! - `pub fn allocate(gpa: Allocator, width: u32, signed: bool) Allocator.Error!Literal`
//! - `pub fn invert(value: Bit) Bit`
//! - `pub fn extendedWord(lit: Literal, plane: []const u64, index: usize, extension: Extension) u64`
//! - `pub fn clearPadding(lit: Literal) void`
//! - `pub fn fillUnknown(lit: Literal) void`
//! - `pub fn copyBits(dest: Literal, source: Literal, offset: u32) void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const integer = @import("integer.zig");
const Literal = integer.Literal;
const Bit = integer.Bit;

/// How a resize or a context-determined operand fills the bits it adds:
/// with zero, or with copies of the top bit (X and Z included), IEEE 1364-2005
/// §5.5.
pub const Extension = enum(u1) { zero, sign };

/// Returns the 64-bit words `width` bits take. Asserts that `width > 0`.
pub fn wordCount(width: u32) usize {
    assert(width > 0);
    const n = (@as(usize, width) - 1) / 64 + 1;
    assert(n * 64 >= width);
    return n;
}

/// Returns the mask of the bits a `width`-bit literal's last word holds.
pub fn mask(width: u32) u64 {
    const n: u6 = @truncate(width);
    return if (n == 0) std.math.maxInt(u64) else (@as(u64, 1) << n) - 1;
}

/// Returns a sized `width`-bit literal whose planes are uninitialized, one
/// allocation from `gpa`; the caller owns `planes`. Asserts that
/// `width > 0`.
pub fn allocate(gpa: Allocator, width: u32, signed: bool) Allocator.Error!Literal {
    assert(width != 0);
    const lit: Literal = .{ .width = width, .sized = true, .signed = signed, .planes = try gpa.alloc(u64, wordCount(width) * 2) };
    assert(lit.values().len == lit.unknowns().len);
    return lit;
}

/// Returns IEEE 1364-2005 Table 5-16's `~` of one bit: X and Z both negate
/// to X.
pub fn invert(value: Bit) Bit {
    return switch (value) {
        .zero => .one,
        .one => .zero,
        .x, .z => .x,
    };
}

/// Returns word `index` of `plane` (one of `lit`'s) extended past
/// `lit.width` by `extension`: the declared bits, then the fill. Reads only
/// the declared bits, so padding and spare capacity are never data.
pub fn extendedWord(lit: Literal, plane: []const u64, index: usize, extension: Extension) u64 {
    assert(lit.width > 0);
    const last = (lit.width - 1) / 64;
    assert(last < plane.len);
    const sign = (plane[last] >> @as(u6, @truncate(lit.width - 1))) & 1;
    const fill = if (extension == .sign) 0 -% sign else 0;
    if (index > last) return fill;
    if (index == last) return (plane[index] & mask(lit.width)) | (fill & ~mask(lit.width));
    return plane[index];
}

/// Clears the bits above `lit.width` in both planes' last declared word:
/// the invariant every operation leaves behind.
pub fn clearPadding(lit: Literal) void {
    const last = wordCount(lit.width) - 1;
    lit.values()[last] &= mask(lit.width);
    lit.unknowns()[last] &= mask(lit.width);
    assert(lit.values()[last] & ~mask(lit.width) == 0);
}

/// Sets every declared bit of `lit` to X.
pub fn fillUnknown(lit: Literal) void {
    @memset(lit.planes, std.math.maxInt(u64));
    clearPadding(lit);
}

/// ORs `source`'s declared bits into `dest` at bit `offset`. The two do not
/// alias; a copy may cross a word boundary, and masking the last source word
/// keeps its padding off the neighbour. Asserts that `source` fits.
pub fn copyBits(dest: Literal, source: Literal, offset: u32) void {
    assert(offset <= dest.width);
    assert(source.width <= dest.width - offset);
    const first: usize = offset / 64;
    const bit_offset: u6 = @truncate(offset);
    const words = wordCount(source.width);
    inline for (.{ false, true }) |unknown| {
        const from = if (unknown) source.unknowns() else source.values();
        const to = if (unknown) dest.unknowns() else dest.values();
        for (from[0..words], 0..) |raw, i| {
            const word = raw & (if (i + 1 == words) mask(source.width) else std.math.maxInt(u64));
            to[first + i] |= word << bit_offset;
            if (bit_offset != 0 and first + i + 1 < to.len)
                to[first + i + 1] |= word >> @as(u6, @intCast(64 - @as(u7, bit_offset)));
        }
    }
}
