//! §5 analog statements: a statement in, its MIR in the current block out.
//! `lowerStmt` is the dispatch: blocks, triggers, `disable` and jumps are
//! here; assignments, contributions, conditionals, loops, events and system
//! tasks are lowered by the file named for them. The walk recurses on
//! statement nesting; `Lower.stmt_depth` asserts its bound.
//!
//! Cites: §2.9, §3.3, §4.7.1, §5, §5.3, §5.3.2, §5.6, §5.6.7, §5.7, §5.8,
//! §5.8.3, §5.9, §5.9.1, §5.9.2, §5.10, §5.10.4, §5.11, §6.3, A.6.4, A.6.5,
//! §6.6, §6.6.1, §6.6.3, §6.7, §9.15.
//!
//! Contents:
//! - `pub const State = struct`
//! - `pub fn lowerStmt(self: *Lower, id: Ast.StmtId) Oom!void`
//! - `pub fn stopping(self: *const Lower) bool`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Elaborate = @import("elab").Elaborate;
const Lower = @import("Lower.zig");
const lower_analog_op = @import("analog_op.zig");
const lower_constfold = @import("constfold.zig");
const lower_contrib = @import("contrib.zig");
const lower_control = @import("control.zig");
const lower_event = @import("event.zig");
const lower_expr = @import("expr.zig");
const lower_param = @import("param.zig");
const lower_systask = @import("systask.zig");
const lower_var = @import("var.zig");
const lower_timepoint = @import("timepoint.zig");
const lower_assign = @import("assign.zig");
const lower_loop = @import("loop.zig");
const lower_indirect = @import("indirect.zig");
const lower_reactive = @import("reactive.zig");
const Oom = Lower.Oom;

/// This file's private state on `Lower` (`Lower.stmt_state`).
pub const State = struct {
    /// A.6.5 `disable` targets: the enclosing named blocks, innermost last.
    named_blocks: std.ArrayList(NamedBlockCtx) = .empty,
};

/// A.6.5 `disable hierarchical_block_identifier` target: §5.3's "the control
/// shall pass out of the block", i.e. that block's own exit. One entry per
/// enclosing named block.
const NamedBlockCtx = struct { name: []const u8, exit: Mir.Block };

