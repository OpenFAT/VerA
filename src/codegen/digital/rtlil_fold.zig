//! An IEEE 1364 constant expression in, its four-state value out
//! (`kernels.Integer.Literal`), sized and signed as `vera --run` sizes it:
//! §5.4.1 Table 5-22's widths, §5.5's signedness propagated down to the
//! operands, an unsized decimal 32 bits (64 when its value needs them) and
//! an unsized based one as wide as its digits past 32 (VD-131). `rtlil.zig`
//! folds parameter defaults, declared ranges, select bounds, replication
//! counts, overrides and `initial` values with it. It is not the analog
//! `frontend.constfold`, whose VAMS §3.2 integers wrap at 32 bits: a 64-bit
//! localparam folded there loses its top half.
//!
//! Clauses: IEEE 1364-2005 §3.5.1 (unsized widths), §5.1 (the operators),
//! §5.4.1, §5.5.1 to §5.5.4, §12.2 (a parameter takes its value's type),
//! §17.11.1 (`$clog2`).
//!
//! Contents:
//! - `pub const Literal = Integer.Literal`
//! - `pub const Params`
//! - `pub const Error`
//! - `pub const max_width`
//! - `pub const max_depth`
//! - `pub fn fold(arena: Allocator, file: *const Ast.SourceFile, params: *const Params, e: ExprId, ctx: u32) Error!?Literal`
//! - `pub fn assigned(arena: Allocator, file: *const Ast.SourceFile, params: *const Params, e: ExprId, ctx: u32) Error!?Literal`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Integer = @import("kernels").Integer;
const Allocator = std.mem.Allocator;
const ExprId = Ast.ExprId;
const StrId = Ast.StrId;

/// A four-state value of any width, planes in the caller's arena.
pub const Literal = Integer.Literal;

/// The module's parameters by name, each at its §12.2 type. A name not here
/// (a net, a variable, a real parameter) is not a constant.
pub const Params = std.AutoHashMapUnmanaged(StrId, Literal);

/// `TooWide`: a value past `max_width` bits. `TooDeep`: operators nested
/// past `max_depth`. Either way the caller refuses the expression by name.
pub const Error = error{ OutOfMemory, TooWide, TooDeep };

/// The widest constant folded: 2^20 bits is 128 KiB a plane, wider than any
/// RTLIL wire a synthesis flow reads, and a replication cannot exhaust memory.
pub const max_width: u32 = 1 << 20;

/// Operators nested deeper than this are refused (`TooDeep`): the fold
/// recurses on the expression, whose depth the source controls.
pub const max_depth: u32 = 4096;

/// An expression's §5.4/§5.5 type: its width and whether it reads signed.
const Type = struct { width: u32, signed: bool };

const bit_type: Type = .{ .width = 1, .signed = false };
const integer_type: Type = .{ .width = 32, .signed = true };

