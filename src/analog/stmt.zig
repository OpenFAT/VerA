//! §5 analog statements: blocks, assignments, named blocks.
//!
//! In: statement AST. Out: MIR instructions in the current block.
//!
//! LRM clauses this file's code cites: §2.9, §3.2, §3.2.2, §3.3, §4.2.1.1,
//! §4.2.1.2, §4.2.13, §4.7.1, §4.7.2.3, §5, §5.3, §5.3.2, §5.6, §5.6.7, §5.7,
//! §5.8, §5.8.3, §5.9, §5.9.1, §5.9.2, §5.10, §5.10.4, §5.11, §6.3, §6.6,
//! §6.6.1, §6.6.3, §6.7, §9.7.3, §9.15.
//! IEEE 1364-2005 clauses cited: §5.5.3.

const std = @import("std");
const Lower = @import("lower.zig");
const lower_analog_op = @import("analog_op.zig");
const lower_constfold = @import("constfold.zig");
const lower_contrib = @import("contrib.zig");
const lower_control = @import("control.zig");
const lower_event = @import("event.zig");
const lower_expr = @import("expr.zig");
const lower_param = @import("param.zig");
const lower_systask = @import("systask.zig");
const lower_shape = @import("shape.zig");
const lower_var = @import("var.zig");
const lower_wide = @import("wide.zig");
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Ssa = @import("ssa.zig");
const Elaborate = @import("elab").Elaborate;
const diag = @import("diag");
const Oom = Lower.Oom;
const TypedValue = Lower.TypedValue;
const ArrayInfo = Lower.ArrayInfo;

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
        if (try timepointOn(self, a)) return lowerTimepoint(self, id);
    };
    // VerA's `vera_lte` statement attribute (A.6.4 prefix): every charge site
    // inside this statement, nested ones included, unless a nearer one says
    // otherwise (`lower_contrib.siteLte`).
    const lte = self.file.stmtLte(id, .vera_lte);
    if (lte) |a| try self.lte_stack.append(self.arena, try lower_contrib.lteValue(self, a));
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
    if (self.tp_cur != null) if (timepointRefuses(self, id)) |what| return self.err(tok, .E0530, "{s}", .{what});
    switch (self.file.stmt(id)) {
        .empty => {},
        .block => |b| try lowerSeqBlock(self, b), // §5.3
        .assign => |a| try lowerAssign(self, a.target, a.value), // §5.7
        .contribute => |c| try lower_contrib.lowerContribute(self, c.lhs, c.rhs), // §5.6
        .indirect => |c| try lower_contrib.lowerIndirect(self, tok, c.lhs, c.probe, c.eqn), // §5.6.7
        .if_stmt => |s| {
            if (s.is_generate) try lower_control.checkGenScheme(self, tok, s.cond); // §6.6
            try lower_control.lowerIf(self, s.cond, s.then_s, s.else_s); // §5.8
        },
        .case_stmt => |s| {
            if (s.is_generate) try lower_control.checkGenScheme(self, tok, s.scrutinee); // §6.6
            try lower_control.lowerCase(self, tok, s.kind, s.scrutinee, s.arms); // §5.8.3
        },
        .for_stmt => |s| try lower_control.lowerFor(self, s.init, s.cond, s.step, s.body), // §5.9.2
        .while_stmt => |s| try lower_control.lowerWhile(self, s.cond, s.body), // §5.9.1
        .repeat_stmt => |s| try lower_control.lowerRepeat(self, s.count, s.body), // §5.9
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

/// §5.10.4 / A.6.5 `event_trigger ::= -> hierarchical_event_identifier ;`.
/// Sets the event's flag for this timepoint; `@(ev)` reads it.
///
/// A.6.4 lists `event_trigger` under `analog_event_statement` and not under
/// `analog_statement`, so a trigger outside an event control is refused, as
/// `disable` (E0401) is.
fn lowerEventTrigger(self: *Lower, tok: u32, target: Ast.ExprId) Oom!void {
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
    try lower_var.checkOneItemPerScope(self, b.params, b.vars, &.{});
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
    const iter = self.gen_iter;
    self.gen_iter = null; // this block's alone, never a nested one's
    if (b.gen_name != .none) {
        const g = self.file.str(b.gen_name);
        return if (iter) |k| try self.arena.print("{s}[{d}]", .{ g, k }) else g;
    }
    if (b.name == .none) return null;
    const label = self.file.str(b.name);
    const unit = if (self.cur_unit < self.unit_paths.len) self.unit_paths[self.cur_unit].path else "";
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
    if (a.value == .none) return true;
    const c = lower_constfold.foldExpr(self, a.value, false) orelse {
        try self.err(a.main_tok, .E0525, "", .{});
        return false;
    };
    return c.isTrue();
}

/// A `vera_timepoint` value: §2.9's default 1 when absent, otherwise a
/// constant that folds without the model card, since it picks the code the
/// device is built with (E0529). The statement must run at most once per
/// evaluation and on every timepoint: not inside a loop, an analog function
/// or an `analog initial` block (E0532). Either refusal, or `= 0`, lowers it
/// uncached.
fn timepointOn(self: *Lower, a: Ast.LteAttr) Oom!bool {
    if (a.value != .none) {
        const c = lower_constfold.foldExpr(self, a.value, false) orelse {
            try self.err(a.main_tok, .E0529, "", .{});
            return false;
        };
        if (!c.isTrue()) return false;
    }
    if (self.restrict) |ctx| {
        try self.err(a.main_tok, .E0532, "in {s}", .{ctx});
        return false;
    }
    if (self.loops.items.len != 0) {
        try self.err(a.main_tok, .E0532, "inside a loop", .{});
        return false;
    }
    return true;
}

/// The construct statement `id` is that a `vera_timepoint` statement may not
/// hold (E0530), or null. Probes, `$limit` and stateful operators are refused
/// where they are lowered (`lower_expr`, `lower_sysfunc`, `lower_analog_op`).
fn timepointRefuses(self: *const Lower, id: Ast.StmtId) ?[]const u8 {
    return switch (self.file.stmt(id)) {
        .contribute, .indirect => "a contribution (§5.6)",
        .event_control => "an event control (§5.10)",
        .event_trigger, .disable => "an event statement (§5.10)",
        // §9.7.3 `$fatal`/`$error` set the device's sticky status, which
        // a cache hit cannot clear: the statement ran once and reported.
        .sys_task => |t| if (std.mem.eql(u8, self.file.str(t.name), "$fatal") or
            std.mem.eql(u8, self.file.str(t.name), "$error")) null else "a system task",
        .empty, .block, .assign, .if_stmt, .case_stmt, .for_stmt, .while_stmt, .repeat_stmt, .jump => null,
    };
}

/// VerA's `vera_timepoint` (§2.9): lowers statement `id` as a diamond on
/// `$tp_hit(b)`. The miss arm is the statement; the hit arm sets every variable
/// it assigns from slot k of cache b (`$tp_real`/`$tp_int`, or an array's
/// cached `anew`). Each slot's value at the join is a core live-out `eval`
/// stores (`Lowered.timepoints`), and the mark place says the statement ran.
fn lowerTimepoint(self: *Lower, id: Ast.StmtId) Oom!void {
    std.debug.assert(self.tp_cur == null); // `lowerStmt` caches only an outermost statement
    std.debug.assert(self.tp_marks.items.len == self.out.timepoints.items.len);
    const b: u32 = @intCast(self.out.timepoints.items.len);
    var slots: std.ArrayList(Lower.TpSlot) = .empty;
    var places: std.ArrayList(Ssa.Place) = .empty;
    try timepointSlots(self, id, &slots, &places);
    std.debug.assert(slots.items.len == places.items.len);
    const saved = self.tp_cur;
    self.tp_cur = b;
    defer self.tp_cur = saved;
    // Nothing assigned, nothing to cache: the statement has no effect a later
    // iteration could read. Lowered anyway so its refusals still fire.
    if (slots.items.len == 0) return lowerStmt(self, id);

    const bv = try self.mir.addIntConst(self.arena, b);
    const mark = self.builder.newPlace();
    try self.builder.writeVariable(mark, .entry, .zero);
    try self.builder.writeVariable(mark, self.cur, .one);
    const hit_b = try self.mir.addBlock(self.arena);
    const miss_b = try self.mir.addBlock(self.arena);
    const join = try self.mir.addBlock(self.arena);
    try self.branchTo(try self.call("$tp_hit", &.{bv}), hit_b, miss_b, true);

    self.cur = hit_b;
    for (slots.items, places.items, 0..) |s, p, k| {
        const kv: u32 = @intCast(k);
        const v = if (s.array != Lower.none_u32)
            try self.mir.emitAnewCached(self.arena, self.cur, s.array, b, kv)
        else
            try self.call(switch (s.ty) {
                .integer => "$tp_int",
                .real => "$tp_real",
                .wide => "$tp_wide",
                .string => unreachable, // `timepointScalar` refuses a string (E0530)
            }, &.{ bv, try self.mir.addIntConst(self.arena, kv) });
        try self.builder.writeVariable(p, self.cur, v);
    }
    try self.gotoBlock(join);

    self.cur = miss_b;
    try lowerStmt(self, id);
    try self.gotoBlock(join);
    try self.builder.sealBlock(join);
    self.cur = join;

    for (slots.items, places.items) |*s, p| s.final = try self.builder.readVariable(p, join);
    // The statement lowered with `tp_cur` set, so nothing inside cached itself:
    // `b` is still the next row.
    std.debug.assert(self.out.timepoints.items.len == b);
    try self.out.timepoints.append(self.arena, .{
        .tok = self.file.stmtTok(id),
        .miss = miss_b,
        .join = join,
        .slots = slots.items,
    });
    try self.tp_marks.append(self.arena, mark);
}

/// The variables statement `id` writes (`Ast.SourceFile.stmtWrites`), resolved
/// in the scope it starts in: one slot per scalar, per element of a scalarized
/// array, and per memory-backed array. A name declared inside the statement
/// resolves to nothing here and is not cached; no read outside sees it.
fn timepointSlots(self: *Lower, id: Ast.StmtId, slots: *std.ArrayList(Lower.TpSlot), places: *std.ArrayList(Ssa.Place)) Oom!void {
    var writes: std.ArrayList(Ast.ExprId) = .empty;
    try (TpWrites{ .l = self, .out = &writes }).stmt(id);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (writes.items) |w| {
        const t = self.file.lvalueBase(w);
        if (t == .none) continue;
        const name = self.file.str(self.file.exprs.strOf(t));
        if ((try seen.getOrPut(self.arena, name)).found_existing) continue;
        if (self.arrays.get(name)) |info| {
            if (info.mem) |m| {
                try slots.append(self.arena, .{ .name = name, .ty = info.ty, .array = m.id });
                try places.append(self.arena, m.place);
                continue;
            }
            var key_buf: [lower_shape.elem_key_len]u8 = undefined;
            var sub: [lower_shape.max_stack_dims]i64 = undefined;
            const idx = try lower_shape.subscriptBuf(self, &sub, info.dims.len);
            for (0..lower_shape.shapeCells(info.dims)) |k| {
                lower_shape.shapeSubscripts(info.dims, k, idx);
                const key = try lower_shape.elemKey(self, &key_buf, name, idx);
                const v = self.vars.get(key) orelse continue;
                try timepointScalar(self, w, try self.arena.dupe(u8, key), v, slots, places);
            }
            continue;
        }
        const v = self.vars.get(name) orelse continue;
        try timepointScalar(self, w, name, v, slots, places);
    }
}

/// `Ast.SourceFile.stmtWrites` of a statement and every statement under it.
const TpWrites = struct {
    l: *Lower,
    out: *std.ArrayList(Ast.ExprId),
    pub fn expr(_: TpWrites, _: Ast.ExprId, _: Ast.SourceFile.Edge) Oom!void {}
    pub fn stmt(w: TpWrites, s: Ast.StmtId) Oom!void {
        if (s == .none) return;
        const funcs: []const Ast.FuncDecl = if (w.l.module) |m| m.functions else &.{};
        try w.l.file.stmtWrites(funcs, s, w.l.arena, w.out);
        try w.l.file.stmtEdges(s, w);
    }
};

fn timepointScalar(self: *Lower, w: Ast.ExprId, name: []const u8, v: Lower.VarSlot, slots: *std.ArrayList(Lower.TpSlot), places: *std.ArrayList(Ssa.Place)) Oom!void {
    if (v.ty == .string) return self.err(self.file.exprs.mainTok(w), .E0530, "an assignment to string `{s}`", .{name});
    try slots.append(self.arena, .{ .name = name, .ty = v.ty, .width = if (v.ty == .wide) v.reg_width.? else 0 });
    try places.append(self.arena, v.place);
}

/// Is the innermost enclosing `vera_nodiff` on?
fn stopping(self: *const Lower) bool {
    const s = self.nodiff_stack.items;
    return s.len != 0 and s[s.len - 1];
}

/// The right-hand side of an assignment: its value, with no derivative under
/// `vera_nodiff`. Only a real carries one.
// ponytail: an array-to-array copy (`A = B`, a slice) keeps its elements'
// derivatives; stop them where they are assigned, or route those copies here.
fn assignValue(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const tv = try lower_expr.lowerExpr(self, e);
    if (!stopping(self) or tv.ty != .real) return tv;
    return .{ .v = try self.emit(.dstop, &.{tv.v}), .ty = .real };
}

/// §5.7 procedural assignment. The target is an lvalue expression so array
/// elements (§3.2.2) work; the value is coerced to the target's type
/// (§4.2.1.1/§4.2.1.2).
fn lowerAssign(self: *Lower, target: Ast.ExprId, value: Ast.ExprId) Oom!void {
    const ex = &self.file.exprs;
    // The rhs is not lowered: a whole array there is no scalar value (E0314).
    if (try paramArrayTarget(self, target)) return;
    // §3.2.2 whole-array assignment from an assignment pattern (§4.2.13):
    // both sides are scalarized, so this is an element-wise copy.
    if (ex.tag(target) == .ident and (ex.tag(value) == .assign_pattern or ex.tag(value) == .concat)) {
        const name = self.file.str(ex.strOf(target));
        if (self.arrays.get(name)) |info| {
            const elems = try lower_shape.flattenPattern(self, value, info.dims, false);
            var key_buf: [lower_shape.elem_key_len]u8 = undefined;
            var sub: [lower_shape.max_stack_dims]i64 = undefined;
            const idx = try lower_shape.subscriptBuf(self, &sub, info.dims.len);
            for (elems, 0..) |elem, k| {
                if (elem == .none) continue;
                lower_shape.shapeSubscripts(info.dims, k, idx);
                if (info.mem == null and !self.vars.contains(try lower_shape.elemKey(self, &key_buf, name, idx))) continue;
                const tv = try assignValue(self, elem);
                try lower_var.writeElem(self, name, info, idx, try self.coerceTo(elem, info.ty, tv));
            }
            return;
        }
    }
    // §5.7 slice assignment: "The array on the LHS of the assignment shall be
    // an array variable, a slice of an array variable or an array parameter".
    // Asked first because a slice is neither a whole array nor a runtime element.
    if (try copyArraySlice(self, target, value)) return;
    // §5.7 whole-array assignment from another array, `A = B`: a shape rule,
    // checked here where both shapes are in scope, then an element-wise copy.
    if (ex.tag(target) == .ident) {
        const dst_name = self.file.str(ex.strOf(target));
        if (self.arrays.get(dst_name)) |dst| {
            if (ex.tag(value) == .ident and try copyWholeArray(self, target, value, dst_name, dst)) return;
            // §5.7 "The arrays on the LHS and the RHS of the assignment must
            // be unpacked": a whole array takes an array, a slice or an
            // assignment pattern, all handled above.
            var b = self.errWith(ex.mainTok(target), .E0429);
            b.msg("`{s}` is an unpacked array and the right-hand side is not", .{dst_name});
            b.help("assign an unpacked array, a slice of one or an assignment pattern `'{{ ... }}`", .{});
            try b.emit();
            _ = try lower_expr.lowerExpr(self, value);
            return;
        }
    }
    // §3.2.2 `a[i] = ...` with a runtime index (§4.7.1 Example 3's `arrayadd`
    // loops on an ordinary variable). The write becomes one masked write per
    // element, the mirror of `lowerIndex`'s select chain for a runtime read.
    if (ex.tag(target) == .index) {
        if (try assignRuntimeIndex(self, target, value)) return;
    }
    // IEEE 1364-2005 §5.5.3 a `reg` wider than 32 bits takes the right-hand
    // side at the width §5.4.1 sizes it to (`lower_wide`).
    if (ex.tag(target) == .ident) if (self.vars.get(self.file.str(ex.strOf(target)))) |s| if (s.ty == .wide) {
        try self.builder.writeVariable(s.place, self.cur, try lower_wide.rhs(self, s.reg_width.?, value));
        try lower_var.countAssign(self, s.place);
        return;
    };
    const lv = try resolveLvalue(self, target) orelse {
        _ = try lower_expr.lowerExpr(self, value); // keep collecting errors from the rhs
        return;
    };
    const tv = try assignValue(self, value);
    try writeLvalue(self, lv, try self.coerceTo(value, lv.ty, tv));
    if (ex.tag(target) == .ident) try lower_contrib.noteVarNoise(self, self.file.str(ex.strOf(target)), value);
}

/// §5.7 "The array on the LHS of the assignment shall be an array variable,
/// a slice of an array variable or an array parameter (when the default value
/// of the parameter is assigned)": past its declaration an array parameter is
/// no target, whole, sliced or one element. Reports E0312 and returns true
/// for one.
fn paramArrayTarget(self: *Lower, target: Ast.ExprId) Oom!bool {
    var subs: [lower_shape.max_stack_dims]Ast.ExprId = undefined;
    const chain = (try indexChain(self, target, &subs)) orelse return false;
    const name = self.file.str(chain.name);
    const info = self.arrays.get(name) orelse return false;
    if (!info.param) return false;
    var b = self.errWith(self.file.exprs.mainTok(target), .E0312);
    b.msg("array parameter `{s}`", .{name});
    b.help("declare an array variable if the values change during the solve", .{});
    try b.emit();
    return true;
}

/// Runtime scalar-element assignment. Each cell receives `select(index == k,
/// value, old)`, leaving all other cells unchanged, including on an invalid index.
/// ponytail: N masked writes per assignment; replace scalarization with explicit
/// array storage if large mutable arrays make this compile-time expansion costly.
fn assignRuntimeIndex(self: *Lower, target: Ast.ExprId, value: Ast.ExprId) Oom!bool {
    // Asked before the rhs is lowered: `false` falls through to the scalar path,
    // which lowers `value` itself, and lowering it twice would repeat side effects.
    if (!try isRuntimeElem(self, target)) return false;
    return writeRuntimeIndex(self, target, value, try assignValue(self, value));
}

/// Reports whether `target` is an element of a declared array whose subscript is
/// only known at run time; the precondition `assignRuntimeIndex` and §4.7.2.3's
/// output-argument writeback share.
fn isRuntimeElem(self: *Lower, target: Ast.ExprId) Oom!bool {
    var subs: [lower_shape.max_stack_dims]Ast.ExprId = undefined;
    const chain = (try indexChain(self, target, &subs)) orelse return false;
    for (chain.subs) |s| {
        if (lower_constfold.foldExpr(self, s, false) != null) continue;
        return self.arrays.contains(self.file.str(chain.name));
    }
    return false;
}

/// Writes an already lowered value to an array element with a runtime subscript,
/// as masked writes; §4.7.2.3's writeback has a `Mir.Value` and no expression.
/// Returns false when `target` is not such an element. `at_e` is only the
/// diagnostic site for §3.3's string conversion.
pub fn writeRuntimeIndex(self: *Lower, target: Ast.ExprId, at_e: Ast.ExprId, tv: TypedValue) Oom!bool {
    if (!try isRuntimeElem(self, target)) return false;
    var subs: [lower_shape.max_stack_dims]Ast.ExprId = undefined;
    const chain = (try indexChain(self, target, &subs)).?;
    const name = self.file.str(chain.name);
    const info = self.arrays.get(name).?;
    if (!try checkSubscriptCount(self, target, name, info, chain.subs.len)) return true;

    const iv = try runtimeArrayIndex(self, chain.subs, info.dims);
    const new = try self.coerceTo(at_e, info.ty, tv);
    // A memory-backed array stores one element; an invalid subscript (-1)
    // stores nothing, as every masked write below leaves its cell.
    if (info.mem) |m| {
        try lower_var.storeElem(self, m.place, iv, new);
        return true;
    }
    var key_buf: [lower_shape.elem_key_len]u8 = undefined;
    var sub: [lower_shape.max_stack_dims]i64 = undefined;
    const at = try lower_shape.subscriptBuf(self, &sub, info.dims.len);
    for (0..lower_shape.shapeCells(info.dims)) |k| {
        lower_shape.shapeSubscripts(info.dims, k, at);
        const key = try lower_shape.elemKey(self, &key_buf, name, at);
        const slot = self.vars.get(key) orelse {
            try self.err(self.file.exprs.mainTok(target), .E0312, "`{s}`", .{name});
            return true;
        };
        const old = try self.builder.readVariable(slot.place, self.cur);
        const c = try self.emit(.ieq, &.{ iv, try self.mir.addIntConst(self.arena, @intCast(k)) });
        try self.builder.writeVariable(slot.place, self.cur, try self.emit(.select, &.{ c, new, old }));
    }
    return true;
}

/// Flattens a full subscript tuple into one index in declaration order, checking
/// each dimension so `[i][columns]` cannot alias `[i+1][0]`. An invalid tuple gives
/// -1, which every masked write leaves untouched. Asserts that `subs` has one
/// subscript per dimension of `dims`.
pub fn runtimeArrayIndex(self: *Lower, subs: []const Ast.ExprId, dims: []const lower_shape.Bounds) Oom!Mir.Value {
    std.debug.assert(subs.len == dims.len);
    var flat = Mir.Value.zero;
    var valid = Mir.Value.one;
    for (subs, dims) |s, d| {
        const index = try self.toInt(try lower_expr.lowerExpr(self, s));
        const lo = try self.mir.addIntConst(self.arena, d.lo);
        const hi = try self.mir.addIntConst(self.arena, d.hi);
        const in_range = try self.emit(.logand, &.{
            try self.emit(.ige, &.{ index, lo }),
            try self.emit(.ile, &.{ index, hi }),
        });
        valid = try self.emit(.logand, &.{ valid, in_range });
        // Keep invalid index arithmetic bounded too, even before the final mask.
        const bounded = try self.emit(.select, &.{ in_range, index, lo });
        const offset = if (d.descending)
            try self.emit(.isub, &.{ hi, bounded })
        else
            try self.emit(.isub, &.{ bounded, lo });
        flat = try self.emit(.iadd, &.{
            try self.emit(.imul, &.{ flat, try self.mir.addIntConst(self.arena, d.count()) }),
            offset,
        });
    }
    return self.emit(.select, &.{ valid, flat, try self.mir.addIntConst(self.arena, -1) });
}

/// §5.7 unpacked array assignment, `A = B`: "Array assignments shall only be
/// done with arrays that are compatible. An array, or a slice of such an array,
/// shall be assignment compatible with any other such array or slice if all the
/// following conditions are satisfied: — The element types of source and target
/// shall be equivalent. — Every dimension of the source array shall have the
/// same number of elements as the target array."
///
/// The clause counts elements, not indices: `int A[10:1]; int B[0:9]; A = B;` is legal.
///
/// Returns false when the right-hand side is not an array at all, so the
/// ordinary scalar path keeps its own diagnostics.
fn copyWholeArray(
    self: *Lower,
    target: Ast.ExprId,
    value: Ast.ExprId,
    dst_name: []const u8,
    dst: ArrayInfo,
) Oom!bool {
    const src_name = self.file.str(self.file.exprs.strOf(value));
    const src = self.arrays.get(src_name) orelse return false;

    if (src.dims.len != dst.dims.len) {
        try self.err(self.file.exprs.mainTok(target), .E0429, "array `{s}` has {d} dimensions and `{s}` has {d}", .{
            dst_name, dst.dims.len, src_name, src.dims.len,
        });
        return true;
    }
    for (dst.dims, src.dims, 0..) |d, s, k| {
        if (d.count() == s.count()) continue;
        var b = self.errWith(self.file.exprs.mainTok(target), .E0429);
        // Print element counts, not bounds: `dimsBounds` normalizes `[10:1]` to
        // lo/hi, which is not the source's spelling.
        b.msg("dimension {d} of array `{s}` holds {d} elements and `{s}` holds {d}", .{
            k, dst_name, d.count(), src_name, s.count(),
        });
        b.note("§5.7 counts elements, not indices: `A[10:1] = B[0:9]` is legal", .{});
        try b.emit();
        return true;
    }
    // "The element types of source and target shall be equivalent." §4.2.1.1's
    // integer/real conversions do not apply: the clause has no coercion.
    if (src.ty != dst.ty) {
        try self.err(self.file.exprs.mainTok(target), .E0429, "array `{s}` holds `{s}` and `{s}` holds `{s}`", .{
            dst_name, @tagName(dst.ty), src_name, @tagName(src.ty),
        });
        return true;
    }

    var key_buf: [lower_shape.elem_key_len]u8 = undefined;
    var d_sub: [lower_shape.max_stack_dims]i64 = undefined;
    var s_sub: [lower_shape.max_stack_dims]i64 = undefined;
    const di = try lower_shape.subscriptBuf(self, &d_sub, dst.dims.len);
    const si = try lower_shape.subscriptBuf(self, &s_sub, src.dims.len);
    const n = lower_shape.shapeCells(dst.dims);
    for (0..n) |k| {
        lower_shape.shapeSubscripts(dst.dims, k, di);
        lower_shape.shapeSubscripts(src.dims, k, si);
        const v = (try lower_expr.arrayElemValue(self, src_name, si)) orelse continue;
        if (dst.mem == null and !self.vars.contains(try lower_shape.elemKey(self, &key_buf, dst_name, di))) continue;
        // The element types are already known equivalent, so there is no
        // conversion to make, only the source's `Value` to re-bind.
        try lower_var.writeElem(self, dst_name, dst, di, v.v);
    }
    return true;
}

/// §5.7 / A.8.5 an array reference that is not a scalar element: a whole array
/// (`subs.len == 0`) or a slice, whose subscript list is shorter than the declared
/// dimension list.
const ArraySlice = struct { name: []const u8, info: ArrayInfo, subs: []const Ast.ExprId };

/// Returns `e` as a whole-array or slice reference, or null for anything else,
/// including a full subscript list. `subs` may point into `buf`.
pub fn arrayRef(self: *Lower, e: Ast.ExprId, buf: *[lower_shape.max_stack_dims]Ast.ExprId) Oom!?ArraySlice {
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .ident => {
            const name = self.file.str(ex.strOf(e));
            const info = self.arrays.get(name) orelse return null;
            return .{ .name = name, .info = info, .subs = &.{} };
        },
        .index => {
            const chain = (try indexChain(self, e, buf)) orelse return null;
            const name = self.file.str(chain.name);
            const info = self.arrays.get(name) orelse return null;
            if (chain.subs.len >= info.dims.len) return null; // a cell, not a slice
            return .{ .name = name, .info = info, .subs = chain.subs };
        },
        else => return null, // else: only a name or a select can name an array
    }
}

