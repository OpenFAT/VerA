//! IEEE 1364-2005 §5.1.5's four-state arithmetic over `Literal`s: operands
//! in, the wrapped result literal out (`+ - * / %`, unary `-`, `**`), each
//! reached as a `Literal` method (`integer.zig`). A result of at most 64 bits
//! is one machine word; a wider one goes through `std.math.big`, which is
//! also the oracle the word path is tested against. Every result is fresh
//! planes from the call's `gpa`, owned by the caller; a failed allocation
//! frees every intermediate.
//! Cites: IEEE 1364-2005 §5.1.5 (Tables 5-6 and 5-8), §5.4, §5.5.
//!
//! Contents:
//! - `pub fn arithmetic(self: Literal, gpa: Allocator, op: Arithmetic, rhs: Literal) Allocator.Error!Literal`
//! - `pub fn negate(self: Literal, gpa: Allocator) Allocator.Error!Literal`
//! - `pub fn power(self: Literal, gpa: Allocator, exponent: Literal) Allocator.Error!Literal`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Big = std.math.big.int.Managed;
const integer = @import("integer.zig");
const words = @import("integer_words.zig");
const Literal = integer.Literal;
const Arithmetic = integer.Arithmetic;
const Bit = integer.Bit;
const Extension = words.Extension;
const fixture = @import("integer_fixture.zig");

/// Returns an arithmetic operator applied (IEEE 1364-2005 §§5.1.5, 5.4,
/// 5.5) at max(operand widths), signed iff both operands are; that common
/// type controls the operands' extension. The caller propagates any outer
/// width and type first. Results wrap at the width; an X/Z in either
/// operand and a division or remainder by zero give all X. Signed division
/// truncates toward zero and the remainder has the dividend's sign. Caller
/// owns the result's planes and frees them with `gpa`.
pub fn arithmetic(self: Literal, gpa: Allocator, op: Arithmetic, rhs: Literal) Allocator.Error!Literal {
    return arithmeticIn(self, gpa, op, rhs, @max(self.width, rhs.width) <= 64);
}

/// Returns `-self` at the operand's width and signedness, wrapping at the
/// most negative value; any X/Z bit makes the whole result X. Caller owns
/// the result's planes and frees them with `gpa`.
pub fn negate(self: Literal, gpa: Allocator) Allocator.Error!Literal {
    return negateIn(self, gpa, self.width <= 64);
}

/// Returns `self ** exponent` (IEEE 1364-2005 §5.1.5, Tables 5-6 and 5-8).
/// The caller propagates the result context to the base first; the exponent
/// keeps its own size and signedness. Results wrap at the base width. Any
/// declared X/Z bit gives all X, an unknown base raised to zero included.
/// O(exponent bits) multiplications at the base width. Caller owns the
/// result's planes and frees them with `gpa`.
pub fn power(self: Literal, gpa: Allocator, exponent: Literal) Allocator.Error!Literal {
    return powerIn(self, gpa, exponent, self.width <= 64);
}

// ---- private ----

