//! Annex A.8.1 brace forms: `{ ... }` concatenation, `{ n { ... } }`
//! multiple concatenation and the `'{ ... }` assignment pattern -> one
//! `Ast.ExprId`. In an analog parse a literal replication count is unrolled
//! here and a concatenation of sized literals folds to one literal (§4.2.13);
//! anything the parser cannot count stays a `.multi_concat` or
//! `.pattern_repl` for lowering, which holds the constant folder. A digital
//! parse keeps every group and count as written.
//!
//! LRM clauses cited: §3.2.1, §3.3, §3.4.4, §3.4.8, §3.6.3.2, §4.2.1,
//! §4.2.1.1, §4.2.13, §4.2.14, §4.5.6, §4.5.11.

const std = @import("std");
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_expr = @import("expr.zig");
const lexer = @import("../lexer.zig");
const Ast = @import("../ast.zig");
const Error = parser.Error;

/// §4.2.13 / A.8.1 `analog_concatenation` or `analog_multiple_concatenation`,
/// cursor on the `{` (token `tok`).
pub fn parseConcat(self: *Parser, tok: u32) Error!Ast.ExprId {
    var items: std.ArrayList(Ast.ExprId) = .empty;
    const count = try braceOperands(self, &items);
    if (count) |n| return multiConcat(self, tok, n, items.items);
    if (try foldBitConcat(self, tok, items.items)) |folded| return folded;
    const off = try self.file.exprs.addExprList(self.arena, items.items);
    return self.file.exprs.add(self.arena, .{ .tag = .concat, .main_tok = tok, .extra = off });
}

/// A.8.1 `assignment_pattern` `'{ ... }` (§3.4.4 array defaults, §4.5.6
/// filter coefficient arguments), cursor on the `'{` (token `tok`). An empty
/// element is `.none`.
pub fn parseAssignPattern(self: *Parser, tok: u32) Error!Ast.ExprId {
    self.pos += 1;
    var items: std.ArrayList(Ast.ExprId) = .empty;
    if (self.peek() != .rbrace) {
        // §3.6.3.2's bus nodeset admits a hole,
        // `electrical [0:4] bus = '{2.3,4.5,,6.0};`: "a null value in
        // the constant array indicates that no nodeset value is being
        // specified for this element". A.8.1 has no such alternative;
        // the clause's example governs. A hole is `.none`, which is
        // also what `Lower.fillPattern` gives a cell nothing reaches.
        const first = if (self.peek() == .comma) Ast.ExprId.none else try parse_expr.parseExpr(self);
        // A.8.1's second alternative:
        //
        //   assignment_pattern ::= '{ expression { , expression } }
        //                        | '{ constant_expression
        //                             { expression { , expression } } }
        //
        // one replication filling the whole pattern, as §4.2.14's
        // `'{ 5{0.0} }`. Nothing but `}` may follow the inner group.
        // The inner braces are plain `{`; a `'{` there is a row of a
        // multi-dimensional pattern (§3.4.8) and stays one element.
        if (first != .none and self.peek() == .lbrace) {
            var inner: std.ArrayList(Ast.ExprId) = .empty;
            try braceGroup(self, &inner);
            if (replCount(self, first)) |n| {
                for (0..n) |_| try items.appendSlice(self.arena, inner.items);
            } else {
                // A constant_expression the parser cannot evaluate
                // (`'{N{0.5}}`, N a localparam): lowering unrolls it
                // with the folder in hand, `Lower.patternElems`.
                const off = try self.file.exprs.addExprList(self.arena, inner.items);
                const group = try self.file.exprs.add(self.arena, .{ .tag = .assign_pattern, .main_tok = tok, .extra = off });
                try items.append(self.arena, try self.file.exprs.add(self.arena, .{ .tag = .pattern_repl, .main_tok = tok, .lhs = first, .rhs = group }));
            }
        } else {
            try items.append(self.arena, first);
            while (self.eat(.comma)) try items.append(
                self.arena,
                if (self.peek() == .comma or self.peek() == .rbrace) .none else try parse_expr.parseExpr(self),
            );
        }
    }
    _ = try self.expect(.rbrace);
    const off = try self.file.exprs.addExprList(self.arena, items.items);
    return self.file.exprs.add(self.arena, .{ .tag = .assign_pattern, .main_tok = tok, .extra = off });
}

