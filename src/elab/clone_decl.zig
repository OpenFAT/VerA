//! The declaration clone: a child's parameters, variables, events, functions
//! and ranges → new rows under their flat names, with §6.3 overrides applied
//! and §3.4.4's array sizes judged. Also the local-scope hiding a block or
//! function body needs (§4.7.1, §5.3.2).
//! Cites: LRM §3.4.4, §3.4.7, §4.7.1, §5.3.2, §6.3, §9.18.
//!
//! Contents:
//! - `pub const HiddenName = struct`
//! - `pub fn cloneParams(...)`
//! - `pub fn cloneDim(self: *Flatten, d: ?Ast.Dim) design.Error!?Ast.Dim`
//! - `pub fn cloneDelay(self: *Flatten, d: Ast.Delay3) design.Error!Ast.Delay3`
//! - `pub fn cloneEvent(self: *Flatten, e: Ast.EventDecl) design.Error!Ast.EventDecl`
//! - `pub fn cloneVar(self: *Flatten, v: Ast.VarDecl) design.Error!Ast.VarDecl`
//! - `pub fn cloneFunc(self: *Flatten, fd: Ast.FuncDecl) design.Error!Ast.FuncDecl`
//! - `pub fn hide(self: *Flatten, list: *std.ArrayList(HiddenName), name: Ast.StrId) void`
//! - `pub fn unhide(self: *Flatten, list: []const HiddenName) void`
//! - `pub fn cloneLocalParams(self: *Flatten, ps: []const Ast.ParamDecl) design.Error![]const Ast.ParamDecl`
//! - `pub fn cloneLocalVars(self: *Flatten, vs: []const Ast.VarDecl) design.Error![]const Ast.VarDecl`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const design = @import("design.zig");
const Flatten = @import("Flatten.zig");
const elaborate = @import("elaborate.zig");
const clone_expr = @import("clone_expr.zig");
const clone_stmt = @import("clone_stmt.zig");
const flat_name = @import("flat_name.zig");
const fold = @import("fold.zig");
const alias = @import("alias.zig");
const hier_param = @import("hier_param.zig");
const fixture = @import("fixture.zig");

/// A rename-map entry `hide` removed, restored by `unhide`.
pub const HiddenName = struct { name: Ast.StrId, was: ?Ast.StrId };

comptime {
    // One row per local of every cloned block and function; 12 B budget.
    assert(@sizeOf(HiddenName) == 12);
}

/// Appends `params` and `aliases` to the flat design under their flat names,
/// taking each value from `over` when overridden (§6.3). Every cloned
/// parameter is local: the device's model card is the top's parameter list,
/// and a child's value is fixed at elaboration. Reports E0921 on a §3.4.4
/// array size mismatch.
pub fn cloneParams(
    self: *Flatten,
    params: []const Ast.ParamDecl,
    aliases: []const Ast.AliasParam,
    over: *const std.AutoHashMapUnmanaged(Ast.StrId, Ast.ExprId),
) design.Error!void {
    for (params) |p| {
        var out = p;
        out.name = flat_name.flat(self, p.name);
        out.ranges = try cloneRanges(self, p.ranges);
        out.dims = try cloneDims(self, p.dims);
        out.packed_range = try cloneDim(self, p.packed_range);
        if (over.get(p.name)) |v| {
            out.default = v; // already in the parent's flat namespace
            out.is_override = true;
        } else {
            out.default = try clone_expr.cloneExpr(self, p.default);
        }
        out.is_local = true;
        try self.decls.params.append(self.ctx.arena, out);
        try fold.syncParamValues(self);
        if (out.dims.len != 0) try checkArraySize(self, out, over.contains(p.name));
    }
    for (aliases) |al| {
        if (alias.original(self.ctx.file, params, aliases, al)) |target|
            try self.expression_aliases.append(self.ctx.arena, .{
                .alias = flat_name.flat(self, al.alias),
                .target = flat_name.flat(self, target),
            });
        if (hier_param.Kind.fromName(self.ctx.file.str(al.target))) |kind| {
            // An inlined alias denotes THIS instance's resolved value. It
            // must not declare another top-level model-card system alias.
            const value = self.unit.hier.get(kind);
            try self.decls.params.append(self.ctx.arena, .{
                .name = flat_name.flat(self, al.alias),
                .ty = .real,
                .default = if (value == .none) try self.ctx.file.exprs.addReal(self.ctx.arena, 0, kind.initial()) else value,
                .is_local = true,
                .main_tok = 0,
            });
            try fold.syncParamValues(self);
        } else try self.decls.aliasparams.append(self.ctx.arena, .{
            .alias = flat_name.flat(self, al.alias),
            .target = flat_name.flat(self, al.target),
        });
    }
}

/// Clones a range's bounds into the flat namespace; null stays null.
pub fn cloneDim(self: *Flatten, d: ?Ast.Dim) design.Error!?Ast.Dim {
    const dim = d orelse return null;
    return .{ .msb = try clone_expr.cloneExpr(self, dim.msb), .lsb = try clone_expr.cloneExpr(self, dim.lsb) };
}

