//! The small-signal kernels as Zig source text: the H(jω) side of the
//! frequency-dependent operators (`ac_txt`) and `zAc`, the family `acDyn`
//! evaluates the core with (`ac_fam_txt`, device.zig only).
//! Cites: §4.5.7, §4.5.11, §4.5.12, §4.6.1.
//!
//! Contents:
//! - `pub const ac_txt`
//! - `pub const ac_fam_txt`

/// The small-signal side of the operators whose response depends on frequency
/// (`ir.op.acDynamic`): §4.5.7 `absdelay`, §4.5.11 `laplace_*`, §4.5.12
/// `zi_*`. At a small-signal point `eval` keeps their value and drops their
/// lanes (`zSs`), and `acDyn` supplies those slots: it evaluates the core with
/// `zAc(F)` (`ac_fam_txt`), whose operators multiply the lanes by H(jω) here.
/// `K` is a kernel scalar, `zL(zAc(F), m)`; `F` is `f64` or a vector of
/// frequencies. At ω = 0 each H is computed in the order the DC branch scales
/// by, so `acDyn` reads back exactly the static partial.
pub const ac_txt =
    \\// ---- §4.5.7/§4.5.11/§4.5.12 small-signal response ----
    \\
    \\/// An operator's output as `eval` sees it: under `.ac`/`.noise` the value
    \\/// alone, since `acDyn` supplies the operator's slots whole.
    \\fn zSs(comptime K: type, kind: contract.AnalysisKind, y: K) K {
    \\    return if (kind == .ac or kind == .noise) K.con(y.val()) else y;
    \\}
    \\/// §4.5.7 "Output(ω) = Input(ω) · e^(−jωtd)".
    \\fn zAcDelay(comptime K: type, vin: K, td: f64) K {
    \\    const A = @TypeOf(vin.v);
    \\    const p = vin.v.omega() * A.splat(td);
    \\    return .{ .v = vin.v.acMul(vin.val(), .init(@cos(p), -@sin(p))) };
    \\}
    \\/// §4.5.11 the cascade at s = jω, one section at a time as `zLaplace`'s
    \\/// DC branch scales, so ω = 0 is that branch's H(0) to the bit. `h0` is
    \\/// `zLaplaceH0(sec)`, passed in because this text also serves devices
    \\/// with no filter kernels.
    \\fn zAcLaplace(comptime K: type, comptime NS: usize, comptime D: usize, uin: K, sec: [NS][2][D + 1]f64, h0: [NS][2]f64) K {
    \\    const A = @TypeOf(uin.v);
    \\    const s: std.math.Complex(A.F) = .init(A.splat(0.0), uin.v.omega());
    \\    var y = uin.v;
    \\    var v = uin.val();
    \\    for (sec, h0) |sc, h| {
    \\        v *= h[0] / h[1];
    \\        y = y.acMul(v, zCDiv(A.F, zPolyC(A.F, D, sc[0], s), zPolyC(A.F, D, sc[1], s)));
    \\    }
    \\    return .{ .v = y };
    \\}
    \\/// §4.5.12 the cascade on the unit circle, z = e^(jωT), one section at a
    \\/// time as `zZiEval`'s DC branch scales, so ω = 0 is its H(1) to the bit.
    \\fn zAcZi(comptime K: type, comptime NS: usize, comptime D: usize, uin: K, sec: [NS][2][D + 1]f64, period: f64) K {
    \\    const A = @TypeOf(uin.v);
    \\    const p = uin.v.omega() * A.splat(period);
    \\    const zinv: std.math.Complex(A.F) = .init(@cos(p), -@sin(p));
    \\    var y = uin.v;
    \\    var v = uin.val();
    \\    for (sec) |sc| {
    \\        var num: f64 = 0.0;
    \\        var den: f64 = 0.0;
    \\        for (sc[0]) |c| num += c;
    \\        for (sc[1]) |c| den += c;
    \\        v *= num / den;
    \\        y = y.acMul(v, zCDiv(A.F, zPolyC(A.F, D, sc[0], zinv), zPolyC(A.F, D, sc[1], zinv)));
    \\    }
    \\    return .{ .v = y };
    \\}
    \\/// Σ p[k]·c^k, summed from 0 in ascending k: at c = 0 it is p[0], and at
    \\/// c = 1 the DC branches' own sum.
    \\fn zPolyC(comptime F: type, comptime D: usize, p: [D + 1]f64, c: std.math.Complex(F)) std.math.Complex(F) {
    \\    const zero: F = if (@typeInfo(F) == .vector) @splat(0.0) else 0.0;
    \\    const one: F = if (@typeInfo(F) == .vector) @splat(1.0) else 1.0;
    \\    var acc: std.math.Complex(F) = .init(zero, zero);
    \\    var ck: std.math.Complex(F) = .init(one, zero);
    \\    for (p) |pk| {
    \\        const k: F = if (@typeInfo(F) == .vector) @splat(pk) else pk;
    \\        acc = acc.add(.init(ck.re * k, ck.im * k));
    \\        ck = ck.mul(c);
    \\    }
    \\    return acc;
    \\}
    \\/// a/b by Smith's rule, the lane's larger part of b as divisor: a real b
    \\/// gives a.re/b.re exactly, and |b|² is never formed.
    \\fn zCDiv(comptime F: type, a: std.math.Complex(F), b: std.math.Complex(F)) std.math.Complex(F) {
    \\    const r1 = b.im / b.re;
    \\    const d1 = b.re + b.im * r1;
    \\    const r2 = b.re / b.im;
    \\    const d2 = b.im + b.re * r2;
    \\    const big = @abs(b.re) >= @abs(b.im);
    \\    const re1 = (a.re + a.im * r1) / d1;
    \\    const im1 = (a.im - a.re * r1) / d1;
    \\    const re2 = (a.re * r2 + a.im) / d2;
    \\    const im2 = (a.im * r2 - a.re) / d2;
    \\    if (@typeInfo(F) == .vector) return .init(@select(f64, big, re1, re2), @select(f64, big, im1, im2));
    \\    return if (big) .init(re1, im1) else .init(re2, im2);
    \\}
    \\
    \\
