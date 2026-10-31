//! Hierarchical names in declaration positions (§6.7, A.9.3): a `defparam`
//! path, a config `instance` clause, an annex F.2.1 out-of-context net
//! declaration and a digital §12.5 instance select, each interned as ONE
//! `Ast.StrId` spelled the way elaboration spells the flat name
//! (`Elaborate.sep` is the same `.`, an array element is `[k]`).
//!
//! LRM clauses cited: §6.3.6, §6.7, annex F.2.1; IEEE 1364-2005 §12.5, §4.2.
//!
//! Contents:
//! - `pub fn parseDottedPath(self: *Parser, allow_index: bool, unfolded: ?*std.ArrayList(Ast.ExprId)) Error!Ast.StrId`
//! - `pub fn instanceSelectAhead(self: *const Parser) bool`
//! - `pub fn parseInstanceSelect(self: *Parser, name: Ast.StrId, unfolded: *std.ArrayList(Ast.ExprId)) Error!Ast.StrId`

const std = @import("std");
const assert = std.debug.assert;
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_expr = @import("expr.zig");
const Ast = @import("../ast.zig");
const constfold = @import("../constfold.zig");
const Error = parser.Error;

/// Parses a §6.7 hierarchical name in a declaration position and interns it as
/// one string with `.` between the parts. `Elaborate.sep` is the same period,
/// so the string a `defparam` path or an Annex F.2.1 out-of-context
/// declaration writes is the flat name elaboration gives the entity. Each part
/// went through `internTok`, so none carries a period of its own.
///
/// `allow_index` admits A.9.3's per-segment `[ constant_expression ]`, which
/// selects one element of a §6.2.2 instance array on any segment but the
/// last. The index is folded here and spelled `[{d}]`, the spelling
/// elaboration gives array elements (`Flatten.walkInstances`); an index that
/// does not fold is E0231, unless `unfolded` takes it: then it is spelled
/// `[]` and appended there, for elaboration to fold. Net declarations pass
/// `false`, because there a `[` after the name is A.2.1.3's vector range.
/// A §6.3.6 system name (`u.$xposition`) ends the path.
pub fn parseDottedPath(self: *Parser, allow_index: bool, unfolded: ?*std.ArrayList(Ast.ExprId)) Error!Ast.StrId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    // A.9.3 `hierarchical_identifier ::= [ $root . ] ...`: `$root` is part
    // 0 of the flat string, which its consumer roots (`override.rootedPath`).
    const first = if (self.peek() == .system_identifier and self.peekAt(1) == .dot and
        std.mem.eql(u8, self.tokenText(self.pos), "$root"))
    root: {
        const id = try self.internTok(self.pos);
        self.pos += 1;
        break :root id;
    } else try self.expectIdent();
    if (self.peek() != .dot and !(allow_index and self.peek() == .lbracket)) return first;
    var joined: std.ArrayList(u8) = .empty;
    try joined.appendSlice(self.arena, self.file.str(first));
    while (true) {
        if (allow_index and self.peek() == .lbracket) {
            const tok = self.pos;
            self.pos += 1;
            const idx = try parse_expr.parseExpr(self);
            _ = try self.expect(.rbracket);
            if (try self.walk(tok, constIndex, .{ self, idx })) |k| {
                var buf: [24]u8 = undefined;
                try joined.appendSlice(self.arena, std.mem.print(&buf, "[{d}]", .{k}) catch unreachable);
            } else if (unfolded) |list| {
                try list.append(self.arena, idx);
                try joined.appendSlice(self.arena, "[]");
            } else return self.failAt(tok, .E0231, "", .{});
            // A.9.3: an indexed segment is always followed by `.`; the final
            // identifier of a path carries no index.
            _ = try self.expect(.dot);
        } else if (!self.eat(.dot)) break;
        // §6.3.6 permits `defparam instance.$xposition = ...` and the
        // other hierarchical system parameters. A system name is the final
        // segment; elaboration checks that it names an overridable value.
        const system = self.peek() == .system_identifier;
        const part = if (system) blk: {
            const id = try self.internTok(self.pos);
            self.pos += 1;
            break :blk id;
        } else try self.expectIdent();
        try joined.append(self.arena, '.');
        try joined.appendSlice(self.arena, self.file.str(part));
        if (system) break;
    }
    return self.file.intern(self.arena, joined.items);
}

/// A digital parse's `[ … ] .` at the cursor: IEEE 1364-2005 §12.5's instance
/// select inside a hierarchical name, not a bit-select.
pub fn instanceSelectAhead(self: *const Parser) bool {
    if (!self.digital or self.peek() != .lbracket) return false;
    var depth: u32 = 0;
    var i = self.pos;
    while (i < self.tags.len) : (i += 1) switch (self.tags[i]) {
        .lbracket => depth += 1,
        .rbracket => {
            depth -= 1;
            if (depth == 0) return i + 1 < self.tags.len and self.tags[i + 1] == .dot;
        },
        .eof, .semicolon => return false,
        else => {}, // else: any other token is inside the brackets
    };
    return false;
}

/// `name[k]` for §12.5's instance select `[ constant_expression ]` at the
/// cursor, spelled as `parseDottedPath` spells it. An index that does not
/// fold (a genvar's, §12.4.1) is spelled `name[]` and appended to
/// `unfolded`, for `SourceFile.hier_indices`.
pub fn parseInstanceSelect(self: *Parser, name: Ast.StrId, unfolded: *std.ArrayList(Ast.ExprId)) Error!Ast.StrId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    const tok = self.pos;
    self.pos += 1;
    const idx = try parse_expr.parseExpr(self);
    _ = try self.expect(.rbracket);
    const k = try self.walk(tok, constIndex, .{ self, idx }) orelse {
        try unfolded.append(self.arena, idx);
        return self.file.intern(self.arena, try self.arena.print("{s}[]", .{self.file.str(name)}));
    };
    return self.file.intern(self.arena, try self.arena.print("{s}[{d}]", .{ self.file.str(name), k }));
}

// ---- private ----

/// Folds A.9.3's `[ constant_expression ]` over literals only, with §4.2's
/// integer typing: the same kernel elaboration applies to the instance-array
/// range. Parameters are elaboration's, so a read of one does not fold, and
/// neither does a real-valued index.
fn constIndex(self: *const Parser, e: Ast.ExprId) ?i64 {
    const c = constfold.fold(&self.file, e, constfold.literal_env) orelse return null;
    return if (c == .int) c.int else null;
}
