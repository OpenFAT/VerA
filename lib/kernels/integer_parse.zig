//! §2.6.1 number literals: one number token's text in, a `Literal` out
//! (`parse`), or the radix its base format names (`radixOf`). Reached as
//! `integer.parse` and `integer.radixOf`.
//! Cites: VAMS §2.6.1; IEEE 1364-2005 §3.5.1 (left truncation of a sized
//! value, x/z fill of a leading x or z digit).
//!
//! Contents:
//! - `pub fn radixOf(text: []const u8) u8`
//! - `pub fn parse(gpa: Allocator, text: []const u8) (Error || Allocator.Error)!Literal`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Big = std.math.big.int.Managed;
const integer = @import("integer.zig");
const words = @import("integer_words.zig");
const Literal = integer.Literal;
const Error = integer.Error;

/// Digits up to which `decimalWords` multiply-accumulates, and the leaf size
/// of its divide and conquer.
const dc_digits: usize = 1024;

/// Returns the §2.6.1 radix `text`'s base format names: 2, 8, 10 or 16, and
/// 10 for a literal without one. `text` is one `parse` accepted.
pub fn radixOf(text: []const u8) u8 {
    const q = std.mem.findScalar(u8, text, '\'') orelse return 10;
    var i = q + 1;
    if (i < text.len and (text[i] == 's' or text[i] == 'S')) i += 1;
    if (i >= text.len) return 10;
    return switch (std.ascii.toLower(text[i])) {
        'b' => 2,
        'o' => 8,
        'h' => 16,
        else => 10,
    };
}