/// §5.7 slice assignment, `A[i] = B` / `B = A[i]`, and A.8.5's production for
/// the right-hand side:
///
///   array_analog_variable_rvalue ::=
///         array_variable_identifier
///       | array_variable_identifier [ analog_expression ] { [ analog_expression ] }
///       | assignment_pattern
///
/// A short subscript list is the grammar's slice: on `integer flag_array[0:8][0:3]`,
/// `flag_array[3]` is a four-element row. The subscript is an `analog_expression`,
/// so it may be known only during the solve; a dynamic prefix becomes one `$idx`
/// per destination cell on the read side and one masked write per candidate row on
/// the write side. All source cells are read before any destination cell is
/// written, so an overlapping copy behaves as a copy.
///
/// ponytail: P*N selects for a P-row array of N-element slices; upgrade to real
/// array storage.
///
/// Returns false when neither side is a slice, so the whole-array and
/// runtime-element paths keep their own diagnostics.
fn copyArraySlice(self: *Lower, target: Ast.ExprId, value: Ast.ExprId) Oom!bool {
    var tbuf: [lower_shape.max_stack_dims]Ast.ExprId = undefined;
    var vbuf: [lower_shape.max_stack_dims]Ast.ExprId = undefined;
    const dst = (try arrayRef(self, target, &tbuf)) orelse return false;
    const src = (try arrayRef(self, value, &vbuf)) orelse return false;
    if (dst.subs.len == 0 and src.subs.len == 0) return false; // `copyWholeArray`

    // "Every dimension of the source array shall have the same number of
    // elements as the target array", compared on the slices.
    const dd = dst.info.dims[dst.subs.len..];
    const sd = src.info.dims[src.subs.len..];
    if (dd.len != sd.len or dst.info.ty != src.info.ty) {
        try self.err(self.file.exprs.mainTok(target), .E0429, "a `{s}` slice of `{s}` has {d} dimension(s) and a `{s}` slice of `{s}` has {d}", .{
            @tagName(dst.info.ty), dst.name, dd.len, @tagName(src.info.ty), src.name, sd.len,
        });
        return true;
    }
    for (dd, sd, 0..) |d, s, k| {
        if (d.count() == s.count()) continue;
        var b = self.errWith(self.file.exprs.mainTok(target), .E0429);
        b.msg("dimension {d} of the `{s}` slice holds {d} elements and the `{s}` slice holds {d}", .{
            k, dst.name, d.count(), src.name, s.count(),
        });
        b.note("§5.7 counts elements, not indices: `A[10:1] = B[0:9]` is legal", .{});
        try b.emit();
        return true;
    }

    const n = lower_shape.shapeCells(dd);
    const vals = try self.arena.alloc(Mir.Value, n);
    if (!try readSliceCells(self, value, src, dd, vals)) return true;
    return writeSliceCells(self, target, dst, dd, vals);
}

