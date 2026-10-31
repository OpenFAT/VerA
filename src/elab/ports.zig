//! §6.2.2 port connections: an instance's connection list → the shape checks
//! (§6.5.5), the per-port binding rule (`connectionFor`), §6.5.7.1's net
//! parts of a concatenated or selected actual, and §5.4.3's question whether a
//! port's flow is read. Also §6.5.2.2's direction check over every module.
//! Cites: LRM §5.4.3, §6.2.2, §6.5, §6.5.2.2, §6.5.5, §6.5.7.1, §6.7.1,
//! A.1.3; IEEE 1364-2005 §5.2.1, §12.3.6.
//!
//! Contents:
//! - `pub fn connectionFor(inst: *const Ast.Instance, port: Ast.Port, i: usize) ?Ast.PortConn`
//! - `pub fn checkPortDirections(self: *Flatten) design.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const design = @import("design.zig");
const Flatten = @import("Flatten.zig");
const elaborate = @import("elaborate.zig");
const flat_name = @import("flat_name.zig");
const lookup = @import("lookup.zig");
const fold = @import("fold.zig");
const connect_rule = @import("connect_rule.zig");
const clone_expr = @import("clone_expr.zig");
const ooc = @import("ooc.zig");
const resolve = @import("resolve.zig");
const discipline = @import("discipline_rules.zig");
const sep = design.sep;
const Unit = Flatten.Unit;

/// Returns the connection that binds `port`, the i'th declared port, or
/// null when the list does not mention it (§6.2.2). The first entry decides
/// between named and ordered binding; a named list takes the first match.
pub fn connectionFor(inst: *const Ast.Instance, port: Ast.Port, i: usize) ?Ast.PortConn {
    // One binding rule for the walk and for `insert.plan`, which needs the index.
    return inst.ports[connect_rule.connIndex(inst, port, i) orelse return null];
}

/// §6.5.2.2 "Each port shall be declared as input, output, or inout
/// (bidirectional), in addition to any other declaration" (E0376), in every
/// user module, instantiated or not, once per compilation. A null port
/// (A.1.3, `nullPortName`'s tab-led name) names no net, so it has nothing
/// to declare.
pub fn checkPortDirections(self: *Flatten) design.Error!void {
    const file = self.ctx.file;
    for (file.userModules()) |*m| for (m.ports) |p| {
        if (p.direction != .unspecified) continue;
        const name = file.str(p.name);
        if (name.len > 0 and name[0] == '\t') continue;
        try self.err(p.main_tok, .E0376, "port `{s}` of module `{s}` is not declared `input`, `output` or `inout`", .{ name, file.str(m.name) });
    };
}

/// One child port bound to parts of parent nets (§6.5.7.1): its parts are a
/// run of `Flatten.out.net_parts`, its `PortConcat` row published once the
/// child's names are bound.
pub const PartBinding = struct { port: Ast.Port, parts: design.PartRange, tok: u32 };

/// One child port bound to a whole parent net, for §6.5.7.1's size check.
pub const WidthBinding = struct { port: Ast.Port, net: Ast.StrId, tok: u32 };

/// `bindPorts`' answer: the rows whose ranges must be cloned in the child's
/// names, which do not exist yet when the ports are bound.
pub const Bindings = struct { parts: []const PartBinding, widths: []const WidthBinding };