/// A.8.1, both brace forms at once:
///
///     analog_concatenation          ::= { analog_expression
///                                         { , analog_expression } }
///     analog_multiple_concatenation ::= { constant_expression
///                                         analog_concatenation }
///
/// Consumes `{ ... }` at the cursor and appends the group's operands to
/// `items`, flattened. Returns the count of a replication it cannot unroll
/// (a non-literal count, or any count in digital mode); `items` then holds
/// one copy of the inner operands.
///
/// The forms are told apart by the token after the first expression: a `{`
/// there opens a replication's inner concatenation (`{2+1{a}}` versus
/// `{2+1}`). In analog mode, literal counts are unrolled for §4.2.13 because
/// `foldBitConcat` needs every sized operand: `{4{2'b10}}` arrives as four
/// operands and `{{0{1'b1}}, b}` as `{b}`. A nonconstant count, or a group
/// over anything but literals (`{4{f(w)}}`, whose call §4.2.13 evaluates
/// once), stays a `.multi_concat` (§3.3 Table 3-3 allows a nonconstant one
/// for a string, `{i{"Hi"}}`).
/// Digital mode keeps every group and count unflattened.
fn braceOperands(self: *Parser, items: *std.ArrayList(Ast.ExprId)) Error!?Ast.ExprId {
    // An analog `{{{...` recurses here through `braceGroup` without passing
    // `parseUnary`, so each brace is a level of its own.
    if (self.segmentDue()) return self.segment(braceOperands, .{ self, items });
    self.enter();
    defer self.leave();
    _ = try self.expect(.lbrace);
    if (self.eat(.rbrace)) return null;

    if (self.digital or self.peek() != .lbrace) {
        const first = try parse_expr.parseExpr(self);
        if (self.peek() == .lbrace) {
            var inner: std.ArrayList(Ast.ExprId) = .empty;
            try braceGroup(self, &inner);
            _ = try self.expect(.rbrace);
            if (self.digital) {
                // Preserve the multiplier and grouping: zero replication
                // still evaluates its operands and has contextual legality.
                try items.appendSlice(self.arena, inner.items);
                return first;
            }
            const n = concatReplCount(self, first) orelse {
                try items.appendSlice(self.arena, inner.items);
                return first;
            };
            // §4.2.13 "When a replication expression is evaluated, the
            // operands shall be evaluated exactly once, even if the
            // replication constant is zero." A literal has nothing to
            // evaluate, so only a group over something else is kept, as a
            // `.multi_concat`: `foldBitConcat` gives a zero one no width, and
            // `Lower.lowerConcat` evaluates any other's operands once.
            for (inner.items) |it| switch (self.file.exprs.tag(it)) {
                .int_literal, .real_literal, .str_literal, .logic_literal => {},
                else => { // else: anything but a literal may have an effect to evaluate
                    try items.appendSlice(self.arena, inner.items);
                    return first;
                },
            };
            for (0..n) |_| try items.appendSlice(self.arena, inner.items);
            return null;
        }
        try items.append(self.arena, first);
        if (!self.eat(.comma)) {
            _ = try self.expect(.rbrace);
            return null;
        }
    }
    while (true) {
        if (!self.digital and self.peek() == .lbrace) {
            try braceGroup(self, items);
        } else try items.append(self.arena, try parse_expr.parseExpr(self));
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.rbrace);
    return null;
}

/// `braceOperands` for positions that cannot pass a count upwards: a
/// nonconstant replication stays one operand instead of being returned.
fn braceGroup(self: *Parser, items: *std.ArrayList(Ast.ExprId)) Error!void {
    const at = self.pos;
    var g: std.ArrayList(Ast.ExprId) = .empty;
    if (try braceOperands(self, &g)) |c| {
        try items.append(self.arena, try multiConcat(self, at, c, g.items));
    } else if (self.digital) {
        const off = try self.file.exprs.addExprList(self.arena, g.items);
        try items.append(self.arena, try self.file.exprs.add(self.arena, .{ .tag = .concat, .main_tok = at, .extra = off }));
    } else try items.appendSlice(self.arena, g.items);
}

/// `{count{items}}` kept unexpanded for lowering (§3.3's nonconstant
/// multiplier). `rhs` is the inner `.concat`, exactly as `Ast.ExprTag`
/// documents the tag.
fn multiConcat(self: *Parser, tok: u32, count: Ast.ExprId, items: []const Ast.ExprId) Error!Ast.ExprId {
    const off = try self.file.exprs.addExprList(self.arena, items);
    const inner = try self.file.exprs.add(self.arena, .{ .tag = .concat, .main_tok = tok, .extra = off });
    return self.file.exprs.add(self.arena, .{ .tag = .multi_concat, .main_tok = tok, .lhs = count, .rhs = inner });
}

