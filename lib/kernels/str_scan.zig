//! §9.5.4.2 `$sscanf`/`$fscanf`: an input string and a control string in,
//! the assignment count, one requested item's value and the bytes consumed
//! out. Device text (`text.str`). Pure: no state, no allocation.
//! Cites: VAMS §2.6.1, §2.6.2 (Table 2-1), §2.7, §4.2.1.1, §9.5.4.2;
//! C11 7.21.6.2.
//!
//! A unit body is an SSA expression tree, so a call that assigns two
//! variables and returns a count has no out-parameter to write through:
//! lowering turns one source call into one `zScanN` (the count) plus one
//! `zScan{I,R,S}` per output argument, each naming its item by index, and
//! every one re-runs the same pure scan over the same two strings. A
//! conversion of a handful of characters is cheaper than the machinery an
//! out-parameter would need, and nothing observes the difference.
//!
//! Scope: §9.5.4.2's own list, %d %o %h %x %b %c %f %e %g %s %r %m, with the
//! suppression `*` and the maximum field width. Not here: `%v`/`%z`/`%t`
//! (strength, 4-state and timeformat values, none of which an analog device
//! has) and C's `%n`/`%p`; lowering refuses those at the call (E0813).
//!
//! Contents:
//! - `pub const ZScan = struct { n: i64, i: i64, r: f64, s: []const u8, used: usize }`
//! - `pub fn zScan(src: []const u8, fmt: []const u8, want: i64) ZScan`
//! - `pub fn zScanNul(src: []const u8, fmt: []const u8, want: i64) ZScan`
//! - `pub fn zScanN(src: []const u8, fmt: []const u8) i64`
//! - `pub fn zScanI(src: []const u8, fmt: []const u8, k: i64) i64`
//! - `pub fn zScanR(src: []const u8, fmt: []const u8, k: i64) f64`
//! - `pub fn zScanS(src: []const u8, fmt: []const u8, k: i64) []const u8`
//! - `pub fn zScanNulN`, `zScanNulI`, `zScanNulR`, `zScanNulS`: the same four under `zScanNul`

const zstd = @import("std");

// ---- device text ----

/// One scan. `n` is §9.5.4.2's return, the number of items "successfully
/// matched and assigned", -1 (EOF) when the input ends before any
/// conversion; `i`, `r` and `s` carry the one requested item's value in all
/// three types, because the destination's type is the caller's business (a
/// `%d` may land in a `real`, §4.2.1.1). `used` is the bytes of `src`
/// consumed, fixed per directive: "if conversion terminates on a conflicting
/// input character, the offending input character is left unread in the
/// input stream", and "trailing white space (including newline characters)
/// is left unread unless matched by a directive". `$fscanf` advances its
/// descriptor by exactly this, which is what makes `$ftell` (§9.5.5) answer
/// the clause's number. `s` is a slice of `src`, valid while `src` is.
pub const ZScan = struct { n: i64 = 0, i: i64 = 0, r: f64 = 0.0, s: []const u8 = "", used: usize = 0 };

/// Returns the `$fscanf` scan of `src` under `fmt`, reporting assigned item
/// `want` (-1: the count alone). "An input field is defined as a string of
/// nonspace characters; it extends to the next inappropriate character or
/// until the maximum field width, if one is specified, is exhausted", and
/// "for all descriptors except the character c, white space leading an input
/// field is ignored".
pub fn zScan(src: []const u8, fmt: []const u8, want: i64) ZScan {
    var out: ZScan = .{};
    zsScanRun(src, fmt, want, &out, false);
    return out;
}

/// Returns `zScan` under `$sscanf`'s white space: "For $sscanf, null
/// characters shall also be considered white space." `$fscanf` keeps C's set.
pub fn zScanNul(src: []const u8, fmt: []const u8, want: i64) ZScan {
    var out: ZScan = .{};
    zsScanRun(src, fmt, want, &out, true);
    return out;
}

/// Returns §9.5.4.2's count on its own.
pub fn zScanN(src: []const u8, fmt: []const u8) i64 {
    return zScan(src, fmt, -1).n;
}

/// Returns item `k` as an integer. An item the scan never reached is 0;
/// lowering guards the destination write with the count, so its prior value
/// survives.
pub fn zScanI(src: []const u8, fmt: []const u8, k: i64) i64 {
    return zScan(src, fmt, k).i;
}

/// Returns item `k` as a real; `zScanI`'s terms.
pub fn zScanR(src: []const u8, fmt: []const u8, k: i64) f64 {
    return zScan(src, fmt, k).r;
}

/// Returns item `k` as a string: a slice of `src`, valid while `src` is;
/// `zScanI`'s terms.
pub fn zScanS(src: []const u8, fmt: []const u8, k: i64) []const u8 {
    return zScan(src, fmt, k).s;
}

/// Returns `zScanN` under `$sscanf`'s white space (`zScanNul`).
pub fn zScanNulN(src: []const u8, fmt: []const u8) i64 {
    return zScanNul(src, fmt, -1).n;
}