/// §6.2.2 binds every port of `child` for instance `inst` at `path`, resolved
/// in the PARENT's namespace (`parent.rename`: an actual naming a net of a
/// mid-level module was flattened to `u.n` already). Writes `unit`'s
/// `connected`, `rename` and `port_disc` rows, the published path rows
/// (`Design.names`, `port_disciplines`, `port_ammeters`,
/// `unconnected_inputs`), the nets a port needs (`resolve.addNet`) and
/// §7.4's discipline answers (`resolve.resolveDiscipline`). Reports E0906 for
/// an actual that is not a net reference. Asserts that `path` is a child path
/// (`parent ++ leaf ++ sep`) and that `unit` binds nothing yet.
pub fn bindPorts(
    self: *Flatten,
    inst: *const Ast.Instance,
    child: *const Ast.ModuleDecl,
    parent: *const Unit,
    unit: *Unit,
    path: []const u8,
) design.Error!Bindings {
    assert(path.len != 0);
    assert(path[path.len - 1] == sep);
    assert(unit.rename.count() == 0);
    var b: Binder = .{
        .self = self,
        .inst = inst,
        .child = child,
        .parent = parent,
        .unit = unit,
        .path = path,
        // At most one of each per child port.
        .parts = try .initCapacity(self.ctx.arena, child.ports.len),
        .widths = try .initCapacity(self.ctx.arena, child.ports.len),
    };
    for (child.ports, 0..) |p, i| try b.bind(p, connectionFor(inst, p, i));
    assert(b.parts.items.len + b.widths.items.len <= child.ports.len);
    assert(unit.connected.count() <= child.ports.len);
    return .{ .parts = b.parts.items, .widths = b.widths.items };
}

// ---- private ----

