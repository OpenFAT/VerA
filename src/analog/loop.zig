//! §5.9 loops: `while`, `repeat` and `for` in, a CFG loop out (header
//! sealed after its back edge, Braun SSA), and §6.6.1's genvar `for`
//! unrolled instead, its scheme folded and refused when it never ends.
//!
//! Cites: §3.4, §3.5, §4.2.7, §5.9, §5.9.1, §5.9.2, §5.11, §6.6.1, §9.15.
//!
//! Contents:
//! - `pub fn lowerWhile(self: *Lower, cond: Ast.ExprId, body: Ast.StmtId) Oom!void`
//! - `pub fn lowerRepeat(self: *Lower, count: Ast.ExprId, body: Ast.StmtId) Oom!void`
//! - `pub fn lowerFor(self: *Lower, init_s: Ast.StmtId, cond: Ast.ExprId, step: Ast.StmtId, body: Ast.StmtId) Oom!void`
//! - private `tryUnrollFor` (`holds`, `next`, `same`)

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const diag = @import("diag");
const Elaborate = @import("elab").Elaborate;
const Lower = @import("Lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_expr = @import("expr.zig");
const lower_stmt = @import("stmt.zig");
const lower_control = @import("control.zig");
const Const = Lower.Const;
const Oom = Lower.Oom;

/// Lowers a §5.9.1 `while` loop. The header is sealed only after the back edge (Braun SSA).
pub fn lowerWhile(self: *Lower, cond: Ast.ExprId, body: Ast.StmtId) Oom!void {
    assert(cond == .none or self.exprValid(cond));
    assert(self.blockValid(self.cur));
    const header = try self.mir.addBlock(self.arena);
    try self.gotoBlock(header);
    self.cur = header;

    const c = try self.toBool(try lower_expr.lowerExpr(self, cond));
    const body_b = try self.mir.addBlock(self.arena);
    const exit = try self.mir.addBlock(self.arena);
    // `self.cur`, not `header`: a §4.2.7 short-circuit or `?:` in the condition
    // splits it across blocks and leaves `cur` at the join, and `header` already
    // ends in that split's branch.
    try self.branchTo(c, body_b, exit, false);

    try self.loops.append(self.arena, .{ .brk = exit, .cont = header });
    self.cur = body_b;
    try lower_control.lowerCondBody(self, body, false); // §5.9: a loop body is never static
    try self.gotoBlock(header);
    const popped = self.loops.pop().?;
    assert(popped.brk == exit); // the body's loops popped their own

    try self.builder.sealBlock(header);
    try self.builder.sealBlock(exit);
    self.cur = exit;
}

/// Lowers a §5.9 `repeat (n)` loop as an integer countdown.
pub fn lowerRepeat(self: *Lower, count: Ast.ExprId, body: Ast.StmtId) Oom!void {
    assert(count == .none or self.exprValid(count));
    assert(self.blockValid(self.cur));
    const n = try self.toInt(try lower_expr.lowerExpr(self, count));
    const place = self.builder.newPlace();
    try self.builder.writeVariable(place, self.cur, n);

    const header = try self.mir.addBlock(self.arena);
    try self.gotoBlock(header);
    self.cur = header;

    const i = try self.builder.readVariable(place, header);
    const c = try self.emit(.igt, &.{ i, .zero });
    const body_b = try self.mir.addBlock(self.arena);
    const step_b = try self.mir.addBlock(self.arena);
    const exit = try self.mir.addBlock(self.arena);
    try self.branchTo(c, body_b, exit, false);

    try self.loops.append(self.arena, .{ .brk = exit, .cont = step_b });
    self.cur = body_b;
    try lower_control.lowerCondBody(self, body, false); // §5.9: a loop body is never static
    try self.gotoBlock(step_b);
    const popped = self.loops.pop().?;
    assert(popped.brk == exit); // the body's loops popped their own

    try self.builder.sealBlock(step_b);
    self.cur = step_b;
    const cur_i = try self.builder.readVariable(place, step_b);
    try self.builder.writeVariable(place, step_b, try self.emit(.isub, &.{ cur_i, .one }));
    try self.gotoBlock(header);

    try self.builder.sealBlock(header);
    try self.builder.sealBlock(exit);
    self.cur = exit;
}

/// Lowers a §5.9.2 `for` loop. A genvar loop (§3.5) is unrolled instead (§6.6.1),
/// which is what makes `genvar`-indexed nets work.
pub fn lowerFor(self: *Lower, init_s: Ast.StmtId, cond: Ast.ExprId, step: Ast.StmtId, body: Ast.StmtId) Oom!void {
    assert(cond == .none or self.exprValid(cond));
    assert(self.blockValid(self.cur));
    if (try tryUnrollFor(self, init_s, cond, step, body)) return;

    try lower_stmt.lowerStmt(self, init_s);
    const header = try self.mir.addBlock(self.arena);
    try self.gotoBlock(header);
    self.cur = header;

    const c = try self.toBool(try lower_expr.lowerExpr(self, cond));
    const body_b = try self.mir.addBlock(self.arena);
    const step_b = try self.mir.addBlock(self.arena);
    const exit = try self.mir.addBlock(self.arena);
    // `self.cur`, not `header` (see `lowerWhile`): the condition may have been
    // split across blocks by a short-circuit, and the branch belongs at its end.
    try self.branchTo(c, body_b, exit, false);

    try self.loops.append(self.arena, .{ .brk = exit, .cont = step_b });
    self.cur = body_b;
    try lower_control.lowerCondBody(self, body, false); // §5.9: a loop body is never static
    try self.gotoBlock(step_b);
    const popped = self.loops.pop().?;
    assert(popped.brk == exit); // the body's loops popped their own

    try self.builder.sealBlock(step_b);
    self.cur = step_b;
    try lower_stmt.lowerStmt(self, step);
    try self.gotoBlock(header);

    try self.builder.sealBlock(header);
    try self.builder.sealBlock(exit);
    self.cur = exit;
}

// ---- private ----

/// §3.5/§6.6.1 genvar loop-generate. Returns false when this is an ordinary
/// procedural `for` (which `lowerFor` then lowers as a CFG loop). The bounds
/// fold with `shapeEval`: a parameter in them fixes how many copies of the body
/// exist, so it is a §3.4 shape parameter like an array bound.
fn tryUnrollFor(self: *Lower, init_s: Ast.StmtId, cond: Ast.ExprId, step: Ast.StmtId, body: Ast.StmtId) Oom!bool {
    assert(cond == .none or self.exprValid(cond));
    const gv = genvarOf(self, init_s) orelse return false;
    // §6.6.1 "Both the initialization and iteration assignments shall assign
    // to the same genvar": a property of the text, so judged before any trip
    // (a zero-trip loop never evaluates its step). E0419's explain owns it.
    if (step != .none and self.file.stmt(step) == .assign) {
        const t = self.file.stmt(step).assign.target;
        const name = if (self.file.exprs.tag(t) == .ident) self.file.str(self.file.exprs.strOf(t)) else "";
        if (!std.mem.eql(u8, name, gv)) {
            try self.err(self.file.exprs.mainTok(t), .E0419, "the iteration assigns `{s}`, and the initialization the genvar `{s}`: both shall assign the same genvar", .{ name, gv });
            return true;
        }
    }
    const init_v = assignValueOf(self, init_s).?;
    const start = lower_constfold.shapeEval(self, init_v) orelse {
        if (unknownLiteral(self, init_v)) |lit|
            try self.err(self.file.exprs.mainTok(lit), .E0486, "the initialization sets the genvar `{s}`", .{gv})
        else
            try self.err(self.file.exprs.mainTok(cond), .E0417, "initial value of `{s}`", .{gv});
        return true;
    };
    // §6.6.1 a scheme that never ends is refused before any body is
    // lowered; one that ends is unrolled in full, however long.
    const Scheme = struct {
        self: *Lower,
        gv: []const u8,
        cond: Ast.ExprId,
        step: Ast.ExprId,
        pub fn holds(sc: @This(), v: Const) Oom!?bool {
            try sc.self.consts.put(sc.self.arena, sc.gv, v);
            const c = lower_constfold.shapeEval(sc.self, sc.cond) orelse return null;
            return c.isTrue();
        }
        pub fn next(sc: @This(), v: Const) Oom!?Const {
            try sc.self.consts.put(sc.self.arena, sc.gv, v);
            return lower_constfold.shapeEval(sc.self, sc.step);
        }
        pub fn same(a: Const, b: Const) bool {
            return switch (a) {
                .int => |x| b == .int and b.int == x,
                .real => |x| b == .real and @as(u64, @bitCast(b.real)) == @as(u64, @bitCast(x)),
                .str => |x| b == .str and std.mem.eql(u8, b.str, x),
            };
        }
    };
    const scheme: Scheme = .{ .self = self, .gv = gv, .cond = cond, .step = assignValueOf(self, step) orelse .none };
    switch (try Elaborate.genvarLoop(Const, scheme, start)) {
        .repeats => |v| {
            _ = self.consts.remove(gv);
            try self.err(self.file.exprs.mainTok(cond), .E0420, "`{s}` repeats the value {d}, so the loop never ends", .{ gv, v.asInt() });
            return true;
        },
        // The unroll meets the same unfolded value and reports it.
        .ends, .unfolded => {},
    }
    try self.consts.put(self.arena, gv, start);
    // Visible to `queueDisplay`'s snapshot while the body lowers.
    try self.active_genvars.append(self.arena, gv);
    defer _ = self.active_genvars.pop();
    // §5.11: a `break`/`continue` that reaches this loop first is E0440.
    const saved_base = self.analog_for_base;
    self.analog_for_base = self.loops.items.len;
    defer self.analog_for_base = saved_base;

    while (true) {
        const c = lower_constfold.shapeEval(self, cond) orelse {
            try self.err(self.file.exprs.mainTok(cond), .E0418, "", .{});
            break;
        };
        if (!c.isTrue()) break;
        // §6.6.1 a loop generate's block is `name[i]` in §9.15's "path".
        if (body != .none and self.file.stmt(body) == .block and self.file.stmt(body).block.gen_name != .none)
            self.gen_iter = if (self.consts.get(gv)) |v| v.asInt() else null;
        try lower_stmt.lowerStmt(self, body);
        const step_v = assignValueOf(self, step) orelse .none;
        const next = lower_constfold.shapeEval(self, step_v) orelse {
            if (unknownLiteral(self, step_v)) |lit|
                try self.err(self.file.exprs.mainTok(lit), .E0486, "the iteration sets the genvar `{s}`", .{gv})
            else
                try self.err(self.file.exprs.mainTok(cond), .E0419, "", .{});
            break;
        };
        try self.consts.put(self.arena, gv, next);
    }
    _ = self.consts.remove(gv);
    return true;
}

/// Returns the genvar a `for` init statement assigns, or null (LRM §3.5).
fn genvarOf(self: *const Lower, init_s: Ast.StmtId) ?[]const u8 {
    assert(init_s == .none or @backingInt(init_s) < self.stmtCount());
    const m = self.module orelse return null;
    if (init_s == .none) return null;
    const s = self.file.stmt(init_s);
    if (s != .assign) return null;
    const t = s.assign.target;
    if (self.file.exprs.tag(t) != .ident) return null;
    const name_id = self.file.exprs.strOf(t);
    for (m.genvars) |g| if (g == name_id) return self.file.str(name_id);
    assert(name_id != .none);
    return null;
}

/// §6.6.1 "It shall be an error if any bit of the genvar is set to x or z":
/// the first literal under `e` with an x or z bit, which is what keeps a
/// genvar assignment's value from folding. `markDiscreteExprs` exempts these
/// literals from E0130, since the scheme is folded, never executed.
fn unknownLiteral(self: *const Lower, e: Ast.ExprId) ?Ast.ExprId {
    assert(e == .none or self.exprValid(e));
    assert(self.file.exprs.len() != 0 or e == .none);
    if (e == .none) return null;
    const ex = &self.file.exprs;
    if (ex.tag(e) == .logic_literal) return if (ex.logicValue(e).hasUnknown()) e else null;
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (unknownLiteral(self, c)) |hit| return hit;
    return null;
}

fn assignValueOf(self: *const Lower, s: Ast.StmtId) ?Ast.ExprId {
    assert(s == .none or @backingInt(s) < self.stmtCount());
    if (s == .none) return null;
    const st = self.file.stmt(s);
    const v = if (st == .assign) st.assign.value else null;
    if (v) |e| assert(e == .none or self.exprValid(e));
    return v;
}

test "tryUnrollFor: §6.6.1 a genvar loop's scheme folds, assigns one genvar, holds no x" {
    const decls = "  genvar i;\n  integer m;\n  real y;";
    const cases = [_]struct { body: []const u8, want: ?diag.Code }{
        .{ .body = "    for (i = 0; i < 3; i = i + 1) y = y + i;", .want = null },
        .{ .body = "    m = 2;\n    for (i = m; i < 2; i = i + 1) y = y + 1.0;", .want = .E0417 },
        .{ .body = "    m = 2;\n    for (i = 0; i < m; i = i + 1) y = y + 1.0;", .want = .E0418 },
        // "Both the initialization and iteration assignments shall assign to
        // the same genvar", and the iteration is constant too.
        .{ .body = "    m = 2;\n    for (i = 0; i < 2; m = i + 1) y = y + 1.0;", .want = .E0419 },
        .{ .body = "    m = 1;\n    for (i = 0; i < 2; i = i + m) y = y + 1.0;", .want = .E0419 },
        // "It shall be an error if any bit of the genvar is set to x or z."
        .{ .body = "    for (i = 1'bx; i < 2; i = i + 1) y = y + 1.0;", .want = .E0486 },
        // §5.11 a jump never leaves an unrolled analog_for.
        .{ .body = "    for (i = 0; i < 2; i = i + 1) begin if (i == 1) break; end", .want = .E0440 },
    };
    for (cases) |c| try Lower.expectBodyVerdict(decls, c.body, c.want);
}

test "loops: §5.9 the procedural loops and their jumps" {
    const decls = "  integer k;\n  real y;";
    try Lower.expectBodyVerdict(decls, "    k = 0;\n    while (k < 3) k = k + 1;", null);
    try Lower.expectBodyVerdict(decls, "    repeat (3) y = y + 1.0;", null);
    try Lower.expectBodyVerdict(decls, "    for (k = 0; k < 3; k = k + 1) begin\n      if (k == 1) break;\n      y = y + 1.0;\n    end", null);
    try Lower.expectBodyVerdict(decls, "    for (k = 0; k < 3; k = k + 1) begin\n      if (k == 1) continue;\n      y = y + 1.0;\n    end", null);
    // A jump outside every loop (E0404).
    try Lower.expectBodyVerdict(decls, "    break;", .E0404);
}

test "§6.6.1 a genvar loop that ends is unrolled however long; one that never ends is E0420" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { cond: []const u8, step: []const u8, code: ?diag.Code }{
        .{ .cond = "i < 4096", .step = "i = i + 1", .code = null }, // the old cap
        .{ .cond = "i < 4097", .step = "i = i + 1", .code = null }, // one past it
        .{ .cond = "i < 100000", .step = "i = i + 1", .code = null }, // far past it
        .{ .cond = "i < 9000", .step = "i = (i + 1) % 8", .code = .E0420 }, // repeats a value
        .{ .cond = "i < 3", .step = "i = i", .code = .E0420 }, // repeats at once
        // A cycle far longer than the old cap.
        .{ .cond = "i < 300000", .step = "i = (i + 1) % 100000", .code = .E0420 },
    };
    for (cases) |c| {
        const src = try gpa.print(
            \\module m(p);
            \\inout p; electrical p;
            \\genvar i;
            \\generate for (i = 0; {s}; {s}) begin end endgenerate
            \\analog I(p) <+ 0.0;
            \\endmodule
        , .{ c.cond, c.step });
        defer gpa.free(src);
        var h: Lower.Harness = undefined;
        try h.init(gpa, src);
        defer h.deinit();
        _ = h.low.lowerFile() catch |err| switch (err) {
            error.DiagnosticsReported => {},
            else => |e| return e,
        };
        if (c.code) |want| {
            try std.testing.expect(h.bag.count() >= 1);
            try std.testing.expectEqual(want, h.bag.at(0).code);
        } else try std.testing.expectEqual(@as(usize, 0), h.bag.count());
    }
}
