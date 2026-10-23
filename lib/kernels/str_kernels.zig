// §9.5.3 / §9.5.4.2 string formatting and scanning kernels — EMITTED VERBATIM
// into every device that calls `$sformat`/`$swrite`/`$sscanf` or holds a
// string (`kernel_text.str_txt` is `@embedFile` of this file) and `@import`ed by
// codegen.zig's tests. One source, so the conversions the tests check are the
// conversions the device runs.
//
// WHY THE SCANNER RE-PARSES. `$sscanf(str, fmt, a, b)` assigns to two variables
// and returns a count, but a unit body is an SSA expression tree: a value is
// what a call RETURNS, and there is no out-parameter to write through. So
// lowering turns one source call into one `zScanN` (the count) plus one
// `zScan{I,R,S}` per output argument, each naming the item it wants by index,
// and every one of them re-runs the same pure scan over the same two strings.
// A conversion of a handful of characters is cheaper than the machinery an
// out-parameter would need in the emitter, and nothing observes the difference:
// the scan has no state and no side effects.
//
// SCOPE. The conversion codes are §9.5.4.2's own list — %d %o %h %x %b %c %f %e
// %g %s %r %m — with the assignment-suppression `*` and the maximum field
// width. What is deliberately NOT here: `%v`/`%z`/`%t` (strength, 4-state and
// timeformat values, none of which an analog device has), and C's `%n`/`%p`.
// lower.zig refuses those at the call (E0813) rather than letting them scan as
// garbage. The OUTPUT side of §9.4.3 Table 9-23 — the C real conversions and
// the engineering `%r` — is `zCReal`, at the bottom of this file.

// `std` is spelled `zstd` HERE because this text is embedded VERBATIM into
// device.zig and h.zig, both of which already declare `const std` in their own
// header — a second `const std` at the same file scope is a redeclaration. The
// alias also lets codegen.zig's tests `@import` this file directly, which is the
// whole reason the kernels live in a real Zig file (see filter_kernels.zig).
const zstd = @import("std");

/// One scan. `n` is §9.5.4.2's return — the number of items "successfully
/// matched and assigned", -1 (EOF) when the input ends before any conversion —
/// and the other three fields carry the value of the ONE item the caller asked
/// for, in all three types, because the destination's type is the caller's
/// business and a `%d` may legally land in a `real` variable (§4.2.1.1).
/// `used` is how many BYTES of `src` the scan consumed, which §9.5.4.2 fixes
/// per directive and not per line: "if conversion terminates on a conflicting
/// input character, the offending input character is left unread in the input
/// stream", and "trailing white space (including newline characters) is left
/// unread unless matched by a directive". `$sscanf` has no position to move,
/// so nothing reads it there; `$fscanf` advances the descriptor by exactly
/// this, which is what makes §9.5.5's `$ftell` answer the clause's number and
/// what lets a failed match be retried against the same bytes.
pub const ZScan = struct { n: i64 = 0, i: i64 = 0, r: f64 = 0.0, s: []const u8 = "", used: usize = 0 };

/// §9.5.4.2 `$sscanf`/`$fscanf`. `want` is the index of the assigned item whose
/// value is reported; -1 asks for the count alone.
///
/// The control string is walked once. §9.5.4.2: "An input field is defined as a
/// string of nonspace characters; it extends to the next inappropriate character
/// or until the maximum field width, if one is specified, is exhausted", and
/// "for all descriptors except the character c, white space leading an input
/// field is ignored".
pub fn zScan(src: []const u8, fmt: []const u8, want: i64) ZScan {
    var out: ZScan = .{};
    zScanRun(src, fmt, want, &out, false);
    return out;
}

/// §9.5.4.2's `$sscanf` spelling: "For $sscanf, null characters shall also be
/// considered white space." `$fscanf` keeps C's set, so the two entry points
/// differ by this one flag.
pub fn zScanNul(src: []const u8, fmt: []const u8, want: i64) ZScan {
    var out: ZScan = .{};
    zScanRun(src, fmt, want, &out, true);
    return out;
}

fn zSpace(ch: u8, nul: bool) bool {
    return zstd.ascii.isWhitespace(ch) or (nul and ch == 0);
}

