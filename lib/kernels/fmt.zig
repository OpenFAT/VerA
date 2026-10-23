//! An operand's planes, width and signedness, radix and field width (or a
//! time and the `$timeformat` state) -> its IEEE 1364-2005 §17.1 text.
//! The interpreter (`digital/display.zig`) and a native executable (`rt/`)
//! both print through these, so the two cannot disagree about a digit.
//! A conversion's flags, width and precision are read here too (`spec`),
//! with which flags each conversion takes (`flagVerdict`).
//! Clauses: VAMS §9.4.3 Table 9-22; IEEE 1364-2005 §17.1.1.2, §17.1.1.3,
//! §17.1.1.4, §17.1.1.7, §17.3, §19.8.
const std = @import("std");
const Int = @import("integer.zig");
const str_k = @import("str_kernels.zig");

/// §9.4.3 Table 9-22's four conversions. The value is the base, so a digit is
/// `@ctz(base)` bits wide for the three power-of-two members and decimal is the
/// one that is not a bit group.
pub const Radix = enum(u8) {
    binary = 2,
    octal = 8,
    decimal = 10,
    hex = 16,

    /// Bits consumed per printed digit. Asserts `self` is not `.decimal`,
    /// which reads the whole operand at once.
    pub fn perDigit(self: Radix) u32 {
        return switch (self) {
            .binary => 1,
            .octal => 3,
            .hex => 4,
            .decimal => unreachable,
        };
    }
};

/// §17.3 `$timeformat(units_number, precision, suffix, min_width)`, with the
/// clause's own defaults: the units are the simulation's precision, nothing
/// after the decimal point, no suffix, and a 20-column field.
pub const TimeFormat = struct {
    units: i32 = 0,
    precision: u32 = 0,
    suffix: []const u8 = "",
    width: u64 = 20,
};

/// A `%d` of a known operand wider than 64 bits takes scratch from the
/// caller's allocator (`wideDecimal`).
pub const Error = std.mem.Allocator.Error || std.Io.Writer.Error;

/// Byte `n` of `v` counting from the least significant, unknown bits read as
/// 0 and bits at or past `v.width` absent (0).
pub fn byteAt(v: Int.Literal, n: u32) u8 {
    const lo = @as(u64, n) * 8;
    if (lo >= v.width) return 0;
    // A byte never straddles a word: the known ones of its word (a 1 is
    // value set, unknown clear), shifted down and cut at the width.
    const word: usize = @intCast(lo / 64);
    const known = v.values()[word] & ~v.unknowns()[word];
    const left = v.width - lo;
    const keep: u8 = if (left >= 8) 0xff else @intCast((@as(u16, 1) << @intCast(left)) - 1);
    return @as(u8, @truncate(known >> @intCast(lo % 64))) & keep;
}

/// §17.1.1.7 `%s` (`char` false) or `%c`, right-justified in `width` columns:
/// "each 8 bits representing a single character ... right-justified so that
/// the rightmost bit of the value is the least significant bit of the last
/// character", and "leading zeros are never printed".
pub fn text(out: *std.Io.Writer, v: Int.Literal, char: bool, width: ?u64) std.Io.Writer.Error!void {
    var n: u32 = if (char) 1 else (v.width + 7) / 8;
    if (!char) while (n != 0 and byteAt(v, n - 1) == 0) {
        n -= 1;
    };
    if (width) |w| if (n < w) try out.splatByteAll(' ', @intCast(w - n));
    while (n != 0) {
        n -= 1;
        try out.writeByte(byteAt(v, n));
    }
}

/// §17.3 `%t`. The operand is a time in the invoking module's time unit
/// (what `$time` returns, and what a literal `1` there means), and
/// `$timeformat`'s `units_number` says which power of ten of a second to
/// report it in. So the printed number is
///
///     value · 10^(unit_exp − units_number)
///
/// and nothing here needs the precision: scaling a unit count by a ratio of
/// decades is exact in the only direction that matters. `t` is the
/// operand as a real: a real operand (`$realtime`, `1.55`) as it is, never
/// first rounded to a whole unit (§17.3.2's own example formats
/// `$realtime`; #64), an integral one through `timeOperand`.
pub fn time(out: *std.Io.Writer, t: f64, f: TimeFormat, unit_exp: i32) std.Io.Writer.Error!void {
    const scaled = t * std.math.pow(f64, 10, @floatFromInt(unit_exp - f.units));
    const len = std.fmt.count("{d:.[1]}", .{ scaled, f.precision }) + f.suffix.len;
    if (len < f.width) try out.splatByteAll(' ', @intCast(f.width - len));
    try out.print("{d:.[1]}", .{ scaled, f.precision });
    try out.writeAll(f.suffix);
}

