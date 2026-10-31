//! Four-state integers (VAMS §2.6.1; IEEE 1364-2005 §5): literal text in, a
//! `Literal` of two packed bit planes out (`parse`), plus the §5.1 operators
//! over them. The planes use the VPI encoding: (value, unknown) = 00/10/11/01
//! for 0/1/X/Z. This file is the type, its accessors and its shape
//! operations (resize, concatenation, replication); the operators live in
//! `integer_logic.zig` and `integer_arith.zig` and the literal reader in
//! `integer_parse.zig`, each reached as a `Literal` method or a decl here.
//! `ref4.zig` is the per-bit reference every operation is held to.
//! Cites: VAMS §2.6.1; IEEE 1364-2005 §5.1.14, §5.1.15, §5.2.1, §5.2.2,
//! §5.5.1, §5.5.2-§5.6.
//!
//! Operand widths are mostly one or two words (a `reg`, an `integer`, a
//! 64-bit `time`), so every word loop here is the plain scalar loop: SIMD
//! pays from a few hundred elements up (simd-loops' triage), far past any
//! real operand.
//!
//! Contents:
//! - `pub const Error = error{ MissingBase, MissingDigits, DigitOutOfRange, ZeroSize, Overflow }`
//! - `pub const ResizeError = error{ZeroSize} || Allocator.Error`
//! - `pub const ConcatError = Allocator.Error || error{ ZeroSize, Overflow }`
//! - `pub const Bit = enum(u2) { zero, one, z, x }`
//! - `pub const Extension = enum(u1) { zero, sign }`
//! - `pub const Bitwise`, `Logical`, `Reduction`, `Equality`, `Shift`, `Relational`, `Arithmetic` (the operator enums)
//! - `pub const Literal = struct` (`values`, `unknowns`, `hasUnknown`, `asInt`, `asExactInt`, `asIndex`, `bit`, `resize`, `concatenate`, `replicate`, and the operators `bitwiseNot`, `bitwise`, `shift`, `relational`, `truth`, `logical`, `reduce`, `equality`, `conditional`, `arithmetic`, `negate`, `power`)
//! - `pub const max_width: u32`
//! - `pub const parse = integer_parse.parse`
//! - `pub const radixOf = integer_parse.radixOf`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const words = @import("integer_words.zig");
const logic = @import("integer_logic.zig");
const arith = @import("integer_arith.zig");
const integer_parse = @import("integer_parse.zig");
const fixture = @import("integer_fixture.zig");

/// Why `parse` refused a literal's text; each member's condition is
/// `parse`'s.
pub const Error = error{ MissingBase, MissingDigits, DigitOutOfRange, ZeroSize, Overflow };
/// Why `Literal.resize` failed: a zero target width, or no memory. Nothing
/// is allocated on either.
pub const ResizeError = error{ZeroSize} || Allocator.Error;
/// Why `Literal.concatenate` or `Literal.replicate` failed: no parts, a
/// zero-width part or a zero count (`ZeroSize`), a width past u32
/// (`Overflow`), both found before allocating, or no memory.
pub const ConcatError = Allocator.Error || error{ ZeroSize, Overflow };

/// One four-state bit; the integer is `value | unknown << 1`.
pub const Bit = enum(u2) { zero = 0, one = 1, z = 2, x = 3 };
/// How `Literal.resize` fills the bits it adds (IEEE 1364-2005 §5.5).
pub const Extension = words.Extension;
/// IEEE 1364-2005 §5.1.10's `&`, `|`, `^` and `~^`, for `Literal.bitwise`.
pub const Bitwise = enum(u2) { and_bits, or_bits, xor_bits, xnor_bits };
/// IEEE 1364-2005 §5.1.9's `&&` and `||`, for `Literal.logical`.
pub const Logical = enum(u1) { and_bits, or_bits };
/// IEEE 1364-2005 §5.1.11's six reductions, for `Literal.reduce`.
pub const Reduction = enum(u3) { and_bits, nand_bits, or_bits, nor_bits, xor_bits, xnor_bits };
/// IEEE 1364-2005 §5.1.8's `==`, `!=`, `===` and `!==`, for `Literal.equality`.
pub const Equality = enum(u2) { equal, not_equal, case_equal, case_not_equal };
/// IEEE 1364-2005 §5.1.12's `<<`, `>>`, `<<<` and `>>>`, for `Literal.shift`.
pub const Shift = enum(u2) { left, right, arithmetic_left, arithmetic_right };
/// IEEE 1364-2005 §5.1.7's four relations, for `Literal.relational`.
pub const Relational = enum(u2) { less, less_equal, greater, greater_equal };
/// IEEE 1364-2005 §5.1.5's binary arithmetic, for `Literal.arithmetic`.
pub const Arithmetic = enum(u3) { add, subtract, multiply, divide, remainder };

