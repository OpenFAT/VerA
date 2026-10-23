//! §6.3 parameter overrides: an instance's `#(...)` list and the §6.3.1
//! defparams collected on the way down → the child's override map (`over`),
//! its §9.18 hierarchical system-parameter values and its §9.19
//! `$param_given` answers. Owns `Flatten.defparams`. LRM §3.4.4, §3.4.5,
//! §3.4.7, §6.3, §6.3.1, §6.3.3, §9.18 Table 9-29, §9.19; IEEE 1364-2005
//! §12.2.1, §12.2.2.2, §12.6, §12.8.1.

const std = @import("std");
const hier_param = @import("hier_param.zig");
const elaborate = @import("elaborate.zig");
const Flatten = elaborate.Flatten;
const Unit = Flatten.Unit;
const Error = elaborate.Error;
const elab_clone = @import("clone.zig");
const PathKey = @import("names.zig").PathKey;
const Ast = @import("frontend").Ast;
const constfold = @import("frontend").constfold;

/// One collected §6.3.1 override, in `Flatten.defparams`.
pub const Defparam = struct {
    /// Already cloned, in the DECLARING module's namespace (§6.3.1: "a constant
    /// expression involving ... parameters declared in the same module as the
    /// defparam statement").
    value: Ast.ExprId,
    tok: u32,
    /// §6.3.1 a path that named no parameter of the elaborated design is E0907,
    /// and this is how that is noticed: nothing ever claimed it.
    used: bool = false,
    /// IEEE 1364-2005 §12.8.1: collected by a first walk (`seedDefparams`),
    /// so it is in force before the walk that binds its target reaches it.
    seeded: bool = false,
    /// A seeded defparam's declaring site was reached again by this walk.
    collected: bool = false,
};

comptime {
    // One row per defparam statement in the instance tree; 12 B budget.
    std.debug.assert(@sizeOf(Defparam) == 12);
}

/// Records `module`'s §6.3.1 defparams, at its instance prefix `path`, before
/// any child is inlined: a defparam applies downward, and the parameters it
/// overrides are created as those instances are. Under a §6.4 paramset
/// instance a defparam overrides nothing; it lands in
/// `Flatten.paramset_defparams` for lowering to judge. Asserts that `path`
/// is empty (the top) or ends in `sep`.
pub fn collectDefparams(self: *Flatten, module: *const Ast.ModuleDecl, path: []const u8) Error!void {
    for (module.defparams) |dp| {
        if (self.unit.paramset_instance) |instance| {
            try self.paramset_defparams.append(self.ctx.arena, .{
                .main_tok = dp.main_tok,
                .instance = instance,
                .gate = self.unit.gate,
            });
            // An active site is illegal; an inactive site's hierarchy
            // does not exist. Neither may override a child parameter.
            continue;
        }
        const key = try defparamKey(self, module, path, self.ctx.file.str(dp.path));
        const gop = try self.defparams.getOrPut(self.ctx.arena, key);
        if (gop.found_existing and gop.value_ptr.seeded) {
            // The first walk's last value for this key is already in force
            // (§12.2.1: "the last defparam statement encountered"); reaching
            // the site again only confirms it still exists.
            gop.value_ptr.collected = true;
            continue;
        }
        gop.value_ptr.* = .{
            .value = try elab_clone.cloneExpr(self, dp.value),
            .tok = dp.main_tok,
        };
    }
}

/// Whether some module's defparam may name a parameter the one-pass flatten
/// binds before reaching it: a path whose first identifier is not one of
/// that module's own instances (IEEE 1364-2005 §12.6's upward forms, a
/// generate block's, or the module's own parameter). Over-approximate: such
/// a design pays for `seedDefparams`' second walk.
pub fn mayBindEarly(file: *const Ast.SourceFile) bool {
    for (file.userModules()) |*m| for (m.defparams) |dp| {
        const text = file.str(dp.path);
        const dot = std.mem.findScalar(u8, text, elaborate.sep) orelse return true;
        for (m.instances) |inst| {
            if (std.mem.eql(u8, file.str(inst.name), text[0..dot])) break;
        } else return true;
    };
    return false;
}

/// IEEE 1364-2005 §12.8.1 b): "any defparam statement whose target can be
/// resolved within the hierarchy elaborated so far must have its target
/// resolved and its value applied" before parameters take their final
/// values. The flatten binds an instance's parameters as it inlines it, so a
/// defparam to an ancestor, to the declaring instance or to a sibling
/// written earlier is reached after its target was bound. `first` is a
/// complete walk of the same design: every defparam it collected, with its
/// key and its last value, is in force from the start of this one.
pub fn seedDefparams(self: *Flatten, first: *const Flatten) Error!void {
    var it = first.defparams.iterator();
    while (it.next()) |dp| {
        var row = dp.value_ptr.*;
        row.used = false;
        row.seeded = true;
        row.collected = false;
        try self.defparams.put(self.ctx.arena, dp.key_ptr.*, row);
    }
    self.seed_params = first.params.items;
}

