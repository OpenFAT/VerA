//! Annex A.1.9 paramset_declaration (LRM §6.4): tokens from `paramset` to
//! `endparamset` in, one `Ast.ParamsetDecl` out: the paramset's own
//! declarations, its `.name = expr;` overrides of the target module's
//! parameters, and its other statements (`body`). §6.4.1's restrictions on
//! what a paramset body may hold are checked here, by a token scan of each
//! statement before it is parsed.
//!
//! LRM clauses cited: §2.9, §6.4, §6.4.1, §6.4.3, §9.18, A.1.9.
//!
//! Contents:
//! - `pub fn parseParamset(self: *Parser) Error!Ast.ParamsetDecl`

const std = @import("std");
const assert = std.debug.assert;
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_decl = @import("decl.zig");
const parse_expr = @import("expr.zig");
const parse_source = @import("source.zig");
const parse_stmt = @import("stmt.zig");
const Ast = @import("../ast.zig");
const Error = parser.Error;

/// Parses one A.1.9 paramset_declaration (LRM §6.4):
///
///     paramset paramset_identifier module_or_paramset_identifier ;
///         paramset_item_declaration { paramset_item_declaration }
///         { paramset_statement }
///     endparamset
///
/// An empty item list is E0297.
///
/// §6.4: "The paramset itself contains no behavioral code; all of the
/// behavior is determined by the associated module". The result holds the
/// paramset's own declarations and its `.name = expr;` overrides of the
/// module's parameters. Clears `self.attrs`.
pub fn parseParamset(self: *Parser) Error!Ast.ParamsetDecl {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    const main_tok = self.pos;
    self.pos += 1; // 'paramset'
    const name = try self.expectIdent();
    const target = try self.expectIdent();
    _ = try self.expect(.semicolon);

    var params: std.ArrayList(Ast.ParamDecl) = .empty;
    var aliasparams: std.ArrayList(Ast.AliasParam) = .empty;
    var vars: std.ArrayList(Ast.VarDecl) = .empty;
    var overrides: std.ArrayList(Ast.ParamsetOverride) = .empty;
    const body_mark = self.bag.count();

    // A.1.9's other two statement forms, `paramset_local_identifier = expr ;`
    // (§6.4.1 "Paramset statements may assign values to variables declared in
    // the paramset") and `analog_function_statement`, in source order.
    // Elaboration runs them after the module's analog blocks (§6.4.3).
    var body: std.ArrayList(Ast.StmtId) = .empty;
    // Every arm that loops consumed: a declaration, an override, or the
    // statement `skipParamsetStatement` scanned (which the parse may rewind
    // into, but `end` is restored after it).
    var item_at: u32 = undefined;
    while (true) : (std.debug.assert(self.pos > item_at)) {
        item_at = self.pos;
        const mark = self.attrs.items.len;
        try self.skipAttributes();
        try parse_source.outsideDesignElement(self, "paramset");
        switch (self.peek()) {
            .eof, .kw_endparamset => {
                try self.attributesEnd(item_at);
                break;
            },
            .kw_parameter, .kw_localparam => {
                try parse_decl.parseParamDecl(self, &params);
                _ = try self.expect(.semicolon);
            },
            .kw_aliasparam => try aliasparams.append(self.arena, try parse_decl.parseAliasparam(self)),
            .kw_integer, .kw_real, .kw_string, .kw_realtime, .kw_time => {
                const first = vars.items.len;
                try parse_decl.parseVarDecl(self, &vars);
                _ = try self.expect(.semicolon);
                // §6.4.3 "Integer or real variables in the paramset declared
                // with descriptions are considered output variables".
                const described = for (self.attrs.items[mark..]) |a| {
                    if (std.mem.eql(u8, self.file.str(a.name), "desc")) break true;
                } else false;
                for (vars.items[first..]) |*v| v.desc = described;
            },
            // A.1.9 `paramset_statement ::= . module_parameter_identifier =
            // paramset_constant_expression ;` and its `. system_parameter_-
            // identifier` sibling (§9.18's `$mfactor` and friends), told
            // apart by the one token that spells a system name.
            .dot => {
                const tok = self.pos;
                self.pos += 1;
                const is_sys = self.peek() == .system_identifier;
                const pname = try self.expectIdentOrSys();
                _ = try self.expect(.assign_eq);
                const value = try parse_expr.parseExpr(self);
                _ = try self.expect(.semicolon);
                try overrides.append(self.arena, .{
                    .kind = if (is_sys) .system_param else .module_param,
                    .name = pname,
                    .value = value,
                    .main_tok = tok,
                });
            },
            // The two other statement forms, and only those: a variable
            // assignment (`ft = 3.0 * .gm;`: an identifier, then `=` or `[`)
            // or a §6.4.1 statement wrapping such assignments, so a
            // misspelled `paramter real rr;` is still refused. A token scan
            // first reports what §6.4.1 forbids (E0237); a statement it
            // passes is parsed, with §6.4.3's `.module_output_variable`
            // spelling admitted as a primary (`in_paramset`).
            else => { // else: every other paramset statement, gated to what A.1.9 admits just below
                const legal = (self.identLike(self.pos) and
                    (self.peekAt(1) == .assign_eq or self.peekAt(1) == .lbracket)) or
                    switch (self.peek()) {
                        .kw_if, .kw_case, .kw_for, .kw_while, .kw_repeat, .kw_begin => true,
                        else => false, // else: not a statement keyword A.1.9 admits here
                    };
                if (!legal) try self.report(
                    self.pos,
                    .E0205,
                    "found {s} in a paramset body",
                    .{self.found(self.pos)},
                );
                const start = self.pos;
                const errors = self.bag.count();
                try skipParamsetStatement(self);
                if (legal and self.bag.count() == errors) {
                    const end = self.pos;
                    self.pos = start;
                    self.in_paramset = true;
                    defer self.in_paramset = false;
                    // A parse error is in the bag; the scan's end resumes.
                    if (parse_stmt.parseStmt(self)) |id| {
                        try body.append(self.arena, id);
                    } else |e| if (e == error.OutOfMemory) return e;
                    self.pos = end;
                }
            },
        }
    }
    // A.1.9 `paramset_item_declaration { paramset_item_declaration }`: at
    // least one. Not after an error in the body, which may have been a
    // misspelled declaration (`paramter real rr;`, E0205).
    if (params.items.len + aliasparams.items.len + vars.items.len == 0) {
        const clean = for (body_mark..self.bag.count()) |i| {
            if (self.bag.at(i).severity == .err) break false;
        } else true;
        if (clean) try self.report(main_tok, .E0297, "paramset `{s}` declares no parameter, aliasparam or variable", .{self.file.str(name)});
    }
    _ = try self.expect(.kw_endparamset);
    // §2.9 attributes inside a paramset decorate its declarations, and
    // `NatureAttr` collection is per design element, so drop them with the
    // element.
    self.attrs.clearRetainingCapacity();

    return .{
        .name = name,
        .target = target,
        .params = params.items,
        .aliasparams = aliasparams.items,
        .vars = vars.items,
        .overrides = overrides.items,
        .body = body.items,
        .main_tok = main_tok,
    };
}

