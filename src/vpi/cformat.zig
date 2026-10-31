//! A C format string and a `va_list` -> the bytes C11 7.21.6.1 prints, for
//! vpi_printf and its family.
//! Cites: ISO C11 7.21.6.1.
//!
//! Contents:
//! - `pub const EOF: c_int`
//! - `pub extern fn vpi_mcd_printf(mcd: c_uint, format: [*:0]const u8, ...) c_int;`
//! - `pub fn cformat(w: *Io.Writer, format: [*:0]const u8, ap: *List) bool`

const std = @import("std");
const Io = std.Io;
const va = @import("va.zig");
const List = va.List;

pub const EOF: c_int = -1;

/// `varargs.c`'s vpi_mcd_printf, for the tests below.
pub extern fn vpi_mcd_printf(mcd: c_uint, format: [*:0]const u8, ...) c_int;

const Spec = struct {
    left: bool = false,
    plus: bool = false,
    space: bool = false,
    alt: bool = false,
    zero: bool = false,
    width: usize = 0,
    prec: ?usize = null,
};

const Length = enum { none, hh, h, l, ll, j, z, t, L };

/// A real conversion's digits: `head`, then `zeros` more zeros, then `tail`
/// (an exponent). Zig renders the shortest round-trip digits and pads the rest
/// with zeros, so past `max_digits` a precision only adds zeros, and those are
/// written rather than rendered: no precision is clamped.
const Body = struct { head: []const u8, zeros: usize = 0, tail: []const u8 = "" };

/// Fraction digits past which %f's rendering is only zeros: the shortest
/// digits of an f64 end within 17 significant places of 4.9e-324.
const max_fixed = 341;

/// Mantissa digits past which %e's rendering is only zeros.
const max_sci = 17;

/// Calls `cformat` the way a C caller would: through a variadic, into a
/// 512-byte buffer (`varargs.c`'s `vera_vpi_format`). Returns the length
/// written, 0 on failure.
const formatted = @extern(*const fn (buf: [*]u8, format: [*:0]const u8, ...) callconv(.c) usize, .{ .name = "vera_vpi_format" });

/// Expand `fmt` against `ap`. A conversion C leaves undefined (an unknown
/// letter, a truncated spec) is copied through as written and consumes no
/// argument — the least wrong thing to do with a format nobody can read.
/// `%n` is not supported: it writes through an application pointer, and a
/// logging routine that stores into memory is a hazard this one does not take.
///
/// False when the writer failed (out of memory).
pub fn cformat(w: *Io.Writer, format: [*:0]const u8, ap: *List) bool {
    expand(w, std.mem.span(format), ap) catch return false;
    return true;
}

// ---- private ----

