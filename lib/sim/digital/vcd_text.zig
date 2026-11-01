//! A dumped variable's planes in, its §18.2 value-change text out: the identifier codes (`codeText`), one value change (`value`) and §18.2.1's `%.16g` real (`g16`), shared by the interpreter's dump and a native executable's (vcd.zig).
//! Cites: IEEE 1364-2005 §18.2.1, §18.2.2, §18.2.3.11, Table 18-1.
//!
//! Contents:
//! - `pub fn words(w: u32) u32`
//! - `pub fn codeText(w: *std.Io.Writer, code: u32) std.Io.Writer.Error!void`
//! - `pub fn value(w: *std.Io.Writer, v: Var, p: []const u64, code: u32, as_x: bool) std.Io.Writer.Error!void`
//! - `pub fn g16(buf: *[64]u8, r: f64) []const u8`
//! - `pub fn strip(s: []const u8) []const u8`

const std = @import("std");
const assert = std.debug.assert;
const bitChar = @import("net.zig").bitChar;
const Var = @import("vcd.zig").Var;

/// 64-bit words in a `w`-bit plane.
pub fn words(w: u32) u32 {
    const n = (w + 63) / 64;
    assert(n * 64 >= w);
    assert(n == 0 or (n - 1) * 64 < w);
    return n;
}

/// §18.2.1 identifier codes, "composed of the printable characters ... from
/// ! to ~": code 0 is `!`, and a longer code counts on in base 94.
pub fn codeText(w: *std.Io.Writer, code: u32) std.Io.Writer.Error!void {
    var n = code;
    // 94^5 > 2^32: a u32 code is at most five characters.
    var chars: u32 = 0;
    while (true) : (chars += 1) {
        assert(chars < 5);
        assert(n <= code); // Each character divides the rest down.
        try w.writeByte(@intCast('!' + n % 94));
        if (n < 94) return;
        n = n / 94 - 1;
    }
}

/// §18.2.2 one value change of `v`, whose planes are `p`: a scalar's value
/// and code with no space, a vector's `b` digits then one space, a real's
/// `r` and `%.16g`.
pub fn value(w: *std.Io.Writer, v: Var, p: []const u64, code: u32, as_x: bool) std.Io.Writer.Error!void {
    assert(v.width != 0);
    assert(p.len == 2 * words(v.width)); // A value plane and an unknown plane.
    if (v.real) assert(v.width == 64);
    const lit: @import("kernels").Integer.Literal = .{ .width = v.width, .signed = false, .sized = true, .planes = @constCast(p) };
    if (v.real and !as_x) {
        var buf: [64]u8 = undefined;
        try w.print("r{s} ", .{g16(&buf, @bitCast(p[0]))});
    } else if (v.width == 1) {
        try w.writeByte(if (as_x) 'x' else bitChar(lit.bit(0)));
    } else {
        try w.writeByte('b');
        var i = v.width;
        if (as_x) i = 1;
        // Table 18-1: a leading digit the next one would extend to anyway is
        // dropped: 0 before 0 or 1, x before x, z before z.
        while (i > 1) : (i -= 1) {
            const top = lit.bit(i - 1);
            const next = lit.bit(i - 2);
            const redundant = if (top == .zero) next == .zero or next == .one else top != .one and top == next;
            if (!redundant) break;
        }
        while (i > 0) : (i -= 1) try w.writeByte(if (as_x) 'x' else bitChar(lit.bit(i - 1)));
        try w.writeByte(' ');
    }
    try codeText(w, code);
    try w.writeByte('\n');
}

/// §18.2.1 "A real number is dumped using a %.16g printf() format": C's
/// style e when the exponent is below -4 or at least 16, else style f with
/// 16 significant digits, trailing zeros and point removed either way.
pub fn g16(buf: *[64]u8, r: f64) []const u8 {
    if (std.math.isNan(r)) return "nan";
    if (std.math.isInf(r)) return if (r < 0) "-inf" else "inf";
    var sci_buf: [64]u8 = undefined;
    const sci = std.mem.print(&sci_buf, "{e:.15}", .{r}) catch unreachable;
    const e_at = std.mem.findScalar(u8, sci, 'e').?;
    const x = std.fmt.parseInt(i32, sci[e_at + 1 ..], 10) catch unreachable;
    // A finite f64's decimal exponent, subnormals included.
    assert(x >= -324);
    assert(x <= 308);
    if (x < -4 or x >= 16) {
        const mant = strip(sci[0..e_at]);
        return std.mem.print(buf, "{s}e{c}{d:0>2}", .{ mant, @as(u8, if (x < 0) '-' else '+'), @abs(x) }) catch unreachable;
    }
    return strip(std.mem.print(buf, "{d:.[1]}", .{ r, @as(usize, @intCast(15 - x)) }) catch unreachable);
}

/// `%g`'s removal of trailing fraction zeros and a trailing point.
pub fn strip(s: []const u8) []const u8 {
    assert(s.len != 0);
    if (std.mem.findScalar(u8, s, '.') == null) return s;
    const t = std.mem.trimEnd(u8, s, "0");
    const out = if (t[t.len - 1] == '.') t[0 .. t.len - 1] else t;
    assert(out.len != 0); // A digit precedes the point.
    return out;
}

// ---- private ----

