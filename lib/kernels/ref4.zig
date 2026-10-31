//! L3 `ref4`: a per-bit four-state evaluator written from
//! IEEE 1364-2005 §5's tables, and the tests that hold `integer.zig`'s
//! `Literal` operations to it. In: operands as `V` (one `B` per bit, a width,
//! a signedness); out: the `V` or `B` the clause defines. It shares no code
//! with `integer.zig`: a value is a bit array, the logic tables are the LRM's
//! cells as printed, and known arithmetic is Zig's u256/i256, never
//! `std.math.big`. The one crossing is `lit`/`fromLit`, through `Literal`'s
//! fields and its `bit` accessor, and the first test checks that crossing.
//! Exhaustive at widths 1-4 (every value of each operand, every width pair,
//! every signedness pair); seeded random at the widths the digital fuzzer draws
//! (`tests/suite.zig` `fuzz_widths`).
//! Clauses: 1364-2005 §5.1.5 (Tables 5-5 to 5-8), §§5.1.7-5.1.14 (Tables 5-10
//! to 5-21), §5.4.1 (Table 5-22), §§5.5.1, 5.5.2, 5.5.4.
//!
//! Three readings, where the text leaves a gap:
//!  - §5.1.10 and §5.1.13 zero-fill a shorter operand; §5.5.2 extends every
//!    context-determined operand by the propagated type, so both-signed
//!    operands sign-extend, and §5.5.4 fills with x or z when the sign bit is
//!    one. The reference follows §5.5.2.
//!  - §5.1.11 defines a reduction by steps between pairs of bits, which a
//!    1-bit operand has none of. The reference folds from the operator's
//!    identity (1 for &, 0 for | and ^). From two bits up that is the clause's
//!    steps exactly: each table's x and z rows are equal, and the identity row
//!    hands a known bit back unchanged.
//!  - §5.5.4's "any nonlogical operation" on a signed value holding x or z is
//!    read as the arithmetic operators, whose §5.1.5 rule already makes the
//!    whole result x. Bitwise, shift, equality and the conditional follow
//!    their own clauses' tables.
//!
//! Contents: nothing public; the file is an oracle and its tests. `V.format`
//! is the std print hook a failing test reports operands through.

const std = @import("std");
const integer = @import("integer.zig");
const Literal = integer.Literal;

/// One four-state bit, in the LRM tables' row and column order: 0 1 x z.
const B = enum { b0, b1, x, z };

// Tables 5-12 (&), 5-13 (|), 5-14 (^) and 5-15 (^~): rows are the left
// operand, columns the right. Tables 5-17 to 5-19, the reductions, repeat
// 5-12 to 5-14 cell for cell.
const t_and = table(.{ "0000", "01xx", "0xxx", "0xxx" });

const t_or = table(.{ "01xx", "1111", "x1xx", "x1xx" });

const t_xor = table(.{ "01xx", "10xx", "xxxx", "xxxx" });

const t_xnor = table(.{ "10xx", "01xx", "xxxx", "xxxx" });

// Table 5-21: the conditional's bit merge under an ambiguous condition.
const t_cond = table(.{ "0xxx", "x1xx", "xxxx", "xxxx" });

// Table 5-16 (~), one column.
const t_not = [4]B{ cell('1'), cell('0'), cell('x'), cell('x') };

/// The widest value either half of the test builds: fuzz_widths tops out at
/// 129, and the random concatenations stay under this.
const max_w = 136;

/// A four-state value: `b[0]` is the least significant bit.
const V = struct {
    w: u32,
    s: bool,
    b: [max_w]B = @splat(.b0),

    fn isKnown(v: *const V) bool {
        for (v.b[0..v.w]) |c| if (!known(c)) return false;
        return true;
    }

    /// Bit `i` of `v` extended under the propagated type (§5.5.2): copies of
    /// the sign bit, x and z included (§5.5.4), when `signed`, else 0.
    fn ext(v: *const V, i: usize, signed: bool) B {
        if (i < v.w) return v.b[i];
        return if (signed) v.b[v.w - 1] else .b0;
    }

    /// The bits read as an unsigned number. Asserts every bit is known.
    fn uval(v: *const V) u256 {
        var r: u256 = 0;
        var i = v.w;
        while (i > 0) {
            i -= 1;
            std.debug.assert(known(v.b[i]));
            r = (r << 1) | @intFromBool(v.b[i] == .b1);
        }
        return r;
    }

    /// The bits read as a two's complement number of width `w`.
    fn sval(v: *const V) i256 {
        const u: i256 = @intCast(v.uval());
        return if (v.b[v.w - 1] == .b1) u - (@as(i256, 1) << @intCast(v.w)) else u;
    }

    /// The value under the operand's own type (§5.1.6, Table 5-9).
    fn num(v: *const V) i256 {
        return if (v.s) v.sval() else @intCast(v.uval());
    }

    pub fn format(v: V, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}'{s}b", .{ v.w, if (v.s) "s" else "" });
        var i = v.w;
        while (i > 0) {
            i -= 1;
            try w.writeByte("01xz"[idx(v.b[i])]);
        }
    }
};