/// One instance's port binding (`bindPorts`): what every port's case reads,
/// and the two row lists it fills.
const Binder = struct {
    self: *Flatten,
    inst: *const Ast.Instance,
    child: *const Ast.ModuleDecl,
    parent: *const Unit,
    unit: *Unit,
    path: []const u8,
    parts: std.ArrayList(PartBinding),
    widths: std.ArrayList(WidthBinding),

    /// Binds port `p` through its connection `conn` (null: not mentioned).
    fn bind(b: *Binder, p: Ast.Port, conn: ?Ast.PortConn) design.Error!void {
        const self = b.self;
        try b.unit.connected.put(self.ctx.arena, p.name, conn != null and conn.?.expr != .none);
        // §6.5.7.1 a concatenated net expression, and §6.5.5's "scalar
        // member, sub-range" of a parent net: each a list of the parent's net
        // parts, bound element by element once the child's range is known.
        if (conn) |c| if (c.expr != .none and switch (self.ctx.file.exprs.tag(c.expr)) {
            .concat, .index => true,
            else => false, // else: a whole net (joined below) or not a net expression (E0906 below)
        }) return b.bindParts(p, c);
        const actual: ?Ast.StrId = if (conn) |c| lookup.netRefName(self, c.expr) else null;
        if (actual == null) if (conn) |c| if (c.expr != .none) {
            if (try b.bindExpression(p, c)) return;
        };
        if (actual) |n| {
            // The port is the parent's net: no new node, no new declaration.
            try b.bindNet(p, b.parent.rename.get(n) orelse n, conn.?.main_tok);
        } else try b.bindBlank(p);
        if (conn) |c| if (c.expr != .none and actual == null)
            try self.err(c.main_tok, .E0906, "a port connection must be a net reference", .{});
    }

    /// §6.5.7.1/§6.5.5: `p` is bound to the parts `c` lists, appended to
    /// `Flatten.out.net_parts` as one run; nothing is appended when a part is
    /// not a net part (E0906).
    fn bindParts(b: *Binder, p: Ast.Port, c: Ast.PortConn) design.Error!void {
        const self = b.self;
        const all = &self.out.net_parts;
        const start = all.items.len;
        const is_concat = self.ctx.file.exprs.tag(c.expr) == .concat;
        const ok = if (is_concat) for (self.ctx.file.exprs.args(c.expr)) |o| {
            if (!try netPart(self, b.parent, o, all)) break false;
        } else true else try netPart(self, b.parent, c.expr, all);
        if (!ok) {
            all.shrinkRetainingCapacity(start);
            return self.err(c.main_tok, .E0906, "a port connection lists scalar nets, constant bit-selects and constant part-selects of nets", .{});
        }
        const vector = p.range != null or p.type_range != null;
        if (is_concat and !vector) {
            all.shrinkRetainingCapacity(start);
            return self.err(c.main_tok, .E0906, "a concatenation connects only a vector port, and `{s}` is scalar", .{self.ctx.file.str(p.name)});
        }
        try b.unit.rename.put(self.ctx.arena, p.name, try flat_name.join(self, b.path, p.name));
        const local = ooc.oocDiscipline(self, b.path, p.name) orelse p.discipline;
        if (local != .none) try b.unit.port_disc.put(self.ctx.arena, p.name, local);
        const parts: design.PartRange = .{ .start = @intCast(start), .len = @intCast(all.items.len - start) };
        assert(parts.len != 0);
        b.parts.appendAssumeCapacity(.{ .port = p, .parts = parts, .tok = c.main_tok });
    }

    /// §6.2.2: "A connection can be a simple reference to a variable or a net
    /// identifier, an expression or a blank. An expression can be used for
    /// supplying a value to a module input port if it is a digital port." A
    /// continuous (analog) input takes a net, so the expression arm is the
    /// non-continuous one only: one synthesized net per port of this instance,
    /// named by the child port's own path, driven by a continuous assignment in
    /// the parent's scope. False when `p` takes no expression.
    fn bindExpression(b: *Binder, p: Ast.Port, c: Ast.PortConn) design.Error!bool {
        const self = b.self;
        assert(c.expr != .none);
        const local = ooc.oocDiscipline(self, b.path, p.name) orelse p.discipline;
        if (p.direction != .input or discipline.isContinuous(self.ctx.file, local)) return false;
        const flat = try self.ctx.arena.print("{s}{s}", .{ b.path, self.ctx.file.str(p.name) });
        const name = try self.ctx.file.intern(self.ctx.arena, flat);
        try b.unit.rename.put(self.ctx.arena, p.name, name);
        try self.out.names.put(self.ctx.arena, flat, name);
        try resolve.addNet(self, .{ .name = name, .discipline = local, .main_tok = c.main_tok });
        const target = try self.ctx.file.exprs.add(self.ctx.arena, .{ .tag = .ident, .str = name, .main_tok = c.main_tok });
        try self.decls.assigns.append(self.ctx.arena, .{
            .target = target,
            .value = try clone_expr.cloneExpr(self, c.expr),
            .main_tok = c.main_tok,
        });
        return true;
    }

    /// `p` joined to the parent's net `bound`: renamed onto it, or (§5.4.3)
    /// split onto an internal net of its own when its flow is read.
    fn bindNet(b: *Binder, p: Ast.Port, bound: Ast.StrId, tok: u32) design.Error!void {
        const self = b.self;
        const a = self.ctx.arena;
        const port_path = try a.print("{s}{s}", .{ b.path, self.ctx.file.str(p.name) });
        const local = ooc.oocDiscipline(self, b.path, p.name) orelse p.discipline;
        // §5.4.3/§6.7.1 a port whose flow is read keeps a net of its own,
        // hung from the parent's by a branch nothing contributes to: the
        // flow probe whose current is the flow into the port.
        if (!b.unit.primitive and p.range == null and p.type_range == null and
            try portFlowRead(self, b.child, b.parent.module, b.inst.name, p.name))
        {
            const internal = try flat_name.join(self, b.path, p.name);
            try resolve.addNet(self, .{ .name = internal, .discipline = local, .main_tok = p.main_tok });
            try self.out.port_ammeters.append(a, .{ .internal = internal, .bound = bound });
            b.widths.appendAssumeCapacity(.{ .port = p, .net = bound, .tok = tok });
            try resolve.resolveDiscipline(self, b.path, p, bound, tok);
            try b.unit.rename.put(a, p.name, internal);
            try self.out.names.put(a, port_path, internal);
            if (local != .none) {
                try b.unit.port_disc.put(a, p.name, local);
                try self.out.port_disciplines.put(a, port_path, local);
            }
            return;
        }
        // §3.7: "When the two nets connected by a port are of net type wreal
        // and wire/tri, the resulting single net will be assigned as wreal."
        // The runtime digital elaboration promotes the same net
        // (`sim.digital.elab.promoteWreal`); this half is what lets analog
        // lowering type the discrete input as a real.
        if (p.kind == .wreal) for (self.decls.nets.items) |*net| {
            if (net.name == bound and (net.kind == .wire or net.kind == .tri)) net.kind = .wreal;
        };
        try b.unit.rename.put(a, p.name, bound);
        // §6.7.1 the port still has a hierarchical name that may be probed,
        // so the path resolves to the net it was joined to.
        try self.out.names.put(a, port_path, bound);
        // E.3.2: a primitive's attribute was bound by `walk.enterLevel`, and
        // its declared `electrical` is the default, bound last. §4.4
        // otherwise the child's own declaration names its accesses.
        if (b.unit.primitive) {
            try self.res.prim_ports.append(a, .{ .path = b.path, .port = p, .bound = bound });
            return;
        }
        b.widths.appendAssumeCapacity(.{ .port = p, .net = bound, .tok = tok });
        try resolve.resolveDiscipline(self, b.path, p, bound, tok);
        if (local != .none) {
            try b.unit.port_disc.put(a, p.name, local);
            try self.out.port_disciplines.put(a, port_path, local);
        }
    }

    /// §6.2.2 "a blank port connection shall represent the situation where the
    /// port is not to be connected", and an omitted named port is the same
    /// thing. The child's equations still reference it, so it becomes an
    /// internal net carrying the port's discipline: §3.10 order 1 still beats
    /// the local declaration on it.
    fn bindBlank(b: *Binder, p: Ast.Port) design.Error!void {
        const self = b.self;
        const internal = try flat_name.join(self, b.path, p.name);
        try b.unit.rename.put(self.ctx.arena, p.name, internal);
        try resolve.addNet(self, .{
            .name = internal,
            .discipline = ooc.oocDiscipline(self, b.path, p.name) orelse p.discipline,
            .main_tok = p.main_tok,
        });
        // IEEE 1364 §19.9 applies to unconnected input ports of the modules
        // declared between the directive pair, so the site is the port's
        // declaration in the child (`p.main_tok`), not the instance.
        if (p.direction == .input) try self.out.unconnected_inputs.append(self.ctx.arena, .{ .name = internal, .main_tok = p.main_tok });
    }
};