/// The walk itself, split out only so `out.used` is written on EVERY exit —
/// there are seven, one per matching failure the clause names, and each has to
/// report the position the offending character was left at.
fn zScanRun(src: []const u8, fmt: []const u8, want: i64, out: *ZScan, nul: bool) void {
    var si: usize = 0;
    defer out.used = si;
    var fi: usize = 0;
    var tried = false; // has any conversion started with input still available?
    while (fi < fmt.len) {
        const fc = fmt[fi];
        // Whitespace in the control string matches any run of whitespace,
        // including none.
        if (zSpace(fc, nul)) {
            fi += 1;
            while (si < src.len and zSpace(src[si], nul)) si += 1;
            continue;
        }
        if (fc != '%') { // ordinary character: it must be there
            if (si >= src.len) return zScanEof(out, tried);
            if (src[si] != fc) return;
            si += 1;
            fi += 1;
            continue;
        }
        fi += 1;
        if (fi >= fmt.len) return;
        if (fmt[fi] == '%') { // a literal percent, matched not converted
            if (si >= src.len) return zScanEof(out, tried);
            if (src[si] != '%') return;
            si += 1;
            fi += 1;
            continue;
        }
        const suppress = fmt[fi] == '*';
        if (suppress) fi += 1;
        // Saturating: a width past the input is the whole input, and a run of
        // digits no usize holds must not overflow.
        var width: usize = 0;
        while (fi < fmt.len and fmt[fi] >= '0' and fmt[fi] <= '9') : (fi += 1)
            width = width *| 10 +| (fmt[fi] - '0');
        if (fi >= fmt.len) return;
        const conv = fmt[fi];
        fi += 1;
        // §9.5.4.2 "%m Returns the current hierarchical path as a string. Does
        // not read data from the input file or str argument." Handled BEFORE
        // the white-space skip and before the EOF test, because both of those
        // are properties of reading input and this directive does not: a `%m`
        // with nothing left to scan is still an assignment, and the `%d` after
        // it still sees the whole field.
        if (conv == 'm') {
            if (suppress) continue;
            // ponytail: the path answers empty. §9.4.3's display-side `%m` is
            // substituted by the EMITTER (`cg_display` writes `g.mir.name`
            // into the format), and a scan control string is a RUNTIME value,
            // so the kernel has no name to reach for. Nothing in §9.5.4.2
            // fixes the spelling of "the current hierarchical path" either.
            // The upgrade is threading the module name into the scan call the
            // way the display path already has it.
            if (out.n == want) out.s = "";
            out.n += 1;
            continue;
        }
        if (conv != 'c') {
            while (si < src.len and zSpace(src[si], nul)) si += 1;
        }
        if (si >= src.len) return zScanEof(out, tried);
        tried = true;
        // `si < src.len` here, so neither sum can pass `src.len`.
        const lim = if (width == 0) src.len else si + @min(width, src.len - si);
        var item: ZScan = .{};
        var end = si;
        switch (conv) {
            // §9.5.4.2 "%c Matches a single character. The normal skip over
            // white space is suppressed" — a width takes that many characters.
            'c' => {
                end = if (width == 0) si + 1 else lim;
                item.i = src[si];
                item.r = @floatFromInt(item.i);
                item.s = src[si..end];
            },
            // "%s Matches a string, which is a sequence of nonwhite space
            // characters." The int/real views are the §2.7 base-256 reading a
            // string operand has everywhere else, which nothing needs but which
            // costs one loop.
            's' => {
                while (end < lim and !zSpace(src[end], nul)) end += 1;
                item.s = src[si..end];
                for (item.s) |ch| item.i = item.i *% 256 +% ch;
                item.r = @floatFromInt(item.i);
            },
            // "%f, %e, or %g Matches a floating point number" — the C shape:
            // sign, digits, fraction, exponent. Parsed with the standard
            // library on the matched slice so the rounding is the one every
            // other real literal in the device gets.
            // "%r Matches a 'real' number in engineering notation, using the
            // scale factors defined in 2.6.2" is the same number followed by
            // one Table 2-1 symbol, so it rides the same arm.
            'f', 'e', 'g', 'r' => {
                var digits: usize = 0;
                if (end < lim and (src[end] == '+' or src[end] == '-')) end += 1;
                while (end < lim and zDigit(src[end], 10) != null) : (end += 1) digits += 1;
                if (end < lim and src[end] == '.') {
                    end += 1;
                    while (end < lim and zDigit(src[end], 10) != null) : (end += 1) digits += 1;
                }
                if (digits == 0) return; // a sign or a dot alone is a matching failure
                if (end < lim and (src[end] == 'e' or src[end] == 'E')) {
                    var k = end + 1;
                    if (k < lim and (src[k] == '+' or src[k] == '-')) k += 1;
                    if (k < lim and zDigit(src[k], 10) != null) {
                        while (k < lim and zDigit(src[k], 10) != null) k += 1;
                        end = k;
                    }
                }
                item.r = zstd.fmt.parseFloat(f64, src[si..end]) catch return;
                // §2.6.2: "No space is permitted between the number and the
                // symbol", so the scale factor is the very next character —
                // and it is OPTIONAL, because a real with an implied factor of
                // 1 is still a real in engineering notation.
                if (conv == 'r' and end < lim) {
                    if (zScaleOf(src[end])) |f| {
                        item.r *= f;
                        end += 1;
                    }
                }
                item.s = src[si..end];
                // Saturating (`lossyCast`), like every other real→int cast the
                // device performs: this text ships in ReleaseFast artifacts,
                // where an unguarded `@intFromFloat` of "1e300" is UB. The
                // hand-rolled range check this replaces answered 0 out of
                // range, which was one more arbitrary rule than needed.
                item.i = zstd.math.lossyCast(i64, @trunc(item.r));
            },
            // The four radix codes. "%d Matches an optionally signed decimal
            // number, consisting of the optional sign from the set + or -,
            // followed by a sequence of characters from the set
            // 0,1,2,3,4,5,6,7,8,9, and _" — the underscore is a §2.6.1 digit
            // separator and is skipped, not converted, in every radix.
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
                    const d = zDigit(src[end], radix) orelse break;
                    acc = acc *% radix +% d;
                    digits += 1;
                }
                if (digits == 0) return; // matching failure, e.g. "%d" on "hello"
                // Wrapping, as the accumulation is: "-9223372036854775808"
                // wraps to minInt, whose plain negation overflows.
                item.i = if (neg) -%acc else acc;
                item.r = @floatFromInt(item.i);
                item.s = src[si..end];
            },
            // NOT unreachable: `lower.checkScanFormat` only runs when the
            // format argument CONST-FOLDS to a string, so a format held in a
            // string variable or built at run time arrives here unchecked.
            // §9.5.4.2 makes an invalid conversion character "implementation
            // dependent"; the choice here is to stop the scan, which reports
            // the items assigned so far rather than counting one that was
            // never converted.
            else => return,
        }
        if (end == si) return; // nothing matched
        si = end;
        if (suppress) continue; // "matched and assigned": consumed, not counted
        // ponytail: count is the next assigned index; EOF is set only on return.
        if (out.n == want) {
            out.i = item.i;
            out.r = item.r;
            out.s = item.s;
        }
        out.n += 1;
    }
    return;
}

