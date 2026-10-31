//! One instance inlined: an instance, its module and its parent's unit →
//! the child's ports bound to the parent's nets (§6.2.2), its overrides
//! applied (§6.3, §6.4), every declaration renamed into the flat namespace
//! (§6.7) and its body cloned (`clone_*.zig`), appended to the flat module.
//! Cites: LRM §3.6.2, §5.6.1.3, §6.2.2, §6.3, §6.4.3, §6.5.7.1, §6.6, §6.7,
//! §6.8, §7.2.2, §9.15; IEEE 1364-2005 §12.3.3.
//!
//! Contents:
//! - `pub fn inlineInstance(self: *Flatten, inst: *const Ast.Instance, child: *const Ast.ModuleDecl, ps: ?*const Ast.ParamsetDecl, path: []const u8, gate: Ast.ExprId) Error!*const Unit`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const design = @import("design.zig");
const Flatten = @import("Flatten.zig");
const clone_decl = @import("clone_decl.zig");
const clone_expr = @import("clone_expr.zig");
const clone_stmt = @import("clone_stmt.zig");
const flat_name = @import("flat_name.zig");
const generate = @import("generate.zig");
const lookup = @import("lookup.zig");
const ooc = @import("ooc.zig");
const override = @import("override.zig");
const paramset = @import("paramset.zig");
const ports = @import("ports.zig");
const resolve = @import("resolve.zig");
const Error = design.Error;
const sep = design.sep;
const Unit = Flatten.Unit;

/// Inlines ONE instance: binds its ports, applies its §6.3 overrides, renames
/// its declarations into the flat namespace and clones its body, leaving its
/// unit in force for the walk to walk its instances under. Returns the unit
/// that was in force, which the walk puts back after them. `ps` is non-null
/// when the instance named a §6.4 PARAMSET: `child` is then the module the
/// paramset specializes and the instance's own `#(...)` overrides belong to
/// the paramset. `gate` is the scheme of the generate block `inst` sits in.
/// Asserts that `path` ends in `sep` (a flat name is `path ++ local`).
pub fn inlineInstance(
    self: *Flatten,
    inst: *const Ast.Instance,
    child: *const Ast.ModuleDecl,
    ps: ?*const Ast.ParamsetDecl,
    path: []const u8,
    gate: Ast.ExprId,
) Error!*const Unit {
    // `walk.nextChild` spells every child path `parent ++ leaf ++ sep`.
    assert(path.len != 0);
    assert(path[path.len - 1] == sep);
    const units_before = self.out.units.len;
    // Put back by the walk; the rename map is a stack.
    const parent = try self.ctx.arena.create(Unit);
    parent.* = self.unit;
    var unit: Unit = .{
        .path = path,
        .primitive = lookup.isPrimitive(self, child),
        .gate = if (gate == .none) parent.gate else try generate.conj(self, parent.gate, gate, false),
        .paramset_instance = if (ps != null) path[0 .. path.len - 1] else parent.paramset_instance,
        .module = child,
        .up = parent,
    };

    // §3.6.2 every out-of-context declaration naming a segment of this
    // instance was collected above it; judge each once, before it is applied.
    try ooc.checkOocOverrides(self, child, path);
    const bound = try ports.bindPorts(self, inst, child, parent, &unit, path);
    try ports.checkConnectionShape(self, inst, child);

    // §6.3 overrides, built before any name is renamed: an override's VALUE
    // is an expression in the parent (`#(.gain(scale*2))`) and its NAME is a
    // parameter of the child.
    var over: std.AutoHashMapUnmanaged(Ast.StrId, Ast.ExprId) = .empty;
    var ps_stmts: std.ArrayList(Ast.StmtId) = .empty;
    if (ps) |p| {
        try paramset.paramsetOverrides(self, inst, p, child, parent, &over, &unit, path, &ps_stmts);
        try hideParamsetVars(self, p, child, path);
    } else try override.collectOverrides(self, inst, child, parent, &over, &unit, path);

    try bindNames(self, &unit, child, path);
    self.unit = unit;
    try publishPorts(self, &unit, bound, path);
    try clone_decl.cloneParams(self, child.params, child.aliasparams, &over);
    try cloneDeclarations(self, child, path);

    // One id per INSTANCE, not per module: two instances of the same child
    // are two devices, and §5.6.1.3 must not let one discard the other's.
    // Appended in issue order, so `Design.units` row `unit_id` is this one.
    const unit_id: u32 = @intCast(self.out.units.len);
    try self.out.units.append(self.ctx.arena, .{ .module = child.name, .path = path, .decl = .of(self.ctx.file, child) });
    for (child.analog) |blk| try appendAnalog(self, &unit, unit_id, blk.is_initial, try clone_stmt.cloneStmt(self, blk.body), blk.main_tok);
    // §6.4.3 a paramset's statements, after the module's blocks: an output
    // variable "may be computed from values of any output parameters of the
    // module" (`.gm`), which those blocks compute.
    if (ps_stmts.items.len != 0) {
        const tok = ps.?.main_tok;
        try appendAnalog(self, &unit, unit_id, false, try self.ctx.file.addStmt(self.ctx.arena, .{ .block = .{ .body = ps_stmts.items } }, tok), tok);
    }
    try cloneDiscrete(self, &unit, inst, child);
    // Exactly this instance's row, after every row the clone added.
    assert(self.out.units.len == units_before + 1);
    assert(self.out.units.len == @as(usize, unit_id) + 1);
    return parent;
}

