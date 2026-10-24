//! Data declarations: annex A.2.1.1 parameters and aliasparams (§3.4), A.2.1.3
//! variable and `reg` declarations (§3.2, §3.3), A.2.1.3 named events
//! (§5.10.4) and A.2.5 dimensions and value ranges -> `Ast.ParamDecl`,
//! `Ast.AliasParam`, `Ast.VarDecl`, `Ast.EventDecl` and `Ast.Dim` values the
//! caller appends to its own scope (a module `Body`, a block, a function).
//!
//! LRM clauses cited: §3.2, §3.2.2, §3.3, §3.4, §3.4.1, §3.4.2, §3.4.4,
//! §3.4.5, §3.4.7, §5.10.4, §9.7.3, §9.18; IEEE 1364-2005 Table 7-1.

const std = @import("std");
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_expr = @import("expr.zig");
const parse_literal = @import("literal.zig");
const Ast = @import("../ast.zig");
const token = @import("../token.zig");
const Error = parser.Error;

// -----------------------------------------------------------------------
// A.2.1.1 parameter declarations: LRM §3.4
// -----------------------------------------------------------------------

/// A.2.1.1 `aliasparam_declaration`, from the keyword through the `;`. Shared
/// by module items and A.1.9 paramset items.
pub fn parseAliasparam(self: *Parser) Error!Ast.AliasParam {
    self.pos += 1; // 'aliasparam'
    const alias = try self.expectIdent();
    _ = try self.expect(.assign_eq);
    // §3.4.7 prints `aliasparam m = $mfactor;`, though Syntax 3-2 puts a
    // parameter_identifier on the right, so a §9.18 system parameter is
    // admitted here too. Which ones have storage to alias is
    // `Lower.aliasSystemParam`'s question.
    const target = try self.expectIdentOrSys();
    _ = try self.expect(.semicolon);
    return .{ .alias = alias, .target = target };
}

/// Parses a `parameter`/`localparam` declaration, value ranges included
/// (§3.4, §3.4.1, §3.4.2, §3.4.5), up to but not including the `;`.
/// `parameter real a = 1, b = 2;` is one declaration but two `ParamDecl`s,
/// so each is appended to `out`.
pub fn parseParamDecl(self: *Parser, out: *std.ArrayList(Ast.ParamDecl)) Error!void {
    const decl_tok = self.pos;
    const is_local = self.peek() == .kw_localparam;
    self.pos += 1;
    const signed = self.eat(.kw_signed);
    // §3.4.1: no type keyword is `.unspecified`, inferred from the default
    // by lowering.
    const is_time = self.peek() == .kw_time;
    const ty = varType(self.peek()) orelse .unspecified;
    if (ty != .unspecified) self.pos += 1;
    // A.2.1.1's first arm, `parameter [ signed ] [ range ] list_of_param_assignments`.
    // The range is a width, not a §3.4.4 array dimension, so it goes in
    // `packed_range` as a `reg`'s does. The arms are exclusive, so a range is
    // read only when no `parameter_type` was written. The bracket does not
    // set the type: §3.4.1 derives an unspecified type from the final value.
    //
    // ponytail: the width is carried, not enforced. `parameter [3:0] p =
    // 8'hff;` reads 255 here and 15 in a tool that truncates. Enforcing it is
    // a fold and a mask in lowering, where the default is already folded.
    const packed_range: ?Ast.Dim =
        if (ty == .unspecified and self.peek() == .lbracket) try parseDim(self) else null;
    // A declaration in an analog block or function is constant, not
    // analog_expression: A.8.4's `( constant_mintypmax_expression )` holds.
    const saved_expr = self.analog_expr;
    self.analog_expr = false;
    defer self.analog_expr = saved_expr;

    while (true) {
        const tok = self.pos;
        const name = try self.expectIdent();
        const dims = try parseDims(self);
        _ = try self.expect(.assign_eq);
        // A.2.4 `param_assignment ::= parameter_identifier =
        // constant_mintypmax_expression { value_range }`.
        const default = try parse_expr.parseMinTypMax(self);
        try self.copyAttributes(decl_tok, tok);

        var ranges: std.ArrayList(Ast.ValueRange) = .empty;
        while (self.peek() == .kw_from or self.peek() == .kw_exclude) {
            try ranges.append(self.arena, try parseRange(self));
        }
        try out.append(self.arena, .{
            .name = name,
            .ty = ty,
            .default = default,
            .is_local = is_local,
            .is_signed = signed,
            .is_time = is_time,
            .dims = dims,
            .packed_range = packed_range,
            .ranges = ranges.items,
            .main_tok = tok,
        });
        // A.1.3's `parameter_declaration { , parameter_declaration }` and
        // A.2.1.1's `list_of_param_assignments` share the comma, so a
        // `parameter` keyword after one ends this list. Only a
        // module_parameter_port_list reaches this; in a body it makes the
        // illegal `parameter real a = 1, parameter real b = 2;` E0207 at `;`.
        if (self.peek() != .comma) break;
        if (self.tags[self.pos + 1] == .kw_parameter or
            self.tags[self.pos + 1] == .kw_localparam) break;
        self.pos += 1;
    }
}

