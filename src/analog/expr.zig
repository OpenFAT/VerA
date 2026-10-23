//! §4.2 expressions, §4.3 math functions, §4.4 signal access.
//!
//! In: expression AST. Out: typed MIR values (`TypedValue`).
//!
//! LRM clauses this file's code cites: §1.3.1.2, §2.6.1, §2.6.2, §2.7, §2.8,
//! §2.9, §3.2, §3.2.1, §3.3, §3.4, §3.4.4, §3.5, §3.6.1.2, §3.12.1, §3.13.2,
//! §4, §4.2.1, §4.2.1.1, §4.2.1.3, §4.2.3, §4.2.4, §4.2.5, §4.2.7, §4.2.8,
//! §4.2.9, §4.2.10, §4.2.11, §4.2.12, §4.2.13, §4.3, §4.3.1, §4.3.2, §4.4,
//! §4.5, §4.5.15, §4.6, §4.7, §4.7.2, §4.7.2.4, §5.2.1, §5.3.2, §5.4.1, §5.4.2,
//! §5.4.2.1, §5.4.2.2, §5.4.3, §5.5.3, §5.5.4, §5.5.5, §5.6.1.2, §5.6.6,
//! §5.6.8.1, §5.6.8.2, §5.8.1, §6.6.1, §6.6.2, §6.6.3, §6.7, §6.7.1, §6.8,
//! §7.3.1, §8.5.3.6, §9.4, §9.20, A.8.9.
//! IEEE 1364-2005 clauses cited: §4.2.1, §5.1.8, §5.5.1, §9.5.1, §12.7.
//! §9.14 / IEEE §§5.4–5.5 size the self-determined `$clog2` operand.

const std = @import("std");
const Lower = @import("lower.zig");
const lower_analog_op = @import("analog_op.zig");
const lower_constfold = @import("constfold.zig");
const lower_contrib = @import("contrib.zig");
const lower_control = @import("control.zig");
const lower_func = @import("func.zig");
const lower_event = @import("event.zig");
const lower_hier_name = @import("hier_name.zig");
const lower_node = @import("node.zig");
const lower_stmt = @import("stmt.zig");
const lower_sysfunc = @import("sysfunc.zig");
const lower_systask = @import("systask.zig");
const lower_shape = @import("shape.zig");
const lower_var = @import("var.zig");
const lower_wide = @import("wide.zig");
const Ast = @import("frontend").Ast;
const constfold = @import("frontend").constfold;
const Const = constfold.Const;
const Mir = @import("ir").Mir;
const naming = @import("ir").names;
const Elaborate = @import("elab").Elaborate;
const diag = @import("diag");
const Oom = Lower.Oom;
const ground = Lower.ground;
const TypedValue = Lower.TypedValue;
const VarSlot = Lower.VarSlot;
const Accum = Lower.Accum;
const poison = Lower.poison;
const unify = Lower.unify;
const astTy = Lower.astTy;

/// Lowers an expression, returning its value and its LRM type; every
/// operator's opcode family depends on the type (LRM §4, §4.2.1.1–§4.2.1.3).
pub fn lowerExpr(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    return lowerExprRaw(self, e, null, false);
}

/// IEEE §§5.4–5.5 inside a self-determined `$clog2` argument. Function
/// calls still lower their bodies and arguments on their own ordinary path.
pub fn lowerClog2Arg(self: *Lower, e: Ast.ExprId, parent: ?constfold.IntContext) Oom!TypedValue {
    if (e == .none) return poison;
    const plan = lower_constfold.clog2Plan(self, e, parent);
    if (plan) |p| if (!p.supported) {
        var width = p.from_width;
        for (p.operands) |operand| if (operand) |c| {
            width = @max(width, c.width);
        };
        try self.err(self.file.exprs.mainTok(e), .E0893, "this intermediate needs {d} bits", .{width});
        return poison;
    };
    var value = try lowerExprRaw(self, e, plan, true);
    if (value.ty == .integer) if (plan) |p| {
        value.v = try resizeInt(self, value.v, .{ .width = p.from_width, .signed = p.result.signed });
        if (p.from_width != p.result.width) value.v = try resizeInt(self, value.v, p.result);
    };
    return value;
}

fn lowerOperand(self: *Lower, e: Ast.ExprId, plan: ?constfold.IntPlan, sized: bool, index: usize) Oom!TypedValue {
    return if (sized) lowerClog2Arg(self, e, if (plan) |p| p.operands[index] else null) else lowerExpr(self, e);
}

/// IntContext.normalize without any width-erasing arithmetic opcode.
fn resizeInt(self: *Lower, v: Mir.Value, context: constfold.IntContext) Oom!Mir.Value {
    if (context.width >= 64) return v;
    const mask: i64 = @intCast((@as(u64, 1) << @intCast(context.width)) - 1);
    const bits = try self.emit(.bitand, &.{ v, try self.mir.addIntConst(self.arena, mask) });
    if (!context.signed) return bits;
    std.debug.assert(context.width >= 1); // `IntContext`: every context comes from an operand width
    const sign = try self.emit(.bitand, &.{ bits, try self.mir.addIntConst(self.arena, @as(i64, 1) << @intCast(context.width - 1)) });
    const negative = try self.emit(.bitor, &.{ bits, try self.mir.addIntConst(self.arena, ~mask) });
    return self.emit(.select, &.{ try self.toBool(.{ .v = sign, .ty = .integer }), negative, bits });
}

// Timer capture belongs on both ordinary and width-aware expression paths.
// A $clog2 operand must retain its dependency when its timer is rescheduled.
fn lowerExprRaw(self: *Lower, e: Ast.ExprId, plan: ?constfold.IntPlan, sized: bool) Oom!TypedValue {
    if (lower_event.replayedExpr(self, e)) |value| return value;
    const value = try lowerExprInner(self, e, plan, sized);
    try lower_event.captureExpr(self, e, value);
    return value;
}

fn lowerExprInner(self: *Lower, e: Ast.ExprId, plan: ?constfold.IntPlan, sized: bool) Oom!TypedValue {
    // An omitted A.8.2 slot reaches here only when its function gave it no
    // meaning: every slot with a default is read before lowering. The cursor
    // is still the enclosing call's token.
    if (e == .none) {
        try self.err(self.mir.cur_tok, .E0894, "write the argument", .{});
        return poison;
    }
    const ex = &self.file.exprs;
    // Provenance: every MIR instruction emitted while this node is being
    // lowered is stamped with its token (Mir.addInst reads the cursor), which
    // is how proof.zig turns a `Mir.Inst` back into a source span. Saved and
    // restored because lowering recurses: an operand must not leave the cursor
    // pointing at itself once the parent resumes emitting.
    const saved_tok = self.mir.cur_tok;
    defer self.mir.cur_tok = saved_tok;
    self.mir.cur_tok = ex.mainTok(e);
    switch (ex.tag(e)) {
        .int_literal => return .{ .v = try self.mir.addIntConst(self.arena, ex.intValue(e)), .ty = .integer }, // §2.6.1
        .logic_literal => {
            // §2.6.1 sets no size limit: a wide two-state literal whose value
            // an i64 holds exactly is that integer.
            const lit = ex.logicValue(e);
            if (lit.asExactInt()) |value| return .{ .v = try self.mir.addIntConst(self.arena, value), .ty = .integer };
            // A wider two-state value is whole only where IEEE 1364 §5.4 sizes
            // it: the right-hand side of a wide `reg` (`lower_wide`). An x or z
            // literal never reaches here (`Lower.lowerFile`).
            const span = self.tokenSpan(ex.mainTok(e));
            try self.err(ex.mainTok(e), .E0130, "`{s}`: the analog backend cannot execute this {d}-bit wide literal", .{ self.src[span.start..span.end], lit.width });
            return poison;
        },
        .real_literal => return .{ .v = try self.mir.addFloatConst(self.arena, ex.realValue(e)), .ty = .real }, // §2.6.2
        .str_literal => return .{
            .v = try self.mir.addStrConst(self.arena, self.file.str(ex.strOf(e))),
            .ty = .string,
        }, // §2.7
        // A.2.5 — only legal inside a value range, which proof.zig reads from
        // the AST directly; lowering one is harmless.
        .pos_inf => return .{ .v = .f_inf, .ty = .real },
        .neg_inf => return .{ .v = try self.mir.addFloatConst(self.arena, -std.math.inf(f64)), .ty = .real },

        .ident => return lookupName(self, e, self.file.str(ex.strOf(e))),
        .hier_ident => {
            // §5.5.3 Syntax 5-4 first: a nature attribute reference is a
            // CONSTANT this module can resolve, unlike a §6.8 hierarchical name,
            // which needs an instance tree (E0901).
            if (lower_analog_op.natureAttrRef(self, e)) |r| switch (r) {
                .value => |c| return switch (c) {
                    .real, .int => .{ .v = try self.mir.addFloatConst(self.arena, c.asReal()), .ty = .real },
                    .str => .{ .v = try self.mir.addStrConst(self.arena, c.str), .ty = .string },
                },
                .banned => |attr| {
                    var b = self.errWith(self.file.exprs.mainTok(e), .E0359);
                    b.msg("`{s}`", .{attr});
                    b.note("§5.5.3: \"This syntax shall not be used for the access, ddt_nature, or idt_nature attributes of a nature, nor any other attribute whose value is not a constant expression\"", .{});
                    try b.emit();
                    return poison;
                },
            };
            // §6.7 "access of parameters can be done hierarchically", and
            // §6.7.1 extends it to variables. The path IS the flat name
            // elaboration gave the child's entity, so once the join resolves
            // there is nothing hierarchical left to do; E0901 is what is left
            // when it does not.
            if (try refuseUnnamedGen(self, e)) return poison;
            const name = try flatName(self, e);
            // §6.7.1's fifth bullet, and the only one of the list that is a
            // prohibition: "It shall be an error to access analog variables
            // hierarchically." It has to be tested before the resolution below,
            // because the resolution succeeds — a flattened child's variable is
            // an ordinary variable of the flat design under its path name, so
            // nothing else would stop the read.
            // Except a §5.3.2 named-block local, which the LRM spells out the
            // other way: "All identifiers declared within a named sequential
            // block can be accessed outside the scope in which they are
            // declared." §6.7.1 is about reaching into another INSTANCE;
            // `publishBlockLocals` bound only labels of this analog block.
            if (self.vars.contains(name) and !self.block_locals.contains(name)) {
                var vb = self.errWith(self.file.exprs.mainTok(e), .E0910);
                vb.msg("`{s}`", .{name});
                vb.note("§6.7.1 permits a hierarchical parameter, branch probe or analog function; a variable is the one entry on that list it forbids", .{});
                try vb.emit();
                return poison;
            }
            if (self.param_index.contains(name) or self.consts.contains(name) or
                self.node_voltages.contains(name) or self.block_locals.contains(name))
                return lookupName(self, e, name);
            try self.err(self.file.exprs.mainTok(e), .E0901, "`{s}` names nothing in the elaborated design", .{name});
            return poison;
        },

        .unary => return lowerUnary(self, e, plan, sized),
        .binary => return lowerBinary(self, e, plan, sized),
        .ternary => return lowerTernary(self, e, plan, sized), // §4.2.3 / §4.2.12

        .call => return lower_func.lowerUserCall(self, e), // §4.7
        .builtin_call => return lowerBuiltin(self, e), // §4.3
        .sys_call => return lower_sysfunc.lowerSysCall(self, e), // ch9
        .filter_call => return lower_analog_op.lowerFilter(self, e), // §4.5
        .noise_call => return lower_analog_op.lowerNoise(self, e), // §4.6

        .branch_access => return lowerBranchAccess(self, e), // §4.4.1
        .port_access => return lowerPortAccess(self, e), // §4.4.2/§5.4.3

        .index => return lowerIndex(self, e),

        // §4.2.13 / §3.3 Table 3-3. A `.multi_concat` reaches lowering only
        // when its multiplier is not a literal, which Table 3-3 allows for a
        // string result, or its operands are not all literals, which §4.2.13
        // evaluates once; every other replication was unrolled in the
        // parser, where the operand widths still exist.
        .concat, .multi_concat => return lowerConcat(self, e),
        .assign_pattern, .pattern_repl => {
            try self.err(self.file.exprs.mainTok(e), .E0509, "", .{});
            return poison;
        },
        .range, .indexed_range => {
            try self.err(self.file.exprs.mainTok(e), .E0329, "", .{});
            return poison;
        },
        .event_or,
        .event_posedge,
        .event_negedge,
        .event_initial_step,
        .event_final_step,
        .event_function,
        // A.6.5 `driver_update expression` — an event, so E0701 like the rest.
        // Nothing lowers a connect module, so this is reachable only if someone
        // writes the keyword where a value belongs.
        .event_driver_update,
        => {
            try self.err(self.file.exprs.mainTok(e), .E0701, "", .{});
            return poison;
        },
    }
}

