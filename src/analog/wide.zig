//! IEEE 1364-2005 §5.4/§5.5 in the analog context: a `reg` wider than §3.2's
//! 32 bits that the analog context assigns (`Ty.wide`) holds every bit its
//! declaration gives it, and the right-hand side of an assignment to it is
//! sized as IEEE 1364 sizes it.
//!
//! In: the right-hand side's AST, or a select of a wide `reg`. Out: a `$wide`
//! call (the `reg`'s new bits) or a `$wide$int` call (the §7.3.1 integer a
//! select reads), each over one `Lowered.wide_nodes` tree whose operands
//! (`leaf_*`) are the call's arguments. `codegen/wide.zig` renders the tree
//! over `kernels/wide_kernels.zig`.
//!
//! The rule (docs/specification/Vague_Decisions.md VD-116). IEEE 1364 §5.4.1 Table
//! 5-22 and §5.5.1 give every operand a self-determined width and sign; the
//! assignment's left-hand width joins the context of the right-hand side
//! (§5.4.1, "including the left-hand side of an assignment"), §5.5.2
//! propagates that context to each context-determined operand, which is
//! extended by the context's sign, and §5.5.3 cuts the result to the `reg`.
//! An operand outside this tree keeps its analog meaning: an `integer`
//! variable or a call returning one is a 32-bit signed operand, a real is a
//! real. So the analog block computes the bits the digital engine computes
//! for the same statement over the same operand values. Every other analog
//! integer stays §3.2's 32-bit integer: only an assignment to a wide `reg`,
//! and the bits of one read back, are sized here.
//!
//! x and z: the analog context has none (§7.3.2). A literal holding one is
//! E0130. A discrete input's value arrives as its value plane; an x or z bit
//! in it is the §7.3.2 run-time error the mixed runner reports before the
//! solve (`mixedInput`), so no x reaches this tree. The IEEE 1364 operations
//! that yield x for known operands (`/` or `%` by zero, zero to a negative
//! power) yield 0, as the analog integer `/` does (W0653).
//!
//! LRM clauses this file's code cites: §2.6.1, §3.2, §7.3.1, §7.3.2, §9.11.
//! IEEE 1364-2005 clauses cited: §3.5.1, §4.1, §4.2.1, §4.8.2, §5.1.5, §5.1.7-§5.1.14,
//! §5.4.1, §5.5.1-§5.5.3, Table 5-6 and Table 5-22.

const std = @import("std");
const Lower = @import("lower.zig");
const Lowered = @import("ir").Lowered;
const lower_expr = @import("expr.zig");
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Oom = Lower.Oom;
const VarSlot = Lower.VarSlot;
const TypedValue = Lower.TypedValue;
const WideNode = Lowered.WideNode;
const none_u32 = Lower.none_u32;

/// An operand's IEEE 1364 type: `w` bits, signed or not; `w == 0` a real.
const T = struct {
    w: u32,
    s: bool = false,

    const real: T = .{ .w = 0 };
    fn isReal(t: T) bool {
        return t.w == 0;
    }
};

/// §5.4.1 the bits of the 32-bit operands (§3.2 `integer`, an unsized
/// literal, an analog call returning an integer).
const int32: T = .{ .w = 32, .s = true };

