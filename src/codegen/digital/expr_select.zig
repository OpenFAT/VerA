//! A select expression -> Zig text over `rt.logic`: an element of an
//! unpacked array (its address, x when out of range), or a bit-, part- or
//! indexed part-select of a vector, numbered by the vector's declared range
//! as the interpreter numbers it.
//! Cites: IEEE 1364-2005 §3.3 (`[msb:lsb]`), §3.9 and §4.9 (arrays,
//! row-major), §5.2.1 (selects), §5.2.2 (an invalid address reads x).
//!
//! Contents:
//! - `pub const VecRange = sim.digital.VecRange`
//! - `pub const Place = struct { shift: i64, count: u32 }`
//! - `pub fn index(em: *Emitter, e: Ast.ExprId, ty: Type) Error!void`
//! - `pub fn indexedShift(em: *Emitter, e: Ast.ExprId, range: VecRange) Error!void`
//! - `pub fn address(em: *Emitter, e: Ast.ExprId, label: u32) Error!void`
//! - `pub fn vecRange(r: *const Run, at: u32, width: u32) VecRange`
//! - `pub fn partPlace(em: *Emitter, e: Ast.ExprId, range: VecRange) Error!Place`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const sim_digital = @import("sim").digital;
const Run = sim_digital.Run;
const compile = sim_digital.for_emitter.compile;
const evaluate = sim_digital.for_emitter.evaluate;
const Type = compile.Type;
const Emitter = @import("Emitter.zig");
const Error = Emitter.Error;
const expr = @import("expr.zig");
const plane_words = @import("plane_words.zig");

/// The interpreter's §3.3 `[msb:lsb]`, so both engines number bits alike.
pub const VecRange = sim_digital.VecRange;

/// A constant part-select as a shift: select bit i is slot bit `i + shift`
/// where the slot has that bit, and names no bit elsewhere (§5.2.1).
pub const Place = struct { shift: i64, count: u32 };

/// Writes §3.9 an array element, or §5.2.1 a bit- or part-select of a
/// vector, in context `ty`. Asserts that `e` is an `.index`.
pub fn index(em: *Emitter, e: Ast.ExprId, ty: Type) Error!void {
    const r = em.r;
    const ex = &r.file.exprs;
    assert(ex.tag(e) == .index);
    const w = ty.width;
    const sg = ty.signed;
    const n = compile.typeOf(r, e);
    if (try em.element(e)) {
        // An out-of-range or x/z address reads x of the element's type.
        const lb = em.label();
        try em.print("L.rs(if (", .{});
        try address(em, e, lb);
        const base = try em.slot(r.chainBase(e).base);
        const nw = plane_words.words(n.width);
        const at = .{ em.planes.off[base], lb, base, nw };
        if (nw == 1)
            try em.print(") |a{d}| M.get(s, {d} + (a{d} - {d}) * {d})", .{lb} ++ at)
        else
            try em.print(") |a{d}| M.getw(s, {d} + (a{d} - {d}) * {d}, {d})", .{lb} ++ at ++ .{nw});
        return em.print(" else L.xs({d}), {d}, {d}, {})", .{ n.width, n.width, w, sg });
    }
    const operand = ex.lhs(e);
    const at = try em.slot(r.chainBase(operand).base);
    const sw = em.slotWidth(at);
    const range = vecRange(r, at, sw);
    const rg = ex.rhs(e);
    if (ex.tag(rg) == .range) {
        const p = try partPlace(em, e, range);
        try em.print("L.rs(L.part(", .{});
        try selectValue(em, operand, at);
        try em.print(", {d}, {d}, {d}), {d}, {d}, {})", .{ p.shift, p.count, sw, n.width, w, sg });
        return;
    }
    if (ex.tag(rg) == .indexed_range) {
        try em.print("L.rs(L.partAt(", .{});
        try selectValue(em, operand, at);
        try em.print(", ", .{});
        try indexedShift(em, e, range);
        return em.print(", {d}, {d}), {d}, {d}, {})", .{ n.width, sw, n.width, w, sg });
    }
    // A known constant index inside the range reads its one plane word, not
    // the whole vector.
    if (sw > 64 and ex.tag(operand) != .index and compile.constantExpression(r, rg)) {
        const v = evaluate.eval(r, em.arena, rg, 0) catch return em.refuse("a constant the engine does not fold");
        if (evaluate.indexInt(v)) |i| {
            const p = range.position(i);
            if (p >= 0 and p < sw) return em.print("L.rs(L.bitAt(M.get(s, {d}), {d}, 63, 0, 64), 1, {d}, {})", .{ em.planes.off[at] + @as(u32, @intCast(p)) / 64, @mod(p, 64), w, sg });
        }
    }
    try em.print("L.rs(L.bitAt(", .{});
    try selectValue(em, operand, at);
    try em.print(", L.asIndex(", .{});
    const t = try expr.selfDetermined(em, rg);
    try em.print(", {d}, {}), {d}, {d}, {d}), 1, {d}, {})", .{ t.width, t.signed, range.msb, range.lsb, sw, w, sg });
}

