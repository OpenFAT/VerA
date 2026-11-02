//! The kernel files' own tests: root.zig's `test` block pulls this file in,
//! so `zig build test-kernels` (and `zig build test`) run it. They sit here and
//! not beside the kernels because a kernel file's bytes are spliced verbatim
//! into every device that uses it (`codegen/kernel_text.zig`), and a test block
//! there shipped in every device's text. They still call the kernels through
//! the files the devices embed, so what they check is what a device runs.
//! LRM: §2.6.2, §4.5.11, §4.5.12, §4.5.15, §5.10.3.3, §9.4.1, §9.4.3, §9.5.1,
//! §9.5.1.1, §9.5.3, §9.5.4.2, §9.5.5, §9.5.7, §9.13, §9.17.3, §9.21;
//! IEEE 1364-2005 §17.2.4, §17.9.3.
//!
//! The plan, one oracle per bug class (none recomputes a kernel's answer the
//! way the kernel does):
//!   limit   wrong damping       -> the branchy ngspice transcriptions below,
//!                                  bit for bit; §9.17.3 transparency at
//!                                  vnew == vold as a property
//!   filter  wrong recurrence    -> difference equations and closed forms
//!                                  worked by hand on dyadic numbers (exact)
//!   table   wrong interpolant   -> polynomials a scheme must reproduce, and
//!                                  end conditions worked by hand
//!   rng     wrong seed stream   -> the listing's own structure: each routine
//!                                  consumes a known number of `uniform` steps
//!   timer   missed/early event  -> an integer-grid oracle on dyadic controls
//!   str     wrong conversion    -> C11 7.21.6 / §9.5.4.2 worked by hand
//!   file    wrong position/data -> the file's bytes, read back through `std`
//! Tests the shipped kernels fail carry zrunner's `xfail(...)` prefix. A
//! kernel that exits the process (E0816, E1011, a §9.21 `E` extrapolation)
//! is a fixture's job (`tests/rng_reference.zig`, `reject-run`), not this file's.
//!
//! Contents:
//! - `pub fn Dual.con(c: f64) Dual`
//! - `pub fn Dual.val(a: Dual) f64`
//! - `pub fn Dual.add(a: Dual, b: Dual) Dual`
//! - `pub fn Dual.addC(a: Dual, c: f64) Dual`
//! - `pub fn Dual.scale(a: Dual, c: f64) Dual`

const std = @import("std");
const gm = @import("contract").gm;
const filt = @import("kernels").filter_kernels;
const limit = @import("kernels").limit_kernels;
const tab = @import("kernels").table_kernels;
const rng = @import("kernels").rng_kernels;
const timer = @import("kernels").timer_kernels;
const str_scan = @import("kernels").str_scan;
const str_real = @import("kernels").str_real;
const str_format = @import("kernels").str_format;
const str_store = @import("kernels").str_store;
const file_k = @import("kernels").file_kernels;
const hist_k = @import("kernels").hist_kernels;
const wide = @import("kernels").wide_kernels;

/// The table the file kernel tests share, as a device instance's or a
/// digital run's (`file_kernels.zFCtx`).
var file_table: @import("kernels").file_table.ZfTable = .{};
const zc: *anyopaque = &file_table;

/// A one-derivative stand-in for the device's scalar family: the slice of the
/// interface the filter and table kernels call (`con`/`val`/`add`/`addC`/
/// `scale`), enough to read the Jacobian entry a kernel hands the solver.
const Dual = struct {
    v: f64,
    d: f64 = 0.0,

    pub fn con(c: f64) Dual {
        return .{ .v = c };
    }
    pub fn val(a: Dual) f64 {
        return a.v;
    }
    pub fn add(a: Dual, b: Dual) Dual {
        return .{ .v = a.v + b.v, .d = a.d + b.d };
    }
    pub fn addC(a: Dual, c: f64) Dual {
        return .{ .v = a.v + c, .d = a.d };
    }
    pub fn scale(a: Dual, c: f64) Dual {
        return .{ .v = a.v * c, .d = a.d * c };
    }
};

// ---- private ----

/// Fails unless `got` has exactly `want`'s bit pattern (so -0.0 is not 0.0).
fn expectSameBits(want: f64, got: f64) !void {
    try std.testing.expectEqual(@as(u64, @bitCast(want)), @as(u64, @bitCast(got)));
}

// ------------------------------------------------------------------ oracles
// limit_kernels.zig's original branchy ngspice transcriptions, verbatim, kept
// as the differential test's reference (simd-first T8: keep the scalar
// reference after the fast one ships). Test-only, so they live here and not in
// the device text.

fn zPnjlimOracle(vnew0: f64, vold: f64, vt: f64, vcrit: f64) f64 {
    var vnew = vnew0;
    if (vnew > vcrit and @abs(vnew - vold) > vt + vt) {
        if (vold > 0.0) {
            // The guard above makes |arg| > 2, so both logs take a
            // strictly positive argument (or exactly 0 after rounding).
            const arg = (vnew - vold) / vt;
            vnew = if (arg > 0.0)
                vold + vt * (2.0 + gm.log(arg - 2.0))
            else
                vold - vt * (2.0 + gm.log(2.0 - arg));
        } else {
            vnew = vt * gm.log(vnew / vt);
        }
    } else if (vnew < 0.0) {
        const arg = if (vold > 0.0) -vold - 1.0 else 2.0 * vold - 1.0;
        if (vnew < arg) vnew = arg;
    }
    return vnew;
}

fn zFetlimOracle(vnew0: f64, vold: f64, vto: f64) f64 {
    var vnew = vnew0;
    const vtsthi = @abs(2.0 * (vold - vto)) + 2.0;
    const vtstlo = vtsthi * 0.5 + 2.0;
    const vtox = vto + 3.5;
    const delv = vnew - vold;
    if (vold >= vto) {
        if (vold >= vtox) {
            if (delv <= 0.0) { // going off
                if (vnew >= vtox) {
                    if (-delv > vtstlo) vnew = vold - vtstlo;
                } else vnew = if (vnew > vto + 2.0) vnew else vto + 2.0; // ngspice MAX(a,b)
            } else { // staying on
                if (delv >= vtsthi) vnew = vold + vtsthi;
            }
        } else { // middle region
            vnew = if (delv <= 0.0)
                (if (vnew > vto - 0.5) vnew else vto - 0.5) // MAX
            else
                (if (vnew < vto + 4.0) vnew else vto + 4.0); // MIN
        }
    } else { // off
        if (delv <= 0.0) {
            if (-delv > vtsthi) vnew = vold - vtsthi;
        } else {
            const vtemp = vto + 0.5;
            if (vnew <= vtemp) {
                if (delv > vtstlo) vnew = vold + vtstlo;
            } else vnew = vtemp;
        }
    }
    return vnew;
}

fn zLimvdsOracle(vnew0: f64, vold: f64) f64 {
    var vnew = vnew0;
    if (vold >= 3.5) {
        if (vnew > vold) {
            vnew = @min(vnew, 3.0 * vold + 2.0);
        } else if (vnew < 3.5) vnew = @max(vnew, 2.0);
    } else {
        vnew = if (vnew > vold) @min(vnew, 4.0) else @max(vnew, -0.5);
    }
    return vnew;
}

/// ngspice `B4SOIlimit` minus the NaN reset (see zSteplim's header for why
/// the kernel bounds NaN instead of zeroing it).
fn zSteplimOracle(vnew0: f64, vold: f64, lim: f64) f64 {
    const t0 = vnew0 - vold;
    if (@abs(t0) > lim)
        return if (t0 > 0.0) vold + lim else vold - lim;
    return vnew0;
}

/// A seed `zRng*Next` returned, back in the i64 the seed variable holds.
fn seedOf(x: f64) i64 {
    return @intFromFloat(x);
}

/// `zRngNext` applied `n` times: `n` plain `uniform()` steps.
fn steps(seed: i64, n: usize) i64 {
    var s = seed;
    for (0..n) |_| s = seedOf(rng.zRngNext(s));
    return s;
}

/// The path `file_kernels` opens for `name` inside `tmp`: the kernels resolve
/// against the process cwd, where `std.testing.tmpDir` makes
/// `.zig-cache/tmp/<sub_path>`.
fn tmpPath(buf: []u8, tmp: *const std.testing.TmpDir, name: []const u8) []const u8 {
    return std.mem.print(buf, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path[0..], name }) catch unreachable;
}

/// Runs the file kernels over `gpa` from an empty table, and frees what they
/// own afterwards: `std.testing.allocator` then reports any leak.
fn fileOver(gpa: std.mem.Allocator) void {
    file_k.zFFreeAll(zc);
    file_k.zf_gpa = gpa;
}
fn fileDone() void {
    file_k.zFFreeAll(zc);
    file_k.zf_gpa = std.heap.page_allocator;
}

/// One accepted step of a ring as `updateState` runs it: the thinning
/// against window `w` (`zHistThin`, skipped when `thin` is false: a plain
/// ring), then the push.
fn histStep(comptime site: []const u8, ts: []f64, vs: []f64, head: *u64, t: f64, v: f64, w: f64, thin: bool) void {
    if (thin) hist_k.zHistThin(site, ts, vs, head, t, w);
    hist_k.zHistPush(ts, vs, head, t, v);
}

/// A random `n`-bit pattern, or one of the edge patterns.
fn wideOperand(comptime n: u32, r: std.Random) @Int(.unsigned, n) {
    const U = @Int(.unsigned, n);
    var bytes: [(n + 7) / 8 + 8]u8 = undefined;
    r.bytes(&bytes);
    var x: U = 0;
    for (bytes[0 .. (n + 7) / 8]) |b| x = if (n > 8) (x << 8) | b else @truncate(b);
    return switch (r.uintLessThan(u8, 8)) {
        0 => 0,
        1 => 1,
        2 => std.math.maxInt(U),
        3 => @as(U, 1) << (n - 1),
        // Short operands, so a division has a nonzero quotient and the
        // single-digit path runs.
        4 => x >> @intCast(n - @min(n, r.uintLessThan(u32, 40) + 1)),
        else => x,
    };
}

fn limbsOf(comptime n: u32, x: @Int(.unsigned, n)) [wide.zwLimbs(n)]u32 {
    var r: [wide.zwLimbs(n)]u32 = undefined;
    for (&r, 0..) |*d, i| d.* = @truncate(@as(@Int(.unsigned, 32 * wide.zwLimbs(n)), x) >> @intCast(32 * i));
    return r;
}

fn expectLimbs(comptime n: u32, what: []const u8, want: @Int(.unsigned, n), got: [wide.zwLimbs(n)]u32) !void {
    if (std.mem.eql(u32, &limbsOf(n, want), &got)) return;
    std.debug.print("n={d} {s}: want 0x{x} got {any}\n", .{ n, what, want, got });
    return error.TestExpectedEqual;
}

/// IEEE 1364 §5.1.5 `/` and `%` on native `n`-bit patterns, with the analog
/// context's 0 for a zero divisor (wide_kernels.zig's header).
fn nativeDivRem(comptime n: u32, comptime signed: bool, comptime rem: bool, a: @Int(.unsigned, n), b: @Int(.unsigned, n)) @Int(.unsigned, n) {
    const S = @Int(.signed, n);
    if (b == 0) return 0;
    if (!signed) return if (rem) a % b else a / b;
    if (b == std.math.maxInt(@Int(.unsigned, n))) return if (rem) 0 else 0 -% a;
    const x: S = @bitCast(a);
    const y: S = @bitCast(b);
    return @bitCast(if (rem) @rem(x, y) else @divTrunc(x, y));
}

fn wideNativeVsLimbs(comptime n: u32, r: std.Random) !void {
    const U = @Int(.unsigned, n);
    const S = @Int(.signed, n);
    const L = wide.zwL;
    for (0..24) |_| {
        const a = wideOperand(n, r);
        const b = wideOperand(n, r);
        const la = limbsOf(n, a);
        const lb = limbsOf(n, b);
        try expectLimbs(n, "+", a +% b, L.add(n, la, lb));
        try expectLimbs(n, "-", a -% b, L.sub(n, la, lb));
        try expectLimbs(n, "*", a *% b, L.mul(n, la, lb));
        try expectLimbs(n, "~", ~a, L.not(n, la));
        try expectLimbs(n, "&", a & b, L.bit(n, .@"and", la, lb));
        try expectLimbs(n, "|", a | b, L.bit(n, .@"or", la, lb));
        try expectLimbs(n, "^", a ^ b, L.bit(n, .xor, la, lb));
        inline for (.{ false, true }) |signed| inline for (.{ false, true }) |rem| {
            try expectLimbs(n, if (rem) "%" else "/", nativeDivRem(n, signed, rem, a, b), L.divRem(n, signed, rem, la, lb));
        };
        const counts = [_]u64{ 0, 1, 31, 32, 33, n - 1, n, n + 1, r.uintLessThan(u64, n + 8), std.math.maxInt(u64) };
        for (counts) |c| {
            try expectLimbs(n, "<<", std.math.shl(U, a, c), L.shl(n, la, c));
            try expectLimbs(n, ">>", std.math.shr(U, a, c), L.shr(n, false, la, c));
            try expectLimbs(n, ">>>", @bitCast(std.math.shr(S, @bitCast(a), c)), L.shr(n, true, la, c));
        }
        try std.testing.expectEqual(a < b, blk: {
            var i: usize = wide.zwLimbs(n);
            while (i > 0) {
                i -= 1;
                if (la[i] != lb[i]) break :blk la[i] < lb[i];
            }
            break :blk false;
        });
        // LLVM cannot lower `@floatFromInt` past 128 bits for aarch64
        // ("unsupported library call operation"), so wider widths take the
        // big-integer oracle's rounding.
        const real: f64 = if (n <= 128) @floatFromInt(a) else blk: {
            var m = try wideBig(std.testing.allocator, n, la, false);
            defer m.deinit();
            break :blk m.toConst().toFloat(f64, .nearest_even)[0];
        };
        try std.testing.expectEqual(real, L.toReal(n, la));
        inline for (.{ 1, n + 7, n + 64 }) |to| for ([_]bool{ false, true }) |signed| {
            const want: @Int(.unsigned, to) = if (to <= n) @truncate(a) else if (signed) @bitCast(@as(@Int(.signed, to), @as(S, @bitCast(a)))) else a;
            try expectLimbs(to, "resize", want, L.resize(to, n, signed, la));
        };
    }
}

/// `x` as an exact integer: the `n`-bit pattern, read signed when `signed`.
fn wideBig(gpa: std.mem.Allocator, comptime n: u32, x: wide.ZW(n), signed: bool) !std.math.big.int.Managed {
    const l = wide.zwToLimbs(n, x);
    var m = try std.math.big.int.Managed.init(gpa);
    try m.set(0);
    var i: usize = l.len;
    while (i > 0) {
        i -= 1;
        try m.shiftLeft(&m, 32);
        var d = try std.math.big.int.Managed.initSet(gpa, l[i]);
        defer d.deinit();
        try m.add(&m, &d);
    }
    if (signed and wide.zwBit(n, x, n - 1)) {
        var p = try std.math.big.int.Managed.initSet(gpa, 1);
        defer p.deinit();
        try p.shiftLeft(&p, n);
        try m.sub(&m, &p);
    }
    return m;
}

fn expectBig(gpa: std.mem.Allocator, comptime n: u32, what: []const u8, want: *std.math.big.int.Managed, got: wide.ZW(n)) !void {
    try want.truncate(want, .unsigned, n);
    var g = try wideBig(gpa, n, got, false);
    defer g.deinit();
    if (want.eql(g)) return;
    std.debug.print("n={d} {s}: want {f} got {f}\n", .{ n, what, want.*, g });
    return error.TestExpectedEqual;
}