/// §3.2.2 array element read. A constant index selects one scalarized
/// element; a runtime index becomes a `$idx` call carrying every element, which
/// codegen renders as ONE `switch` — a jump table, so the read is O(1) in the
/// array's extent (the array is scalarized, so there is no memory to index).
fn lowerIndex(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    var subs: [lower_shape.max_stack_dims]Ast.ExprId = undefined;
    const chain = (try lower_stmt.indexChain(self, e, &subs)) orelse {
        try self.err(self.file.exprs.mainTok(e), .E0330, "only `name[<index>]` is supported", .{});
        return poison;
    };
    const name = self.file.str(chain.name);
    const info = self.arrays.get(name) orelse {
        if (chain.subs.len == 1) if (self.reg_ranges.get(name)) |rr| {
            if (self.vars.get(name)) |slot| return lowerRegSelect(self, e, name, .{ .slot = slot }, rr, chain.subs[0]);
            if (self.out.discrete_inputs.contains(name)) return lowerRegSelect(self, e, name, .input, rr, chain.subs[0]);
        };
        try self.err(self.file.exprs.mainTok(e), .E0309, "`{s}`", .{name});
        return poison;
    };

    try lower_event.captureTimerArray(self, name);
    var idx: [lower_shape.max_stack_dims]i64 = undefined;
    const at = try lower_shape.subscriptBuf(self, &idx, chain.subs.len);
    var all_const = true;
    for (chain.subs, at) |s, *o| {
        // `foldExpr(.., false)`, not `constEval`: a §3.4 parameter is
        // overridable by the model card, so folding `a[n-1]` through `n`'s
        // default would bake one element into the device for every card.
        if (lower_constfold.foldExpr(self, s, false)) |c| {
            // §4.2.1.1 converts a real subscript by rounding to the nearest
            // integer; an infinity, a NaN, or a magnitude past i64 has none, so
            // the subscript names no element: E0310, as for a constant
            // subscript outside the declared range.
            o.* = c.asIntExact() orelse {
                try self.err(self.file.exprs.mainTok(s), .E0310, "subscript {e} of `{s}` has no integer value, so it lies outside every dimension", .{ c.asReal(), name });
                return poison;
            };
        } else all_const = false;
    }
    if (!try lower_stmt.checkSubscriptCount(self, e, name, info, at.len)) return poison;
    if (all_const) {
        if (!try lower_stmt.checkSubscripts(self, e, name, info, at)) return poison;
        return (try arrayElemValue(self, name, at)) orelse poison;
    }

    // `$idx` emits one switch over the scalarized elements. Both reads and
    // writes use the same declared-order flattening and per-dimension bounds.
    const iv = try lower_stmt.runtimeArrayIndex(self, chain.subs, info.dims);
    const ty = info.ty;
    // A memory-backed array reads one element of its storage; an invalid
    // subscript (-1) reads the zero the `$idx` switch's default gives.
    if (info.mem) |m| return .{ .v = try lower_var.loadElem(self, m, ty, iv), .ty = ty };
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    try vals.append(self.arena, .zero);
    try vals.append(self.arena, iv);
    for (0..lower_shape.shapeCells(info.dims)) |k| {
        lower_shape.shapeSubscripts(info.dims, k, at);
        const el = (try arrayElemValue(self, name, at)) orelse return poison;
        try vals.append(self.arena, if (ty == .real) try self.toReal(el) else el.v);
    }
    // The callee name IS the result type — `callee.ty` and `sysFuncTy`
    // agree by construction, the `$sscanf$int` rule.
    const callee: []const u8 = switch (ty) {
        .real => "$idx",
        .integer => "$idx$int",
        .string => "$idx$str",
        .wide => unreachable, // an array element is never `.wide` (`lower_var.declareVarDecl`)
    };
    return .{ .v = try self.call(callee, vals.items), .ty = ty };
}

/// §7.3.1 a constant bit- or part-select of a `reg` read from the analog
/// context: the selected grouping, shifted to bit 0 and zero-extended by
/// `analogRead`, which judges the GROUPING's width against Table 7-1's
/// "Access of discrete bit groupings with greater than 31 bits is illegal".
/// So `r[30:0]` of a `reg [39:0] r` is legal and `r` itself is E0222.
/// The right-hand bound of a packed range is its LSB in either direction
/// (IEEE 1364-2005 §4.2.1), so bit k sits |k - right| places above bit 0.
///
/// The `reg` is a variable (`slot`) or a mixed module's discrete input
/// (`input`, the `Model` field the host writes). Bits 0 to 31 are its §3.2
/// integer's. Above them: a discrete input's further 32-bit words
/// (`Lowered.discrete_words`), the literal a variable holds for the whole
/// analysis (`Lower.reg_consts`), or every bit of a wide `reg` the analog
/// context computes (`Ty.wide`, `lower_wide.select`).
fn lowerRegSelect(self: *Lower, e: Ast.ExprId, name: []const u8, src: union(enum) { slot: VarSlot, input }, rr: Lower.RegRange, sub: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const ranged = ex.tag(sub) == .range;
    const hi_e, const lo_e = if (ranged) .{ ex.lhs(sub), ex.rhs(sub) } else .{ sub, sub };
    if (ex.tag(sub) == .indexed_range) {
        try self.err(ex.mainTok(sub), .E0329, "an indexed part-select of `{s}` read from the analog context", .{name});
        return poison;
    }
    const a: i64, const b: i64 = bounds: {
        if (selectBound(self, hi_e)) |ka| if (selectBound(self, lo_e)) |kb| break :bounds .{ ka, kb };
        try self.err(ex.mainTok(sub), .E0329, "a select of `{s}` read from the analog context needs constant bounds", .{name});
        return poison;
    };
    const w = rr.width;
    const pa = selectPos(rr, a) orelse return outsideRange(self, sub, name, a, w);
    const pb = selectPos(rr, b) orelse return outsideRange(self, sub, name, b, w);
    const lo = @min(pa, pb);
    const width = @max(pa, pb) - lo + 1;
    // Table 7-1's limit on the grouping (E0222, `analogRead`).
    if (width > 31) return .{ .v = try lower_var.analogRead(self, .undef, width), .ty = .integer };
    switch (src) {
        .slot => |slot| if (slot.ty == .wide) return .{ .v = try lower_wide.select(self, slot, lo, width), .ty = .integer },
        .input => {},
    }
    // Bits 0 to 31.
    if (@max(pa, pb) < 32) {
        const raw = switch (src) {
            .slot => |slot| try self.builder.readVariable(slot.place, self.cur),
            .input => (try lookupName(self, e, name)).v,
        };
        const shifted = if (lo == 0) raw else try self.emit(.shr, &.{ raw, try self.mir.addIntConst(self.arena, lo) });
        return .{ .v = try lower_var.analogRead(self, shifted, width), .ty = .integer };
    }
    switch (src) {
        // The literal's bits, zero- or sign-extended to the `reg`'s width as
        // an assignment extends it (IEEE 1364-2005 §5.5.1).
        .slot => {
            const lit = self.reg_consts.get(name) orelse unreachable; // every other `reg` past 32 bits is `.wide` (`lower_var.declareVarDecl`)
            var v: i64 = 0;
            for (0..width) |i| if (literalBit(self, lit, lo + @as(u32, @intCast(i)))) {
                v |= @as(i64, 1) << @intCast(i);
            };
            return .{ .v = try self.mir.addIntConst(self.arena, v), .ty = .integer };
        },
        // Words k0 and k1 of the host's copy: `>>` and `<<` act on 32 bits
        // (§3.2.1), which is each word's width, and `analogRead` masks.
        .input => {
            if (self.in_d2a_body and self.out.discrete_snaps.contains(name)) {
                try self.err(ex.mainTok(sub), .E0329, "`{s}[{d}:{d}]` reaches above bit 31 under an explicit D2A event, whose region-1b copy holds bits 0 to 31", .{ name, a, b });
                return poison;
            }
            const k0 = lo / 32;
            const k1 = (lo + width - 1) / 32;
            const s = lo % 32;
            const w0 = try regWordValue(self, name, k0);
            var v = if (s == 0) w0 else try self.emit(.shr, &.{ w0, try self.mir.addIntConst(self.arena, s) });
            if (k1 != k0) v = try self.emit(.bitor, &.{ v, try self.emit(.shl, &.{ try regWordValue(self, name, k1), try self.mir.addIntConst(self.arena, 32 - s) }) });
            return .{ .v = try lower_var.analogRead(self, v, width), .ty = .integer };
        },
    }
}

/// A select bound: a constant the folder can make an integer of, or null.
pub fn selectBound(self: *Lower, e: Ast.ExprId) ?i64 {
    const c = lower_constfold.foldExpr(self, e, false) orelse return null;
    return c.asIntExact();
}

/// Where bit `k` of a `reg` with range `r` sits above its LSB (IEEE 1364
/// §4.2.1), or null outside the range.
pub fn selectPos(r: Lower.RegRange, k: i64) ?u32 {
    const d = if (r.asc) r.right - k else k - r.right;
    if (d < 0 or d >= r.width) return null;
    return @intCast(d);
}

/// Word `k` of a discrete `reg` input: the `Model` field the host writes it in.
pub fn regWordValue(self: *Lower, name: []const u8, k: u32) Oom!Mir.Value {
    const key = if (k == 0) name else try naming.wordField(self.arena, name, k);
    return self.param_values.items[self.param_index.get(key).?];
}

/// Bit `k` of the literal initializer `lit` (`.none`: zero) of a `reg`.
fn literalBit(self: *Lower, lit: Ast.ExprId, k: u32) bool {
    if (lit == .none) return false;
    const ex = &self.file.exprs;
    if (ex.tag(lit) == .int_literal) {
        const x = ex.intValue(lit);
        return (x >> @as(u6, @intCast(@min(k, 63)))) & 1 != 0;
    }
    const l = ex.logicValue(lit);
    if (k < l.width) return l.bit(k) == .one;
    return l.signed and l.bit(l.width - 1) == .one;
}

/// E0310: bit `k` lies outside `name`'s `w`-bit range.
pub fn outsideRange(self: *Lower, sub: Ast.ExprId, name: []const u8, k: i64, w: u32) Oom!TypedValue {
    try self.err(self.file.exprs.mainTok(sub), .E0310, "bit {d} lies outside `{s}`'s {d}-bit range", .{ k, name, w });
    return poison;
}