/// Reads every cell of `s`'s slice into `out`, in the row-major order
/// `shapeSubscripts` walks. Returns false when a subscript is out of range.
/// Asserts that `sd` is the dimensions `s.subs` leaves and that `out` has one
/// slot per cell of them.
pub fn readSliceCells(self: *Lower, at_e: Ast.ExprId, s: ArraySlice, sd: []const lower_shape.Bounds, out: []Mir.Value) Oom!bool {
    std.debug.assert(s.subs.len + sd.len == s.info.dims.len);
    std.debug.assert(out.len == lower_shape.shapeCells(sd));
    var full: [lower_shape.max_stack_dims]i64 = undefined;
    const idx = try lower_shape.subscriptBuf(self, &full, s.info.dims.len);
    const pdims = s.info.dims[0..s.subs.len];

    if (try constPrefix(self, at_e, s, idx[0..s.subs.len])) |known| {
        if (!known) return false; // out of range — E0310 already reported
        for (out, 0..) |*v, k| {
            lower_shape.shapeSubscripts(sd, k, idx[s.subs.len..]);
            const el = (try lower_expr.arrayElemValue(self, s.name, idx)) orelse return false;
            v.* = el.v;
        }
        return true;
    }
    // A dynamic prefix: one `$idx` switch per destination cell, over the same
    // cell of every candidate row. `runtimeArrayIndex` answers -1 for a
    // subscript outside its dimension, which `$idx` reads as the default 0, as
    // `lowerIndex` does for an out-of-range scalar read.
    const iv = try runtimeArrayIndex(self, s.subs, pdims);
    // Memory-backed: cell k of row `iv` is element `iv * cells + k`, and the
    // invalid row -1 lands below 0, which reads the same zero.
    if (s.info.mem) |m| {
        const row = try self.emit(.imul, &.{ iv, try self.mir.addIntConst(self.arena, @intCast(out.len)) });
        for (out, 0..) |*v, k|
            v.* = try lower_var.loadElem(self, m, s.info.ty, try self.emit(.iadd, &.{ row, try self.mir.addIntConst(self.arena, @intCast(k)) }));
        return true;
    }
    const callee: []const u8 = switch (s.info.ty) {
        .real => "$idx",
        .integer => "$idx$int",
        .string => "$idx$str",
        .wide => unreachable, // an array element is never `.wide` (`lower_var.declareVarDecl`)
    };
    // One operand buffer for every cell: each call copies its operands.
    var args: std.ArrayList(Mir.Value) = .empty;
    defer args.deinit(self.arena);
    for (out, 0..) |*v, k| {
        args.clearRetainingCapacity();
        try args.append(self.arena, .zero);
        try args.append(self.arena, iv);
        lower_shape.shapeSubscripts(sd, k, idx[s.subs.len..]);
        for (0..lower_shape.shapeCells(pdims)) |p| {
            lower_shape.shapeSubscripts(pdims, p, idx[0..s.subs.len]);
            const el = (try lower_expr.arrayElemValue(self, s.name, idx)) orelse return false;
            try args.append(self.arena, el.v);
        }
        v.* = try self.call(callee, args.items);
    }
    return true;
}

