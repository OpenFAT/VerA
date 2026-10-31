//! IEEE 1364-2005 integer arithmetic at any width: operands of a stated
//! width and signedness in, the result bit pattern at that width out. Device
//! text (`text.wide`) for every device whose analog context computes a `reg`
//! wider than 32 bits; VAMS §7.3.1 gives the analog context read access to a
//! discrete bit grouping, and a `reg` it assigns is computed with the bits
//! IEEE 1364 gives it (`analog/wide.zig` sizes each operand).
//! Cites: IEEE 1364-2005 §4.8.2, §5.1.5 (Table 5-6), §5.1.7-§5.1.12, §5.4,
//! §5.5; VAMS §7.3.1, §7.3.2; docs/specification/Vague_Decisions.md VD-116;
//! Knuth TAOCP vol. 2 §4.3.1 (Algorithm D).
//!
//! A value `n` bits wide is `ZW(n)`: one native unsigned integer up to
//! `zw_native_max` bits, above that 32-bit limbs, least significant first,
//! whose bits past `n` are always zero. Every function takes the width
//! first, so one call spelling serves both representations, and returns by
//! value; nothing allocates, so a device may run these on a GPU. A bit
//! pattern carries no sign: the signed operations take `signed` from the
//! operand type. The analog context has no x or z (§7.3.2), so the
//! operations that yield x in IEEE 1364 yield 0 here: division or remainder
//! by zero, and zero to a negative power (VD-116).
//!
//! Contents:
//! - `pub const zw_native_max: u32`
//! - `pub const zwL = struct` (the limb algorithms: `norm`, `one`, `from64`, `low64`, `resize`, `add`, `sub`, `not`, `bit`, `mul`, `shl`, `shr`, `toReal`, `divRem`)
//! - `pub fn ZW(comptime n: u32) type`
//! - `pub fn zwLimbs(comptime n: u32) u32`
//! - `pub fn zwZero(comptime n: u32) ZW(n)`
//! - `pub fn zwLeaf(comptime n: u32, x: i64) ZW(n)`
//! - `pub fn zwWords(comptime n: u32, w: [zwLimbs(n)]i64) ZW(n)`
//! - `pub fn zwConst(comptime n: u32, comptime w: [zwLimbs(n)]u32) ZW(n)`
//! - `pub fn zwInt(comptime n: u32, comptime signed: bool, a: ZW(n)) i64`
//! - `pub fn zwToLimbs(comptime n: u32, a: ZW(n)) [zwLimbs(n)]u32`
//! - `pub fn zwFromLimbs(comptime n: u32, l: [zwLimbs(n)]u32) ZW(n)`
//! - `pub fn zwResize(comptime to: u32, comptime from: u32, comptime signed: bool, a: ZW(from)) ZW(to)`
//! - `pub fn zwAdd`, `zwSub`, `zwMul`, `zwAnd`, `zwOr`, `zwXor`, `zwXnor` `(comptime n: u32, a: ZW(n), b: ZW(n)) ZW(n)`
//! - `pub fn zwNeg`, `zwNot` `(comptime n: u32, a: ZW(n)) ZW(n)`
//! - `pub fn zwDiv`, `zwRem` `(comptime n: u32, comptime signed: bool, a: ZW(n), b: ZW(n)) ZW(n)`
//! - `pub fn zwShl(comptime n: u32, a: ZW(n), comptime cn: u32, c: ZW(cn)) ZW(n)`
//! - `pub fn zwShr(comptime n: u32, comptime arith: bool, a: ZW(n), comptime cn: u32, c: ZW(cn)) ZW(n)`
//! - `pub fn zwPow(comptime n: u32, comptime signed: bool, a: ZW(n), comptime en: u32, comptime esigned: bool, e: ZW(en)) ZW(n)`
//! - `pub fn zwBit(comptime n: u32, a: ZW(n), k: u32) bool`
//! - `pub fn zwIsZero(comptime n: u32, a: ZW(n)) bool`
//! - `pub fn zwEq(comptime n: u32, a: ZW(n), b: ZW(n)) bool`
//! - `pub fn zwLt(comptime n: u32, comptime signed: bool, a: ZW(n), b: ZW(n)) bool`
//! - `pub fn zwAll(comptime n: u32, a: ZW(n)) bool`
//! - `pub fn zwParity(comptime n: u32, a: ZW(n)) bool`
//! - `pub fn zwToReal(comptime n: u32, comptime signed: bool, a: ZW(n)) f64`
//! - `pub fn zwFromReal(comptime n: u32, x: f64) ZW(n)`

