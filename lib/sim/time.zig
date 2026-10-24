//! Exact decimal timescale factors and integer digital delay counts, and an
//! analog time as the digital tick it falls in.
//! IEEE 1364-2005 §§4.8, 4.8.2, 9.7.1, 17.7.1, 17.7.2 and 19.8; VAMS §5.10.3.1,
//! §7.3.6.5, §9.10.
const std = @import("std");

/// Why a timescale or a delay has no tick count. `InvalidQuantum`: not one
/// of §19.8's 18 operands. `PrecisionTooCoarse`: a module's precision is
/// coarser than its unit, which §19.8 forbids. `GlobalPrecisionTooCoarse`:
/// the tick is coarser than a module's precision, which only a caller that
/// passes something other than the design's finest precision causes.
/// `DelayOverflow`: more than 2^64 - 1 ticks. `NonFiniteDelay` and
/// `NegativeRealDelay`: a real delay that names no tick.
pub const Error = error{
    InvalidQuantum,
    PrecisionTooCoarse,
    GlobalPrecisionTooCoarse,
    DelayOverflow,
    NonFiniteDelay,
    NegativeRealDelay,
};

/// Decimal exponent in seconds, including all 18 legal directive operands.
pub const Quantum = enum(i5) {
    fs = -15,
    ten_fs = -14,
    hundred_fs = -13,
    ps = -12,
    ten_ps = -11,
    hundred_ps = -10,
    ns = -9,
    ten_ns = -8,
    hundred_ns = -7,
    us = -6,
    ten_us = -5,
    hundred_us = -4,
    ms = -3,
    ten_ms = -2,
    hundred_ms = -1,
    s = 0,
    ten_s = 1,
    hundred_s = 2,

    /// The quantum whose value in seconds is exactly `seconds`, one of the
    /// preprocessor's canonical binary64 constants; error.InvalidQuantum for
    /// any other value, however close.
    pub fn fromSeconds(seconds: f64) Error!Quantum {
        const decades = [_]f64{
            1e-15, 1e-14, 1e-13, 1e-12, 1e-11, 1e-10,
            1e-9,  1e-8,  1e-7,  1e-6,  1e-5,  1e-4,
            1e-3,  1e-2,  1e-1,  1e0,   1e1,   1e2,
        };
        for (decades, 0..) |value, i| {
            if (seconds == value) return @fromBackingInt(@intCast(@as(i6, @intCast(i)) - 15));
        }
        return error.InvalidQuantum;
    }
};

/// A module's §19.8 time scale as two exact powers of ten: precision steps
/// per time unit, and global ticks per precision step. Each is at most
/// 10^17 (all 18 operands apart), so `u57` holds it.
pub const Scale = struct {
    local_per_unit: u57,
    global_per_local: u57,

    /// The scale of a module written under `` `timescale unit/precision ``,
    /// counted in ticks of `global`, the design's finest precision (§19.8).
    /// `PrecisionTooCoarse` when `precision` is coarser than `unit`,
    /// `GlobalPrecisionTooCoarse` when `global` is coarser than `precision`.
    pub fn init(unit: Quantum, precision: Quantum, global: Quantum) Error!Scale {
        const u: i6 = @backingInt(unit);
        const p: i6 = @backingInt(precision);
        const g: i6 = @backingInt(global);
        if (p > u) return error.PrecisionTooCoarse;
        if (g > p) return error.GlobalPrecisionTooCoarse;
        return .{
            .local_per_unit = std.math.pow(u57, 10, @intCast(u - p)),
            .global_per_local = std.math.pow(u57, 10, @intCast(p - g)),
        };
    }

    /// `value` time units as global ticks, exactly; `DelayOverflow` past
    /// 2^64 - 1 ticks.
    pub fn unsignedDelay(self: Scale, value: u64) Error!u64 {
        return multiply(try multiply(value, self.local_per_unit), self.global_per_local);
    }

    /// Procedural delay: negative integral values are unsigned 64-bit time values
    /// (§9.7.1), not zero. `DelayOverflow` past 2^64 - 1 ticks.
    pub fn signedDelay(self: Scale, value: i64) Error!u64 {
        return self.unsignedDelay(@bitCast(value));
    }

    /// `value` time units rounded half away from zero to the module's
    /// precision, then scaled exactly to global ticks. `NonFiniteDelay` for
    /// an infinity or NaN, `NegativeRealDelay` below 0 (-0.0 is 0),
    /// `DelayOverflow` past 2^64 - 1 ticks.
    pub fn realDelay(self: Scale, value: f64) Error!u64 {
        if (!std.math.isFinite(value)) return error.NonFiniteDelay;
        if (value < 0) return error.NegativeRealDelay;
        return multiply(try roundedLocal(value, self.local_per_unit), self.global_per_local);
    }

    /// Returns `ticks` in the invoking module's time unit, rounded half away
    /// from zero: IEEE 1364-2005 §17.7.1 `$time`, "scaled to the time unit of
    /// the module that invoked it and rounded". The rule is `realDelay`'s, so
    /// a `#0.5` under `10ns/100ps` reports 1, not 0. Exact for every
    /// `ticks`, up to 2^64 - 1.
    pub fn unitsAt(self: Scale, ticks: u64) u64 {
        const local = ticks / self.global_per_local;
        const per: u64 = self.local_per_unit;
        // `(local + per / 2) / per` wraps within per / 2 of 2^64. The
        // remainder decides instead: `per` is a power of ten, so 1 (never a
        // half) or even, and twice the remainder stays below 2 * 10^17.
        return local / per + @intFromBool(local % per * 2 >= per);
    }

    /// `unitsAt` without the rounding (IEEE 1364-2005 §17.7.2 `$realtime`).
    /// Ticks below the module's precision are dropped first, as `unitsAt`
    /// drops them.
    pub fn realAt(self: Scale, ticks: u64) f64 {
        const local: f64 = @floatFromInt(ticks / self.global_per_local);
        return local / @as(f64, @floatFromInt(self.local_per_unit));
    }
};

