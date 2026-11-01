//! Four-state bits -> the text and numbers of Table 12-4: binary, octal,
//! decimal and hex strings, the 8-bit string form, reals, and the plane
//! helpers the put side shares. Pure functions over planes.
//! Cites: VAMS-2023 §12.16 Table 12-4, §4.2.1.1 (real to integer).
//!
//! Contents:
//! - `pub fn roundAway(f: f64) i64`
//! - `pub fn toReal(b: Bits) f64`
//! - `pub fn radixString(out: *std.ArrayList(u8), b: Bits, format: c_int) !void`
//! - `pub fn lowMask(n: u32) u64`
//! - `pub fn negate(words: []u64) void`
//! - `pub fn orField(plane: []u64, lo: usize, bits: u64, n: u32, width: u32) void`

const std = @import("std");
const gpa = std.heap.smp_allocator;
const value_put = @import("value_put.zig");
const user = @import("vpi_user.zig");
const abi = @import("abi.zig");
const value = @import("value.zig");
const Bits = value.Bits;
const Value = abi.Value;

/// Byte `x` spread to eight bytes of 0 or 1, its MSB in the first byte.
const spread: [256]u64 = blk: {
    @setEvalBranchQuota(4000);
    var t: [256]u64 = undefined;
    for (&t, 0..) |*w, x| {
        w.* = 0;
        for (0..8) |j| w.* |= @as(u64, (x >> (7 - j)) & 1) << (8 * j);
    }
    break :blk t;
};

/// §4.2.1.1 real-to-integer: nearest, ties away from zero; 0 for a NaN or
/// an infinity. Asserts that the result keeps `f`'s sign and, within i64's
/// range, is at most a half away from it.
pub fn roundAway(f: f64) i64 {
    if (!std.math.isFinite(f)) return 0;
    const r = std.math.lossyCast(i64, @round(f));
    std.debug.assert(r == 0 or (r > 0) == (f > 0));
    std.debug.assert(@abs(f) >= 0x1p63 or @abs(@as(f64, @floatFromInt(r)) - f) <= 0.5);
    return r;
}

/// The value of `b` as a real, x and z bits read as 0. Asserts that `b`'s
/// planes are the same length and hold its width.
pub fn toReal(b: Bits) f64 {
    std.debug.assert(b.val.len == b.unk.len);
    std.debug.assert(b.val.len * 64 >= b.width);
    if (b.width <= 64) {
        const x = b.low64();
        return if (b.signed) @floatFromInt(@as(i64, @bitCast(x))) else @floatFromInt(x);
    }
    // Wider than 64: sum the words MSB first, x/z read as 0 and bits past
    // the width cleared. A signed value whose top bit is set is negative:
    // sum its magnitude ~u + 1 instead and negate. The +1 carries through
    // exactly the zero words below the lowest nonzero one (`lo`), so each
    // magnitude word is known without a buffer.
    const n: usize = (b.width + 63) / 64;
    const neg = b.signed and b.bit(b.width - 1) == .one;
    var lo: usize = 0;
    while (lo < n and (b.val[lo] & ~b.unk[lo]) == 0) {
        std.debug.assert(lo < n);
        lo += 1;
    }
    var r: f64 = 0;
    var k = n;
    while (k > 0) {
        std.debug.assert(k <= n);
        k -= 1;
        const u = b.val[k] & ~b.unk[k];
        var w: u64 = if (!neg) u else if (k < lo) 0 else if (k == lo) 0 -% u else ~u;
        if (k == n - 1 and b.width % 64 != 0) w &= lowMask(b.width % 64);
        r = r * 18446744073709551616.0 + @as(f64, @floatFromInt(w));
    }
    return if (neg) -r else r;
}

