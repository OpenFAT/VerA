const std = @import("std");
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const diag = @import("diag");
const Lower = @import("Lower.zig");
const lower_expr = @import("expr.zig");
const lower_node = @import("node.zig");
const lower_source_check = @import("source_check.zig");
const lower_branch = @import("branch.zig");
const lower_accum = @import("accum.zig");
const Oom = Lower.Oom;
const ground = Lower.ground;
const Access = Lower.Access;
const Kind = Lower.Kind;

/// Lowers a §5.6.7 indirect branch contribution, `V(out) : V(in) == e;`, read
/// "drive V(out) so that V(in) == e".
///
/// Topologically a direct potential source whose current is a solver unknown.
/// Only the constitutive row differs: it is `<probe> - <equation>` with no
/// `V(hi,lo)` term, since "the source voltage needs to be adjusted so that the
/// given equation is satisfied". The orientation matters for an asymmetric
/// equation. Branches in the equation are only probed, because only the entry
/// appended here reaches codegen's stamping loop.
pub fn lowerIndirect(self: *Lower, tok: u32, lhs: Ast.ExprId, probe_e: Ast.ExprId, eqn: Ast.ExprId) Oom!void {
    if (self.restrict) |ctx| {
        try self.err(self.file.exprs.mainTok(lhs), .E0410, "not allowed in {s}", .{ctx});
        return;
    }
    if (self.in_event_stmt) {
        try self.err(self.file.exprs.mainTok(lhs), .E0411, "", .{});
        return;
    }
    // §5.6.7 "Indirect branch contributions shall not be used in conditional or
    // looping statements, unless the conditional expression is a constant
    // expression." A constant condition never reaches here (see `cond_depth`).
    if (self.cond_depth != 0) {
        try self.err(tok, .E0412, "the condition is not a constant expression", .{});
        return;
    }
    const ex = &self.file.exprs;
    if (ex.tag(lhs) != .branch_access) {
        try self.err(self.file.exprs.mainTok(lhs), .E0413, "", .{});
        return;
    }
    // §5.6.7 "The left-hand side of the equality operator must either be an
    // access function, or ddt, idt or idtmod applied to an access function."
    if (!isIndirectProbe(self, probe_e)) {
        var b = self.errWith(self.file.exprs.mainTok(probe_e), .E0414);
        b.help("use an access function, or `ddt`/`idt`/`idtmod` applied to one", .{});
        try b.emit();
        return;
    }
    const target = try lower_branch.branchOf(self, lhs) orelse return;
    // §5.6.7.2 incompatible with a direct contribution across the same pair of
    // analog nets — checked on the accumulator ENTRY, since `<+` statements are
    // deduped across statements and across if-arms.
    // ponytail: O(rows) per indirect statement; key direct pairs like
    // `State.indirect` if a model writes thousands of them.
    for (self.out.contributions.items) |c| {
        if (c.kind != .direct) continue;
        if (!lower_source_check.samePair(c.hi, c.lo, target.hi, target.lo)) continue;
        var b = self.errWith(self.file.exprs.mainTok(lhs), .E0415);
        b.msg("`({s},{s})`", .{ lower_node.nodeName(self, target.hi), lower_node.nodeName(self, target.lo) });
        b.note("a branch is defined either by accumulated `<+` or by one indirect assignment, never both", .{});
        try b.emit();
        return;
    }

    const p = try self.toReal(try lower_expr.lowerExpr(self, probe_e));
    const e = try self.toReal(try lower_expr.lowerExpr(self, eqn));
    const row = try self.emit(.fsub, &.{ p, e });

    // Its own entry, never `contribIndex`: §5.6.7.1 allows several indirect
    // contributions, each of which is a separate source and equation.
    const idx = try lower_accum.newContrib(self, .indirect, target, self.file.exprs.mainTok(lhs));
    try self.builder.writeVariable(self.accum.items[idx].resist, self.cur, row);
}

/// A.8.3 `indirect_expression`: a branch/port probe, or ddt/idt/idtmod of one.
/// The optional tolerance/initial-condition arguments are ordinary expressions
/// and are not restricted.
fn isIndirectProbe(self: *const Lower, e: Ast.ExprId) bool {
    const ex = &self.file.exprs;
    if (e == .none) return false;
    switch (ex.tag(e)) {
        .branch_access, .port_access => return true,
        .filter_call => {},
        else => return false, // else: not A.8.3 `indirect_expression`
    }
    const name = self.file.str(ex.strOf(e));
    const is_op = std.mem.eql(u8, name, "ddt") or
        std.mem.eql(u8, name, "idt") or
        std.mem.eql(u8, name, "idtmod");
    if (!is_op) return false;
    const args = ex.args(e);
    if (args.len == 0) return false;
    return switch (ex.tag(args[0])) {
        .branch_access, .port_access => true,
        else => false, // else: A.8.3 takes the operator OF a probe only
    };
}

pub fn indirectOn(self: *const Lower, hi: u32, lo: u32) bool {
    return self.contrib_state.indirect.contains(lower_source_check.pairKey(hi, lo));
}

