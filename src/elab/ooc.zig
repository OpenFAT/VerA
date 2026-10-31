//! Annex F.2.1 step 3: out-of-context discipline declarations
//! (`electrical top.u.w;`) → a table keyed by the absolute flat name of the
//! segment each names, judged for §3.6.2 compatibility and applied, with
//! §3.6.3.2's hierarchical nodesets.
//! Cites: LRM §3.6.2, §3.6.3.2, §3.10, §3.11.1, Annex F.2.1.
//!
//! Contents:
//! - `pub const OocDecl = struct`
//! - `pub const OocInit = struct`
//! - `pub fn isOoc(name: []const u8) bool`
//! - `pub fn collectOoc(self: *Flatten, module: *const Ast.ModuleDecl, path: []const u8) design.Error!void`
//! - `pub fn oocDiscipline(self: *Flatten, path: []const u8, local: Ast.StrId) ?Ast.StrId`
//! - `pub fn oocDisciplineBelow(self: *Flatten, path: []const u8, local: Ast.StrId) ?Ast.StrId`
//! - `pub fn checkOocOverrides(self: *Flatten, child: *const Ast.ModuleDecl, path: []const u8) design.Error!void`
//! - `pub fn applyOocInits(self: *Flatten) design.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const design = @import("design.zig");
const Flatten = @import("Flatten.zig");
const elaborate = @import("elaborate.zig");
const clone_expr = @import("clone_expr.zig");
const flat_name = @import("flat_name.zig");
const lookup = @import("lookup.zig");
const defparam = @import("defparam.zig");
const resolve = @import("resolve.zig");
const discipline = @import("discipline_rules.zig");
const sep = design.sep;

/// `Flatten.oocs`: Annex F.2.1 step 3 / §3.10 precedence order 1.
pub const State = struct {
    /// Every OUT-OF-CONTEXT discipline declaration, keyed by the absolute
    /// flat name of the net segment it declares (the key shape of
    /// `defparam.Table.rows`). "Apply all out-of-context node and signal
    /// declarations. For example, electrical top.middle.bottom.sig; overrides
    /// any discipline which may be declared for sig in the module where sig
    /// was declared."
    decls: std.StringHashMapUnmanaged(OocDecl) = .empty,
    /// §3.6.3.2's nodeset on an out-of-context declaration
    /// (`electrical u.w = 2.75;`), in `collectOoc` order (top-down), the
    /// initializer cloned in the declaring module's namespace. Applied after
    /// the walk by `applyOocInits`.
    inits: std.ArrayList(OocInit) = .empty,
};

/// An out-of-context discipline declaration (`Flatten.ooc`), with its token
/// for §3.6.2's compatibility diagnostic.
pub const OocDecl = struct { disc: Ast.StrId, tok: u32 };

/// An out-of-context declaration's initializer: the segment it names
/// (`collectOoc`'s key), how deep its declaring module sits (its path's
/// length), and the initializer in flat names.
pub const OocInit = struct { key: []const u8, depth: usize, init: Ast.ExprId };

/// Returns whether a declared net name is an out-of-context one. A period can
/// only come from a hierarchical path (see `sep`).
pub fn isOoc(name: []const u8) bool {
    return std.mem.findScalar(u8, name, sep) != null;
}

/// Annex F.2.1 step 3: records `module`'s out-of-context discipline
/// declarations under its instance prefix `path`, before any child is
/// inlined, since each names a segment below this module. Reports E0902 for
/// a second declaration of one segment: "More than one conflicting
/// out-of-context discipline declaration for the same hierarchical segment
/// of a signal is an error", and §3.10 makes two declarations at one
/// precedence level illegal even when compatible, so this is a duplicate-key
/// test, not a compatibility test.
pub fn collectOoc(self: *Flatten, module: *const Ast.ModuleDecl, path: []const u8) design.Error!void {
    for (module.nets) |n| {
        if (!isOoc(self.ctx.file.str(n.name))) continue;
        const key = defparam.rootedPath(self, self.ctx.file.str(n.name)) orelse
            try self.ctx.arena.print("{s}{s}", .{ path, self.ctx.file.str(n.name) });
        if (self.oocs.decls.get(key)) |first| {
            try self.err(n.main_tok, .E0902, "`{s}` already has the out-of-context discipline `{s}`", .{
                key, self.ctx.file.str(first.disc),
            });
            continue;
        }
        try self.oocs.decls.put(self.ctx.arena, key, .{ .disc = n.discipline, .tok = n.main_tok });
        if (n.init != .none) try self.oocs.inits.append(self.ctx.arena, .{
            .key = key,
            .depth = path.len,
            .init = try clone_expr.cloneExpr(self, n.init),
        });
    }
}

/// §3.10 precedence order 1: the out-of-context discipline for one segment,
/// if a declaration named it.
///
/// Consulted at all three places a segment gets its discipline: a bound port
/// (`resolveDiscipline`), an unconnected one, and a child's internal net. The
/// clause's example covers the last: "electrical top.middle.bottom.sig;
/// overrides any discipline which may be declared for sig in the module where
/// sig was declared" (`annex_f_resolution/out_of_context_internal_net.va`).
///
/// ponytail: an out-of-context declaration that matched nothing is not
/// diagnosed as an unmatched `defparam` is (E0907): from here it cannot be
/// told apart from a legal form this pass does not reach. The upgrade is a
/// `used` flag on `ooc`, like `Defparam.used`.
pub fn oocDiscipline(self: *Flatten, path: []const u8, local: Ast.StrId) ?Ast.StrId {
    return oocIn(&self.oocs.decls, self, path, local);
}