/// A four-state integer of any width. Both planes are one allocation, owned
/// by the allocator the producing call was given; free `planes` to release
/// it. Widths share the AST's u32 space; an unsized literal is at least 64
/// bits. Invariants every operation keeps: `width >= 1`, the two planes are
/// equal halves of `planes` holding at least `width` bits, the bits above
/// `width` in each plane's last declared word are zero, and an operation
/// reads only the declared bits of its operands. The result of every
/// allocating operation has its own planes: it never aliases an operand.
pub const Literal = struct {
    /// Declared bits, at least 1.
    width: u32,
    /// Written with a §2.6.1 size; an unsized literal's width is VerA's.
    sized: bool,
    /// Read as two's complement (IEEE 1364-2005 §5.5.1); `parse` sets it for
    /// a `'s` base or a simple decimal (§2.6.1).
    signed: bool,
    /// The value plane then the unknown plane, equal halves.
    planes: []u64,

    // Passed by value through every interpreter operator: one slice, a width
    // and two flags, no padding beyond the slice's alignment.
    comptime {
        assert(@sizeOf(Literal) <= 24);
    }

    /// Returns `~self` (IEEE 1364-2005 Table 5-16; `integer_logic`).
    pub const bitwiseNot = logic.bitwiseNot;
    /// Returns a §5.1.10 bitwise operator's result (`integer_logic`).
    pub const bitwise = logic.bitwise;
    /// Returns a §5.1.12 shift's result (`integer_logic`).
    pub const shift = logic.shift;
    /// Returns a §5.1.7 relation's bit (`integer_logic`).
    pub const relational = logic.relational;
    /// Returns the §5.1.9 truth value (`integer_logic`).
    pub const truth = logic.truth;
    /// Returns `&&` or `||` of two truth values (`integer_logic`).
    pub const logical = logic.logical;
    /// Returns a §5.1.11 reduction's bit (`integer_logic`).
    pub const reduce = logic.reduce;
    /// Returns a §5.1.8 equality's bit (`integer_logic`).
    pub const equality = logic.equality;
    /// Returns `self ? yes : no` (§5.1.13; `integer_logic`).
    pub const conditional = logic.conditional;
    /// Returns a §5.1.5 arithmetic operator's result (`integer_arith`).
    pub const arithmetic = arith.arithmetic;
    /// Returns `-self` (§5.1.5; `integer_arith`).
    pub const negate = arith.negate;
    /// Returns `self ** exponent` (§5.1.5; `integer_arith`).
    pub const power = arith.power;

    /// Returns the value plane, least significant word first. It can be
    /// longer than `width` needs: a `parse`d unsized decimal keeps the words
    /// it reserved, all zero above its value.
    pub fn values(self: Literal) []u64 {
        return self.planes[0 .. self.planes.len / 2];
    }

    /// Returns the unknown plane, laid out as `values`; a set bit is X or Z.
    pub fn unknowns(self: Literal) []u64 {
        return self.planes[self.planes.len / 2 ..];
    }

    /// Returns whether any bit is X or Z.
    pub fn hasUnknown(self: Literal) bool {
        return !std.mem.allEqual(u64, self.unknowns(), 0);
    }

    /// Returns the value as an i64, sign-extended when `signed`. Null when
    /// the literal is wider than 64 bits or holds an X or Z bit. A 64-bit
    /// unsigned value comes back as its bit pattern, negative from 2^63 up:
    /// the i64 is the carrier the analog integer path reads, not a numeric
    /// conversion.
    pub fn asInt(self: Literal) ?i64 {
        assert(self.width >= 1);
        if (self.width > 64 or self.hasUnknown()) return null;
        var bits = self.values()[0];
        if (self.signed and self.width < 64 and bits & (@as(u64, 1) << @intCast(self.width - 1)) != 0)
            bits |= ~words.mask(self.width);
        return @bitCast(bits);
    }

    /// Returns the value as an i64 at any width: `asInt` up to 64 bits, and
    /// a wider literal when every bit above bit 63 repeats bit 63 (signed) or
    /// is 0 with bit 63 clear (unsigned), so its numeric value is the i64's.
    /// Null on an X or Z bit.
    pub fn asExactInt(self: Literal) ?i64 {
        if (self.width <= 64) return self.asInt();
        if (self.hasUnknown()) return null;
        // Declared words only: a `parse`d unsized decimal reserves spare
        // zero words past them, which a negative value does not fill.
        const declared = self.values()[0..words.wordCount(self.width)];
        assert(declared.len >= 2);
        const low: i64 = @bitCast(declared[0]);
        if (low < 0 and !self.signed) return null;
        const fill: u64 = if (low < 0) std.math.maxInt(u64) else 0;
        const last = declared.len - 1;
        for (declared[1..], 1..) |word, i| {
            if (word != if (i == last) fill & words.mask(self.width) else fill) return null;
        }
        return low;
    }

    /// Returns the value as a self-determined address (§5.2.1/§5.2.2), null
    /// on any X/Z bit. Values beyond i64 are kept so a part-select based
    /// just outside a declaration can still overlap it; beyond i128 the
    /// result saturates to maxInt(i128) or minInt(i128) by sign, since such
    /// a value cannot overlap an i64 declaration with a u32 select width.
    pub fn asIndex(self: Literal) ?i128 {
        if (self.hasUnknown()) return null;
        const negative = self.signed and self.bit(self.width - 1) == .one;
        const fill: u64 = if (negative) std.math.maxInt(u64) else 0;
        const outside: i128 = if (negative) std.math.minInt(i128) else std.math.maxInt(i128);
        const v = self.values()[0..words.wordCount(self.width)];
        var bits: u128 = v[0];
        if (self.width > 64) bits |= @as(u128, v[1]) << 64;
        if (self.width < 128 and negative) bits |= @as(u128, std.math.maxInt(u128)) << @intCast(self.width);
        if (self.width > 128) {
            for (v[2..], 2..) |word, i| {
                if (word != if (i == v.len - 1) fill & words.mask(self.width) else fill) return outside;
            }
        }
        const result: i128 = @bitCast(bits);
        return if ((result < 0) == negative) result else outside;
    }

    /// Returns bit `index`, bit zero least significant. Asserts that
    /// `index < width`.
    pub fn bit(self: Literal, index: u32) Bit {
        assert(index < self.width);
        const bit_offset: u6 = @truncate(index);
        const word_index = index / 64;
        assert(word_index < self.values().len);
        return @fromBackingInt(@intCast(@as(u2, @intCast((self.values()[word_index] >> bit_offset) & 1)) |
            (@as(u2, @intCast((self.unknowns()[word_index] >> bit_offset) & 1)) << 1)));
    }

    /// Returns a copy at `width` bits (IEEE 1364-2005 §§5.5.2 to 5.6), the
    /// added bits filled by `extension`, which the evaluator supplies from
    /// the propagated type. Signed extension replicates X and Z too. Keeps
    /// the source's signedness: converting the type is a separate evaluator
    /// step. Caller owns the result's planes and frees them with `gpa`.
    pub fn resize(self: Literal, gpa: Allocator, width: u32, extension: Extension) ResizeError!Literal {
        if (width == 0) return error.ZeroSize;
        const out = try words.allocate(gpa, width, self.signed);
        for (out.values(), out.unknowns(), 0..) |*v, *u, i| {
            v.* = words.extendedWord(self, self.values(), i, extension);
            u.* = words.extendedWord(self, self.unknowns(), i, extension);
        }
        words.clearPadding(out);
        assert(out.width == width);
        return out;
    }

    /// Returns self-determined operands joined, leftmost at the most
    /// significant end (IEEE 1364-2005 §5.1.14), unsigned. Caller owns its
    /// planes and frees them with `gpa`. `ZeroSize` for no parts or a
    /// zero-width part, `Overflow` when the widths sum past u32, both before
    /// allocating.
    pub fn concatenate(gpa: Allocator, parts: []const Literal) ConcatError!Literal {
        var width: u32 = 0;
        for (parts) |part| {
            if (part.width == 0) return error.ZeroSize;
            width = std.math.add(u32, width, part.width) catch return error.Overflow;
        }
        if (width == 0) return error.ZeroSize;
        const out = try words.allocate(gpa, width, false);
        @memset(out.planes, 0);
        var offset = width;
        for (parts) |part| {
            offset -= part.width;
            words.copyBits(out, part, offset);
        }
        assert(offset == 0);
        return out;
    }

    /// Returns an evaluated operand repeated `count` times (IEEE 1364-2005
    /// §5.1.15), unsigned; caller owns its planes and frees them with `gpa`.
    /// Zero replication is a source-level exception inside a larger concat
    /// and never makes a zero-width literal: `count == 0` is `ZeroSize`, and
    /// a width past u32 `Overflow`, both before allocating.
    pub fn replicate(self: Literal, gpa: Allocator, count: u32) ConcatError!Literal {
        if (self.width == 0 or count == 0) return error.ZeroSize;
        const width = std.math.mul(u32, self.width, count) catch return error.Overflow;
        const out = try words.allocate(gpa, width, false);
        @memset(out.planes, 0);
        for (0..count) |i| words.copyBits(out, self, @as(u32, @intCast(i)) * self.width);
        assert(out.width == width);
        return out;
    }
};

