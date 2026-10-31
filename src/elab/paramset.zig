//! §6.4 paramset instances: the selected paramset, its chain and the
//! instance's overrides → the paramset's own parameters as localparams, the
//! module parameter values its statements assign, and its variables and
//! statements (§6.4.1, §6.4.3).
//! Cites: LRM §6.3, §6.3.6, §6.4, §6.4.1, §6.4.3, §9.18, §9.19.
//!
//! Contents:
//! - `pub fn paramsetOverrides(...)`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const design = @import("design.zig");
const Flatten = @import("Flatten.zig");
const clone_decl = @import("clone_decl.zig");
const clone_expr = @import("clone_expr.zig");
const clone_stmt = @import("clone_stmt.zig");
const flat_name = @import("flat_name.zig");
const lookup = @import("lookup.zig");
const override = @import("override.zig");
const hier_param = @import("hier_param.zig");
const sep = design.sep;
const Unit = Flatten.Unit;

/// Computes the module parameter values a paramset instance gives `child`
/// into `over`, and sets `unit`'s §9.18 hierarchical values and §9.19 `$param_given`
/// (§6.4). Two levels: the instance overrides the paramset's own parameters,
/// then the paramset's statements compute the module's from those, so
/// `.k = 2.0 * gain;` with `#(.gain(3.0))` gives `k` = 6.0.
///
/// The paramset's own parameters become localparams under
/// `path ++ paramset_name ++ sep`, so `u.gain` stays the module's parameter
/// and `u.ch6_ps.gain` is the paramset's.
///
/// Asserts that `ps`'s §6.4 chain reaches a module, as the walk's
/// `chainEnd` established before inlining.
pub fn paramsetOverrides(
    self: *Flatten,
    inst: *const Ast.Instance,
    ps: *const Ast.ParamsetDecl,
    child: *const Ast.ModuleDecl,
    parent: *const Unit,
    over: *std.AutoHashMapUnmanaged(Ast.StrId, Ast.ExprId),
    unit: *Unit,
    path: []const u8,
    /// Receives the chain's paramset statements, cloned, for `inlineInstance`
    /// to run after the module's analog blocks.
    stmts: *std.ArrayList(Ast.StmtId),
) design.Error!void {
    const ps_path = try self.ctx.arena.print("{s}{s}{c}", .{ path, self.ctx.file.str(ps.name), sep });

    // §6.4's chain, near to far. `chainEnd` already walked it to find
    // `child`, so this cannot fail here.
    var chain: std.ArrayList(*const Ast.ParamsetDecl) = .empty;
    const reaches = try lookup.paramsetChain(self, ps, &chain);
    assert(reaches);
    assert(chain.items[0] == ps);

    // ---- level 1: the paramset's own parameters, overridden by the instance
    var ps_unit: Unit = .{ .hier = parent.hier };
    var ps_over: std.AutoHashMapUnmanaged(Ast.StrId, Ast.ExprId) = .empty;
    // A synthesized instance of the paramset-as-unit: same overrides, no
    // ports, so `collectOverrides` handles §6.3's ordered/named arms,
    // §3.4.7's aliases and §9.18's system overrides for it.
    const as_module: Ast.ModuleDecl = .{
        .name = ps.name,
        .ports = &.{},
        .params = ps.params,
        .aliasparams = ps.aliasparams,
        .main_tok = ps.main_tok,
    };
    try override.collectOverrides(self, inst, &as_module, parent, &ps_over, &ps_unit, path);
    for (ps.params) |p| try flat_name.bind(self, &ps_unit, ps_path, p.name);
    for (ps.aliasparams) |al| try flat_name.bind(self, &ps_unit, ps_path, al.alias);

    const saved = self.unit;
    self.unit = ps_unit;
    // Everything cloned from here to the restore is paramset-body text;
    // the instance's override values (`ps_over`) were cloned above, in the
    // parent's scope.
    self.in_paramset = true;
    try clone_decl.cloneParams(self, ps.params, ps.aliasparams, &ps_over);

    // §6.4.1 "The right-hand side can be composed of numbers, parameters,
    // ...": each link's statements read that link's own parameters. Only the
    // near link is named by an instance, so only its parameters take a §6.3
    // override; a farther link's are its defaults, localparams under
    // `path ++ link ++ sep` as the near link's are under `ps_path`. One unit
    // per link, near first, each statement cloned in its own link's.
    const units = try self.ctx.arena.alloc(Unit, chain.items.len);
    units[0] = self.unit;
    const no_over: std.AutoHashMapUnmanaged(Ast.StrId, Ast.ExprId) = .empty;
    for (chain.items[1..], units[1..]) |link, *u| {
        const link_path = try self.ctx.arena.print("{s}{s}{c}", .{ path, self.ctx.file.str(link.name), sep });
        u.* = .{ .hier = ps_unit.hier };
        for (link.params) |p| try flat_name.bind(self, u, link_path, p.name);
        for (link.aliasparams) |al| try flat_name.bind(self, u, link_path, al.alias);
        self.unit = u.*;
        try clone_decl.cloneParams(self, link.params, link.aliasparams, &no_over);
        u.* = self.unit;
    }

    // ---- level 2: the module's parameters, from the paramsets' statements
    //
    // §6.4's chain, applied far link first so a nearer link's assignment to
    // the same module parameter wins. §6.4 gives no precedence rule;
    // nearest-wins treats the near link as the more specific one, as §6.3
    // ranks an instance override over a default.
    var hier = ps_unit.hier;
    var i = chain.items.len;
    while (i > 0) {
        i -= 1;
        self.unit = units[i];
        defer units[i] = self.unit;
        for (chain.items[i].overrides) |o| switch (o.kind) {
            .module_param => {
                var target = o.name;
                for (child.aliasparams) |al| if (al.alias == o.name) {
                    target = al.target;
                    break;
                };
                const system = hier_param.Kind.fromName(self.ctx.file.str(target));
                if (system == null and !try override.checkOverridable(self, child, target, o.name, o.main_tok)) continue;
                // §6.4.1 "these variables shall not be used to assign values
                // to the module's parameters". Named here, where the paramset
                // is still in hand: once cloned, `t` is only an unknown name.
                if (readsVar(self.ctx.file, chain.items[i], o.value)) |v| {
                    try self.err(self.ctx.file.exprs.mainTok(v), .E0237, "`.{s} = ...` reads the paramset variable `{s}`, and paramset variables shall not assign the module's parameters", .{
                        self.ctx.file.str(o.name), self.ctx.file.str(self.ctx.file.exprs.strOf(v)),
                    });
                    continue;
                }
                const value = try clone_expr.cloneExpr(self, o.value);
                if (system) |kind| {
                    if (try override.checkSystemParam(self, kind, o.main_tok, value, path)) continue;
                    hier.set(kind, try hier_param.compose(kind, self.ctx.file, self.ctx.arena, hier.get(kind), value, o.main_tok));
                } else try over.put(self.ctx.arena, target, value);
            },
            // §6.3.6/§9.18: a paramset's system assignment composes with
            // the value inherited by this paramset instance, just as #(...).
            .system_param => {
                const kind = hier_param.Kind.fromName(self.ctx.file.str(o.name)) orelse {
                    try self.err(o.main_tok, .E0907, "`{s}` is not a hierarchical system parameter", .{self.ctx.file.str(o.name)});
                    continue;
                };
                if (readsVar(self.ctx.file, chain.items[i], o.value)) |v| {
                    try self.err(self.ctx.file.exprs.mainTok(v), .E0237, "`.{s} = ...` reads the paramset variable `{s}`", .{
                        self.ctx.file.str(o.name), self.ctx.file.str(self.ctx.file.exprs.strOf(v)),
                    });
                    continue;
                }
                const value = try clone_expr.cloneExpr(self, o.value);
                if (try override.checkSystemParam(self, kind, o.main_tok, value, path)) continue;
                hier.set(kind, try hier_param.compose(kind, self.ctx.file, self.ctx.arena, hier.get(kind), value, o.main_tok));
            },
        };
    }
    try paramsetStatements(self, chain.items, units, child, path, stmts);
    self.in_paramset = false;
    self.unit = saved;

    unit.hier = hier;
    try override.markGiven(self, child, over, unit);
}

