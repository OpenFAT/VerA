//! §5.7 / A.8.5 array slices: a short subscript list in, the row it names
//! out, read into values (`readSliceCells`) or written from them
//! (`writeSliceCells`), with a run-time prefix as one select per cell.
//!
//! Cites: §3.2.2, §4.2.1.1, §5.7, A.8.5.
//!
//! Contents:
//! - `pub fn arrayRef(self: *Lower, e: Ast.ExprId, buf: *[lower_shape.max_stack_dims]Ast.ExprId) Oom!?ArraySlice`
//! - `pub fn copyArraySlice(self: *Lower, target: Ast.ExprId, value: Ast.ExprId) Oom!bool`
//! - `pub fn readSliceCells(self: *Lower, at_e: Ast.ExprId, s: ArraySlice, sd: []const lower_shape.Bounds, out: []Mir.Value) Oom!bool`
//! - `pub fn writeSliceCells(self: *Lower, at_e: Ast.ExprId, d: ArraySlice, dd: []const lower_shape.Bounds, vals: []const Mir.Value) Oom!bool`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Lower = @import("Lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_shape = @import("shape.zig");
const lower_var = @import("var.zig");
const lower_expr_select = @import("expr_select.zig");
const lower_assign = @import("assign.zig");
const lower_lvalue = @import("lvalue.zig");
const Oom = Lower.Oom;
const ArrayInfo = Lower.ArrayInfo;

/// §5.7 / A.8.5 an array reference that is not a scalar element: a whole array
/// (`subs.len == 0`) or a slice, whose subscript list is shorter than the declared
/// dimension list.
const ArraySlice = struct { name: []const u8, info: ArrayInfo, subs: []const Ast.ExprId };

/// Returns `e` as a whole-array or slice reference, or null for anything else,
/// including a full subscript list. `subs` may point into `buf`.
pub fn arrayRef(self: *Lower, e: Ast.ExprId, buf: *[lower_shape.max_stack_dims]Ast.ExprId) Oom!?ArraySlice {
    assert(e == .none or self.exprValid(e));
    assert(buf.len == lower_shape.max_stack_dims);
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .ident => {
            const name = self.file.str(ex.strOf(e));
            const info = self.arrays.get(name) orelse return null;
            return .{ .name = name, .info = info, .subs = &.{} };
        },
        .index => {
            const chain = (try lower_lvalue.indexChain(self, e, buf)) orelse return null;
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
pub fn copyArraySlice(self: *Lower, target: Ast.ExprId, value: Ast.ExprId) Oom!bool {
    assert(target == .none or self.exprValid(target));
    assert(value == .none or self.exprValid(value));
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
            const el = (try lower_expr_select.arrayElemValue(self, s.name, idx)) orelse return false;
            v.* = el.v;
        }
        return true;
    }
    // A dynamic prefix: one `$idx` switch per destination cell, over the same
    // cell of every candidate row. `runtimeArrayIndex` answers -1 for a
    // subscript outside its dimension, which `$idx` reads as the default 0, as
    // `lowerIndex` does for an out-of-range scalar read.
    const iv = try lower_assign.runtimeArrayIndex(self, s.subs, pdims);
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
            const el = (try lower_expr_select.arrayElemValue(self, s.name, idx)) orelse return false;
            try args.append(self.arena, el.v);
        }
        v.* = try self.call(callee, args.items);
    }
    return true;
}

/// The mirror image: writes `vals` into every cell of `d`'s slice. Asserts
/// that `dd` is the dimensions `d.subs` leaves.
pub fn writeSliceCells(self: *Lower, at_e: Ast.ExprId, d: ArraySlice, dd: []const lower_shape.Bounds, vals: []const Mir.Value) Oom!bool {
    assert(at_e == .none or self.exprValid(at_e));
    assert(self.blockValid(self.cur));
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
    const iv = try lower_assign.runtimeArrayIndex(self, d.subs, pdims);
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

// ---- private ----

/// The slice's leading subscripts, if every one of them folds: true when they
/// are also in range, false when §3.2.2 has been reported on them, null when at
/// least one is only known during the solve.
fn constPrefix(self: *Lower, at_e: Ast.ExprId, s: ArraySlice, out: []i64) Oom!?bool {
    assert(at_e == .none or self.exprValid(at_e));
    assert(out.len == s.subs.len);
    assert(s.subs.len <= s.info.dims.len);
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