/// An integral `%t` operand as the real `time` formats: one with an x or z
/// bit is 0, as is a signed one wider than 64 bits; an unsigned one wider
/// than 64 bits is read by its low 64.
pub fn timeOperand(v: Int.Literal) f64 {
    if (v.hasUnknown()) return 0;
    if (v.signed) return @floatFromInt(v.asInt() orelse 0);
    return @floatFromInt(v.values()[0]);
}

/// 10^e seconds in §19.8's spelling: 1, 10 or 100 of s, ms, us, ns, ps, fs.
/// Asserts `e` is in [-15, 2], the range of §19.8's 18 operands.
pub fn decade(out: *std.Io.Writer, e: i32) std.Io.Writer.Error!void {
    const k = @divFloor(e, 3);
    const units = [_][]const u8{ "fs", "ps", "ns", "us", "ms", "s" };
    const mantissa: u32 = std.math.pow(u32, 10, @intCast(e - 3 * k));
    try out.print("{d}{s}", .{ mantissa, units[@intCast(k + 5)] });
}

/// One operand, in one radix, sized by IEEE 1364-2005 §17.1.1.3 unless the
/// format gave an explicit width. A decimal operand wider than 64 bits with
/// no x or z bit is divided out with scratch from `gpa` (`wideDecimal`).
///
/// The three power-of-two radices are a GROUP walk and decimal is not, and
/// that is the whole split: a hex digit is four bits of this operand and
/// says nothing about the other bits, so a group that is entirely unknown
/// prints as unknown while its neighbours print normally. A decimal
/// rendering has no such locality (one unknown bit makes the whole number
/// unknown), which is why §17.1.1.4 gives it its own rule.
pub fn value(out: *std.Io.Writer, gpa: std.mem.Allocator, v: Int.Literal, radix: Radix, width: ?u64) Error!void {
    const field = width orelse autoWidth(v, radix);
    if (radix == .decimal) {
        if (v.width > 64 and !v.hasUnknown()) return wideDecimal(out, gpa, v, field);
        var buf: [24]u8 = undefined;
        const t = decimalText(&buf, v);
        if (t.len < field) try out.splatByteAll(' ', @intCast(field - t.len));
        return out.writeAll(t);
    }
    // §17.1.1.3: a zero width overrides the automatic size, so a group radix
    // loses its leading zero digits too (`%0h` of 12'd10 is "a").
    var d = autoWidth(v, radix);
    if (width == 0) while (d > 1 and groupDigit(v, radix, d - 1) == '0') {
        d -= 1;
    };
    // §17.1.1.3's automatic size. Right-justified with leading spaces, not
    // zeros: `%d` of an 8-bit 7 is "  7" and not "007". A group radix is
    // already exactly its own width, so padding only ever shows up under
    // decimal or an explicit format width.
    if (d < field) try out.splatByteAll(' ', @intCast(field - d));
    while (d != 0) {
        d -= 1;
        try out.writeByte(groupDigit(v, radix, d));
    }
}