/// One tree under construction: the nodes go straight into `Lowered`, the
/// operands into `args`, the call's arguments after the root.
const Build = struct {
    l: *Lower,
    args: std.ArrayList(Mir.Value) = .empty,
    /// Operands lowered while their type was asked (`opaque`), so each is
    /// lowered once and in source order.
    lowered: std.AutoHashMapUnmanaged(Ast.ExprId, TypedValue) = .empty,
    /// `selfType`'s answers, so an operand's diagnostic is reported once.
    types: std.AutoHashMapUnmanaged(Ast.ExprId, T) = .empty,
    /// The constant selects `selfType` resolved (`Sel`).
    sels: std.AutoHashMapUnmanaged(Ast.ExprId, Sel) = .empty,
    ok: bool = true,

    fn node(b: *Build, n: WideNode) Oom!u32 {
        // Operands are built first, so a node only reads rows below its own,
        // which keeps the tree `codegen/wide.zig` recurses over acyclic.
        const len = b.l.out.wide_nodes.items.len;
        for ([_]u32{ n.a, n.b, n.c }) |k| if (k != none_u32) std.debug.assert(k < len);
        try b.l.out.wide_nodes.append(b.l.arena, n);
        return @intCast(b.l.out.wide_nodes.items.len - 1);
    }

    fn arg(b: *Build, v: Mir.Value) Oom!u32 {
        try b.args.append(b.l.arena, v);
        return @intCast(b.args.items.len - 1);
    }

    fn fail(b: *Build, e: Ast.ExprId, comptime fmt: []const u8, args: anytype) Oom!void {
        b.ok = false;
        try b.l.err(b.l.file.exprs.mainTok(e), .E0329, fmt, args);
    }

    /// The call over the tree rooted at `root`.
    fn finish(b: *Build, callee: []const u8, root: u32) Oom!Mir.Value {
        std.debug.assert(root < b.l.out.wide_nodes.items.len);
        const all = try b.l.arena.alloc(Mir.Value, b.args.items.len + 1);
        all[0] = try b.l.mir.addIntConst(b.l.arena, root);
        @memcpy(all[1..], b.args.items);
        return b.l.call(callee, all);
    }
};

// ---- entry points -----------------------------------------------------------

/// §5.5.3 `r = value` for wide `reg` `r` of `width` bits: its new bits.
pub fn rhs(self: *Lower, width: u32, value: Ast.ExprId) Oom!Mir.Value {
    var b: Build = .{ .l = self };
    const st = try selfType(&b, value);
    if (!b.ok) return zero(self, width);
    // §5.4.1: the left-hand width joins the context; the sign is the
    // right-hand side's alone (§5.5.1).
    const root = if (st.isReal())
        try b.node(.{ .op = .from_real, .width = width, .a = try real(&b, value) })
    else
        try resizeTo(&b, try at(&b, value, .{ .w = @max(width, st.w), .s = st.s }), .{ .w = @max(width, st.w), .s = st.s }, .{ .w = width, .s = st.s });
    if (!b.ok) return zero(self, width);
    return b.finish("$wide", root);
}

/// The bits of a wide `reg` of `width` bits holding §3.2 integer `v`: an
/// output argument, a `$sscanf` target, any write of a 32-bit signed value
/// (§5.5.3: sign-extended, since the right-hand side is signed).
pub fn fromInt(self: *Lower, width: u32, v: Mir.Value) Oom!Mir.Value {
    var b: Build = .{ .l = self };
    const leaf = try b.node(.{ .op = .leaf_int, .width = 32, .signed = true, .arg = try b.arg(v) });
    return b.finish("$wide", try b.node(.{ .op = .resize, .width = width, .signed = true, .a = leaf }));
}

/// A wide `reg` of `width` bits with every bit zero (§3.2's start).
pub fn zero(self: *Lower, width: u32) Oom!Mir.Value {
    var b: Build = .{ .l = self };
    return b.finish("$wide", try lit(&b, &.{}, width));
}

/// §7.3.1 `name[hi:lo]` of a wide `reg` (`slot`) read where an analog integer
/// is wanted: the selected bits, zero-extended. `lo` is the select's offset
/// from the `reg`'s LSB and `width` its bits; Table 7-1's 31-bit limit was
/// checked by the caller.
pub fn select(self: *Lower, slot: VarSlot, lo: u32, width: u32) Oom!Mir.Value {
    var b: Build = .{ .l = self };
    const base = try b.node(.{ .op = .leaf_wide, .width = slot.reg_width.?, .signed = slot.reg_signed, .arg = try b.arg(try self.builder.readVariable(slot.place, self.cur)) });
    return b.finish("$wide$int", try selectNode(&b, base, slot.reg_width.?, lo, width));
}

// ---- §5.4.1/§5.5.1 self-determined types ------------------------------------

