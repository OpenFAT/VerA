//! §2.9 attribute instances: the tokens of `(* attr_spec, ... *)` prefixes
//! in, their specs appended to `Parser.attrs` (for the module's
//! constant-expression check) and one `Ast.AttributeBinding` per prefix in
//! `Parser.file.attributes`, bound to the declaration, statement or operator
//! they decorate; VerA's vendor attributes (`vera_lte` and the rest) also
//! land in `file.lte_attrs`. `appendBinding` is the one writer of the
//! binding rows and keeps `Parser.attr_at` sorted beside them.
//! Cites: LRM §2.9 Syntax 2-4, §2.9.2, A.9.1, A.8.3; IEEE 1364-2005 §3.8;
//! specification/Vague_Decisions.md VD-024.
//!
//! Contents:
//! - `pub const AttrMark = struct`
//! - `pub fn skipAttributes(self: *Parser) error`
//! - `pub fn attributesEnd(self: *Parser, from: u32) error`
//! - `pub fn pastAttributes(self: *const Parser) u32`
//! - `pub fn ownedAttributes(self: *Parser, owner: Ast.AttributeOwner) error`
//! - `pub fn copyAttributes(self: *Parser, from: u32, to: u32) error`
//! - `pub fn statementAttributes(self: *Parser, tok: u32) void`
//! - `pub fn markAttributes(self: *const Parser) AttrMark`
//! - `pub fn rewindAttributes(self: *Parser, m: AttrMark) void`
//! - `pub fn lteSince(self: *const Parser, mark: usize) [lte_kinds.len]?Ast.NatureAttr`
//! - `pub fn keepLte(self: *Parser, specs: [lte_kinds.len]?Ast.NatureAttr, stmt: Ast.StmtId, expr: Ast.ExprId) error`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("../ast.zig");
const token = @import("../token.zig");
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const Error = parser.Error;
const parse_expr = @import("expr.zig");

/// Where a speculative `skipAttributes` started: the cursor and the
/// lengths of `attrs` and `file.attributes`. Both tables only grow while
/// it is held, so the lengths are enough to undo the read.
/// Both lengths are bounded by the token count, which is a `u32`.
pub const AttrMark = struct { pos: u32, specs: u32, bindings: u32 };

comptime {
    assert(@sizeOf(AttrMark) == 12);
}

const lte_kinds = std.enums.values(@FieldType(Ast.LteAttr, "kind"));

/// §2.9 Syntax 2-4 / A.9.1:
///
///     attribute_instance ::= (* attr_spec { , attr_spec } *)
///     attr_spec          ::= attr_name [ = constant_expression ]
///
/// Parses any attribute instances at the cursor and appends every spec to
/// `self.attrs`, which `parseModule` hands to the enclosing module for
/// validation. Also binds this prefix to the following declaration;
/// statement and expression callers refine that parsed owner below.
///
/// A malformed attribute is reported and the cursor resynchronized past its
/// `*)`, so the caller always lands past the instance. Only OOM propagates.
pub fn skipAttributes(self: *Parser) error{OutOfMemory}!void {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    const mark = self.attrs.items.len;
    parseAttributes(self) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        // Already reported. Resynchronize past the closing `*)` so one bad
        // attribute does not also cost the decorated declaration a diagnostic.
        while (true) : (self.pos += 1) switch (self.peek()) {
            .eof => return,
            .attr_close => {
                self.pos += 1;
                return;
            },
            else => {}, // else: any other token is inside the attribute being skipped
        };
    };
    if (self.attrs.items.len != mark) try appendBinding(self, .{
        .owner = .{ .kind = .declaration, .tok = self.pos },
        .specs = try self.arena.dupe(Ast.NatureAttr, self.attrs.items[mark..]),
    });
}

/// For a list loop that ran `skipAttributes` from token `from` and now
/// stops at its closer (`end`, `endmodule`, end of file, ...). §2.9 makes
/// an attribute instance "a prefix attached to" what follows it, so one
/// read here prefixes nothing: E0207 at the instance (#49). Every item
/// list reports it this way, the file's top level included.
pub fn attributesEnd(self: *Parser, from: u32) error{OutOfMemory}!void {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    if (self.pos != from) try self.report(from, .E0207, "found {s}: an attribute instance prefixes nothing", .{self.found(self.pos)});
}

