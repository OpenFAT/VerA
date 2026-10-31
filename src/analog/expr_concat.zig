const std = @import("std");
const Lower = @import("Lower.zig");
const lower_constfold = @import("constfold.zig");
const Ast = @import("frontend").Ast;
const constfold = @import("frontend").constfold;
const Const = constfold.Const;
const Mir = @import("ir").Mir;
const diag = @import("diag");
const lower_expr = @import("expr.zig");
const Oom = Lower.Oom;
const TypedValue = Lower.TypedValue;
const poison = Lower.poison;

/// `{a, b, ...}` in a value position. The INTEGER form (§4.2.13) needs each
/// operand's bit width, which only the token text carries, so `parser.zig`
/// folds it and lowering never sees one, but for integer function calls
/// (`intCallConcat`); what is left here is §3.3 Table 3-3
/// `{Str1,...,Strn}`, "concatenation of Str1,…,Strn" — the LRM's own example is
/// `{ "hello", " ", "world" }` == `"hello world"`.
///
/// Constant operands fold to one `str_const`. Table 3-3 lets an operand be "of
/// type string", so one known only while the device runs is legal: each run
/// of constant operands still folds, and the pieces are joined by the
/// synthetic `$str$cat`, which builds the string in its call site's scratch
/// (`str_kernels.zStrCat`) exactly as `$sformat` does.
///
/// A `.multi_concat` arrives here for two reasons: §4.2.13 evaluates a
/// non-literal operand once, so the parser does not unroll one; and §3.3
/// Table 3-3's Replication row says the "multiplier must be of integral type
/// and can be nonconstant. If multiplier is nonconstant or Str is of type
/// string, the result is a string containing N concatenated copies", and the
/// parser unrolls only a literal count (see `replCount`). A multiplier the
/// folder can make a number of is unrolled here; one it cannot is the row's
/// nonconstant case, and `$str$repeat`
/// makes the N copies while the device runs (`str_kernels.zStrRepeat`).
pub fn lowerConcat(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const repl = ex.tag(e) == .multi_concat;
    const elems = ex.args(if (repl) ex.rhs(e) else e);
    if (elems.len == 0) {
        try self.err(self.file.exprs.mainTok(e), .E0326, "", .{});
        return poison;
    }
    // §4.2.13 "the operands shall be evaluated exactly once, even if the
    // replication constant is zero": `foldBitConcat`'s shape — zero groups,
    // then the sized value their width-zero operands left untouched.
    const last = elems[elems.len - 1];
    if (!repl and elems.len > 1 and ex.tag(last) == .int_literal and ex.intLiteral(last).width != 0) {
        for (elems[0 .. elems.len - 1]) |g| {
            if (ex.tag(g) != .multi_concat) break;
        } else {
            for (elems[0 .. elems.len - 1]) |g| for (ex.args(ex.rhs(g))) |op| {
                _ = try lower_expr.lowerExpr(self, op);
            };
            return lower_expr.lowerExpr(self, last);
        }
    }
    var copies: i64 = 1;
    // §3.3 Table 3-3's nonconstant multiplier, as its integer Value.
    var runtime_count: ?Mir.Value = null;
    if (repl) count: {
        const count = ex.lhs(e);
        const c = try lower_expr.lowerExpr(self, count);
        const k: ?Const = switch (self.mir.valueDef(c.v)) {
            .int_const => |n| .{ .int = n },
            .float_const => |f| .{ .real = f },
            // A constant expression the SSA left as arithmetic (`1.0 + 1.5`)
            // still folds, and so does one over parameters: the count sizes
            // the result, so a parameter in it is a SHAPE parameter (§3.4 —
            // fixed at compilation, `checkShape` refuses a card that moves it).
            .undef, .str_const, .param_ref, .block_param, .inst_result => lower_constfold.shapeEval(self, count),
        };
        const v = k orelse Const{ .str = "" };
        if (v == .str) {
            // A multiplier that survives to the residual is the row's
            // nonconstant case, which "must be of integral type": the §4.2.1
            // real-to-integer conversion below is a constant's.
            if (c.ty != .integer) {
                try self.err(self.file.exprs.mainTok(count), .E0327, "a nonconstant replication multiplier shall be of integral type, got {s}", .{@tagName(c.ty)});
                return poison;
            }
            runtime_count = c.v;
            break :count;
        }
        // §4.2.1: a real replication factor "will first be converted to an
        // integer value using the rules described in 4.2.1.1". A real with no
        // nearest integer (inf, NaN, past i64) yields no count.
        copies = v.asIntExact() orelse {
            try self.err(self.file.exprs.mainTok(count), .E0327, "a replication constant shall be a finite integer after conversion, got {d}", .{v.asReal()});
            return poison;
        };
        // §4.2.13: the replication constant is "non-negative, non-x and
        // non-z". Zero is legal and yields the empty string.
        if (copies < 0) {
            try self.err(self.file.exprs.mainTok(ex.lhs(e)), .E0327, "a replication constant shall be non-negative, got {d}", .{copies});
            return poison;
        }
    }
    // `out` is the current run of constant operands; `parts` holds the
    // run-time operands and the folded runs between them, in source order.
    var out: std.ArrayList(u8) = .empty;
    var parts: std.ArrayList(Mir.Value) = .empty;
    for (elems, 0..) |el, i| {
        const tv = try lower_expr.lowerExpr(self, el);
        if (i == 0 and tv.ty == .integer and runtime_count == null) return intCallConcat(self, e, elems, copies, tv);
        if (tv.ty != .string) {
            try self.err(self.file.exprs.mainTok(e), .E0327, "only sized constants and strings can be concatenated", .{});
            return poison;
        }
        switch (self.mir.valueDef(tv.v)) {
            .str_const => |s| try out.appendSlice(self.arena, s),
            .undef, .float_const, .int_const, .param_ref, .block_param, .inst_result => {
                if (out.items.len != 0)
                    try parts.append(self.arena, try self.mir.addStrConst(self.arena, try out.toOwnedSlice(self.arena)));
                try parts.append(self.arena, tv.v);
            },
        }
    }
    if (parts.items.len != 0 or runtime_count != null) {
        self.out.uses.insert(.str_tasks);
        if (out.items.len != 0 or parts.items.len == 0)
            try parts.append(self.arena, try self.mir.addStrConst(self.arena, try out.toOwnedSlice(self.arena)));
        const str = if (parts.items.len == 1) parts.items[0] else try self.call("$str$cat", parts.items);
        const n = runtime_count orelse
            if (copies == 1) return .{ .v = str, .ty = .string } else try self.mir.addIntConst(self.arena, copies);
        return .{ .v = try self.call("$str$repeat", &.{ n, str }), .ty = .string };
    }
    if (repl) {
        // Past 4096 bytes the copies are made while the device runs, into a
        // row sized for them (`cg_strcap`), rather than spelled out in the
        // device's source: the text is as long as the copies make it, and
        // memory is the only bound (#29).
        if (@as(u128, @intCast(copies)) * out.items.len > 4096) {
            self.out.uses.insert(.str_tasks);
            const one = try self.mir.addStrConst(self.arena, try out.toOwnedSlice(self.arena));
            return .{ .v = try self.call("$str$repeat", &.{ try self.mir.addIntConst(self.arena, copies), one }), .ty = .string };
        }
        // N copies of "" are "", and are not counted out, so `{1e15{""}}`
        // does not spin for the count alone.
        if (out.items.len != 0) {
            const one = try self.arena.dupe(u8, out.items);
            out.clearRetainingCapacity();
            for (0..@intCast(copies)) |_| try out.appendSlice(self.arena, one);
        }
    }
    // The interner borrows: the bytes live in the arena, which outlives the Mir.
    return .{ .v = try self.mir.addStrConst(self.arena, try out.toOwnedSlice(self.arena)), .ty = .string };
}