/// `e`'s self-determined IEEE 1364 type. Lowers an operand this file does
/// not size (`opaque`) to learn its analog type. A form with none is E0329.
fn selfType(b: *Build, e: Ast.ExprId) Oom!T {
    if (b.types.get(e)) |t| return t;
    const t = try selfTypeOnce(b, e);
    try b.types.put(b.l.arena, e, t);
    return t;
}

fn selfTypeOnce(b: *Build, e: Ast.ExprId) Oom!T {
    const l = b.l;
    const ex = &l.file.exprs;
    switch (ex.tag(e)) {
        .int_literal => {
            const n = ex.intLiteral(e);
            if (n.width != 0) return .{ .w = n.width, .s = n.signed };
            // §3.5.1 an unsized constant is an integer's 32 bits, as the
            // digital engine sizes it.
            const fits = if (n.signed) std.math.cast(i32, n.value) != null else std.math.cast(u32, n.value) != null;
            if (!fits) try b.fail(e, "an unsized constant past 32 bits has no IEEE 1364 width; give it a size", .{});
            return .{ .w = 32, .s = n.signed };
        },
        .logic_literal => {
            const n = ex.logicValue(e);
            if (n.hasUnknown()) {
                b.ok = false;
                try l.err(ex.mainTok(e), .E0130, "§7.3.2: the analog context has no x or z bit", .{});
            }
            return .{ .w = if (n.sized) n.width else 32, .s = n.signed };
        },
        .real_literal => return .real,
        .ident => return identType(b, e, l.file.str(ex.strOf(e))),
        .index => if (selectOf(l, e)) |name| return selectType(b, e, name) else return opaqueType(b, e),
        .unary => switch (ex.unOp(e)) {
            .plus, .minus => return selfType(b, ex.lhs(e)),
            .bit_not => return intType(b, e, ex.lhs(e)),
            .logical_not => {
                _ = try selfType(b, ex.lhs(e));
                return .{ .w = 1 };
            },
            .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => {
                _ = try intType(b, e, ex.lhs(e));
                return .{ .w = 1 };
            },
        },
        .binary => {
            const op = ex.binOp(e);
            switch (op) {
                .add, .sub, .mul, .div, .mod => return common(try selfType(b, ex.lhs(e)), try selfType(b, ex.rhs(e))),
                .pow => {
                    const a = try selfType(b, ex.lhs(e));
                    const c = try selfType(b, ex.rhs(e));
                    return if (a.isReal() or c.isReal()) .real else a;
                },
                .bit_and, .bit_or, .bit_xor, .bit_xnor => return common(try intType(b, e, ex.lhs(e)), try intType(b, e, ex.rhs(e))),
                .shl, .shr, .ashl, .ashr => {
                    const a = try intType(b, e, ex.lhs(e));
                    _ = try intType(b, e, ex.rhs(e));
                    return a;
                },
                .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge, .logical_and, .logical_or => {
                    _ = try selfType(b, ex.lhs(e));
                    _ = try selfType(b, ex.rhs(e));
                    return .{ .w = 1 };
                },
            }
        },
        .ternary => {
            _ = try selfType(b, ex.lhs(e));
            return common(try selfType(b, ex.rhs(e)), try selfType(b, ex.ternaryElse(e)));
        },
        // §5.1.14: a concatenation's operands are sized, but the analog
        // parser folds the integer form only from literals (E0216).
        .concat, .multi_concat => {
            try b.fail(e, "a concatenation in a wide `reg`'s right-hand side", .{});
            return .{ .w = 1 };
        },
        else => return opaqueType(b, e), // else: every other form keeps its analog type (§3.2 integer, real)
    }
}

/// §5.5.1: a context-determined operator is real when an operand is, and
/// signed only when both are.
fn common(a: T, c: T) T {
    if (a.isReal() or c.isReal()) return .real;
    return .{ .w = @max(a.w, c.w), .s = a.s and c.s };
}