/// Returns one §2.6.1 number token (size, `'`, optional `s`, base, digits;
/// white space allowed around the base) as a `Literal` whose planes come
/// from `gpa`; the caller owns them. A sized value wider than its size is
/// truncated from the left. An unsized literal is at least 64 bits wide and,
/// with no X or Z digit, only as wide as its value needs. A simple decimal
/// number (no base format) is signed (§2.6.1) and gets no extra sign bit, so
/// one of 2^63 or more has its top bit set and reads negative. Fails with
/// `MissingBase` for a `'` with no base letter, `MissingDigits` for no
/// digits, `ZeroSize` for a size of 0, `DigitOutOfRange` for a digit the
/// base does not have (an X/Z digit in a simple decimal, a size with a
/// leading 0) and `Overflow` when the width passes `integer.max_width`;
/// nothing is allocated on any of them. Linear in the digits up to
/// `dc_digits`, O(digits^1.59 log digits) past it.
pub fn parse(gpa: Allocator, text: []const u8) (Error || Allocator.Error)!Literal {
    var digits = text;
    var radix: u8 = 10;
    var width: u32 = 0;
    var sized = false;
    var signed = true;
    if (std.mem.findScalar(u8, text, '\'')) |q| {
        var i = q + 1;
        signed = false;
        if (i < text.len and (text[i] == 's' or text[i] == 'S')) {
            signed = true;
            i += 1;
        }
        if (i >= text.len) return error.MissingBase;
        radix = switch (std.ascii.toLower(text[i])) {
            'b' => 2,
            'o' => 8,
            'd' => 10,
            'h' => 16,
            else => return error.MissingBase,
        };
        digits = std.mem.trimStart(u8, text[i + 1 ..], " \t\r\n\x0c");
        const size_text = std.mem.trim(u8, text[0..q], " \t\r\n\x0c");
        sized = size_text.len != 0;
        for (size_text, 0..) |c, n| {
            if (c == '_' and n != 0) continue;
            if (!std.ascii.isDigit(c)) return error.DigitOutOfRange;
            width = std.math.mul(u32, width, 10) catch return error.Overflow;
            width = std.math.add(u32, width, c - '0') catch return error.Overflow;
        }
        if (sized and width == 0) return error.ZeroSize;
        if (sized and size_text[0] == '0') return error.DigitOutOfRange;
    }
    if (digits.len == 0) return error.MissingDigits;
    if (digits[0] == '_') return error.DigitOutOfRange;
    var count: u32 = 0;
    var any_unknown = false;
    for (digits) |c| {
        if (c == '_') continue;
        count = std.math.add(u32, count, 1) catch return error.Overflow;
        if (c == 'x' or c == 'X' or c == 'z' or c == 'Z' or c == '?') {
            any_unknown = true;
        } else {
            _ = std.fmt.charToDigit(c, radix) catch return error.DigitOutOfRange;
        }
    }
    if (count == 0) return error.MissingDigits;
    if (any_unknown and std.mem.findScalar(u8, text, '\'') == null) return error.DigitOutOfRange;
    if (radix == 10 and any_unknown and count != 1) return error.DigitOutOfRange;
    const shift: u3 = switch (radix) {
        2 => 1,
        8 => 3,
        else => 4,
    };
    if (!sized) {
        // E1019 bounds the width an unsized literal's digits need, checked
        // before the planes exist: x/z digits fill `count * shift` bits, and
        // known ones at least the first significant digit's bit plus `shift`
        // per digit after it (decimal: log2(10) > 3.3219). This lower bound
        // never refuses a literal that fits; the trimmed width is checked
        // again below.
        const least: u64 = if (any_unknown) @as(u64, count) * shift else blk: {
            var significant: u64 = 0;
            for (digits) |c| {
                if (c == '_' or (c == '0' and significant == 0)) continue;
                significant += 1;
            }
            if (significant == 0) break :blk 0;
            break :blk if (radix == 10) (significant - 1) * 33219 / 10000 + 1 else (significant - 1) * shift + 1;
        };
        if (least > integer.max_width) return error.Overflow;
    }
    // Decimal gets an upper bound while accumulating, then loses unused limbs.
    if (!sized) width = @max(64, std.math.mul(u32, count, shift) catch return error.Overflow);
    assert(width >= 1);
    const n_words = (@as(usize, width) + 63) / 64;
    const planes = try gpa.alloc(u64, n_words * 2);
    errdefer gpa.free(planes);
    @memset(planes, 0);
    var literal: Literal = .{ .width = width, .sized = sized, .signed = signed, .planes = planes };
    if (radix == 10 and any_unknown) {
        @memset(literal.unknowns(), std.math.maxInt(u64));
        if (std.ascii.toLower(digits[0]) == 'x') @memset(literal.values(), std.math.maxInt(u64));
    } else if (radix == 10) {
        if (std.mem.findScalar(u8, digits, '_') == null) {
            try decimalWords(gpa, literal.values(), digits);
        } else {
            const plain = try gpa.alloc(u8, count);
            defer gpa.free(plain);
            var n: usize = 0;
            for (digits) |c| if (c != '_') {
                plain[n] = c;
                n += 1;
            };
            assert(n == count);
            try decimalWords(gpa, literal.values(), plain);
        }
    } else {
        placeDigits(literal, digits, radix, shift, count, any_unknown);
    }
    literal.values()[n_words - 1] &= words.mask(width);
    literal.unknowns()[n_words - 1] &= words.mask(width);
    // An unsized known literal needs only its actual bits, with the host
    // integer floor. The planes keep their allocated stride, which need not
    // equal ceil(width/64).
    if (!sized and !any_unknown) {
        var actual: u32 = 0;
        for (literal.values(), 0..) |word, i| {
            if (word != 0) actual = @intCast(i * 64 + 64 - @clz(word));
        }
        literal.width = @max(64, actual);
    }
    assert(literal.width <= width);
    assert(literal.values().len * 64 >= literal.width);
    return literal;
}

// ---- private ----

