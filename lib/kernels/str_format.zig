//! §9.5.3 a format string known only at run time: its bytes, the scope name
//! and a tuple of arguments in, the formatted text out, in the call site's
//! row. Device text (`text.str`). A literal format is translated at compile
//! time (`cg_display.translateFormat`); a string variable's content is known
//! only here, so this walks it with the same §9.4.3 conversions.
//! Cites: VAMS §2.7, §4.2.1.1, §9.4.3, §9.4.5, §9.5.3; C11 7.21.6.1.
//!
//! Contents:
//! - `pub fn zSFormatRt(buf: anytype, fmt: []const u8, scope: []const u8, args: anytype) []u8`

const zstd = @import("std");
// The device has these at file scope; the host compile aliases them.
const zCReal = @import("str_real.zig").zCReal;
const zcFlag = @import("str_real.zig").zcFlag;
const zcAltOk = @import("str_real.zig").zcAltOk;
const zc_left = @import("str_real.zig").zc_left;
const zc_plus = @import("str_real.zig").zc_plus;
const zc_space = @import("str_real.zig").zc_space;
const zc_zero = @import("str_real.zig").zc_zero;
const zc_alt = @import("str_real.zig").zc_alt;
const zSOver = @import("str_store.zig").zSOver;
const zSTmp = @import("str_store.zig").zSTmp;

// ---- device text ----

/// `zSFormatRt`'s output: an overrun is E1011 rather than a cut.
/// Invariant: `n <= b.len`.
const ZRtOut = struct {
    b: []u8,
    n: usize = 0,

    fn put(self: *ZRtOut, c: u8) void {
        if (self.n >= self.b.len) zSOver();
        self.b[self.n] = c;
        self.n += 1;
    }

    fn str(self: *ZRtOut, s: []const u8) void {
        for (s) |c| self.put(c);
    }
};

/// Returns `fmt` formatted over `args` (a tuple of `i64`, `f64` and
/// `[]const u8` in source order), in `buf` (a pointer to the site's row).
/// §9.5.3: "$sformat always interprets its second argument, and only its
/// second argument, as a format string ... or can be a string variable whose
/// content is interpreted as the format string". `scope` is what `%m` prints
/// (and `%l` after "work.", as the compile-time path does). "If not enough
/// arguments are supplied for the format specifiers or too many are
/// supplied, then the application shall issue a warning and continue
/// execution": a specifier with no argument left prints nothing, a surplus
/// argument is not printed, and either draws one warning on stderr. An
/// overrun is E1011, and so is a width or precision wider than the row.
/// ponytail: a radix conversion shows the 64-bit pattern (no §17.1.1.3
/// automatic width, which needs the operand's declared width); an unknown
/// letter, or '#' on a conversion `zcAltOk` refuses, is copied through with a
/// warning. Thread the widths in if a model formats a sized vector through a
/// variable format.
pub fn zSFormatRt(buf: anytype, fmt: []const u8, scope: []const u8, args: anytype) []u8 {
    var o: ZRtOut = .{ .b = buf };
    // A real field's scratch: the row plus `zCReal`'s widest body past a
    // precision, so every field that fits the row fits here.
    const tmp = zSTmp(buf.len + 512);
    var next: usize = 0;
    var short = false;
    var i: usize = 0;
    while (i < fmt.len) {
        const c = fmt[i];
        i += 1;
        if (c != '%' or i >= fmt.len) {
            o.put(c);
            continue;
        }
        if (fmt[i] == '%') {
            o.put('%');
            i += 1;
            continue;
        }
        const at = i - 1;
        var flags: u8 = 0;
        while (i < fmt.len) : (i += 1) flags |= zcFlag(fmt[i]) orelse break;
        var width: usize = 0;
        while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) width = width *| 10 +| (fmt[i] - '0');
        var prec: i64 = -1;
        if (i < fmt.len and fmt[i] == '.') {
            i += 1;
            prec = 0;
            while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) prec = prec *| 10 +| (fmt[i] - '0');
        }
        if (i >= fmt.len) {
            o.str(fmt[at..]);
            break;
        }
        const conv = fmt[i];
        i += 1;
        // '#' on a conversion with no alternative form is the compile-time
        // path's E0825; known only here, it is the unknown letter's warning.
        if (flags & zc_alt != 0 and !zcAltOk(conv)) {
            zstd.debug.print("warning: $sformat: LRM 9.4.3: `{s}` is not a format specification ('#' is defined on %e, %f and %g only); copied as text\n", .{fmt[at..i]});
            o.str(fmt[at..i]);
            continue;
        }
        switch (conv | 0x20) {
            'm' => zsRtField(&o, scope, flags, width),
            'l' => {
                // "work." then the cell, padded as one field.
                const pad = width -| (5 + scope.len);
                if (flags & zc_left == 0) for (0..pad) |_| o.put(' ');
                o.str("work.");
                o.str(scope);
                if (flags & zc_left != 0) for (0..pad) |_| o.put(' ');
            },
            'd', 'h', 'x', 'o', 'b', 'c', 's', 'e', 'f', 'g', 'r' => {
                if (next >= args.len) {
                    short = true;
                    continue;
                }
                inline for (args, 0..) |a, k| if (k == next) zsRtConv(&o, tmp, a, conv, flags, width, prec);
                next += 1;
            },
            else => {
                zstd.debug.print("warning: $sformat: LRM 9.4.3: `{s}` is not a format specification; copied as text\n", .{fmt[at..i]});
                o.str(fmt[at..i]);
            },
        }
    }
    if (short or next < args.len)
        zstd.debug.print("warning: $sformat: LRM 9.5.3: the format string \"{s}\" has {s} specifications than its {d} argument(s)\n", .{ fmt, if (short) "more" else "fewer", args.len });
    zstd.debug.assert(next <= args.len);
    zstd.debug.assert(o.n <= o.b.len);
    return o.b[0..o.n];
}