/// `{a, b, ...}` in a value position. The INTEGER form (§4.2.13) needs each
/// operand's bit width, which only the token text carries, so `parser.zig`
/// folds it and lowering never sees one, but for integer function calls
/// (`intCallConcat`); what is left here is §3.3 Table 3-3
/// `{Str1,...,Strn}`, "concatenation of Str1,…,Strn" — the LRM's own example is
/// `{ "hello", " ", "world" }` == `"hello world"`.
///
/// Constant operands fold to one `str_const`. Table 3-3 lets an operand be "of
/// type string", so one known only while the device runs is legal: each run
/// of constant operands still folds, and the pieces are joined by the
/// synthetic `$str$cat`, which builds the string in its call site's scratch
/// (`str_kernels.zStrCat`) exactly as `$sformat` does.
///
/// A `.multi_concat` arrives here for two reasons: §4.2.13 evaluates a
/// non-literal operand once, so the parser does not unroll one; and §3.3
/// Table 3-3's Replication row says the "multiplier must be of integral type
/// and can be nonconstant. If multiplier is nonconstant or Str is of type
/// string, the result is a string containing N concatenated copies", and the
/// parser unrolls only a literal count (see `replCount`). A multiplier the
/// folder can make a number of is unrolled here; one it cannot is the row's
/// nonconstant case, and `$str$repeat`
/// makes the N copies while the device runs (`str_kernels.zStrRepeat`).
fn lowerConcat(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const repl = ex.tag(e) == .multi_concat;
    const elems = ex.args(if (repl) ex.rhs(e) else e);
    if (elems.len == 0) {
        try self.err(self.file.exprs.mainTok(e), .E0326, "", .{});
        return poison;
    }
    // §4.2.13 "the operands shall be evaluated exactly once, even if the
    // replication constant is zero": `foldBitConcat`'s shape — zero groups,
    // then the sized value their width-zero operands left untouched.
    const last = elems[elems.len - 1];
    if (!repl and elems.len > 1 and ex.tag(last) == .int_literal and ex.intLiteral(last).width != 0) {
        for (elems[0 .. elems.len - 1]) |g| {
            if (ex.tag(g) != .multi_concat) break;
        } else {
            for (elems[0 .. elems.len - 1]) |g| for (ex.args(ex.rhs(g))) |op| {
                _ = try lowerExpr(self, op);
            };
            return lowerExpr(self, last);
        }
    }
    var copies: i64 = 1;
    // §3.3 Table 3-3's nonconstant multiplier, as its integer Value.
    var runtime_count: ?Mir.Value = null;
    if (repl) count: {
        const count = ex.lhs(e);
        const c = try lowerExpr(self, count);
        const k: ?Const = switch (self.mir.valueDef(c.v)) {
            .int_const => |n| .{ .int = n },
            .float_const => |f| .{ .real = f },
            // A constant expression the SSA left as arithmetic (`1.0 + 1.5`)
            // still folds, and so does one over parameters: the count sizes
            // the result, so a parameter in it is a SHAPE parameter (§3.4 —
            // fixed at compilation, `checkShape` refuses a card that moves it).
            .undef, .str_const, .param_ref, .block_param, .inst_result => lower_constfold.shapeEval(self, count),
        };
        const v = k orelse Const{ .str = "" };
        if (v == .str) {
            // A multiplier that survives to the residual is the row's
            // nonconstant case, which "must be of integral type": the §4.2.1
            // real-to-integer conversion below is a constant's.
            if (c.ty != .integer) {
                try self.err(self.file.exprs.mainTok(count), .E0327, "a nonconstant replication multiplier shall be of integral type, got {s}", .{@tagName(c.ty)});
                return poison;
            }
            runtime_count = c.v;
            break :count;
        }
        // §4.2.1: a real replication factor "will first be converted to an
        // integer value using the rules described in 4.2.1.1". A real with no
        // nearest integer (inf, NaN, past i64) yields no count.
        copies = v.asIntExact() orelse {
            try self.err(self.file.exprs.mainTok(count), .E0327, "a replication constant shall be a finite integer after conversion, got {d}", .{v.asReal()});
            return poison;
        };
        // §4.2.13: the replication constant is "non-negative, non-x and
        // non-z". Zero is legal and yields the empty string.
        if (copies < 0) {
            try self.err(self.file.exprs.mainTok(ex.lhs(e)), .E0327, "a replication constant shall be non-negative, got {d}", .{copies});
            return poison;
        }
    }
    // `out` is the current run of constant operands; `parts` holds the
    // run-time operands and the folded runs between them, in source order.
    var out: std.ArrayList(u8) = .empty;
    var parts: std.ArrayList(Mir.Value) = .empty;
    for (elems, 0..) |el, i| {
        const tv = try lowerExpr(self, el);
        if (i == 0 and tv.ty == .integer and runtime_count == null) return intCallConcat(self, e, elems, copies, tv);
        if (tv.ty != .string) {
            try self.err(self.file.exprs.mainTok(e), .E0327, "only sized constants and strings can be concatenated", .{});
            return poison;
        }
        switch (self.mir.valueDef(tv.v)) {
            .str_const => |s| try out.appendSlice(self.arena, s),
            .undef, .float_const, .int_const, .param_ref, .block_param, .inst_result => {
                if (out.items.len != 0)
                    try parts.append(self.arena, try self.mir.addStrConst(self.arena, try out.toOwnedSlice(self.arena)));
                try parts.append(self.arena, tv.v);
            },
        }
    }
    if (parts.items.len != 0 or runtime_count != null) {
        self.out.uses.insert(.str_tasks);
        if (out.items.len != 0 or parts.items.len == 0)
            try parts.append(self.arena, try self.mir.addStrConst(self.arena, try out.toOwnedSlice(self.arena)));
        const str = if (parts.items.len == 1) parts.items[0] else try self.call("$str$cat", parts.items);
        const n = runtime_count orelse
            if (copies == 1) return .{ .v = str, .ty = .string } else try self.mir.addIntConst(self.arena, copies);
        return .{ .v = try self.call("$str$repeat", &.{ n, str }), .ty = .string };
    }
    if (repl) {
        // Past 4096 bytes the copies are made while the device runs, into a
        // row sized for them (`cg_strcap`), rather than spelled out in the
        // device's source: the text is as long as the copies make it, and
        // memory is the only bound (#29).
        if (@as(u128, @intCast(copies)) * out.items.len > 4096) {
            self.out.uses.insert(.str_tasks);
            const one = try self.mir.addStrConst(self.arena, try out.toOwnedSlice(self.arena));
            return .{ .v = try self.call("$str$repeat", &.{ try self.mir.addIntConst(self.arena, copies), one }), .ty = .string };
        }
        // N copies of "" are "", and are not counted out, so `{1e15{""}}`
        // does not spin for the count alone.
        if (out.items.len != 0) {
            const one = try self.arena.dupe(u8, out.items);
            out.clearRetainingCapacity();
            for (0..@intCast(copies)) |_| try out.appendSlice(self.arena, one);
        }
    }
    // The interner borrows: the bytes live in the arena, which outlives the Mir.
    return .{ .v = try self.mir.addStrConst(self.arena, try out.toOwnedSlice(self.arena)), .ty = .string };
}

/// §4.2.13's integer form over integer function calls, the operands the
/// parser cannot fold but whose width the declaration fixes: an
/// `analog_function_type` `integer` (§4.7.1) is 32 bits (§3.2). `first` is
/// `elems[0]` already lowered. §4.2.13 `result = {4{func(w)}}` "would be
/// computed as: y = func(w); result = {y, y, y, y}", so each operand is
/// evaluated once however many `copies` there are. Every operand is 32 bits
/// wide, so the integer the result is held in is its low 32: the last one.
fn intCallConcat(self: *Lower, e: Ast.ExprId, elems: []const Ast.ExprId, copies: i64, first: TypedValue) Oom!TypedValue {
    const ex = &self.file.exprs;
    var last = first;
    for (elems, 0..) |el, i| {
        const tv = if (i == 0) first else try lowerExpr(self, el);
        if (tv.ty != .integer or ex.tag(el) != .call) {
            try self.err(ex.mainTok(e), .E0327, "only sized constants, strings and integer function calls can be concatenated", .{});
            return poison;
        }
        last = tv;
    }
    // §4.2.13: a zero replication "shall appear only within a concatenation
    // in which at least one of the operands of the concatenation has a
    // positive size"; alone it has no width and no value.
    if (copies == 0) {
        try self.err(ex.mainTok(e), .E0326, "", .{});
        return poison;
    }
    return last;
}

/// The Value of one scalarized element — a variable array (§3.2.2) or a
/// parameter array (§3.4.4).
pub fn arrayElemValue(self: *Lower, name: []const u8, idx: []const i64) Oom!?TypedValue {
    try lower_event.captureTimerArray(self, name);
    if (self.arrays.get(name)) |info| if (info.mem) |m| return .{
        .v = try lower_var.loadElem(self, m, info.ty, try self.mir.addIntConst(self.arena, lower_shape.flatIndex(info.dims, idx))),
        .ty = info.ty,
    };
    var key_buf: [lower_shape.elem_key_len]u8 = undefined;
    const key = try lower_shape.elemKey(self, &key_buf, name, idx);
    if (self.vars.get(key)) |slot|
        return .{ .v = try lower_var.analogRead(self, try self.builder.readVariable(slot.place, self.cur), slot.reg_width), .ty = slot.ty };
    if (self.param_index.get(key)) |pi|
        return .{ .v = self.param_values.items[pi], .ty = astTy(self.out.params.items[pi].ty) };
    return null;
}

/// Returns the flat spelling of a §6.7 `.hier_ident` path: its parts joined by
/// `Elaborate.sep`. Flattening renamed each child entity to `path.name`, so
/// this string is the name the flat design carries.
///
/// Allocates the result in `self.arena` on every call.
pub fn flatName(self: *Lower, e: Ast.ExprId) Oom![]const u8 {
    const path = try Elaborate.flatReference(self.file, self.arena, self.module, e);
    if (self.scope_path.len != 0) if (try inScope(self, path)) |hit| return hit;
    // The one place the join is NOT the answer: a child port bound to a parent
    // net is the same signal as that net, so `u.a` denotes `p` and there is no
    // `u.a` to find. `Design.names` holds those aliases and nothing else.
    return self.out.hier_names.get(path) orelse path;
}

/// §6.6.2: a generate block's declarations can be referenced hierarchically
/// "from within the hierarchy instantiated by the generate block itself",
/// and §6.8 (IEEE 1364-2005 12.7) searches a name "first at the current level
/// and then in higher level modules". Inside a generate block (`scope_path`,
/// its §6.6.3 name included for an unnamed one) `u1.gain` is first the
/// block's own `u1`, which the flatten named `genblk1.u1`: the innermost
/// enclosing scope whose prefix makes `path` name something, or null.
fn inScope(self: *Lower, path: []const u8) Oom!?[]const u8 {
    const unit = if (self.cur_unit < self.unit_paths.len) self.unit_paths[self.cur_unit].path else "";
    var scope = self.scope_path;
    while (scope.len != 0) {
        const cand = try self.arena.print("{s}{s}{c}{s}", .{ unit, scope, Elaborate.sep, path });
        const flat = self.out.hier_names.get(cand) orelse cand;
        if (self.param_index.contains(flat) or self.vars.contains(flat) or self.consts.contains(flat) or
            self.node_voltages.contains(flat) or self.branches.contains(flat) or self.port_branches.contains(flat))
            return flat;
        scope = scope[0 .. std.mem.findScalarLast(u8, scope, Elaborate.sep) orelse 0];
    }
    return null;
}

/// §6.6.2 the unnamed generate block whose flat prefix the hierarchical name
/// `e` spells its way into from outside, or null. "Outside" is the unit that
/// wrote `e`: a unit instantiated inside the block is "within the hierarchy
/// instantiated by the generate block itself" and may name what it holds.
pub fn unnamedGenScope(self: *Lower, e: Ast.ExprId) Oom!?[]const u8 {
    const scopes = self.unnamed_gen orelse blk: {
        var out: std.ArrayList([]const u8) = .empty;
        // A tree of one has no unit table; its module is the source's own.
        if (self.unit_paths.len == 0) {
            if (self.module) |m| try Elaborate.unnamedGenScopes(self.file, self.arena, m, "", &out);
        } else for (self.unit_paths) |u| try Elaborate.unnamedGenScopes(self.file, self.arena, u.decl, u.path, &out);
        self.unnamed_gen = out.items;
        break :blk out.items;
    };
    if (scopes.len == 0) return null;
    const path = try Elaborate.flatReference(self.file, self.arena, self.module, e);
    const own = if (self.cur_unit < self.unit_paths.len) self.unit_paths[self.cur_unit].path else "";
    for (scopes) |s| if (std.mem.startsWith(u8, path, s) and !std.mem.startsWith(u8, own, s)) return s;
    return null;
}

