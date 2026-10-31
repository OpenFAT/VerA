//! Annex A.6.4 analog_statement (LRM Clause 5): statement tokens inside an
//! analog block, function or discrete process in, `Ast.StmtId`s out.
//! Digital-only statements (IEEE 1364-2005 Clause 9) parse only in the
//! discrete grammar.
//!
//! LRM clauses cited: §2.6.2, §4.7.1, §4.7.2.2, §5.6, §5.7, §5.8, §5.8.3, §5.9, §5.9.1,
//! §5.9.2, §5.10, §5.10.4, §5.11.
//!
//! Contents:
//! - `pub fn parseStmtNoNull(self: *Parser) Error!Ast.StmtId`
//! - `pub fn parseStmt(self: *Parser) Error!Ast.StmtId`
//! - `pub fn parseCase(self: *Parser, kind: Ast.CaseKind, gen: ?*parse_module.Body) Error!Ast.StmtId`
//! - `pub fn parseAssignNoSemi(self: *Parser) Error!Ast.StmtId`

const std = @import("std");
const assert = std.debug.assert;
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_decl = @import("decl.zig");
const parse_net = @import("net.zig");
const parse_expr = @import("expr.zig");
const parse_literal = @import("literal.zig");
const parse_generate = @import("generate.zig");
const parse_module = @import("module.zig");
const parse_timing = @import("timing_check.zig");
const parse_event = @import("event.zig");
const parse_hier = @import("hier.zig");
const Ast = @import("../ast.zig");
const Error = parser.Error;

/// Parses one statement where A.6.4 admits no null statement, reporting a
/// bare `;` as E0219 in an analog source and then parsing on (the `;` is
/// consumed and `.empty` returned), so later mistakes are still reported.
///
/// A bare `;` derives only through `analog_statement_or_null`, reached from
/// a conditional arm, a case item and an event statement (annex G.2.2);
/// those sites call `parseStmt`. `analog_seq_block` (A.6.3) and
/// `analog_construct` (A.6.2) take `analog_statement`, so they call this.
pub fn parseStmtNoNull(self: *Parser) Error!Ast.StmtId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    if (!self.digital and self.peek() == .semicolon)
        try self.report(self.pos, .E0219, "", .{});
    return parseStmt(self);
}

/// Parses one statement (A.6.4), null statement included. Outside the
/// discrete grammar (`discreteGrammar`), `#`, `wait`, `forever`, `fork` and
/// the procedural continuous assignments are digital statements A.6.4's
/// `analog_statement` does not derive: each is parsed in full and refused by
/// its own clause (E0258, E0249, E0254, E0255, E0256), so the parse goes on.
/// A task enable falls through to the expression statement. `casex`/`casez`
/// parse everywhere: §7.3.2 makes them analog statements in Verilog-AMS.
pub fn parseStmt(self: *Parser) Error!Ast.StmtId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    if (self.segmentDue()) return self.segment(parseStmt, .{self});
    self.enter();
    defer self.leave();
    const mark = self.attrs.items.len;
    try self.skipAttributes();
    self.statementAttributes(self.pos);
    // A.6.4 `{ attribute_instance } <statement>`: a statement keeps VerA's
    // own attributes (`Ast.SourceFile.lte_attrs`). Read before the body,
    // whose nested statements append their attributes after.
    const lte = self.lteSince(mark);
    const id = try parseStmtBody(self);
    try self.keepLte(lte, id, .none);
    return id;
}