// ---- private ----

/// §6.4.3 an undescribed paramset variable hides the module's variable of the
/// same name from this instance's reporting. Only the selected paramset's own
/// declarations; a chain's earlier links are not read.
fn hideParamsetVars(self: *Flatten, ps: *const Ast.ParamsetDecl, child: *const Ast.ModuleDecl, path: []const u8) Error!void {
    assert(path.len != 0);
    const before = self.out.ps_hidden.items.len;
    for (ps.vars) |v| if (!v.desc) for (child.vars) |mv| if (mv.name == v.name)
        try self.out.ps_hidden.append(self.ctx.arena, try self.ctx.arena.print("{s}{s}", .{ path, self.ctx.file.str(v.name) }));
    assert(self.out.ps_hidden.items.len - before <= ps.vars.len * child.vars.len);
}

/// Every local declaration of `child` gets its flat spelling in `unit`; a
/// port `bindPorts` joined keeps its binding (`flat_name.bind`).
fn bindNames(self: *Flatten, unit: *Unit, child: *const Ast.ModuleDecl, path: []const u8) Error!void {
    assert(path.len != 0);
    const before = unit.rename.count();
    for (child.params) |p| try flat_name.bind(self, unit, path, p.name);
    for (child.aliasparams) |al| try flat_name.bind(self, unit, path, al.alias);
    for (child.nets) |n| try flat_name.bind(self, unit, path, n.name);
    for (child.vars) |v| try flat_name.bind(self, unit, path, v.name);
    for (child.branches) |b| try flat_name.bind(self, unit, path, b.name);
    for (child.genvars) |g| try flat_name.bind(self, unit, path, g);
    for (child.events) |e| try flat_name.bind(self, unit, path, e.name);
    for (child.functions) |fd| try flat_name.bind(self, unit, path, fd.name);
    for (child.instances) |sub| try flat_name.bind(self, unit, path, sub.name);
    for (self.genInstancesOf(child)) |sub| try flat_name.bind(self, unit, path, sub.name);
    assert(unit.rename.count() >= before);
}

/// The §6.5.7.1 rows of the ports `bindPorts` bound, their ranges cloned in
/// the child's names, which are now in force.
fn publishPorts(self: *Flatten, unit: *const Unit, bound: ports.Bindings, path: []const u8) Error!void {
    assert(self.unit.path.ptr == path.ptr);
    const before = self.out.port_concats.items.len + self.out.port_widths.items.len;
    for (bound.parts) |pb| {
        const name = unit.rename.get(pb.port.name).?;
        try self.out.port_concats.append(self.ctx.arena, .{
            .name = name,
            .range = try clone_decl.cloneDim(self, pb.port.range orelse pb.port.type_range),
            .parts = pb.parts,
            .main_tok = pb.tok,
        });
        try resolve.noteSignalDiscipline(self, name, ooc.oocDiscipline(self, path, pb.port.name) orelse pb.port.discipline);
    }
    for (bound.widths) |pw| try self.out.port_widths.append(self.ctx.arena, .{
        .net = pw.net,
        .range = try clone_decl.cloneDim(self, pw.port.range orelse pw.port.type_range),
        .main_tok = pw.tok,
    });
    assert(self.out.port_concats.items.len + self.out.port_widths.items.len == before + bound.parts.len + bound.widths.len);
}