// "This number can be EOF if the input ends before the first matching failure
// or conversion": input that ran out before any conversion was tried and any
// item assigned is that case, whether a conversion or a literal (C11
// 7.21.6.2p16's input failure) found it gone; input that ran out after an
// assignment just reports the assignments.
fn zScanEof(out: *ZScan, tried: bool) void {
    if (!tried and out.n == 0) out.n = -1;
}

/// §9.5.4.2's return value on its own.
pub fn zScanN(src: []const u8, fmt: []const u8) i64 {
    return zScan(src, fmt, -1).n;
}

/// Item `k`, in the destination variable's declared type (§3.2). An item the
/// scan never reached returns a zero payload. Lowering guards the actual
/// destination write with the assignment count, so its prior value survives.
pub fn zScanI(src: []const u8, fmt: []const u8, k: i64) i64 {
    return zScan(src, fmt, k).i;
}

/// Item `k` as a real; see `zScanI`.
pub fn zScanR(src: []const u8, fmt: []const u8, k: i64) f64 {
    return zScan(src, fmt, k).r;
}

/// Item `k` as a string: a slice of `src`, valid while `src` is; see `zScanI`.
pub fn zScanS(src: []const u8, fmt: []const u8, k: i64) []const u8 {
    return zScan(src, fmt, k).s;
}

// `$sscanf`'s four entry points, over `zScanNul` (above).
pub fn zScanNulN(src: []const u8, fmt: []const u8) i64 {
    return zScanNul(src, fmt, -1).n;
}
pub fn zScanNulI(src: []const u8, fmt: []const u8, k: i64) i64 {
    return zScanNul(src, fmt, k).i;
}
pub fn zScanNulR(src: []const u8, fmt: []const u8, k: i64) f64 {
    return zScanNul(src, fmt, k).r;
}
pub fn zScanNulS(src: []const u8, fmt: []const u8, k: i64) []const u8 {
    return zScanNul(src, fmt, k).s;
}

// ---- §9.4.3 Table 9-23: the real conversions -------------------------------
//
// §9.4.3 gives the Table 9-23 conversions "the full formatting capabilities
// available in the C language", so C11 7.21.6.1 is the specification for %e,
// %f and %g — the flag/width/precision prefix AND the rounding. Zig's float
// formatter is not that specification, in three separate ways, each of which
// lost a character on the transcript:
//
//   - `{d}` is shortest-round-trip, so `%g` of 1e8 printed `100000000` where
//     both C and Table 9-23's own "whichever format results in the shorter
//     printed output" want `1e+08`;
//   - `{d:.P}`/`{e:.P}` round the SHORTEST decimal rather than the value, so a
//     precision above 17 digits reports zeros C does not;
//   - and that rounding takes a half AWAY from zero, so `%.0f` of 2.5 printed
//     `3` where C11 7.21.6.1p13's "correctly rounded" — in IEEE 754's default
//     roundTiesToEven direction — is 2.
//
// Table 9-23's `%r`/`%R` is the one row C does not have: "display 'real' in
// engineering notation, using the scale factors defined in 2.6.2". §2.6.2
// Table 2-1 is the whole alphabet (T G M K,k m u n p f a) and "engineering
// notation" fixes the split — the exponent is a multiple of three and the
// mantissa lies in [1, 1000), so 2e-13 is `200f` and never `0.2p`.

/// The flag bits `zCReal` takes, in the order `cg_display.Spec` packs them.
pub const zc_left: u8 = 1; // '-' left-justify; C makes it override '0'
pub const zc_plus: u8 = 2; // '+' always spell the sign
pub const zc_space: u8 = 4; // ' ' a space where the sign would be; '+' wins
pub const zc_zero: u8 = 8; // '0' pad with zeros AFTER the sign
pub const zc_alt: u8 = 16; // '#' C's alternative form: the point always prints