/// Reports E0998 when `e` names something inside an unnamed generate block
/// from outside it (§6.6.2, §6.6.1; §6.6.3 "has no name that can be used in
/// a hierarchical name"), and returns whether it did.
pub fn refuseUnnamedGen(self: *Lower, e: Ast.ExprId) Oom!bool {
    const scope = try unnamedGenScope(self, e) orelse return false;
    var b = self.errWith(self.file.exprs.mainTok(e), .E0998);
    b.msg("`{s}` reaches into `{s}`, an unnamed generate block", .{
        try Elaborate.flatReference(self.file, self.arena, self.module, e), scope[0 .. scope.len - 1],
    });
    b.help("name the block (`begin : g`) and reach it as `g.<item>`", .{});
    try b.emit();
    return true;
}

/// §2.8 name resolution: variables (§3.2) shadow parameters (§3.4), which
/// shadow genvars (§3.5). Nets are NOT values — they are only reachable
/// through an access function (§4.4).
/// §6.7 hierarchical reads pass the dotted path joined by `flatName`.
fn lookupName(self: *Lower, e: Ast.ExprId, name: []const u8) Oom!TypedValue {
    // §8.5.3.6 a digital read under an explicit D2A event is the region-1b value.
    if (self.in_d2a_body and self.out.discrete_snaps.contains(name)) {
        const idx = self.param_index.get(try naming.snapField(self.arena, name)).?;
        return .{ .v = self.param_values.items[idx], .ty = astTy(self.out.params.items[idx].ty) };
    }
    if (self.vars.get(name)) |slot|
        // A wide `reg` read whole is a Table 7-1 grouping past 31 bits (E0222).
        return .{ .v = try lower_var.analogRead(self, try self.builder.readVariable(slot.place, self.cur), slot.reg_width), .ty = if (slot.ty == .wide) .integer else slot.ty };
    // §4.7.2/§6.8: inside a function body, a function-local `parameter` of the
    // same name shadows the module's, so `param_index` is masked and the local
    // value is found in `consts` (where `inlineUserFuncPre` folded it).
    if (!funcParamShadows(self, name)) if (self.param_index.get(name)) |idx|
        return .{ .v = self.param_values.items[idx], .ty = astTy(self.out.params.items[idx].ty) };
    if (self.consts.get(name)) |c| return switch (c) {
        .int => .{ .v = try self.mir.addIntConst(self.arena, c.asInt()), .ty = .integer },
        .real => .{ .v = try self.mir.addFloatConst(self.arena, c.asReal()), .ty = .real },
        .str => |s| .{ .v = try self.mir.addStrConst(self.arena, s), .ty = .string },
    };
    if (self.node_voltages.contains(name)) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0315);
        b.msg("`{s}`", .{name});
        b.help("probe it: `V({s})` or `I({s})`", .{ name, name });
        try b.emit();
        return poison;
    }
    var b = self.errWith(self.file.exprs.mainTok(e), .E0314);
    b.msg("`{s}`", .{name});
    const near = diag.didYouMeanMap(name, self.vars) orelse
        diag.didYouMeanMap(name, self.param_index) orelse
        diag.didYouMeanMap(name, self.node_voltages) orelse
        diag.didYouMeanMap(name, self.branches);
    if (near) |s| b.suggestHere(s);
    try b.emit();
    return poison;
}

/// §4.7.2/§6.8: does the function currently being inlined declare `name` as a
/// local parameter? True makes the local (in `consts`) win over a module
/// parameter of the same name — the shadowing §6.8's scope list requires.
pub fn funcParamShadows(self: *const Lower, name: []const u8) bool {
    for (self.func_params) |*p| {
        if (self.file.strings.eql(p.name, name)) return true;
    }
    return false;
}

/// A.8.6 unary operators. §4.2.3 (+/-), §4.2.7 (!), §4.2.9 (~).
fn lowerUnary(self: *Lower, e: Ast.ExprId, plan: ?constfold.IntPlan, sized: bool) Oom!TypedValue {
    const ex = &self.file.exprs;
    var a = try lowerOperand(self, ex.lhs(e), plan, sized, 0);
    switch (ex.unOp(e)) {
        .plus, .minus => if (a.ty == .string) {
            // §2.7: a literal is a number; §3.3 Table 3-3: a string-typed operand is not.
            if (ex.tag(ex.lhs(e)) != .str_literal) {
                try self.err(ex.mainTok(e), .E0321, "a string variable or parameter is not a number; §3.3 Table 3-3 gives it no arithmetic", .{});
                return poison;
            }
            a = try self.strNum(a);
        },
        .logical_not, .bit_not, .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => {},
    }
    switch (ex.unOp(e)) {
        .plus => return a,
        .minus => {
            // §4.2.3. Fold a literal here instead of emitting `ineg(3)`: the
            // §4.2.8 divisor proof (`integerIv`) has no transfer function for
            // `ineg`, so `11 % -3` would fail to prove its divisor non-zero
            // (E0601). A negative literal is a constant however it is spelled.
            switch (self.mir.valueDef(self.mir.resolveAlias(a.v))) {
                // §3.2 through the one constant kernel: -(-2^31) is -2^31.
                .int_const => |x| return .{ .v = try self.mir.addIntConst(self.arena, constfold.unary(.minus, .{ .int = x }).?.int), .ty = a.ty },
                .float_const => |x| return .{ .v = try self.mir.addFloatConst(self.arena, -x), .ty = a.ty },
                .undef, .str_const, .param_ref, .block_param, .inst_result => {},
            }
            return .{
                .v = try self.emit(if (a.ty == .real) .fneg else .ineg, &.{a.v}),
                .ty = a.ty,
            };
        },
        .logical_not => return .{ .v = try self.emit(.lognot, &.{try self.toBool(a)}), .ty = .integer },
        .bit_not => {
            if (a.ty != .integer) {
                try self.err(self.file.exprs.mainTok(e), .E0318, "`~` on a {s}", .{@tagName(a.ty)});
                return poison;
            }
            return .{ .v = try self.emit(.bitnot, &.{a.v}), .ty = .integer };
        },
        // §4.2.10, the whole clause: "The reduction operators can not be used
        // inside the analog block and only have meaning when used in the
        // digital context." There is no carve-out and no analog form.
        //
        // Unconditional: every expression lowering sees is in the analog
        // block (see `isDigitalOnlySysFunc`).
        .reduce_and, .reduce_nand, .reduce_or, .reduce_nor => {
            // §4.2.1 first: a real operand has no bits to fold at all, and
            // E0319 names the operand rather than the context.
            if (a.ty != .integer) {
                try self.err(self.file.exprs.mainTok(e), .E0319, "got a {s}", .{@tagName(a.ty)});
                return poison;
            }
            try self.err(self.file.exprs.mainTok(e), .E0348, "", .{});
            return poison;
        },
        // §4.2.10 xor reduction is a parity, which has no analog equivalent
        // and no MIR opcode.
        .reduce_xor, .reduce_xnor => {
            try self.err(self.file.exprs.mainTok(e), .E0320, "", .{});
            return poison;
        },
    }
}

/// §7.3.2 a four-state operand as its two planes (IEEE 1364 §5.1.8: z is value
/// 0 / unknown 1, x is 1 / 1): an x/z literal, or a discrete input read through
/// `===`/`!==`/`case` (`Lowered.discrete_xz`). Null for anything two-state.
const Planes = struct { value: Mir.Value, unknown: Mir.Value };
fn fourState(self: *Lower, e: Ast.ExprId) Oom!?Planes {
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .logic_literal => {
            const lit = ex.logicValue(e);
            if (lit.width > 63) return null; // the E0130 the ordinary lowering reports
            const value: i64 = lit.asInt() orelse @bitCast(lit.values()[0]);
            return .{
                .value = try self.mir.addIntConst(self.arena, value),
                .unknown = try self.mir.addIntConst(self.arena, @bitCast(lit.unknowns()[0])),
            };
        },
        .ident => {
            const name = self.file.str(ex.strOf(e));
            if (self.in_d2a_body or !self.out.discrete_xz.contains(name)) return null;
            const xz = self.param_index.get(try naming.xzField(self.arena, name)).?;
            return .{ .value = (try lookupName(self, e, name)).v, .unknown = self.param_values.items[xz] };
        },
        else => return null, // else: every other operand is two-state
    }
}

/// §7.3.2 / IEEE 1364 §5.1.8 `a === b` when either side is four-state: both
/// planes compare, and the result is never x. A two-state side has no unknown
/// bits. Null when neither side is four-state (the ordinary `==` path).
fn caseEquality(self: *Lower, l: Ast.ExprId, r: Ast.ExprId) Oom!?Mir.Value {
    const pl = try fourState(self, l);
    const pr = try fourState(self, r);
    if (pl == null and pr == null) return null;
    const a = pl orelse Planes{ .value = try twoState(self, l), .unknown = .zero };
    const b = pr orelse Planes{ .value = try twoState(self, r), .unknown = .zero };
    const same_value = try cmp(self, .eq, .{ .v = a.value, .ty = .integer }, .{ .v = b.value, .ty = .integer });
    const same_unknown = try cmp(self, .eq, .{ .v = a.unknown, .ty = .integer }, .{ .v = b.unknown, .ty = .integer });
    return try self.emit(.logand, &.{ same_value, same_unknown });
}

/// §7.3.2 "the case, casex, and casez statements": one case item against the
/// subject. `case` is `caseEquality`; IEEE 1364 §9.5.1 makes a z bit of
/// either side a don't-care under `casez`, and an x or z bit under `casex`.
/// Null when neither side is four-state: two-state operands have no
/// don't-care bits, so all three are `==`.
pub fn caseMatch(self: *Lower, kind: Ast.CaseKind, l: Ast.ExprId, r: Ast.ExprId) Oom!?Mir.Value {
    if (kind == .normal) return caseEquality(self, l, r);
    const pl = try fourState(self, l);
    const pr = try fourState(self, r);
    if (pl == null and pr == null) return null;
    const a = pl orelse Planes{ .value = try twoState(self, l), .unknown = .zero };
    const b = pr orelse Planes{ .value = try twoState(self, r), .unknown = .zero };
    // A z is value 0 / unknown 1 (`Planes`), so `unknown & ~value` is its bits.
    const dont_care = switch (kind) {
        .casex => try self.emit(.bitor, &.{ a.unknown, b.unknown }),
        .casez => try self.emit(.bitor, &.{
            try self.emit(.bitand, &.{ a.unknown, try self.emit(.bitnot, &.{a.value}) }),
            try self.emit(.bitand, &.{ b.unknown, try self.emit(.bitnot, &.{b.value}) }),
        }),
        .normal => unreachable,
    };
    const diff = try self.emit(.bitor, &.{ try self.emit(.bitxor, &.{ a.value, b.value }), try self.emit(.bitxor, &.{ a.unknown, b.unknown }) });
    const masked = try self.emit(.bitand, &.{ diff, try self.emit(.bitnot, &.{dont_care}) });
    return try cmp(self, .eq, .{ .v = masked, .ty = .integer }, .{ .v = .zero, .ty = .integer });
}

/// §4.2.1 Table 4-2: `===` is not an operator on reals (E0369, as on the
/// two-state path).
fn twoState(self: *Lower, e: Ast.ExprId) Oom!Mir.Value {
    const tv = try lowerExpr(self, e);
    if (tv.ty != .real) return self.toInt(tv);
    var d = self.errWith(self.file.exprs.mainTok(e), .E0369);
    d.help("use `==`; for reals prefer `abs(a - b) < tol`", .{});
    try d.emit();
    return .zero;
}