/// §6.5 "Ports provide a means of interconnecting instances of modules. If a
/// module A instantiates module B, the ports of module B are associated with
/// either the ports or the internal nets of module A." A VARIABLE of A is
/// neither, so it cannot stand as the actual of B's continuous port: there is
/// no node for the port to join (§6.5.1 lists the port expressions, every one
/// of them a net), and it is not an implicit net either (`declared`, the
/// nets `module` declares).
///
/// Only a port of CONTINUOUS discipline: a real variable driving a discrete
/// or `wreal` input is a real EXPRESSION, which §3.7 and IEEE 1364's input
/// port rules allow, and the mixed-signal kernel decides those.
pub fn checkVariableActuals(self: *Flatten, module: *const Ast.ModuleDecl, declared: *const std.AutoHashMapUnmanaged(Ast.StrId, void), inst: *const Ast.Instance) design.Error!void {
    const child = lookup.findModule(self, inst.module) orelse return;
    for (child.ports, 0..) |p, i| {
        const c = connectionFor(inst, p, i) orelse continue;
        const n = lookup.netRefName(self, c.expr) orelse continue;
        if (declared.contains(n)) continue;
        const is_var = for (module.vars) |v| {
            if (v.name == n) break true;
        } else false;
        if (!is_var or p.discipline == .none or !discipline.isContinuous(self.ctx.file, p.discipline)) continue;
        try self.err(c.main_tok, .E0906, "`{s}` is a variable, and port `{s}` of `{s}` has the continuous discipline `{s}`: it joins only a net", .{
            self.ctx.file.str(n), self.ctx.file.str(p.name), self.ctx.file.str(child.name), self.ctx.file.str(p.discipline),
        });
    }
}