/// §6.3.1 on the top's own parameters: a seeded defparam (`seedDefparams`)
/// naming one replaces its value, and the parameter becomes local: "the
/// parameter in the module shall take the value specified by the defparam",
/// so the host's model card, which stands where an instance override would,
/// no longer sets it. Runs once the top's parameters are `self.params`.
pub fn applyTopDefparams(self: *Flatten) Error!void {
    if (self.defparams.count() == 0) return;
    for (self.params.items) |*p| {
        if (p.is_local) continue;
        const local = self.ctx.file.str(p.name);
        const dp = self.defparams.getPtrAdapted(PathKey{ .path = "", .local = local }, PathKey.Context{}) orelse continue;
        const value = try seededValue(self, "", local, dp) orelse continue;
        dp.used = true;
        p.default = value;
        p.is_override = true;
        p.is_local = true;
    }
}

/// A.9.3's `$root . path`, written anywhere: §6.2.1 "used to unambiguously
/// refer to a top-level instance or to an instance path starting from the
/// root of the instantiation tree". The flattened namespace is rooted at the
/// device, the one top-level instance, so `$root.<top>.` drops. A path that
/// does not open with the top's name keeps its `$root.` spelling, which
/// names nothing (E0907 for a defparam). Null when `p` has no `$root.`.
pub fn rootedPath(self: *const Flatten, p: []const u8) ?[]const u8 {
    const root = "$root" ++ [_]u8{elaborate.sep};
    if (!std.mem.startsWith(u8, p, root)) return null;
    const rest = p[root.len..];
    const top = for (self.unit_paths.items) |u| {
        if (u.path.len == 0) break u.module;
    } else return p;
    if (rest.len > top.len and rest[top.len] == elaborate.sep and std.mem.startsWith(u8, rest, top)) return rest[top.len + 1 ..];
    return p;
}

/// The first identifier `e` reads that names no parameter the flat module
/// declares yet, or null. Lowering reads the flat parameters in order, so a
/// defparam value applied before its declaring instance is inlined may read
/// only those.
fn readsUndeclared(self: *Flatten, e: Ast.ExprId) ?Ast.ExprId {
    if (e == .none) return null;
    const x = &self.ctx.file.exprs;
    if (x.tag(e) == .ident) {
        const name = x.strOf(e);
        for (self.params.items) |p| if (p.name == name) return null;
        for (self.aliasparams.items) |a| if (a.alias == name) return null;
        return e;
    }
    var buf: [3]Ast.ExprId = undefined;
    for (x.children(e, &buf)) |c| if (readsUndeclared(self, c)) |hit| return hit;
    return null;
}

/// The value seeded defparam `dp` (key `path ++ local`) applies now. Its
/// value was cloned in the declaring instance's names, and that instance may
/// not be inlined yet (an upward defparam). IEEE 1364-2005 §12.2.1 lets it
/// read "only numbers and references to parameters ... declared in the same
/// module as the defparam statement", so each parameter it reads that the
/// flat module does not declare yet is replaced by that parameter's final
/// expression: the value another seeded defparam gives it, else its value in
/// the first walk (`seed_params`), which is an expression in flat names and so
/// the same in this one. Null after E0907, when no such value exists or the
/// replacements never end: a value that reads, through those parameters,
/// itself (a defparam whose value reads its own target), named as the cycle.
/// Any chain without one is followed to its end.
pub fn seededValue(self: *Flatten, path: []const u8, local: []const u8, dp: *Defparam) Error!?Ast.ExprId {
    if (!dp.seeded or dp.collected) return dp.value;
    if (try substitutionCycle(self, dp.value)) |names| {
        dp.used = true;
        try self.err(dp.tok, .E0907, "`{s}{s}` is applied before its declaring instance is elaborated, and its value reads the cycle {s}, which no replacement ends (IEEE 1364-2005 12.8.1)", .{ path, local, names });
        return null;
    }
    // Acyclic, so this ends: each replacement trades a name for names
    // strictly further down a finite graph.
    var v = dp.value;
    while (readsUndeclared(self, v)) |hit| {
        const name = self.ctx.file.exprs.strOf(hit);
        const with = seedValueOf(self, name) orelse {
            dp.used = true;
            try self.err(dp.tok, .E0907, "`{s}{s}` is applied before its declaring instance is elaborated, and its value reads `{s}`, which names no parameter of the elaborated design (IEEE 1364-2005 12.8.1)", .{ path, local, self.ctx.file.str(name) });
            return null;
        };
        v = try @import("instance.zig").substIdent(self, v, name, with);
    }
    return v;
}

