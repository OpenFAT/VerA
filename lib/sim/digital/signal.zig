//! The drivers' strength-signals of one bit and the net's type in, the bit the net shows out: §7.10 strength ranges, §7.9 wired logic, a net type's undriven value and `trireg` charge.
//! Cites: IEEE 1364-2005 §3.7, §3.8, §7.9 Tables 7-4/7-6/7-7, §7.10 Figures 7-9 to 7-25.
//!
//! Contents:
//! - `pub const Signal = struct`
//! - `Signal.of(b: Int.Bit, s0: Ast.Strength, s1: Ast.Strength) Signal`
//! - `Signal.orZ(b: Int.Bit, s0: Ast.Strength, s1: Ast.Strength) Signal`
//! - `Signal.none(self: Signal) bool`
//! - `Signal.combine(a: Signal, b: Signal) Signal`
//! - `Signal.combineWired(a: Signal, b: Signal, table: Wired) Signal`
//! - `Signal.collapse(self: Signal) Int.Bit`
//! - `pub fn reduceSignal(sig: Signal, hops: u32, resistive: u32) Signal`
//! - `pub fn reduce(s: Ast.Strength, resistive: bool) Ast.Strength`
//! - `pub fn foldUniform(out: Int.Literal, drivers: []const Driver, ids: []const u32) void`
//! - `pub fn netPull(kind: Ast.NetKind) Signal`
//! - `pub fn wiredLogic(kind: Ast.NetKind) ?Wired`
//! - `pub fn undriven(kind: Ast.NetKind) Int.Bit`
//! Driver bits, their A.2.2.2 strengths and the net's type -> one resolved
//! four-state bit, a delay in scheduler ticks, or a gate output bit. Data and
//! pure functions only; no engine state. IEEE 1364-2005 §7.9 Tables 7-4/7-6/7-7
//! and §7.10 strength resolution, §7.8.5 gate tables (A.3.1, A.3.4), §7.6/§7.12
//! switches, §8 UDPs, §3.7 undriven values, §3.8 `trireg` charge, A.2.2.3
//! `delay3` chosen per §7.14, §6.1.3 vector and inertial delays.
const std = @import("std");
const assert = std.debug.assert;
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const Error = @import("root.zig").Error;
const expectRun = @import("root.zig").expectRun;
const Handle = @import("../scheduler.zig").Handle;
const net = @import("net.zig");
const Driver = net.Driver;
const Wired = net.Wired;
const filled = net.filled;
const setBit = net.setBit;
const wordMask = net.wordMask;

