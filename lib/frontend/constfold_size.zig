//! The constant folder's sizing (VAMS §4.2.9; IEEE 1364-2005 §§5.4–5.5): an
//! expression's width and signedness in, how `constfold` sizes its operands
//! out. Each walk keeps its pending rows on a heap stack (`Pending`), so an
//! expression nests as deep as memory allows on any thread; out of memory is
//! `Error`, never null. Names come from
//! the caller's `env` (`width`, `signed`), as for `constfold.fold`.
//!
//! Contents:
//! - `pub const UnsignedCompare = struct`: `Side`, `extend`
//! - `pub const IntContext = struct`: `normalize`
//! - `pub const IntPlan = struct`: `resize`
//! - `pub const Size = struct`
//! - `pub const Sizes = std.AutoHashMapUnmanaged(Ast.ExprId, Size)`
//! - `pub const Error = std.mem.Allocator.Error`
//! - `pub fn unsignedCompare(gpa: std.mem.Allocator, file: *const Ast.SourceFile, l: Ast.ExprId, r: Ast.ExprId, env: anytype) Error!?UnsignedCompare`
//! - `pub fn operandWidth(gpa: std.mem.Allocator, file: *const Ast.SourceFile, e: Ast.ExprId, env: anytype) Error!?u32`
//! - `pub fn clog2Width(gpa: std.mem.Allocator, file: *const Ast.SourceFile, e: Ast.ExprId, env: anytype) Error!?u32`
//! - `pub fn clog2Signed(gpa: std.mem.Allocator, file: *const Ast.SourceFile, e: Ast.ExprId, env: anytype) Error!?bool`
//! - `pub fn measure(gpa: std.mem.Allocator, file: *const Ast.SourceFile, e: Ast.ExprId, env: anytype, sizes: *Sizes) Error!void`
//! - `pub fn measuredPlan(file: *const Ast.SourceFile, e: Ast.ExprId, sizes: *const Sizes, parent: ?IntContext) ?IntPlan`
//! - `pub fn literalWidth(ex: *const Ast.ExprStore, e: Ast.ExprId) u32`
//! - `pub fn Pending(comptime T: type) type`: `init`, `deinit`, `push`, `pushBoth`, `pop`, `items`
//! - `pub fn envSigned(env: anytype, e: Ast.ExprId) Error!?bool`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("ast.zig");

/// The one failure a walk adds to the caller's: no memory for its pending
/// rows. Never answered as null: that would change the fold's verdict.
pub const Error = std.mem.Allocator.Error;

/// §4.2.9 on the i64 carrier: "When one or both operands are unsigned, the
/// expression shall be interpreted as a comparison between unsigned values. If
/// the operands are of unequal bit lengths, the smaller operand shall be
/// zero-extended to the size of the larger operand." Each operand is extended
/// from its OWN width: `a` at -1 against `40'hFF_FFFF_FFFF` is
/// 40'h00_FFFF_FFFF. Both signed, the carrier already holds the sign-extended
/// values and the signed compare stands.
pub const UnsignedCompare = struct {
    /// Each operand's own-width mask; null at 64 bits or wider, or an unknown
    /// width, where the carrier's value is taken as it stands.
    mask: [2]?i64,
    /// An operand is 64 bits or wider: order the pair as u64 by flipping bit 63
    /// of both before the signed compare.
    flip: bool,

    /// The comparison's operand; its backing integer indexes `mask`.
    pub const Side = enum { lhs, rhs };

    /// Returns operand `side`'s value as the i64 the signed compare orders as
    /// §4.2.9's unsigned comparison.
    pub fn extend(u: UnsignedCompare, side: Side, v: i64) i64 {
        // A mask is an own-width mask below 64 bits: positive, low bits set.
        if (u.mask[@backingInt(side)]) |m| assert(m > 0);
        const z = if (u.mask[@backingInt(side)]) |m| v & m else v;
        return if (u.flip) z ^ std.math.minInt(i64) else z;
    }
};

