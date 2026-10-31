//! Procedural timing controls: the tokens of an A.6.5 `@(...)`, `@*`,
//! `#delay` or `wait (...)` prefix, an intra-assignment control, or a §5.10
//! event expression in, the `Ast.Stmt.event_control` row or event
//! `Ast.ExprId` out.
//! Cites: LRM §5.10, §5.10.1-§5.10.4, A.6.5; IEEE 1364-2005 §9.7, §9.7.5,
//! §9.7.7, §9.22.4.
//!
//! Contents:
//! - `pub fn parseEventTerm(self: *Parser) Error!Ast.ExprId`
//! - `pub fn parseEventControl(self: *Parser) Error!Ast.StmtId`
//! - `pub fn parseDelay(self: *Parser) Error!Ast.ExprId`
//! - `pub fn parseIntraTiming(self: *Parser) Error!struct`

const std = @import("std");
const assert = std.debug.assert;
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const Error = parser.Error;
const parse_expr = @import("expr.zig");
const parse_stmt = @import("stmt.zig");
const parse_hier = @import("hier.zig");
const parse_literal = @import("literal.zig");
const parse_net = @import("net.zig");
const Ast = @import("../ast.zig");

/// Parses one term of an event expression. §5.10.2 step events carry a list
/// of analysis name strings, not expressions (A.6.5); anything else is an
/// ordinary expression, and `cross`/`above`/`timer`/`absdelta` become
/// `.event_function` in `parsePrimary`.
pub fn parseEventTerm(self: *Parser) Error!Ast.ExprId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    const tok = self.pos;
    // A.6.5 `event_expression ::= … | driver_update expression` is digital,
    // absent from `analog_event_expression`, and legal only in a §7.6
    // connect module (§9.22, E0818), where VerA also reads it in an analog
    // event. Any other analog event falls through to `parseExpr`, which
    // finds no expression (§2.8.2).
    if (self.peek() == .kw_driver_update and (self.in_connect_module or self.discreteGrammar())) {
        if (!self.in_connect_module) {
            var d = self.failWith(tok, .E0818);
            d.msg("`driver_update` in a module that is not a connect module", .{});
            d.note("§9.22: \"Driver access functions can only be called from connect modules\", and driver_update \"is used in combination with the driver access functions\"", .{});
            try d.emit();
        }
        self.pos += 1;
        const sig = try parse_expr.parseExpr(self);
        return self.file.exprs.add(self.arena, .{ .tag = .event_driver_update, .main_tok = tok, .lhs = sig });
    }
    // A.6.5 `event_expression ::= posedge expression | negedge expression`,
    // digital like `driver_update` but legal in any discrete event
    // expression.
    if (self.peek() == .kw_posedge or self.peek() == .kw_negedge) {
        const edge: Ast.ExprTag = if (self.peek() == .kw_posedge) .event_posedge else .event_negedge;
        self.pos += 1;
        const sig = try parse_expr.parseExpr(self);
        return self.file.exprs.add(self.arena, .{ .tag = edge, .main_tok = tok, .lhs = sig });
    }
    const tag: Ast.ExprTag = switch (self.peek()) {
        .kw_initial_step => .event_initial_step,
        .kw_final_step => .event_final_step,
        else => return parse_expr.parseExpr(self), // else: not a §5.10.2 global event, so an event expression
    };
    self.pos += 1;
    var names: std.ArrayList(Ast.StrId) = .empty;
    if (self.eat(.lparen)) {
        // A.6.5 makes the analysis list non-empty and the parenthesised
        // group optional, so `final_step()` has no derivation (annex G
        // Table G.2 item 13: "without arguments should not have
        // parenthesis").
        if (self.peek() == .rparen)
            try self.report(self.pos, .E0220, "after `{s}`", .{@tagName(tag)[6..]});
        if (self.peek() != .rparen) while (true) {
            const s = try self.expect(.string_literal);
            try names.append(self.arena, try parse_literal.internString(self, s));
            if (!self.eat(.comma)) break;
        };
        _ = try self.expect(.rparen);
    }
    const off = try self.file.exprs.addStrList(self.arena, names.items);
    return self.file.exprs.add(self.arena, .{ .tag = tag, .main_tok = tok, .extra = off });
}

/// Parses an A.6.5 analog_event_control_statement (§5.10) from its `@`.
pub fn parseEventControl(self: *Parser) Error!Ast.StmtId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    const tok = self.pos;
    self.pos += 1; // '@'
    // A.6.5 `event_control ::= … | @* | @ (*)`. Both spellings mean the
    // same implicit list and carry no expression, so the statement records
    // `.none` (`Ast.Stmt.event_control`). The §2.9 attribute tokens split
    // `(*)` three ways: `(*` `)`, `(` `*)`, `(` `*` `)`.
    if (eatImplicitEvent(self))
        return self.file.addStmt(self.arena, .{ .event_control = .{ .event = .none, .body = try parse_stmt.parseStmt(self) } }, tok);
    const event = try parseEvent(self);
    // A.6.4 `analog_event_control_statement ::= analog_event_control
    // analog_event_statement`.
    self.analog_event_block = !self.discreteGrammar();
    const body = try parse_stmt.parseStmt(self);
    return self.file.addStmt(self.arena, .{ .event_control = .{ .event = event, .body = body } }, tok);
}