/// IEEE 1364-2005 §7.10's signal: a range of strength levels on Figure 7-2's
/// scale, which runs Su0 … Sm0 HiZ0 HiZ1 Sm1 … Su1. A position here is that
/// scale folded at HiZ: `-s` is strength0 level `s`, `+s` strength1 level
/// `s`, and 0 is HiZ. A per-side maximum would not do: §7.10.2's StH (a
/// bufif1 with an x enable passing a 1) is `[HiZ, St1]`, which a maximum
/// cannot tell from St1 and which §7.10.3 lets a Pu1 settle to 1. `collapse`
/// turns it into four states only after resolution.
pub const Signal = struct {
    lo: i8 = 0,
    hi: i8 = 0,

    // Budget: one per net bit (`Run.signals`).
    comptime {
        std.debug.assert(@sizeOf(Signal) == 2);
    }

    /// What a driver holding `b` at `(s0, s1)` asserts. An `x` spans both
    /// sides, an ambiguous range rather than a value, and a `z` asserts
    /// nothing, which is why an undriven net reads z. A
    /// `highz` strength on one side of an `x` is Figure 7-17's H/L: "HiZ0 is
    /// part of the result because the strength specification ... specified
    /// that strength for an output with a value 0".
    pub fn of(b: Int.Bit, s0: Ast.Strength, s1: Ast.Strength) Signal {
        const p0 = -@as(i8, @intCast(@backingInt(s0)));
        const p1: i8 = @intCast(@backingInt(s1));
        const sig: Signal = switch (b) {
            .one => .{ .lo = p1, .hi = p1 },
            .zero => .{ .lo = p0, .hi = p0 },
            .x => .{ .lo = p0, .hi = p1 },
            .z => .{},
        };
        assert(sig.lo <= sig.hi); // A signal is a range of strengths.
        assert(sig.hi <= strength_max);
        return sig;
    }

    /// §7.10.2 H or L: `b` or high impedance, at `b`'s side's strength, what
    /// a three-state driver with an unknown control asserts (Figure 7-6).
    pub fn orZ(b: Int.Bit, s0: Ast.Strength, s1: Ast.Strength) Signal {
        assert(@backingInt(s0) <= strength_max);
        assert(@backingInt(s1) <= strength_max);
        return of(.x, if (b == .one) .highz else s0, if (b == .zero) .highz else s1);
    }

    /// Does the signal reach neither side, the `.{}` of no driver at all?
    pub fn none(self: Signal) bool {
        assert(self.lo <= self.hi);
        return self.lo == 0 and self.hi == 0;
    }

    /// §7.10.1-§7.10.3, one more contributor folded in.
    ///   - two unambiguous signals: the stronger wins; equal strength and
    ///     opposite values give x "along with the strength levels of both
    ///     signals and all the smaller strength levels", the hull;
    ///   - two ambiguous ones: "a range that includes the extremes of the
    ///     signals and all the strengths between them", the hull again;
    ///   - one of each: §7.10.3's rules a-c. The ambiguous levels stronger
    ///     than the unambiguous one remain, the rest disappear, and the gap
    ///     between what remains and the unambiguous level is filled. An
    ///     opposite-value level equal to it remains too: Figure 7-21's text
    ///     drops only the opposite levels of "lesser strength", and §4.6.1
    ///     Table 4-2 makes St0 with StX an x, which dropping it would not.
    pub fn combine(a: Signal, b: Signal) Signal {
        if (a.none()) return b;
        if (b.none()) return a;
        const hull: Signal = .{ .lo = @min(a.lo, b.lo), .hi = @max(a.hi, b.hi) };
        assert(hull.lo <= hull.hi);
        const ua = a.lo == a.hi;
        const ub = b.lo == b.hi;
        if (ua and ub) {
            if (@abs(a.lo) != @abs(b.lo)) return if (@abs(a.lo) > @abs(b.lo)) a else b;
            return hull;
        }
        if (!ua and !ub) return hull;
        const u = if (ua) a.lo else b.lo;
        const amb = if (ua) b else a;
        const s: i8 = @intCast(@abs(u));
        const out: Signal = .{
            .lo = if (amb.lo < -s or (amb.lo == -s and u > 0)) @min(u, amb.lo) else u,
            .hi = if (amb.hi > s or (amb.hi == s and u < 0)) @max(u, amb.hi) else u,
        };
        assert(out.lo <= out.hi);
        return out;
    }

    /// §7.10.4, one more contributor folded into a wired-logic net: the
    /// table decides only between levels of the same strength ("resolve
    /// conflicts when multiple drivers have the same strength"), and
    /// otherwise "the stronger signal shall dominate" (§7.10.1). An ambiguous
    /// signal takes "all combinations of each of the strength levels in the
    /// first signal with each of the strength levels in the second", and the
    /// result spans every level those produce. HiZ is a level of a range
    /// that crosses it, which is how §7.10.2's H with a Sm0 on a `wor` may
    /// still be 0.
    pub fn combineWired(a: Signal, b: Signal, table: Wired) Signal {
        if (a.none()) return b;
        if (b.none()) return a;
        assert(a.lo <= a.hi);
        var out: Signal = .{ .lo = std.math.maxInt(i8), .hi = std.math.minInt(i8) };
        var p = a.lo;
        while (p <= a.hi) : (p += 1) {
            var q = b.lo;
            while (q <= b.hi) : (q += 1) {
                // At equal strength `and` is decided by a 0 and `or` by a 1.
                const r = if (@abs(p) != @abs(q))
                    (if (@abs(p) > @abs(q)) p else q)
                else if (table == .@"and") @min(p, q) else @max(p, q);
                out.lo = @min(out.lo, r);
                out.hi = @max(out.hi, r);
            }
        }
        assert(out.lo <= out.hi); // Both ranges are non-empty.
        return out;
    }

    /// The four-state value of the range: wholly on one side is that side's
    /// value, HiZ alone is z, and anything that straddles HiZ (§7.10.2's H
    /// and L among them) is x. Requires `lo <= hi`, which every `Signal`
    /// built here keeps (a reduction across a switch is monotone).
    pub fn collapse(self: Signal) Int.Bit {
        // Branchless, since the per-bit fold calls it on data-dependent
        // signals: the unknown plane is "the range touches HiZ" (lo <= 0 <=
        // hi), the value plane "it reaches strength1, or it is an L, which
        // reaches strength0 and stops at HiZ". The branchy reading is the
        // oracle of the test "Signal.collapse agrees with the clause's
        // reading on every range".
        assert(self.lo <= self.hi);
        const u = @intFromBool(self.lo <= 0) & @intFromBool(self.hi >= 0);
        const v = @intFromBool(self.hi > 0) | (@intFromBool(self.lo < 0) & @intFromBool(self.hi == 0));
        return @fromBackingInt(@as(u2, v) | @as(u2, u) << 1);
    }
};