test "lower: §5.6.7 indirect contribution is a nullor entry, one per statement" {
    var h: Lower.Harness = undefined;
    try h.init(std.testing.allocator,
        \\module amp(out, pin, nin);
        \\  inout out, pin, nin;
        \\  electrical out, pin, nin;
        \\  analog begin
        \\    V(out) : V(pin, nin) == 2.0 * V(out);
        \\    V(out) : V(pin) == 0.0;
        \\  end
        \\endmodule
    );
    defer h.deinit();
    _ = try h.low.lowerFile();

    // §5.6.7.1 several indirect contributions are legal, and each is its own
    // equation — NEVER accumulated the way §5.6.1.3 accumulates `<+`.
    try std.testing.expectEqual(@as(usize, 2), h.low.out.contributions.items.len);
    for (h.low.out.contributions.items) |c| {
        try std.testing.expectEqual(Lower.Kind.indirect, c.kind);
        try std.testing.expectEqual(Lower.Access.potential, c.access);
        try std.testing.expectEqual(@as(u32, 0), c.hi); // out
        try std.testing.expectEqual(Lower.ground, c.lo);
        try std.testing.expectEqual(Mir.Value.f_zero, c.react_val);
    }
    // Row ORIENTATION: probe − equation, so the top-level op is `fsub` whose
    // LHS is the probe slice. Reversed, the residual is negated and an
    // asymmetric equation converges to the wrong point.
    const row = h.mir.resolveAlias(h.low.out.contributions.items[0].resist_val);
    const inst = h.mir.valueDef(row).inst_result;
    try std.testing.expectEqual(Mir.Opcode.fsub, h.mir.instOp(inst));
    const lhs = h.mir.resolveAlias(h.mir.instData(inst).binary.lhs);
    // lhs is V(pin,nin) = x[pin] − x[nin]; rhs is the 2.0*V(out) product.
    try std.testing.expectEqual(Mir.Opcode.fsub, h.mir.instOp(h.mir.valueDef(lhs).inst_result));
    const rhs = h.mir.resolveAlias(h.mir.instData(inst).binary.rhs);
    try std.testing.expectEqual(Mir.Opcode.fmul, h.mir.instOp(h.mir.valueDef(rhs).inst_result));
}

test "lower: §5.6.7.2 an indirectly assigned branch refuses <+, in either order" {
    // The two orders are mirror images, and each has its own code.
    const cases = [_]struct { want: diag.Code, src: []const u8 }{
        .{ .want = .E0409, .src =
        \\module a(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    V(p, n) : V(p) == 0.0;
        \\    I(p, n) <+ 1e-6;
        \\  end
        \\endmodule
        },
        // …and the reverse order, on the reversed net pair (a "parallel
        // branch" in §5.6.7.2's words).
        .{ .want = .E0415, .src =
        \\module a(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    I(n, p) <+ 1e-6;
        \\    V(p, n) : V(p) == 0.0;
        \\  end
        \\endmodule
        },
    };
    for (cases) |c| {
        var h: Lower.Harness = undefined;
        try h.init(std.testing.allocator, c.src);
        defer h.deinit();
        try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
        try std.testing.expectEqual(c.want, h.bag.at(0).code);
    }
}

test "lower: §5.6.7 indirect is banned under a runtime condition, allowed under a constant one" {
    var bad: Lower.Harness = undefined;
    try bad.init(std.testing.allocator,
        \\module a(o, i);
        \\  inout o, i;
        \\  electrical o, i;
        \\  analog if (V(i) > 0.0) V(o) : V(i) == 0.0;
        \\endmodule
    );
    defer bad.deinit();
    try std.testing.expectError(error.DiagnosticsReported, bad.low.lowerFile());
    try std.testing.expectEqual(diag.Code.E0412, bad.bag.at(0).code);

    // "…unless the conditional expression is a constant expression": a folded
    // condition lowers its arm straight into the current block, so it never
    // raises `cond_depth`. A parameter condition folds too, as a shape
    // parameter (`lowerIf`); the second harness below.
    var ok: Lower.Harness = undefined;
    try ok.init(std.testing.allocator,
        \\module a(o, i);
        \\  inout o, i;
        \\  electrical o, i;
        \\  analog if (1) V(o) : V(i) == 0.0;
        \\endmodule
    );
    defer ok.deinit();
    _ = try ok.low.lowerFile();
    try std.testing.expectEqual(@as(usize, 1), ok.low.out.contributions.items.len);
    try std.testing.expectEqual(Lower.Kind.indirect, ok.low.out.contributions.items[0].kind);

    var par: Lower.Harness = undefined;
    try par.init(std.testing.allocator,
        \\module a(o, i);
        \\  inout o, i;
        \\  electrical o, i;
        \\  parameter integer sel = 1;
        \\  analog if (sel) V(o) : V(i) == 0.0;
        \\endmodule
    );
    defer par.deinit();
    _ = try par.low.lowerFile();
    try std.testing.expectEqual(Lower.Kind.indirect, par.low.out.contributions.items[0].kind);
    try std.testing.expect(par.low.out.params.items[0].shape);
}
