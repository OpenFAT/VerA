//! Expressions: annex A.8.3 expression tokens -> `Ast.ExprId`s, by precedence
//! climbing (§4.1, §4.2.2), with A.8.4 primaries: names and §6.7
//! hierarchical names, A.8.2 calls, §4.4 branch probes and selects. A literal
//! is decoded by `literal.zig` and a brace form by `concat.zig`. Every
//! nesting level counts toward `Parser.deepest`; deep recursion continues on
//! a fresh stack segment (`Parser.segment`).
//!
//! LRM clauses cited: §2.7, §2.9, §3.2.2, §4.1, §4.2, §4.2.2, §4.2.10,
//! §4.2.12, §4.3, §4.4, §4.5, §4.6, §4.7, §5.6.8.2, §5.10.2, §6.7, §6.7.1.
//!
//! Contents:
//! - `pub fn parseExpr(self: *Parser) Error!Ast.ExprId`
//! - `pub fn parsePostfix(self: *Parser) Error!Ast.ExprId`
//! - `pub fn parseSelectAt(self: *Parser, base: Ast.ExprId, tok: u32) Error!Ast.ExprId`
//! - `pub fn parseMinTypMax(self: *Parser) Error!Ast.ExprId`
//! - `pub fn parsePrimary(self: *Parser) Error!Ast.ExprId`
//! - `pub fn joinName(self: *Parser, parts: []const Ast.StrId) Error!Ast.StrId`
//! - `pub fn parseNetRef(self: *Parser) Error!Ast.ExprId`
//! - `pub fn parseNetLvalue(self: *Parser) Error!Ast.ExprId`
//! - `pub fn parseCallArgs(self: *Parser) Error![]const Ast.ExprId`

const std = @import("std");
const assert = std.debug.assert;
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_stmt = @import("stmt.zig");
const parse_event = @import("event.zig");
const token = @import("../token.zig");
const Ast = @import("../ast.zig");
const parse_hier = @import("hier.zig");
const parse_concat = @import("concat.zig");
const parse_literal = @import("literal.zig");
const Error = parser.Error;

/// §4.2.12 `?:` sits below every binary operator (Table 4-3, last row).
const prec_ternary: u8 = 1;

/// Parses a full expression, conditional operator included (§4.1, §4.2).
pub fn parseExpr(self: *Parser) Error!Ast.ExprId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    return parseExprPrec(self, prec_ternary);
}

/// Parses a primary followed by any §3.2.2/§3.4.4 selects: `base[i]`,
/// `base[msb:lsb]`.
pub fn parsePostfix(self: *Parser) Error!Ast.ExprId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    var e = try parsePrimary(self);
    // Each select nests the tree one level, as an operator does.
    const base = self.depth;
    defer self.depth = base;
    while (self.peek() == .lbracket) {
        self.nest();
        e = try parseSelectAt(self, e, self.pos);
    }
    return e;
}

/// One select on `base`, `[i]`, `[msb:lsb]` or IEEE 1364-2005 §5.2.1's
/// `[base +: width]` / `[base -: width]`, the cursor on the `[`. The
/// `.index` node is reported at `tok`: the `[` itself, or a branch
/// terminal's name, as for a bit-select (`parseNetRef`).
pub fn parseSelectAt(self: *Parser, base: Ast.ExprId, tok: u32) Error!Ast.ExprId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    _ = try self.expect(.lbracket);
    var idx = try parseExpr(self);
    if (self.eat(.colon)) { // A.8.3 analog_range_expression
        const lsb = try parseExpr(self);
        idx = try self.file.exprs.add(self.arena, .{ .tag = .range, .main_tok = tok, .lhs = idx, .rhs = lsb });
    } else if (self.peek() == .plus or self.peek() == .minus) {
        const down = self.peek() == .minus;
        self.pos += 2; // `+:` or `-:`, which `parseExprPrec` stopped at
        const width = try parseExpr(self);
        idx = try self.file.exprs.add(self.arena, .{ .tag = .indexed_range, .main_tok = tok, .lhs = idx, .rhs = width, .extra = @intFromBool(down) });
    }
    _ = try self.expect(.rbracket);
    return self.file.exprs.add(self.arena, .{ .tag = .index, .main_tok = tok, .lhs = base, .rhs = idx });
}