/// The strongest strength, `supply` (A.2.2.2 encodes them 0..7).
const strength_max: i8 = @backingInt(Ast.Strength.supply);

/// §7.11/§7.12 a signal that crossed `hops` pass switches, `resistive` of
/// them resistive: supply becomes strong at the first switch, and each
/// resistive one reduces by Table 7-8.
pub fn reduceSignal(sig: Signal, hops: u32, resistive: u32) Signal {
    if (hops == 0) return sig;
    assert(sig.lo <= sig.hi);
    const one = struct {
        fn side(v: i8, k: u32) i8 {
            var s = reduce(@fromBackingInt(@intCast(@abs(v))), false);
            for (0..k) |_| s = reduce(s, true);
            const m: i8 = @intCast(@backingInt(s));
            return if (v < 0) -m else m;
        }
    };
    const out: Signal = .{ .lo = one.side(sig.lo, resistive), .hi = one.side(sig.hi, resistive) };
    assert(out.lo <= out.hi); // Reduction keeps the order of strengths.
    return out;
}

//
// The joined-group search both resolutions run (`resolution.resolveJoined`,
// `rt/net.zig`'s `resolveJoined`). It lives here because this is the one
// file both already import: in `rt/net.zig` the interpreter's
// `resolution.zig` would reach it through `rt/root.zig` -> `digital/root.zig`,
// a file cycle. The two differ only in where a switch's conduction and a
// net's switch list are kept, so each search takes `g`, which has
// `switches(g, net: u32) []const u32` (the `trans` rows touching net `net`),
// `tran(g, ti: u32)` (a row with `a`, `b`, `a_bit`, `b_bit`, `resistive`) and
// `conduction(g, ti: u32) Tran.State`.

/// IEEE 1364-2005 §7.12 Table 7-8: what a resistive switch makes of the
/// strength it passes; a non-resistive one only turns supply into strong.
pub fn reduce(s: Ast.Strength, resistive: bool) Ast.Strength {
    assert(@backingInt(s) <= strength_max);
    const out: Ast.Strength = if (!resistive) (if (s == .supply) .strong else s) else switch (s) {
        .supply, .strong => .pull,
        .pull => .weak,
        .large, .weak => .medium,
        .medium, .small => .small,
        .highz => .highz,
    };
    assert(@backingInt(out) <= @backingInt(s)); // A switch never strengthens.
    if (s != .highz) assert(out != .highz);
    return out;
}