/// The ways a connection list can be malformed: longer than the port list,
/// naming a port that does not exist, mixing the two spellings, or naming
/// one port twice. §6.2.2 permits it to be shorter: that is the
/// omitted-port spelling of "not to be connected".
///
/// The list's FIRST entry decides which spelling it is (`connectionFor`
/// binds by the same test), so a mix is diagnosed relative to that. §6.5.5:
/// "The two types of module port connections can not be mixed; connections
/// to the ports of a particular module instance shall be all by order or
/// all by name."
pub fn checkConnectionShape(self: *Flatten, inst: *const Ast.Instance, child: *const Ast.ModuleDecl) design.Error!void {
    const named = inst.ports.len != 0 and inst.ports[0].name != .none;
    if (!named) {
        if (inst.ports.len > child.ports.len) try self.err(
            inst.ports[child.ports.len].main_tok,
            .E0906,
            "`{s}` declares {d} port{s}, and this instance connects {d}",
            .{ self.ctx.file.str(child.name), child.ports.len, if (child.ports.len == 1) "" else "s", inst.ports.len },
        );
        // An ordered list binds by position, so a `.name(...)` inside one
        // would be ignored silently; the named loop below cannot see it.
        for (inst.ports) |c| if (c.name != .none) try self.err(
            c.main_tok,
            .E0906,
            "a named connection in a list of ordered connections",
            .{},
        );
        return;
    }
    for (inst.ports, 0..) |c, i| {
        if (c.name == .none) {
            try self.err(c.main_tok, .E0906, "an ordered connection in a list of named connections", .{});
            continue;
        }
        const found = for (child.ports) |p| {
            if (p.connName() == c.name) break true;
        } else false;
        if (!found) {
            try self.err(c.main_tok, .E0906, "`{s}` is not a port of `{s}`", .{
                self.ctx.file.str(c.name), self.ctx.file.str(child.name),
            });
            continue;
        }
        // IEEE 1364 §12.3.6: a port is connected at most once.
        // `connectionFor` takes the first match, so a second `.a(...)`
        // would otherwise be dropped silently.
        for (inst.ports[0..i]) |prev| if (prev.name == c.name) {
            try self.err(c.main_tok, .E0906, "`{s}` is connected twice", .{self.ctx.file.str(c.name)});
            break;
        };
    }
}

/// §5.4.3 whether the flow into `port` of an instance of `child` is read:
/// by the child itself (`I(<port>)`, or `I(pb)` of a §3.12.1 port branch on
/// it), or by the parent through §6.7.1's `I(<inst.port>)` /
/// `I(inst.branch(<port>))`.
/// ponytail: a reader two or more levels up keeps `lower_expr.instancePortFlow`'s
/// sum of flow contributions; scanning every ancestor is the upgrade.
pub fn portFlowRead(self: *Flatten, child: *const Ast.ModuleDecl, parent: ?*const Ast.ModuleDecl, inst: Ast.StrId, port: Ast.StrId) design.Error!bool {
    const file = self.ctx.file;
    const x = &file.exprs;
    const Scan = struct {
        flat: *Flatten,
        module: *const Ast.ModuleDecl,
        /// The child's own reads match `port`; the parent's, `want`.
        port: Ast.StrId,
        want: ?[]const u8,
        found: *bool,
        pub fn expr(w: @This(), e: Ast.ExprId, _: Ast.SourceFile.Edge) design.Error!void {
            if (e == .none or w.found.*) return;
            const fx = &w.flat.ctx.file.exprs;
            const tag = fx.tag(e);
            if (tag == .port_access or (tag == .branch_access and fx.rhs(e) == .none)) {
                var t = fx.lhs(e);
                if (t != .none and fx.tag(t) == .index) t = fx.lhs(t);
                if (t != .none) if (w.want) |want| {
                    if (tag == .port_access and fx.tag(t) == .hier_ident and
                        std.mem.eql(u8, try flat_name.flatReference(w.flat.ctx.file, w.flat.ctx.arena, w.module, t), want)) w.found.* = true;
                } else if (fx.tag(t) == .ident) {
                    const name = fx.strOf(t);
                    if (tag == .port_access and name == w.port) w.found.* = true;
                    if (tag == .branch_access) for (w.module.branches) |b| if (b.is_port_branch and b.name == name) {
                        var h = b.hi;
                        if (h != .none and fx.tag(h) == .index) h = fx.lhs(h);
                        if (h != .none and fx.tag(h) == .ident and fx.strOf(h) == w.port) w.found.* = true;
                    };
                };
            }
            var buf: [3]Ast.ExprId = undefined;
            for (fx.children(e, &buf)) |c| try w.expr(c, .read);
        }
        pub fn stmt(w: @This(), s: Ast.StmtId) design.Error!void {
            if (s != .none and !w.found.*) try w.flat.ctx.file.stmtEdges(s, w);
        }
    };
    _ = x;
    var found = false;
    const own: Scan = .{ .flat = self, .module = child, .port = port, .want = null, .found = &found };
    for (child.analog) |blk| try own.stmt(blk.body);
    if (found) return true;
    const up = parent orelse return false;
    const want = try std.mem.concat(self.ctx.arena, u8, &.{ file.str(inst), &[_]u8{sep}, file.str(port) });
    const above: Scan = .{ .flat = self, .module = up, .port = port, .want = want, .found = &found };
    for (up.analog) |blk| try above.stmt(blk.body);
    return found;
}