/// VAMS §9.10 `$abstime` of `ticks` ticks of 10^`finest` seconds (`finest`
/// one of `Quantum`'s exponents): the tick count divided, or multiplied, by
/// an exact power of ten, so the result is the correctly rounded seconds.
pub fn secondsAt(ticks: u64, finest: i32) f64 {
    std.debug.assert(finest >= @backingInt(Quantum.fs) and finest <= @backingInt(Quantum.hundred_s));
    const powers = [_]f64{ 1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15 };
    const t: f64 = @floatFromInt(ticks);
    const p = powers[@abs(finest)];
    return if (finest < 0) t / p else t * p;
}

test secondsAt {
    // 1500 ps is 1.5 ns, exactly as the literal 1.5e-9 rounds.
    try std.testing.expectEqual(@as(f64, 1.5e-9), secondsAt(1500, -12));
    try std.testing.expectEqual(@as(f64, 3e-15), secondsAt(3, -15));
    try std.testing.expectEqual(@as(f64, 700), secondsAt(7, 2));
    try std.testing.expectEqual(@as(f64, 0), secondsAt(0, -9));
}

/// The greatest tick whose time is <= `t` (§7.3.6.5's "greatest digital time
/// tick which is less than or equal to the analog time"). A `t` within a few
/// ulps of a tick IS that tick: 4e-9 / 1e-9 is 3.9999999999999996 in
/// binary64, and flooring it would put the analog solve one tick early.
/// A negative or NaN `t` is tick 0; one at or past 2^64 ticks (+inf
/// included) is the last tick, 2^64 - 1. Asserts `tick > 0`.
pub fn tickAtOrBefore(t: f64, tick: f64) u64 {
    std.debug.assert(tick > 0);
    const x = t / tick;
    const r = @round(x);
    // An infinite `x` fails the first test (inf - inf is NaN) and floors to
    // itself; a NaN one fails both comparisons below and `@max` drops it.
    const k = if (@abs(x - r) <= ulps * @abs(r)) r else @floor(x);
    // 2^64 is the first binary64 past the last tick.
    if (k >= 0x1p64) return std.math.maxInt(u64);
    return @intFromFloat(@max(k, 0.0));
}

/// The relative distance within which two times are one: rounding, never a
/// fraction of a tick however many ticks the run is long.
pub const ulps = 4 * std.math.floatEps(f64);

/// §5.10.3.1: "If dir is +1, the event ... only occur[s] on rising edge
/// transitions", -1 on falling ones, 0 on both, and any other value on none.
/// The same test the device's `cross` makes against its accepted value.
pub fn crosses(dir: f64, v0: f64, v1: f64) bool {
    const rise = v0 <= 0 and v1 > 0;
    const fall = v0 >= 0 and v1 < 0;
    return if (dir == 1) rise else if (dir == -1) fall else if (dir == 0) rise or fall else false;
}

