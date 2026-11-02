//! §9.4.3 Table 9-23's real conversions: one f64, its conversion letter,
//! flags, width and precision in, the C11 7.21.6.1 text (or §2.6.2's
//! engineering `%r`) out, in the caller's buffer. Device text (`text.str`),
//! and host Zig for the digital engine's `%e/%f/%g` (`fmt.zig`, `sim`), so
//! both engines print a real one way; `tests/printf_reference.zig` holds it
//! to glibc's `snprintf`.
//! Cites: VAMS §2.6.2 (Table 2-1), §9.4.3 (Table 9-23); C11 7.21.6.1;
//! IEEE 754 roundTiesToEven; docs/specification/Vague_Decisions.md §6.
//!
//! §9.4.3 gives the real conversions "the full formatting capabilities
//! available in the C language", so C11 is the specification for the flag,
//! width and precision prefix and for the rounding. Zig's float formatter is
//! not that specification in three ways, each of which lost a character on a
//! transcript: `{d}` is shortest-round-trip (so `%g` of 1e8 printed
//! `100000000`, not `1e+08`); `{d:.P}` rounds the shortest decimal rather
//! than the value (a precision past 17 digits reported zeros C does not);
//! and that rounding takes a half away from zero (`%.0f` of 2.5 printed `3`,
//! where C's "correctly rounded" is 2). So the value is expanded exactly
//! (`zcFrom`) and rounded here.
//!
//! Contents:
//! - `pub const zc_left: u8`, `zc_plus: u8`, `zc_space: u8`, `zc_zero: u8`, `zc_alt: u8`
//! - `pub fn zcFlag(c: u8) ?u8`
//! - `pub fn zcAltOk(conv: u8) bool`
//! - `pub fn zCReal(buf: []u8, v: f64, conv: u8, flags: u8, width: usize, prec: i64) []const u8`

const zstd = @import("std");

// ---- device text ----

// The flag bits `zCReal` takes, in the order `cg_display.Spec` packs them.
/// '-' left-justifies; C makes it override '0'.
pub const zc_left: u8 = 1;
/// '+' always spells the sign.
pub const zc_plus: u8 = 2;
/// ' ' puts a space where the sign would be; '+' wins.
pub const zc_space: u8 = 4;
/// '0' pads with zeros after the sign.
pub const zc_zero: u8 = 8;
/// '#' C's alternative form: the point always prints.
pub const zc_alt: u8 = 16;

/// Significant digits a `ZCDec` holds. Every f64 is m·2^e with m < 2^53, so
/// its decimal expansion terminates: 2^-1074 needs 751 significant digits
/// and 2^1023 needs 309, so 800 holds every finite double.
const zc_digits = 800;

/// A decimal: `value = 0.d[0..n] × 10^dp`, which keeps the point out of the
/// digit array. Invariant: `n <= zc_digits`, and `d[n - 1] != 0` once trimmed.
const ZCDec = struct {
    d: [zc_digits]u8 = @splat(0),
    n: usize = 0,
    dp: i32 = 0,
    neg: bool = false,
};

/// A bounded writer over the caller's buffer: an overrun is dropped
/// (`zCReal`'s rule). Invariant: `n <= b.len`.
const ZCOut = struct {
    b: []u8,
    n: usize = 0,

    fn put(self: *ZCOut, c: u8) void {
        if (self.n < self.b.len) {
            self.b[self.n] = c;
            self.n += 1;
        }
        zstd.debug.assert(self.n <= self.b.len);
    }

    fn str(self: *ZCOut, s: []const u8) void {
        for (s) |c| self.put(c);
    }
};

/// Returns C11 7.21.6.1p6's flag character `c` as its `zc_*` bit, or null
/// for any other byte. The one spelling of the flag set: lowering's pairing
/// count (`systask`), the compile-time translation (`cg_display`) and
/// `zSFormatRt` all read it, so none takes a flag for a conversion letter.
pub fn zcFlag(c: u8) ?u8 {
    return switch (c) {
        '-' => zc_left,
        '+' => zc_plus,
        ' ' => zc_space,
        '0' => zc_zero,
        '#' => zc_alt,
        else => null,
    };
}