fn wideAgainstBig(comptime n: u32, r: std.Random) !void {
    const gpa = std.testing.allocator;
    const Big = std.math.big.int.Managed;
    for (0..6) |_| {
        var la: [wide.zwLimbs(n)]u32 = undefined;
        var lb: [wide.zwLimbs(n)]u32 = undefined;
        for (&la, &lb) |*x, *y| {
            x.* = r.int(u32);
            y.* = r.int(u32);
        }
        // A short divisor half the time: the single-digit and early-exit paths.
        if (r.boolean()) @memset(lb[r.uintLessThan(usize, lb.len) + 1 ..], 0);
        const a = wide.zwFromLimbs(n, wide.zwL.norm(n, la));
        const b = wide.zwFromLimbs(n, wide.zwL.norm(n, lb));
        inline for (.{ false, true }) |signed| {
            var x = try wideBig(gpa, n, a, signed);
            defer x.deinit();
            var y = try wideBig(gpa, n, b, signed);
            defer y.deinit();
            var t = try Big.init(gpa);
            defer t.deinit();
            try t.add(&x, &y);
            try expectBig(gpa, n, "+", &t, wide.zwAdd(n, a, b));
            try t.sub(&x, &y);
            try expectBig(gpa, n, "-", &t, wide.zwSub(n, a, b));
            try t.mul(&x, &y);
            try expectBig(gpa, n, "*", &t, wide.zwMul(n, a, b));
            if (!wide.zwIsZero(n, b)) {
                var q = try Big.init(gpa);
                defer q.deinit();
                try q.divTrunc(&t, &x, &y);
                try expectBig(gpa, n, "/", &q, wide.zwDiv(n, signed, a, b));
                try expectBig(gpa, n, "%", &t, wide.zwRem(n, signed, a, b));
            }
            const e: u64 = r.uintLessThan(u64, 70);
            try t.pow(&x, @intCast(e));
            try expectBig(gpa, n, "**", &t, wide.zwPow(n, signed, a, 64, false, e));
            try std.testing.expectEqual(x.order(y) == .lt, wide.zwLt(n, signed, a, b));
            const f = x.toConst().toFloat(f64, .nearest_even);
            try std.testing.expectEqual(f[0], wide.zwToReal(n, signed, a));
        }
    }
}

// ---------------------------------------------------------------- filter
// `zBilin` is NOT re-tested here beyond the degree below: codegen's
// "§4.5.11 the bilinear transform is the one the emitted filter runs" already
// pins D = 0 and D = 2 exactly and the DC/Nyquist closed forms at D = 3.

test "zBilin: D = 1, the degree the other rows skip" {
    // P(s) = 2 + 3s, k = 10. Clearing (1+z⁻¹) by hand:
    //   P·(1+z⁻¹) = 2(1+z⁻¹) + 3k(1−z⁻¹) = (2+3k) + (2−3k)z⁻¹.
    // Dyadic, so exact. codegen.zig covers D = 0, 2 and 3; a first-order
    // section is the commonest filter there is and was the gap between them.
    const qz = filt.zBilin(1, .{ 2.0, 3.0 }, 10.0, 1);
    try std.testing.expectEqual([2]f64{ 32.0, -28.0 }, qz);
}

test "zDeg/zBilin: a zero-padded section transforms at its own degree" {
    // The same 2 + 3s padded to D = 3. Its effective degree is 1, and the
    // transform at d = 1 is the row above, bit for bit, with zeros after.
    // Untrimmed, `(1+z⁻¹)²` would multiply both sides: poles on z = −1.
    const sec: [2][4]f64 = .{ .{ 2.0, 3.0, 0.0, 0.0 }, .{ 1.0, 0.0, 0.0, 0.0 } };
    try std.testing.expectEqual(@as(usize, 1), filt.zDeg(3, sec));
    try std.testing.expectEqual([4]f64{ 32.0, -28.0, 0.0, 0.0 }, filt.zBilin(3, sec[0], 10.0, 1));
    // Either side sets the degree: a denominator-only s² is degree 2.
    try std.testing.expectEqual(@as(usize, 2), filt.zDeg(2, .{ .{ 1.0, 0.0, 0.0 }, .{ 1.0, 0.0, 5.0 } }));
    try std.testing.expectEqual(@as(usize, 0), filt.zDeg(2, .{ .{ 4.0, 0.0, 0.0 }, .{ 2.0, 0.0, 0.0 } }));
}

test "zPush: newest first, and an empty history is a no-op" {
    var uh: [3]f64 = .{ 0, 0, 0 };
    var yh: [3]f64 = .{ 0, 0, 0 };
    for ([_]f64{ 1, 2, 3 }) |v| filt.zPush(&uh, &yh, v, -v);
    // Newest at index 0, oldest last — the order zSec/zSecR index with.
    try std.testing.expectEqualSlices(f64, &.{ 3, 2, 1 }, &uh);
    try std.testing.expectEqualSlices(f64, &.{ -3, -2, -1 }, &yh);

    // A degree-0 section keeps no history; the guard is what makes that legal.
    var none: [0]f64 = .{};
    filt.zPush(&none, &none, 1.0, 1.0);
}

test "zH0: the gain at s = 0, common powers of s cancelled, a pole answers 0" {
    // den[0] != 0: num[0]/den[0], the pair unchanged.
    try std.testing.expectEqual([2]f64{ 3.0, 2.0 }, filt.zH0(1, .{ .{ 3.0, 5.0 }, .{ 2.0, 7.0 } }));
    // s / (s + s²) = 1 / (1 + s): H(0) = 1, not 0/0.
    try std.testing.expectEqual([2]f64{ 1.0, 1.0 }, filt.zH0(2, .{ .{ 0.0, 1.0, 0.0 }, .{ 0.0, 1.0, 1.0 } }));
    // s² / (s + s²): a zero at s = 0 remains, H(0) = 0.
    const z = filt.zH0(2, .{ .{ 0.0, 0.0, 1.0 }, .{ 0.0, 1.0, 1.0 } });
    try std.testing.expectEqual(@as(f64, 0.0), z[0] / z[1]);
    // 1 / s: a pole at s = 0, VerA's static output 0.
    try std.testing.expectEqual([2]f64{ 0.0, 1.0 }, filt.zH0(1, .{ .{ 1.0, 0.0 }, .{ 0.0, 1.0 } }));
}

test "zLaplaceStep: a slow pole holds H(0), and a step follows the bilinear difference equation" {
    // 0.625 / ((1 + s/1e5)(1 + s/1e9)) at dt = 0.1 ns: ω·dt = 1e-5 on the
    // slow pole. Direct form on the bilinear coefficients drifts off H(0)
    // here (specification/Vague_Decisions.md); the state-space step may not move at all.
    const sec: [1][2][3]f64 = .{.{ .{ 0.625, 0.0, 0.0 }, .{ 1.0, 1e-5 + 1e-9, 1e-14 } }};
    var uh: [2]f64 = undefined;
    var yh: [2]f64 = undefined;
    filt.zLaplaceStep(1, 2, 1.0, sec, 0.0, &uh, &yh);
    for (0..2000) |_| filt.zLaplaceStep(1, 2, 1.0, sec, 1e-10, &uh, &yh);
    const f = filt.zSsForm(2, sec[0]).?;
    try std.testing.expectEqual(filt.ZSs{ .off = 0, .m = 2 }, f);
    try std.testing.expectEqual(@as(f64, 0.625), filt.zSsStep(2, f, sec[0], &yh, 1.0, 1.0, 1e-10, null)[0]);

    // First order, 1/(1 + s), stepped 0 -> 1 from rest with h = 0.5: the
    // bilinear difference equation of y' = u − y,
    //   (1 + h/2) y_n = (1 − h/2) y_{n−1} + h/2 (u_{n−1} + u_n),
    // so y = 0.2, 0.52, 0.712, ... (u_0 = 0 is the static point).
    const one: [1][2][2]f64 = .{.{ .{ 1.0, 0.0 }, .{ 1.0, 1.0 } }};
    var uh1: [1]f64 = undefined;
    var yh1: [1]f64 = undefined;
    filt.zLaplaceStep(1, 1, 0.0, one, 0.0, &uh1, &yh1);
    var want: f64 = 0.0;
    var u_prev: f64 = 0.0;
    for (0..5) |_| {
        want = (0.75 * want + 0.25 * (u_prev + 1.0)) / 1.25;
        u_prev = 1.0;
        const got = filt.zSsStep(1, filt.zSsForm(1, one[0]).?, one[0], &yh1, uh1[0], 1.0, 0.5, null)[0];
        filt.zLaplaceStep(1, 1, 1.0, one, 0.5, &uh1, &yh1);
        try std.testing.expectApproxEqRel(want, got, 1e-15);
    }
    // A bare gain (D = 0) has no state to index: 3/2 at every point.
    var none: [0]f64 = .{};
    filt.zLaplaceStep(1, 0, 2.0, .{.{ .{3.0}, .{2.0} }}, 0.0, &none, &none);
    filt.zLaplaceStep(1, 0, 2.0, .{.{ .{3.0}, .{2.0} }}, 1e-9, &none, &none);
    // An improper section (s / 1) keeps direct form.
    try std.testing.expectEqual(@as(?filt.ZSs, null), filt.zSsForm(1, .{ .{ 0.0, 1.0 }, .{ 1.0, 0.0 } }));
}

test "zRootSecs: conjugates pair within tolerance, reals pair in order, an orphan is NaN" {
    // -1 ± 1j (the partner off by 1e-12 relative) and -2: (1 + s + s²/2), (1 + s/2).
    const s = filt.zRootSecs(3, false, .{ -1, 1, -2, 0, -1, -1 - 1e-12 });
    try std.testing.expectApproxEqRel(@as(f64, 1.0), s[0][1], 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 0.5), s[0][2], 1e-12);
    try std.testing.expectEqual([3]f64{ 1, 0.5, 0 }, s[1]);
    // Two reals and a zero root in z⁻¹: (1 − 0.5z⁻¹)(1 − 0.25z⁻¹), z⁻¹.
    const z = filt.zRootSecs(3, true, .{ 0.5, 0, 0.25, 0, 0, 0 });
    try std.testing.expectEqual([3]f64{ 1, -0.75, 0.125 }, z[0]);
    try std.testing.expectEqual([3]f64{ 0, 1, 0 }, z[1]);
    // -1 + 1j alone has no conjugate.
    try std.testing.expect(filt.zRootSecs(1, false, .{ -1, 1 })[0][0] != filt.zRootSecs(1, false, .{ -1, 1 })[0][0]);
}

test "zSecR: unit section is the identity, and gain is b0/a0" {
    const uh: [1]f64 = .{0};
    const yh: [1]f64 = .{0};
    try std.testing.expectApproxEqAbs(
        @as(f64, 4.25),
        filt.zSecR(1, 4.25, .{ 1, 0 }, .{ 1, 0 }, &uh, &yh),
        1e-12,
    );
    // b[0]/a[0] is the instantaneous gain the solver differentiates through.
    try std.testing.expectApproxEqAbs(
        @as(f64, 2.0),
        filt.zSecR(1, 4.0, .{ 3, 0 }, .{ 6, 0 }, &uh, &yh),
        1e-12,
    );
}

test "zSecR/zSec: the history terms, and the slope is b0/a0" {
    // y = (b0·u + Σ b_j·uh[j-1] − a_j·yh[j-1]) / a0 with b = {1,2,3},
    // a = {2,0.5,0.25}, u = 4, uh = {1,2}, yh = {4,8}:
    //   (4 + (2 − 2) + (6 − 2)) / 2 = 4, every term dyadic.
    const b: [3]f64 = .{ 1, 2, 3 };
    const a: [3]f64 = .{ 2, 0.5, 0.25 };
    const uh: [2]f64 = .{ 1, 2 };
    const yh: [2]f64 = .{ 4, 8 };
    try std.testing.expectEqual(@as(f64, 4.0), filt.zSecR(2, 4.0, b, a, &uh, &yh));
    // The solver's form: the same value, and ∂y/∂u = b0/a0 = 0.5.
    const y = filt.zSec(Dual, 2, .{ .v = 4.0, .d = 1.0 }, b, a, &uh, &yh);
    try std.testing.expectEqual(@as(f64, 4.0), y.v);
    try std.testing.expectEqual(@as(f64, 0.5), y.d);
}

test "zH0/zSsForm: an all-zero denominator, and common powers of s cancelled" {
    // No nonzero denominator coefficient: the pair divides by zero, as a
    // zero resistance does, and the state-space form has nothing to hold.
    try std.testing.expectEqual([2]f64{ 3.0, 0.0 }, filt.zH0(1, .{ .{ 3.0, 1.0 }, .{ 0.0, 0.0 } }));
    try std.testing.expectEqual(@as(?filt.ZSs, null), filt.zSsForm(1, .{ .{ 1.0, 0.0 }, .{ 0.0, 0.0 } }));
    // (s + 2s²) / (4s + 8s²): one power of s on both sides, cancelled, so a
    // first-order section is left (off = 1, m = 1).
    try std.testing.expectEqual(filt.ZSs{ .off = 1, .m = 1 }, filt.zSsForm(2, .{ .{ 0.0, 1.0, 2.0 }, .{ 0.0, 4.0, 8.0 } }));
    // zLaplaceH0 is zH0 of each section.
    const h = filt.zLaplaceH0(2, 1, .{ .{ .{ 3.0, 1.0 }, .{ 2.0, 5.0 } }, .{ .{ 0.0, 1.0 }, .{ 0.0, 4.0 } } });
    try std.testing.expectEqual([2][2]f64{ .{ 3.0, 2.0 }, .{ 1.0, 4.0 } }, h);
}

test "zLaplace: a static point is the product of the section gains, value and slope" {
    // (3 + s)/(2 + 5s) has H(0) = 3/2; s/(4s) cancels to 1/4. dt <= 0 (and a
    // NaN dt, which is not > 0) is static: y = 2·(3/2)·(1/4) = 0.75 and the
    // Jacobian entry is the gain itself, 0.375. All dyadic, so exact.
    const sec: [2][2][2]f64 = .{ .{ .{ 3.0, 1.0 }, .{ 2.0, 5.0 } }, .{ .{ 0.0, 1.0 }, .{ 0.0, 4.0 } } };
    const hist: [2]f64 = .{ 0.0, 0.0 };
    for ([_]f64{ 0.0, -1.0, std.math.nan(f64) }) |dt| {
        const y = filt.zLaplace(Dual, 2, 1, .{ .v = 2.0, .d = 1.0 }, sec, dt, &hist, &hist);
        try std.testing.expectEqual(@as(f64, 0.75), y.v);
        try std.testing.expectEqual(@as(f64, 0.375), y.d);
    }
}

