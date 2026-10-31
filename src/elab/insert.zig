//! §7.8 automatic insertion of connect modules: one module's instance list →
//! the same list with every mixed port (and gate terminal, §7.8.5.1)
//! re-pointed at a new segment, plus one connect-module instance per segment
//! for the walk to inline like any other child.
//! Cites: LRM §3.9, §6.9.3, §7.8.2, §7.8.3, §7.8.4, §7.8.5, §7.8.5.1;
//! IEEE 1364-2005 §7.1.5.
//!
//! Contents:
//! - `pub fn plan(self: *Flatten, module: *const Ast.ModuleDecl, path: []const u8, src: []const Ast.Instance, gates: []const Ast.ExprId) design.Error![]const Ast.Instance`
//! - `pub fn moduleOf(self: *Flatten, inst: *const Ast.Instance, path: []const u8) design.Error!?*const Ast.ModuleDecl`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Preprocessor = @import("frontend").Preprocessor;
const design = @import("design.zig");
const Flatten = @import("Flatten.zig");
const elaborate = @import("elaborate.zig");
const flat_name = @import("flat_name.zig");
const lookup = @import("lookup.zig");
const fold = @import("fold.zig");
const paramset_select = @import("paramset_select.zig");
const resolve = @import("resolve.zig");
const segment = @import("segment.zig");
const connect_rule = @import("connect_rule.zig");
const sep = design.sep;
const fixture = @import("fixture.zig");

/// One mixed port that matched exactly one rule.
const Hit = struct {
    /// The instance's index in `src`, and its connection's index.
    inst: usize,
    conn: usize,
    /// Or a primitive's terminal (`Ast.PrimTerm`).
    prim: ?Prim = null,
    /// §7.8.5's InstName.
    name: Ast.StrId,
    rule: usize,
    /// The upper connection, a name in THIS module (§7.8.5's SigName).
    sig: Ast.StrId,
    /// The lower connection's discipline (§7.8.5's BottomDiscipline).
    bottom: Ast.StrId,
    port: Ast.StrId,
};

/// A primitive terminal `plan` bridges, and its row in the flat list
/// (`Flatten.gates`, `pulls` or `switches`).
const Prim = struct { term: Ast.PrimTerm, flat: usize };