/// The mirror image: writes `vals` into every cell of `d`'s slice. Asserts
/// that `dd` is the dimensions `d.subs` leaves.
pub fn writeSliceCells(self: *Lower, at_e: Ast.ExprId, d: ArraySlice, dd: []const lower_shape.Bounds, vals: []const Mir.Value) Oom!bool {
    std.debug.assert(d.subs.len + dd.len == d.info.dims.len);
    var key_buf: [lower_shape.elem_key_len]u8 = undefined;
    var full: [lower_shape.max_stack_dims]i64 = undefined;
    const idx = try lower_shape.subscriptBuf(self, &full, d.info.dims.len);
    const pdims = d.info.dims[0..d.subs.len];

    if (try constPrefix(self, at_e, d, idx[0..d.subs.len])) |known| {
        if (!known) return true;
        for (vals, 0..) |v, k| {
            lower_shape.shapeSubscripts(dd, k, idx[d.subs.len..]);
            if (d.info.mem == null and !self.vars.contains(try lower_shape.elemKey(self, &key_buf, d.name, idx))) continue;
            try lower_var.writeElem(self, d.name, d.info, idx, v);
        }
        return true;
    }
    const iv = try runtimeArrayIndex(self, d.subs, pdims);
    // Memory-backed: the `readSliceCells` addressing; row -1 writes nothing.
    if (d.info.mem) |m| {
        const row = try self.emit(.imul, &.{ iv, try self.mir.addIntConst(self.arena, @intCast(vals.len)) });
        for (vals, 0..) |v, k|
            try lower_var.storeElem(self, m.place, try self.emit(.iadd, &.{ row, try self.mir.addIntConst(self.arena, @intCast(k)) }), v);
        return true;
    }
    for (0..lower_shape.shapeCells(pdims)) |p| {
        lower_shape.shapeSubscripts(pdims, p, idx[0..d.subs.len]);
        const hit = try self.emit(.ieq, &.{ iv, try self.mir.addIntConst(self.arena, @intCast(p)) });
        for (vals, 0..) |v, k| {
            lower_shape.shapeSubscripts(dd, k, idx[d.subs.len..]);
            const slot = self.vars.get(try lower_shape.elemKey(self, &key_buf, d.name, idx)) orelse continue;
            const old = try self.builder.readVariable(slot.place, self.cur);
            try self.builder.writeVariable(slot.place, self.cur, try self.emit(.select, &.{ hit, v, old }));
        }
    }
    return true;
}

