//! §6.4 paramsets: an instance of a paramset name and its overrides → the
//! selected paramset (§6.4.2), the module at the end of its chain, and the
//! parameter values the paramset statements assign. LRM §3.4.2, §3.4.5,
//! §3.4.7, §6.3, §6.4, §6.4.1, §6.4.2, §6.4.3, §9.18, §9.19.

const std = @import("std");
const hier_param = @import("hier_param.zig");
const elaborate = @import("elaborate.zig");
const Flatten = elaborate.Flatten;
const elab_clone = @import("clone.zig");
const elab_names = @import("names.zig");
const Ast = @import("frontend").Ast;
const constfold = @import("frontend").constfold;
const Error = elaborate.Error;
const sep = elaborate.sep;
const Unit = Flatten.Unit;
const connectionFor = @import("instance.zig").connectionFor;
const elab_override = @import("override.zig");

// ---- §6.4 paramsets ---------------------------------------------------

/// Returns the paramset of an overload set this instance uses (§6.4.2), or
/// null after reporting E0904 (no paramset of that name), E0911 (none
/// admits the instance) or E0914 (still ambiguous after tie-breaking).
///
/// "Paramset identifiers need not be unique: multiple paramsets can be
/// declared using the same paramset_identifier ... During elaboration, the
/// simulator shall choose an appropriate paramset from the set that shares a
/// given name for every instance that references that name."
///
/// Two phases, from the clause. The selection rules ("the following rules
/// shall be enforced") cut the overload set down to the applicable paramsets
/// (`paramsetAdmits`). Then: "The rules above may not
/// be sufficient for the simulator to pick a unique paramset, in which case
/// the following rules shall be applied in order until a unique paramset
/// has been selected:"
///
///   1. "The paramset with the fewest number of un-overridden parameters
///      shall be selected." (§6.4.2's m3 example: the default paramset, l and
///      w both overridden, beats the long-channel one, ad and as defaulted.)
///   2. "The paramset with the greatest number of local parameters with
///      specified ranges shall be selected."
///   3. "The paramset with the fewest ports not connected in the instance
///      line shall be selected", over the target module's port list, since
///      same-named paramsets "may refer to different modules".
pub fn selectParamset(self: *Flatten, inst: *const Ast.Instance, path: []const u8) Error!?*const Ast.ParamsetDecl {
    var live: std.ArrayList(*const Ast.ParamsetDecl) = .empty;
    const candidates = try matchingParamsets(self, inst, path, &live);
    if (live.items.len == 0) {
        if (candidates == 0) {
            try elab_names.unknownModule(self, inst);
        } else {
            try self.err(inst.main_tok, .E0911, "`{s}`: no paramset named `{s}` admits these parameter values", .{
                self.ctx.file.str(inst.name), self.ctx.file.str(inst.module),
            });
        }
        return null;
    }
    if (live.items.len > 1) {
        try self.err(inst.main_tok, .E0914, "`{s}`: {d} paramsets named `{s}` are still applicable after §6.4.2's tie-breaking rules", .{
            self.ctx.file.str(inst.name), live.items.len, self.ctx.file.str(inst.module),
        });
        return null;
    }
    return live.items[0];
}

/// Shared by actual instantiation and §6.9.3 connect insertion. Both must see
/// the same effective overrides at the external instance path, before storage
/// is renamed to the internal `instance.paramset.parameter` namespace.
/// Asserts that `live` starts empty.
pub fn matchingParamsets(self: *Flatten, inst: *const Ast.Instance, path: []const u8, live: *std.ArrayList(*const Ast.ParamsetDecl)) Error!usize {
    std.debug.assert(live.items.len == 0);
    var count: usize = 0;
    for (self.ctx.file.paramsets) |ps| if (ps.name == inst.module) {
        count += 1;
    };
    const reads = if (count > 1) try self.ctx.arena.alloc(bool, self.params.items.len) else null;
    if (reads) |r| @memset(r, false);
    try live.ensureUnusedCapacity(self.ctx.arena, count);
    for (self.ctx.file.paramsets) |*ps| {
        if (ps.name == inst.module and try paramsetAdmits(self, inst, ps, path, reads))
            live.appendAssumeCapacity(ps);
    }
    if (reads) |r| for (r, self.params.items) |read, p| {
        if (read) try self.selection_params.append(self.ctx.arena, p.name);
    };
    // "applied in order until a unique paramset has been selected".
    for ([_]TieRule{ .un_overridden, .ranged_locals, .unconnected_ports }) |rule|
        if (live.items.len > 1) try tieBreak(self, inst, path, live, rule);
    std.debug.assert(live.items.len <= count);
    return count;
}