fn multiply(value: u64, factor: u57) Error!u64 {
    const result: u128 = @as(u128, value) * factor;
    return std.math.cast(u64, result) orelse error.DelayOverflow;
}

/// Conventional IEEE binary64 scaling followed by half-away-from-zero rounding.
/// Only this real-input boundary uses floating arithmetic; global scaling and
/// all integral-input conversions remain integer operations.
fn roundedLocal(value: f64, factor: u57) Error!u64 {
    const scaled = value * @as(f64, @floatFromInt(factor));
    const rounded = @round(scaled);
    if (!std.math.isFinite(rounded) or rounded >= 0x1p64) return error.DelayOverflow;
    return @intFromFloat(rounded);
}

const testing = std.testing;

test "preprocessor seconds bridge rejects noncanonical floating values" {
    try testing.expectEqual(Quantum.fs, try Quantum.fromSeconds(1e-15));
    try testing.expectEqual(Quantum.hundred_s, try Quantum.fromSeconds(100));
    try testing.expectEqual(Quantum.hundred_us, try Quantum.fromSeconds(1e-4));
    for ([_]f64{ 0, -1, 2e-9, 1e-16, std.math.inf(f64), std.math.nan(f64), @bitCast(@as(u64, @bitCast(@as(f64, 1e-9))) + 1) }) |bad|
        try testing.expectError(error.InvalidQuantum, Quantum.fromSeconds(bad));
}

test "local and global precision ordering is validated" {
    try testing.expectError(error.PrecisionTooCoarse, Scale.init(.ps, .ns, .fs));
    try testing.expectError(error.GlobalPrecisionTooCoarse, Scale.init(.ns, .ps, .ns));
    const largest = try Scale.init(.hundred_s, .fs, .fs);
    try testing.expectEqual(@as(u57, 100_000_000_000_000_000), largest.local_per_unit);
    try testing.expectEqual(@as(u64, 100_000_000_000_000_000), try largest.unsignedDelay(1));
}

test "integer delay counts stay exact past binary64 precision" {
    const identity = try Scale.init(.ns, .ns, .ns);
    try testing.expectEqual(@as(u64, 9_007_199_254_740_993), try identity.unsignedDelay(9_007_199_254_740_993));
    try testing.expectEqual(std.math.maxInt(u64), try identity.unsignedDelay(std.math.maxInt(u64)));
    const finer = try Scale.init(.ns, .ps, .fs);
    try testing.expectEqual(@as(u64, 7_000_000), try finer.unsignedDelay(7));
    try testing.expectEqual(@as(u64, 0), try finer.unsignedDelay(0));
    try testing.expectError(error.DelayOverflow, finer.unsignedDelay(std.math.maxInt(u64)));
}

test "real delays round locally before conversion to global ticks" {
    const scale = try Scale.init(.ten_ns, .ns, .ps);
    try testing.expectEqual(@as(u64, 16_000), try scale.realDelay(1.55)); // §19.8 example
    try testing.expectEqual(@as(u64, 13_000), try scale.realDelay(1.25)); // exact half, away
    try testing.expectEqual(@as(u64, 12_000), try scale.realDelay(1.24));
    try testing.expectEqual(@as(u64, 0), try scale.realDelay(0.03125));
    try testing.expectEqual(@as(u64, 1_000), try scale.realDelay(0.0625));
    const coarse = try Scale.init(.ns, .ns, .ps);
    try testing.expectEqual(@as(u64, 0), try coarse.realDelay(0.49));
    try testing.expectEqual(@as(u64, 1_000), try coarse.realDelay(0.5));
    try testing.expectEqual(@as(u64, 1_000), try coarse.realDelay(1.49));
}

