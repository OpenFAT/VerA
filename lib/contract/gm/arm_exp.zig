//! An `f64` (or a vector of them) in, e^x out: ARM optimized-routines exp
//! (musl src/math exp.c, exp_data.c; Copyright (c) 2018, Arm Limited, MIT),
//! its fma-free variant, one implementation on every target (host, NVPTX,
//! AMDGCN). `arm_pow.zig` reuses the reduction (`expCore`) for pow's exp step.
//! Cites: C99 F.10.3.1 (exp's special cases); the bound is
//! docs/specification/Vague_Decisions.md, "Host math".
//!
//! Contract, held by `gm.zig`'s tests against an f128 oracle: error <= 0.52
//! ulp of the correctly rounded result for every finite x (ARM: 0.509 with
//! fma, 0.511 without); exp(+-0) = 1, exp(+inf) = +inf, exp(-inf) = +0, NaN
//! in -> NaN out; +inf above 0x1.62e42fefa39efp9 (709.78), gradual underflow
//! to +0 below -745.13; never negative. It replaces compiler_rt's exp (musl's
//! older FreeBSD exp, < 1 ulp), and is not bit-identical to it.
//!
//! Contents:
//! - `pub const sign_bias: u64`
//! - `pub fn armExp(x: f64) f64`
//! - `pub fn hexp(x: anytype) @TypeOf(x)`
//! - `pub inline fn expCore(x: f64, xtail: f64, sbias: u64) f64`
//! - `pub inline fn expMain(comptime T: type, x: T, xtail: T, sbias: u64) Reduced(T)`
//! - `pub fn Reduced(comptime T: type) type`

const std = @import("std");
const assert = std.debug.assert;
const bits = @import("bits.zig");
const UOf = bits.UOf;
const sp = bits.sp;
const asF = bits.asF;
const asU = bits.asU;
const top12 = bits.top12;

/// The `sbias` that makes `expCore` return `-exp(x)`: pow's sign of a
/// negative base raised to an odd integer.
pub const sign_bias: u64 = 0x800 << 7;

// exact_everywhere: these routines use no fma. `@mulAdd` is one rounding
// where the hardware fuses and a slow libcall where it does not (baseline
// x86-64), and a fused and an unfused build round differently, so the same
// device would give different bits on host, NVPTX and AMDGCN. ARM's fma-free
// variants are the ones used, measured (round 2, i9-14900HX): exp unchanged
// (it has no fma), log 10.1 -> 12.5 and pow 23.7 -> 28.0 TSC ticks/call,
// bounds unchanged at the measured precision (log <= 0.500, pow <= 0.505 ulp).
const exp_n = 128;
const exp_invln2n = 0x1.71547652b82fep0 * 128.0;
const exp_negln2hin = -0x1.62e42fefa0000p-8;
const exp_negln2lon = -0x1.cf79abc9e3b3ap-47;
const exp_shift = 0x1.8p52;
const exp_c2 = 0x1.ffffffffffdbdp-2;
const exp_c3 = 0x1.555555555543cp-3;
const exp_c4 = 0x1.55555cf172b91p-5;
const exp_c5 = 0x1.1111167a4d017p-7;

comptime {
    // `expMain` reduces k modulo the table's 128 entries by `%`, and indexes
    // two words per entry.
    assert(exp_n == 128);
    assert(exp_tab.len == 2 * exp_n);
}