/// Parses a §5.8.3 / A.6.7 case statement of `kind`, or, when `gen` is
/// non-null, a Syntax 6-8 `case_generate_construct ::= case
/// ( constant_expression ) case_generate_item { case_generate_item }
/// endcase` whose arm bodies are generate blocks appended to `gen`. The two
/// productions differ only in what an arm body is.
pub fn parseCase(self: *Parser, kind: Ast.CaseKind, gen: ?*parse_module.Body) Error!Ast.StmtId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    const tok = self.pos;
    self.pos += 1; // 'case' / 'casex' / 'casez'
    _ = try self.expect(.lparen);
    const scrutinee = try parse_expr.parseExpr(self);
    _ = try self.expect(.rparen);

    var arms: std.ArrayList(Ast.CaseArm) = .empty;
    var arm_at: u32 = undefined;
    while (self.peek() != .kw_endcase and self.peek() != .eof) : (std.debug.assert(self.pos > arm_at)) {
        arm_at = self.pos;
        // A.6.7 gives a case item no attribute prefix (its statement_or_null
        // carries one); an instance before an item is still read and dropped,
        // but one that runs into `endcase` prefixes nothing: §2.9, E0207 (#69).
        const past = self.pastAttributes();
        if (past != arm_at and (self.tags[past] == .kw_endcase or self.tags[past] == .eof)) {
            try self.skipAttributes();
            try self.attributesEnd(arm_at);
            break;
        }
        try self.skipAttributes();
        const mark = self.scratch_exprs.items.len;
        defer self.scratch_exprs.shrinkRetainingCapacity(mark);
        if (self.eat(.kw_default)) {
            _ = self.eat(.colon); // A.6.7: `default [ : ]`
        } else {
            while (true) {
                const label = try parse_expr.parseExpr(self);
                try self.scratch_exprs.append(self.arena, label);
                if (!self.eat(.comma)) break;
            }
            _ = try self.expect(.colon);
        }
        const labels = try self.arena.dupe(Ast.ExprId, self.scratch_exprs.items[mark..]);
        const body = if (gen) |b| try parse_generate.parseGenerateBlock(self, b) else try parseStmt(self);
        try arms.append(self.arena, .{ .labels = labels, .body = body });
    }
    _ = try self.expect(.kw_endcase);
    return self.file.addStmt(
        self.arena,
        .{ .case_stmt = .{
            .kind = kind,
            .scrutinee = scrutinee,
            .arms = arms.items,
            .is_generate = gen != null,
        } },
        tok,
    );
}

/// Parses an A.6.8 `for` header assignment: an analog_variable_assignment
/// with no terminating `;`.
pub fn parseAssignNoSemi(self: *Parser) Error!Ast.StmtId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    const tok = self.pos;
    const target = try parse_expr.parseExpr(self);
    _ = try self.expect(.assign_eq);
    const value = try parse_expr.parseExpr(self);
    return self.file.addStmt(self.arena, .{ .assign = .{ .target = target, .value = value } }, tok);
}

// ---- private ----