/// Returns a replication count when it is an integer literal in 0..4096, else
/// null. §4.2.13 wants a "non-negative, non-x and non-z constant expression";
/// a literal is the only constant the parser can evaluate.
///
/// A negative count is not reported here: it returns null, the group keeps
/// its `.multi_concat`, and `lowerConcat` names the rule with the folder in
/// hand so `{n-5{a}}` gets the same verdict as `{-5{a}}`.
///
/// ponytail: the cap is an unrolling guard, not a rule. 32 bits is the
/// widest concatenation an `integer` can hold (E0217), so no legal integer
/// replication comes near it; a string replication past the cap falls to
/// the same lowering path as a nonconstant one.
fn replCount(self: *const Parser, e: Ast.ExprId) ?u32 {
    const ex = &self.file.exprs;
    if (ex.tag(e) != .int_literal) return null;
    const v = ex.intValue(e);
    if (v < 0 or v > 4096) return null;
    return @intCast(v);
}

/// `replCount` for a concatenation's count, which §4.2.1 also lets be real:
/// "If a real expression is used for the replication factor of a
/// concatenation, the expression will first be converted to an integer value
/// using the rules described in 4.2.1.1": round to nearest, ties away from
/// zero, which is `@round`. So `{2.5{4'd3}}` is `{3{4'd3}}`.
///
/// Only a concatenation's: an A.8.1 assignment pattern is not one, and keeps
/// `replCount`. A negative real is a unary minus, not a literal, so it
/// reaches `lowerConcat` exactly as `{-5{a}}` does.
fn concatReplCount(self: *const Parser, e: Ast.ExprId) ?u32 {
    const ex = &self.file.exprs;
    if (ex.tag(e) != .real_literal) return replCount(self, e);
    const r = @round(ex.realValue(e));
    if (!(r >= 0 and r <= 4096)) return null;
    return @intFromFloat(r);
}

/// Folds an analog §4.2.13 integer concatenation of sized literals into one
/// literal with the joined width. "Unsized constant numbers shall not be
/// allowed in concatenations", and in Verilog-A only a §2.6.1 sized constant
/// carries a width. Reports E0216 for an unsized operand and E0217 past 32
/// bits (§3.2.1).
///
/// Returns null in digital mode, when an operand is a logic literal (x/z or
/// wider than 64 bits), or when no operand is sized: `{a, b}` stays a
/// `.concat` for §4.5.11 filter coefficients, §3.2.2 array assignment and the
/// §3.3 Table 3-3 string form, which lowering handles.
fn foldBitConcat(self: *Parser, tok: u32, items: []const Ast.ExprId) Error!?Ast.ExprId {
    if (self.digital) return null;
    const ex = &self.file.exprs;
    var any_sized = false;
    var effects: std.ArrayList(Ast.ExprId) = .empty;
    for (items) |it| {
        if (ex.tag(it) == .logic_literal) return null;
        // A zero group `braceOperands` kept for §4.2.13's "evaluated exactly
        // once": "considered to have a size of zero and is ignored".
        if (ex.tag(it) == .multi_concat and concatReplCount(self, ex.lhs(it)) == 0) {
            try effects.append(self.arena, it);
            continue;
        }
        if (ex.tag(it) != .int_literal) continue;
        if (ex.intLiteral(it).width != 0) any_sized = true;
    }
    if (!any_sized) return null;

    var acc: u64 = 0;
    var total: u64 = 0;
    for (items) |it| {
        if (std.mem.findScalar(Ast.ExprId, effects.items, it) != null) continue;
        const lit: ?Ast.IntLiteral = if (ex.tag(it) == .int_literal and ex.intLiteral(it).width != 0)
            ex.intLiteral(it)
        else
            null;
        const l = lit orelse {
            var d = self.failWith(ex.mainTok(it), .E0216);
            d.help("give the operand a width, e.g. `8'd5`", .{});
            try d.emit();
            return error.ParseError;
        };
        total += l.width;
        // §3.2.1: the result is a 32-bit integer; wider is diagnosed, not wrapped.
        if (total > 32) return self.failAt(tok, .E0217, "at least {d} bits wide", .{total});
        const mask: u64 = (@as(u64, 1) << @intCast(l.width)) - 1;
        acc = (acc << @intCast(l.width)) | (@as(u64, @bitCast(l.value)) & mask);
    }
    const folded = try ex.addIntLiteral(self.arena, tok, .{ .value = @bitCast(acc), .width = @intCast(total), .signed = false });
    if (effects.items.len == 0) return folded;
    // The zero groups first, the value last: `Lower.lowerConcat` evaluates
    // each group's operands once and answers the folded literal.
    try effects.append(self.arena, folded);
    const off = try ex.addExprList(self.arena, effects.items);
    return try ex.add(self.arena, .{ .tag = .concat, .main_tok = tok, .extra = off });
}