/// `operand`'s type, which IEEE 1364 §4.1 keeps integral: a real
/// operand of a bitwise, shift or reduction operator is E0329.
fn intType(b: *Build, op: Ast.ExprId, operand: Ast.ExprId) Oom!T {
    const t = try selfType(b, operand);
    if (t.isReal()) {
        try b.fail(op, "IEEE 1364 §5.1: a bitwise, shift or reduction operator takes no real operand", .{});
        return .{ .w = 1 };
    }
    return t;
}

/// A name's type: a variable's declaration, a discrete input's, a
/// parameter's (`Lowered.Param.source_width`), else its analog type.
fn identType(b: *Build, e: Ast.ExprId, name: []const u8) Oom!T {
    const l = b.l;
    if (l.in_d2a_body and l.out.discrete_snaps.contains(name)) return opaqueType(b, e);
    if (l.vars.get(name)) |slot| return switch (slot.ty) {
        .wide => .{ .w = slot.reg_width.?, .s = slot.reg_signed },
        .integer => if (slot.reg_width) |w| .{ .w = w, .s = slot.reg_signed } else int32,
        .real => .real,
        .string => opaqueType(b, e),
    };
    if (l.out.discrete_inputs.contains(name)) {
        if (l.reg_ranges.get(name)) |rr| return .{ .w = rr.width, .s = rr.signed };
        return opaqueType(b, e);
    }
    if (!lower_expr.funcParamShadows(l, name)) if (l.param_index.get(name)) |pi| {
        const p = l.out.params.items[pi];
        if (p.ty != .integer) return opaqueType(b, e);
        const w = p.source_width orelse 32;
        // The `Model` field is an i64: a wider parameter has no carrier.
        if (w > 64) try b.fail(e, "parameter `{s}` is {d} bits; a parameter reaches the analog context in 64", .{ name, w });
        return .{ .w = @min(w, 64), .s = p.source_signed orelse true };
    };
    return opaqueType(b, e);
}

/// An operand this file does not size: lowered now, typed by its analog type.
fn opaqueType(b: *Build, e: Ast.ExprId) Oom!T {
    const tv = try lowerOpaque(b, e);
    return switch (tv.ty) {
        .integer => if (isRealToBits(b, e)) .{ .w = 64 } else int32,
        .real => .real,
        .string, .wide => blk: {
            try b.fail(e, "this operand has no integer value", .{});
            break :blk int32;
        },
    };
}

/// §9.11 `$realtobits` returns the double's 64 bits, unsigned.
fn isRealToBits(b: *Build, e: Ast.ExprId) bool {
    const ex = &b.l.file.exprs;
    return ex.tag(e) == .sys_call and std.mem.eql(u8, b.l.file.str(ex.strOf(e)), "$realtobits");
}

fn lowerOpaque(b: *Build, e: Ast.ExprId) Oom!TypedValue {
    if (b.lowered.get(e)) |tv| return tv;
    const tv = try lower_expr.lowerExpr(b.l, e);
    try b.lowered.put(b.l.arena, e, tv);
    if (tv.v == .undef) b.ok = false;
    return tv;
}

// ---- §5.5.2 building at a propagated type -----------------------------------