/// Returns whether '#' is defined on conversion `conv`: C's alternative form
/// belongs to C's conversions, and §9.4.3 grants C's capabilities to Table
/// 9-23's real conversions only, so %e/%f/%g, either case. Table 9-22's
/// rows, `%m`/`%l` and §2.6.2's `%r` have none (E0825; Vague_Decisions §6).
pub fn zcAltOk(conv: u8) bool {
    return switch (conv | 0x20) {
        'e', 'f', 'g' => true,
        else => false,
    };
}

/// Returns one §9.4.3 Table 9-23 real conversion of `v`, whole field, in a
/// prefix of `buf`. `conv` is the source's letter (its case picks `e`/`E`
/// and INF/NAN), `flags` the `zc_*` set, `prec` -1 when the source gave no
/// precision. The width is applied here rather than by an outer `{s:>W}`
/// because C's '0' puts the pad between the sign and the digits. An
/// overrun of `buf` is dropped, not wrapped: the emitter sizes the row from
/// the same width and precision, so a short row is a codegen bug, not input.
/// An explicit `%g` precision counts fractional digits (§9.4.3's own
/// "%10.3g ... three (3) fractional digits"), where C counts significant
/// ones; without a precision the two readings agree and C's rule applies.
pub fn zCReal(buf: []u8, v: f64, conv: u8, flags: u8, width: usize, prec: i64) []const u8 {
    const upper = conv >= 'A' and conv <= 'Z';
    const c = conv | 0x20;
    var o: ZCOut = .{ .b = buf };
    const neg = zstd.math.signbit(v);
    const sgn: u8 = if (neg) '-' else if (flags & zc_plus != 0) '+' else if (flags & zc_space != 0) ' ' else 0;
    // An infinity or a NaN takes the sign flags and the width, never the
    // zero fill ("the 0 flag is ignored" once the result is not a number);
    // a NaN is "[-]nan" (7.21.6.1p8): its sign bit prints.
    var special = false;
    if (zstd.math.isNan(v) or zstd.math.isInf(v)) {
        special = true;
        if (sgn != 0) o.put(sgn);
        if (zstd.math.isNan(v)) o.str(if (upper) "NAN" else "nan") else o.str(if (upper) "INF" else "inf");
    } else if (c == 'r') {
        if (sgn != 0) o.put(sgn);
        zcEngineering(&o, v, prec);
    } else {
        if (sgn != 0) o.put(sgn);
        var z: ZCDec = undefined;
        zcFrom(&z, v);
        const body = o.n;
        // C11 7.21.6.1p6 '#': "always contains a decimal-point character",
        // and "for g and G conversions, trailing zeros are not removed".
        const alt = flags & zc_alt != 0;
        if (c == 'e') {
            zcSci(&o, &z, if (prec < 0) 6 else @intCast(prec), upper, null, alt);
        } else if (c == 'f' or prec >= 0) {
            zcFixed(&o, &z, if (prec < 0) 6 else @intCast(prec), alt);
        } else {
            const pg: i32 = 6; // C's default precision for %g
            zcRound(&z, pg);
            const x: i32 = if (z.n == 0) 0 else z.dp - 1;
            if (x < -4 or x >= pg) {
                zcSci(&o, &z, @intCast(pg - 1), upper, if (alt) null else body, alt);
            } else {
                // C: style f with precision P - 1 - X, then strip.
                zcFixed(&o, &z, @intCast(@max(pg - 1 - x, 0)), alt);
                if (!alt) zcStrip(&o, body);
            }
        }
    }
    zstd.debug.assert(o.n <= buf.len);
    if (o.n >= width) return o.b[0..o.n];
    // A field wider than the row cannot be padded on either side: the text
    // is returned as it fits (checked before the '-' arm, whose pad loop
    // could otherwise never reach `width`).
    if (width > o.b.len) return o.b[0..o.n];
    const pad = width - o.n;
    if (flags & zc_left != 0) { // '-' wins over '0' and pads on the right
        while (o.n < width) o.put(' ');
        return o.b[0..width];
    }
    const keep: usize = if (flags & zc_zero != 0 and !special and sgn != 0) 1 else 0;
    @memmove(o.b[keep + pad .. width], o.b[keep..o.n]);
    @memset(o.b[keep .. keep + pad], if (flags & zc_zero != 0 and !special) '0' else ' ');
    return o.b[0..width];
}

