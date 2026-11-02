//! IEEE 1364-2005 §5.1's four-state logic over `Literal`s: operands in, the
//! result literal or bit out. Bitwise operators, shifts, relations,
//! equality, reductions, the logical operators and the conditional, each
//! reached as a `Literal` method (`integer.zig`). Each allocating operator
//! returns fresh planes from its `gpa`, owned by the caller.
//! Cites: IEEE 1364-2005 §5.1.7-§5.1.13 (Tables 5-12 to 5-21), §5.4, §5.5.
//!
//! Sizing is self-determined: a surrounding expression propagates its width
//! and signedness to the operands first (§5.4, §5.5), and context-determined
//! operands extend by the propagated type (both signed: sign, else zero).
//!
//! Contents:
//! - `pub fn bitwiseNot(self: Literal, gpa: Allocator) Allocator.Error!Literal`
//! - `pub fn bitwise(self: Literal, gpa: Allocator, op: Bitwise, rhs: Literal) Allocator.Error!Literal`
//! - `pub fn shift(self: Literal, gpa: Allocator, op: Shift, rhs: Literal) Allocator.Error!Literal`
//! - `pub fn relational(self: Literal, op: Relational, rhs: Literal) Bit`
//! - `pub fn truth(self: Literal) Bit`
//! - `pub fn logical(self: Literal, op: Logical, rhs: Literal) Bit`
//! - `pub fn reduce(self: Literal, op: Reduction) Bit`
//! - `pub fn equality(self: Literal, op: Equality, rhs: Literal) Bit`
//! - `pub fn conditional(self: Literal, gpa: Allocator, yes: Literal, no: Literal) Allocator.Error!Literal`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const integer = @import("integer.zig");
const words = @import("integer_words.zig");
const Literal = integer.Literal;
const Bit = integer.Bit;
const Bitwise = integer.Bitwise;
const Shift = integer.Shift;
const Relational = integer.Relational;
const Logical = integer.Logical;
const Reduction = integer.Reduction;
const Equality = integer.Equality;
const Extension = words.Extension;
const fixture = @import("integer_fixture.zig");

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

/// Returns `~self` (IEEE 1364-2005 Table 5-16): X and Z both negate to X.
/// Caller owns the result's planes and frees them with `gpa`.
pub fn bitwiseNot(self: Literal, gpa: Allocator) Allocator.Error!Literal {
    const out = try words.allocate(gpa, self.width, self.signed);
    for (out.values(), out.unknowns(), 0..) |*v, *u, i| {
        u.* = self.unknowns()[i];
        v.* = ~self.values()[i] | u.*;
    }
    words.clearPadding(out);
    assert(out.width == self.width);
    return out;
}