/// LRM §3.4.2 / A.2.5 value_range. The ranges are the only parameter bound
/// evidence `proof.zig` gets, so each must reach `ParamDecl.ranges`.
fn parseRange(self: *Parser) Error!Ast.ValueRange {
    const kind: Ast.ValueRange.Kind = if (self.peek() == .kw_from) .from else .exclude;
    self.pos += 1;

    // `from '{"a", "b"}`: a string-set range (§3.4.2).
    if (self.peek() == .apostrophe_lbrace) {
        self.pos += 1;
        var names: std.ArrayList(Ast.StrId) = .empty;
        if (self.peek() != .rbrace) while (true) {
            const tok = try self.expect(.string_literal);
            try names.append(self.arena, try parse_literal.internString(self, tok));
            if (!self.eat(.comma)) break;
        };
        _ = try self.expect(.rbrace);
        const off = try self.file.exprs.addStrList(self.arena, names.items);
        return .{ .kind = kind, .lo = .none, .strings = off };
    }

    // `exclude constant_expression`: A.2.5 gives the bare form to `exclude`
    // only. `from 5` is user input, so it is a diagnostic, not an assert.
    if (self.peek() != .lparen and self.peek() != .lbracket) {
        if (kind == .from) {
            var d = self.failWith(self.pos, .E0207);
            d.msg("found {s}", .{self.found(self.pos)});
            d.point("expected `(` or `[` — only `exclude` takes a bare value", .{});
            try d.emit();
            return error.ParseError;
        }
        return .{ .kind = kind, .lo = try parseValueRangeExpr(self) };
    }

    const lo_inclusive = self.peek() == .lbracket;
    self.pos += 1;
    const lo = try parseValueRangeExpr(self);
    // `exclude ( expr )`: a parenthesized single value, not a range.
    if (self.peek() != .colon) {
        _ = try self.expect(.rparen);
        return .{ .kind = kind, .lo = lo };
    }
    self.pos += 1;
    const hi = try parseValueRangeExpr(self);
    const hi_inclusive = switch (self.peek()) {
        .rbracket => true,
        .rparen => false,
        else => return self.failAt(self.pos, .E0210, "found {s}", .{self.found(self.pos)}), // else: a value_range closes with `]` or `)` and nothing else: E0210
    };
    self.pos += 1;
    return .{
        .kind = kind,
        .lo = lo,
        .hi = hi,
        .lo_inclusive = lo_inclusive,
        .hi_inclusive = hi_inclusive,
    };
}

/// A.2.5 value_range_expression ::= constant_expression | -inf | inf
fn parseValueRangeExpr(self: *Parser) Error!Ast.ExprId {
    const tok = self.pos;
    if (self.peek() == .minus and self.peekAt(1) == .kw_inf) {
        self.pos += 2;
        return self.file.exprs.add(self.arena, .{ .tag = .neg_inf, .main_tok = tok });
    }
    if (self.peek() == .kw_inf) {
        self.pos += 1;
        return self.file.exprs.add(self.arena, .{ .tag = .pos_inf, .main_tok = tok });
    }
    return parse_expr.parseExpr(self);
}