/// Parses IEEE 1364-2005 §5.3 / A.8.3 `mintypmax_expression ::= expression
/// | expression : expression : expression`: in parentheses wherever a
/// non-analog expression is (A.8.4 `( mintypmax_expression )`), and bare
/// where A.2.2.3, A.2.4, A.4.1, A.7.4 and A.7.5.2 write one (a `delay3`
/// element, a parameter or specparam default, a defparam, a named parameter
/// override, a path delay, a timing check offset). The tool chooses one
/// member of each triple; VerA takes the typical, the middle, in every
/// context, so compound expressions all read their middle members
/// (`specification/Vague_Decisions.md` VD-099). The others are parsed and dropped.
///
/// ponytail: a dropped member is never elaborated, so a name it misspells
/// is not diagnosed. Keeping all three needs an AST node and a fold.
pub fn parseMinTypMax(self: *Parser) Error!Ast.ExprId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    const e = try parseExpr(self);
    if (!self.eat(.colon)) return e;
    const typ = try parseExpr(self);
    _ = try self.expect(.colon);
    _ = try parseExpr(self);
    return typ;
}

/// Parses an A.8.4 analog_primary: a literal, parenthesized expression,
/// concatenation, assignment pattern, name, call or branch probe. A token
/// that begins none of them is E0209.
pub fn parsePrimary(self: *Parser) Error!Ast.ExprId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    const tok = self.pos;
    // A call this primary makes is a task enable when it heads a discrete
    // statement (`Parser.task_enable_head`); nothing nested in it is.
    const task_enable = self.task_enable_head;
    self.task_enable_head = false;
    // §10.6: a keyword the active set does not reserve is just a name, so
    // `sin` under "1364-2005" reads as a variable, not as §4.3.2's builtin.
    // (`tokenText` still switches on the real tag, so the spelling is exact.)
    const t = if (self.identLike(tok)) token.Tag.identifier else self.peek();
    switch (t) {
        .int_literal, .real_literal => return parse_literal.parseNumber(self),
        .string_literal => { // §2.7
            const s = try parse_literal.internString(self, tok);
            self.pos += 1;
            return self.file.exprs.add(self.arena, .{ .tag = .str_literal, .main_tok = tok, .str = s });
        },
        .lparen => {
            self.pos += 1;
            if (!self.analog_expr) {
                const e = try parseMinTypMax(self);
                _ = try self.expect(.rparen);
                return e;
            }
            // A.8.4 `analog_primary ::= ... | ( analog_expression )`.
            const e = try parseExpr(self);
            if (self.peek() == .colon) return self.failAt(self.pos, .E0295, "", .{});
            _ = try self.expect(.rparen);
            return e;
        },
        // §4.2.13 / A.8.1 analog_concatenation, analog_multiple_concatenation
        .lbrace => return parse_concat.parseConcat(self, tok),
        // A.8.1 assignment_pattern `'{ ... }` (§3.4.4 array defaults,
        // §4.5.6 filter coefficient args)
        .apostrophe_lbrace => return parse_concat.parseAssignPattern(self, tok),
        .identifier, .escaped_identifier => {
            // References and declaration names must use the same escaped
            // period normalization; raw text aliases hierarchy separators.
            const name = try self.internTok(tok);
            self.pos += 1;
            // §2.9: an attribute_instance "can appear as a suffix to an
            // operator or a Verilog-AMS function name in an expression"
            // (Example 7: `add (* mode = "cla" *) (b, c)`), and A.8.2 gives
            // `analog_function_call` the slot. Only a call has it, so the skip
            // is rolled back when no `(` follows: the attribute is then a
            // prefix on whatever comes next.
            if (self.peek() == .attr_open) {
                const mark = self.markAttributes();
                try self.ownedAttributes(.{ .kind = .expression, .tok = tok });
                // This instance belongs to whatever follows and will be
                // collected there.
                if (self.peek() != .lparen) self.rewindAttributes(mark);
            }
            // A dotted name: a §6.8 hierarchical name, or a §5.5.3 Syntax 5-4
            // `nature_attribute_reference ::= net_identifier .
            // potential_or_flow . nature_attribute_identifier`. Both land in
            // `.hier_ident`; lowering tells them apart by resolving the parts.
            // IEEE 1364-2005 §12.5 an instance select, `g[0].l.x`: the part
            // is spelled `g[0]`, the name the digital engine registers.
            var unfolded: std.ArrayList(Ast.ExprId) = .empty;
            const head = if (parse_hier.instanceSelectAhead(self)) try parse_hier.parseInstanceSelect(self, name, &unfolded) else name;
            if (self.peek() == .dot) {
                var parts: std.ArrayList(Ast.StrId) = .empty;
                try parts.append(self.arena, head);
                while (self.eat(.dot)) {
                    // Syntax 5-4's middle and last parts are annex B keywords
                    // (`potential`/`flow` and the §3.6.1.2 attribute names),
                    // the same list `parseNatureAttr` admits.
                    const part = switch (self.peek()) {
                        .kw_potential,
                        .kw_flow,
                        .kw_abstol,
                        .kw_access,
                        .kw_units,
                        .kw_ddt_nature,
                        .kw_idt_nature,
                        => blk: {
                            const s = try self.internTok(self.pos);
                            self.pos += 1;
                            break :blk s;
                        },
                        else => try self.expectIdent(), // else: not a nature attribute keyword; `expectIdent` takes it or refuses it
                    };
                    try parts.append(self.arena, if (parse_hier.instanceSelectAhead(self)) try parse_hier.parseInstanceSelect(self, part, &unfolded) else part);
                }
                // Keyed by the main token, which the `.hier_ident` or `.call`
                // below carries.
                if (unfolded.items.len != 0)
                    try self.file.hier_indices.append(self.arena, .{ .tok = tok, .indices = unfolded.items });
                // §6.7.1: "Analog user defined functions can be accessed
                // hierarchically." A dotted name with an argument list becomes
                // `.call` under the joined name, which is the flat name
                // elaboration gives the child's function because
                // `Elaborate.sep` is the same `.`. This join and
                // `Lower.flatName` must change together.
                if (self.peek() == .lparen) return parseCall(self, .call, tok, try joinName(self, parts.items), task_enable);
                const off = try self.file.exprs.addStrList(self.arena, parts.items);
                return self.file.exprs.add(self.arena, .{ .tag = .hier_ident, .main_tok = tok, .extra = off });
            }
            if (self.peek() == .lparen) {
                // §4.4 branch probe vs §4.7 user function: only a declared
                // nature access name (§3.6.1.2) probes a branch.
                if (self.access_names.contains(self.file.str(name))) {
                    return parseAccess(self, name, tok);
                }
                return parseCall(self, .call, tok, name, task_enable);
            }
            return self.file.exprs.add(self.arena, .{ .tag = .ident, .main_tok = tok, .str = name });
        },
        // §4.4: "the generic potential and flow access functions are also
        // supported" (§5.5.1 Syntax 5-3). Parsed as `V(...)`/`I(...)` are;
        // lowering skips only the §3.6.1.2 name match. The words are annex B
        // keywords, so they arrive as their own tags and `real potential;`
        // cannot shadow them (§3.13.2).
        .kw_potential, .kw_flow => {
            const name = try self.file.intern(self.arena, token.Tag.lexeme(t).?);
            self.pos += 1;
            return parseAccess(self, name, tok);
        },
        // §2.8.3 / A.8.2 analog_system_function_call. `$name` with no
        // argument list is the same tag with an empty list.
        .system_identifier => {
            const name = try self.internTok(tok);
            self.pos += 1;
            // §6.2.1/§6.7 Syntax 6-9 `hierarchical_identifier ::= [ $root . ]
            // { identifier [ [ constant_expression ] ] . } identifier`. `$root`
            // anchors the path at the top of the instantiation tree; it rides
            // along as part 0 and `Lower.flatName`, which knows the root, strips it.
            if (self.eat(.dot)) {
                const h = try hierTerminal(self, &.{name}, tok);
                // A.9.3 `hierarchical_function_identifier`, `$root.top.f(x)`:
                // a call under the joined name, as for a dotted name above.
                if (self.peek() != .lparen) return h;
                return parseCall(self, .call, tok, try joinName(self, self.file.exprs.nameParts(h)), task_enable);
            }
            if (self.peek() == .lparen) return parseCall(self, .sys_call, tok, name, false);
            return addCall(self, .sys_call, tok, name, &.{});
        },
        // §6.4.3: "A paramset output variable's value may be computed from
        // values of any output parameters of the module by using the special
        // syntax .module_output_variable_identifier." A primary in a paramset
        // statement only, interned with its period: no other name holds one
        // (`internTok` interns an escaped identifier's period as a space), and
        // elaboration binds `.gm` to the instance's `gm`.
        .dot => if (self.in_paramset) {
            self.pos += 1;
            const name = try self.expectIdent();
            const dotted = try self.file.intern(self.arena, try self.arena.print(".{s}", .{self.file.str(name)}));
            return self.file.exprs.add(self.arena, .{ .tag = .ident, .main_tok = tok, .str = dotted });
        },
        // A.2.5 value_range_expression `inf` (only meaningful in §3.4.2).
        .kw_inf => {
            self.pos += 1;
            return self.file.exprs.add(self.arena, .{ .tag = .pos_inf, .main_tok = tok });
        },
        else => {}, // else: not one of the keyword primaries above; the identifier path follows
    }

    // Keyword-named calls. The groups are disjoint (token.zig's annex
    // A.8.2/A.6.5 test) and map one to one onto `ExprTag`.
    const call_tag: Ast.ExprTag = switch (token.callGroup(t)) {
        .math => .builtin_call, // §4.3
        .filter => .filter_call, // §4.5
        .small_signal => .noise_call, // §4.6
        .event => .event_function, // §5.10.3
        .none => if (t == .kw_analysis)
            .sys_call // §4.6.1 analysis_function_call
        else if (t == .kw_initial_step or t == .kw_final_step)
            return parse_event.parseEventTerm(self) // §5.10.2
        else
            return self.failAt(self.pos, .E0209, "found {s}", .{self.found(self.pos)}),
    };

    const name = try self.file.intern(self.arena, token.Tag.lexeme(t).?);
    self.pos += 1;
    // §2.9: an attribute_instance "can appear as a suffix to ... a
    // Verilog-AMS function name in an expression". A.8.2 draws that slot only
    // for `analog_function_call`; VerA extends it to these keyword-named
    // calls so `ddt (* vera_lte = 0 *) (q)` can name one charge site, and
    // `absdelay (* vera_interp = 2 *) (x, td)` one delay.
    const mark = self.attrs.items.len;
    if (self.peek() == .attr_open) try self.ownedAttributes(.{ .kind = .expression, .tok = tok });
    const lte = self.lteSince(mark);
    const id = try parseCall(self, call_tag, tok, name, false);
    try self.keepLte(lte, .none, id);
    return id;
}