// ---- private ----

/// §2.6.2 `%r`: engineering notation, "using the scale factors defined in
/// 2.6.2", over the shortest round-trip digits (the rendering of 0.0015 is
/// `1.5m`, not the 55 digits 0.0015 exactly is). The exponent is a multiple
/// of three and the mantissa lies in [1, 1000), which picks exactly one
/// Table 2-1 symbol, so 2e-13 is `200f` and never `0.2p`. Outside the table
/// the mantissa absorbs the exponent.
fn zcEngineering(o: *ZCOut, v: f64, prec: i64) void {
    var z: ZCDec = undefined;
    zcShortest(&z, v);
    const x: i32 = if (z.n == 0) 0 else z.dp - 1;
    var g: i32 = @divFloor(x, 3) * 3;
    g = @min(12, @max(-18, g));
    z.dp -= g;
    // Every shortest digit past the point, which counts the zeros between
    // the point and a run that starts below it (dp < 0 once the clamp at -18
    // has absorbed the exponent).
    const p: usize = if (prec >= 0)
        @intCast(prec)
    else if (z.n > 0 and z.dp < @as(i32, @intCast(z.n)))
        @intCast(@as(i32, @intCast(z.n)) - z.dp)
    else
        0;
    // A precision can round the mantissa up to 1000 (999.96 to one place):
    // the value then takes the next symbol up, as 1.0K, while there is one.
    if (prec >= 0 and g < 12) {
        var rounded = z;
        zcRound(&rounded, rounded.dp + @as(i32, @intCast(p)));
        if (rounded.dp > 3) {
            g += 3;
            z.dp -= 3;
        }
    }
    zstd.debug.assert(@mod(g, 3) == 0);
    const body = o.n;
    zcFixed(o, &z, p, false);
    if (prec < 0) zcStrip(o, body);
    const sym = zcScaleSym(g);
    if (sym != 0) o.put(sym);
}

/// The digit at significant position `i`, or 0 outside the held run, so a
/// renderer may ask for a fractional digit past an exact expansion's end.
fn zcAt(z: *const ZCDec, i: i32) u8 {
    if (i < 0) return 0;
    const k: usize = @intCast(i);
    return if (k < z.n) z.d[k] else 0;
}

fn zcTrim(z: *ZCDec) void {
    zstd.debug.assert(z.n <= zc_digits);
    while (z.n > 0 and z.d[z.n - 1] == 0) z.n -= 1;
    if (z.n == 0) z.dp = 0;
}

/// `z` times 2^k, k <= 59: `d·2^k + carry` stays below 10·2^59 < 2^63, and
/// the carry left over is at most 18 new leading digits.
fn zcMulP2(z: *ZCDec, k: u6) void {
    zstd.debug.assert(k <= 59);
    var carry: u64 = 0;
    var i = z.n;
    while (i > 0) {
        i -= 1;
        const t = (@as(u64, z.d[i]) << k) + carry;
        z.d[i] = @intCast(t % 10);
        carry = t / 10;
    }
    var tmp: [20]u8 = undefined;
    var m: usize = 0;
    while (carry != 0) : (carry /= 10) {
        tmp[m] = @intCast(carry % 10);
        m += 1;
    }
    zstd.debug.assert(m <= 18);
    if (m != 0) { // `m` new most-significant digits: the run shifts right
        const keep = @min(z.n, zc_digits - m);
        zstd.mem.copyBackwards(u8, z.d[m..][0..keep], z.d[0..keep]);
        for (0..m) |j| z.d[j] = tmp[m - 1 - j];
        z.n = keep + m;
        z.dp += @intCast(m);
    }
    zcTrim(z);
}