/// Places a power-of-two radix's `digits` into `literal`'s zeroed planes,
/// each digit's `shift` bits directly, from the least significant digit up:
/// linear in the digits, where shifting the whole value per digit was
/// O(digits * words). Digits above the width are a sized literal's left
/// truncation. A leading x, z or ? fills every bit above the digits
/// (IEEE 1364-2005 §3.5.1).
fn placeDigits(literal: Literal, digits: []const u8, radix: u8, shift: u3, count: u32, any_unknown: bool) void {
    assert(radix == 2 or radix == 8 or radix == 16);
    assert(shift == @ctz(radix));
    const width = literal.width;
    const n_words = literal.values().len;
    var bit: u64 = 0;
    var i = digits.len;
    while (i > 0 and bit < width) {
        i -= 1;
        const c = digits[i];
        if (c == '_') continue;
        const unknown = c == 'x' or c == 'X' or c == 'z' or c == 'Z' or c == '?';
        const group: u64 = (@as(u64, 1) << shift) - 1;
        // `parse` checked every digit against the radix.
        const val: u64 = if (unknown) (if (std.ascii.toLower(c) == 'x') group else 0) else (std.fmt.charToDigit(c, radix) catch unreachable);
        const unk: u64 = if (unknown) group else 0;
        const w: usize = @intCast(bit / 64);
        const off: u6 = @intCast(bit % 64);
        literal.values()[w] |= val << off;
        literal.unknowns()[w] |= unk << off;
        // A group straddling a word boundary spills its high bits.
        if (@as(u64, off) + shift > 64 and w + 1 < n_words) {
            const back: u6 = @intCast(64 - @as(u7, off));
            literal.values()[w + 1] |= val >> back;
            literal.unknowns()[w + 1] |= unk >> back;
        }
        bit += shift;
    }
    if (!any_unknown) return;
    const used = @as(u64, count) * shift;
    const leading = std.ascii.toLower(digits[0]);
    if (used < width and (leading == 'x' or leading == 'z' or leading == '?')) {
        const start: usize = @intCast(used / 64);
        const padding = ~((@as(u64, 1) << @as(u6, @intCast(used % 64))) - 1);
        literal.unknowns()[start] |= padding;
        if (leading == 'x') literal.values()[start] |= padding;
        @memset(literal.unknowns()[start + 1 ..], std.math.maxInt(u64));
        if (leading == 'x') @memset(literal.values()[start + 1 ..], std.math.maxInt(u64));
    }
}

/// The decimal digits `ds` (no `_`) into `out`, little-endian 64-bit words,
/// reduced mod 2^(64 * out.len): the left truncation a sized literal gets.
/// Up to `dc_digits` digits a multiply-accumulate over the words written so
/// far; past it divide and conquer, value = hi * 10^n + lo with n a
/// power-of-two multiple of `dc_digits`, whose products std multiplies by
/// Karatsuba: O(digits^1.59 log digits), where the multiply-accumulate alone
/// is O(digits^2). Temporaries come from `gpa` and are freed.
fn decimalWords(gpa: Allocator, out: []u64, ds: []const u8) Allocator.Error!void {
    assert(out.len >= 1);
    @memset(out, 0);
    if (ds.len <= dc_digits) {
        var used: usize = 0;
        for (ds) |c| {
            var carry: u128 = c - '0';
            for (out[0..used]) |*word| {
                carry += @as(u128, word.*) * 10;
                word.* = @truncate(carry);
                carry >>= 64;
            }
            if (carry != 0 and used < out.len) {
                out[used] = @intCast(carry);
                used += 1;
            }
        }
        assert(used <= out.len);
        return;
    }
    // pows[k] = 10^(dc_digits * 2^k), every k a split of `ds` uses.
    var levels: usize = 0;
    while (dc_digits << @intCast(levels + 1) < ds.len) levels += 1;
    const pows = try gpa.alloc(Big, levels + 1);
    defer gpa.free(pows);
    var made: usize = 0;
    defer for (pows[0..made]) |*p| p.deinit();
    var ten = try Big.initSet(gpa, 10);
    defer ten.deinit();
    pows[0] = try Big.init(gpa);
    made = 1;
    try pows[0].pow(&ten, dc_digits);
    while (made <= levels) : (made += 1) {
        pows[made] = try Big.init(gpa);
        pows[made].mul(&pows[made - 1], &pows[made - 1]) catch |e| {
            pows[made].deinit();
            return e;
        };
    }
    var value = try decimalBig(gpa, ds, pows);
    defer value.deinit();
    const limb_bits = @bitSizeOf(std.math.big.Limb);
    for (value.limbs[0..value.len()], 0..) |limb, i| {
        const bit = i * limb_bits;
        if (bit / 64 >= out.len) break;
        out[bit / 64] |= @as(u64, limb) << @intCast(bit % 64);
    }
}

