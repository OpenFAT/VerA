//! §4.2 expressions: an `Ast.ExprId` in, a `TypedValue` (a `Mir.Value` and
//! the LRM type that picks its consumer's opcode family) out, emitted into
//! the current block. This file is the dispatch: each construct is lowered by
//! the file named for it (expr_name, expr_op, expr_cond, expr_case,
//! expr_select, expr_concat, expr_access, math), and every operand comes back
//! through `lowerExpr`, so the walk's depth is the expression's.
//!
//! Recursion: the walk recurses on expression depth. The parser measured that
//! depth and the driver runs lowering on a `deep_stack` reserved for it;
//! `Lower.expr_depth` asserts each frame stays below the expression table's
//! size (a tree is shallower than its node count), so a cycle crashes here
//! instead of exhausting the stack.
//!
//! Cites: §2.6.1, §2.6.2, §2.7, §4.2, §4.2.1, §4.2.13, §4.3, §4.4, §4.5,
//! §4.6, §4.7, §5.10, §6.7, §9, A.2.5, A.6.5, A.8.2; IEEE 1364-2005 §5.4,
//! §5.5 (the self-determined `$clog2` operand, §9.14).
//!
//! Contents:
//! - `pub const test_decls`
//! - `pub fn lowerExpr(self: *Lower, e: Ast.ExprId) Oom!TypedValue`
//! - `pub fn lowerClog2Arg(self: *Lower, e: Ast.ExprId, parent: ?constfold.IntContext) Oom!TypedValue`
//! - `pub fn lowerOperand(self: *Lower, e: Ast.ExprId, plan: ?constfold.IntPlan, sized: bool, index: usize) Oom!TypedValue`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const constfold = @import("frontend").constfold;
const Mir = @import("ir").Mir;
const Lower = @import("Lower.zig");
const lower_analog_op = @import("analog_op.zig");
const lower_constfold = @import("constfold.zig");
const lower_func = @import("func.zig");
const lower_event = @import("event.zig");
const lower_sysfunc = @import("sysfunc.zig");
const lower_wide = @import("wide.zig");
const lower_expr_name = @import("expr_name.zig");
const lower_expr_select = @import("expr_select.zig");
const lower_expr_concat = @import("expr_concat.zig");
const lower_expr_op = @import("expr_op.zig");
const lower_expr_cond = @import("expr_cond.zig");
const lower_expr_access = @import("expr_access.zig");
const lower_math = @import("math.zig");
const lower_timer = @import("timer.zig");
const lower_noise_op = @import("noise_op.zig");
const Oom = Lower.Oom;
const TypedValue = Lower.TypedValue;
const poison = Lower.poison;

/// Test support: the declarations every expression case here and in the
/// expr_* files reads.
pub const test_decls =
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

/// Lowers an expression, returning its value and its LRM type; every
/// operator's opcode family depends on the type (LRM §4, §4.2.1.1–§4.2.1.3).
/// A refused expression reports its diagnostic and returns `poison`; only
/// running out of memory fails. Never returns a `.wide` type: a whole wide
/// `reg` read is E0222. `e == .none` is an omitted A.8.2 slot, E0894.
pub fn lowerExpr(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    assert(e == .none or self.exprValid(e));
    return lowerExprRaw(self, e, null, false);
}

/// IEEE §§5.4–5.5 inside a self-determined `$clog2` argument. Function
/// calls still lower their bodies and arguments on their own ordinary path.
pub fn lowerClog2Arg(self: *Lower, e: Ast.ExprId, parent: ?constfold.IntContext) Oom!TypedValue {
    assert(e == .none or self.exprValid(e));
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
        value.v = try lower_expr_op.resizeInt(self, value.v, .{ .width = p.from_width, .signed = p.result.signed });
        if (p.from_width != p.result.width) value.v = try lower_expr_op.resizeInt(self, value.v, p.result);
    };
    assert(self.valueValid(value.v));
    return value;
}

/// Lowers operand `index` of a `$clog2` plan when `sized`, else as `lowerExpr`:
/// the one call the operator files make for each operand, so a self-determined
/// operand keeps its IEEE width (§9.14) wherever it sits in the tree.
pub fn lowerOperand(self: *Lower, e: Ast.ExprId, plan: ?constfold.IntPlan, sized: bool, index: usize) Oom!TypedValue {
    assert(e == .none or self.exprValid(e));
    return if (sized) lowerClog2Arg(self, e, if (plan) |p| p.operands[index] else null) else lowerExpr(self, e);
}

// ---- private ----

// Timer capture belongs on both ordinary and width-aware expression paths.
// A $clog2 operand must retain its dependency when its timer is rescheduled.
fn lowerExprRaw(self: *Lower, e: Ast.ExprId, plan: ?constfold.IntPlan, sized: bool) Oom!TypedValue {
    assert(e == .none or self.exprValid(e));
    if (lower_timer.replayedExpr(self, e)) |value| return value;
    self.expr_depth += 1;
    defer self.expr_depth -= 1;
    assert(self.expr_depth <= self.file.exprs.len() + 1); // see the header: depth below node count
    const value = try lowerExprInner(self, e, plan, sized);
    assert(self.valueValid(value.v));
    assert(value.ty != .wide);
    try lower_timer.captureExpr(self, e, value);
    return value;
}

fn lowerExprInner(self: *Lower, e: Ast.ExprId, plan: ?constfold.IntPlan, sized: bool) Oom!TypedValue {
    assert(self.expr_depth != 0); // only `lowerExprRaw` calls this
    assert(e == .none or self.exprValid(e));
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

        .ident => return lower_expr_name.lookupName(self, e, self.file.str(ex.strOf(e))),
        .hier_ident => return lower_expr_name.lowerHierIdent(self, e), // §6.7, §5.5.3

        .unary => return lower_expr_op.lowerUnary(self, e, plan, sized),
        .binary => return lower_expr_op.lowerBinary(self, e, plan, sized),
        .ternary => return lower_expr_cond.lowerTernary(self, e, plan, sized), // §4.2.3 / §4.2.12

        .call => return lower_func.lowerUserCall(self, e), // §4.7
        .builtin_call => return lower_math.lowerBuiltin(self, e), // §4.3
        .sys_call => return lower_sysfunc.lowerSysCall(self, e), // ch9
        .filter_call => return lower_analog_op.lowerFilter(self, e), // §4.5
        .noise_call => return lower_noise_op.lowerNoise(self, e), // §4.6

        .branch_access => return lower_expr_access.lowerBranchAccess(self, e), // §4.4.1
        .port_access => return lower_expr_access.lowerPortAccess(self, e), // §4.4.2/§5.4.3

        .index => return lower_expr_select.lowerIndex(self, e),

        // §4.2.13 / §3.3 Table 3-3. A `.multi_concat` reaches lowering only
        // when its multiplier is not a literal, which Table 3-3 allows for a
        // string result, or its operands are not all literals, which §4.2.13
        // evaluates once; every other replication was unrolled in the
        // parser, where the operand widths still exist.
        .concat, .multi_concat => return lower_expr_concat.lowerConcat(self, e),
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