/// `z` over 2^k, k <= 59: `rem·10 + d` stays below 10·2^59. Exact: the
/// remainder spills at most k digits past the run.
fn zcDivP2(z: *ZCDec, k: u6) void {
    zstd.debug.assert(k <= 59);
    const zlow = (@as(u64, 1) << k) - 1;
    var rem: u64 = 0;
    var w: usize = 0;
    var i: usize = 0;
    // Quotient digit `i` lands at or before position `i`, so `w <= i`.
    while ((i < z.n or rem != 0) and w < zc_digits) : (i += 1) {
        const cur = rem * 10 + (if (i < z.n) z.d[i] else 0);
        rem = cur & zlow;
        // `zq`, not `q`: this text sits at a device's file scope, where `q`
        // is the generated charge function and a shadowing local is an error.
        const zq: u8 = @intCast(cur >> k);
        // A leading zero quotient digit is not stored; it moves the point.
        if (w == 0 and zq == 0) z.dp -= 1 else {
            z.d[w] = zq;
            w += 1;
        }
    }
    z.n = w;
    zcTrim(z);
}

/// `z` = the exact decimal expansion of finite `v`. §2.6.2 makes a real an
/// IEEE 754 double, so the operand is the bit pattern and nothing here
/// depends on decimal parsing.
fn zcFrom(z: *ZCDec, v: f64) void {
    zstd.debug.assert(zstd.math.isFinite(v));
    z.* = .{};
    z.neg = zstd.math.signbit(v);
    const bits: u64 = @bitCast(v);
    const be: u11 = @truncate(bits >> 52);
    var m: u64 = bits & 0xf_ffff_ffff_ffff;
    var e2: i32 = undefined;
    if (be == 0) {
        e2 = -1074; // subnormal: no implicit leading bit
    } else {
        m |= @as(u64, 1) << 52;
        e2 = @as(i32, be) - 1075;
    }
    if (m == 0) return; // ±0 is the empty digit run
    var tmp: [20]u8 = undefined;
    var k: usize = 0;
    while (m != 0) : (m /= 10) {
        tmp[k] = @intCast(m % 10);
        k += 1;
    }
    var i: usize = 0;
    while (i < k) : (i += 1) z.d[i] = tmp[k - 1 - i];
    z.n = k;
    z.dp = @intCast(k);
    zcTrim(z);
    // 59 bits per pass: `zcMulP2`/`zcDivP2`'s bound.
    while (e2 > 0) {
        const zsh: u6 = @intCast(@min(e2, 59));
        zcMulP2(z, zsh);
        e2 -= zsh;
    }
    while (e2 < 0) {
        const zsh: u6 = @intCast(@min(-e2, 59));
        zcDivP2(z, zsh);
        e2 += zsh;
    }
}

/// `z` = the shortest round-trip decimal of `v` (std's scientific mode,
/// which is Ryu's shortest).
fn zcShortest(z: *ZCDec, v: f64) void {
    z.* = .{};
    z.neg = zstd.math.signbit(v);
    var tb: [64]u8 = undefined;
    // `[-]d[.ddd]e[-]X`.
    const t = zstd.fmt.float.render(&tb, v, .{ .mode = .scientific }) catch return;
    var i: usize = 0;
    if (i < t.len and (t[i] == '-' or t[i] == '+')) i += 1;
    var lead: i32 = 0; // digits before the point: always exactly one here
    while (i < t.len and t[i] != 'e') : (i += 1) {
        if (t[i] == '.') continue;
        if (z.n < zc_digits) {
            z.d[z.n] = t[i] - '0';
            z.n += 1;
        }
        if (lead == 0) lead = 1;
    }
    const e10 = if (i < t.len) zstd.fmt.parseInt(i32, t[i + 1 ..], 10) catch 0 else 0;
    z.dp = e10 + lead;
    zcTrim(z);
}

