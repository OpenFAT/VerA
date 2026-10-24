//! IEEE 1364-2005 four-state operators for a native executable: operands
//! as `T(w)` (a `W` up to 64 bits, a `Wide(n)` above, the width fixed at
//! compile time by §5.5) in; the value `Integer.Literal`'s operator of the
//! same name computes out. Under `--two-state` an x or z an operator would
//! make is 0. Clauses: §5.1.5 to §5.1.14 with Tables 5-12 to 5-21, §5.5.2
//! extension, §5.2.1 packed selects, §9.5.1 casez/casex.
const std = @import("std");
const Int = @import("kernels").Integer;

/// `vera --emit-exe --two-state`: not IEEE 1364 §3.2/§4.1 4-state logic.
pub const two = blk: {
    const root = @import("root");
    break :blk if (@hasDecl(root, "vera_two_state")) root.vera_two_state else false;
};

/// A value of at most 64 bits as two planes, VPI-encoded per bit: (v, x) =
/// 00/10/11/01 for 0/1/x/z. Bits at and above the width are 0 in both.
pub const W = struct { v: u64, x: u64 };

/// A value of more than 64 bits: `n` words per plane, least significant
/// first, encoded and zero-padded above the width as `W` is.
pub fn Wide(comptime n: u32) type {
    return struct { v: [n]u64, x: [n]u64 };
}

/// The words per plane of a `w`-bit value.
pub fn words(w: u32) u32 {
    return (w + 63) / 64;
}

/// The type a `w`-bit value is carried in.
pub fn T(comptime w: u32) type {
    return if (w <= 64) W else Wide(words(w));
}

/// The type of a `w`-bit plane mask: what `State.put` takes beside a `T(w)`.
pub fn M(comptime w: u32) type {
    return if (w <= 64) u64 else [words(w)]u64;
}

const ones = std.math.maxInt(u64);

/// The mask of the last word of a `w`-bit value.
fn top(comptime w: u32) u64 {
    return if (w % 64 == 0) ones else (@as(u64, 1) << @intCast(w % 64)) - 1;
}

fn wordsOf(comptime A: type) u32 {
    const V = @FieldType(A, "v");
    return if (V == u64) 1 else @typeInfo(V).array.len;
}

/// `a` as words, one when it is a `W`.
pub inline fn wide(a: anytype) Wide(wordsOf(@TypeOf(a))) {
    if (@FieldType(@TypeOf(a), "v") == u64) return .{ .v = .{a.v}, .x = .{a.x} };
    return .{ .v = a.v, .x = a.x };
}

/// Words back as the `T(w)` they carry.
inline fn narrow(comptime w: u32, a: Wide(words(w))) T(w) {
    if (w <= 64) return .{ .v = a.v[0], .x = a.x[0] };
    return a;
}

/// Every bit of a `w`-bit value.
pub fn full(comptime w: u32) M(w) {
    if (w <= 64) return mask(w);
    var m: [words(w)]u64 = @splat(ones);
    m[words(w) - 1] = top(w);
    return m;
}

/// A `w`-bit value of all x; all 0 under `--two-state`.
pub fn xs(comptime w: u32) T(w) {
    const f = if (two) std.mem.zeroes(M(w)) else full(w);
    return .{ .v = f, .x = f };
}

/// Bits `[lo, hi)` of word `j`, clamped to the word.
pub fn span(j: usize, lo: i64, hi: i64) u64 {
    const base: i64 = @intCast(64 * j);
    return below(std.math.clamp(hi - base, 0, 64)) & ~below(std.math.clamp(lo - base, 0, 64));
}

fn below(n: i64) u64 {
    // No cast guarded by the branch: Windows' LLVM Debug build ran the cast's
    // safety check at n == 64. A shift by 64 or more is 0, so 0 -% 1 = ones.
    return std.math.shl(u64, 1, n) -% 1;
}

/// The 64 bits of `p` from bit `pos` up; bits outside `p` read 0.
fn funnel(p: []const u64, at: i64) u64 {
    const q = @divFloor(at, 64);
    const b: u6 = @intCast(@mod(at, 64));
    const lo = wordAt(p, q) >> b;
    const hi = if (b == 0) 0 else wordAt(p, q + 1) << @intCast(64 - @as(u7, b));
    return lo | hi;
}

fn wordAt(p: []const u64, i: i64) u64 {
    return if (i < 0 or i >= p.len) 0 else p[@intCast(i)];
}

/// `dst |= src << at`, bits past `dst` dropped.
fn orAt(dst: []u64, src: []const u64, at: u32) void {
    const q = at / 64;
    const b: u6 = @intCast(at % 64);
    for (src, 0..) |w, j| {
        if (q + j < dst.len) dst[q + j] |= w << b;
        if (b != 0 and q + j + 1 < dst.len) dst[q + j + 1] |= w >> @intCast(64 - @as(u7, b));
    }
}

fn anyX(a: anytype) bool {
    var any: u64 = 0;
    for (wide(a).x) |x| any |= x;
    return any != 0;
}

/// `r` of width `w`, or all x when `unk` (§5.1.5).
fn orX(comptime w: u32, r: [words(w)]u64, unk: bool) T(w) {
    // `@Vector`, not a loop: with the last word masked, LLVM's SLP pass
    // leaves the loop half scalar at 4+ words (tests/codegen_probe.zig).
    const u = 0 -% @as(u64, @intFromBool(unk));
    const V = @Vector(words(w), u64);
    const uv: V = @splat(u);
    var o: Wide(words(w)) = .{ .v = @as(V, r) | uv, .x = uv };
    o.v[words(w) - 1] &= top(w);
    o.x[words(w) - 1] &= top(w);
    return narrow(w, o);
}

/// One bit, as `Integer.Bit` encodes it: `v | x << 1`.
pub const Bit = enum(u2) { zero = 0, one = 1, z = 2, x = 3 };

/// The mask of a `w`-bit value. Asserts at comptime that `w` is 1 to 64.
pub fn mask(comptime w: u32) u64 {
    comptime std.debug.assert(w >= 1 and w <= 64);
    return if (w == 64) std.math.maxInt(u64) else (@as(u64, 1) << w) - 1;
}

/// A `W` from its two planes; the caller keeps bits above the width 0.
pub inline fn k(v: u64, x: u64) W {
    return .{ .v = v, .x = x };
}

/// Bit 0 of a `W` or a `Wide`: the bit an edge is of (§9.7.2).
pub inline fn low(a: anytype) Bit {
    const s = wide(a);
    return @fromBackingInt(@intCast(@as(u2, @intCast(s.v[0] & 1)) | @as(u2, @intCast(s.x[0] & 1)) << 1));
}

/// `Literal.resize`: truncate, or extend by `sign` (per plane, so a top x
/// or z replicates as itself).
pub inline fn rs(a: anytype, comptime from: u32, comptime to: u32, comptime sign: bool) T(to) {
    if (from > 64 or to > 64) return rsWide(wide(a), from, to, sign);
    if (to <= from or !sign) return .{ .v = a.v & mask(to), .x = a.x & mask(to) };
    const hi = ~mask(from) & mask(to);
    return .{
        .v = a.v | (hi & (0 -% ((a.v >> (from - 1)) & 1))),
        .x = a.x | (hi & (0 -% ((a.x >> (from - 1)) & 1))),
    };
}