/// Returns a bitwise operator applied (IEEE 1364-2005 Tables 5-12 to 5-15,
/// §§5.4 and 5.5) at the wider operand's width, signed iff both are. Caller
/// owns the result's planes and frees them with `gpa`.
pub fn bitwise(self: Literal, gpa: Allocator, op: Bitwise, rhs: Literal) Allocator.Error!Literal {
    const signed = self.signed and rhs.signed;
    const extension: Extension = if (signed) .sign else .zero;
    const out = try words.allocate(gpa, @max(self.width, rhs.width), signed);
    for (out.values(), out.unknowns(), 0..) |*v, *u, i| {
        const av = words.extendedWord(self, self.values(), i, extension);
        const au = words.extendedWord(self, self.unknowns(), i, extension);
        const bv = words.extendedWord(rhs, rhs.values(), i, extension);
        const bu = words.extendedWord(rhs, rhs.unknowns(), i, extension);
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
    words.clearPadding(out);
    assert(out.width == @max(self.width, rhs.width));
    return out;
}

/// Returns `self` shifted by `rhs` (IEEE 1364-2005 §5.1.12). The caller
/// propagates the result width and type to `self` first (§§5.4-5.5); `rhs`
/// is self-determined and unsigned and changes neither. Shifted X/Z
/// survive; an X/Z bit in `rhs` makes the whole result X. Caller owns the
/// result's planes and frees them with `gpa`.
pub fn shift(self: Literal, gpa: Allocator, op: Shift, rhs: Literal) Allocator.Error!Literal {
    const out = try words.allocate(gpa, self.width, self.signed);
    if (rhs.hasUnknown()) {
        words.fillUnknown(out);
        return out;
    }
    // A count at or past the width shifts every bit out; never truncated.
    const amount: u32 = count: {
        for (rhs.values()[1..words.wordCount(rhs.width)]) |word| {
            if (word != 0) break :count self.width;
        }
        break :count @intCast(@min(rhs.values()[0], self.width));
    };
    assert(amount <= self.width);
    const left = op == .left or op == .arithmetic_left;
    const extension: Extension = if (op == .arithmetic_right and self.signed) .sign else .zero;
    const whole: usize = amount / 64;
    const bits: u6 = @truncate(amount);
    inline for (.{ false, true }) |unknown| {
        const source = if (unknown) self.unknowns() else self.values();
        const dest = if (unknown) out.unknowns() else out.values();
        if (amount == self.width) {
            const sign = (source[(self.width - 1) / 64] >> @as(u6, @truncate(self.width - 1))) & 1;
            @memset(dest, if (extension == .sign) 0 -% sign else 0);
        } else for (dest, 0..) |*word, i| {
            if (left) {
                word.* = if (i >= whole) source[i - whole] << bits else 0;
                if (bits != 0 and i > whole)
                    word.* |= source[i - whole - 1] >> @as(u6, @intCast(64 - @as(u7, bits)));
            } else {
                word.* = words.extendedWord(self, source, i + whole, extension) >> bits;
                if (bits != 0)
                    word.* |= words.extendedWord(self, source, i + whole + 1, extension) << @as(u6, @intCast(64 - @as(u7, bits)));
            }
        }
    }
    words.clearPadding(out);
    return out;
}

/// Returns a relation's bit (IEEE 1364-2005 §5.1.7). Unlike equality's
/// known-mismatch rule, any X/Z operand makes the relation X. Both-signed
/// operands extend and compare as signed; otherwise both as unsigned.
pub fn relational(self: Literal, op: Relational, rhs: Literal) Bit {
    if (self.hasUnknown() or rhs.hasUnknown()) return .x;
    const signed = self.signed and rhs.signed;
    const extension: Extension = if (signed) .sign else .zero;
    const width = @max(self.width, rhs.width);
    const top = words.wordCount(width);
    var i = top;
    var order: std.math.Order = .eq;
    while (i != 0) {
        i -= 1;
        var a = words.extendedWord(self, self.values(), i, extension);
        var b = words.extendedWord(rhs, rhs.values(), i, extension);
        if (i == top - 1) {
            a &= words.mask(width);
            b &= words.mask(width);
            // Bias the common sign bit so unsigned word order is two's
            // complement order, partial words included.
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
    const r: Bit = if (switch (op) {
        .less => order == .lt,
        .less_equal => order != .gt,
        .greater => order == .gt,
        .greater_equal => order != .lt,
    }) .one else .zero;
    assert(r == .one or r == .zero);
    return r;
}

/// Returns the logical truth value (IEEE 1364-2005 §5.1.9): any known one
/// decides it, even beside X/Z.
pub fn truth(self: Literal) Bit {
    const r = reduce(self, .or_bits);
    assert(r != .z);
    return r;
}

/// Returns `&&` or `||` of the two truth values (IEEE 1364-2005 §5.1.9).
pub fn logical(self: Literal, op: Logical, rhs: Literal) Bit {
    const a = truth(self);
    const b = truth(rhs);
    return switch (op) {
        .and_bits => if (a == .zero or b == .zero) .zero else if (a == .one and b == .one) .one else .x,
        .or_bits => if (a == .one or b == .one) .one else if (a == .zero and b == .zero) .zero else .x,
    };
}

/// Returns a unary reduction's bit (IEEE 1364-2005 §5.1.11); only the
/// declared bits contribute, and the result is never Z.
pub fn reduce(self: Literal, op: Reduction) Bit {
    var zeros: u64 = 0;
    var ones: u64 = 0;
    var unknown: u64 = 0;
    var parity: u1 = 0;
    const n = words.wordCount(self.width);
    assert(n <= self.values().len);
    for (self.values()[0..n], self.unknowns()[0..n], 0..) |v, u, i| {
        const live = if (i + 1 == n) words.mask(self.width) else std.math.maxInt(u64);
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
    const r = switch (op) {
        .nand_bits, .nor_bits, .xnor_bits => words.invert(result),
        .and_bits, .or_bits, .xor_bits => result,
    };
    assert(r != .z);
    return r;
}

/// Returns an equality operator's bit (IEEE 1364-2005 §5.1.8). A known
/// mismatch resolves `==` even beside unknown bits; case equality compares
/// both planes and is never X.
pub fn equality(self: Literal, op: Equality, rhs: Literal) Bit {
    const width = @max(self.width, rhs.width);
    const extension: Extension = if (self.signed and rhs.signed) .sign else .zero;
    const n = words.wordCount(width);
    var different: u64 = 0;
    var unknown: u64 = 0;
    for (0..n) |i| {
        const av = words.extendedWord(self, self.values(), i, extension);
        const au = words.extendedWord(self, self.unknowns(), i, extension);
        const bv = words.extendedWord(rhs, rhs.values(), i, extension);
        const bu = words.extendedWord(rhs, rhs.unknowns(), i, extension);
        const live = if (i + 1 == n) words.mask(width) else std.math.maxInt(u64);
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
    const r = switch (op) {
        .not_equal, .case_not_equal => words.invert(result),
        .equal, .case_equal => result,
    };
    if (op == .case_equal or op == .case_not_equal) assert(r != .x);
    return r;
}

/// Returns `self ? yes : no` (IEEE 1364-2005 §5.1.13, Table 5-21). Under an
/// ambiguous condition only matching known bits survive; even Z/Z merges to
/// X in this edition. Table 5-22 makes the arms context-determined:
/// §§5.5.1-5.5.2 propagate their common signedness and width before this
/// operator, so both-signed arms sign-extend, otherwise zero-extend, and
/// §5.1.13's shorter-arm zero-fill sentence does not override that. The
/// arms are already evaluated: short-circuiting is the caller's. Caller owns
/// the result's planes and frees them with `gpa`.
pub fn conditional(self: Literal, gpa: Allocator, yes: Literal, no: Literal) Allocator.Error!Literal {
    const signed = yes.signed and no.signed;
    const extension: Extension = if (signed) .sign else .zero;
    const out = try words.allocate(gpa, @max(yes.width, no.width), signed);
    const condition = truth(self);
    for (out.values(), out.unknowns(), 0..) |*v, *u, i| {
        const av = words.extendedWord(yes, yes.values(), i, extension);
        const au = words.extendedWord(yes, yes.unknowns(), i, extension);
        const bv = words.extendedWord(no, no.values(), i, extension);
        const bu = words.extendedWord(no, no.unknowns(), i, extension);
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
    words.clearPadding(out);
    assert(out.width == @max(yes.width, no.width));
    return out;
}

// ---- private ----

fn testStateIndex(state: Bit) usize {
    return switch (state) {
        .zero => 0,
        .one => 1,
        .x => 2,
        .z => 3,
    };
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

test "four-state scalar operators exhaust IEEE1364 truth tables" {
    const allocator = std.testing.allocator;
    for (fixture.truth_states, 0..) |a, ai| {
        var a_storage: [2]u64 = undefined;
        const lhs = fixture.testScalar(&a_storage, a);
        const neg = try lhs.bitwiseNot(allocator);
        defer allocator.free(neg.planes);
        try std.testing.expectEqual(words.invert(a), neg.bit(0));
        try std.testing.expectEqual(words.invert(a), words.invert(lhs.truth()));
        for (fixture.truth_states, 0..) |b, bi| {
            var b_storage: [2]u64 = undefined;
            const rhs = fixture.testScalar(&b_storage, b);
            inline for (std.meta.tags(Bitwise)) |op| {
                const out = try lhs.bitwise(allocator, op, rhs);
                defer allocator.free(out.planes);
                const expected = switch (op) {
                    .and_bits => and_truth[ai][bi],
                    .or_bits => or_truth[ai][bi],
                    .xor_bits => xor_truth[ai][bi],
                    .xnor_bits => words.invert(xor_truth[ai][bi]),
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
            try std.testing.expectEqual(words.invert(logical_eq), lhs.equality(.not_equal, rhs));
            try std.testing.expectEqual(case_eq, lhs.equality(.case_equal, rhs));
            try std.testing.expectEqual(words.invert(case_eq), lhs.equality(.case_not_equal, rhs));
            for (fixture.truth_states) |condition| {
                var c_storage: [2]u64 = undefined;
                const c = fixture.testScalar(&c_storage, condition);
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
                .nand_bits, .nor_bits, .xnor_bits => words.invert(normal),
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
            fixture.testPut(value, @intCast(i), fixture.truth_states[state_index]);
            and_value = and_truth[testStateIndex(and_value)][state_index];
            or_value = or_truth[testStateIndex(or_value)][state_index];
            xor_value = xor_truth[testStateIndex(xor_value)][state_index];
        }
        try std.testing.expectEqual(and_value, value.reduce(.and_bits));
        try std.testing.expectEqual(words.invert(and_value), value.reduce(.nand_bits));
        try std.testing.expectEqual(or_value, value.reduce(.or_bits));
        try std.testing.expectEqual(words.invert(or_value), value.reduce(.nor_bits));
        try std.testing.expectEqual(xor_value, value.reduce(.xor_bits));
        try std.testing.expectEqual(words.invert(xor_value), value.reduce(.xnor_bits));
        try std.testing.expectEqual(or_value, value.truth());
    }
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = try integer.parse(arena, "129'h10000000000000000000000000000000x");
    const b = try integer.parse(arena, "129'h00000000000000000000000000000000z");
    try std.testing.expectEqual(Bit.zero, a.equality(.equal, b));
    try std.testing.expectEqual(Bit.one, a.equality(.not_equal, b));
    try std.testing.expectEqual(Bit.one, a.truth());
    try std.testing.expectEqual(Bit.x, b.truth());
    try std.testing.expectEqual(Bit.zero, words.invert(a.truth()));
}

test "packed bitwise operations match scalar oracle across partial and multiple words" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var random_state = std.Random.DefaultPrng.init(0x13642005);
    const random = random_state.random();
    for ([_]u32{ 1, 31, 32, 33, 63, 64, 65, 127, 128, 129, 257, 65536 }) |width| {
        const a = try words.allocate(arena, width, false);
        const b = try words.allocate(arena, width, false);
        for (a.planes, b.planes) |*av, *bv| {
            av.* = random.int(u64);
            bv.* = random.int(u64);
        }
        words.clearPadding(a);
        words.clearPadding(b);
        const ones = try words.allocate(arena, width, false);
        @memset(ones.values(), std.math.maxInt(u64));
        @memset(ones.unknowns(), 0);
        words.clearPadding(ones);
        try std.testing.expectEqual(Bit.one, ones.reduce(.and_bits));
        try std.testing.expectEqual(Bit.one, ones.reduce(.or_bits));
        try std.testing.expectEqual(if (width % 2 == 0) Bit.zero else Bit.one, ones.reduce(.xor_bits));
        for ([_]Bit{ .x, .z }) |state| {
            fixture.testPut(ones, width - 1, state);
            try std.testing.expectEqual(Bit.x, ones.reduce(.and_bits));
            try std.testing.expectEqual(if (width > 1) Bit.one else Bit.x, ones.reduce(.or_bits));
            try std.testing.expectEqual(Bit.x, ones.reduce(.xor_bits));
        }
        const neg = try a.bitwiseNot(arena);
        var c_storage: [2]u64 = undefined;
        const unknown = fixture.testScalar(&c_storage, .x);
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
                    .xnor_bits => words.invert(xor_truth[ai][bi]),
                };
                try std.testing.expectEqual(expected, out.bit(index));
                try std.testing.expectEqual(words.invert(a.bit(index)), neg.bit(index));
                try std.testing.expectEqual(merge_truth[ai][bi], merged.bit(index));
            }
            const last = words.wordCount(width) - 1;
            try std.testing.expectEqual(@as(u64, 0), out.values()[last] & ~words.mask(width));
            try std.testing.expectEqual(@as(u64, 0), out.unknowns()[last] & ~words.mask(width));
        }
    }
}

test "four-state shifts exhaust four-bit scalar state patterns" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (0..256) |pattern| {
        for ([_]bool{ false, true }) |signed| {
            var storage: [2]u64 = undefined;
            const value = fixture.testPattern(&storage, 4, signed, pattern);
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
            const value = try words.allocate(arena, width, signed);
            for (value.planes) |*word| word.* = random.int(u64);
            words.clearPadding(value);
            for ([_]u64{ 0, 1, 31, 32, 63, 64, 65, width - 1, width, @as(u64, width) + 1 }) |count| {
                var count_storage = [_]u64{ count, 0 };
                const rhs: Literal = .{ .width = 64, .sized = true, .signed = false, .planes = &count_storage };
                inline for (std.meta.tags(Shift)) |op| {
                    const out = try value.shift(arena, op, rhs);
                    for (0..width) |index|
                        try std.testing.expectEqual(testShiftBit(value, op, count, @intCast(index)), out.bit(@intCast(index)));
                    const last = words.wordCount(width) - 1;
                    try std.testing.expectEqual(@as(u64, 0), out.values()[last] & ~words.mask(width));
                    try std.testing.expectEqual(@as(u64, 0), out.unknowns()[last] & ~words.mask(width));
                }
            }
        }
    }
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
                            const a = fixture.testPattern(&a_storage, aw, as, ap);
                            const b = fixture.testPattern(&b_storage, bw, bs, bp);
                            const an = fixture.testNumber(a, as and bs);
                            const bn = fixture.testNumber(b, as and bs);
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
        var a = try words.allocate(arena, width, false);
        @memset(a.planes, 0);
        fixture.testPut(a, width - 1, .one);
        var b = try words.allocate(arena, width, false);
        @memset(b.planes, 0);
        for (0..width - 1) |i| fixture.testPut(b, @intCast(i), .one);
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
            fixture.testPut(b, 0, unknown);
            inline for (std.meta.tags(Relational)) |op|
                try std.testing.expectEqual(Bit.x, a.relational(op, b));
        }
    }
    const minus_one = try integer.parse(arena, "4'shf");
    for ([_]u32{ 5, 63, 64, 65, 128, 129, 257 }) |width| {
        var ten = try words.allocate(arena, width, true);
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