/// §17.1.1.3: "a radix conversion is sized to the operand's declared width,
/// and the default decimal field is sized to the largest value the operand
/// can hold". For a signed operand the largest printed value is the
/// negative one, because of its sign: a 32-bit `integer` is 11 columns
/// ("-2147483648"), not 10. Exact at every width, so an x in a 128-bit `%d`
/// is right-justified in 39 columns.
fn autoWidth(v: Int.Literal, radix: Radix) u32 {
    if (radix != .decimal) {
        const per = radix.perDigit();
        return (v.width + per - 1) / per;
    }
    // The count of decimal digits in 2^n - 1 (unsigned) or 2^(n-1)
    // (signed magnitude, plus one column for the sign). 2^n is never a
    // power of ten for n >= 1, so 2^n - 1 has 2^n's digits,
    // floor(n log10 2) + 1, and n = 0 has one. The floor is taken with
    // log10(2) in 64-bit fixed point: short by less than n / 2^64, which
    // leaves it exact for every width up to `Int.max_width` (checked
    // against an exact digit count of 2^n over that range).
    const bits: u32 = if (v.signed and v.width != 0) v.width - 1 else v.width;
    const log10_2: u128 = 0x4d104d427de7fbcc; // floor(log10(2) * 2^64)
    const digits: u32 = @intCast((@as(u128, bits) * log10_2) >> 64);
    return digits + 1 + @intFromBool(v.signed);
}

/// Digit `d` of a power-of-two radix, counting from the least significant
/// group. Bits past the operand's width are absent, not zero: they
/// contribute nothing to the digit's value and nothing to its unknown-ness,
/// which is what makes an all-x 8-bit operand print "xxx" in octal rather
/// than "Xxx": the top group holds two x bits and no third bit at all.
fn groupDigit(v: Int.Literal, radix: Radix, d: u32) u8 {
    const per = radix.perDigit();
    var val: u32 = 0;
    var xs: u32 = 0;
    var zs: u32 = 0;
    var present: u32 = 0;
    var k: u32 = 0;
    while (k < per) : (k += 1) {
        const index = d * per + k;
        if (index >= v.width) continue;
        present += 1;
        switch (v.bit(index)) {
            .zero => {},
            .one => val |= @as(u32, 1) << @intCast(k),
            .x => xs += 1,
            .z => zs += 1,
        }
    }
    // §17.1.1.4: all unknown prints lowercase, partly unknown prints
    // uppercase; the case is the only sign that the digit's known bits
    // were thrown away.
    return if (xs == present) 'x' //
    else if (zs == present) 'z' //
    else if (xs != 0) 'X' //
    else if (zs != 0) 'Z' //
    else "0123456789abcdef"[val];
}

/// Decimal, where one unknown bit poisons the whole number (§17.1.1.4), as
/// a slice of `buf`. Asserts `buf` holds 20 bytes, the longest i64 or u64,
/// and that a known `v` is at most 64 bits wide (`wideDecimal` is the rest).
fn decimalText(buf: []u8, v: Int.Literal) []const u8 {
    if (v.hasUnknown()) {
        // An x bit is value and unknown set, a z bit unknown alone.
        var xs: u32 = 0;
        var zs: u32 = 0;
        for (v.values(), v.unknowns(), 0..) |val, unk, j| {
            const m = widthMask(v.width, j);
            xs += @popCount(val & unk & m);
            zs += @popCount(~val & unk & m);
        }
        buf[0] = if (xs == v.width) 'x' //
            else if (zs == v.width) 'z' //
            else if (xs != 0) 'X' //
            else 'Z';
        return buf[0..1];
    }
    std.debug.assert(v.width <= 64);
    const raw = v.values()[0];
    if (v.signed) return std.mem.print(buf, "{d}", .{v.asInt().?}) catch unreachable;
    // Not `asInt`: it bit-casts, so an unsigned 64-bit operand at or above
    // 2^63 would print negative. $time is exactly that operand.
    return std.mem.print(buf, "{d}", .{raw}) catch unreachable;
}