/// §9.4.3 `%[flags][width][.precision]conv`: C11 7.21.6.1p6's five flag
/// characters, each as its `zc_*` bit, or null for any other byte. The one
/// spelling of the flag set: lowering's pairing count (`systask`), the
/// compile-time translation (`cg_display`) and `zSFormatRt` all read it, so
/// none of them can take a flag for a conversion letter.
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

/// Whether '#' is defined on conversion `conv`. C11 7.21.6.1p6 gives the
/// alternative form to C's own conversions, and §9.4.3 grants "the full
/// formatting capabilities available in the C language" to Table 9-23's real
/// conversions only, so it is %e/%f/%g, either case. Table 9-22's rows,
/// `%m`/`%l` and §2.6.2's `%r` have no '#' form (E0825;
/// `docs/specification/Vague_Decisions.md` §6).
pub fn zcAltOk(conv: u8) bool {
    return switch (conv | 0x20) {
        'e', 'f', 'g' => true,
        else => false,
    };
}

/// The exact decimal expansion of one finite f64.
///
/// Correct rounding is a property of the EXACT value, and every f64 is m·2^e
/// with m < 2^53, so the expansion TERMINATES: 2^-1074 needs 751 significant
/// digits and 2^1023 needs 309, so 800 holds every finite double with room.
/// `value = 0.d[0..n] × 10^dp`, which keeps the point out of the digit array.
//
// ponytail: one digit-array pass per 59 bits of binary exponent, so the worst
// case (a denormal, |e| = 1074) is 19 passes over ~770 digits, ~30k cycles.
// The upgrade, if a model formats extreme reals in a loop, is u64 limbs of
// 10^19 instead of one decimal digit per byte.
const zc_digits = 800;
const ZCDec = struct {
    d: [zc_digits]u8 = @splat(0),
    n: usize = 0,
    dp: i32 = 0,
    neg: bool = false,
};

/// The digit at significant position `i`, or 0 outside the held run — which is
/// what lets the renderers ask for a fractional digit past the end of an exact
/// expansion without a bounds test at every call.
fn zcAt(z: *const ZCDec, i: i32) u8 {
    if (i < 0) return 0;
    const k: usize = @intCast(i);
    return if (k < z.n) z.d[k] else 0;
}

fn zcTrim(z: *ZCDec) void {
    while (z.n > 0 and z.d[z.n - 1] == 0) z.n -= 1;
    if (z.n == 0) z.dp = 0;
}