const Op2 = enum { bit_and, bit_or, bit_xor, bit_xnor };

const Red = enum { r_and, r_nand, r_or, r_nor, r_xor, r_xnor };

const Rel = enum { lt, le, gt, ge };

const Sh = enum { shl, shr, ashl, ashr };

const Ar = enum { add, sub, mul, div, rem };

/// One operand, both ways.
const Arg = struct { v: V, l: Literal };

/// Scratch for each operation's result, reset per call: the operand
/// `Literal`s outlive it, the results do not. A 129-bit power's big-integer
/// temporaries are the largest user.
const Scratch = struct {
    buf: []u8,
    fba: std.heap.FixedBufferAllocator = undefined,

    fn init(a: std.mem.Allocator) !Scratch {
        return .{ .buf = try a.alloc(u8, 1 << 20) };
    }

    fn get(self: *Scratch) std.mem.Allocator {
        self.fba = .init(self.buf);
        return self.fba.allocator();
    }
};

/// tests/suite.zig's `fuzz_widths`: where the one-word and multiword
/// paths of `integer.zig` meet.
const fuzz_widths = [_]u32{ 1, 2, 3, 7, 8, 13, 16, 31, 32, 33, 48, 63, 64, 65, 100, 128, 129 };

// ---- private ----

fn cell(comptime c: u8) B {
    return switch (c) {
        '0' => .b0,
        '1' => .b1,
        'x' => .x,
        'z' => .z,
        else => @compileError("not a logic table cell"),
    };
}

/// A 4×4 table, one string per row, as the LRM prints it.
fn table(comptime rows: [4]*const [4]u8) [4][4]B {
    var t: [4][4]B = undefined;
    for (rows, 0..) |row, i| {
        for (row, 0..) |c, j| t[i][j] = cell(c);
    }
    return t;
}

fn idx(b: B) usize {
    return switch (b) {
        .b0 => 0,
        .b1 => 1,
        .x => 2,
        .z => 3,
    };
}

fn known(b: B) bool {
    return b == .b0 or b == .b1;
}

fn not(a: B) B {
    return t_not[idx(a)];
}

fn op2(t: *const [4][4]B, a: B, b: B) B {
    return t[idx(a)][idx(b)];
}

/// The low `w` bits of `x`: arithmetic modulo 2^w.
fn fromInt(w: u32, s: bool, x: u256) V {
    var r: V = .{ .w = w, .s = s };
    for (0..w) |i| r.b[i] = if ((x >> @intCast(i)) & 1 == 1) .b1 else .b0;
    return r;
}

fn allX(w: u32, s: bool) V {
    var r: V = .{ .w = w, .s = s };
    @memset(r.b[0..w], .x);
    return r;
}

/// `v` brought to the expression's size and type (§5.5.2's last step).
fn widen(v: *const V, w: u32, s: bool) V {
    var r: V = .{ .w = w, .s = s };
    for (0..w) |i| r.b[i] = v.ext(i, s);
    return r;
}

/// §5.1.10: bit by bit through Tables 5-12 to 5-15. Table 5-22: the width is
/// the larger operand's; §5.5.1: signed only when both are.
fn bitwise(op: Op2, a: *const V, b: *const V) V {
    const t = switch (op) {
        .bit_and => &t_and,
        .bit_or => &t_or,
        .bit_xor => &t_xor,
        .bit_xnor => &t_xnor,
    };
    const w = @max(a.w, b.w);
    const s = a.s and b.s;
    var r: V = .{ .w = w, .s = s };
    for (0..w) |i| r.b[i] = op2(t, a.ext(i, s), b.ext(i, s));
    return r;
}