/// §7.9/§7.10 the resolution of drivers that all assert one strength on
/// both sides and no H/L, on a net type with no wired logic and no pull of
/// its own, written to `out` 64 bits a word. At one strength the fold of
/// `Signal.combine` reduces to: any x, or a 0 beside a 1, is x; else a 0 or
/// a 1 is that value; else z. `ids` index `drivers`, and each one's
/// `current` has as many plane words as `out`.
pub fn foldUniform(out: Int.Literal, drivers: []const Driver, ids: []const u32) void {
    const words = out.values().len;
    assert(out.planes.len == 2 * words);
    for (0..words) |w| {
        var any0: u64 = 0;
        var any1: u64 = 0;
        var anyx: u64 = 0;
        for (ids) |d| {
            const cur = drivers[d].current;
            std.debug.assert(cur.planes.len == out.planes.len);
            const v = cur.values()[w];
            const u = cur.unknowns()[w];
            any0 |= ~v & ~u;
            any1 |= v & ~u;
            anyx |= v & u;
        }
        const x = anyx | (any0 & any1);
        const m = wordMask(out.width, w);
        out.values()[w] = (x | any1) & m;
        out.unknowns()[w] = (x | ~(any0 | any1)) & m;
    }
}

/// §3.7/§7.9: what the net type itself contributes, at the level clause 7
/// gives it: `undriven`'s value, at the strength that lets a driver argue
/// with it: a `weak1` driver cannot move a
/// `tri0` because pull(5) beats weak(3), and nothing an `assign` can write
/// beats a supply net's supply(7).
pub fn netPull(kind: Ast.NetKind) Signal {
    const pull: Signal = switch (kind) {
        .supply0 => .of(.zero, .supply, .highz),
        .supply1 => .of(.one, .highz, .supply),
        .tri0 => .of(.zero, .pull, .highz),
        .tri1 => .of(.one, .highz, .pull),
        // No pull of its own; a wreal resolves as a real and never gets here.
        .wire, .tri, .triand, .trior, .trireg, .wand, .wor, .uwire, .wreal => .{},
    };
    assert(pull.lo <= pull.hi);
    if (wiredLogic(kind) != null) assert(pull.none()); // §7.13: a wired net has no pull of its own.
    return pull;
}

/// Which §7.9 table a net folds its drivers through, null for every net type
/// that resolves through `Signal.combine` alone.
pub fn wiredLogic(kind: Ast.NetKind) ?Wired {
    return switch (kind) {
        .wand, .triand => .@"and",
        .wor, .trior => .@"or",
        .wire, .tri, .tri0, .tri1, .trireg, .uwire, .supply0, .supply1, .wreal => null,
    };
}

/// §3.7 the value a net of this type shows with no driver at all: the pull of
/// `tri0`/`tri1`, the constant of a supply net, the X a `trireg` starts at
/// before it has any charge to hold, and Z for everything else.
pub fn undriven(kind: Ast.NetKind) Int.Bit {
    const b: Int.Bit = switch (kind) {
        .supply0, .tri0 => .zero,
        .supply1, .tri1 => .one,
        .trireg => .x,
        // A wreal reads 0.0 undriven, which `mintNet` gives it directly.
        .wire, .tri, .triand, .trior, .wand, .wor, .uwire, .wreal => .z,
    };
    // §3.7: the undriven value is what the net type's own pull resolves to,
    // save a trireg's, which holds its x until a driver charges it.
    if (kind != .trireg) assert(netPull(kind).collapse() == b);
    return b;
}

test "an undriven net reads Z where a variable reads X" {
    try expectRun(
        \\module example;
        \\reg [3:0] r;
        \\wire [3:0] w;
        \\wire s;
        \\initial $display("%b %b %b", r, w, s);
        \\endmodule
    , "xxxx zzzz z\n");
}