const Folder = struct {
    arena: Allocator,
    file: *const Ast.SourceFile,
    params: *const Params,

    /// §5.4.1 Table 5-22, one row per operator.
    fn typeAt(f: Folder, e: ExprId, depth: u32) Error!?Type {
        assert(e != .none);
        if (depth > max_depth) return error.TooDeep;
        const ex = &f.file.exprs;
        const t: Type = switch (ex.tag(e)) {
            .int_literal => .{ .width = literalWidth(ex.intLiteral(e)), .signed = ex.intLiteral(e).signed },
            .logic_literal => .{ .width = ex.logicValue(e).width, .signed = ex.logicValue(e).signed },
            // §3.6: eight bits a character, and "" is one NUL.
            .str_literal => .{ .width = try narrow(8 * @max(1, @as(u64, f.file.str(ex.strOf(e)).len))), .signed = false },
            .ident => blk: {
                const p = f.params.get(ex.strOf(e)) orelse return null;
                break :blk .{ .width = p.width, .signed = p.signed };
            },
            .unary => switch (ex.unOp(e)) {
                .plus, .minus, .bit_not => (try f.typeAt(ex.lhs(e), depth + 1)) orelse return null,
                .logical_not, .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => blk: {
                    _ = (try f.typeAt(ex.lhs(e), depth + 1)) orelse return null;
                    break :blk bit_type;
                },
            },
            .binary => blk: {
                const a = (try f.typeAt(ex.lhs(e), depth + 1)) orelse return null;
                const b = (try f.typeAt(ex.rhs(e), depth + 1)) orelse return null;
                break :blk switch (ex.binOp(e)) {
                    .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => common(a, b),
                    .pow, .shl, .shr, .ashl, .ashr => a,
                    .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge, .logical_and, .logical_or => bit_type,
                };
            },
            .ternary => blk: {
                _ = (try f.typeAt(ex.lhs(e), depth + 1)) orelse return null;
                const a = (try f.typeAt(ex.rhs(e), depth + 1)) orelse return null;
                const b = (try f.typeAt(ex.ternaryElse(e), depth + 1)) orelse return null;
                break :blk common(a, b);
            },
            .concat => blk: {
                var w: u64 = 0;
                for (ex.args(e)) |a| {
                    if (unsizedLiteral(f.file, a)) return null;
                    w += ((try f.typeAt(a, depth + 1)) orelse return null).width;
                }
                break :blk .{ .width = try narrow(w), .signed = false };
            },
            .multi_concat => blk: {
                const n = (try f.count(ex.lhs(e), depth + 1)) orelse return null;
                if (unsizedLiteral(f.file, ex.rhs(e))) return null;
                const inner = (try f.typeAt(ex.rhs(e), depth + 1)) orelse return null;
                break :blk .{ .width = try narrow(@as(u64, inner.width) * n), .signed = false };
            },
            .sys_call => blk: {
                const name = f.file.str(ex.strOf(e));
                const args = ex.args(e);
                if (args.len != 1) return null;
                const a = (try f.typeAt(args[0], depth + 1)) orelse return null;
                if (std.mem.eql(u8, name, "$signed")) break :blk .{ .width = a.width, .signed = true };
                if (std.mem.eql(u8, name, "$unsigned")) break :blk .{ .width = a.width, .signed = false };
                // §17.11.1: `$clog2` returns an integer.
                if (std.mem.eql(u8, name, "$clog2")) break :blk integer_type;
                return null;
            },
            else => return null, // else: a real, a string, a select or a call is no constant this fold covers
        };
        assert(t.width != 0);
        if (t.width > max_width) return error.TooWide;
        return t;
    }

    /// `e` at the propagated type `ty`: the width is always `ty.width`.
    fn eval(f: Folder, e: ExprId, ty: Type, depth: u32) Error!?Literal {
        assert(ty.width != 0 and ty.width <= max_width);
        if (depth > max_depth) return error.TooDeep;
        const ex = &f.file.exprs;
        const a = f.arena;
        const v: Literal = switch (ex.tag(e)) {
            .int_literal => try convert(a, try intLiteral(a, ex.intLiteral(e)), ty),
            .logic_literal => try unsized(a, ex.logicValue(e), ty),
            .str_literal => try convert(a, try stringLiteral(a, f.file.str(ex.strOf(e))), ty),
            .ident => try convert(a, f.params.get(ex.strOf(e)) orelse return null, ty),
            .unary => switch (ex.unOp(e)) {
                .plus => (try f.eval(ex.lhs(e), ty, depth + 1)) orelse return null,
                .minus => try ((try f.eval(ex.lhs(e), ty, depth + 1)) orelse return null).negate(a),
                .bit_not => try ((try f.eval(ex.lhs(e), ty, depth + 1)) orelse return null).bitwiseNot(a),
                .logical_not => try bitAt(a, invert(((try f.self(ex.lhs(e), depth + 1)) orelse return null).truth()), ty),
                .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => |op| blk: {
                    const r: Integer.Reduction = switch (op) {
                        .reduce_and => .and_bits,
                        .reduce_nand => .nand_bits,
                        .reduce_or => .or_bits,
                        .reduce_nor => .nor_bits,
                        .reduce_xor => .xor_bits,
                        .reduce_xnor => .xnor_bits,
                        else => unreachable, // else: the arm admits only the six reductions
                    };
                    break :blk try bitAt(a, ((try f.self(ex.lhs(e), depth + 1)) orelse return null).reduce(r), ty);
                },
            },
            .binary => (try f.binary(e, ty, depth)) orelse return null,
            .ternary => blk: {
                const c = (try f.self(ex.lhs(e), depth + 1)) orelse return null;
                const yes = (try f.eval(ex.rhs(e), ty, depth + 1)) orelse return null;
                const no = (try f.eval(ex.ternaryElse(e), ty, depth + 1)) orelse return null;
                break :blk try c.conditional(a, yes, no);
            },
            .concat => blk: {
                const parts = try a.alloc(Literal, ex.args(e).len);
                for (ex.args(e), parts) |x, *p| p.* = (try f.self(x, depth + 1)) orelse return null;
                break :blk try convert(a, Literal.concatenate(a, parts) catch |err| return sized(err), ty);
            },
            .multi_concat => blk: {
                const n = (try f.count(ex.lhs(e), depth + 1)) orelse return null;
                const inner = (try f.self(ex.rhs(e), depth + 1)) orelse return null;
                break :blk try convert(a, inner.replicate(a, n) catch |err| return sized(err), ty);
            },
            .sys_call => blk: {
                const name = f.file.str(ex.strOf(e));
                var arg = (try f.self(ex.args(e)[0], depth + 1)) orelse return null;
                if (std.mem.eql(u8, name, "$clog2")) {
                    if (arg.hasUnknown()) break :blk try filledX(a, ty);
                    break :blk try fromInt(a, clog2(arg), ty);
                }
                arg.signed = std.mem.eql(u8, name, "$signed");
                break :blk try convert(a, arg, ty);
            },
            else => return null, // else: `typeAt` declined every other tag first
        };
        assert(v.width == ty.width);
        return v;
    }

    fn binary(f: Folder, e: ExprId, ty: Type, depth: u32) Error!?Literal {
        assert(ty.width != 0);
        const ex = &f.file.exprs;
        const a = f.arena;
        const op = ex.binOp(e);
        switch (op) {
            .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => {
                const l = (try f.eval(ex.lhs(e), ty, depth + 1)) orelse return null;
                const r = (try f.eval(ex.rhs(e), ty, depth + 1)) orelse return null;
                return switch (op) {
                    .add => try l.arithmetic(a, .add, r),
                    .sub => try l.arithmetic(a, .subtract, r),
                    .mul => try l.arithmetic(a, .multiply, r),
                    .div => try l.arithmetic(a, .divide, r),
                    .mod => try l.arithmetic(a, .remainder, r),
                    .bit_and => try l.bitwise(a, .and_bits, r),
                    .bit_or => try l.bitwise(a, .or_bits, r),
                    .bit_xor => try l.bitwise(a, .xor_bits, r),
                    .bit_xnor => try l.bitwise(a, .xnor_bits, r),
                    else => unreachable, // else: the arm admits only these nine
                };
            },
            .pow, .shl, .shr, .ashl, .ashr => {
                const l = (try f.eval(ex.lhs(e), ty, depth + 1)) orelse return null;
                // The right operand is self-determined (Table 5-22).
                const r = (try f.self(ex.rhs(e), depth + 1)) orelse return null;
                return switch (op) {
                    .pow => try l.power(a, r),
                    .shl => try l.shift(a, .left, r),
                    .shr => try l.shift(a, .right, r),
                    .ashl => try l.shift(a, .arithmetic_left, r),
                    .ashr => try l.shift(a, .arithmetic_right, r),
                    else => unreachable, // else: the arm admits only these five
                };
            },
            .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge => {
                // §5.4.1: the operands take each other's width and, §5.5.1,
                // compare signed only when both are.
                const lt = (try f.typeAt(ex.lhs(e), depth + 1)) orelse return null;
                const rt = (try f.typeAt(ex.rhs(e), depth + 1)) orelse return null;
                const both = common(lt, rt);
                const l = (try f.eval(ex.lhs(e), both, depth + 1)) orelse return null;
                const r = (try f.eval(ex.rhs(e), both, depth + 1)) orelse return null;
                const b: Integer.Bit = switch (op) {
                    .eq => l.equality(.equal, r),
                    .neq => l.equality(.not_equal, r),
                    .case_eq => l.equality(.case_equal, r),
                    .case_neq => l.equality(.case_not_equal, r),
                    .lt => l.relational(.less, r),
                    .le => l.relational(.less_equal, r),
                    .gt => l.relational(.greater, r),
                    .ge => l.relational(.greater_equal, r),
                    else => unreachable, // else: the arm admits only the eight comparisons
                };
                return try bitAt(a, b, ty);
            },
            .logical_and, .logical_or => {
                const l = (try f.self(ex.lhs(e), depth + 1)) orelse return null;
                const r = (try f.self(ex.rhs(e), depth + 1)) orelse return null;
                return try bitAt(a, l.logical(if (op == .logical_and) .and_bits else .or_bits, r), ty);
            },
        }
    }

    /// `e` self-determined.
    fn self(f: Folder, e: ExprId, depth: u32) Error!?Literal {
        const t = (try f.typeAt(e, depth)) orelse return null;
        return f.eval(e, t, depth);
    }

    /// A replication count (§5.1.14): a positive constant without x or z.
    fn count(f: Folder, e: ExprId, depth: u32) Error!?u32 {
        const v = (try f.self(e, depth)) orelse return null;
        const n = v.asExactInt() orelse return null;
        if (n <= 0) return null;
        return std.math.cast(u32, n) orelse error.TooWide;
    }
};

