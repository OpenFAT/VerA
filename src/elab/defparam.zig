//! §6.3.1 defparams: each module's `defparam` statements, collected on the
//! way down → a table keyed by the absolute flat parameter name, consumed as
//! instances are inlined, with IEEE 1364-2005 §12.8.1's seeded values for a
//! defparam that names a parameter bound before it is reached, and E0907 for
//! one that names nothing.
//! Cites: LRM §6.2.1, §6.3.1; IEEE 1364-2005 §12.2.1, §12.6, §12.8.1,
//! §12.8.2.
//!
//! Contents:
//! - `pub const Table = struct`
//! - `pub const Defparam = struct`
//! - `pub fn collectDefparams(self: *Flatten, module: *const Ast.ModuleDecl, path: []const u8) design.Error!void`
//! - `pub fn mayBindEarly(file: *const Ast.SourceFile) bool`
//! - `pub fn seedDefparams(self: *Flatten, first: *const Flatten) design.Error!void`
//! - `pub fn applyTopDefparams(self: *Flatten) design.Error!void`
//! - `pub fn rootedPath(self: *const Flatten, p: []const u8) ?[]const u8`
//! - `pub fn seededValue(self: *Flatten, path: []const u8, local: []const u8, dp: *Defparam) design.Error!?Ast.ExprId`
//! - `pub fn reportUnusedDefparams(self: *Flatten) design.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const diag = @import("diag");
const design = @import("design.zig");
const Flatten = @import("Flatten.zig");
const elaborate = @import("elaborate.zig");
const generate = @import("generate.zig");
const clone_expr = @import("clone_expr.zig");
const flat_name = @import("flat_name.zig");
const sep = design.sep;
const fixture = @import("fixture.zig");

/// `Flatten.defparams`: §6.3.1 every `defparam` seen so far, keyed by the
/// absolute flat name of the parameter it overrides (the declaring module's
/// path joined with the path the source wrote), collected on the way down
/// (`collectDefparams`), before any instance below it is inlined, so a
/// defparam is always in the table before the parameter it names exists.
pub const Table = struct {
    rows: std.StringHashMapUnmanaged(Defparam) = .empty,
    /// IEEE 1364-2005 §12.8.1: the first walk's flat parameters, when
    /// `seedDefparams` ran one; `seededValue` reads a not-yet-inlined
    /// parameter's value from them.
    seed_params: []const Ast.ParamDecl = &.{},
};

/// One collected §6.3.1 override, in `Flatten.defparams`.
pub const Defparam = struct {
    /// Already cloned, in the DECLARING module's namespace (§6.3.1: "a constant
    /// expression involving ... parameters declared in the same module as the
    /// defparam statement").
    value: Ast.ExprId,
    /// The defparam statement's token, where E0907/E0908 point.
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
    assert(@sizeOf(Defparam) == 12);
}