fn parseStmtBody(self: *Parser) Error!Ast.StmtId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    const tok = self.pos;
    const event_block = self.analog_event_block;
    self.analog_event_block = false;
    defer self.analog_event_block = event_block;
    if (self.eat(.hash)) {
        if (!self.discreteGrammar()) try self.report(tok, .E0254, "", .{});
        const delay = try parse_event.parseDelay(self);
        const body = try parseStmt(self);
        return self.file.addStmt(self.arena, .{ .event_control = .{ .event = delay, .body = body, .kind = .delay } }, tok);
    }
    // A.6.5 `wait_statement ::= wait ( expression ) statement_or_null`:
    // digital only, like `#`; A.6.4 has no analog alternative for it.
    if (self.peek() == .kw_wait) {
        if (!self.discreteGrammar()) try self.report(tok, .E0255, "", .{});
        self.pos += 1;
        _ = try self.expect(.lparen);
        const cond = try parse_expr.parseExpr(self);
        _ = try self.expect(.rparen);
        const body = try parseStmt(self);
        return self.file.addStmt(self.arena, .{ .event_control = .{ .event = cond, .body = body, .kind = .level } }, tok);
    }
    // A.6.2 `procedural_continuous_assignments` (IEEE 1364-2005 §9.3),
    // digital statements only: `assign`/`force lvalue = expr;`,
    // `deassign`/`release lvalue;`. §8.5.3.2 gives each its process.
    {
        const kind: ?Ast.ProcContinuous = if (self.peek() == .kw_assign) .assign else if (self.reservedIs(self.pos, "force")) .force else if (self.reservedIs(self.pos, "deassign")) .deassign else if (self.reservedIs(self.pos, "release")) .release else null;
        if (kind) |k| {
            if (!self.discreteGrammar()) try self.report(tok, .E0258, "`{s}`", .{@tagName(k)});
            self.pos += 1;
            const target = try parse_expr.parsePostfix(self);
            var value: Ast.ExprId = .none;
            if (k == .assign or k == .force) {
                _ = try self.expect(.assign_eq);
                value = try parse_expr.parseExpr(self);
            }
            _ = try self.expect(.semicolon);
            return self.file.addStmt(self.arena, .{ .assign = .{ .target = target, .value = value, .continuous = k } }, tok);
        }
    }
    // A.6.8 `loop_statement ::= forever statement` (IEEE 1364-2005 §9.6:
    // "Continuously executes a statement"), digital only. A.6.8's
    // `analog_loop_statement` has no forever (annex G.2.1 retired it), so
    // outside the discrete context it is parsed and refused (E0256). The body is `statement`, not
    // `statement_or_null`, so `forever ;` is E0296 (a null body would also
    // never suspend).
    //
    // Recorded as `while (1) body`: §9.6 gives the two the same meaning, so
    // no walk over `Ast.Stmt` needs a separate arm. The `1` is an
    // unsized decimal (§2.6.1: signed, 32-bit) anchored on `forever`.
    if (self.peek() == .kw_forever) {
        if (!self.discreteGrammar()) try self.report(tok, .E0256, "", .{});
        self.pos += 1;
        const always = try self.file.exprs.addIntLiteral(self.arena, tok, .{ .value = 1, .width = 0, .signed = true });
        if (self.peek() == .semicolon) return self.failAt(self.pos, .E0296, "", .{});
        const body = try parseStmt(self);
        return self.file.addStmt(self.arena, .{ .while_stmt = .{ .cond = always, .body = body } }, tok);
    }
    // A.6.3 `par_block`, IEEE 1364-2005 §9.8.2, digital only. A.6.4's
    // `analog_statement` has `analog_seq_block` and no par_block (E0249).
    if (self.reservedIs(self.pos, "fork")) {
        if (!self.discreteGrammar()) try self.report(tok, .E0249, "", .{});
        return parseSeqBlock(self);
    }
    switch (self.peek()) {
        .semicolon => {
            self.pos += 1;
            return self.file.addStmt(self.arena, .empty, tok);
        },
        .kw_begin => {
            self.analog_event_block = event_block; // A.6.3 analog_event_seq_block
            return parseSeqBlock(self);
        },
        .kw_if => return parse_generate.parseIf(self, null, tok), // §5.8 / A.6.6
        // §5.8.3 / A.6.7. `casex`/`casez` share the production; §7.3.2
        // lists all three among the analog context's four-state features.
        .kw_case => return parseCase(self, .normal, null),
        .kw_casex, .kw_casez => {
            // Annex C.7: "casex and casez are not supported in Verilog-A".
            if (self.verilog_a) try self.refuseDigital(self.pos, self.tokenText(self.pos));
            return parseCase(self, if (self.peek() == .kw_casex) .casex else .casez, null);
        },
        .kw_for => return parse_generate.parseFor(self, null, tok), // §5.9.2 / A.6.8
        .kw_while => { // §5.9.1
            self.pos += 1;
            _ = try self.expect(.lparen);
            const cond = try parse_expr.parseExpr(self);
            _ = try self.expect(.rparen);
            const body = try parseStmt(self);
            return self.file.addStmt(self.arena, .{ .while_stmt = .{ .cond = cond, .body = body } }, tok);
        },
        .kw_repeat => { // §5.9
            self.pos += 1;
            _ = try self.expect(.lparen);
            const count = try parse_expr.parseExpr(self);
            _ = try self.expect(.rparen);
            const body = try parseStmt(self);
            return self.file.addStmt(self.arena, .{ .repeat_stmt = .{ .count = count, .body = body } }, tok);
        },
        .at => return parse_event.parseEventControl(self), // §5.10 / A.6.5
        // A.6.5 `event_trigger ::= -> hierarchical_event_identifier
        // { [ expression ] } ;` (§5.10.4). The executor checks that the
        // expression names one event rather than a value or whole array.
        .arrow => {
            self.pos += 1;
            const target = try parse_expr.parseExpr(self);
            _ = try self.expect(.semicolon);
            return self.file.addStmt(self.arena, .{ .event_trigger = .{ .target = target } }, tok);
        },
        .kw_disable => { // §5.11
            self.pos += 1;
            // A.6.5 `disable hierarchical_block_identifier` (A.9.3), one
            // flat name, `$root.` included.
            const name = try parse_hier.parseDottedPath(self, false, null);
            _ = try self.expect(.semicolon);
            return self.file.addStmt(self.arena, .{ .disable = .{ .name = name } }, tok);
        },
        .kw_return => { // A.6.5 jump_statement (§4.7.1)
            self.pos += 1;
            // §4.7.2.2: "When the return statement is used, the function
            // shall specify an expression with the return of the correct
            // type for the function." A bare `return;` specifies none, and
            // is not a spelling of §4.7.2.1's default. Outside a function,
            // lowering reports `return` (E0403).
            const value: Ast.ExprId = if (self.peek() == .semicolon) v: {
                if (self.in_analog_fn) {
                    var d = self.failWith(tok, .E0227);
                    d.help("write `return <expr>;`", .{});
                    try d.emit();
                }
                break :v .none;
            } else try parse_expr.parseExpr(self);
            _ = try self.expect(.semicolon);
            return self.file.addStmt(self.arena, .{ .jump = .{ .kind = .ret, .value = value } }, tok);
        },
        .kw_break, .kw_continue => {
            const kind: Ast.Stmt.JumpKind = if (self.peek() == .kw_break) .brk else .cont;
            self.pos += 1;
            _ = try self.expect(.semicolon);
            return self.file.addStmt(self.arena, .{ .jump = .{ .kind = kind } }, tok);
        },
        // A.6.9 analog_system_task_enable (§5.12, ch9). `$root.` opens an
        // A.9.3 hierarchical name instead: an lvalue or a task enable.
        .system_identifier => return if (self.peekAt(1) == .dot and std.mem.eql(u8, self.tokenText(self.pos), "$root"))
            parseExprOrContributeStmt(self)
        else
            parseSysTask(self),
        else => return parseExprOrContributeStmt(self), // else: not a statement keyword, so an expression or contribution statement
    }
}