/// The widest a number literal may be (E1019), by its size or, unsized, by
/// the width its digits need: the largest a `Literal.width` (u32, as every
/// stage carries a width) can hold. Not a policy bound: a literal of this
/// width allocates 1 GiB of planes, so memory runs out first.
pub const max_width: u32 = std.math.maxInt(u32);

/// §2.6.1's literal reader (`integer_parse.parse`).
pub const parse = integer_parse.parse;
/// §2.6.1's radix of a literal's text (`integer_parse.radixOf`).
pub const radixOf = integer_parse.radixOf;

comptime {
    assert(@bitSizeOf(Bit) == 2);
    assert(@backingInt(Bit.x) == 3); // value and unknown set: the VPI's X
}

// ---- private ----

fn testConcatOracle(allocator: std.mem.Allocator, parts: []const Literal, count: u32) !void {
    var bits: std.ArrayList(Bit) = .empty;
    defer bits.deinit(allocator);
    // Independent scalar oracle stores logical bits instead of packed words.
    for (0..count) |_| {
        var part = parts.len;
        while (part != 0) {
            part -= 1;
            for (0..parts[part].width) |i| try bits.append(allocator, parts[part].bit(@intCast(i)));
        }
    }
    const joined = try Literal.concatenate(allocator, parts);
    defer allocator.free(joined.planes);
    const result = try joined.replicate(allocator, count);
    defer allocator.free(result.planes);
    try std.testing.expect(!joined.signed and !result.signed);
    try std.testing.expectEqual(bits.items.len, result.width);
    for (bits.items, 0..) |bit, i| try std.testing.expectEqual(bit, result.bit(@intCast(i)));
    const last = words.wordCount(result.width) - 1;
    try std.testing.expectEqual(@as(u64, 0), (result.values()[last] | result.unknowns()[last]) & ~words.mask(result.width));
}