fn rsWide(s: anytype, comptime from: u32, comptime to: u32, comptime sign: bool) T(to) {
    const nf = comptime words(from);
    const nt = comptime words(to);
    const b: u6 = (from - 1) % 64;
    const fv: u64 = if (sign) 0 -% ((s.v[nf - 1] >> b) & 1) else 0;
    const fx: u64 = if (sign) 0 -% ((s.x[nf - 1] >> b) & 1) else 0;
    var o: Wide(nt) = undefined;
    for (0..nt) |i| {
        o.v[i] = if (i < nf) s.v[i] else fv;
        o.x[i] = if (i < nf) s.x[i] else fx;
    }
    if (nf <= nt) {
        o.v[nf - 1] |= fv & ~top(from);
        o.x[nf - 1] |= fx & ~top(from);
    }
    o.v[nt - 1] &= top(to);
    o.x[nt - 1] &= top(to);
    return narrow(to, o);
}

/// A one-bit result in its context (`evaluate.scalarContext`).
pub inline fn ctx(b: Bit, comptime w: u32, comptime sign: bool) T(w) {
    const n: u2 = @backingInt(b);
    return rs(W{ .v = n & 1, .x = n >> 1 }, 1, w, sign);
}

/// §5.1.10 Table 5-16 `~`: x and z bits invert to x.
pub inline fn not(a: anytype, comptime w: u32) T(w) {
    if (w <= 64) return .{ .v = (~a.v | a.x) & mask(w), .x = a.x };
    // `@Vector` for the reason `orX` gives.
    const V = @Vector(words(w), u64);
    var o: T(w) = .{ .v = ~@as(V, a.v) | @as(V, a.x), .x = a.x };
    o.v[words(w) - 1] &= top(w);
    return o;
}

/// Any unknown bit makes all of it x.
pub inline fn neg(a: anytype, comptime w: u32) T(w) {
    if (w > 64) return negWide(w, a);
    const unk = 0 -% @as(u64, @intFromBool(a.x != 0));
    return .{ .v = ((0 -% a.v) | unk) & mask(w), .x = unk & mask(w) };
}

fn negWide(comptime w: u32, a: T(w)) T(w) {
    var r: [words(w)]u64 = undefined;
    var borrow: u1 = 0;
    for (&r, a.v) |*d, v| {
        const s = @subWithOverflow(0, v);
        const t = @subWithOverflow(s[0], borrow);
        d.* = t[0];
        borrow = s[1] | t[1];
    }
    return orX(w, r, anyX(a));
}

/// §5.1.10's binary bitwise operators, Tables 5-12 to 5-15.
pub const Bitwise = enum { @"and", @"or", xor, xnor };

/// `a op b` per bit (§5.1.10): a known 0 decides `&`, a known 1 decides
/// `|`, and any unknown bit makes `^`/`~^` x. Both operands already `w` wide.
pub inline fn bitwise(comptime op: Bitwise, a: anytype, b: @TypeOf(a), comptime w: u32) T(w) {
    if (w > 64) {
        var o: T(w) = undefined;
        for (&o.v, &o.x, a.v, a.x, b.v, b.x) |*ov, *ox, av, ax, bv, bx| {
            const r = bitwise(op, W{ .v = av, .x = ax }, W{ .v = bv, .x = bx }, 64);
            ov.* = r.v;
            ox.* = r.x;
        }
        o.v[words(w) - 1] &= top(w);
        return o;
    }
    return switch (op) {
        .@"and" => blk: {
            const x = (a.x | b.x) & (a.v | a.x) & (b.v | b.x);
            break :blk .{ .v = (a.v & b.v) | x, .x = x };
        },
        .@"or" => blk: {
            const x = (a.x | b.x) & ~((a.v & ~a.x) | (b.v & ~b.x));
            break :blk .{ .v = a.v | b.v | x, .x = x };
        },
        .xor => .{ .v = (a.v ^ b.v) | a.x | b.x, .x = a.x | b.x },
        .xnor => .{ .v = (~(a.v ^ b.v) | a.x | b.x) & mask(w), .x = a.x | b.x },
    };
}

fn sext(v: u64, comptime w: u32) u64 {
    if (w == 64) return v;
    return v | (~mask(w) & (0 -% ((v >> (w - 1)) & 1)));
}

/// §5.1.5's binary arithmetic operators but `**` (`pow`).
const Arith = enum { add, sub, mul, div, mod };

/// `Literal.arithmetic` at one word: any unknown bit, and `/` or `%` by 0,
/// is all x (§5.1.5).
pub inline fn arith(comptime op: Arith, a: anytype, b: @TypeOf(a), comptime w: u32, comptime signed: bool) T(w) {
    if (w > 64) return switch (op) {
        .add, .sub => addWide(op == .sub, w, a, b),
        .mul => big(w, signed, a, b, w, signed, .multiply),
        .div => big(w, signed, a, b, w, signed, .divide),
        .mod => big(w, signed, a, b, w, signed, .remainder),
    };
    const av = if (signed) sext(a.v, w) else a.v;
    const bv = if (signed) sext(b.v, w) else b.v;
    const zero = (op == .div or op == .mod) and bv == 0;
    const unk = 0 -% @as(u64, @intFromBool((a.x | b.x) != 0 or zero));
    const d = bv | @intFromBool(bv == 0); // never divides by zero; `unk` covers it
    const r: u64 = switch (op) {
        .add => av +% bv,
        .sub => av -% bv,
        .mul => av *% bv,
        .div, .mod => if (!signed)
            (if (op == .div) av / d else av % d)
        else if (d == std.math.maxInt(u64))
            (if (op == .div) 0 -% av else 0)
        else
            @bitCast(if (op == .div) @divTrunc(@as(i64, @bitCast(av)), @as(i64, @bitCast(d))) else @rem(@as(i64, @bitCast(av)), @as(i64, @bitCast(d)))),
    };
    if (two) return .{ .v = r & ~unk & mask(w), .x = 0 };
    return .{ .v = (r | unk) & mask(w), .x = unk & mask(w) };
}

/// A carry (or borrow) chain: `+` and `-` at any width wrap the same way
/// signed or not.
fn addWide(comptime sub: bool, comptime w: u32, a: T(w), b: T(w)) T(w) {
    var r: [words(w)]u64 = undefined;
    var c: u1 = 0;
    for (&r, a.v, b.v) |*d, av, bv| {
        const s = if (sub) @subWithOverflow(av, bv) else @addWithOverflow(av, bv);
        const t = if (sub) @subWithOverflow(s[0], c) else @addWithOverflow(s[0], c);
        d.* = t[0];
        c = s[1] | t[1];
    }
    return orX(w, r, anyX(a) or anyX(b));
}

/// Both planes of `a`, values first: an `Integer.Literal`'s `planes`.
pub fn planesOf(a: anytype) [2 * wordsOf(@TypeOf(a))]u64 {
    const s = wide(a);
    return s.v ++ s.x;
}

/// `Integer.Literal`'s operator itself, for the wide `* / % **`: rare, and
/// already exact at every width.
fn big(comptime w: u32, comptime signed: bool, a: anytype, b: anytype, comptime bw: u32, comptime bsigned: bool, comptime op: ?Int.Arithmetic) T(w) {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    var pa = planesOf(a);
    var pb = planesOf(b);
    const la: Int.Literal = .{ .width = w, .signed = signed, .sized = true, .planes = &pa };
    const lb: Int.Literal = .{ .width = bw, .signed = bsigned, .sized = true, .planes = &pb };
    const r = (if (op) |o| la.arithmetic(arena.allocator(), o, lb) else la.power(arena.allocator(), lb)) catch @panic("out of memory");
    var o: Wide(words(w)) = undefined;
    @memcpy(&o.v, r.values()[0..words(w)]);
    @memcpy(&o.x, r.unknowns()[0..words(w)]);
    if (two) for (&o.v, &o.x) |*v, *x| {
        v.* &= ~x.*;
        x.* = 0;
    };
    return narrow(w, o);
}