/// The slice's leading subscripts, if every one of them folds: true when they
/// are also in range, false when §3.2.2 has been reported on them, null when at
/// least one is only known during the solve.
fn constPrefix(self: *Lower, at_e: Ast.ExprId, s: ArraySlice, out: []i64) Oom!?bool {
    for (s.subs, out) |e, *o| {
        const c = lower_constfold.foldExpr(self, e, false) orelse return null;
        // As `resolveLvalue`: a subscript with no §4.2.1.1 integer names no row.
        o.* = c.asIntExact() orelse {
            try self.err(self.file.exprs.mainTok(e), .E0310, "subscript {e} of `{s}` has no integer value, so it lies outside every dimension", .{ c.asReal(), s.name });
            return false;
        };
    }
    for (out, s.info.dims[0..s.subs.len], 0..) |i, d, k| {
        if (i >= d.lo and i <= d.hi) continue;
        try self.err(self.file.exprs.mainTok(at_e), .E0310, "index {d} is outside dimension {d} of `{s}[{d}:{d}]`", .{
            i, k, s.name, d.lo, d.hi,
        });
        return false;
    }
    return true;
}

/// An assignable location (§5.7): a variable, or one element of an array. An
/// element of a memory-backed array (§3.2.2) has no SSA place of its own, so
/// the location is read and written through `readLvalue`/`writeLvalue` only.
pub const Lvalue = struct {
    ty: Lower.Ty,
    at: union(enum) {
        place: Ssa.Place,
        elem: struct { place: Ssa.Place, index: Mir.Value },
        /// A `reg` wider than 32 bits (`Ty.wide`), written a §3.2 integer:
        /// IEEE 1364-2005 §5.5.3 sign-extends it (`lower_wide.fromInt`).
        wide: struct { place: Ssa.Place, width: u32 },
    },
};