fn testConcatAllocation(allocator: std.mem.Allocator) !void {
    const a = try parse(allocator, "65'b10xz");
    defer allocator.free(a.planes);
    const b = try parse(allocator, "129'shfedcba98765432100123456789abcdef0");
    defer allocator.free(b.planes);
    const joined = try Literal.concatenate(allocator, &.{ a, b, a });
    defer allocator.free(joined.planes);
    const repeated = try joined.replicate(allocator, 3);
    defer allocator.free(repeated.planes);
}

fn testOneAllocation(allocator: std.mem.Allocator) !void {
    const a = try parse(allocator, "70'sh2f_0123_4567_89ab_cdef");
    defer allocator.free(a.planes);
    const count = try parse(allocator, "7'd3");
    defer allocator.free(count.planes);
    const inverted = try a.bitwiseNot(allocator);
    defer allocator.free(inverted.planes);
    const xor = try a.bitwise(allocator, .xor_bits, count);
    defer allocator.free(xor.planes);
    const wide = try a.resize(allocator, 130, .sign);
    defer allocator.free(wide.planes);
    const shifted = try a.shift(allocator, .arithmetic_right, count);
    defer allocator.free(shifted.planes);
    const merged = try count.conditional(allocator, a, count);
    defer allocator.free(merged.planes);
}