/// The cycle `seededValue`'s replacements would run round from `e`, named
/// parameter by parameter (`` `a` → `b` → `a` ``), or null. A depth-first
/// walk over "the final expression of `a` reads `b`", on a heap stack.
fn substitutionCycle(self: *Flatten, e: Ast.ExprId) Error!?[]const u8 {
    const Frame = struct { name: Ast.StrId, reads: []const Ast.StrId, next: usize = 0 };
    // true while on the walk's path, false once every name below is done.
    var on_path: std.AutoHashMapUnmanaged(Ast.StrId, bool) = .empty;
    var stack: std.ArrayList(Frame) = .empty;
    const a = self.ctx.arena;
    for (try undeclaredReads(self, e)) |root| {
        if (on_path.contains(root)) continue;
        try on_path.put(a, root, true);
        try stack.append(a, .{ .name = root, .reads = try undeclaredReads(self, seedValueOf(self, root) orelse .none) });
        while (stack.items.len != 0) {
            const top = &stack.items[stack.items.len - 1];
            if (top.next == top.reads.len) {
                try on_path.put(a, top.name, false);
                _ = stack.pop();
                continue;
            }
            const c = top.reads[top.next];
            top.next += 1;
            if (on_path.get(c)) |open| {
                if (!open) continue;
                var names: std.ArrayList(u8) = .empty;
                var at = stack.items.len;
                while (stack.items[at - 1].name != c) at -= 1;
                for (stack.items[at - 1 ..]) |f| try names.print(a, "`{s}` → ", .{self.ctx.file.str(f.name)});
                try names.print(a, "`{s}`", .{self.ctx.file.str(c)});
                return names.items;
            }
            try on_path.put(a, c, true);
            try stack.append(a, .{ .name = c, .reads = try undeclaredReads(self, seedValueOf(self, c) orelse .none) });
        }
    }
    return null;
}

/// Every identifier `readsUndeclared` could return from `e`, once each.
fn undeclaredReads(self: *Flatten, e: Ast.ExprId) Error![]const Ast.StrId {
    var out: std.ArrayList(Ast.StrId) = .empty;
    var todo: std.ArrayList(Ast.ExprId) = .empty;
    if (e != .none) try todo.append(self.ctx.arena, e);
    const x = &self.ctx.file.exprs;
    while (todo.pop()) |n| {
        if (x.tag(n) == .ident) {
            const name = x.strOf(n);
            if (readsUndeclared(self, n) != null and std.mem.findScalar(Ast.StrId, out.items, name) == null)
                try out.append(self.ctx.arena, name);
            continue;
        }
        var buf: [3]Ast.ExprId = undefined;
        for (x.children(n, &buf)) |c| if (c != .none) try todo.append(self.ctx.arena, c);
    }
    return out.items;
}

/// The final expression of flat parameter `name` in this design: a seeded
/// defparam's value, else its first-walk value (scalars only).
fn seedValueOf(self: *Flatten, name: Ast.StrId) ?Ast.ExprId {
    if (self.defparams.get(self.ctx.file.str(name))) |dp| if (dp.seeded) return dp.value;
    for (self.seed_params) |p| if (p.name == name and p.dims.len == 0) return p.default;
    return null;
}