/// Table 5-16, bit by bit; the operand's width and type (Table 5-22, `op i`).
fn bitNot(a: *const V) V {
    var r: V = .{ .w = a.w, .s = a.s };
    for (0..a.w) |i| r.b[i] = not(a.b[i]);
    return r;
}

/// §5.1.11: the operator applied between the running result and each bit in
/// turn; the n-forms invert the result through Table 5-16.
fn reduce(op: Red, a: *const V) B {
    const t: *const [4][4]B = switch (op) {
        .r_and, .r_nand => &t_and,
        .r_or, .r_nor => &t_or,
        .r_xor, .r_xnor => &t_xor,
    };
    var r: B = if (t == &t_and) .b1 else .b0;
    for (a.b[0..a.w]) |c| r = op2(t, r, c);
    return switch (op) {
        .r_nand, .r_nor, .r_xnor => not(r),
        .r_and, .r_or, .r_xor => r,
    };
}

/// §5.1.8 `==`: bit for bit after §5.5.2 extension. A position whose bits
/// are both known either must match or cannot; one with an x or z could go
/// either way. One that cannot match decides 0; every one that must decides
/// 1; anything else is "ambiguous ... due to unknown or high-impedance bits".
fn eq(a: *const V, b: *const V) B {
    const w = @max(a.w, b.w);
    const s = a.s and b.s;
    var ambiguous = false;
    for (0..w) |i| {
        const p = a.ext(i, s);
        const q = b.ext(i, s);
        if (known(p) and known(q)) {
            if (p != q) return .b0;
        } else ambiguous = true;
    }
    return if (ambiguous) .x else .b1;
}

/// §5.1.8 `===`: x and z compared as values, so the result is always known.
fn caseEq(a: *const V, b: *const V) B {
    const w = @max(a.w, b.w);
    const s = a.s and b.s;
    for (0..w) |i| if (a.ext(i, s) != b.ext(i, s)) return .b0;
    return .b1;
}

/// §5.1.9 and §5.1.13: an operand's truth value is its "logical equality
/// comparison ... with zero", inverted.
fn truth(a: *const V) B {
    const zero = fromInt(a.w, false, 0);
    return not(eq(a, &zero));
}

/// §5.1.7: x when either operand holds an x or z; otherwise a signed
/// comparison when both are signed, else unsigned (zero extension keeps an
/// unsigned value's magnitude, sign extension a signed one's).
fn relational(op: Rel, a: *const V, b: *const V) B {
    if (!a.isKnown() or !b.isKnown()) return .x;
    const p: i256 = if (a.s and b.s) a.sval() else @intCast(a.uval());
    const q: i256 = if (a.s and b.s) b.sval() else @intCast(b.uval());
    const holds = switch (op) {
        .lt => p < q,
        .le => p <= q,
        .gt => p > q,
        .ge => p >= q,
    };
    return if (holds) .b1 else .b0;
}

/// §5.1.12. The right operand is unsigned and self-determined; an x or z in
/// it makes the result unknown. The result has the left operand's width and
/// type (Table 5-22). `>>>` fills with the left operand's top bit, whatever
/// its value, when the result is signed.
fn shift(op: Sh, a: *const V, n: *const V) V {
    if (!n.isKnown()) return allX(a.w, a.s);
    var k: usize = 0;
    for (n.b[0..n.w], 0..) |c, i| if (c == .b1) {
        if (i >= 32) {
            k = a.w;
            break;
        }
        k |= @as(usize, 1) << @intCast(i);
    };
    k = @min(k, a.w);
    const fill: B = if (op == .ashr and a.s) a.b[a.w - 1] else .b0;
    var r: V = .{ .w = a.w, .s = a.s };
    for (0..a.w) |i| r.b[i] = switch (op) {
        .shl, .ashl => if (i >= k) a.b[i - k] else .b0,
        .shr, .ashr => if (i + k < a.w) a.b[i + k] else fill,
    };
    return r;
}