/// The instances of `module` as §7.8.4 leaves them: `src` is its source
/// instances, then its §6.6 generate instances, whose schemes `gates` holds
/// from index `module.instances.len` on (one whose scheme does not hold is
/// not planned). Every port matched by a connect statement is bound to a
/// fresh digital segment instead of its upper connection, and the connect
/// module instances bridging the two are appended after the originals, so
/// `src.len` is the index at which the auto-inserted ones begin. Returns
/// `src` itself when nothing is mixed; otherwise the list is new, in the
/// arena. Reports E0922 for a port that matches more than one connect
/// statement. Asserts that `gates` holds exactly the generate instances'
/// schemes, `src.len == module.instances.len + gates.len` (`enterLevel`).
///
/// §7.8.4: "A connection shall be selected for a port only
/// if one of the connections to the port is digital and the other is analog.
/// In this case, the port shall match one (and only one) connect statement";
/// "The connect module for a port shall be instantiated in the context of the
/// ports upper connection" (this module); "All ports connecting to the same
/// signal (upper connection), sharing the same connect module, and having
/// merged parameter shall share a single instance of the selected connect
/// module. All other ports shall have an instance of the selected connect
/// module".
///
/// Both connections are read as §7.4 resolution leaves them
/// (`segment.up`/`segment.down`), not as declared: "The disciplines of mixed
/// nets are determined prior to the connect module insertion phase of
/// elaboration" (§7.6). So an undeclared port takes the discipline its
/// segment resolved to, and under §7.4.4.2's detail mode an undeclared
/// digital segment below an analog one is analog, which moves the bridge down
/// to its discrete children. A port both of whose domains are known and that
/// no statement matches is E0927, and one whose upper connection this pass
/// could not decide is judged by the net the walk resolves: both are left
/// joined and recorded in `unbridged`, for `checkUnbridged` after the walk.
///
/// ponytail: rules are read only from connect modules with exactly one
/// continuous and one discrete port (every §7.6 example). Supply-sensitive
/// bridges with a third port (§7.8.6) are the upgrade.
pub fn plan(self: *Flatten, module: *const Ast.ModuleDecl, path: []const u8, src: []const Ast.Instance, gates: []const Ast.ExprId) design.Error![]const Ast.Instance {
    // Per level: without the first walk's list (`Flatten.tree_ooc`), an
    // out-of-context declaration below is collected only when its module is
    // walked (`resolve.collectOoc`), so an answer cached for the level above
    // may predate it.
    assert(src.len == module.instances.len + gates.len); // `enterLevel`'s, consumed here
    self.seg.up.clearRetainingCapacity();
    self.seg.index.clearRetainingCapacity();
    var n_ins: usize = 0;
    for (self.ctx.file.connectrules) |cr| n_ins += cr.insertions.len;
    var rules: std.ArrayList(connect_rule.Rule) = try .initCapacity(self.ctx.arena, n_ins);
    for (self.ctx.file.connectrules) |cr| for (cr.insertions) |*ins| {
        // `checkConnectRules` has reported what is wrong with a statement;
        // here a refused one simply bridges nothing.
        const r = try connect_rule.ruleOf(self, ins, false) orelse continue;
        if (!try connect_rule.paramsDeclared(self, ins, r.module, false)) continue;
        rules.appendAssumeCapacity(r);
    };
    const file = self.ctx.file;
    var hits: std.ArrayList(Hit) = .empty;
    for (src, 0..) |inst, ii| {
        if (ii >= module.instances.len and !fold.gateHolds(self, gates[ii - module.instances.len])) continue;
        const child_path = try self.ctx.arena.print("{s}{s}{c}", .{ path, file.str(inst.name), sep });
        const child = try moduleOf(self, &inst, child_path) orelse continue;
        if (child.is_connect) continue;
        for (child.ports, 0..) |p, pi| {
            const ci = connect_rule.connIndex(&inst, p, pi) orelse continue;
            const sig = lookup.netRefName(self, inst.ports[ci].expr) orelse continue;
            const bound = self.unit.rename.get(sig) orelse sig;
            const upper = self.seg.down.getAdapted(flat_name.PathKey{ .path = path, .local = file.str(sig) }, flat_name.PathKey.Context{}) orelse try segment.up(self, module, path, sig, 0);
            const lower = try segment.down(self, child, child_path, p.name, upper);
            try self.seg.down.put(self.ctx.arena, try segKey(self, child_path, p.name), lower);
            if (lower.domain == .unspecified) continue;
            if (upper.domain == .unspecified) {
                try self.unbridged.append(self.ctx.arena, .{ .tok = inst.ports[ci].main_tok, .net = bound, .lower = lower.disc, .port = p.name, .inst = inst.name, .dir = p.direction });
                continue;
            }
            if (upper.domain == lower.domain) continue;
            const found, const count = connect_rule.matchRules(file, rules.items, p.direction, upper.disc, lower.disc);
            if (count > 1) {
                try self.err(inst.ports[ci].main_tok, .E0922, "port `{s}` of `{s}` matches more than one connect statement ({d})", .{
                    file.str(p.name), file.str(inst.name), count,
                });
                continue;
            }
            try hits.append(self.ctx.arena, .{
                .inst = ii,
                .conn = ci,
                .name = inst.name,
                .rule = found orelse {
                    // Judged with the rest after the walk, so the order of
                    // diagnostics stays §7.4's before §7.8's.
                    try self.unbridged.append(self.ctx.arena, .{ .tok = inst.ports[ci].main_tok, .net = bound, .lower = lower.disc, .port = p.name, .inst = inst.name, .dir = p.direction, .upper = upper });
                    continue;
                },
                .sig = sig,
                .bottom = lower.disc,
                .port = p.name,
            });
        }
    }
    // §3.9 "For digital primitives the domain is discrete and thus the
    // discipline is set via the default_discipline directive": a primitive's
    // terminal is a port whose lower connection has the discipline in force
    // at the primitive, named for §7.8.5 by §7.8.5.1 (`Ast.primTerms`). Its
    // rows are the tails of `Flatten.gates`, `pulls` and `switches`, which
    // `inlineInstance` (or `run`, at the top) has just appended in source
    // order.
    const bases = [3]usize{
        self.decls.gates.items.len - module.gates.len,
        self.decls.pulls.items.len - module.pulls.len,
        self.decls.switches.items.len - module.switches.len,
    };
    for (try Ast.primTerms(self.ctx.arena, file, module)) |pt| {
        if (pt.main_tok >= self.ctx.tok_starts.len) continue;
        const dname = Preprocessor.DefaultDiscipline.inForce(self.ctx.default_disciplines, self.ctx.tok_starts[pt.main_tok], .wire) orelse continue;
        const bottom = file.strings.find(dname) orelse continue;
        if (connect_rule.domain(file, bottom) != .discrete) continue;
        const base = file.lvalueBase(pt.expr);
        if (base == .none) continue;
        const sig = file.exprs.strOf(base);
        const upper = self.seg.down.getAdapted(flat_name.PathKey{ .path = path, .local = file.str(sig) }, flat_name.PathKey.Context{}) orelse try segment.up(self, module, path, sig, 0);
        if (upper.domain != .continuous) continue;
        // A mixed terminal no bridge can take whole is refused, never left
        // joined to the analog node.
        const why: ?[]const u8 = if (pt.generated)
            "the primitive is in a generate block"
        else if (base != pt.expr)
            "the terminal selects part of the net"
        else if (isVector(module, sig))
            "the net is a vector"
        else if (pt.list == .switch_ and pt.range != null)
            "the switch is an instance array"
        else
            null;
        if (why) |w| {
            try self.err(pt.main_tok, .E0929, "terminal `{s}` of `{s}` is on `{s}` (`{s}`) and gets no connect module: {s}", .{
                pt.port, pt.inst, file.str(sig), file.str(upper.disc), w,
            });
            continue;
        }
        const port = try file.intern(self.ctx.arena, pt.port);
        // IEEE 1364-2005 §7.1.5 an instance array is one gate per index, and
        // a scalar terminal is every one's, so each lane is a port of its own
        // whose InstName is the lane's, `g[3]` (as `expandInstanceArrays`
        // names a module array's).
        var lo: i64, var hi: i64 = .{ 0, 0 };
        if (pt.range) |rg| {
            const msb = fold.constInt(self, rg.msb);
            const lsb = fold.constInt(self, rg.lsb);
            if (msb == null or lsb == null) {
                try self.err(pt.main_tok, .E0909, "`{s}`", .{pt.inst});
                continue;
            }
            lo = @min(msb.?, lsb.?);
            hi = @max(msb.?, lsb.?);
        }
        var k = lo;
        while (k <= hi) : (k += 1) {
            const inst = try file.intern(self.ctx.arena, if (pt.range == null) pt.inst else try self.ctx.arena.print("{s}[{d}]", .{ pt.inst, k }));
            const found, const count = connect_rule.matchRules(file, rules.items, pt.dir, upper.disc, bottom);
            if (count > 1) {
                try self.err(pt.main_tok, .E0922, "port `{s}` of `{s}` matches more than one connect statement ({d})", .{
                    pt.port, file.str(inst), count,
                });
                continue;
            }
            try hits.append(self.ctx.arena, .{
                .inst = 0,
                .conn = 0,
                .prim = .{ .term = pt, .flat = bases[@backingInt(pt.list)] + pt.row },
                .name = inst,
                .rule = found orelse {
                    const bound = self.unit.rename.get(sig) orelse sig;
                    try self.unbridged.append(self.ctx.arena, .{ .tok = pt.main_tok, .net = bound, .lower = bottom, .port = port, .inst = inst, .dir = pt.dir, .upper = upper });
                    continue;
                },
                .sig = sig,
                .bottom = bottom,
                .port = port,
            });
        }
    }
    if (hits.items.len == 0) return src;

    // Copies of the originals, whose connection lists the segments rewrite.
    // The originals, then at most one bridge per hit.
    var out: std.ArrayList(Ast.Instance) = try .initCapacity(self.ctx.arena, src.len + hits.items.len);
    out.appendSliceAssumeCapacity(src);
    const conns = try self.ctx.arena.alloc([]Ast.PortConn, out.items.len);
    for (out.items, conns) |*inst, *c| {
        c.* = try self.ctx.arena.dupe(Ast.PortConn, inst.ports);
        inst.ports = c.*;
    }

    for (hits.items, 0..) |h, hi| {
        const r = rules.items[h.rule];
        // The bridge's port that faces the lower connection, and the one that
        // takes the upper: the discrete port when the child's side is digital,
        // the continuous one when it is analog (m03_09's shape).
        const low_analog = connect_rule.domain(file, h.bottom) == .continuous;
        const lower_port, const upper_port = if (low_analog) .{ r.cont.port, r.disc.port } else .{ r.disc.port, r.cont.port };
        // §7.8.3 "The default is merged." And §7.8.2 overrides `split` on an
        // analog lower connection: "there shall never be more than one analog
        // node representing a signal", so those ports always share one.
        // ponytail: §7.8.3.2 Example 3 leaves the instance count of an analog
        // split unstated; one is the count that keeps the node count right.
        const merged = r.ins.mode != .split or low_analog;
        // A merged port joins the bridge an earlier port of its group made.
        const first = if (merged) for (hits.items[0..hi]) |g| {
            if (g.sig == h.sig and g.rule == h.rule and g.bottom == h.bottom) break g;
        } else null else null;
        const name = try segmentName(self, path, r, merged, lower_port, h, if (first) |g| g else h);
        // A primitive's flat row takes the segment; the bridge takes the
        // source's terminal, which inlining renames like any instance's
        // actual.
        const conn: Ast.PortConn = if (h.prim) |p| prim: {
            const t = p.term;
            // ponytail: an array's flat row keeps its terminals; lowering
            // reads none of a gate's, and the mixed runner re-points the lane.
            if (t.range == null) try Ast.setPrimTerm(self.ctx.arena, self.decls.gates.items, self.decls.pulls.items, self.decls.switches.items, t, p.flat, try ident(self, name.segment, t.main_tok));
            break :prim .{ .expr = t.expr, .main_tok = t.main_tok };
        } else conns[h.inst][h.conn];
        const up_expr = conn.expr;
        if (h.prim == null) conns[h.inst][h.conn].expr = try ident(self, name.segment, conn.main_tok);
        try self.out.inserts.append(self.ctx.arena, .{
            .path = path,
            .inst = file.str(h.name),
            .port = file.str(h.port),
            .module = file.str(r.module.name),
            .name = file.str(name.instance),
            .upper_port = file.str(upper_port),
            .lower_port = file.str(lower_port),
        });
        if (first != null) continue;

        try resolve.addNet(self, .{ .name = name.segment, .discipline = h.bottom, .main_tok = conn.main_tok });
        const ports = try self.ctx.arena.alloc(Ast.PortConn, 2);
        ports[0] = .{ .name = upper_port, .expr = up_expr, .main_tok = conn.main_tok };
        ports[1] = .{ .name = lower_port, .expr = try ident(self, name.segment, conn.main_tok), .main_tok = conn.main_tok };
        out.appendAssumeCapacity(.{
            .module = r.module.name,
            .name = name.instance,
            // §7.7.3 "An attribute method can be used with the connect
            // statement to specify parameter values to pass into the
            // Verilog-AMS HDL connect module".
            .params = r.ins.params,
            .ports = ports,
            .main_tok = conn.main_tok,
        });
    }
    // The first hit never finds an earlier one of its group, so at least one
    // bridge was appended.
    assert(out.items.len > src.len);
    return out.items;
}