/// `Literal.power`: the base in context, the exponent self-determined
/// (§5.1.5 Table 5-6).
pub fn pow(a: anytype, comptime w: u32, comptime signed: bool, e: anytype, comptime ew: u32, comptime esigned: bool) T(w) {
    if (w > 64 or ew > 64) return big(w, signed, a, e, ew, esigned, null);
    if (a.x != 0 or e.x != 0) return xs(w);
    const m = mask(w);
    const ev = e.v & mask(ew);
    if (ev == 0) return .{ .v = 1, .x = 0 };
    const negative = esigned and (ev >> (ew - 1)) & 1 == 1;
    const b = a.v & m;
    if (b == 0) return if (negative) xs(w) else .{ .v = 0, .x = 0 };
    if (b == 1 or (signed and b == m)) return .{ .v = if (b == 1 or ev & 1 == 0) 1 else m, .x = 0 };
    if (negative) return .{ .v = 0, .x = 0 };
    var result: u64 = 1;
    var base = b;
    var rest = ev;
    while (rest != 0) : (rest >>= 1) {
        if (rest & 1 == 1) result *%= base;
        base *%= base;
    }
    return .{ .v = result & m, .x = 0 };
}

/// §5.1.12's four shift operators.
pub const Shift = enum { left, right, arithmetic_left, arithmetic_right };

/// `Literal.shift`: an unknown amount is all x; an amount of at least the
/// width leaves only the fill (§5.1.12).
pub inline fn shift(comptime op: Shift, a: anytype, comptime w: u32, comptime signed: bool, b: anytype) T(w) {
    if (comptime w > 64 or wordsOf(@TypeOf(b)) > 1) return shiftWide(op, w, signed, wide(a), wide(b));
    if (b.x != 0) return xs(w);
    const fill = op == .arithmetic_right and signed;
    if (b.v >= w) return if (fill)
        .{ .v = 0 -% ((a.v >> (w - 1)) & 1) & mask(w), .x = 0 -% ((a.x >> (w - 1)) & 1) & mask(w) }
    else
        .{ .v = 0, .x = 0 };
    const n: u6 = @intCast(b.v);
    return switch (op) {
        .left, .arithmetic_left => .{ .v = (a.v << n) & mask(w), .x = (a.x << n) & mask(w) },
        .right, .arithmetic_right => if (fill) .{
            .v = @as(u64, @bitCast(@as(i64, @bitCast(sext(a.v, w))) >> n)) & mask(w),
            .x = @as(u64, @bitCast(@as(i64, @bitCast(sext(a.x, w))) >> n)) & mask(w),
        } else .{ .v = a.v >> n, .x = a.x >> n },
    };
}

fn shiftWide(comptime op: Shift, comptime w: u32, comptime signed: bool, a: Wide(words(w)), b: anytype) T(w) {
    if (anyX(b)) return xs(w);
    var hi: u64 = 0;
    for (b.v[1..]) |v| hi |= v;
    // `Literal.shift`: an amount of at least the width leaves only the fill.
    const amount: u32 = if (hi != 0) w else @intCast(@min(b.v[0], w));
    const fill = op == .arithmetic_right and signed;
    const n = comptime words(w);
    const sb: u6 = (w - 1) % 64;
    var o: Wide(n) = undefined;
    inline for (.{ &o.v, &o.x }, .{ a.v, a.x }) |out, src_| {
        var src = src_;
        const f: u64 = if (fill) 0 -% ((src[n - 1] >> sb) & 1) else 0;
        src[n - 1] |= f & ~top(w);
        const q = amount / 64;
        const bs: u6 = @intCast(amount % 64);
        for (out, 0..) |*d, i| {
            if (op == .left or op == .arithmetic_left) {
                d.* = if (i >= q) src[i - q] << bs else 0;
                if (bs != 0 and i > q) d.* |= src[i - q - 1] >> @intCast(64 - @as(u7, bs));
            } else {
                const lo = if (i + q < n) src[i + q] else f;
                const up_ = if (i + q + 1 < n) src[i + q + 1] else f;
                d.* = lo >> bs;
                if (bs != 0) d.* |= up_ << @intCast(64 - @as(u7, bs));
            }
        }
        out[n - 1] &= top(w);
    }
    return narrow(w, o);
}

/// §5.1.7's four relational operators.
pub const Relational = enum { lt, le, gt, ge };

/// Any unknown bit makes the relation x (§5.1.7).
pub inline fn rel(comptime op: Relational, a: anytype, b: @TypeOf(a), comptime w: u32, comptime signed: bool) Bit {
    if (w > 64) return relWide(op, w, signed, a, b);
    if ((a.x | b.x) != 0) return .x;
    const ord = if (signed)
        std.math.order(@as(i64, @bitCast(sext(a.v, w))), @as(i64, @bitCast(sext(b.v, w))))
    else
        std.math.order(a.v, b.v);
    return if (switch (op) {
        .lt => ord == .lt,
        .le => ord != .gt,
        .gt => ord == .gt,
        .ge => ord != .lt,
    }) .one else .zero;
}

/// Word order from the top, the sign bit biased so unsigned order is
/// two's-complement order (`Literal.relational`).
fn relWide(comptime op: Relational, comptime w: u32, comptime signed: bool, a: T(w), b: T(w)) Bit {
    if (anyX(a) or anyX(b)) return .x;
    var lt: u1 = 0;
    var gt: u1 = 0;
    var decided: u1 = 0;
    var i: usize = words(w);
    while (i > 0) {
        i -= 1;
        const bias: u64 = if (signed and i == words(w) - 1) @as(u64, 1) << ((w - 1) % 64) else 0;
        const av = a.v[i] ^ bias;
        const bv = b.v[i] ^ bias;
        lt |= ~decided & @intFromBool(av < bv);
        gt |= ~decided & @intFromBool(av > bv);
        decided |= @intFromBool(av != bv);
    }
    return if (switch (op) {
        .lt => lt == 1,
        .le => gt == 0,
        .gt => gt == 1,
        .ge => lt == 0,
    }) .one else .zero;
}

/// §5.1.8: logical (`==`, `!=`) and case (`===`, `!==`) equality.
pub const Equality = enum { eq, neq, case_eq, case_neq };

/// Both operands already in their common type (§5.1.8).
pub inline fn eq(comptime op: Equality, a: anytype, b: @TypeOf(a)) Bit {
    var different: u64 = 0;
    var unknown: u64 = 0;
    const sa = wide(a);
    const sb = wide(b);
    for (sa.v, sa.x, sb.v, sb.x) |av, ax, bv, bx| {
        different |= switch (op) {
            .case_eq, .case_neq => (av ^ bv) | (ax ^ bx),
            .eq, .neq => (av ^ bv) & ~(ax | bx),
        };
        unknown |= ax | bx;
    }
    const r: Bit = if (different != 0) .zero else switch (op) {
        .case_eq, .case_neq => .one,
        .eq, .neq => if (unknown != 0) .x else .one,
    };
    return if (op == .neq or op == .case_neq) invert(r) else r;
}

/// §5.1.11's six reduction operators.
pub const Reduction = enum { @"and", nand, @"or", nor, xor, xnor };