/// §4.2.13's integer form over integer function calls, the operands the
/// parser cannot fold but whose width the declaration fixes: an
/// `analog_function_type` `integer` (§4.7.1) is 32 bits (§3.2). `first` is
/// `elems[0]` already lowered. §4.2.13 `result = {4{func(w)}}` "would be
/// computed as: y = func(w); result = {y, y, y, y}", so each operand is
/// evaluated once however many `copies` there are. Every operand is 32 bits
/// wide, so the integer the result is held in is its low 32: the last one.
fn intCallConcat(self: *Lower, e: Ast.ExprId, elems: []const Ast.ExprId, copies: i64, first: TypedValue) Oom!TypedValue {
    const ex = &self.file.exprs;
    var last = first;
    for (elems, 0..) |el, i| {
        const tv = if (i == 0) first else try lower_expr.lowerExpr(self, el);
        if (tv.ty != .integer or ex.tag(el) != .call) {
            try self.err(ex.mainTok(e), .E0327, "only sized constants, strings and integer function calls can be concatenated", .{});
            return poison;
        }
        last = tv;
    }
    // §4.2.13: a zero replication "shall appear only within a concatenation
    // in which at least one of the operands of the concatenation has a
    // positive size"; alone it has no width and no value.
    if (copies == 0) {
        try self.err(ex.mainTok(e), .E0326, "", .{});
        return poison;
    }
    return last;
}

test "lowerConcat: §3.3 Table 3-3 string concatenation and replication" {
    const cases = [_]struct { body: []const u8, want: ?diag.Code }{
        .{ .body = "    s = {cnt{\"ab\"}};", .want = null },
        .{ .body = "    s = {s, \"x\"};", .want = null },
        // A multiplier known only while the device runs makes N copies then.
        .{ .body = "    k = 1 + (V(p, n) > 0.0);\n    s = {k{\"ab\"}};", .want = null },
        // "non-negative" (§4.2.13), and "of integral type" when nonconstant.
        .{ .body = "    s = {neg{\"ab\"}};", .want = .E0327 },
        .{ .body = "    r = V(p, n);\n    s = {r{\"ab\"}};", .want = .E0327 },
        // The folded copies are as many as asked: past the 4096 bytes a
        // fixed row once held (#29).
        .{ .body = "    s = {big{\"a\"}};", .want = null },
        // N copies of "" are "" for any N, at no cost proportional to N.
        .{ .body = "    s = {huge{\"\"}};", .want = null },
    };
    for (cases) |c| try Lower.expectBodyVerdict(lower_expr.test_decls, c.body, c.want);
}