/// `e` evaluated in a context `ctx` bits wide (0: self-determined), as an
/// assignment's right side is (§5.4.1): the result is `max(own, ctx)` bits
/// at `e`'s own signedness. Null when `e` is not constant: a name that is not
/// a parameter, a real, an unsized constant in a concatenation (§5.1.14) or
/// a construct this fold does not cover.
pub fn fold(arena: Allocator, file: *const Ast.SourceFile, params: *const Params, e: ExprId, ctx: u32) Error!?Literal {
    assert(e != .none);
    const f: Folder = .{ .arena = arena, .file = file, .params = params };
    const own = (try f.typeAt(e, 0)) orelse return null;
    const ty: Type = .{ .width = @max(own.width, ctx), .signed = own.signed };
    const v = (try f.eval(e, ty, 0)) orelse return null;
    assert(v.width == ty.width);
    return v;
}

/// `fold` for an assignment's right side, which may also be a real literal
/// (or a negated one): §4.8.2 converts it to the nearest integer, ties away
/// from zero, as a signed value at least 64 bits wide. Null for any other
/// real, and for one outside 64 bits signed.
pub fn assigned(arena: Allocator, file: *const Ast.SourceFile, params: *const Params, e: ExprId, ctx: u32) Error!?Literal {
    assert(e != .none);
    const r = realOf(file, e) orelse return fold(arena, file, params, e, ctx);
    const n = @round(r);
    // -2^63 is an i64 and 2^63 is not; NaN and the infinities are neither.
    if (!(n >= -0x1p63 and n < 0x1p63)) return null;
    const out = try fromInt(arena, @intFromFloat(n), .{ .width = @max(64, ctx), .signed = true });
    assert(out.width >= ctx);
    return out;
}