// ---- private ----

/// Skips one A.1.9 paramset statement by tokens: to the `;` that ends it,
/// balancing `(...)` (a `for` header holds two semicolons), `begin`/`end`
/// and `case`/`endcase`, and continuing over `else`, so a dropped
/// `if (c) begin ft = 1.0; end else ft = 2.0;` is one skip. A statement
/// that is a block ends at its `end`/`endcase`, which has no `;`.
///
/// Still reports E0237 for what §6.4.1 forbids a paramset: "Shall not use
/// access functions. Shall not use contribution statements or event control
/// statements. Shall not use named blocks." Skipping them silently would
/// accept them.
fn skipParamsetStatement(self: *Parser) Error!void {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    var depth: u32 = 0;
    while (true) : (self.pos += 1) {
        const what: ?[]const u8 = switch (self.peek()) {
            .kw_potential, .kw_flow => if (self.peekAt(1) == .lparen) "an access function" else null,
            .identifier => if (self.peekAt(1) == .lparen and self.access_names.contains(self.tokenText(self.pos))) "an access function" else null,
            .kw_begin => if (self.peekAt(1) == .colon) "a named block" else null,
            .contribute => "a contribution statement",
            .at => "an event control",
            else => null, // else: every other token is legal in a paramset statement
        };
        if (what) |w| try self.report(self.pos, .E0237, "{s}: found {s}", .{ w, self.found(self.pos) });
        switch (self.peek()) {
            .eof, .kw_endparamset => return,
            .lparen, .kw_begin, .kw_case => depth += 1,
            .rparen => depth -|= 1,
            .kw_end, .kw_endcase => {
                depth -|= 1;
                if (depth == 0 and self.peekAt(1) != .kw_else) {
                    self.pos += 1;
                    return;
                }
            },
            .semicolon => if (depth == 0 and self.peekAt(1) != .kw_else) {
                self.pos += 1;
                return;
            },
            else => {}, // else: any other token is inside the statement being skipped
        }
    }
}
