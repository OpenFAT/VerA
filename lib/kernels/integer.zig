//! Four-state integer literals (LRM §2.6.1): literal text in, a `Literal` of
//! two packed bit planes out, plus the IEEE 1364-2005 §5.1 operators over them.
//! The planes use the VPI encoding: (value, unknown) = 00/10/11/01 for 0/1/X/Z.

const std = @import("std");

/// Why `parse` refused a literal's text.
pub const Error = error{ MissingBase, MissingDigits, DigitOutOfRange, ZeroSize, Overflow };

/// One four-state bit; the integer is `value | unknown << 1`.
pub const Bit = enum(u2) { zero = 0, one = 1, z = 2, x = 3 };
/// How `Literal.resize` fills the bits it adds: with zero, or with copies of
/// the top bit (X and Z included), IEEE 1364-2005 §5.5.
const Extension = enum(u1) { zero, sign };
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

/// A four-state integer of any width. Both planes are one allocation, owned by
/// the allocator the producing call was given; free `planes` to release it.
/// Widths share the AST's u32 address space; an unsized literal is at least 64
/// bits wide. Every operation keeps the bits above `width` in each plane's
/// last word zero, and reads only the declared bits of its operands.
pub const Literal = struct {
    /// Declared bits, at least 1.
    width: u32,
    /// Written with a §2.6.1 size; an unsized literal's width is VerA's.
    sized: bool,
    signed: bool,
    /// The value plane then the unknown plane, equal halves.
    planes: []u64,

    // Passed by value through every interpreter operator: one slice, a
    // width and two flags, no padding beyond the slice's alignment.
    comptime {
        std.debug.assert(@sizeOf(Literal) <= 24);
    }

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
    /// Returns the value as an i64, sign-extended when `signed`. Null when the
    /// literal is wider than 64 bits or holds an X or Z bit. A 64-bit unsigned
    /// value comes back as its bit pattern, negative from 2^63 up: the i64 is
    /// the carrier the analog integer path reads, not a numeric conversion.
    pub fn asInt(self: Literal) ?i64 {
        if (self.width > 64 or self.hasUnknown()) return null;
        var bits = self.values()[0];
        if (self.signed and self.width < 64 and bits & (@as(u64, 1) << @intCast(self.width - 1)) != 0)
            bits |= ~mask(self.width);
        return @bitCast(bits);
    }
    /// Returns the value as an i64 at any width: at 64 bits or fewer it is
    /// `asInt`, and a wider literal qualifies when every bit above bit 63
    /// repeats bit 63 (signed) or is 0 with bit 63 clear (unsigned), so its
    /// numeric value is the i64's. Null on an X or Z bit.
    pub fn asExactInt(self: Literal) ?i64 {
        if (self.width <= 64) return self.asInt();
        if (self.hasUnknown()) return null;
        // Declared words only: a `parse`d unsized decimal reserves spare
        // zero words past them, which a negative value does not fill.
        const words = self.values()[0..wordCount(self.width)];
        const low: i64 = @bitCast(words[0]);
        if (low < 0 and !self.signed) return null;
        const fill: u64 = if (low < 0) std.math.maxInt(u64) else 0;
        const last = words.len - 1;
        for (words[1..], 1..) |word, i| {
            if (word != if (i == last) fill & mask(self.width) else fill) return null;
        }
        return low;
    }
    /// Returns the value as a self-determined address (§5.2.1/§5.2.2), null
    /// on any x/z bit. Values beyond i64 are kept so a part-select based just
    /// outside a declaration can still overlap it; beyond i128 the result
    /// saturates to maxInt(i128) or minInt(i128) by sign, since such a value
    /// cannot overlap an i64 declaration with a u32 select width.
    pub fn asIndex(self: Literal) ?i128 {
        if (self.hasUnknown()) return null;
        const negative = self.signed and self.bit(self.width - 1) == .one;
        const fill: u64 = if (negative) std.math.maxInt(u64) else 0;
        const outside: i128 = if (negative) std.math.minInt(i128) else std.math.maxInt(i128);
        const v = self.values()[0..wordCount(self.width)];
        var bits: u128 = v[0];
        if (self.width > 64) bits |= @as(u128, v[1]) << 64;
        if (self.width < 128 and negative) bits |= @as(u128, std.math.maxInt(u128)) << @intCast(self.width);
        if (self.width > 128) {
            for (v[2..], 2..) |word, i| {
                if (word != if (i == v.len - 1) fill & mask(self.width) else fill) return outside;
            }
        }
        const result: i128 = @bitCast(bits);
        return if ((result < 0) == negative) result else outside;
    }
    /// Returns bit `index`, bit zero least significant. Asserts
    /// `index < width`.
    pub fn bit(self: Literal, index: u32) Bit {
        std.debug.assert(index < self.width);
        const bit_offset: u6 = @truncate(index);
        const word_index = index / 64;
        return @fromBackingInt(@intCast(@as(u2, @intCast((self.values()[word_index] >> bit_offset) & 1)) |
            (@as(u2, @intCast((self.unknowns()[word_index] >> bit_offset) & 1)) << 1)));
    }

    /// Returns a copy at `width` bits (IEEE 1364-2005 §§5.5.2 to 5.6). The
    /// evaluator supplies the propagated extension mode. Signed extension
    /// replicates X and Z too. This preserves the source signedness; converting
    /// the type is a separate evaluator step. Every allocating operation
    /// returns independent planes owned by `allocator`.
    pub fn resize(self: Literal, allocator: std.mem.Allocator, width: u32, extension: Extension) (error{ZeroSize} || std.mem.Allocator.Error)!Literal {
        if (width == 0) return error.ZeroSize;
        const out = try allocate(allocator, width, self.signed);
        for (out.values(), out.unknowns(), 0..) |*v, *u, i| {
            v.* = self.extendedWord(self.values(), i, extension);
            u.* = self.extendedWord(self.unknowns(), i, extension);
        }
        out.clearPadding();
        return out;
    }

    /// Joins self-determined operands, leftmost at the most significant end
    /// (IEEE 1364-2005 §5.1.14). The result is unsigned; caller owns its
    /// planes and frees them with `allocator`. Fails with `ZeroSize` for no
    /// parts or a zero-width part and `Overflow` when the widths sum past
    /// u32, both before allocating.
    pub fn concatenate(allocator: std.mem.Allocator, parts: []const Literal) (std.mem.Allocator.Error || error{ ZeroSize, Overflow })!Literal {
        var width: u32 = 0;
        for (parts) |part| {
            if (part.width == 0) return error.ZeroSize;
            width = std.math.add(u32, width, part.width) catch return error.Overflow;
        }
        if (width == 0) return error.ZeroSize;
        const out = try allocate(allocator, width, false);
        @memset(out.planes, 0);
        var offset = width;
        for (parts) |part| {
            offset -= part.width;
            out.copyBits(part, offset);
        }
        return out;
    }

    /// Repeats an already evaluated operand `count` times, unsigned; caller
    /// owns the result's planes and frees them with `allocator`. Zero
    /// replication is a source-level exception inside a larger concat; it
    /// never creates a zero-width Literal: `count == 0` fails with `ZeroSize`,
    /// and a width past u32 with `Overflow`, both before allocating.
    pub fn replicate(self: Literal, allocator: std.mem.Allocator, count: u32) (std.mem.Allocator.Error || error{ ZeroSize, Overflow })!Literal {
        if (self.width == 0 or count == 0) return error.ZeroSize;
        const width = std.math.mul(u32, self.width, count) catch return error.Overflow;
        const out = try allocate(allocator, width, false);
        @memset(out.planes, 0);
        for (0..count) |i| out.copyBits(self, @as(u32, @intCast(i)) * self.width);
        return out;
    }

    // Source and destination do not alias. Copies may cross a word boundary;
    // masking the last source word keeps padding from overwriting its neighbor.
    fn copyBits(self: Literal, source: Literal, offset: u32) void {
        std.debug.assert(offset <= self.width and source.width <= self.width - offset);
        const first: usize = offset / 64;
        const bit_offset: u6 = @truncate(offset);
        const words = wordCount(source.width);
        inline for (.{ false, true }) |unknown| {
            const from = if (unknown) source.unknowns() else source.values();
            const to = if (unknown) self.unknowns() else self.values();
            for (from[0..words], 0..) |raw, i| {
                const word = raw & (if (i + 1 == words) mask(source.width) else std.math.maxInt(u64));
                to[first + i] |= word << bit_offset;
                if (bit_offset != 0 and first + i + 1 < to.len)
                    to[first + i + 1] |= word >> @as(u6, @intCast(64 - @as(u7, bit_offset)));
            }
        }
    }

    /// Returns `~self` (IEEE 1364-2005 Table 5-16). X and Z both negate to X.
    /// Caller owns the result's planes and frees them with `allocator`.
    pub fn bitwiseNot(self: Literal, allocator: std.mem.Allocator) std.mem.Allocator.Error!Literal {
        const out = try allocate(allocator, self.width, self.signed);
        for (out.values(), out.unknowns(), 0..) |*v, *u, i| {
            u.* = self.unknowns()[i];
            v.* = ~self.values()[i] | u.*;
        }
        out.clearPadding();
        return out;
    }

    /// Applies a bitwise operator (IEEE 1364-2005 Tables 5-12 to 5-15, §§5.4
    /// and 5.5). Self-determined result
    /// sizing only: a surrounding expression must propagate its context first.
    /// Caller owns the result's planes and frees them with `allocator`.
    pub fn bitwise(self: Literal, allocator: std.mem.Allocator, op: Bitwise, rhs: Literal) std.mem.Allocator.Error!Literal {
        const signed = self.signed and rhs.signed;
        const extension: Extension = if (signed) .sign else .zero;
        const out = try allocate(allocator, @max(self.width, rhs.width), signed);
        for (out.values(), out.unknowns(), 0..) |*v, *u, i| {
            const av = self.extendedWord(self.values(), i, extension);
            const au = self.extendedWord(self.unknowns(), i, extension);
            const bv = rhs.extendedWord(rhs.values(), i, extension);
            const bu = rhs.extendedWord(rhs.unknowns(), i, extension);
            switch (op) {
                .and_bits => {
                    u.* = (au | bu) & (av | au) & (bv | bu);
                    v.* = (av & bv) | u.*;
                },
                .or_bits => {
                    u.* = (au | bu) & ~((av & ~au) | (bv & ~bu));
                    v.* = (av | bv) | u.*;
                },
                .xor_bits, .xnor_bits => {
                    u.* = au | bu;
                    v.* = (if (op == .xor_bits) av ^ bv else ~(av ^ bv)) | u.*;
                },
            }
        }
        out.clearPadding();
        return out;
    }

    /// Applies an arithmetic operator (IEEE 1364-2005 §§5.1.5, 5.4, 5.5).
    /// Result width is max(operand widths),
    /// signed iff both operands are signed. That common type controls operand
    /// extension before arithmetic. The caller must propagate any outer width
    /// and type first; these helpers do not infer expression/assignment context.
    /// Results wrap at that width; X/Z in either operand and division/remainder
    /// by zero produce all X. Signed division truncates toward zero, and the
    /// remainder has the dividend's sign. Inputs and output never alias.
    /// Caller owns the result's planes and frees them with `allocator`; a
    /// failed allocation frees every intermediate.
    pub fn arithmetic(self: Literal, allocator: std.mem.Allocator, op: Arithmetic, rhs: Literal) std.mem.Allocator.Error!Literal {
        return self.arithmeticIn(allocator, op, rhs, @max(self.width, rhs.width) <= 64);
    }

    /// `one_word` is a result of at most 64 bits computed in one machine word:
    /// wrap at the result width is arithmetic modulo 2^width, which a wrapping
    /// u64 op followed by the width mask computes exactly, and operands
    /// extended to 64 bits under the common signedness are exactly their
    /// values, which is all divide and remainder read. Otherwise the standard
    /// library's exact integers, at any width, which are also the oracle the word path
    /// is tested against.
    fn arithmeticIn(self: Literal, allocator: std.mem.Allocator, op: Arithmetic, rhs: Literal, one_word: bool) std.mem.Allocator.Error!Literal {
        const signed = self.signed and rhs.signed;
        const out = try allocate(allocator, @max(self.width, rhs.width), signed);
        errdefer allocator.free(out.planes);
        // Reduction masks padding and spare capacity outside the declared bits.
        if (self.reduce(.xor_bits) == .x or rhs.reduce(.xor_bits) == .x) {
            out.fillUnknown();
            return out;
        }
        if (one_word) {
            const extension: Extension = if (signed) .sign else .zero;
            const a = self.extendedWord(self.values(), 0, extension);
            const b = rhs.extendedWord(rhs.values(), 0, extension);
            if ((op == .divide or op == .remainder) and b == 0) {
                out.fillUnknown();
                return out;
            }
            out.values()[0] = switch (op) {
                .add => a +% b,
                .subtract => a -% b,
                .multiply => a *% b,
                .divide, .remainder => if (!signed)
                    (if (op == .divide) a / b else a % b)
                else if (b == std.math.maxInt(u64))
                    // x / -1 is -x, wrapping at the most negative value (the
                    // one quotient an i64 divide would trap on); x % -1 is 0.
                    (if (op == .divide) 0 -% a else 0)
                else
                    @bitCast(if (op == .divide) @divTrunc(@as(i64, @bitCast(a)), @as(i64, @bitCast(b))) else @rem(@as(i64, @bitCast(a)), @as(i64, @bitCast(b)))),
            };
            out.unknowns()[0] = 0;
            out.clearPadding();
            return out;
        }
        var a = try self.arithmeticValue(allocator, signed);
        defer a.deinit();
        var b = try rhs.arithmeticValue(allocator, signed);
        defer b.deinit();
        if ((op == .divide or op == .remainder) and b.toConst().eqlZero()) {
            out.fillUnknown();
            return out;
        }
        var result = try std.math.big.int.Managed.init(allocator);
        defer result.deinit();
        switch (op) {
            .add => _ = try result.addWrap(&a, &b, .unsigned, out.width),
            .subtract => _ = try result.subWrap(&a, &b, .unsigned, out.width),
            .multiply => try result.mulWrap(&a, &b, .unsigned, out.width),
            .divide, .remainder => {
                var remainder = try std.math.big.int.Managed.init(allocator);
                defer remainder.deinit();
                try result.divTrunc(&remainder, &a, &b);
                if (op == .remainder) std.mem.swap(std.math.big.int.Managed, &result, &remainder);
            },
        }
        try out.storeArithmetic(&result);
        return out;
    }

    /// Returns `-self`. Unary minus retains the operand width and signedness,
    /// including wrap at the most negative value. Any X/Z bit makes the entire
    /// result X. Caller owns the result's planes and frees them with
    /// `allocator`.
    pub fn negate(self: Literal, allocator: std.mem.Allocator) std.mem.Allocator.Error!Literal {
        return self.negateIn(allocator, self.width <= 64);
    }

    /// `one_word` as in `arithmeticIn`.
    fn negateIn(self: Literal, allocator: std.mem.Allocator, one_word: bool) std.mem.Allocator.Error!Literal {
        const out = try allocate(allocator, self.width, self.signed);
        errdefer allocator.free(out.planes);
        if (self.reduce(.xor_bits) == .x) {
            out.fillUnknown();
            return out;
        }
        if (one_word) {
            out.values()[0] = 0 -% self.values()[0];
            out.unknowns()[0] = 0;
            out.clearPadding();
            return out;
        }
        var value = try self.arithmeticValue(allocator, self.signed);
        defer value.deinit();
        value.negate();
        try out.storeArithmetic(&value);
        return out;
    }

    /// Returns `self ** exponent` (IEEE 1364-2005 §5.1.5, Tables 5-6 and
    /// 5-8). The caller propagates the
    /// result context to the base first; the exponent keeps its own size and
    /// signedness. Integer results wrap at the base width. Any declared X/Z
    /// bit yields all X, including an unknown base raised to zero. Caller owns
    /// the result's planes and frees them with `allocator`. This operation is
    /// O(exponent bits) multiplications at the base width.
    pub fn power(self: Literal, allocator: std.mem.Allocator, exponent: Literal) std.mem.Allocator.Error!Literal {
        return self.powerIn(allocator, exponent, self.width <= 64);
    }

    /// `one_word` as in `arithmeticIn`: the same case split on one word.
    fn powerIn(self: Literal, allocator: std.mem.Allocator, exponent: Literal, one_word: bool) std.mem.Allocator.Error!Literal {
        const out = try allocate(allocator, self.width, self.signed);
        errdefer allocator.free(out.planes);
        if (self.reduce(.xor_bits) == .x or exponent.reduce(.xor_bits) == .x) {
            out.fillUnknown();
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
            const m = mask(self.width);
            const b = self.values()[0] & m;
            if (b == 0) {
                if (negative) out.fillUnknown();
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
        var base = try self.arithmeticValue(allocator, self.signed);
        defer base.deinit();
        if (base.toConst().eqlZero()) {
            if (negative) out.fillUnknown();
            return out;
        }
        if (base.toConst().orderAgainstScalar(@as(i32, 1)) == .eq or
            base.toConst().orderAgainstScalar(@as(i32, -1)) == .eq)
        {
            if (base.isPositive() or exponent.bit(0) == .zero) try base.set(1);
            try out.storeArithmetic(&base);
            return out;
        }
        // Integer reciprocals truncate toward zero. The zero and ±1 cases
        // above are the exceptions, even for multiword negative exponents.
        if (negative) return out;

        var result = try std.math.big.int.Managed.init(allocator);
        defer result.deinit();
        try result.set(1);
        var bit_index: u32 = 0;
        while (bit_index < bits) : (bit_index += 1) {
            if (exponent.bit(bit_index) == .one)
                try result.mulWrap(&result, &base, .unsigned, self.width);
            if (bit_index + 1 < bits)
                try base.mulWrap(&base, &base, .unsigned, self.width);
        }
        try out.storeArithmetic(&result);
        return out;
    }

    fn fillUnknown(self: Literal) void {
        @memset(self.planes, std.math.maxInt(u64));
        self.clearPadding();
    }

    /// Converts the packed planes to the standard library's exact integer
    /// arithmetic. Explicit byte order keeps the u64 planes host-independent;
    /// only the declared bits participate, including a partial final word.
    fn arithmeticValue(self: Literal, allocator: std.mem.Allocator, signed: bool) std.mem.Allocator.Error!std.math.big.int.Managed {
        const bytes = try allocator.alloc(u8, wordCount(self.width) * 8);
        defer allocator.free(bytes);
        for (self.values()[0..wordCount(self.width)], 0..) |word, i|
            std.mem.writeInt(u64, bytes[i * 8 ..][0..8], word, .little);
        var out = try std.math.big.int.Managed.initCapacity(allocator, std.math.big.int.calcTwosCompLimbCount(self.width));
        var mutable = out.toMutable();
        mutable.readTwosComplement(bytes, self.width, .little, if (signed) .signed else .unsigned);
        out.setMetadata(mutable.positive, mutable.len);
        return out;
    }

    fn storeArithmetic(self: Literal, value: *std.math.big.int.Managed) std.mem.Allocator.Error!void {
        try value.truncate(value, .unsigned, self.width);
        @memset(self.planes, 0);
        value.toConst().writeTwosComplement(std.mem.sliceAsBytes(self.values()), .little);
        for (self.values()) |*word| word.* = std.mem.readInt(u64, std.mem.asBytes(word), .little);
        self.clearPadding();
    }

    /// Shifts `self` by `rhs` (IEEE 1364-2005 §5.1.12). The caller propagates
    /// the expression's result width/type to self first (§§5.4–5.5); rhs is
    /// self-determined, unsigned, and cannot change the result width or
    /// signedness. Shifted X/Z survive; an X/Z bit in `rhs` makes the whole
    /// result X. Caller owns the result's planes and frees them with
    /// `allocator`.
    pub fn shift(self: Literal, allocator: std.mem.Allocator, op: Shift, rhs: Literal) std.mem.Allocator.Error!Literal {
        const out = try allocate(allocator, self.width, self.signed);
        if (rhs.hasUnknown()) {
            @memset(out.planes, std.math.maxInt(u64));
            out.clearPadding();
            return out;
        }
        const amount: u32 = count: {
            for (rhs.values()[1..wordCount(rhs.width)]) |word| {
                if (word != 0) break :count self.width;
            }
            break :count @intCast(@min(rhs.values()[0], self.width));
        };
        const left = op == .left or op == .arithmetic_left;
        const extension: Extension = if (op == .arithmetic_right and self.signed) .sign else .zero;
        const words: usize = amount / 64;
        const bits: u6 = @truncate(amount);
        inline for (.{ false, true }) |unknown| {
            const source = if (unknown) self.unknowns() else self.values();
            const dest = if (unknown) out.unknowns() else out.values();
            if (amount == self.width) {
                const sign = (source[(self.width - 1) / 64] >> @as(u6, @truncate(self.width - 1))) & 1;
                @memset(dest, if (extension == .sign) 0 -% sign else 0);
            } else for (dest, 0..) |*word, i| {
                if (left) {
                    word.* = if (i >= words) source[i - words] << bits else 0;
                    if (bits != 0 and i > words)
                        word.* |= source[i - words - 1] >> @as(u6, @intCast(64 - @as(u7, bits)));
                } else {
                    word.* = self.extendedWord(source, i + words, extension) >> bits;
                    if (bits != 0)
                        word.* |= self.extendedWord(source, i + words + 1, extension) << @as(u6, @intCast(64 - @as(u7, bits)));
                }
            }
        }
        out.clearPadding();
        return out;
    }

    /// Compares two literals (IEEE 1364-2005 §5.1.7). Unlike equality's
    /// known-mismatch rule, any X/Z operand makes the relation unknown.
    /// Both-signed operands extend and compare as signed; otherwise both
    /// normalize as unsigned.
    pub fn relational(self: Literal, op: Relational, rhs: Literal) Bit {
        if (self.hasUnknown() or rhs.hasUnknown()) return .x;
        const signed = self.signed and rhs.signed;
        const extension: Extension = if (signed) .sign else .zero;
        const width = @max(self.width, rhs.width);
        var i = wordCount(width);
        var order: std.math.Order = .eq;
        while (i != 0) {
            i -= 1;
            var a = self.extendedWord(self.values(), i, extension);
            var b = rhs.extendedWord(rhs.values(), i, extension);
            if (i == wordCount(width) - 1) {
                a &= mask(width);
                b &= mask(width);
                // Bias the common sign bit so unsigned word order implements
                // two's-complement signed order, including partial words.
                if (signed) {
                    const sign = @as(u64, 1) << @as(u6, @truncate(width - 1));
                    a ^= sign;
                    b ^= sign;
                }
            }
            if (a != b) {
                order = if (a < b) .lt else .gt;
                break;
            }
        }
        return if (switch (op) {
            .less => order == .lt,
            .less_equal => order != .gt,
            .greater => order == .gt,
            .greater_equal => order != .lt,
        }) .one else .zero;
    }

    /// Returns the logical truth value (IEEE 1364-2005 §5.1.9): any known one
    /// decides it, even beside X/Z.
    pub fn truth(self: Literal) Bit {
        return self.reduce(.or_bits);
    }

    /// Applies `&&` or `||` to the two truth values (IEEE 1364-2005 §5.1.9).
    pub fn logical(self: Literal, op: Logical, rhs: Literal) Bit {
        const a = self.truth();
        const b = rhs.truth();
        return switch (op) {
            .and_bits => if (a == .zero or b == .zero) .zero else if (a == .one and b == .one) .one else .x,
            .or_bits => if (a == .one or b == .one) .one else if (a == .zero and b == .zero) .zero else .x,
        };
    }

    /// Applies a unary reduction (IEEE 1364-2005 §5.1.11). Only the declared
    /// bits contribute.
    pub fn reduce(self: Literal, op: Reduction) Bit {
        var zeros: u64 = 0;
        var ones: u64 = 0;
        var unknown: u64 = 0;
        var parity: u1 = 0;
        const words = wordCount(self.width);
        for (self.values()[0..words], self.unknowns()[0..words], 0..) |v, u, i| {
            const live = if (i + 1 == words) mask(self.width) else std.math.maxInt(u64);
            zeros |= ~(v | u) & live;
            ones |= v & ~u & live;
            unknown |= u & live;
            parity ^= @truncate(@popCount(v & live));
        }
        const result: Bit = switch (op) {
            .and_bits, .nand_bits => if (zeros != 0) .zero else if (unknown != 0) .x else .one,
            .or_bits, .nor_bits => if (ones != 0) .one else if (unknown != 0) .x else .zero,
            .xor_bits, .xnor_bits => if (unknown != 0) .x else if (parity == 1) .one else .zero,
        };
        return switch (op) {
            .nand_bits, .nor_bits, .xnor_bits => invert(result),
            else => result,
        };
    }

    /// Applies an equality operator (IEEE 1364-2005 §5.1.8). A known mismatch
    /// resolves == even when other bits are unknown. Case equality compares
    /// both planes and never yields X.
    pub fn equality(self: Literal, op: Equality, rhs: Literal) Bit {
        const width = @max(self.width, rhs.width);
        const extension: Extension = if (self.signed and rhs.signed) .sign else .zero;
        const words = wordCount(width);
        var different: u64 = 0;
        var unknown: u64 = 0;
        for (0..words) |i| {
            const av = self.extendedWord(self.values(), i, extension);
            const au = self.extendedWord(self.unknowns(), i, extension);
            const bv = rhs.extendedWord(rhs.values(), i, extension);
            const bu = rhs.extendedWord(rhs.unknowns(), i, extension);
            const live = if (i + 1 == words) mask(width) else std.math.maxInt(u64);
            different |= (switch (op) {
                .case_equal, .case_not_equal => (av ^ bv) | (au ^ bu),
                .equal, .not_equal => (av ^ bv) & ~(au | bu),
            }) & live;
            unknown |= (au | bu) & live;
        }
        const result: Bit = if (different != 0) .zero else switch (op) {
            .case_equal, .case_not_equal => .one,
            .equal, .not_equal => if (unknown != 0) .x else .one,
        };
        return switch (op) {
            .not_equal, .case_not_equal => invert(result),
            else => result,
        };
    }

    /// Returns `self ? yes : no` (IEEE 1364-2005 §5.1.13, Table 5-21). Under
    /// an ambiguous condition,
    /// only matching known bits survive; even Z/Z merges to X in this edition.
    /// Table 5-22 makes the arms context-determined. §§5.5.1–5.5.2 propagate
    /// their common signedness and width BEFORE this operator: both-signed arms
    /// sign-extend, otherwise zero-extend. Thus §5.1.13's shorter-arm zero-fill
    /// sentence does not override the prior signed normalization.
    /// Inputs are already evaluated values, so expression short-circuiting is
    /// the caller's responsibility. Outer context sizing is as for `bitwise`.
    /// Caller owns the result's planes and frees them with `allocator`.
    pub fn conditional(self: Literal, allocator: std.mem.Allocator, yes: Literal, no: Literal) std.mem.Allocator.Error!Literal {
        const signed = yes.signed and no.signed;
        const extension: Extension = if (signed) .sign else .zero;
        const out = try allocate(allocator, @max(yes.width, no.width), signed);
        const condition = self.truth();
        for (out.values(), out.unknowns(), 0..) |*v, *u, i| {
            const av = yes.extendedWord(yes.values(), i, extension);
            const au = yes.extendedWord(yes.unknowns(), i, extension);
            const bv = no.extendedWord(no.values(), i, extension);
            const bu = no.extendedWord(no.unknowns(), i, extension);
            switch (condition) {
                .one => {
                    v.* = av;
                    u.* = au;
                },
                .zero => {
                    v.* = bv;
                    u.* = bu;
                },
                .x, .z => {
                    u.* = au | bu | (av ^ bv);
                    v.* = av | u.*;
                },
            }
        }
        out.clearPadding();
        return out;
    }

    fn extendedWord(self: Literal, plane: []const u64, index: usize, extension: Extension) u64 {
        const last = (self.width - 1) / 64;
        const sign = (plane[last] >> @as(u6, @truncate(self.width - 1))) & 1;
        const fill = if (extension == .sign) 0 -% sign else 0;
        if (index > last) return fill;
        if (index == last) return (plane[index] & mask(self.width)) | (fill & ~mask(self.width));
        return plane[index];
    }

    fn clearPadding(self: Literal) void {
        const last = wordCount(self.width) - 1;
        self.values()[last] &= mask(self.width);
        self.unknowns()[last] &= mask(self.width);
    }
};

fn wordCount(width: u32) usize {
    return (@as(usize, width) - 1) / 64 + 1;
}

fn allocate(allocator: std.mem.Allocator, width: u32, signed: bool) std.mem.Allocator.Error!Literal {
    std.debug.assert(width != 0);
    return .{ .width = width, .sized = true, .signed = signed, .planes = try allocator.alloc(u64, wordCount(width) * 2) };
}

fn invert(value: Bit) Bit {
    return switch (value) {
        .zero => .one,
        .one => .zero,
        .x, .z => .x,
    };
}

fn mask(width: u32) u64 {
    const n: u6 = @truncate(width);
    return if (n == 0) std.math.maxInt(u64) else (@as(u64, 1) << n) - 1;
}

/// The widest a number literal may be (E1019), by its size or, unsized, by
/// the width its digits need: the largest a `Literal.width` (u32, as every
/// stage carries a width) can hold. Not a policy bound: a literal of this
/// width allocates 1 GiB of planes, so memory runs out first.
pub const max_width: u32 = std.math.maxInt(u32);

/// §2.6.1 the radix `text`'s base format names: 2, 8, 10 or 16, and 10 for
/// a literal without one. `text` is one `parse` accepted.
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

/// Parses one §2.6.1 number token (size, `'`, optional `s`, base, digits;
/// white space allowed around the base) into a `Literal` whose planes are
/// allocated from `arena`; the caller owns them. A sized value wider than its
/// size is truncated from the left. An unsized literal is at least 64 bits
/// wide and, when it has no X or Z digit, only as wide as its value needs. A
/// simple decimal number (no base format) is signed (§2.6.1) and gets no
/// extra sign bit, so one of 2^63 or more has its top bit set and reads
/// negative.
///
/// Fails with `MissingBase` for a `'` with no base letter, `MissingDigits`
/// for no digits, `ZeroSize` for a size of 0, `DigitOutOfRange` for a digit
/// the base does not have (an X/Z digit in a simple decimal, a size with a
/// leading 0) and `Overflow` when the width passes `max_width`.
pub fn parse(arena: std.mem.Allocator, text: []const u8) (Error || std.mem.Allocator.Error)!Literal {
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
        if (width > max_width) return error.Overflow;
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
        if (least > max_width) return error.Overflow;
    }
    // Decimal gets an upper bound while accumulating, then loses unused limbs.
    if (!sized) width = @max(64, std.math.mul(u32, count, shift) catch return error.Overflow);
    const words = (@as(usize, width) + 63) / 64;
    const planes = try arena.alloc(u64, words * 2);
    errdefer arena.free(planes);
    @memset(planes, 0);
    var literal: Literal = .{ .width = width, .sized = sized, .signed = signed, .planes = planes };
    if (radix == 10 and any_unknown) {
        @memset(literal.unknowns(), std.math.maxInt(u64));
        if (std.ascii.toLower(digits[0]) == 'x') @memset(literal.values(), std.math.maxInt(u64));
    } else if (radix == 10) {
        if (std.mem.findScalar(u8, digits, '_') == null) {
            try decimalWords(arena, literal.values(), digits);
        } else {
            const plain = try arena.alloc(u8, count);
            defer arena.free(plain);
            var n: usize = 0;
            for (digits) |c| if (c != '_') {
                plain[n] = c;
                n += 1;
            };
            try decimalWords(arena, literal.values(), plain);
        }
    } else {
        // A power-of-two radix places each digit's `shift` bits directly,
        // from the least significant digit up: linear in the digits, where
        // shifting the whole value per digit was O(digits * words). Digits
        // above `width` are the left truncation a sized literal gets.
        var bit: u64 = 0;
        var i = digits.len;
        while (i > 0 and bit < width) {
            i -= 1;
            const c = digits[i];
            if (c == '_') continue;
            const unknown = c == 'x' or c == 'X' or c == 'z' or c == 'Z' or c == '?';
            const group: u64 = (@as(u64, 1) << shift) - 1;
            const val: u64 = if (unknown) (if (std.ascii.toLower(c) == 'x') group else 0) else (std.fmt.charToDigit(c, radix) catch unreachable);
            const unk: u64 = if (unknown) group else 0;
            const w: usize = @intCast(bit / 64);
            const off: u6 = @intCast(bit % 64);
            literal.values()[w] |= val << off;
            literal.unknowns()[w] |= unk << off;
            // A group straddling a word boundary spills its high bits.
            if (@as(u64, off) + shift > 64 and w + 1 < words) {
                const back: u6 = @intCast(64 - @as(u7, off));
                literal.values()[w + 1] |= val >> back;
                literal.unknowns()[w + 1] |= unk >> back;
            }
            bit += shift;
        }
        if (radix != 10 and any_unknown) {
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
    }
    literal.values()[words - 1] &= mask(width);
    literal.unknowns()[words - 1] &= mask(width);
    // Unsized known literals need only their actual bits, with the host integer
    // floor. Preserve allocated plane strides, which need not equal ceil(width/64).
    if (!sized and !any_unknown) {
        var actual: u32 = 0;
        for (literal.values(), 0..) |word, i| {
            if (word != 0) actual = @intCast(i * 64 + 64 - @clz(word));
        }
        literal.width = @max(64, actual);
        if (literal.width > max_width) return error.Overflow;
    }
    return literal;
}

/// Digits up to which `decimalWords` multiply-accumulates, and the leaf size
/// of its divide and conquer.
const dc_digits: usize = 1024;

/// The decimal digits `ds` (no `_`) into `out`, little-endian 64-bit words,
/// reduced mod 2^(64 * out.len): the left truncation a sized literal gets.
/// Up to `dc_digits` digits a multiply-accumulate over the words written so
/// far; past it divide and conquer, value = hi * 10^n + lo with n a
/// power-of-two multiple of `dc_digits`, whose products std multiplies by
/// Karatsuba: O(digits^1.59 log digits), where the multiply-accumulate alone
/// is O(digits^2). Temporaries come from `gpa` and are freed.
fn decimalWords(gpa: std.mem.Allocator, out: []u64, ds: []const u8) std.mem.Allocator.Error!void {
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
        return;
    }
    const Big = std.math.big.int.Managed;
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

/// `decimalWords`' divide and conquer: split `ds` above its largest
/// `dc_digits * 2^k` low digits, so `pows[k]` is the shift.
fn decimalBig(gpa: std.mem.Allocator, ds: []const u8, pows: []const std.math.big.int.Managed) std.mem.Allocator.Error!std.math.big.int.Managed {
    var r = try std.math.big.int.Managed.init(gpa);
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
    const n = dc_digits << @intCast(k);
    var hi = try decimalBig(gpa, ds[0 .. ds.len - n], pows);
    defer hi.deinit();
    var lo = try decimalBig(gpa, ds[ds.len - n ..], pows);
    defer lo.deinit();
    try r.mul(&hi, &pows[k]);
    try r.add(&r, &lo);
    return r;
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
        for ([_]usize{ 1, len / 19 + 2 }) |words| {
            const got = try gpa.alloc(u64, words);
            defer gpa.free(got);
            try decimalWords(gpa, got, ds);
            const want = try gpa.alloc(u64, words);
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

// Scalar truth tables are the oracle for packed words, in 0/1/X/Z order.
const truth_states = [_]Bit{ .zero, .one, .x, .z };
const and_truth = [4][4]Bit{
    .{ .zero, .zero, .zero, .zero },
    .{ .zero, .one, .x, .x },
    .{ .zero, .x, .x, .x },
    .{ .zero, .x, .x, .x },
};
const or_truth = [4][4]Bit{
    .{ .zero, .one, .x, .x },
    .{ .one, .one, .one, .one },
    .{ .x, .one, .x, .x },
    .{ .x, .one, .x, .x },
};
const xor_truth = [4][4]Bit{
    .{ .zero, .one, .x, .x },
    .{ .one, .zero, .x, .x },
    .{ .x, .x, .x, .x },
    .{ .x, .x, .x, .x },
};
const merge_truth = [4][4]Bit{
    .{ .zero, .x, .x, .x },
    .{ .x, .one, .x, .x },
    .{ .x, .x, .x, .x },
    .{ .x, .x, .x, .x },
};

fn testScalar(storage: *[2]u64, state: Bit) Literal {
    storage.* = .{ @backingInt(state) & 1, @backingInt(state) >> 1 };
    return .{ .width = 1, .signed = false, .sized = true, .planes = storage };
}

fn testPut(value: Literal, index: u32, state: Bit) void {
    const bit_mask = @as(u64, 1) << @as(u6, @truncate(index));
    const word = index / 64;
    value.values()[word] = (value.values()[word] & ~bit_mask) | (if (@backingInt(state) & 1 != 0) bit_mask else 0);
    value.unknowns()[word] = (value.unknowns()[word] & ~bit_mask) | (if (@backingInt(state) & 2 != 0) bit_mask else 0);
}

fn testStateIndex(state: Bit) usize {
    return switch (state) {
        .zero => 0,
        .one => 1,
        .x => 2,
        .z => 3,
    };
}

test "four-state scalar operators exhaust IEEE1364 truth tables" {
    const allocator = std.testing.allocator;
    for (truth_states, 0..) |a, ai| {
        var a_storage: [2]u64 = undefined;
        const lhs = testScalar(&a_storage, a);
        const neg = try lhs.bitwiseNot(allocator);
        defer allocator.free(neg.planes);
        try std.testing.expectEqual(invert(a), neg.bit(0));
        try std.testing.expectEqual(invert(a), invert(lhs.truth()));
        for (truth_states, 0..) |b, bi| {
            var b_storage: [2]u64 = undefined;
            const rhs = testScalar(&b_storage, b);
            inline for (std.meta.tags(Bitwise)) |op| {
                const out = try lhs.bitwise(allocator, op, rhs);
                defer allocator.free(out.planes);
                const expected = switch (op) {
                    .and_bits => and_truth[ai][bi],
                    .or_bits => or_truth[ai][bi],
                    .xor_bits => xor_truth[ai][bi],
                    .xnor_bits => invert(xor_truth[ai][bi]),
                };
                try std.testing.expectEqual(expected, out.bit(0));
                try std.testing.expectEqual(@as(u32, 1), out.width);
                try std.testing.expect(!out.signed);
                try std.testing.expectEqualSlices(u64, &.{ @backingInt(expected) & 1, @backingInt(expected) >> 1 }, out.planes);
            }
            try std.testing.expectEqual(and_truth[ai][bi], lhs.logical(.and_bits, rhs));
            try std.testing.expectEqual(or_truth[ai][bi], lhs.logical(.or_bits, rhs));
            const logical_eq: Bit = if (ai >= 2 or bi >= 2) .x else if (a == b) .one else .zero;
            const case_eq: Bit = if (a == b) .one else .zero;
            try std.testing.expectEqual(logical_eq, lhs.equality(.equal, rhs));
            try std.testing.expectEqual(invert(logical_eq), lhs.equality(.not_equal, rhs));
            try std.testing.expectEqual(case_eq, lhs.equality(.case_equal, rhs));
            try std.testing.expectEqual(invert(case_eq), lhs.equality(.case_not_equal, rhs));
            for (truth_states) |condition| {
                var c_storage: [2]u64 = undefined;
                const c = testScalar(&c_storage, condition);
                const out = try c.conditional(allocator, lhs, rhs);
                defer allocator.free(out.planes);
                const expected = switch (condition) {
                    .zero => b,
                    .one => a,
                    .x, .z => merge_truth[ai][bi],
                };
                try std.testing.expectEqual(expected, out.bit(0));
            }
        }
        // Single-bit reductions still turn Z into X.
        const normal: Bit = if (a == .z) .x else a;
        inline for (std.meta.tags(Reduction)) |op| {
            const expected = switch (op) {
                .nand_bits, .nor_bits, .xnor_bits => invert(normal),
                else => normal,
            };
            try std.testing.expectEqual(expected, lhs.reduce(op));
        }
    }
}

test "packed reductions exhaust four-bit vectors and equality known mismatch wins" {
    // 4^4 vectors cover controlling 0/1 in every position among X/Z.
    for (0..256) |pattern| {
        var storage = [_]u64{ 0, 0 };
        const value: Literal = .{ .width = 4, .sized = true, .signed = false, .planes = &storage };
        var and_value: Bit = .one;
        var or_value: Bit = .zero;
        var xor_value: Bit = .zero;
        for (0..4) |i| {
            const state_index = (pattern >> @as(u6, @intCast(i * 2))) & 3;
            testPut(value, @intCast(i), truth_states[state_index]);
            and_value = and_truth[testStateIndex(and_value)][state_index];
            or_value = or_truth[testStateIndex(or_value)][state_index];
            xor_value = xor_truth[testStateIndex(xor_value)][state_index];
        }
        try std.testing.expectEqual(and_value, value.reduce(.and_bits));
        try std.testing.expectEqual(invert(and_value), value.reduce(.nand_bits));
        try std.testing.expectEqual(or_value, value.reduce(.or_bits));
        try std.testing.expectEqual(invert(or_value), value.reduce(.nor_bits));
        try std.testing.expectEqual(xor_value, value.reduce(.xor_bits));
        try std.testing.expectEqual(invert(xor_value), value.reduce(.xnor_bits));
        try std.testing.expectEqual(or_value, value.truth());
    }
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = try parse(arena, "129'h10000000000000000000000000000000x");
    const b = try parse(arena, "129'h00000000000000000000000000000000z");
    try std.testing.expectEqual(Bit.zero, a.equality(.equal, b));
    try std.testing.expectEqual(Bit.one, a.equality(.not_equal, b));
    try std.testing.expectEqual(Bit.one, a.truth());
    try std.testing.expectEqual(Bit.x, b.truth());
    try std.testing.expectEqual(Bit.zero, invert(a.truth()));
}

test "packed bitwise operations match scalar oracle across partial and multiple words" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var random_state = std.Random.DefaultPrng.init(0x13642005);
    const random = random_state.random();
    for ([_]u32{ 1, 31, 32, 33, 63, 64, 65, 127, 128, 129, 257, 65536 }) |width| {
        const a = try allocate(arena, width, false);
        const b = try allocate(arena, width, false);
        for (a.planes, b.planes) |*av, *bv| {
            av.* = random.int(u64);
            bv.* = random.int(u64);
        }
        a.clearPadding();
        b.clearPadding();
        const ones = try allocate(arena, width, false);
        @memset(ones.values(), std.math.maxInt(u64));
        @memset(ones.unknowns(), 0);
        ones.clearPadding();
        try std.testing.expectEqual(Bit.one, ones.reduce(.and_bits));
        try std.testing.expectEqual(Bit.one, ones.reduce(.or_bits));
        try std.testing.expectEqual(if (width % 2 == 0) Bit.zero else Bit.one, ones.reduce(.xor_bits));
        for ([_]Bit{ .x, .z }) |state| {
            testPut(ones, width - 1, state);
            try std.testing.expectEqual(Bit.x, ones.reduce(.and_bits));
            try std.testing.expectEqual(if (width > 1) Bit.one else Bit.x, ones.reduce(.or_bits));
            try std.testing.expectEqual(Bit.x, ones.reduce(.xor_bits));
        }
        const neg = try a.bitwiseNot(arena);
        var c_storage: [2]u64 = undefined;
        const unknown = testScalar(&c_storage, .x);
        const merged = try unknown.conditional(arena, a, b);
        inline for (std.meta.tags(Bitwise)) |op| {
            const out = try a.bitwise(arena, op, b);
            for (0..width) |i| {
                const index: u32 = @intCast(i);
                const ai = testStateIndex(a.bit(index));
                const bi = testStateIndex(b.bit(index));
                const expected = switch (op) {
                    .and_bits => and_truth[ai][bi],
                    .or_bits => or_truth[ai][bi],
                    .xor_bits => xor_truth[ai][bi],
                    .xnor_bits => invert(xor_truth[ai][bi]),
                };
                try std.testing.expectEqual(expected, out.bit(index));
                try std.testing.expectEqual(invert(a.bit(index)), neg.bit(index));
                try std.testing.expectEqual(merge_truth[ai][bi], merged.bit(index));
            }
            const last = wordCount(width) - 1;
            try std.testing.expectEqual(@as(u64, 0), out.values()[last] & ~mask(width));
            try std.testing.expectEqual(@as(u64, 0), out.unknowns()[last] & ~mask(width));
        }
    }
}

test "resize preserves four-state sign bits and masks truncation at word boundaries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]u32{ 1, 31, 32, 63, 64, 65, 127, 128, 129 }) |width| {
        for (truth_states) |sign| {
            const a = try allocate(arena, width, true);
            @memset(a.planes, 0);
            testPut(a, width - 1, sign);
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
    const condition = testScalar(&condition_storage, .x);
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
    try std.testing.expect(spare.values().len > wordCount(spare.width));
    const compact = try spare.resize(arena, 65, .zero);
    try std.testing.expectEqualSlices(u64, &.{ 1, 0 }, compact.values());
    try std.testing.expectEqual(Bit.one, spare.equality(.equal, compact));
}

fn testPattern(storage: *[2]u64, width: u32, signed: bool, pattern: usize) Literal {
    storage.* = .{ 0, 0 };
    const out: Literal = .{ .width = width, .sized = true, .signed = signed, .planes = storage };
    for (0..width) |i|
        testPut(out, @intCast(i), truth_states[(pattern >> @as(u6, @intCast(i * 2))) & 3]);
    return out;
}

// Independent small-vector oracle: decode each scalar state to a mathematical
// integer, then apply Zig comparisons. Packed comparison words are not reused.
fn testNumber(value: Literal, signed: bool) ?i32 {
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

test "four-state shifts exhaust four-bit scalar state patterns" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (0..256) |pattern| {
        for ([_]bool{ false, true }) |signed| {
            var storage: [2]u64 = undefined;
            const value = testPattern(&storage, 4, signed, pattern);
            for (0..7) |count| {
                var count_storage = [_]u64{ count, 0 };
                const rhs: Literal = .{ .width = 4, .sized = true, .signed = true, .planes = &count_storage };
                inline for (std.meta.tags(Shift)) |op| {
                    const out = try value.shift(arena, op, rhs);
                    try std.testing.expectEqual(value.width, out.width);
                    try std.testing.expectEqual(value.signed, out.signed);
                    try std.testing.expect(out.planes.ptr != value.planes.ptr);
                    for (0..4) |index|
                        try std.testing.expectEqual(testShiftBit(value, op, count, @intCast(index)), out.bit(@intCast(index)));
                }
            }
        }
    }
}

test "packed shifts preserve X Z and carries across word boundaries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var random_state = std.Random.DefaultPrng.init(0x5122005);
    const random = random_state.random();
    for ([_]u32{ 1, 31, 32, 33, 63, 64, 65, 127, 128, 129, 257, 65536 }) |width| {
        for ([_]bool{ false, true }) |signed| {
            const value = try allocate(arena, width, signed);
            for (value.planes) |*word| word.* = random.int(u64);
            value.clearPadding();
            for ([_]u64{ 0, 1, 31, 32, 63, 64, 65, width - 1, width, @as(u64, width) + 1 }) |count| {
                var count_storage = [_]u64{ count, 0 };
                const rhs: Literal = .{ .width = 64, .sized = true, .signed = false, .planes = &count_storage };
                inline for (std.meta.tags(Shift)) |op| {
                    const out = try value.shift(arena, op, rhs);
                    for (0..width) |index|
                        try std.testing.expectEqual(testShiftBit(value, op, count, @intCast(index)), out.bit(@intCast(index)));
                    const last = wordCount(width) - 1;
                    try std.testing.expectEqual(@as(u64, 0), out.values()[last] & ~mask(width));
                    try std.testing.expectEqual(@as(u64, 0), out.unknowns()[last] & ~mask(width));
                }
            }
        }
    }
}

test "shift count is unsigned self-determined and never truncated" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try parse(arena, "129'sh1abcd56780000000000000000a5f0zx10");
    const original = try arena.dupe(u64, source.planes);
    for ([_][]const u8{ "65'h10000000000000000", "128'h80000000000000000000000000000000", "64'shffffffffffffffff" }) |text| {
        const count = try parse(arena, text);
        inline for (std.meta.tags(Shift)) |op| {
            const out = try source.shift(arena, op, count);
            for (0..source.width) |index|
                try std.testing.expectEqual(if (op == .arithmetic_right) source.bit(source.width - 1) else Bit.zero, out.bit(@intCast(index)));
        }
    }
    for ([_][]const u8{ "129'hx00000000000000000000000000000000", "129'hz00000000000000000000000000000000", "4'b00x0", "4'b00z0" }) |text| {
        const count = try parse(arena, text);
        inline for (std.meta.tags(Shift)) |op| {
            const out = try source.shift(arena, op, count);
            for (0..source.width) |index| try std.testing.expectEqual(Bit.x, out.bit(@intCast(index)));
        }
    }
    // A signed four-bit -1 is an unsigned shift count of 15, not 2^64-1.
    const fifteen = try parse(arena, "4'shf");
    const shifted = try source.shift(arena, .left, fifteen);
    for (0..source.width) |index|
        try std.testing.expectEqual(testShiftBit(source, .left, 15, @intCast(index)), shifted.bit(@intCast(index)));
    const one = try parse(arena, "1'b1");
    const negative = try parse(arena, "4'sb1000");
    const normalized = try negative.resize(arena, 8, .sign);
    const arithmetic = try normalized.shift(arena, .arithmetic_right, one);
    try std.testing.expectEqualSlices(u64, &.{ 0xfc, 0 }, arithmetic.planes);
    var unsigned_context = try negative.resize(arena, 8, .zero);
    unsigned_context.signed = false;
    const logical = try unsigned_context.shift(arena, .arithmetic_right, one);
    try std.testing.expectEqualSlices(u64, &.{ 4, 0 }, logical.planes);
    for ([_][]const u8{ "1'sbx", "1'sbz" }) |text| {
        const sign = try parse(arena, text);
        const out = try sign.shift(arena, .arithmetic_right, fifteen);
        try std.testing.expectEqual(sign.bit(0), out.bit(0));
    }
    const spare_count = try parse(arena, "000000000000000000000000000000000000000000001");
    const small_shift = try negative.shift(arena, .left, spare_count);
    try std.testing.expectEqualSlices(u64, &.{ 0, 0 }, small_shift.planes);
    try std.testing.expectEqualSlices(u64, original, source.planes);
}

test "four-state relations exhaust small vectors and mixed signedness" {
    for ([_]u32{ 1, 2, 3 }) |aw| {
        for ([_]u32{ 1, 2, 3 }) |bw| {
            for (0..@as(usize, 1) << @intCast(2 * aw)) |ap| {
                for (0..@as(usize, 1) << @intCast(2 * bw)) |bp| {
                    for ([_]bool{ false, true }) |as| {
                        for ([_]bool{ false, true }) |bs| {
                            var a_storage: [2]u64 = undefined;
                            var b_storage: [2]u64 = undefined;
                            const a = testPattern(&a_storage, aw, as, ap);
                            const b = testPattern(&b_storage, bw, bs, bp);
                            const an = testNumber(a, as and bs);
                            const bn = testNumber(b, as and bs);
                            inline for (std.meta.tags(Relational)) |op| {
                                const expected: Bit = if (an == null or bn == null) .x else if (switch (op) {
                                    .less => an.? < bn.?,
                                    .less_equal => an.? <= bn.?,
                                    .greater => an.? > bn.?,
                                    .greater_equal => an.? >= bn.?,
                                }) .one else .zero;
                                try std.testing.expectEqual(expected, a.relational(op, b));
                            }
                        }
                    }
                }
            }
        }
    }
}

test "relational signed normalization spans partial and multiple words" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]u32{ 1, 31, 32, 63, 64, 65, 127, 128, 129, 257, 65536 }) |width| {
        var a = try allocate(arena, width, false);
        @memset(a.planes, 0);
        testPut(a, width - 1, .one);
        var b = try allocate(arena, width, false);
        @memset(b.planes, 0);
        for (0..width - 1) |i| testPut(b, @intCast(i), .one);
        try std.testing.expectEqual(Bit.one, a.relational(.greater, b));
        try std.testing.expectEqual(Bit.zero, a.relational(.less_equal, b));
        a.signed = true;
        b.signed = true;
        try std.testing.expectEqual(Bit.one, a.relational(.less, b));
        try std.testing.expectEqual(Bit.zero, a.relational(.greater_equal, b));
        try std.testing.expectEqual(Bit.one, a.relational(.less_equal, a));
        try std.testing.expectEqual(Bit.one, a.relational(.greater_equal, a));
        for ([_]Bit{ .x, .z }) |unknown| {
            // Unknown wins even when a different known high bit orders the pair.
            testPut(b, 0, unknown);
            inline for (std.meta.tags(Relational)) |op|
                try std.testing.expectEqual(Bit.x, a.relational(op, b));
        }
    }
    const minus_one = try parse(arena, "4'shf");
    for ([_]u32{ 5, 63, 64, 65, 128, 129, 257 }) |width| {
        var ten = try allocate(arena, width, true);
        @memset(ten.planes, 0);
        ten.values()[0] = 10;
        try std.testing.expectEqual(Bit.one, minus_one.relational(.less, ten));
        ten.signed = false;
        try std.testing.expectEqual(Bit.one, minus_one.relational(.greater, ten));
        const same_negative = try minus_one.resize(arena, width, .sign);
        try std.testing.expectEqual(Bit.one, minus_one.relational(.less_equal, same_negative));
        try std.testing.expectEqual(Bit.one, minus_one.relational(.greater_equal, same_negative));
        try std.testing.expectEqual(Bit.zero, minus_one.relational(.greater, same_negative));
    }
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
    const last = wordCount(actual.width) - 1;
    try std.testing.expectEqual(@as(u64, 0), actual.values()[last] & ~mask(actual.width));
    try std.testing.expectEqual(@as(u64, 0), actual.unknowns()[last] & ~mask(actual.width));
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