/// The three §6.4.2 tie-breaking rules, in the clause's order.
const TieRule = enum { un_overridden, ranged_locals, unconnected_ports };

/// Applies one tie-breaking rule: scores every surviving candidate and keeps
/// the minimum in `live` (a "greatest" rule negates its count).
fn tieBreak(
    self: *Flatten,
    inst: *const Ast.Instance,
    path: []const u8,
    live: *std.ArrayList(*const Ast.ParamsetDecl),
    rule: TieRule,
) Error!void {
    std.debug.assert(live.items.len > 1); // a unique paramset needs no tie-break
    const scores = try self.ctx.arena.alloc(i64, live.items.len);
    for (live.items, scores) |ps, *s| s.* = switch (rule) {
        // "the fewest number of un-overridden parameters": the paramset's
        // overridable parameters the instance left at their defaults. A
        // localparam is not overridable (§3.4.5), and §6.4.2's neighbouring
        // rules count "parameters" and "local parameters" separately.
        .un_overridden => blk: {
            var n: i64 = 0;
            for (ps.params, 0..) |p, i| {
                if (p.is_local) continue;
                n += @intFromBool(try elab_override.parameterBinding(self, inst, ps.params, ps.aliasparams, i, path, false) == null);
            }
            break :blk n;
        },
        // "the greatest number of local parameters with specified ranges",
        // negated.
        .ranged_locals => blk: {
            var n: i64 = 0;
            for (ps.params) |p| n += @intFromBool(p.is_local and p.ranges.len != 0);
            break :blk -n;
        },
        // "the fewest ports not connected in the instance line". A target
        // module the file never declares scores worst; if such a candidate
        // is selected anyway, E0904 names it at the use site.
        .unconnected_ports => blk: {
            const child = elab_names.findModule(self, ps.target) orelse break :blk std.math.maxInt(i64);
            var n: i64 = 0;
            for (child.ports, 0..) |p, i| {
                const conn = connectionFor(inst, p, i);
                n += @intFromBool(conn == null or conn.?.expr == .none);
            }
            break :blk n;
        },
    };
    const best = std.mem.min(i64, scores);
    var w: usize = 0;
    for (live.items, scores) |ps, s| if (s == best) {
        live.items[w] = ps;
        w += 1;
    };
    // The best score is some candidate's, so it survives.
    std.debug.assert(w != 0);
    live.shrinkRetainingCapacity(w);
}

/// Whether an external override names a public parameter of this candidate.
/// §6.4 hides unexposed parameters of the underlying module; §3.4.5 excludes
/// localparams. System parameters (and their aliases) keep §9.18's binding.
fn exposes(self: *Flatten, ps: *const Ast.ParamsetDecl, name: []const u8) bool {
    if (hier_param.Kind.fromName(name) != null) return true;
    for (ps.params) |p| if (!p.is_local and std.mem.eql(u8, self.ctx.file.str(p.name), name)) return true;
    for (ps.aliasparams) |al| {
        if (!std.mem.eql(u8, self.ctx.file.str(al.alias), name)) continue;
        if (hier_param.Kind.fromName(self.ctx.file.str(al.target)) != null) return true;
        for (ps.params) |p| if (!p.is_local and p.name == al.target) return true;
    }
    return false;
}