const zwstd = @import("std");

// ---- device text ----

/// Widths up to this many bits compute as one native integer, wider ones as
/// limbs. Measured (x86_64, ReleaseFast, a mix of + - * / % << >> < ==):
/// native is 4-17x faster than limbs up to 128 bits, 2.2x slower at 192 and
/// 4.3x slower at 320.
pub const zw_native_max: u32 = 128;

/// The limb algorithms, for any `n` (the tests run them at native widths
/// too). Each takes and returns `n`-bit limbs whose bits past `n` are zero.
pub const zwL = struct {
    /// Returns `a` with its bits past `n` cleared.
    pub fn norm(comptime n: u32, a: L(n)) L(n) {
        var r = a;
        r[zwLimbs(n) - 1] &= topMask(n);
        zwstd.debug.assert(r[zwLimbs(n) - 1] & ~topMask(n) == 0);
        return r;
    }

    /// Returns the value 1.
    pub fn one(comptime n: u32) L(n) {
        var r = zwstd.mem.zeroes(L(n));
        r[0] = 1;
        return r;
    }

    /// Returns `x` as limbs. Bits past `n` are not cleared: `zwLeaf` `norm`s
    /// after.
    pub fn from64(comptime n: u32, x: u64) L(n) {
        var r = zwstd.mem.zeroes(L(n));
        r[0] = @truncate(x);
        if (comptime zwLimbs(n) > 1) r[1] = @truncate(x >> 32);
        return r;
    }

    /// Returns the low 64 bits.
    pub fn low64(comptime n: u32, a: L(n)) u64 {
        const hi: u64 = if (comptime zwLimbs(n) > 1) a[1] else 0;
        return (hi << 32) | a[0];
    }

    /// Returns `zwResize` on limbs: cut, or extended by the sign bit when
    /// `signed`.
    pub fn resize(comptime to: u32, comptime from: u32, signed: bool, a: L(from)) L(to) {
        const fill: u32 = if (signed and zwBit(from, zwFromLimbs(from, a), from - 1)) 0xffff_ffff else 0;
        // Sign-fill the source's top limb above `from` first, so a copy that
        // keeps that limb whole extends correctly.
        var src = a;
        src[zwLimbs(from) - 1] |= fill & ~topMask(from);
        var r: L(to) = undefined;
        for (&r, 0..) |*d, i| d.* = if (i < zwLimbs(from)) src[i] else fill;
        return norm(to, r);
    }

    /// Returns `zwAdd` on limbs: ripple carry.
    pub fn add(comptime n: u32, a: L(n), b: L(n)) L(n) {
        var r: L(n) = undefined;
        var c: u64 = 0;
        for (&r, a, b) |*d, x, y| {
            c += @as(u64, x) + y;
            d.* = @truncate(c);
            c >>= 32;
        }
        zwstd.debug.assert(c <= 1);
        return norm(n, r);
    }

    /// Returns `zwSub` on limbs: `a + ~b + 1`.
    pub fn sub(comptime n: u32, a: L(n), b: L(n)) L(n) {
        var r: L(n) = undefined;
        var c: u64 = 1;
        for (&r, a, b) |*d, x, y| {
            c += @as(u64, x) + ~y;
            d.* = @truncate(c);
            c >>= 32;
        }
        zwstd.debug.assert(c <= 1);
        return norm(n, r);
    }

    /// Returns `zwNot` on limbs.
    pub fn not(comptime n: u32, a: L(n)) L(n) {
        var r: L(n) = undefined;
        for (&r, a) |*d, x| d.* = ~x;
        return norm(n, r);
    }

    /// Returns `zwAnd`, `zwOr` or `zwXor` on limbs, by `op`.
    pub fn bit(comptime n: u32, comptime op: enum { @"and", @"or", xor }, a: L(n), b: L(n)) L(n) {
        var r: L(n) = undefined;
        for (&r, a, b) |*d, x, y| d.* = switch (op) {
            .@"and" => x & y,
            .@"or" => x | y,
            .xor => x ^ y,
        };
        return r;
    }

    /// Returns the low `n` bits of `a * b`: schoolbook, each row cut at limb k.
    pub fn mul(comptime n: u32, a: L(n), b: L(n)) L(n) {
        const k = zwLimbs(n);
        var r = zwstd.mem.zeroes(L(n));
        for (0..k) |i| {
            if (a[i] == 0) continue;
            var c: u64 = 0;
            for (0..k - i) |j| {
                const t = @as(u64, a[i]) * b[j] + r[i + j] + c;
                r[i + j] = @truncate(t);
                c = t >> 32;
            }
        }
        return norm(n, r);
    }

    /// Returns `a << s`; a count of `n` or more clears every bit.
    pub fn shl(comptime n: u32, a: L(n), s: u64) L(n) {
        if (s >= n) return zwstd.mem.zeroes(L(n));
        const k = zwLimbs(n);
        const ws: usize = @intCast(s / 32);
        const bs: u5 = @intCast(s % 32);
        zwstd.debug.assert(ws < k);
        var r = zwstd.mem.zeroes(L(n));
        var i: usize = k;
        while (i > ws) {
            i -= 1;
            const lo = a[i - ws];
            const below: u32 = if (i - ws > 0) a[i - ws - 1] else 0;
            r[i] = if (bs == 0) lo else (lo << bs) | (below >> @intCast(32 - @as(u6, bs)));
        }
        return norm(n, r);
    }

    /// Returns `a >> s`, filled with the sign bit when `arith`; a count of
    /// `n` or more leaves only the fill.
    pub fn shr(comptime n: u32, arith: bool, a: L(n), s: u64) L(n) {
        const k = zwLimbs(n);
        const fill: u32 = if (arith and zwBit(n, zwFromLimbs(n, a), n - 1)) 0xffff_ffff else 0;
        var src = a;
        src[k - 1] |= fill & ~topMask(n);
        var r: L(n) = undefined;
        if (s >= n) {
            @memset(&r, fill);
            return norm(n, r);
        }
        const ws: usize = @intCast(s / 32);
        const bs: u5 = @intCast(s % 32);
        zwstd.debug.assert(ws < k);
        for (&r, 0..) |*d, i| {
            const lo: u32 = if (i + ws < k) src[i + ws] else fill;
            const hi: u32 = if (i + ws + 1 < k) src[i + ws + 1] else fill;
            d.* = if (bs == 0) lo else (lo >> bs) | (hi << @intCast(32 - @as(u6, bs)));
        }
        return norm(n, r);
    }

    /// Returns the nearest double to unsigned `a`, ties to even: the top 64
    /// bits, with every bit below them folded into the last as a sticky bit.
    pub fn toReal(comptime n: u32, a: L(n)) f64 {
        var i: usize = zwLimbs(n);
        while (i > 0 and a[i - 1] == 0) i -= 1;
        if (i == 0) return 0;
        const top: u64 = 32 * (i - 1) + (32 - @clz(a[i - 1])); // bits in use
        if (top <= 64) return @floatFromInt(low64(n, a));
        const lo = top - 64;
        zwstd.debug.assert(lo < n);
        const sh = shr(n, false, a, lo);
        var m = low64(n, sh);
        zwstd.debug.assert(m >> 63 == 1); // the top bit in use lands on bit 63
        // Sticky: any one bit below `lo`.
        const ws: usize = @intCast(lo / 32);
        var sticky = false;
        for (a[0..ws]) |d| sticky = sticky or d != 0;
        if (lo % 32 != 0) sticky = sticky or (a[ws] & ((@as(u32, 1) << @intCast(lo % 32)) - 1)) != 0;
        if (sticky) m |= 1;
        return zwstd.math.ldexp(@as(f64, @floatFromInt(m)), @intCast(lo));
    }

    /// Returns the unsigned or signed (two's complement) truncating division
    /// of `a` by `b`: the quotient, or the remainder when `rem`. By zero 0.
    pub fn divRem(comptime n: u32, signed: bool, rem: bool, a: L(n), b: L(n)) L(n) {
        const zero = zwstd.mem.zeroes(L(n));
        if (zwstd.mem.eql(u32, &b, &zero)) return zero;
        const na = signed and zwBit(n, zwFromLimbs(n, a), n - 1);
        const nb = signed and zwBit(n, zwFromLimbs(n, b), n - 1);
        const ma = if (na) sub(n, zero, a) else a;
        const mb = if (nb) sub(n, zero, b) else b;
        var q: L(n) = undefined;
        var r: L(n) = undefined;
        divmod(n, ma, mb, &q, &r);
        if (rem) return if (na) sub(n, zero, r) else r;
        return if (na != nb) sub(n, zero, q) else q;
    }

    // ---- private ----

    fn L(comptime n: u32) type {
        return [zwLimbs(n)]u32;
    }

    fn topMask(comptime n: u32) u32 {
        const r = n % 32;
        return if (r == 0) 0xffff_ffff else (@as(u32, 1) << r) - 1;
    }

    /// Unsigned `a / b` and `a % b`, `b` nonzero: Knuth's Algorithm D on
    /// 32-bit digits, as Hacker's Delight `divmnu` writes it. Out of line, so
    /// its scratch is its own frame's.
    noinline fn divmod(comptime n: u32, a: L(n), b: L(n), q: *L(n), r: *L(n)) void {
        const k = zwLimbs(n);
        q.* = zwstd.mem.zeroes(L(n));
        r.* = zwstd.mem.zeroes(L(n));
        var m: usize = k;
        while (m > 0 and a[m - 1] == 0) m -= 1;
        var nn: usize = k;
        while (nn > 0 and b[nn - 1] == 0) nn -= 1;
        zwstd.debug.assert(nn > 0); // divRem returns 0 for a zero divisor
        if (m < nn) {
            r.* = a;
            return;
        }
        if (nn == 1) {
            var c: u64 = 0;
            var j: usize = m;
            while (j > 0) {
                j -= 1;
                const t = (c << 32) | a[j];
                q[j] = @truncate(t / b[0]);
                c = t % b[0];
            }
            r[0] = @truncate(c);
            return;
        }
        // Normalize so the divisor's top digit has its high bit set.
        const s: u5 = @intCast(@clz(b[nn - 1]));
        var vn: [zwLimbs(n)]u32 = undefined;
        var un: [zwLimbs(n) + 1]u32 = undefined;
        var i: usize = nn - 1;
        while (i > 0) : (i -= 1) vn[i] = shlPair(b[i], b[i - 1], s);
        vn[0] = b[0] << s;
        zwstd.debug.assert(vn[nn - 1] >> 31 == 1);
        un[m] = if (s == 0) 0 else a[m - 1] >> @intCast(32 - @as(u6, s));
        i = m - 1;
        while (i > 0) : (i -= 1) un[i] = shlPair(a[i], a[i - 1], s);
        un[0] = a[0] << s;
        var j: usize = m - nn + 1;
        while (j > 0) {
            j -= 1;
            const num = (@as(u64, un[j + nn]) << 32) | un[j + nn - 1];
            var qhat = num / vn[nn - 1];
            var rhat = num % vn[nn - 1];
            // Knuth: with a normalized divisor qhat is at most 2 too large.
            var fixes: u32 = 0;
            while (qhat >= (1 << 32) or qhat * vn[nn - 2] > ((rhat << 32) | un[j + nn - 2])) : (fixes += 1) {
                zwstd.debug.assert(fixes < 2);
                qhat -= 1;
                rhat += vn[nn - 1];
                if (rhat >= (1 << 32)) break;
            }
            // Multiply and subtract.
            var borrow: i64 = 0;
            var t: i64 = 0;
            for (0..nn) |x| {
                const p: u64 = qhat * vn[x];
                t = @as(i64, un[x + j]) - borrow - @as(i64, @intCast(p & 0xffff_ffff));
                un[x + j] = @truncate(@as(u64, @bitCast(t)));
                borrow = @as(i64, @intCast(p >> 32)) - (t >> 32);
            }
            t = @as(i64, un[j + nn]) - borrow;
            un[j + nn] = @truncate(@as(u64, @bitCast(t)));
            q[j] = @truncate(qhat);
            if (t < 0) {
                // Add back.
                q[j] -%= 1;
                var c: u64 = 0;
                for (0..nn) |x| {
                    c += @as(u64, un[x + j]) + vn[x];
                    un[x + j] = @truncate(c);
                    c >>= 32;
                }
                un[j + nn] +%= @truncate(c);
            }
        }
        // Unnormalize the remainder.
        for (0..nn) |x| r[x] = if (s == 0) un[x] else (un[x] >> s) | (un[x + 1] << @intCast(32 - @as(u6, s)));
    }

    fn shlPair(hi: u32, lo: u32, s: u5) u32 {
        return if (s == 0) hi else (hi << s) | (lo >> @intCast(32 - @as(u6, s)));
    }
};