/// One IEEE §5.5.2 type/size context, over the existing i64 carrier.
pub const IntContext = struct {
    /// Bits; 64 or more leaves the carrier as it is.
    width: u32,
    signed: bool,

    /// Returns `value` cut to `width` bits and re-extended by `signed`.
    /// `width` is at least 1: every context comes from an operand width.
    pub fn normalize(c: IntContext, value: i64) i64 {
        assert(c.width >= 1);
        if (c.width >= 64) return value;
        const mask = (@as(u64, 1) << @intCast(c.width)) - 1;
        var bits = @as(u64, @bitCast(value)) & mask;
        if (c.signed and bits & (@as(u64, 1) << @intCast(c.width - 1)) != 0) bits |= ~mask;
        // Unsigned below 64 bits is never negative on the carrier.
        if (!c.signed) assert(@as(i64, @bitCast(bits)) >= 0);
        return @bitCast(bits);
    }
};

/// Shared by folding and lowering: where context propagates, where it stops,
/// and how the result enters its parent. No changes to ordinary analog ops.
pub const IntPlan = struct {
    /// The context the node's value enters its parent in.
    result: IntContext,
    /// The width the node computes at, before `resize` converts it.
    from_width: u32,
    /// The context each operand is folded in (`lhs`, `rhs`, the `?:` else
    /// arm); null where the operand is self-determined.
    operands: [3]?IntContext = .{ null, null, null },
    /// False when the result is wider than the i64 carrier can compute.
    supported: bool = true,

    /// Returns `value`, computed at `from_width`, converted to `result`.
    pub fn resize(p: IntPlan, value: i64) i64 {
        assert(p.from_width >= 1);
        assert(p.result.width >= 1);
        const source: IntContext = .{ .width = p.from_width, .signed = p.result.signed };
        return p.result.normalize(source.normalize(value));
    }
};

/// One row's self-determined size, as `measuredPlan` reads it: `clog2Width`'s
/// width and `clog2Signed`'s signedness, each null where that walk's is.
pub const Size = struct { width: ?u32, signed: ?bool };

/// The `Size` of every row `measure` reached, keyed by row.
pub const Sizes = std.AutoHashMapUnmanaged(Ast.ExprId, Size);

// One hash-map value per row: a width and a signedness, both optional.
comptime {
    assert(@sizeOf(Size) <= 12);
}

/// Rows a width or signedness walk keeps on the native stack.
const rows_in_place = 64;

/// One row of `measure`'s post-order: `open` once its operands are pushed.
const Visit = struct { e: Ast.ExprId, open: bool };

/// The §4.2.9 extension of comparison `l` vs `r` under `env` (`fold`'s), or
/// null when neither operand is known unsigned.
pub fn unsignedCompare(gpa: std.mem.Allocator, file: *const Ast.SourceFile, l: Ast.ExprId, r: Ast.ExprId, env: anytype) Error!?UnsignedCompare {
    assert(l != .none);
    assert(r != .none);
    if (((try envSigned(env, l)) orelse true) and ((try envSigned(env, r)) orelse true)) return null;
    const w = [2]?u32{ try operandWidth(gpa, file, l, env), try operandWidth(gpa, file, r, env) };
    var u: UnsignedCompare = .{ .mask = undefined, .flip = false };
    for (w, &u.mask) |wi, *m| {
        const n = wi orelse {
            m.* = null;
            continue;
        };
        u.flip = u.flip or n >= 64;
        m.* = if (n >= 64) null else (@as(i64, 1) << @intCast(n)) - 1;
    }
    // A flip comes from a 64-bit operand, whose mask is the carrier's own.
    if (u.flip) assert(u.mask[0] == null or u.mask[1] == null);
    return u;
}