/// §5.1.5: any x or z bit makes the whole result x, so does a zero divisor;
/// division truncates toward zero and the modulus takes the first operand's
/// sign. Width max(L(a), L(b)) and signed when both are (Table 5-22,
/// §5.5.1); the operands take that size and type first (§5.5.2), and the
/// result is the low bits of the exact value.
fn arith(op: Ar, a: *const V, b: *const V) V {
    const w = @max(a.w, b.w);
    const s = a.s and b.s;
    if (!a.isKnown() or !b.isKnown()) return allX(w, s);
    const x = widen(a, w, s);
    const y = widen(b, w, s);
    const ux = x.uval();
    const uy = y.uval();
    return switch (op) {
        .add => fromInt(w, s, ux +% uy),
        .sub => fromInt(w, s, ux -% uy),
        .mul => fromInt(w, s, ux *% uy),
        .div, .rem => if (uy == 0) allX(w, s) else if (!s)
            fromInt(w, s, if (op == .div) ux / uy else ux % uy)
        else
            fromInt(w, s, @bitCast(if (op == .div) @divTrunc(x.sval(), y.sval()) else @rem(x.sval(), y.sval()))),
    };
}

/// Table 5-7's unary minus: the operand's width and type, x on any x or z.
fn negate(a: *const V) V {
    if (!a.isKnown()) return allX(a.w, a.s);
    return fromInt(a.w, a.s, 0 -% a.uval());
}

/// §5.1.5 `**` with integer operands, Table 5-6 row by row. The exponent is
/// self-determined (its own type decides whether it is negative); the result
/// has the base's width and type (Table 5-22). x on any x or z bit.
fn power(a: *const V, e: *const V) V {
    const w = a.w;
    const s = a.s;
    if (!a.isKnown() or !e.isKnown()) return allX(w, s);
    const one = fromInt(w, s, 1);
    const minus_one = fromInt(w, s, std.math.maxInt(u256));
    const parity = if (e.b[0] == .b1) minus_one else one; // op2 odd -> -1, even -> 1
    const base = a.num();
    const exp = e.num();
    if (exp == 0) return one; // row "zero": 1 for every op1
    if (exp > 0) { // row "positive"
        if (base == -1) return parity;
        if (base == 0) return fromInt(w, s, 0);
        if (base == 1) return one;
        // op1 ** op2: the product's low w bits, by squaring.
        var r: u256 = 1;
        var m = a.uval();
        var k: u256 = @intCast(exp);
        while (k != 0) : (k >>= 1) {
            if (k & 1 == 1) r *%= m;
            m *%= m;
        }
        return fromInt(w, s, r);
    }
    // row "negative"
    if (base == -1) return parity;
    if (base == 0) return allX(w, s); // 'bx
    if (base == 1) return one;
    return fromInt(w, s, 0); // below -1 or above 1
}

/// §5.1.13 with Table 5-21. The condition is self-determined; the result is
/// max(L(j), L(k)) wide (Table 5-22) and signed when both arms are (§5.5.1).
fn conditional(c: *const V, y: *const V, n: *const V) V {
    const w = @max(y.w, n.w);
    const s = y.s and n.s;
    const t = truth(c);
    var r: V = .{ .w = w, .s = s };
    for (0..w) |i| r.b[i] = switch (t) {
        .b1 => y.ext(i, s),
        .b0 => n.ext(i, s),
        .x, .z => op2(&t_cond, y.ext(i, s), n.ext(i, s)),
    };
    return r;
}

/// §5.1.14: the first operand is the most significant; the result is
/// unsigned (§5.5.1) and as wide as the parts together (Table 5-22).
fn concat(parts: []const *const V) V {
    var w: u32 = 0;
    for (parts) |p| w += p.w;
    var r: V = .{ .w = w, .s = false };
    var at = w;
    for (parts) |p| {
        at -= p.w;
        @memcpy(r.b[at..][0..p.w], p.b[0..p.w]);
    }
    return r;
}

/// §5.6's truncation (the low bits survive) and §5.5.3/§5.5.4's extension
/// (copies of the top bit, x and z too, when `sign`). The type stays.
fn resize(v: *const V, w: u32, sign: bool) V {
    var r: V = .{ .w = w, .s = v.s };
    for (0..w) |i| r.b[i] = if (i < v.w) v.b[i] else if (sign) v.b[v.w - 1] else .b0;
    return r;
}

