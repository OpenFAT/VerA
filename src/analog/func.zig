//! §4.7 user-defined analog functions.
//!
//! In: function declarations and call sites. Out: the function body inlined
//! into the caller's CFG at each call (the device has no call ABI), the
//! `output`/`inout` write-backs, and the E0510 recursion refusal.
//!
//! Spine: `checkFuncRecursion` once per module; `lowerUserCall` (or §9.17.3's
//! `$limit`, through `inlineUserFuncPre`) per call. `scanCallSites` is the one
//! statement walk both share.
//!
//! LRM clauses this file's code cites: §3.2, §3.2.2, §4.7, §4.7.1, §4.7.2, §4.7.2.3,
//! §4.7.2.4, §4.7.3, §5.7, §5.11, §6.8, §7.3.7, §9.17.3.
//! IEEE 1364-2005 clauses cited: §10.4.1.

const std = @import("std");
const Lower = @import("lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_event = @import("event.zig");
const lower_expr = @import("expr.zig");
const lower_limit = @import("limit.zig");
const lower_stmt = @import("stmt.zig");
const lower_shape = @import("shape.zig");
const lower_var = @import("var.zig");
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Oom = Lower.Oom;
const Ty = Lower.Ty;
const TypedValue = Lower.TypedValue;
const Const = Lower.Const;
const VarSlot = Lower.VarSlot;
const poison = Lower.poison;
const astTy = Lower.astTy;

/// Reports E0510 on every analog function in `fns` that calls itself directly
/// or indirectly: "recursive functions are not permitted" (LRM §4.7.3, of an
/// analog user-defined function). Checked on the declarations, not only at
/// reached calls, because an uncalled recursive function is still illegal. A
/// digital function (§4.7) is IEEE 1364-2005's, which may recurse (§10.4.1
/// `automatic`: "reentrant").
///
/// Cost: one reachability walk per function, O(fns * edges); the graph is one module's.
pub fn checkFuncRecursion(self: *Lower, fns: []const Ast.FuncDecl) Oom!void {
    if (fns.len == 0) return;
    const edges = try self.arena.alloc(std.ArrayList(u32), fns.len);
    for (fns, edges) |*fd, *out| {
        out.* = .empty;
        try scanCallSites(self, fd.body, false, fns, out);
    }

    const seen = try self.arena.alloc(bool, fns.len);
    var stack: std.ArrayList(u32) = .empty;
    for (fns, 0..) |*fd, i| {
        if (!fd.is_analog) continue;
        @memset(seen, false);
        stack.clearRetainingCapacity();
        try stack.append(self.arena, @intCast(i));
        while (stack.pop()) |j| {
            for (edges[j].items) |k| {
                if (k == i) { // back at the start ⇒ `fd` calls itself, however far around
                    try self.err(fd.main_tok, .E0510, "`{s}`", .{self.file.str(fd.name)});
                    stack.clearRetainingCapacity();
                    break;
                }
                if (seen[k]) continue;
                seen[k] = true;
                try stack.append(self.arena, k);
            }
        }
    }
}

/// Walks every expression under statement `id`. With `limits`, creates one state
/// slot per access function reached by a user-function `$limit`, in source order,
/// seeded in the entry block (LRM §9.17.3). Otherwise appends to `out` the index in
/// `fns` of each §4.7 function called; an undeclared name is not an edge
/// (`lowerUserCall` reports E0512 when the call is reached).
pub fn scanCallSites(
    self: *Lower,
    id: Ast.StmtId,
    comptime limits: bool,
    fns: if (limits) void else []const Ast.FuncDecl,
    out: if (limits) void else *std.ArrayList(u32),
) Oom!void {
    if (id == .none) return;
    // Every edge of the statement (`SourceFile.stmtEdges`): a `$limit` or a
    // call is a site wherever it is written, a for-loop's init and step, a
    // case label, a repeat count and an event expression included.
    const Walk = struct {
        l: *Lower,
        fns: if (limits) void else []const Ast.FuncDecl,
        out: if (limits) void else *std.ArrayList(u32),
        pub fn expr(w: @This(), e: Ast.ExprId, _: Ast.SourceFile.Edge) Oom!void {
            try scanCallSitesExpr(w.l, e, limits, w.fns, w.out);
        }
        pub fn stmt(w: @This(), s: Ast.StmtId) Oom!void {
            try scanCallSites(w.l, s, limits, w.fns, w.out);
        }
    };
    try self.file.stmtEdges(id, Walk{ .l = self, .fns = fns, .out = out });
}

fn scanCallSitesExpr(
    self: *Lower,
    e: Ast.ExprId,
    comptime limits: bool,
    fns: if (limits) void else []const Ast.FuncDecl,
    out: if (limits) void else *std.ArrayList(u32),
) Oom!void {
    if (e == .none) return;
    const ex = &self.file.exprs;
    const tag = ex.tag(e);
    if (limits) {
        if (tag == .sys_call and std.mem.eql(u8, self.file.str(ex.strOf(e)), "$limit")) {
            const args = if (ex.extraOf(e) < ex.poolLen()) ex.args(e) else &[_]Ast.ExprId{};
            if (args.len >= 2) {
                if (lower_limit.limitUserFunc(self, args[1]) != null) try lower_limit.addLimitSlot(self, args[0]);
            }
        }
    } else if (tag == .call) {
        // StrIds are interned, so identity is name equality.
        for (fns, 0..) |*fd, k| if (fd.name == ex.strOf(e)) {
            try out.append(self.arena, @intCast(k));
            break;
        };
    }
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| try scanCallSitesExpr(self, c, limits, fns, out);
}

/// Lowers a call to a §4.7 user function by inlining its body. An undeclared name
/// reports through `unknownCall`; a digital function called from analog context
/// reports E0436 and is inlined anyway (LRM §7.3.7).
pub fn lowerUserCall(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    const m = self.module orelse return poison;
    for (m.functions) |*fd| {
        if (fd.name != ex.strOf(e)) continue; // interned: identity is name equality
        // §7.3.7: "Digital functions cannot be called from within the analog
        // context." The declaration is legal; the call is not, so the diagnostic
        // lands here. Lowered anyway, so uses of the result do not report again.
        if (!fd.is_analog) {
            var b = self.errWith(ex.mainTok(e), .E0436);
            b.msg("`{s}`", .{name});
            b.label(self.tokenSpan(fd.main_tok), "`{s}` is declared here, without `analog`", .{name});
            try b.emit();
        }
        return inlineUserFuncPre(self, fd, &.{}, ex.args(e), e);
    }
    // vpi_* and every other unresolved name lands here.
    try lower_expr.unknownCall(self, e, name);
    return poison;
}

/// Inlines a call to `fd` at `site`; the generated device has no call ABI.
/// The body sees only its own arguments and locals (LRM §4.7.1), and `output`/`inout`
/// arguments are written back to the caller's lvalues afterwards (§4.7.2.3, §4.7.2.4).
/// `pre` binds the leading formals to values the caller already has (`$limit`'s
/// `vnew` and `vold`, §9.17.3); `arg_exprs` binds the rest. Reports E0510 on a
/// recursive inline and E0511 on an argument-count mismatch, returning `poison`.
pub fn inlineUserFuncPre(
    self: *Lower,
    fd: *const Ast.FuncDecl,
    pre: []const Mir.Value,
    arg_exprs: []const Ast.ExprId,
    site: Ast.ExprId,
) Oom!TypedValue {
    const name = self.file.str(fd.name);
    for (self.inlining.items) |n| {
        if (std.mem.eql(u8, n, name)) {
            try self.err(self.file.exprs.mainTok(site), .E0510, "`{s}`", .{name});
            return poison;
        }
    }
    if (pre.len + arg_exprs.len != fd.args.len) {
        try self.err(self.file.exprs.mainTok(site), .E0511, "`{s}()` takes {d}, got {d}", .{
            name, fd.args.len, pre.len + arg_exprs.len,
        });
        return poison;
    }

    // §4.7.1/§6.8: an array formal's bounds are the function's own
    // declarations, so they fold in its scope (a local parameter shadows the
    // module's of the same name, a caller's genvar is out of sight). Once, here,
    // so the actual is measured against the very shape the body declares.
    const formal_dims = try self.arena.alloc([]const lower_shape.Bounds, fd.args.len);
    @memset(formal_dims, &.{});
    const has_array = for (fd.args) |formal| {
        if (formal.dims.len != 0) break true;
    } else false;
    if (has_array) {
        const saved_fp = self.func_params;
        self.func_params = fd.params;
        var shadowed: std.ArrayList(Shadow) = .empty;
        defer shadowed.deinit(self.arena);
        try enterFuncConsts(self, fd, self.active_genvars.items, &shadowed);
        var ok = true;
        for (fd.args, formal_dims) |formal, *d| {
            if (formal.dims.len == 0) continue;
            d.* = try lower_shape.dimsBounds(self, formal.dims, formal.main_tok, self.file.str(formal.name)) orelse {
                ok = false;
                break;
            };
        }
        try leaveFuncConsts(self, &shadowed);
        self.func_params = saved_fp;
        if (!ok) return poison;
    }

    // Actuals are evaluated in the caller's scope, before it is swapped out.
    // An array formal (§4.7.2.3) is scalarized like any §3.2 array, so it takes
    // one Value per element in both directions.
    var actuals: std.ArrayList([]const Mir.Value) = .empty;
    defer actuals.deinit(self.arena);
    for (fd.args, 0..) |formal, fi| {
        const ty = astTy(formal.ty);
        // §9.17.3's simulator-supplied leading formals: already a value, and
        // already checked `input` by the caller, so neither the array nor the
        // output arm below can apply to one.
        if (fi < pre.len) {
            try actuals.append(self.arena, try self.arena.dupe(Mir.Value, &.{switch (ty) {
                .real => try self.toReal(.{ .v = pre[fi], .ty = .real }),
                .integer => try self.toInt(.{ .v = pre[fi], .ty = .real }),
                .string => pre[fi],
                .wide => unreachable, // `astTy` types no formal `.wide`
            }}));
            continue;
        }
        const actual = arg_exprs[fi - pre.len];
        if (formal.dims.len != 0) {
            const n = lower_shape.shapeCells(formal_dims[fi]);
            const vals = try self.arena.alloc(Mir.Value, n);
            // §4.7.2.3: "All output arguments ... are initialized, zero (0) if
            // numeric, which in turn means that the argument passed to it is
            // reset to zero." An `inout` is NOT (§4.7.2.4 copies in). The
            // shape rule binds an `output` all the same: nothing is copied in,
            // but `funcArrayOut` copies n values back into the actual.
            const shaped = if (formal.direction == .output) blk: {
                @memset(vals, lower_var.zeroOf(ty));
                break :blk try arrayActualCells(self, actual) == n;
            } else try funcArrayIn(self, actual, ty, vals);
            if (!shaped) {
                try self.err(self.file.exprs.mainTok(actual), .E0511, "`{s}()` argument `{s}` needs {d} elements", .{
                    name, self.file.str(formal.name), n,
                });
                return poison;
            }
            try actuals.append(self.arena, vals);
            continue;
        }
        if (formal.direction == .output) {
            try actuals.append(self.arena, try self.arena.dupe(Mir.Value, &.{lower_var.zeroOf(ty)}));
            continue;
        }
        const tv = try lower_expr.lowerExpr(self, actual);
        try actuals.append(self.arena, try self.arena.dupe(Mir.Value, &.{switch (ty) {
            .real => try self.toReal(tv),
            .integer => try self.toInt(tv),
            .string => tv.v,
            .wide => unreachable, // `astTy` types no formal `.wide`
        }}));
    }

    std.debug.assert(actuals.items.len == fd.args.len); // one per formal, `pre` ones included

    // Timer scheduling captures caller dependencies, not this call's private
    // locals. Pure functions are recomputed with new actuals; effectful ones
    // keep their original result and never execute a second time.
    const timer_capture = lower_event.suspendCapture(self);
    defer lower_event.resumeCapture(self, timer_capture);

    // ---- enter the function scope (§4.7.1) ----
    const saved_vars = self.vars;
    const saved_arrays = self.arrays;
    const saved_ret = self.ret;
    const saved_restrict = self.restrict;
    // A fresh loop stack: the body is inlined into the caller's CFG, so otherwise a
    // `break` outside the body's own loops would exit the loop around the call site.
    // With the stack empty, `lowerJump` reports §5.11's E0404 as for a module-level `break`.
    const saved_loops = self.loops;
    const saved_af = self.analog_for_base;
    const saved_func_params = self.func_params;
    const log_mark = self.scope_log.items.len;
    self.vars = .empty;
    self.arrays = .empty;
    self.loops = .empty;
    self.analog_for_base = null;
    self.restrict = "an analog function";
    try self.inlining.append(self.arena, name);

    // §4.7.2 local parameters fold to constants; they never reach the Model.
    // The decl list is installed as `func_params` so `lookupName` masks a module
    // parameter of the same name for the body's duration (§6.8). Swapped per call
    // like `vars` (§4.7.1 isolation).
    self.func_params = fd.params;
    // `consts` is shared with the caller, and §4.7.1 lets the body see only
    // "locally-defined parameters and module-level parameters" of what it
    // holds. So for the body's duration the caller's genvars are taken out
    // (a genvar is neither), and a local parameter's fold replaces a module
    // parameter's of the same name; `shadowed` records every entry touched so the
    // exit below restores it.
    var shadowed: std.ArrayList(Shadow) = .empty;
    defer shadowed.deinit(self.arena);
    const saved_genvars = self.active_genvars;
    self.active_genvars = .empty;
    try enterFuncConsts(self, fd, saved_genvars.items, &shadowed);

    const ret_ty = astTy(fd.ret_ty);
    const ret_slot = try lower_var.declareVar(self, name, ret_ty); // §4.7.1 return variable
    try self.builder.writeVariable(ret_slot.place, self.cur, lower_var.zeroOf(ret_ty));

    var arg_slots: std.ArrayList([]const VarSlot) = .empty;
    defer arg_slots.deinit(self.arena);
    for (fd.args, actuals.items, formal_dims) |formal, vals, dims| {
        const fname = self.file.str(formal.name);
        const ty = astTy(formal.ty);
        if (formal.dims.len != 0) {
            // The formal's own §3.2 declaration, inside the function scope: the
            // shape comes from the formal and the values from the actual, which
            // makes `arrayadd(x, '{y,z})` (§4.7.3) legal: the two actuals have
            // different shapes and the same size.
            // §3.2.2 a formal some subscript in the body indexes at run time:
            // one storage, filled element by element from the actual.
            if (lower_var.isMemArray(self, formal.name, ty)) {
                const place = try lower_var.declareMemArray(self, fname, dims, ty, true);
                for (vals, 0..) |v, k| try lower_var.storeElem(self, place, try self.mir.addIntConst(self.arena, @intCast(k)), v);
                try arg_slots.append(self.arena, &.{});
                continue;
            }
            try lower_var.declareArray(self, fname, .{ .dims = dims, .ty = ty });
            const slots = try self.arena.alloc(VarSlot, vals.len);
            var sub: [lower_shape.max_stack_dims]i64 = undefined;
            const idx = try lower_shape.subscriptBuf(self, &sub, dims.len);
            for (vals, slots, 0..) |v, *slot, k| {
                lower_shape.shapeSubscripts(dims, k, idx);
                slot.* = try lower_var.declareVar(self, try lower_shape.elemName(self, fname, idx), ty);
                try self.builder.writeVariable(slot.place, self.cur, v);
            }
            try arg_slots.append(self.arena, slots);
            continue;
        }
        const slot = try lower_var.declareVar(self, fname, ty);
        try self.builder.writeVariable(slot.place, self.cur, vals[0]);
        try arg_slots.append(self.arena, try self.arena.dupe(VarSlot, &.{slot}));
    }
    // §6.8 an analog function is one of the six scopes; its locals are a list
    // like a module's or a block's.
    try lower_var.checkOneItemPerScope(self, &.{}, fd.vars, &.{});
    for (fd.vars) |*v| try lower_var.declareVarDecl(self, v, .local);

    const exit = try self.mir.addBlock(self.arena);
    self.ret = .{ .slot = ret_slot, .exit = exit };
    try lower_stmt.lowerStmt(self, fd.body);
    try self.gotoBlock(exit);
    try self.builder.sealBlock(exit);
    self.cur = exit;

    const result: TypedValue = .{
        .v = try self.builder.readVariable(ret_slot.place, self.cur),
        .ty = ret_ty,
    };
    // §4.7.2.3/§4.7.2.4 read the writeback values while the scope is still up.
    var writeback: std.ArrayList([]const Mir.Value) = .empty;
    defer writeback.deinit(self.arena);
    for (fd.args, arg_slots.items) |formal, slots| {
        if (formal.direction != .output and formal.direction != .inout) continue;
        // A memory-backed formal has no per-element slots; read its cells.
        if (self.arrays.get(self.file.str(formal.name))) |info| if (info.mem != null) {
            const vals = try self.arena.alloc(Mir.Value, lower_shape.shapeCells(info.dims));
            var sub: [lower_shape.max_stack_dims]i64 = undefined;
            const idx = try lower_shape.subscriptBuf(self, &sub, info.dims.len);
            for (vals, 0..) |*v, k| {
                lower_shape.shapeSubscripts(info.dims, k, idx);
                v.* = (try lower_expr.arrayElemValue(self, self.file.str(formal.name), idx)).?.v;
            }
            try writeback.append(self.arena, vals);
            continue;
        };
        const vals = try self.arena.alloc(Mir.Value, slots.len);
        for (slots, vals) |slot, *v| v.* = try self.builder.readVariable(slot.place, self.cur);
        try writeback.append(self.arena, vals);
    }

    // ---- leave the function scope ----
    const left = self.inlining.pop().?;
    std.debug.assert(std.mem.eql(u8, left, name)); // a nested call popped its own
    std.debug.assert(self.loops.items.len == 0); // the body's loops popped their own
    std.debug.assert(log_mark <= self.scope_log.items.len);
    self.scope_log.shrinkRetainingCapacity(log_mark);
    self.vars.deinit(self.arena);
    self.arrays.deinit(self.arena);
    self.vars = saved_vars;
    self.arrays = saved_arrays;
    self.ret = saved_ret;
    self.restrict = saved_restrict;
    self.func_params = saved_func_params;
    self.loops.deinit(self.arena);
    self.loops = saved_loops;
    self.analog_for_base = saved_af;
    try leaveFuncConsts(self, &shadowed);
    self.active_genvars = saved_genvars;

    var w: usize = 0;
    for (fd.args, 0..) |formal, fi| {
        if (formal.direction != .output and formal.direction != .inout) continue;
        defer w += 1;
        // A `pre` formal has no source expression to write back into. §9.17.3
        // makes every `$limit` limiter formal `input` (E0814), so this guard
        // only keeps that true.
        if (fi < pre.len) continue;
        const actual = arg_exprs[fi - pre.len];
        const vals = writeback.items[w];
        if (formal.dims.len != 0) {
            // §4.7.2.3: "the last value assigned to the output argument is then
            // assigned to the corresponding analog variable reference that was
            // passed into the function", element by element, in declaration
            // order, into the caller's own storage.
            try funcArrayOut(self, actual, vals);
            continue;
        }
        // §3.2 a runtime subscript names no single storage slot, so the writeback
        // is the same masked one `a[i] = ...` takes. §4.7.2.3 puts no
        // constant-expression condition on the "analog variable reference".
        if (try lower_stmt.writeRuntimeIndex(self, actual, actual, .{ .v = vals[0], .ty = astTy(formal.ty) })) continue;
        const slot = try lower_stmt.resolveLvalue(self, actual) orelse continue;
        try lower_stmt.writeLvalue(self, slot, vals[0]);
    }
    std.debug.assert(w == writeback.items.len); // one writeback per output/inout formal
    return result;
}

// One `consts` entry a function scope replaced or removed, and what it held.
const Shadow = struct { name: []const u8, prev: ?Const };

// Installs the constants `fd`'s body sees (§4.7.1, §6.8): the caller's
// `genvars` taken out (a genvar is neither a local nor a module parameter),
// and each local parameter's fold in, shadowing a module parameter of the
// same name. Logs every entry it touches in `shadowed` for `leaveFuncConsts`.
// `func_params` is already `fd.params`, so a local default that names an
// earlier local folds to it.
fn enterFuncConsts(self: *Lower, fd: *const Ast.FuncDecl, genvars: []const []const u8, shadowed: *std.ArrayList(Shadow)) Oom!void {
    for (genvars) |g| {
        const prev = self.consts.fetchRemove(g) orelse continue;
        try shadowed.append(self.arena, .{ .name = g, .prev = prev.value });
    }
    for (fd.params) |*p| {
        const c = lower_constfold.constEval(self, p.default) orelse continue;
        const pname = self.file.str(p.name);
        try shadowed.append(self.arena, .{ .name = pname, .prev = self.consts.get(pname) });
        try self.consts.put(self.arena, pname, c);
    }
}

// Undoes `enterFuncConsts` in reverse, so a name touched twice ends at its
// first `prev`.
fn leaveFuncConsts(self: *Lower, shadowed: *std.ArrayList(Shadow)) Oom!void {
    while (shadowed.pop()) |sh| {
        if (sh.prev) |c| try self.consts.put(self.arena, sh.name, c) else _ = self.consts.remove(sh.name);
    }
}

/// The cell count of an array actual in one of §4.7.2.3's two shapes, "an
/// analog variable or an array assignment pattern of analog variables", or null
/// for anything else.
fn arrayActualCells(self: *Lower, actual: Ast.ExprId) Oom!?usize {
    const ex = &self.file.exprs;
    return switch (ex.tag(actual)) {
        .ident => if (self.arrays.get(self.file.str(ex.strOf(actual)))) |info| lower_shape.shapeCells(info.dims) else null,
        .assign_pattern, .concat => (try lower_shape.patternElems(self, actual)).len,
        .index => blk: {
            var buf: [lower_shape.max_stack_dims]Ast.ExprId = undefined;
            const s = (try lower_stmt.arrayRef(self, actual, &buf)) orelse break :blk null;
            break :blk lower_shape.shapeCells(s.info.dims[s.subs.len..]);
        },
        else => null, // else: §4.7.2.3 admits no third shape
    };
}

/// §4.7.2.3: "the argument passed into the function must be an analog variable
/// or an array assignment pattern of analog variables of equivalent size."
/// Copies in one Value per element of the formal. False when the actual has the
/// wrong size or is not one of those two shapes. Pattern elements lower as
/// expressions; `funcArrayOut` is where write-back needs storage.
fn funcArrayIn(self: *Lower, actual: Ast.ExprId, ty: Ty, out: []Mir.Value) Oom!bool {
    const ex = &self.file.exprs;
    switch (ex.tag(actual)) {
        .ident => {
            const aname = self.file.str(ex.strOf(actual));
            const info = self.arrays.get(aname) orelse return false;
            if (lower_shape.shapeCells(info.dims) != out.len) return false;
            var sub: [lower_shape.max_stack_dims]i64 = undefined;
            const idx = try lower_shape.subscriptBuf(self, &sub, info.dims.len);
            for (out, 0..) |*v, k| {
                lower_shape.shapeSubscripts(info.dims, k, idx);
                const el = (try lower_expr.arrayElemValue(self, aname, idx)) orelse return false;
                v.* = if (ty == .real) try self.toReal(el) else el.v;
            }
            return true;
        },
        .assign_pattern, .concat => {
            const elems = try lower_shape.patternElems(self, actual);
            if (elems.len != out.len) return false;
            for (elems, out) |e, *v| {
                const tv = try lower_expr.lowerExpr(self, e);
                v.* = if (ty == .real) try self.toReal(tv) else tv.v;
            }
            return true;
        },
        // §5.7 "a slice of an array variable" (`c[i]` of `real c[0:2][0:2]`)
        // is an array for assignment, and §4.7.3 says "the argument
        // expressions are assigned to the declared inputs": so a slice is an
        // analog variable an array formal takes, copied in cell by cell the
        // way `copyArraySlice` copies one.
        .index => {
            var buf: [lower_shape.max_stack_dims]Ast.ExprId = undefined;
            const s = (try lower_stmt.arrayRef(self, actual, &buf)) orelse return false;
            const sd = s.info.dims[s.subs.len..];
            if (lower_shape.shapeCells(sd) != out.len) return false;
            // False only after E0310 on a folded subscript: that is the
            // diagnostic, so the call is still well-shaped.
            if (!try lower_stmt.readSliceCells(self, actual, s, sd, out)) @memset(out, lower_var.zeroOf(ty));
            if (ty == .real) for (out) |*v| {
                v.* = try self.toReal(.{ .v = v.*, .ty = s.info.ty });
            };
            return true;
        },
        else => return false, // else: §4.7.2.3 admits no third shape; the caller reports E0511
    }
}

/// The write-back half of the same sentence. Each element of the actual is an
/// ordinary lvalue, so a pattern element that is not writable reports the usual
/// E0313/E0316 from `resolveLvalue` (§4.7.2.3 says "analog variables").
fn funcArrayOut(self: *Lower, actual: Ast.ExprId, vals: []const Mir.Value) Oom!void {
    const ex = &self.file.exprs;
    switch (ex.tag(actual)) {
        .ident => {
            const aname = self.file.str(ex.strOf(actual));
            const info = self.arrays.get(aname) orelse return;
            var key_buf: [lower_shape.elem_key_len]u8 = undefined;
            var sub: [lower_shape.max_stack_dims]i64 = undefined;
            const idx = try lower_shape.subscriptBuf(self, &sub, info.dims.len);
            for (vals, 0..) |v, k| {
                lower_shape.shapeSubscripts(info.dims, k, idx);
                if (info.mem == null and !self.vars.contains(try lower_shape.elemKey(self, &key_buf, aname, idx))) continue;
                try lower_var.writeElem(self, aname, info, idx, v);
            }
        },
        .assign_pattern, .concat => {
            for (try lower_shape.patternElems(self, actual), vals) |e, v| {
                const slot = try lower_stmt.resolveLvalue(self, e) orelse continue;
                try lower_stmt.writeLvalue(self, slot, v);
            }
        },
        // §5.7 "the array on the LHS of the assignment shall be an array
        // variable, a slice of an array variable ...": the slice receives.
        .index => {
            var buf: [lower_shape.max_stack_dims]Ast.ExprId = undefined;
            const s = (try lower_stmt.arrayRef(self, actual, &buf)) orelse return;
            _ = try lower_stmt.writeSliceCells(self, actual, s, s.info.dims[s.subs.len..], vals);
        },
        else => unreachable, // else: the call refused any other shape (`arrayActualCells`, `funcArrayIn`)
    }
}

test "§4.7 analog functions: recursion on the declarations, arity at the call" {
    // §4.7.3 "recursive functions are not permitted", called or not.
    try Lower.expectVerdict(
        \\module m(p);
        \\  inout p; electrical p;
        \\  analog function real f;
        \\    input a; real a;
        \\    f = h(a);
        \\  endfunction
        \\  analog function real h;
        \\    input a; real a;
        \\    h = f(a);
        \\  endfunction
        \\  analog I(p) <+ V(p);
        \\endmodule
    , .E0510);
    try Lower.expectVerdict(
        \\module m(p);
        \\  inout p; electrical p;
        \\  real r;
        \\  analog function real f;
        \\    input a; real a;
        \\    f = 2.0 * a;
        \\  endfunction
        \\  analog begin r = f(1.0, 2.0); I(p) <+ r * V(p); end
        \\endmodule
    , .E0511);
}

test "§4.7.2.3/§6.8 an array formal's bounds are the function's own declarations" {
    // §6.8 makes the analog function a scope, so its local `n` (2) shadows the
    // module's (3) in the formal's declaration as it does in the body: `v` is
    // two cells, and a two-element pattern is "of equivalent size".
    try Lower.expectVerdict(
        \\module m(p);
        \\  inout p; electrical p;
        \\  parameter integer n = 3;
        \\  real r;
        \\  analog function real sum2;
        \\    input v;
        \\    parameter integer n = 2;
        \\    real v[0:n-1];
        \\    sum2 = v[0] + v[1];
        \\  endfunction
        \\  analog begin r = sum2('{1.0, 2.0}); I(p) <+ r * V(p); end
        \\endmodule
    , null);
}
