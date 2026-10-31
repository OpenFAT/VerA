//! §2.8 name resolution in a value position: an identifier or §6.7
//! hierarchical name in, the variable, parameter or genvar value it denotes
//! out (E0314/E0315 when it denotes none or a net). Variables shadow
//! parameters, which shadow genvars; a function-local parameter shadows the
//! module's (§4.7.2, §6.8); a hierarchical name is the flat name elaboration
//! gave the child's entity.
//!
//! Cites: §2.8, §3.2, §3.4, §3.5, §4.4, §4.7.2, §5.3.2, §5.5.3, §6.6.1,
//! §6.6.2, §6.6.3, §6.7, §6.7.1, §6.8, §7.3.1 (Table 7-1), §8.5.3.6; IEEE
//! 1364-2005 §12.7.
//!
//! Contents:
//! - `pub fn lowerHierIdent(self: *Lower, e: Ast.ExprId) Oom!TypedValue`
//! - `pub fn flatName(self: *Lower, e: Ast.ExprId) Oom![]const u8`
//! - `pub fn unnamedGenScope(self: *Lower, e: Ast.ExprId) Oom!?[]const u8`
//! - `pub fn refuseUnnamedGen(self: *Lower, e: Ast.ExprId) Oom!bool`
//! - `pub fn lookupName(self: *Lower, e: Ast.ExprId, name: []const u8) Oom!TypedValue`
//! - `pub fn funcParamShadows(self: *const Lower, name: []const u8) bool`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const naming = @import("ir").names;
const elab = @import("elab");
const diag = @import("diag");
const Lower = @import("Lower.zig");
const lower_analog_op = @import("analog_op.zig");
const lower_var = @import("var.zig");
const Oom = Lower.Oom;
const TypedValue = Lower.TypedValue;
const poison = Lower.poison;
const astTy = Lower.astTy;

/// Lowers a §6.7 hierarchical name in a value position: a §5.5.3 nature
/// attribute reference (a constant this module resolves), or the flat name
/// elaboration gave a child's parameter, branch probe or named-block local.
/// A child's variable is §6.7.1's E0910, a name in no scope E0901, a reach
/// into an unnamed generate block E0998; each returns the poison value.
/// Asserts that `e` is a `.hier_ident` row.
pub fn lowerHierIdent(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    assert(e == .none or self.exprValid(e));
    assert(self.file.exprs.tag(e) == .hier_ident);
    // §5.5.3 Syntax 5-4 first: a nature attribute reference is a
    // CONSTANT this module can resolve, unlike a §6.8 hierarchical name,
    // which needs an instance tree (E0901).
    if (lower_analog_op.natureAttrRef(self, e)) |r| switch (r) {
        .value => |c| return switch (c) {
            .real, .int => .{ .v = try self.mir.addFloatConst(self.arena, c.asReal()), .ty = .real },
            .str => .{ .v = try self.mir.addStrConst(self.arena, c.str), .ty = .string },
        },
        .banned => |attr| {
            var b = self.errWith(self.file.exprs.mainTok(e), .E0359);
            b.msg("`{s}`", .{attr});
            b.note("§5.5.3: \"This syntax shall not be used for the access, ddt_nature, or idt_nature attributes of a nature, nor any other attribute whose value is not a constant expression\"", .{});
            try b.emit();
            return poison;
        },
    };
    // §6.7 "access of parameters can be done hierarchically", and
    // §6.7.1 extends it to variables. The path IS the flat name
    // elaboration gave the child's entity, so once the join resolves
    // there is nothing hierarchical left to do; E0901 is what is left
    // when it does not.
    if (try refuseUnnamedGen(self, e)) return poison;
    const name = try flatName(self, e);
    // §6.7.1's fifth bullet, and the only one of the list that is a
    // prohibition: "It shall be an error to access analog variables
    // hierarchically." It has to be tested before the resolution below,
    // because the resolution succeeds — a flattened child's variable is
    // an ordinary variable of the flat design under its path name, so
    // nothing else would stop the read.
    // Except a §5.3.2 named-block local, which the LRM spells out the
    // other way: "All identifiers declared within a named sequential
    // block can be accessed outside the scope in which they are
    // declared." §6.7.1 is about reaching into another INSTANCE;
    // `publishBlockLocals` bound only labels of this analog block.
    if (self.vars.contains(name) and !self.block_locals.contains(name)) {
        var vb = self.errWith(self.file.exprs.mainTok(e), .E0910);
        vb.msg("`{s}`", .{name});
        vb.note("§6.7.1 permits a hierarchical parameter, branch probe or analog function; a variable is the one entry on that list it forbids", .{});
        try vb.emit();
        return poison;
    }
    if (self.param_index.contains(name) or self.consts.contains(name) or
        self.node_voltages.contains(name) or self.block_locals.contains(name))
        return lookupName(self, e, name);
    try self.err(self.file.exprs.mainTok(e), .E0901, "`{s}` names nothing in the elaborated design", .{name});
    return poison;
}