/// The flat name `a.b.c` of a §6.7 hierarchical name's parts, interned: the
/// name elaboration gives the entity (`Elaborate.sep` is the same `.`), so
/// `Lower.flatName` and this join must change together. `parts` must be
/// nonempty (a name has at least one part).
pub fn joinName(self: *Parser, parts: []const Ast.StrId) Error!Ast.StrId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    var n = parts.len - 1;
    for (parts) |part| n += self.file.str(part).len;
    var joined: std.ArrayList(u8) = try .initCapacity(self.arena, n);
    for (parts, 0..) |part, i| {
        if (i != 0) joined.appendAssumeCapacity('.');
        joined.appendSliceAssumeCapacity(self.file.str(part));
    }
    return self.file.strings.intern(self.arena, joined.items);
}

/// Parses an A.8.9 / A.2.1.3 branch terminal: a net or branch name, optionally
/// with a §5.5.2 bit select (`V(in[1])`).
///
/// The index is any expression: §5.5.2's "constant" admits a genvar, which is
/// constant only part-way through elaboration, so lowering folds it (E0352).
/// A §6.7.1 hierarchical terminal (`V(drv.a)`, `V($root.global_supply.vdd)`)
/// becomes a `.hier_ident`, `$root` included as part 0, as in `parsePrimary`.
///
/// ponytail: no index inside a path (`u[0].a`); adding one needs a
/// resolution rule, and `hier_ident` is already the shape it would use.
pub fn parseNetRef(self: *Parser) Error!Ast.ExprId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    const tok = self.pos;
    const name = if (self.peek() == .system_identifier and self.tags[self.pos + 1] == .dot) blk: {
        const root = try self.internTok(self.pos);
        self.pos += 1;
        break :blk root;
    } else try self.expectIdent();
    // §6.7 + §5.5.2: in `V(u.v[1])` the select applies to the whole path.
    const base = if (self.eat(.dot))
        try hierTerminal(self, &.{name}, tok)
    else
        try self.file.exprs.add(self.arena, .{ .tag = .ident, .main_tok = tok, .str = name });
    if (self.peek() != .lbracket) return base;
    // A.2.1.3 `branch_terminal ::= net_identifier [ constant_range_expression ]`:
    // a bit, a part or an indexed part (`vecTerminal` judges which).
    return parseSelectAt(self, base, tok);
}