/// Reads back an identifier code `codeText` wrote (least significant
/// character first): the inverse the codes' uniqueness is checked with.
fn codeValue(text: []const u8) u32 {
    assert(text.len != 0);
    assert(text.len <= 5); // `codeText`'s bound.
    var i = text.len - 1;
    var n: u32 = text[i] - '!';
    while (i != 0) {
        i -= 1;
        n = (text[i] - '!') + 94 * (n + 1);
    }
    return n;
}

fn testLiteral(a: std.mem.Allocator, bits: []const u8) !@import("kernels").Integer.Literal {
    assert(bits.len != 0);
    const v = try @import("net.zig").filled(a, @intCast(bits.len), false, .zero);
    for (bits, 0..) |c, i| @import("net.zig").setBit(v, @intCast(bits.len - 1 - i), switch (c) {
        '0' => .zero,
        '1' => .one,
        'x' => .x,
        else => .z,
    });
    assert(v.width == bits.len);
    return v;
}

test "§18.2.1 %.16g" {
    var buf: [64]u8 = undefined;
    for ([_]f64{ 1.5, -2.25e10, 0.25, 6.02e23, 1e16, 0.0, 1.0 / 3.0, 1e-5, 123456789012345678.0 }, [_][]const u8{ "1.5", "-22500000000", "0.25", "6.02e+23", "1e+16", "0", "0.3333333333333333", "1e-05", "1.234567890123457e+17" }) |r, want|
        try std.testing.expectEqualStrings(want, g16(&buf, r));
}

test "§18.2.1 %.16g at the edges of its two styles" {
    var buf: [64]u8 = undefined;
    // Each expected text is C's printf("%.16g") of the value: the style is
    // chosen by the exponent after rounding to 16 digits, so 9.999...e15
    // rounds up into style e.
    const cases = [_]struct { f64, []const u8 }{
        .{ -@as(f64, 0.0), "-0" },
        .{ @as(f64, 0.1) + 0.2, "0.3" },
        .{ 1e-4, "0.0001" },
        .{ 3.0000000000000004e-05, "3e-05" },
        .{ 1e15, "1000000000000000" },
        .{ 9007199254740992.0, "9007199254740992" },
        .{ 9.999999999999999e15, "1e+16" },
        .{ 1.5e-300, "1.5e-300" },
        .{ 123.456, "123.456" },
        .{ std.math.inf(f64), "inf" },
        .{ -std.math.inf(f64), "-inf" },
        .{ std.math.nan(f64), "nan" },
    };
    for (cases) |c| try std.testing.expectEqualStrings(c[1], g16(&buf, c[0]));
}

test codeText {
    var buf: [16]u8 = undefined;
    // §18.2.1: the 94 printable characters from ! to ~, then two of them.
    const cases = [_]struct { u32, []const u8 }{
        .{ 0, "!" },
        .{ 1, "\"" },
        .{ 93, "~" },
        .{ 94, "!!" },
        .{ 95, "\"!" },
        .{ 187, "~!" },
        .{ 188, "!\"" },
        .{ 94 * 94 + 93, "~~" },
    };
    for (cases) |c| {
        var w: std.Io.Writer = .fixed(&buf);
        try codeText(&w, c[0]);
        try std.testing.expectEqualStrings(c[1], w.buffered());
    }
    // Every code reads back as itself, so no two variables share one.
    for (0..20_000) |code| {
        var w: std.Io.Writer = .fixed(&buf);
        try codeText(&w, @intCast(code));
        try std.testing.expectEqual(@as(u32, @intCast(code)), codeValue(w.buffered()));
        for (w.buffered()) |ch| try std.testing.expect(ch >= '!' and ch <= '~');
    }
}

test value {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // §18.2.1 Table 18-1: a vector drops a leading digit the next one left-
    // extends to anyway: 0 before 0 or 1, x before x, z before z. Never a
    // 1, and never a 0 before an x or z.
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "0000", "b0 !\n" },
        .{ "0010", "b10 !\n" },
        .{ "1010", "b1010 !\n" },
        .{ "xx01", "bx01 !\n" },
        .{ "zzzz", "bz !\n" },
        .{ "0x10", "b0x10 !\n" },
        .{ "z", "z!\n" },
        .{ "1", "1!\n" },
    };
    for (cases) |c| {
        const v = try testLiteral(a, c[0]);
        var out: std.Io.Writer.Allocating = .init(a);
        try value(&out.writer, .{ .slot = 0, .width = v.width, .real = false, .head = "", .tail = "" }, v.planes, 0, false);
        try std.testing.expectEqualStrings(c[1], out.written());
    }
    // §18.2.3.11 `$dumpoff`'s x: a vector as one extended digit.
    {
        const v = try testLiteral(a, "1010");
        var out: std.Io.Writer.Allocating = .init(a);
        try value(&out.writer, .{ .slot = 0, .width = 4, .real = false, .head = "", .tail = "" }, v.planes, 95, true);
        try std.testing.expectEqualStrings("bx \"!\n", out.written());
    }
    // A real: `r`, its %.16g, a space.
    {
        const p = [2]u64{ @bitCast(@as(f64, 1.5)), 0 };
        var out: std.Io.Writer.Allocating = .init(a);
        try value(&out.writer, .{ .slot = 0, .width = 64, .real = true, .head = "", .tail = "" }, &p, 0, false);
        try std.testing.expectEqualStrings("r1.5 !\n", out.written());
    }
}