/// The token past the attribute instances at the cursor, found by
/// scanning to each `*)` without parsing, so nothing is read, bound or
/// reported. A statement loop asks it whether a prefix runs into the
/// loop's closer, which `parseStmt` would otherwise take for the start of
/// a statement (#66). Cost: the instances' tokens.
pub fn pastAttributes(self: *const Parser) u32 {
    var i = self.pos;
    while (self.tags[i] == .attr_open) {
        while (self.tags[i] != .attr_close and self.tags[i] != .eof) i += 1;
        if (self.tags[i] == .eof) break;
        i += 1;
    }
    return i;
}

/// `skipAttributes`, then binds what it read to `owner` (an operator or
/// call suffix, or a statement prefix) instead of the next declaration.
/// Asserts a `.declaration` owner's token is not past the cursor.
pub fn ownedAttributes(self: *Parser, owner: Ast.AttributeOwner) error{OutOfMemory}!void {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    assert(owner.kind != .declaration or owner.tok <= self.pos); // `attr_at`'s invariant
    const first = self.file.attributes.items.len;
    try skipAttributes(self);
    // §2.9/IEEE §3.8 prohibit attributes inside an attribute value;
    // attr_depth diagnoses them. A successful run adds only this one
    // prefix binding, whose specs include every adjacent instance.
    assert(self.file.attributes.items.len <= first + 1);
    for (self.file.attributes.items[first..]) |*a| a.owner = owner;
}

/// Gives the declaration at token `to` every attribute binding the
/// declaration at token `from` has: §2.9 Example 5 puts a prefix on every
/// name of its list. A binding already copied is not added again. Cost:
/// the bindings appended since the cursor reached `from` (and `to`), not
/// the file's.
pub fn copyAttributes(self: *Parser, from: u32, to: u32) error{OutOfMemory}!void {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    if (from == to) return;
    const count = self.file.attributes.items.len;
    for (bindingsFrom(self, from)..count) |i| {
        const a = self.file.attributes.items[i];
        if (a.owner.kind != .declaration or a.owner.tok != from) continue;
        const exists = for (self.file.attributes.items[bindingsFrom(self, to)..]) |b| {
            if (b.owner.kind == .declaration and b.owner.tok == to and b.specs.ptr == a.specs.ptr) break true;
        } else false;
        if (!exists) try appendBinding(self, .{ .owner = .{ .kind = .declaration, .tok = to }, .specs = a.specs });
    }
}

/// Rebinds the declaration-owned attributes at token `tok` to the
/// statement that starts there. `skipAttributes` binds a prefix to a
/// declaration, and lookahead may have read a statement's prefix before
/// knowing it was one. Cost: the bindings appended since the cursor
/// reached `tok`.
pub fn statementAttributes(self: *Parser, tok: u32) void {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    for (self.file.attributes.items[bindingsFrom(self, tok)..]) |*a| if (a.owner.kind == .declaration and a.owner.tok == tok) {
        a.owner.kind = .statement;
    };
}

/// Returns the mark `rewindAttributes` undoes a speculative read back to.
pub fn markAttributes(self: *const Parser) AttrMark {
    return .{ .pos = self.pos, .specs = @intCast(self.attrs.items.len), .bindings = @intCast(self.file.attributes.items.len) };
}

/// Hands attribute instances read since `m` back to the token stream: the
/// cursor returns to `m` and their specs and bindings are dropped, so
/// whatever the instance prefixes collects it again. Asserts the cursor
/// has not moved back past `m`.
pub fn rewindAttributes(self: *Parser, m: AttrMark) void {
    assert(m.pos <= self.pos);
    self.pos = m.pos;
    self.attrs.shrinkRetainingCapacity(m.specs);
    self.file.attributes.shrinkRetainingCapacity(m.bindings);
    self.attr_at.shrinkRetainingCapacity(m.bindings);
}

/// The last spec of each VerA attribute in `self.attrs[mark..]` (§2.9:
/// "the last attribute value shall be used"), in `lte_kinds` order.
pub fn lteSince(self: *const Parser, mark: usize) [lte_kinds.len]?Ast.NatureAttr {
    var out: [lte_kinds.len]?Ast.NatureAttr = @splat(null);
    for (self.attrs.items[mark..]) |a| for (&out, lte_kinds) |*o, k| {
        if (std.mem.eql(u8, self.file.str(a.name), @tagName(k))) o.* = a;
    };
    return out;
}