/// Clones a rise/fall/off delay into the flat namespace.
pub fn cloneDelay(self: *Flatten, d: Ast.Delay3) design.Error!Ast.Delay3 {
    return .{ .rise = try clone_expr.cloneExpr(self, d.rise), .fall = try clone_expr.cloneExpr(self, d.fall), .off = try clone_expr.cloneExpr(self, d.off) };
}

/// Returns named event `e` under its flat name, dimensions cloned.
pub fn cloneEvent(self: *Flatten, e: Ast.EventDecl) design.Error!Ast.EventDecl {
    return .{ .name = flat_name.flat(self, e.name), .dims = try cloneDims(self, e.dims), .main_tok = e.main_tok };
}

/// Returns `v` under its flat name, with dimensions and initializer cloned.
pub fn cloneVar(self: *Flatten, v: Ast.VarDecl) design.Error!Ast.VarDecl {
    var out = v;
    out.name = flat_name.flat(self, v.name);
    out.dims = try cloneDims(self, v.dims);
    out.packed_range = try cloneDim(self, v.packed_range);
    out.init = try clone_expr.cloneExpr(self, v.init);
    return out;
}

/// Clones a §4.7.1 user function under its flat name. Its formals and locals
/// are the function's own scope, so they are hidden from the unit's rename
/// map for the body; otherwise a formal sharing a module-level name would be
/// rewritten to the module's.
pub fn cloneFunc(self: *Flatten, fd: Ast.FuncDecl) design.Error!Ast.FuncDecl {
    var out = fd;
    out.name = flat_name.flat(self, fd.name);
    var hidden: std.ArrayList(HiddenName) = try .initCapacity(self.ctx.arena, fd.args.len + fd.params.len + fd.vars.len);
    for (fd.args) |arg| hide(self, &hidden, arg.name);
    for (fd.params) |p| hide(self, &hidden, p.name);
    for (fd.vars) |v| hide(self, &hidden, v.name);
    out.params = try cloneLocalParams(self, fd.params);
    out.vars = try cloneLocalVars(self, fd.vars);
    out.body = try clone_stmt.cloneStmt(self, fd.body);
    unhide(self, hidden.items);
    return out;
}

/// Removes `name` from the unit's rename map for a local scope and records
/// the old binding in `list`, which the caller sized for every local it hides.
/// The caller restores the whole list with `unhide`, in reverse order.
pub fn hide(self: *Flatten, list: *std.ArrayList(HiddenName), name: Ast.StrId) void {
    list.appendAssumeCapacity(.{ .name = name, .was = self.unit.rename.get(name) });
    _ = self.unit.rename.remove(name);
}

pub fn unhide(self: *Flatten, list: []const HiddenName) void {
    // Reverse, so a name hidden twice (a formal and a body local) comes back
    // to the outermost saved binding.
    var i = list.len;
    while (i > 0) {
        i -= 1;
        if (list[i].was) |w| {
            self.unit.rename.putAssumeCapacity(list[i].name, w);
        } else {
            _ = self.unit.rename.remove(list[i].name);
        }
    }
}

/// A block's or function's own declarations: cloned for their initializers
/// and ranges, but not renamed: they are locals of a scope lowering already
/// pushes and pops.
pub fn cloneLocalParams(self: *Flatten, ps: []const Ast.ParamDecl) design.Error![]const Ast.ParamDecl {
    if (ps.len == 0) return &.{};
    const out = try self.ctx.arena.alloc(Ast.ParamDecl, ps.len);
    for (ps, out) |p, *o| {
        o.* = p;
        o.default = try clone_expr.cloneExpr(self, p.default);
        o.dims = try cloneDims(self, p.dims);
        o.packed_range = try cloneDim(self, p.packed_range);
        o.ranges = try cloneRanges(self, p.ranges);
    }
    return out;
}

pub fn cloneLocalVars(self: *Flatten, vs: []const Ast.VarDecl) design.Error![]const Ast.VarDecl {
    if (vs.len == 0) return &.{};
    const out = try self.ctx.arena.alloc(Ast.VarDecl, vs.len);
    for (vs, out) |v, *o| {
        o.* = v;
        o.dims = try cloneDims(self, v.dims);
        o.packed_range = try cloneDim(self, v.packed_range);
        o.init = try clone_expr.cloneExpr(self, v.init);
    }
    return out;
}

// ---- private ----