/// `decimalWords`' divide and conquer: `ds` split above its largest
/// `dc_digits * 2^k` low digits, so `pows[k]` is the shift. Recursion depth
/// is at most `pows.len`, since each split at least halves the high part.
fn decimalBig(gpa: Allocator, ds: []const u8, pows: []const Big) Allocator.Error!Big {
    var r = try Big.init(gpa);
    errdefer r.deinit();
    if (ds.len <= dc_digits) {
        r.setString(10, ds) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidBase, error.InvalidCharacter => unreachable, // `parse` checked every digit
        };
        return r;
    }
    var k: usize = 0;
    while (dc_digits << @intCast(k + 1) < ds.len) k += 1;
    assert(k < pows.len);
    const n = dc_digits << @intCast(k);
    var hi = try decimalBig(gpa, ds[0 .. ds.len - n], pows);
    defer hi.deinit();
    var lo = try decimalBig(gpa, ds[ds.len - n ..], pows);
    defer lo.deinit();
    try r.mul(&hi, &pows[k]);
    try r.add(&r, &lo);
    return r;
}

fn testParseAllocation(allocator: std.mem.Allocator, text: []const u8) !void {
    const v = try parse(allocator, text);
    allocator.free(v.planes);
}

test "decimal literals past the multiply-accumulate size divide and conquer to the same value" {
    // Oracle: the multiply-accumulate path, which `dc_digits` digits or
    // fewer take, over the same words. Lengths straddle the leaf and two
    // split levels; the 1-word output is a sized literal's left truncation.
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x2611);
    const random = prng.random();
    for ([_]usize{ dc_digits + 1, 2 * dc_digits, 2 * dc_digits + 7, 5 * dc_digits + 3 }) |len| {
        const ds = try gpa.alloc(u8, len);
        defer gpa.free(ds);
        for (ds) |*c| c.* = '0' + random.uintLessThan(u8, 10);
        ds[0] = '7';
        for ([_]usize{ 1, len / 19 + 2 }) |word_count| {
            const got = try gpa.alloc(u64, word_count);
            defer gpa.free(got);
            try decimalWords(gpa, got, ds);
            const want = try gpa.alloc(u64, word_count);
            defer gpa.free(want);
            @memset(want, 0);
            var i: usize = 0;
            while (i < len) : (i += 1) {
                var carry: u128 = ds[i] - '0';
                for (want) |*word| {
                    carry += @as(u128, word.*) * 10;
                    word.* = @truncate(carry);
                    carry >>= 64;
                }
            }
            try std.testing.expectEqualSlices(u64, want, got);
        }
    }
}

test "§2.6.1 radixOf reads the base format, and 10 without one" {
    try std.testing.expectEqual(@as(u8, 10), radixOf("9"));
    try std.testing.expectEqual(@as(u8, 10), radixOf("4'd9"));
    try std.testing.expectEqual(@as(u8, 2), radixOf("4'sB1x0z"));
    try std.testing.expectEqual(@as(u8, 8), radixOf("'o17"));
    try std.testing.expectEqual(@as(u8, 16), radixOf("8 'hFF"));
}