/// The child's nets, variables, branches, genvars, events, functions and
/// attributes under their flat names, appended to the flat module.
fn cloneDeclarations(self: *Flatten, child: *const Ast.ModuleDecl, path: []const u8) Error!void {
    assert(path.len != 0);
    const branches_before = self.decls.branches.items.len;
    for (child.nets) |n| {
        // Annex F.2.1 step 3: a dotted declaration is an out-of-context one,
        // already collected by `ooc.collectOoc`. It declares no net HERE.
        if (ooc.isOoc(self.ctx.file.str(n.name))) continue;
        var out = n;
        out.name = flat_name.flat(self, n.name);
        out.range = try clone_decl.cloneDim(self, n.range);
        out.init = try clone_expr.cloneExpr(self, n.init);
        // §3.10 precedence order 1 on an internal net of the child: an
        // out-of-context declaration "overrides any discipline which may
        // be declared for sig in the module where sig was declared".
        if (ooc.oocDiscipline(self, path, n.name)) |d| out.discipline = d;
        try resolve.addNet(self, out);
    }
    for (child.vars) |v| try cloneVar(self, child, path, v);
    for (child.branches) |b| {
        var out = b;
        out.name = flat_name.flat(self, b.name);
        out.hi = try clone_expr.cloneExpr(self, b.hi);
        out.lo = try clone_expr.cloneExpr(self, b.lo);
        out.range = try clone_decl.cloneDim(self, b.range);
        try self.decls.branches.append(self.ctx.arena, out);
    }
    for (child.genvars) |g| try self.decls.genvars.append(self.ctx.arena, flat_name.flat(self, g));
    for (child.events) |e| try self.decls.events.append(self.ctx.arena, try clone_decl.cloneEvent(self, e));
    for (child.functions) |fd| try self.decls.functions.append(self.ctx.arena, try clone_decl.cloneFunc(self, fd));
    for (child.attrs) |at| try self.decls.attrs.append(self.ctx.arena, .{
        .name = at.name,
        .value = try clone_expr.cloneExpr(self, at.value),
        .main_tok = at.main_tok,
    });
    assert(self.decls.branches.items.len == branches_before + child.branches.len);
}

/// Appends variable `v` of `child` under its flat name. IEEE 1364-2005
/// §12.3.3 an output port "declared as a variable" is renamed with its port
/// onto the parent's net, so two such ports on one net (§9.22's two drivers)
/// are one flat name, and one declaration serves both: the digital half
/// resolves the net. §6.8: renamed onto the parent's net, the variable and
/// that net share a flat name from two scopes (`Design.port_vars`).
fn cloneVar(self: *Flatten, child: *const Ast.ModuleDecl, path: []const u8, v: Ast.VarDecl) Error!void {
    assert(path.len != 0);
    const out = try clone_decl.cloneVar(self, v);
    const port = for (child.ports) |p| {
        if (p.name == v.name) break true;
    } else false;
    const again = port and for (self.decls.vars.items) |seen| {
        if (seen.name == out.name) break true;
    } else false;
    if (again) return;
    try self.decls.vars.append(self.ctx.arena, out);
    const spelled = self.ctx.file.str(out.name);
    const local = self.ctx.file.str(v.name);
    const own = spelled.len == path.len + local.len and std.mem.startsWith(u8, spelled, path) and std.mem.endsWith(u8, spelled, local);
    if (port and !own) try self.out.port_vars.append(self.ctx.arena, out.name);
    assert(self.decls.vars.items[self.decls.vars.items.len - 1].name == out.name);
}