/// Returns whether `ps` passes §6.4.2's selection rules for `inst` ("When
/// choosing an appropriate paramset, the following rules shall be
/// enforced"), as far as each is decidable here. Reports nothing.
///
///   1. "All parameters overridden on the instance shall be parameters of
///      the paramset", and §3.4.5 keeps a localparam out of an override's
///      reach in either spelling.
///   2. "The parameters of the paramset, with overrides and defaults, shall
///      be all within the allowed ranges specified in the paramset
///      parameter declaration": this is what makes a binned set select on
///      geometry.
///   3. "The local parameters of the paramset, computed from parameters,
///      shall be within the allowed ranges specified in the paramset":
///      judged as far as `constReal` folds (see `inRanges`).
///   4. "The underlying module shall have a port declared for each port
///      connected in the instance line." An undeclared target module cannot
///      fail it; that is E0904 at the use site.
fn paramsetAdmits(self: *Flatten, inst: *const Ast.Instance, ps: *const Ast.ParamsetDecl, path: []const u8, reads: ?[]bool) Error!bool {
    const named = inst.params.len != 0 and inst.params[0].name != .none;
    if (!named and inst.params.len > elab_override.overridableCount(ps.params)) return false;
    if (named) for (inst.params) |o| {
        if (!exposes(self, ps, self.ctx.file.str(o.name))) return false;
    };
    var it = self.defparams.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.startsWith(u8, key, path)) continue;
        const name = key[path.len..];
        // A path into a descendant names that descendant's own parameters,
        // not an additional parameter of the paramset instance.
        if (std.mem.findScalar(u8, name, sep) != null) continue;
        if (!exposes(self, ps, name)) return false;
    }
    const bindings = try self.ctx.arena.alloc(?elab_override.ParamBinding, ps.params.len);
    for (bindings, 0..) |*b, i| b.* = try elab_override.parameterBinding(self, inst, ps.params, ps.aliasparams, i, path, false);
    const env: ParamsetEnv = .{ .self = self, .ps = ps, .bindings = bindings, .reads = reads };
    for (ps.params, 0..) |p, i| {
        if (p.ranges.len != 0 and !inRanges(self, env.value(i), p.ranges, env)) return false;
    }
    // Criterion 4, both connection spellings. A mixed or malformed list is
    // E0906 after selection (`checkConnectionShape`).
    if (elab_names.findModule(self, ps.target)) |child| {
        const conns_named = inst.ports.len != 0 and inst.ports[0].name != .none;
        if (conns_named) {
            for (inst.ports) |c| {
                if (c.name == .none) continue;
                const found = for (child.ports) |p| {
                    if (p.connName() == c.name) break true;
                } else false;
                if (!found) return false;
            }
        } else if (inst.ports.len > child.ports.len) return false;
    }
    return true;
}

/// §3.4.2 does this value satisfy the declared `from`/`exclude` ranges?
///
/// ponytail: a value or a bound this cannot fold counts as admissible, so a
/// missing folder never becomes a selection error; `Lower` still judges the
/// value it ends up with (E0361).
fn inRanges(self: *Flatten, value: ?constfold.Const, ranges: []const Ast.ValueRange, env: ParamsetEnv) bool {
    if (ranges.len == 0) return true;
    // §3.4.2: "Valid values of string parameters are indicated differently.
    // The `from` keyword may be used with a list of valid string values, or
    // the `exclude` keyword may be used with a list of invalid string
    // values." A.2.5's `value_range_type '{ string {, string} }`, parsed
    // into `ValueRange.strings`. Without this arm a binned set keyed on a
    // string (§3.4.6's `ebersmoll` mapping) admits every bin.
    const c = value orelse return true;
    if (c == .str) return strInRanges(self, c.str, ranges);
    const v = c.asReal();
    var has_from = false;
    var in_from = false;
    for (ranges) |r| {
        if (r.strings != null) continue;
        const lo = (constfold.fold(self.ctx.file, r.lo, env) orelse return true).asReal();
        const hi = if (r.hi == .none) lo else (constfold.fold(self.ctx.file, r.hi, env) orelse return true).asReal();
        const above = if (r.lo_inclusive) v >= lo else v > lo;
        const below = if (r.hi_inclusive) v <= hi else v < hi;
        switch (r.kind) {
            .from => {
                has_from = true;
                if (above and below) in_from = true;
            },
            .exclude => if (above and below) return false,
        }
    }
    return !has_from or in_from;
}