/// `z` times 2^k, k <= 59: `d·2^k + carry` stays below 10·2^59 < 2^63, and
/// the carry left over is at most 18 new leading digits.
fn zcMulP2(z: *ZCDec, k: u6) void {
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
    const zlow = (@as(u64, 1) << k) - 1;
    var rem: u64 = 0;
    var w: usize = 0;
    var i: usize = 0;
    // Quotient digit `i` lands at or before position `i`, so `w <= i`.
    while ((i < z.n or rem != 0) and w < zc_digits) : (i += 1) {
        const cur = rem * 10 + (if (i < z.n) z.d[i] else 0);
        rem = cur & zlow;
        // `zq` and not `q`: this text is embedded at the FILE SCOPE of a
        // device, where `q` is the generated charge function — Zig forbids a
        // local that shadows a declaration, so every name here has to miss the
        // emitter's own (see `naming.zig`).
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

/// §2.6.2 makes a real an IEEE 754 double, so the operand IS the bit pattern
/// and nothing here depends on decimal parsing.
fn zcFrom(z: *ZCDec, v: f64) void {
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

/// The SHORTEST round-trip decimal of one f64, in the same shape. `%r` wants
/// this and not the exact expansion: the engineering rendering of 0.0015 is
/// `1.5m`, not the 55 digits 0.0015 exactly is.
fn zcShortest(z: *ZCDec, v: f64) void {
    z.* = .{};
    z.neg = zstd.math.signbit(v);
    var tb: [64]u8 = undefined;
    // `[-]d[.ddd]e[-]X` — std's scientific mode, which is Ryu's shortest.
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

/// Keep `keep` significant digits, C11 7.21.6.1p13 "correctly rounded" in
/// IEEE 754's default direction: ties go to the EVEN last digit, which is what
/// makes %.0f of 2.5 answer 2 and of 3.5 answer 4.
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
        // An exact tie (nothing but the 5 below) goes to the even candidate;
        // the digit before position 0 is an implicit 0, which is even.
        up = rest or (k > 0 and z.d[k - 1] % 2 == 1);
    }
    z.n = k;
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

/// A bounded writer over the caller's scratch row. An overrun is dropped
/// rather than wrapped: the emitter sizes the row from the same width and
/// precision this reads, so a short row is a codegen bug, not input.
const ZCOut = struct {
    b: []u8,
    n: usize = 0,
    fn put(self: *ZCOut, c: u8) void {
        if (self.n < self.b.len) {
            self.b[self.n] = c;
            self.n += 1;
        }
    }
    fn str(self: *ZCOut, s: []const u8) void {
        for (s) |c| self.put(c);
    }
};

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

/// C's %e body: one digit, `p` fractional digits, then a signed exponent of at
/// least two digits — `1.500000e+00`, which Zig's `{e}` spells `1.5e0`.
///
/// `strip_from` is %g's trailing-zero removal, applied to the MANTISSA before
/// the exponent is appended — stripping the finished text instead would eat
/// the `00` of `e+00`. `alt` ('#') prints the point even when `p` is 0.
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
/// fractional portion of the result and the decimal-point character is removed
/// if there is no fractional portion remaining". `from` is where the body the
/// rule applies to started, so an exponent appended afterwards is untouched.
fn zcStrip(o: *ZCOut, from: usize) void {
    var dot = false;
    for (o.b[from..o.n]) |c| if (c == '.') {
        dot = true;
        break;
    };
    if (!dot) return;
    while (o.n > from and o.b[o.n - 1] == '0') o.n -= 1;
    if (o.n > from and o.b[o.n - 1] == '.') o.n -= 1;
}

/// §2.6.2 Table 2-1's scale symbol for a power of ten, or 0 for 1e0 — which
/// the table has no row for, so an unscaled mantissa gets no suffix.
/// ponytail: 1e3 is spelled "K, k" and no clause says which an OUTPUT uses;
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

/// §9.4.3 Table 9-23 one real conversion, whole field, C11 7.21.6.1 semantics.
///
/// `conv` is the source's own letter (its case decides `e`/`E` and INF/NAN),
/// `flags` is the `zc_*` bitset, and `prec` is -1 when the source gave no
/// precision field. The WIDTH is applied here rather than by an outer `{s:>W}`
/// because C's '0' flag puts the pad between the sign and the digits — a field
/// of zeros with the sign buried inside is not a number.
pub fn zCReal(buf: []u8, v: f64, conv: u8, flags: u8, width: usize, prec: i64) []const u8 {
    const upper = conv >= 'A' and conv <= 'Z';
    const c = conv | 0x20;
    var o: ZCOut = .{ .b = buf };
    const neg = zstd.math.signbit(v);
    const sgn: u8 = if (neg) '-' else if (flags & zc_plus != 0) '+' else if (flags & zc_space != 0) ' ' else 0;
    // C: an infinity or a NaN takes the sign flags and the width, but never the
    // zero fill — "for a, A, e, E, f, F, g, and G conversions ... the 0 flag is
    // ignored" once the result is not a number. A NaN is "[-]nan" (7.21.6.1p8):
    // its sign bit prints, and '+'/' ' apply as to any signed conversion.
    var special = false;
    if (zstd.math.isNan(v) or zstd.math.isInf(v)) {
        special = true;
        if (sgn != 0) o.put(sgn);
        if (zstd.math.isNan(v)) o.str(if (upper) "NAN" else "nan") else o.str(if (upper) "INF" else "inf");
    } else if (c == 'r') {
        if (sgn != 0) o.put(sgn);
        var z: ZCDec = undefined;
        zcShortest(&z, v);
        // Engineering notation: the exponent is a multiple of three and the
        // mantissa is in [1, 1000), which picks exactly one Table 2-1 symbol.
        const x: i32 = if (z.n == 0) 0 else z.dp - 1;
        var g: i32 = @divFloor(x, 3) * 3;
        g = @min(12, @max(-18, g)); // outside the table the mantissa absorbs it
        z.dp -= g;
        // Every shortest digit past the point: `n - dp` of them, which counts
        // the zeros between the point and a run that starts below it (dp < 0
        // once the clamp at -18 has absorbed the exponent).
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
        const body = o.n;
        zcFixed(&o, &z, p, false);
        if (prec < 0) zcStrip(&o, body);
        const sym = zcScaleSym(g);
        if (sym != 0) o.put(sym);
    } else {
        if (sgn != 0) o.put(sgn);
        var z: ZCDec = undefined;
        zcFrom(&z, v);
        const body = o.n;
        // C11 7.21.6.1p6 '#': "the result of converting a floating-point
        // number always contains a decimal-point character, even if no
        // digits follow it", and "for g and G conversions, trailing zeros
        // are not removed from the result".
        const alt = flags & zc_alt != 0;
        if (c == 'e') {
            zcSci(&o, &z, if (prec < 0) 6 else @intCast(prec), upper, null, alt);
        } else if (c == 'f' or prec >= 0) {
            // §9.4.3's own worked example — "%10.3g sets a minimum field width
            // of 10 with three (3) fractional digits" — reads a %g precision as
            // FRACTIONAL digits where C11 7.21.6.1 reads it as SIGNIFICANT
            // digits. The two cannot both hold; with an explicit precision the
            // clause's printed example is what VerA follows, because a tool
            // that follows the LRM's own example is following the LRM. See
            // tests/conformance/tests/verilog-a/ch09_system_tasks/real_g_conversion_is_significant_digits.va, which withdraws the
            // explicit-precision rows for exactly this reason.
            zcFixed(&o, &z, if (prec < 0) 6 else @intCast(prec), alt);
        } else {
            // %g with NO precision: there the contradiction cannot arise, and
            // C's rule and Table 9-23's "whichever format results in the
            // shorter printed output" agree on every value.
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

    if (o.n >= width) return o.b[0..o.n];
    // A field wider than the row cannot be padded on either side: the text is
    // returned as it fits, the bounded writer's rule. (Checked before the '-'
    // arm, whose pad loop could otherwise never reach `width`.)
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

// ---- §9.5.3 a format_string known only at run time ------------------------

/// §9.5.3: "$sformat always interprets its second argument, and only its
/// second argument, as a format string. This format argument can be a static
/// string ... or can be a string variable whose content is interpreted as the
/// format string." A literal is translated at compile time
/// (`cg_display.translateFormat`); a variable's content is known only here, so
/// this walks it with the same §9.4.3 conversions over `args`, a tuple of
/// `i64`, `f64` and `[]const u8` in source order. `scope` is what `%m` prints
/// (and `%l` after "work.", as the compile-time path does).
///
/// "If not enough arguments are supplied for the format specifiers or too
/// many are supplied, then the application shall issue a warning and continue
/// execution": a specifier with no argument left prints nothing, a surplus
/// argument is not printed, and either draws one warning on stderr. Returns the
/// text, in `buf` (a pointer to the site's row); an overrun is E1011
/// (`zSOver`), and so is a width or precision wider than the row's room.
///
/// ponytail: a radix conversion shows the 64-bit pattern (no §17.1.1.3
/// automatic width, which needs the operand's declared width); an unknown
/// letter, or '#' on a conversion `zcAltOk` refuses, is copied through with
/// a warning. Thread the widths in if a model formats a sized vector through
/// a variable format.
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
            'm' => zRtField(&o, scope, flags, width),
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
                inline for (args, 0..) |a, k| if (k == next) zRtConv(&o, tmp, a, conv, flags, width, prec);
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
    return o.b[0..o.n];
}

/// `zSFormatRt`'s output: `ZCOut`, but an overrun is E1011 rather than a cut.
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

/// `text` in a field of `width`, space-padded on the side '-' does not pick.
fn zRtField(o: *ZRtOut, text: []const u8, flags: u8, width: usize) void {
    const pad = width -| text.len;
    if (flags & zc_left == 0) for (0..pad) |_| o.put(' ');
    o.str(text);
    if (flags & zc_left != 0) for (0..pad) |_| o.put(' ');
}

/// One argument through one §9.4.3 conversion: a real conversion is `zCReal`;
/// an integer one takes §4.2.1.1's rounding of a real and §2.7's value of a
/// string; `%s` of a number is its bytes (§9.4.5).
fn zRtConv(o: *ZRtOut, tmp: []u8, a: anytype, conv: u8, flags: u8, width: usize, prec: i64) void {
    const T = @TypeOf(a);
    const int: i64 = if (T == i64) a else if (T == f64) zstd.math.lossyCast(i64, @round(a)) else blk: {
        var acc: u64 = 0;
        for (a[a.len - @min(a.len, 8) ..]) |ch| acc = acc << 8 | ch;
        break :blk @bitCast(acc);
    };
    switch (conv | 0x20) {
        'e', 'f', 'g', 'r' => {
            // A field or a precision past the row's room cannot fit; below
            // that, `tmp` holds the whole field (`zSFormatRt`).
            const room = o.b.len - o.n;
            if (width > room or prec > @as(i64, @intCast(room))) zSOver();
            o.str(zCReal(tmp, if (T == f64) a else @floatFromInt(int), conv, flags, width, prec));
        },
        'c' => zRtField(o, &.{@as(u8, @truncate(@as(u64, @bitCast(int))))}, flags, width),
        's' => if (T == []const u8) zRtField(o, a, flags, width) else {
            var be: [8]u8 = undefined;
            zstd.mem.writeInt(u64, &be, @bitCast(int), .big);
            zRtField(o, zstd.mem.trimStart(u8, &be, &.{0}), flags, width);
        },
        'd' => {
            // C 7.21.6.1: the sign leads the field, '0' fills between it and
            // the digits, '-' pads on the right.
            const sign: []const u8 = if (int < 0) "-" else if (flags & zc_plus != 0) "+" else if (flags & zc_space != 0) " " else "";
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
        else => { // else: the radices %h %x %o %b, the only letters `zSFormatRt` passes besides the arms above
            const u: u64 = @bitCast(int);
            const digits = switch (conv | 0x20) {
                'o' => zstd.mem.print(tmp, "{o}", .{u}),
                'b' => zstd.mem.print(tmp, "{b}", .{u}),
                else => zstd.mem.print(tmp, "{x}", .{u}), // else: %h and %x
            } catch unreachable;
            const pad = width -| digits.len;
            if (flags & (zc_zero | zc_left) == zc_zero) {
                for (0..pad) |_| o.put('0');
                o.str(digits);
            } else zRtField(o, digits, flags, width);
        },
    }
}

// ---- §9.4.1 the $monitor mechanism ----------------------------------------

/// §9.4.1, the sentence that separates `$monitor` from `$strobe`:
///
///   "When a $monitor task is invoked with one or more arguments, the simulator
///    sets up a mechanism whereby for each accepted step, IF THE VARIABLE OR AN
///    EXPRESSION IN THE ARGUMENT LIST CHANGES VALUE compared with the last
///    accepted step ... the entire argument list is displayed at the end of the
///    time step as if reported by the $strobe task. If two or more arguments
///    change value at the same time, ONLY ONE DISPLAY IS PRODUCED."
///
/// §9.5.2 carries it verbatim to `$fmonitor`: "the $fstrobe and $fmonitor
/// system tasks work just like their counterparts ... except that they write to
/// files using the file descriptor".
///
/// WHAT IS COMPARED: the argument VALUES, not the rendered line. The clause
/// asks whether "the variable or an expression in the argument list changes
/// value", and it exempts two of them by name — "with the exception of the
/// $abstime or $realtime system functions". A line comparison cannot honour
/// the exemption: a `$monitor("%g %d", $abstime, k)` renders a different line
/// on every step and reported every step. So the emitter hands this kernel one
/// u64 per watched argument — the bit pattern of a real or integer, a hash of
/// a string — with the `$abstime`/`$realtime` operands left out, and the text
/// to write when they changed. `lib/sim/digital/display.zig`'s monitor tracks its
/// watched variables the same way (IEEE 1364-2005 §17.1.3's `$time` rule).
///
/// Returns the text when the watched values differ from those this site last
/// reported — which includes the FIRST accepted step, where there is no "last
/// accepted step" to compare against — and null when the step is to be
/// suppressed, or when the statement has not been invoked yet: the mechanism
/// exists only once "a $monitor task is invoked" (`zMonitorArm`). `site` is
/// `Lower.armMonitor`'s key.
//
// ponytail: one latch per call site, as wide as the site watches (`vals` is
// `*const [n]u64`), file scope, on `zSBuf`'s terms and for `zSBuf`'s reason —
// the comparison has to outlive the step that made it. Per-instance latches
// are the upgrade the day a host runs two instances of a model that monitors.
pub fn zMonitor(comptime site: usize, vals: anytype, text: []const u8) ?[]const u8 {
    const Last = zMonitorLatch(site);
    if (!Last.armed) return null;
    const V = zMonitorVals(site, vals.len);
    if (V.seen and zstd.mem.eql(u64, &V.v, vals)) return null;
    V.v = vals.*;
    V.seen = true;
    return text;
}

/// §9.4.1 "sets up a mechanism": the statement ran, so site `site` reports at
/// the end of this accepted step and every one after it. f64 because the call
/// is a void task riding the display chain.
pub fn zMonitorArm(comptime site: usize) f64 {
    zMonitorLatch(site).armed = true;
    return 0.0;
}

fn zMonitorLatch(comptime site: usize) type {
    return struct {
        const n = site;
        var armed: bool = false;
    };
}

/// The values site `site` last reported, `len` of them.
fn zMonitorVals(comptime site: usize, comptime len: usize) type {
    return struct {
        const n = site;
        var v: [len]u64 = undefined;
        var seen: bool = false;
    };
}

/// §3.3 string storage excludes NUL bytes. Compact the completed formatter
/// output in its existing call-site scratch; padding counted the original bytes.
/// ponytail: scalar compaction, one pass over the site's row; consider
/// mask-based compaction if a model formats long text and it measures hot.
pub fn zStringStore(bytes: []u8) []const u8 {
    var used: usize = 0;
    for (bytes) |byte| {
        if (byte == 0) continue;
        bytes[used] = byte;
        used += 1;
    }
    return bytes[0..used];
}

/// Scratch for ONE `$sformat`/`$swrite` call site, keyed by the site's MIR
/// instruction id. The formatted bytes have to outlive the expression that
/// produced them — a string slot is a `[]const u8` and the writer is a
/// subexpression — so the storage cannot be a local in the emitted block.
///
/// A distinct `site` instantiates a distinct `Buf`, and therefore a distinct
/// array: that is what keeps two `$sformat` calls in one module from writing
/// over each other, which §9.5.3 requires (each names its own string variable).
///
// ponytail: file-scope rows. Two threads evaluating the SAME call site on
// different instances would interleave; per-instance scratch is the upgrade
// the day a host runs a device's units concurrently. An overrun ends the run
// (`zSOver`, E1011): §9.5.3 gives no truncation rule, so neither a cut nor an
// empty string is an answer the clause allows.
//
// This is the 4096-byte row; a site whose text can be longer gets a row of
// its own size (`zSRow`, sized by `cg_strcap`).
pub fn zSBuf(comptime site: usize) *[4096]u8 {
    const Buf = struct {
        const n = site;
        var b: [4096]u8 = undefined;
    };
    return &Buf.b;
}

/// Call site `site`'s row of `len` bytes: slot 0 is its text, slot k + 1 the
/// scratch of its operand k's composed field when that is too wide for the
/// stack (`cg_display.Spec.max_stack`). `zSBuf`'s terms otherwise.
pub fn zSRow(comptime site: usize, comptime slot: usize, comptime len: usize) *[len]u8 {
    const Row = struct {
        const n = site;
        const k = slot;
        var b: [len]u8 = undefined;
    };
    return &Row.b;
}

/// Scratch of `len` bytes that lives for one kernel call (`zStrCat`,
/// `zStrRepeat`, `zSFormatRt`): static, so a long row makes no long frame.
fn zSTmp(comptime len: usize) *[len]u8 {
    const Tmp = struct {
        var b: [len]u8 = undefined;
    };
    return &Tmp.b;
}

/// §5.10/§3.3 a held string variable's own bytes, an `Instance` field (#19).
/// Not a slice: a `$sformat` result lives in its site's `zSBuf`, which the
/// site rewrites the next time it runs (a Newton iterate, a rejected step, a
/// second instance), so a held slice of it changed under the device's feet.
/// `stateCtl` copies the whole value, so a revert restores the text.
// ponytail: `len` bytes per held string, the longest text the model can put
// there (`cg_strcap.heldCap`); `stateCtl` copies all of it per commit and
// revert. Copy `n` bytes there if a model holds many strings and it measures
// hot.
pub fn ZStrHeldN(comptime len: usize) type {
    return struct {
        n: zstd.math.IntFittingRange(0, len) = 0,
        b: [len]u8 = @splat(0),

        /// The held text.
        pub fn get(h: *const @This()) []const u8 {
            return h.b[0..h.n];
        }
    };
}

/// The held string of the 4096-byte row.
pub const ZStrHeld = ZStrHeldN(4096);

/// Returns a `ZStrHeldN(len)` holding a copy of `s`: a fresh value, so `s`
/// may be a slice of the field the result is stored into. Text longer than
/// the field is E1011, at compile time for an initializer.
pub fn zStrHeldN(comptime len: usize, s: []const u8) ZStrHeldN(len) {
    var h: ZStrHeldN(len) = .{};
    if (s.len > len) {
        if (@inComptime()) @compileError("error[E1011]: a held string initializer exceeds its field");
        zSOver();
    }
    @memcpy(h.b[0..s.len], s);
    h.n = @intCast(s.len);
    return h;
}

/// `zStrHeldN` for the 4096-byte `ZStrHeld`.
pub fn zStrHeld(s: []const u8) ZStrHeld {
    return zStrHeldN(4096, s);
}

/// E1011: run-time text outgrew the row its call site or held string was
/// sized for. Fatal, like `$fatal`, because the run cannot continue with the
/// value it was asked for.
pub fn zSOver() noreturn {
    zstd.debug.print("error[E1011]: run-time text exceeds the row the compiler sized for it; see `vera --explain E1011`\n", .{});
    zstd.process.exit(1);
}

/// §3.3 Table 3-3 "Concatenation of Str1,…,Strn" when a piece is a string
/// known only at run time, into its call site's row (`buf`, a pointer to
/// it). A piece may be this same site's previous result (`s = {s, "x"}`), so
/// the bytes are built in scratch first and copied once; an overrun is
/// `$sformat`'s E1011 (`zSOver`).
pub fn zStrCat(buf: anytype, parts: []const []const u8) []const u8 {
    const tmp = zSTmp(buf.len);
    var n: usize = 0;
    for (parts) |p| {
        if (p.len > tmp.len - n) zSOver();
        @memcpy(tmp[n..][0..p.len], p);
        n += p.len;
    }
    if (n > buf.len) zSOver();
    @memcpy(buf[0..n], tmp[0..n]);
    return buf[0..n];
}

/// §3.3 Table 3-3 Replication with a nonconstant multiplier: "a string
/// containing N concatenated copies of Str". The row fixes no result for a
/// negative N (§4.2.13's "non-negative" governs a constant), so N <= 0 is the
/// empty string, as zero copies are. Same local and overrun rule as `zStrCat`.
pub fn zStrRepeat(buf: anytype, count: i64, s: []const u8) []const u8 {
    if (count <= 0 or s.len == 0) return "";
    const tmp = zSTmp(buf.len);
    if (count > tmp.len / s.len) zSOver();
    const k: usize = @intCast(count);
    for (0..k) |j| @memcpy(tmp[j * s.len ..][0..s.len], s);
    @memcpy(buf[0 .. k * s.len], tmp[0 .. k * s.len]);
    return buf[0 .. k * s.len];
}

/// §2.6.2 Table 2-1's scale factor for one symbol, or null when the character
/// is not one. The 1e3 row is spelled "K, k", so a SCANNER takes both — which
/// is why no fixture may pin which of the two an output prints.
fn zScaleOf(c: u8) ?f64 {
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
fn zDigit(c: u8, radix: u8) ?u8 {
    // ponytail: keep the existing hex-digit ceiling even for a larger radix.
    return zstd.fmt.charToDigit(c, @min(radix, 16)) catch null;
}