/// Returns the current value at `lv`.
pub fn readLvalue(self: *Lower, lv: Lvalue) Oom!Mir.Value {
    return switch (lv.at) {
        .place => |p| self.builder.readVariable(p, self.cur),
        .elem => |el| self.emit(if (lv.ty == .integer) .iload else .fload, &.{ try self.builder.readVariable(el.place, self.cur), el.index }),
        // A conditional write (a scan task's target) would keep the old
        // bits as an integer, which has 32 of them.
        .wide => blk: {
            try self.err(self.mir.cur_tok, .E0329, "a conditional write into a `reg` wider than 32 bits", .{});
            break :blk .zero;
        },
    };
}

/// Writes `v` to `lv` in the current block.
pub fn writeLvalue(self: *Lower, lv: Lvalue, v: Mir.Value) Oom!void {
    switch (lv.at) {
        .place => |p| {
            try self.builder.writeVariable(p, self.cur, v);
            try lower_var.countAssign(self, p);
        },
        .elem => |el| try lower_var.storeElem(self, el.place, el.index, v),
        .wide => |w| {
            try self.builder.writeVariable(w.place, self.cur, try lower_wide.fromInt(self, w.width, v));
            try lower_var.countAssign(self, w.place);
        },
    }
}

/// Resolves an assignable location, `x` or `x[<constant>]` (§3.2.2). Returns null
/// after reporting a diagnostic for anything else.
pub fn resolveLvalue(self: *Lower, e: Ast.ExprId) Oom!?Lvalue {
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .ident => {
            const name = self.file.str(ex.strOf(e));
            if (self.vars.get(name)) |s| {
                if (s.ty == .wide) return .{ .ty = .integer, .at = .{ .wide = .{ .place = s.place, .width = s.reg_width.? } } };
                return .{ .ty = s.ty, .at = .{ .place = s.place } };
            }
            if (self.param_index.contains(name)) {
                var b = self.errWith(self.file.exprs.mainTok(e), .E0312);
                b.msg("`{s}`", .{name});
                b.help("declare a `real` variable if the value changes during the solve", .{});
                try b.emit();
                return null;
            }
            var b = self.errWith(self.file.exprs.mainTok(e), .E0313);
            b.msg("`{s}`", .{name});
            const near = diag.didYouMeanMap(name, self.vars) orelse
                diag.didYouMeanMap(name, self.param_index);
            if (near) |s| b.suggestHere(s);
            try b.emit();
            return null;
        },
        .index => {
            var subs: [lower_shape.max_stack_dims]Ast.ExprId = undefined;
            const chain = (try indexChain(self, e, &subs)) orelse {
                try self.err(self.file.exprs.mainTok(e), .E0316, "only `x` and `x[<constant>]` can be assigned to", .{});
                return null;
            };
            const name = self.file.str(chain.name);
            var idx: [lower_shape.max_stack_dims]i64 = undefined;
            const at = try lower_shape.subscriptBuf(self, &idx, chain.subs.len);
            for (chain.subs, at) |s, *o| {
                const c = lower_constfold.constEval(self, s) orelse {
                    try self.err(self.file.exprs.mainTok(e), .E0311, "indexing `{s}`", .{name});
                    return null;
                };
                // `lower_expr.lowerIndex`'s rule, so a write and a read of
                // one subscript agree: a real with no §4.2.1.1 integer (NaN,
                // an infinity, past i64) names no element. Saturating it
                // wrote a NaN subscript to element 0.
                o.* = c.asIntExact() orelse {
                    try self.err(self.file.exprs.mainTok(s), .E0310, "subscript {e} of `{s}` has no integer value, so it lies outside every dimension", .{ c.asReal(), name });
                    return null;
                };
            }
            return arrayElem(self, e, name, at);
        },
        // §5.7's third restriction: "Hierarchical assignment of a variable from
        // another scope/module is not allowed." Its own code, so the message
        // reads as the rule it is rather than a VerA limitation.
        .hier_ident => {
            var b = self.errWith(self.file.exprs.mainTok(e), .E0316);
            b.msg("a hierarchical name is not an assignment target", .{});
            b.note("§5.7: \"Hierarchical assignment of a variable from another scope/module is not allowed\"", .{});
            try b.emit();
            return null;
        },
        // A.6.3: `{a, b} = ...` is net_lvalue/variable_lvalue, a different
        // production from the §4.2.13 expression, and it is not in the analog
        // subset (annex C). Named so the message does not blame the rhs.
        .concat, .multi_concat => {
            try self.err(self.file.exprs.mainTok(e), .E0317, "", .{});
            return null;
        },
        else => { // else: not an lvalue: E0316
            try self.err(self.file.exprs.mainTok(e), .E0316, "only `x` and `x[<constant>]` can be assigned to", .{});
            return null;
        },
    }
}