/// `arithmetic` with its path chosen: `one_word` computes a result of at
/// most 64 bits in one machine word (wrapping at the width is arithmetic mod
/// 2^width, a wrapping u64 op then the mask; operands extended to 64 bits by
/// the common signedness are exactly their values, all divide and remainder
/// read); otherwise `std.math.big`'s exact integers, at any width.
fn arithmeticIn(self: Literal, gpa: Allocator, op: Arithmetic, rhs: Literal, one_word: bool) Allocator.Error!Literal {
    if (one_word) assert(@max(self.width, rhs.width) <= 64);
    const signed = self.signed and rhs.signed;
    const out = try words.allocate(gpa, @max(self.width, rhs.width), signed);
    errdefer gpa.free(out.planes);
    // The reduction masks padding and spare capacity outside the declared bits.
    if (self.reduce(.xor_bits) == .x or rhs.reduce(.xor_bits) == .x) {
        words.fillUnknown(out);
        return out;
    }
    if (one_word) {
        const extension: Extension = if (signed) .sign else .zero;
        const a = words.extendedWord(self, self.values(), 0, extension);
        const b = words.extendedWord(rhs, rhs.values(), 0, extension);
        if ((op == .divide or op == .remainder) and b == 0) {
            words.fillUnknown(out);
            return out;
        }
        out.values()[0] = switch (op) {
            .add => a +% b,
            .subtract => a -% b,
            .multiply => a *% b,
            .divide, .remainder => if (!signed)
                (if (op == .divide) a / b else a % b)
            else if (b == std.math.maxInt(u64))
                // x / -1 is -x, wrapping at the most negative value (the one
                // quotient an i64 divide would trap on); x % -1 is 0.
                (if (op == .divide) 0 -% a else 0)
            else
                @bitCast(if (op == .divide) @divTrunc(@as(i64, @bitCast(a)), @as(i64, @bitCast(b))) else @rem(@as(i64, @bitCast(a)), @as(i64, @bitCast(b)))),
        };
        out.unknowns()[0] = 0;
        words.clearPadding(out);
        return out;
    }
    var a = try arithmeticValue(self, gpa, signed);
    defer a.deinit();
    var b = try arithmeticValue(rhs, gpa, signed);
    defer b.deinit();
    if ((op == .divide or op == .remainder) and b.toConst().eqlZero()) {
        words.fillUnknown(out);
        return out;
    }
    var result = try Big.init(gpa);
    defer result.deinit();
    switch (op) {
        .add => _ = try result.addWrap(&a, &b, .unsigned, out.width),
        .subtract => _ = try result.subWrap(&a, &b, .unsigned, out.width),
        .multiply => try result.mulWrap(&a, &b, .unsigned, out.width),
        .divide, .remainder => {
            var remainder = try Big.init(gpa);
            defer remainder.deinit();
            try result.divTrunc(&remainder, &a, &b);
            if (op == .remainder) std.mem.swap(Big, &result, &remainder);
        },
    }
    try storeArithmetic(out, &result);
    return out;
}

/// `negate` with its path chosen, as `arithmeticIn`.
fn negateIn(self: Literal, gpa: Allocator, one_word: bool) Allocator.Error!Literal {
    if (one_word) assert(self.width <= 64);
    const out = try words.allocate(gpa, self.width, self.signed);
    errdefer gpa.free(out.planes);
    if (self.reduce(.xor_bits) == .x) {
        words.fillUnknown(out);
        return out;
    }
    if (one_word) {
        out.values()[0] = 0 -% self.values()[0];
        out.unknowns()[0] = 0;
        words.clearPadding(out);
        return out;
    }
    var value = try arithmeticValue(self, gpa, self.signed);
    defer value.deinit();
    value.negate();
    try storeArithmetic(out, &value);
    return out;
}