/// Returns the type of an `n`-bit value.
pub fn ZW(comptime n: u32) type {
    return if (n <= zw_native_max) @Int(.unsigned, n) else [zwLimbs(n)]u32;
}

/// Returns the 32-bit limbs `n` bits take.
pub fn zwLimbs(comptime n: u32) u32 {
    return (n + 31) / 32;
}

/// Returns the value with every bit zero.
pub fn zwZero(comptime n: u32) ZW(n) {
    return if (comptime zwNative(n)) 0 else zwstd.mem.zeroes([zwLimbs(n)]u32);
}

/// Returns `x`'s 64-bit pattern at `n` bits, cut or zero-extended: an
/// analog integer or real-pattern operand.
pub fn zwLeaf(comptime n: u32, x: i64) ZW(n) {
    const u: u64 = @bitCast(x);
    if (comptime zwNative(n)) return @truncate(u);
    return zwL.norm(n, zwL.from64(n, u));
}

/// Returns the value whose 32-bit words, least significant first, are the
/// low 32 bits of each of `w`: a discrete input's `Model` words.
pub fn zwWords(comptime n: u32, w: [zwLimbs(n)]i64) ZW(n) {
    var l: [zwLimbs(n)]u32 = undefined;
    for (&l, w) |*d, s| d.* = @truncate(@as(u64, @bitCast(s)));
    return zwFromLimbs(n, zwL.norm(n, l));
}