/// §6.4.2 defaults and localparams see the candidate's effective parameters,
/// while an inline override and a defparam retain their respective scopes.
const ParamsetEnv = struct {
    self: *Flatten,
    ps: *const Ast.ParamsetDecl,
    bindings: []const ?elab_override.ParamBinding,
    reads: ?[]bool,
    depth: usize = 0,

    fn value(env: ParamsetEnv, i: usize) ?constfold.Const {
        // Acyclic parameter defaults visit at most one declaration per level.
        // A cycle remains lowering's diagnostic, not infinite recursion here.
        if (env.depth >= env.ps.params.len) return null;
        const p = env.ps.params[i];
        const raw = if (env.bindings[i]) |b|
            elab_names.constValue(env.self, b.value, !b.flat, env.reads)
        else blk: {
            var next = env;
            next.depth += 1;
            break :blk constfold.fold(env.self.ctx.file, p.default, next);
        };
        return constfold.parameterValue(p.ty, raw orelse return null);
    }

    /// Resolves an identifier naming one of the candidate's parameters to
    /// its effective value; anything else declines.
    pub fn leaf(env: ParamsetEnv, e: Ast.ExprId) ?constfold.Const {
        const ex = &env.self.ctx.file.exprs;
        if (ex.tag(e) != .ident) return null;
        for (env.ps.params, 0..) |p, i| if (p.name == ex.strOf(e)) return env.value(i);
        return null;
    }
    /// Leaves operand signedness unknown.
    pub fn signed(_: ParamsetEnv, _: Ast.ExprId) ?bool {
        return null;
    }
    /// Leaves a parameter's width unknown.
    pub fn width(_: ParamsetEnv, _: Ast.ExprId) ?u32 {
        return null;
    }
};

/// The string half of `inRanges`: membership in a `'{ ... }` set, union over
/// the `from` clauses, any `exclude` hit fatal, as lowering's
/// `checkParamRange` judges it. Returns a verdict instead of a diagnostic,
/// because here a non-member only means "this bin is not the one".
fn strInRanges(self: *Flatten, s: []const u8, ranges: []const Ast.ValueRange) bool {
    var has_from = false;
    var in_from = false;
    for (ranges) |r| {
        const off = r.strings orelse continue;
        const contains = for (self.ctx.file.exprs.list(off)) |id| {
            if (std.mem.eql(u8, s, self.ctx.file.str(@fromBackingInt(@intCast(id))))) break true;
        } else false;
        switch (r.kind) {
            .from => {
                has_from = true;
                in_from = in_from or contains;
            },
            .exclude => if (contains) return false,
        }
    }
    return !has_from or in_from;
}

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
) Error!void {
    const ps_path = try self.ctx.arena.print("{s}{s}{c}", .{ path, self.ctx.file.str(ps.name), sep });

    // §6.4's chain, near to far. `chainEnd` already walked it to find
    // `child`, so this cannot fail here.
    var chain: std.ArrayList(*const Ast.ParamsetDecl) = .empty;
    const reaches = try elab_names.paramsetChain(self, ps, &chain);
    std.debug.assert(reaches);
    std.debug.assert(chain.items[0] == ps);

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
    try elab_override.collectOverrides(self, inst, &as_module, parent, &ps_over, &ps_unit, path);
    for (ps.params) |p| try elab_names.bind(self, &ps_unit, ps_path, p.name);
    for (ps.aliasparams) |al| try elab_names.bind(self, &ps_unit, ps_path, al.alias);

    const saved = self.unit;
    self.unit = ps_unit;
    // Everything cloned from here to the restore is paramset-body text;
    // the instance's override values (`ps_over`) were cloned above, in the
    // parent's scope.
    self.in_paramset = true;
    try elab_clone.cloneParams(self, ps.params, ps.aliasparams, &ps_over);

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
        for (link.params) |p| try elab_names.bind(self, u, link_path, p.name);
        for (link.aliasparams) |al| try elab_names.bind(self, u, link_path, al.alias);
        self.unit = u.*;
        try elab_clone.cloneParams(self, link.params, link.aliasparams, &no_over);
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
                if (system == null and !try elab_override.checkOverridable(self, child, target, o.name, o.main_tok)) continue;
                // §6.4.1 "these variables shall not be used to assign values
                // to the module's parameters". Named here, where the paramset
                // is still in hand: once cloned, `t` is only an unknown name.
                if (readsVar(self.ctx.file, chain.items[i], o.value)) |v| {
                    try self.err(self.ctx.file.exprs.mainTok(v), .E0237, "`.{s} = ...` reads the paramset variable `{s}`, and paramset variables shall not assign the module's parameters", .{
                        self.ctx.file.str(o.name), self.ctx.file.str(self.ctx.file.exprs.strOf(v)),
                    });
                    continue;
                }
                const value = try elab_clone.cloneExpr(self, o.value);
                if (system) |kind| {
                    if (try elab_override.checkSystemParam(self, kind, o.main_tok, value, path)) continue;
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
                const value = try elab_clone.cloneExpr(self, o.value);
                if (try elab_override.checkSystemParam(self, kind, o.main_tok, value, path)) continue;
                hier.set(kind, try hier_param.compose(kind, self.ctx.file, self.ctx.arena, hier.get(kind), value, o.main_tok));
            },
        };
    }
    try paramsetStatements(self, chain.items, units, child, path, stmts);
    self.in_paramset = false;
    self.unit = saved;

    unit.hier = hier;
    try elab_override.markGiven(self, child, over, unit);
}

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
) Error!void {
    std.debug.assert(units.len == chain.len); // one unit per link
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
        for (link.vars) |v| try self.unit.rename.put(self.ctx.arena, v.name, try elab_names.join(self, link_path, v.name));
        for (link.vars) |v| {
            const out = try elab_clone.cloneVar(self, v);
            try self.vars.append(self.ctx.arena, out);
            if (v.desc) try self.ps_outputs.append(self.ctx.arena, .{
                .report = try self.ctx.arena.print("{s}{s}", .{ path, file.str(v.name) }),
                .flat = file.str(out.name),
            });
        }
        for (link.body) |st| try stmts.append(self.ctx.arena, try elab_clone.cloneStmt(self, st));
    }
}

