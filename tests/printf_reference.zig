//! L3 formatting oracle: `str_real.zCReal`, the one
//! `%e %f %g` conversion the analog devices (`cg_display`) and the digital
//! engine (`sim/digital/display.zig`, `sim/rt`) both print through, against
//! the C library's `snprintf`, which IEEE 1364-2005 §17.1.1.3 and VAMS §9.4.3
//! defer to ("the full formatting capabilities available in the C
//! language"). In: special doubles (±0, subnormals, inf, NaN, the largest
//! double, 1234.5678) under every flag set, several widths and precisions;
//! the ties that round across a power of ten; 10^5 seeded random doubles.
//! Out: byte-equal text. `lib/kernels/fmt.zig` has no real conversion of its own
//! (the digital path is zCReal with its flags, its field padded as it streams
//! by `display.real`, whose test holds that padding to zCReal's), so this is
//! its oracle too.
//!
//! The oracle is glibc's, and build.zig runs this nowhere else: a NaN's sign
//! is the implementation's to print (C11 7.21.6.1; Windows' UCRT differs),
//! and macOS libc keeps the trailing zeros on a `%g` tie, which C11 removes
//! (`%g` of 1347705: "1.34770e+06", not "1.3477e+06").
//!
//! One glibc defect is routed around, not matched: '#' %g of a value that
//! rounds up to 10^P (`Tally.see` has the rule and its C11 derivation).
//!
//! One deliberate gap: `%g` with an explicit precision. Both clauses' own
//! example reads `%10.3g` as "3 fractional digits" where C reads significant
//! digits, and VerA follows the example (`zCReal`'s comment, and the
//! withdrawn rows of `s01_01`), so only a `%g` without a precision is held
//! to C here.

const std = @import("std");
const zCReal = @import("kernels").str_real.zCReal;

extern "c" fn snprintf(buf: [*]u8, n: usize, format: [*:0]const u8, ...) c_int;

const inf = std.math.inf(f64);

/// One conversion, as zCReal takes it: flags 1 '-', 2 '+', 4 ' ', 8 '0',
/// 16 '#' (`str_real.zc_*`); `prec` -1 for none.
const Spec = struct { conv: u8, flags: u8 = 0, width: usize = 0, prec: i64 = -1 };

fn cFormat(buf: []u8, s: Spec) ![:0]u8 {
    var fl: [5]u8 = undefined;
    var nf: usize = 0;
    for ("-+ 0#", 0..) |c, i| if (s.flags & (@as(u8, 1) << @intCast(i)) != 0) {
        fl[nf] = c;
        nf += 1;
    };
    var wb: [24]u8 = undefined;
    const w = if (s.width > 0) try std.mem.print(&wb, "{d}", .{s.width}) else "";
    var pb: [24]u8 = undefined;
    const p = if (s.prec >= 0) try std.mem.print(&pb, ".{d}", .{s.prec}) else "";
    return std.mem.printSentinel(buf, "%{s}{s}{s}{c}", .{ fl[0..nf], w, p, s.conv }, 0);
}

/// Mismatches seen by one test; the first few are printed.
const Tally = struct {
    bad: usize = 0,
    ran: usize = 0,

    fn see(t: *Tally, v: f64, s: Spec) !void {
        var fb: [48]u8 = undefined;
        const f = try cFormat(&fb, s);
        var cb: [8192]u8 = undefined;
        const n = snprintf(&cb, cb.len, f.ptr, v);
        if (n < 0 or n >= cb.len) return error.SnprintfFailed;
        var want: []const u8 = cb[0..@intCast(n)];
        // glibc defect (2.42 at least): under '#', a %g whose value rounds up
        // to 10^P at P significant digits (999999.5 at P = 6) prints "1.e+06",
        // keeping the zero fraction digits it chose for style f before the
        // carry. C11 7.21.6.1p8 takes X after rounding (X = P, so style e at
        // precision P - 1) and '#' keeps the zeros: "1.00000e+06". With P > 1
        // C11 never prints "1.e", so there the oracle is C11's own rule run
        // through snprintf: the same flags and width as %e at precision P - 1.
        const p_g: i64 = if (s.prec < 0) 6 else @max(s.prec, 1);
        if (s.flags & 16 != 0 and s.conv | 0x20 == 'g' and p_g > 1 and std.mem.find(u8, want, if (s.conv == 'G') "1.E" else "1.e") != null) {
            var eb: [48]u8 = undefined;
            const ef = try cFormat(&eb, .{ .conv = s.conv - ('g' - 'e'), .flags = s.flags, .width = s.width, .prec = p_g - 1 });
            const en = snprintf(&cb, cb.len, ef.ptr, v);
            if (en < 0 or en >= cb.len) return error.SnprintfFailed;
            want = cb[0..@intCast(en)];
        }
        var zb: [8192]u8 = undefined;
        const got = zCReal(&zb, v, s.conv, s.flags, s.width, s.prec);
        t.ran += 1;
        if (std.mem.eql(u8, got, want)) return;
        t.bad += 1;
        if (t.bad <= 12) std.debug.print("printf: {s} of {e} (0x{x:0>16}): C \"{s}\", zCReal \"{s}\"\n", .{ f, v, @as(u64, @bitCast(v)), want, got });
    }

    fn done(t: Tally, what: []const u8) !void {
        if (t.bad == 0) return;
        std.debug.print("printf: {s}: {d} of {d} conversions differ from snprintf\n", .{ what, t.bad, t.ran });
        return error.PrintfMismatch;
    }
};