fn expand(w: *Io.Writer, fmt: []const u8, ap: *List) Io.Writer.Error!void {
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] != '%') {
            const end = std.mem.findScalarPos(u8, fmt, i, '%') orelse fmt.len;
            try w.writeAll(fmt[i..end]);
            i = end;
            continue;
        }
        const start = i;
        i += 1;
        var s: Spec = .{};
        while (i < fmt.len) : (i += 1) switch (fmt[i]) {
            '-' => s.left = true,
            '+' => s.plus = true,
            ' ' => s.space = true,
            '#' => s.alt = true,
            '0' => s.zero = true,
            else => break,
        };
        if (i < fmt.len and fmt[i] == '*') {
            i += 1;
            const v = va.arg(ap, c_int);
            if (v < 0) s.left = true;
            s.width = @abs(v);
        } else while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) {
            s.width = s.width *| 10 +| (fmt[i] - '0');
        }
        if (i < fmt.len and fmt[i] == '.') {
            i += 1;
            if (i < fmt.len and fmt[i] == '*') {
                i += 1;
                const v = va.arg(ap, c_int);
                s.prec = if (v < 0) null else @intCast(v);
            } else {
                var p: usize = 0;
                while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) p = p *| 10 +| (fmt[i] - '0');
                // C's precision is an `int`; past INT_MAX is undefined, and
                // clamped here so the arithmetic on it stays in range.
                s.prec = @min(p, std.math.maxInt(c_int));
            }
        }
        var len: Length = .none;
        if (i < fmt.len) {
            len = switch (fmt[i]) {
                'h' => .h,
                'l' => .l,
                'j' => .j,
                'z' => .z,
                't' => .t,
                'L' => .L,
                else => .none,
            };
            if (len != .none) i += 1;
            // `hh` and `ll`: the letter doubled.
            if ((len == .h or len == .l) and i < fmt.len and fmt[i] == fmt[i - 1]) {
                i += 1;
                len = if (len == .h) .hh else .ll;
            }
        }
        if (i >= fmt.len) {
            try w.writeAll(fmt[start..]);
            break;
        }
        const conv = fmt[i];
        i += 1;
        switch (conv) {
            '%' => try w.writeByte('%'),
            'd', 'i' => {
                const v: i128 = switch (len) {
                    .none, .h, .hh => blk: {
                        const x = va.arg(ap, c_int);
                        break :blk switch (len) {
                            .h => @as(i16, @truncate(x)),
                            .hh => @as(i8, @truncate(x)),
                            else => x,
                        };
                    },
                    .l => va.arg(ap, c_long),
                    .ll, .L => va.arg(ap, c_longlong),
                    .j => va.arg(ap, i64),
                    .z, .t => va.arg(ap, isize),
                };
                try integer(w, s, @intCast(@abs(v)), v < 0, 10, false);
            },
            'u', 'x', 'X', 'o' => {
                const v: u64 = switch (len) {
                    .none, .h, .hh => blk: {
                        const x: c_uint = @bitCast(va.arg(ap, c_int));
                        break :blk switch (len) {
                            .h => @as(u16, @truncate(x)),
                            .hh => @as(u8, @truncate(x)),
                            else => x,
                        };
                    },
                    .l => va.arg(ap, c_ulong),
                    .ll, .L => va.arg(ap, c_ulonglong),
                    .j => va.arg(ap, u64),
                    .z, .t => va.arg(ap, usize),
                };
                const base: u8 = switch (conv) {
                    'o' => 8,
                    'u' => 10,
                    else => 16,
                };
                try integer(w, s, v, false, base, conv == 'X');
            },
            'c' => {
                const b: u8 = @truncate(@as(c_uint, @bitCast(va.arg(ap, c_int))));
                try padded(w, s, &.{b});
            },
            's' => {
                const p = va.arg(ap, ?[*:0]const u8);
                var text: []const u8 = if (p) |q| std.mem.span(q) else "(null)";
                if (s.prec) |pr| text = text[0..@min(pr, text.len)];
                try padded(w, s, text);
            },
            'p' => {
                const p = va.arg(ap, usize);
                var buf: [2 + 16]u8 = undefined;
                const text = std.mem.print(&buf, "0x{x}", .{p}) catch unreachable;
                try padded(w, s, text);
            },
            'f', 'F', 'e', 'E', 'g', 'G' => {
                // ponytail: `long double` cannot be read from a va_list by this
                // compiler on SysV. Its size is not an f64's, so every later
                // argument would be misread: the rest of the format goes out
                // verbatim instead. `%L` in a VPI log line is the ceiling.
                if (len == .L) return w.writeAll(fmt[start..]);
                try real(w, s, va.arg(ap, f64), conv);
            },
            'n' => _ = va.arg(ap, ?*anyopaque),
            else => try w.writeAll(fmt[start..i]),
        }
    }
}

/// `text` in a field of `s.width`, space-padded on the side `-` selects.
fn padded(w: *Io.Writer, s: Spec, text: []const u8) Io.Writer.Error!void {
    const pad = s.width -| text.len;
    if (!s.left) try w.splatByteAll(' ', pad);
    try w.writeAll(text);
    if (s.left) try w.splatByteAll(' ', pad);
}

/// A sign or prefix, zeros, then digits, laid into the field. C's '0' flag
/// puts its padding BETWEEN the prefix and the digits, and is ignored when a
/// precision is given or the field is left-justified.
fn field(w: *Io.Writer, s: Spec, prefix: []const u8, zeros: usize, digits: []const u8, zero_ok: bool) Io.Writer.Error!void {
    const body = prefix.len + zeros + digits.len;
    const pad = s.width -| body;
    const zero_fill = s.zero and !s.left and zero_ok;
    if (!s.left and !zero_fill) try w.splatByteAll(' ', pad);
    try w.writeAll(prefix);
    if (zero_fill) try w.splatByteAll('0', pad);
    try w.splatByteAll('0', zeros);
    try w.writeAll(digits);
    if (s.left) try w.splatByteAll(' ', pad);
}