/// Table 12-4's string formats. Octal and hex group from the LSB; a group
/// that is ALL x (z) prints `x` (`z`), one that is only PARTLY x (z) prints
/// `X` (`Z`) — x winning over z when a group holds both, as it would in any
/// expression reading the group. Asserts that `b`'s planes are the same
/// length and hold its width, and that no text is longer than the binary
/// one plus a sign.
pub fn radixString(out: *std.ArrayList(u8), b: Bits, format: c_int) !void {
    std.debug.assert(b.val.len == b.unk.len);
    std.debug.assert(b.val.len * 64 >= b.width);
    const before = out.items.len;
    defer std.debug.assert(out.items.len - before <= b.width + 1);
    switch (format) {
        user.vpiBinStrVal => binText(try out.addManyAsSlice(gpa, b.width), b.val, b.unk),
        user.vpiOctStrVal, user.vpiHexStrVal => {
            const g: u32 = if (format == user.vpiOctStrVal) 3 else 4;
            const dst = try out.addManyAsSlice(gpa, (b.width + g - 1) / g);
            // dst[0] is the most significant group, the only partial one.
            for (dst, 0..) |*c, j| {
                const lo = @as(u32, @intCast(dst.len - 1 - j)) * g;
                c.* = groupChar(b, lo, @min(lo + g, b.width));
            }
        },
        user.vpiDecStrVal => {
            if (!b.known()) {
                // The same all/some rule over the whole value: a decimal digit
                // has no bits of its own to be unknown in.
                try out.append(gpa, groupChar(b, 0, b.width));
                return;
            }
            try decimal(out, b);
        },
        user.vpiStringVal => {
            // "each 8-bit group of the value of the object is assumed to
            // represent an ASCII character", MSB first. A NUL group prints
            // nothing: it is the padding of a register wider than its text.
            // An x or z bit reads as 0.
            try out.ensureUnusedCapacity(gpa, (b.width + 7) / 8);
            var k = (b.width + 7) / 8;
            while (k > 0) {
                std.debug.assert(k <= (b.width + 7) / 8);
                k -= 1;
                const lo = k * 8;
                const n = @min(8, b.width - lo);
                const c: u8 = @intCast(field(b.val, lo, n) & ~field(b.unk, lo, n));
                if (c != 0) out.appendAssumeCapacity(c);
            }
        },
        else => unreachable,
    }
}

/// The low `n` bits set, all 64 for `n >= 64`. Asserts that they are
/// exactly that many, and contiguous from bit 0.
pub fn lowMask(n: u32) u64 {
    const m = if (n >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(n)) - 1;
    std.debug.assert(@popCount(m) == @min(n, 64));
    std.debug.assert(m & (m +% 1) == 0);
    return m;
}

/// Two's-complement negation of the little-endian words in place. Asserts
/// that there is a word, and that the low one is negated.
pub fn negate(words: []u64) void {
    std.debug.assert(words.len != 0);
    const low = words[0];
    var carry: u1 = 1;
    for (words) |*w| {
        const r = @addWithOverflow(~w.*, @as(u64, carry));
        w.* = r[0];
        carry = r[1];
    }
    std.debug.assert(words[0] == 0 -% low);
}

/// ORs the `n`-bit `bits` (n in 1..64) into `plane` at bit `lo`, dropping
/// what falls at or past `width`; `plane` holds `width` bits. Asserts both.
pub fn orField(plane: []u64, lo: usize, bits: u64, n: u32, width: u32) void {
    std.debug.assert(n >= 1);
    std.debug.assert(n <= 64);
    std.debug.assert(plane.len * 64 >= width);
    if (lo >= width) return;
    const x = bits & lowMask(@intCast(@min(n, width - lo)));
    const w = lo / 64;
    const o: u6 = @truncate(lo);
    plane[w] |= x << o;
    if (o != 0 and o + n > 64) plane[w + 1] |= x >> @intCast(64 - @as(u32, o));
}

// ---- private ----

/// vpiBinStrVal's characters, MSB first: `dst.len` bits of the planes `val`
/// and `unk` (Figure 12-10), eight per step once the top `dst.len % 8` are
/// written. A byte of chars is 0x30 + v + 0x4a*u - 3*(v&u): '0', '1', 'z'
/// (0x7a), 'x' (0x78), with no carry between bytes.
fn binText(dst: []u8, val: []const u64, unk: []const u64) void {
    std.debug.assert(val.len == unk.len);
    std.debug.assert(val.len * 64 >= dst.len);
    const head = dst.len % 8;
    for (dst[0..head], 0..) |*c, j| {
        const i = dst.len - 1 - j;
        const o: u6 = @truncate(i);
        const v: u8 = @truncate(val[i / 64] >> o & 1);
        const u: u8 = @truncate(unk[i / 64] >> o & 1);
        c.* = "01zx"[v | u << 1];
    }
    var k = head;
    var i = dst.len - head;
    while (i > 0) : (k += 8) {
        std.debug.assert(i <= dst.len - head);
        i -= 8;
        const o: u6 = @truncate(i);
        const v = spread[@as(u8, @truncate(val[i / 64] >> o))];
        const u = spread[@as(u8, @truncate(unk[i / 64] >> o))];
        std.mem.writeInt(u64, dst[k..][0..8], 0x3030303030303030 +% v +% 0x4a *% u -% 3 *% (v & u), .little);
    }
    std.debug.assert(k == dst.len);
}