/// The flat key of defparam path `dp` written in `module` at instance
/// prefix `path` (IEEE 1364-2005 §12.6, as §12.2.1 applies it to a defparam).
/// A first segment naming an instance of `module`, its generate blocks'
/// included, starts a downward path. Otherwise it is looked up the
/// hierarchy, this instance first: an instance whose name or module name
/// (Syntax 12-7's `module_identifier`) it is becomes the base, and the rest
/// of the path runs down from there. A top-level module's instance name is
/// its module name. Nothing matching leaves the path downward, for E0907.
fn defparamKey(self: *Flatten, module: *const Ast.ModuleDecl, path: []const u8, dp: []const u8) Error![]const u8 {
    // The ancestor walk below cuts `path` at each `sep`.
    if (path.len != 0) std.debug.assert(path[path.len - 1] == elaborate.sep);
    if (rootedPath(self, dp)) |r| return r;
    const downward = try self.ctx.arena.print("{s}{s}", .{ path, dp });
    const dot = std.mem.findScalar(u8, dp, elaborate.sep) orelse return downward;
    const first = dp[0..dot];
    for (module.instances) |inst| if (std.mem.eql(u8, self.ctx.file.str(inst.name), first)) return downward;
    var gen: std.ArrayList(Ast.Instance) = .empty;
    for (module.analog) |blk| try @import("instance.zig").genInstanceList(self.ctx.file, blk.body, self.ctx.arena, &gen);
    for (gen.items) |inst| if (std.mem.eql(u8, self.ctx.file.str(inst.name), first)) return downward;
    // `path` ends in `sep`; each shorter prefix ending in `sep` (or empty)
    // is an ancestor's.
    var end = path.len;
    while (true) {
        const prefix = path[0..end];
        const unit = for (self.unit_paths.items) |u| {
            if (std.mem.eql(u8, u.path, prefix)) break u;
        } else null;
        if (unit) |u| {
            const own = if (end == 0) u.module else blk: {
                const parent_end = if (std.mem.findScalarLast(u8, prefix[0 .. end - 1], elaborate.sep)) |k| k + 1 else 0;
                break :blk prefix[parent_end .. end - 1];
            };
            if (std.mem.eql(u8, own, first) or std.mem.eql(u8, u.module, first))
                return self.ctx.arena.print("{s}{s}", .{ prefix, dp[dot + 1 ..] });
        }
        if (end == 0) return downward;
        const was = end;
        end = if (std.mem.findScalarLast(u8, path[0 .. end - 1], elaborate.sep)) |k| k + 1 else 0;
        std.debug.assert(end < was); // one level up per pass, so the walk ends at the top
    }
}

/// Reports E0907 for every defparam no parameter claimed. §6.3.1 a defparam
/// names "the parameter ... in any module instance throughout the design",
/// so one that matched nothing named nothing. Runs after the walk because
/// the instance a path names may be several levels below the module the
/// defparam is written in.
pub fn reportUnusedDefparams(self: *Flatten) Error!void {
    var it = self.defparams.iterator();
    while (it.next()) |dp| if (dp.value_ptr.seeded and !dp.value_ptr.collected) {
        // §12.8.2's hazard in another form: the first walk's hierarchy held
        // this defparam and the one its values produced does not.
        try self.err(dp.value_ptr.tok, .E0907, "`{s}`: this defparam's own instance does not exist once the defparams are applied (IEEE 1364-2005 12.8.1)", .{dp.key_ptr.*});
    } else if (!dp.value_ptr.used) {
        const key = dp.key_ptr.*;
        if (boundEarlier(self, key)) try self.err(
            dp.value_ptr.tok,
            .E0907,
            "`{s}` is a parameter of an instance elaborated before this defparam was reached; an upward defparam applies only to instances after the declaring one in instance order",
            .{key},
        ) else try self.err(dp.value_ptr.tok, .E0907, "`{s}` names no parameter of the elaborated design", .{key});
    };
}

/// Whether flat parameter name `key` is a parameter of an inlined instance:
/// a §12.6 upward defparam (`defparamKey`) found its target already bound.
/// `seedDefparams`' second walk applies every defparam the first collected,
/// so this is reached only by one that `mayBindEarly` did not foresee.
fn boundEarlier(self: *Flatten, key: []const u8) bool {
    const k = (std.mem.findScalarLast(u8, key, elaborate.sep) orelse return false) + 1;
    for (self.unit_paths.items) |u| if (std.mem.eql(u8, u.path, key[0..k])) {
        for (u.decl.params) |p| if (!p.is_local and std.mem.eql(u8, self.ctx.file.str(p.name), key[k..])) return true;
    };
    return false;
}

/// Returns how many of `params` an override can land on: the non-local ones
/// (§3.4.5).
pub fn overridableCount(params: []const Ast.ParamDecl) usize {
    var n: usize = 0;
    for (params) |p| n += @intFromBool(!p.is_local);
    return n;
}

/// One effective §6.3 override. A defparam value was cloned in its DECLARING
/// module; an inline value is still in the instantiating module's namespace.
pub const ParamBinding = struct {
    value: Ast.ExprId,
    /// The name the override was written with (an alias or the original), for
    /// §3.4.7's conflict check; `.none` for an ordered `#(...)` value.
    spelling: Ast.StrId,
    /// True for a defparam's value, already in the flat namespace; false for
    /// an inline value, still in the instantiating module's names.
    flat: bool,
};

comptime {
    // One row per paramset parameter per §6.4.2 candidate; 12 B budget.
    std.debug.assert(@sizeOf(ParamBinding) == 12);
}