/// §5.1.11 Tables 5-17 to 5-19: one bit from every bit of the `w`-bit `a`; a
/// decisive known bit wins over x and z, else any unknown bit is x.
pub inline fn reduce(comptime op: Reduction, a: anytype, comptime w: u32) Bit {
    var zeros: u64 = 0;
    var known1: u64 = 0;
    var unknown: u64 = 0;
    var parity: u64 = 0;
    const s = wide(a);
    for (s.v, s.x, 0..) |v, x, i| {
        zeros |= ~(v | x) & (if (i == s.v.len - 1) top(w) else ones);
        known1 |= v & ~x;
        unknown |= x;
        parity ^= @popCount(v);
    }
    const r: Bit = switch (op) {
        .@"and", .nand => if (zeros != 0) .zero else if (unknown != 0) .x else .one,
        .@"or", .nor => if (known1 != 0) .one else if (unknown != 0) .x else .zero,
        .xor, .xnor => if (unknown != 0) .x else if (parity & 1 == 1) .one else .zero,
    };
    return switch (op) {
        .nand, .nor, .xnor => invert(r),
        else => r,
    };
}

/// §5.1.9: any known 1 makes it true, even beside x or z.
pub inline fn truth(a: anytype) Bit {
    var known1: u64 = 0;
    var unknown: u64 = 0;
    const s = wide(a);
    for (s.v, s.x) |v, x| {
        known1 |= v & ~x;
        unknown |= x;
    }
    return if (known1 != 0) .one else if (unknown != 0) .x else .zero;
}

/// §5.1.9 `!` of one truth: x and z are x.
pub inline fn invert(b: Bit) Bit {
    return switch (b) {
        .zero => .one,
        .one => .zero,
        .x, .z => .x,
    };
}

/// §5.1.9's binary logical operators `&&` and `||`.
pub const Logical = enum { @"and", @"or" };

/// `Literal.logical` of two one-bit truths.
pub inline fn logical(comptime op: Logical, a: Bit, b: Bit) Bit {
    return switch (op) {
        .@"and" => if (a == .zero or b == .zero) .zero else if (a == .one and b == .one) .one else .x,
        .@"or" => if (a == .one or b == .one) .one else if (a == .zero and b == .zero) .zero else .x,
    };
}

/// §5.1.13 Table 5-21: under an ambiguous condition only matching known
/// bits survive. Both arms already in the context type.
pub inline fn cond(c: Bit, y: anytype, n: @TypeOf(y)) @TypeOf(y) {
    return switch (c) {
        .one => y,
        .zero => n,
        .x, .z => blk: {
            if (@FieldType(@TypeOf(y), "v") == u64) {
                const x = y.x | n.x | (y.v ^ n.v);
                break :blk .{ .v = y.v | x, .x = x };
            }
            var o: @TypeOf(y) = undefined;
            for (&o.v, &o.x, y.v, y.x, n.v, n.x) |*ov, *ox, yv, yx, nv, nx| {
                ox.* = yx | nx | (yv ^ nv);
                ov.* = yv | ox.*;
            }
            break :blk o;
        },
    };
}

/// §4.8.2 integer to real (`evaluate.realOfInt`): the value read by its own
/// signedness, each x or z bit as 0.
pub inline fn toReal(a: anytype, comptime w: u32, comptime signed: bool) f64 {
    // ponytail: the low 64 bits of a wider operand, as the interpreter reads it.
    const lo = wide(a).v[0] & ~wide(a).x[0];
    if (signed and w <= 64) return @floatFromInt(@as(i64, @bitCast(sext(lo, w))));
    return @floatFromInt(lo);
}

/// §4.8.2 real to integer (`evaluate.intOfReal`): rounded to nearest, halves
/// away from zero, as a 64-bit signed value; x when no such integer exists.
pub inline fn ofReal(r: f64) W {
    const t = @round(r);
    // NaN fails both compares.
    if (!(t >= -0x1p63 and t < 0x1p63)) return xs(64);
    return .{ .v = @bitCast(@as(i64, @intFromFloat(t))), .x = 0 };
}

/// §4.8.2 real to a `to`-bit integer (`evaluate.intOfReal`, then the
/// assignment's truncation): rounded to nearest, halves away from zero, mod
/// 2^to, at any magnitude; x when no such integer exists.
pub fn ofRealTo(r: f64, comptime to: u32) T(to) {
    const n = @round(r);
    if (!std.math.isFinite(n)) return xs(to);
    var v: [words(to)]u64 = @splat(0);
    if (n >= -0x1p63 and n < 0x1p63) {
        const i: i64 = @intFromFloat(n);
        for (&v, 0..) |*w, j| w.* = if (j == 0) @bitCast(i) else if (i < 0) ones else 0;
    } else {
        // An f64 this large is its 53-bit significand shifted left.
        const fr = std.math.frexp(@abs(n));
        const mant: u64 = @intFromFloat(std.math.ldexp(fr.significand, 53));
        const by: u32 = @intCast(fr.exponent - 53);
        const at = by / 64;
        const b: u6 = @intCast(by % 64);
        if (at < v.len) v[at] |= mant << b;
        if (b != 0 and at + 1 < v.len) v[at + 1] |= mant >> @intCast(64 - @as(u7, b));
        if (n < 0) {
            var carry: u1 = 1;
            for (&v) |*w| {
                const sum = @addWithOverflow(~w.*, @as(u64, carry));
                w.* = sum[0];
                carry = sum[1];
            }
        }
    }
    v[v.len - 1] &= top(to);
    return narrow(to, .{ .v = v, .x = @splat(0) });
}

/// §17.8 `$rtoi`: truncated toward zero, a 32-bit signed value; x when none.
pub inline fn rtoi(r: f64) W {
    const t = @trunc(r);
    if (!(t >= -0x1p31 and t < 0x1p31)) return xs(32);
    return .{ .v = @as(u32, @bitCast(@as(i32, @intFromFloat(t)))), .x = 0 };
}

/// A real as the 64-bit value a real slot holds: its IEEE 754 bits.
pub inline fn realBits(r: f64) W {
    return .{ .v = @bitCast(r), .x = 0 };
}

/// The real a real slot's value holds.
pub inline fn real(a: W) f64 {
    return @bitCast(a.v);
}

/// The least significant word of `a`'s value plane (`$bitstoreal`).
pub inline fn word0(a: anytype) u64 {
    return wide(a).v[0];
}

/// §5.1.13 a real `?:` under an x or z condition is always zero, after
/// both arms have been evaluated (`evaluate.evalReal`).
pub inline fn realCond(c: Bit, y: f64, n: f64) f64 {
    return switch (c) {
        .one => y,
        .zero => n,
        .x, .z => 0,
    };
}

/// A real's truth (§9.4): not zero.
pub inline fn realTruth(r: f64) Bit {
    return if (r != 0) .one else .zero;
}

/// `{hi, lo}`, `hi` being `hw` bits wide and `lo` `lw`.
pub inline fn join(hi: anytype, comptime hw: u32, lo: anytype, comptime lw: u32) T(hw + lw) {
    if (hw + lw <= 64) return .{ .v = hi.v << lw | lo.v, .x = hi.x << lw | lo.x };
    var o: Wide(words(hw + lw)) = .{ .v = @splat(0), .x = @splat(0) };
    const sl = wide(lo);
    const sh = wide(hi);
    orAt(&o.v, &sl.v, 0);
    orAt(&o.x, &sl.x, 0);
    orAt(&o.v, &sh.v, lw);
    orAt(&o.x, &sh.x, lw);
    return o;
}

/// The integer a self-determined index reads as, or null when it has an
/// unknown bit or is wider than 64 bits (`Literal.asInt`).
pub inline fn asInt(a: anytype, comptime w: u32, comptime signed: bool) ?i64 {
    if (w > 64) return null;
    if (a.x != 0) return null;
    return @bitCast(if (signed) sext(a.v, w) else a.v);
}