/// Parses a §5.3.2 / A.6.3 analog_seq_block, or a digital `fork … join`.
/// Local declarations are only legal on a named block (E0290).
fn parseSeqBlock(self: *Parser) Error!Ast.StmtId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    const tok = self.pos;
    const event_block = self.analog_event_block;
    self.analog_event_block = false;
    defer self.analog_event_block = event_block;
    const parallel = self.peek() != .kw_begin; // `fork`
    self.pos += 1; // 'begin' / 'fork'
    var blk: Ast.SeqBlock = .{ .parallel = parallel };
    if (self.eat(.colon)) {
        const at = self.pos;
        blk.name = try self.expectIdent();
        // §4.7.1: an analog function "shall not use named blocks".
        // Non-fatal, so the rest of the body is still parsed.
        if (self.in_analog_fn) {
            var d = self.failWith(at, .E0226);
            d.msg("`{s}`", .{self.file.str(blk.name)});
            d.help("remove the label", .{});
            try d.emit();
        }
    }

    var params: std.ArrayList(Ast.ParamDecl) = .empty;
    var vars: std.ArrayList(Ast.VarDecl) = .empty;
    var events: std.ArrayList(Ast.EventDecl) = .empty;
    // Only a declaration loops, and every one consumes its keyword.
    var decl_at: u32 = undefined;
    while (true) : (std.debug.assert(self.pos > decl_at)) {
        decl_at = self.pos;
        const mark = self.markAttributes();
        try self.skipAttributes();
        // A keyword the §10.6 set frees (`string` under "1364-2005") that no
        // name follows is no declaration: it starts a statement.
        if (self.identLike(self.pos) and !self.identLike(self.pos + 1)) {
            self.rewindAttributes(mark);
            break;
        }
        // A.6.3 `analog_seq_block ::= begin [ : analog_block_identifier
        // { analog_block_item_declaration } ] ...`, and IEEE 1364-2005's
        // `seq_block`/`par_block` alike: an unnamed block declares nothing.
        // The digital parse stops here, since its `reg` and `event` arms
        // below read a named block's only; elsewhere the declaration is
        // reported and read on, so the statements after it still parse.
        if (blk.name == .none) switch (self.peek()) {
            .kw_parameter, .kw_localparam, .kw_integer, .kw_real, .kw_string, .kw_realtime, .kw_time => if (self.digital)
                return self.failAt(self.pos, .E0290, "found {s}", .{self.found(self.pos)})
            else
                try self.report(self.pos, .E0290, "found {s}", .{self.found(self.pos)}),
            .kw_reg, .kw_event => if (self.digital) return self.failAt(self.pos, .E0290, "found {s}", .{self.found(self.pos)}),
            else => {}, // else: not a declaration
        };
        switch (self.peek()) {
            .kw_parameter, .kw_localparam => {
                try parse_decl.parseParamDecl(self, &params);
                _ = try self.expect(.semicolon);
            },
            .kw_integer, .kw_real, .kw_string, .kw_realtime, .kw_time => {
                try parse_decl.parseVarDecl(self, &vars);
                _ = try self.expect(.semicolon);
            },
            // IEEE 1364-2005 A.2.8 `block_item_declaration`'s digital arms,
            // which A.6.3 gives a named block only.
            .kw_reg => if (self.digital and blk.name != .none) try parse_decl.parseRegDecl(self, &vars) else {
                self.rewindAttributes(mark);
                break;
            },
            .kw_event => if (self.digital and blk.name != .none) {
                const decl_tok = self.pos;
                self.pos += 1;
                while (true) {
                    const event = try parse_decl.parseEventDecl(self);
                    try self.copyAttributes(decl_tok, event.main_tok);
                    try events.append(self.arena, event);
                    if (!self.eat(.comma)) break;
                }
                _ = try self.expect(.semicolon);
            } else {
                self.rewindAttributes(mark);
                break;
            },
            else => { // else: not a declaration: the block's statements start here
                // The attributes just read prefix the first statement
                // (A.6.4), so they are handed back for `parseStmt`.
                self.rewindAttributes(mark);
                break;
            },
        }
    }

    const mark = self.scratch_stmts.items.len;
    defer self.scratch_stmts.shrinkRetainingCapacity(mark);
    var before: u32 = undefined;
    // A statement, or `recoverStatement`'s one token at least.
    while (!blockCloser(self, parallel, self.pos)) : (std.debug.assert(self.pos > before)) {
        before = self.pos;
        // §2.9: an attribute instance is "a prefix attached to" a statement;
        // one followed by the closer prefixes nothing (#66).
        const past = self.pastAttributes();
        if (past != before and blockCloser(self, parallel, past)) {
            try self.skipAttributes();
            try self.attributesEnd(before);
            break;
        }
        // A.6.3 `analog_seq_block ::= begin [ : id ... ] { analog_statement }`
        // has no null alternative, so a stray `;` here is E0219. An
        // `analog_event_seq_block`'s `analog_event_statement` has one (A.6.4).
        self.analog_event_block = event_block;
        const s = (if (event_block) parseStmt(self) else parseStmtNoNull(self)) catch |e| {
            if (e == error.OutOfMemory) return e;
            self.recoverStatement(before);
            continue;
        };
        try self.scratch_stmts.append(self.arena, s);
    }
    if (parallel) {
        if (!self.reservedIs(self.pos, "join")) return self.failAt(self.pos, .E0207, "found {s}: no `join` closes the fork", .{self.found(self.pos)});
        self.pos += 1;
    } else _ = try self.expect(.kw_end);

    blk.params = params.items;
    blk.vars = vars.items;
    blk.events = events.items;
    blk.body = try self.arena.dupe(Ast.StmtId, self.scratch_stmts.items[mark..]);
    return self.file.addStmt(self.arena, .{ .block = blk }, tok);
}

