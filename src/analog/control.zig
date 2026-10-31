//! §5.8 conditionals, §5.9 loops, and §6.6 hierarchy selection.
//!
//! In: if/case/for/while/repeat AST and gated hierarchy restrictions.
//! Out: MIR control flow (blocks, branches, phis) and selection diagnostics.
//!
//! LRM clauses this file's code cites: §3.4, §3.4.4, §3.5, §4.2.7, §4.4,
//! §4.5.15, §5.5.3, §5.6.7, §5.8, §5.8.1, §5.8.3, §5.9, §5.9.1, §5.9.2, §5.11,
//! §6.3.1, §6.4, §6.6, §6.6.1, §6.6.2, §6.8, §6.9.4, §7.3.2, §9.10, §9.15,
//! §9.18, §9.19, §9.20.
//! IEEE 1364-2005 clauses cited: §9.5.

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Lower = @import("Lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_expr = @import("expr.zig");
const lower_hier_name = @import("hier_name.zig");
const lower_stmt = @import("stmt.zig");
const lower_expr_op = @import("expr_op.zig");
const lower_expr_case = @import("expr_case.zig");
const lower_static = @import("static.zig");
const Oom = Lower.Oom;
const TypedValue = Lower.TypedValue;

/// §6.6: "All expressions in generate schemes shall be constant expressions,
/// deterministic at elaboration time." The scheme of an if-generate is its
/// condition and of a case-generate its selector; the loop generate's three
/// parts are E0417-E0419, judged in `tryUnrollFor` where the unroll needs them.
///
/// A parameter is a `constant_primary` (A.8.4), and §6.6 exists for "parameter
/// values to affect the structure of the model", so parameters fold here; a module
/// variable or a solution read does not. Each parameter read becomes a §3.4 shape
/// parameter (`shapeEval`), which `checkShape` keeps the card from moving. An
/// unfoldable scheme is reported, then still lowered as a §5.8 runtime branch.
///
/// ponytail: `lowerIf` still lowers a parameterized generate as a runtime diamond
/// over both arms. The card cannot move a shape parameter, so the diamond always
/// takes the compiled arm; this is unobservable until §6.6.1 per-instance
/// declarations exist.
pub fn checkGenScheme(self: *Lower, tok: u32, scheme: Ast.ExprId) Oom!void {
    if (lower_constfold.shapeEval(self, scheme) != null) return;
    var b = self.errWith(tok, .E0428);
    b.help("a generate scheme may read parameters and genvars, not variables", .{});
    try b.emit();
}

/// §6.3.1/§6.4 forbid a defparam in or below a paramset instance. §6.9.4
/// gives parameters their final values before §6.6.2 selects generate arms;
/// flattening retained both arms, so judge their gates only after lowerParamDecl.
/// As with every generate scheme, the card must preserve the selected shape.
pub fn checkParamsetDefparams(self: *Lower) Oom!void {
    for (self.design.paramset_defparams) |dp| {
        if (dp.gate != .none) {
            const active = lower_constfold.shapeEval(self, dp.gate) orelse {
                try checkGenScheme(self, self.file.exprs.mainTok(dp.gate), dp.gate);
                continue;
            };
            if (!active.isTrue()) continue;
        }
        try self.err(dp.main_tok, .E0926, "a defparam in the hierarchy of paramset instance `{s}`", .{dp.instance});
    }
}

/// Lowers a §5.8 conditional. A constant-foldable condition lowers only the taken
/// arm, which is also what collapses `generate if` (§6.6.2).
pub fn lowerIf(self: *Lower, cond: Ast.ExprId, then_s: Ast.StmtId, else_s: Ast.StmtId) Oom!void {
    if (lower_constfold.foldExpr(self, cond, false)) |c| {
        return lower_stmt.lowerStmt(self, if (c.isTrue()) then_s else else_s);
    }
    // §5.6.7 "Indirect branch contributions shall not be used in conditional
    // ... statements, unless the conditional expression is a constant
    // expression", and a parameter is a `constant_primary` (A.8.4). The arm
    // decides the circuit's topology, so its parameters become shape
    // parameters a card cannot move (`shapeEval`), as a generate scheme's do.
    // The fold first: it reads only `cond`, where `hasIndirect` walks both
    // arms, so a chain of n runtime `if`s stays O(n) (#29).
    // ponytail: n nested `if`s on parameters still walk O(n^2); memoize
    // `hasIndirect` per statement if a model nests those deep.
    if (lower_constfold.foldExpr(self, cond, true) != null and
        (try hasIndirect(self, then_s) or try hasIndirect(self, else_s)))
    {
        const c = lower_constfold.shapeEval(self, cond).?;
        return lower_stmt.lowerStmt(self, if (c.isTrue()) then_s else else_s);
    }
    const c = try self.toBool(try lower_expr.lowerExpr(self, cond));
    try lowerBranchStmt(self, c, then_s, else_s, lower_static.isAnalysisOrConst(self, cond) or try lower_static.isStaticValue(self, c), cond);
}

/// Whether statement `id` or one under it is a §5.6.7 indirect contribution.
fn hasIndirect(self: *Lower, id: Ast.StmtId) Oom!bool {
    if (id == .none) return false;
    if (self.file.stmt(id) == .indirect) return true;
    var walk = struct {
        lower: *Lower,
        found: bool = false,
        pub fn expr(_: *@This(), _: Ast.ExprId, _: Ast.SourceFile.Edge) Oom!void {}
        pub fn stmt(w: *@This(), s: Ast.StmtId) Oom!void {
            w.found = w.found or try hasIndirect(w.lower, s);
        }
    }{ .lower = self };
    try self.file.stmtEdges(id, &walk);
    return walk.found;
}

/// Lowers a body that only runs under a runtime condition, raising `cond_depth` for
/// §5.6.7's ban on indirect contributions and §5.8.1/§5.9's ban on analog operators.
/// Constant-folded paths call `lowerStmt` directly, which is the "unless the
/// conditional expression is a constant expression" carve-out. `static` is §5.8.1's
/// weaker `analysis_or_constant_expression` carve-out; it relaxes E0514 alone.
pub fn lowerCondBody(self: *Lower, body: Ast.StmtId, static: bool) Oom!void {
    self.cond_depth += 1;
    self.static_cond_depth += @intFromBool(static);
    std.debug.assert(self.static_cond_depth <= self.cond_depth); // a static arm is still an arm
    defer {
        self.cond_depth -= 1;
        self.static_cond_depth -= @intFromBool(static);
    }
    try lower_stmt.lowerStmt(self, body);
}

/// Lowers `if (cond) then_s else else_s` over an already lowered condition as a
/// runtime diamond; `static` is as for `lowerCondBody`.
pub fn lowerBranchStmt(
    self: *Lower,
    cond: Mir.Value,
    then_s: Ast.StmtId,
    else_s: Ast.StmtId,
    static: bool,
    /// The source condition of an `if`, for §9.20's parameter-chosen alias
    /// (`lower_hier_name.pushCond`); `.none` for a guard the compiler made.
    ast_cond: Ast.ExprId,
) Oom!void {
    const then_b = try self.mir.addBlock(self.arena);
    const else_b = try self.mir.addBlock(self.arena);
    const join = try self.mir.addBlock(self.arena);

    try self.branchTo(cond, then_b, else_b, true);

    const src = ast_cond != .none;
    const pure = src and lower_static.isAnalysisOrConst(self, ast_cond);
    self.cur = then_b;
    if (src) try lower_hier_name.pushCond(self, .{ .e = ast_cond, .pol = true, .pure = pure });
    try lowerCondBody(self, then_s, static);
    if (src) lower_hier_name.popCond(self);
    try self.gotoBlock(join);

    self.cur = else_b;
    if (src) try lower_hier_name.pushCond(self, .{ .e = ast_cond, .pol = false, .pure = pure });
    try lowerCondBody(self, else_s, static);
    if (src) lower_hier_name.popCond(self);
    try self.gotoBlock(join);

    try self.builder.sealBlock(join);
    self.cur = join;
}

/// Lowers a §5.8.3 case as its equality chain: the first matching arm wins and
/// `default` is the final else. `casex`/`casez` (§7.3.2) differ only in the
/// don't-care bits a four-state side brings (`lower_expr_case.caseMatch`).
pub fn lowerCase(
    self: *Lower,
    tok: u32,
    kind: Ast.CaseKind,
    scrutinee: Ast.ExprId,
    arms: []const Ast.CaseArm,
) Oom!void {
    const sv = try lower_expr.lowerExpr(self, scrutinee);
    var default_arm: Ast.StmtId = .none;
    var defaults: usize = 0;
    for (arms) |a| {
        if (a.labels.len != 0) continue;
        defaults += 1;
        default_arm = a.body;
    }
    // §5.8.3: "The default statement is optional. Use of multiple default
    // statements in one case statement is illegal." Reported once; lowering
    // carries on with the last one so later mistakes are still reported.
    if (defaults > 1) {
        try self.err(tok, .E0427, "{d} `default` arms", .{defaults});
    }
    // §5.8.1 applies to `case` word for word: the arm LABELS are constants by
    // A.6.7, so whether an arm is decided before the solve turns entirely on
    // the scrutinee.
    // §7.3.2 a four-state subject or an x/z label compares both planes, as
    // `===` does (IEEE 1364 §9.5: `case` is case equality).
    const ex = &self.file.exprs;
    var four = ex.tag(scrutinee) == .ident and self.out.discrete_xz.contains(self.file.str(ex.strOf(scrutinee)));
    for (arms) |a| for (a.labels) |l| if (ex.tag(l) == .logic_literal) {
        four = true;
    };
    try lowerCaseChain(self, sv, scrutinee, if (four) scrutinee else null, kind, arms, default_arm, lower_static.isAnalysisOrConst(self, scrutinee) or try lower_static.isStaticValue(self, sv.v));
}

fn lowerCaseChain(
    self: *Lower,
    sv: TypedValue,
    /// The source subject, for §9.20's parameter-chosen alias (`pushCond`).
    subject: Ast.ExprId,
    four_state: ?Ast.ExprId,
    kind: Ast.CaseKind,
    arms: []const Ast.CaseArm,
    default_arm: Ast.StmtId,
    static: bool,
) Oom!void {
    assert(self.valueValid(sv.v));
    assert(self.blockValid(self.cur));
    const depth_before = self.cond_depth;
    const pure = lower_static.isAnalysisOrConst(self, subject);
    // Each labelled arm's else-branch holds the rest of the chain, so its join
    // closes only once the chain's end is lowered: a stack of open joins, not
    // recursion, since a `case` holds any number of arms.
    var joins: std.ArrayList(Mir.Block) = .empty;
    defer joins.deinit(self.arena);
    for (arms) |a| {
        if (a.labels.len == 0) continue;
        // §5.8.3 an arm with several labels matches any of them.
        var cond: ?Mir.Value = null;
        for (a.labels) |l| {
            const eq = if (four_state) |fs|
                (try lower_expr_case.caseMatch(self, kind, fs, l)) orelse try lower_expr_op.cmp(self, .eq, sv, try lower_expr.lowerExpr(self, l))
            else
                try lower_expr_op.cmp(self, .eq, sv, try lower_expr.lowerExpr(self, l));
            cond = if (cond) |c| try self.emit(.logor, &.{ c, eq }) else eq;
        }

        const then_b = try self.mir.addBlock(self.arena);
        const else_b = try self.mir.addBlock(self.arena);
        const join = try self.mir.addBlock(self.arena);
        try self.branchTo(cond.?, then_b, else_b, true);

        self.cur = then_b;
        try lower_hier_name.pushCond(self, .{ .e = subject, .labels = a.labels, .pol = true, .pure = pure });
        try lowerCondBody(self, a.body, static);
        lower_hier_name.popCond(self);
        try self.gotoBlock(join);

        self.cur = else_b;
        self.cond_depth += 1;
        self.static_cond_depth += @intFromBool(static);
        try lower_hier_name.pushCond(self, .{ .e = subject, .labels = a.labels, .pol = false, .pure = pure });
        try joins.append(self.arena, join);
    }
    try lower_stmt.lowerStmt(self, default_arm);
    // Close the open arms innermost first, as the chain nests.
    while (joins.pop()) |join| {
        lower_hier_name.popCond(self);
        self.static_cond_depth -= @intFromBool(static);
        self.cond_depth -= 1;
        try self.gotoBlock(join);
        try self.builder.sealBlock(join);
        self.cur = join;
    }
    assert(self.cond_depth == depth_before);
}

test "lowerCase: §5.8.3 one default at most (E0427)" {
    const decls = "  integer k;\n  real y;";
    try Lower.expectBodyVerdict(decls, "    case (k) 1, 2: y = 1.0; default: y = 2.0; endcase", null);
    try Lower.expectBodyVerdict(decls, "    case (k) 1: y = 1.0; default: y = 2.0; default: y = 3.0; endcase", .E0427);
}

test "lowerIf: §5.8 a constant condition lowers only its arm; a parameter is no constant here" {
    const decls = "  real y;\n  parameter integer on = 0;";
    // The arm that is not taken is not lowered at all, so the undeclared
    // name in it is never resolved.
    try Lower.expectBodyVerdict(decls, "    if (0) zz = 1.0;", null);
    try Lower.expectBodyVerdict(decls, "    if (1) y = 1.0; else zz = 1.0;", null);
    // §3.4: a model card may override `on`, so both arms are lowered.
    try Lower.expectBodyVerdict(decls, "    if (on) zz = 1.0;", .E0313);
}