/// Returns a literal from its 32-bit words, least significant first.
pub fn zwConst(comptime n: u32, comptime w: [zwLimbs(n)]u32) ZW(n) {
    return comptime zwFromLimbs(n, zwL.norm(n, w));
}

/// Returns `a`'s value as the analog integer a select reads (§7.3.1): `n`
/// <= 64 bits, zero-extended, or sign-extended when `signed`.
pub fn zwInt(comptime n: u32, comptime signed: bool, a: ZW(n)) i64 {
    comptime zwstd.debug.assert(n <= 64);
    const x: @Int(.unsigned, n) = if (comptime zwNative(n)) a else @truncate(zwL.low64(n, a));
    if (signed) return @as(ZS(n), @bitCast(x));
    return x;
}

/// Returns `a` as limbs, whichever representation `ZW(n)` is.
pub fn zwToLimbs(comptime n: u32, a: ZW(n)) [zwLimbs(n)]u32 {
    if (comptime !zwNative(n)) return a;
    var r: [zwLimbs(n)]u32 = undefined;
    inline for (&r, 0..) |*d, i| d.* = @truncate(@as(@Int(.unsigned, 32 * zwLimbs(n)), a) >> (32 * i));
    return r;
}

/// Returns limbs `l` (bits past `n` zero) as `ZW(n)`.
pub fn zwFromLimbs(comptime n: u32, l: [zwLimbs(n)]u32) ZW(n) {
    if (comptime !zwNative(n)) return l;
    var r: @Int(.unsigned, n) = 0;
    inline for (l, 0..) |d, i| r |= @as(@Int(.unsigned, n), @truncate(@as(@Int(.unsigned, 32 * zwLimbs(n)), d) << (32 * i)));
    return r;
}