test "zLaplace: one trapezoidal step of 1/(1+s), and an improper section in direct form" {
    // y' = u − y from rest (x = 0, ua = 0) to ub = 1 over dt = 0.5, c = dt/2:
    //   (1 + c)Δ = c·(2(−x + ua) + (ub − ua)) ⇒ Δ = 0.25/1.25 = 0.2,
    // and ∂y/∂ub = c/(1 + c) = 0.2. Both quotients are the one correctly
    // rounded 0.2, so the comparison is exact.
    const lag: [1][2][2]f64 = .{.{ .{ 1.0, 0.0 }, .{ 1.0, 1.0 } }};
    const zero: [1]f64 = .{0.0};
    const y = filt.zLaplace(Dual, 1, 1, .{ .v = 1.0, .d = 1.0 }, lag, 0.5, &zero, &zero);
    try std.testing.expectEqual(@as(f64, 0.2), y.v);
    try std.testing.expectEqual(@as(f64, 0.2), y.d);

    // s/1 has no state-space form. Its bilinear coefficients at k = 2/dt = 4
    // are b = {k, −k}, a = {1, 1}, so y = 4u − 4·uh − yh: from uh = 0.5,
    // yh = 2 and u = 1 that is 0, with slope 4.
    const diff: [1][2][2]f64 = .{.{ .{ 0.0, 1.0 }, .{ 1.0, 0.0 } }};
    const uh: [1]f64 = .{0.5};
    const yh: [1]f64 = .{2.0};
    const d = filt.zLaplace(Dual, 1, 1, .{ .v = 1.0, .d = 1.0 }, diff, 0.5, &uh, &yh);
    try std.testing.expectEqual(@as(f64, 0.0), d.v);
    try std.testing.expectEqual(@as(f64, 4.0), d.d);
    // The accepted step runs the same equation and pushes (u, y) newest-first.
    var us: [1]f64 = .{0.5};
    var ys: [1]f64 = .{2.0};
    filt.zLaplaceStep(1, 1, 1.0, diff, 0.5, &us, &ys);
    try std.testing.expectEqual([1]f64{1.0}, us);
    try std.testing.expectEqual([1]f64{0.0}, ys);
}

test "zZiStep: a two-section cascade follows its difference equations" {
    // Section 0: y = u + 0.5·y₋₁ (num {1, 0}, den {1, −0.5}); section 1: a
    // gain of 0.5. A unit step from rest: section 0 gives 1, 1.5, 1.75 and the
    // cascade 0.5, 0.75, 0.875. Dyadic throughout.
    const sec: [2][2][2]f64 = .{ .{ .{ 1.0, 0.0 }, .{ 1.0, -0.5 } }, .{ .{ 0.5, 0.0 }, .{ 1.0, 0.0 } } };
    var uh: [2]f64 = .{ 0.0, 0.0 };
    var yh: [2]f64 = .{ 0.0, 0.0 };
    for ([_]f64{ 0.5, 0.75, 0.875 }) |want| try std.testing.expectEqual(want, filt.zZiStep(2, 1, 1.0, sec, &uh, &yh));
    // Each section's newest (input, output) pair is what it pushed last.
    try std.testing.expectEqual([2]f64{ 1.0, 1.75 }, uh);
    try std.testing.expectEqual([2]f64{ 1.75, 0.875 }, yh);
    // The static gain is H(1) = ∏ Σnum/Σden = (1/0.5)·(0.5/1) = 1.
    try std.testing.expectEqual(@as(f64, 1.0), filt.zZiGain(2, 1, sec));
}

test "zZiEval: static gain, the held output between samples, and the sample itself" {
    const sec: [2][2][2]f64 = .{ .{ .{ 1.0, 0.0 }, .{ 1.0, -0.5 } }, .{ .{ 0.5, 0.0 }, .{ 1.0, 0.0 } } };
    // Static: z = 1, the input times H(1) = 1, slope 1.
    const none: [2]f64 = .{ 0.0, 0.0 };
    const st = filt.zZiEval(Dual, 2, 1, .{ .v = 3.0, .d = 1.0 }, sec, 0.0, 99.0, 0.0, 0.0, 1.0, &none, &none);
    try std.testing.expectEqual(@as(f64, 3.0), st.v);
    try std.testing.expectEqual(@as(f64, 1.0), st.d);

    // The history after one accepted unit sample (see the zZiStep test).
    var uh: [2]f64 = .{ 0.0, 0.0 };
    var yh: [2]f64 = .{ 0.0, 0.0 };
    _ = filt.zZiStep(2, 1, 1.0, sec, &uh, &yh);
    // Between samples (t = 0.5, one sample taken, T = 1): the held output,
    // and no derivative.
    const held = filt.zZiEval(Dual, 2, 1, .{ .v = 1.0, .d = 1.0 }, sec, 1e-3, 0.5, 0.5, 1.0, 1.0, &uh, &yh);
    try std.testing.expectEqual(@as(f64, 0.5), held.v);
    try std.testing.expectEqual(@as(f64, 0.0), held.d);
    // At t = T the second sample is owed: §4.5.12 "exhibits no delay", so the
    // output is that sample's, 0.75, with slope (1/1)·(0.5/1) = 0.5.
    const at = filt.zZiEval(Dual, 2, 1, .{ .v = 1.0, .d = 1.0 }, sec, 1e-3, 0.5, 1.0, 1.0, 1.0, &uh, &yh);
    try std.testing.expectEqual(@as(f64, 0.75), at.v);
    try std.testing.expectEqual(@as(f64, 0.5), at.d);
    // A step that jumped to t = 2T owes two: one is replayed on a copy, the
    // last is differentiated. The third sample of the step response, 0.875.
    const two = filt.zZiEval(Dual, 2, 1, .{ .v = 1.0, .d = 1.0 }, sec, 1e-3, 0.5, 2.0, 1.0, 1.0, &uh, &yh);
    try std.testing.expectEqual(@as(f64, 0.875), two.v);
    try std.testing.expectEqual(@as(f64, 0.5), two.d);
    // The residual never moves the accepted history.
    try std.testing.expectEqual([2]f64{ 1.0, 1.0 }, uh);
    try std.testing.expectEqual([2]f64{ 1.0, 0.5 }, yh);
}

test "zZiDue/zZiRamp: the sample count and the transition" {
    // n = floor(t/T + 1e-9) + 1 − nk: the k-th instant k·T is owed once t
    // reaches it, so t = 0 owes the first.
    try std.testing.expectEqual(@as(u32, 1), filt.zZiDue(0.0, 0.0, 1.0));
    try std.testing.expectEqual(@as(u32, 2), filt.zZiDue(2.5, 1.0, 1.0));
    try std.testing.expectEqual(@as(u32, 0), filt.zZiDue(0.5, 1.0, 1.0));
    // A time 1e-12 short of an instant reaches it (the relative tolerance).
    try std.testing.expectEqual(@as(u32, 1), filt.zZiDue(1.0 - 1e-12, 1.0, 1.0));
    // The replay is bounded, and a period that is not positive owes nothing.
    try std.testing.expectEqual(@as(u32, 4096), filt.zZiDue(1e12, 0.0, 1.0));
    try std.testing.expectEqual(@as(u32, 0), filt.zZiDue(1.0, 0.0, 0.0));
    try std.testing.expectEqual(@as(u32, 0), filt.zZiDue(1.0, 0.0, -1.0));
    try std.testing.expectEqual(@as(u32, 0), filt.zZiDue(1.0, 0.0, std.math.nan(f64)));
    try std.testing.expectEqual(@as(u32, 0), filt.zZiDue(std.math.nan(f64), 0.0, 1.0));

    // From 0 to 4 starting at ts = 1 over tau = 2: before, halfway, after.
    try std.testing.expectEqual(@as(f64, 0.0), filt.zZiRamp(0.0, 4.0, 1.0, 2.0, 0.5));
    try std.testing.expectEqual(@as(f64, 2.0), filt.zZiRamp(0.0, 4.0, 1.0, 2.0, 2.0));
    try std.testing.expectEqual(@as(f64, 4.0), filt.zZiRamp(0.0, 4.0, 1.0, 2.0, 3.0));
    // tau = 0 is "abruptly discontinuous": the new value at once.
    try std.testing.expectEqual(@as(f64, 4.0), filt.zZiRamp(0.0, 4.0, 1.0, 0.0, 0.5));
}

test "zZiEvalRamp: the transition weight is 0 at the sample instant and grows over tau" {
    // A unity section (D = 0), T = 10, t0 = 0, one sample taken, the previous
    // transition from 0 to 1 began at ts = 1 with tau = 2.
    const unity: [1][2][1]f64 = .{.{ .{1.0}, .{1.0} }};
    const empty: [0]f64 = .{};
    const u: Dual = .{ .v = 5.0, .d = 1.0 };
    // t = 2, no sample owed: the transition's value, 0.5, flat.
    const mid = filt.zZiEvalRamp(Dual, 1, 0, u, unity, 1e-3, 1.0, 0.0, 1.0, 2.0, 1.0, 10.0, 0.0, 2.0, &empty, &empty);
    try std.testing.expectEqual(@as(f64, 0.5), mid.v);
    try std.testing.expectEqual(@as(f64, 0.0), mid.d);
    // t = 10, the sample is owed but w = 0: still the previous value, 1.
    const now = filt.zZiEvalRamp(Dual, 1, 0, u, unity, 1e-3, 1.0, 0.0, 1.0, 10.0, 1.0, 10.0, 0.0, 2.0, &empty, &empty);
    try std.testing.expectEqual(@as(f64, 1.0), now.v);
    try std.testing.expectEqual(@as(f64, 0.0), now.d);
    // t = 11, w = 0.5: half the new sample (5) and half the old value (1).
    const half = filt.zZiEvalRamp(Dual, 1, 0, u, unity, 1e-3, 1.0, 0.0, 1.0, 11.0, 1.0, 10.0, 0.0, 2.0, &empty, &empty);
    try std.testing.expectEqual(@as(f64, 3.0), half.v);
    try std.testing.expectEqual(@as(f64, 0.5), half.d);
}

test "zRootSecs: real s-domain roots pair in order, and a zero root is s" {
    // (1 − s/ρ) for ρ = −2 and −4: (1 + s/2)(1 + s/4) = 1 + 0.75s + 0.125s².
    try std.testing.expectEqual([1][3]f64{.{ 1.0, 0.75, 0.125 }}, filt.zRootSecs(2, false, .{ -2.0, 0.0, -4.0, 0.0 }));
    // ρ = 0 alone is §4.5.11's `s` term, a degree-1 section.
    try std.testing.expectEqual([1][3]f64{.{ 0.0, 1.0, 0.0 }}, filt.zRootSecs(1, false, .{ 0.0, 0.0 }));
}

// §4.5.15 the branchless limiters against the oracles above.
test "§4.5.15 branchless limiters ≡ branchy ngspice oracles, bit for bit" {
    const expectBits = struct {
        fn eq(a: f64, b: f64) !void {
            try std.testing.expectEqual(@as(u64, @bitCast(a)), @as(u64, @bitCast(b)));
        }
    }.eq;

    var prng = std.Random.DefaultPrng.init(0x5eed_4515);
    const rand = prng.random();
    // Signed magnitude in 1e-12..1e3 (log-uniform), both signs.
    const draw = struct {
        fn any(r: std.Random) f64 {
            const m = std.math.pow(f64, 10.0, -12.0 + 15.0 * r.float(f64));
            return if (r.boolean()) m else -m;
        }
        fn pos(r: std.Random) f64 {
            return std.math.pow(f64, 10.0, -12.0 + 15.0 * r.float(f64));
        }
    };

    for (0..1_000_000) |_| {
        const vnew = draw.any(rand);
        const vold = draw.any(rand);
        // vt/vcrit positive: the physical domain (see header) — outside it the
        // ORACLE logs a negative and NaNs, which the clamped kernel cannot.
        const vt = draw.pos(rand);
        const vcrit = draw.pos(rand);
        const vto = draw.any(rand);
        const lim = draw.pos(rand);
        try expectBits(limit.zPnjlim(vnew, vold, vt, vcrit), zPnjlimOracle(vnew, vold, vt, vcrit));
        try expectBits(limit.zFetlim(vnew, vold, vto), zFetlimOracle(vnew, vold, vto));
        try expectBits(limit.zLimvds(vnew, vold), zLimvdsOracle(vnew, vold));
        try expectBits(limit.zSteplim(vnew, vold, lim), zSteplimOracle(vnew, vold, lim));
        try expectBits(limit.zSteplim(vold + lim, vold, lim), zSteplimOracle(vold + lim, vold, lim)); // |Δ| == lim
        try expectBits(limit.zSteplim(vold - lim, vold, lim), zSteplimOracle(vold - lim, vold, lim));

        // Exact boundary hits, derived from the same random draws so they land
        // on every magnitude: each guard's `==` case must stay transparent.
        try expectBits(limit.zPnjlim(vcrit, vold, vt, vcrit), zPnjlimOracle(vcrit, vold, vt, vcrit)); // vnew == vcrit
        try expectBits(limit.zPnjlim(vold + (vt + vt), vold, vt, vcrit), zPnjlimOracle(vold + (vt + vt), vold, vt, vcrit)); // |Δ| == 2vt
        try expectBits(limit.zPnjlim(vold - (vt + vt), vold, vt, vcrit), zPnjlimOracle(vold - (vt + vt), vold, vt, vcrit));
        try expectBits(limit.zPnjlim(-vold - 1.0, vold, vt, vcrit), zPnjlimOracle(-vold - 1.0, vold, vt, vcrit)); // vnew == floor
        try expectBits(limit.zPnjlim(vnew, 0.0, vt, vcrit), zPnjlimOracle(vnew, 0.0, vt, vcrit)); // vold on its sign guard
        try expectBits(limit.zFetlim(vnew, vto, vto), zFetlimOracle(vnew, vto, vto)); // vold == vto
        try expectBits(limit.zFetlim(vnew, vto + 3.5, vto), zFetlimOracle(vnew, vto + 3.5, vto)); // vold == vtox
        try expectBits(limit.zFetlim(vold, vold, vto), zFetlimOracle(vold, vold, vto)); // delv == 0
        try expectBits(limit.zFetlim(vto + 0.5, vold, vto), zFetlimOracle(vto + 0.5, vold, vto)); // vnew == vtemp
        try expectBits(limit.zFetlim(vto + 2.0, vold, vto), zFetlimOracle(vto + 2.0, vold, vto));
        try expectBits(limit.zLimvds(vnew, 3.5), zLimvdsOracle(vnew, 3.5)); // vold on 3.5
        try expectBits(limit.zLimvds(3.5, vold), zLimvdsOracle(3.5, vold)); // vnew on 3.5
        try expectBits(limit.zLimvds(vold, vold), zLimvdsOracle(vold, vold)); // vnew == vold
        try expectBits(limit.zLimvds(4.0, vold), zLimvdsOracle(4.0, vold));
        try expectBits(limit.zLimvds(-0.5, vold), zLimvdsOracle(-0.5, vold));
        try expectBits(limit.zLimvds(3.0 * vold + 2.0, vold), zLimvdsOracle(3.0 * vold + 2.0, vold));
    }

    // Signed-zero ties through the MAX/MIN ternaries: vto placing a bound at
    // exactly 0.0 while vnew is ±0.0.
    for ([_]f64{ -2.0, 0.5, -4.0 }) |vto| {
        for ([_]f64{ 0.0, -0.0 }) |z| {
            for ([_]f64{ 1.0, -1.0, 5.0, -5.0, 0.0 }) |vold| {
                try expectBits(limit.zFetlim(z, vold, vto), zFetlimOracle(z, vold, vto));
            }
        }
    }

    // fetlim step-bound edges need vtsthi/vtstlo, which depend on (vold, vto).
    for (0..1_000) |_| {
        const vold = draw.any(rand);
        const vto = draw.any(rand);
        const vtsthi = @abs(2.0 * (vold - vto)) + 2.0;
        const vtstlo = vtsthi * 0.5 + 2.0;
        for ([_]f64{ vold + vtsthi, vold - vtsthi, vold + vtstlo, vold - vtstlo }) |vnew|
            try expectBits(limit.zFetlim(vnew, vold, vto), zFetlimOracle(vnew, vold, vto));
    }
}