/// The bit length §4.2.9 extends an operand from: a §2.6.1 literal's size and
/// a name's (`env.width`) as written; any other integer expression is §3.2's
/// 32 bits, since the analog operators compute at that width, or the carrier's
/// wider value where a sign, a complement, a bitwise operator or `?:` passes a
/// wide operand through. Null when unknown.
pub fn operandWidth(gpa: std.mem.Allocator, file: *const Ast.SourceFile, e: Ast.ExprId, env: anytype) Error!?u32 {
    assert(e != .none);
    const w = try expressionWidth(gpa, file, e, env, false);
    // Not self-determined: an operator result is at least §3.2's 32 bits.
    if (w) |x| if (file.exprs.tag(e) == .binary) assert(x >= 32);
    return w;
}

/// IEEE 1364-2005 §5.4.1 / §17.11.1: `$clog2`'s self-determined operand
/// keeps the size of a sized unary or arithmetic expression; no assignment
/// context widens it to the analog integer carrier's 32 bits.
pub fn clog2Width(gpa: std.mem.Allocator, file: *const Ast.SourceFile, e: Ast.ExprId, env: anytype) Error!?u32 {
    assert(e != .none);
    assert(@backingInt(e) < file.exprs.len());
    return expressionWidth(gpa, file, e, env, true);
}

/// IEEE §5.5.1 signedness before the unsigned `$clog2` boundary. Names are
/// the environment's; a function call keeps its own argument contexts.
pub fn clog2Signed(gpa: std.mem.Allocator, file: *const Ast.SourceFile, e: Ast.ExprId, env: anytype) Error!?bool {
    assert(e != .none);
    const ex = &file.exprs;
    assert(@backingInt(e) < ex.len());
    // §5.5.1: unsigned when any operand the sign passes through is, and
    // unknown when any of them is.
    var in_place: [rows_in_place]Ast.ExprId = undefined;
    var pending: Pending(Ast.ExprId) = .init(&in_place, gpa);
    defer pending.deinit();
    try pending.push(e);
    var signed = true;
    while (pending.pop()) |n| {
        const leaf: bool = switch (ex.tag(n)) {
            .int_literal => ex.intLiteral(n).signed,
            .logic_literal => ex.logicValue(n).signed,
            .ident => (try envSigned(env, n)) orelse return null,
            .unary => switch (ex.unOp(n)) {
                .plus, .minus, .bit_not => {
                    try pending.push(ex.lhs(n));
                    continue;
                },
                .logical_not, .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => false,
            },
            .binary => switch (ex.binOp(n)) {
                .shl, .shr, .ashl, .ashr, .pow => {
                    try pending.push(ex.lhs(n));
                    continue;
                },
                .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => {
                    try pending.pushBoth(ex.lhs(n), ex.rhs(n));
                    continue;
                },
                .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge, .logical_and, .logical_or => false,
            },
            .ternary => {
                try pending.pushBoth(ex.rhs(n), ex.ternaryElse(n));
                continue;
            },
            .sys_call => !std.mem.eql(u8, file.str(ex.strOf(n)), "$realtobits"),
            .call, .index => true, // analog function/array integral results are §3.2 integers
            else => return null, // else: not an integral expression in the analog context
        };
        signed = signed and leaf;
    }
    return signed;
}

/// Records in `sizes` the `Size` of `e` and of every row its operators
/// reach (each operand of a `.unary`, `.binary` or `.ternary`), each from
/// its operands' once they are in. Sizing a whole tree is so one pass over
/// its rows, where `clog2Width` and `clog2Signed` per row re-walk every
/// operand below it, quadratic in the depth. Agrees with those two walks
/// on every row; a row already in `sizes` is kept.
pub fn measure(gpa: std.mem.Allocator, file: *const Ast.SourceFile, e: Ast.ExprId, env: anytype, sizes: *Sizes) Error!void {
    assert(e != .none);
    const ex = &file.exprs;
    assert(@backingInt(e) < ex.len());
    var in_place: [rows_in_place]Visit = undefined;
    var pending: Pending(Visit) = .init(&in_place, gpa);
    defer pending.deinit();
    try pending.push(.{ .e = e, .open = false });
    while (pending.pop()) |v| {
        // A row shared by two parents is pushed twice and sized once.
        if (sizes.contains(v.e)) continue;
        var buf: [3]Ast.ExprId = undefined;
        const ops = operands(ex, v.e, &buf);
        if (!v.open and ops.len != 0) {
            try pending.push(.{ .e = v.e, .open = true });
            for (ops) |o| if (o != .none) try pending.push(.{ .e = o, .open = false });
            continue;
        }
        try sizes.putNoClobber(gpa, v.e, try sizeOf(file, v.e, env, sizes));
        assert(sizes.count() <= ex.len());
    }
    assert(sizes.contains(e));
}