/// Returns `zScanI` under `$sscanf`'s white space (`zScanNul`).
pub fn zScanNulI(src: []const u8, fmt: []const u8, k: i64) i64 {
    return zScanNul(src, fmt, k).i;
}

/// Returns `zScanR` under `$sscanf`'s white space (`zScanNul`).
pub fn zScanNulR(src: []const u8, fmt: []const u8, k: i64) f64 {
    return zScanNul(src, fmt, k).r;
}

/// Returns `zScanS` under `$sscanf`'s white space (`zScanNul`).
pub fn zScanNulS(src: []const u8, fmt: []const u8, k: i64) []const u8 {
    return zScanNul(src, fmt, k).s;
}

// ---- private ----

fn zsSpace(ch: u8, nul: bool) bool {
    return zstd.ascii.isWhitespace(ch) or (nul and ch == 0);
}

/// The walk, split out so `out.used` is written on every exit: one per
/// matching failure the clause names, each reporting where the offending
/// character was left. The control string is walked once.
fn zsScanRun(src: []const u8, fmt: []const u8, want: i64, out: *ZScan, nul: bool) void {
    var si: usize = 0;
    defer out.used = si;
    defer zstd.debug.assert(si <= src.len);
    var fi: usize = 0;
    var tried = false; // has any conversion started with input still available?
    var directives: usize = 0;
    while (fi < fmt.len) : (directives += 1) {
        // Each directive consumes at least one control byte.
        zstd.debug.assert(directives < fmt.len);
        const fc = fmt[fi];
        // White space in the control string matches any run of it, or none.
        if (zsSpace(fc, nul)) {
            fi += 1;
            while (si < src.len and zsSpace(src[si], nul)) si += 1;
            continue;
        }
        if (fc != '%') { // an ordinary character must be there
            if (si >= src.len) return zsScanEof(out, tried);
            if (src[si] != fc) return;
            si += 1;
            fi += 1;
            continue;
        }
        fi += 1;
        if (fi >= fmt.len) return;
        if (fmt[fi] == '%') { // a literal percent, matched not converted
            if (si >= src.len) return zsScanEof(out, tried);
            if (src[si] != '%') return;
            si += 1;
            fi += 1;
            continue;
        }
        const suppress = fmt[fi] == '*';
        if (suppress) fi += 1;
        // Saturating: a width past the input is the whole input, and digits
        // no usize holds must not overflow.
        var width: usize = 0;
        while (fi < fmt.len and fmt[fi] >= '0' and fmt[fi] <= '9') : (fi += 1)
            width = width *| 10 +| (fmt[fi] - '0');
        if (fi >= fmt.len) return;
        const conv = fmt[fi];
        fi += 1;
        // "%m Returns the current hierarchical path as a string. Does not
        // read data from the input file or str argument": before the white
        // space skip and the EOF test, which are properties of reading.
        if (conv == 'm') {
            if (suppress) continue;
            // ponytail: the path answers empty. A scan control string is a
            // run-time value, so the kernel has no name to reach for (the
            // display-side `%m` is the emitter's), and §9.5.4.2 fixes no
            // spelling of "the current hierarchical path". The upgrade is
            // threading the module name into the scan call.
            if (out.n == want) out.s = "";
            out.n += 1;
            continue;
        }
        if (conv != 'c') {
            while (si < src.len and zsSpace(src[si], nul)) si += 1;
        }
        if (si >= src.len) return zsScanEof(out, tried);
        tried = true;
        const lim = if (width == 0) src.len else si + @min(width, src.len - si);
        const item = zsConvert(src, si, lim, conv, width, nul) orelse return;
        zstd.debug.assert(item.used > si);
        zstd.debug.assert(item.used <= lim);
        si = item.used;
        if (suppress) continue; // "matched and assigned": consumed, not counted
        if (out.n == want) {
            out.i = item.i;
            out.r = item.r;
            out.s = item.s;
        }
        out.n += 1;
    }
}