/// Returns the flat spelling of a §6.7 `.hier_ident` path: its parts joined by
/// `elab.sep`. Flattening renamed each child entity to `path.name`, so
/// this string is the name the flat design carries.
///
/// Allocates the result in `self.arena` on every call.
pub fn flatName(self: *Lower, e: Ast.ExprId) Oom![]const u8 {
    assert(self.module != null); // elaboration is done: flat names exist
    assert(e == .none or self.exprValid(e));
    const path = try elab.flatReference(self.file, self.arena, self.module, e);
    if (self.scope_path.len != 0) if (try inScope(self, path)) |hit| return hit;
    // The one place the join is NOT the answer: a child port bound to a parent
    // net is the same signal as that net, so `u.a` denotes `p` and there is no
    // `u.a` to find. `Design.names` holds those aliases and nothing else.
    const flat = if (self.design.names.get(path)) |id| self.file.str(id) else path;
    assert(flat.len != 0);
    return flat;
}

/// §6.6.2 the unnamed generate block whose flat prefix the hierarchical name
/// `e` spells its way into from outside, or null. "Outside" is the unit that
/// wrote `e`: a unit instantiated inside the block is "within the hierarchy
/// instantiated by the generate block itself" and may name what it holds.
pub fn unnamedGenScope(self: *Lower, e: Ast.ExprId) Oom!?[]const u8 {
    assert(e == .none or self.exprValid(e));
    const scopes = self.unnamed_gen orelse blk: {
        var out: std.ArrayList([]const u8) = .empty;
        // A tree of one has no unit table; its module is the source's own.
        if (self.design.units.len == 0) {
            if (self.module) |m| try elab.unnamedGenScopes(self.file, self.arena, m, "", &out);
        } else for (self.design.units.items(.decl), self.design.units.items(.path)) |ud, up| try elab.unnamedGenScopes(self.file, self.arena, ud.get(self.file), up, &out);
        self.unnamed_gen = out.items;
        break :blk out.items;
    };
    if (scopes.len == 0) return null;
    const path = try elab.flatReference(self.file, self.arena, self.module, e);
    const own = if (self.cur_unit < self.design.units.len) self.design.units.items(.path)[self.cur_unit] else "";
    for (scopes) |s| if (std.mem.startsWith(u8, path, s) and !std.mem.startsWith(u8, own, s)) return s;
    assert(self.unnamed_gen != null); // the scopes are built once and kept
    return null;
}

/// Reports E0998 when `e` names something inside an unnamed generate block
/// from outside it (§6.6.2, §6.6.1; §6.6.3 "has no name that can be used in
/// a hierarchical name"), and returns whether it did.
pub fn refuseUnnamedGen(self: *Lower, e: Ast.ExprId) Oom!bool {
    assert(e == .none or self.exprValid(e));
    const scope = try unnamedGenScope(self, e) orelse return false;
    assert(scope.len != 0); // a flat prefix, ending in `elab.sep`
    var b = self.errWith(self.file.exprs.mainTok(e), .E0998);
    b.msg("`{s}` reaches into `{s}`, an unnamed generate block", .{
        try elab.flatReference(self.file, self.arena, self.module, e), scope[0 .. scope.len - 1],
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
    assert(e == .none or self.exprValid(e));
    assert(self.blockValid(self.cur));
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
    const near = diag.didYouMeanMap(Lower.VarSlot, name, self.vars) orelse
        diag.didYouMeanMap(u32, name, self.param_index) orelse
        diag.didYouMeanMap(u32, name, self.node_voltages) orelse
        diag.didYouMeanMap(Lower.BranchInfo, name, self.branches);
    if (near) |s| b.suggestHere(s);
    try b.emit();
    return poison;
}

/// §4.7.2/§6.8: does the function currently being inlined declare `name` as a
/// local parameter? True makes the local (in `consts`) win over a module
/// parameter of the same name — the shadowing §6.8's scope list requires.
pub fn funcParamShadows(self: *const Lower, name: []const u8) bool {
    assert(name.len != 0);
    for (self.func_params) |*p| {
        if (self.file.strings.eql(p.name, name)) return true;
    }
    return false;
}

// ---- private ----

/// §6.6.2: a generate block's declarations can be referenced hierarchically
/// "from within the hierarchy instantiated by the generate block itself",
/// and §6.8 (IEEE 1364-2005 12.7) searches a name "first at the current level
/// and then in higher level modules". Inside a generate block (`scope_path`,
/// its §6.6.3 name included for an unnamed one) `u1.gain` is first the
/// block's own `u1`, which the flatten named `genblk1.u1`: the innermost
/// enclosing scope whose prefix makes `path` name something, or null.
fn inScope(self: *Lower, path: []const u8) Oom!?[]const u8 {
    assert(path.len != 0);
    assert(self.scope_path.len != 0); // the caller asks only inside a scope
    const unit = if (self.cur_unit < self.design.units.len) self.design.units.items(.path)[self.cur_unit] else "";
    var scope = self.scope_path;
    // Each pass drops one trailing segment, so the walk ends within the
    // path's byte count.
    var steps: usize = 0;
    while (scope.len != 0) : (steps += 1) {
        assert(steps <= self.scope_path.len);
        const cand = try self.arena.print("{s}{s}{c}{s}", .{ unit, scope, elab.sep, path });
        const flat = if (self.design.names.get(cand)) |id| self.file.str(id) else cand;
        if (self.param_index.contains(flat) or self.vars.contains(flat) or self.consts.contains(flat) or
            self.node_voltages.contains(flat) or self.branches.contains(flat) or self.port_branches.contains(flat))
            return flat;
        scope = scope[0 .. std.mem.findScalarLast(u8, scope, elab.sep) orelse 0];
    }
    return null;
}
