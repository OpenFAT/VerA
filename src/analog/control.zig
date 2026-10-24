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
const Lower = @import("lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_expr = @import("expr.zig");
const lower_hier_name = @import("hier_name.zig");
const lower_stmt = @import("stmt.zig");
const lower_shape = @import("shape.zig");
const Ast = @import("frontend").Ast;
const diag = @import("diag");
const Mir = @import("ir").Mir;
const Elaborate = @import("elab").Elaborate;
const Const = Lower.Const;
const Oom = Lower.Oom;
const TypedValue = Lower.TypedValue;

/// This file's private state on `Lower` (`Lower.control_state`): the scratch
/// `isStaticValue` walks with, cleared at the start of each walk and reused, so
/// a condition costs no arena allocation once the sets have grown to the
/// largest walk (on psp103, ~5k conditions used to leave ~3 MB of dead sets).
pub const State = struct {
    /// Values already on the walk.
    seen: std.AutoHashMapUnmanaged(Mir.Value, void) = .empty,
    /// Blocks whose deciding branch was already judged.
    blocks: std.AutoHashMapUnmanaged(Mir.Block, void) = .empty,
    /// `controlStatic`'s predecessor worklist; nested walks share it above a
    /// base mark.
    stack: std.ArrayList(Mir.Block) = .empty,
    /// Blocks and values a walk that answered static already judged (a sealed
    /// block with every deciding branch static; a value with static operands).
    /// Kept across walks, since neither can change once judged, so a chain of
    /// n `if`s judges each block and value once rather than once per `if`.
    static_blocks: std.AutoHashMapUnmanaged(Mir.Block, void) = .empty,
    static_values: std.AutoHashMapUnmanaged(Mir.Value, void) = .empty,
};

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
    for (self.paramset_defparams) |dp| {
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
    try lowerBranchStmt(self, c, then_s, else_s, isAnalysisOrConst(self, cond) or try isStaticValue(self, c), cond);
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
fn lowerCondBody(self: *Lower, body: Ast.StmtId, static: bool) Oom!void {
    self.cond_depth += 1;
    self.static_cond_depth += @intFromBool(static);
    std.debug.assert(self.static_cond_depth <= self.cond_depth); // a static arm is still an arm
    defer {
        self.cond_depth -= 1;
        self.static_cond_depth -= @intFromBool(static);
    }
    try lower_stmt.lowerStmt(self, body);
}

/// Reports whether `e` is an A.8.3 `analysis_or_constant_expression` (the §5.8.1
/// carve-out): literals, parameters and `analysis()` calls combined with operators,
/// none of which can change between Newton iterations. Unlike `foldExpr(..., false)`,
/// a parameter qualifies: the card may override it, but not mid-solve.
pub fn isAnalysisOrConst(self: *const Lower, e: Ast.ExprId) bool {
    if (e == .none) return false;
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        // A.8.4 `number`, `string_literal`.
        .int_literal, .logic_literal, .real_literal, .str_literal, .pos_inf, .neg_inf => true,
        .ident => blk: {
            const name = self.file.str(ex.strOf(e));
            if (self.vars.contains(name)) break :blk false;
            break :blk self.param_index.contains(name) or self.consts.contains(name);
        },
        // A.8.2 analysis_function_call. Its value is fixed for the analysis,
        // which is the whole reason §5.8.1 spells out "analysis_or_constant".
        // A.8.4 `system_parameter_identifier`: §9.18 Syntax 9-13's six hierarchical
        // parameters, fixed per instance for the whole simulation.
        .sys_call => blk: {
            const name = self.file.str(ex.strOf(e));
            if (std.mem.eql(u8, name, "analysis")) break :blk true;
            // §9.19 genvar_system_function: "fixed during elaboration. As such,
            // these functions can be used in genvar expressions controlling
            // conditional or looping behavior of the analog operators" (#33).
            // A top-level call reads the host-written mask, so it does not fold.
            if (std.mem.eql(u8, name, "$param_given") or std.mem.eql(u8, name, "$port_connected")) break :blk true;
            if (ex.args(e).len != 0) break :blk false;
            for ([_][]const u8{ "$mfactor", "$xposition", "$yposition", "$angle", "$hflip", "$vflip" }) |s| {
                if (std.mem.eql(u8, name, s)) break :blk true;
            }
            break :blk false;
        },
        // A.8.4 `parameter_identifier [ constant_range_expression ]`: the base
        // has to name a §3.4.4 array PARAMETER, whose elements `param.zig`
        // scalarizes into `param_index` under `elemKey`'s `name[i]` spelling.
        .index => blk: {
            var base = e;
            while (ex.tag(base) == .index) {
                if (!isAnalysisOrConst(self, ex.rhs(base))) break :blk false;
                base = ex.lhs(base);
            }
            if (ex.tag(base) != .ident) break :blk false;
            const name = self.file.str(ex.strOf(base));
            const info = self.arrays.get(name) orelse break :blk false;
            var buf: [lower_shape.elem_key_len]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            w.writeAll(name) catch break :blk false;
            for (info.dims) |d| w.print("[{d}]", .{d.lo}) catch break :blk false;
            break :blk self.param_index.contains(w.buffered());
        },
        // Operators, A.8.4 `constant_analog_built_in_function_call` and
        // `constant_concatenation`: constant when every operand is.
        .unary, .binary, .range, .indexed_range, .multi_concat, .ternary, .builtin_call, .concat => blk: {
            var buf: [3]Ast.ExprId = undefined;
            for (ex.children(e, &buf)) |c| if (!isAnalysisOrConst(self, c)) break :blk false;
            break :blk true;
        },
        // A.8.4 `nature_attribute_reference ::= net_identifier .
        // potential_or_flow . nature_attribute_identifier`: a nature's
        // attribute is fixed at declaration. Any other dotted name is a §6.8
        // hierarchical reference to something that can move.
        .hier_ident => blk: {
            const parts = ex.nameParts(e);
            if (parts.len != 3) break :blk false;
            break :blk self.file.strings.eql(parts[1], "potential") or self.file.strings.eql(parts[1], "flow");
        },
        // Probes, analog operators and small-signal sources are exactly what
        // moves between iterations; an assignment pattern and the event forms
        // are not A.8.4 primaries.
        //
        // A user function call stays out even with constant arguments: A.8.4's
        // `constant_analog_function_call` promises nothing about the body, which
        // may read `$abstime` (§9.10), and §4.5.15's test is "terms which can
        // not change their value during the course of a simulation".
        .call,
        .branch_access,
        .port_access,
        .filter_call,
        .noise_call,
        .assign_pattern,
        .pattern_repl,
        .event_or,
        .event_posedge,
        .event_negedge,
        .event_initial_step,
        .event_final_step,
        .event_function,
        .event_driver_update,
        => false,
    };
}

/// Reports whether lowered value `v` consists of §4.5.15 "terms which can not
/// change their value during the course of a simulation", by following its
/// dependences rather than its spelling, so `td = ptf * c * tf; if (td == 0.0)`
/// qualifies where `isAnalysisOrConst` refuses every variable.
///
/// Static leaves: literals, parameters (§3.4), and the calls `static_calls`
/// names. Dynamic: a §4.4 probe (`block_param`), the committed-state latches,
/// any other call (analog operators, `$abstime`, `$held_*` seeds, I/O, ...),
/// and a phi whose merge a dynamic branch decides.
///
/// ponytail: a phi is judged by every branch backward-reachable from its
/// incoming blocks, not only the ones between its dominator and itself, so a
/// solve-dependent `if` anywhere earlier in the block makes a later merge
/// dynamic even when it cannot decide it. Sound, and no worse than the
/// syntactic test it extends (which refuses every variable). Upgrade: control
/// dependence through the immediate dominator of the phi's block. A held
/// variable is dynamic even when every write to it is static, for the same
/// reason.
pub fn isStaticValue(self: *Lower, v: Mir.Value) Oom!bool {
    const st = &self.control_state;
    st.seen.clearRetainingCapacity();
    st.blocks.clearRetainingCapacity();
    st.stack.clearRetainingCapacity();
    if (!try staticWalk(self, v, &st.seen, &st.blocks)) return false;
    // Only a whole walk that answered static proves its blocks: a `false`
    // anywhere may have been met after a block was provisionally passed.
    var it = st.blocks.keyIterator();
    while (it.next()) |blk| try st.static_blocks.put(self.arena, blk.*, {});
    var vt = st.seen.keyIterator();
    while (vt.next()) |sv| try st.static_values.put(self.arena, sv.*, {});
    return true;
}

/// The calls whose value is fixed for the whole simulation: A.8.2's
/// `analysis()`, §9.15's `$temperature` and `$vt`, §9.18's six system
/// parameters, and the runtime array read (a pure selection over its operands).
const static_calls = std.StaticStringMap(void).initComptime(.{
    .{"analysis"},   .{"$temperature"}, .{"$vt"},    .{"$mfactor"}, .{"$xposition"},
    .{"$yposition"}, .{"$angle"},       .{"$hflip"}, .{"$vflip"},   .{"$idx"},
    .{"$idx$int"},   .{"$idx$str"},
});

fn staticWalk(
    self: *Lower,
    v0: Mir.Value,
    seen: *std.AutoHashMapUnmanaged(Mir.Value, void),
    blocks: *std.AutoHashMapUnmanaged(Mir.Block, void),
) Oom!bool {
    const v = self.mir.resolveAlias(v0);
    if (self.control_state.static_values.contains(v)) return true;
    // A value already on the walk is being decided by the rest of it: a loop
    // phi reaching itself adds no dependence of its own.
    if ((try seen.getOrPut(self.arena, v)).found_existing) return true;
    const inst = switch (self.mir.valueDef(v)) {
        .undef, .float_const, .int_const, .str_const, .param_ref => return true,
        .block_param => return false, // §4.4: an unknown of the solve
        .inst_result => |i| i,
    };
    switch (self.mir.instData(inst)) {
        .unary => |u| {
            // Committed-solution latches: they move with every accepted step.
            if (u.op == .path_prev or u.op == .path_acc) return false;
            return staticWalk(self, u.operand, seen, blocks);
        },
        .binary => |b| return try staticWalk(self, b.lhs, seen, blocks) and
            try staticWalk(self, b.rhs, seen, blocks),
        .ternary => |t| return try staticWalk(self, t.cond, seen, blocks) and
            try staticWalk(self, t.then_val, seen, blocks) and
            try staticWalk(self, t.else_val, seen, blocks),
        .call => |c| {
            if (!static_calls.has(c.name)) return false;
            // `args` borrows the payload pool; the walk appends nothing to it.
            for (c.args) |a| if (!try staticWalk(self, a, seen, blocks)) return false;
            return true;
        },
        .phi => |p| {
            // An incomplete phi (unsealed loop header) has no operands yet.
            if (p.count == 0) return false;
            for (0..p.count) |k| {
                const pair = self.mir.phiPair(inst, @intCast(k));
                if (!try staticWalk(self, pair.value, seen, blocks)) return false;
                if (!try controlStatic(self, pair.block, seen, blocks)) return false;
            }
            return true;
        },
        .branch, .jump => return false,
        // §3.2.2 a fresh local array is static; a held one is dynamic, as a
        // held variable is. An element is static when its version and its
        // index are, and a version when everything stored into it is.
        .anew => |a| return self.out.mem_arrays.items[a.array].held == Lower.none_u32,
        .load => |l| return try staticWalk(self, l.arr, seen, blocks) and
            try staticWalk(self, l.index, seen, blocks),
        .store => |st| return try staticWalk(self, st.arr, seen, blocks) and
            try staticWalk(self, st.index, seen, blocks) and
            try staticWalk(self, st.value, seen, blocks),
    }
}

/// Reports whether every branch that can decide whether control reaches `from` has
/// a static condition. Walks predecessors to the entry; see `isStaticValue` for the
/// over-approximation.
fn controlStatic(
    self: *Lower,
    from: Mir.Block,
    seen: *std.AutoHashMapUnmanaged(Mir.Value, void),
    blocks: *std.AutoHashMapUnmanaged(Mir.Block, void),
) Oom!bool {
    // A nested walk (a phi met while judging a branch) works above `base` and
    // leaves the stack there on success; a `false` unwinds every walk at once.
    const stack = &self.control_state.stack;
    const base = stack.items.len;
    try stack.append(self.arena, from);
    const b = &self.builder;
    while (stack.items.len > base) {
        const blk = stack.pop().?;
        if (self.control_state.static_blocks.contains(blk)) continue;
        if ((try blocks.getOrPut(self.arena, blk)).found_existing) continue;
        const i = @backingInt(blk);
        // Unsealed: more predecessors may still arrive (a loop's back edge).
        if (i >= b.block_state.len or !b.block_state.items(.sealed)[i]) return false;
        const last = self.mir.blockLast(blk);
        if (last != .none and self.mir.instOp(last) == .branch) {
            if (!try staticWalk(self, self.mir.instData(last).branch.cond, seen, blocks)) return false;
        }
        var node = b.block_state.items(.preds_head)[i];
        for (0..b.block_state.items(.preds_len)[i]) |_| {
            try stack.append(self.arena, b.pred_pool.items[node].block);
            node = b.pred_pool.items[node].next;
        }
    }
    return true;
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
    const pure = src and isAnalysisOrConst(self, ast_cond);
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
/// don't-care bits a four-state side brings (`lower_expr.caseMatch`).
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
    try lowerCaseChain(self, sv, scrutinee, if (four) scrutinee else null, kind, arms, default_arm, isAnalysisOrConst(self, scrutinee) or try isStaticValue(self, sv.v));
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
    if (arms.len == 0) return lower_stmt.lowerStmt(self, default_arm);
    const a = arms[0];
    if (a.labels.len == 0) return lowerCaseChain(self, sv, subject, four_state, kind, arms[1..], default_arm, static);

    // §5.8.3 an arm with several labels matches any of them.
    var cond: ?Mir.Value = null;
    for (a.labels) |l| {
        const eq = if (four_state) |fs|
            (try lower_expr.caseMatch(self, kind, fs, l)) orelse try lower_expr.cmp(self, .eq, sv, try lower_expr.lowerExpr(self, l))
        else
            try lower_expr.cmp(self, .eq, sv, try lower_expr.lowerExpr(self, l));
        cond = if (cond) |c| try self.emit(.logor, &.{ c, eq }) else eq;
    }

    const then_b = try self.mir.addBlock(self.arena);
    const else_b = try self.mir.addBlock(self.arena);
    const join = try self.mir.addBlock(self.arena);
    try self.branchTo(cond.?, then_b, else_b, true);

    const pure = isAnalysisOrConst(self, subject);
    self.cur = then_b;
    try lower_hier_name.pushCond(self, .{ .e = subject, .labels = a.labels, .pol = true, .pure = pure });
    try lowerCondBody(self, a.body, static);
    lower_hier_name.popCond(self);
    try self.gotoBlock(join);

    self.cur = else_b;
    self.cond_depth += 1;
    self.static_cond_depth += @intFromBool(static);
    try lower_hier_name.pushCond(self, .{ .e = subject, .labels = a.labels, .pol = false, .pure = pure });
    try lowerCaseChain(self, sv, subject, four_state, kind, arms[1..], default_arm, static);
    lower_hier_name.popCond(self);
    self.static_cond_depth -= @intFromBool(static);
    self.cond_depth -= 1;
    try self.gotoBlock(join);

    try self.builder.sealBlock(join);
    self.cur = join;
}

/// Lowers a §5.9.1 `while` loop. The header is sealed only after the back edge (Braun SSA).
pub fn lowerWhile(self: *Lower, cond: Ast.ExprId, body: Ast.StmtId) Oom!void {
    const header = try self.mir.addBlock(self.arena);
    try self.gotoBlock(header);
    self.cur = header;

    const c = try self.toBool(try lower_expr.lowerExpr(self, cond));
    const body_b = try self.mir.addBlock(self.arena);
    const exit = try self.mir.addBlock(self.arena);
    // `self.cur`, not `header`: a §4.2.7 short-circuit or `?:` in the condition
    // splits it across blocks and leaves `cur` at the join, and `header` already
    // ends in that split's branch.
    try self.branchTo(c, body_b, exit, false);

    try self.loops.append(self.arena, .{ .brk = exit, .cont = header });
    self.cur = body_b;
    try lowerCondBody(self, body, false); // §5.9: a loop body is never static
    try self.gotoBlock(header);
    const popped = self.loops.pop().?;
    std.debug.assert(popped.brk == exit); // the body's loops popped their own

    try self.builder.sealBlock(header);
    try self.builder.sealBlock(exit);
    self.cur = exit;
}

/// Lowers a §5.9 `repeat (n)` loop as an integer countdown.
pub fn lowerRepeat(self: *Lower, count: Ast.ExprId, body: Ast.StmtId) Oom!void {
    const n = try self.toInt(try lower_expr.lowerExpr(self, count));
    const place = self.builder.newPlace();
    try self.builder.writeVariable(place, self.cur, n);

    const header = try self.mir.addBlock(self.arena);
    try self.gotoBlock(header);
    self.cur = header;

    const i = try self.builder.readVariable(place, header);
    const c = try self.emit(.igt, &.{ i, .zero });
    const body_b = try self.mir.addBlock(self.arena);
    const step_b = try self.mir.addBlock(self.arena);
    const exit = try self.mir.addBlock(self.arena);
    try self.branchTo(c, body_b, exit, false);

    try self.loops.append(self.arena, .{ .brk = exit, .cont = step_b });
    self.cur = body_b;
    try lowerCondBody(self, body, false); // §5.9: a loop body is never static
    try self.gotoBlock(step_b);
    const popped = self.loops.pop().?;
    std.debug.assert(popped.brk == exit); // the body's loops popped their own

    try self.builder.sealBlock(step_b);
    self.cur = step_b;
    const cur_i = try self.builder.readVariable(place, step_b);
    try self.builder.writeVariable(place, step_b, try self.emit(.isub, &.{ cur_i, .one }));
    try self.gotoBlock(header);

    try self.builder.sealBlock(header);
    try self.builder.sealBlock(exit);
    self.cur = exit;
}

/// Lowers a §5.9.2 `for` loop. A genvar loop (§3.5) is unrolled instead (§6.6.1),
/// which is what makes `genvar`-indexed nets work.
pub fn lowerFor(self: *Lower, init_s: Ast.StmtId, cond: Ast.ExprId, step: Ast.StmtId, body: Ast.StmtId) Oom!void {
    if (try tryUnrollFor(self, init_s, cond, step, body)) return;

    try lower_stmt.lowerStmt(self, init_s);
    const header = try self.mir.addBlock(self.arena);
    try self.gotoBlock(header);
    self.cur = header;

    const c = try self.toBool(try lower_expr.lowerExpr(self, cond));
    const body_b = try self.mir.addBlock(self.arena);
    const step_b = try self.mir.addBlock(self.arena);
    const exit = try self.mir.addBlock(self.arena);
    // `self.cur`, not `header` (see `lowerWhile`): the condition may have been
    // split across blocks by a short-circuit, and the branch belongs at its end.
    try self.branchTo(c, body_b, exit, false);

    try self.loops.append(self.arena, .{ .brk = exit, .cont = step_b });
    self.cur = body_b;
    try lowerCondBody(self, body, false); // §5.9: a loop body is never static
    try self.gotoBlock(step_b);
    const popped = self.loops.pop().?;
    std.debug.assert(popped.brk == exit); // the body's loops popped their own

    try self.builder.sealBlock(step_b);
    self.cur = step_b;
    try lower_stmt.lowerStmt(self, step);
    try self.gotoBlock(header);

    try self.builder.sealBlock(header);
    try self.builder.sealBlock(exit);
    self.cur = exit;
}

/// §3.5/§6.6.1 genvar loop-generate. Returns false when this is an ordinary
/// procedural `for` (which `lowerFor` then lowers as a CFG loop). The bounds
/// fold with `shapeEval`: a parameter in them fixes how many copies of the body
/// exist, so it is a §3.4 shape parameter like an array bound.
fn tryUnrollFor(self: *Lower, init_s: Ast.StmtId, cond: Ast.ExprId, step: Ast.StmtId, body: Ast.StmtId) Oom!bool {
    const gv = genvarOf(self, init_s) orelse return false;
    // §6.6.1 "Both the initialization and iteration assignments shall assign
    // to the same genvar": a property of the text, so judged before any trip
    // (a zero-trip loop never evaluates its step). E0419's explain owns it.
    if (step != .none and self.file.stmt(step) == .assign) {
        const t = self.file.stmt(step).assign.target;
        const name = if (self.file.exprs.tag(t) == .ident) self.file.str(self.file.exprs.strOf(t)) else "";
        if (!std.mem.eql(u8, name, gv)) {
            try self.err(self.file.exprs.mainTok(t), .E0419, "the iteration assigns `{s}`, and the initialization the genvar `{s}`: both shall assign the same genvar", .{ name, gv });
            return true;
        }
    }
    const init_v = assignValueOf(self, init_s).?;
    const start = lower_constfold.shapeEval(self, init_v) orelse {
        if (unknownLiteral(self, init_v)) |lit|
            try self.err(self.file.exprs.mainTok(lit), .E0486, "the initialization sets the genvar `{s}`", .{gv})
        else
            try self.err(self.file.exprs.mainTok(cond), .E0417, "initial value of `{s}`", .{gv});
        return true;
    };
    // §6.6.1 a scheme that never ends is refused before any body is
    // lowered; one that ends is unrolled in full, however long.
    const Scheme = struct {
        self: *Lower,
        gv: []const u8,
        cond: Ast.ExprId,
        step: Ast.ExprId,
        pub fn holds(sc: @This(), v: Const) Oom!?bool {
            try sc.self.consts.put(sc.self.arena, sc.gv, v);
            const c = lower_constfold.shapeEval(sc.self, sc.cond) orelse return null;
            return c.isTrue();
        }
        pub fn next(sc: @This(), v: Const) Oom!?Const {
            try sc.self.consts.put(sc.self.arena, sc.gv, v);
            return lower_constfold.shapeEval(sc.self, sc.step);
        }
        pub fn same(a: Const, b: Const) bool {
            return switch (a) {
                .int => |x| b == .int and b.int == x,
                .real => |x| b == .real and @as(u64, @bitCast(b.real)) == @as(u64, @bitCast(x)),
                .str => |x| b == .str and std.mem.eql(u8, b.str, x),
            };
        }
    };
    const scheme: Scheme = .{ .self = self, .gv = gv, .cond = cond, .step = assignValueOf(self, step) orelse .none };
    switch (try Elaborate.genvarLoop(Const, scheme, start)) {
        .repeats => |v| {
            _ = self.consts.remove(gv);
            try self.err(self.file.exprs.mainTok(cond), .E0420, "`{s}` repeats the value {d}, so the loop never ends", .{ gv, v.asInt() });
            return true;
        },
        // The unroll meets the same unfolded value and reports it.
        .ends, .unfolded => {},
    }
    try self.consts.put(self.arena, gv, start);
    // Visible to `queueDisplay`'s snapshot while the body lowers.
    try self.active_genvars.append(self.arena, gv);
    defer _ = self.active_genvars.pop();
    // §5.11: a `break`/`continue` that reaches this loop first is E0440.
    const saved_base = self.analog_for_base;
    self.analog_for_base = self.loops.items.len;
    defer self.analog_for_base = saved_base;

    while (true) {
        const c = lower_constfold.shapeEval(self, cond) orelse {
            try self.err(self.file.exprs.mainTok(cond), .E0418, "", .{});
            break;
        };
        if (!c.isTrue()) break;
        // §6.6.1 a loop generate's block is `name[i]` in §9.15's "path".
        if (body != .none and self.file.stmt(body) == .block and self.file.stmt(body).block.gen_name != .none)
            self.gen_iter = if (self.consts.get(gv)) |v| v.asInt() else null;
        try lower_stmt.lowerStmt(self, body);
        const step_v = assignValueOf(self, step) orelse .none;
        const next = lower_constfold.shapeEval(self, step_v) orelse {
            if (unknownLiteral(self, step_v)) |lit|
                try self.err(self.file.exprs.mainTok(lit), .E0486, "the iteration sets the genvar `{s}`", .{gv})
            else
                try self.err(self.file.exprs.mainTok(cond), .E0419, "", .{});
            break;
        };
        try self.consts.put(self.arena, gv, next);
    }
    _ = self.consts.remove(gv);
    return true;
}

/// Returns the genvar a `for` init statement assigns, or null (LRM §3.5).
fn genvarOf(self: *const Lower, init_s: Ast.StmtId) ?[]const u8 {
    const m = self.module orelse return null;
    if (init_s == .none) return null;
    const s = self.file.stmt(init_s);
    if (s != .assign) return null;
    const t = s.assign.target;
    if (self.file.exprs.tag(t) != .ident) return null;
    const name_id = self.file.exprs.strOf(t);
    for (m.genvars) |g| if (g == name_id) return self.file.str(name_id);
    return null;
}

/// §6.6.1 "It shall be an error if any bit of the genvar is set to x or z":
/// the first literal under `e` with an x or z bit, which is what keeps a
/// genvar assignment's value from folding. `markDiscreteExprs` exempts these
/// literals from E0130, since the scheme is folded, never executed.
fn unknownLiteral(self: *const Lower, e: Ast.ExprId) ?Ast.ExprId {
    if (e == .none) return null;
    const ex = &self.file.exprs;
    if (ex.tag(e) == .logic_literal) return if (ex.logicValue(e).hasUnknown()) e else null;
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (unknownLiteral(self, c)) |hit| return hit;
    return null;
}

fn assignValueOf(self: *const Lower, s: Ast.StmtId) ?Ast.ExprId {
    if (s == .none) return null;
    const st = self.file.stmt(s);
    return if (st == .assign) st.assign.value else null;
}

test isAnalysisOrConst {
    // A.8.3 `analysis_or_constant_expression`, judged on the parsed default
    // in an empty scope, so no identifier is a parameter: literals,
    // `analysis()`, §9.18's six system parameters and §5.5.3's nature
    // attributes, under any operator; nothing that moves between iterations.
    const cases = [_]struct { expr: []const u8, want: bool }{
        .{ .expr = "1", .want = true },
        .{ .expr = "2.5", .want = true },
        .{ .expr = "\"s\"", .want = true },
        .{ .expr = "4'b1010", .want = true },
        .{ .expr = "analysis(\"dc\")", .want = true },
        .{ .expr = "(1 > 0) && analysis(\"tran\")", .want = true },
        .{ .expr = "1 ? 2 : 3", .want = true },
        .{ .expr = "abs(-2.0)", .want = true },
        .{ .expr = "$mfactor", .want = true },
        .{ .expr = "p.potential.abstol", .want = true },
        .{ .expr = "$abstime", .want = false },
        .{ .expr = "$temperature", .want = false },
        .{ .expr = "ddt(1.0)", .want = false },
        .{ .expr = "V(p)", .want = false },
        .{ .expr = "f(1)", .want = false },
        .{ .expr = "undeclared", .want = false },
        .{ .expr = "u.x", .want = false },
        .{ .expr = "undeclared ? 2 : 3", .want = false },
    };
    for (cases) |c| {
        const src = try std.testing.allocator.print("module m; parameter real a = {s}; endmodule", .{c.expr});
        defer std.testing.allocator.free(src);
        var h: Lower.Harness = undefined;
        try h.init(std.testing.allocator, src);
        defer h.deinit();
        const m = &h.file.modules[h.file.builtin_modules];
        std.testing.expectEqual(c.want, isAnalysisOrConst(&h.low, m.params[0].default)) catch |e| {
            std.debug.print("{s}\n", .{c.expr});
            return e;
        };
    }
}

test "lowerCase: §5.8.3 one default at most (E0427)" {
    const decls = "  integer k;\n  real y;";
    try Lower.expectBodyVerdict(decls, "    case (k) 1, 2: y = 1.0; default: y = 2.0; endcase", null);
    try Lower.expectBodyVerdict(decls, "    case (k) 1: y = 1.0; default: y = 2.0; default: y = 3.0; endcase", .E0427);
}

test "tryUnrollFor: §6.6.1 a genvar loop's scheme folds, assigns one genvar, holds no x" {
    const decls = "  genvar i;\n  integer m;\n  real y;";
    const cases = [_]struct { body: []const u8, want: ?diag.Code }{
        .{ .body = "    for (i = 0; i < 3; i = i + 1) y = y + i;", .want = null },
        .{ .body = "    m = 2;\n    for (i = m; i < 2; i = i + 1) y = y + 1.0;", .want = .E0417 },
        .{ .body = "    m = 2;\n    for (i = 0; i < m; i = i + 1) y = y + 1.0;", .want = .E0418 },
        // "Both the initialization and iteration assignments shall assign to
        // the same genvar", and the iteration is constant too.
        .{ .body = "    m = 2;\n    for (i = 0; i < 2; m = i + 1) y = y + 1.0;", .want = .E0419 },
        .{ .body = "    m = 1;\n    for (i = 0; i < 2; i = i + m) y = y + 1.0;", .want = .E0419 },
        // "It shall be an error if any bit of the genvar is set to x or z."
        .{ .body = "    for (i = 1'bx; i < 2; i = i + 1) y = y + 1.0;", .want = .E0486 },
        // §5.11 a jump never leaves an unrolled analog_for.
        .{ .body = "    for (i = 0; i < 2; i = i + 1) begin if (i == 1) break; end", .want = .E0440 },
    };
    for (cases) |c| try Lower.expectBodyVerdict(decls, c.body, c.want);
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

test "loops: §5.9 the procedural loops and their jumps" {
    const decls = "  integer k;\n  real y;";
    try Lower.expectBodyVerdict(decls, "    k = 0;\n    while (k < 3) k = k + 1;", null);
    try Lower.expectBodyVerdict(decls, "    repeat (3) y = y + 1.0;", null);
    try Lower.expectBodyVerdict(decls, "    for (k = 0; k < 3; k = k + 1) begin\n      if (k == 1) break;\n      y = y + 1.0;\n    end", null);
    try Lower.expectBodyVerdict(decls, "    for (k = 0; k < 3; k = k + 1) begin\n      if (k == 1) continue;\n      y = y + 1.0;\n    end", null);
    // A jump outside every loop (E0404).
    try Lower.expectBodyVerdict(decls, "    break;", .E0404);
}

test "§6.6.1 a genvar loop that ends is unrolled however long; one that never ends is E0420" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { cond: []const u8, step: []const u8, code: ?diag.Code }{
        .{ .cond = "i < 4096", .step = "i = i + 1", .code = null }, // the old cap
        .{ .cond = "i < 4097", .step = "i = i + 1", .code = null }, // one past it
        .{ .cond = "i < 100000", .step = "i = i + 1", .code = null }, // far past it
        .{ .cond = "i < 9000", .step = "i = (i + 1) % 8", .code = .E0420 }, // repeats a value
        .{ .cond = "i < 3", .step = "i = i", .code = .E0420 }, // repeats at once
        // A cycle far longer than the old cap.
        .{ .cond = "i < 300000", .step = "i = (i + 1) % 100000", .code = .E0420 },
    };
    for (cases) |c| {
        const src = try gpa.print(
            \\module m(p);
            \\inout p; electrical p;
            \\genvar i;
            \\generate for (i = 0; {s}; {s}) begin end endgenerate
            \\analog I(p) <+ 0.0;
            \\endmodule
        , .{ c.cond, c.step });
        defer gpa.free(src);
        var h: Lower.Harness = undefined;
        try h.init(gpa, src);
        defer h.deinit();
        _ = h.low.lowerFile() catch |err| switch (err) {
            error.DiagnosticsReported => {},
            else => |e| return e,
        };
        if (c.code) |want| {
            try std.testing.expect(h.bag.count() >= 1);
            try std.testing.expectEqual(want, h.bag.at(0).code);
        } else try std.testing.expectEqual(@as(usize, 0), h.bag.count());
    }
}