/// §17.1.1.3 `%d` of a known operand of any width, right-justified in
/// `field` columns. The magnitude (negated over the width when `v` is signed
/// and its top bit is set) is divided by 10^19 until it is zero, each
/// remainder one 19-digit group, and the groups print most significant
/// first. The scratch comes from `gpa` and is freed before returning.
fn wideDecimal(out: *std.Io.Writer, gpa: std.mem.Allocator, v: Int.Literal, field: u64) Error!void {
    // ponytail: schoolbook division, quadratic in the word count; a
    // divide-and-conquer radix conversion if multi-megabit %d ever matters.
    const words = (v.width + 63) / 64;
    const mag = try gpa.alloc(u64, words);
    defer gpa.free(mag);
    for (mag, v.values()[0..words], 0..) |*m, val, j| m.* = val & widthMask(v.width, j);
    const negative = v.signed and v.bit(v.width - 1) == .one;
    if (negative) {
        // -v over `v.width` bits: invert, add one, cut at the width.
        var carry: u1 = 1;
        for (mag, 0..) |*m, j| {
            const sum = @addWithOverflow(~m.*, @as(u64, carry));
            m.* = sum[0] & widthMask(v.width, j);
            carry = sum[1];
        }
    }
    const base: u64 = 10_000_000_000_000_000_000;
    // 10^19 > 2^63, so each group takes more than 63 bits off the magnitude.
    const groups = try gpa.alloc(u64, words + words / 63 + 1);
    defer gpa.free(groups);
    var n: usize = 0;
    var top = words;
    while (true) {
        while (top != 0 and mag[top - 1] == 0) top -= 1;
        if (top == 0 and n != 0) break;
        var rem: u128 = 0;
        var j = top;
        while (j != 0) {
            j -= 1;
            const cur = (rem << 64) | mag[j];
            mag[j] = @intCast(cur / base);
            rem = cur % base;
        }
        groups[n] = @intCast(rem);
        n += 1;
    }
    const len = std.fmt.count("{d}", .{groups[n - 1]}) + 19 * (n - 1) + @intFromBool(negative);
    if (len < field) try out.splatByteAll(' ', @intCast(field - len));
    if (negative) try out.writeByte('-');
    try out.print("{d}", .{groups[n - 1]});
    var k = n - 1;
    while (k != 0) {
        k -= 1;
        try out.print("{d:0>19}", .{groups[k]});
    }
}

// The bits of word `j` below bit `width`.
fn widthMask(width: u32, j: usize) u64 {
    const lo = 64 * @as(u64, j);
    if (lo >= width) return 0;
    const left = width - lo;
    return if (left >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(left)) - 1;
}

/// One conversion's `[flags][width][.precision]`, read after its `%`.
pub const Spec = struct {
    /// C11 7.21.6.1p6's flags as `str_kernels.zc_*` bits.
    flags: u8 = 0,
    /// The field width; null when none is written (§17.1.1.3's automatic
    /// sizing). A '0' flag alone is width 0: `%0d`, the override.
    width: ?u64 = null,
    /// The precision; -1 when none is written.
    precision: i64 = -1,
};

/// The `Spec` at `t[i.*..]`, with `i.*` moved past it to the conversion
/// letter (or to the end). Flags are `str_kernels.zcFlag`'s set, the one
/// lowering, the device and the host read; leading zeros are the '0' flag,
/// so `%05d` is the '0' flag and width 5, the width digits `%05d` always
/// had. Width and precision saturate: §17.1.1.2 bounds neither, and no
/// width is buffered (`display.real`, `value`).
pub fn spec(t: []const u8, i: *usize) Spec {
    var s: Spec = .{};
    while (i.* < t.len) : (i.* += 1) s.flags |= str_k.zcFlag(t[i.*]) orelse break;
    if (s.flags & str_k.zc_zero != 0) s.width = 0;
    while (i.* < t.len and t[i.*] >= '0' and t[i.*] <= '9') : (i.* += 1)
        s.width = (s.width orelse 0) *| 10 +| (t[i.*] - '0');
    if (i.* < t.len and t[i.*] == '.') {
        i.* += 1;
        s.precision = 0;
        while (i.* < t.len and t[i.*] >= '0' and t[i.*] <= '9') : (i.* += 1)
            s.precision = s.precision *| 10 +| (t[i.*] - '0');
    }
    return s;
}

/// Whether conversion `conv` takes the flags in `flags` in the digital
/// context. IEEE 1364-2005 §17.1.1.2 grants "the full formatting
/// capabilities available in the C language" to its real conversions only
/// (`%e %f %g`, and VAMS §9.4.7's `%r`), so every flag renders there but
/// '#' on `%r` (`str_kernels.zcAltOk`). The others are sized by §17.1.1.3,
/// whose one override is the zero (`%0d`): '#' on them is `.alt` (E0825)
/// and '-', '+' or ' ' is `.c_flag` (E0827), refused rather than ignored.
pub fn flagVerdict(flags: u8, conv: u8) enum { ok, alt, c_flag } {
    if (flags & str_k.zc_alt != 0 and !str_k.zcAltOk(conv)) return .alt;
    const real = switch (conv | 0x20) {
        'e', 'f', 'g', 'r' => true,
        else => false,
    };
    if (!real and flags & (str_k.zc_left | str_k.zc_plus | str_k.zc_space) != 0) return .c_flag;
    return .ok;
}

