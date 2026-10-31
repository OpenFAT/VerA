//! Test support for `integer*.zig`'s tests: a four-state bit pattern in, a
//! `Literal` over caller storage out, and the scalar decoding the operators'
//! oracles read back. Not re-exported by `root.zig`; only the integer files'
//! `test` blocks import it.
//! Cites: IEEE 1364-2005 §5.1 (the 0/1/X/Z encoding).
//!
//! Contents:
//! - `pub const truth_states: [4]Bit`
//! - `pub fn testScalar(storage: *[2]u64, state: Bit) Literal`
//! - `pub fn testPut(value: Literal, index: u32, state: Bit) void`
//! - `pub fn testPattern(storage: *[2]u64, width: u32, signed: bool, pattern: usize) Literal`
//! - `pub fn testNumber(value: Literal, signed: bool) ?i32`

const std = @import("std");
const integer = @import("integer.zig");
const Literal = integer.Literal;
const Bit = integer.Bit;

/// Every bit state, in 0/1/X/Z order: the index the truth tables use.
pub const truth_states = [_]Bit{ .zero, .one, .x, .z };

/// Returns a 1-bit literal holding `state`, over `storage`.
pub fn testScalar(storage: *[2]u64, state: Bit) Literal {
    storage.* = .{ @backingInt(state) & 1, @backingInt(state) >> 1 };
    return .{ .width = 1, .signed = false, .sized = true, .planes = storage };
}

/// Sets bit `index` of `value` to `state`, in place.
pub fn testPut(value: Literal, index: u32, state: Bit) void {
    const bit_mask = @as(u64, 1) << @as(u6, @truncate(index));
    const word = index / 64;
    value.values()[word] = (value.values()[word] & ~bit_mask) | (if (@backingInt(state) & 1 != 0) bit_mask else 0);
    value.unknowns()[word] = (value.unknowns()[word] & ~bit_mask) | (if (@backingInt(state) & 2 != 0) bit_mask else 0);
}

/// Returns a `width`-bit literal (width <= 32) over `storage` whose bit i is state `(pattern >> 2i) & 3`.
pub fn testPattern(storage: *[2]u64, width: u32, signed: bool, pattern: usize) Literal {
    storage.* = .{ 0, 0 };
    const out: Literal = .{ .width = width, .sized = true, .signed = signed, .planes = storage };
    for (0..width) |i|
        testPut(out, @intCast(i), truth_states[(pattern >> @as(u6, @intCast(i * 2))) & 3]);
    return out;
}

/// Returns `value` decoded bit by bit as a mathematical integer, null on an X or Z bit.
pub fn testNumber(value: Literal, signed: bool) ?i32 {
    var out: i32 = 0;
    for (0..value.width) |i| switch (value.bit(@intCast(i))) {
        .zero => {},
        .one => out += @as(i32, 1) << @intCast(i),
        .x, .z => return null,
    };
    if (signed and value.bit(value.width - 1) == .one)
        out -= @as(i32, 1) << @intCast(value.width);
    return out;
}