// ---- private ----

/// `v` as type `ty` (§5.5.4: an operand is converted to the propagated type;
/// it is sign-extended only when that type is signed), or truncated to it.
fn convert(arena: Allocator, v: Literal, ty: Type) Error!Literal {
    assert(v.width != 0);
    assert(ty.width != 0 and ty.width <= max_width);
    var out = v.resize(arena, ty.width, if (ty.signed and v.signed) .sign else .zero) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ZeroSize => unreachable, // `ty.width` is asserted nonzero
    };
    out.signed = ty.signed;
    return out;
}

/// The two's complement of `v` at type `ty`.
fn fromInt(arena: Allocator, v: i64, ty: Type) Error!Literal {
    assert(ty.width != 0 and ty.width <= max_width);
    const planes = try arena.alloc(u64, 2);
    planes[0] = @bitCast(v);
    planes[1] = 0;
    const word: Literal = .{ .width = 64, .sized = true, .signed = true, .planes = planes };
    const out = try convert(arena, word, ty);
    assert(out.width == ty.width);
    return out;
}

/// Table 5-22's `max(L(i), L(j))`, signed only when both are (§5.5.1).
fn common(a: Type, b: Type) Type {
    return .{ .width = @max(a.width, b.width), .signed = a.signed and b.signed };
}