// ---- private ----

/// §6.4.1: "Paramset statements may assign values to variables declared in
/// the paramset; the values need not be constant expressions. ... Paramset
/// variables may be used to provide output variables (see 6.4.3)." Each
/// link's variables are declared under `path ++ link ++ sep` (where its
/// parameters are) and its statements cloned into `stmts`, far link first
/// as the module assignments are; a described variable is reported as the
/// instance's own (`Design.ps_outputs`). §6.4.3's `.gm` reads the module's
/// `gm` of this instance. Each link's statements run in its own unit
/// (`units`, parallel to `chain`), so they read that link's parameters.
fn paramsetStatements(
    self: *Flatten,
    chain: []const *const Ast.ParamsetDecl,
    units: []Unit,
    child: *const Ast.ModuleDecl,
    path: []const u8,
    stmts: *std.ArrayList(Ast.StmtId),
) design.Error!void {
    assert(units.len == chain.len); // one unit per link
    const file = self.ctx.file;
    var any = false;
    for (chain) |link| any = any or link.body.len != 0 or link.vars.len != 0;
    if (!any) return;
    var i = chain.len;
    while (i > 0) {
        i -= 1;
        const link = chain[i];
        self.unit = units[i];
        defer units[i] = self.unit;
        for (child.vars) |v| try bindDotted(self, path, v.name);
        for (child.params) |p| try bindDotted(self, path, p.name);
        const link_path = try self.ctx.arena.print("{s}{s}{c}", .{ path, file.str(link.name), sep });
        for (link.vars) |v| try self.unit.rename.put(self.ctx.arena, v.name, try flat_name.join(self, link_path, v.name));
        for (link.vars) |v| {
            const out = try clone_decl.cloneVar(self, v);
            try self.decls.vars.append(self.ctx.arena, out);
            if (v.desc) try self.out.ps_outputs.append(self.ctx.arena, .{
                .report = try self.ctx.arena.print("{s}{s}", .{ path, file.str(v.name) }),
                .flat = out.name,
            });
        }
        for (link.body) |st| try stmts.append(self.ctx.arena, try clone_stmt.cloneStmt(self, st));
    }
}

/// Binds §6.4.3's `.name` (the parser's spelling, `parsePrimary`) to the
/// instance's `name`. Interned only where a statement wrote it.
fn bindDotted(self: *Flatten, path: []const u8, name: Ast.StrId) design.Error!void {
    assert(name != .none);
    assert(path.len != 0);
    const dotted = self.ctx.file.strings.find(try self.ctx.arena.print(".{s}", .{self.ctx.file.str(name)})) orelse return;
    try self.unit.rename.put(self.ctx.arena, dotted, try flat_name.join(self, path, name));
}

/// §6.4.1 the first identifier in `e` that names one of `ps`'s variables.
fn readsVar(file: *const Ast.SourceFile, ps: *const Ast.ParamsetDecl, e: Ast.ExprId) ?Ast.ExprId {
    if (e == .none) return null;
    const x = &file.exprs;
    if (x.tag(e) == .ident) for (ps.vars) |v| {
        if (v.name == x.strOf(e)) return e;
    };
    var buf: [3]Ast.ExprId = undefined;
    for (x.children(e, &buf)) |c| if (readsVar(file, ps, c)) |hit| return hit;
    return null;
}
