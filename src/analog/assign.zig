//! §5.7 procedural assignment: a target and a value in, the store out, for
//! scalars, constant and run-time array elements (§3.2.2), whole arrays and
//! assignment patterns, wide `reg`s (IEEE 1364-2005 §5.5.3), with the value
//! coerced to the target's type (§4.2.1).
//!
//! Cites: §3.2.2, §3.3, §4.2.1.1, §4.2.1.2, §4.2.13, §4.7.1, §4.7.2.3,
//! §5.4.1, §5.5.3, §5.7, A.8.5; IEEE 1364-2005 §5.5.3.
//!
//! Contents:
//! - `pub fn lowerAssign(self: *Lower, target: Ast.ExprId, value: Ast.ExprId) Oom!void`
//! - `pub fn writeRuntimeIndex(self: *Lower, target: Ast.ExprId, at_e: Ast.ExprId, tv: TypedValue) Oom!bool`
//! - `pub fn runtimeArrayIndex(self: *Lower, subs: []const Ast.ExprId, dims: []const lower_shape.Bounds) Oom!Mir.Value`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const diag = @import("diag");
const Lower = @import("Lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_expr = @import("expr.zig");
const lower_shape = @import("shape.zig");
const lower_var = @import("var.zig");
const lower_wide = @import("wide.zig");
const lower_expr_select = @import("expr_select.zig");
const lower_stmt = @import("stmt.zig");
const lower_slice = @import("slice.zig");
const lower_lvalue = @import("lvalue.zig");
const lower_noise_src = @import("noise_src.zig");
const Oom = Lower.Oom;
const TypedValue = Lower.TypedValue;
const ArrayInfo = Lower.ArrayInfo;

/// §5.7 procedural assignment. The target is an lvalue expression so array
/// elements (§3.2.2) work; the value is coerced to the target's type
/// (§4.2.1.1/§4.2.1.2).
pub fn lowerAssign(self: *Lower, target: Ast.ExprId, value: Ast.ExprId) Oom!void {
    assert(target == .none or self.exprValid(target));
    assert(value == .none or self.exprValid(value));
    assert(self.blockValid(self.cur));
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
    if (try lower_slice.copyArraySlice(self, target, value)) return;
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
    const lv = try lower_lvalue.resolveLvalue(self, target) orelse {
        _ = try lower_expr.lowerExpr(self, value); // keep collecting errors from the rhs
        return;
    };
    const tv = try assignValue(self, value);
    try lower_lvalue.writeLvalue(self, lv, try self.coerceTo(value, lv.ty, tv));
    if (ex.tag(target) == .ident) try lower_noise_src.noteVarNoise(self, self.file.str(ex.strOf(target)), value);
}

/// Writes an already lowered value to an array element with a runtime subscript,
/// as masked writes; §4.7.2.3's writeback has a `Mir.Value` and no expression.
/// Returns false when `target` is not such an element. `at_e` is only the
/// diagnostic site for §3.3's string conversion.
pub fn writeRuntimeIndex(self: *Lower, target: Ast.ExprId, at_e: Ast.ExprId, tv: TypedValue) Oom!bool {
    assert(target == .none or self.exprValid(target));
    assert(at_e == .none or self.exprValid(at_e));
    assert(self.valueValid(tv.v));
    if (!try isRuntimeElem(self, target)) return false;
    var subs: [lower_shape.max_stack_dims]Ast.ExprId = undefined;
    const chain = (try lower_lvalue.indexChain(self, target, &subs)).?;
    const name = self.file.str(chain.name);
    const info = self.arrays.get(name).?;
    if (!try lower_lvalue.checkSubscriptCount(self, target, name, info, chain.subs.len)) return true;

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
    assert(self.blockValid(self.cur));
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

// ---- private ----

/// The right-hand side of an assignment: its value, with no derivative under
/// `vera_nodiff`. Only a real carries one.
// ponytail: an array-to-array copy (`A = B`, a slice) keeps its elements'
// derivatives; stop them where they are assigned, or route those copies here.
fn assignValue(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    assert(e == .none or self.exprValid(e));
    assert(self.blockValid(self.cur));
    const tv = try lower_expr.lowerExpr(self, e);
    if (!lower_stmt.stopping(self) or tv.ty != .real) return tv;
    return .{ .v = try self.emit(.dstop, &.{tv.v}), .ty = .real };
}

/// §5.7 "The array on the LHS of the assignment shall be an array variable,
/// a slice of an array variable or an array parameter (when the default value
/// of the parameter is assigned)": past its declaration an array parameter is
/// no target, whole, sliced or one element. Reports E0312 and returns true
/// for one.
fn paramArrayTarget(self: *Lower, target: Ast.ExprId) Oom!bool {
    assert(target == .none or self.exprValid(target));
    assert(self.blockValid(self.cur));
    var subs: [lower_shape.max_stack_dims]Ast.ExprId = undefined;
    const chain = (try lower_lvalue.indexChain(self, target, &subs)) orelse return false;
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
    assert(target == .none or self.exprValid(target));
    assert(value == .none or self.exprValid(value));
    // Asked before the rhs is lowered: `false` falls through to the scalar path,
    // which lowers `value` itself, and lowering it twice would repeat side effects.
    if (!try isRuntimeElem(self, target)) return false;
    return writeRuntimeIndex(self, target, value, try assignValue(self, value));
}

/// Reports whether `target` is an element of a declared array whose subscript is
/// only known at run time; the precondition `assignRuntimeIndex` and §4.7.2.3's
/// output-argument writeback share.
fn isRuntimeElem(self: *Lower, target: Ast.ExprId) Oom!bool {
    assert(target == .none or self.exprValid(target));
    assert(self.blockValid(self.cur));
    var subs: [lower_shape.max_stack_dims]Ast.ExprId = undefined;
    const chain = (try lower_lvalue.indexChain(self, target, &subs)) orelse return false;
    for (chain.subs) |s| {
        if (lower_constfold.foldExpr(self, s, false) != null) continue;
        return self.arrays.contains(self.file.str(chain.name));
    }
    return false;
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
    assert(target == .none or self.exprValid(target));
    assert(value == .none or self.exprValid(value));
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
        const v = (try lower_expr_select.arrayElemValue(self, src_name, si)) orelse continue;
        if (dst.mem == null and !self.vars.contains(try lower_shape.elemKey(self, &key_buf, dst_name, di))) continue;
        // The element types are already known equivalent, so there is no
        // conversion to make, only the source's `Value` to re-bind.
        try lower_var.writeElem(self, dst_name, dst, di, v.v);
    }
    return true;
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