test "§9.17.3 a converged bias comes back unchanged from every limiter" {
    // "When the simulator has converged, the return value of the $limit()
    // function is the value of the access function reference": vnew == vold
    // is that state, and cg_limit reads "the clamp fired" off any change.
    // limvds is ngspice's DEVlimvds, which floors a bias below -0.5 V even at
    // a fixed point (it runs only after the MOS mode swap makes vds >= 0), so
    // its property is stated on that domain alone.
    var prng = std.Random.DefaultPrng.init(0x9173_0003);
    const r = prng.random();
    for (0..100_000) |_| {
        const v = (r.float(f64) - 0.5) * 20.0;
        const vt = 0.001 + 0.1 * r.float(f64);
        const vcrit = 0.1 + r.float(f64);
        const vto = (r.float(f64) - 0.5) * 4.0;
        const lim = 2.0 * r.float(f64);
        try expectSameBits(v, limit.zPnjlim(v, v, vt, vcrit));
        try expectSameBits(v, limit.zFetlim(v, v, vto));
        try expectSameBits(v, limit.zSteplim(v, v, lim));
        if (v >= -0.5) try expectSameBits(v, limit.zLimvds(v, v));
    }
}

test "§4.5.15 zSteplim: |vnew − vold| ≤ lim, and a non-finite iterate stays bounded" {
    try std.testing.expectEqual(@as(f64, 1.5), limit.zSteplim(10.0, 1.0, 0.5));
    try std.testing.expectEqual(@as(f64, 0.5), limit.zSteplim(-10.0, 1.0, 0.5));
    try std.testing.expectEqual(@as(f64, 1.25), limit.zSteplim(1.25, 1.0, 0.5));
    try std.testing.expectEqual(@as(f64, 1.5), limit.zSteplim(std.math.inf(f64), 1.0, 0.5));
    try std.testing.expectEqual(@as(f64, 0.5), limit.zSteplim(-std.math.inf(f64), 1.0, 0.5));
    // A NaN iterate has no side to clamp to; the header promises only that the
    // result is a bound, never the NaN.
    const n = limit.zSteplim(std.math.nan(f64), 1.0, 0.5);
    try std.testing.expect(n >= 0.5 and n <= 1.5);
}

// ------------------------------------------------------------------- table

test "§9.21 zTabLess/zTabSort/zTabEnd: lexicographic, stable, contiguous isolines" {
    // Rows (x, y, f), outermost column first.
    const rows = [_]f64{ 1, 2, 10, 1, 3, 20, 0, 9, 30 };
    try std.testing.expect(tab.zTabLess(3, 2, &rows, 0, 1)); // equal x, 2 < 3
    try std.testing.expect(!tab.zTabLess(3, 2, &rows, 1, 0));
    try std.testing.expect(tab.zTabLess(3, 2, &rows, 2, 0)); // 0 < 1 decides
    try std.testing.expect(!tab.zTabLess(3, 2, &rows, 0, 0)); // strict
    // One independent: rows 1 and 3 share x = 1, rows 0 and 2 share x = 2;
    // the sort keeps source order within each (§9.21's duplicate rule reads
    // the first of a run).
    const one = [_]f64{ 2, 0, 1, 0, 2, 0, 1, 0 };
    var order = [_]u32{ 0, 1, 2, 3 };
    tab.zTabSort(2, 1, &one, &order);
    try std.testing.expectEqualSlices(u32, &.{ 1, 3, 0, 2 }, &order);
    try std.testing.expectEqual(@as(usize, 2), tab.zTabEnd(2, &one, &order, 0, 0));
    try std.testing.expectEqual(@as(usize, 4), tab.zTabEnd(2, &one, &order, 0, 2));
}

test "§9.21.4 zTabSpline1: both splines reproduce a straight line, value and slope" {
    // f = 2x + 1 on x = 0..3. The natural cubic's moments solve to 0 and the
    // quadratic's knot slopes march as 2, 2, 2, so both are the line itself,
    // and `L` extrapolates along it. Dyadic, so exact.
    const xs = [_]f64{ 0, 1, 2, 3 };
    const fs = [_]f64{ 1, 3, 5, 7 };
    for ([_]u8{ '2', '3' }) |scheme| {
        for ([_]f64{ -1.0, 0.0, 0.5, 1.5, 2.5, 3.0, 5.0 }) |t| {
            const got = tab.zTabSpline1(4, scheme, 'L', 'L', &xs, &fs, t);
            try std.testing.expectEqual(2.0 * t + 1.0, got.v);
            try std.testing.expectEqual(@as(f64, 2.0), got.d);
        }
    }
    // `E` has no extrapolant to meet, so it takes `L`'s end condition.
    try std.testing.expectEqual(@as(f64, 4.0), tab.zTabSpline1(4, '3', 'E', 'E', &xs, &fs, 1.5).v);
}

test "§9.21.4 zTabSpline1: `C` ends are clamped, S' = 0, and flat beyond the table" {
    // Cubic on (0, 1), (1, 3) clamped both ends is the Hermite cubic
    // 1 + 2(3u² − 2u³): at u = 0.5 the value 2 and slope 12u(1 − u) = 3, and
    // the slope at either knot is 0. Moments ±12, all dyadic.
    const xs = [_]f64{ 0, 1 };
    const fs = [_]f64{ 1, 3 };
    const mid = tab.zTabSpline1(2, '3', 'C', 'C', &xs, &fs, 0.5);
    try std.testing.expectEqual(@as(f64, 2.0), mid.v);
    try std.testing.expectEqual(@as(f64, 3.0), mid.d);
    try std.testing.expectEqual(@as(f64, 0.0), tab.zTabSpline1(2, '3', 'C', 'C', &xs, &fs, 0.0).d);
    try std.testing.expectEqual(@as(f64, 0.0), tab.zTabSpline1(2, '3', 'C', 'C', &xs, &fs, 1.0).d);
    // Table 9-31 constant extrapolation "returns the table endpoint value".
    try std.testing.expectEqual(tab.zTabVD{ .v = 1.0, .d = 0.0 }, tab.zTabSpline1(2, '3', 'C', 'C', &xs, &fs, -1.0));
    try std.testing.expectEqual(tab.zTabVD{ .v = 3.0, .d = 0.0 }, tab.zTabSpline1(2, '3', 'C', 'C', &xs, &fs, 2.0));
    // The quadratic honours the low end: S'(0) = 0, then S = 1 + 2u² on the
    // first interval of 2x + 1's samples, so 1.5 with slope 2 at u = 0.5.
    const q = tab.zTabSpline1(4, '2', 'C', 'L', &[_]f64{ 0, 1, 2, 3 }, &[_]f64{ 1, 3, 5, 7 }, 0.5);
    try std.testing.expectEqual(@as(f64, 1.5), q.v);
    try std.testing.expectEqual(@as(f64, 2.0), q.d);
}

test "§9.21.4 zTabSpline1: the cubic interpolates every knot of curved data" {
    const xs = [_]f64{ 0, 1, 3, 4 };
    const fs = [_]f64{ 0, 1, 0, 2 };
    for ([_]u8{ 'L', 'C' }) |end| {
        for (xs, fs) |x, f| try std.testing.expectApproxEqAbs(f, tab.zTabSpline1(4, '3', end, end, &xs, &fs, x).v, 1e-12);
    }
}

test "§9.21 zTable: a spline dimension carries its own slope, and `E` admits the endpoint" {
    // One dimension, f = 2x + 1 sampled at 0..3, scheme `3`: the line, and
    // the Jacobian entry 2.
    const line = [_]f64{ 0, 1, 1, 3, 2, 5, 3, 7 };
    const f = tab.zTable(Dual, 4, 2, 1, 1, "3LL", line, .{.{ .v = 1.5, .d = 1.0 }});
    try std.testing.expectEqual(@as(f64, 4.0), f.v);
    try std.testing.expectEqual(@as(f64, 2.0), f.d);
    // Table 9-31 `E` reports a point BEYOND the interpolation region; the
    // endpoints themselves are inside it, so these return rather than exit.
    try std.testing.expectEqual(@as(f64, 1.0), tab.zTable(Dual, 4, 2, 1, 1, "1EE", line, .{.{ .v = 0.0 }}).v);
    try std.testing.expectEqual(@as(f64, 7.0), tab.zTable(Dual, 4, 2, 1, 1, "1EE", line, .{.{ .v = 3.0 }}).v);
}

// --------------------------------------------------------------------- rng

test "§9.13 every routine consumes the uniform steps IEEE 1364 §17.9.3 says" {
    // The seed is an inout source variable, so the write-back must walk as far
    // as the listing's routine did. Each relation below is a sentence of the
    // listing: `exponential` and a one-stage `erlangian` draw one uniform,
    // `chi_square` draws one normal for an odd df then one exponential per
    // even pair, `t` is a chi_square then a normal, `poisson` draws one
    // uniform plus one per count, and `rtl_dist_uniform` draws one whenever
    // start < end.
    for ([_]i64{ -2147483648, -7, 0, 1, 7, 42, 2147483647 }) |s| {
        const one = rng.zRngNext(s);
        try std.testing.expectEqual(one, rng.zRngExponentialNext(s, 3.0));
        try std.testing.expectEqual(one, rng.zRngErlangNext(s, 1.0, 3.0));
        try std.testing.expectEqual(@as(f64, @floatFromInt(steps(s, 3))), rng.zRngErlangNext(s, 3.0, 1.0));
        try std.testing.expectEqual(one, rng.zRngChiSquareNext(s, 2.0));
        try std.testing.expectEqual(@as(f64, @floatFromInt(steps(s, 2))), rng.zRngChiSquareNext(s, 4.0));
        const nrm = rng.zRngNormalNext(s, 0.0, 1.0);
        try std.testing.expectEqual(nrm, rng.zRngChiSquareNext(s, 1.0));
        try std.testing.expectEqual(rng.zRngNext(seedOf(nrm)), rng.zRngChiSquareNext(s, 3.0));
        try std.testing.expectEqual(rng.zRngNormalNext(seedOf(rng.zRngChiSquareNext(s, 5.0)), 0.0, 1.0), rng.zRngTNext(s, 5.0));
        const k: usize = @intFromFloat(rng.zRngPoisson(s, 3.0));
        try std.testing.expectEqual(@as(f64, @floatFromInt(steps(s, k + 1))), rng.zRngPoissonNext(s, 3.0));
        try std.testing.expectEqual(one, rng.zRngIUniformNext(s, -5.0, 5.0));
        try std.testing.expectEqual(one, rng.zRngIUniformNext(s, 0.0, 2147483647.0));
        try std.testing.expectEqual(one, rng.zRngUniformNext(s, -1.0, 1.0));
    }
}

test "§9.13 the variates are the listing's formulas over its uniform" {
    // `exponential` is −log(u)·mean and a one-stage `erlangian` −mean·log(u)/1,
    // u being the very `uniform(seed, 0, 1)` draw. Within an ulp, not bit for
    // bit: an optimizing build may fold one side's log at compile time.
    for ([_]i64{ -7, 1, 7, 42, 2147483647 }) |s| {
        const u = rng.zRngUniform(s, 0.0, 1.0);
        try std.testing.expect(u != 0.0);
        try std.testing.expectApproxEqRel(-@log(u) * 3.0, rng.zRngExponential(s, 3.0), 1e-15);
        try std.testing.expectApproxEqRel(-3.0 * @log(u), rng.zRngErlang(s, 1.0, 3.0), 1e-15);
    }
}

test "§9.13 the seed is the low 32 bits of the integer, read as signed" {
    try std.testing.expectEqual(rng.zRngNext(7), rng.zRngNext(7 + (1 << 32)));
    try std.testing.expectEqual(rng.zRngNext(-1), rng.zRngNext(0xFFFF_FFFF));
    try std.testing.expectEqual(rng.zRngRand(-2147483648), rng.zRngRand(2147483648));
}

test "IEEE 1364 §17.9.2 $dist_uniform: the closed range, its degenerate case, its extremes" {
    var s: i64 = 1;
    for (0..2000) |_| {
        for ([_][2]f64{ .{ -5, 5 }, .{ 0, 1 }, .{ 100, 101 }, .{ -2147483648, 0 }, .{ 0, 2147483647 }, .{ -2147483647, 2147483647 } }) |range| {
            const x = rng.zRngIUniform(s, range[0], range[1]);
            try std.testing.expect(x >= range[0] and x <= range[1]);
            try std.testing.expectEqual(@round(x), x);
        }
        // §9.13.2 `$rdist_uniform`: [start, end) up to the listing's own
        // top sliver of (end − start)·2⁻²³.
        const y = rng.zRngUniform(s, -1.0, 1.0);
        try std.testing.expect(y >= -1.0 and y <= 1.0 + 2.0 * 0x1p-22);
        s = seedOf(rng.zRngNext(s));
    }
    // `if (start >= end) return start`, before the seed is touched.
    try std.testing.expectEqual(@as(f64, 5), rng.zRngIUniform(9, 5, 5));
    try std.testing.expectEqual(@as(f64, 6), rng.zRngIUniform(9, 6, 5));
    try std.testing.expectEqual(@as(f64, 9), rng.zRngIUniformNext(9, 6, 5));
    // The full int32 range is the third branch, `$random`'s; bounds past
    // int32 fold onto it the way the reference's C cast did.
    for ([_]i64{ -7, 0, 7, 42 }) |seed| {
        try std.testing.expectEqual(rng.zRngRand(seed), rng.zRngIUniform(seed, -2147483648, 2147483647));
        try std.testing.expectEqual(rng.zRngRandNext(seed), rng.zRngIUniformNext(seed, -2147483648, 2147483647));
        try std.testing.expectEqual(rng.zRngRand(seed), rng.zRngIUniform(seed, -1e300, 1e300));
    }
    // A live but unused call: every rule satisfied, nothing drawn, 0 returned.
    try std.testing.expectEqual(@as(f64, 0), rng.zRngCheck(1.0, 0b1111, 2.0, 3.0));
    try std.testing.expectEqual(@as(f64, 0), rng.zRngCheck(1.0, 0, -1.0, -2.0));
}

// ------------------------------------------------------------------- timer

test "§5.10.3.3 zNextTimer: the first event strictly after t, against an integer oracle" {
    // Controls on a 1/8 grid and times on a 1/16 grid: every start + k·period
    // is exact, so the oracle is integer arithmetic in sixteenths. The kernel
    // divides by periods like 3/8, whose quotient does round; its repair
    // steps are what this checks.
    var i: i64 = -8;
    while (i <= 8) : (i += 1) {
        var j: i64 = 1;
        while (j <= 6) : (j += 1) {
            var m: i64 = -40;
            while (m <= 40) : (m += 1) {
                const s16 = 2 * i;
                const p16 = 2 * j;
                const k: i64 = if (s16 > m) 0 else @divFloor(m - s16, p16) + 1;
                const want: f64 = @as(f64, @floatFromInt(s16 + k * p16)) / 16.0;
                const start: f64 = @as(f64, @floatFromInt(i)) / 8.0;
                const period: f64 = @as(f64, @floatFromInt(j)) / 8.0;
                const t: f64 = @as(f64, @floatFromInt(m)) / 16.0;
                try std.testing.expectEqual(@as(?f64, want), timer.zNextTimer(start, period, t));
            }
        }
    }
}