/// Parses an A.8.5 `net_lvalue ::= hierarchical_net_identifier [ ... ]
/// | { net_lvalue { , net_lvalue } }`, a primitive's output or inout
/// terminal (A.3.3, A.5.4). A one-element concatenation is its element, the
/// same bits (IEEE 1364-2005 §5.1.14); a wider one stays a `.concat` for the
/// executor to judge.
pub fn parseNetLvalue(self: *Parser) Error!Ast.ExprId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    if (self.peek() != .lbrace) return parseNetRef(self);
    const c = try parse_concat.parseConcat(self, self.pos);
    const ex = &self.file.exprs;
    if (ex.tag(c) == .concat and ex.args(c).len == 1) return ex.args(c)[0];
    return c;
}

/// Parses an A.8.2 / A.6.9 argument list, cursor on the `(`. An omitted
/// argument (`f(a, , c)`) becomes `.none`, so lowering can apply the
/// per-function defaults instead of guessing arity. The slice is arena-owned
/// and exactly as long as the list.
pub fn parseCallArgs(self: *Parser) Error![]const Ast.ExprId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    const mark = self.scratch_exprs.items.len;
    defer self.scratch_exprs.shrinkRetainingCapacity(mark);
    try pushCallArgs(self, null);
    return self.arena.dupe(Ast.ExprId, self.scratch_exprs.items[mark..]);
}

