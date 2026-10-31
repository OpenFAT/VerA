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
const Ast = @import("frontend").Ast;
const design = @import("design.zig");
const Flatten = @import("Flatten.zig");
const elaborate = @import("elaborate.zig");
const flat_name = @import("flat_name.zig");
const lookup = @import("lookup.zig");
const fold = @import("fold.zig");
const connect_rule = @import("connect_rule.zig");
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

// ---- private ----

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

/// Inline ONE instance: bind its ports, apply its §6.3 overrides, rename its
/// declarations into the flat namespace and clone its body, leaving its unit
/// in force for `walkInstances` to walk its instances under. Returns the
/// unit that was in force, which the walk puts back after them.
///
/// `path` already ends in `sep`, so a flat name is `path ++ local`.
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
    const ex = &self.ctx.file.exprs;
    const base = if (ex.tag(e) == .index) ex.lhs(e) else e;
    const n = lookup.netRefName(self, base) orelse return false;
    const net = self.ctx.file.str(parent.rename.get(n) orelse n);
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
    try std.testing.expectEqualStrings("u.b", d.unconnected_inputs[0].name);
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
    try std.testing.expectEqualStrings("q", d.implicit_nets[0].name);
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
    const NetPart = design.NetPart;
    const Want = struct { name: []const u8, vector: bool, parts: []const NetPart };
    const want = [_]Want{
        .{ .name = "u.v", .vector = true, .parts = &.{ .{ .net = "a" }, .{ .net = "b" } } },
        .{ .name = "w1.s", .vector = false, .parts = &.{.{ .net = "bus", .sel = .bit, .a = 1, .b = 1 }} },
        .{ .name = "w2.s", .vector = false, .parts = &.{.{ .net = "bus", .sel = .range, .a = 3, .b = 2 }} },
        .{ .name = "w3.s", .vector = false, .parts = &.{.{ .net = "bus", .sel = .up, .a = 1, .b = 2 }} },
        .{ .name = "w4.s", .vector = false, .parts = &.{.{ .net = "bus", .sel = .down, .a = 3, .b = 2 }} },
    };
    try std.testing.expectEqual(want.len, d.port_concats.len);
    for (want, d.port_concats) |w, got| {
        try std.testing.expectEqualStrings(w.name, got.name);
        try std.testing.expectEqual(w.vector, got.range != null);
        try std.testing.expectEqual(w.parts.len, got.parts.len);
        for (w.parts, got.parts) |wp, gp| {
            try std.testing.expectEqualStrings(wp.net, gp.net);
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
    try std.testing.expectEqualStrings("p", d.names.get("u.a").?);
    try std.testing.expectEqualStrings("n", d.names.get("u.b").?);
    try std.testing.expect(d.names.get("u.w") == null);
    try std.testing.expect(fixture.netNamed(&f.file, d.top, "u.w") != null);
    // §6.5.7.1 one size check per port bound to a net.
    try std.testing.expectEqual(@as(usize, 2), d.port_widths.len);
    try std.testing.expectEqualStrings("p", d.port_widths[0].net);
    try std.testing.expect(d.port_widths[0].range == null);
}