// ---- private ----

/// `text` in a field of `width`, space-padded on the side '-' does not pick.
fn zsRtField(o: *ZRtOut, text: []const u8, flags: u8, width: usize) void {
    const pad = width -| text.len;
    if (flags & zc_left == 0) for (0..pad) |_| o.put(' ');
    o.str(text);
    if (flags & zc_left != 0) for (0..pad) |_| o.put(' ');
}

/// One argument through one §9.4.3 conversion: a real conversion is
/// `zCReal`; an integer one takes §4.2.1.1's rounding of a real and §2.7's
/// value of a string; `%s` of a number is its bytes (§9.4.5).
fn zsRtConv(o: *ZRtOut, tmp: []u8, a: anytype, conv: u8, flags: u8, width: usize, prec: i64) void {
    const T = @TypeOf(a);
    const int: i64 = if (T == i64) a else if (T == f64) zstd.math.lossyCast(i64, @round(a)) else blk: {
        var acc: u64 = 0;
        for (a[a.len - @min(a.len, 8) ..]) |ch| acc = acc << 8 | ch;
        break :blk @bitCast(acc);
    };
    switch (conv | 0x20) {
        'e', 'f', 'g', 'r' => {
            // A field or a precision past the row's room cannot fit; below
            // that, `tmp` holds the whole field.
            const room = o.b.len - o.n;
            if (width > room or prec > @as(i64, @intCast(room))) zSOver();
            zstd.debug.assert(tmp.len >= room + 512);
            o.str(zCReal(tmp, if (T == f64) a else @floatFromInt(int), conv, flags, width, prec));
        },
        'c' => zsRtField(o, &.{@as(u8, @truncate(@as(u64, @bitCast(int))))}, flags, width),
        's' => if (T == []const u8) zsRtField(o, a, flags, width) else {
            var be: [8]u8 = undefined;
            zstd.mem.writeInt(u64, &be, @bitCast(int), .big);
            zsRtField(o, zstd.mem.trimStart(u8, &be, &.{0}), flags, width);
        },
        'd' => {
            // C 7.21.6.1: the sign leads the field, '0' fills between it and
            // the digits, '-' pads on the right.
            const sign: []const u8 = if (int < 0) "-" else if (flags & zc_plus != 0) "+" else if (flags & zc_space != 0) " " else "";
            // A 64-bit magnitude is 20 digits and `tmp` is at least 512.
            const digits = zstd.mem.print(tmp, "{d}", .{@abs(int)}) catch unreachable;
            const pad = width -| (sign.len + digits.len);
            if (flags & (zc_zero | zc_left) == zc_zero) {
                o.str(sign);
                for (0..pad) |_| o.put('0');
                o.str(digits);
            } else {
                if (flags & zc_left == 0) for (0..pad) |_| o.put(' ');
                o.str(sign);
                o.str(digits);
                if (flags & zc_left != 0) for (0..pad) |_| o.put(' ');
            }
        },
        // The radices %h %x %o %b, the only letters `zSFormatRt` passes
        // besides the arms above.
        else => {
            const u: u64 = @bitCast(int);
            // 64 binary digits at most, and `tmp` is at least 512.
            const digits = switch (conv | 0x20) {
                'o' => zstd.mem.print(tmp, "{o}", .{u}),
                'b' => zstd.mem.print(tmp, "{b}", .{u}),
                else => zstd.mem.print(tmp, "{x}", .{u}), // %h and %x
            } catch unreachable;
            const pad = width -| digits.len;
            if (flags & (zc_zero | zc_left) == zc_zero) {
                for (0..pad) |_| o.put('0');
                o.str(digits);
            } else zsRtField(o, digits, flags, width);
        },
    }
}