test "real rounding distinguishes adjacent binary64 values at half ticks" {
    const scale = try Scale.init(.s, .s, .s);
    const half_bits: u64 = @bitCast(@as(f64, 0.5));
    try testing.expectEqual(@as(u64, 0), try scale.realDelay(@bitCast(half_bits - 1)));
    try testing.expectEqual(@as(u64, 1), try scale.realDelay(@bitCast(half_bits + 1)));
    try testing.expectEqual(@as(u64, 0), try scale.realDelay(@bitCast(@as(u64, 1))));
    try testing.expectEqual(@as(u64, 0), try scale.realDelay(-0.0));
    try testing.expectEqual(@as(u64, 9_007_199_254_740_992), try scale.realDelay(9_007_199_254_740_992));
    try testing.expectEqual(std.math.maxInt(u64) - 2047, try scale.realDelay(@bitCast(@as(u64, @bitCast(@as(f64, 0x1p64))) - 1)));
    try testing.expectError(error.DelayOverflow, scale.realDelay(0x1p64));
    try testing.expectError(error.DelayOverflow, scale.realDelay(std.math.floatMax(f64)));
    try testing.expectError(error.NonFiniteDelay, scale.realDelay(std.math.inf(f64)));
    try testing.expectError(error.NonFiniteDelay, scale.realDelay(-std.math.inf(f64)));
    try testing.expectError(error.NonFiniteDelay, scale.realDelay(std.math.nan(f64)));
}

test "binary64 scaling interpretation preserves conventional decimal-half rounding" {
    const scale = try Scale.init(.ten_ns, .ns, .ns);
    // The multiplication rounds these binary64 inputs to exact half ticks.
    // An exact rational reinterpretation would instead produce 1 and 14.
    try testing.expectEqual(@as(u64, 2), try scale.realDelay(0.15));
    try testing.expectEqual(@as(u64, 15), try scale.realDelay(1.45));
    const large = try Scale.init(.hundred_s, .fs, .fs);
    const next_one: f64 = @bitCast(@as(u64, @bitCast(@as(f64, 1))) + 1);
    try testing.expectEqual(@as(u64, 100_000_000_000_000_016), try large.realDelay(next_one));
    const global = try Scale.init(.hundred_s, .s, .fs);
    try testing.expectError(error.DelayOverflow, global.realDelay(1000));
}

test "negative procedural integers are unsigned times; negative reals are refused" {
    const scale = try Scale.init(.ns, .ns, .ns);
    try testing.expectEqual(std.math.maxInt(u64), try scale.signedDelay(-1));
    try testing.expectEqual(@as(u64, 1) << 63, try scale.signedDelay(std.math.minInt(i64)));
    try testing.expectEqual(@as(u64, 2), try scale.signedDelay(2));
    try testing.expectError(error.NegativeRealDelay, scale.realDelay(-0.5));
    try testing.expectError(error.NonFiniteDelay, scale.realDelay(-std.math.inf(f64)));
    const finer = try Scale.init(.ns, .ps, .ps);
    try testing.expectError(error.DelayOverflow, finer.signedDelay(-1));
}

test "dyadic real delays match independent rational rounding oracle across scale grid" {
    for (0..18) |unit_offset| {
        for (0..unit_offset + 1) |precision_offset| {
            const unit: Quantum = @fromBackingInt(@intCast(@as(i6, @intCast(unit_offset)) - 15));
            const precision: Quantum = @fromBackingInt(@intCast(@as(i6, @intCast(precision_offset)) - 15));
            const scale = try Scale.init(unit, precision, precision);
            for (0..257) |n| {
                const numerator: u128 = @as(u128, n) * scale.local_per_unit;
                const expected: u128 = (numerator + 128) / 256;
                try testing.expectEqual(@as(u64, @intCast(expected)), try scale.realDelay(@as(f64, @floatFromInt(n)) / 256));
            }
        }
    }
}

test "tickAtOrBefore: a time within rounding of a tick is that tick" {
    try testing.expectEqual(@as(u64, 4), tickAtOrBefore(4e-9, 1e-9));
    try testing.expectEqual(@as(u64, 4), tickAtOrBefore(4.5e-9, 1e-9));
    try testing.expectEqual(@as(u64, 0), tickAtOrBefore(0, 1e-9));
    try testing.expectEqual(@as(u64, 20), tickAtOrBefore(20e-9, 1e-9));
    try testing.expectEqual(@as(u64, 600000000), tickAtOrBefore(0.6000000006, 1e-9));
}