/// Writes the optional storage shift of indexed part-select `e` (§5.2.1).
/// Its width is constant; only the self-determined base is evaluated here.
pub fn indexedShift(em: *Emitter, e: Ast.ExprId, range: VecRange) Error!void {
    const r = em.r;
    const ex = &r.file.exprs;
    const rg = ex.rhs(e);
    assert(ex.tag(rg) == .indexed_range);
    const count = compile.typeOf(r, e).width;
    assert(count != 0);
    try em.print("L.selectShift(L.asIndex(", .{});
    const t = try expr.selfDetermined(em, ex.lhs(rg));
    try em.print(", {d}, {}), {d}, {d}, {d}, {})", .{ t.width, t.signed, range.msb, range.lsb, count, ex.extraOf(rg) == 0 });
}

/// Writes `evaluate.address` of element `e` as a Zig `?u32`: the element's
/// slot, or null. `label` (from `Emitter.label`) names its block and locals.
pub fn address(em: *Emitter, e: Ast.ExprId, label: u32) Error!void {
    const r = em.r;
    const ex = &r.file.exprs;
    const c = r.chainBase(e);
    const base = try em.slot(c.base);
    const arr = r.decls.arrays.get(base).?;
    try em.print("b{d}: {{", .{label});
    // §4.9 row-major: the innermost select is the last dimension.
    var depth: usize = 0;
    var x = e;
    while (ex.tag(x) == .index) : (x = ex.lhs(x)) depth += 1;
    assert(depth != 0);
    assert(depth <= arr.rest.len + 1);
    const selects = try em.arena.alloc(Ast.ExprId, depth);
    x = e;
    while (depth != 0) : (x = ex.lhs(x)) {
        depth -= 1;
        selects[depth] = ex.rhs(x);
    }
    try em.print(" var o{d}: u64 = 0;", .{label});
    for (selects, 0..) |sel, d| {
        const span: sim_digital.Span = if (d == 0) .{ .low = arr.low, .high = arr.high } else arr.rest[d - 1];
        try em.print(" const i{d}_{d} = L.asIndex(", .{ label, d });
        const t = try expr.selfDetermined(em, sel);
        try em.print(", {d}, {}) orelse break :b{d} null;", .{ t.width, t.signed, label });
        try em.print(" if (i{d}_{d} < {d} or i{d}_{d} > {d}) break :b{d} null;", .{ label, d, span.low, label, d, span.high, label });
        try em.print(" o{d} = o{d} * {d} + @as(u64, @intCast(i{d}_{d} - {d}));", .{ label, label, span.high - span.low + 1, label, d, span.low });
    }
    try em.print(" break :b{d} @as(?u32, {d} + @as(u32, @intCast(o{d}))); }}", .{ label, base, label });
}

/// Returns slot `at`'s declared `[msb:lsb]`, `[w-1:0]` when it declares none.
pub fn vecRange(r: *const Run, at: u32, width: u32) VecRange {
    assert(at < r.values.len);
    const range = r.typing.vec_ranges.get(at) orelse VecRange{ .msb = @as(i64, width) - 1, .lsb = 0 };
    return range;
}

/// Returns the `Place` of part-select `e` on a vector declared `range`, from
/// the bounds `infer` folded for the executing scope's specialization.
/// Asserts that `e` was typed there.
pub fn partPlace(em: *Emitter, e: Ast.ExprId, range: VecRange) Error!Place {
    const r = em.r;
    assert(r.file.exprs.tag(r.file.exprs.rhs(e)) == .range);
    const b = r.typing.part_selects.get(.{ .spec = r.specOf(r.scope), .e = e }).?;
    // `infer` refused a part-select against its vector's direction (§5.2.1).
    const place: Place = .{ .shift = range.position(b.lsb), .count = @intCast(@abs(b.msb - b.lsb) + 1) };
    assert(place.count != 0);
    return place;
}

// ---- private ----

/// The packed value a select reads, including an addressed array element.
fn selectValue(em: *Emitter, operand: Ast.ExprId, base: u32) Error!void {
    assert(operand != .none);
    if (em.r.file.exprs.tag(operand) != .index) return em.get(base);
    return expr.value(em, operand, .{ .width = em.slotWidth(base), .signed = false });
}