// ---- private ----

/// Precedence climbing over LRM Table 4-3 (§4.2.2).
fn parseExprPrec(self: *Parser, min_prec: u8) Error!Ast.ExprId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    var lhs = try parseUnary(self);
    // Each operator folded into `lhs` makes its tree one level deeper, and
    // every later walk recurses down that spine: it counts toward `deepest`.
    const base = self.depth;
    defer self.depth = base;
    while (true) {
        const t = self.peek();
        // §4.2.12 conditional: lowest precedence, right associative.
        if (t == .question and min_prec <= prec_ternary) {
            const tok = self.pos;
            self.nest();
            self.pos += 1;
            try self.ownedAttributes(.{ .kind = .expression, .tok = tok });
            // Both arms nest a native level `parseUnary` has already left, so
            // both count as frames (#29): `a ? b ? c ? ... : z : y` is as deep
            // as `a ? b : c ? ...`.
            const then_e = try self.descend(parseExprPrec, .{ self, prec_ternary });
            _ = try self.expect(.colon);
            const else_e = try self.descend(parseExprPrec, .{ self, prec_ternary });
            lhs = try self.file.exprs.add(self.arena, .{
                .tag = .ternary,
                .main_tok = tok,
                .lhs = lhs,
                .rhs = then_e,
                .extra = @backingInt(else_e),
            });
            continue;
        }
        // IEEE 1364-2005 A.8.3 `+:` / `-:` end an indexed part-select's base.
        if ((t == .plus or t == .minus) and self.peekAt(1) == .colon) return lhs;
        const op = binOp(t) orelse return lhs;
        const prec = binopPrec(op);
        if (prec < min_prec) return lhs;
        const tok = self.pos;
        // Annex C.5: "The case equality operators (===, !==) are not supported in Verilog-A."
        if (self.verilog_a and (op == .case_eq or op == .case_neq)) try self.refuseDigital(tok, self.tokenText(tok));
        self.nest();
        self.pos += 1;
        try self.ownedAttributes(.{ .kind = .expression, .tok = tok }); // A.8.3 binary suffix
        // §4.2.2: "All operators associate left to right with the exception
        // of the conditional operator". No `**` carve-out, so `2**3**2` is 64.
        const rhs = try parseExprPrec(self, prec + 1);
        lhs = try self.file.exprs.add(self.arena, .{
            .tag = .binary,
            .main_tok = tok,
            .lhs = lhs,
            .rhs = rhs,
            .extra = @backingInt(op),
        });
    }
}