/// A.2.1.3 / A.2.7 variable type keyword -> `Ast.Type`, null for any other
/// token. `time` folds to integer and `realtime` to real (§3.4.1). An analog
/// function's return type is narrower (A.2.6), so `parseFuncDecl` has its own.
pub fn varType(tag: token.Tag) ?Ast.Type {
    return switch (tag) {
        .kw_integer, .kw_time => .integer,
        .kw_real, .kw_realtime => .real,
        .kw_string => .string,
        else => null, // else: not one of the five variable-type keywords
    };
}

/// Parses an A.2.1.3 `reg_declaration ::= reg [ discipline_identifier ]
/// [ signed ] [ range ] list_of_variable_identifiers ;`, cursor on `reg`,
/// through its `;`, appending one `VarDecl` per name to `out`. The analog
/// context reads any `reg` as Table 7-1's nonnegative integer ("The sign bit
/// (bit 31) of the integer is always set to zero"), so `signed` changes only
/// the digital kernel's arithmetic.
pub fn parseRegDecl(self: *Parser, out: *std.ArrayList(Ast.VarDecl)) Error!void {
    const tok = self.pos;
    self.pos += 1;
    const disc: Ast.StrId = if (regDisciplineAhead(self)) d: {
        const d = try self.internTok(self.pos);
        self.pos += 1;
        break :d d;
    } else .none;
    const signed = self.eat(.kw_signed);
    // §7.3.1's 31-bit limit is on an ACCESS ("Access of discrete bit
    // groupings with greater than 31 bits is illegal"), not on a declaration:
    // `lower_var.analogRead` judges each grouping the analog context reads,
    // so a 31-bit part-select of a wider `reg` stays legal.
    const range: ?Ast.Dim = try optDim(self);
    while (true) {
        const name_tok = self.pos;
        const name = try self.expectIdent();
        try self.copyAttributes(tok, name_tok);
        // A.2.1.3 reg_declaration ends in A.2.3's
        // list_of_variable_identifiers, whose A.2.2.1 `variable_type`
        // takes dimensions and an initializer:
        //
        //     variable_type ::=
        //         variable_identifier { dimension } [ = constant_assignment_pattern ]
        //         | variable_identifier = constant_expression
        //
        // `integer`/`time` reach the same production through
        // `parseVarDecl`, so neither is gated on `digital` here.
        const dims = try parseDims(self);
        const value = if (self.eat(.assign_eq)) try parse_expr.parseExpr(self) else Ast.ExprId.none;
        try out.append(self.arena, .{
            .name = name,
            .ty = .integer,
            .main_tok = name_tok,
            .storage = .reg,
            .packed_range = range,
            .is_signed = signed,
            .dims = dims,
            .init = value,
            .discipline = disc,
        });
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.semicolon);
}

/// Whether a `reg` declaration's optional discipline_identifier is at the
/// cursor: a name followed by another name, by `signed`, or by a `[ range ]`
/// that a name follows. A name followed by `[`, `;`, `,` or `=` otherwise is
/// the variable itself (`reg r[0:3];` declares an array).
fn regDisciplineAhead(self: *const Parser) bool {
    if (!self.identLike(self.pos)) return false;
    var i = self.pos + 1;
    if (self.tags[i] == .lbracket) {
        var depth: u32 = 0;
        while (self.tags[i] != .eof) : (i += 1) {
            switch (self.tags[i]) {
                .lbracket => depth += 1,
                .rbracket => {
                    depth -= 1;
                    if (depth == 0) break;
                },
                else => {}, // else: a token inside the range
            }
        }
        if (self.tags[i] == .eof) return false;
        i += 1;
    } else if (self.tags[i] == .kw_signed) return true;
    return self.identLike(i);
}