const testing = std.testing;

test "§17.1.1.2 spec: C's flags, then the width and precision; leading zeros are the '0' flag" {
    const cases = [_]struct { t: []const u8, want: Spec, rest: []const u8 }{
        .{ .t = "d", .want = .{}, .rest = "d" },
        .{ .t = "0d", .want = .{ .flags = str_k.zc_zero, .width = 0 }, .rest = "d" },
        .{ .t = "05d", .want = .{ .flags = str_k.zc_zero, .width = 5 }, .rest = "d" },
        .{ .t = "10d", .want = .{ .width = 10 }, .rest = "d" },
        .{ .t = "-+ #010.3f", .want = .{ .flags = 31, .width = 10, .precision = 3 }, .rest = "f" },
        .{ .t = ".f", .want = .{ .precision = 0 }, .rest = "f" },
        .{ .t = "99999999999999999999999d", .want = .{ .width = std.math.maxInt(u64) }, .rest = "d" },
        .{ .t = "-", .want = .{ .flags = str_k.zc_left }, .rest = "" },
    };
    for (cases) |c| {
        var i: usize = 0;
        const got = spec(c.t, &i);
        try testing.expectEqual(c.want.flags, got.flags);
        try testing.expectEqual(c.want.width, got.width);
        try testing.expectEqual(c.want.precision, got.precision);
        try testing.expectEqualStrings(c.rest, c.t[i..]);
    }
}

test "§17.1.1.2 flagVerdict: C's flags on the real conversions only (#43)" {
    const all = str_k.zc_left | str_k.zc_plus | str_k.zc_space | str_k.zc_zero | str_k.zc_alt;
    for ("eEfFgG") |c| try testing.expect(flagVerdict(all, c) == .ok);
    try testing.expect(flagVerdict(all & ~str_k.zc_alt, 'r') == .ok);
    try testing.expect(flagVerdict(str_k.zc_alt, 'R') == .alt);
    for ("dDhHoObBcCsStTvVmMlL") |c| {
        try testing.expect(flagVerdict(str_k.zc_zero, c) == .ok); // `%0d`
        try testing.expect(flagVerdict(str_k.zc_alt, c) == .alt);
        try testing.expect(flagVerdict(str_k.zc_left, c) == .c_flag);
        try testing.expect(flagVerdict(str_k.zc_plus, c) == .c_flag);
        try testing.expect(flagVerdict(str_k.zc_space, c) == .c_flag);
    }
}

fn lit(planes: []u64, width: u32, signed: bool) Int.Literal {
    return .{ .width = width, .signed = signed, .sized = true, .planes = planes };
}

test "perDigit: one octal digit is 3 bits, one hex digit 4" {
    try testing.expectEqual(@as(u32, 1), Radix.binary.perDigit());
    try testing.expectEqual(@as(u32, 3), Radix.octal.perDigit());
    try testing.expectEqual(@as(u32, 4), Radix.hex.perDigit());
}

test "byteAt reads known 1 bits only, and nothing past the width" {
    // 12'bx101_0110_1001: bit 11 is x (v and x both set), bits 8..10 are 101.
    var p = [2]u64{ 0xd69, 0x800 };
    const v = lit(&p, 12, false);
    try testing.expectEqual(@as(u8, 0x69), byteAt(v, 0));
    try testing.expectEqual(@as(u8, 0x05), byteAt(v, 1));
    try testing.expectEqual(@as(u8, 0), byteAt(v, 2));
    // A byte of the second word of a 72-bit operand.
    var q = [4]u64{ 0, 0xab, 0, 0 };
    try testing.expectEqual(@as(u8, 0xab), byteAt(lit(&q, 72, false), 8));
}