test "§5.10.3.3 zNextTimer: one-shots, non-finite controls, a vanishing period" {
    // Strictly after: an event AT t is not next.
    try std.testing.expectEqual(@as(?f64, 1.5), timer.zNextTimer(1.0, 0.5, 1.0));
    // A non-positive period has only its start event.
    try std.testing.expectEqual(@as(?f64, 3.0), timer.zNextTimer(3.0, 0.0, 2.0));
    try std.testing.expectEqual(@as(?f64, null), timer.zNextTimer(1.0, 0.0, 2.0));
    try std.testing.expectEqual(@as(?f64, null), timer.zNextTimer(1.0, -1.0, 2.0));
    try std.testing.expectEqual(@as(?f64, null), timer.zNextTimer(std.math.nan(f64), 1.0, 0.0));
    try std.testing.expectEqual(@as(?f64, null), timer.zNextTimer(0.0, 1.0, std.math.inf(f64)));
    try std.testing.expectEqual(@as(?f64, null), timer.zNextTimer(0.0, std.math.inf(f64), 1.0));
    // A period below t's spacing: consecutive times span an event, so the
    // answer is just past t, not t itself.
    const r = timer.zNextTimer(0.0, 1e-300, 1.0).?;
    try std.testing.expect(r > 1.0 and r < 1.0 + 1e-15);
}

test "§5.10.3.3 zTimerPending/zTimerDue: a changed control replaces the pending event" {
    const inf = std.math.inf(f64);
    // Unchanged controls keep the scheduled event, even one already passed:
    // a host that stepped just beyond it still observes it.
    try std.testing.expectEqual(@as(f64, 2.0), timer.zTimerPending(1.0, 0.5, 2.25, 1.0, 0.5, 2.0));
    try std.testing.expect(timer.zTimerDue(1.0, 0.5, 2.25, 1.0, 0.5, 2.0));
    // A new start at or after now is the event.
    try std.testing.expectEqual(@as(f64, 5.0), timer.zTimerPending(5.0, 1.0, 2.0, 0.0, 0.0, 99.0));
    // A past one-shot is spent.
    try std.testing.expectEqual(inf, timer.zTimerPending(1.0, 0.0, 2.0, 0.0, 0.0, 99.0));
    // Now is on the new grid, so now is the event; off the grid, the next one.
    try std.testing.expectEqual(@as(f64, 2.0), timer.zTimerPending(1.0, 0.5, 2.0, 0.0, 0.0, 99.0));
    try std.testing.expect(timer.zTimerDue(1.0, 0.5, 2.0, 0.0, 0.0, 99.0));
    try std.testing.expectEqual(@as(f64, 2.5), timer.zTimerPending(1.0, 0.5, 2.25, 0.0, 0.0, 99.0));
    try std.testing.expect(!timer.zTimerDue(1.0, 0.5, 2.25, 0.0, 0.0, 99.0));
}

// ---------------------------------------------------------------- held string

test "zStrHeld: a held string owns its bytes, so rewriting the source leaves it (#19)" {
    const str = @import("kernels").str_store;
    var site: [8]u8 = "t=10    ".*;
    const held = str.zStrHeld(site[0..4]);
    @memcpy(site[0..4], "t=20");
    try std.testing.expectEqualStrings("t=10", held.get());
    // `updateState`'s order: copy out first, then store (the new text may be
    // a slice of the field it replaces). A copy is a value, which is what
    // `stateCtl(.revert)` restores.
    var inst = held;
    const next = str.zStrHeld(inst.get()[2..]);
    inst = next;
    try std.testing.expectEqualStrings("10", inst.get());
    try std.testing.expectEqualStrings("t=10", held.get());
}

test "zStrHeld: exactly one 4096-byte row fits" {
    const full: [4096]u8 = @splat('a');
    const h = str_store.zStrHeld(&full);
    try std.testing.expectEqual(@as(usize, 4096), h.get().len);
}

// ------------------------------------------------------------------ string

test "§9.5.4.2 zScan: %c keeps white space, %s and the radix codes take their fields" {
    // "%c Matches a single character. The normal skip over white space is
    // suppressed"; a width takes that many.
    const c = str_scan.zScan(" x", "%c", 0);
    try std.testing.expectEqual(@as(i64, 1), c.n);
    try std.testing.expectEqual(@as(i64, ' '), c.i);
    try std.testing.expectEqual(@as(usize, 1), c.used);
    try std.testing.expectEqualStrings("abc", str_scan.zScanS("abcdef", "%3c", 0));
    try std.testing.expectEqualStrings("ab", str_scan.zScanS("ab", "%5c", 0));
    // %s stops at white space or the width, and the next field resumes there.
    try std.testing.expectEqualStrings("hel", str_scan.zScanS("hello world", "%3s", 0));
    try std.testing.expectEqualStrings("lo", str_scan.zScanS("hello world", "%3s%s", 1));
    // §2.7: a string read as a number is base 256.
    try std.testing.expectEqual(@as(i64, 0x4142), str_scan.zScanI("AB", "%s", 0));
    // The radices, an optional sign, and §2.6.1's `_` separator skipped.
    try std.testing.expectEqual(@as(i64, 511), str_scan.zScanI("777", "%o", 0));
    try std.testing.expectEqual(@as(i64, 5), str_scan.zScanI("1_01", "%b", 0));
    try std.testing.expectEqual(@as(i64, 255), str_scan.zScanI("fF", "%h", 0));
    try std.testing.expectEqual(@as(i64, -26), str_scan.zScanI("-1A", "%x", 0));
    try std.testing.expectEqual(@as(i64, 12), str_scan.zScanI("+12", "%d", 0));
    try std.testing.expectEqual(@as(f64, 12.0), str_scan.zScanR("+12", "%d", 0));
    // A digit outside the radix ends the field and is left unread.
    const o = str_scan.zScan("78", "%o", 0);
    try std.testing.expectEqual(@as(i64, 7), o.i);
    try std.testing.expectEqual(@as(usize, 1), o.used);
    // A sign or a separator alone is a matching failure: 0 items, not EOF.
    try std.testing.expectEqual(@as(i64, 0), str_scan.zScanN("+", "%d"));
    try std.testing.expectEqual(@as(i64, 0), str_scan.zScanN("_", "%d"));
}

test "§9.5.4.2 zScan: the C real shape, and %r's optional Table 2-1 symbol" {
    try std.testing.expectEqual(@as(f64, -0.5), str_scan.zScanR("-.5", "%f", 0));
    try std.testing.expectEqual(@as(f64, 25.0), str_scan.zScanR("2.5e1", "%e", 0));
    try std.testing.expectEqual(@as(f64, 300.0), str_scan.zScanR("3.e2x", "%g", 0));
    // An `e` with no digit after it is not an exponent, and is left unread.
    const e = str_scan.zScan("1e", "%f", 0);
    try std.testing.expectEqual(@as(f64, 1.0), e.r);
    try std.testing.expectEqual(@as(usize, 1), e.used);
    // No digit at all is a matching failure, and so is a word, `inf` included.
    try std.testing.expectEqual(@as(i64, 0), str_scan.zScanN(".", "%f"));
    try std.testing.expectEqual(@as(i64, 0), str_scan.zScanN("inf", "%f"));
    // The integer view of a real truncates toward zero.
    try std.testing.expectEqual(@as(i64, -2), str_scan.zScanI("-2.75", "%f", 0));
    // §2.6.2: the symbol follows with no space, and 1e3 is spelled K or k.
    try std.testing.expectEqual(@as(f64, 2500.0), str_scan.zScanR("2.5k", "%r", 0));
    try std.testing.expectEqual(@as(f64, 2500.0), str_scan.zScanR("2.5K", "%r", 0));
    try std.testing.expectEqual(@as(f64, 1.5), str_scan.zScanR("1.5", "%r", 0));
    const spaced = str_scan.zScan("3 k", "%r", 0);
    try std.testing.expectEqual(@as(f64, 3.0), spaced.r);
    try std.testing.expectEqual(@as(usize, 1), spaced.used);
}

test "§9.5.4.2 zScan: white space, literals, %%, %m, and what a scan leaves unread" {
    // Control-string white space matches any run, newlines included, or none.
    try std.testing.expectEqual(@as(i64, 2), str_scan.zScanN("1\n\t 2", "%d %d"));
    try std.testing.expectEqual(@as(i64, 2), str_scan.zScanI("1\n\t 2", "%d %d", 1));
    try std.testing.expectEqual(@as(i64, 1), str_scan.zScanN("12", "%d %d"));
    // "trailing white space (including newline characters) is left unread
    // unless matched by a directive".
    try std.testing.expectEqual(@as(usize, 1), str_scan.zScan("7  \n", "%d", -1).used);
    try std.testing.expectEqual(@as(usize, 4), str_scan.zScan("7  \n", "%d ", -1).used);
    try std.testing.expectEqual(@as(usize, 2), str_scan.zScan("12 ab", "%d", -1).used);
    // The leading white space a conversion skips stays consumed when the
    // conversion then fails on the character after it.
    try std.testing.expectEqual(@as(usize, 2), str_scan.zScan("  x", "%d", -1).used);
    // Literal text must be there; `%%` is a literal percent, not an item.
    try std.testing.expectEqual(@as(i64, 1), str_scan.zScanN("a=5", "a=%d"));
    try std.testing.expectEqual(@as(i64, 0), str_scan.zScanN("b=5", "a=%d"));
    try std.testing.expectEqual(@as(i64, 1), str_scan.zScanN("5%", "%d%%"));
    // "%m ... Does not read data": an assignment even with no input left.
    try std.testing.expectEqual(@as(i64, 1), str_scan.zScanN("", "%m"));
    try std.testing.expectEqualStrings("", str_scan.zScanS("", "%m", 0));
    try std.testing.expectEqual(@as(i64, 2), str_scan.zScanN("4", "%m%d"));
    try std.testing.expectEqual(@as(i64, 4), str_scan.zScanI("4", "%m%d", 1));
    // An invalid conversion character stops the scan with the items so far,
    // and so does a control string that ends inside a specification.
    try std.testing.expectEqual(@as(i64, 1), str_scan.zScanN("5 6", "%d %q"));
    try std.testing.expectEqual(@as(i64, 1), str_scan.zScanN("5", "%d%"));
    try std.testing.expectEqual(@as(i64, 1), str_scan.zScanN("5", "%d%5"));
    // `want` counts ASSIGNED items, so a suppressed field has no index, and
    // an item the scan never reached has a zero payload.
    try std.testing.expectEqual(@as(i64, 3), str_scan.zScanI("1 2 3", "%d %*d %d", 1));
    try std.testing.expectEqual(@as(i64, 0), str_scan.zScanI("1", "%d %d", 1));
    try std.testing.expectEqual(@as(f64, 0.0), str_scan.zScanR("1", "%d %d", 1));
    try std.testing.expectEqualStrings("", str_scan.zScanS("1", "%d %d", 1));
    // EOF: the input ends before any conversion was tried.
    try std.testing.expectEqual(@as(i64, -1), str_scan.zScanN("   ", "%d"));
    try std.testing.expectEqual(@as(i64, -1), str_scan.zScanN("", "%c"));
}

test "§9.5.4.2 $sscanf: a null character is white space, for it only" {
    // "For $sscanf, null characters shall also be considered white space."
    // Between two fields, in the format's white-space run, and as a `%s`
    // terminator.
    try std.testing.expectEqual(@as(i64, 2), str_scan.zScanNulN("1\x002", "%d %d"));
    try std.testing.expectEqual(@as(i64, 7), str_scan.zScanNulI("1\x00 7", "%d %d", 1));
    try std.testing.expectEqualStrings("ab", str_scan.zScanNulS("ab\x00cd", "%s", 0));
    // `$fscanf` keeps C's set: the same input stops it.
    try std.testing.expectEqual(@as(i64, 1), str_scan.zScanN("1\x002", "%d %d"));
    try std.testing.expectEqualStrings("ab\x00cd", str_scan.zScanS("ab\x00cd", "%s", 0));
    try std.testing.expectEqual(@as(i64, -1), str_scan.zScanN("a", "a%d"));
}

test "§9.5.4.2 zScan: EOF when the input ends before the first matching failure" {
    // "This number can be EOF if the input ends before the first matching
    // failure or conversion." A matching failure needs a conflicting
    // character; an input that has ended offers none, so a control string
    // that opens with literal text answers EOF on it (C11 7.21.6.2p16 calls
    // this an input failure before the first conversion).
    try std.testing.expectEqual(@as(i64, -1), str_scan.zScanN("", "x%d"));
    try std.testing.expectEqual(@as(i64, -1), str_scan.zScanN("", "%%"));
    try std.testing.expectEqual(@as(i64, -1), str_scan.zScanN("  ", " x%d"));
}

test "§9.4.3 zCReal: special values, zero, the extremes, flags and widths (C11 7.21.6.1)" {
    var b: [64]u8 = undefined;
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    const neg_zero = -@as(f64, 0.0);
    // Flags, in `cg_format.Spec`'s order: 1 '-', 2 '+', 4 ' ', 8 '0'.
    const rows = .{
        .{ nan, 'f', @as(u8, 0), @as(usize, 0), @as(i64, -1), "nan" },
        .{ nan, 'F', 0, 0, -1, "NAN" },
        .{ -inf, 'e', 0, 0, -1, "-inf" },
        .{ inf, 'g', 2, 0, -1, "+inf" },
        .{ inf, 'f', 8, 6, -1, "   inf" }, // '0' never fills a non-number
        .{ inf, 'f', 1, 6, -1, "inf   " },
        .{ 0.0, 'e', 0, 0, -1, "0.000000e+00" },
        .{ neg_zero, 'f', 0, 0, 2, "-0.00" },
        .{ 0.0, 'g', 0, 0, -1, "0" },
        .{ 5e-324, 'e', 0, 0, -1, "4.940656e-324" },
        .{ 1.7976931348623157e308, 'e', 0, 0, -1, "1.797693e+308" },
        .{ 2.5, 'e', 0, 0, 0, "2e+00" }, // an exact tie goes to the even digit
        .{ 3.5, 'e', 0, 0, 0, "4e+00" },
        .{ 9.5, 'e', 0, 0, 0, "1e+01" }, // and a carry renormalises
        .{ 1.5, 'e', 4, 0, -1, " 1.500000e+00" },
        .{ 1.5, 'e', 6, 0, -1, "+1.500000e+00" }, // '+' wins over ' '
        .{ 1.0e8, 'G', 0, 0, -1, "1E+08" },
        .{ 100000.0, 'g', 0, 0, -1, "100000" },
        .{ 1.0e-4, 'g', 0, 0, -1, "0.0001" },
        .{ 123456789.0, 'g', 0, 0, -1, "1.23457e+08" },
        .{ 0.5, 'g', 0, 0, -1, "0.5" },
        .{ 1234.5678, 'g', 0, 0, 2, "1234.57" }, // §9.4.3's fractional reading
        .{ 12.0, 'f', 8, 6, 1, "0012.0" },
        .{ -1.0, 'f', 9, 6, 1, "-1.0  " }, // '-' overrides '0'
        .{ 1.0, 'e', 0, 3, -1, "1.000000e+00" }, // a width below the text
    };
    inline for (rows) |row| {
        try std.testing.expectEqualStrings(row[5], str_real.zCReal(&b, row[0], row[1], row[2], row[3], row[4]));
    }
}