/// `power` with its path chosen, as `arithmeticIn`: the same case split on
/// one word.
fn powerIn(self: Literal, gpa: Allocator, exponent: Literal, one_word: bool) Allocator.Error!Literal {
    if (one_word) assert(self.width <= 64);
    const out = try words.allocate(gpa, self.width, self.signed);
    errdefer gpa.free(out.planes);
    if (self.reduce(.xor_bits) == .x or exponent.reduce(.xor_bits) == .x) {
        words.fillUnknown(out);
        return out;
    }
    @memset(out.planes, 0);
    var bits = exponent.width;
    while (bits != 0 and exponent.bit(bits - 1) == .zero) bits -= 1;
    if (bits == 0) {
        out.values()[0] = 1;
        return out;
    }
    const negative = exponent.signed and exponent.bit(exponent.width - 1) == .one;
    if (one_word) {
        const m = words.mask(self.width);
        const b = self.values()[0] & m;
        if (b == 0) {
            if (negative) words.fillUnknown(out);
        } else if (b == 1 or (self.signed and b == m)) {
            // ±1: 1 stays 1, and -1 alternates with the exponent's parity.
            out.values()[0] = if (b == 1 or exponent.bit(0) == .zero) 1 else m;
        } else if (!negative) {
            var result: u64 = 1;
            var base = b;
            var bit_index: u32 = 0;
            while (bit_index < bits) : (bit_index += 1) {
                if (exponent.bit(bit_index) == .one) result *%= base;
                if (bit_index + 1 < bits) base *%= base;
            }
            out.values()[0] = result & m;
        }
        return out;
    }
    var base = try arithmeticValue(self, gpa, self.signed);
    defer base.deinit();
    if (base.toConst().eqlZero()) {
        if (negative) words.fillUnknown(out);
        return out;
    }
    if (base.toConst().orderAgainstScalar(@as(i32, 1)) == .eq or
        base.toConst().orderAgainstScalar(@as(i32, -1)) == .eq)
    {
        if (base.isPositive() or exponent.bit(0) == .zero) try base.set(1);
        try storeArithmetic(out, &base);
        return out;
    }
    // Integer reciprocals truncate toward zero; zero and ±1 above are the
    // exceptions, even for multiword negative exponents.
    if (negative) return out;
    var result = try Big.init(gpa);
    defer result.deinit();
    try result.set(1);
    var bit_index: u32 = 0;
    while (bit_index < bits) : (bit_index += 1) {
        if (exponent.bit(bit_index) == .one)
            try result.mulWrap(&result, &base, .unsigned, self.width);
        if (bit_index + 1 < bits)
            try base.mulWrap(&base, &base, .unsigned, self.width);
    }
    try storeArithmetic(out, &result);
    return out;
}

/// `lit`'s declared bits as an exact integer read under `signed`. Explicit
/// byte order keeps the u64 planes host-independent; a partial final word
/// takes part only up to the width. Caller deinits the result.
fn arithmeticValue(lit: Literal, gpa: Allocator, signed: bool) Allocator.Error!Big {
    const n = words.wordCount(lit.width);
    const bytes = try gpa.alloc(u8, n * 8);
    defer gpa.free(bytes);
    for (lit.values()[0..n], 0..) |word, i|
        std.mem.writeInt(u64, bytes[i * 8 ..][0..8], word, .little);
    var out = try Big.initCapacity(gpa, std.math.big.int.calcTwosCompLimbCount(lit.width));
    var mutable = out.toMutable();
    mutable.readTwosComplement(bytes, lit.width, .little, if (signed) .signed else .unsigned);
    out.setMetadata(mutable.positive, mutable.len);
    return out;
}

/// Stores `value` modulo 2^width into `out`'s planes, all bits known.
fn storeArithmetic(out: Literal, value: *Big) Allocator.Error!void {
    try value.truncate(value, .unsigned, out.width);
    @memset(out.planes, 0);
    value.toConst().writeTwosComplement(std.mem.sliceAsBytes(out.values()), .little);
    for (out.values()) |*word| word.* = std.mem.readInt(u64, std.mem.asBytes(word), .little);
    words.clearPadding(out);
    assert(!out.hasUnknown());
}

// Independent arithmetic oracle: scalar mathematical integers, followed by a
// bit comparison at the result width. No packed or std.math.big operations.
fn testArithmeticResult(actual: Literal, expected: ?i1025) !void {
    for (0..actual.width) |i| {
        const want: Bit = if (expected) |number|
            (if ((@as(u1025, @bitCast(number)) >> @intCast(i)) & 1 != 0) .one else .zero)
        else
            .x;
        try std.testing.expectEqual(want, actual.bit(@intCast(i)));
    }
    const last = words.wordCount(actual.width) - 1;
    try std.testing.expectEqual(@as(u64, 0), actual.values()[last] & ~words.mask(actual.width));
    try std.testing.expectEqual(@as(u64, 0), actual.unknowns()[last] & ~words.mask(actual.width));
}