/// The module `inst` elaborates to: the one it names, or (§6.9.3) the module
/// at the end of the paramset §6.4.2 selects for it. "Automatic insertion of
/// connect modules is a post-elaboration operation ... It should also occur
/// after the paramset selection as the choice for a particular module
/// instantiation may affect the disciplines of the connected nets." The ports
/// whose disciplines decide whether a connection is mixed are the selected
/// module's.
///
/// Quiet: selection proper (`paramset_select.selectParamset`) runs again when the
/// instance is inlined and reports anything wrong there, once. A set that does
/// not narrow to one paramset here inserts nothing.
pub fn moduleOf(self: *Flatten, inst: *const Ast.Instance, path: []const u8) design.Error!?*const Ast.ModuleDecl {
    if (lookup.findModule(self, inst.module)) |m| return m;
    var live: std.ArrayList(*const Ast.ParamsetDecl) = .empty;
    _ = try paramset_select.matchingParamsets(self, inst, path, &live);
    if (live.items.len != 1) return null;
    // The chain, walked without `paramsetChain`'s diagnostics; a chain that
    // never reaches a module is E0904 at inlining.
    var link = live.items[0];
    for (0..self.ctx.file.paramsets.len + 1) |_| {
        if (lookup.findModule(self, link.target)) |m| return m;
        link = for (self.ctx.file.paramsets) |*p| {
            if (p.name == link.target) break p;
        } else return null;
    }
    return null;
}

