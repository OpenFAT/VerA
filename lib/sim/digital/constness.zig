//! An expression in its scope in, whether §5.2/A.8.3 call it a constant expression out, with the refusal that says why not.
//! Cites: IEEE 1364-2005 §5.2, §10.4.5 (constant functions), A.8.3.
//!
//! Contents:
//! - `pub fn constantExpression(self: *Run, e: Ast.ExprId) bool`
//! - `pub fn attributeConstantExpression(self: *Run, e: Ast.ExprId) bool`
//! - `pub fn checkAttributes(self: *Run, attrs: []const Ast.NatureAttr, scope: u32) Error!void`
//! - `pub fn constantFunction(self: *Run, idx: u32) Error!bool`
//! - `pub fn notConstant(self: *Run, idx: u32) Error!?[]const u8`
//! - `V.expr(v: *@This(), x: Ast.ExprId, _: Ast.SourceFile.Edge) Error!void`
//! - `V.stmt(v: *@This(), st: Ast.StmtId) Error!void`
//! - `pub fn unsizedConcatOperand(self: *Run, e: Ast.ExprId) bool`
//! AST -> bytecode: one process body or driver expression, in its instance
//! scope, -> `Instruction` rows in `Run.code`, each expression's type in
//! `Run.types`, and the static slot lists drivers and `@*` wait on; or E1100
//! before any process has run.
//! Clauses: IEEE 1364-2005 §4.8.1, §5.1.1, §5.1.14, §5.2.1/§5.2.2, §5.5.1
//! Table 5-22, §5.10.4, §6.1, §8.5.3.3/§8.5.3.4, §9.3, §9.5, §9.6, §9.7.1 to
//! §9.7.7, §9.8.2, §10.2.2/§10.2.3, §10.4.4/§10.4.5, §12.7, §17.1 to §17.11,
//! §20.4, A.6.5; VAMS §7.3.6.3 analog probes, §9.14 Table 9-11 `$clog2`,
//! §9.22 driver access.
const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const exec = @import("exec.zig");
const evaluate = @import("evaluate.zig");
const deep = @import("base").deep_stack;
const display = @import("display.zig");
const driver = @import("driver.zig");
const system = @import("system.zig");
const elab = @import("elab.zig");
const evcd = @import("evcd.zig");
const vcd = @import("vcd.zig");
const root = @import("root.zig");
const Error = root.Error;
const Run = root.Run;
const SpecExpr = root.SpecExpr;
const expectRun = root.expectRun;
const expectRejected = root.expectRejected;
const filled = @import("net.zig").filled;
const compile = @import("compile.zig");
const system_functions = @import("system_functions.zig");
const subIn = compile.subIn;
const sys_fns = system_functions.sys_fns;

/// IEEE 1364-2005 §5.2: is `e`, in the executing scope, a constant
/// expression: literals, parameters and the operators over them, constant
/// system function calls, and §10.4.5 constant function calls while
/// elaboration still folds (`Run.growing`)? Evaluates nothing.
pub fn constantExpression(self: *Run, e: Ast.ExprId) bool {
    return isConstantExpression(self, e, false);
}

/// Attributes are materialized for VPI after elaboration, when their
/// §10.4.5 constant function calls still retain their elaborated frames.
pub fn attributeConstantExpression(self: *Run, e: Ast.ExprId) bool {
    return isConstantExpression(self, e, true);
}

/// IEEE 1364-2005 §3.8: "attr_spec ::= attr_name [ = constant_expression ]",
/// so a value naming a variable or net is refused. `attrs` are one module's
/// (`ModuleDecl.attrs`), read in its instance `scope`, whose parameters are
/// constants.
pub fn checkAttributes(self: *Run, attrs: []const Ast.NatureAttr, scope: u32) Error!void {
    const saved = self.scope;
    defer self.scope = saved;
    self.scope = scope;
    for (attrs) |a| if (a.value != .none and !attributeConstantExpression(self, a.value))
        return self.exprFail(a.value, "§3.8: an attribute value must be a constant expression");
}

/// IEEE 1364-2005 §10.4.5: is function `idx` a constant function?
pub fn constantFunction(self: *Run, idx: u32) Error!bool {
    return try notConstant(self, idx) == null;
}