test "four-state based literals preserve width, sign, extension and truncation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { source: []const u8, width: u32, value: u64, unknown: u64, signed: bool = false }{
        .{ .source = "3'b01x", .width = 3, .value = 3, .unknown = 1 },
        .{ .source = "12'hX", .width = 12, .value = 0xfff, .unknown = 0xfff },
        .{ .source = "12'hz3", .width = 12, .value = 3, .unknown = 0xff0 },
        .{ .source = "12'h0Z3", .width = 12, .value = 3, .unknown = 0xf0 },
        .{ .source = "8'o?7", .width = 8, .value = 7, .unknown = 0xf8 },
        .{ .source = "8 'sD ?__", .width = 8, .value = 0, .unknown = 255, .signed = true },
        .{ .source = "8'dX", .width = 8, .value = 255, .unknown = 255 },
        .{ .source = "4'hx1", .width = 4, .value = 1, .unknown = 0 },
        .{ .source = "4'shf", .width = 4, .value = 15, .unknown = 0, .signed = true },
        .{ .source = "8'shf", .width = 8, .value = 15, .unknown = 0, .signed = true },
        .{ .source = "'hX", .width = 64, .value = std.math.maxInt(u64), .unknown = std.math.maxInt(u64) },
        .{ .source = "123", .width = 64, .value = 123, .unknown = 0, .signed = true },
        .{ .source = "8'h123456789abcdef0123456789abcdEF", .width = 8, .value = 239, .unknown = 0 },
        .{ .source = "8'd18446744073709551617", .width = 8, .value = 1, .unknown = 0 },
    };
    for (cases) |case| {
        const literal = try parse(arena, case.source);
        try std.testing.expectEqual(case.width, literal.width);
        try std.testing.expectEqual(case.value, literal.values()[0]);
        try std.testing.expectEqual(case.unknown, literal.unknowns()[0]);
        try std.testing.expectEqual(case.signed, literal.signed);
    }
    try std.testing.expectEqual(@as(?i64, -1), (try parse(arena, "4'shf")).asInt());
    try std.testing.expectEqual(@as(?i64, 15), (try parse(arena, "8'shf")).asInt());
    try std.testing.expectEqual(@as(?i64, null), (try parse(arena, "4'hx")).asInt());
}

test "wide literals cross limbs without silently reducing their declared size" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const wide = try parse(arena, "85'hz3");
    try std.testing.expectEqual(@as(u32, 85), wide.width);
    try std.testing.expectEqual(@as(u64, 3), wide.values()[0]);
    try std.testing.expectEqual(@as(u64, 0), wide.values()[1]);
    try std.testing.expectEqual(@as(u64, 0xfffffffffffffff0), wide.unknowns()[0]);
    try std.testing.expectEqual(@as(u64, 0x1fffff), wide.unknowns()[1]);
    const carry = try parse(arena, "128'd18446744073709551617");
    try std.testing.expectEqualSlices(u64, &.{ 1, 1 }, carry.values());
    const unsized = try parse(arena, "'h10000000000000000");
    try std.testing.expectEqual(@as(u32, 65), unsized.width);
    try std.testing.expect(!unsized.sized);
    try std.testing.expectEqualSlices(u64, &.{ 0, 1 }, unsized.values());
    const minimum = try parse(arena, "65536'bx");
    try std.testing.expectEqual(@as(usize, 1024), minimum.values().len);
    for (minimum.values(), minimum.unknowns()) |value, unknown| {
        try std.testing.expectEqual(std.math.maxInt(u64), value);
        try std.testing.expectEqual(value, unknown);
    }
    try std.testing.expectError(error.DigitOutOfRange, parse(arena, "8'd1x"));
    try std.testing.expectError(error.DigitOutOfRange, parse(arena, "8'dxx"));
    try std.testing.expectError(error.DigitOutOfRange, parse(arena, "8'b_1"));
    try std.testing.expectError(error.DigitOutOfRange, parse(arena, "8'b2"));
    try std.testing.expectError(error.ZeroSize, parse(arena, "0'h1"));
    try std.testing.expectError(error.DigitOutOfRange, parse(arena, "08'hff"));
    try std.testing.expectError(error.DigitOutOfRange, parse(arena, "0_8'hff"));
    try std.testing.expectError(error.Overflow, parse(arena, "4294967296'h1"));
    try std.testing.expectEqual(@as(u32, 16777217), (try parse(arena, "16777217'h1")).width);
}