/// `e` computed at integer type `ctx`: a context-determined operator at
/// `ctx` itself, any other form at its own type and then converted (§5.5.2).
fn at(b: *Build, e: Ast.ExprId, ctx: T) Oom!u32 {
    const l = b.l;
    const ex = &l.file.exprs;
    const st = try selfType(b, e);
    if (st.isReal()) return b.node(.{ .op = .from_real, .width = ctx.w, .signed = ctx.s, .a = try real(b, e) });
    switch (ex.tag(e)) {
        .unary => switch (ex.unOp(e)) {
            .plus => return at(b, ex.lhs(e), ctx),
            .minus => return b.node(.{ .op = .neg, .width = ctx.w, .signed = ctx.s, .a = try at(b, ex.lhs(e), ctx) }),
            .bit_not => return b.node(.{ .op = .not, .width = ctx.w, .signed = ctx.s, .a = try at(b, ex.lhs(e), ctx) }),
            .logical_not, .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => {},
        },
        .binary => {
            const op: ?Lowered.WideOp = switch (ex.binOp(e)) {
                .add => .add,
                .sub => .sub,
                .mul => .mul,
                .div => .div,
                .mod => .rem,
                .bit_and => .@"and",
                .bit_or => .@"or",
                .bit_xor => .xor,
                .bit_xnor => .xnor,
                .shl, .ashl => .shl,
                .shr => .shr,
                .ashr => .ashr,
                .pow => .pow,
                .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge, .logical_and, .logical_or => null,
            };
            if (op) |o| {
                const a = try at(b, ex.lhs(e), ctx);
                // §5.4.1 Table 5-22: a shift count and an exponent are
                // self-determined.
                const self_determined = o == .shl or o == .shr or o == .ashr or o == .pow;
                const c = if (self_determined) try any(b, ex.rhs(e)) else try at(b, ex.rhs(e), ctx);
                return b.node(.{ .op = o, .width = ctx.w, .signed = ctx.s, .a = a, .b = c });
            }
        },
        .ternary => {
            const cond = try any(b, ex.lhs(e));
            return b.node(.{ .op = .cond, .width = ctx.w, .signed = ctx.s, .a = cond, .b = try at(b, ex.rhs(e), ctx), .c = try at(b, ex.ternaryElse(e), ctx) });
        },
        else => {}, // else: every other form is an operand of its own type, converted below
    }
    return resizeTo(b, try leafOf(b, e, st), st, ctx);
}

/// `e` at its own type (§5.5.2's self-determined operand); a real stays real.
fn any(b: *Build, e: Ast.ExprId) Oom!u32 {
    const st = try selfType(b, e);
    return if (st.isReal()) real(b, e) else at(b, e, st);
}

/// §5.5.2: converted to `to`, extended by `to`'s sign.
fn resizeTo(b: *Build, n: u32, from: T, to: T) Oom!u32 {
    if (from.w == to.w) return n;
    return b.node(.{ .op = .resize, .width = to.w, .signed = to.s, .a = n });
}

/// `e`, a form with a self-determined result (a leaf, a select, a
/// comparison, a logical or reduction operator), at its type `st`.
fn leafOf(b: *Build, e: Ast.ExprId, st: T) Oom!u32 {
    const l = b.l;
    const ex = &l.file.exprs;
    switch (ex.tag(e)) {
        .int_literal, .logic_literal => return literal(b, e, st),
        .ident => if (try identNode(b, l.file.str(ex.strOf(e)), st)) |n| return n,
        .index => if (b.sels.get(e)) |s| return selectNode(b, try baseNode(b, s.name), l.reg_ranges.get(s.name).?.width, s.lo, s.width),
        .unary => switch (ex.unOp(e)) {
            .logical_not => return b.node(.{ .op = .lnot, .width = 1, .a = try any(b, ex.lhs(e)) }),
            .reduce_and, .reduce_or, .reduce_xor => |u| return b.node(.{ .op = reduction(u), .width = 1, .a = try any(b, ex.lhs(e)) }),
            .reduce_nand, .reduce_nor, .reduce_xnor => |u| return b.node(.{ .op = .lnot, .width = 1, .a = try b.node(.{ .op = reduction(u), .width = 1, .a = try any(b, ex.lhs(e)) }) }),
            .plus, .minus, .bit_not => unreachable, // `at` computes these at the context
        },
        .binary => switch (ex.binOp(e)) {
            .logical_and, .logical_or => |o| return b.node(.{ .op = if (o == .logical_and) .land else .lor, .width = 1, .a = try any(b, ex.lhs(e)), .b = try any(b, ex.rhs(e)) }),
            .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge => |o| return comparison(b, o, ex.lhs(e), ex.rhs(e)),
            .add, .sub, .mul, .div, .mod, .pow, .bit_and, .bit_or, .bit_xor, .bit_xnor, .shl, .shr, .ashl, .ashr => unreachable, // `at` computes these at the context
        },
        else => {}, // else: every other form is an analog operand (`opaque`)
    }
    const tv = try lowerOpaque(b, e);
    return switch (tv.ty) {
        .integer => b.node(.{ .op = .leaf_int, .width = st.w, .signed = st.s, .arg = try b.arg(tv.v) }),
        .real, .string, .wide => unreachable, // `selfType` typed this operand an integer
    };
}