/// The full numeric index, retaining bases just outside an i64 declaration
/// for partially overlapping indexed selects. Shared with the interpreter.
pub inline fn asIndex(a: anytype, comptime w: u32, comptime signed: bool) ?i128 {
    var planes = planesOf(a);
    const literal: Int.Literal = .{ .width = w, .signed = signed, .sized = true, .planes = &planes };
    return literal.asIndex();
}

/// `exec.position` then `readSelect` of one bit: bit `index` of a vector
/// declared `[msb:lsb]`, x when the index is x/z or outside it (§5.2.1).
pub inline fn bitAt(a: anytype, index: ?i128, comptime msb: i64, comptime lsb: i64, comptime w: u32) W {
    const p = pos(index, msb, lsb, w) orelse return xs(1);
    const s = wide(a);
    const n: u6 = @intCast(p % 64);
    return .{ .v = (s.v[p / 64] >> n) & 1, .x = (s.x[p / 64] >> n) & 1 };
}

/// The least-significant storage position of an indexed part-select.
/// `+:` ascends declared indices and `-:` descends them (§5.2.1); the
/// declaration determines which selected end is least significant.
pub inline fn selectShift(index: ?i128, comptime msb: i64, comptime lsb: i64, comptime count: u32, comptime ascending: bool) ?i64 {
    const i = index orelse return null;
    const p = if (msb >= lsb) i -| lsb else lsb -| i;
    return std.math.lossyCast(i64, if ((msb >= lsb) == ascending) p else p -| (count - 1));
}

/// A runtime part-select, all x for an x/z base (§5.2.1).
pub inline fn partAt(a: anytype, shift_: ?i64, comptime count: u32, comptime sw: u32) T(count) {
    return part(a, shift_ orelse return xs(count), count, sw);
}

/// A constant or runtime part-select of an `sw`-bit vector:
/// bit i of the `count`-bit result is bit `i + shift` of `a` where that bit
/// exists, else x (§5.2.1).
pub inline fn part(a: anytype, shift_: i64, comptime count: u32, comptime sw: u32) T(count) {
    if (shift_ >= sw or shift_ <= -@as(i64, count)) return xs(count);
    const lo: i64 = @max(0, -shift_);
    const hi: i64 = @min(count, @as(i64, sw) - shift_);
    if (count > 64 or sw > 64) {
        const s = wide(a);
        var o: Wide(words(count)) = undefined;
        for (&o.v, &o.x, 0..) |*v, *x, j| {
            const at = shift_ + @as(i64, @intCast(64 * j));
            const valid = span(j, lo, hi);
            const holes = if (two) 0 else ~valid & (if (j == words(count) - 1) top(count) else ones);
            v.* = (funnel(&s.v, at) & valid) | holes;
            x.* = (funnel(&s.x, at) & valid) | holes;
        }
        return narrow(count, o);
    }
    const valid = span(0, lo, hi);
    const v = if (shift_ >= 64 or shift_ <= -64) 0 else if (shift_ >= 0) a.v >> @intCast(shift_) else a.v << @intCast(-shift_);
    const x = if (shift_ >= 64 or shift_ <= -64) 0 else if (shift_ >= 0) a.x >> @intCast(shift_) else a.x << @intCast(-shift_);
    const holes = if (two) 0 else ~valid & mask(count);
    return .{ .v = (v & valid) | holes, .x = (x & valid) | holes };
}

/// The slot bits a part-select of `count` bits at `shift` names
/// in an `sw`-bit vector: the mask `place`'s value is stored under.
pub fn field(shift_: i64, comptime count: u32, comptime sw: u32) M(sw) {
    if (shift_ >= sw or shift_ <= -@as(i64, count)) return std.mem.zeroes(M(sw));
    const lo: i64 = @max(0, shift_);
    const hi: i64 = @min(sw, shift_ + count);
    if (sw <= 64) return span(0, lo, hi);
    var m: [words(sw)]u64 = undefined;
    for (&m, 0..) |*w, j| w.* = span(j, lo, hi);
    return m;
}

/// The inverse of `part` for an assignment: `a`'s `count` bits placed at
/// `shift` in an `sw`-bit vector, zero outside `field`.
pub inline fn place(a: anytype, shift_: i64, comptime count: u32, comptime sw: u32) T(sw) {
    if (shift_ >= sw or shift_ <= -@as(i64, count)) return std.mem.zeroes(T(sw));
    const m = field(shift_, count, sw);
    if (count > 64 or sw > 64) {
        const s = wide(a);
        var o: Wide(words(sw)) = undefined;
        for (&o.v, &o.x, 0..) |*v, *x, j| {
            const at = @as(i64, @intCast(64 * j)) - shift_;
            const fm = if (sw <= 64) m else m[j];
            v.* = funnel(&s.v, at) & fm;
            x.* = funnel(&s.x, at) & fm;
        }
        return narrow(sw, o);
    }
    const v = if (shift_ >= 64 or shift_ <= -64) 0 else if (shift_ >= 0) a.v << @intCast(shift_) else a.v >> @intCast(-shift_);
    const x = if (shift_ >= 64 or shift_ <= -64) 0 else if (shift_ >= 0) a.x << @intCast(shift_) else a.x >> @intCast(-shift_);
    return .{ .v = v & m, .x = x & m };
}

/// The one-bit `a` moved up to bit `p` of an `sw`-bit vector: a runtime
/// bit-select's value.
pub inline fn up(a: W, p: u32, comptime sw: u32) T(sw) {
    if (sw <= 64) return .{ .v = a.v << @intCast(p), .x = a.x << @intCast(p) };
    var o: T(sw) = .{ .v = @splat(0), .x = @splat(0) };
    o.v[p / 64] = a.v << @intCast(p % 64);
    o.x[p / 64] = a.x << @intCast(p % 64);
    return o;
}

/// Bit `p` alone of an `sw`-bit vector: a runtime bit-select's mask.
pub inline fn bit(p: u32, comptime sw: u32) M(sw) {
    if (sw <= 64) return @as(u64, 1) << @intCast(p);
    var m: M(sw) = @splat(0);
    m[p / 64] = @as(u64, 1) << @intCast(p % 64);
    return m;
}

/// The bit position a runtime bit-select names, or null (`exec.position`).
pub inline fn pos(index: ?i128, comptime msb: i64, comptime lsb: i64, comptime w: u32) ?u32 {
    const i = index orelse return null;
    const p = if (msb >= lsb) i -| lsb else lsb -| i;
    return if (p < 0 or p >= w) null else @intCast(p);
}

/// §5.1.14 `{count{a}}`.
pub inline fn rep(a: anytype, comptime w: u32, comptime count: u32) T(w * count) {
    if (w * count <= 64) {
        var out: W = .{ .v = 0, .x = 0 };
        inline for (0..count) |i| {
            out.v |= a.v << (i * w);
            out.x |= a.x << (i * w);
        }
        return out;
    }
    var o: Wide(words(w * count)) = .{ .v = @splat(0), .x = @splat(0) };
    const s = wide(a);
    for (0..count) |i| {
        orAt(&o.v, &s.v, @intCast(i * w));
        orAt(&o.x, &s.x, @intCast(i * w));
    }
    return o;
}