/// The same binding feeds overload selection and final parameter assignment.
/// §6.3 lets a defparam replace an inline value under the same name. §3.4.7
/// forbids different original/alias spellings even across the two mechanisms.
/// Inspection never consumes an override: only the selected instance does.
pub fn parameterBinding(self: *Flatten, inst: *const Ast.Instance, params: []const Ast.ParamDecl, aliases: []const Ast.AliasParam, index: usize, path: []const u8, consume: bool) Error!?ParamBinding {
    const p = params[index];
    if (p.is_local) return null;
    var found: ?ParamBinding = null;
    const named = inst.params.len != 0 and inst.params[0].name != .none;
    if (named) {
        for (inst.params) |o| {
            if (o.value == .none) continue;
            var target = o.name;
            for (aliases) |al| if (al.alias == o.name) {
                target = al.target;
                break;
            };
            if (target == p.name) found = .{ .value = o.value, .spelling = o.name, .flat = false };
        }
    } else {
        var ordinal: usize = 0;
        for (params[0..index]) |before| if (!before.is_local) {
            ordinal += 1;
        };
        if (ordinal < inst.params.len and inst.params[ordinal].value != .none)
            found = .{ .value = inst.params[ordinal].value, .spelling = .none, .flat = false };
    }
    try parameterDefparam(self, path, p.name, p.name, consume, &found);
    for (aliases) |al| if (al.target == p.name)
        try parameterDefparam(self, path, p.name, al.alias, consume, &found);
    return found;
}

fn parameterDefparam(self: *Flatten, path: []const u8, original: Ast.StrId, spelling: Ast.StrId, consume: bool, found: *?ParamBinding) Error!void {
    const key = PathKey{ .path = path, .local = self.ctx.file.str(spelling) };
    const dp = self.defparams.getPtrAdapted(key, PathKey.Context{}) orelse return;
    var value = dp.value;
    if (consume) {
        value = try seededValue(self, path, key.local, dp) orelse return;
        dp.used = true;
        if (found.*) |before| if (before.spelling != .none and before.spelling != spelling)
            try self.err(dp.tok, .E0908, "`{s}` and its alias are both given a value", .{self.ctx.file.str(original)});
    }
    found.* = .{ .value = value, .spelling = spelling, .flat = true };
}

/// Folds `e` to a real, or null: §2.6 literals, the A.2.5 infinities, and
/// every operator over them, through the shared constant kernel, so `1/2` is
/// §4.2.4's integer division as in lowering. This literal-only helper checks
/// §9.18 domains without freezing host inputs; selection uses ParamsetEnv.
pub fn constReal(self: *Flatten, e: Ast.ExprId) ?f64 {
    const c = constfold.fold(self.ctx.file, e, constfold.literal_env) orelse return null;
    return if (c == .str) null else c.asReal();
}

/// §9.18/Table 9-29 domains, checked when the specified expression folds
/// without the model card. Every override mechanism uses this same check.
/// A value that reads the card is recorded for the card-time `checkCard`
/// instead (`Design.system_checks`), under the name `path$kind`.
pub fn checkSystemParam(self: *Flatten, kind: hier_param.Kind, tok: u32, e: Ast.ExprId, path: []const u8) Error!bool {
    if (constfold.firstStateRead(self.ctx.file, e, self.vars.items)) |what| {
        try self.err(tok, .E0363, "`{s}` override reads `{s}`", .{ kind.name(), what });
        return true;
    }
    const v = constReal(self, e) orelse {
        if (kind.constrained()) try self.system_checks.append(self.ctx.arena, .{
            .kind = kind,
            .value = e,
            .name = try std.mem.concat(self.ctx.arena, u8, &.{ path, kind.name() }),
        });
        return false;
    };
    if (kind.allows(v)) return false;
    try self.err(tok, .E0890, "`{s}` is {d}, and Table 9-29 allows only {s}", .{ kind.name(), v, kind.domain() });
    return true;
}

/// Returns whether `child` has an overridable parameter `target`; otherwise
/// reports E0907 naming it `shown` (an alias reads as written, §3.4.7).
pub fn checkOverridable(self: *Flatten, child: *const Ast.ModuleDecl, target: Ast.StrId, shown: Ast.StrId, tok: u32) Error!bool {
    const decl = for (child.params) |*p| {
        if (p.name == target) break p;
    } else {
        try self.err(tok, .E0907, "`{s}` is not a parameter of `{s}`", .{ self.ctx.file.str(shown), self.ctx.file.str(child.name) });
        return false;
    };
    // §3.4.5 a localparam is not overridable.
    if (decl.is_local) {
        try self.err(tok, .E0907, "`{s}` is a localparam of `{s}`", .{ self.ctx.file.str(shown), self.ctx.file.str(child.name) });
        return false;
    }
    return true;
}