test "§9.4.3 a %g precision: the device's zCReal and the host's formatSay print one text (#44)" {
    // §9.4.3's example reads "%10.3g" as "a minimum field width of 10 with
    // three (3) fractional digits"; VerA follows it on the device (zCReal)
    // and, since #44, on the host rendering a recorded `Say` (formatC), where
    // C11 would count significant digits. Each `want` is worked by hand as
    // `%f` at that precision:
    //   %.3g    1234.5678  to 3 places, the 0.0008 past 1234.567 rounds up:
    //                      "1234.568" (C11: "1.23e+03")
    //   %10.3g  1234.5678  the same 8 characters right-justified in 10
    //   %.2g    0.012345   0.01|2345 rounds down: "0.01" (C11: "0.012")
    //   %.0g    7.25       no fractional digit, .25 rounds down: "7"
    //   %.6g    1.5        six places, kept: "1.500000" (C11: "1.5")
    //   %#.0g   3.0        '#' keeps the point: "3." (C11: "3.")
    //   %-8.1G  2.375      2.3|75 rounds up to "2.4", left in 8 columns
    //   %+.2g   0.5        the sign, two places: "+0.50"
    //   %g      1234.5678  no precision: C's six significant digits, "1234.57"
    const contract = @import("contract");
    const rows = .{
        // fmt, value, conv, flags (`str_real.zc_*`), width, precision, want
        .{ "%.3g", 1234.5678, 'g', @as(u8, 0), @as(usize, 0), @as(i64, 3), "1234.568" },
        .{ "%10.3g", 1234.5678, 'g', 0, 10, 3, "  1234.568" },
        .{ "%.2g", 0.012345, 'g', 0, 0, 2, "0.01" },
        .{ "%.0g", 7.25, 'g', 0, 0, 0, "7" },
        .{ "%.6g", 1.5, 'g', 0, 0, 6, "1.500000" },
        .{ "%#.0g", 3.0, 'g', str_real.zc_alt, 0, 0, "3." },
        .{ "%-8.1G", 2.375, 'G', str_real.zc_left, 8, 1, "2.4     " },
        .{ "%+.2g", 0.5, 'g', str_real.zc_plus, 0, 2, "+0.50" },
        .{ "%g", 1234.5678, 'g', 0, 0, -1, "1234.57" },
    };
    inline for (rows) |row| {
        var b: [64]u8 = undefined;
        try std.testing.expectEqualStrings(row[6], str_real.zCReal(&b, row[1], row[2], row[3], row[4], row[5]));
        const D = struct {
            pub const say_sites = [_]contract.SaySite{.{ .fmt = row[0], .file = "", .line = 0, .nargs = 1 }};
        };
        var store = [_]f64{ 0, row[1] };
        var s: contract.Say = .{ .buf = &store, .len = store.len };
        var out: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&out);
        try contract.formatSay(D, &s, "", &w);
        try std.testing.expectEqualStrings(row[6], w.buffered());
    }
}

test "§9.4.3 zCReal %r: §2.6.2 Table 2-1 engineering notation" {
    var b: [64]u8 = undefined;
    const rows = .{
        .{ 1500.0, @as(i64, -1), "1.5K" },
        .{ 1.0, -1, "1" },
        .{ 999.0, -1, "999" },
        .{ 1000.0, -1, "1K" },
        .{ -2.5e-9, -1, "-2.5n" },
        .{ 0.0, -1, "0" },
        .{ 1.0e15, -1, "1000T" }, // past T, the mantissa absorbs the exponent
        .{ 1500.0, 2, "1.50K" },
    };
    inline for (rows) |row| {
        try std.testing.expectEqualStrings(row[2], str_real.zCReal(&b, row[0], 'r', 0, 0, row[1]));
    }
}

test "§2.6.2 zCReal %r: below the table every shortest digit prints" {
    // Below 1e-18 Table 2-1 has no symbol, so the mantissa absorbs the
    // exponent: 1.5e-20 is 0.015a and 1e-21 is 0.001a. With no precision the
    // kernel means to print every shortest round-trip digit, as it does above.
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("0.015a", str_real.zCReal(&b, 1.5e-20, 'r', 0, 0, -1));
    try std.testing.expectEqualStrings("0.001a", str_real.zCReal(&b, 1e-21, 'r', 0, 0, -1));
}

test "§2.6.2 zCReal %r: a precision keeps the rounded mantissa in [1, 1000)" {
    // 999.96 to one fractional digit is 1000.0, which engineering notation
    // writes 1.0K; 999999 to two is 1.00M, not 1000.00K.
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("1.0K", str_real.zCReal(&b, 999.96, 'r', 0, 0, 1));
    try std.testing.expectEqualStrings("1.00M", str_real.zCReal(&b, 999999.0, 'r', 0, 0, 2));
}

test "§9.5.3 zSFormatRt: a run-time format walks the §9.4.3 conversions" {
    var b: [256]u8 = undefined;
    try std.testing.expectEqualStrings("-42| 3.14|ab|ff", str_format.zSFormatRt(&b, "%d|%5.2f|%s|%x", "top", .{
        @as(i64, -42),
        @as(f64, 3.14159),
        @as([]const u8, "ab"),
        @as(i64, 255),
    }));
    // %m is the scope, %l its library binding, %% a percent; a field width
    // and '-' apply to %m as to any conversion.
    try std.testing.expectEqualStrings("[top][work.top][%][top ][7]", str_format.zSFormatRt(&b, "[%m][%l][%%][%-4m][%d]", "top", .{@as(i64, 7)}));
    // C 7.21.6.1's flags on the integer conversions, and the radices.
    try std.testing.expectEqualStrings("-0042|-42  |+5| 5|10|101|000000ff|ff|A|AB", str_format.zSFormatRt(&b, "%05d|%-5d|%+d|% d|%o|%b|%08x|%h|%c|%s", "m", .{
        @as(i64, -42),
        @as(i64, -42),
        @as(i64, 5),
        @as(i64, 5),
        @as(i64, 8),
        @as(i64, 5),
        @as(i64, 255),
        @as(i64, 255),
        @as(i64, 65),
        @as(i64, 0x4142),
    }));
    // §4.2.1.1 rounds a real half away from zero for an integer conversion,
    // §2.7 reads a string as base 256, and a real conversion takes an integer.
    try std.testing.expectEqualStrings("3 -3 16706 2.000000e+00 A", str_format.zSFormatRt(&b, "%d %d %d %e %c", "m", .{
        @as(f64, 2.5),
        @as(f64, -2.5),
        @as([]const u8, "AB"),
        @as(i64, 2),
        @as(f64, 65.4),
    }));
    // A '%' that ends the string is text, and so is a specification the
    // string ends inside.
    try std.testing.expectEqualStrings("50%", str_format.zSFormatRt(&b, "%d%", "m", .{@as(i64, 50)}));
    try std.testing.expectEqualStrings("1a%5", str_format.zSFormatRt(&b, "%da%5", "m", .{@as(i64, 1)}));
    // "If not enough arguments are supplied ... issue a warning and continue
    // execution": the specification with no argument prints nothing.
    try std.testing.expectEqualStrings("a1bc", str_format.zSFormatRt(&b, "a%db%dc", "m", .{@as(i64, 1)}));
}

test "§3.3 zStringStore/zStrCat/zStrRepeat: NULs dropped, aliasing pieces, N <= 0 copies" {
    var raw = "a\x00b\x00".*;
    try std.testing.expectEqualStrings("ab", str_store.zStringStore(&raw));
    var buf: [8]u8 = undefined;
    @memcpy(buf[0..2], "ab");
    // A piece may be this same site's previous result (`s = {s, "x"}`).
    try std.testing.expectEqualStrings("abx", str_store.zStrCat(&buf, &.{ buf[0..2], "x" }));
    try std.testing.expectEqualStrings("ababab", str_store.zStrRepeat(&buf, 3, "ab"));
    try std.testing.expectEqualStrings("", str_store.zStrRepeat(&buf, 0, "ab"));
    try std.testing.expectEqualStrings("", str_store.zStrRepeat(&buf, -2, "ab"));
    try std.testing.expectEqualStrings("", str_store.zStrRepeat(&buf, 5, ""));
}

test "§9.4.1 zMonitor: nothing before the invocation, then one report per change" {
    var site: str_store.ZMon = .{};
    try std.testing.expect(str_store.zMonitor(&site, &[_]u64{ 1, 2 }, "t") == null);
    try std.testing.expectEqual(@as(f64, 0.0), str_store.zMonitorArm(&site));
    // The first accepted step has no "last accepted step" to equal.
    try std.testing.expectEqualStrings("t", str_store.zMonitor(&site, &[_]u64{ 1, 2 }, "t").?);
    try std.testing.expect(str_store.zMonitor(&site, &[_]u64{ 1, 2 }, "t") == null);
    try std.testing.expectEqualStrings("t", str_store.zMonitor(&site, &[_]u64{ 1, 3 }, "t").?);
    try std.testing.expectEqualStrings("t", str_store.zMonitor(&site, &[_]u64{1}, "t").?);
    try std.testing.expect(str_store.zMonitor(&site, &[_]u64{1}, "t") == null);
    // The latch is as wide as the site watches: past 64 values it still
    // compares, and reports only the change.
    var many: [65]u64 = @splat(0);
    try std.testing.expectEqualStrings("t", str_store.zMonitor(&site, &many, "t").?);
    try std.testing.expect(str_store.zMonitor(&site, &many, "t") == null);
    many[64] = 1;
    try std.testing.expectEqualStrings("t", str_store.zMonitor(&site, &many, "t").?);
}

test "§9.5.3 zSBuf/zSRow: one row per call site and slot, of the size asked" {
    try std.testing.expect(str_store.zSBuf(9001) != str_store.zSBuf(9002));
    try std.testing.expect(str_store.zSBuf(9001) == str_store.zSBuf(9001));
    try std.testing.expectEqual(@as(usize, 4096), str_store.zSBuf(9001).len);
    try std.testing.expectEqual(@as(usize, 100_000), str_store.zSRow(9001, 0, 100_000).len);
    try std.testing.expect(@intFromPtr(str_store.zSRow(9001, 0, 5000)) != @intFromPtr(str_store.zSRow(9001, 1, 5000)));
}

test "§3.3 zStrCat/zStrRepeat: a row past 4096 bytes composes whole" {
    const row = str_store.zSRow(9003, 0, 10_000);
    const a: [4096]u8 = @splat('a');
    const t = str_store.zStrCat(row, &.{ &a, &a, "xy" });
    try std.testing.expectEqual(@as(usize, 8194), t.len);
    try std.testing.expectEqualStrings("xy", t[8192..]);
    // The previous result as a piece of the next (`s = {s, s}`).
    try std.testing.expectEqual(@as(usize, 16388), str_store.zStrCat(str_store.zSRow(9004, 0, 16388), &.{ t, t }).len);
    try std.testing.expectEqual(@as(usize, 9000), str_store.zStrRepeat(row, 3000, "abc").len);
}

test "§9.5.3 zSFormatRt: a width past 4096 fills a row that holds it" {
    const row = str_store.zSRow(9005, 0, 16_000);
    const t = str_format.zSFormatRt(row, "%5000d|%-4999.1f|%-4800l|", "m", .{ @as(i64, 7), @as(f64, 0.25) });
    try std.testing.expectEqual(@as(usize, 5001 + 5000 + 4801), t.len);
    try std.testing.expectEqualStrings("7|0.2", t[4999..5004]);
    try std.testing.expectEqualStrings(" |work.m ", t[9999..10008]);
    // A precision past 4096 is the field's, not a clamp's.
    const p = str_format.zSFormatRt(str_store.zSRow(9006, 0, 6000), "%.5000f", "m", .{@as(f64, 1)});
    try std.testing.expectEqual(@as(usize, 5002), p.len);
}

test "zStrHeldN: a field past 4096 bytes holds its text" {
    const big: [70_000]u8 = @splat('q');
    const h = str_store.zStrHeldN(70_000, &big);
    try std.testing.expectEqual(@as(usize, 70_000), h.get().len);
}

// The next two tests, and the $fseek overflow test below, trapped (an
// overflow) or never returned (a pad loop) before their fix. No `xfail(...)`
// marker can contain a trap or a hang, so they landed with the fix.

test "§9.5.4.2 zScan: the most negative integer, and a width no usize holds" {
    // The accumulation wraps, so "-9223372036854775808" arrives as minInt, and
    // its negation must wrap as well rather than trap.
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), str_scan.zScanI("-9223372036854775808", "%d", 0));
    // A width saturates, and past the input it is the whole input.
    try std.testing.expectEqual(@as(i64, 12), str_scan.zScanI("12", "%99999999999999999999999d", 0));
    try std.testing.expectEqualStrings("ab", str_scan.zScanS("ab", "%99999999999999999999999c", 0));
    try std.testing.expectEqualStrings("ab", str_scan.zScanS("ab cd", "%18446744073709551615s", 0));
}

test "§9.4.3 zCReal: a field wider than the row returns what fits, '-' or not" {
    // The writer drops an overrun ("1.000000" keeps four bytes), and the left
    // pad must not wait for a width the row cannot reach.
    var b: [4]u8 = undefined;
    try std.testing.expectEqualStrings("1.00", str_real.zCReal(&b, 1.0, 'f', 1, 10, -1));
    try std.testing.expectEqualStrings("1.00", str_real.zCReal(&b, 1.0, 'f', 0, 10, -1));
}

// -------------------------------------------------------------------- file

test "§9.5.1/§9.5.2 append writes at the end; r+ reads and writes one position" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var pb: [256]u8 = undefined;
    var rb: [64]u8 = undefined;
    const p = tmpPath(&pb, &tmp, "a.txt");
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "abc" });

    // Table 9-24 "a": the position starts at the end, and a write goes to the
    // end wherever $fseek left it.
    const a = file_k.zFOpen(zc, p, "a", false);
    try std.testing.expect(a != 0);
    try std.testing.expectEqual(@as(i64, 3), file_k.zFTell(zc, a));
    try std.testing.expectEqual(@as(i64, 0), file_k.zFSeek(zc, a, 0, 0));
    try std.testing.expectEqual(@as(i64, 1), file_k.zFPut(zc, a, "d"));
    try std.testing.expectEqual(@as(i64, 4), file_k.zFTell(zc, a));
    // An "a" channel cannot be read: §9.5.4.1 "if an error occurs reading
    // from the file, then code is set to zero", and $ferror says why.
    try std.testing.expectEqual(@as(i64, 0), file_k.zFGets(zc, a));
    try std.testing.expectEqual(@as(i64, 9), file_k.zFError(zc, a));
    _ = file_k.zFClose(zc, a);
    try std.testing.expectEqualStrings("abcd", try tmp.dir.readFile(io, "a.txt", &rb));

    // "r+": one position for both directions.
    const rw = file_k.zFOpen(zc, p, "r+", false);
    try std.testing.expectEqual(@as(i64, 1), file_k.zFPut(zc, rw, "X"));
    try std.testing.expectEqual(@as(i64, 3), file_k.zFGets(zc, rw));
    try std.testing.expectEqualStrings("bcd", file_k.zFLine(zc, 3, rw));
    try std.testing.expect(file_k.zFEof(zc, rw) != 0);
    _ = file_k.zFClose(zc, rw);
    try std.testing.expectEqualStrings("Xbcd", try tmp.dir.readFile(io, "a.txt", &rb));
}