/// ARM exp_data.c `tab`: 2^(k/128) ~= H[k]*(1 + T[k]); [2k] = bits of T[k],
/// [2k+1] = bits of H[k] - (k << 52)/128.
const exp_tab = [256]u64{
    0x0,                0x3ff0000000000000, 0x3c9b3b4f1a88bf6e, 0x3feff63da9fb3335,
    0xbc7160139cd8dc5d, 0x3fefec9a3e778061, 0xbc905e7a108766d1, 0x3fefe315e86e7f85,
    0x3c8cd2523567f613, 0x3fefd9b0d3158574, 0xbc8bce8023f98efa, 0x3fefd06b29ddf6de,
    0x3c60f74e61e6c861, 0x3fefc74518759bc8, 0x3c90a3e45b33d399, 0x3fefbe3ecac6f383,
    0x3c979aa65d837b6d, 0x3fefb5586cf9890f, 0x3c8eb51a92fdeffc, 0x3fefac922b7247f7,
    0x3c3ebe3d702f9cd1, 0x3fefa3ec32d3d1a2, 0xbc6a033489906e0b, 0x3fef9b66affed31b,
    0xbc9556522a2fbd0e, 0x3fef9301d0125b51, 0xbc5080ef8c4eea55, 0x3fef8abdc06c31cc,
    0xbc91c923b9d5f416, 0x3fef829aaea92de0, 0x3c80d3e3e95c55af, 0x3fef7a98c8a58e51,
    0xbc801b15eaa59348, 0x3fef72b83c7d517b, 0xbc8f1ff055de323d, 0x3fef6af9388c8dea,
    0x3c8b898c3f1353bf, 0x3fef635beb6fcb75, 0xbc96d99c7611eb26, 0x3fef5be084045cd4,
    0x3c9aecf73e3a2f60, 0x3fef54873168b9aa, 0xbc8fe782cb86389d, 0x3fef4d5022fcd91d,
    0x3c8a6f4144a6c38d, 0x3fef463b88628cd6, 0x3c807a05b0e4047d, 0x3fef3f49917ddc96,
    0x3c968efde3a8a894, 0x3fef387a6e756238, 0x3c875e18f274487d, 0x3fef31ce4fb2a63f,
    0x3c80472b981fe7f2, 0x3fef2b4565e27cdd, 0xbc96b87b3f71085e, 0x3fef24dfe1f56381,
    0x3c82f7e16d09ab31, 0x3fef1e9df51fdee1, 0xbc3d219b1a6fbffa, 0x3fef187fd0dad990,
    0x3c8b3782720c0ab4, 0x3fef1285a6e4030b, 0x3c6e149289cecb8f, 0x3fef0cafa93e2f56,
    0x3c834d754db0abb6, 0x3fef06fe0a31b715, 0x3c864201e2ac744c, 0x3fef0170fc4cd831,
    0x3c8fdd395dd3f84a, 0x3feefc08b26416ff, 0xbc86a3803b8e5b04, 0x3feef6c55f929ff1,
    0xbc924aedcc4b5068, 0x3feef1a7373aa9cb, 0xbc9907f81b512d8e, 0x3feeecae6d05d866,
    0xbc71d1e83e9436d2, 0x3feee7db34e59ff7, 0xbc991919b3ce1b15, 0x3feee32dc313a8e5,
    0x3c859f48a72a4c6d, 0x3feedea64c123422, 0xbc9312607a28698a, 0x3feeda4504ac801c,
    0xbc58a78f4817895b, 0x3feed60a21f72e2a, 0xbc7c2c9b67499a1b, 0x3feed1f5d950a897,
    0x3c4363ed60c2ac11, 0x3feece086061892d, 0x3c9666093b0664ef, 0x3feeca41ed1d0057,
    0x3c6ecce1daa10379, 0x3feec6a2b5c13cd0, 0x3c93ff8e3f0f1230, 0x3feec32af0d7d3de,
    0x3c7690cebb7aafb0, 0x3feebfdad5362a27, 0x3c931dbdeb54e077, 0x3feebcb299fddd0d,
    0xbc8f94340071a38e, 0x3feeb9b2769d2ca7, 0xbc87deccdc93a349, 0x3feeb6daa2cf6642,
    0xbc78dec6bd0f385f, 0x3feeb42b569d4f82, 0xbc861246ec7b5cf6, 0x3feeb1a4ca5d920f,
    0x3c93350518fdd78e, 0x3feeaf4736b527da, 0x3c7b98b72f8a9b05, 0x3feead12d497c7fd,
    0x3c9063e1e21c5409, 0x3feeab07dd485429, 0x3c34c7855019c6ea, 0x3feea9268a5946b7,
    0x3c9432e62b64c035, 0x3feea76f15ad2148, 0xbc8ce44a6199769f, 0x3feea5e1b976dc09,
    0xbc8c33c53bef4da8, 0x3feea47eb03a5585, 0xbc845378892be9ae, 0x3feea34634ccc320,
    0xbc93cedd78565858, 0x3feea23882552225, 0x3c5710aa807e1964, 0x3feea155d44ca973,
    0xbc93b3efbf5e2228, 0x3feea09e667f3bcd, 0xbc6a12ad8734b982, 0x3feea012750bdabf,
    0xbc6367efb86da9ee, 0x3fee9fb23c651a2f, 0xbc80dc3d54e08851, 0x3fee9f7df9519484,
    0xbc781f647e5a3ecf, 0x3fee9f75e8ec5f74, 0xbc86ee4ac08b7db0, 0x3fee9f9a48a58174,
    0xbc8619321e55e68a, 0x3fee9feb564267c9, 0x3c909ccb5e09d4d3, 0x3feea0694fde5d3f,
    0xbc7b32dcb94da51d, 0x3feea11473eb0187, 0x3c94ecfd5467c06b, 0x3feea1ed0130c132,
    0x3c65ebe1abd66c55, 0x3feea2f336cf4e62, 0xbc88a1c52fb3cf42, 0x3feea427543e1a12,
    0xbc9369b6f13b3734, 0x3feea589994cce13, 0xbc805e843a19ff1e, 0x3feea71a4623c7ad,
    0xbc94d450d872576e, 0x3feea8d99b4492ed, 0x3c90ad675b0e8a00, 0x3feeaac7d98a6699,
    0x3c8db72fc1f0eab4, 0x3feeace5422aa0db, 0xbc65b6609cc5e7ff, 0x3feeaf3216b5448c,
    0x3c7bf68359f35f44, 0x3feeb1ae99157736, 0xbc93091fa71e3d83, 0x3feeb45b0b91ffc6,
    0xbc5da9b88b6c1e29, 0x3feeb737b0cdc5e5, 0xbc6c23f97c90b959, 0x3feeba44cbc8520f,
    0xbc92434322f4f9aa, 0x3feebd829fde4e50, 0xbc85ca6cd7668e4b, 0x3feec0f170ca07ba,
    0x3c71affc2b91ce27, 0x3feec49182a3f090, 0x3c6dd235e10a73bb, 0x3feec86319e32323,
    0xbc87c50422622263, 0x3feecc667b5de565, 0x3c8b1c86e3e231d5, 0x3feed09bec4a2d33,
    0xbc91bbd1d3bcbb15, 0x3feed503b23e255d, 0x3c90cc319cee31d2, 0x3feed99e1330b358,
    0x3c8469846e735ab3, 0x3feede6b5579fdbf, 0xbc82dfcd978e9db4, 0x3feee36bbfd3f37a,
    0x3c8c1a7792cb3387, 0x3feee89f995ad3ad, 0xbc907b8f4ad1d9fa, 0x3feeee07298db666,
    0xbc55c3d956dcaeba, 0x3feef3a2b84f15fb, 0xbc90a40e3da6f640, 0x3feef9728de5593a,
    0xbc68d6f438ad9334, 0x3feeff76f2fb5e47, 0xbc91eee26b588a35, 0x3fef05b030a1064a,
    0x3c74ffd70a5fddcd, 0x3fef0c1e904bc1d2, 0xbc91bdfbfa9298ac, 0x3fef12c25bd71e09,
    0x3c736eae30af0cb3, 0x3fef199bdd85529c, 0x3c8ee3325c9ffd94, 0x3fef20ab5fffd07a,
    0x3c84e08fd10959ac, 0x3fef27f12e57d14b, 0x3c63cdaf384e1a67, 0x3fef2f6d9406e7b5,
    0x3c676b2c6c921968, 0x3fef3720dcef9069, 0xbc808a1883ccb5d2, 0x3fef3f0b555dc3fa,
    0xbc8fad5d3ffffa6f, 0x3fef472d4a07897c, 0xbc900dae3875a949, 0x3fef4f87080d89f2,
    0x3c74a385a63d07a7, 0x3fef5818dcfba487, 0xbc82919e2040220f, 0x3fef60e316c98398,
    0x3c8e5a50d5c192ac, 0x3fef69e603db3285, 0x3c843a59ac016b4b, 0x3fef7321f301b460,
    0xbc82d52107b43e1f, 0x3fef7c97337b9b5f, 0xbc892ab93b470dc9, 0x3fef864614f5a129,
    0x3c74b604603a88d3, 0x3fef902ee78b3ff6, 0x3c83c5ec519d7271, 0x3fef9a51fbc74c83,
    0xbc8ff7128fd391f0, 0x3fefa4afa2a490da, 0xbc8dae98e223747d, 0x3fefaf482d8e67f1,
    0x3c8ec3bc41aa2008, 0x3fefba1bee615a27, 0x3c842b94c3a9eb32, 0x3fefc52b376bba97,
    0x3c8a64a931d185ee, 0x3fefd0765b6e4540, 0xbc8e37bae43be3ed, 0x3fefdbfdad9cbe14,
    0x3c77893b4d91cd9d, 0x3fefe7c1819e90d8, 0x3c5305c14160cc89, 0x3feff3c22b8f71f1,
};

