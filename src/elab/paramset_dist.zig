//! §9.13 distribution calls written inside a §6.4 paramset body → their
//! `type_string` validated and dropped, and a call whose seed and parameters
//! are literals folded with the device's own kernels (`rng_kernels`).
//! Cites: LRM §4.2.1.1, §9.13.1, §9.13.2, Syntax 9-8, Table 9-10.
//!
//! Contents:
//! - `pub fn rewriteParamsetDist(self: *Flatten, e: Ast.ExprId) design.Error!?Ast.ExprId`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const rng = @import("kernels").rng_kernels;
const design = @import("design.zig");
const Flatten = @import("Flatten.zig");
const clone_expr = @import("clone_expr.zig");
const override = @import("override.zig");
const dist = @import("dist.zig");

/// §9.13.1/§9.13.2 a distribution call written inside a §6.4 paramset body,
/// the one scope whose calls may carry the optional trailing `type_string`.
///
///   1. The `type_string`: `type_string ::= "global" | "instance"`, anything
///      else is E0816. Monte-Carlo trials are the host's loop, and in the one
///      trial VerA compiles both spellings select the same draw, so a valid
///      string is validated and dropped.
///   2. The value: §9.13.2 makes the draw a pure function of its seed, so a
///      call whose seed and parameters are literals is folded now with the
///      same kernels every device embeds (`rng_kernels.zig`). The literal
///      then reaches the model card through the ordinary §6.3 overrides.
///
/// Returns null when the callee is not one of Table 9-10's names (or is
/// `$random`, whose Syntax 9-8 production has no `type_string`). A call
/// whose arguments do not fold is returned with the string stripped and
/// left to lowering, which owns the remaining argument rules (in a parameter
/// position that still ends in E0363).
///
/// ponytail: the fold takes a literal seed only. Syntax 9-9 also admits an
/// integer parameter identifier, and a paramset's own parameters are fixed
/// by the time this runs; folding through them needs the parameter values
/// threaded in here. Add when a model writes one.
pub fn rewriteParamsetDist(self: *Flatten, e: Ast.ExprId) design.Error!?Ast.ExprId {
    assert(self.in_paramset); // the one scope a `type_string` is legal in
    assert(self.ctx.file.exprs.tag(e) == .sys_call);
    const x = &self.ctx.file.exprs;
    const name = self.ctx.file.str(x.strOf(e));
    const d = dist.of(name) orelse return null;
    if (std.mem.eql(u8, name, "$random")) return null;
    const tok = x.mainTok(e);
    const args = x.args(e);

    var eff = args;
    var stripped = false;
    var bad = false;
    if (eff.len > 0 and eff[eff.len - 1] != .none and x.tag(eff[eff.len - 1]) == .str_literal) {
        const last = eff[eff.len - 1];
        const ts = self.ctx.file.str(x.strOf(last));
        if (!std.mem.eql(u8, ts, "global") and !std.mem.eql(u8, ts, "instance")) {
            try self.err(x.mainTok(last), .E0816, "`{s}`'s `type_string` shall be \"global\" or \"instance\", got \"{s}\"", .{ name, ts });
            bad = true;
        }
        eff = eff[0 .. eff.len - 1];
        stripped = true;
    }

    // The fold: the seed plus §9.13.2's parameters, all literal, judged by
    // the same domain rules `lowerRandom` applies on the runtime path.
    fold: {
        if (bad or eff.len != @as(usize, d.nparam) + 1) break :fold;
        const seed = constIntLit(x, eff[0]) orelse break :fold;
        var p = [2]f64{ 0, 0 };
        for (eff[1..], 0..) |arg, i| {
            p[i] = override.constReal(self, arg) orelse break :fold;
            if (d.positive & (@as(u8, 1) << @intCast(i)) != 0 and !(p[i] > 0)) {
                try self.err(x.mainTok(arg), .E0816, "`{s}`'s `{s}` shall be greater than zero, got {d}", .{ name, dist.paramName(d, i), p[i] });
                bad = true;
            }
            if (d.count and i == 0 and p[i] > 0 and
                (!(p[i] <= 2147483647.0) or p[i] != @trunc(p[i])))
            {
                try self.err(x.mainTok(arg), .E0816, "`{s}`'s fractional or out-of-range `{s}` is unsupported; the reference count domain is 1..2147483647", .{ name, dist.paramName(d, i) });
                bad = true;
            }
        }
        if (d.ordered and d.ty == .real and !(p[0] < p[1])) {
            try self.err(x.mainTok(eff[1]), .E0816, "the start value shall be smaller than the end value, got {d} and {d}", .{ p[0], p[1] });
            bad = true;
        }
        if (bad) break :fold; // report; nothing sound to draw
        const v: f64 = if (std.mem.eql(u8, d.kernel, "$rng$rand"))
            rng.zRngRand(seed)
        else if (std.mem.eql(u8, d.kernel, "$rng$i_uniform"))
            rng.zRngIUniform(seed, p[0], p[1])
        else if (std.mem.eql(u8, d.kernel, "$rng$uniform"))
            rng.zRngUniform(seed, p[0], p[1])
        else if (std.mem.eql(u8, d.kernel, "$rng$normal"))
            rng.zRngNormal(seed, p[0], p[1])
        else if (std.mem.eql(u8, d.kernel, "$rng$exponential"))
            rng.zRngExponential(seed, p[0])
        else if (std.mem.eql(u8, d.kernel, "$rng$poisson"))
            rng.zRngPoisson(seed, p[0])
        else if (std.mem.eql(u8, d.kernel, "$rng$chi_square"))
            rng.zRngChiSquare(seed, p[0])
        else if (std.mem.eql(u8, d.kernel, "$rng$t"))
            rng.zRngT(seed, p[0])
        else if (std.mem.eql(u8, d.kernel, "$rng$erlang"))
            rng.zRngErlang(seed, p[0], p[1])
        else
            break :fold;
        if (d.ty == .integer and (!std.math.isFinite(v) or
            @round(v) < -2147483648.0 or @round(v) > 2147483647.0))
        {
            try self.err(tok, .E0816, "`{s}`'s reference result cannot be represented as a signed 32-bit integer", .{name});
            break :fold;
        }
        // §9.13.2 "$dist_ ... return integer values": §4.2.1.1's rounding,
        // the same conversion the runtime path's `toInt` performs.
        return if (d.ty == .integer)
            try x.addInt(self.ctx.arena, tok, @intFromFloat(@round(v)))
        else
            try x.addReal(self.ctx.arena, tok, v);
    }

    if (!stripped) return null; // the ordinary clone will do
    // Unfoldable, but a `type_string` shall not survive to lowering, where
    // it would read as the out-of-paramset scope error: rebuild the call
    // over the remaining arguments, cloned as `cloneArgs` would have.
    var n = x.get(e);
    n.extra = try clone_expr.cloneArgs(self, eff);
    return try self.ctx.file.exprs.add(self.ctx.arena, n);
}