test "tickAtOrBefore: below zero and NaN are tick 0, past the last tick is the last" {
    try testing.expectEqual(@as(u64, 0), tickAtOrBefore(-1e-9, 1e-9));
    try testing.expectEqual(@as(u64, 0), tickAtOrBefore(-0.0, 1e-9));
    try testing.expectEqual(@as(u64, 0), tickAtOrBefore(std.math.nan(f64), 1e-9));
    // 3.999 ticks is more than rounding short of 4: tick 3.
    try testing.expectEqual(@as(u64, 3), tickAtOrBefore(3.999e-9, 1e-9));
    // 3e-9 / 1e-9 is 2.9999999999999996: within rounding of tick 3.
    try testing.expectEqual(@as(u64, 3), tickAtOrBefore(3e-9, 1e-9));
    // 1e300 s at 1 fs is past binary64 itself; 2^64 ticks is one past the last.
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), tickAtOrBefore(1e300, 1e-15));
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), tickAtOrBefore(std.math.inf(f64), 1e-15));
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), tickAtOrBefore(0x1p64, 1));
}

test "every §19.8 operand round-trips through fromSeconds" {
    var buf: [8]u8 = undefined;
    var e: i32 = -15;
    while (e <= 2) : (e += 1) {
        // What the preprocessor folds `1e<e>` to: binary64's nearest value.
        const seconds = try std.fmt.parseFloat(f64, try std.mem.print(&buf, "1e{d}", .{e}));
        try testing.expectEqual(e, @as(i32, @backingInt(try Quantum.fromSeconds(seconds))));
    }
}

test "Scale.init over every unit, precision and global operand" {
    const all = std.enums.values(Quantum);
    for (all) |u| for (all) |p| for (all) |g| {
        const ue: i32 = @backingInt(u);
        const pe: i32 = @backingInt(p);
        const ge: i32 = @backingInt(g);
        const got = Scale.init(u, p, g);
        if (pe > ue) {
            try testing.expectError(error.PrecisionTooCoarse, got);
        } else if (ge > pe) {
            try testing.expectError(error.GlobalPrecisionTooCoarse, got);
        } else {
            const scale = try got;
            try testing.expectEqual(std.math.pow(u64, 10, @intCast(ue - pe)), scale.local_per_unit);
            try testing.expectEqual(std.math.pow(u64, 10, @intCast(pe - ge)), scale.global_per_local);
        }
    };
}

test "unitsAt rounds half away from zero, up to the last tick" {
    // 1000 ticks per ns and 10 ns per unit: 4.999 ns is 0 units, 5 ns is 1,
    // 14.999 ns is 1 and 15 ns is 2 (§17.7.1, `realDelay`'s rounding).
    const scale = try Scale.init(.ten_ns, .ns, .ps);
    try testing.expectEqual(@as(u64, 0), scale.unitsAt(4_999));
    try testing.expectEqual(@as(u64, 1), scale.unitsAt(5_000));
    try testing.expectEqual(@as(u64, 1), scale.unitsAt(14_999));
    try testing.expectEqual(@as(u64, 2), scale.unitsAt(15_000));
    // Below the precision is dropped before the unrounded division too.
    try testing.expectEqual(@as(f64, 1.5), scale.realAt(15_500));
    // (2^64 - 1) ns is 1844674407370955161.5 units of 10 ns: away from zero.
    const coarse = try Scale.init(.ten_ns, .ns, .ns);
    try testing.expectEqual(@as(u64, 1_844_674_407_370_955_162), coarse.unitsAt(std.math.maxInt(u64)));
    try testing.expectEqual(@as(u64, 1_844_674_407_370_955_161), coarse.unitsAt(std.math.maxInt(u64) - 5));
}

test "crosses: §5.10.3.1's directions over every sign pair" {
    const levels = [_]f64{ -1, 0, 1 };
    // The crossings, listed: a rise ends above zero from at or below it, a
    // fall ends below zero from at or above it.
    const rises = [_][2]f64{ .{ -1, 1 }, .{ 0, 1 } };
    const falls = [_][2]f64{ .{ 1, -1 }, .{ 0, -1 } };
    for (levels) |v0| for (levels) |v1| {
        const rise = listedPair(&rises, v0, v1);
        const fall = listedPair(&falls, v0, v1);
        try testing.expectEqual(rise, crosses(1, v0, v1));
        try testing.expectEqual(fall, crosses(-1, v0, v1));
        try testing.expectEqual(rise or fall, crosses(0, v0, v1));
        // Any other direction makes no event.
        for ([_]f64{ 0.5, 2, -2, std.math.nan(f64) }) |dir| try testing.expect(!crosses(dir, v0, v1));
    };
}

fn listedPair(rows: []const [2]f64, v0: f64, v1: f64) bool {
    for (rows) |r| if (r[0] == v0 and r[1] == v1) return true;
    return false;
}