/// exp(x), the contract in this file's header.
pub fn armExp(x: f64) f64 {
    const abstop = top12(x) & 0x7ff;
    if (abstop < top12(0x1p-28)) return expSmall(x);
    if (abstop >= top12(512.0)) {
        @branchHint(.unlikely);
        if (abstop >= 0x7ff) return if (asU(x) == asU(-std.math.inf(f64))) 0.0 else 1.0 + x; // +-inf, NaN
        // The results `expSpecial` would round to anyway, without it
        // (a decaying history term reaches here every step): exp(x)
        // rounds to +0 below this double (it is above -1075 ln2, the
        // next one below is not) and to +inf above ln(DBL_MAX).
        if (x < -0x1.74910d52d3051p9) return 0.0;
        if (x > 0x1.62e42fefa39efp9) return std.math.inf(f64);
    }
    const e = expCore(x, 0.0, 0);
    assert(!(e < 0.0)); // Never negative, with no sign bias.
    assert(!std.math.isNan(e)); // A NaN x returned above.
    return e;
}

/// exp(x) for `f64` or `@Vector(n, f64)`; the contract is `armExp`'s. A
/// vector whose lanes are all ordinary (|x| in [2^-54, 512)) runs the table
/// arithmetic on the whole vector; any other takes `armExp` lane by lane.
/// Either way a lane is the scalar call's bits.
pub fn hexp(x: anytype) @TypeOf(x) {
    const T = @TypeOf(x);
    switch (@typeInfo(T)) {
        .vector => |v| {
            const U = UOf(T);
            const abstop = bits.shrU(@as(U, @bitCast(x)), 52) & sp(U, 0x7ff);
            const ordinary = abstop -% sp(U, top12(0x1p-54)) < sp(U, top12(512.0) - top12(0x1p-54));
            if (!@reduce(.And, ordinary)) {
                @branchHint(.unlikely);
                // SAFETY: the loop writes every lane.
                var out: T = undefined;
                inline for (0..v.len) |l| out[l] = armExp(x[l]);
                return out;
            }
            const m = expMain(T, x, sp(T, 0.0), 0);
            const scale: T = @bitCast(m.sbits);
            // `expSmall`'s lanes: the scalar call's branch, as a select.
            const small = abstop < sp(U, top12(0x1p-28));
            return @select(f64, small, expSmall(x), scale + scale * m.tmp);
        },
        else => return armExp(x),
    }
}