/// A.8.6 unary_operator (§4.2.1, §4.2.7 to §4.2.10). Unary binds tighter than
/// every binary operator (Table 4-3, top row).
fn parseUnary(self: *Parser) Error!Ast.ExprId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    // Every expression recursion (parentheses, `?:`) passes here.
    if (self.segmentDue()) return self.segment(parseUnary, .{self});
    self.enter();
    defer self.leave();
    const tok = self.pos;
    const op: Ast.UnaryOp = switch (self.peek()) {
        .plus => .plus,
        .minus => .minus,
        .bang => .logical_not,
        .tilde => .bit_not,
        .amp => .reduce_and,
        .tilde_amp => .reduce_nand,
        .pipe => .reduce_or,
        .tilde_pipe => .reduce_nor,
        // §4.2.10 reduction xor. Parsed like its siblings; lowering refuses it
        // with E0320, which names the subset rule.
        .caret => .reduce_xor,
        .tilde_caret, .caret_tilde => .reduce_xnor,
        else => return parsePostfix(self), // else: not a unary operator, so a postfix/primary operand
    };
    self.pos += 1;
    try self.ownedAttributes(.{ .kind = .expression, .tok = tok }); // A.8.3 unary suffix
    // A.8.3 `unary_operator { attribute_instance } primary` (VAMS-2023
    // annex A: `analog_primary`): the operand is a primary, so `- -x`, `!!x`
    // and `~ &x` are syntax errors (E0209 at the second operator) and
    // `-(-x)` is the spelling. `a - -b` stays legal: binary, then unary.
    const operand = try parsePostfix(self);
    return self.file.exprs.add(self.arena, .{
        .tag = .unary,
        .main_tok = tok,
        .lhs = operand,
        .extra = @backingInt(op),
    });
}

inline fn addCall(self: *Parser, tag: Ast.ExprTag, tok: u32, name: Ast.StrId, args: []const Ast.ExprId) Error!Ast.ExprId {
    const off = try self.file.exprs.addExprList(self.arena, args);
    return self.file.exprs.add(self.arena, .{
        .tag = tag,
        .main_tok = tok,
        .extra = off,
        .str = name,
    });
}

/// §4.4.1 branch_probe_function_call / §4.4.2 port_probe_function_call
/// (A.8.2). `V(a)`, `V(a,b)`, `I(br)`, `I(<p>)`.
fn parseAccess(self: *Parser, name: Ast.StrId, tok: u32) Error!Ast.ExprId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    _ = try self.expect(.lparen);
    if (self.eat(.lt)) { // §5.4.3 port branch `I(<p>)`
        const port = try parseNetRef(self);
        _ = try self.expect(.gt);
        _ = try self.expect(.rparen);
        return self.file.exprs.add(self.arena, .{
            .tag = .port_access,
            .main_tok = tok,
            .lhs = port,
            .str = name,
        });
    }
    if (try parseHierBranchRef(self, name, tok)) |e| return e;
    const hi = try parseNetRef(self);
    var lo: Ast.ExprId = .none;
    if (self.eat(.comma)) lo = try parseNetRef(self);
    _ = try self.expect(.rparen);
    return self.file.exprs.add(self.arena, .{
        .tag = .branch_access,
        .main_tok = tok,
        .lhs = hi,
        .rhs = lo,
        .str = name,
    });
}