/// §17.11 `$clog2` of a self-determined operand, x/z read as 0 (`exec`'s
/// `integerCeilingLog2`).
pub inline fn clog2(a: anytype, comptime w: u32) u64 {
    if (w > 64) {
        if (anyX(a)) return 0;
        var length: u64 = 0;
        var power_of_two = true;
        for (a.v, 0..) |word, index| {
            if (word == 0) continue;
            if (length != 0 or word & (word - 1) != 0) power_of_two = false;
            length = @as(u64, @intCast(index)) * 64 + 64 - @clz(word);
        }
        return if (length != 0 and power_of_two) length - 1 else length;
    }
    if (a.x != 0 or a.v == 0) return 0;
    const length: u64 = 64 - @clz(a.v);
    return if (a.v & (a.v - 1) == 0) length - 1 else length;
}

/// §9.5 `case` and §9.5.1's `casez` and `casex`.
pub const CaseKind = enum { normal, casez, casex };

/// §9.5 / §9.5.1: `case` is `===`; casez/casex skip z (and x) bits of
/// either side.
pub inline fn caseMatch(comptime kind: CaseKind, a: anytype, b: @TypeOf(a)) bool {
    var miss: u64 = 0;
    const sa = wide(a);
    const sb = wide(b);
    for (sa.v, sa.x, sb.v, sb.x) |av, ax, bv, bx| {
        const wild: u64 = switch (kind) {
            .normal => 0,
            .casex => ax | bx,
            .casez => (ax & ~av) | (bx & ~bv),
        };
        miss |= ((av ^ bv) | (ax ^ bx)) & ~wild;
    }
    return miss == 0;
}

// ---- tests: every kernel against `Integer.Literal` --------------------------

fn lit(a: std.mem.Allocator, v: anytype, w: u32, signed: bool) !Int.Literal {
    return .{ .width = w, .sized = true, .signed = signed, .planes = try a.dupe(u64, &planesOf(v)) };
}

fn same(want: Int.Literal, got: anytype) !void {
    const g = wide(got);
    try std.testing.expectEqualSlices(u64, want.values(), &g.v);
    try std.testing.expectEqualSlices(u64, want.unknowns(), &g.x);
}

fn bitOf(b: Int.Bit) Bit {
    return @fromBackingInt(@intCast(@backingInt(b)));
}

fn check(comptime w: u32, comptime signed: bool, a: T(w), b: T(w)) !void {
    // Not `std.testing.allocator`: the arena frees everything anyway, and its
    // per-allocation stack capture is most of these tests' run time.
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const la = try lit(al, a, w, signed);
    const lb = try lit(al, b, w, signed);
    try same(try la.bitwiseNot(al), not(a, w));
    try same(try la.negate(al), neg(a, w));
    inline for (.{ .@"and", .@"or", .xor, .xnor }, .{ .and_bits, .or_bits, .xor_bits, .xnor_bits }) |op, iop|
        try same(try la.bitwise(al, iop, lb), bitwise(op, a, b, w));
    inline for (.{ .add, .sub, .mul, .div, .mod }, .{ .add, .subtract, .multiply, .divide, .remainder }) |op, iop|
        try same(try la.arithmetic(al, iop, lb), arith(op, a, b, w, signed));
    inline for (.{ .left, .right, .arithmetic_left, .arithmetic_right }) |op|
        try same(try la.shift(al, @field(Int.Shift, @tagName(op)), lb), shift(op, a, w, signed, b));
    try same(try la.power(al, lb), pow(a, w, signed, b, w, signed));
    inline for (.{ .lt, .le, .gt, .ge }, .{ .less, .less_equal, .greater, .greater_equal }) |op, iop|
        try std.testing.expectEqual(bitOf(la.relational(iop, lb)), rel(op, a, b, w, signed));
    inline for (.{ .eq, .neq, .case_eq, .case_neq }, .{ .equal, .not_equal, .case_equal, .case_not_equal }) |op, iop|
        try std.testing.expectEqual(bitOf(la.equality(iop, lb)), eq(op, a, b));
    inline for (.{ .@"and", .nand, .@"or", .nor, .xor, .xnor }, .{ .and_bits, .nand_bits, .or_bits, .nor_bits, .xor_bits, .xnor_bits }) |op, iop|
        try std.testing.expectEqual(bitOf(la.reduce(iop)), reduce(op, a, w));
    try std.testing.expectEqual(bitOf(la.truth()), truth(a));
    try same(try la.conditional(al, la, lb), cond(truth(a), a, b));
    inline for (.{ 1, w, w + 3, 63, 64, 65, 130 }) |to| {
        try same(try la.resize(al, to, if (signed) .sign else .zero), rs(a, w, to, signed));
    }
    try same(try Int.Literal.concatenate(al, &.{ la, lb }), join(a, w, b, w));
    try same(try la.replicate(al, 3), rep(a, w, 3));
    try std.testing.expectEqual(if (w > 64) null else la.asInt(), asInt(a, w, signed));
}

fn randomW(rand: std.Random, comptime w: u32) T(w) {
    // Mostly known, so arithmetic is exercised past its all-x early exit.
    var o: Wide(words(w)) = undefined;
    const known = rand.uintLessThan(u8, 3) != 0;
    for (&o.v, &o.x) |*v, *x| {
        v.* = rand.int(u64);
        x.* = if (known) 0 else rand.int(u64);
    }
    o.v[words(w) - 1] &= top(w);
    o.x[words(w) - 1] &= top(w);
    return narrow(w, o);
}

/// A known amount below `n`, as a `w`-bit value.
fn small(rand: std.Random, comptime w: u32, n: u64) T(w) {
    return rs(W{ .v = rand.uintLessThan(u64, n) & mask(@min(w, 64)), .x = 0 }, @min(w, 64), w, false);
}

test "every kernel equals Integer.Literal: all 4^w operand pairs for w in 1..3" {
    inline for (.{ 1, 2, 3 }) |w| inline for (.{ false, true }) |signed| {
        const n: u64 = @as(u64, 1) << (2 * w);
        for (0..n) |i| for (0..n) |j| {
            const a: W = .{ .v = i & mask(w), .x = (i >> w) & mask(w) };
            const b: W = .{ .v = j & mask(w), .x = (j >> w) & mask(w) };
            try check(w, signed, a, b);
        };
    };
}

test "every kernel equals Integer.Literal: random words at block-boundary widths" {
    var prng = std.Random.DefaultPrng.init(0x1364);
    const rand = prng.random();
    inline for (.{ 5, 31, 32, 33, 63, 64 }) |w| inline for (.{ false, true }) |signed| {
        for (0..2000) |_| try check(w, signed, randomW(rand, w), randomW(rand, w));
        // Small shift amounts and exponents, which random words never are.
        for (0..500) |_| try check(w, signed, randomW(rand, w), small(rand, w, w + 2));
    };
}

test "every kernel equals Integer.Literal: random multi-word values" {
    var prng = std.Random.DefaultPrng.init(0x1365);
    const rand = prng.random();
    inline for (.{ 65, 100, 127, 128, 129, 130, 200, 256 }) |w| inline for (.{ false, true }) |signed| {
        for (0..400) |_| try check(w, signed, randomW(rand, w), randomW(rand, w));
        for (0..200) |_| try check(w, signed, randomW(rand, w), small(rand, w, w + 2));
        // Equal high words, so comparison reaches the low ones.
        for (0..200) |_| {
            const a = randomW(rand, w);
            var b = a;
            b.v[0] = rand.int(u64);
            try check(w, signed, a, b);
        }
    };
}