// ---- private ----

/// Whether `module` declares `name` with a range (§6.5.2, §3.6.3).
fn isVector(module: *const Ast.ModuleDecl, name: Ast.StrId) bool {
    for (module.nets) |n| if (n.name == name and n.range != null) return true;
    for (module.ports) |p| if (p.name == name and (p.range != null or p.type_range != null)) return true;
    return false;
}

/// A `segment` cache key: the segment's instance path and local name.
fn segKey(self: *Flatten, path: []const u8, net: Ast.StrId) design.Error![]const u8 {
    return self.ctx.arena.print("{s}{s}", .{ path, self.ctx.file.str(net) });
}

/// §7.8.5's generated instance name, and the flat name of the segment it
/// bridges to the lower connections (its `lower_port`, seen from inside it).
///
///     merged  SigName__ModuleName__BottomDiscipline
///     split   SigName__InstName__PortName
fn segmentName(
    self: *Flatten,
    path: []const u8,
    r: connect_rule.Rule,
    merged: bool,
    lower_port: Ast.StrId,
    h: Hit,
    owner: Hit,
) design.Error!struct { instance: Ast.StrId, segment: Ast.StrId } {
    const file = self.ctx.file;
    const a = self.ctx.arena;
    const leaf = if (!merged)
        try a.print("{s}__{s}__{s}", .{ file.str(h.sig), file.str(h.name), file.str(h.port) })
    else
        try a.print("{s}__{s}__{s}", .{ file.str(owner.sig), file.str(r.module.name), file.str(owner.bottom) });
    return .{
        .instance = try file.intern(a, leaf),
        .segment = try file.intern(a, try a.print("{s}{s}{c}{s}", .{ path, leaf, sep, file.str(lower_port) })),
    };
}