/// Whether token `i` closes a `parseSeqBlock` body: `join` for a `fork`,
/// `end` otherwise, or end of file.
fn blockCloser(self: *const Parser, parallel: bool, i: u32) bool {
    return self.tags[i] == .eof or (if (parallel) self.reservedIs(i, "join") else self.tags[i] == .kw_end);
}

/// Parses an A.6.9 `$task [ ( [expr] {, [expr]} ) ] ;` (Clause 9). The name
/// keeps its `$` so lowering reports it as written.
fn parseSysTask(self: *Parser) Error!Ast.StmtId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    const tok = self.pos;
    // IEEE 1364-2005 §15.1: "no timing check can appear in procedural code".
    if (parse_timing.timing_checks.has(self.tokenText(tok)))
        return self.failAt(tok, .E0207, "`{s}` is a timing check, which only a specify block holds (§15.1)", .{self.tokenText(tok)});
    const name = try self.internTok(tok);
    self.pos += 1;
    var args: []const Ast.ExprId = &.{};
    if (self.peek() == .lparen) args = try parse_expr.parseCallArgs(self);
    _ = try self.expect(.semicolon);
    return self.file.addStmt(self.arena, .{ .sys_task = .{ .name = name, .args = args } }, tok);
}

/// Parses a contribution (§5.6), an indirect contribution (§5.6.7) or a
/// procedural assignment (§5.7). One expression is parsed first (`<+`, `=`
/// and `:` bind looser than every Table 4-3 operator), then the operator
/// decides. In the discrete grammar also a nonblocking assignment or a task
/// enable. Anything else after the expression is E0214.
fn parseExprOrContributeStmt(self: *Parser) Error!Ast.StmtId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    const tok = self.pos;
    // A.6.9: a call heading a discrete statement is a task enable.
    self.task_enable_head = self.discreteGrammar();
    const lhs = if (self.discreteGrammar()) try parse_expr.parsePostfix(self) else try parse_expr.parseExpr(self);
    // A.8.5: every lvalue (variable_lvalue, net_lvalue,
    // analog_variable_lvalue) opens with a name or `{`, so a literal before
    // `=` or `<=` is no assignment (`#d 20 = 1'bx;`). Other targets are
    // judged by lowering, which knows what a name declares.
    if ((self.peek() == .assign_eq or (self.discreteGrammar() and self.peek() == .lt_eq)) and isLiteral(self.file.exprs.tag(lhs)))
        return self.failAt(tok, .E0207, "found {s}: an A.8.5 assignment target is a variable, never a literal", .{self.found(tok)});
    if (self.discreteGrammar() and self.eat(.lt_eq)) {
        const timing = try parse_event.parseIntraTiming(self);
        const value = try parse_expr.parseExpr(self);
        _ = try self.expect(.semicolon);
        return self.file.addStmt(self.arena, .{ .assign = .{
            .target = lhs,
            .value = value,
            .nonblocking = true,
            .timing = timing.expr,
            .timing_is_delay = timing.is_delay,
            .timing_repeat = timing.count,
            .timing_implicit = timing.implicit,
        } }, tok);
    }
    // A.6.4 `task_enable ::= hierarchical_task_identifier [ ( expression
    // { , expression } ) ] ;` (IEEE 1364-2005 §10.2.2). Recorded as a
    // `sys_task` row whose name has no `$`: a digital statement only, where
    // the engine tells the two apart by that first character.
    if (self.discreteGrammar() and self.peek() == .semicolon) {
        const ex = &self.file.exprs;
        if (ex.tag(lhs) == .ident or ex.tag(lhs) == .call or ex.tag(lhs) == .hier_ident) {
            self.pos += 1;
            // A copy: `ex.args` points into the expression pool, which the
            // rest of the file grows and moves.
            const args: []const Ast.ExprId = if (ex.tag(lhs) == .call) try self.arena.dupe(Ast.ExprId, ex.args(lhs)) else &.{};
            // A.9.3 `hierarchical_task_identifier`, `c.t;`: the flat name.
            const name = if (ex.tag(lhs) == .hier_ident) try parse_expr.joinName(self, ex.nameParts(lhs)) else ex.strOf(lhs);
            return self.file.addStmt(self.arena, .{ .sys_task = .{ .name = name, .args = args } }, tok);
        }
    }
    switch (self.peek()) {
        .contribute => { // §5.6 / A.6.10
            self.pos += 1;
            const rhs = try parse_expr.parseExpr(self);
            _ = try self.expect(.semicolon);
            return self.file.addStmt(self.arena, .{ .contribute = .{ .lhs = lhs, .rhs = rhs } }, tok);
        },
        .assign_eq => { // §5.7 / A.6.2
            self.pos += 1;
            const timing = try parse_event.parseIntraTiming(self);
            const value = try parse_expr.parseExpr(self);
            _ = try self.expect(.semicolon);
            return self.file.addStmt(self.arena, .{ .assign = .{
                .target = lhs,
                .value = value,
                .timing = timing.expr,
                .timing_is_delay = timing.is_delay,
                .timing_repeat = timing.count,
                .timing_implicit = timing.implicit,
            } }, tok);
        },
        .colon => { // §5.6.7 / A.6.10 indirect contribution
            self.pos += 1;
            const probe = try parse_expr.parsePrimary(self);
            _ = try self.expect(.eq_eq);
            const eqn = try parse_expr.parseExpr(self);
            _ = try self.expect(.semicolon);
            return self.file.addStmt(
                self.arena,
                .{ .indirect = .{ .lhs = lhs, .probe = probe, .eqn = eqn } },
                tok,
            );
        },
        else => return self.failAt(self.pos, .E0214, "found {s}", .{self.found(self.pos)}), // else: an lvalue is followed by `<+`, `=` or `:`: E0214
    }
}

/// Whether `tag` is a literal, which no A.8.5 lvalue is.
fn isLiteral(tag: Ast.ExprTag) bool {
    return switch (tag) {
        .int_literal, .logic_literal, .real_literal, .str_literal, .pos_inf, .neg_inf => true,
        else => false, // else: a name, call, select or operator node: lowering judges it as a target
    };
}