fn narrow(w: u64) Error!u32 {
    if (w > max_width) return error.TooWide;
    return @intCast(w);
}

fn sized(err: error{ OutOfMemory, ZeroSize, Overflow }) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Overflow => error.TooWide,
        error.ZeroSize => unreachable, // `typeAt` admitted no empty part and no zero count
    };
}

/// §3.5.1 and VD-131, as the interpreter sizes a literal
/// (`sim.digital` `compile.literalWidth`).
fn literalWidth(n: anytype) u32 {
    if (n.width != 0) return n.width;
    if (n.digit_bits != 0) return @max(32, n.digit_bits);
    const fits = if (n.signed) std.math.cast(i32, n.value) != null else n.value >= 0 and n.value <= std.math.maxInt(u32);
    return if (fits) 32 else 64;
}

/// §5.1.14: "Unsized constant numbers shall not be allowed in
/// concatenations", as a direct operand.
fn unsizedLiteral(file: *const Ast.SourceFile, e: ExprId) bool {
    const ex = &file.exprs;
    return switch (ex.tag(e)) {
        .int_literal => ex.intLiteral(e).width == 0,
        .logic_literal => !ex.logicValue(e).sized,
        else => false, // else: only a literal can be unsized
    };
}

/// A real literal or a negated one, the one real `fold` converts.
fn realOf(file: *const Ast.SourceFile, e: ExprId) ?f64 {
    const ex = &file.exprs;
    return switch (ex.tag(e)) {
        .real_literal => ex.realValue(e),
        .unary => if (ex.unOp(e) == .minus and ex.tag(ex.lhs(e)) == .real_literal) -ex.realValue(ex.lhs(e)) else null,
        else => null, // else: an integral expression, or a real one not folded
    };
}

/// §3.6: packed ASCII, the first character most significant.
fn stringLiteral(a: Allocator, text: []const u8) Error!Literal {
    const w: u32 = @intCast(8 * @max(1, text.len));
    const words = (w - 1) / 64 + 1;
    const planes = try a.alloc(u64, 2 * words);
    @memset(planes, 0);
    for (text, 0..) |c, i| {
        const shift = (text.len - 1 - i) * 8;
        planes[shift / 64] |= @as(u64, c) << @intCast(shift % 64);
    }
    const out: Literal = .{ .width = w, .sized = true, .signed = false, .planes = planes };
    assert(!out.hasUnknown());
    return out;
}

fn intLiteral(a: Allocator, n: anytype) Error!Literal {
    const w = literalWidth(n);
    // The lexer's value is the literal's low 64 bits.
    const planes = try a.alloc(u64, 2);
    planes[0] = @bitCast(n.value);
    planes[1] = 0;
    const word: Literal = .{ .width = 64, .sized = true, .signed = n.signed, .planes = planes };
    var out = try convert(a, word, .{ .width = w, .signed = false });
    out.signed = n.signed;
    return out;
}