test "a shift of a one-word value by a multi-word amount, and back" {
    var prng = std.Random.DefaultPrng.init(0x5112);
    const rand = prng.random();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    inline for (.{ .{ 8, 100 }, .{ 64, 65 }, .{ 130, 7 } }) |ww| for (0..500) |_| {
        const a = randomW(rand, ww[0]);
        const b = if (rand.boolean()) randomW(rand, ww[1]) else small(rand, ww[1], ww[0] + 2);
        const la = try lit(al, a, ww[0], true);
        const lb = try lit(al, b, ww[1], false);
        inline for (.{ .left, .right, .arithmetic_left, .arithmetic_right }) |op|
            try same(try la.shift(al, @field(Int.Shift, @tagName(op)), lb), shift(op, a, ww[0], true, b));
        try same(try la.power(al, lb), pow(a, ww[0], true, b, ww[1], false));
    };
}

test "$clog2 of a multi-word value" {
    inline for (.{ 65, 129, 200 }) |w| for (0..w) |e| {
        var a: T(w) = .{ .v = @splat(0), .x = @splat(0) };
        a.v[e / 64] = @as(u64, 1) << @intCast(e % 64);
        try std.testing.expectEqual(@as(u64, e), clog2(a, w));
        a.v[0] |= 1;
        try std.testing.expectEqual(@as(u64, if (e == 0) 0 else e + 1), clog2(a, w));
        a.x[0] = 1;
        try std.testing.expectEqual(@as(u64, 0), clog2(a, w));
    };
}

test "part, place, up and bitAt move the bits the per-bit rule names" {
    var prng = std.Random.DefaultPrng.init(0x521);
    const rand = prng.random();
    inline for (.{ .{ 130, -3, 70 }, .{ 130, 60, 10 }, .{ 130, 120, 16 }, .{ 70, 0, 70 }, .{ 20, -4, 8 }, .{ 20, 16, 8 }, .{ 200, 64, 65 } }) |c| for (0..200) |_| {
        const sw = c[0];
        const sh = c[1] + rand.intRangeAtMost(i64, -3, 3);
        const count = c[2];
        const a = wide(randomW(rand, sw));
        const got = wide(part(narrow(sw, a), sh, count, sw));
        const val = wide(randomW(rand, count));
        const put = wide(place(narrow(count, val), sh, count, sw));
        const m = field(sh, count, sw);
        for (0..count) |i| {
            const p = @as(i64, @intCast(i)) + sh;
            const want: u2 = if (p < 0 or p >= sw) 3 else @intCast((a.v[@intCast(@divFloor(p, 64))] >> @intCast(@mod(p, 64))) & 1 | ((a.x[@intCast(@divFloor(p, 64))] >> @intCast(@mod(p, 64))) & 1) << 1);
            const g: u2 = @intCast((got.v[i / 64] >> @intCast(i % 64)) & 1 | ((got.x[i / 64] >> @intCast(i % 64)) & 1) << 1);
            try std.testing.expectEqual(want, g);
        }
        for (0..sw) |p| {
            const i = @as(i64, @intCast(p)) - sh;
            const inside = i >= 0 and i < count;
            const mb = ((if (sw <= 64) m else m[p / 64]) >> @intCast(p % 64)) & 1 == 1;
            try std.testing.expectEqual(inside, mb);
            const want: u2 = if (!inside) 0 else @intCast((val.v[@intCast(@divFloor(i, 64))] >> @intCast(@mod(i, 64))) & 1 | ((val.x[@intCast(@divFloor(i, 64))] >> @intCast(@mod(i, 64))) & 1) << 1);
            const g: u2 = @intCast((put.v[p / 64] >> @intCast(p % 64)) & 1 | ((put.x[p / 64] >> @intCast(p % 64)) & 1) << 1);
            try std.testing.expectEqual(want, g);
        }
        const p: u32 = rand.uintLessThan(u32, sw);
        const one = wide(up(W{ .v = 1, .x = 1 }, p, sw));
        const bm = bit(p, sw);
        for (0..words(sw)) |j| {
            const want: u64 = if (j == p / 64) @as(u64, 1) << @intCast(p % 64) else 0;
            try std.testing.expectEqual(want, one.v[j]);
            try std.testing.expectEqual(want, one.x[j]);
            try std.testing.expectEqual(want, if (sw <= 64) bm else bm[j]);
        }
        const b = bitAt(narrow(sw, a), p, sw - 1, 0, sw);
        try std.testing.expectEqual((a.v[p / 64] >> @intCast(p % 64)) & 1, b.v);
        try std.testing.expectEqual((a.x[p / 64] >> @intCast(p % 64)) & 1, b.x);
    };
}

test "indexed part-select shifts preserve declaration direction and distant indices" {
    try std.testing.expectEqual(@as(?i64, 0), selectShift(4, 11, 4, 4, true));
    try std.testing.expectEqual(@as(?i64, 4), selectShift(11, 11, 4, 4, false));
    try std.testing.expectEqual(@as(?i64, 4), selectShift(4, 4, 11, 4, true));
    try std.testing.expectEqual(@as(?i64, 0), selectShift(11, 4, 11, 4, false));
    try std.testing.expectEqual(@as(?i64, null), selectShift(null, 7, 0, 4, true));
    for ([_]i64{ std.math.minInt(i64), std.math.maxInt(i64) }) |sh| {
        try std.testing.expectEqual(xs(4), part(W{ .v = 0xa5, .x = 0 }, sh, 4, 8));
        try std.testing.expectEqual(@as(u64, 0), field(sh, 4, 8));
        try std.testing.expectEqual(W{ .v = 0, .x = 0 }, place(W{ .v = 0xf, .x = 0 }, sh, 4, 8));
    }
    try std.testing.expectEqual(@as(?u32, null), pos(std.math.minInt(i64), 11, 4, 8));
}

test "&&, || and ! are Kleene's three-valued logic over 0, 1 and unknown (§5.1.9)" {
    const bits = [_]Bit{ .zero, .one, .z, .x };
    for (bits) |a| for (bits) |b| {
        // Kleene: 0, 1/2 for x or z, 1; `and` is the minimum, `or` the maximum.
        const ka = kleene(a);
        const kb = kleene(b);
        try std.testing.expectEqual(fromKleene(@min(ka, kb)), logical(.@"and", a, b));
        try std.testing.expectEqual(fromKleene(@max(ka, kb)), logical(.@"or", a, b));
    };
    for (bits) |a| try std.testing.expectEqual(fromKleene(2 - kleene(a)), invert(a));
}

fn kleene(b: Bit) u2 {
    return switch (b) {
        .zero => 0,
        .x, .z => 1,
        .one => 2,
    };
}

fn fromKleene(level: u2) Bit {
    return switch (level) {
        0 => .zero,
        1 => .x,
        2 => .one,
        3 => unreachable,
    };
}

test "low and ctx read and widen one bit, sign-extended when signed" {
    try std.testing.expectEqual(Bit.one, low(W{ .v = 0b11, .x = 0 }));
    try std.testing.expectEqual(Bit.x, low(W{ .v = 1, .x = 1 }));
    try std.testing.expectEqual(Bit.z, low(W{ .v = 0, .x = 1 }));
    try std.testing.expectEqual(Bit.zero, low(Wide(2){ .v = .{ 2, 1 }, .x = .{ 0, 1 } }));
    // A 1-bit signed 1 is -1: four 1s at 4 bits; unsigned it is 1.
    try std.testing.expectEqual(W{ .v = 0xf, .x = 0 }, ctx(.one, 4, true));
    try std.testing.expectEqual(W{ .v = 1, .x = 0 }, ctx(.one, 4, false));
    try std.testing.expectEqual(W{ .v = 0xf, .x = 0xf }, ctx(.x, 4, true));
    try std.testing.expectEqual(W{ .v = 0, .x = 1 }, ctx(.z, 4, false));
    try std.testing.expectEqual(W{ .v = 0, .x = 0xf }, ctx(.z, 4, true));
    try std.testing.expectEqual(W{ .v = 0, .x = 0 }, ctx(.zero, 4, true));
}

