//! One instance inlined: an instance, its module and its parent's unit →
//! the child's ports bound to the parent's nets (§6.2.2), its overrides
//! applied (§6.3, §6.4), every declaration renamed into the flat namespace
//! (§6.7) and its body cloned (`clone_*.zig`), appended to the flat module.
//! Cites: LRM §3.6.5, §3.7, §5.4.3, §6.2.2, §6.3, §6.4.3, §6.5.7.1, §6.6,
//! §6.7, §6.7.1, §6.8, §9.15, §9.19, Annex E.3.2; IEEE 1364-2005 §12.3.3,
//! §19.9.
//!
//! Contents:

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const design = @import("design.zig");
const Flatten = @import("Flatten.zig");
const elaborate = @import("elaborate.zig");
const generate = @import("generate.zig");
const ports = @import("ports.zig");
const clone_decl = @import("clone_decl.zig");
const clone_expr = @import("clone_expr.zig");
const clone_stmt = @import("clone_stmt.zig");
const flat_name = @import("flat_name.zig");
const lookup = @import("lookup.zig");
const override = @import("override.zig");
const paramset = @import("paramset.zig");
const ooc = @import("ooc.zig");
const resolve = @import("resolve.zig");
const discipline = @import("discipline_rules.zig");
const sep = design.sep;
const Unit = Flatten.Unit;

// ---- private ----