fn testArithmeticNumber(op: Arithmetic, a: i1025, b: i1025) ?i1025 {
    return switch (op) {
        .add => a + b,
        .subtract => a - b,
        .multiply => a * b,
        .divide => if (b == 0) null else @divTrunc(a, b),
        .remainder => if (b == 0) null else @rem(a, b),
    };
}

fn testWideNumber(value: Literal, signed: bool) i1025 {
    var result: i1025 = 0;
    for (0..value.width) |i| {
        if (value.bit(@intCast(i)) == .one) result += @as(i1025, 1) << @intCast(i);
    }
    if (signed and value.bit(value.width - 1) == .one)
        result -= @as(i1025, 1) << @intCast(value.width);
    return result;
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

fn testPowerNumber(base: i32, exponent: i32) ?i1025 {
    if (exponent < 0) {
        if (base == 0) return null;
        if (base == 1) return 1;
        if (base == -1) return if (@rem(exponent, 2) == 0) 1 else -1;
        return 0;
    }
    var result: i1025 = 1;
    for (0..@intCast(exponent)) |_| result *= base;
    return result;
}

fn testPowerAllocation(allocator: std.mem.Allocator) !void {
    const a = try integer.parse(allocator, "129'h100000000000000000000000000000003");
    defer allocator.free(a.planes);
    const b = try integer.parse(allocator, "65'd17");
    defer allocator.free(b.planes);
    const result = try a.power(allocator, b);
    defer allocator.free(result.planes);
}

/// A random operand of 1..64 bits, either signedness, with x/z bits in about
/// one operand in eight and a bias toward the words that end the ranges.
fn testRandomWord(random: std.Random, storage: *[2]u64) Literal {
    const width = random.intRangeAtMost(u32, 1, 64);
    const edges = [_]u64{ 0, 1, std.math.maxInt(u64), @as(u64, 1) << 63, (@as(u64, 1) << 63) - 1, 2 };
    storage[0] = if (random.boolean()) edges[random.uintLessThan(usize, edges.len)] else random.int(u64);
    storage[1] = if (random.uintLessThan(u8, 8) == 0) random.int(u64) else 0;
    const out: Literal = .{ .width = width, .sized = true, .signed = random.boolean(), .planes = storage };
    words.clearPadding(out);
    return out;
}

test "packed arithmetic exhausts small four-state operands and signedness" {
    const allocator = std.testing.allocator;
    var aa: [2]u64 = undefined;
    var bb: [2]u64 = undefined;
    for (1..4) |aw| {
        for (0..@as(usize, 1) << @intCast(2 * aw)) |ap| {
            inline for (.{ false, true }) |sa| {
                const a = fixture.testPattern(&aa, @intCast(aw), sa, ap);
                const av = fixture.testNumber(a, sa);
                const negated = try a.negate(allocator);
                defer allocator.free(negated.planes);
                try std.testing.expectEqual(a.width, negated.width);
                try std.testing.expectEqual(sa, negated.signed);
                try testArithmeticResult(negated, if (av) |v| -@as(i1025, v) else null);
                for (1..4) |bw| {
                    for (0..@as(usize, 1) << @intCast(2 * bw)) |bp| {
                        inline for (.{ false, true }) |sb| {
                            const b = fixture.testPattern(&bb, @intCast(bw), sb, bp);
                            const signed = sa and sb;
                            const x = fixture.testNumber(a, signed);
                            const y = fixture.testNumber(b, signed);
                            for (std.enums.values(Arithmetic)) |op| {
                                const actual = try a.arithmetic(allocator, op, b);
                                defer allocator.free(actual.planes);
                                try std.testing.expectEqual(@as(u32, @intCast(@max(aw, bw))), actual.width);
                                try std.testing.expectEqual(signed, actual.signed);
                                try testArithmeticResult(actual, if (x != null and y != null) testArithmeticNumber(op, x.?, y.?) else null);
                            }
                        }
                    }
                }
            }
        }
    }
}

test "packed arithmetic matches wide scalar integers across word boundaries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(0x41d7235c99e01a6b);
    const random = prng.random();
    const widths = [_]u32{ 31, 32, 33, 63, 64, 65, 127, 128, 129, 191, 255, 256, 257, 511 };
    for (widths, 0..) |aw, wi| {
        const bw = widths[(wi * 5 + 3) % widths.len];
        for (0..8) |_| {
            inline for (.{ false, true }) |sa| {
                inline for (.{ false, true }) |sb| {
                    const a = try words.allocate(arena, aw, sa);
                    const b = try words.allocate(arena, bw, sb);
                    for (a.values()) |*word| word.* = random.int(u64);
                    for (b.values()) |*word| word.* = random.int(u64);
                    @memset(a.unknowns(), 0);
                    @memset(b.unknowns(), 0);
                    words.clearPadding(a);
                    words.clearPadding(b);
                    const before_a = try arena.dupe(u64, a.planes);
                    const before_b = try arena.dupe(u64, b.planes);
                    const signed = sa and sb;
                    const x = testWideNumber(a, signed);
                    const y = testWideNumber(b, signed);
                    for (std.enums.values(Arithmetic)) |op| {
                        const actual = try a.arithmetic(arena, op, b);
                        try std.testing.expectEqual(@max(aw, bw), actual.width);
                        try std.testing.expectEqual(signed, actual.signed);
                        try testArithmeticResult(actual, testArithmeticNumber(op, x, y));
                    }
                    try testArithmeticResult(try a.negate(arena), -testWideNumber(a, sa));
                    try std.testing.expectEqualSlices(u64, before_a, a.planes);
                    try std.testing.expectEqualSlices(u64, before_b, b.planes);
                }
            }
        }
    }
}