/// Parses an A.6.5 `delay_control` after the `#`: `( mintypmax_expression )`
/// or a `delay_value`.
pub fn parseDelay(self: *Parser) Error!Ast.ExprId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    const saved_delay = self.in_digital_delay;
    self.in_digital_delay = true;
    defer self.in_digital_delay = saved_delay;
    if (!self.eat(.lparen)) return parse_net.parseDelayValue(self);
    const value = try parse_expr.parseMinTypMax(self);
    _ = try self.expect(.rparen);
    return value;
}

/// Parses A.6.2's optional `delay_or_event_control` after the assignment
/// operator: A.6.5 `delay_control | event_control`. Analog has no such
/// production, so outside the discrete grammar this reads nothing and the
/// expression parser reports a `#` or `@`.
pub fn parseIntraTiming(self: *Parser) Error!struct { expr: Ast.ExprId, is_delay: bool, count: Ast.ExprId = .none, implicit: bool = false } {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    if (!self.discreteGrammar()) return .{ .expr = .none, .is_delay = false };
    switch (self.peek()) {
        .hash => {
            self.pos += 1;
            return .{ .expr = try parseDelay(self), .is_delay = true };
        },
        .at => {
            self.pos += 1;
            if (eatImplicitEvent(self)) return .{ .expr = .none, .is_delay = false, .implicit = true };
            return .{ .expr = try parseEvent(self), .is_delay = false };
        },
        // A.6.5 `repeat ( expression ) event_control`.
        .kw_repeat => {
            self.pos += 1;
            _ = try self.expect(.lparen);
            const count = try parse_expr.parseExpr(self);
            _ = try self.expect(.rparen);
            _ = try self.expect(.at);
            if (eatImplicitEvent(self)) return .{ .expr = .none, .is_delay = false, .count = count, .implicit = true };
            return .{ .expr = try parseEvent(self), .is_delay = false, .count = count };
        },
        else => return .{ .expr = .none, .is_delay = false }, // else: no intra-assignment timing control
    }
}

// ---- private ----

/// Consumes A.6.5's `*` or `(*)` after an `@`, the implicit event list, and
/// returns whether it was there. The §2.9 attribute tokens split `(*)` three
/// ways: `(*` `)`, `(` `*)`, `(` `*` `)`.
fn eatImplicitEvent(self: *Parser) bool {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    const star_toks: u32 = switch (self.peek()) {
        .star => 1,
        .attr_open => if (self.peekAt(1) == .rparen) 2 else 0,
        .lparen => if (self.peekAt(1) == .attr_close) 2 else if (self.peekAt(1) == .star and self.peekAt(2) == .rparen) 3 else 0,
        else => 0, // else: any other token after `@` starts an event expression or a name
    };
    self.pos += star_toks;
    return star_toks != 0;
}

/// Parses an A.6.5 `event_control` after the `@`: `( event_expression )` or
/// `hierarchical_event_identifier`.
fn parseEvent(self: *Parser) Error!Ast.ExprId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    if (self.eat(.lparen)) {
        const e = try parseEventExpr(self);
        _ = try self.expect(.rparen);
        return e;
    }
    // A.9.3 `hierarchical_event_identifier`: `c.e`, `$root.top.e`. Its final
    // segment takes no index, so an event-array element is `@(ev[0])`.
    if (self.peekAt(1) == .dot) return parse_expr.parsePrimary(self);
    const id_tok = self.pos;
    const name = try self.expectIdent();
    return self.file.exprs.add(self.arena, .{ .tag = .ident, .main_tok = id_tok, .str = name });
}

/// Parses an A.6.5 analog_event_expression. `or` and `,` both build
/// `.event_or` (§4.2.2 puts them at the `||` level, below everything else).
fn parseEventExpr(self: *Parser) Error!Ast.ExprId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    var lhs = try parseEventTerm(self);
    // Each `or` nests the tree one level, as an operator does.
    const base = self.depth;
    defer self.depth = base;
    while (self.peek() == .kw_or or self.peek() == .comma) {
        const tok = self.pos;
        self.nest();
        self.pos += 1;
        const rhs = try parseEventTerm(self);
        lhs = try self.file.exprs.add(self.arena, .{
            .tag = .event_or,
            .main_tok = tok,
            .lhs = lhs,
            .rhs = rhs,
        });
    }
    return lhs;
}