/// A.8.6 binary operators. LRM Table 4-3 precedence is the parser's job; this
/// only picks the opcode family from the operand types (§4.2.1).
fn lowerBinary(self: *Lower, e: Ast.ExprId, plan: ?constfold.IntPlan, sized: bool) Oom!TypedValue {
    const ex = &self.file.exprs;
    const op = ex.binOp(e);
    // §4.2.7 && and || short-circuit: the rhs must not be evaluated when the
    // lhs already decides the result, so this needs real control flow.
    if (op == .logical_and or op == .logical_or) return lowerShortCircuit(self, e, op, plan, sized);

    // §3.3 Table 3-3: "If both operands are string literals, the operator is
    // the same Verilog equality operator as for integer types." Each literal
    // is its packed bytes (§2.6.3), NULs included, and the shorter is
    // zero-extended — which is byte equality once leading NULs are dropped.
    // The literal's LEXICAL bytes, because string storage removes NULs.
    const eq_op = op == .eq or op == .neq or op == .case_eq or op == .case_neq;
    if (eq_op and ex.tag(ex.lhs(e)) == .str_literal and ex.tag(ex.rhs(e)) == .str_literal) {
        const sa = (try lower_sysfunc.outputLiteral(self, ex.lhs(e))) orelse self.file.str(ex.strOf(ex.lhs(e)));
        const sb = (try lower_sysfunc.outputLiteral(self, ex.rhs(e))) orelse self.file.str(ex.strOf(ex.rhs(e)));
        const same = std.mem.eql(u8, std.mem.trimStart(u8, sa, "\x00"), std.mem.trimStart(u8, sb, "\x00"));
        const want_same = op == .eq or op == .case_eq;
        return .{ .v = if (same == want_same) .one else .zero, .ty = .integer };
    }
    if (op == .case_eq or op == .case_neq) if (try caseEquality(self, ex.lhs(e), ex.rhs(e))) |same|
        return .{ .v = if (op == .case_eq) same else try self.emit(.lognot, &.{same}), .ty = .integer };
    var a = try lowerOperand(self, ex.lhs(e), plan, sized, 0);
    var b = try lowerOperand(self, ex.rhs(e), plan, sized, 1);
    // §2.7 makes a string LITERAL an unsigned integer, so a MIXED pair with a
    // literal is arithmetic and not a string operation. Two strings stay
    // strings: Table 3-3's relational row is a string comparison and
    // `{a, " ", b}` is a concatenation, and both would be destroyed by
    // converting either side.
    if ((a.ty == .string) != (b.ty == .string)) {
        // A string-typed operand (variable, parameter, function result) is no
        // number: §3.3 Table 3-3 gives it only ==, !=, the relational operators,
        // concatenation and replication, each against another string or a
        // literal, and "A string cannot be assigned to an integral type". The
        // test is the expression's shape, as `numOperand`'s: a variable
        // assigned a literal carries the literal's constant and is still a string.
        const str_side = if (a.ty == .string) ex.lhs(e) else ex.rhs(e);
        if (ex.tag(str_side) != .str_literal) {
            const other = @tagName(if (a.ty == .string) b.ty else a.ty);
            switch (op) {
                .bit_and, .bit_or, .bit_xor, .bit_xnor, .shl, .shr, .ashl, .ashr => try self.err(ex.mainTok(e), .E0322, "got a string and {s}", .{other}),
                .add, .sub, .mul, .div, .mod, .pow => try self.err(ex.mainTok(e), .E0321, "a string variable or parameter is not a number; §3.3 Table 3-3 gives it no arithmetic", .{}),
                .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge => try self.err(ex.mainTok(e), .E0321, "§3.3 Table 3-3 compares a string only with a string or a string literal; the other operand is {s}", .{other}),
                .logical_and, .logical_or => unreachable, // `lowerShortCircuit` returned for both at the top
            }
            return poison;
        }
        a = try self.strNum(a);
        b = try self.strNum(b);
    }

    switch (op) {
        .add, .sub, .mul, .div, .mod => {
            const ty = unify(a.ty, b.ty);
            if (ty == .string) {
                try self.err(self.file.exprs.mainTok(e), .E0321, "", .{});
                return poison;
            }
            const real = ty == .real;
            const opc: Mir.Opcode = switch (op) {
                .add => if (real) .fadd else .iadd,
                .sub => if (real) .fsub else .isub,
                .mul => if (real) .fmul else .imul,
                .div => if (real) .fdiv else .idiv,
                .mod => if (real) .fmod else .imod,
                else => unreachable, // else: the enclosing prong admits only these five
            };
            const lv = if (real) try self.toReal(a) else a.v;
            const rv = if (real) try self.toReal(b) else b.v;
            const result = try self.emit(opc, &.{ lv, rv });
            if (opc == .imod and self.runtime_error_phase != .none) {
                const divisor = self.mir.valueDef(self.mir.resolveAlias(rv));
                // A literal nonzero divisor cannot fail. All other evaluated
                // remainders stay on the guarded effect chain (§4.2.3), even
                // if their assigned value is dead. The chain's numeric sum is
                // not observable; its dependencies and CFG edges are.
                if (divisor != .int_const or divisor.int_const == 0) {
                    const value = try self.toReal(.{ .v = result, .ty = .integer });
                    if (self.runtime_error_phase == .display) {
                        try lower_systask.chainCondDisplay(self, value);
                        return .{ .v = result, .ty = ty };
                    }
                    const place = try self.effectPlace();
                    const previous = try self.builder.readVariable(place, self.cur);
                    try self.builder.writeVariable(place, self.cur, try self.emit(.fadd, &.{ previous, value }));
                }
            }
            return .{ .v = result, .ty = ty };
        },
        // §4.2.1.3: "If either operand is real, the other operand is converted
        // to real" — so two integers stay integer, and `7/(2**k)` divides by
        // an integer. §4.3.1's `pow()` FUNCTION is the real-valued one.
        .pow => return if (a.ty == .integer and b.ty == .integer)
            .{ .v = try self.emit(.ipow, &.{ a.v, b.v }), .ty = .integer }
        else
            .{ .v = try self.emit(.pow, &.{ try self.toReal(a), try self.toReal(b) }), .ty = .real },
        .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge => {
            // §7.3.2 lists `===` and `!==` among the features the analog
            // context supports, and §4.2.6 defers their meaning to IEEE 1364
            // §5.1.8: x and z compare as bits. Every operand that reaches here
            // is two-state (an x/z literal is E0130, a four-state net read is
            // E0315), and on two-state bits the case operators ARE `==` and
            // `!=`. §4.2.1 still bars them from a real operand: Table 4-2, the
            // operators legal on reals, has no `===` or `!==`.
            const case = op == .case_eq or op == .case_neq;
            if (case and (a.ty == .real or b.ty == .real)) {
                var d = self.errWith(self.file.exprs.mainTok(e), .E0369);
                d.help("use `==`; for reals prefer `abs(a - b) < tol`", .{});
                try d.emit();
                return poison;
            }
            const op_cmp: Ast.BinaryOp = if (!case) op else if (op == .case_eq) .eq else .neq;
            if (sized and a.ty == .integer and b.ty == .integer) if (plan) |p| if (p.operands[0]) |c| {
                if (!c.signed and c.width == 64) {
                    a.v = try extendUnsigned(self, a.v, null, true);
                    b.v = try extendUnsigned(self, b.v, null, true);
                }
                return .{ .v = try cmp(self, op_cmp, a, b), .ty = .integer };
            };
            // §4.2.9's unsigned comparison: each operand zero-extended from
            // its own width. See `constfold.UnsignedCompare`.
            if (a.ty == .integer and b.ty == .integer) if (lower_constfold.unsignedCompare(self, e)) |u| {
                const az: TypedValue = .{ .v = try extendUnsigned(self, a.v, u.mask[0], u.flip), .ty = .integer };
                const bz: TypedValue = .{ .v = try extendUnsigned(self, b.v, u.mask[1], u.flip), .ty = .integer };
                return .{ .v = try cmp(self, op_cmp, az, bz), .ty = .integer };
            };
            return .{ .v = try cmp(self, op_cmp, a, b), .ty = .integer };
        },
        .bit_and, .bit_or, .bit_xor, .bit_xnor, .shl, .shr => {
            if (a.ty != .integer or b.ty != .integer) {
                try self.err(self.file.exprs.mainTok(e), .E0322, "got {s} and {s}", .{ @tagName(a.ty), @tagName(b.ty) });
                return poison;
            }
            // A logical right shift clears the sign extension before shifting
            // the source-width bit pattern; its result keeps the result type.
            if (sized and op == .shr) if (plan) |p| if (p.operands[0]) |c| {
                a.v = try resizeInt(self, a.v, .{ .width = c.width, .signed = false });
            };
            const opc: Mir.Opcode = switch (op) {
                .bit_and => .bitand,
                .bit_or => .bitor,
                .bit_xor => .bitxor,
                .bit_xnor => .bitxnor,
                .shl => .shl,
                .shr => .shr,
                else => unreachable, // else: the enclosing prong admits only these six
            };
            return .{ .v = try self.emit(opc, &.{ a.v, b.v }), .ty = .integer };
        },
        // §4.2.11 arithmetic shifts have no MIR opcode: a Verilog-A `integer`
        // is signed, so `<<<`/`>>>` would need a separate signed-shift op.
        .ashl, .ashr => {
            var d = self.errWith(self.file.exprs.mainTok(e), .E0324);
            d.help("use `<<` and `>>`", .{});
            try d.emit();
            return poison;
        },
        // `lowerShortCircuit` returned for both at the top.
        .logical_and, .logical_or => unreachable,
    }
}

/// `constfold.UnsignedCompare.extend` as MIR.
fn extendUnsigned(self: *Lower, v: Mir.Value, mask: ?i64, flip: bool) Oom!Mir.Value {
    var z = v;
    if (mask) |m| z = try self.emit(.bitand, &.{ z, try self.mir.addIntConst(self.arena, m) });
    if (flip) z = try self.emit(.bitxor, &.{ z, try self.mir.addIntConst(self.arena, std.math.minInt(i64)) });
    return z;
}

/// §4.2.4 relational / §4.2.5 equality — integer 0/1 result either way.
pub fn cmp(self: *Lower, op: Ast.BinaryOp, a: TypedValue, b: TypedValue) Oom!Mir.Value {
    const real = unify(a.ty, b.ty) == .real;
    const opc: Mir.Opcode = switch (op) {
        .eq => if (real) .feq else .ieq,
        .neq => if (real) .fne else .ine,
        .lt => if (real) .flt else .ilt,
        .le => if (real) .fle else .ile,
        .gt => if (real) .fgt else .igt,
        .ge => if (real) .fge else .ige,
        else => unreachable, // else: both callers pass a relational or `==`/`!=` operator
    };
    const lv = if (real) try self.toReal(a) else a.v;
    const rv = if (real) try self.toReal(b) else b.v;
    return self.emit(opc, &.{ lv, rv });
}