/// Returns `a` (`from` bits) converted to `to` bits (IEEE 1364 §5.5.2),
/// sign-extended only when the propagated type is `signed`.
pub fn zwResize(comptime to: u32, comptime from: u32, comptime signed: bool, a: ZW(from)) ZW(to) {
    if (comptime zwNative(to) and zwNative(from)) {
        if (to == from) return a;
        if (to < from) return @truncate(a);
        if (!signed) return a;
        return @bitCast(@as(ZS(to), @as(ZS(from), @bitCast(a))));
    }
    return zwFromLimbs(to, zwL.resize(to, from, signed, zwToLimbs(from, a)));
}

/// Returns IEEE 1364 §5.1.5 `+`, wrapping at `n` bits.
pub fn zwAdd(comptime n: u32, a: ZW(n), b: ZW(n)) ZW(n) {
    return if (comptime zwNative(n)) a +% b else zwL.add(n, a, b);
}

/// Returns IEEE 1364 §5.1.5 `-`, wrapping at `n` bits.
pub fn zwSub(comptime n: u32, a: ZW(n), b: ZW(n)) ZW(n) {
    return if (comptime zwNative(n)) a -% b else zwL.sub(n, a, b);
}

/// Returns IEEE 1364 §5.1.5 `*`: the low `n` bits of the product.
pub fn zwMul(comptime n: u32, a: ZW(n), b: ZW(n)) ZW(n) {
    return if (comptime zwNative(n)) a *% b else zwL.mul(n, a, b);
}