/// A.8.9 / Syntax 5-3 hierarchical_unnamed_branch_reference:
///
///   hierarchical_inst_identifier.branch ( branch_terminal [ , branch_terminal ] )
///
/// §5.6.8.2's spelling for a branch a child instance already owns,
/// `V(top.drv.branch(x,y)) <+ 1.2;`, as against §5.6.8.1's
/// `V(top.drv.x, top.drv.y)`, which creates a new branch in the writer.
/// Returns null, consuming nothing, when the lookahead is not that form.
///
/// The terminals are rewritten onto the instance path (`drv.x`, `drv.y`), so
/// everything downstream sees an ordinary terminal pair; the node is marked
/// `Ast.branch_ref_hier_unnamed` to keep the distinction.
///
/// ponytail: the rewrite makes the two spellings one branch. That is right for
/// a flow contribution (§5.6.1.2 sums them) and short of §5.6.8.2 for a
/// potential one, which should also discard what the child retained. The
/// upgrade is to attribute the contribution to the child's
/// `Ast.AnalogBlock.unit`, which `Lower.discardOpposite` already keys on.
/// The production's `( < port_identifier > )` alternatives are the child
/// port's §3.12.1 port branch, so they become the `I(<inst.p>)` port access
/// they name. A path may open with `$root` (A.9.3), and a terminal may carry
/// A.2.1.3's `[ constant_expression ]`, which selects on the whole path as in
/// `parseNetRef`.
fn parseHierBranchRef(self: *Parser, name: Ast.StrId, tok: u32) Error!?Ast.ExprId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    const rooted = self.peek() == .system_identifier and std.mem.eql(u8, self.tokenText(self.pos), "$root");
    // The lookahead counts the parts the loop below then reads.
    const n_parts = blk: {
        var i = self.pos;
        if (!rooted and !self.identLike(i)) return null;
        while (self.tags[i + 1] == .dot) : (i += 2) {
            if (self.tags[i + 2] == .kw_branch) {
                if (self.tags[i + 3] != .lparen) return null;
                break;
            }
            if (!self.identLike(i + 2)) return null;
        } else return null;
        break :blk (i - self.pos) / 2 + 1;
    };
    var parts: std.ArrayList(Ast.StrId) = try .initCapacity(self.arena, n_parts);
    if (rooted) {
        parts.appendAssumeCapacity(try self.internTok(self.pos));
        self.pos += 1;
        _ = try self.expect(.dot);
    }
    while (!self.eat(.kw_branch)) {
        parts.appendAssumeCapacity(try self.expectIdent());
        _ = try self.expect(.dot);
    }
    _ = try self.expect(.lparen);
    if (self.eat(.lt)) {
        const port = try hierBranchTerminal(self, parts.items, tok);
        _ = try self.expect(.gt);
        _ = try self.expect(.rparen);
        _ = try self.expect(.rparen);
        return try self.file.exprs.add(self.arena, .{ .tag = .port_access, .main_tok = tok, .lhs = port, .str = name });
    }
    const hi = try hierBranchTerminal(self, parts.items, tok);
    var lo: Ast.ExprId = .none;
    if (self.eat(.comma)) lo = try hierBranchTerminal(self, parts.items, tok);
    _ = try self.expect(.rparen);
    _ = try self.expect(.rparen);
    return try self.file.exprs.add(self.arena, .{
        .tag = .branch_access,
        .main_tok = tok,
        .lhs = hi,
        .rhs = lo,
        .str = name,
        // The rewrite above erases the spelling, and §5.6.8.1 vs §5.6.8.2 is
        // decided by it: mark the node (`Ast.branch_ref_hier_unnamed`).
        .extra = Ast.branch_ref_hier_unnamed,
    });
}

/// One `branch_terminal` of a hierarchical unnamed branch on the instance
/// path `prefix`, with its optional select (`parseHierBranchRef`).
fn hierBranchTerminal(self: *Parser, prefix: []const Ast.StrId, tok: u32) Error!Ast.ExprId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    const base = try hierTerminal(self, prefix, tok);
    if (self.peek() != .lbracket) return base;
    self.pos += 1;
    const idx = try parseExpr(self);
    _ = try self.expect(.rbracket);
    return self.file.exprs.add(self.arena, .{ .tag = .index, .main_tok = tok, .lhs = base, .rhs = idx });
}

/// `prefix . id { . id }` as one `.hier_ident`, the cursor on the first `id`:
/// a `branch_terminal` of the production above, or any dotted name whose head
/// is already read.
fn hierTerminal(self: *Parser, prefix: []const Ast.StrId, tok: u32) Error!Ast.ExprId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    var parts: std.ArrayList(Ast.StrId) = .empty;
    try parts.appendSlice(self.arena, prefix);
    try parts.append(self.arena, try self.expectIdent());
    while (self.eat(.dot)) try parts.append(self.arena, try self.expectIdent());
    const off = try self.file.exprs.addStrList(self.arena, parts.items);
    return self.file.exprs.add(self.arena, .{ .tag = .hier_ident, .main_tok = tok, .extra = off });
}