/// §3.4.4: "An array assigned to an instance of a module to override the
/// default value of an array parameter shall be of the exact size of the
/// parameter array", and "If the array size is changed, the parameter array
/// shall be assigned an array of the new size". Judged on the flat parameter
/// `p`, whose range and value already have overrides applied, so both rules
/// are one element-count comparison.
///
/// ponytail: "from the same module as the parameter assignment that changed
/// the parameter array size" is not checked; a replacement of the right size
/// from a defparam elsewhere is accepted. The upgrade is recording each
/// override's source module in `over`.
fn checkArraySize(self: *Flatten, p: Ast.ParamDecl, overridden: bool) design.Error!void {
    const got, const want = patternMismatch(self, p.default, p.dims) orelse return;
    const tok = if (overridden) self.ctx.file.exprs.mainTok(p.default) else p.main_tok;
    if (overridden)
        try self.err(tok, .E0921, "the array assigned to `{s}` has {d} elements, and its declared range has {d}", .{ self.ctx.file.str(p.name), got, want })
    else
        try self.err(tok, .E0921, "an override resized `{s}` to {d} elements, and no array of the new size was assigned to it (its default has {d})", .{ self.ctx.file.str(p.name), want, got });
}

/// The first `{ got, want }` element-count disagreement between assignment
/// pattern `e` and `dims`, outermost dimension first; null when they agree
/// or when either side does not fold (lowering owns those diagnostics).
fn patternMismatch(self: *Flatten, e: Ast.ExprId, dims: []const Ast.Dim) ?struct { i128, i128 } {
    if (dims.len == 0) return null;
    const ex = &self.ctx.file.exprs;
    if (e == .none or (ex.tag(e) != .assign_pattern and ex.tag(e) != .concat)) return null;
    const msb = fold.constIntFlat(self, dims[0].msb) orelse return null;
    const lsb = fold.constIntFlat(self, dims[0].lsb) orelse return null;
    var elems = ex.args(e);
    var reps: i64 = 1;
    // A.8.1's `'{N{...}}` with a non-literal count: see `Ast.Tag.pattern_repl`.
    if (elems.len == 1 and ex.tag(elems[0]) == .pattern_repl) {
        reps = fold.constIntFlat(self, ex.lhs(elems[0])) orelse return null;
        elems = ex.args(ex.rhs(elems[0]));
    }
    const got = @as(i128, reps) * elems.len;
    const want: i128 = @intCast(@abs(@as(i128, msb) - lsb) + 1);
    if (got != want) return .{ got, want };
    for (elems) |el| if (patternMismatch(self, el, dims[1..])) |m| return m;
    return null;
}

fn cloneDims(self: *Flatten, dims: []const Ast.Dim) design.Error![]const Ast.Dim {
    if (dims.len == 0) return &.{};
    const out = try self.ctx.arena.alloc(Ast.Dim, dims.len);
    for (dims, out) |d, *o| o.* = (try cloneDim(self, d)).?;
    return out;
}

fn cloneRanges(self: *Flatten, rs: []const Ast.ValueRange) design.Error![]const Ast.ValueRange {
    if (rs.len == 0) return &.{};
    const out = try self.ctx.arena.alloc(Ast.ValueRange, rs.len);
    for (rs, out) |r, *o| {
        o.* = r;
        o.lo = try clone_expr.cloneExpr(self, r.lo);
        o.hi = try clone_expr.cloneExpr(self, r.hi);
    }
    return out;
}

test "§4.7.1 a function's formal hides a module name for the function body only" {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\module top(p); inout p; electrical p; kid u(p); endmodule
        \\module kid(a); inout a; electrical a; parameter real x = 2.0;
        \\  analog function real fn; input x; real x; fn = x; endfunction
        \\  analog I(a) <+ fn(x) * V(a);
        \\endmodule
    );
    const d = try elaborate.elaborate(f.ctx());
    const ex = &f.file.exprs;
    const func = d.top.functions[0];
    try std.testing.expectEqualStrings("u.fn", f.file.str(func.name));
    // Inside, `x` is the formal; the return variable is the renamed function.
    const body = f.file.stmt(func.body).assign;
    try std.testing.expectEqualStrings("x", f.file.str(ex.strOf(body.value)));
    try std.testing.expectEqualStrings("u.fn", f.file.str(ex.strOf(body.target)));
    // Outside, `x` is the instance's parameter again.
    const call = ex.lhs(f.file.stmt(d.top.analog[0].body).contribute.rhs);
    try std.testing.expectEqualStrings("u.fn", f.file.str(ex.strOf(call)));
    try std.testing.expectEqualStrings("u.x", f.file.str(ex.strOf(ex.args(call)[0])));
}

test "§3.4.4 an array override must have the parameter's size (E0921)" {
    const src =
        \\module top(p); inout p; electrical p; kid #(.c('{{{s}}})) u(p); endmodule
        \\module kid(a); inout a; electrical a; parameter real c[0:1] = '{{0.0, 0.0}}; endmodule
    ;
    var bad: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer bad.deinit();
    try fixture.parse(&bad, try bad.arena.allocator().print(src, .{"1.0, 2.0, 3.0"}));
    try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(bad.ctx()));
    try std.testing.expect(fixture.hasCode(&bad.bag, .E0921));

    var good: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer good.deinit();
    try fixture.parse(&good, try good.arena.allocator().print(src, .{"1.0, 2.0"}));
    _ = try elaborate.elaborate(good.ctx());
}