/// Bits [lo, lo + n) of `plane`, n in 1..64, as the low bits of a word.
/// Asserts the plane holds them.
fn field(plane: []const u64, lo: u32, n: u32) u64 {
    std.debug.assert(n >= 1 and n <= 64);
    std.debug.assert((lo + n + 63) / 64 <= plane.len);
    const w = lo / 64;
    const o: u6 = @truncate(lo);
    var x = plane[w] >> o;
    if (o != 0 and o + n > 64) x |= plane[w + 1] << @intCast(64 - @as(u32, o));
    return x & lowMask(n);
}

/// Bits [lo, hi) of `b` as one character: `x`/`z` when every bit is x/z,
/// `X` when any is x, `Z` when any is z, else the value's hex digit (which
/// needs hi - lo <= 4).
fn groupChar(b: Bits, lo: u32, hi: u32) u8 {
    std.debug.assert(lo < hi);
    std.debug.assert(hi <= b.width);
    var all_x = true;
    var all_z = true;
    var any_x = false;
    var any_z = false;
    var d: u64 = 0;
    var i = lo;
    while (i < hi) {
        std.debug.assert(i < hi);
        const n = @min(hi - i, 64);
        const m = lowMask(n);
        const v = field(b.val, i, n);
        const u = field(b.unk, i, n);
        all_x = all_x and v & u == m;
        all_z = all_z and ~v & u == m;
        any_x = any_x or v & u != 0;
        any_z = any_z or ~v & u & m != 0;
        d = v;
        i += n;
    }
    if (all_x) return 'x';
    if (all_z) return 'z';
    if (any_x) return 'X';
    if (any_z) return 'Z';
    // A known group is a digit only when it is one: hi - lo <= 4.
    std.debug.assert(d < 16);
    return "0123456789abcdef"[@intCast(d)];
}

/// Decimal of a fully known value, any width: repeated division of the
/// magnitude by 10. Signed objects print their sign.
fn decimal(out: *std.ArrayList(u8), b: Bits) !void {
    // `radixString` prints a value with an x or z bit as one character.
    std.debug.assert(b.known());
    std.debug.assert(b.val.len * 64 >= b.width);
    // Up to 1024 bits on the stack: the common widths never allocate.
    var stack: [16]u64 = undefined;
    const words = if (b.val.len <= stack.len) stack[0..b.val.len] else try gpa.alloc(u64, b.val.len);
    defer if (words.ptr != @as([*]u64, &stack)) gpa.free(words);
    @memcpy(words, b.val);
    // Mask to width, then negate a signed negative value.
    if (b.width % 64 != 0) words[words.len - 1] &= lowMask(b.width % 64);
    const neg = b.signed and b.bit(b.width - 1) == .one;
    if (neg) {
        negate(words);
        if (b.width % 64 != 0) words[words.len - 1] &= lowMask(b.width % 64);
    }
    const start = out.items.len;
    // Bound: a 64-bit word has at most 20 decimal digits.
    const digits_max = 20 * words.len + 1;
    var digits: usize = 0;
    while (true) : (digits += 1) {
        std.debug.assert(digits < digits_max);
        var rem: u128 = 0;
        var k = words.len;
        // OR of the quotient words: zero once the magnitude is.
        var left: u64 = 0;
        while (k > 0) {
            std.debug.assert(k <= words.len);
            k -= 1;
            const cur = (rem << 64) | words[k];
            words[k] = @intCast(cur / 10);
            rem = cur % 10;
            left |= words[k];
        }
        try out.append(gpa, '0' + @as(u8, @intCast(rem)));
        if (left == 0) break;
    }
    if (neg) try out.append(gpa, '-');
    std.mem.reverse(u8, out.items[start..]);
}

test "Table 12-4 vpiDecStrVal: every 8-bit value, signed and unsigned, against std.fmt" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var want_buf: [8]u8 = undefined;
    const unk = [1]u64{0};
    for (0..256) |x| {
        const val = [1]u64{x};
        for ([_]bool{ false, true }) |signed| {
            out.clearRetainingCapacity();
            try radixString(&out, .{ .width = 8, .val = &val, .unk = &unk, .signed = signed }, user.vpiDecStrVal);
            const byte: u8 = @intCast(x);
            const want = if (signed)
                try std.mem.print(&want_buf, "{d}", .{@as(i8, @bitCast(byte))})
            else
                try std.mem.print(&want_buf, "{d}", .{byte});
            try std.testing.expectEqualStrings(want, out.items);
        }
    }
}