/// §9.19 `$param_given` is a fact about the instantiation, one answer per
/// flattened parameter (an alias shares its target's), so the clone can
/// substitute a literal.
pub fn markGiven(self: *Flatten, child: *const Ast.ModuleDecl, over: *const std.AutoHashMapUnmanaged(Ast.StrId, Ast.ExprId), unit: *Unit) Error!void {
    for (child.params) |p| try unit.given.put(self.ctx.arena, p.name, over.contains(p.name));
    for (child.aliasparams) |al| if (over.contains(al.target))
        try unit.given.put(self.ctx.arena, al.alias, true);
}

/// Binds an instance's `#(...)` to `child`'s parameters into `over` (§6.3),
/// applies matching defparams last (§6.3.1), and sets `unit`'s §9.18
/// hierarchical values and §9.19 `$param_given` answers. Reports E0907 and
/// E0908 on bad overrides.
pub fn collectOverrides(
    self: *Flatten,
    inst: *const Ast.Instance,
    child: *const Ast.ModuleDecl,
    parent: *const Unit,
    over: *std.AutoHashMapUnmanaged(Ast.StrId, Ast.ExprId),
    unit: *Unit,
    path: []const u8,
) Error!void {
    var specified: hier_param.Values = .initFill(.none);
    var spellings: std.EnumArray(hier_param.Kind, Ast.StrId) = .initFill(.none);

    const named = inst.params.len != 0 and inst.params[0].name != .none;
    // §3.4.5: local parameters "cannot directly be modified with the
    // defparam statement or by the ordered or named parameter value
    // assignment", so §6.3's declaration order counts overridable
    // parameters only and an ordered value skips every `is_local` entry.
    // The named arm refuses a localparam by name below.
    var ord: usize = 0;
    for (inst.params) |o| {
        // The value is the parent's expression, cloned under the parent's map.
        const value = blk: {
            const saved = self.unit;
            self.unit = parent.*;
            defer self.unit = saved;
            break :blk try elab_clone.cloneExpr(self, o.value);
        };

        if (!named) {
            // §6.3 "in the order of their declaration".
            while (ord < child.params.len and child.params[ord].is_local) ord += 1;
            if (ord >= child.params.len) {
                const n = overridableCount(child.params);
                try self.err(o.main_tok, .E0907, "`{s}` declares {d} overridable parameter{s}, and this instance overrides {d}", .{
                    self.ctx.file.str(child.name), n,
                    if (n == 1) "" else "s",       inst.params.len,
                });
                continue;
            }
            try over.put(self.ctx.arena, child.params[ord].name, value);
            ord += 1;
            continue;
        }
        // §3.4.7 an aliasparam is a second NAME for one parameter, so an
        // override through it lands on the target.
        var target = o.name;
        for (child.aliasparams) |al| if (al.alias == o.name) {
            target = al.target;
            break;
        };
        if (hier_param.Kind.fromName(self.ctx.file.str(target))) |kind| {
            // §6.3.3 an empty association supplies no new value.
            if (o.value == .none) continue;
            if (specified.get(kind) != .none) {
                try self.err(o.main_tok, .E0908, "`{s}` is given more than one value", .{kind.name()});
                continue;
            }
            specified.set(kind, value);
            spellings.set(kind, o.name);
            continue;
        }
        if (!try checkOverridable(self, child, target, o.name, o.main_tok)) continue;
        // §6.3.3 / IEEE 12.2.2.2: .name() documents the parameter but
        // leaves its default, dependencies and $param_given unchanged.
        // Validate the name/localparam above even when no value is given.
        if (o.value == .none) continue;
        // §3.4.7: "It shall be an error to specify a value for both the
        // original parameter and its alias in the same module instantiation".
        if (over.contains(target)) {
            try self.err(o.main_tok, .E0908, "`{s}` and its alias are both given a value", .{self.ctx.file.str(target)});
            continue;
        }
        try over.put(self.ctx.arena, target, value);
    }

    // Resolve §6.3.1 precedence BEFORE composition: a defparam replaces
    // the specified value, never the inherited contribution. §3.4.7
    // forbids assigning through different aliases, even across mechanisms.
    for (hier_param.Kind.all) |kind| {
        const direct = try self.ctx.file.intern(self.ctx.arena, kind.name());
        try collectSystemDefparam(self, path, kind, direct, &specified, &spellings);
        for (child.aliasparams) |al| if (al.target == direct)
            try collectSystemDefparam(self, path, kind, al.alias, &specified, &spellings);
        const value = specified.get(kind);
        unit.hier.set(kind, parent.hier.get(kind));
        if (value == .none or try checkSystemParam(self, kind, self.ctx.file.exprs.mainTok(value), value, path)) continue;
        unit.hier.set(kind, try hier_param.compose(kind, self.ctx.file, self.ctx.arena, parent.hier.get(kind), value, self.ctx.file.exprs.mainTok(value)));
    }

    // §6.3.1 last: "If a defparam assignment conflicts with a module
    // instance parameter, the parameter in the module shall take the value
    // specified by the defparam." It overwrites `#(...)` whatever the text
    // order. §3.4.5 still holds: only overridable parameters are looked up.
    for (child.params, 0..) |p, i| {
        const binding = try parameterBinding(self, inst, child.params, child.aliasparams, i, path, true) orelse continue;
        if (binding.flat) try over.put(self.ctx.arena, p.name, binding.value);
    }

    try markGiven(self, child, over, unit);
}