test "IEEE1364-2005 section 7.9 wired logic resolves all drivers of one net" {
    // Each net has the same two drivers; only the resolution function differs.
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a, b;
        \\wire w;
        \\wand wa;
        \\wor wo;
        \\assign w = a, wa = a, wo = a;
        \\assign w = b, wa = b, wo = b;
        \\initial begin
        \\  a = 0; b = 0; #1 $display("0 0 %b %b %b", w, wa, wo);
        \\  a = 1;        #1 $display("1 0 %b %b %b", w, wa, wo);
        \\  b = 1;        #1 $display("1 1 %b %b %b", w, wa, wo);
        \\  a = 1'bz;     #1 $display("z 1 %b %b %b", w, wa, wo);
        \\  b = 1'bx;     #1 $display("z x %b %b %b", w, wa, wo);
        \\  b = 1'bz;     #1 $display("z z %b %b %b", w, wa, wo);
        \\  $finish(0);
        \\end
        \\endmodule
    ,
        \\0 0 0 0 0
        \\1 0 x 0 1
        \\1 1 1 1 1
        \\z 1 1 1 1
        \\z x x x x
        \\z z z z z
        \\
    );
}

test "Signal.collapse agrees with the clause's reading on every range" {
    // §7.10: wholly strength1 is 1, wholly strength0 is 0, HiZ alone is z,
    // anything straddling HiZ (H and L among them) is x.
    var lo: i8 = -7;
    while (lo <= 7) : (lo += 1) {
        var hi: i8 = lo;
        while (hi <= 7) : (hi += 1) {
            const s: Signal = .{ .lo = lo, .hi = hi };
            const want: Int.Bit = if (lo > 0) .one else if (hi < 0) .zero else if (s.none()) .z else .x;
            try std.testing.expectEqual(want, s.collapse());
        }
    }
}

test "IEEE1364-2005 Figure 7-25 wired logic over an ambiguous strength" {
    // Signal 1 is St0..Pu0, signal 2 is Pu1. `and`: Pu0 & Pu1 = Pu0 and St0
    // dominates, so St0..Pu0. `or`: Pu0 | Pu1 = Pu1 but St0 still dominates,
    // so the result spans St0..Pu1.
    const s1: Signal = .{ .lo = -6, .hi = -5 };
    const s2: Signal = .of(.one, .pull, .pull);
    try std.testing.expectEqual(Signal{ .lo = -6, .hi = -5 }, s1.combineWired(s2, .@"and"));
    try std.testing.expectEqual(Signal{ .lo = -6, .hi = 5 }, s1.combineWired(s2, .@"or"));
}

// IEEE 1364-2005 clause 7, A.2.2.2, A.6.1: the three places strength decides
// what a four-state resolution alone would get wrong. The d03 fixtures cover
// the resolution as a whole.
test "a drive strength decides which of two disagreeing drivers the net shows" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a, b;
        \\wire w;
        \\tri0 t;
        \\assign (strong1, strong0) w = a, t = a;
        \\assign (weak1, weak0) w = b;
        \\initial begin
        \\  a = 1; b = 0; #1 $display("6v3 %b %b", w, t);
        \\  a = 0; b = 1; #1 $display("3v6 %b %b", w, t);
        \\  a = 1'bx;     #1 $display("ambiguous %b %b", w, t);
        \\  a = 1'bz;     #1 $display("removed %b %b", w, t);
        \\  $finish(0);
        \\end
        \\endmodule
    ,
        // `t` is a tri0: its own pull(5) loses to strong(6) on both polarities and
        // to the strong x on neither side, so the ambiguous line is x there too,
        // and the weak driver of `w` never moves it.
        \\6v3 1 1
        \\3v6 0 0
        \\ambiguous x x
        \\removed 1 0
        \\
    );
}

test "a highz half suppresses that polarity outright, wired logic included" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a, b;
        \\wire w;
        \\wand wa;
        \\assign (strong1, highz0) w = a, wa = a;
        \\assign (weak1, weak0) w = b, wa = b;
        \\initial begin
        \\  a = 0; b = 1; #1 $display("open_drain %b %b", w, wa);
        \\  a = 0; b = 0; #1 $display("weak_zero %b %b", w, wa);
        \\  a = 0; b = 1'bz; #1 $display("nothing_left %b %b", w, wa);
        \\  $finish(0);
        \\end
        \\endmodule
    ,
        // The `highz0` driver holding 0 asserts nothing at all, so it is invisible
        // to the plain wire and is the wand table's identity rather than a 0 vote.
        \\open_drain 1 1
        \\weak_zero 0 0
        \\nothing_left z z
        \\
    );
}