/// Returns IEEE 1364 §5.1.10 `&`, two-state (§7.3.2: no x or z here).
pub fn zwAnd(comptime n: u32, a: ZW(n), b: ZW(n)) ZW(n) {
    return if (comptime zwNative(n)) a & b else zwL.bit(n, .@"and", a, b);
}

/// Returns IEEE 1364 §5.1.10 `|`, two-state.
pub fn zwOr(comptime n: u32, a: ZW(n), b: ZW(n)) ZW(n) {
    return if (comptime zwNative(n)) a | b else zwL.bit(n, .@"or", a, b);
}

/// Returns IEEE 1364 §5.1.10 `^`, two-state.
pub fn zwXor(comptime n: u32, a: ZW(n), b: ZW(n)) ZW(n) {
    return if (comptime zwNative(n)) a ^ b else zwL.bit(n, .xor, a, b);
}

/// Returns IEEE 1364 §5.1.10 `~^`, two-state.
pub fn zwXnor(comptime n: u32, a: ZW(n), b: ZW(n)) ZW(n) {
    return zwNot(n, zwXor(n, a, b));
}

/// Returns IEEE 1364 §5.1.5 unary `-`: the two's complement at `n` bits.
pub fn zwNeg(comptime n: u32, a: ZW(n)) ZW(n) {
    return if (comptime zwNative(n)) 0 -% a else zwL.sub(n, zwZero(n), a);
}

/// Returns IEEE 1364 §5.1.10 `~`; the bits past `n` stay zero.
pub fn zwNot(comptime n: u32, a: ZW(n)) ZW(n) {
    return if (comptime zwNative(n)) ~a else zwL.not(n, a);
}