test "%s drops leading zero bytes and right-justifies; %c is the last byte (§17.1.1.7)" {
    var out_buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out_buf);
    // 24'h00_48_69: "Hi" behind a zero byte.
    var p = [2]u64{ 0x4869, 0 };
    const v = lit(&p, 24, false);
    try text(&w, v, false, null);
    try testing.expectEqualStrings("Hi", w.buffered());
    w.end = 0;
    try text(&w, v, false, 5);
    try testing.expectEqualStrings("   Hi", w.buffered());
    w.end = 0;
    try text(&w, v, true, null);
    try testing.expectEqualStrings("i", w.buffered());
    w.end = 0;
    try text(&w, v, true, 3);
    try testing.expectEqualStrings("  i", w.buffered());
    w.end = 0;
    // All zero: every byte is a leading zero, so nothing prints.
    var zero = [2]u64{ 0, 0 };
    try text(&w, lit(&zero, 16, false), false, null);
    try testing.expectEqualStrings("", w.buffered());
}

test "decade spells every §19.8 operand" {
    const want = [_][]const u8{ "1fs", "10fs", "100fs", "1ps", "10ps", "100ps", "1ns", "10ns", "100ns", "1us", "10us", "100us", "1ms", "10ms", "100ms", "1s", "10s", "100s" };
    var out_buf: [8]u8 = undefined;
    for (want, 0..) |s, i| {
        var w: std.Io.Writer = .fixed(&out_buf);
        try decade(&w, @as(i32, @intCast(i)) - 15);
        try testing.expectEqualStrings(s, w.buffered());
    }
}

test "%t scales a unit count to $timeformat's units and pads to its width (§17.3)" {
    var out_buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out_buf);
    // 1500 units of 1 ns is 1500000 ps: 7 digits in the default 20 columns.
    var p = [2]u64{ 1500, 0 };
    const v = timeOperand(lit(&p, 64, false));
    try time(&w, v, .{ .units = -12 }, -9);
    try testing.expectEqualStrings("             1500000", w.buffered());
    w.end = 0;
    try time(&w, v, .{ .units = -12, .precision = 2, .suffix = " ps", .width = 0 }, -9);
    try testing.expectEqualStrings("1500000.00 ps", w.buffered());
    w.end = 0;
    // 1500 ns is 1.5 us.
    try time(&w, v, .{ .units = -6, .precision = 1, .width = 0 }, -9);
    try testing.expectEqualStrings("1.5", w.buffered());
    w.end = 0;
    // Signed: -5 units of 1 ns in ns.
    var n = [2]u64{ @bitCast(@as(i64, -5)), 0 };
    try time(&w, timeOperand(lit(&n, 64, true)), .{ .units = -9, .width = 0 }, -9);
    try testing.expectEqualStrings("-5", w.buffered());
    w.end = 0;
    // An x bit reads as no time at all.
    var x = [2]u64{ 1, 1 };
    try time(&w, timeOperand(lit(&x, 64, false)), .{ .units = -9, .width = 0 }, -9);
    try testing.expectEqualStrings("0", w.buffered());
    w.end = 0;
    // A real operand is not rounded to a whole unit first (#64): 1.55 units
    // of 10 ns is 15.5 ns.
    try time(&w, 1.55, .{ .units = -9, .precision = 3, .width = 0 }, -8);
    try testing.expectEqualStrings("15.500", w.buffered());
}