pub fn inlineInstance(
    self: *Flatten,
    inst: *const Ast.Instance,
    child: *const Ast.ModuleDecl,
    /// §6.4 non-null when the instance named a PARAMSET: `child` is then the
    /// module the paramset specializes and the instance's own `#(...)`
    /// overrides belong to the paramset, not to `child`.
    ps: ?*const Ast.ParamsetDecl,
    path: []const u8,
    /// §6.6 the scheme of the generate block `inst` sits in (`genInstances`).
    gate: Ast.ExprId,
) design.Error!*const Unit {
    // `nextChild` spells every child path `parent ++ leaf ++ sep`.
    assert(path.len != 0);
    assert(path[path.len - 1] == sep);
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

    // ---- §6.2.2 port connections ---------------------------------------
    // Resolved in the PARENT's namespace, which means through the parent's
    // rename map: an actual naming a net of a mid-level module has already
    // been flattened to `u.n`.
    // At most one of each per child port.
    var concats: std.ArrayList(struct { port: Ast.Port, parts: []const design.NetPart, tok: u32 }) = try .initCapacity(self.ctx.arena, child.ports.len);
    var widths: std.ArrayList(struct { port: Ast.Port, net: Ast.StrId, tok: u32 }) = try .initCapacity(self.ctx.arena, child.ports.len);
    for (child.ports, 0..) |p, i| {
        const conn = ports.connectionFor(inst, p, i);
        try unit.connected.put(self.ctx.arena, p.name, conn != null and conn.?.expr != .none);
        // §6.5.7.1 a concatenated net expression, and §6.5.5's "scalar
        // member, sub-range" of a parent net: each a list of the parent's net
        // parts, bound element by element once the child's range is known.
        if (conn) |c| if (c.expr != .none and switch (self.ctx.file.exprs.tag(c.expr)) {
            .concat, .index => true,
            else => false, // else: a whole net (joined below) or not a net expression (E0906 below)
        }) {
            var parts: std.ArrayList(design.NetPart) = .empty;
            const is_concat = self.ctx.file.exprs.tag(c.expr) == .concat;
            var ok = true;
            if (is_concat) {
                for (self.ctx.file.exprs.args(c.expr)) |o| if (!try ports.netPart(self, parent, o, &parts)) {
                    ok = false;
                    break;
                };
            } else ok = try ports.netPart(self, parent, c.expr, &parts);
            if (!ok) {
                try self.err(c.main_tok, .E0906, "a port connection lists scalar nets, constant bit-selects and constant part-selects of nets", .{});
                continue;
            }
            const vector = p.range != null or p.type_range != null;
            if (is_concat and !vector) {
                try self.err(c.main_tok, .E0906, "a concatenation connects only a vector port, and `{s}` is scalar", .{self.ctx.file.str(p.name)});
                continue;
            }
            try unit.rename.put(self.ctx.arena, p.name, try flat_name.join(self, path, p.name));
            const local = ooc.oocDiscipline(self, path, p.name) orelse p.discipline;
            if (local != .none) try unit.port_disc.put(self.ctx.arena, p.name, local);
            try concats.append(self.ctx.arena, .{ .port = p, .parts = parts.items, .tok = c.main_tok });
            continue;
        };
        const actual: ?Ast.StrId = if (conn) |c| lookup.netRefName(self, c.expr) else null;
        if (actual == null) if (conn) |c| if (c.expr != .none) {
            // §6.2.2: "A connection can be a simple reference to a variable or
            // a net identifier, an expression or a blank. An expression can be
            // used for supplying a value to a module input port if it is a
            // digital port." A continuous (analog) input takes a net, so the
            // expression arm is the non-continuous one only.
            const local = ooc.oocDiscipline(self, path, p.name) orelse p.discipline;
            if (p.direction == .input and !discipline.isContinuous(self.ctx.file, local)) {
                // One synthesized net per port of this instance, named by the
                // child port's own hierarchical path (unique per instance),
                // driven by a continuous assignment in the parent's scope.
                const flat = try self.ctx.arena.print("{s}{s}", .{ path, self.ctx.file.str(p.name) });
                const name = try self.ctx.file.intern(self.ctx.arena, flat);
                try unit.rename.put(self.ctx.arena, p.name, name);
                try self.out.names.put(self.ctx.arena, flat, flat);
                try resolve.addNet(self, .{ .name = name, .discipline = local, .main_tok = c.main_tok });
                const target = try self.ctx.file.exprs.add(self.ctx.arena, .{
                    .tag = .ident,
                    .str = name,
                    .main_tok = c.main_tok,
                });
                try self.decls.assigns.append(self.ctx.arena, .{
                    .target = target,
                    .value = try clone_expr.cloneExpr(self, c.expr),
                    .main_tok = c.main_tok,
                });
                continue;
            }
        };
        if (actual) |n| {
            // The port is the parent's net: no new node, no new declaration.
            // ponytail: the parent map already owns this lookup and fallback.
            const bound = parent.rename.get(n) orelse n;
            // §5.4.3/§6.7.1 a port whose flow is read keeps a net of its own,
            // hung from the parent's by a branch nothing contributes to: the
            // flow probe whose current is the flow into the port.
            if (!unit.primitive and p.range == null and p.type_range == null and
                try ports.portFlowRead(self, child, parent.module, inst.name, p.name))
            {
                const internal = try flat_name.join(self, path, p.name);
                try resolve.addNet(self, .{
                    .name = internal,
                    .discipline = ooc.oocDiscipline(self, path, p.name) orelse p.discipline,
                    .main_tok = p.main_tok,
                });
                try self.out.port_ammeters.append(self.ctx.arena, .{
                    .internal = self.ctx.file.str(internal),
                    .bound = self.ctx.file.str(bound),
                });
                widths.appendAssumeCapacity(.{ .port = p, .net = bound, .tok = conn.?.main_tok });
                try resolve.resolveDiscipline(self, path, p, bound, conn.?.main_tok);
                try unit.rename.put(self.ctx.arena, p.name, internal);
                const port_path = try self.ctx.arena.print("{s}{s}", .{ path, self.ctx.file.str(p.name) });
                try self.out.names.put(self.ctx.arena, port_path, self.ctx.file.str(internal));
                const local = ooc.oocDiscipline(self, path, p.name) orelse p.discipline;
                if (local != .none) {
                    try unit.port_disc.put(self.ctx.arena, p.name, local);
                    try self.out.port_disciplines.put(self.ctx.arena, port_path, self.ctx.file.str(local));
                }
                continue;
            }
            // §3.7: "When the two nets connected by a port are of net type
            // wreal and wire/tri, the resulting single net will be assigned
            // as wreal." The runtime digital elaboration promotes the same
            // net (`sim.digital.elab.promoteWreal`); this half is what lets
            // analog lowering type the discrete input as a real.
            if (p.kind == .wreal) for (self.decls.nets.items) |*net| {
                if (net.name == bound and (net.kind == .wire or net.kind == .tri)) net.kind = .wreal;
            };
            try unit.rename.put(self.ctx.arena, p.name, bound);
            // §6.7.1 the port still has a hierarchical name that may be
            // probed, so the path resolves to the net it was joined to.
            // These are the only rows `design.Design.names` holds.
            const port_path = try self.ctx.arena.print("{s}{s}", .{ path, self.ctx.file.str(p.name) });
            try self.out.names.put(self.ctx.arena, port_path, self.ctx.file.str(bound));
            // E.3.2: a primitive's attribute was bound by `walkInstances`,
            // and its declared `electrical` is the default, bound last.
            // §4.4 otherwise the child's own declaration names its accesses.
            if (unit.primitive) {
                try self.res.prim_ports.append(self.ctx.arena, .{ .path = path, .port = p, .bound = bound });
            } else {
                widths.appendAssumeCapacity(.{ .port = p, .net = bound, .tok = conn.?.main_tok });
                try resolve.resolveDiscipline(self, path, p, bound, conn.?.main_tok);
                const local = ooc.oocDiscipline(self, path, p.name) orelse p.discipline;
                if (local != .none) {
                    try unit.port_disc.put(self.ctx.arena, p.name, local);
                    try self.out.port_disciplines.put(self.ctx.arena, port_path, self.ctx.file.str(local));
                }
            }
        } else {
            // §6.2.2 "a blank port connection shall represent the situation
            // where the port is not to be connected", and an omitted named
            // port is the same thing. The child's equations still reference
            // it, so it becomes an internal net carrying the port's discipline.
            const internal = try flat_name.join(self, path, p.name);
            try unit.rename.put(self.ctx.arena, p.name, internal);
            try resolve.addNet(self, .{
                .name = internal,
                // §3.10 order 1 still beats the local declaration on a port
                // nobody connected: the segment exists, it is just the only
                // segment of its signal.
                .discipline = ooc.oocDiscipline(self, path, p.name) orelse p.discipline,
                .main_tok = p.main_tok,
            });
            // IEEE 1364 §19.9 applies to unconnected input ports of the
            // modules declared between the directive pair, so the site is
            // the port's declaration in the child (`p.main_tok`), not the
            // instance.
            if (p.direction == .input) try self.out.unconnected_inputs.append(self.ctx.arena, .{
                .name = self.ctx.file.str(internal),
                .main_tok = p.main_tok,
            });
        }
        if (conn) |c| if (c.expr != .none and actual == null)
            try self.err(c.main_tok, .E0906, "a port connection must be a net reference", .{});
    }
    try ports.checkConnectionShape(self, inst, child);

    // ---- §6.3 parameter overrides --------------------------------------
    // Built before any name is renamed, because an override's VALUE is an
    // expression in the parent (`#(.gain(scale*2))`) and its NAME is a
    // parameter of the child.
    var over: std.AutoHashMapUnmanaged(Ast.StrId, Ast.ExprId) = .empty;
    var ps_stmts: std.ArrayList(Ast.StmtId) = .empty;
    if (ps) |p|
        try paramset.paramsetOverrides(self, inst, p, child, parent, &over, &unit, path, &ps_stmts)
    else
        try override.collectOverrides(self, inst, child, parent, &over, &unit, path);
    // §6.4.3 an undescribed paramset variable hides the module's variable of
    // the same name from this instance's reporting. Only the selected
    // paramset's own declarations; a chain's earlier links are not read.
    if (ps) |p| for (p.vars) |v| if (!v.desc) for (child.vars) |mv| if (mv.name == v.name)
        try self.out.ps_hidden.append(self.ctx.arena, try self.ctx.arena.print("{s}{s}", .{ path, self.ctx.file.str(v.name) }));

    // ---- names: every local declaration gets its flat spelling ----------
    for (child.params) |p| try flat_name.bind(self, &unit, path, p.name);
    for (child.aliasparams) |al| try flat_name.bind(self, &unit, path, al.alias);
    for (child.nets) |n| try flat_name.bind(self, &unit, path, n.name);
    for (child.vars) |v| try flat_name.bind(self, &unit, path, v.name);
    for (child.branches) |b| try flat_name.bind(self, &unit, path, b.name);
    for (child.genvars) |g| try flat_name.bind(self, &unit, path, g);
    for (child.events) |e| try flat_name.bind(self, &unit, path, e.name);
    for (child.functions) |fd| try flat_name.bind(self, &unit, path, fd.name);
    for (child.instances) |sub| try flat_name.bind(self, &unit, path, sub.name);
    for (self.genInstancesOf(child)) |sub| try flat_name.bind(self, &unit, path, sub.name);

    self.unit = unit;
    for (concats.items) |cc| {
        const name = unit.rename.get(cc.port.name).?;
        try self.out.port_concats.append(self.ctx.arena, .{
            .name = self.ctx.file.str(name),
            .range = try clone_decl.cloneDim(self, cc.port.range orelse cc.port.type_range),
            .parts = cc.parts,
            .main_tok = cc.tok,
        });
        try resolve.noteSignalDiscipline(self, name, ooc.oocDiscipline(self, path, cc.port.name) orelse cc.port.discipline);
    }
    for (widths.items) |pw| try self.out.port_widths.append(self.ctx.arena, .{
        .net = self.ctx.file.str(pw.net),
        .range = try clone_decl.cloneDim(self, pw.port.range orelse pw.port.type_range),
        .main_tok = pw.tok,
    });

    // ---- the declarations themselves -----------------------------------
    try clone_decl.cloneParams(self, child.params, child.aliasparams, &over);
    for (child.nets) |n| {
        // Annex F.2.1 step 3: a dotted declaration is an out-of-context one,
        // already collected by `resolve.collectOoc`. It declares no net HERE.
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
    for (child.vars) |v| {
        const out = try clone_decl.cloneVar(self, v);
        // IEEE 1364-2005 §12.3.3 an output port "declared as a variable"
        // is renamed with its port onto the parent's net, so two such
        // ports on one net (§9.22's two drivers) are one flat name. One
        // declaration serves both: the digital half resolves the net.
        const port = for (child.ports) |p| {
            if (p.name == v.name) break true;
        } else false;
        const again = port and for (self.decls.vars.items) |seen| {
            if (seen.name == out.name) break true;
        } else false;
        if (again) continue;
        try self.decls.vars.append(self.ctx.arena, out);
        // §6.8: renamed onto the parent's net, the variable and that net
        // share a flat name from two scopes (`design.Design.port_vars`).
        const flat_spelling = self.ctx.file.str(out.name);
        const local = self.ctx.file.str(v.name);
        const own = flat_spelling.len == path.len + local.len and std.mem.startsWith(u8, flat_spelling, path) and std.mem.endsWith(u8, flat_spelling, local);
        if (port and !own) try self.out.port_vars.append(self.ctx.arena, out.name);
    }
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
    // One id per INSTANCE, not per module: two instances of the same child
    // are two devices, and §5.6.1.3 must not let one discard the other's.
    const unit_id: u32 = @intCast(self.out.units.items.len);
    // Appended in issue order, so `design.Design.units[unit_id]` is this instance.
    try self.out.units.append(self.ctx.arena, .{
        .module = self.ctx.file.str(child.name),
        .path = path,
        .decl = child,
    });
    assert(self.out.units.items.len == @as(usize, unit_id) + 1); // `run` appended unit 0, the top
    for (child.analog) |blk| try appendAnalog(self, &unit, unit_id, blk.is_initial, try clone_stmt.cloneStmt(self, blk.body), blk.main_tok);
    // §6.4.3 a paramset's statements, after the module's blocks: an output
    // variable "may be computed from values of any output parameters of the
    // module" (`.gm`), which those blocks compute.
    if (ps_stmts.items.len != 0) {
        const tok = ps.?.main_tok;
        try appendAnalog(self, &unit, unit_id, false, try self.ctx.file.addStmt(self.ctx.arena, .{ .block = .{ .body = ps_stmts.items } }, tok), tok);
    }
    // ponytail: a gated child's discrete half has no scheme to run under.
    if (unit.gate != .none and child.discrete.len + child.assigns.len + child.gates.len + child.pulls.len + child.switches.len != 0)
        try self.err(inst.main_tok, .E0235, "a module instance with discrete behavior", .{});
    for (child.discrete) |blk| try self.decls.discrete.append(self.ctx.arena, .{
        .is_always = blk.is_always,
        .body = try clone_stmt.cloneStmt(self, blk.body),
        .main_tok = blk.main_tok,
    });
    for (child.assigns) |a| {
        var o = a;
        o.target = try clone_expr.cloneExpr(self, a.target);
        o.value = try clone_expr.cloneExpr(self, a.value);
        o.delay = try clone_decl.cloneDelay(self, a.delay);
        try self.decls.assigns.append(self.ctx.arena, o);
    }
    for (child.gates) |g| {
        var o = g;
        o.out = try clone_expr.cloneExpr(self, g.out);
        const ins = try self.ctx.arena.alloc(Ast.ExprId, g.ins.len);
        for (g.ins, ins) |src, *d| d.* = try clone_expr.cloneExpr(self, src);
        o.ins = ins;
        o.delay = try clone_decl.cloneDelay(self, g.delay);
        try self.decls.gates.append(self.ctx.arena, o);
    }
    for (child.pulls) |p| {
        var o = p;
        o.out = try clone_expr.cloneExpr(self, p.out);
        try self.decls.pulls.append(self.ctx.arena, o);
    }
    for (child.switches) |sw| {
        var o = sw;
        const terms = try self.ctx.arena.alloc(Ast.ExprId, sw.terms.len);
        for (sw.terms, terms) |src, *d| d.* = try clone_expr.cloneExpr(self, src);
        o.terms = terms;
        o.delay = try clone_decl.cloneDelay(self, sw.delay);
        try self.decls.switches.append(self.ctx.arena, o);
    }
    // `walkInstances` walks this unit's instances with its map in force.
    return parent;
}

/// Appends one analog block of unit `unit_id`. §6.6 an instance a generate
/// scheme brings into existence behaves only while the scheme holds.
fn appendAnalog(self: *Flatten, unit: *const Unit, unit_id: u32, is_initial: bool, cloned: Ast.StmtId, tok: u32) design.Error!void {
    const body = if (unit.gate == .none) cloned else try self.ctx.file.addStmt(self.ctx.arena, .{ .if_stmt = .{
        .cond = unit.gate,
        .then_s = cloned,
        .else_s = .none,
        .is_generate = false,
    } }, tok);
    try self.decls.analog.append(self.ctx.arena, .{
        .is_initial = is_initial,
        .body = body,
        .main_tok = tok,
        .unit = unit_id,
    });
}

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