fn reduction(u: Ast.UnaryOp) Lowered.WideOp {
    return switch (u) {
        .reduce_and, .reduce_nand => .red_and,
        .reduce_or, .reduce_nor => .red_or,
        .reduce_xor, .reduce_xnor => .red_xor,
        .plus, .minus, .bit_not, .logical_not => unreachable, // the callers pass reductions only
    };
}

/// §5.1.7/§5.1.8: both operands at their common type (a real comparison
/// when either is real); a one-bit unsigned result.
fn comparison(b: *Build, o: Ast.BinaryOp, x: Ast.ExprId, y: Ast.ExprId) Oom!u32 {
    const tx = try selfType(b, x);
    const ty = try selfType(b, y);
    const c = common(tx, ty);
    const a = if (c.isReal()) try real(b, x) else try at(b, x, c);
    const d = if (c.isReal()) try real(b, y) else try at(b, y, c);
    return switch (o) {
        .eq, .case_eq => b.node(.{ .op = .eq, .width = 1, .a = a, .b = d }),
        .neq, .case_neq => b.node(.{ .op = .lnot, .width = 1, .a = try b.node(.{ .op = .eq, .width = 1, .a = a, .b = d }) }),
        .lt => b.node(.{ .op = .lt, .width = 1, .a = a, .b = d }),
        .gt => b.node(.{ .op = .lt, .width = 1, .a = d, .b = a }),
        .le => b.node(.{ .op = .le, .width = 1, .a = a, .b = d }),
        .ge => b.node(.{ .op = .le, .width = 1, .a = d, .b = a }),
        else => unreachable, // else: `leafOf` passes the comparisons only
    };
}

/// `e` as a real: a real operator over real operands, or an integer operand
/// computed at its own type and then converted (§5.5.2's first exception).
fn real(b: *Build, e: Ast.ExprId) Oom!u32 {
    const l = b.l;
    const ex = &l.file.exprs;
    const st = try selfType(b, e);
    if (!st.isReal()) return b.node(.{ .op = .to_real, .width = 0, .a = try at(b, e, st) });
    switch (ex.tag(e)) {
        .unary => switch (ex.unOp(e)) {
            .plus => return real(b, ex.lhs(e)),
            .minus => return b.node(.{ .op = .neg, .width = 0, .a = try real(b, ex.lhs(e)) }),
            .bit_not, .logical_not, .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => unreachable, // integer results
        },
        .binary => {
            const op: Lowered.WideOp = switch (ex.binOp(e)) {
                .add => .add,
                .sub => .sub,
                .mul => .mul,
                .div => .div,
                .mod => .rem,
                .pow => .pow,
                // `selfType` types every other operator an integer.
                .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge, .logical_and, .logical_or => unreachable,
                .bit_and, .bit_or, .bit_xor, .bit_xnor, .shl, .shr, .ashl, .ashr => unreachable,
            };
            return b.node(.{ .op = op, .width = 0, .a = try real(b, ex.lhs(e)), .b = try real(b, ex.rhs(e)) });
        },
        .ternary => return b.node(.{ .op = .cond, .width = 0, .a = try any(b, ex.lhs(e)), .b = try real(b, ex.rhs(e)), .c = try real(b, ex.ternaryElse(e)) }),
        .real_literal => return b.node(.{ .op = .leaf_real, .width = 0, .arg = try b.arg(try l.mir.addFloatConst(l.arena, ex.realValue(e))) }),
        else => {}, // else: a real variable, parameter or call: its analog value
    }
    const tv = try lowerOpaque(b, e);
    return b.node(.{ .op = .leaf_real, .width = 0, .arg = try b.arg(tv.v) });
}

// ---- operands -----------------------------------------------------------------