/// Keeps `keep` significant digits, C11 7.21.6.1p13 "correctly rounded" in
/// IEEE 754's default direction: a tie goes to the even last digit, so
/// %.0f of 2.5 is 2 and of 3.5 is 4.
fn zcRound(z: *ZCDec, keep: i32) void {
    if (keep < 0) {
        z.* = .{ .neg = z.neg };
        return;
    }
    const k: usize = @intCast(keep);
    if (k >= z.n) return;
    const first = z.d[k];
    var up = first > 5;
    if (first == 5) {
        var rest = false;
        var i = k + 1;
        while (i < z.n) : (i += 1) if (z.d[i] != 0) {
            rest = true;
            break;
        };
        // An exact tie goes to the even candidate; the digit before
        // position 0 is an implicit 0, which is even.
        up = rest or (k > 0 and z.d[k - 1] % 2 == 1);
    }
    z.n = k;
    defer zstd.debug.assert(z.n <= k or z.n == 1);
    if (up) {
        var i = k;
        while (i > 0) {
            i -= 1;
            if (z.d[i] != 9) {
                z.d[i] += 1;
                return zcTrim(z);
            }
            z.d[i] = 0;
        }
        z.d[0] = 1; // 999… carried out, or `keep` was 0 and the value rounds up
        z.n = 1;
        z.dp += 1;
        return;
    }
    zcTrim(z);
}

/// C's %f body: the integer part, then exactly `p` fractional digits; `alt`
/// ('#') prints the point even when no digit follows it.
fn zcFixed(o: *ZCOut, z: *ZCDec, p: usize, alt: bool) void {
    zcRound(z, z.dp + @as(i32, @intCast(p)));
    if (z.dp <= 0) {
        o.put('0');
    } else {
        var i: i32 = 0;
        while (i < z.dp) : (i += 1) o.put('0' + zcAt(z, i));
    }
    if (p == 0) {
        if (alt) o.put('.');
        return;
    }
    o.put('.');
    var t: usize = 1;
    while (t <= p) : (t += 1) o.put('0' + zcAt(z, z.dp + @as(i32, @intCast(t)) - 1));
}

/// C's %e body: one digit, `p` fractional digits, then a signed exponent of
/// at least two digits (`1.500000e+00`, which Zig's `{e}` spells `1.5e0`).
/// `strip_from` is %g's trailing-zero removal, applied to the mantissa
/// before the exponent is appended (stripping the finished text would eat
/// the `00` of `e+00`); `alt` ('#') prints the point even when `p` is 0.
fn zcSci(o: *ZCOut, z: *ZCDec, p: usize, upper: bool, strip_from: ?usize, alt: bool) void {
    zcRound(z, @intCast(p + 1));
    const x: i32 = if (z.n == 0) 0 else z.dp - 1;
    o.put('0' + zcAt(z, 0));
    if (p == 0 and alt) o.put('.');
    if (p > 0) {
        o.put('.');
        var t: usize = 1;
        while (t <= p) : (t += 1) o.put('0' + zcAt(z, @intCast(t)));
    }
    if (strip_from) |from| zcStrip(o, from);
    o.put(if (upper) 'E' else 'e');
    o.put(if (x < 0) '-' else '+');
    const mag: u32 = @intCast(if (x < 0) -x else x);
    var eb: [8]u8 = undefined;
    const es = zstd.mem.print(&eb, "{d}", .{mag}) catch "0";
    if (es.len < 2) o.put('0');
    o.str(es);
}

/// C's %g trailing-zero removal: "trailing zeros are removed from the
/// fractional portion of the result and the decimal-point character is
/// removed if there is no fractional portion remaining". `from` is where the
/// body it applies to started, so an exponent appended later is untouched.
fn zcStrip(o: *ZCOut, from: usize) void {
    zstd.debug.assert(from <= o.n);
    var dot = false;
    for (o.b[from..o.n]) |c| if (c == '.') {
        dot = true;
        break;
    };
    if (!dot) return;
    while (o.n > from and o.b[o.n - 1] == '0') o.n -= 1;
    if (o.n > from and o.b[o.n - 1] == '.') o.n -= 1;
}

/// §2.6.2 Table 2-1's scale symbol for a power of ten, or 0 for 1e0, which
/// the table has no row for, so an unscaled mantissa gets no suffix.
/// ponytail: 1e3 is spelled "K, k" and no clause says which an output uses;
/// the first spelling in the table is the one emitted.
fn zcScaleSym(g: i32) u8 {
    return switch (g) {
        12 => 'T',
        9 => 'G',
        6 => 'M',
        3 => 'K',
        -3 => 'm',
        -6 => 'u',
        -9 => 'n',
        -12 => 'p',
        -15 => 'f',
        -18 => 'a',
        else => 0,
    };
}