/// `parseCallArgs` onto `scratch_exprs` above its current length, for a
/// caller that copies the arguments into the expression pool and truncates.
///
/// `user` names a user function call (A.8.2 `analog_function_call`,
/// `function_call`: `( expression { , expression } )`), which takes no empty
/// slot and, in an analog expression, no empty list (E0289). The system,
/// operator and event forms keep their omitted slots as `.none` for the
/// clause that gives each one a meaning or a refusal. A task enable passes
/// no `user` (`parseCall`): IEEE 1364-2005 §10.2.2 forbids its null argument
/// by its own sentence, and the digital engine refuses it there (E1100). The
/// discrete grammar keeps a function's `f()` for the same engine, which
/// refuses it by arity (E1100).
fn pushCallArgs(self: *Parser, user: ?Ast.StrId) Error!void {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    const mark = self.scratch_exprs.items.len;
    _ = try self.expect(.lparen);
    if (self.peek() == .rparen) {
        if (user) |name| if (!self.discreteGrammar())
            return self.failAt(self.pos, .E0289, "`{s}()` passes no argument", .{self.file.str(name)});
    } else while (true) {
        const empty = self.peek() == .comma or self.peek() == .rparen;
        if (empty) if (user) |name|
            return self.failAt(self.pos, .E0289, "argument {d} of `{s}` is empty", .{ self.scratch_exprs.items.len - mark + 1, self.file.str(name) });
        const arg: Ast.ExprId = if (empty) .none else try parseExpr(self);
        try self.scratch_exprs.append(self.arena, arg);
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.rparen);
}

/// Parses an argument list at the cursor and adds the call node of `tag`
/// over it. The arguments go from the scratch stack straight into the
/// expression pool, with no list of their own. `task_enable`: the `.call`
/// is A.6.9's task_enable, whose arguments §10.2.2 judges, not A.8.2.
fn parseCall(self: *Parser, tag: Ast.ExprTag, tok: u32, name: Ast.StrId, task_enable: bool) Error!Ast.ExprId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    const mark = self.scratch_exprs.items.len;
    defer self.scratch_exprs.shrinkRetainingCapacity(mark);
    try pushCallArgs(self, if (tag == .call and !task_enable) name else null);
    return addCall(self, tag, tok, name, self.scratch_exprs.items[mark..]);
}

/// Operator precedence. LRM §4.2.2 Table 4-3, highest binds tightest.
fn binopPrec(op: Ast.BinaryOp) u8 {
    return switch (op) {
        .pow => 12,
        .mul, .div, .mod => 11,
        .add, .sub => 10,
        .shl, .shr, .ashl, .ashr => 9,
        .lt, .le, .gt, .ge => 8,
        .eq, .neq, .case_eq, .case_neq => 7,
        .bit_and => 6,
        .bit_xor, .bit_xnor => 5,
        .bit_or => 4,
        .logical_and => 3,
        .logical_or => 2,
    };
}

/// A.8.6 binary_operator → `Ast.BinaryOp`, null for a token that is not one.
/// `===`/`!==`/`<<<`/`>>>` are mapped, not rejected: lowering judges them in
/// Verilog-AMS, and `--sim=verilogA` refuses the first two (annex C.5, E0250).
fn binOp(tag: token.Tag) ?Ast.BinaryOp {
    return switch (tag) {
        .plus => .add,
        .minus => .sub,
        .star => .mul,
        .slash => .div,
        .percent => .mod,
        .star_star => .pow,
        .eq_eq => .eq,
        .bang_eq => .neq,
        .eq_eq_eq => .case_eq,
        .bang_eq_eq => .case_neq,
        .lt => .lt,
        .lt_eq => .le,
        .gt => .gt,
        .gt_eq => .ge,
        .amp_amp => .logical_and,
        .pipe_pipe => .logical_or,
        .amp => .bit_and,
        .pipe => .bit_or,
        .caret => .bit_xor,
        .caret_tilde, .tilde_caret => .bit_xnor,
        .lt_lt => .shl,
        .gt_gt => .shr,
        .lt_lt_lt => .ashl,
        .gt_gt_gt => .ashr,
        else => null, // else: not a binary operator token
    };
}