fn arrayElem(self: *Lower, e: Ast.ExprId, name: []const u8, idx: []const i64) Oom!?Lvalue {
    const info = self.arrays.get(name) orelse {
        try self.err(self.file.exprs.mainTok(e), .E0309, "`{s}`", .{name});
        return null;
    };
    if (!try checkSubscripts(self, e, name, info, idx)) return null;
    if (info.mem) |m| return .{ .ty = info.ty, .at = .{ .elem = .{
        .place = m.place,
        .index = try self.mir.addIntConst(self.arena, lower_shape.flatIndex(info.dims, idx)),
    } } };
    var key_buf: [lower_shape.elem_key_len]u8 = undefined;
    const s = self.vars.get(try lower_shape.elemKey(self, &key_buf, name, idx)) orelse return null;
    return .{ .ty = s.ty, .at = .{ .place = s.place } };
}

/// The base identifier and the subscripts of `name[i][j]...` (§3.2), outermost first.
const IndexChain = struct { name: Ast.StrId, subs: []const Ast.ExprId };
/// Returns `e`'s base name and subscripts, or null when the base is not a plain
/// name (`f(x)[0]`). `subs` points into `buf`, or into the arena when deeper.
pub fn indexChain(self: *Lower, e: Ast.ExprId, buf: []Ast.ExprId) Oom!?IndexChain {
    const ex = &self.file.exprs;
    var n: usize = 0;
    var cur = e;
    while (ex.tag(cur) == .index) : (cur = ex.lhs(cur)) n += 1;
    if (ex.tag(cur) != .ident or ex.strOf(cur) == .none) return null;
    const subs = if (n <= buf.len) buf[0..n] else try self.arena.alloc(Ast.ExprId, n);
    const name = ex.strOf(cur);
    cur = e;
    var i = n;
    while (i > 0) {
        i -= 1;
        subs[i] = ex.rhs(cur);
        cur = ex.lhs(cur);
    }
    return .{ .name = name, .subs = subs };
}