test "resize preserves four-state sign bits and masks truncation at word boundaries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]u32{ 1, 31, 32, 63, 64, 65, 127, 128, 129 }) |width| {
        for (fixture.truth_states) |sign| {
            const a = try words.allocate(arena, width, true);
            @memset(a.planes, 0);
            fixture.testPut(a, width - 1, sign);
            const extended = try a.resize(arena, width + 130, .sign);
            const unsigned = try a.resize(arena, width + 130, .zero);
            for (0..width + 130) |i| {
                const index: u32 = @intCast(i);
                try std.testing.expectEqual(if (i < width) a.bit(index) else sign, extended.bit(index));
                try std.testing.expectEqual(if (i < width) a.bit(index) else Bit.zero, unsigned.bit(index));
            }
            const truncated = try extended.resize(arena, width, .zero);
            try std.testing.expectEqualSlices(u64, a.planes, truncated.planes);
            try std.testing.expect(extended.signed);
        }
    }
    const signed = try parse(arena, "4'sb10xz");
    const allones = try parse(arena, "8'shff");
    const signed_result = try signed.bitwise(arena, .and_bits, allones);
    try std.testing.expectEqual(Bit.one, signed_result.bit(7));
    try std.testing.expect(signed_result.signed);
    var unsigned = allones;
    unsigned.signed = false;
    const unsigned_result = try signed.bitwise(arena, .and_bits, unsigned);
    try std.testing.expectEqual(Bit.zero, unsigned_result.bit(7));
    try std.testing.expect(!unsigned_result.signed);
    const short_minus_one = try parse(arena, "4'shf");
    try std.testing.expectEqual(Bit.one, short_minus_one.equality(.case_equal, allones));
    try std.testing.expectEqual(Bit.zero, short_minus_one.equality(.case_equal, unsigned));
    var condition_storage: [2]u64 = undefined;
    const condition = fixture.testScalar(&condition_storage, .x);
    const long_positive = try parse(arena, "8'sh0f");
    // Table 5-22 and §5.5.2 normalize signed arms before §5.1.13 merging.
    const signed_merge = try condition.conditional(arena, short_minus_one, long_positive);
    try std.testing.expectEqualSlices(u64, &.{ 255, 240 }, signed_merge.planes);
    try std.testing.expect(signed_merge.signed);
    var short_unsigned = short_minus_one;
    short_unsigned.signed = false;
    const unsigned_merge = try condition.conditional(arena, short_unsigned, long_positive);
    try std.testing.expectEqualSlices(u64, &.{ 15, 0 }, unsigned_merge.planes);
    try std.testing.expect(!unsigned_merge.signed);
    try std.testing.expectError(error.ZeroSize, signed.resize(arena, 0, .zero));
    // Unsized decimal parse reserves more words than its final logical width.
    const spare = try parse(arena, "000000000000000000000000000000000000000000001");
    try std.testing.expect(spare.values().len > words.wordCount(spare.width));
    const compact = try spare.resize(arena, 65, .zero);
    try std.testing.expectEqualSlices(u64, &.{ 1, 0 }, compact.values());
    try std.testing.expectEqual(Bit.one, spare.equality(.equal, compact));
}