fn integer(w: *Io.Writer, s: Spec, mag: u64, neg: bool, base: u8, upper: bool) Io.Writer.Error!void {
    var buf: [64]u8 = undefined;
    var digits: []const u8 = buf[0..std.fmt.printInt(&buf, mag, base, if (upper) .upper else .lower, .{})];
    // "The result of converting a zero value with a precision of zero is no
    // characters."
    if (mag == 0 and s.prec != null and s.prec.? == 0) digits = "";
    var zeros: usize = if (s.prec) |p| p -| digits.len else 0;
    var prefix_buf: [2]u8 = undefined;
    var prefix: []const u8 = "";
    if (neg) prefix = "-" else if (base == 10 and s.plus) prefix = "+" else if (base == 10 and s.space) prefix = " ";
    if (s.alt and base == 8 and zeros == 0 and (digits.len == 0 or digits[0] != '0')) zeros = 1;
    if (s.alt and base == 16 and mag != 0) {
        prefix_buf = .{ '0', if (upper) 'X' else 'x' };
        prefix = &prefix_buf;
    }
    try field(w, s, prefix, zeros, digits, s.prec == null);
}

/// %e %f %g, C11 7.21.6.1 semantics over Zig's shortest-round-trip digits.
///
/// ponytail: rounding is of the SHORTEST decimal that round-trips, not of the
/// exact binary value, so a tie like `%.2f` of 0.125 (exactly representable)
/// can land on the other side of glibc's answer. That costs a last digit on a
/// logging routine; exact binary-to-decimal is the upgrade if an application
/// ever depends on it.
fn real(w: *Io.Writer, s: Spec, v: f64, conv: u8) Io.Writer.Error!void {
    const upper = std.ascii.isUpper(conv);
    const neg = std.math.signbit(v);
    const sign: []const u8 = if (neg) "-" else if (s.plus) "+" else if (s.space) " " else "";
    if (std.math.isNan(v) or std.math.isInf(v)) {
        const word = if (std.math.isNan(v)) (if (upper) "NAN" else "nan") else (if (upper) "INF" else "inf");
        return field(w, s, sign, 0, word, false);
    }
    const a = @abs(v);
    const p: usize = s.prec orelse 6;
    var buf: [512]u8 = undefined;
    const body: Body = switch (conv | 0x20) {
        'f' => fixed(&buf, a, p, s.alt),
        'e' => sci(&buf, a, p, upper, s.alt),
        else => blk: {
            // C: P = p, or 1 if p is 0. X = the exponent %e would print. Style
            // f with precision P-1-X if P > X >= -4, else style e with P-1;
            // then trailing zeros go unless '#'.
            const pg: usize = if (p == 0) 1 else p;
            const x = exponentAfterRounding(a, pg - 1);
            const out = if (x >= -4 and x < std.math.cast(i32, pg) orelse std.math.maxInt(i32))
                fixed(&buf, a, @intCast(@as(i64, @intCast(pg)) - 1 - x), s.alt)
            else
                sci(&buf, a, pg - 1, upper, s.alt);
            // The padding zeros are all fractional, so stripping takes them.
            break :blk if (s.alt) out else .{ .head = stripZeros(out.head), .tail = out.tail };
        },
    };
    const len = sign.len + body.head.len + body.zeros + body.tail.len;
    const pad = s.width -| len;
    const zero_fill = s.zero and !s.left;
    if (!s.left and !zero_fill) try w.splatByteAll(' ', pad);
    try w.writeAll(sign);
    if (zero_fill) try w.splatByteAll('0', pad);
    try w.writeAll(body.head);
    try w.splatByteAll('0', body.zeros);
    try w.writeAll(body.tail);
    if (s.left) try w.splatByteAll(' ', pad);
}

/// The decimal exponent of `a` printed as %e with `p` fraction digits — which
/// can be one more than `a`'s own when rounding carries (9.99 at p=1 is 1.0e1).
fn exponentAfterRounding(a: f64, p: usize) i32 {
    var buf: [64]u8 = undefined;
    const r = std.fmt.float.render(&buf, a, .{ .mode = .scientific, .precision = @min(p, max_sci) }) catch return 0;
    const e = std.mem.findScalar(u8, r, 'e') orelse return 0;
    return std.fmt.parseInt(i32, r[e + 1 ..], 10) catch 0;
}

fn fixed(buf: []u8, a: f64, p: usize, alt: bool) Body {
    const r = std.fmt.float.render(buf, a, .{ .mode = .decimal, .precision = @min(p, max_fixed) }) catch return .{ .head = "?" };
    if (p == 0 and alt) {
        buf[r.len] = '.';
        return .{ .head = buf[0 .. r.len + 1] };
    }
    return .{ .head = r, .zeros = p -| max_fixed };
}