/// Appends the parent net part `e` names: a net `x` whole, §6.5.5's scalar
/// member `bus[1]`, its sub-range `bus[3:2]`, or IEEE 1364-2005 §5.2.1's
/// `bus[i +: 2]` (a sub-range by A.2.1.3's constant_range_expression). The
/// bounds fold in the parent's names, a genvar's value included; whether
/// they lie in the net's declared range is lowering's to judge (E0352).
/// Returns false for anything else: a non-constant bound, or an expression
/// that is not a net.
pub fn netPart(self: *Flatten, parent: *const Unit, e: Ast.ExprId, out: *std.ArrayList(design.NetPart)) design.Error!bool {
    assert(e != .none);
    const ex = &self.ctx.file.exprs;
    const base = if (ex.tag(e) == .index) ex.lhs(e) else e;
    const n = lookup.netRefName(self, base) orelse return false;
    const net = parent.rename.get(n) orelse n;
    if (base == e) {
        try out.append(self.ctx.arena, .{ .net = net });
        return true;
    }
    const sel = ex.rhs(e);
    const two = ex.tag(sel) == .range or ex.tag(sel) == .indexed_range;
    // `constInt` folds in `self.unit`, which is still the parent here.
    const a = fold.constInt(self, if (two) ex.lhs(sel) else sel) orelse return false;
    const b = if (two) fold.constInt(self, ex.rhs(sel)) orelse return false else a;
    try out.append(self.ctx.arena, .{
        .net = net,
        .sel = if (!two) .bit else if (ex.tag(sel) == .range) .range else if (ex.extraOf(sel) != 0) .down else .up,
        .a = a,
        .b = b,
    });
    return true;
}

const fixture = @import("fixture.zig");

test connectionFor {
    const e1: Ast.ExprId = @fromBackingInt(@as(u32, 1));
    const e2: Ast.ExprId = @fromBackingInt(@as(u32, 2));
    const a: Ast.StrId = @fromBackingInt(@as(u32, 10));
    const b: Ast.StrId = @fromBackingInt(@as(u32, 11));
    const ordered: Ast.Instance = .{ .module = a, .name = a, .ports = &.{ .{ .expr = e1 }, .{ .expr = e2 } } };
    try std.testing.expectEqual(e2, connectionFor(&ordered, .{ .name = b }, 1).?.expr);
    try std.testing.expect(connectionFor(&ordered, .{ .name = b }, 2) == null);
    const named: Ast.Instance = .{ .module = a, .name = a, .ports = &.{ .{ .name = b, .expr = e1 }, .{ .name = a, .expr = e2 } } };
    try std.testing.expectEqual(e2, connectionFor(&named, .{ .name = a }, 0).?.expr);
    try std.testing.expectEqual(e1, connectionFor(&named, .{ .name = b }, 1).?.expr);
}