/// §4.2.3 names three short-circuiting operators, "&&, ||, and ?:", and says of
/// all three that "any side effects or runtime errors that would have occurred
/// due to evaluation of the short-circuited operand expression shall not occur";
/// §4.2.12 says the same from the value side, naming only the arm it selects.
/// So the arms are branches, not operands of a `select`: an inlined function
/// that writes an `inout` formal (§4.7.2.4) must not run in the arm that was not
/// chosen, and neither must a division the condition exists to guard.
///
/// The shape is `lowerShortCircuit`'s — one place, one phi at the join. The one
/// difference is the type: `&&` is integer by definition, while §4.2.1 makes a
/// ternary's type the unification of both arms, and neither arm's type is known
/// until it has been lowered. So the then-arm is left unterminated while the
/// else-arm is lowered, and both are finished afterwards, once `ty` is settled
/// and the `.itof` each arm may need can still be emitted before its jump.
/// Nothing between the two reads the then-arm's terminator: the SSA builder
/// walks predecessors, and the else-arm has none of the then-arm's blocks.
fn lowerTernary(self: *Lower, e: Ast.ExprId, plan: ?constfold.IntPlan, sized: bool) Oom!TypedValue {
    const ex = &self.file.exprs;
    const cond = ex.lhs(e);
    const c = try self.toBool(try lowerOperand(self, cond, plan, sized, 0));

    // §4.5.15 "Analog operators shall not be used inside conditional (if, case,
    // or ?:) statements unless the conditional expression controlling the
    // statement consists of terms which can not change their value during the
    // course of a simulation." `?:` is in that list because an operator in an
    // arm loses its history on every step the arm is off. The two counters
    // `lowerCondBody` raises for an `if` body are raised here too, so E0514 in
    // `lowerFilter` sees it.
    const static = lower_control.isAnalysisOrConst(self, cond) or try lower_control.isStaticValue(self, c);
    self.cond_depth += 1;
    self.static_cond_depth += @intFromBool(static);
    defer {
        self.cond_depth -= 1;
        self.static_cond_depth -= @intFromBool(static);
    }

    const then_b = try self.mir.addBlock(self.arena);
    const else_b = try self.mir.addBlock(self.arena);
    const join = try self.mir.addBlock(self.arena);
    try self.branchTo(c, then_b, else_b, true);

    const pure = lower_control.isAnalysisOrConst(self, cond);
    self.cur = then_b;
    try lower_hier_name.pushCond(self, .{ .e = cond, .pol = true, .pure = pure });
    const t = try lowerOperand(self, ex.rhs(e), plan, sized, 1);
    lower_hier_name.popCond(self);
    const then_end = self.cur; // an arm may have branched on its own (`&&`, a nested `?:`)

    self.cur = else_b;
    try lower_hier_name.pushCond(self, .{ .e = cond, .pol = false, .pure = pure });
    const f = try lowerOperand(self, ex.ternaryElse(e), plan, sized, 2);
    lower_hier_name.popCond(self);
    const else_end = self.cur;

    const ty = unify(t.ty, f.ty);
    const place = self.builder.newPlace();
    try self.builder.writeVariable(place, else_end, if (ty == .real) try self.toReal(f) else f.v);
    try self.gotoBlock(join);

    self.cur = then_end;
    try self.builder.writeVariable(place, then_end, if (ty == .real) try self.toReal(t) else t.v);
    try self.gotoBlock(join);

    try self.builder.sealBlock(join);
    self.cur = join;
    return .{ .v = try self.builder.readVariable(place, join), .ty = ty };
}

/// §4.5.15 "It is important to ensure that all analog operators are evaluated
/// every iteration of a simulation to ensure that the internal state is
/// maintained." Whether this subtree holds one of the operators that rule protects.
/// `ddx` and `limexp` are the clause's own exceptions (see `isHistoryless`).
///
/// ponytail: syntactic, and it does not look inside a §4.7 analog function
/// body. An operator there is already E0422; if one becomes legal, compute a
/// per-function flag when the function lowers.
fn hasStatefulOp(self: *const Lower, e: Ast.ExprId) bool {
    if (e == .none) return false;
    const ex = &self.file.exprs;
    const tag = ex.tag(e);
    if (tag == .filter_call and !lower_analog_op.isHistoryless(self.file.str(ex.strOf(e)))) return true;
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (hasStatefulOp(self, c)) return true;
    return false;
}

/// §4.2.7 `&&` / `||` with LRM short-circuit evaluation. The rhs gets its own
/// block, so a guard like `(x != 0) && (1/x > k)` never divides by zero.
fn lowerShortCircuit(self: *Lower, e: Ast.ExprId, op: Ast.BinaryOp, plan: ?constfold.IntPlan, sized: bool) Oom!TypedValue {
    const ex = &self.file.exprs;
    // §4.5.15's evaluate-every-iteration rule wins over §4.2.7's skip when the
    // rhs holds an analog operator: a skipped step would feed that operator the
    // branch-local zero, and its state would go "out-of-date" as the clause
    // warns. §4.2.3's "any side effects ... shall not occur" is about side
    // effects and runtime errors, and advancing a required operator is neither.
    // §4.5.15's restriction names only `if`, `case` and `?:`, so this spelling
    // is legal and not diagnosed.
    if (hasStatefulOp(self, ex.rhs(e))) {
        const l = try self.toBool(try lowerOperand(self, ex.lhs(e), plan, sized, 0));
        const r = try self.toBool(try lowerOperand(self, ex.rhs(e), plan, sized, 1));
        // `toBool` normalises both to 0/1, so max is `||` and min is `&&`.
        return .{
            .v = try self.emit(if (op == .logical_and) .imin else .imax, &.{ l, r }),
            .ty = .integer,
        };
    }
    const a = try self.toBool(try lowerOperand(self, ex.lhs(e), plan, sized, 0));
    const place = self.builder.newPlace();
    try self.builder.writeVariable(place, self.cur, a);

    const rhs_b = try self.mir.addBlock(self.arena);
    const join = try self.mir.addBlock(self.arena);
    // `a && b` evaluates b only when a is true; `a || b` only when a is false.
    if (op == .logical_and) {
        _ = try self.mir.emitBranch(self.arena, self.cur, a, rhs_b, join);
    } else {
        _ = try self.mir.emitBranch(self.arena, self.cur, a, join, rhs_b);
    }
    try self.builder.addPredecessor(rhs_b, self.cur);
    try self.builder.addPredecessor(join, self.cur);
    try self.builder.sealBlock(rhs_b);

    self.cur = rhs_b;
    const b = try self.toBool(try lowerOperand(self, ex.rhs(e), plan, sized, 1));
    try self.builder.writeVariable(place, self.cur, b);
    try self.gotoBlock(join);

    try self.builder.sealBlock(join);
    self.cur = join;
    return .{ .v = try self.builder.readVariable(place, join), .ty = .integer };
}

/// §4.4.1 access function: `V(a)`, `V(a,b)`, `I(br)`.
/// A potential is the difference of two node unknowns; a flow that is *read*
/// makes the branch current an unknown of its own (§5.4.2).
fn lowerBranchAccess(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    if (self.restrict) |ctx| {
        try self.err(self.file.exprs.mainTok(e), .E0421, "not allowed in {s}", .{ctx});
        return poison;
    }
    // VerA's `vera_timepoint` (§2.9): a probe is the iterate.
    if (self.tp_cur != null) {
        try self.err(self.file.exprs.mainTok(e), .E0530, "a probe (§4.4)", .{});
        return poison;
    }
    // §3.12.1: a port branch names the §5.4.3 port flow, so `I(pb)` and
    // `I(<p>)` are one quantity and read the one unknown. Ahead of `branchOf`
    // because the name is not in `branches` and would otherwise fall through to
    // `nodeOf` and become an implicit net.
    if (try lower_contrib.portBranchOf(self, e)) |p| return portFlowRead(self, e, p);
    const t = try lower_contrib.branchOf(self, e) orelse return poison;
    try self.branch_reads.append(self.arena, .{
        .access = t.access,
        .hi = t.hi,
        .lo = t.lo,
        .tok = self.file.exprs.mainTok(e),
    });
    // §1.3.1.2: the reversed spelling of a branch is the same quantity with the
    // opposite sign. For the potential that is just which way the subtraction
    // runs; for the flow it is the whole point — `t` has already been
    // canonicalised, so `I(n,p)` reads the ONE `flow(p,n)` unknown negated
    // instead of minting a second, independent one that nothing constrains.
    switch (t.access) {
        .potential => {
            // §9.20 through `aliasProbe`: a parameter may choose the node.
            const hi = try lower_hier_name.aliasProbe(self, t.hi);
            if (t.lo == ground)
                return .{ .v = if (t.neg) try self.emit(.fneg, &.{hi}) else hi, .ty = .real };
            const lo = try lower_hier_name.aliasProbe(self, t.lo);
            const d = if (t.neg) [2]Mir.Value{ lo, hi } else [2]Mir.Value{ hi, lo };
            return .{ .v = try self.emit(.fsub, &d), .ty = .real };
        },
        .flow => {
            try lower_hier_name.refuseRuntime(self, self.file.exprs.mainTok(e), t.hi, t.lo);
            // §5.4.2.2 "Both the potential and the flow of a source branch are
            // accessible in expressions anywhere in the module." A flow
            // source's branch flow has no row pinning an unknown, so the read
            // is the value retained on the branch (§5.6.1.2): the accumulator
            // at `self.cur`. An ordinary expression reads mid-block and sees
            // sequential retention; a §9.4 display operand is lowered from
            // `lowerDeferredDisplays` past the whole block and sees the
            // converged end-of-cycle value, retention-select phis included.
            //
            // §5.6.6 first: inside a `<+`'s own right-hand side, a read of the
            // same branch is the implicit form, whose value is the branch-flow
            // unknown, never the retained prefix. Checked ahead of `flowAccum`
            // because `contribIndex` has already created the statement's own
            // entry. Codegen's `FreeFlow` row defines the unknown,
            // `x[u] − Σ contributions = 0`, like `portFlowRead`'s for `I(<p>)`.
            const implicit = if (self.contrib_target) |ct|
                ct.access == .flow and ct.hi == t.hi and ct.lo == t.lo and ct.br == t.br
            else
                false;
            // Only once a flow contribution has already been lowered onto this
            // pair. An uncontributed branch is a §5.4.2.1 flow probe, and a
            // potential source's branch current is pinned by its branch row;
            // both read the unknown, including §5.6.8.1's hierarchical case
            // (`potentialSourceHere`).
            if (!implicit and !potentialSourceHere(self, t)) if (flowAccum(self, t)) |acc| {
                // §5.6.1.2: the retained value of a source branch is the whole
                // of what was contributed to it, reactive half included.
                //
                // The reactive half is retained as a charge, so reading the
                // flow back differentiates it again with a second `ddt`
                // instance of its own. Only when there is a reactive half: a
                // resistive branch emits no operator and cannot trip §5.8.1's
                // conditional-operator rule.
                const r = try self.builder.readVariable(acc.resist, self.cur);
                const q = try self.builder.readVariable(acc.react, self.cur);
                const v = if (q == .f_zero) r else blk: {
                    // The charge's own sites already carry its truncation check.
                    const dq = try lower_analog_op.opDdt(self, self.file.exprs.mainTok(e), q, flowAbstol(self, t.hi), false);
                    break :blk if (r == .f_zero) dq else try self.emit(.fadd, &.{ r, dq });
                };
                return .{ .v = if (t.neg) try self.emit(.fneg, &.{v}) else v, .ty = .real };
            };
            const u = try lower_node.flowUnknown(self, t.hi, t.lo);
            const v = try lower_node.probe(self, u);
            return .{ .v = if (t.neg) try self.emit(.fneg, &.{v}) else v, .ty = .real };
        },
    }
}

/// The §5.6.1.2 retained-flow accumulator of the branch (hi, lo), if a `<+` has
/// already made it a flow source. Keyed exactly like `contribIndex` — on the
/// canonicalised pair, so `I(n,p)` finds the one entry `I(p,n)` created.
///
/// Not keyed on the unit, unlike `discardOpposite`: §5.5.5 lets "a module
/// access the potential and flow of a branch in another module instance ...
/// providing that value is available in the other instance", and a hierarchical
/// `I(x1.p, x1.n)` is exactly that read. §5.5.4's new-branch rule is about the
/// access functions whose examples are all POTENTIAL probes, which draw no flow
/// — see `potentialSourceHere` for the case where this unit's OWN source is the
/// branch being read.
fn flowAccum(self: *const Lower, t: lower_contrib.Target) ?Accum {
    const i = lower_contrib.directRow(self, .{ .access = .flow, .hi = t.hi, .lo = t.lo, .br = t.br }) orelse return null;
    // §5.6.8.2/§6.7.1 an instance's own unnamed branch, when several share
    // the row. An instance that contributed nothing to the pair reads the
    // row, as a parent reading its child's flow always has.
    if (self.out.contributions.items[i].shared and t.br == Lower.unnamed_branch)
        if (self.unit_accum.get(.{ .row = i, .unit = t.unit })) |pa| return pa;
    return self.accum.items[i];
}

/// §3.6.1.2 the flow tolerance of the discipline at node `n`, which is what
/// codegen's `abstolOf` gives a branch current; annex D's 1e-12 without one.
fn flowAbstol(self: *const Lower, n: u32) f64 {
    if (n == ground) return 1e-12;
    const info = self.out.disciplines.get(self.out.nodes.items(.disc)[n]) orelse return 1e-12;
    return info.flow_abstol;
}

