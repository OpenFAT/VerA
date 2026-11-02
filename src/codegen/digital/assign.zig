//! An assignment's target and right-hand side -> the Zig statements that
//! store it: `evaluate.place`, then `evaluate.evalFor`, then `write` now or
//! an NBA row (§9.2.2), through the cheapest `rt` store that still wakes
//! everything the slot reaches (`plan.Reach`).
//! Cites: IEEE 1364-2005 §4.8, §4.8.2 (real stores), §5.2, §5.2.1 (select
//! targets), §6 Table 6-1 (concatenation targets), §9.2, §9.2.2, §9.7.7,
//! §10.2.2, §17.2.3.
//!
//! Contents:
//! - `pub const How = union(enum) { blocking, nba, nba_after: Ast.ExprId }`
//! - `pub const Rhs = union(enum)`
//! - `pub fn assignment(em: *Emitter, target: Ast.ExprId, val: Rhs, how: How) Error!void`
//! - `pub fn targetType(em: *Emitter, target: Ast.ExprId) Error!Type`
//! - `pub fn store(em: *Emitter, at: u32, how: How) Error!void`
//! - `pub fn storeElement(em: *Emitter, base: u32, lb: u32, how: How) Error!void`
//! - `pub fn fmtReach(wakes: plan.Reach) std.fmt.Alt(plan.Reach, reachText)`
//! - `pub fn assignInt(em: *Emitter, target: Ast.ExprId, v: []const u8) Error!void`
//! - `pub fn assignWord(em: *Emitter, target: Ast.ExprId, word: []const u8, ty: Type) Error!void`
//! - `pub fn assignChars(em: *Emitter, target: Ast.ExprId, v: []const u8) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const sim_digital = @import("sim").digital;
const compile = sim_digital.for_emitter.compile;
const Type = compile.Type;
const Emitter = @import("Emitter.zig");
const Error = Emitter.Error;
const expr = @import("expr.zig");
const expr_select = @import("expr_select.zig");
const layout = @import("layout.zig");
const plan = @import("plan.zig");
const plane_words = @import("plane_words.zig");
const timing = @import("timing.zig");

/// How an assignment stores (§9.2): now, or as a nonblocking update of this
/// step or `delay` later.
pub const How = union(enum) { blocking, nba, nba_after: Ast.ExprId };

/// A right-hand side: an expression, a value already stored at word `off`
/// with type `ty` (§9.7.7), or a formal captured before restoring its
/// caller's automatic frame (§10.2.2, §10.2.3).
pub const Rhs = union(enum) {
    expr: Ast.ExprId,
    stored: struct { off: u32, ty: Type },
    captured: struct { call: u32, port: usize, ty: Type },
    /// A procedural RHS evaluated before resolving an indexed target,
    /// including when that target ultimately names no storage (§9.2).
    evaluated: struct { label: u32, ty: Type },
    /// Bits `lo` up of the `total`-bit local `cat<label>`, one operand's
    /// share of a concatenation lvalue's value.
    part: struct { label: u32, lo: u32, total: u32 },
};