/// `oocDiscipline` over every declaration in the design, those in modules
/// below the level being planned included (`Flatten.tree_ooc`), for
/// `segment.up`.
pub fn oocDisciplineBelow(self: *Flatten, path: []const u8, local: Ast.StrId) ?Ast.StrId {
    return oocIn(&self.tree.ooc, self, path, local) orelse oocDiscipline(self, path, local);
}

/// §3.6.2: "It shall be an error to hierarchically override the discipline
/// of a net that was explicitly declared unless it is a compatible
/// discipline" (§3.11.1). Judged once per segment of `child`, the module
/// inlined at `path`: each port, and each net that is not a port's second
/// declaration. Reports E0375 at the out-of-context declaration.
///
/// An Annex E primitive's `electrical` is the placeholder E.3.2 resolves
/// past, not a declaration of the net, so its ports are not judged.
pub fn checkOocOverrides(self: *Flatten, child: *const Ast.ModuleDecl, path: []const u8) design.Error!void {
    if (lookup.isPrimitive(self, child)) return;
    for (child.ports) |p| try checkOocOverride(self, path, p.name, p.discipline);
    for (child.nets) |n| {
        if (declaresPort(child, n.name)) continue;
        try checkOocOverride(self, path, n.name, n.discipline);
    }
}

/// §3.6.3.2: "If different nets of a node have conflicting initializers, then
/// initializers on hierarchical net declarations win. If there are multiple
/// hierarchical declarations, then the declaration on the highest level
/// wins." A segment's flat net is the port binding's (`names`) or, for an
/// internal net, the key itself (`sep` is the path separator). The first
/// declaration at the shallowest level wins: §3.6.3.2 makes a tie a race,
/// and `collectOoc` order is the walk's.
pub fn applyOocInits(self: *Flatten) design.Error!void {
    for (self.oocs.inits.items, 0..) |o, i| {
        const flat = flatText(self, o.key);
        const beaten = for (self.oocs.inits.items, 0..) |q, j| {
            if (j == i) continue;
            if (!std.mem.eql(u8, flatText(self, q.key), flat)) continue;
            if (q.depth < o.depth or (q.depth == o.depth and j < i)) break true;
        } else false;
        if (beaten) continue;
        const name = try self.ctx.file.intern(self.ctx.arena, flat);
        var found = false;
        for (self.decls.nets.items) |*n| if (n.name == name) {
            n.init = o.init;
            found = true;
        };
        // An undeclared (implicit) net has no declaration to carry it.
        if (!found) try resolve.addNet(self, .{ .name = name, .init = o.init, .main_tok = self.ctx.file.exprs.mainTok(o.init) });
    }
}

// ---- private ----

/// The flat net segment `key` names: a connected port's net (`names`), else
/// the key itself. Spelled, not interned: only the winner is interned.
fn flatText(self: *const Flatten, key: []const u8) []const u8 {
    assert(key.len != 0);
    const id = self.out.names.get(key) orelse return key;
    return self.ctx.file.str(id);
}

fn oocIn(map: *const std.StringHashMapUnmanaged(OocDecl), self: *Flatten, path: []const u8, local: Ast.StrId) ?Ast.StrId {
    const d = map.getAdapted(flat_name.PathKey{ .path = path, .local = self.ctx.file.str(local) }, flat_name.PathKey.Context{}) orelse return null;
    return if (d.disc == .none) null else d.disc;
}

fn declaresPort(m: *const Ast.ModuleDecl, name: Ast.StrId) bool {
    for (m.ports) |p| if (p.name == name) return true;
    return false;
}

fn checkOocOverride(self: *Flatten, path: []const u8, local: Ast.StrId, declared: Ast.StrId) design.Error!void {
    if (declared == .none) return;
    const file = self.ctx.file;
    const o = self.oocs.decls.getAdapted(flat_name.PathKey{ .path = path, .local = file.str(local) }, flat_name.PathKey.Context{}) orelse return;
    if (o.disc == .none) return;
    const why = discipline.disciplineConflict(file, declared, o.disc) orelse return;
    try self.err(o.tok, .E0375, "`{s}{s}` is declared `{s}` and cannot be overridden with `{s}` ({s})", .{
        path, file.str(local), file.str(declared), file.str(o.disc), why,
    });
}

const fixture = @import("fixture.zig");

test isOoc {
    try std.testing.expect(isOoc("m.l.p"));
    try std.testing.expect(!isOoc("p"));
    try std.testing.expect(!isOoc(""));
}

test applyOocInits {
    // §3.6.3.2: "initializers on hierarchical net declarations win. If there
    // are multiple hierarchical declarations, then the declaration on the
    // highest level wins." `u.w` has a local nodeset 1.25 and the top's
    // hierarchical 2.75: 2.75. Node `n` has the top's own 1.25, the top's
    // `m.p = 2.75` (level 0) and mid's `v.q = 1.25` (level `m.`), all one
    // node after the joins: the top's hierarchical 2.75.
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\discipline electrical; domain continuous; enddiscipline
        \\module cub(g); inout g; electrical g; electrical w = 1.25; endmodule
        \\module leaf(q, g); inout q, g; electrical q, g; endmodule
        \\module mid(p, g); inout p, g; electrical p, g; leaf v(p, g); electrical v.q = 1.25; endmodule
        \\module top(g); inout g; electrical g; electrical n = 1.25;
        \\  cub u(g); mid m(n, g);
        \\  electrical u.w = 2.75; electrical m.p = 2.75;
        \\endmodule
    );
    const d = try elaborate.elaborate(f.ctx());
    const x = &f.file.exprs;
    try std.testing.expectEqual(@as(f64, 2.75), x.realValue(fixture.netNamed(&f.file, d.top, "u.w").?.init));
    try std.testing.expectEqual(@as(f64, 2.75), x.realValue(fixture.netNamed(&f.file, d.top, "n").?.init));
}