/// A name's node at its type `st`, or null for an analog operand (`opaque`).
fn identNode(b: *Build, name: []const u8, st: T) Oom!?u32 {
    const l = b.l;
    if (l.in_d2a_body and l.out.discrete_snaps.contains(name)) return null;
    if (l.vars.get(name)) |slot| switch (slot.ty) {
        .wide => return try b.node(.{ .op = .leaf_wide, .width = st.w, .signed = st.s, .arg = try b.arg(try l.builder.readVariable(slot.place, l.cur)) }),
        // A `reg` past 32 bits the analog context never assigns holds its
        // literal for the whole analysis (`Lower.reg_consts`).
        .integer => if (slot.reg_width != null and slot.reg_width.? > 32) {
            return try constReg(b, name, st);
        } else {
            // The slot's own value: the `reg`'s bits, no Table 7-1 conversion.
            return try b.node(.{ .op = .leaf_int, .width = st.w, .signed = st.s, .arg = try b.arg(try l.builder.readVariable(slot.place, l.cur)) });
        },
        .real, .string => return null,
    };
    if (l.out.discrete_inputs.contains(name) and l.reg_ranges.contains(name)) return try inputNode(b, name, st);
    return null;
}

/// The whole `reg` `name` (a variable or a discrete input) at its own type.
fn baseNode(b: *Build, name: []const u8) Oom!u32 {
    const rr = b.l.reg_ranges.get(name).?;
    return (try identNode(b, name, .{ .w = rr.width, .s = rr.signed })).?;
}

/// §5.5.3 the literal a `reg` the analog context never assigns was given,
/// extended to the `reg` by the literal's own sign (zero with none).
fn constReg(b: *Build, name: []const u8, st: T) Oom!u32 {
    const e = b.l.reg_consts.get(name) orelse .none;
    if (e == .none) return lit(b, &.{}, st.w);
    const lt = try selfType(b, e);
    return resizeTo(b, try literal(b, e, lt), lt, .{ .w = st.w, .s = lt.s });
}

/// A discrete input `reg` (`Lowered.discrete_words`): its `Model` words.
fn inputNode(b: *Build, name: []const u8, st: T) Oom!u32 {
    const l = b.l;
    const words = l.out.discrete_words.get(name) orelse 1;
    if (words == 1) return b.node(.{ .op = .leaf_int, .width = st.w, .signed = st.s, .arg = try b.arg(try lower_expr.regWordValue(l, name, 0)) });
    const first = try b.arg(try lower_expr.regWordValue(l, name, 0));
    for (1..words) |k| _ = try b.arg(try lower_expr.regWordValue(l, name, @intCast(k)));
    return b.node(.{ .op = .leaf_words, .width = st.w, .signed = st.s, .arg = first });
}

/// A resolved constant select `name[hi:lo]` / `name[k]` of a `reg` (IEEE
/// 1364 §4.2.1): its offset from the `reg`'s LSB and its bits.
const Sel = struct { name: []const u8, lo: u32, width: u32 };

/// The `reg` `e` selects from, when `e` is `name[...]` of a `reg` this file
/// reads whole (a variable or a discrete input), else null.
fn selectOf(l: *Lower, e: Ast.ExprId) ?[]const u8 {
    const ex = &l.file.exprs;
    const base = ex.lhs(e);
    if (base == .none or ex.tag(base) != .ident) return null;
    const name = l.file.str(ex.strOf(base));
    if (l.arrays.contains(name) or !l.reg_ranges.contains(name)) return null;
    if (l.in_d2a_body and l.out.discrete_snaps.contains(name)) return null;
    if (l.vars.get(name) == null and !(l.out.discrete_inputs.contains(name) and !lower_expr.funcParamShadows(l, name))) return null;
    return name;
}