test "$clog2 of a one-word value is the least k with 2^k >= it; x reads as 0 (§17.11)" {
    for (0..1025) |i| {
        const v: u64 = @intCast(i);
        var want: u64 = 0;
        while (std.math.shl(u64, 1, want) < v) want += 1;
        try std.testing.expectEqual(want, clog2(W{ .v = v, .x = 0 }, 64));
    }
    try std.testing.expectEqual(@as(u64, 64), clog2(W{ .v = std.math.maxInt(u64), .x = 0 }, 64));
    try std.testing.expectEqual(@as(u64, 63), clog2(W{ .v = 1 << 63, .x = 0 }, 64));
    try std.testing.expectEqual(@as(u64, 0), clog2(W{ .v = 1000, .x = 8 }, 64));
}

test "real to integer rounds half away from zero; one with no 64-bit integer is x (§4.8.2)" {
    const of = struct {
        fn int(i: i64) W {
            return .{ .v = @bitCast(i), .x = 0 };
        }
    }.int;
    try std.testing.expectEqual(of(36), ofReal(35.5));
    try std.testing.expectEqual(of(-2), ofReal(-1.5));
    try std.testing.expectEqual(of(1), ofReal(0.5));
    try std.testing.expectEqual(of(-1), ofReal(-0.5));
    try std.testing.expectEqual(of(0), ofReal(0.49999999999999994));
    // The largest binary64 below 2^63.
    try std.testing.expectEqual(of(0x7fff_ffff_ffff_fc00), ofReal(0x1p63 - 1024));
    // -2^63 is an i64 (§4.8.2).
    try std.testing.expectEqual(of(std.math.minInt(i64)), ofReal(-0x1p63));
    const x64: W = .{ .v = std.math.maxInt(u64), .x = std.math.maxInt(u64) };
    for ([_]f64{ 0x1p63, std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64) }) |r|
        try std.testing.expectEqual(x64, ofReal(r));
}

test "$rtoi truncates toward zero into 32 bits; one with no 32-bit integer is x (§17.8)" {
    try std.testing.expectEqual(W{ .v = 2, .x = 0 }, rtoi(2.9));
    try std.testing.expectEqual(W{ .v = 0xffff_fffe, .x = 0 }, rtoi(-2.9));
    try std.testing.expectEqual(W{ .v = 0x7fff_ffff, .x = 0 }, rtoi(2147483647.9));
    // -2^31 is an i32, and so is what truncates to it.
    try std.testing.expectEqual(W{ .v = 0x8000_0000, .x = 0 }, rtoi(-0x1p31));
    try std.testing.expectEqual(W{ .v = 0x8000_0000, .x = 0 }, rtoi(-2147483648.9));
    const x32: W = .{ .v = 0xffff_ffff, .x = 0xffff_ffff };
    for ([_]f64{ 0x1p31, -2147483649.0, std.math.inf(f64), std.math.nan(f64) }) |r|
        try std.testing.expectEqual(x32, rtoi(r));
}

test "integer to real reads the operand's own signedness, x and z bits as 0 (§4.8.2)" {
    try std.testing.expectEqual(@as(f64, -1), toReal(W{ .v = 0xff, .x = 0 }, 8, true));
    try std.testing.expectEqual(@as(f64, 255), toReal(W{ .v = 0xff, .x = 0 }, 8, false));
    // 2'b1x: the x bit is 0, so 2.
    try std.testing.expectEqual(@as(f64, 2), toReal(W{ .v = 0b11, .x = 0b01 }, 2, false));
    // 4'bx000 signed: its sign bit is x, read as 0.
    try std.testing.expectEqual(@as(f64, 0), toReal(W{ .v = 0b1000, .x = 0b1000 }, 4, true));
    // A real slot's bits round-trip.
    try std.testing.expectEqual(@as(f64, -0.0), real(realBits(-0.0)));
    try std.testing.expect(std.math.signbit(real(realBits(-0.0))));
    // A real `?:` under an unknown condition is 0 (§5.1.13); a real's truth
    // is "not zero", -0.0 included.
    try std.testing.expectEqual(@as(f64, 0), realCond(.x, 1, 2));
    try std.testing.expectEqual(@as(f64, 0), realCond(.z, 1, 2));
    try std.testing.expectEqual(@as(f64, 1), realCond(.one, 1, 2));
    try std.testing.expectEqual(@as(f64, 2), realCond(.zero, 1, 2));
    try std.testing.expectEqual(Bit.zero, realTruth(-0.0));
    try std.testing.expectEqual(Bit.one, realTruth(1e-300));
}

test "casez/casex agree with the per-bit wildcard rule" {
    var prng = std.Random.DefaultPrng.init(0x951);
    const rand = prng.random();
    for (0..5000) |_| {
        const a = randomW(rand, 6);
        const b = randomW(rand, 6);
        try std.testing.expectEqual(caseMatch(.casez, a, b), caseMatch(.casez, rs(a, 6, 130, false), rs(b, 6, 130, false)));
        try std.testing.expectEqual(caseMatch(.casex, a, b), caseMatch(.casex, rs(a, 6, 130, false), rs(b, 6, 130, false)));
        inline for (.{ .casez, .casex }) |kind| {
            var want = true;
            for (0..6) |i| {
                const ab: u2 = @intCast((a.v >> @intCast(i)) & 1 | ((a.x >> @intCast(i)) & 1) << 1);
                const bb: u2 = @intCast((b.v >> @intCast(i)) & 1 | ((b.x >> @intCast(i)) & 1) << 1);
                const wild = ab == 2 or bb == 2 or (kind == .casex and (ab == 3 or bb == 3));
                if (!wild and ab != bb) want = false;
            }
            try std.testing.expectEqual(want, caseMatch(kind, a, b));
        }
        try std.testing.expectEqual(eq(.case_eq, a, b) == .one, caseMatch(.normal, a, b));
    }
}

test "span is bits [lo, hi) of word j, clamped: the mask root.forcedBits once built by hand" {
    for (0..3) |j| for (0..200) |lo| for (0..80) |width| {
        const a: i64 = @as(i64, @intCast(lo)) - 64 * @as(i64, @intCast(j));
        const b = a + @as(i64, @intCast(width));
        var want: u64 = 0;
        if (b > 0 and a < 64) {
            const p: u7 = @intCast(@max(a, 0));
            const q: u7 = @intCast(@min(b, 64));
            want = (std.math.shl(u64, 1, q) -% 1) & ~(std.math.shl(u64, 1, p) -% 1);
        }
        try std.testing.expectEqual(want, span(j, @intCast(lo), @intCast(lo + width)));
    };
}

test "xs and full cover exactly the width, at and across word ends" {
    inline for (.{ 1, 63, 64, 65, 128, 130 }) |w| {
        const f = wide(xs(w));
        var bits: u32 = 0;
        for (f.v, f.x) |v, x| {
            try std.testing.expectEqual(v, x);
            bits += @popCount(v);
        }
        try std.testing.expectEqual(@as(u32, w), bits);
        try std.testing.expectEqual(f.v, wide(T(w){ .v = full(w), .x = full(w) }).v);
    }
    // An unknown multi-word amount shifts to all x (§5.1.12).
    const amount: Wide(2) = .{ .v = .{ 1, 0 }, .x = .{ 0, 1 } };
    try std.testing.expectEqual(xs(8), shift(.left, W{ .v = 1, .x = 0 }, 8, false, amount));
}
