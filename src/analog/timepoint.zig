//! VerA's `vera_timepoint` (§2.9): one statement in, a diamond on
//! `$tp_hit(b)` out whose hit arm reads every variable the statement writes
//! from cache `b` (`Lowered.timepoints`), and the refusals of what a cached
//! statement may not hold (E0529, E0530, E0532).
//!
//! Cites: §2.9, §5.6, §5.10, §9.7.3.
//!
//! Contents:
//! - `pub fn timepointOn(self: *Lower, a: Ast.LteAttr) Oom!bool`
//! - `pub fn timepointRefuses(self: *const Lower, id: Ast.StmtId) ?[]const u8`
//! - `pub fn lowerTimepoint(self: *Lower, id: Ast.StmtId) Oom!void`
//! - private `TpWrites` (`expr`, `stmt`)

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Lower = @import("Lower.zig");
const lower_analog_op = @import("analog_op.zig");
const lower_constfold = @import("constfold.zig");
const lower_expr = @import("expr.zig");
const lower_shape = @import("shape.zig");
const Ssa = @import("ssa.zig");
const lower_stmt = @import("stmt.zig");
const Oom = Lower.Oom;

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

/// A `vera_timepoint` value: §2.9's default 1 when absent, otherwise a
/// constant that folds without the model card, since it picks the code the
/// device is built with (E0529). The statement must run at most once per
/// evaluation and on every timepoint: not inside a loop, an analog function
/// or an `analog initial` block (E0532). Either refusal, or `= 0`, lowers it
/// uncached.
pub fn timepointOn(self: *Lower, a: Ast.LteAttr) Oom!bool {
    assert(a.value == .none or self.exprValid(a.value));
    assert(self.tp_cur == null); // `lowerStmt` asks only outside a cached statement
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
pub fn timepointRefuses(self: *const Lower, id: Ast.StmtId) ?[]const u8 {
    assert(id != .none);
    assert(self.tp_cur != null); // asked only inside a cached statement
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
pub fn lowerTimepoint(self: *Lower, id: Ast.StmtId) Oom!void {
    assert(self.tp_cur == null); // `lowerStmt` caches only an outermost statement
    assert(self.tp_marks.items.len == self.out.timepoints.items.len);
    const b: u32 = @intCast(self.out.timepoints.items.len);
    var slots: std.ArrayList(Lower.TpSlot) = .empty;
    var places: std.ArrayList(Ssa.Place) = .empty;
    try timepointSlots(self, id, &slots, &places);
    assert(slots.items.len == places.items.len);
    const saved = self.tp_cur;
    self.tp_cur = b;
    defer self.tp_cur = saved;
    // Nothing assigned, nothing to cache: the statement has no effect a later
    // iteration could read. Lowered anyway so its refusals still fire.
    if (slots.items.len == 0) return lower_stmt.lowerStmt(self, id);

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
    try lower_stmt.lowerStmt(self, id);
    try self.gotoBlock(join);
    try self.builder.sealBlock(join);
    self.cur = join;

    for (slots.items, places.items) |*s, p| s.final = try self.builder.readVariable(p, join);
    // The statement lowered with `tp_cur` set, so nothing inside cached itself:
    // `b` is still the next row.
    assert(self.out.timepoints.items.len == b);
    try self.out.timepoints.append(self.arena, .{
        .tok = self.file.stmtTok(id),
        .miss = miss_b,
        .join = join,
        .slots = slots.items,
    });
    try self.tp_marks.append(self.arena, mark);
}

// ---- private ----

/// The variables statement `id` writes (`Ast.SourceFile.stmtWrites`), resolved
/// in the scope it starts in: one slot per scalar, per element of a scalarized
/// array, and per memory-backed array. A name declared inside the statement
/// resolves to nothing here and is not cached; no read outside sees it.
fn timepointSlots(self: *Lower, id: Ast.StmtId, slots: *std.ArrayList(Lower.TpSlot), places: *std.ArrayList(Ssa.Place)) Oom!void {
    assert(id != .none);
    assert(slots.items.len == places.items.len);
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

fn timepointScalar(self: *Lower, w: Ast.ExprId, name: []const u8, v: Lower.VarSlot, slots: *std.ArrayList(Lower.TpSlot), places: *std.ArrayList(Ssa.Place)) Oom!void {
    assert(w == .none or self.exprValid(w));
    if (v.ty == .string) return self.err(self.file.exprs.mainTok(w), .E0530, "an assignment to string `{s}`", .{name});
    try slots.append(self.arena, .{ .name = name, .ty = v.ty, .width = if (v.ty == .wide) v.reg_width.? else 0 });
    try places.append(self.arena, v.place);
}