test "packed arithmetic wraps long carries and minimum signed values exactly" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]u32{ 63, 64, 65, 127, 128, 129, 1025, 4097 }) |width| {
        const ones = try words.allocate(arena, width, false);
        @memset(ones.values(), std.math.maxInt(u64));
        @memset(ones.unknowns(), 0);
        words.clearPadding(ones);
        const zero = try words.allocate(arena, width, false);
        @memset(zero.planes, 0);
        const one = try words.allocate(arena, width, false);
        @memset(one.planes, 0);
        one.values()[0] = 1;
        const three = try integer.parse(arena, "2'b11");
        const sum = try ones.arithmetic(arena, .add, one);
        const difference = try zero.arithmetic(arena, .subtract, one);
        try std.testing.expectEqualSlices(u64, zero.planes, sum.planes);
        try std.testing.expectEqualSlices(u64, ones.planes, difference.planes);
        const quotient = try ones.arithmetic(arena, .divide, three);
        const remainder = try ones.arithmetic(arena, .remainder, three);
        for (0..width) |i| {
            try std.testing.expectEqual(if (i % 2 == width % 2 and i + 1 < width) Bit.one else .zero, quotient.bit(@intCast(i)));
            try std.testing.expectEqual(if (i == 0 and width % 2 == 1) Bit.one else .zero, remainder.bit(@intCast(i)));
        }
        const minimum = try words.allocate(arena, width, true);
        @memset(minimum.planes, 0);
        fixture.testPut(minimum, width - 1, .one);
        var minus_one = ones;
        minus_one.signed = true;
        const divided_minimum = try minimum.arithmetic(arena, .divide, minus_one);
        const negated_minimum = try minimum.negate(arena);
        try std.testing.expectEqualSlices(u64, minimum.planes, divided_minimum.planes);
        try std.testing.expectEqualSlices(u64, minimum.planes, negated_minimum.planes);
        try std.testing.expectEqualSlices(u64, zero.planes, (try minimum.arithmetic(arena, .remainder, minus_one)).planes);
        try std.testing.expectEqualSlices(u64, zero.planes, (try minimum.arithmetic(arena, .add, minimum)).planes);
        const two = try integer.parse(arena, "3'sb010");
        try std.testing.expectEqualSlices(u64, zero.planes, (try minimum.arithmetic(arena, .multiply, two)).planes);
        for ([_]u32{ 0, width / 2, width - 1 }) |bit_index| {
            inline for (.{ Bit.x, Bit.z }) |state| {
                const unknown = try ones.resize(arena, width, .zero);
                fixture.testPut(unknown, bit_index, state);
                for (std.enums.values(Arithmetic)) |op| {
                    const result = try unknown.arithmetic(arena, op, zero);
                    for (0..width) |i| try std.testing.expectEqual(Bit.x, result.bit(@intCast(i)));
                }
            }
        }
    }
}