test "Table 12-4 vpiDecStrVal: wider than 64 bits, and the most negative values" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const two64 = [2]u64{ 0, 1 };
    const ones = [2]u64{ std.math.maxInt(u64), std.math.maxInt(u64) };
    const zero = [2]u64{ 0, 0 };
    // 2^64, unsigned in 128 bits.
    try radixString(&out, .{ .width = 128, .val = &two64, .unk = &zero, .signed = false }, user.vpiDecStrVal);
    try std.testing.expectEqualStrings("18446744073709551616", out.items);
    // Every bit one, signed: -1.
    out.clearRetainingCapacity();
    try radixString(&out, .{ .width = 128, .val = &ones, .unk = &zero, .signed = true }, user.vpiDecStrVal);
    try std.testing.expectEqualStrings("-1", out.items);
    // Bit 64 alone in 65 signed bits is the sign: -2^64.
    out.clearRetainingCapacity();
    try radixString(&out, .{ .width = 65, .val = &two64, .unk = &zero, .signed = true }, user.vpiDecStrVal);
    try std.testing.expectEqualStrings("-18446744073709551616", out.items);
}

test "Table 12-4 vpiStringVal: 8-bit groups MSB first, NUL groups dropped" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const unk = [1]u64{0};
    // 12 bits: the top group is 4 bits of zero, a NUL.
    const a = [1]u64{0x041};
    try radixString(&out, .{ .width = 12, .val = &a, .unk = &unk, .signed = false }, user.vpiStringVal);
    try std.testing.expectEqualStrings("A", out.items);
    // A NUL between two characters is dropped too.
    const ab = [1]u64{0x41_00_42};
    out.clearRetainingCapacity();
    try radixString(&out, .{ .width = 24, .val = &ab, .unk = &unk, .signed = false }, user.vpiStringVal);
    try std.testing.expectEqualStrings("AB", out.items);
}

test "Table 12-4 vpiRealVal: a signed value wider than 64 bits keeps its sign" {
    const zero = [2]u64{ 0, 0 };
    // -1 in 100 bits: every bit one.
    const ones = [2]u64{ std.math.maxInt(u64), (1 << 36) - 1 };
    try std.testing.expectEqual(@as(f64, -1), toReal(.{ .width = 100, .val = &ones, .unk = &zero, .signed = true }));
    // The same bits unsigned: 2^100 - 1, which rounds to 2^100 in an f64.
    try std.testing.expectEqual(std.math.pow(f64, 2, 100), toReal(.{ .width = 100, .val = &ones, .unk = &zero, .signed = false }));
    // -5 in 72 bits.
    const m5 = [2]u64{ std.math.maxInt(u64) - 4, 0xff };
    try std.testing.expectEqual(@as(f64, -5), toReal(.{ .width = 72, .val = &m5, .unk = &zero, .signed = true }));
    // Within 64 bits: 1010 is -6 signed.
    const v4 = [1]u64{0b1010};
    try std.testing.expectEqual(@as(f64, -6), toReal(.{ .width = 4, .val = &v4, .unk = zero[0..1], .signed = true }));
}

test "§4.2.1.1 roundAway: nearest, ties away from zero, non-finite is 0" {
    for ([_]struct { f64, i64 }{
        .{ 2.5, 3 },
        .{ -2.5, -3 },
        .{ 0.5, 1 },
        .{ -0.5, -1 },
        .{ 2.4999, 2 },
        .{ -0.0, 0 },
        .{ std.math.nan(f64), 0 },
        .{ std.math.inf(f64), 0 },
        .{ -std.math.inf(f64), 0 },
        .{ 1e300, std.math.maxInt(i64) },
        .{ -1e300, std.math.minInt(i64) },
    }) |case| try std.testing.expectEqual(case[1], roundAway(case[0]));
}

test "§12.30: a string a put writes reads back as the same string, every 8-bit value" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var text: [16:0]u8 = undefined;
    for (0..256) |x| {
        const want = [2]u64{ x, 0 };
        for ([_]c_int{ user.vpiBinStrVal, user.vpiOctStrVal, user.vpiHexStrVal, user.vpiDecStrVal }) |format| {
            // The spelling the get side writes for `x` is the put's input.
            out.clearRetainingCapacity();
            try radixString(&out, .{ .width = 8, .val = want[0..1], .unk = want[1..2], .signed = false }, format);
            @memcpy(text[0..out.items.len], out.items);
            text[out.items.len] = 0;
            var v: Value = std.mem.zeroes(Value);
            v.format = format;
            v.value.str = &text;
            var planes: [2]u64 = undefined;
            try value_put.toPlanes(&v, 8, &planes);
            try std.testing.expectEqual(want, planes);
        }
    }
}