test "parse decodes every base, as the lexer spells the token (§2.6.1)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const val = struct {
        fn f(al: std.mem.Allocator, text: []const u8) !i64 {
            return (try parse(al, text)).asInt().?;
        }
    }.f;
    try std.testing.expectEqual(@as(i64, 27195), try val(a, "27_195"));
    try std.testing.expectEqual(@as(i64, 0x35), try val(a, "16'b0011_0101"));
    try std.testing.expectEqual(@as(i64, 0o7460), try val(a, "12'o7460"));
    try std.testing.expectEqual(@as(i64, 0x12abf001), try val(a, "32'h12ab_f001"));
    try std.testing.expectEqual(@as(i64, 0xaf), try val(a, "8'HAf"));
    // §2.6.1: the size is optional; an unsized based constant is legal.
    try std.testing.expectEqual(@as(i64, 0x837ff), try val(a, "'h837ff"));
    try std.testing.expect(!(try parse(a, "'h837ff")).sized);
    // §2.6.1: a number wider than its size is truncated from the left.
    try std.testing.expectEqual(@as(i64, 0xf), try val(a, "4'h1f"));
    try std.testing.expectEqual(@as(i64, 255), try val(a, "8'hFFFF"));
    // §2.6.1 `s`: truncate to the size first, then read as two's complement.
    try std.testing.expectEqual(@as(i64, -1), try val(a, "4'shf"));
    try std.testing.expectEqual(@as(i64, -8), try val(a, "4'sb1000"));
    try std.testing.expectEqual(@as(i64, 7), try val(a, "4'sd7"));
    try std.testing.expectEqual(@as(i64, -1), try val(a, "8'SHff"));
    try std.testing.expect((try parse(a, "4'shf")).signed);
    // §4.2.13 needs the declared width to reject unsized constants in a concat.
    try std.testing.expectEqual(@as(u32, 4), (try parse(a, "4'shf")).width);
    try std.testing.expect((try parse(a, "4'b01xz")).hasUnknown());
    try std.testing.expectError(error.MissingDigits, parse(a, "4'h"));
    try std.testing.expectError(error.MissingBase, parse(a, "4'"));
    try std.testing.expectError(error.DigitOutOfRange, parse(a, "4'b012"));
    // §2.6.1: "the unsigned number token shall immediately follow the base
    // format, optionally preceded by white space"; four of the clause's five
    // examples are written that way.
    try std.testing.expectEqual(@as(i64, 0xaf), try val(a, "8'h Af"));
    try std.testing.expectEqual(@as(i64, 3), try val(a, "5 'D 3"));
    try std.testing.expectEqual(@as(i64, 0x12abf001), try val(a, "32 'h 12ab_f001"));
    // §10.4 macro substitution can leave white space at both joins (lexer.zig
    // keeps `8 'h A5` one token for that reason).
    try std.testing.expectEqual(@as(i64, 0xa5), try val(a, "8 'h A5"));
    // Syntax 2-2 `size ::= non_zero_unsigned_number`: an explicit 0 is not the
    // unsized form, it is no form at all.
    try std.testing.expectError(error.ZeroSize, parse(a, "0'b1"));
    try std.testing.expectError(error.ZeroSize, parse(a, "0_0'h1"));
}

test "§2.6.1 an unsized literal's width: the 64-bit floor, then its value's bits" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const max = try parse(a, "9223372036854775807");
    try std.testing.expectEqual(@as(u32, 64), max.width);
    try std.testing.expectEqual(@as(?i64, std.math.maxInt(i64)), max.asInt());
    try std.testing.expect(max.signed and !max.sized);
    // 2^64 needs 65 bits.
    const wide = try parse(a, "18446744073709551616");
    try std.testing.expectEqual(@as(u32, 65), wide.width);
    try std.testing.expectEqualSlices(u64, &.{ 0, 1 }, wide.values()[0..2]);
    // A based unsized literal is unsigned unless it says `s`.
    const based = try parse(a, "'h8000_0000_0000_0000");
    try std.testing.expectEqual(@as(u32, 64), based.width);
    try std.testing.expect(!based.signed);
    try std.testing.expectEqual(@as(?i64, std.math.minInt(i64)), based.asInt());
    try std.testing.expect((try parse(a, "'sh1")).signed);
    try std.testing.expectEqual(@as(u32, 64), (try parse(a, "0")).width);
}