/// Lowers one statement into the current block (LRM §5).
pub fn lowerStmt(self: *Lower, id: Ast.StmtId) Oom!void {
    if (id == .none) return;
    assert(@backingInt(id) < self.stmtCount());
    // The walk recurses on statement nesting, which the parser measured and
    // the driver reserved a stack for. A statement is on the walk at most
    // twice (`lowerTimepoint` lowers its own statement again), so the depth
    // stays below twice the statement count; a cycle crashes here.
    self.stmt_depth += 1;
    defer self.stmt_depth -= 1;
    assert(self.stmt_depth <= 2 * self.stmtCount() + 1);
    const tok = self.file.stmtTok(id);
    // Same provenance cursor as `lowerExpr`, for the instructions a statement
    // emits outside any expression (phis, jumps, accumulator writes).
    const saved_tok = self.mir.cur_tok;
    defer self.mir.cur_tok = saved_tok;
    self.mir.cur_tok = tok;
    // VerA's `vera_timepoint` (§2.9): the statement runs once per timepoint
    // (`lowerTimepoint`, which lowers it again with `tp_cur` set). Inside one,
    // a nested attribute adds nothing: the outer statement is cached whole.
    if (self.tp_cur == null) if (self.file.stmtLte(id, .vera_timepoint)) |a| {
        if (try lower_timepoint.timepointOn(self, a)) return lower_timepoint.lowerTimepoint(self, id);
    };
    // VerA's `vera_lte` statement attribute (A.6.4 prefix): every charge site
    // inside this statement, nested ones included, unless a nearer one says
    // otherwise (`lower_reactive.siteLte`).
    const lte = self.file.stmtLte(id, .vera_lte);
    if (lte) |a| try self.lte_stack.append(self.arena, try lower_reactive.lteValue(self, a));
    defer if (lte != null) {
        _ = self.lte_stack.pop();
    };
    // `vera_interp`, the same way, for every `absdelay` inside.
    const interp = self.file.stmtLte(id, .vera_interp);
    if (interp) |a| try self.interp_stack.append(self.arena, try lower_analog_op.interpQuad(self, a));
    defer if (interp != null) {
        _ = self.interp_stack.pop();
    };
    // `vera_nodiff`, the same way, for every assignment inside.
    const nodiff = self.file.stmtLte(id, .vera_nodiff);
    if (nodiff) |a| try self.nodiff_stack.append(self.arena, try nodiffValue(self, a));
    defer if (nodiff != null) {
        _ = self.nodiff_stack.pop();
    };
    switch (self.file.stmt(id)) {
        .contribute, .indirect => if (stopping(self)) return self.err(tok, .E0526, "", .{}),
        else => {}, // else: only a contribution leaves a branch without a Jacobian
    }
    if (self.tp_cur != null) if (lower_timepoint.timepointRefuses(self, id)) |what| return self.err(tok, .E0530, "{s}", .{what});
    switch (self.file.stmt(id)) {
        .empty => {},
        .block => |b| try lowerSeqBlock(self, b), // §5.3
        .assign => |a| try lower_assign.lowerAssign(self, a.target, a.value), // §5.7
        .contribute => |c| try lower_contrib.lowerContribute(self, c.lhs, c.rhs), // §5.6
        .indirect => |c| try lower_indirect.lowerIndirect(self, tok, c.lhs, c.probe, c.eqn), // §5.6.7
        .if_stmt => |s| {
            if (s.is_generate) try lower_control.checkGenScheme(self, tok, s.cond); // §6.6
            try lower_control.lowerIf(self, s.cond, s.then_s, s.else_s); // §5.8
        },
        .case_stmt => |s| {
            if (s.is_generate) try lower_control.checkGenScheme(self, tok, s.scrutinee); // §6.6
            try lower_control.lowerCase(self, tok, s.kind, s.scrutinee, s.arms); // §5.8.3
        },
        .for_stmt => |s| try lower_loop.lowerFor(self, s.init, s.cond, s.step, s.body), // §5.9.2
        .while_stmt => |s| try lower_loop.lowerWhile(self, s.cond, s.body), // §5.9.1
        .repeat_stmt => |s| try lower_loop.lowerRepeat(self, s.count, s.body), // §5.9
        // §5.10. A.6.5 gives `@*`/`@ (*)` (recorded as a `.none` event) to
        // `event_control` alone; `analog_event_control` has no such
        // alternative.
        .event_control => |s| if (s.event == .none)
            try self.err(tok, .E0701, "", .{})
        else
            try lower_event.lowerEventControl(self, s.event, s.body),
        .event_trigger => |s| try lowerEventTrigger(self, tok, s.target), // §5.10.4
        .disable => |s| try lowerDisable(self, tok, self.file.str(s.name)),
        .sys_task => |s| try lower_systask.lowerSysTask(self, tok, self.file.str(s.name), s.args),
        .jump => |j| try lowerJump(self, tok, j.kind, j.value),
    }
}

/// Is the innermost enclosing `vera_nodiff` on?
pub fn stopping(self: *const Lower) bool {
    assert(self.nodiff_stack.items.len <= self.stmtCount());
    const s = self.nodiff_stack.items;
    const on = s.len != 0 and s[s.len - 1];
    if (on) assert(s.len != 0);
    return on;
}

// ---- private ----