test "a supply net outranks every strength an assign can write but its own" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a;
        \\supply1 vdd;
        \\supply1 v2;
        \\assign (strong1, strong0) vdd = a;
        \\assign (supply1, supply0) v2 = a;
        \\initial begin
        \\  a = 0; #1 $display("zero %b %b", vdd, v2);
        \\  a = 1; #1 $display("one %b %b", vdd, v2);
        \\  $finish(0);
        \\end
        \\endmodule
    ,
        // A supply-strength driver does not lose to the net, it ties with it, and a
        // tie on two nonzero sides is x. That is the line a resolver which simply
        // ignores a supply net's drivers gets wrong.
        \\zero 1 x
        \\one 1 1
        \\
    );
}

test "the pull supply and capacitive net types supply what no driver did" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg d;
        \\tri0 t0;
        \\tri1 t1;
        \\supply0 s0;
        \\supply1 s1;
        \\trireg c;
        \\assign t0 = d, t1 = d, s0 = d, s1 = d, c = d;
        \\initial begin
        \\  $display("start %b %b %b %b %b", t0, t1, s0, s1, c);
        \\  d = 0;    #1 $display("zero  %b %b %b %b %b", t0, t1, s0, s1, c);
        \\  d = 1'bz; #1 $display("float %b %b %b %b %b", t0, t1, s0, s1, c);
        \\  $finish(0);
        \\end
        \\endmodule
    ,
        \\start x x 0 1 x
        \\zero  0 0 0 1 0
        \\float 0 1 0 1 0
        \\
    );
}

// §7.10.2/§7.10.3 against the clause's own figures, each as (lo, hi) on the
// folded scale: 35X is [-3, 5], 56X [-5, 6], 36X [-3, 6], 651 [5, 6].
test "§7.10 strength ranges combine the way Figures 7-9 through 7-19 draw them" {
    const S = Signal;
    // Figure 7-9: PuH + WeL is 35X, "the extremes of the signals and all the strengths between".
    try std.testing.expectEqual(S{ .lo = -3, .hi = 5 }, S.orZ(.one, .strong, .pull).combine(S.orZ(.zero, .weak, .strong)));
    // Figure 7-14: 651 + 530 is 56X.
    try std.testing.expectEqual(S{ .lo = -5, .hi = 6 }, (S{ .lo = 5, .hi = 6 }).combine(.{ .lo = -5, .hi = -3 }));
    // Figure 7-19: StH + We0 is 36X (rule c fills the gap).
    const sth = S.of(.x, .highz, .strong);
    try std.testing.expectEqual(S{ .lo = -3, .hi = 6 }, sth.combine(S.of(.zero, .weak, .strong)));
    // Rules a/b: StH + Pu1 keeps only St1 above Pu1: a 1, not an x.
    try std.testing.expectEqual(Int.Bit.one, sth.combine(S.of(.one, .strong, .pull)).collapse());
    try std.testing.expectEqual(Int.Bit.x, sth.collapse());
    // An opposite level equal to the unambiguous one ties: Table 4-2's 0-with-x.
    try std.testing.expectEqual(Int.Bit.x, S.of(.x, .strong, .strong).combine(S.of(.zero, .strong, .strong)).collapse());
    try std.testing.expectEqual(Int.Bit.x, S.of(.x, .pull, .pull).combine(S.of(.zero, .pull, .highz)).collapse());
    try std.testing.expectEqual(Int.Bit.x, sth.combine(S.of(.zero, .strong, .strong)).collapse());
    // §7.10.1: unambiguous, the stronger wins; equal and opposite is x.
    try std.testing.expectEqual(Int.Bit.zero, S.of(.one, .strong, .weak).combine(S.of(.zero, .pull, .strong)).collapse());
    try std.testing.expectEqual(Int.Bit.x, S.of(.one, .strong, .pull).combine(S.of(.zero, .pull, .strong)).collapse());
    try std.testing.expectEqual(Int.Bit.z, S.of(.one, .strong, .highz).collapse());
}