/// Zig renders `1.5e3`; C wants `1.500000e+03` — at least two exponent digits
/// and an explicit sign.
fn sci(buf: []u8, a: f64, p: usize, upper: bool, alt: bool) Body {
    var tmp: [64]u8 = undefined;
    const r = std.fmt.float.render(&tmp, a, .{ .mode = .scientific, .precision = @min(p, max_sci) }) catch return .{ .head = "?" };
    const e = std.mem.findScalar(u8, r, 'e') orelse return .{ .head = "?" };
    const x = std.fmt.parseInt(i32, r[e + 1 ..], 10) catch 0;
    const mant = r[0..e];
    const dot = if (p == 0 and alt) "." else "";
    const head = std.mem.print(buf, "{s}{s}", .{ mant, dot }) catch return .{ .head = "?" };
    const tail = std.mem.print(buf[head.len..], "{c}{c}{d:0>2}", .{
        @as(u8, if (upper) 'E' else 'e'), @as(u8, if (x < 0) '-' else '+'), @abs(x),
    }) catch return .{ .head = "?" };
    return .{ .head = head, .zeros = p -| max_sci, .tail = tail };
}

/// %g's "trailing zeros are removed from the fractional portion of the result
/// and the decimal-point character is removed if there is no fractional
/// portion remaining", on a fixed result or an e-style mantissa.
fn stripZeros(s: []const u8) []const u8 {
    if (std.mem.findScalar(u8, s, '.') == null) return s;
    var end = s.len;
    while (end > 0 and s[end - 1] == '0') end -= 1;
    if (end > 0 and s[end - 1] == '.') end -= 1;
    return s[0..end];
}

/// `cformat` into `buf`, for `varargs.c`'s `vera_vpi_format`: 0 when it fails.
export fn vera_vpi_cformat(buf: [*]u8, len: usize, format: [*:0]const u8, ap: *List) usize {
    var w: Io.Writer = .fixed(buf[0..len]);
    if (!cformat(&w, format, ap)) return 0;
    return w.end;
}

fn expectFormat(want: []const u8, got_len: usize, buf: []const u8) !void {
    try std.testing.expectEqualStrings(want, buf[0..got_len]);
}

test "C conversions: integers, flags, widths and precisions" {
    var b: [512]u8 = undefined;
    try expectFormat("p02 printf 7 ok\n", formatted(&b, "p02 printf %d %s\n", @as(c_int, 7), @as([*:0]const u8, "ok")), &b);
    try expectFormat("[   -42][-42   ][-0042][+42]", formatted(&b, "[%6d][%-6d][%05d][%+d]", @as(c_int, -42), @as(c_int, -42), @as(c_int, -42), @as(c_int, 42)), &b);
    try expectFormat("ff 0XFF 017 0x1f", formatted(&b, "%x %#X %#o %#x", @as(c_uint, 255), @as(c_uint, 255), @as(c_uint, 15), @as(c_uint, 31)), &b);
    try expectFormat("4294967295 18446744073709551615", formatted(&b, "%u %llu", @as(c_uint, 0xffffffff), @as(c_ulonglong, std.math.maxInt(u64))), &b);
    try expectFormat("[ab][   xyz][c]%", formatted(&b, "[%.2s][%*s][%c]%%", @as([*:0]const u8, "abc"), @as(c_int, 6), @as([*:0]const u8, "xyz"), @as(c_int, 'c')), &b);
    try expectFormat("[00007][]", formatted(&b, "[%.5d][%.0d]", @as(c_int, 7), @as(c_int, 0)), &b);
}

test "C conversions: reals" {
    var b: [512]u8 = undefined;
    try expectFormat("3.500000 1.500000e+03 2.5E-07", formatted(&b, "%f %e %.1E", @as(f64, 3.5), @as(f64, 1500.0), @as(f64, 2.5e-7)), &b);
    // %g: style f inside [1e-4, 1e6), style e outside, trailing zeros stripped.
    try expectFormat("0.0001 100000 1e+06 1e-05 0.5", formatted(&b, "%g %g %g %g %g", @as(f64, 1e-4), @as(f64, 1e5), @as(f64, 1e6), @as(f64, 1e-5), @as(f64, 0.5)), &b);
    try expectFormat("[  -1.25][-001.25][inf]", formatted(&b, "[%7.2f][%07.2f][%f]", @as(f64, -1.25), @as(f64, -1.25), std.math.inf(f64)), &b);
    try expectFormat("3.14159", formatted(&b, "%g", @as(f64, 3.14159265)), &b);
}

test "C conversions: a real's precision is never clamped" {
    var b: [512]u8 = undefined;
    // 0.5 exactly, 100 fraction digits: "0.5" then 99 zeros.
    try expectFormat("0.5" ++ @as([99]u8, @splat('0')), formatted(&b, "%.100f", @as(f64, 0.5)), &b);
    // 60 mantissa digits: "1." and 60 zeros, then the exponent.
    try expectFormat("1." ++ @as([60]u8, @splat('0')) ++ "e+00", formatted(&b, "%.60e", @as(f64, 1.0)), &b);
    // The smallest subnormal's one shortest digit (see `real`) sits at the
    // 324th place, past where the old 300-digit clamp cut it off.
    try expectFormat("0." ++ @as([323]u8, @splat('0')) ++ "5000000", formatted(&b, "%.330f", @as(f64, 5e-324)), &b);
}