fn ident(self: *Flatten, name: Ast.StrId, tok: u32) design.Error!Ast.ExprId {
    return self.ctx.file.exprs.add(self.ctx.arena, .{ .tag = .ident, .main_tok = tok, .str = name });
}

test "§7.8.4 mixed ports on one signal share one merged bridge, and split gives each its own (§7.8.5 names)" {
    // Two `dd` input ports of `din` on the `ca` signal `a`: each is mixed,
    // and the a2d statement matches each once. Merged (the default, §7.8.3)
    // they share `a__a2d__dd` (SigName__ModuleName__BottomDiscipline);
    // split each gets `a__<inst>__d` (SigName__InstName__PortName). The
    // bridge's discrete `cm` faces the lower connection, which is the
    // segment `<bridge>.cm`, declared with the bottom discipline.
    const src =
        \\discipline ca; domain continuous; enddiscipline
        \\discipline dd; domain discrete; enddiscipline
        \\module top; ca a; din u1(a); din u2(a); endmodule
        \\connectmodule a2d(el, cm); input el; output cm; ca el; dd cm; endmodule
        \\module din(d); input d; dd d; endmodule
        \\connectrules r; connect a2d{s}; endconnectrules
    ;
    const Case = struct { mode: []const u8, names: [2][]const u8, units: usize };
    for ([_]Case{
        .{ .mode = "", .names = .{ "a__a2d__dd", "a__a2d__dd" }, .units = 4 },
        .{ .mode = " split", .names = .{ "a__u1__d", "a__u2__d" }, .units = 5 },
    }) |case| {
        var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
        defer f.deinit();
        const a = f.arena.allocator();
        try fixture.parse(&f, try a.print(src, .{case.mode}));
        const d = try elaborate.elaborate(f.ctx());
        try std.testing.expectEqual(@as(usize, 2), d.inserts.len);
        for (d.inserts, [_][]const u8{ "u1", "u2" }, case.names) |ins, inst, name| {
            try std.testing.expectEqualStrings("", ins.path);
            try std.testing.expectEqualStrings(inst, ins.inst);
            try std.testing.expectEqualStrings("d", ins.port);
            try std.testing.expectEqualStrings("a2d", ins.module);
            try std.testing.expectEqualStrings(name, ins.name);
            try std.testing.expectEqualStrings("el", ins.upper_port);
            try std.testing.expectEqualStrings("cm", ins.lower_port);
            const seg = fixture.netNamed(&f.file, d.top, try a.print("{s}.cm", .{name})).?;
            try std.testing.expectEqualStrings("dd", f.file.str(seg.discipline));
        }
        // The top, the two children, then one bridge per distinct name.
        try std.testing.expectEqual(case.units, d.units.len);
    }
}