/// `v` as a `Literal`, in the plane encoding `integer.zig` documents
/// ((value, unknown) = 00/10/11/01 for 0/1/x/z), padding clear.
fn lit(a: std.mem.Allocator, v: *const V) !Literal {
    const words = (v.w + 63) / 64;
    const planes = try a.alloc(u64, words * 2);
    @memset(planes, 0);
    for (v.b[0..v.w], 0..) |c, i| {
        const m = @as(u64, 1) << @intCast(i % 64);
        if (c == .b1 or c == .x) planes[i / 64] |= m;
        if (c == .x or c == .z) planes[words + i / 64] |= m;
    }
    return .{ .width = v.w, .sized = true, .signed = v.s, .planes = planes };
}

fn fromBit(b: integer.Bit) B {
    return switch (b) {
        .zero => .b0,
        .one => .b1,
        .x => .x,
        .z => .z,
    };
}

fn fromLit(l: Literal) V {
    std.debug.assert(l.width <= max_w);
    var r: V = .{ .w = l.width, .s = l.signed };
    for (0..l.width) |i| r.b[i] = fromBit(l.bit(@intCast(i)));
    return r;
}

fn sameV(got: *const V, want: *const V) bool {
    return got.w == want.w and got.s == want.s and std.mem.eql(B, got.b[0..got.w], want.b[0..want.w]);
}

fn expectV(what: []const u8, args: []const *const Arg, got: Literal, want: V) !void {
    if (got.width <= max_w) {
        const g = fromLit(got);
        if (sameV(&g, &want)) return;
        std.debug.print("ref4: {s}: got {f}, want {f} for", .{ what, g, want });
    } else std.debug.print("ref4: {s}: got a {d}-bit result, want {f} for", .{ what, got.width, want });
    for (args) |a| std.debug.print(" {f}", .{a.v});
    std.debug.print("\n", .{});
    return error.Ref4Mismatch;
}

fn expectB(what: []const u8, args: []const *const Arg, got: integer.Bit, want: B) !void {
    if (fromBit(got) == want) return;
    std.debug.print("ref4: {s}: got {c}, want {c} for", .{ what, "01xz"[idx(fromBit(got))], "01xz"[idx(want)] });
    for (args) |a| std.debug.print(" {f}", .{a.v});
    std.debug.print("\n", .{});
    return error.Ref4Mismatch;
}

/// Every value of widths `lo`..`hi`, unsigned then signed.
fn small(a: std.mem.Allocator, lo: u32, hi: u32) ![]Arg {
    var n: usize = 0;
    for (lo..hi + 1) |w| n += 2 * (@as(usize, 1) << @intCast(2 * w));
    const out = try a.alloc(Arg, n);
    var k: usize = 0;
    for ([_]bool{ false, true }) |s| for (lo..hi + 1) |w| {
        for (0..@as(usize, 1) << @intCast(2 * w)) |code| {
            var v: V = .{ .w = @intCast(w), .s = s };
            for (0..w) |i| v.b[i] = switch ((code >> @intCast(2 * i)) & 3) {
                0 => .b0,
                1 => .b1,
                2 => .x,
                else => .z,
            };
            out[k] = .{ .v = v, .l = try lit(a, &v) };
            k += 1;
        }
    };
    return out;
}