test "a group radix prints x and z per digit, lowercase when the whole group is unknown (§17.1.1.4)" {
    var out_buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out_buf);
    const Case = struct { v: u64, x: u64, width: u32, radix: Radix, field: ?u64, want: []const u8 };
    for ([_]Case{
        // 8'bx...: the octal top group has two bits, both x: still "x".
        .{ .v = 0xff, .x = 0xff, .width = 8, .radix = .octal, .field = null, .want = "xxx" },
        // 8'b0101_000x: one x bit of four is "X".
        .{ .v = 0x51, .x = 0x01, .width = 8, .radix = .hex, .field = null, .want = "5X" },
        // 8'bzzzz_0011: a whole z group is "z".
        .{ .v = 0x03, .x = 0xf0, .width = 8, .radix = .hex, .field = null, .want = "z3" },
        // 8'b0000_00z1: one z bit of four is "Z".
        .{ .v = 0x01, .x = 0x02, .width = 8, .radix = .hex, .field = null, .want = "0Z" },
        // 4'b1x0z, one digit per bit.
        .{ .v = 0xc, .x = 0x5, .width = 4, .radix = .binary, .field = null, .want = "1x0z" },
        // 12'd10: three hex digits by default, the leading zeros kept; `%0h`
        // drops them; an explicit field pads with spaces.
        .{ .v = 10, .x = 0, .width = 12, .radix = .hex, .field = null, .want = "00a" },
        .{ .v = 10, .x = 0, .width = 12, .radix = .hex, .field = 0, .want = "a" },
        .{ .v = 10, .x = 0, .width = 12, .radix = .hex, .field = 5, .want = "  00a" },
        // `%0b` of a zero keeps one digit.
        .{ .v = 0, .x = 0, .width = 4, .radix = .binary, .field = 0, .want = "0" },
    }) |c| {
        w.end = 0;
        var p = [2]u64{ c.v, c.x };
        try value(&w, testing.allocator, lit(&p, c.width, false), c.radix, c.field);
        try testing.expectEqualStrings(c.want, w.buffered());
    }
}

test "%d: one unknown bit poisons the number, and the field fits the largest value (§17.1.1.3)" {
    var out_buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out_buf);
    const Case = struct { v: u64, x: u64, width: u32, signed: bool = false, field: ?u64 = null, want: []const u8 };
    for ([_]Case{
        // 8'd7 in the 3 columns of 255; `%0d` drops the padding.
        .{ .v = 7, .x = 0, .width = 8, .want = "  7" },
        .{ .v = 7, .x = 0, .width = 8, .field = 0, .want = "7" },
        // A 32-bit integer in the 11 columns of -2147483648.
        .{ .v = 0xffff_fffb, .x = 0, .width = 32, .signed = true, .want = "         -5" },
        // All x, some x, all z, some z (and no x).
        .{ .v = 0xff, .x = 0xff, .width = 8, .want = "  x" },
        .{ .v = 0x01, .x = 0x01, .width = 8, .want = "  X" },
        .{ .v = 0x00, .x = 0xff, .width = 8, .want = "  z" },
        .{ .v = 0x00, .x = 0x10, .width = 8, .want = "  Z" },
        // 2^64 - 1, unsigned: not `asInt`'s -1.
        .{ .v = std.math.maxInt(u64), .x = 0, .width = 64, .want = "18446744073709551615" },
        .{ .v = 1 << 63, .x = 0, .width = 64, .signed = true, .want = "-9223372036854775808" },
    }) |c| {
        w.end = 0;
        var p = [2]u64{ c.v, c.x };
        try value(&w, testing.allocator, lit(&p, c.width, c.signed), .decimal, c.field);
        try testing.expectEqualStrings(c.want, w.buffered());
    }
    // 65 bits: an x pads to the 20 columns of 2^65 - 1.
    w.end = 0;
    var unknown = [4]u64{ std.math.maxInt(u64), 1, std.math.maxInt(u64), 1 };
    try value(&w, testing.allocator, lit(&unknown, 65, false), .decimal, null);
    try testing.expectEqualStrings("                   x", w.buffered());
    w.end = 0;
    // 128 bits: 2^128 - 1 is 340282366920938463463374607431768211455, 39 digits.
    var wide = [4]u64{ std.math.maxInt(u64), std.math.maxInt(u64), std.math.maxInt(u64), std.math.maxInt(u64) };
    try value(&w, testing.allocator, lit(&wide, 128, false), .decimal, null);
    try testing.expectEqualStrings("                                      x", w.buffered());
}