test checkPortDirections {
    // §6.5.2.2: `c` has a discipline and no direction (#73). `kid` is never
    // instantiated, and is still checked.
    var bad: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer bad.deinit();
    try fixture.parse(&bad,
        \\discipline ca; domain continuous; enddiscipline
        \\module top(p); inout p; ca p; endmodule
        \\module kid(c); ca c; endmodule
    );
    try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(bad.ctx()));
    try std.testing.expect(fixture.hasCode(&bad.bag, .E0376));

    // The legal neighbour declares the direction; a null port (A.1.3) names
    // no net and so has no direction to declare.
    var good: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer good.deinit();
    try fixture.parse(&good,
        \\discipline ca; domain continuous; enddiscipline
        \\module top(p, ); inout p; ca p; endmodule
        \\module kid(c); inout c; ca c; endmodule
    );
    _ = try elaborate.elaborate(good.ctx());
    try std.testing.expect(!fixture.hasCode(&good.bag, .E0376));
}

test "§6.5.5 a connection list is all ordered or all named, at most as long as the ports, each port once (E0906)" {
    const src =
        \\module top(p); inout p; electrical p; kid u{s}; endmodule
        \\module kid(a, b); inout a, b; electrical a, b; endmodule
    ;
    for ([_][]const u8{
        "(p, p, p)", // longer than the port list
        "(p, .b(p))", // a named connection in an ordered list
        "(.a(p), p)", // an ordered connection in a named list
        "(.zz(p))", // no such port
        "(.a(p), .a(p))", // IEEE 1364 §12.3.6 connected twice
    }) |conns| {
        var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
        defer f.deinit();
        try fixture.parse(&f, try f.arena.allocator().print(src, .{conns}));
        try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(f.ctx()));
        try std.testing.expect(fixture.hasCode(&f.bag, .E0906));
    }
    // §6.2.2 permits a shorter list: `b` is then unconnected.
    var good: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer good.deinit();
    try fixture.parse(&good, try good.arena.allocator().print(src, .{"(.a(p))"}));
    _ = try elaborate.elaborate(good.ctx());
}

test "§6.5 a variable cannot stand for a continuous port (E0906); a net can" {
    const src =
        \\discipline ca; domain continuous; enddiscipline
        \\module top(p); inout p; ca p; {s} kid u(x); endmodule
        \\module kid(a); inout a; ca a; endmodule
    ;
    var bad: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer bad.deinit();
    try fixture.parse(&bad, try bad.arena.allocator().print(src, .{"real x;"}));
    try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(bad.ctx()));
    try std.testing.expect(fixture.hasCode(&bad.bag, .E0906));

    var good: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer good.deinit();
    try fixture.parse(&good, try good.arena.allocator().print(src, .{"ca x;"}));
    _ = try elaborate.elaborate(good.ctx());
}

test "§6.2.2 a blank connection is an internal net and §9.19 $port_connected says so" {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\module top(p); inout p; electrical p; kid u(p, ); endmodule
        \\module kid(a, b); inout a; input b; electrical a, b;
        \\  analog I(a) <+ $port_connected(a);
        \\  analog I(a) <+ $port_connected(b);
        \\endmodule
    );
    const d = try elaborate.elaborate(f.ctx());
    // The input `b` is "not to be connected": its own net, judged later
    // against IEEE 1364 §19.9 `unconnected_drive`.
    try std.testing.expectEqual(@as(usize, 1), d.unconnected_inputs.len);
    try std.testing.expectEqualStrings("u.b", f.file.str(d.unconnected_inputs[0].name));
    try std.testing.expect(fixture.netNamed(&f.file, d.top, "u.b") != null);
    const x = &f.file.exprs;
    try std.testing.expectEqual(@as(i64, 1), x.intValue(f.file.stmt(d.top.analog[0].body).contribute.rhs));
    try std.testing.expectEqual(@as(i64, 0), x.intValue(f.file.stmt(d.top.analog[1].body).contribute.rhs));
}