/// Records `module`'s §6.3.1 defparams, at its instance prefix `path`, before
/// any child is inlined: a defparam applies downward, and the parameters it
/// overrides are created as those instances are. Under a §6.4 paramset
/// instance a defparam overrides nothing; it lands in
/// `Flatten.paramset_defparams` for lowering to judge. Asserts that `path`
/// is empty (the top) or ends in `sep`.
pub fn collectDefparams(self: *Flatten, module: *const Ast.ModuleDecl, path: []const u8) design.Error!void {
    for (module.defparams) |dp| {
        if (self.unit.paramset_instance) |instance| {
            try self.out.paramset_defparams.append(self.ctx.arena, .{
                .main_tok = dp.main_tok,
                .instance = instance,
                .gate = self.unit.gate,
            });
            // An active site is illegal; an inactive site's hierarchy
            // does not exist. Neither may override a child parameter.
            continue;
        }
        const key = try defparamKey(self, module, path, self.ctx.file.str(dp.path));
        const gop = try self.defparams.rows.getOrPut(self.ctx.arena, key);
        if (gop.found_existing and gop.value_ptr.seeded) {
            // The first walk's last value for this key is already in force
            // (§12.2.1: "the last defparam statement encountered"); reaching
            // the site again only confirms it still exists.
            gop.value_ptr.collected = true;
            continue;
        }
        gop.value_ptr.* = .{
            .value = try clone_expr.cloneExpr(self, dp.value),
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
        const dot = std.mem.findScalar(u8, text, sep) orelse return true;
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
pub fn seedDefparams(self: *Flatten, first: *const Flatten) design.Error!void {
    var it = first.defparams.rows.iterator();
    while (it.next()) |dp| {
        var row = dp.value_ptr.*;
        row.used = false;
        row.seeded = true;
        row.collected = false;
        try self.defparams.rows.put(self.ctx.arena, dp.key_ptr.*, row);
    }
    self.defparams.seed_params = first.decls.params.items;
}

/// §6.3.1 on the top's own parameters: a seeded defparam (`seedDefparams`)
/// naming one replaces its value, and the parameter becomes local: "the
/// parameter in the module shall take the value specified by the defparam",
/// so the host's model card, which stands where an instance override would,
/// no longer sets it. Runs once the top's parameters are `self.decls.params`.
pub fn applyTopDefparams(self: *Flatten) design.Error!void {
    if (self.defparams.rows.count() == 0) return;
    for (self.decls.params.items) |*p| {
        if (p.is_local) continue;
        const local = self.ctx.file.str(p.name);
        const dp = self.defparams.rows.getPtrAdapted(flat_name.PathKey{ .path = "", .local = local }, flat_name.PathKey.Context{}) orelse continue;
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
    const root = "$root" ++ [_]u8{sep};
    if (!std.mem.startsWith(u8, p, root)) return null;
    const rest = p[root.len..];
    // Row 0 is the top, whose path is the only empty one.
    if (self.out.units.len == 0) return p;
    assert(self.out.units.items(.path)[0].len == 0);
    const top = self.ctx.file.str(self.out.units.items(.module)[0]);
    if (rest.len > top.len and rest[top.len] == sep and std.mem.startsWith(u8, rest, top)) return rest[top.len + 1 ..];
    return p;
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
pub fn seededValue(self: *Flatten, path: []const u8, local: []const u8, dp: *Defparam) design.Error!?Ast.ExprId {
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
        v = try generate.substIdent(self, v, name, with);
    }
    return v;
}

/// Reports E0907 for every defparam no parameter claimed. §6.3.1 a defparam
/// names "the parameter ... in any module instance throughout the design",
/// so one that matched nothing named nothing. Runs after the walk because
/// the instance a path names may be several levels below the module the
/// defparam is written in.
pub fn reportUnusedDefparams(self: *Flatten) design.Error!void {
    var it = self.defparams.rows.iterator();
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

// ---- private ----

/// The flat key of defparam path `dp` written in `module` at instance
/// prefix `path` (IEEE 1364-2005 §12.6, as §12.2.1 applies it to a defparam).
/// A first segment naming an instance of `module`, its generate blocks'
/// included, starts a downward path. Otherwise it is looked up the
/// hierarchy, this instance first: an instance whose name or module name
/// (Syntax 12-7's `module_identifier`) it is becomes the base, and the rest
/// of the path runs down from there. A top-level module's instance name is
/// its module name. Nothing matching leaves the path downward, for E0907.
fn defparamKey(self: *Flatten, module: *const Ast.ModuleDecl, path: []const u8, dp: []const u8) design.Error![]const u8 {
    // The ancestor walk below cuts `path` at each `sep`.
    if (path.len != 0) assert(path[path.len - 1] == sep);
    if (rootedPath(self, dp)) |r| return r;
    const downward = try self.ctx.arena.print("{s}{s}", .{ path, dp });
    const dot = std.mem.findScalar(u8, dp, sep) orelse return downward;
    const first = dp[0..dot];
    for (module.instances) |inst| if (std.mem.eql(u8, self.ctx.file.str(inst.name), first)) return downward;
    var gen: std.ArrayList(Ast.Instance) = .empty;
    for (module.analog) |blk| try generate.genInstanceList(self.ctx.file, blk.body, self.ctx.arena, &gen);
    for (gen.items) |inst| if (std.mem.eql(u8, self.ctx.file.str(inst.name), first)) return downward;
    // `path` ends in `sep`; each shorter prefix ending in `sep` (or empty)
    // is an ancestor's.
    var end = path.len;
    while (true) {
        const prefix = path[0..end];
        const unit = for (self.out.units.items(.path), self.out.units.items(.module)) |up, um| {
            if (std.mem.eql(u8, up, prefix)) break self.ctx.file.str(um);
        } else null;
        if (unit) |module_name| {
            const own = if (end == 0) module_name else blk: {
                const parent_end = if (std.mem.findScalarLast(u8, prefix[0 .. end - 1], sep)) |k| k + 1 else 0;
                break :blk prefix[parent_end .. end - 1];
            };
            if (std.mem.eql(u8, own, first) or std.mem.eql(u8, module_name, first))
                return self.ctx.arena.print("{s}{s}", .{ prefix, dp[dot + 1 ..] });
        }
        if (end == 0) return downward;
        const was = end;
        end = if (std.mem.findScalarLast(u8, path[0 .. end - 1], sep)) |k| k + 1 else 0;
        assert(end < was); // one level up per pass, so the walk ends at the top
    }
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
        for (self.decls.params.items) |p| if (p.name == name) return null;
        for (self.decls.aliasparams.items) |a| if (a.alias == name) return null;
        return e;
    }
    var buf: [3]Ast.ExprId = undefined;
    for (x.children(e, &buf)) |c| if (readsUndeclared(self, c)) |hit| return hit;
    return null;
}

/// The cycle `seededValue`'s replacements would run round from `e`, named
/// parameter by parameter (`` `a` → `b` → `a` ``), or null. A depth-first
/// walk over "the final expression of `a` reads `b`", on a heap stack.
fn substitutionCycle(self: *Flatten, e: Ast.ExprId) design.Error!?[]const u8 {
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
fn undeclaredReads(self: *Flatten, e: Ast.ExprId) design.Error![]const Ast.StrId {
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
    if (self.defparams.rows.get(self.ctx.file.str(name))) |dp| if (dp.seeded) return dp.value;
    for (self.defparams.seed_params) |p| if (p.name == name and p.dims.len == 0) return p.default;
    return null;
}

/// Whether flat parameter name `key` is a parameter of an inlined instance:
/// a §12.6 upward defparam (`defparamKey`) found its target already bound.
/// `seedDefparams`' second walk applies every defparam the first collected,
/// so this is reached only by one that `mayBindEarly` did not foresee.
fn boundEarlier(self: *Flatten, key: []const u8) bool {
    const k = (std.mem.findScalarLast(u8, key, sep) orelse return false) + 1;
    for (self.out.units.items(.path), self.out.units.items(.decl)) |up, decl| if (std.mem.eql(u8, up, key[0..k])) {
        for (decl.get(self.ctx.file).params) |p| if (!p.is_local and std.mem.eql(u8, self.ctx.file.str(p.name), key[k..])) return true;
    };
    return false;
}

test rootedPath {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f, "module top; endmodule");
    var fl = try fixture.flatten(&f);
    // Before `run` records unit 0 there is no top name to strip.
    try std.testing.expectEqualStrings("$root.top.u.g", rootedPath(&fl, "$root.top.u.g").?);
    try fl.out.units.append(f.arena.allocator(), .{ .module = fixture.id(&f.file, "top").?, .path = "", .decl = .of(&f.file, &f.file.modules[0]) });
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