/// Returns how `e` is sized inside `parent` (null: `e` is self-determined).
/// IEEE Table 5-22 and §5.5.2: logical operands, a shift/power's RHS, and a
/// conditional's condition are self-determined. Comparisons share a context
/// between their operands, independent of their one-bit result. Read from
/// the sizes `measure` recorded, which reached `e`; null when they lack a
/// width or signedness the plan needs.
pub fn measuredPlan(file: *const Ast.SourceFile, e: Ast.ExprId, sizes: *const Sizes, parent: ?IntContext) ?IntPlan {
    const ex = &file.exprs;
    assert(@backingInt(e) < ex.len());
    const s = sizes.get(e).?;
    const own: IntContext = .{ .width = s.width orelse return null, .signed = s.signed orelse return null };
    const result: IntContext = if (parent) |p| .{ .width = @max(p.width, own.width), .signed = p.signed } else own;
    var plan: IntPlan = .{ .result = result, .from_width = own.width };
    assert(plan.result.width >= own.width);
    switch (ex.tag(e)) {
        .unary => switch (ex.unOp(e)) {
            .plus, .minus, .bit_not => {
                plan.from_width = result.width;
                plan.operands[0] = result;
                plan.supported = result.width <= (if (ex.unOp(e) == .minus) @as(u32, 32) else 64);
            },
            .logical_not, .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => {},
        },
        .binary => switch (ex.binOp(e)) {
            .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => {
                plan.from_width = result.width;
                plan.operands[0] = result;
                plan.operands[1] = result;
                const bitwise = switch (ex.binOp(e)) {
                    .bit_and, .bit_or, .bit_xor, .bit_xnor => true,
                    else => false, // else: the enclosing prong's five arithmetic operations wrap at 32
                };
                plan.supported = result.width <= (if (bitwise) @as(u32, 64) else 32);
            },
            .pow, .shl, .shr, .ashl, .ashr => {
                plan.from_width = result.width;
                plan.operands[0] = result;
                plan.supported = result.width <= 32;
            },
            .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge => {
                const l = sizeAt(sizes, ex.lhs(e));
                const r = sizeAt(sizes, ex.rhs(e));
                const c: IntContext = .{
                    .width = @max(l.width orelse return null, r.width orelse return null),
                    .signed = (l.signed orelse return null) and (r.signed orelse return null),
                };
                plan.operands[0] = c;
                plan.operands[1] = c;
                plan.supported = c.width <= 64;
            },
            .logical_and, .logical_or => {},
        },
        .ternary => {
            plan.from_width = result.width;
            plan.operands[1] = result;
            plan.operands[2] = result;
            plan.supported = result.width <= 64;
        },
        else => {}, // else: a primary keeps its own width until converted to its parent
    }
    // A self-determined result carries no context of its own into operands.
    if (plan.operands[0]) |c| assert(c.width >= 1);
    return plan;
}

/// A §2.6.1 integer literal's width: its size, or, unsized, "at least 32"
/// bits: §3.2's 32 when they hold the value, the carrier's 64 when they do
/// not. `expressionWidth` and `reduction` must agree on it.
pub fn literalWidth(ex: *const Ast.ExprStore, e: Ast.ExprId) u32 {
    assert(ex.tag(e) == .int_literal);
    const w = ex.intLiteral(e).width;
    if (w != 0) return w;
    const v = ex.intValue(e);
    return if (std.math.cast(u32, v) != null or std.math.cast(i32, v) != null) 32 else 64;
}