test reduce {
    // IEEE 1364-2005 §7.12 Table 7-8, row by row: what a resistive switch
    // makes of each input strength.
    const S = Ast.Strength;
    const table = [_][2]S{
        .{ .supply, .pull },
        .{ .strong, .pull },
        .{ .pull, .weak },
        .{ .large, .medium },
        .{ .weak, .medium },
        .{ .medium, .small },
        .{ .small, .small },
        .{ .highz, .highz },
    };
    for (table) |row| {
        try std.testing.expectEqual(row[1], reduce(row[0], true));
        // §7.11: a non-resistive switch only turns supply into strong.
        try std.testing.expectEqual(if (row[0] == .supply) S.strong else row[0], reduce(row[0], false));
    }
}

test reduceSignal {
    const su1: Signal = .of(.one, .supply, .supply);
    // No switch crossed: the signal as driven.
    try std.testing.expectEqual(su1, reduceSignal(su1, 0, 0));
    // §7.11: supply arrives as strong across a tran.
    try std.testing.expectEqual(Signal{ .lo = 6, .hi = 6 }, reduceSignal(su1, 1, 0));
    // Table 7-8: strong (from supply) to pull across one rtran, to weak
    // across a second.
    try std.testing.expectEqual(Signal{ .lo = 5, .hi = 5 }, reduceSignal(su1, 1, 1));
    try std.testing.expectEqual(Signal{ .lo = 3, .hi = 3 }, reduceSignal(su1, 2, 2));
    // Both sides of an x reduce: StX across an rtran is PuX.
    try std.testing.expectEqual(Signal{ .lo = -5, .hi = 5 }, reduceSignal(.of(.x, .strong, .strong), 1, 1));
    // HiZ stays HiZ however many switches it crosses.
    try std.testing.expectEqual(Signal{}, reduceSignal(.{}, 3, 3));
}

test "§7.10 Signal: what a driver asserts, and its four-state value" {
    try std.testing.expectEqual(Signal{ .lo = 6, .hi = 6 }, Signal.of(.one, .weak, .strong));
    try std.testing.expectEqual(Signal{ .lo = -3, .hi = -3 }, Signal.of(.zero, .weak, .strong));
    try std.testing.expectEqual(Signal{ .lo = -3, .hi = 6 }, Signal.of(.x, .weak, .strong));
    try std.testing.expectEqual(Signal{}, Signal.of(.z, .supply, .supply));
    // Figure 7-6's H and L: one side's level and HiZ.
    try std.testing.expectEqual(Signal{ .lo = 0, .hi = 6 }, Signal.orZ(.one, .strong, .strong));
    try std.testing.expectEqual(Signal{ .lo = -6, .hi = 0 }, Signal.orZ(.zero, .strong, .strong));
    try std.testing.expectEqual(Int.Bit.x, Signal.orZ(.one, .strong, .strong).collapse());
    try std.testing.expect((Signal{}).none());
    try std.testing.expect(!Signal.orZ(.one, .strong, .strong).none());
    try std.testing.expectEqual(Int.Bit.one, (Signal{ .lo = 1, .hi = 7 }).collapse());
    try std.testing.expectEqual(Int.Bit.zero, (Signal{ .lo = -7, .hi = -1 }).collapse());
}