test "arithmetic context is applied before evaluation and padding is not data" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = try integer.parse(arena, "4'hf");
    const b = try integer.parse(arena, "4'h1");
    try testArithmeticResult(try a.arithmetic(arena, .add, b), 0);
    const wider_a = try a.resize(arena, 8, .zero);
    const wider_b = try b.resize(arena, 8, .zero);
    try testArithmeticResult(try wider_a.arithmetic(arena, .add, wider_b), 16);
    const signed = try integer.parse(arena, "4'sh8");
    const sign_extended = try signed.resize(arena, 8, .sign);
    const signed_one = try integer.parse(arena, "8'sh1");
    try testArithmeticResult(try sign_extended.arithmetic(arena, .add, signed_one), -7);
    // A caller's propagated unsigned context zero-extends the original bits.
    var unsigned = try signed.resize(arena, 8, .zero);
    unsigned.signed = false;
    try testArithmeticResult(try unsigned.arithmetic(arena, .add, wider_b), 9);
    var av: [2]u64 = .{ std.math.maxInt(u64), std.math.maxInt(u64) ^ 15 };
    const padded: Literal = .{ .width = 4, .signed = false, .sized = true, .planes = &av };
    try testArithmeticResult(try padded.arithmetic(arena, .add, b), 0);
    try testArithmeticResult(try padded.negate(arena), 1);
    const spare = try integer.parse(arena, "000000000000000000000000000000000000000000001");
    try std.testing.expect(spare.values().len > words.wordCount(spare.width));
    const spare_sum = try spare.arithmetic(arena, .add, b);
    try testArithmeticResult(spare_sum, 2);
}

test "packed arithmetic frees partial allocations on every failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testArithmeticAllocation, .{});
}

test "packed power exhausts small four-state operands with independent signedness" {
    const allocator = std.testing.allocator;
    var aa: [2]u64 = undefined;
    var bb: [2]u64 = undefined;
    for (1..4) |aw| for (1..4) |bw| {
        for (0..@as(usize, 1) << @intCast(2 * aw)) |ap| {
            inline for (.{ false, true }) |sa| {
                const a = fixture.testPattern(&aa, @intCast(aw), sa, ap);
                const av = fixture.testNumber(a, sa);
                for (0..@as(usize, 1) << @intCast(2 * bw)) |bp| {
                    inline for (.{ false, true }) |sb| {
                        const b = fixture.testPattern(&bb, @intCast(bw), sb, bp);
                        const bv = fixture.testNumber(b, sb);
                        const result = try a.power(allocator, b);
                        defer allocator.free(result.planes);
                        try std.testing.expectEqual(a.width, result.width);
                        try std.testing.expectEqual(a.signed, result.signed);
                        try testArithmeticResult(result, if (av != null and bv != null) testPowerNumber(av.?, bv.?) else null);
                    }
                }
            }
        }
    };
}

