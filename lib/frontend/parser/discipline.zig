//! Annex A.1.6 nature_declaration and A.1.7 discipline_declaration (§3.6):
//! tokens from `nature`/`discipline` to the matching `end*` keyword in, one
//! `Ast.NatureDecl` or `Ast.DisciplineDecl` out. A nature's `access = X;`
//! also grows `Parser.access_names`, which decides whether a later `X(...)`
//! is a branch probe (§4.4.1) or a function call (§4.7).
//!
//! LRM clauses cited: §3.6.1, §3.6.1.2, §3.6.1.3, §3.6.2, §3.6.2.1 to
//! §3.6.2.3, §3.6.2.7.

const std = @import("std");
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_expr = @import("expr.zig");
const Ast = @import("../ast.zig");
const Error = parser.Error;

/// Parses a §3.6.1 nature declaration (A.1.6), cursor on `nature`. Each
/// `access = X;` attribute adds `X` to `access_names`, so later `X(...)` parse
/// as branch probes. Whether a base nature declares `abstol` and `access` is
/// lowering's check.
pub fn parseNature(self: *Parser) Error!Ast.NatureDecl {
    const main_tok = self.pos;
    self.pos += 1; // 'nature'
    const name = try self.expectIdent();
    var parent: Ast.StrId = .none;
    var parent_access: ?Ast.PotentialOrFlow = null;
    if (self.eat(.colon)) {
        parent = try self.expectIdent();
        // A.1.6 `discipline_identifier . potential_or_flow`
        if (self.eat(.dot)) {
            parent_access = switch (self.peek()) {
                .kw_potential => .potential,
                .kw_flow => .flow,
                else => return self.failAt(self.pos, .E0211, "found {s}", .{self.found(self.pos)}), // else: A.1.6 names `potential` or `flow` and nothing else: E0211
            };
            self.pos += 1;
        }
    }
    _ = self.eat(.semicolon);

    var attrs: std.ArrayList(Ast.NatureAttr) = .empty;
    while (self.peek() != .kw_endnature and self.peek() != .eof) {
        const attr = try parseNatureAttr(self);
        // §3.6.1.2: this is where the branch-probe names come from.
        if (self.file.strings.eql(attr.name, "access") and
            self.file.exprs.tag(attr.value) == .ident)
        {
            const access = self.file.str(self.file.exprs.strOf(attr.value));
            try self.access_names.put(self.arena, access, {});
        }
        try attrs.append(self.arena, attr);
    }
    _ = try self.expect(.kw_endnature);
    return .{
        .name = name,
        .parent = parent,
        .parent_access = parent_access,
        .attrs = attrs.items,
        .main_tok = main_tok,
    };
}

/// A.1.6 `nature_attribute ::= identifier = nature_attribute_expression ;`.
/// The five LRM-defined attribute names (§3.6.1.2: abstol, access,
/// idt_nature, ddt_nature, units) are keywords.
pub fn parseNatureAttr(self: *Parser) Error!Ast.NatureAttr {
    const tok = self.pos;
    const name: Ast.StrId = switch (self.peek()) {
        .identifier, .escaped_identifier => try self.expectIdent(),
        .kw_abstol, .kw_access, .kw_units, .kw_ddt_nature, .kw_idt_nature => blk: {
            const s = try self.file.intern(self.arena, self.tokenText(self.pos));
            self.pos += 1;
            break :blk s;
        },
        else => return self.failAt(self.pos, .E0208, "found {s}", .{self.found(self.pos)}), // else: not a nature attribute name: E0208
    };
    _ = try self.expect(.assign_eq);
    const value = try parse_expr.parseExpr(self);
    _ = try self.expect(.semicolon);
    return .{ .name = name, .value = value, .main_tok = tok };
}

/// Parses a §3.6.2 discipline declaration (A.1.7), cursor on `discipline`.
pub fn parseDiscipline(self: *Parser) Error!Ast.DisciplineDecl {
    const main_tok = self.pos;
    self.pos += 1; // 'discipline'
    const name = try self.expectIdent();
    _ = self.eat(.semicolon);

    var d: Ast.DisciplineDecl = .{ .name = name, .main_tok = main_tok };
    var overrides: std.ArrayList(Ast.DisciplineDecl.Override) = .empty;
    var attrs: std.ArrayList(Ast.NatureAttr) = .empty;
    while (self.peek() != .kw_enddiscipline and self.peek() != .eof) {
        switch (self.peek()) {
            // §3.6.2.1 nature_binding / §3.6.2.3 nature_attribute_override
            .kw_potential, .kw_flow => {
                const which: Ast.PotentialOrFlow =
                    if (self.peek() == .kw_potential) .potential else .flow;
                self.pos += 1;
                if (self.eat(.dot)) {
                    try overrides.append(self.arena, .{
                        .which = which,
                        .attr = try parseNatureAttr(self),
                    });
                } else {
                    const nature = try self.expectIdent();
                    _ = try self.expect(.semicolon);
                    if (which == .potential) d.potential = nature else d.flow = nature;
                }
            },
            // §3.6.2.2 domain binding
            .kw_domain => {
                self.pos += 1;
                d.domain = switch (self.peek()) {
                    .kw_continuous => .continuous,
                    .kw_discrete => .discrete,
                    else => return self.failAt(self.pos, .E0212, "found {s}", .{self.found(self.pos)}), // else: A.1.7 names `continuous` or `discrete` and nothing else: E0212
                };
                // Annex C.17: a Verilog-A implementation "shall silently ignore
                // any definition of a discipline with a domain of discrete", so
                // annex D's `logic` parses; C.4's error is a use of one
                // (`source.refuseDiscreteUses`).
                self.pos += 1;
                _ = try self.expect(.semicolon);
            },
            // §3.6.2.7: "Like natures, a discipline can specify user-defined
            // attributes." A.1.7's discipline_item omits the production; VerA
            // follows the prose. Gated on the `=` so a stray identifier still
            // gets E0213 rather than a mid-production "expected '='".
            .identifier, .escaped_identifier => {
                if (self.peekAt(1) != .assign_eq)
                    return self.failAt(self.pos, .E0213, "found {s}", .{self.found(self.pos)});
                try attrs.append(self.arena, try parseNatureAttr(self));
            },
            else => return self.failAt(self.pos, .E0213, "found {s}", .{self.found(self.pos)}), // else: not a discipline_item: E0213
        }
    }
    _ = try self.expect(.kw_enddiscipline);
    d.overrides = overrides.items;
    d.attrs = attrs.items;
    return d;
}