/// A walk's pending entries: `in_place` on the caller's stack, then
/// `gpa`, so the walk's depth costs heap and never native stack.
pub fn Pending(comptime T: type) type {
    return struct {
        bfa: std.heap.BufferFirstAllocator,
        list: std.ArrayList(T) = .empty,

        const Self = @This();

        /// Starts empty on `in_place`, which must outlive the walk, then
        /// takes `gpa`'s memory.
        pub fn init(in_place: []T, gpa: std.mem.Allocator) Self {
            return .{ .bfa = .init(std.mem.sliceAsBytes(in_place), gpa) };
        }
        /// Frees what the walk took from `gpa`, if anything.
        pub fn deinit(p: *Self) void {
            p.list.deinit(p.bfa.allocator());
        }
        /// Pushes `x`, to pop before everything pushed earlier.
        pub fn push(p: *Self, x: T) Error!void {
            try p.list.append(p.bfa.allocator(), x);
        }
        /// Pushes `first` last, so it pops first: source order.
        pub fn pushBoth(p: *Self, first: T, second: T) Error!void {
            try p.list.appendSlice(p.bfa.allocator(), &.{ second, first });
        }
        /// Pops the entry pushed last, or null when none is left.
        pub fn pop(p: *Self) ?T {
            return p.list.pop();
        }
        /// The entries, pushed first to last; valid until the next push.
        pub fn items(p: *Self) []T {
            return p.list.items;
        }
    };
}

/// `env.signed(e)`, from an `env` whose methods may or may not fail.
pub fn envSigned(env: anytype, e: Ast.ExprId) Error!?bool {
    return env.signed(e);
}

// ---- private ----

/// `operandWidth` and `clog2Width`: §3.2's 32 bits as the floor for an
/// operand an operator sizes, or exactly as written when `self_determined`.
fn expressionWidth(gpa: std.mem.Allocator, file: *const Ast.SourceFile, e: Ast.ExprId, env: anytype, comptime self_determined: bool) Error!?u32 {
    assert(e != .none);
    const ex = &file.exprs;
    // The width is the widest operand the size passes through, raised to
    // §3.2's 32 bits (`widthFloor`) once any operator passed it on.
    var in_place: [rows_in_place]Ast.ExprId = undefined;
    var pending: Pending(Ast.ExprId) = .init(&in_place, gpa);
    defer pending.deinit();
    try pending.push(e);
    var widest: u32 = 0;
    while (pending.pop()) |n| {
        const w: u32 = switch (ex.tag(n)) {
            .int_literal => literalWidth(ex, n),
            .logic_literal => ex.logicValue(n).width,
            .ident => (try envWidth(env, n)) orelse return null,
            // `unary`'s `wrapFrom`: a sign or complement keeps a wide literal's width.
            .unary => switch (ex.unOp(n)) {
                .plus, .minus, .bit_not => {
                    try pending.push(ex.lhs(n));
                    continue;
                },
                .logical_not, .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => if (self_determined) 1 else 32,
            },
            .binary => switch (ex.binOp(n)) {
                .bit_and, .bit_or, .bit_xor, .bit_xnor => {
                    try pending.pushBoth(ex.lhs(n), ex.rhs(n));
                    continue;
                },
                .add, .sub, .mul, .div, .mod => if (self_determined) {
                    try pending.pushBoth(ex.lhs(n), ex.rhs(n));
                    continue;
                } else 32,
                .pow, .shl, .shr, .ashl, .ashr => if (self_determined) {
                    try pending.push(ex.lhs(n));
                    continue;
                } else 32,
                .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge, .logical_and, .logical_or => if (self_determined) 1 else 32,
            },
            .ternary => {
                try pending.pushBoth(ex.rhs(n), ex.ternaryElse(n));
                continue;
            },
            // §9.11 `$realtobits` returns the double's 64-bit pattern.
            .sys_call => if (std.mem.eql(u8, file.str(ex.strOf(n)), "$realtobits")) 64 else 32,
            else => 32, // else: every other integer-valued form is §3.2's 32-bit integer
        };
        widest = @max(widest, if (n == e) w else widthFloor(w, self_determined));
    }
    return widest;
}