/// The select `e` of `reg` `name`: unsigned, its width (§5.5.1).
fn selectType(b: *Build, e: Ast.ExprId, name: []const u8) Oom!T {
    const l = b.l;
    const ex = &l.file.exprs;
    const rr = l.reg_ranges.get(name).?;
    const sub = ex.rhs(e);
    if (ex.tag(sub) == .indexed_range) {
        try b.fail(sub, "an indexed part-select of `{s}`", .{name});
        return .{ .w = 1 };
    }
    const ranged = ex.tag(sub) == .range;
    const hi_e, const lo_e = if (ranged) .{ ex.lhs(sub), ex.rhs(sub) } else .{ sub, sub };
    const hi = lower_expr.selectBound(l, hi_e);
    const lo = lower_expr.selectBound(l, lo_e);
    if (hi == null or lo == null) {
        try b.fail(sub, "a select of `{s}` needs constant bounds", .{name});
        return .{ .w = 1 };
    }
    const pa = lower_expr.selectPos(rr, hi.?);
    const pb = lower_expr.selectPos(rr, lo.?);
    if (pa == null or pb == null) {
        b.ok = false;
        _ = try lower_expr.outsideRange(l, sub, name, if (pa == null) hi.? else lo.?, rr.width);
        return .{ .w = 1 };
    }
    const s: Sel = .{ .name = name, .lo = @min(pa.?, pb.?), .width = @max(pa.?, pb.?) - @min(pa.?, pb.?) + 1 };
    try b.sels.put(l.arena, e, s);
    return .{ .w = s.width };
}

/// IEEE 1364 §4.2.1: bits `lo` to `lo + width - 1` of `base`, unsigned.
fn selectNode(b: *Build, base: u32, base_width: u32, lo: u32, width: u32) Oom!u32 {
    var n = base;
    if (lo != 0) {
        const count = try lit(b, &.{lo}, 32);
        n = try b.node(.{ .op = .shr, .width = base_width, .a = n, .b = count });
    }
    if (width == base_width) return n;
    return b.node(.{ .op = .resize, .width = width, .a = n });
}

/// §2.6.1/§3.5.1 a literal operand at its own type `st`.
fn literal(b: *Build, e: Ast.ExprId, st: T) Oom!u32 {
    const ex = &b.l.file.exprs;
    const words = try b.l.arena.alloc(u32, (st.w + 31) / 32);
    @memset(words, 0);
    if (ex.tag(e) == .int_literal) {
        const bits: u64 = @bitCast(ex.intValue(e));
        words[0] = @truncate(bits);
        if (words.len > 1) words[1] = @truncate(bits >> 32);
    } else {
        const n = ex.logicValue(e);
        for (0..@min(st.w, n.width)) |k| if (n.bit(@intCast(k)) == .one) {
            words[k / 32] |= @as(u32, 1) << @intCast(k % 32);
        };
    }
    const node = try lit(b, words, st.w);
    b.l.out.wide_nodes.items[node].signed = st.s;
    return node;
}

/// A two-state logic literal's low 64 bits as an i64 (its exact value when
/// an i64 holds it, `Integer.Literal.asExactInt`).
pub fn literalLow64(self: *Lower, e: Ast.ExprId) i64 {
    const n = self.file.exprs.logicValue(e);
    if (n.asExactInt()) |v| return v;
    return @bitCast(n.values()[0]);
}

/// A literal node of `width` bits, its 32-bit words `words` (missing ones
/// zero; bits past `width` are cut).
fn lit(b: *Build, words: []const u32, width: u32) Oom!u32 {
    const first: u32 = @intCast(b.l.out.wide_lits.items.len);
    const n = (width + 31) / 32;
    for (0..n) |k| try b.l.out.wide_lits.append(b.l.arena, if (k < words.len) words[k] else 0);
    if (width % 32 != 0) b.l.out.wide_lits.items[first + n - 1] &= (@as(u32, 1) << @intCast(width % 32)) - 1;
    return b.node(.{ .op = .lit, .width = width, .arg = first });
}

test "IEEE 1364 §5.5.1: a context-determined operator is signed only when both operands are" {
    try std.testing.expectEqual(T{ .w = 40, .s = false }, common(.{ .w = 32, .s = true }, .{ .w = 40 }));
    try std.testing.expectEqual(T{ .w = 40, .s = true }, common(.{ .w = 32, .s = true }, .{ .w = 40, .s = true }));
    try std.testing.expect(common(.real, .{ .w = 40 }).isReal());
}
