//! Selects: `name[i]` and `name[hi:lo]` in, the element or bit grouping
//! out. A §3.2.2 array element (scalarized, or one `$idx` switch / memory
//! load for a run-time subscript), a §3.4.4 parameter array element, a
//! §7.3.1 constant bit- or part-select of a `reg`, or an element of a
//! digital array the analog block reads.
//!
//! Cites: §2.8, §3.2, §3.2.1, §3.2.2, §3.4, §3.4.4, §4.2.1, §4.2.1.1, §4.4,
//! §7.3.1 (Table 7-1); IEEE 1364-2005 §4.2.1, §5.5.1.
//!
//! Contents:
//! - `pub fn lowerIndex(self: *Lower, e: Ast.ExprId) Oom!TypedValue`
//! - `pub fn selectBound(self: *Lower, e: Ast.ExprId) ?i64`
//! - `pub fn selectPos(r: Lower.RegRange, k: i64) ?u32`
//! - `pub fn regWordValue(self: *Lower, name: []const u8, k: u32) Oom!Mir.Value`
//! - `pub fn outsideRange(self: *Lower, sub: Ast.ExprId, name: []const u8, k: i64, w: u32) Oom!TypedValue`
//! - `pub fn arrayElemValue(self: *Lower, name: []const u8, idx: []const i64) Oom!?TypedValue`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const constfold = @import("frontend").constfold;
const Mir = @import("ir").Mir;
const naming = @import("ir").names;
const diag = @import("diag");
const Lower = @import("Lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_event = @import("event.zig");
const lower_stmt = @import("stmt.zig");
const lower_shape = @import("shape.zig");
const lower_var = @import("var.zig");
const lower_wide = @import("wide.zig");
const lower_expr = @import("expr.zig");
const lower_expr_name = @import("expr_name.zig");
const Oom = Lower.Oom;
const TypedValue = Lower.TypedValue;
const VarSlot = Lower.VarSlot;
const poison = Lower.poison;
const astTy = Lower.astTy;

/// §3.2.2 array element read. A constant index selects one scalarized
/// element; a runtime index becomes a `$idx` call carrying every element, which
/// codegen renders as ONE `switch` — a jump table, so the read is O(1) in the
/// array's extent (the array is scalarized, so there is no memory to index).
pub fn lowerIndex(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    assert(e == .none or self.exprValid(e));
    assert(self.blockValid(self.cur));
    var subs: [lower_shape.max_stack_dims]Ast.ExprId = undefined;
    const chain = (try lower_stmt.indexChain(self, e, &subs)) orelse {
        try self.err(self.file.exprs.mainTok(e), .E0330, "only `name[<index>]` is supported", .{});
        return poison;
    };
    const name = self.file.str(chain.name);
    const info = self.arrays.get(name) orelse {
        if (chain.subs.len == 1) if (self.discrete_arrays.get(name)) |rg| return discreteElem(self, name, rg.lo, rg.hi, chain.subs[0]);
        if (chain.subs.len == 1) if (self.reg_ranges.get(name)) |rr| {
            if (self.vars.get(name)) |slot| return lowerRegSelect(self, e, name, .{ .slot = slot }, rr, chain.subs[0]);
            if (self.out.discrete_inputs.contains(name)) return lowerRegSelect(self, e, name, .input, rr, chain.subs[0]);
        };
        try self.err(self.file.exprs.mainTok(e), .E0309, "`{s}`", .{name});
        return poison;
    };

    try lower_event.captureTimerArray(self, name);
    var idx: [lower_shape.max_stack_dims]i64 = undefined;
    const at = try lower_shape.subscriptBuf(self, &idx, chain.subs.len);
    var all_const = true;
    for (chain.subs, at) |s, *o| {
        // `foldExpr(.., false)`, not `constEval`: a §3.4 parameter is
        // overridable by the model card, so folding `a[n-1]` through `n`'s
        // default would bake one element into the device for every card.
        if (lower_constfold.foldExpr(self, s, false)) |c| {
            // §4.2.1.1 converts a real subscript by rounding to the nearest
            // integer; an infinity, a NaN, or a magnitude past i64 has none, so
            // the subscript names no element: E0310, as for a constant
            // subscript outside the declared range.
            o.* = c.asIntExact() orelse {
                try self.err(self.file.exprs.mainTok(s), .E0310, "subscript {e} of `{s}` has no integer value, so it lies outside every dimension", .{ c.asReal(), name });
                return poison;
            };
        } else all_const = false;
    }
    if (!try lower_stmt.checkSubscriptCount(self, e, name, info, at.len)) return poison;
    if (all_const) {
        if (!try lower_stmt.checkSubscripts(self, e, name, info, at)) return poison;
        return (try arrayElemValue(self, name, at)) orelse poison;
    }

    // `$idx` emits one switch over the scalarized elements. Both reads and
    // writes use the same declared-order flattening and per-dimension bounds.
    const iv = try lower_stmt.runtimeArrayIndex(self, chain.subs, info.dims);
    const ty = info.ty;
    // A memory-backed array reads one element of its storage; an invalid
    // subscript (-1) reads the zero the `$idx` switch's default gives.
    if (info.mem) |m| return .{ .v = try lower_var.loadElem(self, m, ty, iv), .ty = ty };
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    try vals.append(self.arena, .zero);
    try vals.append(self.arena, iv);
    for (0..lower_shape.shapeCells(info.dims)) |k| {
        lower_shape.shapeSubscripts(info.dims, k, at);
        const el = (try arrayElemValue(self, name, at)) orelse return poison;
        try vals.append(self.arena, if (ty == .real) try self.toReal(el) else el.v);
    }
    // The callee name IS the result type — `callee.ty` and `sysFuncTy`
    // agree by construction, the `$sscanf$int` rule.
    const callee: []const u8 = switch (ty) {
        .real => "$idx",
        .integer => "$idx$int",
        .string => "$idx$str",
        .wide => unreachable, // an array element is never `.wide` (`lower_var.declareVarDecl`)
    };
    return .{ .v = try self.call(callee, vals.items), .ty = ty };
}

/// A select bound: a constant the folder can make an integer of, or null.
pub fn selectBound(self: *Lower, e: Ast.ExprId) ?i64 {
    assert(e == .none or self.exprValid(e));
    const c = lower_constfold.foldExpr(self, e, false) orelse return null;
    assert(e != .none); // `.none` folds to nothing
    return c.asIntExact();
}

/// Where bit `k` of a `reg` with range `r` sits above its LSB (IEEE 1364
/// §4.2.1), or null outside the range.
pub fn selectPos(r: Lower.RegRange, k: i64) ?u32 {
    assert(r.width != 0); // a declared range holds at least one bit
    const d = if (r.asc) r.right - k else k - r.right;
    if (d < 0 or d >= r.width) return null;
    assert(d < r.width);
    return @intCast(d);
}

/// Word `k` of a discrete `reg` input: the `Model` field the host writes it in.
pub fn regWordValue(self: *Lower, name: []const u8, k: u32) Oom!Mir.Value {
    assert(name.len != 0);
    const key = if (k == 0) name else try naming.wordField(self.arena, name, k);
    const pi = self.param_index.get(key).?; // `declareDiscreteInputs` added every word
    assert(pi < self.param_values.items.len);
    return self.param_values.items[pi];
}

/// E0310: bit `k` lies outside `name`'s `w`-bit range.
pub fn outsideRange(self: *Lower, sub: Ast.ExprId, name: []const u8, k: i64, w: u32) Oom!TypedValue {
    assert(sub == .none or self.exprValid(sub));
    assert(w != 0); // a declared range holds at least one bit
    try self.err(self.file.exprs.mainTok(sub), .E0310, "bit {d} lies outside `{s}`'s {d}-bit range", .{ k, name, w });
    return poison;
}

/// The Value of one scalarized element — a variable array (§3.2.2) or a
/// parameter array (§3.4.4).
pub fn arrayElemValue(self: *Lower, name: []const u8, idx: []const i64) Oom!?TypedValue {
    assert(self.blockValid(self.cur));
    assert(idx.len != 0); // one subscript per dimension, and an array has one
    try lower_event.captureTimerArray(self, name);
    if (self.arrays.get(name)) |info| if (info.mem) |m| return .{
        .v = try lower_var.loadElem(self, m, info.ty, try self.mir.addIntConst(self.arena, lower_shape.flatIndex(info.dims, idx))),
        .ty = info.ty,
    };
    var key_buf: [lower_shape.elem_key_len]u8 = undefined;
    const key = try lower_shape.elemKey(self, &key_buf, name, idx);
    if (self.vars.get(key)) |slot|
        return .{ .v = try lower_var.analogRead(self, try self.builder.readVariable(slot.place, self.cur), slot.reg_width), .ty = slot.ty };
    if (self.param_index.get(key)) |pi|
        return .{ .v = self.param_values.items[pi], .ty = astTy(self.out.params.items[pi].ty) };
    return null;
}

// ---- private ----

/// §7.3.1 a constant bit- or part-select of a `reg` read from the analog
/// context: the selected grouping, shifted to bit 0 and zero-extended by
/// `analogRead`, which judges the GROUPING's width against Table 7-1's
/// "Access of discrete bit groupings with greater than 31 bits is illegal".
/// So `r[30:0]` of a `reg [39:0] r` is legal and `r` itself is E0222.
/// The right-hand bound of a packed range is its LSB in either direction
/// (IEEE 1364-2005 §4.2.1), so bit k sits |k - right| places above bit 0.
///
/// The `reg` is a variable (`slot`) or a mixed module's discrete input
/// (`input`, the `Model` field the host writes). Bits 0 to 31 are its §3.2
/// integer's. Above them: a discrete input's further 32-bit words
/// (`Lowered.discrete_words`), the literal a variable holds for the whole
/// analysis (`Lower.reg_consts`), or every bit of a wide `reg` the analog
/// context computes (`Ty.wide`, `lower_wide.select`).
fn lowerRegSelect(self: *Lower, e: Ast.ExprId, name: []const u8, src: union(enum) { slot: VarSlot, input }, rr: Lower.RegRange, sub: Ast.ExprId) Oom!TypedValue {
    assert(e == .none or self.exprValid(e));
    assert(sub == .none or self.exprValid(sub));
    assert(self.blockValid(self.cur));
    const ex = &self.file.exprs;
    const ranged = ex.tag(sub) == .range;
    const hi_e, const lo_e = if (ranged) .{ ex.lhs(sub), ex.rhs(sub) } else .{ sub, sub };
    if (ex.tag(sub) == .indexed_range) {
        try self.err(ex.mainTok(sub), .E0329, "an indexed part-select of `{s}` read from the analog context", .{name});
        return poison;
    }
    const a: i64, const b: i64 = bounds: {
        if (selectBound(self, hi_e)) |ka| if (selectBound(self, lo_e)) |kb| break :bounds .{ ka, kb };
        try self.err(ex.mainTok(sub), .E0329, "a select of `{s}` read from the analog context needs constant bounds", .{name});
        return poison;
    };
    const w = rr.width;
    const pa = selectPos(rr, a) orelse return outsideRange(self, sub, name, a, w);
    const pb = selectPos(rr, b) orelse return outsideRange(self, sub, name, b, w);
    const lo = @min(pa, pb);
    const width = @max(pa, pb) - lo + 1;
    // Table 7-1's limit on the grouping (E0222, `analogRead`).
    if (width > 31) return .{ .v = try lower_var.analogRead(self, .undef, width), .ty = .integer };
    switch (src) {
        .slot => |slot| if (slot.ty == .wide) return .{ .v = try lower_wide.select(self, slot, lo, width), .ty = .integer },
        .input => {},
    }
    // Bits 0 to 31.
    if (@max(pa, pb) < 32) {
        const raw = switch (src) {
            .slot => |slot| try self.builder.readVariable(slot.place, self.cur),
            .input => (try lower_expr_name.lookupName(self, e, name)).v,
        };
        const shifted = if (lo == 0) raw else try self.emit(.shr, &.{ raw, try self.mir.addIntConst(self.arena, lo) });
        return .{ .v = try lower_var.analogRead(self, shifted, width), .ty = .integer };
    }
    switch (src) {
        // The literal's bits, zero- or sign-extended to the `reg`'s width as
        // an assignment extends it (IEEE 1364-2005 §5.5.1).
        .slot => {
            const lit = self.reg_consts.get(name) orelse unreachable; // every other `reg` past 32 bits is `.wide` (`lower_var.declareVarDecl`)
            var v: i64 = 0;
            for (0..width) |i| if (literalBit(self, lit, lo + @as(u32, @intCast(i)))) {
                v |= @as(i64, 1) << @intCast(i);
            };
            return .{ .v = try self.mir.addIntConst(self.arena, v), .ty = .integer };
        },
        // Words k0 and k1 of the host's copy: `>>` and `<<` act on 32 bits
        // (§3.2.1), which is each word's width, and `analogRead` masks.
        .input => {
            if (self.in_d2a_body and self.out.discrete_snaps.contains(name)) {
                try self.err(ex.mainTok(sub), .E0329, "`{s}[{d}:{d}]` reaches above bit 31 under an explicit D2A event, whose region-1b copy holds bits 0 to 31", .{ name, a, b });
                return poison;
            }
            const k0 = lo / 32;
            const k1 = (lo + width - 1) / 32;
            const s = lo % 32;
            const w0 = try regWordValue(self, name, k0);
            var v = if (s == 0) w0 else try self.emit(.shr, &.{ w0, try self.mir.addIntConst(self.arena, s) });
            if (k1 != k0) v = try self.emit(.bitor, &.{ v, try self.emit(.shl, &.{ try regWordValue(self, name, k1), try self.mir.addIntConst(self.arena, 32 - s) }) });
            return .{ .v = try lower_var.analogRead(self, v, width), .ty = .integer };
        },
    }
}

/// Bit `k` of the literal initializer `lit` (`.none`: zero) of a `reg`.
fn literalBit(self: *Lower, lit: Ast.ExprId, k: u32) bool {
    assert(lit == .none or self.exprValid(lit));
    if (lit == .none) return false;
    const ex = &self.file.exprs;
    if (ex.tag(lit) == .int_literal) {
        const x = ex.intValue(lit);
        return (x >> @as(u6, @intCast(@min(k, 63)))) & 1 != 0;
    }
    const l = ex.logicValue(lit);
    assert(l.width != 0);
    if (k < l.width) return l.bit(k) == .one;
    return l.signed and l.bit(l.width - 1) == .one;
}

/// §7.3.1 `name[index]` of a digital array the analog block reads, one
/// input per element (`Lower.discrete_arrays`): a constant index is that
/// element, a run-time one a select over all of them. An index outside
/// `[lo, hi]` reads 0, as an analog array's out-of-range read does.
fn discreteElem(self: *Lower, name: []const u8, lo: i64, hi: i64, sub: Ast.ExprId) Oom!TypedValue {
    assert(sub == .none or self.exprValid(sub));
    assert(self.blockValid(self.cur));
    std.debug.assert(lo <= hi);
    const elem = struct {
        fn read(l: *Lower, base: []const u8, k: i64) Oom!Mir.Value {
            const key = try l.arena.print("{s}[{d}]", .{ base, k });
            const pi = l.param_index.get(key).?; // `declareDiscreteArray` added every element
            return l.param_values.items[pi];
        }
    };
    if (lower_constfold.constEval(self, sub)) |c| if (c.asIntExact()) |k| {
        if (k < lo or k > hi) return .{ .v = try self.mir.addIntConst(self.arena, 0), .ty = .integer };
        return .{ .v = try elem.read(self, name, k), .ty = .integer };
    };
    const idx = try lower_expr.lowerExpr(self, sub);
    if (idx.ty != .integer) {
        try self.err(self.file.exprs.mainTok(sub), .E0311, "the index of `{s}` is not an integer", .{name});
        return poison;
    }
    var out = try self.mir.addIntConst(self.arena, 0);
    var k = lo;
    while (k <= hi) : (k += 1) {
        const eq = try self.emit(.ieq, &.{ idx.v, try self.mir.addIntConst(self.arena, k) });
        out = try self.emit(.select, &.{ try self.toBool(.{ .v = eq, .ty = .integer }), try elem.read(self, name, k), out });
    }
    return .{ .v = out, .ty = .integer };
}

test "lookupName/lowerIndex: §2.8 names and §3.2.2/§7.3.1 selects" {
    const cases = [_]struct { body: []const u8, want: ?diag.Code }{
        .{ .body = "    y = nosuch;", .want = .E0314 },
        // A net is no value; §4.4 reaches it through an access function.
        .{ .body = "    y = p;", .want = .E0315 },
        .{ .body = "    y = r[0];", .want = .E0309 },
        // §7.3.1 a constant bit- or part-select of a `reg`, inside its range.
        .{ .body = "    k = rg[3:0] + rg[7];", .want = null },
        .{ .body = "    k = rg[8];", .want = .E0310 },
        .{ .body = "    j = 1;\n    k = rg[j];", .want = .E0329 },
        .{ .body = "    j = 1;\n    k = rg[j +: 2];", .want = .E0329 },
    };
    for (cases) |c| try Lower.expectBodyVerdict(lower_expr.test_decls, c.body, c.want);
}

test "selectPos: every bit of every small range against a walk of the range" {
    // IEEE 1364-2005 §4.2.1: the right-hand bound is the LSB in either
    // direction. Oracle: walk the declared range from its right bound,
    // counting places, and compare with `selectPos` for every k near it.
    var right: i64 = -3;
    while (right <= 3) : (right += 1) for ([_]bool{ false, true }) |asc| for (1..6) |width| {
        const r: Lower.RegRange = .{ .right = right, .asc = asc, .width = @intCast(width) };
        var k: i64 = -12;
        while (k <= 12) : (k += 1) {
            var want: ?u32 = null;
            for (0..width) |pos| {
                const bit = if (asc) right - @as(i64, @intCast(pos)) else right + @as(i64, @intCast(pos));
                if (bit == k) want = @intCast(pos);
            }
            try std.testing.expectEqual(want, selectPos(r, k));
        }
    };
}