test "§3.6.5 an actual the parent never declared is an implicit net, reported and given the port's discipline" {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\module top(p); inout p; electrical p; kid u(q); endmodule
        \\module kid(a); inout a; electrical a; endmodule
    );
    const d = try elaborate.elaborate(f.ctx());
    try std.testing.expectEqual(@as(usize, 1), d.implicit_nets.len);
    try std.testing.expectEqualStrings("q", f.file.str(d.implicit_nets[0].name));
    try std.testing.expectEqualStrings("electrical", f.file.str(fixture.netNamed(&f.file, d.top, "q").?.discipline));
}

test "§6.5.7.1 a concatenation or a constant select binds a port to parts of parent nets" {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\discipline electrical; domain continuous; enddiscipline
        \\module top(a, b); inout a, b; electrical a, b; electrical [3:0] bus;
        \\  kid u({a, b}); one w1(bus[1]); one w2(bus[3:2]); one w3(bus[1 +: 2]); one w4(bus[3 -: 2]);
        \\endmodule
        \\module kid(v); inout [1:0] v; electrical [1:0] v; endmodule
        \\module one(s); inout s; electrical s; endmodule
    );
    const d = try elaborate.elaborate(f.ctx());
    const Part = struct { net: []const u8, sel: design.NetPart.Select = .whole, a: i64 = 0, b: i64 = 0 };
    const Want = struct { name: []const u8, vector: bool, parts: []const Part };
    const want = [_]Want{
        .{ .name = "u.v", .vector = true, .parts = &.{ .{ .net = "a" }, .{ .net = "b" } } },
        .{ .name = "w1.s", .vector = false, .parts = &.{.{ .net = "bus", .sel = .bit, .a = 1, .b = 1 }} },
        .{ .name = "w2.s", .vector = false, .parts = &.{.{ .net = "bus", .sel = .range, .a = 3, .b = 2 }} },
        .{ .name = "w3.s", .vector = false, .parts = &.{.{ .net = "bus", .sel = .up, .a = 1, .b = 2 }} },
        .{ .name = "w4.s", .vector = false, .parts = &.{.{ .net = "bus", .sel = .down, .a = 3, .b = 2 }} },
    };
    try std.testing.expectEqual(want.len, d.port_concats.len);
    for (want, d.port_concats) |w, got| {
        try std.testing.expectEqualStrings(w.name, f.file.str(got.name));
        try std.testing.expectEqual(w.vector, got.range != null);
        try std.testing.expectEqual(w.parts.len, got.parts.len);
        for (w.parts, got.parts.of(d.net_parts)) |wp, gp| {
            try std.testing.expectEqualStrings(wp.net, f.file.str(gp.net));
            try std.testing.expectEqual(wp.sel, gp.sel);
            try std.testing.expectEqual(wp.a, gp.a);
            try std.testing.expectEqual(wp.b, gp.b);
        }
    }
}

test "§6.7.1 a connected port's path names the parent's net; an internal net needs no row" {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\discipline electrical; domain continuous; enddiscipline
        \\module top(p, n); inout p, n; electrical p, n; kid u(p, n); endmodule
        \\module kid(a, b); inout a, b; electrical a, b; electrical w; endmodule
    );
    const d = try elaborate.elaborate(f.ctx());
    try std.testing.expectEqual(@as(u32, 2), d.names.count());
    try std.testing.expectEqualStrings("p", f.file.str(d.names.get("u.a").?));
    try std.testing.expectEqualStrings("n", f.file.str(d.names.get("u.b").?));
    try std.testing.expect(d.names.get("u.w") == null);
    try std.testing.expect(fixture.netNamed(&f.file, d.top, "u.w") != null);
    // §6.5.7.1 one size check per port bound to a net.
    try std.testing.expectEqual(@as(usize, 2), d.port_widths.len);
    try std.testing.expectEqualStrings("p", f.file.str(d.port_widths[0].net));
    try std.testing.expect(d.port_widths[0].range == null);
}