;

/// `zAc`, the family `acDyn` evaluates the core with. device.zig only: no unit
/// names it, and it reads `n_u`.
pub const ac_fam_txt =
    \\/// A dense family whose lanes are three blocks: `n_u` direct partials, then
    \\/// the real and imaginary parts of `n_u` complex partials, each an `F` of
    \\/// frequencies. `w` points at the ω `acDyn` probed with. A probe seeds the
    \\/// direct block and every operation but `acMul` scales the blocks alike, so
    \\/// after the core the complex blocks hold exactly the Jacobian that flowed
    \\/// through a frequency-dependent operator, times that operator's H(jω).
    \\fn zAc(comptime Fw: type) type {
    \\    return struct {
    \\        pub const V = f64;
    \\        const W = if (@typeInfo(Fw) == .vector) @typeInfo(Fw).vector.len else 1;
    \\        const N = n_u * (1 + 2 * W);
    \\        const Lanes = @Vector(N, f64);
    \\        pub fn Of(comptime _: u64) type {
    \\            return T;
    \\        }
    \\        pub fn con(c: f64) T {
    \\            return .{ .v = c };
    \\        }
    \\        pub fn probe(comptime u: usize, v: f64) T {
    \\            var t: T = .{ .v = v };
    \\            t.d[u] = 1.0;
    \\            return t;
    \\        }
    \\        pub fn sel(c: T, a: T, b: T) T {
    \\            return if (c.v != 0.0) a else b;
    \\        }
    \\        pub const T = struct {
    \\            v: f64,
    \\            d: [N]f64 = @splat(0.0),
    \\            /// Null on a value no probe reached, which has no lanes to rotate.
    \\            w: ?*const Fw = null,
    \\            pub const F = Fw;
    \\            pub fn splat(c: f64) F {
    \\                return if (@typeInfo(F) == .vector) @splat(c) else c;
    \\            }
    \\            pub fn omega(a: T) F {
    \\                return if (a.w) |p| p.* else splat(0.0);
    \\            }
    \\            fn k(c: f64) Lanes {
    \\                return @splat(c);
    \\            }
    \\            fn lv(a: T) Lanes {
    \\                return a.d;
    \\            }
    \\            fn mk(v: f64, d: Lanes, a: T, b: T) T {
    \\                return .{ .v = v, .d = d, .w = a.w orelse b.w };
    \\            }
    \\            fn map(a: T, v: f64, c: f64) T {
    \\                return .{ .v = v, .d = lv(a) * k(c), .w = a.w };
    \\            }
    \\            fn at(a: T, o: usize) F {
    \\                if (@typeInfo(F) == .vector) return a.d[o..][0..W].*;
    \\                return a.d[o];
    \\            }
    \\            fn put(a: *T, o: usize, x: F) void {
    \\                if (@typeInfo(F) == .vector) a.d[o..][0..W].* = x else a.d[o] = x;
    \\            }
    \\            /// The complex partial by unknown `u`, real and imaginary part.
    \\            pub fn acRe(a: T, u: usize) F {
    \\                return a.at(n_u + u * W);
    \\            }
    \\            pub fn acIm(a: T, u: usize) F {
    \\                return a.at(n_u * (1 + W) + u * W);
    \\            }
    \\            /// An operator output `y` whose small-signal response is `h`: the
    \\            /// input's direct and complex blocks, summed, times `h`.
    \\            pub fn acMul(a: T, y: f64, h: std.math.Complex(F)) T {
    \\                var o: T = .{ .v = y, .w = a.w };
    \\                for (0..n_u) |u| {
    \\                    const re = splat(a.d[u]) + a.acRe(u);
    \\                    const im = a.acIm(u);
    \\                    o.put(n_u + u * W, h.re * re - h.im * im);
    \\                    o.put(n_u * (1 + W) + u * W, h.re * im + h.im * re);
    \\                }
    \\                return o;
    \\            }
    \\            pub fn to(a: T, comptime _: u64) T {
    \\                return a;
    \\            }
    \\            pub fn val(a: T) f64 {
    \\                return a.v;
    \\            }
    \\            pub fn ddxAt(a: T, comptime u: usize) f64 {
    \\                return a.d[u];
    \\            }
    \\            pub fn add(a: T, b: T) T {
    \\                return mk(a.v + b.v, lv(a) + lv(b), a, b);
    \\            }
    \\            pub fn sub(a: T, b: T) T {
    \\                return mk(a.v - b.v, lv(a) - lv(b), a, b);
    \\            }
    \\            pub fn mul(a: T, b: T) T {
    \\                return mk(a.v * b.v, @mulAdd(Lanes, lv(b), k(a.v), lv(a) * k(b.v)), a, b);
    \\            }
    \\            pub fn div(a: T, b: T) T {
    \\                const qt = a.v / b.v;
    \\                return mk(qt, @mulAdd(Lanes, lv(b), k(-qt), lv(a)) * k(1.0 / b.v), a, b);
    \\            }
    \\            pub fn neg(a: T) T {
    \\                return .{ .v = -a.v, .d = -lv(a), .w = a.w };
    \\            }
    \\            pub fn scale(a: T, c: f64) T {
    \\                return map(a, a.v * c, c);
    \\            }
    \\            pub fn addC(a: T, c: f64) T {
    \\                return .{ .v = a.v + c, .d = a.d, .w = a.w };
    \\            }
    \\            pub fn exp(a: T) T {
    \\                const e = contract.gm.exp(a.v);
    \\                return map(a, e, e);
    \\            }
    \\            pub fn log(a: T) T {
    \\                return map(a, contract.gm.log(a.v), 1.0 / a.v);
    \\            }
    \\            pub fn expm1(a: T) T {
    \\                return map(a, contract.gm.expm1(a.v), contract.gm.exp(a.v));
    \\            }
    \\            pub fn log1p(a: T) T {
    \\                return map(a, contract.gm.log1p(a.v), 1.0 / (1.0 + a.v));
    \\            }
    \\            pub fn sqrt(a: T) T {
    \\                const s = @sqrt(a.v);
    \\                return map(a, s, if (s > 0.0) 0.5 / s else 0.0);
    \\            }
    \\            pub fn sin(a: T) T {
    \\                return map(a, contract.gm.sin(a.v), contract.gm.cos(a.v));
    \\            }
    \\            pub fn cos(a: T) T {
    \\                return map(a, contract.gm.cos(a.v), -contract.gm.sin(a.v));
    \\            }
    \\            pub fn tanh(a: T) T {
    \\                const th = contract.gm.tanh(a.v);
    \\                return map(a, th, 1.0 - th * th);
    \\            }
    \\            pub fn sinh(a: T) T {
    \\                return map(a, contract.gm.sinh(a.v), contract.gm.cosh(a.v));
    \\            }
    \\            pub fn cosh(a: T) T {
    \\                return map(a, contract.gm.cosh(a.v), contract.gm.sinh(a.v));
    \\            }
    \\            pub fn atan(a: T) T {
    \\                return map(a, contract.gm.atan(a.v), 1.0 / (1.0 + a.v * a.v));
    \\            }
    \\            pub fn pow(a: T, c: f64) T {
    \\                const p = contract.gm.pow(a.v, c);
    \\                const s = if (a.v != 0.0) c * p / a.v else c * contract.gm.pow(a.v, c - 1.0);
    \\                return map(a, p, if (std.math.isFinite(s)) s else 0.0);
    \\            }
    \\            pub fn lt(a: T, b: T) T {
    \\                return con(@floatFromInt(@intFromBool(a.v < b.v)));
    \\            }
    \\            pub fn le(a: T, b: T) T {
    \\                return con(@floatFromInt(@intFromBool(a.v <= b.v)));
    \\            }
    \\            pub fn eq(a: T, b: T) T {
    \\                return con(@floatFromInt(@intFromBool(a.v == b.v)));
    \\            }
    \\        };
    \\    };
    \\}
    \\
    \\
;
