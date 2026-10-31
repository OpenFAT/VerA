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
const Lower = @import("Lower.zig");
const lower_analog_op = @import("analog_op.zig");
const lower_constfold = @import("constfold.zig");
const lower_func = @import("func.zig");
const lower_event = @import("event.zig");
const lower_sysfunc = @import("sysfunc.zig");
const lower_wide = @import("wide.zig");
const Ast = @import("frontend").Ast;
const constfold = @import("frontend").constfold;
const Mir = @import("ir").Mir;
const lower_expr_name = @import("expr_name.zig");
const lower_expr_select = @import("expr_select.zig");
const lower_expr_concat = @import("expr_concat.zig");
const lower_expr_op = @import("expr_op.zig");
const lower_expr_cond = @import("expr_cond.zig");
const lower_expr_access = @import("expr_access.zig");
const lower_math = @import("math.zig");
const Oom = Lower.Oom;
const TypedValue = Lower.TypedValue;
const poison = Lower.poison;

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
        value.v = try lower_expr_op.resizeInt(self, value.v, .{ .width = p.from_width, .signed = p.result.signed });
        if (p.from_width != p.result.width) value.v = try lower_expr_op.resizeInt(self, value.v, p.result);
    };
    return value;
}

pub fn lowerOperand(self: *Lower, e: Ast.ExprId, plan: ?constfold.IntPlan, sized: bool, index: usize) Oom!TypedValue {
    return if (sized) lowerClog2Arg(self, e, if (plan) |p| p.operands[index] else null) else lowerExpr(self, e);
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

        .ident => return lower_expr_name.lookupName(self, e, self.file.str(ex.strOf(e))),
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
            if (try lower_expr_name.refuseUnnamedGen(self, e)) return poison;
            const name = try lower_expr_name.flatName(self, e);
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
                return lower_expr_name.lookupName(self, e, name);
            try self.err(self.file.exprs.mainTok(e), .E0901, "`{s}` names nothing in the elaborated design", .{name});
            return poison;
        },

        .unary => return lower_expr_op.lowerUnary(self, e, plan, sized),
        .binary => return lower_expr_op.lowerBinary(self, e, plan, sized),
        .ternary => return lower_expr_cond.lowerTernary(self, e, plan, sized), // §4.2.3 / §4.2.12

        .call => return lower_func.lowerUserCall(self, e), // §4.7
        .builtin_call => return lower_math.lowerBuiltin(self, e), // §4.3
        .sys_call => return lower_sysfunc.lowerSysCall(self, e), // ch9
        .filter_call => return lower_analog_op.lowerFilter(self, e), // §4.5
        .noise_call => return lower_analog_op.lowerNoise(self, e), // §4.6

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

// ---- §4.3 math functions (Tables 4-14 and 4-15) ----------------------------

/// The declarations every expression case below reads.
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