test "§7.9 the two-signal folds are symmetric and HiZ is their identity" {
    // Every range on Figure 7-2's folded scale, lo <= hi in [-7, 7].
    // Symmetry only: a fold of three or more signals with two ambiguous
    // ones depends on their order (`(StL, StL, Pu0)` is 0 one way and x
    // another), which the clause's pairwise rules leave open.
    var la: i8 = -7;
    while (la <= 7) : (la += 1) {
        var ha = la;
        while (ha <= 7) : (ha += 1) {
            const a: Signal = .{ .lo = la, .hi = ha };
            try std.testing.expectEqual(a, a.combine(.{}));
            try std.testing.expectEqual(a, (Signal{}).combine(a));
            try std.testing.expectEqual(a, a.combineWired(.{}, .@"and"));
            try std.testing.expectEqual(a, (Signal{}).combineWired(a, .@"or"));
            var lb: i8 = -7;
            while (lb <= 7) : (lb += 1) {
                var hb = lb;
                while (hb <= 7) : (hb += 1) {
                    const b: Signal = .{ .lo = lb, .hi = hb };
                    try std.testing.expectEqual(a.combine(b), b.combine(a));
                    try std.testing.expectEqual(a.combineWired(b, .@"and"), b.combineWired(a, .@"and"));
                    try std.testing.expectEqual(a.combineWired(b, .@"or"), b.combineWired(a, .@"or"));
                }
            }
        }
    }
}

test "§3.7/§7.9 what each net type supplies undriven, and which table it folds through" {
    const Row = struct { Ast.NetKind, Int.Bit, ?Wired };
    const rows = [_]Row{
        .{ .wire, .z, null },
        .{ .tri, .z, null },
        .{ .tri0, .zero, null },
        .{ .tri1, .one, null },
        .{ .triand, .z, .@"and" },
        .{ .trior, .z, .@"or" },
        .{ .trireg, .x, null },
        .{ .wand, .z, .@"and" },
        .{ .wor, .z, .@"or" },
        .{ .uwire, .z, null },
        .{ .supply0, .zero, null },
        .{ .supply1, .one, null },
        .{ .wreal, .z, null },
    };
    for (rows) |row| {
        const kind, const bit, const table = row;
        try std.testing.expectEqual(bit, undriven(kind));
        try std.testing.expectEqual(table, wiredLogic(kind));
        // A net type's own pull collapses to its undriven value. A trireg's
        // x is charge it holds (§3.8), not a pull: it asserts nothing.
        try std.testing.expectEqual(if (kind == .trireg) Int.Bit.z else bit, netPull(kind).collapse());
    }
    // §7.9: tri0 pulls at pull(5), a supply net supplies at supply(7).
    try std.testing.expectEqual(Signal{ .lo = -5, .hi = -5 }, netPull(.tri0));
    try std.testing.expectEqual(Signal{ .lo = 7, .hi = 7 }, netPull(.supply1));
}

test foldUniform {
    // Differential against the per-bit `Signal.combine` fold `resolve` runs
    // otherwise: every driver count to 4, every strength but highz, widths
    // across the word boundaries, and random 0/1/x/z bits.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(0x7e9);
    const rand = prng.random();
    for ([_]u32{ 1, 63, 64, 65, 130 }) |width| for (1..5) |count| for (1..8) |level| {
        const s: Ast.Strength = @fromBackingInt(@intCast(level));
        var drivers: [4]Driver = undefined;
        for (drivers[0..count]) |*d| {
            d.* = .{ .net = 0, .source = .{ .pull = .z }, .sensitivity = &.{}, .current = try filled(a, width, false, .z), .s0 = s, .s1 = s };
            for (0..width) |i| setBit(d.current, @intCast(i), rand.enumValue(Int.Bit));
        }
        const ids = [_]u32{ 0, 1, 2, 3 };
        // Garbage above the width must not reach the result.
        const out = try filled(a, width, false, .x);
        foldUniform(out, drivers[0..count], ids[0..count]);
        for (0..width) |i| {
            var acc: Signal = .{};
            for (drivers[0..count]) |d| acc = acc.combine(.of(d.current.bit(@intCast(i)), d.s0, d.s1));
            try std.testing.expectEqual(acc.combine(netPull(.wire)).collapse(), out.bit(@intCast(i)));
        }
        const last = out.values().len - 1;
        try std.testing.expectEqual(@as(u64, 0), out.values()[last] & ~wordMask(width, last));
        try std.testing.expectEqual(@as(u64, 0), out.unknowns()[last] & ~wordMask(width, last));
    };
}