test "§7.8.5.1 a gate's mixed terminals get split bridges named by the primitive port names" {
    // §3.9: under `default_discipline dd every gate terminal is a `dd`
    // lower connection. In `blk`, `p` and `q` are `ca`, so and g1's in1/in2
    // are mixed inputs (a2d) and buf g2's out1/out2 mixed outputs (d2a); `y`
    // has no domain and is bridged by nothing.
    const src =
        \\discipline ca; domain continuous; enddiscipline
        \\discipline dd; domain discrete; enddiscipline
        \\module top; ca a, b; blk u(a, b); endmodule
        \\module blk(p, q); inout p, q; ca p, q; wire y; and g1(y, p, q); buf g2(p, q, y); endmodule
        \\connectmodule a2d(el, cm); input el; output cm; ca el; dd cm; endmodule
        \\connectmodule d2a(cm, el); input cm; output el; dd cm; ca el; endmodule
        \\connectrules r; connect a2d split; connect d2a split; endconnectrules
    ;
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f, src);
    var c = f.ctx();
    c.default_disciplines = &.{.{ .at = 0, .qualifier = null, .discipline = "dd" }};
    const d = try elaborate.elaborate(c);
    const want = [_][4][]const u8{
        .{ "g1", "in1", "a2d", "p__g1__in1" },
        .{ "g1", "in2", "a2d", "q__g1__in2" },
        .{ "g2", "out1", "d2a", "p__g2__out1" },
        .{ "g2", "out2", "d2a", "q__g2__out2" },
    };
    try std.testing.expectEqual(want.len, d.inserts.len);
    for (d.inserts, want) |ins, w| {
        try std.testing.expectEqualStrings("u.", ins.path);
        try std.testing.expectEqualStrings(w[0], ins.inst);
        try std.testing.expectEqualStrings(w[1], ins.port);
        try std.testing.expectEqualStrings(w[2], ins.module);
        try std.testing.expectEqualStrings(w[3], ins.name);
    }
    // The flat gate rows read and drive the segments, `y` untouched.
    const ex = &f.file.exprs;
    const g1 = d.top.gates[0];
    try std.testing.expectEqualStrings("u.p__g1__in1.cm", f.file.str(ex.strOf(g1.ins[0])));
    try std.testing.expectEqualStrings("u.q__g1__in2.cm", f.file.str(ex.strOf(g1.ins[1])));
    try std.testing.expectEqualStrings("u.y", f.file.str(ex.strOf(g1.out)));
    try std.testing.expectEqualStrings("u.p__g2__out1.cm", f.file.str(ex.strOf(d.top.gates[1].out)));
    try std.testing.expectEqualStrings("u.q__g2__out2.cm", f.file.str(ex.strOf(d.top.gates[2].out)));
}