/// §5.6.8.1: "Direct contribution statements can contribute to a branch between
/// combinations of local and hierarchical nets. In these cases, a new unnamed
/// branch is created in the module containing the direct contribution
/// statements." So a potential `<+` written here is a source branch of this
/// instance, in parallel with whatever another instance retained over the same
/// node pair: §5.4.1's "only one unnamed branch between any two nets" is a
/// per-instance rule, and flattening has already collapsed the pairs.
///
/// The flow of that source is the branch-current unknown codegen pins with its
/// branch row, never the parallel branch's accumulator, which would read back
/// the child's conduction current.
///
/// `unit` is the id of the contribution that opened the entry (see its doc), so
/// a second instance potential-sourcing a pair another already sources reads the
/// accumulator instead — two ideal potential sources in parallel is a degenerate
/// topology the clause does not describe either way.
fn potentialSourceHere(self: *const Lower, t: lower_contrib.Target) bool {
    for (self.out.contributions.items) |c| {
        if (c.kind == .direct and c.access == .potential and c.hi == t.hi and c.lo == t.lo and
            c.br == t.br and c.unit == self.cur_unit) return true;
    }
    return false;
}

/// LRM §5.4.3 port access — `I(<p>)`.
///
/// "The port access function accesses the flow into a port of a module. ...
/// However (<>) is used to delimit the port name, e.g., I(<a>) accesses the
/// current through module port a."
///
/// By KCL that current is the sum of everything this module stamps at `p`, the
/// residual codegen is assembling, so it cannot be an expression over the other
/// units without a cycle. It becomes its own solver unknown, like the §5.4.2
/// branch-flow unknown, and codegen pins it with the row `x[u] − Σ stamps at p`.
fn lowerPortAccess(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    if (self.restrict) |ctx| {
        try self.err(self.file.exprs.mainTok(e), .E0421, "not allowed in {s}", .{ctx});
        return poison;
    }
    // VerA's `vera_timepoint` (§2.9): a probe is the iterate.
    if (self.tp_cur != null) {
        try self.err(self.file.exprs.mainTok(e), .E0530, "a probe (§4.4)", .{});
        return poison;
    }
    if (try instancePortFlow(self, e)) |tv| return tv;
    const p = try nodeUnrefused(self, self.file.exprs.lhs(e)) orelse return poison;
    return portFlowRead(self, e, p);
}

/// `nodeOf`, or null when it refused the terminal (E0351/E0352). It stands
/// ground in for a refused one, and ground is no port: a caller that went on
/// would report the same mistake a second time, as E0508.
fn nodeUnrefused(self: *Lower, e: Ast.ExprId) Oom!?u32 {
    const had = self.had_error;
    self.had_error = false;
    const p = try lower_node.nodeOf(self, e);
    const refused = self.had_error;
    self.had_error = had or refused;
    return if (refused) null else p;
}

/// §5.4.3 "The port access function accesses the flow into a port of a
/// module", and A.8.9 lets the port be hierarchical
/// (`analog_port_reference ::= hierarchical_port_identifier`; §6.7.1 "flow
/// access for ... port branches can be done hierarchically"): `I(<u.p>)` is
/// the flow into instance `u` through its own port `p`, not the flow through
/// the net `p` is joined to. By KCL it is what `u`'s hierarchy conducts away
/// from that net: the sum of the flow contributions its units made to
/// branches touching the net, an instance's own share of a row several
/// instances share (`unit_accum`, §5.6.8.2), the reactive half through one
/// `ddt`. Null when `e`'s port is not hierarchical (the module's own port).
///
/// Read as a sum of accumulators, so every block of `u`'s hierarchy must be
/// lowered before the read, and every branch of it at the net must be a flow
/// source: a potential source's or an indirect branch's current is a solver
/// unknown whose static retention codegen decides. Either case is E0997.
fn instancePortFlow(self: *Lower, e: Ast.ExprId) Oom!?TypedValue {
    const ex = &self.file.exprs;
    const lhs = ex.lhs(e);
    if (ex.tag(lhs) != .hier_ident) return null;
    const path = try Elaborate.flatReference(self.file, self.arena, self.module, lhs);
    const cut = std.mem.findScalarLast(u8, path, Elaborate.sep) orelse return null;
    const inst = path[0 .. cut + 1];
    const units = self.unit_paths;
    const lo: u32 = for (units, 0..) |u, i| {
        if (std.mem.eql(u8, u.path, inst)) break @intCast(i);
    } else return null;
    // Units are numbered depth first, so `inst`'s hierarchy is one run.
    var hi = lo + 1;
    while (hi < units.len and std.mem.startsWith(u8, units[hi].path, inst)) hi += 1;
    const port_name = path[cut + 1 ..];
    const decl = units[lo].decl;
    for (decl.ports) |pt| {
        if (std.mem.eql(u8, self.file.str(pt.name), port_name)) break;
    } else {
        try self.err(ex.mainTok(e), .E0508, "`{s}` is not a port of `{s}`", .{ path, self.file.str(decl.name) });
        return poison;
    }
    const name = self.file.str(ex.strOf(e));
    const access = self.access_kind.get(name) orelse return null; // `portFlowRead` names it (E0501)
    if (access == .potential) return null; // and this (E0507)
    const p = try nodeUnrefused(self, lhs) orelse return poison;
    try lower_contrib.checkAccessMatch(self, e, name, access, p);
    // Every block of the hierarchy is behind this one.
    for (self.cur_block..self.module.?.analog.len) |j| {
        const unit = self.module.?.analog[j].unit;
        if (unit < lo or unit >= hi) continue;
        var b = self.errWith(ex.mainTok(e), .E0997);
        b.msg("`{s}(<{s}>)` is read before `{s}`'s own analog blocks are lowered", .{ name, path, inst[0 .. inst.len - 1] });
        b.note("VerA sums the instance's contributions at the port; read it from a module instantiated above it, after it", .{});
        try b.emit();
        return poison;
    }
    var resist: Mir.Value = .f_zero;
    var react: Mir.Value = .f_zero;
    for (self.out.contributions.items, self.accum.items, 0..) |c, acc, i| {
        if (c.hi != p and c.lo != p) continue;
        if (c.kind != .direct or c.access != .flow) {
            if (c.unit < lo or c.unit >= hi) continue;
            var b = self.errWith(ex.mainTok(e), .E0997);
            b.msg("`{s}` drives `{s}` through a {s}", .{ inst[0 .. inst.len - 1], path, if (c.kind != .direct) "§5.6.7 indirect branch" else "potential source" });
            b.note("that branch's current is a solver unknown; VerA sums only flow contributions at a hierarchical port", .{});
            try b.emit();
            return poison;
        }
        const neg = c.lo == p;
        if (c.shared) {
            for (lo..hi) |k| if (self.unit_accum.get(.{ .row = @intCast(i), .unit = @intCast(k) })) |pa| {
                resist = try addSigned(self, resist, try self.builder.readVariable(pa.resist, self.cur), neg);
                react = try addSigned(self, react, try self.builder.readVariable(pa.react, self.cur), neg);
            };
        } else if (c.unit >= lo and c.unit < hi) {
            resist = try addSigned(self, resist, try self.builder.readVariable(acc.resist, self.cur), neg);
            react = try addSigned(self, react, try self.builder.readVariable(acc.react, self.cur), neg);
        }
    }
    if (react != .f_zero) {
        // The charges' own sites already carry their truncation check.
        const dq = try lower_analog_op.opDdt(self, ex.mainTok(e), react, flowAbstol(self, p), false);
        resist = if (resist == .f_zero) dq else try self.emit(.fadd, &.{ resist, dq });
    }
    return .{ .v = resist, .ty = .real };
}

/// `acc ± v`, folding a zero on either side.
fn addSigned(self: *Lower, acc: Mir.Value, v: Mir.Value, neg: bool) Oom!Mir.Value {
    if (v == .f_zero) return acc;
    if (acc == .f_zero) return if (neg) try self.emit(.fneg, &.{v}) else v;
    return self.emit(if (neg) .fsub else .fadd, &.{ acc, v });
}

/// The read half of §5.4.3, shared by `I(<p>)` and by a §3.12.1 port branch
/// named over the same port: the two spellings are one quantity, so they must
/// be one unknown and one set of rules. `p` is the port's `nodes` row —
/// resolved by the caller, because the two spellings name it differently (an
/// argument expression here, a branch declaration there).
fn portFlowRead(self: *Lower, e: Ast.ExprId, p: u32) Oom!TypedValue {
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    const access = self.access_kind.get(name) orelse {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0501);
        b.msg("`{s}`", .{name});
        if (diag.didYouMeanMap(name, self.access_kind)) |s|
            b.suggestHere(s);
        try b.emit();
        return poison;
    };
    // §5.4.3 "The expression V(<a>) is invalid for ports and nets, where V is a
    // potential access function." A port access reads a FLOW, always.
    if (access == .potential) {
        try self.err(self.file.exprs.mainTok(e), .E0507, "`{s}` is a potential access function", .{name});
        return poison;
    }
    // §4.4.2 "For port access functions, the expression list is a single port
    // of the module"; §5.4.1 "it must be a declared port of the module in which
    // the port access function is used." An internal net has no outside, so its
    // port flow would be an identically-zero substitute — reject instead.
    if (p == ground or p >= self.out.num_ports) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0508);
        b.msg("`{s}(<{s}>)`", .{ name, lower_node.nodeName(self, p) });
        if (diag.didYouMeanMap(lower_node.nodeName(self, p), self.node_voltages)) |s|
            b.help("did you mean `{s}`?", .{s});
        try b.emit();
        return poison;
    }
    // §4.4 the name still has to be the port discipline's flow access.
    try lower_contrib.checkAccessMatch(self, e, name, access, p);
    return .{ .v = try lower_node.probe(self, try lower_node.portFlowUnknown(self, p)), .ty = .real };
}

// ---- §4.3 math functions (Tables 4-14 and 4-15) ----------------------------

/// LRM Table 4-14 §4.3.1 / Table 4-15 §4.3.2 — the real-valued one-argument
/// functions, by their LRM spelling. `log` is base 10 (`log10` in MIR).
pub fn unaryMathOp(name: []const u8) ?Mir.Opcode {
    return unary_math.get(name);
}

/// LRM Table 4-14 — the real-valued two-argument functions.
pub fn binaryMathOp(name: []const u8) ?Mir.Opcode {
    return binary_math.get(name);
}

// File-scope so `unknownCall` can offer `.keys()` as did-you-mean candidates:
// a misspelled built-in is the commonest way to reach E0512, and the LRM's own
// spelling is the answer.
const unary_math = std.StaticStringMap(Mir.Opcode).initComptime(.{
    .{ "sqrt", .sqrt },   .{ "exp", .exp },     .{ "expm1", .expm1 },
    .{ "ln", .ln },       .{ "ln1p", .ln1p },   .{ "log", .log10 },
    .{ "floor", .floor }, .{ "ceil", .ceil },   .{ "sin", .sin },
    .{ "cos", .cos },     .{ "tan", .tan },     .{ "asin", .asin },
    .{ "acos", .acos },   .{ "atan", .atan },   .{ "sinh", .sinh },
    .{ "cosh", .cosh },   .{ "tanh", .tanh },   .{ "asinh", .asinh },
    .{ "acosh", .acosh }, .{ "atanh", .atanh },
});

const binary_math = std.StaticStringMap(Mir.Opcode).initComptime(.{
    .{ "pow", .pow }, .{ "hypot", .hypot }, .{ "atan2", .atan2 },
});