/// Appends one analog block of unit `unit_id`. §6.6 an instance a generate
/// scheme brings into existence behaves only while the scheme holds.
fn appendAnalog(self: *Flatten, unit: *const Unit, unit_id: u32, is_initial: bool, cloned: Ast.StmtId, tok: u32) Error!void {
    assert(unit_id != 0); // the top's blocks go in by `Flatten.run`, uncloned
    assert(unit_id < self.out.units.len);
    const body = if (unit.gate == .none) cloned else try self.ctx.file.addStmt(self.ctx.arena, .{ .if_stmt = .{
        .cond = unit.gate,
        .then_s = cloned,
        .else_s = .none,
        .is_generate = false,
    } }, tok);
    try self.decls.analog.append(self.ctx.arena, .{ .is_initial = is_initial, .body = body, .main_tok = tok, .unit = unit_id });
}

/// §7.2.2 the child's discrete half: its blocks, continuous assignments,
/// gates, pulls and switches, renamed. A gated child has no scheme for it to
/// run under (E0235).
fn cloneDiscrete(self: *Flatten, unit: *const Unit, inst: *const Ast.Instance, child: *const Ast.ModuleDecl) Error!void {
    assert(unit.module.? == child);
    const gates_before = self.decls.gates.items.len;
    // ponytail: a gated child's discrete half has no scheme to run under.
    if (unit.gate != .none and child.discrete.len + child.assigns.len + child.gates.len + child.pulls.len + child.switches.len != 0)
        try self.err(inst.main_tok, .E0235, "a module instance with discrete behavior", .{});
    const a = self.ctx.arena;
    for (child.discrete) |blk| try self.decls.discrete.append(a, .{
        .is_always = blk.is_always,
        .body = try clone_stmt.cloneStmt(self, blk.body),
        .main_tok = blk.main_tok,
    });
    for (child.assigns) |as| {
        var o = as;
        o.target = try clone_expr.cloneExpr(self, as.target);
        o.value = try clone_expr.cloneExpr(self, as.value);
        o.delay = try clone_decl.cloneDelay(self, as.delay);
        try self.decls.assigns.append(a, o);
    }
    for (child.gates) |g| {
        var o = g;
        o.out = try clone_expr.cloneExpr(self, g.out);
        const ins = try a.alloc(Ast.ExprId, g.ins.len);
        for (g.ins, ins) |src, *d| d.* = try clone_expr.cloneExpr(self, src);
        o.ins = ins;
        o.delay = try clone_decl.cloneDelay(self, g.delay);
        try self.decls.gates.append(a, o);
    }
    for (child.pulls) |p| {
        var o = p;
        o.out = try clone_expr.cloneExpr(self, p.out);
        try self.decls.pulls.append(a, o);
    }
    for (child.switches) |sw| {
        var o = sw;
        const terms = try a.alloc(Ast.ExprId, sw.terms.len);
        for (sw.terms, terms) |src, *d| d.* = try clone_expr.cloneExpr(self, src);
        o.terms = terms;
        o.delay = try clone_decl.cloneDelay(self, sw.delay);
        try self.decls.switches.append(a, o);
    }
    assert(self.decls.gates.items.len == gates_before + child.gates.len);
}

const elaborate = @import("elaborate.zig");
const fixture = @import("fixture.zig");

test "§6.6 a module instance with discrete behavior under a generate scheme is E0235" {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\module top(p); inout p; electrical p; parameter integer sel = 1;
        \\  generate if (sel) begin kid u(p); end endgenerate
        \\endmodule
        \\module kid(a); inout a; electrical a; reg q; initial q = 0; endmodule
    );
    try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(f.ctx()));
    try std.testing.expect(fixture.hasCode(&f.bag, .E0235));
}

test "§6.4.3 a paramset variable without a description hides the module's variable of that name" {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\module top(p); inout p; electrical p; ps u(p); endmodule
        \\paramset ps dev; real id; .scale = 4.0; endparamset
        \\module dev(a); inout a; electrical a; parameter real scale = 1.0; real id;
        \\  analog begin id = scale * V(a); I(a) <+ id; end
        \\endmodule
    );
    const d = try elaborate.elaborate(f.ctx());
    try std.testing.expectEqual(@as(usize, 1), d.ps_hidden.len);
    try std.testing.expectEqualStrings("u.id", d.ps_hidden[0]);
    const scale = fixture.paramNamed(&f.file, d.top, "u.scale").?;
    try std.testing.expect(scale.is_override);
    try std.testing.expectEqual(@as(f64, 4.0), f.file.exprs.realValue(scale.default));
}
