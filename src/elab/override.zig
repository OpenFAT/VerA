//! §6.3 parameter overrides: an instance's `#(...)` list and the matching
//! defparams → the child's override map, its §9.18 hierarchical
//! system-parameter values (Table 9-29 domains judged) and its §9.19
//! `$param_given` answers.
//! Cites: LRM §3.4.5, §3.4.7, §6.3, §6.3.1, §6.3.3, §9.18 Table 9-29, §9.19;
//! IEEE 1364-2005 §12.2.2.2.
//!
//! Contents:
//! - `pub const ParamBinding = struct`
//! - `pub fn collectOverrides(`
//! - `pub fn overridableCount(params: []const Ast.ParamDecl) usize`
//! - `pub fn parameterBinding(self: *Flatten, inst: *const Ast.Instance, params: []const Ast.ParamDecl, aliases: []const Ast.AliasParam, index: usize, path: []const u8, consume: bool) design.Error!?ParamBinding`
//! - `pub fn constReal(self: *Flatten, e: Ast.ExprId) ?f64`
//! - `pub fn checkSystemParam(self: *Flatten, kind: hier_param.Kind, tok: u32, e: Ast.ExprId, path: []const u8) design.Error!bool`
//! - `pub fn checkOverridable(self: *Flatten, child: *const Ast.ModuleDecl, target: Ast.StrId, shown: Ast.StrId, tok: u32) design.Error!bool`
//! - `pub fn markGiven(self: *Flatten, child: *const Ast.ModuleDecl, over: *const std.AutoHashMapUnmanaged(Ast.StrId, Ast.ExprId), unit: *Unit) design.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const constfold = @import("frontend").constfold;
const diag = @import("diag");
const design = @import("design.zig");
const Flatten = @import("Flatten.zig");
const elaborate = @import("elaborate.zig");
const clone_expr = @import("clone_expr.zig");
const flat_name = @import("flat_name.zig");
const defparam = @import("defparam.zig");
const hier_param = @import("hier_param.zig");
const Unit = Flatten.Unit;

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
    assert(@sizeOf(ParamBinding) == 12);
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
) design.Error!void {
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
            break :blk try clone_expr.cloneExpr(self, o.value);
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

/// Returns how many of `params` an override can land on: the non-local ones
/// (§3.4.5).
pub fn overridableCount(params: []const Ast.ParamDecl) usize {
    var n: usize = 0;
    for (params) |p| n += @intFromBool(!p.is_local);
    return n;
}

/// The same binding feeds overload selection and final parameter assignment.
/// §6.3 lets a defparam replace an inline value under the same name. §3.4.7
/// forbids different original/alias spellings even across the two mechanisms.
/// Inspection never consumes an override: only the selected instance does.
pub fn parameterBinding(self: *Flatten, inst: *const Ast.Instance, params: []const Ast.ParamDecl, aliases: []const Ast.AliasParam, index: usize, path: []const u8, consume: bool) design.Error!?ParamBinding {
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
pub fn checkSystemParam(self: *Flatten, kind: hier_param.Kind, tok: u32, e: Ast.ExprId, path: []const u8) design.Error!bool {
    if (constfold.firstStateRead(self.ctx.file, e, self.decls.vars.items)) |what| {
        try self.err(tok, .E0363, "`{s}` override reads `{s}`", .{ kind.name(), what });
        return true;
    }
    const v = constReal(self, e) orelse {
        if (kind.constrained()) try self.out.system_checks.append(self.ctx.arena, .{
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
pub fn checkOverridable(self: *Flatten, child: *const Ast.ModuleDecl, target: Ast.StrId, shown: Ast.StrId, tok: u32) design.Error!bool {
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
pub fn markGiven(self: *Flatten, child: *const Ast.ModuleDecl, over: *const std.AutoHashMapUnmanaged(Ast.StrId, Ast.ExprId), unit: *Unit) design.Error!void {
    for (child.params) |p| try unit.given.put(self.ctx.arena, p.name, over.contains(p.name));
    for (child.aliasparams) |al| if (over.contains(al.target))
        try unit.given.put(self.ctx.arena, al.alias, true);
}

// ---- private ----

fn parameterDefparam(self: *Flatten, path: []const u8, original: Ast.StrId, spelling: Ast.StrId, consume: bool, found: *?ParamBinding) design.Error!void {
    const key = flat_name.PathKey{ .path = path, .local = self.ctx.file.str(spelling) };
    const dp = self.defparams.rows.getPtrAdapted(key, flat_name.PathKey.Context{}) orelse return;
    var value = dp.value;
    if (consume) {
        value = try defparam.seededValue(self, path, key.local, dp) orelse return;
        dp.used = true;
        if (found.*) |before| if (before.spelling != .none and before.spelling != spelling)
            try self.err(dp.tok, .E0908, "`{s}` and its alias are both given a value", .{self.ctx.file.str(original)});
    }
    found.* = .{ .value = value, .spelling = spelling, .flat = true };
}

fn collectSystemDefparam(self: *Flatten, path: []const u8, kind: hier_param.Kind, name: Ast.StrId, specified: *hier_param.Values, spellings: *std.EnumArray(hier_param.Kind, Ast.StrId)) design.Error!void {
    const dp = self.defparams.rows.getPtrAdapted(flat_name.PathKey{ .path = path, .local = self.ctx.file.str(name) }, flat_name.PathKey.Context{}) orelse return;
    dp.used = true;
    const previous = spellings.get(kind);
    if (previous != .none and previous != name) {
        try self.err(dp.tok, .E0908, "`{s}` and its alias are both given a value", .{kind.name()});
        return;
    }
    specified.set(kind, dp.value);
    spellings.set(kind, name);
}

const fixture = @import("fixture.zig");

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