test "parse agrees with std.fmt on random sized hex and unsized decimal numbers" {
    // Oracle: std.fmt prints the number and a u128 holds the expected bits.
    // The sized value is truncated from the left (§2.6.1); the decimal one
    // is as wide as its value, never under 64.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(0x2611_2005);
    const random = prng.random();
    var buf: [96]u8 = undefined;
    for (0..2000) |_| {
        _ = arena_state.reset(.retain_capacity);
        const x = random.int(u128) >> random.int(u7);
        const w = random.intRangeAtMost(u32, 1, 128);
        const lit = try parse(arena, try std.mem.print(&buf, "{d}'h{x}", .{ w, x }));
        const want = if (w == 128) x else x & ((@as(u128, 1) << @intCast(w)) - 1);
        const v = lit.values();
        try std.testing.expectEqual(w, lit.width);
        try std.testing.expectEqual(want, @as(u128, v[0]) | (if (v.len > 1) @as(u128, v[1]) << 64 else 0));
        try std.testing.expect(!lit.hasUnknown() and lit.sized and !lit.signed);

        const dec = try parse(arena, try std.mem.print(&buf, "{d}", .{x}));
        const bits: u32 = 128 - @clz(x);
        const dv = dec.values();
        try std.testing.expectEqual(@max(@as(u32, 64), bits), dec.width);
        try std.testing.expectEqual(x, @as(u128, dv[0]) | (if (dv.len > 1) @as(u128, dv[1]) << 64 else 0));
        try std.testing.expect(dec.signed and !dec.sized);
    }
}

test "E1019 is only the u32 width: literals past the old 2^24-bit cap parse, in linear time" {
    const gpa = std.testing.allocator;
    // `'h1` and 4194304 zeros need 4194304 * 4 + 1 bits, one past the old
    // 2^24 cap: bit 2^24 set, every other bit clear.
    const known = try gpa.alloc(u8, 3 + 4194304);
    defer gpa.free(known);
    @memcpy(known[0..3], "'h1");
    @memset(known[3..], '0');
    const k = try parse(gpa, known);
    defer gpa.free(k.planes);
    try std.testing.expectEqual(@as(u32, (1 << 24) + 1), k.width);
    try std.testing.expectEqual(@as(u64, 1), k.values()[(1 << 24) / 64]);
    for (k.values()[0 .. (1 << 24) / 64]) |w| try std.testing.expectEqual(@as(u64, 0), w);
    // X digits fill `count * 4` bits: 4194305 of them, all x.
    const unknown = try gpa.alloc(u8, 2 + 4194305);
    defer gpa.free(unknown);
    @memcpy(unknown[0..2], "'h");
    @memset(unknown[2..], 'x');
    const u = try parse(gpa, unknown);
    defer gpa.free(u.planes);
    try std.testing.expectEqual(@as(u32, 4194305 * 4), u.width);
    const uw = u.unknowns();
    for (uw[0 .. uw.len - 1]) |w| try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), w);
    try std.testing.expectEqual(@as(u64, 0xf), uw[uw.len - 1]);
    // A sized literal past the old cap, and the u32 bound itself.
    const sized = try parse(gpa, "16777217'h1_0");
    defer gpa.free(sized.planes);
    try std.testing.expectEqual(@as(u32, 16777217), sized.width);
    try std.testing.expectEqual(@as(u64, 0x10), sized.values()[0]);
    try std.testing.expectError(error.Overflow, parse(gpa, "4294967296'h0"));
    // Leading zeros need no bits.
    const zeros = try parse(gpa, "'h000000000000000000001");
    defer gpa.free(zeros.planes);
    try std.testing.expectEqual(@as(u32, 64), zeros.width);
}