/// Checks that a reference supplies one subscript per declared dimension (§3.2),
/// returning false after a diagnostic. Separate from the range check because a
/// runtime subscript has a count but no value.
pub fn checkSubscriptCount(self: *Lower, e: Ast.ExprId, name: []const u8, info: ArrayInfo, n: usize) Oom!bool {
    if (n == info.dims.len) return true;
    try self.err(self.file.exprs.mainTok(e), .E0356, "`{s}` is declared with {d} dimension(s) and is indexed with {d}", .{
        name, info.dims.len, n,
    });
    return false;
}

/// Checks each subscript against its dimension's declared bounds (§3.2.2),
/// returning false after a diagnostic.
pub fn checkSubscripts(self: *Lower, e: Ast.ExprId, name: []const u8, info: ArrayInfo, idx: []const i64) Oom!bool {
    if (!try checkSubscriptCount(self, e, name, info, idx.len)) return false;
    for (idx, info.dims, 0..) |i, d, k| {
        if (i >= d.lo and i <= d.hi) continue;
        try self.err(self.file.exprs.mainTok(e), .E0310, "index {d} is outside dimension {d} of `{s}[{d}:{d}]`", .{
            i, k, name, d.lo, d.hi,
        });
        return false;
    }
    return true;
}

/// §4.7.1 `return`, §5.9 `break` / `continue`. All three close the current
/// block and continue into dead code, so statements after them are lowered but
/// unreachable (and dropped by codegen).
fn lowerJump(self: *Lower, tok: u32, kind: Ast.Stmt.JumpKind, value: Ast.ExprId) Oom!void {
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

test "lowerAssign: §5.7 assignment targets and §3.2.2 subscripts" {
    const decls =
        \\  real x[0:3];
        \\  real rv[3:0];
        \\  real m2[0:1][0:2];
        \\  real r3[0:2];
        \\  real r2[0:1];
        \\  integer ia[0:3];
        \\  real s, y;
        \\  integer j;
        \\  parameter real g = 1.0;
        \\  parameter real c[0:1] = '{1.0, 2.0};
    ;
    const cases = [_]struct { body: []const u8, want: ?@import("diag").Code }{
        .{ .body = "    x[0] = 1.0;\n    y = x[0];", .want = null },
        .{ .body = "    j = 1;\n    x[j] = 2.0;", .want = null },
        .{ .body = "    x = '{1.0, 2.0, 3.0, 4.0};", .want = null },
        // A parameter is no target, nor is an array parameter's element (E0312).
        .{ .body = "    g = 2.0;", .want = .E0312 },
        .{ .body = "    c[0] = 3.0;", .want = .E0312 },
        .{ .body = "    zz = 1.0;", .want = .E0313 },
        // A subscript on a scalar: E0309 for a constant, E0311 for a variable.
        .{ .body = "    s[0] = 1.0;", .want = .E0309 },
        .{ .body = "    j = 1;\n    s[j] = 1.0;", .want = .E0311 },
        .{ .body = "    x[4] = 1.0;", .want = .E0310 },
        .{ .body = "    x[0][0] = 1.0;", .want = .E0356 },
        // §4.2.1.1 gives NaN no integer, so it names no element: E0310 on
        // the write exactly as on the read.
        .{ .body = "    y = x[0.0/0.0];", .want = .E0310 },
        .{ .body = "    x[0.0/0.0] = 1.0;", .want = .E0310 },
        // §5.7 whole arrays: an array on both sides, element counts equal
        // dimension by dimension, element types equivalent (E0429).
        .{ .body = "    rv = x;", .want = null },
        .{ .body = "    x = 1.0;", .want = .E0429 },
        .{ .body = "    x = r3;", .want = .E0429 },
        .{ .body = "    x = ia;", .want = .E0429 },
        // Slices (A.8.5): a short subscript list is a row.
        .{ .body = "    r3 = m2[1];\n    m2[0] = r3;", .want = null },
        .{ .body = "    j = 1;\n    r3 = m2[j];", .want = null },
        .{ .body = "    r2 = m2[1];", .want = .E0429 },
        .{ .body = "    r3 = m2[2];", .want = .E0310 },
        .{ .body = "    r3 = m2[0.0/0.0];", .want = .E0310 },
        .{ .body = "    m2[0.0/0.0] = r3;", .want = .E0310 },
    };
    for (cases) |c| try Lower.expectBodyVerdict(decls, c.body, c.want);
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