test "packed arithmetic exhausts small four-state operands and signedness" {
    const allocator = std.testing.allocator;
    var aa: [2]u64 = undefined;
    var bb: [2]u64 = undefined;
    for (1..4) |aw| {
        for (0..@as(usize, 1) << @intCast(2 * aw)) |ap| {
            inline for (.{ false, true }) |sa| {
                const a = testPattern(&aa, @intCast(aw), sa, ap);
                const av = testNumber(a, sa);
                const negated = try a.negate(allocator);
                defer allocator.free(negated.planes);
                try std.testing.expectEqual(a.width, negated.width);
                try std.testing.expectEqual(sa, negated.signed);
                try testArithmeticResult(negated, if (av) |v| -@as(i1025, v) else null);
                for (1..4) |bw| {
                    for (0..@as(usize, 1) << @intCast(2 * bw)) |bp| {
                        inline for (.{ false, true }) |sb| {
                            const b = testPattern(&bb, @intCast(bw), sb, bp);
                            const signed = sa and sb;
                            const x = testNumber(a, signed);
                            const y = testNumber(b, signed);
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

fn testWideNumber(value: Literal, signed: bool) i1025 {
    var result: i1025 = 0;
    for (0..value.width) |i| {
        if (value.bit(@intCast(i)) == .one) result += @as(i1025, 1) << @intCast(i);
    }
    if (signed and value.bit(value.width - 1) == .one)
        result -= @as(i1025, 1) << @intCast(value.width);
    return result;
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
                    const a = try allocate(arena, aw, sa);
                    const b = try allocate(arena, bw, sb);
                    for (a.values()) |*word| word.* = random.int(u64);
                    for (b.values()) |*word| word.* = random.int(u64);
                    @memset(a.unknowns(), 0);
                    @memset(b.unknowns(), 0);
                    a.clearPadding();
                    b.clearPadding();
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
        const ones = try allocate(arena, width, false);
        @memset(ones.values(), std.math.maxInt(u64));
        @memset(ones.unknowns(), 0);
        ones.clearPadding();
        const zero = try allocate(arena, width, false);
        @memset(zero.planes, 0);
        const one = try allocate(arena, width, false);
        @memset(one.planes, 0);
        one.values()[0] = 1;
        const three = try parse(arena, "2'b11");
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
        const minimum = try allocate(arena, width, true);
        @memset(minimum.planes, 0);
        testPut(minimum, width - 1, .one);
        var minus_one = ones;
        minus_one.signed = true;
        const divided_minimum = try minimum.arithmetic(arena, .divide, minus_one);
        const negated_minimum = try minimum.negate(arena);
        try std.testing.expectEqualSlices(u64, minimum.planes, divided_minimum.planes);
        try std.testing.expectEqualSlices(u64, minimum.planes, negated_minimum.planes);
        try std.testing.expectEqualSlices(u64, zero.planes, (try minimum.arithmetic(arena, .remainder, minus_one)).planes);
        try std.testing.expectEqualSlices(u64, zero.planes, (try minimum.arithmetic(arena, .add, minimum)).planes);
        const two = try parse(arena, "3'sb010");
        try std.testing.expectEqualSlices(u64, zero.planes, (try minimum.arithmetic(arena, .multiply, two)).planes);
        for ([_]u32{ 0, width / 2, width - 1 }) |bit_index| {
            inline for (.{ Bit.x, Bit.z }) |state| {
                const unknown = try ones.resize(arena, width, .zero);
                testPut(unknown, bit_index, state);
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
    const a = try parse(arena, "4'hf");
    const b = try parse(arena, "4'h1");
    try testArithmeticResult(try a.arithmetic(arena, .add, b), 0);
    const wider_a = try a.resize(arena, 8, .zero);
    const wider_b = try b.resize(arena, 8, .zero);
    try testArithmeticResult(try wider_a.arithmetic(arena, .add, wider_b), 16);
    const signed = try parse(arena, "4'sh8");
    const sign_extended = try signed.resize(arena, 8, .sign);
    const signed_one = try parse(arena, "8'sh1");
    try testArithmeticResult(try sign_extended.arithmetic(arena, .add, signed_one), -7);
    // A caller's propagated unsigned context zero-extends the original bits.
    var unsigned = try signed.resize(arena, 8, .zero);
    unsigned.signed = false;
    try testArithmeticResult(try unsigned.arithmetic(arena, .add, wider_b), 9);
    var av: [2]u64 = .{ std.math.maxInt(u64), std.math.maxInt(u64) ^ 15 };
    const padded: Literal = .{ .width = 4, .signed = false, .sized = true, .planes = &av };
    try testArithmeticResult(try padded.arithmetic(arena, .add, b), 0);
    try testArithmeticResult(try padded.negate(arena), 1);
    const spare = try parse(arena, "000000000000000000000000000000000000000000001");
    try std.testing.expect(spare.values().len > wordCount(spare.width));
    const spare_sum = try spare.arithmetic(arena, .add, b);
    try testArithmeticResult(spare_sum, 2);
}

fn testArithmeticAllocation(allocator: std.mem.Allocator) !void {
    const a = try parse(allocator, "257'sh1fedcba9876543210fedcba98765432100123456789abcdef0123456789abcdef0");
    defer allocator.free(a.planes);
    const b = try parse(allocator, "129'sh1fedcba98765432100123456789abcdef0");
    defer allocator.free(b.planes);
    for (std.enums.values(Arithmetic)) |op| {
        const result = try a.arithmetic(allocator, op, b);
        allocator.free(result.planes);
    }
    const negated = try a.negate(allocator);
    allocator.free(negated.planes);
}

test "packed arithmetic frees partial allocations on every failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testArithmeticAllocation, .{});
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

test "packed power exhausts small four-state operands with independent signedness" {
    const allocator = std.testing.allocator;
    var aa: [2]u64 = undefined;
    var bb: [2]u64 = undefined;
    for (1..4) |aw| for (1..4) |bw| {
        for (0..@as(usize, 1) << @intCast(2 * aw)) |ap| {
            inline for (.{ false, true }) |sa| {
                const a = testPattern(&aa, @intCast(aw), sa, ap);
                const av = testNumber(a, sa);
                for (0..@as(usize, 1) << @intCast(2 * bw)) |bp| {
                    inline for (.{ false, true }) |sb| {
                        const b = testPattern(&bb, @intCast(bw), sb, bp);
                        const bv = testNumber(b, sb);
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
    const seventeen = try parse(arena, "8'd17");
    for ([_]u32{ 1, 31, 32, 63, 64, 65, 127, 128, 129, 257, 511 }) |width| {
        const a = try allocate(arena, width, false);
        @memset(a.planes, 0);
        a.values()[0] = 29;
        a.clearPadding();
        var mathematical: i1025 = 1;
        for (0..17) |_| mathematical *= if (width < 64) @as(i1025, @intCast(29 & mask(width))) else 29;
        try testArithmeticResult(try a.power(arena, seventeen), mathematical);
    }

    // (2^128 + 3)^3 mod 2^257 = 2^256 + 27*2^128 + 27.
    const wide_base = try allocate(arena, 257, false);
    @memset(wide_base.planes, 0);
    wide_base.values()[0] = 3;
    wide_base.values()[2] = 1;
    const three = try parse(arena, "4'd3");
    const cube = try wide_base.power(arena, three);
    try std.testing.expectEqualSlices(u64, &.{ 27, 0, 27, 0, 1 }, cube.values());
    try std.testing.expect(!cube.hasUnknown());

    const huge = try allocate(arena, 129, false);
    @memset(huge.planes, 0);
    huge.values()[2] = 1;
    huge.values()[0] = 1;
    const base_three = try three.resize(arena, 129, .zero);
    // Euler's theorem: 3^(2^128+1) = 3 modulo 2^129.
    try testArithmeticResult(try base_three.power(arena, huge), 3);
    var negative = huge;
    negative.signed = true;
    try testArithmeticResult(try base_three.power(arena, negative), 0);
    const minus_one = try parse(arena, "65'sh1ffffffffffffffff");
    try testArithmeticResult(try minus_one.power(arena, negative), -1);
    huge.values()[0] = 0;
    try testArithmeticResult(try minus_one.power(arena, negative), 1);

    const very_wide = try allocate(arena, 4097, false);
    @memset(very_wide.planes, 0);
    very_wide.values()[0] = 2;
    const boundary = try parse(arena, "32'd4096");
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

fn testPowerAllocation(allocator: std.mem.Allocator) !void {
    const a = try parse(allocator, "129'h100000000000000000000000000000003");
    defer allocator.free(a.planes);
    const b = try parse(allocator, "65'd17");
    defer allocator.free(b.planes);
    const result = try a.power(allocator, b);
    defer allocator.free(result.planes);
}

test "packed power allocation failures release every intermediate" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testPowerAllocation, .{});
}

/// A random operand of 1..64 bits, either signedness, with x/z bits in about
/// one operand in eight and a bias toward the words that end the ranges.
fn testRandomWord(random: std.Random, storage: *[2]u64) Literal {
    const width = random.intRangeAtMost(u32, 1, 64);
    const edges = [_]u64{ 0, 1, std.math.maxInt(u64), @as(u64, 1) << 63, (@as(u64, 1) << 63) - 1, 2 };
    storage[0] = if (random.boolean()) edges[random.uintLessThan(usize, edges.len)] else random.int(u64);
    storage[1] = if (random.uintLessThan(u8, 8) == 0) random.int(u64) else 0;
    const out: Literal = .{ .width = width, .sized = true, .signed = random.boolean(), .planes = storage };
    out.clearPadding();
    return out;
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
            const want = try a.arithmeticIn(arena, op, b, false);
            const got = try a.arithmeticIn(arena, op, b, true);
            try std.testing.expectEqual(want.width, got.width);
            try std.testing.expectEqual(want.signed, got.signed);
            try std.testing.expectEqualSlices(u64, want.planes, got.planes);
        }
        try std.testing.expectEqualSlices(u64, (try a.negateIn(arena, false)).planes, (try a.negateIn(arena, true)).planes);
        try std.testing.expectEqualSlices(u64, (try a.powerIn(arena, b, false)).planes, (try a.powerIn(arena, b, true)).planes);
    }
}

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
    const last = wordCount(result.width) - 1;
    try std.testing.expectEqual(@as(u64, 0), (result.values()[last] | result.unknowns()[last]) & ~mask(result.width));
}

test "concatenation and replication match a scalar bit oracle" {
    const allocator = std.testing.allocator;
    var a_planes: [2]u64 = undefined;
    var b_planes: [2]u64 = undefined;
    for (1..4) |aw| for (1..4) |bw| {
        for (0..@as(usize, 1) << @intCast(2 * aw)) |ap| {
            const a = testPattern(&a_planes, @intCast(aw), true, ap);
            for (0..@as(usize, 1) << @intCast(2 * bw)) |bp| {
                const b = testPattern(&b_planes, @intCast(bw), true, bp);
                try testConcatOracle(allocator, &.{ a, b }, 2);
            }
        }
    };
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts: [8]Literal = undefined;
    for ([_]u32{ 1, 63, 64, 65, 127, 128, 129, 257 }, 0..) |width, n| {
        const part = try allocate(arena, width, n % 2 == 0);
        @memset(part.planes, 0);
        for (0..width) |i| testPut(part, @intCast(i), @fromBackingInt(@intCast((i * 7 + n) % 4)));
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

test "concatenation allocation failures release input and result storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testConcatAllocation, .{});
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

fn testParseAllocation(allocator: std.mem.Allocator, text: []const u8) !void {
    const v = try parse(allocator, text);
    allocator.free(v.planes);
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

test "an allocation failure in a one-allocation operation leaks nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testOneAllocation, .{});
}