/// §5.10.4 / A.6.5 `event_trigger ::= -> hierarchical_event_identifier ;`.
/// Sets the event's flag for this timepoint; `@(ev)` reads it.
///
/// A.6.4 lists `event_trigger` under `analog_event_statement` and not under
/// `analog_statement`, so a trigger outside an event control is refused, as
/// `disable` (E0401) is.
fn lowerEventTrigger(self: *Lower, tok: u32, target: Ast.ExprId) Oom!void {
    assert(target == .none or self.exprValid(target));
    assert(self.blockValid(self.cur));
    const tag = self.file.exprs.tag(target);
    if (tag != .ident and tag != .index) return self.err(tok, .E0235, "§5.10.4: a hierarchical named event trigger in an analog block", .{});
    if (!self.in_event_stmt) {
        var b = self.errWith(tok, .E0434);
        b.help("only `@(<event>) -> ev;` is legal", .{});
        return b.emit();
    }
    // §5.10.4 Syntax 5-21 `-> hierarchical_event_identifier { [ expression ] }`:
    // the element the subscript selects is raised, and no other.
    const r = try lower_event.eventRef(self, target) orelse return;
    for (r.places, r.conds) |p, c| {
        const v = if (c == .one) Mir.Value.one else try self.emit(.select, &.{ c, .one, try self.builder.readVariable(p, self.cur) });
        try self.builder.writeVariable(p, self.cur, v);
    }
}

/// A.6.5 `disable_statement`. It is an alternative of A.6.4
/// `analog_event_statement` and absent from `analog_statement`, so
/// `@(<event>) disable <block>;` is the only form an analog block can contain.
/// Clause 5 has no section for `disable`, so annex A is the citation.
fn lowerDisable(self: *Lower, tok: u32, name: []const u8) Oom!void {
    assert(self.blockValid(self.cur));
    assert(name.len != 0);
    if (!self.in_event_stmt) {
        var b = self.errWith(tok, .E0401);
        b.help("only `@(<event>) disable <block>;` is legal", .{});
        return b.emit();
    }
    // A.6.5's operand is a block (or task) identifier and nothing else, so a
    // name that reaches no enclosing block label has no derivation. Searched
    // innermost first: §6.7 makes a block label a scope name.
    var i = self.stmt_state.named_blocks.items.len;
    while (i > 0) {
        i -= 1;
        const nb = self.stmt_state.named_blocks.items[i];
        if (!std.mem.eql(u8, nb.name, name)) continue;
        // §5.3: "the control shall pass out of the block after the last
        // statement is executed"; a disable passes out early to the same
        // destination, so the statements after the block still run.
        try self.gotoBlock(nb.exit);
        return self.startUnreachable();
    }
    // ponytail: hierarchical spellings (`disable top.dut.seg`) are not resolved;
    // elaboration flattens a label into the instance path, so an enclosing
    // block's flat name is what `name` already is. Walk the instance tree here
    // when a fixture disables a block it does not lexically enclose.
    var b = self.errWith(tok, .E0402);
    b.msg("`{s}` names no named block in scope", .{name});
    b.help("`disable` takes the label of an enclosing named block", .{});
    return b.emit();
}