test "%d of a known operand past 64 bits is its whole decimal value (§17.1.1.3)" {
    var out_buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out_buf);
    const max = std.math.maxInt(u64);
    const Case = struct { lo: u64, hi: u64, width: u32, signed: bool = false, field: ?u64 = null, want: []const u8 };
    for ([_]Case{
        // 2^64, the first value past the old boundary, in the 20 columns of 2^65 - 1.
        .{ .lo = 0, .hi = 1, .width = 65, .want = "18446744073709551616" },
        // 2^65 - 1 as a signed 65-bit value is -1; -2^64 is the most negative.
        .{ .lo = max, .hi = 1, .width = 65, .signed = true, .field = 0, .want = "-1" },
        .{ .lo = 0, .hi = 1, .width = 65, .signed = true, .want = "-18446744073709551616" },
        // 2^128 - 1: 39 digits.
        .{ .lo = max, .hi = max, .width = 128, .want = "340282366920938463463374607431768211455" },
        // 10^19 exactly: the zero low group still prints all 19 of its zeros.
        .{ .lo = 10_000_000_000_000_000_000, .hi = 0, .width = 100, .field = 0, .want = "10000000000000000000" },
        // A small value in a 100-bit operand pads to 2^100 - 1's 31 columns.
        .{ .lo = 5, .hi = 0, .width = 100, .want = "                              5" },
        // Bits past the width are not read: 66 bits of all ones is 2^66 - 1.
        .{ .lo = max, .hi = max, .width = 66, .field = 0, .want = "73786976294838206463" },
    }) |c| {
        w.end = 0;
        var p = [4]u64{ c.lo, c.hi, 0, 0 };
        try value(&w, testing.allocator, lit(&p, c.width, c.signed), .decimal, c.field);
        try testing.expectEqualStrings(c.want, w.buffered());
    }
    // Well past it: 2^1000 in 1001 bits, 302 digits.
    var planes: [32]u64 = @splat(0);
    planes[15] = 1 << 40;
    var long_buf: [400]u8 = undefined;
    var lw: std.Io.Writer = .fixed(&long_buf);
    try value(&lw, testing.allocator, lit(&planes, 1001, false), .decimal, 0);
    try testing.expectEqualStrings("10715086071862673209484250490600018105614048117055336074437503883703510511249361224931983788156958581275946729175531468251871452856923140435984577574698574803934567774824230985421074605062371141877954182153046474983581941267398767559165543946077062914571196477686542167660429831652624386837205668069376", lw.buffered());
}

fn wideDecimalAllocation(gpa: std.mem.Allocator) !void {
    var planes: [32]u64 = @splat(0);
    planes[15] = 1 << 40;
    var buf: [400]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try value(&w, gpa, lit(&planes, 1001, true), .decimal, null);
}

test "%d past 64 bits frees its scratch on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, wideDecimalAllocation, .{});
}

/// The decimal digits of 2^n, by doubling a digit string: an oracle that
/// shares no arithmetic with `autoWidth`.
fn digitsOfPow2(n: u32) u32 {
    // ponytail: u32 digits, not u8. The Debug x86_64 backend fails to encode
    // the u8 version (`emit MIR failed: CannotEncode`, Zig 0.17.0).
    var d: [128]u32 = @splat(0);
    d[0] = 1;
    var len: u32 = 1;
    for (0..n) |_| {
        var carry: u32 = 0;
        for (d[0..len]) |*digit| {
            const doubled = digit.* * 2 + carry;
            digit.* = doubled % 10;
            carry = doubled / 10;
        }
        if (carry != 0) {
            d[len] = carry;
            len += 1;
        }
    }
    return len;
}

test "autoWidth is the width of the operand's largest value, at every width" {
    for (1..300) |i| {
        const w: u32 = @intCast(i);
        // 2^n is never a power of ten for n >= 1, so 2^n - 1 has its digits.
        try testing.expectEqual(digitsOfPow2(w), autoWidth(lit(&.{}, w, false), .decimal));
        // Signed: the magnitude of the most negative value, and its sign.
        try testing.expectEqual(1 + digitsOfPow2(w - 1), autoWidth(lit(&.{}, w, true), .decimal));
    }
    // A group radix: one digit per 1, 3 or 4 bits, rounded up.
    try testing.expectEqual(@as(u32, 3), autoWidth(lit(&.{}, 12, false), .hex));
    try testing.expectEqual(@as(u32, 3), autoWidth(lit(&.{}, 8, false), .octal));
    try testing.expectEqual(@as(u32, 5), autoWidth(lit(&.{}, 5, true), .binary));
}