/// Records `lteSince`'s finds against statement `stmt` or call `expr`.
pub fn keepLte(self: *Parser, specs: [lte_kinds.len]?Ast.NatureAttr, stmt: Ast.StmtId, expr: Ast.ExprId) error{OutOfMemory}!void {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    for (specs, lte_kinds) |f, k| if (f) |a| try self.file.lte_attrs.append(
        self.arena,
        .{ .kind = k, .stmt = stmt, .expr = expr, .value = a.value, .main_tok = a.main_tok },
    );
}

// ---- private ----

/// The one writer of `file.attributes`' rows, keeping `attr_at` beside it.
/// Asserts a declaration owner is not past the cursor, which is what lets
/// `bindingsFrom` skip every row appended before the cursor reached it.
fn appendBinding(self: *Parser, binding: Ast.AttributeBinding) error{OutOfMemory}!void {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    assert(self.attr_at.items.len == self.file.attributes.items.len);
    assert(binding.owner.kind != .declaration or binding.owner.tok <= self.pos);
    try self.attr_at.ensureUnusedCapacity(self.arena, 1);
    try self.file.attributes.append(self.arena, binding);
    self.attr_at.appendAssumeCapacity(self.pos);
}

/// Index of the first `file.attributes` row appended with the cursor at or
/// past `tok`. No earlier row is owned by a declaration at `tok`.
/// Cost: O(log n) in the file's bindings.
fn bindingsFrom(self: *const Parser, tok: u32) usize {
    // Most declarations and statements carry no attribute: then the
    // newest row is older than `tok`, and so is every other.
    const rows = self.attr_at.items;
    if (rows.len == 0 or rows[rows.len - 1] < tok) return rows.len;
    const order = struct {
        fn f(want: u32, at: u32) std.math.Order {
            return std.math.order(want, at);
        }
    }.f;
    return std.sort.lowerBound(u32, rows, tok, order);
}

fn parseAttributes(self: *Parser) Error!void {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    while (self.peek() == .attr_open) {
        // §2.9: "Nesting of attribute instances is disallowed." An attribute
        // value is a full `parseExpr`, and A.8.3 gives an operator its own
        // `{ attribute_instance }` slot, so without this check
        // `(* outer = (1 + (* inner *) 2) *)` would parse cleanly.
        if (self.attr_depth != 0) {
            var d = self.failWith(self.pos, .E0357);
            d.msg("the value contains an attribute instance", .{});
            d.note("§2.9: \"Nesting of attribute instances is disallowed\"", .{});
            try d.emit();
            return error.ParseError;
        }
        self.pos += 1;
        self.attr_depth += 1;
        defer self.attr_depth -= 1;
        while (true) {
            const tok = self.pos;
            // `attr_name ::= identifier` (A.9.1), but §2.9.2's own `units`
            // is an annex B keyword (`kw_units`) it prints unescaped. No
            // clause grants any other keyword that exception (VD-024).
            if (!self.identLike(tok) and self.peek() != .kw_units) {
                if (!token.isKeyword(self.peek()))
                    return self.failAt(tok, .E0208, "found {s}", .{self.found(tok)});
                var d = self.failWith(tok, .E0208);
                d.msg("found keyword `{s}`: an attribute name is an identifier", .{self.tokenText(tok)});
                d.note("§2.9 / A.9.1: `attr_name ::= identifier`; only §2.9.2's `units` is exempt", .{});
                d.help("escape it: `\\{s} `", .{self.tokenText(tok)});
                try d.emit();
                return error.ParseError;
            }
            const name = try self.internTok(tok);
            self.pos += 1;
            // §2.9: "If the value is not specified, then ... the default
            // value is 1." `.none` stands for that default.
            const value: Ast.ExprId = if (self.eat(.assign_eq))
                try parse_expr.parseExpr(self)
            else
                .none;
            try self.attrs.append(self.arena, .{ .name = name, .value = value, .main_tok = tok });
            if (!self.eat(.comma)) break;
        }
        _ = try self.expect(.attr_close);
    }
}