/// Parses an A.2.1.3 integer/real/string/time declaration (§3.2, §3.3), cursor
/// on the type keyword, up to but not including the `;`. Appends one `VarDecl`
/// per name to `out`. Asserts the cursor is on a variable type keyword.
pub fn parseVarDecl(self: *Parser, out: *std.ArrayList(Ast.VarDecl)) Error!void {
    const decl_tok = self.pos;
    const storage: @FieldType(Ast.VarDecl, "storage") = if (self.peek() == .kw_time) .time else .variable;
    const ty = varType(self.peek()).?;
    self.pos += 1;
    while (true) {
        const tok = self.pos;
        const name = try self.expectIdent();
        try self.copyAttributes(decl_tok, tok);
        const dims = try parseDims(self);
        var init_expr: Ast.ExprId = .none;
        if (self.eat(.assign_eq)) init_expr = try parse_expr.parseExpr(self);
        try out.append(self.arena, .{
            .name = name,
            .ty = ty,
            .dims = dims,
            .init = init_expr,
            .storage = storage,
            .main_tok = tok,
        });
        if (!self.eat(.comma)) break;
    }
}

/// The width of `[msb:lsb]` when both bounds are integer literals, else null.
///
/// ponytail: literals only. Folding `[W-1:0]` needs the constant evaluator,
/// which lives in lowering.
pub fn literalWidth(self: *const Parser, d: Ast.Dim) ?u64 {
    const ex = &self.file.exprs;
    if (ex.tag(d.msb) != .int_literal or ex.tag(d.lsb) != .int_literal) return null;
    // In i128 the difference of two 64-bit values cannot overflow; a width
    // past u64 (`[2**64-1 : -1]`) is no width a path can compare.
    return std.math.cast(u64, @abs(literalValue(self, d.msb) - literalValue(self, d.lsb)) + 1);
}

/// An `.int_literal`'s value as written. The store keeps an `i64`, so an
/// unsigned 64-bit literal with its top bit set (`64'h8000000000000000`)
/// reads back negative; reinterpreted here, it is the large positive number.
/// Asserts (by `intLiteral`) that `e` is an `.int_literal`.
pub fn literalValue(self: *const Parser, e: Ast.ExprId) i128 {
    const lit = self.file.exprs.intLiteral(e);
    if (!lit.signed and lit.value < 0) return @as(u64, @bitCast(lit.value));
    return lit.value;
}

/// §9.7.3 / AMS §5.10.4: dimensions belong to each event identifier.
pub fn parseEventDecl(self: *Parser) Error!Ast.EventDecl {
    const tok = self.pos;
    const name = try self.expectIdent();
    return .{ .name = name, .dims = try parseDims(self), .main_tok = tok };
}

/// Parses zero or more A.2.5 dimensions after a declared name: A.2.2.1
/// `variable_type ::= identifier { dimension }` and A.2.1.1's
/// `parameter_identifier { dimension }`, as in §3.2's
/// `real vtable[0:16][0:7][0:64];`. Lowering scalarizes them (`dimsBounds`).
pub fn parseDims(self: *Parser) Error![]const Ast.Dim {
    if (self.peek() != .lbracket) return &.{};
    var dims: std.ArrayList(Ast.Dim) = .empty;
    while (self.peek() == .lbracket)
        try dims.append(self.arena, try parseDim(self));
    return dims.items;
}

/// An optional `[ range ]`: null unless the next token is `[`.
pub fn optDim(self: *Parser) Error!?Ast.Dim {
    return if (self.peek() == .lbracket) try parseDim(self) else null;
}

/// A.2.5 `dimension ::= [ expr : expr ]` (§3.2.2, §3.4.4).
pub fn parseDim(self: *Parser) Error!Ast.Dim {
    _ = try self.expect(.lbracket);
    const msb = try parse_expr.parseExpr(self);
    _ = try self.expect(.colon);
    const lsb = try parse_expr.parseExpr(self);
    _ = try self.expect(.rbracket);
    return .{ .msb = msb, .lsb = lsb };
}