/// Writes A.6.2 `lvalue = value` or `lvalue <= value`. Recursion follows a
/// concatenation target, whose depth the reserved stack of
/// `deep_stack.runGuarded` bounds.
pub fn assignment(em: *Emitter, target: Ast.ExprId, val: Rhs, how: How) Error!void {
    assert(target != .none);
    const r = em.r;
    const ex = &r.file.exprs;
    // `evaluate.put`: the value once, then each operand its bits, the
    // rightmost the least significant (§6 Table 6-1).
    if (ex.tag(target) == .concat) {
        const total = (try targetType(em, target)).width;
        const lb = em.label();
        try em.print("            {{\n            const cat{d} = ", .{lb});
        try rhsFor(em, val, .{ .width = total, .signed = false });
        try em.print(";\n", .{});
        var lo = total;
        for (ex.args(target)) |arg| {
            lo -= (try targetType(em, arg)).width;
            try assignment(em, arg, .{ .part = .{ .label = lb, .lo = lo, .total = total } }, how);
        }
        assert(lo == 0);
        return em.print("            }}\n", .{});
    }
    if (ex.tag(target) == .index and (val == .expr or val == .stored)) {
        // §9.2 evaluates the RHS even when §5.2's index names no storage.
        // Capture once before any address/unknown guard. This also keeps
        // function effects from being duplicated across a packed write. A
        // stored system-function result also needs this copy: an index's
        // nested call can reuse that function's temporary slot.
        const lb = em.label();
        const ty = try targetType(em, target);
        try em.print("            {{\n            const v{d} = ", .{lb});
        try rhsFor(em, val, ty);
        try em.print(";\n", .{});
        try assignment(em, target, .{ .evaluated = .{ .label = lb, .ty = ty } }, how);
        return em.print("            }}\n", .{});
    }
    if (ex.tag(target) != .index) {
        const at = try em.slot(target);
        try em.print("            ", .{});
        try store(em, at, how);
        try rhsFor(em, val, r.slotType(at));
        return em.print(", {f});\n", .{plane_words.full(em.slotWidth(at))});
    }
    if (try em.element(target)) {
        const base = try em.slot(r.chainBase(target).base);
        const lb = em.label();
        try em.print("            if (", .{});
        try expr_select.address(em, target, lb);
        try em.print(") |a{d}| ", .{lb});
        try storeElement(em, base, lb, how);
        try rhsFor(em, val, r.slotType(base));
        return em.print(", {f});\n", .{plane_words.full(em.slotWidth(base))});
    }
    // §5.2.1 a select of a vector: unsigned, as wide as it selects.
    const vector = ex.lhs(target);
    const at = try em.slot(r.chainBase(vector).base);
    const element_label: ?u32 = if (ex.tag(vector) == .index) em.label() else null;
    if (element_label) |lb| {
        try em.print("            if (", .{});
        try expr_select.address(em, vector, lb);
        try em.print(") |a{d}| {{\n", .{lb});
    }
    try assignSelect(em, target, at, element_label, val, how);
    if (element_label != null) try em.print("            }}\n", .{});
}

/// Returns `evaluate.targetType`: the type a value assigned to `target`
/// takes. Recursion follows a concatenation target.
pub fn targetType(em: *Emitter, target: Ast.ExprId) Error!Type {
    assert(target != .none);
    const r = em.r;
    const ex = &r.file.exprs;
    // As wide as its operands together, unsigned.
    if (ex.tag(target) == .concat) {
        var width: u32 = 0;
        for (ex.args(target)) |x| width += (try targetType(em, x)).width;
        return .{ .width = width, .signed = false };
    }
    if (ex.tag(target) != .index) return r.slotType(try em.slot(target));
    if (try em.element(target)) return r.slotType(try em.slot(r.chainBase(target).base));
    return .{ .width = compile.typeOf(r, target).width, .signed = false };
}

/// Writes the call that stores into slot `at`, up to its value: `M.nba` (or
/// `M.nbaAfter`), or `M.put`, or `M.set` when nothing can wait on the slot.
/// Asserts that the plan is laid out.
pub fn store(em: *Emitter, at: u32, how: How) Error!void {
    assert(at < em.watched.len);
    assert(at < em.reach.len);
    // §4.8 a real changes when its value does, not its bits.
    if (em.r.decls.reals.contains(at)) {
        try realStoreCall(em, how);
        return em.print("{d}, {d}, ", .{ at, em.planes.off[at] });
    }
    if (how == .blocking and !em.watched[at]) return em.print("try M.set(s, {d}, ", .{em.planes.off[at]});
    try storeCall(em, how, em.reach[at]);
    try em.print("{d}, {d}, ", .{ at, em.planes.off[at] });
}

/// Writes `store` of the element `a<lb>` of the array whose first element
/// is slot `base`: watched and woken as any element is.
pub fn storeElement(em: *Emitter, base: u32, lb: u32, how: How) Error!void {
    const r = em.r;
    const off = .{ em.planes.off[base], lb, base, plane_words.words(r.values[base].width) };
    if (r.decls.reals.contains(base)) {
        try realStoreCall(em, how);
        return em.print("a{d}, {d} + (a{d} - {d}) * {d}, ", .{lb} ++ off);
    }
    const count = r.decls.arrays.get(base).?.count;
    assert(base + count <= em.watched.len);
    const watched = std.mem.findScalar(bool, em.watched[base..][0..count], true) != null;
    if (how == .blocking and !watched) return em.print("try M.set(s, {d} + (a{d} - {d}) * {d}, ", off);
    var wakes: plan.Reach = .{};
    for (em.reach[base..][0..count]) |x| wakes = @bitCast(@as(u8, @bitCast(wakes)) | @as(u8, @bitCast(x)));
    try storeCall(em, how, wakes);
    try em.print("a{d}, {d} + (a{d} - {d}) * {d}, ", .{lb} ++ off);
}