fn binaryOps(sc: *Scratch, a: *const Arg, b: *const Arg) !void {
    const args = [_]*const Arg{ a, b };
    inline for (.{
        .{ integer.Bitwise.and_bits, Op2.bit_and, "&" },
        .{ integer.Bitwise.or_bits, Op2.bit_or, "|" },
        .{ integer.Bitwise.xor_bits, Op2.bit_xor, "^" },
        .{ integer.Bitwise.xnor_bits, Op2.bit_xnor, "~^" },
    }) |o| try expectV(o[2], &args, try a.l.bitwise(sc.get(), o[0], b.l), bitwise(o[1], &a.v, &b.v));
    inline for (.{
        .{ integer.Arithmetic.add, Ar.add, "+" },
        .{ integer.Arithmetic.subtract, Ar.sub, "-" },
        .{ integer.Arithmetic.multiply, Ar.mul, "*" },
        .{ integer.Arithmetic.divide, Ar.div, "/" },
        .{ integer.Arithmetic.remainder, Ar.rem, "%" },
    }) |o| try expectV(o[2], &args, try a.l.arithmetic(sc.get(), o[0], b.l), arith(o[1], &a.v, &b.v));
    inline for (.{
        .{ integer.Shift.left, Sh.shl, "<<" },
        .{ integer.Shift.right, Sh.shr, ">>" },
        .{ integer.Shift.arithmetic_left, Sh.ashl, "<<<" },
        .{ integer.Shift.arithmetic_right, Sh.ashr, ">>>" },
    }) |o| try expectV(o[2], &args, try a.l.shift(sc.get(), o[0], b.l), shift(o[1], &a.v, &b.v));
    try expectV("**", &args, try a.l.power(sc.get(), b.l), power(&a.v, &b.v));
    inline for (.{
        .{ integer.Relational.less, Rel.lt, "<" },
        .{ integer.Relational.less_equal, Rel.le, "<=" },
        .{ integer.Relational.greater, Rel.gt, ">" },
        .{ integer.Relational.greater_equal, Rel.ge, ">=" },
    }) |o| try expectB(o[2], &args, a.l.relational(o[0], b.l), relational(o[1], &a.v, &b.v));
    const e = eq(&a.v, &b.v);
    const ce = caseEq(&a.v, &b.v);
    try expectB("==", &args, a.l.equality(.equal, b.l), e);
    try expectB("!=", &args, a.l.equality(.not_equal, b.l), not(e));
    try expectB("===", &args, a.l.equality(.case_equal, b.l), ce);
    try expectB("!==", &args, a.l.equality(.case_not_equal, b.l), not(ce));
    // §5.1.9: && and || are Tables 5-12 and 5-13 over the truth values.
    try expectB("&&", &args, a.l.logical(.and_bits, b.l), op2(&t_and, truth(&a.v), truth(&b.v)));
    try expectB("||", &args, a.l.logical(.or_bits, b.l), op2(&t_or, truth(&a.v), truth(&b.v)));
}

fn concatOp(sc: *Scratch, a: *const Arg, b: *const Arg) !void {
    try expectV("{,}", &.{ a, b }, try Literal.concatenate(sc.get(), &.{ a.l, b.l }), concat(&.{ &a.v, &b.v }));
}

fn condOp(sc: *Scratch, c: *const Arg, y: *const Arg, n: *const Arg) !void {
    try expectV("?:", &.{ c, y, n }, try c.l.conditional(sc.get(), y.l, n.l), conditional(&c.v, &y.v, &n.v));
}

fn unaryOps(sc: *Scratch, a: *const Arg) !void {
    const args = [_]*const Arg{a};
    try expectV("~", &args, try a.l.bitwiseNot(sc.get()), bitNot(&a.v));
    try expectV("unary -", &args, try a.l.negate(sc.get()), negate(&a.v));
    try expectB("truth", &args, a.l.truth(), truth(&a.v));
    inline for (.{
        .{ integer.Reduction.and_bits, Red.r_and, "&" },
        .{ integer.Reduction.nand_bits, Red.r_nand, "~&" },
        .{ integer.Reduction.or_bits, Red.r_or, "|" },
        .{ integer.Reduction.nor_bits, Red.r_nor, "~|" },
        .{ integer.Reduction.xor_bits, Red.r_xor, "^" },
        .{ integer.Reduction.xnor_bits, Red.r_xnor, "~^" },
    }) |o| try expectB(o[2], &args, a.l.reduce(o[0]), reduce(o[1], &a.v));
    for (1..4) |k| {
        if (a.v.w * k > max_w) break;
        const parts = [3]*const V{ &a.v, &a.v, &a.v };
        try expectV("{k{}}", &args, try a.l.replicate(sc.get(), @intCast(k)), concat(parts[0..k]));
    }
    for ([_]u32{ 1, a.v.w -| 1, a.v.w, a.v.w + 1, a.v.w + 5, 64, 65 }) |w| {
        if (w == 0) continue;
        try expectV("resize zero", &args, try a.l.resize(sc.get(), w, .zero), resize(&a.v, w, false));
        try expectV("resize sign", &args, try a.l.resize(sc.get(), w, .sign), resize(&a.v, w, true));
    }
    // `asInt`: the value under the operand's type, null past 64 bits or on
    // an x or z bit.
    const want: ?i64 = if (a.v.w > 64 or !a.v.isKnown()) null else if (a.v.s)
        @as(i64, @intCast(a.v.sval()))
    else
        @as(i64, @bitCast(@as(u64, @intCast(a.v.uval()))));
    if (a.l.asInt() != want) {
        std.debug.print("ref4: asInt: got {?d}, want {?d} for {f}\n", .{ a.l.asInt(), want, a.v });
        return error.Ref4Mismatch;
    }
}