/// Returns IEEE 1364 §5.1.5 `/`: truncating; by zero 0 (x there); the most
/// negative value over -1 wraps to itself.
pub fn zwDiv(comptime n: u32, comptime signed: bool, a: ZW(n), b: ZW(n)) ZW(n) {
    if (comptime zwNative(n)) {
        if (b == 0) return 0;
        if (!signed) return a / b;
        if (b == zwstd.math.maxInt(ZW(n))) return 0 -% a;
        return @bitCast(@divTrunc(@as(ZS(n), @bitCast(a)), @as(ZS(n), @bitCast(b))));
    }
    return zwL.divRem(n, signed, false, a, b);
}

/// Returns IEEE 1364 §5.1.5 `%`: the sign of the first operand; by zero 0
/// (x there).
pub fn zwRem(comptime n: u32, comptime signed: bool, a: ZW(n), b: ZW(n)) ZW(n) {
    if (comptime zwNative(n)) {
        if (b == 0) return 0;
        if (!signed) return a % b;
        if (b == zwstd.math.maxInt(ZW(n))) return 0;
        return @bitCast(@rem(@as(ZS(n), @bitCast(a)), @as(ZS(n), @bitCast(b))));
    }
    return zwL.divRem(n, signed, true, a, b);
}

/// Returns IEEE 1364 §5.1.12 `<<`/`<<<`; the count `c` (`cn` bits) is
/// unsigned.
pub fn zwShl(comptime n: u32, a: ZW(n), comptime cn: u32, c: ZW(cn)) ZW(n) {
    const s = zwCount(cn, c);
    return if (comptime zwNative(n)) zwstd.math.shl(ZW(n), a, s) else zwL.shl(n, a, s);
}

/// Returns IEEE 1364 §5.1.12 `>>`, and `>>>` when `arith` (a signed operand).
pub fn zwShr(comptime n: u32, comptime arith: bool, a: ZW(n), comptime cn: u32, c: ZW(cn)) ZW(n) {
    const s = zwCount(cn, c);
    if (comptime zwNative(n)) {
        if (arith) return @bitCast(zwstd.math.shr(ZS(n), @bitCast(a), s));
        return zwstd.math.shr(ZW(n), a, s);
    }
    return zwL.shr(n, arith, a, s);
}

/// Returns IEEE 1364 §5.1.5 Table 5-6 `**` at the base's `n` bits: 1 for a
/// zero exponent; for a negative one, 1 or -1 by parity for a base of ±1, 0
/// otherwise (x for a zero base there); else wrapping powers, by
/// square-and-multiply up to the exponent's top set bit.
pub fn zwPow(comptime n: u32, comptime signed: bool, a: ZW(n), comptime en: u32, comptime esigned: bool, e: ZW(en)) ZW(n) {
    if (zwIsZero(en, e)) return zwFromLimbs(n, zwL.one(n));
    const neg = esigned and zwBit(en, e, en - 1);
    if (zwIsZero(n, a)) return zwZero(n);
    if (zwEq(n, a, zwFromLimbs(n, zwL.one(n)))) return a;
    if (signed and zwEq(n, a, zwNot(n, zwZero(n)))) return if (zwBit(en, e, 0)) a else zwFromLimbs(n, zwL.one(n));
    if (neg) return zwZero(n);
    var r = zwFromLimbs(n, zwL.one(n));
    var base = a;
    var top: u32 = en;
    while (top > 0 and !zwBit(en, e, top - 1)) top -= 1;
    zwstd.debug.assert(top >= 1); // a nonzero exponent has a set bit
    var i: u32 = 0;
    while (i < top) : (i += 1) {
        if (zwBit(en, e, i)) r = zwMul(n, r, base);
        if (i + 1 < top) base = zwMul(n, base, base);
    }
    return r;
}

/// Returns bit `k` of `a`. Asserts that `k < n`.
pub fn zwBit(comptime n: u32, a: ZW(n), k: u32) bool {
    zwstd.debug.assert(k < n);
    if (comptime zwNative(n)) return (zwstd.math.shr(ZW(n), a, k) & 1) != 0;
    return (a[k / 32] >> @intCast(k % 32)) & 1 != 0;
}

/// Returns whether every bit is zero: §5.1.9's false.
pub fn zwIsZero(comptime n: u32, a: ZW(n)) bool {
    if (comptime zwNative(n)) return a == 0;
    for (a) |d| if (d != 0) return false;
    return true;
}