test "§9.5.5 $fseek: absolute, relative, from the end, and refused before the start" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [256]u8 = undefined;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "s.txt", .data = "hello" });
    const r = file_k.zFOpen(zc, tmpPath(&pb, &tmp, "s.txt"), "r", false);
    try std.testing.expect(r != 0);
    try std.testing.expectEqual(@as(i64, 0), file_k.zFSeek(zc, r, 2, 0));
    try std.testing.expectEqual(@as(i64, 2), file_k.zFTell(zc, r));
    try std.testing.expectEqual(@as(i64, 0), file_k.zFSeek(zc, r, 1, 1));
    try std.testing.expectEqual(@as(i64, 3), file_k.zFTell(zc, r));
    try std.testing.expectEqual(@as(i64, 0), file_k.zFSeek(zc, r, -1, 2));
    try std.testing.expectEqual(@as(i64, 4), file_k.zFTell(zc, r));
    // "If an error occurs repositioning the file, then code is set to -1":
    // the position stays where it was, and $ferror names the cause.
    try std.testing.expectEqual(@as(i64, -1), file_k.zFSeek(zc, r, -5, 1));
    try std.testing.expectEqual(@as(i64, 4), file_k.zFTell(zc, r));
    try std.testing.expectEqual(@as(i64, 22), file_k.zFError(zc, r));
    try std.testing.expectEqual(@as(i64, 'o'), file_k.zFGetc(zc, r));
    // Past the end is a position like any other; reading there is EOF, and
    // the next reposition clears it.
    try std.testing.expectEqual(@as(i64, 0), file_k.zFSeek(zc, r, 10, 0));
    try std.testing.expectEqual(@as(i64, -1), file_k.zFGetc(zc, r));
    try std.testing.expect(file_k.zFEof(zc, r) != 0);
    try std.testing.expectEqual(@as(i64, 0), file_k.zFSeek(zc, r, 0, 0));
    try std.testing.expectEqual(@as(i64, 0), file_k.zFEof(zc, r));
    try std.testing.expectEqual(@as(i64, 'h'), file_k.zFGetc(zc, r));
    _ = file_k.zFClose(zc, r);
}

test "§9.5.5 $fseek: an offset whose sum overflows is refused, not trapped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [256]u8 = undefined;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "o.txt", .data = "hello" });
    const r = file_k.zFOpen(zc, tmpPath(&pb, &tmp, "o.txt"), "r", false);
    try std.testing.expectEqual(@as(i64, 0), file_k.zFSeek(zc, r, 2, 0));
    // 2 + maxInt and 5 + maxInt name no position: code -1, EINVAL, and the
    // position stays.
    try std.testing.expectEqual(@as(i64, -1), file_k.zFSeek(zc, r, std.math.maxInt(i64), 1));
    try std.testing.expectEqual(@as(i64, -1), file_k.zFSeek(zc, r, std.math.maxInt(i64), 2));
    try std.testing.expectEqual(@as(i64, 2), file_k.zFTell(zc, r));
    try std.testing.expectEqual(@as(i64, 22), file_k.zFError(zc, r));
    _ = file_k.zFClose(zc, r);
}

test "§9.5.1 a descriptor the table does not hold answers each call's failure value" {
    const fd_bit: i64 = 1 << 31;
    const nowhere = fd_bit | 40; // past the thirty channels
    try std.testing.expectEqual(@as(i64, -1), file_k.zFTell(zc, nowhere));
    try std.testing.expectEqual(@as(i64, -1), file_k.zFTell(zc, fd_bit | 1)); // STDOUT is no table row
    try std.testing.expectEqual(@as(i64, -1), file_k.zFSeek(zc, nowhere, 0, 0));
    try std.testing.expectEqual(@as(i64, -1), file_k.zFGetc(zc, nowhere));
    try std.testing.expectEqual(@as(i64, -1), file_k.zFUngetc(zc, 'a', nowhere));
    try std.testing.expectEqual(@as(i64, 0), file_k.zFEof(zc, nowhere));
    try std.testing.expectEqualStrings("", file_k.zFLine(zc, 5, nowhere));
    try std.testing.expectEqual(@as(i64, 0), file_k.zFClose(zc, nowhere));
    // An mcd bit whose channel is closed names nothing either.
    try std.testing.expectEqual(@as(i64, -1), file_k.zFTell(zc, 1 << 20));
    // §9.5.1: a failed open returns 0; a call on that 0 is refused (EBADF).
    try std.testing.expectEqual(@as(i64, 0), file_k.zFPut(zc, 0, "x"));
    try std.testing.expectEqual(@as(i64, 9), file_k.zFError(zc, 0));
    try std.testing.expectEqual(@as(i64, 0), file_k.zFGets(zc, 0));
    try std.testing.expectEqualStrings("", file_k.zFWindow(zc, 0));
    try std.testing.expectEqual(@as(i64, 0), file_k.zFFlush(0));
    // §9.5.7: a description for every errno the table sets, "" for none.
    try std.testing.expectEqualStrings("", file_k.zFErrorStr(0, 0));
    try std.testing.expectEqualStrings("no such file or directory", file_k.zFErrorStr(2, 0));
    try std.testing.expectEqualStrings("bad file descriptor", file_k.zFErrorStr(9, 0));
    try std.testing.expectEqualStrings("invalid argument", file_k.zFErrorStr(22, 0));
    try std.testing.expectEqualStrings("too many open files", file_k.zFErrorStr(24, 0));
    try std.testing.expectEqualStrings("i/o error", file_k.zFErrorStr(5, 0));
}

test "IEEE 1364 §17.2.4.1 $ungetc needs a byte to step back over, and holds 16" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [256]u8 = undefined;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "u.txt", .data = "0123456789abcdefghij" });
    const r = file_k.zFOpen(zc, tmpPath(&pb, &tmp, "u.txt"), "r", false);
    try std.testing.expectEqual(@as(i64, -1), file_k.zFUngetc(zc, 'x', r)); // position 0
    for (0..17) |_| _ = file_k.zFGetc(zc, r);
    for (0..16) |j| try std.testing.expectEqual(@as(i64, 0), file_k.zFUngetc(zc, @as(i64, 'A') + @as(i64, @intCast(j)), r));
    try std.testing.expectEqual(@as(i64, -1), file_k.zFUngetc(zc, 'Z', r)); // a 17th
    try std.testing.expectEqual(@as(i64, 1), file_k.zFTell(zc, r));
    // Last pushed, first read; then the file resumes after the bytes covered.
    var k: usize = 16;
    while (k > 0) {
        k -= 1;
        try std.testing.expectEqual(@as(i64, 'A') + @as(i64, @intCast(k)), file_k.zFGetc(zc, r));
    }
    try std.testing.expectEqual(@as(i64, 'h'), file_k.zFGetc(zc, r));
    _ = file_k.zFClose(zc, r);
}

test "§9.5.1 thirty mcd channels; a file descriptor is not limited by them" {
    fileOver(std.testing.allocator);
    defer fileDone();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [256]u8 = undefined;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "e.txt", .data = "e" });
    const p = tmpPath(&pb, &tmp, "e.txt");
    // The mcd shape: bits 1..30, then EMFILE (§9.5.1's 31 with standard output).
    var mcds: [30]i64 = undefined;
    for (&mcds, 1..) |*m, b| {
        m.* = file_k.zFOpen(zc, p, "r", true);
        try std.testing.expectEqual(@as(i64, 1) << @intCast(b), m.*);
    }
    try std.testing.expectEqual(@as(i64, 0), file_k.zFOpen(zc, p, "r", true));
    try std.testing.expectEqual(@as(i64, 24), file_k.zFError(zc, 0));
    // The fd shape keeps opening past the thirty, numbered from 3.
    var fds: [100]i64 = undefined;
    for (&fds, 3..) |*fd, c| {
        fd.* = file_k.zFOpen(zc, p, "r", false);
        try std.testing.expectEqual((@as(i64, 1) << 31) | @as(i64, @intCast(c)), fd.*);
    }
    try std.testing.expectEqual(@as(i64, 'e'), file_k.zFGetc(zc, fds[99]));
    // "The $fopen function shall reuse channels that have been closed."
    _ = file_k.zFClose(zc, fds[7]);
    try std.testing.expectEqual(fds[7], file_k.zFOpen(zc, p, "r", false));
    _ = file_k.zFClose(zc, mcds[4]);
    try std.testing.expectEqual(mcds[4], file_k.zFOpen(zc, p, "r", true));
    for (fds) |fd| _ = file_k.zFClose(zc, fd);
    for (mcds) |m| _ = file_k.zFClose(zc, m);
}

test "§9.5.1 an open that cannot get memory fails: $fopen 0, $ferror 12" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [256]u8 = undefined;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "n.txt", .data = "n" });
    const p = tmpPath(&pb, &tmp, "n.txt");
    // No memory at all: not even the table.
    var none = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    fileOver(none.allocator());
    try std.testing.expectEqual(@as(i64, 0), file_k.zFOpen(zc, p, "r", false));
    try std.testing.expectEqual(@as(i64, 12), file_k.zFError(zc, 0));
    try std.testing.expectEqualStrings("out of memory", file_k.zFErrorStr(12, 0));
    fileDone();
    // The table, but no row to remember a path opened for writing.
    var one = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    fileOver(one.allocator());
    defer fileDone();
    var wb: [256]u8 = undefined;
    try std.testing.expectEqual(@as(i64, 0), file_k.zFOpen(zc, tmpPath(&wb, &tmp, "w.txt"), "w", true));
    try std.testing.expectEqual(@as(i64, 12), file_k.zFError(zc, 0));
    // A read open on a row the table has needs no memory.
    const r = file_k.zFOpen(zc, p, "r", true);
    try std.testing.expect(r != 0);
    _ = file_k.zFClose(zc, r);
}

test "§9.5.1.1 every distinct path opened for writing is remembered (past 64)" {
    fileOver(std.testing.allocator);
    defer fileDone();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [256]u8 = undefined;
    var nb: [32]u8 = undefined;
    for (0..100) |k| {
        const w = file_k.zFOpen(zc, tmpPath(&pb, &tmp, try std.mem.print(&nb, "w{d}.txt", .{k})), "w", false);
        try std.testing.expect(w != 0);
        _ = file_k.zFPut(zc, w, "ab");
        _ = file_k.zFClose(zc, w);
    }
    // A later analysis appends to the first path, which a 64-row table forgot.
    file_k.zFNewAnalysis(
        zc,
    );
    const w = file_k.zFOpen(zc, tmpPath(&pb, &tmp, "w0.txt"), "w", false);
    _ = file_k.zFPut(zc, w, "c");
    _ = file_k.zFClose(zc, w);
    var rb: [8]u8 = undefined;
    try std.testing.expectEqualStrings("abc", try tmp.dir.readFile(std.testing.io, "w0.txt", &rb));
}

test "§9.5.4.1 $fgets returns a line of any length whole" {
    fileOver(std.testing.allocator);
    defer fileDone();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [256]u8 = undefined;
    const long = try std.testing.allocator.alloc(u8, 10001);
    defer std.testing.allocator.free(long);
    @memset(long, 'x');
    long[10000] = '\n';
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "l.txt", .data = long });
    const r = file_k.zFOpen(zc, tmpPath(&pb, &tmp, "l.txt"), "r", false);
    try std.testing.expectEqual(@as(i64, 10001), file_k.zFGets(zc, r));
    try std.testing.expectEqualStrings(long, file_k.zFLine(zc, 10001, r));
    try std.testing.expectEqual(@as(i64, 10001), file_k.zFTell(zc, r));
    // The next read finds the end: nothing transferred, EOF detected.
    try std.testing.expectEqual(@as(i64, 0), file_k.zFGets(zc, r));
    try std.testing.expect(file_k.zFEof(zc, r) != 0);
    _ = file_k.zFClose(zc, r);
}

test "§9.5.4.2 $fscanf widens its window until the scan stops inside it" {
    fileOver(std.testing.allocator);
    defer fileDone();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [256]u8 = undefined;
    // 9000 spaces before the field: three of the first 4096-byte windows.
    var data: [9003]u8 = undefined;
    @memset(data[0..9000], ' ');
    @memcpy(data[9000..], "42\n");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "w.txt", .data = &data });
    const r = file_k.zFOpen(zc, tmpPath(&pb, &tmp, "w.txt"), "r", false);
    // cg_display's loop: scan, and again over a wider window while it asks.
    var rounds: usize = 0;
    const n = while (true) : (rounds += 1) {
        const sc = str_scan.zScan(file_k.zFWindow(zc, r), "%d", 0);
        if (file_k.zFMore(zc, r, sc.used)) continue;
        try std.testing.expectEqual(@as(i64, 42), sc.i);
        break file_k.zFTake(zc, r, sc.n, @intCast(sc.used));
    };
    try std.testing.expectEqual(@as(i64, 1), n);
    try std.testing.expect(rounds >= 2);
    try std.testing.expectEqual(@as(i64, 9002), file_k.zFTell(zc, r));
    _ = file_k.zFClose(zc, r);
}

test "§9.5.1.1 a write-mode reopen truncates within an analysis and appends across them" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var pb: [256]u8 = undefined;
    var rb: [64]u8 = undefined;
    const p = tmpPath(&pb, &tmp, "w.txt");
    const put = struct {
        fn f(path: []const u8, text: []const u8) void {
            const w = file_k.zFOpen(zc, path, "w", false);
            _ = file_k.zFPut(zc, w, text);
            _ = file_k.zFClose(zc, w);
        }
    }.f;
    put(p, "ab");
    put(p, "x"); // the same analysis: C's truncate
    try std.testing.expectEqualStrings("x", try tmp.dir.readFile(io, "w.txt", &rb));
    file_k.zFNewAnalysis(
        zc,
    );
    // "Content written from the following analyses shall be appended".
    put(p, "yz");
    try std.testing.expectEqualStrings("xyz", try tmp.dir.readFile(io, "w.txt", &rb));
    // Within the second analysis, a reopen truncates to what the first left.
    put(p, "q");
    try std.testing.expectEqualStrings("xq", try tmp.dir.readFile(io, "w.txt", &rb));
}

test "§9.5.1 an OR of mcds writes to every channel it names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var pb1: [256]u8 = undefined;
    var pb2: [256]u8 = undefined;
    var rb: [64]u8 = undefined;
    const m1 = file_k.zFOpen(zc, tmpPath(&pb1, &tmp, "m1.txt"), "w", true);
    const m2 = file_k.zFOpen(zc, tmpPath(&pb2, &tmp, "m2.txt"), "w", true);
    try std.testing.expect(m1 != 0 and m2 != 0 and m1 & m2 == 0);
    try std.testing.expectEqual(@as(i64, 2), file_k.zFPut(zc, m1 | m2, "hi"));
    try std.testing.expectEqual(@as(i64, 0), file_k.zFClose(zc, m1 | m2));
    try std.testing.expectEqualStrings("hi", try tmp.dir.readFile(io, "m1.txt", &rb));
    try std.testing.expectEqualStrings("hi", try tmp.dir.readFile(io, "m2.txt", &rb));
    // One $fclose of the OR freed both channels.
    try std.testing.expectEqual(@as(i64, -1), file_k.zFTell(zc, m1));
    try std.testing.expectEqual(@as(i64, -1), file_k.zFTell(zc, m2));
}

test "§9.5 zFKeep: a call site's result lands in its own slot" {
    var slots: [2]i64 = .{ 0, 0 };
    try std.testing.expectEqual(@as(i64, 5), file_k.zFKeep(&slots[0], 5));
    try std.testing.expectEqualSlices(i64, &.{ 5, 0 }, &slots);
}

test "§9.5.1 two tables number their descriptors alike and share no channel" {
    // A device keeps one table per instance: each instance's first fd is
    // §9.5.1's first free number, 3, however many the other opened.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [256]u8 = undefined;
    var a: @import("kernels").file_table.ZfTable = .{};
    var b: @import("kernels").file_table.ZfTable = .{};
    defer file_k.zFFreeAll(&a);
    defer file_k.zFFreeAll(&b);
    const fd3: i64 = (1 << 31) | 3;
    try std.testing.expectEqual(fd3, file_k.zFOpen(&a, tmpPath(&pb, &tmp, "a.txt"), "w", false));
    try std.testing.expectEqual(fd3 + 1, file_k.zFOpen(&a, tmpPath(&pb, &tmp, "a2.txt"), "w", false));
    try std.testing.expectEqual(fd3, file_k.zFOpen(&b, tmpPath(&pb, &tmp, "b.txt"), "w", false));
    try std.testing.expectEqual(@as(i64, 2), file_k.zFPut(&a, fd3, "a\n"));
    try std.testing.expectEqual(@as(i64, 2), file_k.zFPut(&b, fd3, "b\n"));
    // `b` never opened fd 4.
    try std.testing.expectEqual(@as(i64, -1), file_k.zFTell(&b, fd3 + 1));
    var rb: [8]u8 = undefined;
    try std.testing.expectEqualStrings("a\n", try tmp.dir.readFile(std.testing.io, "a.txt", &rb));
    try std.testing.expectEqualStrings("b\n", try tmp.dir.readFile(std.testing.io, "b.txt", &rb));
}