/// One conversion `conv` of the field `src[si..lim]`, `si < lim`: the
/// item's three views and, in `used`, where it ended; null on a matching
/// failure (nothing matched, or an invalid conversion letter).
fn zsConvert(src: []const u8, si: usize, lim: usize, conv: u8, width: usize, nul: bool) ?ZScan {
    zstd.debug.assert(si < lim);
    zstd.debug.assert(lim <= src.len);
    var item: ZScan = .{};
    var end = si;
    switch (conv) {
        // "%c Matches a single character. The normal skip over white space
        // is suppressed"; a width takes that many characters.
        'c' => {
            end = if (width == 0) si + 1 else lim;
            item.i = src[si];
            item.r = @floatFromInt(item.i);
            item.s = src[si..end];
        },
        // "%s Matches a string, which is a sequence of nonwhite space
        // characters"; the int/real views are §2.7's base-256 reading.
        's' => {
            while (end < lim and !zsSpace(src[end], nul)) end += 1;
            item.s = src[si..end];
            for (item.s) |ch| item.i = item.i *% 256 +% ch;
            item.r = @floatFromInt(item.i);
        },
        // "%f, %e, or %g Matches a floating point number": sign, digits,
        // fraction, exponent, parsed by std on the matched slice so the
        // rounding is every other real literal's. "%r Matches a 'real' number
        // in engineering notation, using the scale factors defined in 2.6.2":
        // the same number and one optional Table 2-1 symbol right after it
        // ("no space is permitted between the number and the symbol").
        'f', 'e', 'g', 'r' => {
            var digits: usize = 0;
            if (end < lim and (src[end] == '+' or src[end] == '-')) end += 1;
            while (end < lim and zsDigit(src[end], 10) != null) : (end += 1) digits += 1;
            if (end < lim and src[end] == '.') {
                end += 1;
                while (end < lim and zsDigit(src[end], 10) != null) : (end += 1) digits += 1;
            }
            if (digits == 0) return null; // a sign or a dot alone
            if (end < lim and (src[end] == 'e' or src[end] == 'E')) {
                var k = end + 1;
                if (k < lim and (src[k] == '+' or src[k] == '-')) k += 1;
                if (k < lim and zsDigit(src[k], 10) != null) {
                    while (k < lim and zsDigit(src[k], 10) != null) k += 1;
                    end = k;
                }
            }
            item.r = zstd.fmt.parseFloat(f64, src[si..end]) catch return null;
            if (conv == 'r' and end < lim) {
                if (zsScaleOf(src[end])) |f| {
                    item.r *= f;
                    end += 1;
                }
            }
            item.s = src[si..end];
            // Saturating, like every real-to-int cast the device performs:
            // this text ships in ReleaseFast artifacts, where an unguarded
            // `@intFromFloat` of "1e300" is UB.
            item.i = zstd.math.lossyCast(i64, @trunc(item.r));
        },
        // "%d Matches an optionally signed decimal number, consisting of the
        // optional sign from the set + or -, followed by a sequence of
        // characters from the set 0,1,2,3,4,5,6,7,8,9, and _": the
        // underscore is §2.6.1's separator, skipped in every radix.
        'd', 'o', 'b', 'h', 'x' => {
            const radix: u8 = switch (conv) {
                'b' => 2,
                'o' => 8,
                'h', 'x' => 16,
                else => 10,
            };
            var neg = false;
            if (end < lim and (src[end] == '+' or src[end] == '-')) {
                neg = src[end] == '-';
                end += 1;
            }
            var digits: usize = 0;
            var acc: i64 = 0;
            while (end < lim) : (end += 1) {
                if (src[end] == '_') continue;
                const d = zsDigit(src[end], radix) orelse break;
                acc = acc *% radix +% d;
                digits += 1;
            }
            if (digits == 0) return null; // e.g. "%d" on "hello"
            // Wrapping, as the accumulation is: "-9223372036854775808" wraps
            // to minInt, whose plain negation overflows.
            item.i = if (neg) -%acc else acc;
            item.r = @floatFromInt(item.i);
            item.s = src[si..end];
        },
        // Not unreachable: lowering checks a format only when it folds to a
        // constant, so a run-time format arrives unchecked. §9.5.4.2 makes an
        // invalid conversion character "implementation dependent"; this
        // stops the scan, reporting the items assigned so far.
        else => return null,
    }
    if (end == si) return null; // nothing matched
    item.used = end;
    return item;
}

/// "This number can be EOF if the input ends before the first matching
/// failure or conversion": input that ran out before any conversion was
/// tried and any item assigned (whether a conversion or a literal found it
/// gone, C11 7.21.6.2p16's input failure); input that ran out after an
/// assignment reports the assignments.
fn zsScanEof(out: *ZScan, tried: bool) void {
    zstd.debug.assert(out.n >= 0);
    if (!tried and out.n == 0) out.n = -1;
}

/// §2.6.2 Table 2-1's scale factor for one symbol, or null. The 1e3 row is
/// spelled "K, k", so a scanner takes both, which is why no fixture may pin
/// which of the two an output prints.
fn zsScaleOf(c: u8) ?f64 {
    return switch (c) {
        'T' => 1e12,
        'G' => 1e9,
        'M' => 1e6,
        'K', 'k' => 1e3,
        'm' => 1e-3,
        'u' => 1e-6,
        'n' => 1e-9,
        'p' => 1e-12,
        'f' => 1e-15,
        'a' => 1e-18,
        else => null,
    };
}

/// The value of `c` as a digit in `radix`, or null when it is not one.
fn zsDigit(c: u8, radix: u8) ?u8 {
    // ponytail: keep the existing hex-digit ceiling even for a larger radix.
    const d = zstd.fmt.charToDigit(c, @min(radix, 16)) catch return null;
    zstd.debug.assert(d < radix);
    return d;
}