fn collectSystemDefparam(self: *Flatten, path: []const u8, kind: hier_param.Kind, name: Ast.StrId, specified: *hier_param.Values, spellings: *std.EnumArray(hier_param.Kind, Ast.StrId)) Error!void {
    const dp = self.defparams.getPtrAdapted(PathKey{ .path = path, .local = self.ctx.file.str(name) }, PathKey.Context{}) orelse return;
    dp.used = true;
    const previous = spellings.get(kind);
    if (previous != .none and previous != name) {
        try self.err(dp.tok, .E0908, "`{s}` and its alias are both given a value", .{kind.name()});
        return;
    }
    specified.set(kind, dp.value);
    spellings.set(kind, name);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const fixture = @import("fixture.zig");
const diag = @import("diag");

test rootedPath {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f, "module top; endmodule");
    var fl = try fixture.flatten(&f);
    // Before `run` records unit 0 there is no top name to strip.
    try std.testing.expectEqualStrings("$root.top.u.g", rootedPath(&fl, "$root.top.u.g").?);
    try fl.unit_paths.append(f.arena.allocator(), .{ .module = "top", .path = "", .decl = &f.file.modules[0] });
    // §6.2.1: `$root.<top>.` names the device, the flat namespace's root.
    try std.testing.expectEqualStrings("u.g", rootedPath(&fl, "$root.top.u.g").?);
    // Only the whole first part is the top's name, and `$root.top` alone
    // names nothing below it; both keep `$root.` and name nothing (E0907).
    try std.testing.expectEqualStrings("$root.topx.g", rootedPath(&fl, "$root.topx.g").?);
    try std.testing.expectEqualStrings("$root.top", rootedPath(&fl, "$root.top").?);
    try std.testing.expectEqualStrings("$root.other.g", rootedPath(&fl, "$root.other.g").?);
    // No `$root.`: not this rule's path.
    try std.testing.expect(rootedPath(&fl, "top.u.g") == null);
}

test overridableCount {
    // §3.4.5: a localparam takes no override.
    const ps = [_]Ast.ParamDecl{
        .{ .name = .none, .ty = .real, .default = .none, .is_local = true },
        .{ .name = .none, .ty = .real, .default = .none },
        .{ .name = .none, .ty = .integer, .default = .none },
    };
    try std.testing.expectEqual(@as(usize, 2), overridableCount(&ps));
    try std.testing.expectEqual(@as(usize, 0), overridableCount(&.{}));
}

test mayBindEarly {
    // A defparam into one of its own module's instances is reached before
    // the parameter it names exists: one walk is enough.
    var down: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer down.deinit();
    try fixture.parse(&down,
        \\module top(p); inout p; electrical p; kid u(p); defparam u.g = 2.0; endmodule
        \\module kid(a); inout a; electrical a; parameter real g = 1.0; endmodule
    );
    try std.testing.expect(!mayBindEarly(&down.file));
    // IEEE 1364-2005 §12.6's upward form may name a parameter bound earlier.
    var upward: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer upward.deinit();
    try fixture.parse(&upward,
        \\module top(p); inout p; electrical p; kid u(p); endmodule
        \\module kid(a); inout a; electrical a; parameter real g = 1.0; defparam top.u.g = 2.0; endmodule
    );
    try std.testing.expect(mayBindEarly(&upward.file));
}