test "§9.5.4.2 $fscanf consumes exactly what matched, and only an EOF scan sets $feof" {
    // The composition cg_display emits: scan the unread window, then advance
    // by `ZScan.used`.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [256]u8 = undefined;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.txt", .data = "12 34\n" });
    const r = file_k.zFOpen(zc, tmpPath(&pb, &tmp, "f.txt"), "r", false);
    const Step = struct { n: i64, used: usize, pos: i64 };
    for ([_]Step{
        .{ .n = 1, .used = 2, .pos = 2 }, // "12"; the space is left unread
        .{ .n = 1, .used = 3, .pos = 5 }, // " 34"; the newline is left unread
        .{ .n = -1, .used = 1, .pos = 6 }, // white space to the end: EOF
    }) |want| {
        const sc = str_scan.zScan(file_k.zFWindow(zc, r), "%d", 0);
        try std.testing.expectEqual(want.n, sc.n);
        try std.testing.expectEqual(want.used, sc.used);
        try std.testing.expectEqual(want.n, file_k.zFTake(zc, r, sc.n, @intCast(sc.used)));
        try std.testing.expectEqual(want.pos, file_k.zFTell(zc, r));
        try std.testing.expectEqual(@as(i64, @intFromBool(want.n < 0)), file_k.zFEof(zc, r));
    }
    _ = file_k.zFClose(zc, r);
}

// ------------------------------------------------------------ absdelay ring

test "§4.5.7 a ring whose oldest sample leaves the window first is a plain ring, bit for bit" {
    var ta: [64]f64 = @splat(0);
    var va: [64]f64 = @splat(0);
    var tb: [64]f64 = @splat(0);
    var vb: [64]f64 = @splat(0);
    var ha: u64 = 0;
    var hb: u64 = 0;
    // td = 10 steps of a 64-sample ring: the window never needs the oldest.
    for (0..1000) |k| {
        const t: f64 = @floatFromInt(k);
        histStep("plain_a", &ta, &va, &ha, t, @sin(t / 20.0), 10.0, true);
        histStep("plain_b", &tb, &vb, &hb, t, @sin(t / 20.0), 10.0, false);
        try std.testing.expectEqual(hb, ha);
        const q = t - 10.0 + 0.25;
        try std.testing.expectEqual(hist_k.zHistAt(&tb, &vb, hb, q), hist_k.zHistAt(&ta, &va, ha, q));
    }
}

test "§4.5.7 a full ring thins its older half and keeps its window: against the full history" {
    // A 64-sample ring under a 200-step window: plain, it would forget the
    // lookback after 64 steps. sin(t/20) has |x''| <= 1/400, so linear
    // interpolation over samples g apart is within g^2/8/400 of the full
    // history, whose samples sit on every step (td is a whole number of
    // steps, so the reference is the exact sample).
    var ts: [64]f64 = @splat(0);
    var vs: [64]f64 = @splat(0);
    var head: u64 = 0;
    const w = 200.0;
    var thinned = false;
    for (0..3000) |k| {
        const t: f64 = @floatFromInt(k);
        histStep("thin", &ts, &vs, &head, t, @sin(t / 20.0), w, true);
        const n = @min(head, ts.len);
        const oldest: usize = if (head > ts.len) @intCast(head % ts.len) else 0;
        if (k >= ts.len and head < ts.len) thinned = true;
        if (t < w) continue;
        // The window is covered: the lookback is never older than the ring.
        try std.testing.expect(ts[oldest] <= t - w);
        var gap: f64 = 0;
        for (1..n) |i| gap = @max(gap, ts[(oldest + i) % ts.len] - ts[(oldest + i - 1) % ts.len]);
        const want = @sin((t - w) / 20.0);
        try std.testing.expect(@abs(hist_k.zHistAt(&ts, &vs, head, t - w) - want) <= gap * gap / 8.0 / 400.0 + 1e-12);
    }
    try std.testing.expect(thinned);
}

test "§4.5.7 a thinned ring answers a ramp exactly, and its newest half keeps every step" {
    var ts: [16]f64 = @splat(0);
    var vs: [16]f64 = @splat(0);
    var head: u64 = 0;
    for (0..17) |k| histStep("ramp", &ts, &vs, &head, @floatFromInt(k), 3.0 * @as(f64, @floatFromInt(k)) + 1.0, 100.0, true);
    // Full inside the window at the push of 16: the older half kept 0, 2, 4,
    // 6; 8..15 whole; then 16.
    try std.testing.expectEqual(@as(u64, 13), head);
    try std.testing.expectEqualSlices(f64, &.{ 0, 2, 4, 6, 8, 9, 10, 11, 12, 13, 14, 15, 16 }, ts[0..13]);
    try std.testing.expectEqual(@as(f64, 3.0 * 5.0 + 1.0), hist_k.zHistAt(&ts, &vs, head, 5.0));
    try std.testing.expectEqual(@as(f64, 3.0 * 0.5 + 1.0), hist_k.zHistAt(&ts, &vs, head, 0.5));
}

test "§4.5.7 zHistRevert undoes a thinning push exactly, at every ring size and offset" {
    var buf_t: [37]f64 = undefined;
    var buf_v: [37]f64 = undefined;
    for (8..38) |n| for (0..n) |o| {
        const ts = buf_t[0..n];
        const vs = buf_v[0..n];
        // A full ring whose oldest sample sits at slot o (head = n + o).
        for (0..n) |i| {
            const age = (i + n - o) % n; // 0 = oldest
            ts[i] = @floatFromInt(age);
            vs[i] = 10.0 * @as(f64, @floatFromInt(age)) + 0.5;
        }
        const saved_t = buf_t;
        const saved_v = buf_v;
        var head: u64 = n + o;
        // stateCtl(.commit): the two slots a push may overwrite.
        const t0 = ts[@intCast(head % n)];
        const v0 = vs[@intCast(head % n)];
        const t1 = ts[@intCast((head + 1) % n)];
        const v1 = vs[@intCast((head + 1) % n)];
        histStep("revert", ts, vs, &head, @floatFromInt(n), 99.0, 1e9, true);
        try std.testing.expect(head == hist_k.zhKept(n) + 1);
        // The live samples are in time order.
        for (1..@intCast(head)) |i| try std.testing.expect(ts[i] > ts[i - 1]);
        hist_k.zHistRevert(ts, vs, n + o, head, t0, v0, t1, v1);
        try std.testing.expectEqualSlices(f64, saved_t[0..n], ts);
        try std.testing.expectEqualSlices(f64, saved_v[0..n], vs);
    };
}

// ---- IEEE 1364 §5 wide integers (`wide_kernels.zig`) --------------------------
// Two oracles. Up to `zw_native_max + 64` bits, the limb algorithms (`zwL`,
// what a device runs past the threshold) against the native `uN` operators
// (what it runs below): every width, every operation, random operands and the
// edge patterns (0, 1, all ones, the sign bit alone). Past that, the `zw*`
// entry points against `std.math.big`'s exact integers.

test "IEEE 1364 §5 wide integers: the limb algorithms equal native uN at every width to the threshold + 64" {
    var prng = std.Random.DefaultPrng.init(0x1364_0504);
    inline for (1..wide.zw_native_max + 65) |n| try wideNativeVsLimbs(n, prng.random());
}

test "IEEE 1364 §5 wide integers: the zw entry points equal std.math.big past the threshold" {
    var prng = std.Random.DefaultPrng.init(0x1364_0505);
    inline for (.{ wide.zw_native_max + 1, 300, 1000, 4100 }) |n| try wideAgainstBig(n, prng.random());
}

test "IEEE 1364 §4.8.2 wide integers: a real rounds half away from zero to its low n bits" {
    inline for (.{ 8, 40, 64, 72, 300 }) |n| {
        const W = wide.ZW(n);
        try std.testing.expect(wide.zwEq(n, wide.zwFromReal(n, 2.5), wide.zwLeaf(n, 3)));
        try std.testing.expect(wide.zwEq(n, wide.zwFromReal(n, -2.5), wide.zwResize(n, 64, true, wide.zwLeaf(64, -3))));
        try std.testing.expect(wide.zwEq(n, wide.zwFromReal(n, std.math.nan(f64)), wide.zwZero(n)));
        // 2^70 + 2^18 as a double, then its low n bits.
        const x: f64 = 0x1p70 + 0x1p18;
        const want: W = wide.zwAdd(n, wide.zwShl(n, wide.zwLeaf(n, 1), 32, 70), wide.zwShl(n, wide.zwLeaf(n, 1), 32, 18));
        try std.testing.expect(wide.zwEq(n, wide.zwFromReal(n, x), want));
        try std.testing.expect(wide.zwEq(n, wide.zwFromReal(n, -x), wide.zwNeg(n, want)));
        try std.testing.expectEqual(@as(f64, -3), wide.zwToReal(n, true, wide.zwResize(n, 64, true, wide.zwLeaf(64, -3))));
    }
}

test "IEEE 1364 Table 5-6 wide integers: the power edge cases" {
    inline for (.{ 40, 300 }) |n| {
        const one = wide.zwLeaf(n, 1);
        const m1 = wide.zwNot(n, wide.zwZero(n));
        try std.testing.expect(wide.zwEq(n, wide.zwPow(n, true, wide.zwZero(n), 8, false, 0), one));
        try std.testing.expect(wide.zwEq(n, wide.zwPow(n, true, m1, 8, true, @as(u8, @bitCast(@as(i8, -3)))), m1));
        try std.testing.expect(wide.zwEq(n, wide.zwPow(n, true, m1, 8, true, @as(u8, @bitCast(@as(i8, -4)))), one));
        try std.testing.expect(wide.zwEq(n, wide.zwPow(n, true, wide.zwLeaf(n, 3), 8, true, @as(u8, @bitCast(@as(i8, -1)))), wide.zwZero(n)));
        try std.testing.expect(wide.zwEq(n, wide.zwPow(n, false, wide.zwLeaf(n, 3), 8, false, 4), wide.zwLeaf(n, 81)));
    }
}

test "IEEE 1364 §5 wide integers: the bitwise, reduction, shift and conversion entry points" {
    const expect = std.testing.expect;
    inline for (.{ 40, 200 }) |n| {
        const one = wide.zwLeaf(n, 1);
        const top = wide.zwShl(n, one, 32, n - 1);
        const x = wide.zwOr(n, top, wide.zwLeaf(n, 5)); // 2^(n-1) + 5
        const ones = wide.zwNot(n, wide.zwZero(n));
        try expect(wide.zwEq(n, wide.zwAnd(n, x, wide.zwLeaf(n, 7)), wide.zwLeaf(n, 5)));
        try expect(wide.zwIsZero(n, wide.zwXor(n, x, x)));
        try expect(wide.zwEq(n, wide.zwXnor(n, x, x), ones));
        // §5.1.11: every bit one, and the parity of the one bits.
        try expect(wide.zwAll(n, ones));
        try expect(!wide.zwAll(n, x));
        try expect(wide.zwParity(n, ones) == (n % 2 == 1));
        try expect(wide.zwParity(n, x)); // three one bits: 2^(n-1), 4 and 1
        try expect(!wide.zwParity(n, wide.zwLeaf(n, 3)));
        // §5.1.12 `>>>` of a negative pattern fills with ones, `>>` with zeros.
        try expect(wide.zwEq(n, wide.zwShr(n, true, x, 32, n - 1), ones));
        try expect(wide.zwEq(n, wide.zwShr(n, false, x, 32, n - 1), one));
        // A count no u64 holds (a 200-bit 2^150) shifts every bit out.
        const huge = wide.zwShl(200, wide.zwLeaf(200, 1), 32, 150);
        try expect(wide.zwIsZero(n, wide.zwShl(n, x, 200, huge)));
        try expect(wide.zwIsZero(n, wide.zwShr(n, false, x, 200, huge)));
        try expect(wide.zwEq(n, wide.zwShr(n, true, x, 200, huge), ones));
    }
    // §7.3.1 a select reads at most 32 bits, zero- or sign-extended.
    try std.testing.expectEqual(@as(i64, -3), wide.zwInt(40, true, wide.zwLeaf(40, -3)));
    try std.testing.expectEqual(@as(i64, (1 << 40) - 3), wide.zwInt(40, false, wide.zwLeaf(40, -3)));
    // A discrete input's words keep their low 32 bits, cut at the width.
    try std.testing.expectEqual(@as(wide.ZW(40), 0x05_ffff_ffff), wide.zwWords(40, .{ -1, 0x1_0000_0005 }));
    try std.testing.expectEqual(@as(wide.ZW(40), (1 << 40) - 1), wide.zwConst(40, .{ 0xffff_ffff, 0xffff_ffff }));
    try std.testing.expect(wide.zwEq(200, wide.zwWords(200, @splat(-1)), wide.zwNot(200, wide.zwZero(200))));
}

test "§4.5.7 zAbsdelay: DC and an empty ring pass the input, a short delay interpolates toward it" {
    var ts: [8]f64 = @splat(0);
    var vs: [8]f64 = @splat(0);
    var head: u64 = 0;
    const vin: Dual = .{ .v = 40.0, .d = 1.0 };
    // Nothing accepted yet: the input, derivative and all.
    try std.testing.expectEqual(vin, hist_k.zAbsdelay(Dual, vin, &ts, &vs, head, 1.0, 1.0, 0.5));
    for (0..4) |k| hist_k.zHistPush(&ts, &vs, &head, @floatFromInt(k), 10.0 * @as(f64, @floatFromInt(k)));
    // A static point (dt <= 0) is the input.
    try std.testing.expectEqual(vin, hist_k.zAbsdelay(Dual, vin, &ts, &vs, head, 4.0, 0.0, 1.5));
    // Inside the history: the recorded value, a constant.
    try std.testing.expectEqual(Dual{ .v = 25.0, .d = 0.0 }, hist_k.zAbsdelay(Dual, vin, &ts, &vs, head, 4.0, 1.0, 1.5));
    // td shorter than the step: halfway from the newest sample (30) to the
    // input (40), carrying half the input's derivative.
    try std.testing.expectEqual(Dual{ .v = 35.0, .d = 0.5 }, hist_k.zAbsdelay(Dual, vin, &ts, &vs, head, 4.0, 1.0, 0.5));
    // A negative td reads the future: clamped to the input itself.
    try std.testing.expectEqual(vin, hist_k.zAbsdelay(Dual, vin, &ts, &vs, head, 4.0, 1.0, -1.0));
    // No time since the newest sample: the input, not a 0/0.
    try std.testing.expectEqual(vin, hist_k.zAbsdelay(Dual, vin, &ts, &vs, head, 3.0, 1.0, -0.5));
    // A NaN delay answers NaN, never a sample from the wrong time.
    try std.testing.expect(std.math.isNan(hist_k.zAbsdelay(Dual, vin, &ts, &vs, head, 4.0, 1.0, std.math.nan(f64)).v));
}