test "power-of-two radices place digits across word boundaries and truncate from the left" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Octal groups straddle bit 63/64: 23 digits of 7 is 69 ones.
    const o = try parse(arena, "69'o77777777777777777777777");
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), o.values()[0]);
    try std.testing.expectEqual(@as(u64, 0x1f), o.values()[1]);
    // Sized narrower than the digits: the high digits are dropped.
    const t = try parse(arena, "4'hAB");
    try std.testing.expectEqual(@as(u64, 0xB), t.values()[0]);
    // A z digit in octal straddling the boundary: unknown, value 0.
    const z = try parse(arena, "66'oz000000000000000000000");
    try std.testing.expectEqual(@as(u64, 1) << 63, z.unknowns()[0]);
    try std.testing.expectEqual(@as(u64, 0b11), z.unknowns()[1]);
    try std.testing.expectEqual(@as(u64, 0), z.values()[1]);
}

test "parse: a leading x or z fills the size, digits and sizes take `_`, and malformed text names its rule" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Case = struct { []const u8, u32, u64, u64 };
    // §2.6.1: a number whose leftmost digit is x or z is extended with that
    // digit; a known leftmost digit zero-extends.
    for ([_]Case{
        .{ "16'hz1", 16, 0x0001, 0xfff0 },
        .{ "16'hx1", 16, 0xfff1, 0xfff0 },
        .{ "16'h1x", 16, 0x001f, 0x000f },
        .{ "16'h?", 16, 0x0000, 0xffff },
        .{ "1_6'h1", 16, 0x0001, 0x0000 },
        .{ "8'dx_", 8, 0x00ff, 0x00ff },
        .{ "8'dz", 8, 0x0000, 0x00ff },
        .{ "8'b1_0_1", 8, 0x0005, 0x0000 },
        .{ " 8 'h f", 8, 0x000f, 0x0000 },
    }) |c| {
        const lit = try parse(a, c[0]);
        try std.testing.expectEqual(c[1], lit.width);
        try std.testing.expectEqual(c[2], lit.values()[0]);
        try std.testing.expectEqual(c[3], lit.unknowns()[0]);
    }
    try std.testing.expectError(error.DigitOutOfRange, parse(a, "8'h_1"));
    try std.testing.expectError(error.DigitOutOfRange, parse(a, "x"));
    try std.testing.expectError(error.DigitOutOfRange, parse(a, "1 6'h1"));
    try std.testing.expectError(error.DigitOutOfRange, parse(a, "8'o8"));
    try std.testing.expectError(error.DigitOutOfRange, parse(a, "8'hg"));
    try std.testing.expectError(error.MissingBase, parse(a, "4'q1"));
    try std.testing.expectError(error.MissingBase, parse(a, "'"));
    try std.testing.expectError(error.MissingBase, parse(a, "8's"));
    try std.testing.expectError(error.MissingDigits, parse(a, "8'h "));
    try std.testing.expectError(error.MissingDigits, parse(a, ""));
    try std.testing.expectEqual(@as(u8, 10), radixOf("4'sD1"));
    try std.testing.expectEqual(@as(u8, 2), radixOf("'B1"));
    try std.testing.expectEqual(@as(u8, 10), radixOf("8'"));
}

test "parse frees its planes, digit copy and big-integer scratch on every allocation failure" {
    // Past `dc_digits`, with a `_`: the digit copy, then divide and conquer.
    const gpa = std.testing.allocator;
    const text = try gpa.alloc(u8, 2 * dc_digits + 9);
    defer gpa.free(text);
    for (text, 0..) |*c, i| c.* = '1' + @as(u8, @intCast(i % 9));
    text[5] = '_';
    try std.testing.checkAllAllocationFailures(gpa, testParseAllocation, .{text});
}