test "§9.18 Table 9-29: an out-of-domain system parameter is E0890, a second value for one E0908" {
    const src =
        \\module top(p); inout p; electrical p; kid #({s}) u(p); endmodule
        \\module kid(a); inout a; electrical a; analog I(a) <+ V(a); endmodule
    ;
    const Case = struct { over: []const u8, code: diag.Code };
    for ([_]Case{
        .{ .over = ".$mfactor(0.0)", .code = .E0890 }, // $mfactor > 0
        .{ .over = ".$hflip(2.0)", .code = .E0890 }, // $hflip = +1 or -1
        .{ .over = ".$angle(360.0)", .code = .E0890 }, // 0 <= $angle < 360
        .{ .over = ".$mfactor(2.0), .$mfactor(3.0)", .code = .E0908 },
    }) |case| {
        var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
        defer f.deinit();
        try fixture.parse(&f, try f.arena.allocator().print(src, .{case.over}));
        try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(f.ctx()));
        try std.testing.expect(fixture.hasCode(&f.bag, case.code));
    }
    // Each domain's edge from inside is legal.
    var good: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer good.deinit();
    try fixture.parse(&good, try good.arena.allocator().print(src, .{".$angle(0.0), .$hflip(-1.0), .$mfactor(0.5)"}));
    _ = try elaborate.elaborate(good.ctx());
}

test "§9.18 $mfactor composes as a product down the hierarchy" {
    // Table 9-29: an instance's $mfactor is its parent's times its own, so
    // `k` inside `m` (2.0) inside the top reads 2.0 * 3.0.
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\module top(p); inout p; electrical p; mid #(.$mfactor(2.0)) m(p); endmodule
        \\module mid(a); inout a; electrical a; kid #(.$mfactor(3.0)) k(a); endmodule
        \\module kid(b); inout b; electrical b; analog V(b) <+ $mfactor; endmodule
    );
    const d = try elaborate.elaborate(f.ctx());
    const x = &f.file.exprs;
    const rhs = f.file.stmt(d.top.analog[0].body).contribute.rhs;
    try std.testing.expectEqual(Ast.BinaryOp.mul, x.binOp(rhs));
    try std.testing.expectEqual(@as(f64, 2.0), x.realValue(x.lhs(rhs)));
    try std.testing.expectEqual(@as(f64, 3.0), x.realValue(x.rhs(rhs)));
}

test "§6.3 an ordered override list longer than the overridable parameters is E0907" {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\module top(p); inout p; electrical p; kid #(1.0, 2.0) u(p); endmodule
        \\module kid(a); inout a; electrical a; parameter real g = 0.0; endmodule
    );
    try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(f.ctx()));
    try std.testing.expect(fixture.hasCode(&f.bag, .E0907));
}

test "IEEE 1364-2005 §12.8.1 an upward defparam's value is replaced down a chain of any length; a cycle is E0907, named" {
    const gpa = std.testing.allocator;
    // `w`'s `p<n>` is `p<n-1> + 1.0` from `p0 = 1.0`, and `w` sets the top's
    // `u.g`, inlined before `w`, to `p<n>`: n replacements. 64 was the old
    // bound on them, so 65 and far past it. The value itself is run by
    // `ch06_hierarchy/defparam_upward_value_chain_65.va`.
    for ([_]usize{ 64, 65, 2000 }) |n| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        try text.appendSlice(gpa,
            \\module top(p); inout p; electrical p; kid u(p); writer w(p); endmodule
            \\module kid(c); inout c; electrical c; parameter real g = 0.0; endmodule
            \\module writer(c); inout c; electrical c; parameter real p0 = 1.0;
            \\
        );
        for (1..n + 1) |i| try text.print(gpa, "parameter real p{d} = p{d} + 1.0;\n", .{ i, i - 1 });
        try text.print(gpa, "defparam top.u.g = p{d};\nendmodule\n", .{n});
        var f: fixture.Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try fixture.parse(&f, text.items);
        const d = try elaborate.elaborate(f.ctx());
        try std.testing.expectEqual(@as(usize, 0), f.bag.count());
        try std.testing.expect(fixture.paramNamed(&f.file, d.top, "u.g").?.is_override);
    }
    // `u.g`'s value reads `w.y`, `w.y` reads `w.x`, and the defparam on
    // `w.x` reads `w.y` again: no replacement ends.
    var f: fixture.Fixture = .{ .arena = .init(gpa) };
    defer f.deinit();
    try fixture.parse(&f,
        \\module top(p); inout p; electrical p; kid u(p); writer w(p); endmodule
        \\module kid(c); inout c; electrical c; parameter real g = 0.0; endmodule
        \\module writer(c); inout c; electrical c; parameter real x = 1.0; parameter real y = x;
        \\  defparam top.u.g = y; defparam w.x = y;
        \\endmodule
    );
    try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(f.ctx()));
    try std.testing.expectEqual(diag.Code.E0907, f.bag.at(0).code);
    try std.testing.expect(std.mem.find(u8, f.bag.at(0).message, "the cycle `w.y` → `w.x` → `w.y`") != null);
}