/// A random operand: fully known half the time (or arithmetic would almost
/// never leave its x path), else x and z sprinkled or uniform, with the
/// patterns that end ranges (0, all ones, the sign bit alone) mixed in.
fn randomV(r: std.Random, w: u32) V {
    var v: V = .{ .w = w, .s = r.boolean() };
    switch (r.uintLessThan(u8, 8)) {
        0 => {},
        1 => @memset(v.b[0..w], .b1),
        2 => v.b[w - 1] = .b1,
        3, 4, 5 => for (0..w) |i| {
            v.b[i] = if (r.boolean()) .b1 else .b0;
        },
        6 => for (0..w) |i| {
            v.b[i] = switch (r.uintLessThan(u8, 16)) {
                0 => .x,
                1 => .z,
                else => if (r.boolean()) .b1 else .b0,
            };
        },
        else => for (0..w) |i| {
            v.b[i] = switch (r.uintLessThan(u8, 4)) {
                0 => .b0,
                1 => .b1,
                2 => .x,
                else => .z,
            };
        },
    }
    return v;
}

fn randomArg(a: std.mem.Allocator, r: std.Random, w: u32) !Arg {
    const v = randomV(r, w);
    return .{ .v = v, .l = try lit(a, &v) };
}

test "ref4: the crossing reads back every small value through Literal.bit" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for (try small(arena.allocator(), 1, 4)) |a| {
        const back = fromLit(a.l);
        try std.testing.expect(sameV(&back, &a.v));
    }
    // The tables are the LRM's: spot cells a transcription slip would move.
    try std.testing.expectEqual(B.b0, op2(&t_and, .z, .b0));
    try std.testing.expectEqual(B.b1, op2(&t_or, .x, .b1));
    try std.testing.expectEqual(B.x, op2(&t_cond, .z, .z));
    try std.testing.expectEqual(B.x, not(.z));
}

test "ref4 §5.1 every binary operator, exhaustive over widths 1-4 and both signednesses" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const vals = try small(arena.allocator(), 1, 4);
    var sc: Scratch = try .init(arena.allocator());
    for (vals) |*a| for (vals) |*b| {
        try binaryOps(&sc, a, b);
        try concatOp(&sc, a, b);
    };
}

test "ref4 §5.1 every unary operator, resize and replication, exhaustive over widths 1-4" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var sc: Scratch = try .init(arena.allocator());
    for (try small(arena.allocator(), 1, 4)) |*a| try unaryOps(&sc, a);
}

test "ref4 §5.1.13 Table 5-21: the conditional, exhaustive over 1-2 bit conditions and 1-3 bit arms" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const conds = try small(arena.allocator(), 1, 2);
    const arms = try small(arena.allocator(), 1, 3);
    var sc: Scratch = try .init(arena.allocator());
    for (conds) |*c| for (arms) |*y| for (arms) |*n| try condOp(&sc, c, y, n);
}

test "ref4 §5.1 every operator on seeded random operands at the fuzzer's widths" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = .init(0x4ef00f04);
    const r = prng.random();
    var sc: Scratch = try .init(std.testing.allocator);
    defer std.testing.allocator.free(sc.buf);
    for (0..6000) |_| {
        _ = arena.reset(.retain_capacity);
        const al = arena.allocator();
        const any = fuzz_widths.len;
        const a = try randomArg(al, r, fuzz_widths[r.uintLessThan(usize, any)]);
        // A narrow right operand half the time: shift counts and exponents
        // that land inside the width.
        const b = try randomArg(al, r, fuzz_widths[r.uintLessThan(usize, if (r.boolean()) 6 else any)]);
        const c = try randomArg(al, r, fuzz_widths[r.uintLessThan(usize, any)]);
        try binaryOps(&sc, &a, &b);
        if (a.v.w + b.v.w <= max_w) try concatOp(&sc, &a, &b);
        try unaryOps(&sc, &a);
        try condOp(&sc, &c, &a, &b);
    }
}