/// `pow.c` `exp_inline`: exp(x + xtail), negated when `sbias` is
/// `sign_bias`. Asserts that `sbias` is 0 or `sign_bias`; the caller keeps
/// |xtail| < 2^-8/128.
pub inline fn expCore(x: f64, xtail: f64, sbias: u64) f64 {
    assert(sbias == 0 or sbias == sign_bias);
    var abstop = top12(x) & 0x7ff;
    if (abstop -% top12(0x1p-54) >= top12(512.0) -% top12(0x1p-54)) {
        @branchHint(.unlikely);
        if (abstop -% top12(0x1p-54) >= 0x80000000) {
            // Tiny x (0 included): 1 + x rounds right.
            const one = 1.0 + x;
            return if (sbias != 0) -one else one;
        }
        if (abstop >= top12(1024.0)) {
            const inf = std.math.inf(f64);
            const r: f64 = if (asU(x) >> 63 != 0) 0.0 else inf;
            return if (sbias != 0) -r else r;
        }
        abstop = 0; // large |x|: `expSpecial` below
    }
    // exp(x) = 2^(k/N) * exp(r), r in [-ln2/2N, ln2/2N].
    const m = expMain(f64, x, xtail, sbias);
    if (abstop == 0) {
        @branchHint(.unlikely);
        return expSpecial(m.tmp, m.sbits, m.ki);
    }
    const scale = asF(m.sbits);
    assert(abstop != 0);
    return scale + scale * m.tmp;
}