/// Why function `idx` is no §10.4.5 constant function, or null when it is
/// one: every name its body uses is its own (a formal, a local, its result)
/// or a parameter, it holds no hierarchical reference, every function it
/// calls is a constant function of the same module, and every system function
/// it calls may be in a constant expression. Asked of a framed function; one
/// it calls is framed early (`earlyFrame`) if need be. A recursive call is
/// taken as constant while it is being asked about.
pub fn notConstant(self: *Run, idx: u32) Error!?[]const u8 {
    // ponytail: a system task is refused, not ignored as §10.4.5 says, and a
    // named block's own locals are not the function's.
    const sub = &self.subs.items[idx];
    if (sub.constant) |c| return if (c) null else "it is not a constant function";
    if (!sub.decl.is_function) return "it is a task";
    sub.constant = true;
    const V = struct {
        r: *Run,
        sub: *const root.Sub,
        why: ?[]const u8 = null,
        pub fn expr(v: *@This(), x: Ast.ExprId, _: Ast.SourceFile.Edge) Error!void {
            if (x == .none or v.why != null) return;
            const ex = &v.r.file.exprs;
            const f = v.sub.frame;
            v.why = switch (ex.tag(x)) {
                .ident => if (v.r.lookup(f.scope, ex.strOf(x))) |at|
                    if ((at >= f.first and at < f.first + f.count) or v.r.params.contains(at)) null else "it reads a name that is neither its own nor a parameter"
                else
                    "it reads a name that is neither its own nor a parameter",
                .hier_ident => "it contains a hierarchical reference",
                .call => if (subIn(v.r, v.sub.inst, ex.strOf(x))) |callee| blk: {
                    if (!v.r.subs.items[callee].framed) try elab.earlyFrame(v.r, callee, ex.mainTok(x));
                    break :blk if (try notConstant(v.r, callee) == null) null else "it calls a function that is not a constant function";
                } else "it calls a function that is not a constant function",
                .sys_call => if (sys_fns.get(v.r.file.str(ex.strOf(x)))) |sf| if (sf.constant()) null else "it calls a system function no constant expression may" else "it calls a system function no constant expression may",
                else => null, // else: every other form is constant when its operands are
            };
            var buf: [3]Ast.ExprId = undefined;
            for (ex.children(x, &buf)) |c| try v.expr(c, .read);
        }
        pub fn stmt(v: *@This(), st: Ast.StmtId) Error!void {
            if (st == .none or v.why != null) return;
            // §10.4.5: a system task in a constant function is ignored when
            // the call is folded (`exec`); a task enable is not allowed.
            if (v.r.file.stmt(st) == .sys_task and v.r.file.str(v.r.file.stmt(st).sys_task.name)[0] != '$') {
                v.why = "it enables a task";
                return;
            }
            try v.r.file.stmtEdges(st, v);
        }
    };
    var v: V = .{ .r = self, .sub = sub };
    try v.stmt(sub.decl.body);
    sub.constant = v.why == null;
    return v.why;
}

// Bare unsized numbers are prohibited by §5.1.14. Its application to
// arithmetic expressions is disputed; retain an explicit unsupported
// boundary until qualified, stopping at self-determined expression results.
pub fn unsizedConcatOperand(self: *Run, e: Ast.ExprId) bool {
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .int_literal => ex.intLiteral(e).width == 0,
        .logic_literal => !ex.logicValue(e).sized,
        .unary => switch (ex.unOp(e)) {
            .plus, .minus, .bit_not => unsizedConcatOperand(self, ex.lhs(e)),
            // One-bit results, sized whatever their operand.
            .logical_not, .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => false,
        },
        .binary => switch (ex.binOp(e)) {
            .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => unsizedConcatOperand(self, ex.lhs(e)) or unsizedConcatOperand(self, ex.rhs(e)),
            .shl, .shr, .ashl, .ashr, .pow => unsizedConcatOperand(self, ex.lhs(e)),
            .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge, .logical_and, .logical_or => false,
        },
        .ternary => unsizedConcatOperand(self, ex.rhs(e)) or unsizedConcatOperand(self, ex.ternaryElse(e)),
        else => false, // else: a name, a select, a call or a concatenation has its own size
    };
}

// ---- private ----

fn isConstantExpression(self: *Run, e: Ast.ExprId, attribute: bool) bool {
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .int_literal, .logic_literal, .str_literal, .real_literal => return true,
        // §12.2: a parameter is a constant; every other name is not.
        .ident => {
            // An attribute's name that the module scope does not hold is a
            // genvar or a name of the generate block, task or function the
            // attribute sits in (`checkAttributes` reads the module's whole
            // list in its instance scope).
            // ponytail: such a name is taken as constant; checking it needs
            // each attribute's own scope.
            const at = self.lookup(self.scope, ex.strOf(e)) orelse return attribute;
            return self.params.contains(at);
        },
        // §5: "constant bit-selects and part-selects of parameters" are
        // constant; the base is a name, which the arm above judges.
        .unary, .binary, .multi_concat, .ternary, .concat, .index, .range, .indexed_range => {},
        // §10.4.5: "A constant function call shall be a function invocation
        // of a constant function local to the calling module where the
        // arguments to the function are constant expressions", "evaluated at
        // elaboration time", so only while elaboration folds.
        .call => {
            if (self.growing == null and !attribute) return false;
            const idx = subIn(self, self.scope, ex.strOf(e)) orelse return false;
            if (!self.subs.items[idx].framed or !(constantFunction(self, idx) catch false)) return false;
        },
        // §17.7: a call that reads the clock is never constant, however
        // constant its (absent) arguments are. Without this `$time`
        // would be accepted as a replication count.
        .sys_call => if (sys_fns.get(self.file.str(ex.strOf(e)))) |f| {
            if (!f.constant()) return false;
        } else return false,
        else => return false, // else: not a form this executor folds
    }
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (!isConstantExpression(self, c, attribute)) return false;
    return true;
}