/// Binds §6.4.3's `.name` (the parser's spelling, `parsePrimary`) to the
/// instance's `name`. Interned only where a statement wrote it.
fn bindDotted(self: *Flatten, path: []const u8, name: Ast.StrId) Error!void {
    const dotted = self.ctx.file.strings.find(try self.ctx.arena.print(".{s}", .{self.ctx.file.str(name)})) orelse return;
    try self.unit.rename.put(self.ctx.arena, dotted, try elab_names.join(self, path, name));
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const fixture = @import("fixture.zig");

test "§6.4.2 ties: the greatest number of ranged localparams, then the fewest unconnected ports; still tied is E0914" {
    // Rule 1 ties both pairs below (each leaves its one parameter `l` at its
    // default). Rule 2 then picks the paramset whose localparam has a range.
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\module top(p); inout p; electrical p; bin u(p); endmodule
        \\paramset bin base; parameter real l = 1.0; .k = 10.0; endparamset
        \\paramset bin base; parameter real l = 1.0; localparam real lp = 1.0 from [0:2]; .k = 20.0; endparamset
        \\module base(a); inout a; electrical a; parameter real k = 0.0; endmodule
    );
    const d = try elaborate.elaborate(f.ctx());
    try std.testing.expectEqual(@as(f64, 20.0), f.file.exprs.realValue(fixture.paramNamed(&f.file, d.top, "u.k").?.default));

    // Rules 1 and 2 tie; rule 3 counts the target module's ports the
    // instance leaves unconnected: `two`'s `b` is, `one` has no other.
    var g: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer g.deinit();
    try fixture.parse(&g,
        \\module top(p); inout p; electrical p; bin u(p); endmodule
        \\paramset bin two; parameter real l = 1.0; .k = 10.0; endparamset
        \\paramset bin one; parameter real l = 1.0; .k = 20.0; endparamset
        \\module two(a, b); inout a, b; electrical a, b; parameter real k = 0.0; endmodule
        \\module one(a); inout a; electrical a; parameter real k = 0.0; endmodule
    );
    const dg = try elaborate.elaborate(g.ctx());
    try std.testing.expectEqualStrings("one", dg.units[1].module);
    try std.testing.expectEqual(@as(f64, 20.0), g.file.exprs.realValue(fixture.paramNamed(&g.file, dg.top, "u.k").?.default));

    // Two indistinguishable paramsets survive every rule.
    var h: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer h.deinit();
    try fixture.parse(&h,
        \\module top(p); inout p; electrical p; bin u(p); endmodule
        \\paramset bin base; parameter real l = 1.0; .k = 10.0; endparamset
        \\paramset bin base; parameter real l = 1.0; .k = 20.0; endparamset
        \\module base(a); inout a; electrical a; parameter real k = 0.0; endmodule
    );
    try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(h.ctx()));
    try std.testing.expect(fixture.hasCode(&h.bag, .E0914));
}