test "packed power preserves multiword context and large exponent semantics" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const seventeen = try integer.parse(arena, "8'd17");
    for ([_]u32{ 1, 31, 32, 63, 64, 65, 127, 128, 129, 257, 511 }) |width| {
        const a = try words.allocate(arena, width, false);
        @memset(a.planes, 0);
        a.values()[0] = 29;
        words.clearPadding(a);
        var mathematical: i1025 = 1;
        for (0..17) |_| mathematical *= if (width < 64) @as(i1025, @intCast(29 & words.mask(width))) else 29;
        try testArithmeticResult(try a.power(arena, seventeen), mathematical);
    }

    // (2^128 + 3)^3 mod 2^257 = 2^256 + 27*2^128 + 27.
    const wide_base = try words.allocate(arena, 257, false);
    @memset(wide_base.planes, 0);
    wide_base.values()[0] = 3;
    wide_base.values()[2] = 1;
    const three = try integer.parse(arena, "4'd3");
    const cube = try wide_base.power(arena, three);
    try std.testing.expectEqualSlices(u64, &.{ 27, 0, 27, 0, 1 }, cube.values());
    try std.testing.expect(!cube.hasUnknown());

    const huge = try words.allocate(arena, 129, false);
    @memset(huge.planes, 0);
    huge.values()[2] = 1;
    huge.values()[0] = 1;
    const base_three = try three.resize(arena, 129, .zero);
    // Euler's theorem: 3^(2^128+1) = 3 modulo 2^129.
    try testArithmeticResult(try base_three.power(arena, huge), 3);
    var negative = huge;
    negative.signed = true;
    try testArithmeticResult(try base_three.power(arena, negative), 0);
    const minus_one = try integer.parse(arena, "65'sh1ffffffffffffffff");
    try testArithmeticResult(try minus_one.power(arena, negative), -1);
    huge.values()[0] = 0;
    try testArithmeticResult(try minus_one.power(arena, negative), 1);

    const very_wide = try words.allocate(arena, 4097, false);
    @memset(very_wide.planes, 0);
    very_wide.values()[0] = 2;
    const boundary = try integer.parse(arena, "32'd4096");
    const power_of_two = try very_wide.power(arena, boundary);
    for (power_of_two.values(), 0..) |word, i|
        try std.testing.expectEqual(@as(u64, if (i == 64) 1 else 0), word);
    try std.testing.expect(!power_of_two.hasUnknown());

    // Only declared bits participate; padding and spare plane words are not
    // unknown operands. Neither input may be overwritten by repeated squaring.
    var padded_words = [_]u64{ ~@as(u64, 7) | 5, 99, ~@as(u64, 7), 88 };
    var count_words = [_]u64{ ~@as(u64, 7) | 2, 77, ~@as(u64, 7), 66 };
    const saved_base = padded_words;
    const saved_count = count_words;
    const padded: Literal = .{ .width = 3, .signed = false, .sized = true, .planes = &padded_words };
    const padded_count: Literal = .{ .width = 3, .signed = false, .sized = true, .planes = &count_words };
    try testArithmeticResult(try padded.power(arena, padded_count), 1);
    try std.testing.expectEqualSlices(u64, &saved_base, &padded_words);
    try std.testing.expectEqualSlices(u64, &saved_count, &count_words);
}

test "packed power allocation failures release every intermediate" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testPowerAllocation, .{});
}

test "one-word arithmetic, negate and power agree with the big-integer path" {
    // The word path replaces the big-integer path for every result of at
    // most 64 bits, so the big one is kept as its oracle over exactly that
    // domain: random widths, both signs, both planes.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(0x1364_0064);
    const random = prng.random();
    var aa: [2]u64 = undefined;
    var bb: [2]u64 = undefined;
    for (0..20_000) |_| {
        _ = arena_state.reset(.retain_capacity);
        const a = testRandomWord(random, &aa);
        const b = testRandomWord(random, &bb);
        for (std.enums.values(Arithmetic)) |op| {
            const want = try arithmeticIn(a, arena, op, b, false);
            const got = try arithmeticIn(a, arena, op, b, true);
            try std.testing.expectEqual(want.width, got.width);
            try std.testing.expectEqual(want.signed, got.signed);
            try std.testing.expectEqualSlices(u64, want.planes, got.planes);
        }
        try std.testing.expectEqualSlices(u64, (try negateIn(a, arena, false)).planes, (try negateIn(a, arena, true)).planes);
        try std.testing.expectEqualSlices(u64, (try powerIn(a, arena, b, false)).planes, (try powerIn(a, arena, b, true)).planes);
    }
}