/// Lowers a §4.3 built-in math call. `abs`/`min`/`max` keep integer operands integer
/// (§4.3.1: "if both operands are integer the result is integer").
pub fn lowerBuiltin(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const spelling = self.file.str(ex.strOf(e));
    const name = if (std.mem.startsWith(u8, spelling, "$")) spelling[1..] else spelling;
    const args = ex.args(e);

    if (unaryMathOp(name)) |op| {
        if (args.len != 1) return arityError(self, e, name, 1);
        const a = try numOperand(self, args[0]) orelse return poison;
        return .{ .v = try self.emit(op, &.{try self.toReal(a)}), .ty = .real };
    }
    if (binaryMathOp(name)) |op| {
        if (args.len != 2) return arityError(self, e, name, 2);
        const a = try numOperand(self, args[0]) orelse return poison;
        const b = try numOperand(self, args[1]) orelse return poison;
        return .{ .v = try self.emit(op, &.{ try self.toReal(a), try self.toReal(b) }), .ty = .real };
    }
    if (std.mem.eql(u8, name, "abs")) {
        if (args.len != 1) return arityError(self, e, name, 1);
        const a = try numOperand(self, args[0]) orelse return poison;
        const int = a.ty == .integer;
        return .{ .v = try self.emit(if (int) .iabs else .fabs, &.{a.v}), .ty = a.ty };
    }
    if (std.mem.eql(u8, name, "min") or std.mem.eql(u8, name, "max")) {
        if (args.len != 2) return arityError(self, e, name, 2);
        const a = try numOperand(self, args[0]) orelse return poison;
        const b = try numOperand(self, args[1]) orelse return poison;
        const ty = unify(a.ty, b.ty);
        const is_min = name[1] == 'i';
        const op: Mir.Opcode = if (ty == .real)
            (if (is_min) .fmin else .fmax)
        else
            (if (is_min) .imin else .imax);
        const lv = if (ty == .real) try self.toReal(a) else a.v;
        const rv = if (ty == .real) try self.toReal(b) else b.v;
        return .{ .v = try self.emit(op, &.{ lv, rv }), .ty = ty };
    }
    try unknownCall(self, e, name);
    return poison;
}

/// Lowers one §4.3 built-in operand: §4.3.1 "The operands shall be numeric
/// (integer or real)", §4.3.2 "All operands shall be numeric". A string
/// literal is one (§2.7: an unsigned integer constant); a string variable is
/// not (§3.3 Table 3-3 gives it no arithmetic), and is E0321 with null. The
/// test is the expression's shape: a variable assigned a literal carries the
/// literal's constant value, and is still a string.
fn numOperand(self: *Lower, arg: Ast.ExprId) Oom!?TypedValue {
    const tv = try lowerExpr(self, arg);
    if (tv.ty != .string) return tv;
    if (self.file.exprs.tag(arg) == .str_literal) return try self.strNum(tv);
    try self.err(self.file.exprs.mainTok(arg), .E0321, "a §4.3 math function operand shall be numeric (integer or real); this one is a string", .{});
    return null;
}

/// Reports E0512 with a suggestion drawn from everything that could have been
/// called here: the module's §4.7 analog functions and the §4.3 built-ins of
/// Tables 4-14/4-15, in one candidate list so the single nearest name wins.
pub fn unknownCall(self: *Lower, e: Ast.ExprId, name: []const u8) Oom!void {
    var b = self.errWith(self.file.exprs.mainTok(e), .E0512);
    b.msg("`{s}`", .{name});

    var names: std.ArrayList([]const u8) = .empty;
    if (self.module) |m| {
        for (m.functions) |*fd| try names.append(self.arena, self.file.str(fd.name));
    }
    try names.appendSlice(self.arena, unary_math.keys());
    try names.appendSlice(self.arena, binary_math.keys());
    // §3.13.2 access functions land here too: the parser routes `Vv(p,n)` to a
    // function call because `Vv` is not an access name, so `V` is the
    // answer far more often than any analog function is.
    var it = self.access_kind.keyIterator();
    while (it.next()) |k| try names.append(self.arena, k.*);
    if (diag.didYouMean(name, names.items)) |s| b.suggestHere(s);

    return b.emit();
}

/// Reports E0506 (`name` takes `want` arguments) and returns the poison value.
pub fn arityError(self: *Lower, e: Ast.ExprId, name: []const u8, want: usize) Oom!TypedValue {
    try self.err(self.file.exprs.mainTok(e), .E0506, "`{s}()` takes {d}", .{ name, want });
    return poison;
}

/// The declarations every expression case below reads.
const test_decls =
    \\  electrical q;
    \\  real r, y, y0;
    \\  integer k, j;
    \\  string s;
    \\  reg [7:0] rg;
    \\  parameter integer cnt = 2;
    \\  parameter integer neg = -1;
    \\  parameter integer big = 5000;
    \\  parameter real huge = 1e15;
;

test "lowerUnary/lowerBinary: §4.2 an operator takes only the operand types its table lists" {
    const cases = [_]struct { body: []const u8, want: ?diag.Code }{
        // §4.2.9 bitwise operators are integer operators.
        .{ .body = "    k = ~k;", .want = null },
        .{ .body = "    y = ~r;", .want = .E0318 },
        .{ .body = "    k = k & 3;", .want = null },
        .{ .body = "    y = r & 3;", .want = .E0322 },
        // §4.2.10 the reductions are digital only: E0319 on a real operand,
        // E0348 on an integer one, E0320 for the parity forms.
        .{ .body = "    k = &r;", .want = .E0319 },
        .{ .body = "    k = &k;", .want = .E0348 },
        .{ .body = "    k = ^k;", .want = .E0320 },
        // §4.2.11 the arithmetic shifts have no analog form.
        .{ .body = "    k = k <<< 1;", .want = .E0324 },
        // §4.2.1 Table 4-2 has no `===` on reals.
        .{ .body = "    k = (k === 1);", .want = null },
        .{ .body = "    k = (r === 1.0);", .want = .E0369 },
        // §2.7 a string literal is a number; §3.3 a string value is not.
        .{ .body = "    y = \"A\" + 1;", .want = null },
        .{ .body = "    y = -\"A\";", .want = null },
        .{ .body = "    y = s + 1;", .want = .E0321 },
        .{ .body = "    y = -s;", .want = .E0321 },
        .{ .body = "    k = (s == 1);", .want = .E0321 },
    };
    for (cases) |c| try Lower.expectBodyVerdict(test_decls, c.body, c.want);
}

test "lowerBuiltin: §4.3 math functions take numeric operands, as many as their table says" {
    const cases = [_]struct { body: []const u8, want: ?diag.Code }{
        .{ .body = "    y = hypot(3.0, 4.0) + atan2(1.0, 1.0) + log(10.0);", .want = null },
        .{ .body = "    k = abs(-3) + min(k, 2) + max(k, 4);", .want = null },
        .{ .body = "    y = sqrt(\"A\");", .want = null },
        .{ .body = "    y = sqrt(s);", .want = .E0321 },
        .{ .body = "    y = sqrt(1.0, 2.0);", .want = .E0506 },
        .{ .body = "    y = pow(1.0);", .want = .E0506 },
        .{ .body = "    y = abs(1.0, 2.0);", .want = .E0506 },
        .{ .body = "    y = min(1.0);", .want = .E0506 },
    };
    for (cases) |c| try Lower.expectBodyVerdict(test_decls, c.body, c.want);
}

test "lookupName/lowerIndex: §2.8 names and §3.2.2/§7.3.1 selects" {
    const cases = [_]struct { body: []const u8, want: ?diag.Code }{
        .{ .body = "    y = nosuch;", .want = .E0314 },
        // A net is no value; §4.4 reaches it through an access function.
        .{ .body = "    y = p;", .want = .E0315 },
        .{ .body = "    y = r[0];", .want = .E0309 },
        // §7.3.1 a constant bit- or part-select of a `reg`, inside its range.
        .{ .body = "    k = rg[3:0] + rg[7];", .want = null },
        .{ .body = "    k = rg[8];", .want = .E0310 },
        .{ .body = "    j = 1;\n    k = rg[j];", .want = .E0329 },
        .{ .body = "    j = 1;\n    k = rg[j +: 2];", .want = .E0329 },
    };
    for (cases) |c| try Lower.expectBodyVerdict(test_decls, c.body, c.want);
}

test "lowerConcat: §3.3 Table 3-3 string concatenation and replication" {
    const cases = [_]struct { body: []const u8, want: ?diag.Code }{
        .{ .body = "    s = {cnt{\"ab\"}};", .want = null },
        .{ .body = "    s = {s, \"x\"};", .want = null },
        // A multiplier known only while the device runs makes N copies then.
        .{ .body = "    k = 1 + (V(p, n) > 0.0);\n    s = {k{\"ab\"}};", .want = null },
        // "non-negative" (§4.2.13), and "of integral type" when nonconstant.
        .{ .body = "    s = {neg{\"ab\"}};", .want = .E0327 },
        .{ .body = "    r = V(p, n);\n    s = {r{\"ab\"}};", .want = .E0327 },
        // The folded copies are as many as asked: past the 4096 bytes a
        // fixed row once held (#29).
        .{ .body = "    s = {big{\"a\"}};", .want = null },
        // N copies of "" are "" for any N, at no cost proportional to N.
        .{ .body = "    s = {huge{\"\"}};", .want = null },
    };
    for (cases) |c| try Lower.expectBodyVerdict(test_decls, c.body, c.want);
}

test "lowerPortAccess: §5.4.3 a port access reads the flow into a port of the module" {
    const cases = [_]struct { body: []const u8, want: ?diag.Code }{
        .{ .body = "    y = I(<p>);", .want = null },
        // "The expression V(<a>) is invalid for ports and nets".
        .{ .body = "    y = V(<p>);", .want = .E0507 },
        // "it must be a declared port of the module".
        .{ .body = "    y = I(<q>);", .want = .E0508 },
    };
    for (cases) |c| try Lower.expectBodyVerdict(test_decls, c.body, c.want);
    // §5.2.1: no probe in an analog initial block (E0421).
    try Lower.expectBodyVerdict(test_decls ++ "\n  analog initial begin\n    y0 = V(p);\n  end", "", .E0421);
}

test "lowerShortCircuit: §4.2.7 skips the rhs, unless §4.5.15 must evaluate its operator" {
    const Case = struct { expr: []const u8, imin: bool };
    const cases = [_]Case{
        .{ .expr = "(V(p, n) > 0) && (V(p, n) < 1)", .imin = false },
        .{ .expr = "(V(p, n) > 0) && (ddt(V(p, n)) > 0)", .imin = true },
    };
    for (cases) |c| {
        const src = try std.testing.allocator.print(
            \\module m(p, n);
            \\  inout p, n; electrical p, n;
            \\  integer k;
            \\  analog begin
            \\    k = {s};
            \\    I(p, n) <+ k * V(p, n);
            \\  end
            \\endmodule
        , .{c.expr});
        defer std.testing.allocator.free(src);
        var h: Lower.Harness = undefined;
        try h.init(std.testing.allocator, src);
        defer h.deinit();
        _ = try h.lower() orelse {
            h.dump();
            return error.TestUnexpectedResult;
        };
        const ops = h.mir.insts.items(.op);
        // The skipping form is a branch around the rhs; the evaluating form
        // is `imin` over both sides, normalized to 0/1.
        try std.testing.expectEqual(c.imin, std.mem.countScalar(Mir.Opcode, ops, .imin) != 0);
        if (!c.imin) try std.testing.expect(std.mem.countScalar(Mir.Opcode, ops, .branch) != 0);
    }
}

test "selectPos: every bit of every small range against a walk of the range" {
    // IEEE 1364-2005 §4.2.1: the right-hand bound is the LSB in either
    // direction. Oracle: walk the declared range from its right bound,
    // counting places, and compare with `selectPos` for every k near it.
    var right: i64 = -3;
    while (right <= 3) : (right += 1) for ([_]bool{ false, true }) |asc| for (1..6) |width| {
        const r: Lower.RegRange = .{ .right = right, .asc = asc, .width = @intCast(width) };
        var k: i64 = -12;
        while (k <= 12) : (k += 1) {
            var want: ?u32 = null;
            for (0..width) |pos| {
                const bit = if (asc) right - @as(i64, @intCast(pos)) else right + @as(i64, @intCast(pos));
                if (bit == k) want = @intCast(pos);
            }
            try std.testing.expectEqual(want, selectPos(r, k));
        }
    };
}
