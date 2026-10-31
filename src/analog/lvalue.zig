//! §5.7 assignable locations: a target expression in, its `Lvalue` (an SSA
//! place, a memory element or a wide `reg`) out, and the §3.2 subscript
//! checks every array reference shares.
//!
//! Cites: §3.2, §3.2.2, §4.2.1.1, §4.2.13, §5.5.3, §5.7, A.6.3; IEEE
//! 1364-2005 §5.5.3.
//!
//! Contents:
//! - `pub const Lvalue = struct`
//! - `pub fn readLvalue(self: *Lower, lv: Lvalue) Oom!Mir.Value`
//! - `pub fn writeLvalue(self: *Lower, lv: Lvalue, v: Mir.Value) Oom!void`
//! - `pub fn resolveLvalue(self: *Lower, e: Ast.ExprId) Oom!?Lvalue`
//! - `pub fn indexChain(self: *Lower, e: Ast.ExprId, buf: []Ast.ExprId) Oom!?IndexChain`
//! - `pub fn checkSubscriptCount(self: *Lower, e: Ast.ExprId, name: []const u8, info: ArrayInfo, n: usize) Oom!bool`
//! - `pub fn checkSubscripts(self: *Lower, e: Ast.ExprId, name: []const u8, info: ArrayInfo, idx: []const i64) Oom!bool`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const diag = @import("diag");
const Lower = @import("Lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_shape = @import("shape.zig");
const lower_var = @import("var.zig");
const lower_wide = @import("wide.zig");
const Ssa = @import("ssa.zig");
const lower_expr_select = @import("expr_select.zig");
const Oom = Lower.Oom;
const ArrayInfo = Lower.ArrayInfo;

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

/// The base identifier and the subscripts of `name[i][j]...` (§3.2), outermost first.
const IndexChain = struct { name: Ast.StrId, subs: []const Ast.ExprId };

/// Returns the current value at `lv`.
pub fn readLvalue(self: *Lower, lv: Lvalue) Oom!Mir.Value {
    assert(self.blockValid(self.cur));
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
    assert(self.valueValid(v));
    assert(self.blockValid(self.cur));
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
    assert(e == .none or self.exprValid(e));
    assert(self.blockValid(self.cur));
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
                // `lower_expr_select.lowerIndex`'s rule, so a write and a read of
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

/// Returns `e`'s base name and subscripts, or null when the base is not a plain
/// name (`f(x)[0]`). `subs` points into `buf`, or into the arena when deeper.
pub fn indexChain(self: *Lower, e: Ast.ExprId, buf: []Ast.ExprId) Oom!?IndexChain {
    assert(e == .none or self.exprValid(e));
    assert(buf.len != 0);
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
    assert(ex.tag(cur) == .ident); // the walk back ends at the base it started from
    return .{ .name = name, .subs = subs };
}

/// Checks that a reference supplies one subscript per declared dimension (§3.2),
/// returning false after a diagnostic. Separate from the range check because a
/// runtime subscript has a count but no value.
pub fn checkSubscriptCount(self: *Lower, e: Ast.ExprId, name: []const u8, info: ArrayInfo, n: usize) Oom!bool {
    assert(e == .none or self.exprValid(e));
    assert(info.dims.len != 0); // an array has at least one dimension
    if (n == info.dims.len) return true;
    try self.err(self.file.exprs.mainTok(e), .E0356, "`{s}` is declared with {d} dimension(s) and is indexed with {d}", .{
        name, info.dims.len, n,
    });
    return false;
}

/// Checks each subscript against its dimension's declared bounds (§3.2.2),
/// returning false after a diagnostic.
pub fn checkSubscripts(self: *Lower, e: Ast.ExprId, name: []const u8, info: ArrayInfo, idx: []const i64) Oom!bool {
    assert(e == .none or self.exprValid(e));
    assert(info.dims.len != 0);
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

// ---- private ----

fn arrayElem(self: *Lower, e: Ast.ExprId, name: []const u8, idx: []const i64) Oom!?Lvalue {
    assert(e == .none or self.exprValid(e));
    assert(name.len != 0);
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