/// Every spec a special value meets: six letters, all 32 flag sets ('#'
/// included, #41), no width and a width of 13 (wider than most fields,
/// narrower than the long ones), and (but for %g) eleven precisions.
fn everySpec(t: *Tally, v: f64) !void {
    for ("eEfFgG") |conv| for (0..32) |flags| for ([_]usize{ 0, 13 }) |width| {
        const precs: []const i64 = if (conv | 0x20 == 'g') &.{-1} else &.{ -1, 0, 1, 2, 3, 6, 10, 16, 17, 20, 40 };
        for (precs) |prec| try t.see(v, .{ .conv = conv, .flags = @intCast(flags), .width = width, .prec = prec });
    };
}

test "§17.1.1.3 zCReal = snprintf: ±0, subnormals, inf, range ends and 1234.5678 under every flag, width and precision" {
    var t: Tally = .{};
    for ([_]f64{
        0,                      -0.0,                    inf,                     -inf,
        0x1p-1074,              -0x1p-1074,              0x0.fffffffffffffp-1022, 0x1p-1022,
        std.math.floatMax(f64), -std.math.floatMax(f64), 1234.5678,               -1234.5678,
        0.5,                    1.5,                     2.5,                     -2.5,
        0.125,                  9.5,                     99.5,                    0.05,
        1e-5,                   1e-4,                    9.9999e-5,               999999.5,
        999999.4999,            1e6,                     1e15,                    1e16,
        1e17,                   1e21,                    1e22,                    1e23,
        0.1,                    0.3,                     1.0 / 3.0,               std.math.pi,
        1e100,                  1e-100,                  1e308,                   1e-308,
        123456789012345678.0,   4.35,                    0.0005,                  1e-7,
    }) |v| try everySpec(&t, v);
    try t.done("specials");
}

test "§17.1.1.3 zCReal = snprintf for NaN, both signs" {
    var t: Tally = .{};
    for ([_]u64{ 0x7ff8000000000000, 0xfff8000000000000 }) |bits| try everySpec(&t, @bitCast(bits));
    try t.done("NaN");
}

test "§17.1.1.3 zCReal = snprintf: the values that round across a power of ten, at every precision" {
    var t: Tally = .{};
    var sb: [64]u8 = undefined;
    // 9...95·10^e with 1..17 nines, and 10^e itself: the ties (or their
    // nearest doubles) where a carry adds a digit or moves %g's style.
    for (0..18) |nines| {
        var e: i32 = -25;
        while (e <= 25) : (e += 1) {
            var s: []const u8 = undefined;
            if (nines == 0) s = try std.mem.print(&sb, "1e{d}", .{e}) else {
                @memset(sb[0..nines], '9');
                s = try std.mem.print(sb[nines..], "5e{d}", .{e});
                s = sb[0 .. nines + s.len];
            }
            const v = try std.fmt.parseFloat(f64, s);
            for ([_]f64{ std.math.nextAfter(f64, v, -inf), v, std.math.nextAfter(f64, v, inf) }) |x| {
                try t.see(x, .{ .conv = 'g' });
                var p: i64 = -1;
                while (p <= 17) : (p += 1) {
                    try t.see(x, .{ .conv = 'e', .prec = p });
                    try t.see(x, .{ .conv = 'f', .prec = p });
                }
            }
        }
    }
    try t.done("power-of-ten boundaries");
}

/// A random finite double: mostly ordinary magnitudes, some decimal-short
/// (m·10^k, whose expansions sit near decimal ties), some dyadic (m/2^j,
/// exact ties), and a tenth anywhere in the format.
fn randomDouble(r: std.Random, sb: []u8) !f64 {
    const sign: f64 = if (r.boolean()) -1 else 1;
    return switch (r.uintLessThan(u8, 20)) {
        0, 1 => blk: {
            var b = r.int(u64) & 0x7fffffffffffffff;
            if (b >= 0x7ff0000000000000) b -= 0x0010000000000000;
            break :blk sign * @as(f64, @bitCast(b));
        },
        2, 3, 4, 5, 6 => blk: {
            const s = try std.mem.print(sb, "{d}e{d}", .{ r.intRangeAtMost(u32, 1, 9999999), r.intRangeAtMost(i32, -30, 30) });
            break :blk sign * try std.fmt.parseFloat(f64, s);
        },
        7 => sign * @as(f64, @floatFromInt(r.intRangeAtMost(u32, 1, 1 << 20))) / @as(f64, @floatFromInt(@as(u32, 1) << r.intRangeAtMost(u5, 1, 12))),
        else => sign * std.math.ldexp(1 + r.float(f64), r.intRangeAtMost(i32, -70, 70)),
    };
}

test "§17.1.1.3 zCReal = snprintf on 10^5 seeded random doubles" {
    var t: Tally = .{};
    var prng: std.Random.DefaultPrng = .init(0x1711_3);
    const r = prng.random();
    var sb: [64]u8 = undefined;
    for (0..100_000) |_| {
        const v = try randomDouble(r, &sb);
        try t.see(v, .{ .conv = 'e' });
        try t.see(v, .{ .conv = 'f' });
        try t.see(v, .{ .conv = 'g' });
        const conv = "eEfFgG"[r.uintLessThan(usize, 6)];
        try t.see(v, .{
            .conv = conv,
            .flags = r.uintLessThan(u8, 32),
            .width = r.uintLessThan(usize, 31),
            .prec = if (conv | 0x20 == 'g') -1 else r.intRangeAtMost(i64, -1, 25),
        });
    }
    try t.done("random");
}