/// Formats `wakes` as the `rt.Reach` literal of the fields it sets.
pub fn fmtReach(wakes: plan.Reach) std.fmt.Alt(plan.Reach, reachText) {
    return .{ .data = wakes };
}

/// Writes `evaluate.assignInt`: the Zig `i64` `v` assigned to `target`,
/// through a scratch word past the slots'.
pub fn assignInt(em: *Emitter, target: Ast.ExprId, v: []const u8) Error!void {
    assert(v.len != 0);
    try assignWord(em, target, try em.arena.print("L.k(@bitCast(@as(i64, {s})), 0)", .{v}), .{ .width = 64, .signed = true });
}

/// Writes the 64-bit `L.T(64)` text `word`, typed `ty` (a signed 64-bit
/// integer or a real's bits), assigned to `target`
/// (`evaluate.assign`/`assignReal`).
pub fn assignWord(em: *Emitter, target: Ast.ExprId, word: []const u8, ty: Type) Error!void {
    assert(word.len != 0);
    assert(ty.width == 64);
    const at = try layout.cellOf(&em.planes, em.arena, layout.word_cell, 64);
    try em.print("            try M.set(s, {d}, {s}, 0x{x});\n", .{ at, word, std.math.maxInt(u64) });
    try assignment(em, target, .{ .stored = .{ .off = at, .ty = ty } }, .blocking);
}

/// Writes `system.stringValue` of the Zig `[]const u8` `v` assigned to
/// `target`, through a scratch cell as wide as the target (§17.2.3: "the
/// string assignment to variable rules").
pub fn assignChars(em: *Emitter, target: Ast.ExprId, v: []const u8) Error!void {
    assert(v.len != 0);
    // A real takes the characters' low 64 bits as an unsigned number.
    const tt = try targetType(em, target);
    const w = if (tt.real) 64 else tt.width;
    const at = try layout.cellOf(&em.planes, em.arena, layout.scratchCell(w), w);
    try em.print("            s.setChars({d}, {d}, {s});\n", .{ at, w, v });
    try assignment(em, target, .{ .stored = .{ .off = at, .ty = .{ .width = w, .signed = false } } }, .blocking);
}

// ---- private ----

/// §4.8 real deposits compare numeric values at arrival, including NBA
/// updates. Keep their type in the queue until then (§9.2.2).
fn realStoreCall(em: *Emitter, how: How) Error!void {
    switch (how) {
        .blocking => try em.print("try s.putReal(", .{}),
        .nba => try em.print("try s.nbaReal(", .{}),
        .nba_after => |d| {
            assert(d != .none);
            try em.print("try s.nbaRealAfter(", .{});
            try timing.delay(em, d);
            try em.print(", ", .{});
        },
    }
}

/// The integral store call for `how`, waking `wakes`.
fn storeCall(em: *Emitter, how: How, wakes: plan.Reach) Error!void {
    switch (how) {
        .blocking => try em.print("try M.put(s, {f}, ", .{fmtReach(wakes)}),
        .nba => try em.print("try M.nba(s, {f}, ", .{fmtReach(wakes)}),
        .nba_after => |d| {
            assert(d != .none);
            try em.print("try M.nbaAfter(s, {f}, ", .{fmtReach(wakes)});
            try timing.delay(em, d);
            try em.print(", ", .{});
        },
    }
}

fn reachText(wakes: plan.Reach, out: *std.Io.Writer) std.Io.Writer.Error!void {
    try out.writeAll(".{");
    inline for (.{ "fan", "comb", "watch", "terms", "mon", "dump", "path" }) |f| if (@field(wakes, f)) try out.writeAll(" ." ++ f ++ " = true,");
    try out.writeAll(" }");
}

/// An already evaluated right-hand side, before assignment conversion.
fn rhsValue(em: *Emitter, rhs: Rhs) Error!void {
    switch (rhs) {
        .expr, .part => unreachable, // `rhsFor` emits expressions and concatenation slices directly.
        .stored => |v| if (v.ty.width <= 64)
            try em.print("M.get(s, {d})", .{v.off})
        else
            try em.print("M.getw(s, {d}, {d})", .{ v.off, plane_words.words(v.ty.width) }),
        .captured => |v| try em.print("o{d}_{d}", .{ v.call, v.port }),
        .evaluated => |v| try em.print("v{d}", .{v.label}),
    }
}

