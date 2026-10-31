const std = @import("std");
const Lower = @import("Lower.zig");
const lower_var = @import("var.zig");
const Ast = @import("frontend").Ast;
const naming = @import("ir").names;
const Elaborate = @import("elab").Elaborate;
const diag = @import("diag");
const Oom = Lower.Oom;
const TypedValue = Lower.TypedValue;
const poison = Lower.poison;
const astTy = Lower.astTy;

/// Returns the flat spelling of a §6.7 `.hier_ident` path: its parts joined by
/// `Elaborate.sep`. Flattening renamed each child entity to `path.name`, so
/// this string is the name the flat design carries.
///
/// Allocates the result in `self.arena` on every call.
pub fn flatName(self: *Lower, e: Ast.ExprId) Oom![]const u8 {
    const path = try Elaborate.flatReference(self.file, self.arena, self.module, e);
    if (self.scope_path.len != 0) if (try inScope(self, path)) |hit| return hit;
    // The one place the join is NOT the answer: a child port bound to a parent
    // net is the same signal as that net, so `u.a` denotes `p` and there is no
    // `u.a` to find. `Design.names` holds those aliases and nothing else.
    return self.out.hier_names.get(path) orelse path;
}

/// §6.6.2: a generate block's declarations can be referenced hierarchically
/// "from within the hierarchy instantiated by the generate block itself",
/// and §6.8 (IEEE 1364-2005 12.7) searches a name "first at the current level
/// and then in higher level modules". Inside a generate block (`scope_path`,
/// its §6.6.3 name included for an unnamed one) `u1.gain` is first the
/// block's own `u1`, which the flatten named `genblk1.u1`: the innermost
/// enclosing scope whose prefix makes `path` name something, or null.
fn inScope(self: *Lower, path: []const u8) Oom!?[]const u8 {
    const unit = if (self.cur_unit < self.design.units.len) self.design.units[self.cur_unit].path else "";
    var scope = self.scope_path;
    while (scope.len != 0) {
        const cand = try self.arena.print("{s}{s}{c}{s}", .{ unit, scope, Elaborate.sep, path });
        const flat = self.out.hier_names.get(cand) orelse cand;
        if (self.param_index.contains(flat) or self.vars.contains(flat) or self.consts.contains(flat) or
            self.node_voltages.contains(flat) or self.branches.contains(flat) or self.port_branches.contains(flat))
            return flat;
        scope = scope[0 .. std.mem.findScalarLast(u8, scope, Elaborate.sep) orelse 0];
    }
    return null;
}

/// §6.6.2 the unnamed generate block whose flat prefix the hierarchical name
/// `e` spells its way into from outside, or null. "Outside" is the unit that
/// wrote `e`: a unit instantiated inside the block is "within the hierarchy
/// instantiated by the generate block itself" and may name what it holds.
pub fn unnamedGenScope(self: *Lower, e: Ast.ExprId) Oom!?[]const u8 {
    const scopes = self.unnamed_gen orelse blk: {
        var out: std.ArrayList([]const u8) = .empty;
        // A tree of one has no unit table; its module is the source's own.
        if (self.design.units.len == 0) {
            if (self.module) |m| try Elaborate.unnamedGenScopes(self.file, self.arena, m, "", &out);
        } else for (self.design.units) |u| try Elaborate.unnamedGenScopes(self.file, self.arena, u.decl, u.path, &out);
        self.unnamed_gen = out.items;
        break :blk out.items;
    };
    if (scopes.len == 0) return null;
    const path = try Elaborate.flatReference(self.file, self.arena, self.module, e);
    const own = if (self.cur_unit < self.design.units.len) self.design.units[self.cur_unit].path else "";
    for (scopes) |s| if (std.mem.startsWith(u8, path, s) and !std.mem.startsWith(u8, own, s)) return s;
    return null;
}

/// Reports E0998 when `e` names something inside an unnamed generate block
/// from outside it (§6.6.2, §6.6.1; §6.6.3 "has no name that can be used in
/// a hierarchical name"), and returns whether it did.
pub fn refuseUnnamedGen(self: *Lower, e: Ast.ExprId) Oom!bool {
    const scope = try unnamedGenScope(self, e) orelse return false;
    var b = self.errWith(self.file.exprs.mainTok(e), .E0998);
    b.msg("`{s}` reaches into `{s}`, an unnamed generate block", .{
        try Elaborate.flatReference(self.file, self.arena, self.module, e), scope[0 .. scope.len - 1],
    });
    b.help("name the block (`begin : g`) and reach it as `g.<item>`", .{});
    try b.emit();
    return true;
}

/// §2.8 name resolution: variables (§3.2) shadow parameters (§3.4), which
/// shadow genvars (§3.5). Nets are NOT values — they are only reachable
/// through an access function (§4.4).
/// §6.7 hierarchical reads pass the dotted path joined by `flatName`.
pub fn lookupName(self: *Lower, e: Ast.ExprId, name: []const u8) Oom!TypedValue {
    // §8.5.3.6 a digital read under an explicit D2A event is the region-1b value.
    if (self.in_d2a_body and self.out.discrete_snaps.contains(name)) {
        const idx = self.param_index.get(try naming.snapField(self.arena, name)).?;
        return .{ .v = self.param_values.items[idx], .ty = astTy(self.out.params.items[idx].ty) };
    }
    if (self.vars.get(name)) |slot|
        // A wide `reg` read whole is a Table 7-1 grouping past 31 bits (E0222).
        return .{ .v = try lower_var.analogRead(self, try self.builder.readVariable(slot.place, self.cur), slot.reg_width), .ty = if (slot.ty == .wide) .integer else slot.ty };
    // §4.7.2/§6.8: inside a function body, a function-local `parameter` of the
    // same name shadows the module's, so `param_index` is masked and the local
    // value is found in `consts` (where `inlineUserFuncPre` folded it).
    if (!funcParamShadows(self, name)) if (self.param_index.get(name)) |idx|
        return .{ .v = self.param_values.items[idx], .ty = astTy(self.out.params.items[idx].ty) };
    if (self.consts.get(name)) |c| return switch (c) {
        .int => .{ .v = try self.mir.addIntConst(self.arena, c.asInt()), .ty = .integer },
        .real => .{ .v = try self.mir.addFloatConst(self.arena, c.asReal()), .ty = .real },
        .str => |s| .{ .v = try self.mir.addStrConst(self.arena, s), .ty = .string },
    };
    if (self.node_voltages.contains(name)) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0315);
        b.msg("`{s}`", .{name});
        b.help("probe it: `V({s})` or `I({s})`", .{ name, name });
        try b.emit();
        return poison;
    }
    var b = self.errWith(self.file.exprs.mainTok(e), .E0314);
    b.msg("`{s}`", .{name});
    const near = diag.didYouMeanMap(name, self.vars) orelse
        diag.didYouMeanMap(name, self.param_index) orelse
        diag.didYouMeanMap(name, self.node_voltages) orelse
        diag.didYouMeanMap(name, self.branches);
    if (near) |s| b.suggestHere(s);
    try b.emit();
    return poison;
}

/// §4.7.2/§6.8: does the function currently being inlined declare `name` as a
/// local parameter? True makes the local (in `consts`) win over a module
/// parameter of the same name — the shadowing §6.8's scope list requires.
pub fn funcParamShadows(self: *const Lower, name: []const u8) bool {
    for (self.func_params) |*p| {
        if (self.file.strings.eql(p.name, name)) return true;
    }
    return false;
}
