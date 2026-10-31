//! §6.3.6/§9.18 hierarchical system-parameter names → Table 9-29 identities,
//! domains and composition expressions. Shared by elaboration and the
//! §3.4.7 top-level alias declarations in lowering.
//!
//! Contents:
//! - `pub const Kind`
//! - `pub const Values`
//! - `pub const Aliases`
//! - `pub fn compose(self: Kind, file: *Ast.SourceFile, arena: std.mem.Allocator, parent: Ast.ExprId, value: Ast.ExprId, tok: u32) std.mem.Allocator.Error!Ast.ExprId`

const std = @import("std");
const Ast = @import("frontend").Ast;
const constfold = @import("frontend").constfold;

/// One §9.18 Table 9-29 hierarchical system parameter (`base`'s, so
/// `Lowered.SystemCheck` names one without importing elaboration).
pub const Kind = @import("base").SystemParam;

/// One instance's expression per kind, `.none` where nothing sets it.
pub const Values = std.EnumArray(Kind, Ast.ExprId);

/// Lowering's §3.4.7 top-level alias per kind: the `Lowered.params` row that
/// holds it, or null.
pub const Aliases = std.EnumArray(Kind, ?u32);

/// Returns the expression for an instance's value given its parent's
/// (Table 9-29's composition: a sum, a product, or a sum modulo 360).
/// `parent` and `value` already refer to the flat namespace. `.none`
/// means the table's top-level identity. Force real arithmetic: even an
/// integer spelling of a coordinate or angle is a real-valued system
/// parameter, so a fractional angle never passes through integer `%`.
/// The new nodes are appended to `file.exprs` from `arena`. Asserts that
/// `value` is an expression: only `parent` may be `.none`.
pub fn compose(self: Kind, file: *Ast.SourceFile, arena: std.mem.Allocator, parent: Ast.ExprId, value: Ast.ExprId, tok: u32) std.mem.Allocator.Error!Ast.ExprId {
    std.debug.assert(value != .none);
    const x = &file.exprs;
    const real_value = if (constfold.fold(file, value, constfold.literal_env)) |v|
        if (v == .str) value else try x.addReal(arena, tok, v.asReal())
    else
        try binary(file, arena, .add, value, try x.addReal(arena, tok, 0), tok);
    if (parent == .none) return real_value;
    const op: Ast.BinaryOp = switch (self) {
        .angle, .xposition, .yposition => .add,
        .hflip, .mfactor, .vflip => .mul,
    };
    const combined = try binary(file, arena, op, parent, real_value, tok);
    // Each valid input is in [0,360), so the sum is nonnegative and
    // §4.2.4's real remainder is precisely Table 9-29's modulo 360.
    return if (self == .angle)
        binary(file, arena, .mod, combined, try x.addReal(arena, tok, 360), tok)
    else
        combined;
}

// ---- private ----

fn binary(file: *Ast.SourceFile, arena: std.mem.Allocator, op: Ast.BinaryOp, lhs: Ast.ExprId, rhs: Ast.ExprId, tok: u32) std.mem.Allocator.Error!Ast.ExprId {
    return file.exprs.add(arena, .{
        .tag = .binary,
        .main_tok = tok,
        .lhs = lhs,
        .rhs = rhs,
        .extra = @backingInt(op),
    });
}

test "compose: Table 9-29's resolved value, as an expression" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var file: Ast.SourceFile = .empty;
    const x = &file.exprs;
    const t = std.testing;
    const three = try x.addInt(a, 0, 3);
    // At the top of the hierarchy the value is the specified one, as a real.
    const top = try compose(.mfactor, &file, a, .none, three, 0);
    try t.expectEqual(Ast.ExprTag.real_literal, x.tag(top));
    try t.expectEqual(@as(f64, 3), x.realValue(top));
    // Below it: specified * hier for the products.
    const parent = try x.add(a, .{ .tag = .ident, .str = try file.intern(a, "p") });
    const m = try compose(.mfactor, &file, a, parent, three, 0);
    try t.expectEqual(Ast.BinaryOp.mul, x.binOp(m));
    try t.expectEqual(parent, x.lhs(m));
    try t.expectEqual(@as(f64, 3), x.realValue(x.rhs(m)));
    // specified + hier, modulo 360 degrees, for $angle.
    const ang = try compose(.angle, &file, a, parent, three, 0);
    try t.expectEqual(Ast.BinaryOp.mod, x.binOp(ang));
    try t.expectEqual(@as(f64, 360), x.realValue(x.rhs(ang)));
    try t.expectEqual(Ast.BinaryOp.add, x.binOp(x.lhs(ang)));
    try t.expectEqual(parent, x.lhs(x.lhs(ang)));
    // A value that does not fold is made real by adding 0.0, so integer `%`
    // can never see a fractional angle.
    const w = try x.add(a, .{ .tag = .ident, .str = try file.intern(a, "w") });
    const xp = try compose(.xposition, &file, a, .none, w, 0);
    try t.expectEqual(Ast.BinaryOp.add, x.binOp(xp));
    try t.expectEqual(w, x.lhs(xp));
    try t.expectEqual(@as(f64, 0), x.realValue(x.rhs(xp)));
}