/// Returns IEEE 1364 §5.1.8 `==` on two-state bits of one width.
pub fn zwEq(comptime n: u32, a: ZW(n), b: ZW(n)) bool {
    if (comptime zwNative(n)) return a == b;
    return zwstd.mem.eql(u32, &a, &b);
}

/// Returns `a < b` (IEEE 1364 §5.1.7), both `n` bits of one type.
pub fn zwLt(comptime n: u32, comptime signed: bool, a: ZW(n), b: ZW(n)) bool {
    if (comptime zwNative(n)) {
        if (signed) return @as(ZS(n), @bitCast(a)) < @as(ZS(n), @bitCast(b));
        return a < b;
    }
    if (signed) {
        const sa = zwBit(n, a, n - 1);
        if (sa != zwBit(n, b, n - 1)) return sa;
    }
    var i: usize = zwLimbs(n);
    while (i > 0) {
        i -= 1;
        if (a[i] != b[i]) return a[i] < b[i];
    }
    return false;
}

/// Returns §5.1.11's reduction AND: every bit is one.
pub fn zwAll(comptime n: u32, a: ZW(n)) bool {
    return zwEq(n, a, zwNot(n, zwZero(n)));
}

/// Returns §5.1.11's reduction XOR: an odd number of one bits.
pub fn zwParity(comptime n: u32, a: ZW(n)) bool {
    if (comptime zwNative(n)) return @popCount(a) & 1 != 0;
    var p: u32 = 0;
    for (a) |d| p ^= @popCount(d);
    return p & 1 != 0;
}

/// Returns the nearest double to `a`, ties to even (IEEE 1364 §4.8.2, the
/// §5.5.1 conversion of an integer operand of a real operator). Past 64 bits
/// by the limb algorithm whatever `ZW(n)` is: LLVM's NVPTX backend has no
/// conversion from a wider integer (it asks for a libcall and aborts).
pub fn zwToReal(comptime n: u32, comptime signed: bool, a: ZW(n)) f64 {
    if (comptime n <= 64) {
        if (signed) return @floatFromInt(@as(ZS(n), @bitCast(a)));
        return @floatFromInt(a);
    }
    const l = zwToLimbs(n, a);
    if (signed and zwBit(n, a, n - 1)) return -zwL.toReal(n, zwL.sub(n, zwstd.mem.zeroes([zwLimbs(n)]u32), l));
    return zwL.toReal(n, l);
}

/// Returns a real converted to `n` bits (IEEE 1364 §4.8.2): rounded to the
/// nearest integer, ties away from zero, then its low `n` bits (two's
/// complement). NaN and an infinity have no integer; they convert to 0.
pub fn zwFromReal(comptime n: u32, x: f64) ZW(n) {
    if (!zwstd.math.isFinite(x)) return zwZero(n);
    const r = @round(x);
    const mag = @abs(r);
    var v: ZW(n) = undefined;
    if (mag < 0x1p63) {
        v = zwLeaf(n, @intFromFloat(mag));
    } else {
        const fr = zwstd.math.frexp(mag);
        zwstd.debug.assert(fr.exponent >= 64);
        const sh: u64 = @intCast(fr.exponent - 53);
        v = zwShl(n, zwLeaf(n, @intFromFloat(fr.significand * 0x1p53)), 64, sh);
    }
    return if (r < 0) zwNeg(n, v) else v;
}

// ---- private ----

fn zwNative(comptime n: u32) bool {
    return n <= zw_native_max;
}

fn ZS(comptime n: u32) type {
    return @Int(.signed, n);
}

/// A shift count, saturated: every count past `u64` shifts every bit out.
fn zwCount(comptime cn: u32, c: ZW(cn)) u64 {
    if (comptime zwNative(cn)) return zwstd.math.lossyCast(u64, c);
    for (c[2..]) |d| if (d != 0) return zwstd.math.maxInt(u64);
    return zwL.low64(cn, c);
}