/// What `expMain` returns for `T`: exp(x + xtail) ~= scale * (1 + tmp), with
/// `sbits` the bits of scale and `ki` the reduction's k.
pub fn Reduced(comptime T: type) type {
    return struct { tmp: T, sbits: UOf(T), ki: UOf(T) };
}

/// `exp_inline`'s ordinary-input arithmetic: the reduction's k, the table's
/// scale and the polynomial in the reduced argument. Asserts that `sbias`
/// is 0 or `sign_bias`; the caller keeps x ordinary (|x| in [2^-54, 512) or
/// the `expSpecial` range).
pub inline fn expMain(comptime T: type, x: T, xtail: T, sbias: u64) Reduced(T) {
    assert(sbias == 0 or sbias == sign_bias);
    const U = UOf(T);
    const z = sp(T, exp_invln2n) * x;
    var kd = z + sp(T, exp_shift);
    const ki: U = @bitCast(kd);
    kd -= sp(T, exp_shift);
    var r = x + kd * sp(T, exp_negln2hin) + kd * sp(T, exp_negln2lon);
    r += xtail;
    const idx = bits.shl(ki % sp(U, exp_n), 1);
    const top = bits.shl(ki +% sp(U, sbias), 52 - 7);
    const tail: T = @bitCast(bits.gather(u64, &exp_tab, idx));
    const sbits = bits.gather(u64, &exp_tab, idx + sp(U, 1)) +% top;
    const r2 = r * r;
    const tmp = tail + r + r2 * (sp(T, exp_c2) + r * sp(T, exp_c3)) + r2 * r2 * (sp(T, exp_c4) + r * sp(T, exp_c5));
    return .{ .tmp = tmp, .sbits = sbits, .ki = ki };
}

// ---- private ----

/// exp(x) for |x| < 2^-28: 1 + (x + x^2/2), the next term below
/// 2^-86 relative, so one final rounding (<= 0.5 + 2^-30 ulp). Cheaper
/// than the table path for the near-zero arguments a history decay
/// factor exp(-a*dt) feeds every step (coupled_ltra: all of them).
inline fn expSmall(x: anytype) @TypeOf(x) {
    const T = @TypeOf(x);
    return sp(T, 1.0) + (x + x * x * sp(T, 0.5));
}

/// `pow.c` `specialcase`: scale * (1 + tmp) where scale's exponent may
/// have left the normal range (`ki` the reduction's k).
fn expSpecial(tmp: f64, sbits0: u64, ki: u64) f64 {
    assert(!std.math.isNan(tmp)); // The reduction of a finite x.
    var sbits = sbits0;
    if (ki & 0x80000000 == 0) {
        // k > 0: the exponent of scale may have overflowed by <= 460.
        sbits -%= 1009 << 52;
        const scale = asF(sbits);
        return 0x1p1009 * (scale + scale * tmp);
    }
    // k < 0: round in the normal range first, then scale into the
    // subnormal one, so there is no double rounding.
    sbits +%= 1022 << 52;
    const scale = asF(sbits);
    var y = scale + scale * tmp;
    if (@abs(y) < 1.0) {
        const one: f64 = if (y < 0.0) -1.0 else 1.0;
        var lo = scale - y + scale * tmp;
        const hi = one + y;
        lo = one - hi + y + lo;
        y = (hi + lo) - one;
        if (y == 0.0) y = asF(sbits & 0x8000000000000000);
    }
    assert(!(y < 0.0) or sbits >> 63 != 0); // A negative result only under the sign bias.
    return 0x1p-1022 * y;
}