/// §3.5.1: an unsized x or z constant fills its context with its top bit;
/// any other literal converts as an operand.
fn unsized(a: Allocator, v: Literal, ty: Type) Error!Literal {
    if (v.sized) return convert(a, v, ty);
    const top = v.bit(v.width - 1);
    var out = v.resize(a, ty.width, if (top == .x or top == .z or ty.signed) .sign else .zero) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ZeroSize => unreachable, // `ty.width` is nonzero
    };
    out.signed = ty.signed;
    return out;
}

/// A one-bit unsigned result (a comparison, a reduction) in context `ty`:
/// zero-extended, the result being unsigned (§5.5.1).
fn bitAt(a: Allocator, b: Integer.Bit, ty: Type) Error!Literal {
    const planes = try a.alloc(u64, 2);
    const k = @backingInt(b);
    planes[0] = k & 1;
    planes[1] = k >> 1;
    const one: Literal = .{ .width = 1, .sized = true, .signed = false, .planes = planes };
    assert(one.bit(0) == b);
    return convert(a, one, ty);
}

fn filledX(a: Allocator, ty: Type) Error!Literal {
    const out = try fromInt(a, -1, ty);
    @memcpy(out.unknowns(), out.values());
    return out;
}

fn invert(b: Integer.Bit) Integer.Bit {
    return switch (b) {
        .zero => .one,
        .one => .zero,
        .x, .z => .x,
    };
}

/// §17.11.1: the ceiling of the log base 2 of `v` read unsigned; 0 for 0 and 1.
fn clog2(v: Literal) i64 {
    assert(!v.hasUnknown());
    const words = v.values();
    var top: ?u64 = null;
    var ones: u64 = 0;
    for (words, 0..) |w, i| {
        ones += @popCount(w);
        if (w != 0) top = i * 64 + 63 - @clz(w);
    }
    const t = top orelse return 0;
    return @intCast(if (ones == 1) t else t + 1);
}

test "fold: §12.2-typed 64-bit parameters keep their top half, where a 32-bit fold wraps" {
    // Oracle: IEEE 1364-2005 §5.4.1 by hand. `HI - 7` is 64 bits signed
    // (Table 5-22's max(64, 32)), 2^63 - 1 - 7 = 9223372036854775800; and
    // `NIB - 4'd4` is 4 bits unsigned, 3 - 4 wrapping to 15.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var bag: @import("diag").Bag = .init(a);
    const src = "module m; localparam x = HI - 7; localparam y = NIB - 4'd4; localparam z = $clog2(65); endmodule";
    var tokens = try @import("frontend").lexer.tokenize(a, src, null);
    var parser = @import("frontend").Parser.Parser.init(a, src, tokens.items(.tag), tokens.items(.start), &bag);
    parser.digital = true;
    const file = &(try parser.parseSourceFile());
    const ps = file.modules[0].params;
    // `HI` and `NIB` are not declared in the source: the table gives them.
    var params: Params = .empty;
    try params.put(a, file.exprs.strOf(file.exprs.lhs(ps[0].default)), try fromInt(a, std.math.maxInt(i64), .{ .width = 64, .signed = true }));
    try params.put(a, file.exprs.strOf(file.exprs.lhs(ps[1].default)), try fromInt(a, 3, .{ .width = 4, .signed = false }));
    const x = (try fold(a, file, &params, ps[0].default, 0)).?;
    try std.testing.expectEqual(@as(u32, 64), x.width);
    try std.testing.expectEqual(@as(?i64, 9223372036854775800), x.asInt());
    const y = (try fold(a, file, &params, ps[1].default, 0)).?;
    try std.testing.expectEqual(@as(u32, 4), y.width);
    try std.testing.expectEqual(@as(?i64, 15), y.asInt());
    // §17.11.1: ceil(log2(65)) = 7, an integer.
    const z = (try fold(a, file, &params, ps[2].default, 0)).?;
    try std.testing.expectEqual(@as(u32, 32), z.width);
    try std.testing.expectEqual(@as(?i64, 7), z.asInt());
}