/// §5.3.2 named sequential block: its declarations shadow for the block only.
fn lowerSeqBlock(self: *Lower, b: Ast.SeqBlock) Oom!void {
    assert(self.blockValid(self.cur));
    const mark = self.scope_log.items.len;
    defer lower_var.closeScope(self, mark);
    // §5.3.2's key for a local's static location, in step with `scanHeld`'s.
    const outer_path = self.block_path;
    defer self.block_path = outer_path;
    if (b.name != .none)
        self.block_path = try self.arena.print("{s}{s}.", .{ outer_path, self.file.str(b.name) });
    const outer_scope = self.scope_path;
    defer self.scope_path = outer_scope;
    if (try scopeElem(self, b)) |elem|
        self.scope_path = if (outer_scope.len == 0) elem else try self.arena.print("{s}{c}{s}", .{ outer_scope, Elaborate.sep, elem });
    for (b.params) |*p| try lower_param.lowerParamDecl(self, p); // §5.3.2 local parameters
    try lower_var.checkOneItemPerScope(self, b.params, b.vars, &.{}, &.{});
    for (b.vars) |*v| try lower_var.declareVarDecl(self, v, .local);
    if (b.name != .none) try publishBlockLocals(self, self.file.str(b.name), b);
    // §6.7 a labelled block is a scope, and A.6.5 lets `disable` name it. The
    // exit block is where control lands both when falling off the end and when
    // disabled.
    const exit: ?Mir.Block = if (b.name == .none) null else blk: {
        const e = try self.mir.addBlock(self.arena);
        try self.stmt_state.named_blocks.append(self.arena, .{ .name = self.file.str(b.name), .exit = e });
        break :blk e;
    };
    for (b.body) |s| try lowerStmt(self, s);
    if (exit) |e| {
        const popped = self.stmt_state.named_blocks.pop().?;
        std.debug.assert(popped.exit == e); // the body's blocks popped their own
        try self.gotoBlock(e);
        try self.builder.sealBlock(e);
        self.cur = e;
    }
}

/// The name `b` adds to §9.15's "path", or null for a block that is no scope.
/// A generate block is named by §6.6.3 (`Ast.SeqBlock.gen_name`), with §6.6.1's
/// `[i]` when a loop generate made it; any other block by its label, which
/// elaboration flattened onto the instance path (`joinLocal`) and which is
/// read back here relative to that instance.
fn scopeElem(self: *Lower, b: Ast.SeqBlock) Oom!?[]const u8 {
    assert(self.cur_unit < self.design.units.len or self.design.units.len == 0);
    const iter = self.gen_iter;
    self.gen_iter = null; // this block's alone, never a nested one's
    if (b.gen_name != .none) {
        const g = self.file.str(b.gen_name);
        return if (iter) |k| try self.arena.print("{s}[{d}]", .{ g, k }) else g;
    }
    if (b.name == .none) return null;
    const label = self.file.str(b.name);
    const unit = if (self.cur_unit < self.design.units.len) self.design.units[self.cur_unit].path else "";
    return if (std.mem.startsWith(u8, label, unit)) label[unit.len..] else label;
}

/// §5.3.2: "All identifiers declared within a named sequential block can be
/// accessed outside the scope in which they are declared." The block's scope is
/// popped by `closeScope`, so the outside spelling needs a second binding that is
/// not shadow-logged, under `<label>.<local>` (the path `flatName` builds for
/// `myscope.localVar`). Assignment from outside stays refused (E0316): "Named
/// block variables cannot be assigned outside the scope of the block".
///
/// ponytail: last declaration wins when the same label runs twice (a §6.6.1
/// unrolled `for` body). Nothing can name one iteration's copy apart from
/// another, so there is nothing for an ordinal to disambiguate yet.
fn publishBlockLocals(self: *Lower, label: []const u8, b: Ast.SeqBlock) Oom!void {
    assert(label.len != 0);
    assert(self.block_path.len != 0); // `lowerSeqBlock` set it for this labelled block
    for (b.vars) |v| {
        const local = self.file.str(v.name);
        // Arrays are scalarized into `name[i]` entries, which have no scalar
        // slot under the bare name; §5.3.2's example is a scalar and no fixture
        // names an element hierarchically.
        const slot = self.vars.get(local) orelse continue;
        const q = try self.arena.print("{s}{c}{s}", .{ label, Elaborate.sep, local });
        try self.vars.put(self.arena, q, slot);
        try self.block_locals.put(self.arena, q, {});
    }
    // "Parameters declared within a named block have local scope", local to
    // assignment, which §6.3 override cannot reach anyway; the read follows the
    // same "all identifiers" sentence. They live in `consts`.
    for (b.params) |p| {
        const c = self.consts.get(self.file.str(p.name)) orelse continue;
        const q = try self.arena.print("{s}{c}{s}", .{ label, Elaborate.sep, self.file.str(p.name) });
        try self.consts.put(self.arena, q, c);
    }
}