// ---- private ----

/// §9.13.1 Syntax 9-8's literal seed form, `[ sign ] decimal_number`. A real
/// is not one: "the seed argument shall be an integer" is lowering's E0816 to
/// report, so a real seed declines the fold.
fn constIntLit(x: *const Ast.ExprStore, e: Ast.ExprId) ?i64 {
    if (e == .none) return null;
    return switch (x.tag(e)) {
        .int_literal => x.intValue(e),
        .unary => switch (x.unOp(e)) {
            .plus => constIntLit(x, x.lhs(e)),
            .minus => if (constIntLit(x, x.lhs(e))) |v| -v else null,
            else => null, // else: the production's `[ sign ]` is `+` or `-` and nothing else
        },
        else => null, // else: not `[ sign ] decimal_number`, so not the literal seed form
    };
}

test "§9.13.1 constIntLit reads only Syntax 9-8's `[ sign ] decimal_number` seed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var file: Ast.SourceFile = .empty;
    const x = &file.exprs;
    const five = try x.addInt(a, 0, 5);
    const neg = try x.add(a, .{ .tag = .unary, .lhs = five, .extra = @backingInt(Ast.UnaryOp.minus) });
    const pos_neg = try x.add(a, .{ .tag = .unary, .lhs = neg, .extra = @backingInt(Ast.UnaryOp.plus) });
    const not_five = try x.add(a, .{ .tag = .unary, .lhs = five, .extra = @backingInt(Ast.UnaryOp.logical_not) });
    const real = try x.addReal(a, 0, 5.0);
    try std.testing.expectEqual(@as(?i64, 5), constIntLit(x, five));
    try std.testing.expectEqual(@as(?i64, -5), constIntLit(x, neg));
    try std.testing.expectEqual(@as(?i64, -5), constIntLit(x, pos_neg));
    // Any other operator, a real ("the seed argument shall be an integer",
    // lowering's E0816) and an omitted argument decline the fold.
    try std.testing.expectEqual(@as(?i64, null), constIntLit(x, not_five));
    try std.testing.expectEqual(@as(?i64, null), constIntLit(x, real));
    try std.testing.expectEqual(@as(?i64, null), constIntLit(x, .none));
}