test "concatenation and replication match a scalar bit oracle" {
    const allocator = std.testing.allocator;
    var a_planes: [2]u64 = undefined;
    var b_planes: [2]u64 = undefined;
    for (1..4) |aw| for (1..4) |bw| {
        for (0..@as(usize, 1) << @intCast(2 * aw)) |ap| {
            const a = fixture.testPattern(&a_planes, @intCast(aw), true, ap);
            for (0..@as(usize, 1) << @intCast(2 * bw)) |bp| {
                const b = fixture.testPattern(&b_planes, @intCast(bw), true, bp);
                try testConcatOracle(allocator, &.{ a, b }, 2);
            }
        }
    };
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts: [8]Literal = undefined;
    for ([_]u32{ 1, 63, 64, 65, 127, 128, 129, 257 }, 0..) |width, n| {
        const part = try words.allocate(arena, width, n % 2 == 0);
        @memset(part.planes, 0);
        for (0..width) |i| fixture.testPut(part, @intCast(i), @fromBackingInt(@intCast((i * 7 + n) % 4)));
        parts[n] = part;
    }
    for ([_]u32{ 1, 2, 3, 17 }) |count| try testConcatOracle(allocator, &parts, count);
    var dirty_planes = [_]u64{ ~@as(u64, 7) | 5, 77, ~@as(u64, 7) | 2, 88 };
    const saved = dirty_planes;
    const dirty: Literal = .{ .width = 3, .signed = true, .sized = true, .planes = &dirty_planes };
    try testConcatOracle(allocator, &.{ parts[2], dirty, parts[4] }, 3);
    try std.testing.expectEqualSlices(u64, &saved, &dirty_planes);
}

test "concatenation widths fail before allocating or truncating" {
    const allocator = std.testing.allocator;
    const wide: Literal = .{ .width = std.math.maxInt(u32), .signed = false, .sized = true, .planes = &.{} };
    const one: Literal = .{ .width = 1, .signed = false, .sized = true, .planes = &.{} };
    try std.testing.expectError(error.Overflow, Literal.concatenate(allocator, &.{ wide, one }));
    try std.testing.expectError(error.Overflow, wide.replicate(allocator, 2));
    try std.testing.expectError(error.ZeroSize, Literal.concatenate(allocator, &.{}));
    try std.testing.expectError(error.ZeroSize, one.replicate(allocator, 0));
}

test "concatenation allocation failures release input and result storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testConcatAllocation, .{});
}

test "asExactInt: a wide two-state literal is an integer only when an i64 holds its value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(?i64, 1), (try parse(a, "128'h1")).asExactInt());
    try std.testing.expectEqual(@as(?i64, -2), (try parse(a, "100'shF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFE")).asExactInt());
    try std.testing.expectEqual(@as(?i64, null), (try parse(a, "128'h1_0000_0000_0000_0000")).asExactInt());
    try std.testing.expectEqual(@as(?i64, null), (try parse(a, "128'h8000_0000_0000_0000")).asExactInt());
    try std.testing.expectEqual(@as(?i64, null), (try parse(a, "128'hx")).asExactInt());
}