test "C conversions: flags, lengths, and the conversions C leaves undefined" {
    var b: [512]u8 = undefined;
    // C11 7.21.6.1: '+' and ' ' on a signed conversion; '0' is ignored when a
    // precision is given.
    try expectFormat("+0| 42|  007|7    ", formatted(&b, "%+d|% d|%05.3d|%-5d", @as(c_int, 0), @as(c_int, 42), @as(c_int, 7), @as(c_int, 7)), &b);
    // A zero at precision 0 is no digits, but keeps its sign; '#' with 'o'
    // still prints the one 0.
    try expectFormat("[][+][0]", formatted(&b, "[%.0d][%+.0d][%#.0o]", @as(c_int, 0), @as(c_int, 0), @as(c_uint, 0)), &b);
    // hh and h convert to char and short first: 300 is 44, 70000 is 4464,
    // 255 as a signed char is -1.
    try expectFormat("44 4464 -1", formatted(&b, "%hhd %hd %hhd", @as(c_int, 300), @as(c_int, 70000), @as(c_int, 255)), &b);
    // A negative '*' width is the '-' flag; a negative '*' precision is none.
    try expectFormat("[ab   ][abc]", formatted(&b, "[%*s][%.*s]", @as(c_int, -5), @as([*:0]const u8, "ab"), @as(c_int, -1), @as([*:0]const u8, "abc")), &b);
    // An unknown conversion goes out as written and takes no argument; so
    // does a spec the format ends inside.
    try expectFormat("%q 5 %", formatted(&b, "%q %d %", @as(c_int, 5)), &b);
    try expectFormat("[  x][y  ]", formatted(&b, "[%3c][%-3c]", @as(c_int, 'x'), @as(c_int, 'y')), &b);
    try expectFormat("-9223372036854775808 8000000000000000", formatted(&b, "%lld %llx", @as(c_longlong, std.math.minInt(i64)), @as(c_ulonglong, 1 << 63)), &b);
}

test "C conversions: reals at the edges" {
    var b: [512]u8 = undefined;
    // Zero in each style; %g strips "0.00000" to "0".
    try expectFormat("0.000000 0.000000e+00 0", formatted(&b, "%f %e %g", @as(f64, 0), @as(f64, 0), @as(f64, 0)), &b);
    // A negative zero keeps its sign; '+' and ' ' on a positive value.
    try expectFormat("-0.0 +1.5 [ 1.5]", formatted(&b, "%.1f %+.1f [% .1f]", @as(f64, -0.0), @as(f64, 1.5), @as(f64, 1.5)), &b);
    // %E and %G upper-case the exponent; '#' keeps %g's trailing zeros.
    try expectFormat("1.000000E-10 1E-10 1.00000", formatted(&b, "%E %G %#g", @as(f64, 1e-10), @as(f64, 1e-10), @as(f64, 1.0)), &b);
    // Precision 0: no point unless '#'.
    try expectFormat("3 3. 1e+04 1.e+04", formatted(&b, "%.0f %#.0f %.0e %#.0e", @as(f64, 2.6), @as(f64, 2.6), @as(f64, 12345), @as(f64, 12345)), &b);
    // '0' pads between the sign and the digits; '-' pads on the right.
    try expectFormat("-00003.142|1.23e+03  |", formatted(&b, "%010.3f|%-10.2e|", @as(f64, -3.14159), @as(f64, 1234.5)), &b);
    // Infinities and NaN: no zero padding, case from the conversion.
    try expectFormat("nan|  INF|-inf  |  inf", formatted(&b, "%f|%5F|%-6f|%05f", std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64), std.math.inf(f64)), &b);
}

test "C conversions: a precision past INT_MAX is clamped, not trapped" {
    var b: [512]u8 = undefined;
    // %g strips the zeros a huge precision asks for; %f cannot fit them in
    // the buffer, which fails the format (0) rather than the process.
    try expectFormat("1|", formatted(&b, "%.99999999999999999999g|", @as(f64, 1.0)), &b);
    try std.testing.expectEqual(@as(usize, 0), formatted(&b, "%.99999999999999999999f", @as(f64, 1.0)));
    try std.testing.expectEqual(@as(usize, 0), formatted(&b, "%99999999999999999999d", @as(c_int, 1)));
}