/// A `vera_nodiff` value: §2.9's default 1 when absent, otherwise a constant
/// that folds without the model card, since it picks what the device computes.
/// E0525 otherwise, and the statement keeps its derivatives.
fn nodiffValue(self: *Lower, a: Ast.LteAttr) Oom!bool {
    assert(a.value == .none or self.exprValid(a.value));
    if (a.value == .none) return true;
    const c = lower_constfold.foldExpr(self, a.value, false) orelse {
        try self.err(a.main_tok, .E0525, "", .{});
        assert(self.had_error);
        return false;
    };
    return c.isTrue();
}

/// §4.7.1 `return`, §5.9 `break` / `continue`. All three close the current
/// block and continue into dead code, so statements after them are lowered but
/// unreachable (and dropped by codegen).
fn lowerJump(self: *Lower, tok: u32, kind: Ast.Stmt.JumpKind, value: Ast.ExprId) Oom!void {
    assert(value == .none or self.exprValid(value));
    assert(self.blockValid(self.cur));
    switch (kind) {
        .ret => {
            const rc = self.ret orelse {
                try self.err(tok, .E0403, "", .{});
                return;
            };
            if (value != .none) {
                // §5.11 "an expression of the correct type": a store into the
                // function's result, so §3.3's string rule holds (`coerceTo`).
                const tv = try lower_expr.lowerExpr(self, value);
                try self.builder.writeVariable(rc.slot.place, self.cur, try self.coerceTo(value, rc.slot.ty, tv));
            }
            try self.gotoBlock(rc.exit);
        },
        .brk, .cont => {
            const what = if (kind == .brk) "break" else "continue";
            if (self.analog_for_base) |base| std.debug.assert(base <= self.loops.items.len);
            if (self.analog_for_base == self.loops.items.len) {
                try self.err(tok, .E0440, "`{s}`", .{what});
                return;
            }
            const l = self.loops.last() orelse {
                try self.err(tok, .E0404, "`{s}`", .{what});
                return;
            };
            try self.gotoBlock(if (kind == .brk) l.brk else l.cont);
        },
    }
    try self.startUnreachable();
}

test "lower: A.6.4/A.6.5 a trigger or a disable is an analog_event_statement" {
    const decls = "  event ev;\n  real y;";
    // Outside an event control: E0434 for `->`, E0401 for `disable`.
    try Lower.expectBodyVerdict(decls, "    -> ev;", .E0434);
    try Lower.expectBodyVerdict(decls, "    begin : blk\n      disable blk;\n    end", .E0401);
    // A.6.5's operand names an enclosing block (E0402).
    try Lower.expectBodyVerdict(decls, "    @(initial_step) disable nosuch;", .E0402);
    try Lower.expectBodyVerdict(decls, "    begin : blk\n      y = 1.0;\n      @(initial_step) disable blk;\n      y = 2.0;\n    end", null);
}

test "lowerStmt: §2.9 vera_nodiff and vera_timepoint refuse what they cannot hold" {
    const decls = "  real y;\n  integer j;";
    // A contribution under `vera_nodiff` would leave its branch without a
    // Jacobian (E0526), and a cached one would not be re-stamped (E0530).
    try Lower.expectBodyVerdict(decls, "    (* vera_nodiff *) I(p, n) <+ V(p, n);", .E0526);
    try Lower.expectBodyVerdict(decls, "    (* vera_timepoint *) I(p, n) <+ V(p, n);", .E0530);
    // Once per evaluation: not inside a loop (E0532).
    try Lower.expectBodyVerdict(decls, "    for (j = 0; j < 2; j = j + 1) (* vera_timepoint *) y = 1.0;", .E0532);
    try Lower.expectBodyVerdict(decls, "    (* vera_timepoint *) y = 1.0;", null);
}