test "asInt hands a 64-bit unsigned value back as its bit pattern, and asExactInt is asInt up to 64 bits" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const top = try parse(a, "64'h8000_0000_0000_0000");
    try std.testing.expectEqual(@as(?i64, std.math.minInt(i64)), top.asInt());
    try std.testing.expectEqual(@as(?i64, std.math.minInt(i64)), top.asExactInt());
    try std.testing.expectEqual(@as(?i64, -1), (try parse(a, "64'hFFFF_FFFF_FFFF_FFFF")).asInt());
    // Below 64 bits only a signed value is sign-extended.
    try std.testing.expectEqual(@as(?i64, 255), (try parse(a, "8'hff")).asInt());
    try std.testing.expectEqual(@as(?i64, -1), (try parse(a, "8'shff")).asInt());
    try std.testing.expectEqual(@as(?i64, -1), (try parse(a, "1'sb1")).asInt());
    try std.testing.expectEqual(@as(?i64, null), (try parse(a, "65'h1")).asInt());
    // 65 bits: a signed -1 repeats bit 63 into bit 64; 2^64 has no i64.
    try std.testing.expectEqual(@as(?i64, -1), (try parse(a, "65'sh1_FFFF_FFFF_FFFF_FFFF")).asExactInt());
    try std.testing.expectEqual(@as(?i64, null), (try parse(a, "65'h1_0000_0000_0000_0000")).asExactInt());
    try std.testing.expectEqual(@as(?i64, 5), (try parse(a, "65'h5")).asExactInt());
    // A signed 65-bit value whose bit 64 disagrees with bit 63 is out of range.
    try std.testing.expectEqual(@as(?i64, null), (try parse(a, "65'sh0_8000_0000_0000_0000")).asExactInt());
}

test "asIndex keeps values past i64 and saturates past i128 by sign" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqual(@as(?i128, -1), (try parse(a, "3'sb111")).asIndex());
    try std.testing.expectEqual(@as(?i128, 7), (try parse(a, "3'b111")).asIndex());
    try std.testing.expectEqual(@as(?i128, null), (try parse(a, "3'b1x1")).asIndex());
    try std.testing.expectEqual(@as(?i128, null), (try parse(a, "3'b1z1")).asIndex());
    // 2^64 has no i64 and is kept.
    try std.testing.expectEqual(@as(?i128, 1 << 64), (try parse(a, "80'h1_0000_0000_0000_0000")).asIndex());
    // 128 ones: unsigned 2^128-1 is past i128 and saturates high; signed it is -1.
    try std.testing.expectEqual(@as(?i128, std.math.maxInt(i128)), (try parse(a, "128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF")).asIndex());
    try std.testing.expectEqual(@as(?i128, -1), (try parse(a, "128'shFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF")).asIndex());
    // -2^128 (a 129-bit signed minimum) is below i128 and saturates low.
    try std.testing.expectEqual(@as(?i128, std.math.minInt(i128)), (try parse(a, "129'sh1_0000_0000_0000_0000_0000_0000_0000_0000")).asIndex());
    // Wider than 128 bits with zero (or, negative, all-ones) high words fits;
    // a set bit at 128 does not.
    try std.testing.expectEqual(@as(?i128, 5), (try parse(a, "200'h5")).asIndex());
    try std.testing.expectEqual(@as(?i128, -5), (try (try parse(a, "8'shfb")).resize(a, 200, .sign)).asIndex());
    try std.testing.expectEqual(@as(?i128, std.math.maxInt(i128)), (try parse(a, "200'h1_0000_0000_0000_0000_0000_0000_0000_0000")).asIndex());
}

test "asIndex/asExactInt read only the declared words of an unsized decimal" {
    // 2^129 - 1 is 129 one bits, a signed -1. Leading zeros make `parse`
    // reserve a fourth word past the value's three; its zeros are not data.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for ([_][]const u8{ "680564733841876926926749214863536422911", "00000000000000000000680564733841876926926749214863536422911" }) |text| {
        const v = try parse(a, text);
        try std.testing.expectEqual(@as(u32, 129), v.width);
        try std.testing.expectEqual(@as(?i128, -1), v.asIndex());
        try std.testing.expectEqual(@as(?i64, -1), v.asExactInt());
    }
}

test "an allocation failure in a one-allocation operation leaks nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testOneAllocation, .{});
}