/// `rhs` in the type `target` gives it (`evaluate.evalFor`,
/// `evaluate.convertSlot`).
fn rhsFor(em: *Emitter, rhs: Rhs, target: Type) Error!void {
    const ty = switch (rhs) {
        .expr => |e| return expr.assigned(em, e, target),
        .stored => |v| v.ty,
        .captured => |v| v.ty,
        .evaluated => |v| v.ty,
        .part => |p| return em.print("L.part(cat{d}, {d}, {d}, {d})", .{ p.label, p.lo, target.width, p.total }),
    };
    // `evaluate.convertValue`, §4.8.2 between a real and an integer.
    if (ty.real and target.real) return rhsValue(em, rhs);
    if (target.real) {
        try em.print("L.realBits(L.toReal(", .{});
        try rhsValue(em, rhs);
        return em.print(", {d}, {}))", .{ ty.width, ty.signed });
    }
    if (ty.real) {
        try em.print("L.ofRealTo(L.real(", .{});
        try rhsValue(em, rhs);
        return em.print("), {d})", .{target.width});
    }
    assert(!ty.real and !target.real);
    try em.print("L.rs(", .{});
    try rhsValue(em, rhs);
    try em.print(", {d}, {d}, {})", .{ ty.width, target.width, ty.signed });
}

/// The masked write of a packed select, after an optional array address has
/// been captured. Its slot and mask are captured now even for an NBA.
fn assignSelect(em: *Emitter, target: Ast.ExprId, at: u32, element_label: ?u32, val: Rhs, how: How) Error!void {
    const r = em.r;
    const ex = &r.file.exprs;
    assert(ex.tag(target) == .index);
    const sw = em.slotWidth(at);
    const range = expr_select.vecRange(r, at, sw);
    const rg = ex.rhs(target);
    if (ex.tag(rg) == .range) {
        const p = try expr_select.partPlace(em, target, range);
        try em.print("            ", .{});
        try storeSelected(em, at, element_label, how);
        try em.print("L.place(", .{});
        try rhsFor(em, val, .{ .width = p.count, .signed = false });
        return em.print(", {d}, {d}, {d}), L.field({d}, {d}, {d}));\n", .{ p.shift, p.count, sw, p.shift, p.count, sw });
    }
    const lb = em.label();
    if (ex.tag(rg) == .indexed_range) {
        const count = compile.typeOf(r, target).width;
        try em.print("            if (", .{});
        try expr_select.indexedShift(em, target, range);
        try em.print(") |q{d}| ", .{lb});
        try storeSelected(em, at, element_label, how);
        try em.print("L.place(", .{});
        try rhsFor(em, val, .{ .width = count, .signed = false });
        return em.print(", q{d}, {d}, {d}), L.field(q{d}, {d}, {d}));\n", .{ lb, count, sw, lb, count, sw });
    }
    try em.print("            if (L.pos(L.asIndex(", .{});
    const t = try expr.selfDetermined(em, rg);
    try em.print(", {d}, {}), {d}, {d}, {d})) |q{d}| ", .{ t.width, t.signed, range.msb, range.lsb, sw, lb });
    if (sw > 64 and how == .blocking and element_label == null) {
        // One bit of a wide vector: the store touches only its word.
        if (em.watched[at])
            try em.print("try M.putWord(s, {f}, {d}, {d}, q{d} / 64, ", .{ fmtReach(em.reach[at]), at, em.planes.off[at], lb })
        else
            try em.print("try M.set(s, {d} + q{d} / 64, ", .{ em.planes.off[at], lb });
        try em.print("L.up(", .{});
        try rhsFor(em, val, .{ .width = 1, .signed = false });
        return em.print(", q{d} % 64, 64), L.bit(q{d} % 64, 64));\n", .{ lb, lb });
    }
    try storeSelected(em, at, element_label, how);
    try em.print("L.up(", .{});
    try rhsFor(em, val, .{ .width = 1, .signed = false });
    try em.print(", q{d}, {d}), L.bit(q{d}, {d}));\n", .{ lb, sw, lb, sw });
}

/// `store` of slot `at`, or of the element `a<label>` of it.
fn storeSelected(em: *Emitter, at: u32, element_label: ?u32, how: How) Error!void {
    if (element_label) |lb| return storeElement(em, at, lb, how);
    assert(element_label == null);
    return store(em, at, how);
}