/// The operands `measure` sizes before `e`: a `.unary`'s, `.binary`'s or
/// `.ternary`'s, the condition included; none for any other row.
fn operands(ex: *const Ast.ExprStore, e: Ast.ExprId, buf: *[3]Ast.ExprId) []const Ast.ExprId {
    const n: usize = switch (ex.tag(e)) {
        .unary => 1,
        .binary => 2,
        .ternary => 3,
        else => 0, // else: a primary or a call, sized whole by `sizeOf`
    };
    buf.* = .{ ex.lhs(e), ex.rhs(e), if (n == 3) ex.ternaryElse(e) else .none };
    return buf[0..n];
}

/// Row `n`'s `Size` from its operands' in `sizes`: the rules of
/// `expressionWidth` (self-determined) and `clog2Signed`, one row at a time.
fn sizeOf(file: *const Ast.SourceFile, n: Ast.ExprId, env: anytype, sizes: *const Sizes) Error!Size {
    const ex = &file.exprs;
    assert(!sizes.contains(n)); // each row is sized once
    return switch (ex.tag(n)) {
        .int_literal => .{ .width = literalWidth(ex, n), .signed = ex.intLiteral(n).signed },
        .logic_literal => .{ .width = ex.logicValue(n).width, .signed = ex.logicValue(n).signed },
        .ident => .{ .width = try envWidth(env, n), .signed = try envSigned(env, n) },
        .unary => switch (ex.unOp(n)) {
            .plus, .minus, .bit_not => sizeAt(sizes, ex.lhs(n)),
            .logical_not, .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => .{ .width = 1, .signed = false },
        },
        .binary => switch (ex.binOp(n)) {
            .shl, .shr, .ashl, .ashr, .pow => sizeAt(sizes, ex.lhs(n)),
            .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => wider(sizeAt(sizes, ex.lhs(n)), sizeAt(sizes, ex.rhs(n))),
            .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge, .logical_and, .logical_or => .{ .width = 1, .signed = false },
        },
        .ternary => wider(sizeAt(sizes, ex.rhs(n)), sizeAt(sizes, ex.ternaryElse(n))),
        // §9.11 `$realtobits` returns the double's 64-bit pattern, unsigned.
        .sys_call => if (std.mem.eql(u8, file.str(ex.strOf(n)), "$realtobits")) .{ .width = 64, .signed = false } else .{ .width = 32, .signed = true },
        .call, .index => .{ .width = 32, .signed = true }, // analog function/array integral results are §3.2 integers
        else => .{ .width = 32, .signed = null }, // else: §3.2's 32 bits, but no integral expression in the analog context
    };
}

/// The size `measure` recorded for operand `e`; a missing operand has none.
fn sizeAt(sizes: *const Sizes, e: Ast.ExprId) Size {
    if (e == .none) return .{ .width = null, .signed = null };
    return sizes.get(e).?;
}

/// Two operands that share a context: the wider width, signed only when
/// both are; either one unknown leaves that half unknown.
fn wider(a: Size, b: Size) Size {
    const out: Size = .{
        .width = if (a.width != null and b.width != null) @max(a.width.?, b.width.?) else null,
        .signed = if (a.signed != null and b.signed != null) a.signed.? and b.signed.? else null,
    };
    if (out.width) |w| assert(w >= a.width.?);
    return out;
}

fn widthFloor(w: u32, comptime self_determined: bool) u32 {
    const out = if (self_determined) w else @max(w, 32);
    assert(out >= w);
    return out;
}

/// `env.width(e)`, from an `env` whose methods may or may not fail.
fn envWidth(env: anytype, e: Ast.ExprId) Error!?u32 {
    return env.width(e);
}
