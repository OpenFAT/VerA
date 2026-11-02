//! `kernels.Integer`, the four-state literal reference, through its public
//! face: §2.6.1 literal text in (`parse`, `radixOf`), `Literal`'s accessors
//! (`asInt`, `asExactInt`, `asIndex`), shape operations (`resize`,
//! `concatenate`, `replicate`) and IEEE 1364-2005 §5 operators out. The
//! oracles: §2.6.1's and §5.1's rules worked by hand per literal; std.fmt
//! printing the number `parse` must read back; a per-bit shift reference
//! (`testShiftBit`); `std.testing.checkAllAllocationFailures` for every
//! release path. Tests that build operands from the private word layer
//! (`integer_words.zig`, `integer_fixture.zig`) or call a private path
//! (`arithmeticIn`, `decimalWords`) stay beside lib/kernels/integer*.zig,
//! with `ref4.zig` as the per-bit judge.

const std = @import("std");
const integer = @import("kernels").Integer;
const Literal = integer.Literal;
const Bit = integer.Bit;
const Shift = integer.Shift;
const Arithmetic = integer.Arithmetic;
const parse = integer.parse;
const radixOf = integer.radixOf;

// ---- private ----

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

fn testArithmeticAllocation(allocator: std.mem.Allocator) !void {
    const a = try integer.parse(allocator, "257'sh1fedcba9876543210fedcba98765432100123456789abcdef0123456789abcdef0");
    defer allocator.free(a.planes);
    const b = try integer.parse(allocator, "129'sh1fedcba98765432100123456789abcdef0");
    defer allocator.free(b.planes);
    for (std.enums.values(Arithmetic)) |op| {
        const result = try a.arithmetic(allocator, op, b);
        allocator.free(result.planes);
    }
    const negated = try a.negate(allocator);
    allocator.free(negated.planes);
}

fn testPowerAllocation(allocator: std.mem.Allocator) !void {
    const a = try integer.parse(allocator, "129'h100000000000000000000000000000003");
    defer allocator.free(a.planes);
    const b = try integer.parse(allocator, "65'd17");
    defer allocator.free(b.planes);
    const result = try a.power(allocator, b);
    defer allocator.free(result.planes);
}

fn testShiftBit(value: Literal, op: Shift, count: u64, index: u32) Bit {
    return switch (op) {
        .left, .arithmetic_left => if (count <= index) value.bit(index - @as(u32, @intCast(count))) else .zero,
        .right, .arithmetic_right => if (count < value.width - index)
            value.bit(index + @as(u32, @intCast(count)))
        else if (op == .arithmetic_right and value.signed)
            value.bit(value.width - 1)
        else
            .zero,
    };
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

test "packed arithmetic frees partial allocations on every failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testArithmeticAllocation, .{});
}

test "packed power allocation failures release every intermediate" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testPowerAllocation, .{});
}

test "shift count is unsigned self-determined and never truncated" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try integer.parse(arena, "129'sh1abcd56780000000000000000a5f0zx10");
    const original = try arena.dupe(u64, source.planes);
    for ([_][]const u8{ "65'h10000000000000000", "128'h80000000000000000000000000000000", "64'shffffffffffffffff" }) |text| {
        const count = try integer.parse(arena, text);
        inline for (std.meta.tags(Shift)) |op| {
            const out = try source.shift(arena, op, count);
            for (0..source.width) |index|
                try std.testing.expectEqual(if (op == .arithmetic_right) source.bit(source.width - 1) else Bit.zero, out.bit(@intCast(index)));
        }
    }
    for ([_][]const u8{ "129'hx00000000000000000000000000000000", "129'hz00000000000000000000000000000000", "4'b00x0", "4'b00z0" }) |text| {
        const count = try integer.parse(arena, text);
        inline for (std.meta.tags(Shift)) |op| {
            const out = try source.shift(arena, op, count);
            for (0..source.width) |index| try std.testing.expectEqual(Bit.x, out.bit(@intCast(index)));
        }
    }
    // A signed four-bit -1 is an unsigned shift count of 15, not 2^64-1.
    const fifteen = try integer.parse(arena, "4'shf");
    const shifted = try source.shift(arena, .left, fifteen);
    for (0..source.width) |index|
        try std.testing.expectEqual(testShiftBit(source, .left, 15, @intCast(index)), shifted.bit(@intCast(index)));
    const one = try integer.parse(arena, "1'b1");
    const negative = try integer.parse(arena, "4'sb1000");
    const normalized = try negative.resize(arena, 8, .sign);
    const arithmetic = try normalized.shift(arena, .arithmetic_right, one);
    try std.testing.expectEqualSlices(u64, &.{ 0xfc, 0 }, arithmetic.planes);
    var unsigned_context = try negative.resize(arena, 8, .zero);
    unsigned_context.signed = false;
    const zero_filled = try unsigned_context.shift(arena, .arithmetic_right, one);
    try std.testing.expectEqualSlices(u64, &.{ 4, 0 }, zero_filled.planes);
    for ([_][]const u8{ "1'sbx", "1'sbz" }) |text| {
        const sign = try integer.parse(arena, text);
        const out = try sign.shift(arena, .arithmetic_right, fifteen);
        try std.testing.expectEqual(sign.bit(0), out.bit(0));
    }
    const spare_count = try integer.parse(arena, "000000000000000000000000000000000000000000001");
    const small_shift = try negative.shift(arena, .left, spare_count);
    try std.testing.expectEqualSlices(u64, &.{ 0, 0 }, small_shift.planes);
    try std.testing.expectEqualSlices(u64, original, source.planes);
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
