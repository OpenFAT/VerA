//! Source expressions and resolved hierarchical paths → §3.4.7 alias-use
//! diagnostics. Binding names remain legal; value expressions must use the
//! original parameter. Source checking precedes folding and flattening;
//! the second check uses the alias paths recorded while instances are cloned.
//!
//! Contents:
//! - `pub fn original(file: *const Ast.SourceFile, params: []const Ast.ParamDecl, aliases: []const Ast.AliasParam, alias: Ast.AliasParam) ?Ast.StrId`
//! - `pub fn checkSource(ctx: Ctx) Error!void`
//! - `pub fn checkFlat(ctx: Ctx, top: *const Ast.ModuleDecl, aliases: []const Ast.AliasParam) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const design = @import("design.zig");
const flat_name = @import("flat_name.zig");
const Kind = @import("hier_param.zig").Kind;
const Ast = @import("frontend").Ast;
const Lexer = @import("frontend").Lexer;
const Ctx = design.Ctx;
const Error = design.Error;
const fixture = @import("fixture.zig");
const elaborate = @import("elaborate.zig");

const Scan = struct {
    ctx: Ctx,
    aliases: []const Ast.AliasParam,
    params: []const Ast.ParamDecl = &.{},
    /// Non-null only after flattening. Local identifier reads were already
    /// checked in their source scope; generated geometry storage may legally
    /// refer to an alias internally, so this pass checks hierarchical reads.
    top: ?*const Ast.ModuleDecl = null,

    fn expr(self: *Scan, e: Ast.ExprId) Error!void {
        if (e == .none) return;
        const file = self.ctx.file;
        const x = &file.exprs;
        if (self.top) |top| {
            if (x.tag(e) == .hier_ident) {
                const path = try flat_name.flatReference(file, self.ctx.arena, top, e);
                for (self.aliases) |al| if (file.strings.eql(al.alias, path)) {
                    try self.reject(e, al.alias, al.target);
                    break;
                };
            }
        } else if (x.tag(e) == .ident) {
            for (self.aliases) |al| if (al.alias == x.strOf(e)) {
                if (original(file, self.params, self.aliases, al)) |target|
                    try self.reject(e, al.alias, target);
                break;
            };
        }
        var buf: [3]Ast.ExprId = undefined;
        for (x.children(e, &buf)) |child| try self.expr(child);
    }

    fn reject(self: *Scan, e: Ast.ExprId, alias: Ast.StrId, target: Ast.StrId) Error!void {
        const file = self.ctx.file;
        try self.ctx.bag.add(.lower, .E0373, Lexer.tokenSpan(self.ctx.src, self.ctx.tok_starts, file.exprs.mainTok(e)), "`{s}` is an alias; reference the original parameter `{s}`", .{ file.str(alias), file.str(target) });
    }

    /// Visit AST expression slots, never binding-name slots (`StrId`). This
    /// includes defaults, ranges, attributes, calls and dead branches, while
    /// `.alias(value)` and defparam/paramset assignment targets stay legal.
    /// Structural recursion also reaches function, task and generate bodies.
    fn walk(self: *Scan, value: anytype) Error!void {
        const T = @TypeOf(value);
        if (T == Ast.ExprId) return self.expr(value);
        if (T == Ast.StmtId) {
            if (value != .none) try self.walk(self.ctx.file.stmt(value));
            return;
        }
        switch (@typeInfo(T)) {
            .@"struct" => inline for (@typeInfo(T).@"struct".field_names) |name| try self.walk(@field(value, name)),
            .@"union" => switch (value) {
                inline else => |payload| try self.walk(payload), // else: every union variant's expression slots are visited
            },
            .optional => if (value) |v| try self.walk(v),
            .pointer => |p| switch (p.size) {
                .slice => for (value) |v| try self.walk(v),
                .one => try self.walk(value.*),
                .many, .c => @compileError("AST alias-use walk needs a bounded pointer"),
            },
            .array => for (value) |v| try self.walk(v),
            else => {}, // else: scalars, enums and binding identifiers contain no expression slots
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Returns the original parameter `alias` names, following a chain of
/// aliases, or null when the alias shadows a parameter, the chain names
/// nothing, or it is a cycle. A §9.18 system parameter is an original.
/// Invalid declarations remain the E0303/E0331 checks' job (lowering).
pub fn original(file: *const Ast.SourceFile, params: []const Ast.ParamDecl, aliases: []const Ast.AliasParam, alias: Ast.AliasParam) ?Ast.StrId {
    assert(alias.alias != .none);
    for (params) |p| if (p.name == alias.alias) return null;
    var target = alias.target;
    for (0..aliases.len + 1) |_| {
        for (params) |p| if (p.name == target) return target;
        if (Kind.fromName(file.str(target)) != null) return target;
        target = for (aliases) |a| {
            if (a.alias == target) break a.target;
        } else return null;
    }
    return null; // cyclic alias declarations have no original parameter
}

/// §3.4.7 reports E0373 for every expression that reads an aliasparam
/// instead of its original, in every user module and paramset, before
/// anything is folded or cloned. Returns `error.DiagnosticsReported` if the
/// bag holds any error afterwards, including one reported earlier.
pub fn checkSource(ctx: Ctx) Error!void {
    for (ctx.file.userModules()) |*m| {
        if (m.aliasparams.len == 0) continue;
        var scan: Scan = .{ .ctx = ctx, .aliases = m.aliasparams, .params = m.params };
        try scan.walk(m.*);
    }
    for (ctx.file.paramsets) |*ps| {
        if (ps.aliasparams.len == 0) continue;
        var scan: Scan = .{ .ctx = ctx, .aliases = ps.aliasparams, .params = ps.params };
        try scan.walk(ps.*);
    }
    if (ctx.bag.failed()) return error.DiagnosticsReported;
}

/// §3.4.7 the flattened half of `checkSource`: reports E0373 for every
/// hierarchical read (`u.alias`) of one of `aliases`, given in their flat
/// names. Local reads were judged in their source scope already. Returns
/// `error.DiagnosticsReported` if the bag holds any error afterwards.
pub fn checkFlat(ctx: Ctx, top: *const Ast.ModuleDecl, aliases: []const Ast.AliasParam) Error!void {
    assert(top.name != .none);
    if (aliases.len == 0) return;
    var scan: Scan = .{ .ctx = ctx, .aliases = aliases, .top = top };
    try scan.walk(top.*);
    if (ctx.bag.failed()) return error.DiagnosticsReported;
}

test original {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var file: Ast.SourceFile = .empty;
    const g = try file.intern(a, "g");
    const ag = try file.intern(a, "ag");
    const a1 = try file.intern(a, "a1");
    const a2 = try file.intern(a, "a2");
    const c1 = try file.intern(a, "c1");
    const c2 = try file.intern(a, "c2");
    const am = try file.intern(a, "am");
    const mf = try file.intern(a, "$mfactor");
    const ad = try file.intern(a, "ad");
    const nowhere = try file.intern(a, "nowhere");
    const params = [_]Ast.ParamDecl{.{ .name = g, .ty = .real, .default = .none }};
    const aliases = [_]Ast.AliasParam{
        .{ .alias = ag, .target = g },
        .{ .alias = a1, .target = a2 },
        .{ .alias = a2, .target = g },
        .{ .alias = c1, .target = c2 },
        .{ .alias = c2, .target = c1 },
        .{ .alias = am, .target = mf },
        .{ .alias = ad, .target = nowhere },
    };
    // §3.4.7: one alias, then a chain of two, both end at the parameter.
    try std.testing.expectEqual(@as(?Ast.StrId, g), original(&file, &params, &aliases, aliases[0]));
    try std.testing.expectEqual(@as(?Ast.StrId, g), original(&file, &params, &aliases, aliases[1]));
    // A cycle and a dangling target have no original; the walk still ends.
    try std.testing.expectEqual(@as(?Ast.StrId, null), original(&file, &params, &aliases, aliases[3]));
    try std.testing.expectEqual(@as(?Ast.StrId, null), original(&file, &params, &aliases, aliases[6]));
    // §9.18 a system parameter is an original in its own right.
    try std.testing.expectEqual(@as(?Ast.StrId, mf), original(&file, &params, &aliases, aliases[5]));
    // An alias spelled like a parameter is shadowed by it, so it aliases nothing.
    const shadowed = [_]Ast.ParamDecl{ params[0], .{ .name = ag, .ty = .real, .default = .none } };
    try std.testing.expectEqual(@as(?Ast.StrId, null), original(&file, &shadowed, &aliases, aliases[0]));
}

test checkSource {
    // §3.4.7: a value expression that reads an aliasparam is E0373.
    var bad: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer bad.deinit();
    try fixture.parse(&bad,
        \\module top(p); inout p; electrical p;
        \\  parameter real g = 1.0; aliasparam ag = g; parameter real h = ag * 2.0;
        \\endmodule
    );
    try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(bad.ctx()));
    try std.testing.expect(fixture.hasCode(&bad.bag, .E0373));

    // The legal neighbour reads the original.
    var good: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer good.deinit();
    try fixture.parse(&good,
        \\module top(p); inout p; electrical p;
        \\  parameter real g = 1.0; aliasparam ag = g; parameter real h = g * 2.0;
        \\endmodule
    );
    _ = try elaborate.elaborate(good.ctx());
    try std.testing.expect(!fixture.hasCode(&good.bag, .E0373));
}
