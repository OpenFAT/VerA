//! §7.8 automatic insertion of connect modules: one module's instance list →
//! the same list with every mixed port (and gate terminal, §7.8.5.1)
//! re-pointed at a new segment, plus one synthetic instance of the selected
//! connect module per segment for the flatten to inline like any other
//! child. LRM §3.9, §3.11.1, §7.6, §7.7.1, §7.7.3, §7.8.1 to §7.8.5.1.

const std = @import("std");
const hier_param = @import("hier_param.zig");
const elaborate = @import("elaborate.zig");
const Flatten = elaborate.Flatten;
const elab_names = @import("names.zig");
const elab_resolve = @import("resolve.zig");
const elab_override = @import("override.zig");
const elab_paramset = @import("paramset.zig");
const elab_segment = @import("segment.zig");
const discipline = @import("discipline_rules.zig");
const Ast = @import("frontend").Ast;
const Preprocessor = @import("frontend").Preprocessor;
const Error = elaborate.Error;
const sep = elaborate.sep;

/// One connect statement, read as §7.6's Table 7-2 pair: which of the connect
/// module's two ports is continuous and which discrete, with the discipline and
/// direction each has after §7.7.1's overrides.
const Rule = struct {
    ins: *const Ast.ConnectInsertion,
    module: *const Ast.ModuleDecl,
    cont: Side,
    disc: Side,

    const Side = struct { port: Ast.StrId, discipline: Ast.StrId, dir: Ast.Direction };
};

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

/// Whether `module` declares `name` with a range (§6.5.2, §3.6.3).
fn isVector(module: *const Ast.ModuleDecl, name: Ast.StrId) bool {
    for (module.nets) |n| if (n.name == name and n.range != null) return true;
    for (module.ports) |p| if (p.name == name and (p.range != null or p.type_range != null)) return true;
    return false;
}

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
pub fn plan(self: *Flatten, module: *const Ast.ModuleDecl, path: []const u8, src: []const Ast.Instance, gates: []const Ast.ExprId) Error![]const Ast.Instance {
    // Per level: without the first walk's list (`Flatten.tree_ooc`), an
    // out-of-context declaration below is collected only when its module is
    // walked (`resolve.collectOoc`), so an answer cached for the level above
    // may predate it.
    std.debug.assert(src.len == module.instances.len + gates.len); // `enterLevel`'s, consumed here
    self.seg_up.clearRetainingCapacity();
    self.seg_index.clearRetainingCapacity();
    var n_ins: usize = 0;
    for (self.ctx.file.connectrules) |cr| n_ins += cr.insertions.len;
    var rules: std.ArrayList(Rule) = try .initCapacity(self.ctx.arena, n_ins);
    for (self.ctx.file.connectrules) |cr| for (cr.insertions) |*ins| {
        // `checkConnectRules` has reported what is wrong with a statement;
        // here a refused one simply bridges nothing.
        const r = try ruleOf(self, ins, false) orelse continue;
        if (!try paramsDeclared(self, ins, r.module, false)) continue;
        rules.appendAssumeCapacity(r);
    };
    const file = self.ctx.file;
    var hits: std.ArrayList(Hit) = .empty;
    for (src, 0..) |inst, ii| {
        if (ii >= module.instances.len and !elab_names.gateHolds(self, gates[ii - module.instances.len])) continue;
        const child_path = try self.ctx.arena.print("{s}{s}{c}", .{ path, file.str(inst.name), elaborate.sep });
        const child = try moduleOf(self, &inst, child_path) orelse continue;
        if (child.is_connect) continue;
        for (child.ports, 0..) |p, pi| {
            const ci = connIndex(&inst, p, pi) orelse continue;
            const sig = elab_names.netRefName(self, inst.ports[ci].expr) orelse continue;
            const bound = self.unit.rename.get(sig) orelse sig;
            const upper = self.seg_down.getAdapted(elab_names.PathKey{ .path = path, .local = file.str(sig) }, elab_names.PathKey.Context{}) orelse try elab_segment.up(self, module, path, sig, 0);
            const lower = try elab_segment.down(self, child, child_path, p.name, upper);
            try self.seg_down.put(self.ctx.arena, try segKey(self, child_path, p.name), lower);
            if (lower.domain == .unspecified) continue;
            if (upper.domain == .unspecified) {
                try self.unbridged.append(self.ctx.arena, .{ .tok = inst.ports[ci].main_tok, .net = bound, .lower = lower.disc, .port = p.name, .inst = inst.name, .dir = p.direction });
                continue;
            }
            if (upper.domain == lower.domain) continue;
            const found, const count = matchRules(file, rules.items, p.direction, upper.disc, lower.disc);
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
        self.gates.items.len - module.gates.len,
        self.pulls.items.len - module.pulls.len,
        self.switches.items.len - module.switches.len,
    };
    for (try Ast.primTerms(self.ctx.arena, file, module)) |pt| {
        if (pt.main_tok >= self.ctx.tok_starts.len) continue;
        const dname = Preprocessor.DefaultDiscipline.inForce(self.ctx.default_disciplines, self.ctx.tok_starts[pt.main_tok], .wire) orelse continue;
        const bottom = file.strings.find(dname) orelse continue;
        if (domain(file, bottom) != .discrete) continue;
        const base = file.lvalueBase(pt.expr);
        if (base == .none) continue;
        const sig = file.exprs.strOf(base);
        const upper = self.seg_down.getAdapted(elab_names.PathKey{ .path = path, .local = file.str(sig) }, elab_names.PathKey.Context{}) orelse try elab_segment.up(self, module, path, sig, 0);
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
            const msb = elab_names.constInt(self, rg.msb);
            const lsb = elab_names.constInt(self, rg.lsb);
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
            const found, const count = matchRules(file, rules.items, pt.dir, upper.disc, bottom);
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
        const low_analog = domain(file, h.bottom) == .continuous;
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
            if (t.range == null) try Ast.setPrimTerm(self.ctx.arena, self.gates.items, self.pulls.items, self.switches.items, t, p.flat, try ident(self, name.segment, t.main_tok));
            break :prim .{ .expr = t.expr, .main_tok = t.main_tok };
        } else conns[h.inst][h.conn];
        const up_expr = conn.expr;
        if (h.prim == null) conns[h.inst][h.conn].expr = try ident(self, name.segment, conn.main_tok);
        try self.inserts.append(self.ctx.arena, .{
            .path = path,
            .inst = file.str(h.name),
            .port = file.str(h.port),
            .module = file.str(r.module.name),
            .name = file.str(name.instance),
            .upper_port = file.str(upper_port),
            .lower_port = file.str(lower_port),
        });
        if (first != null) continue;

        try elab_resolve.addNet(self, .{ .name = name.segment, .discipline = h.bottom, .main_tok = conn.main_tok });
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
    std.debug.assert(out.items.len > src.len);
    return out.items;
}

/// A child port `plan` bridged with nothing, as `checkUnbridged` reads it.
pub const Unbridged = struct {
    tok: u32,
    /// The flat net the port joins.
    net: Ast.StrId,
    /// The port's own discipline: its lower connection.
    lower: Ast.StrId,
    port: Ast.StrId,
    inst: Ast.StrId,
    dir: Ast.Direction,
    /// The upper connection as `plan` resolved it, when it could: then the
    /// port is known mixed and no statement matched it.
    upper: ?elab_segment.Seg = null,
};

/// §7.8.4 "the port shall match one (and only one) connect statement", the
/// zero-match half (E0922 is the other), and §6.5.7 "Ports of both analog
/// and digital discipline may be connected to a net provided the
/// appropriate connect statements exist". Run after §7.4 resolution, since
/// a port is mixed by the disciplines its net resolved to, not by what
/// crosses it.
pub fn checkUnbridged(self: *Flatten) Error!void {
    const file = self.ctx.file;
    for (self.unbridged.items) |u| {
        if (u.upper) |up| {
            try unmatched(self, u.tok, u.port, u.inst, u.lower, u.net, up.disc);
            continue;
        }
        const upper = self.disc_of.get(u.net) orelse continue;
        const up_d = domain(file, upper) orelse continue;
        const lo_d = domain(file, u.lower) orelse continue;
        if (up_d == lo_d or up_d == .unspecified or lo_d == .unspecified) continue;
        // A statement that matches, which `plan` could not apply: the net
        // resolved continuous above the level that elaborated this port.
        const rule = find: {
            for (file.connectrules) |cr| for (cr.insertions) |*ins| {
                const r = try ruleOf(self, ins, false) orelse continue;
                if (matches(file, r, u.dir, upper, u.lower)) break :find r;
            };
            break :find null;
        };
        if (rule) |r| {
            try self.err(u.tok, .E0929, "`{s}` matches port `{s}` of `{s}` (`{s}`), but its net `{s}` resolved `{s}` above the level that elaborated the port", .{
                file.str(r.module.name), file.str(u.port), file.str(u.inst), file.str(u.lower), file.str(u.net), file.str(upper),
            });
            continue;
        }
        try unmatched(self, u.tok, u.port, u.inst, u.lower, u.net, upper);
    }
}

/// E0927 for a mixed port no connect statement matches.
fn unmatched(self: *Flatten, tok: u32, port: Ast.StrId, inst: Ast.StrId, lower: Ast.StrId, net: Ast.StrId, upper: Ast.StrId) Error!void {
    const file = self.ctx.file;
    try self.err(tok, .E0927, "port `{s}` of `{s}` is {s}{s}{s} and its net `{s}` is {s}{s}{s}, and no connect statement bridges them", .{
        file.str(port), file.str(inst), q(lower), discName(file, lower), q(lower), file.str(net), q(upper), discName(file, upper), q(upper),
    });
}

/// A segment's discipline for a message: §3.6.2.4's digital net with none
/// (`segment.Seg.behavioral`) is named by what it is.
fn discName(file: *const Ast.SourceFile, d: Ast.StrId) []const u8 {
    return if (d == .none) "discrete with no discipline (3.6.2.4)" else file.str(d);
}

fn q(d: Ast.StrId) []const u8 {
    return if (d == .none) "" else "`";
}

/// A `segment` cache key: the segment's instance path and local name.
fn segKey(self: *Flatten, path: []const u8, net: Ast.StrId) Error![]const u8 {
    return self.ctx.arena.print("{s}{s}", .{ path, self.ctx.file.str(net) });
}

/// The module `inst` elaborates to: the one it names, or (§6.9.3) the module
/// at the end of the paramset §6.4.2 selects for it. "Automatic insertion of
/// connect modules is a post-elaboration operation ... It should also occur
/// after the paramset selection as the choice for a particular module
/// instantiation may affect the disciplines of the connected nets." The ports
/// whose disciplines decide whether a connection is mixed are the selected
/// module's.
///
/// Quiet: selection proper (`elab_paramset.selectParamset`) runs again when the
/// instance is inlined and reports anything wrong there, once. A set that does
/// not narrow to one paramset here inserts nothing.
pub fn moduleOf(self: *Flatten, inst: *const Ast.Instance, path: []const u8) Error!?*const Ast.ModuleDecl {
    if (elab_names.findModule(self, inst.module)) |m| return m;
    var live: std.ArrayList(*const Ast.ParamsetDecl) = .empty;
    _ = try elab_paramset.matchingParamsets(self, inst, path, &live);
    if (live.items.len != 1) return null;
    // The chain, walked without `paramsetChain`'s diagnostics; a chain that
    // never reaches a module is E0904 at inlining.
    var link = live.items[0];
    for (0..self.ctx.file.paramsets.len + 1) |_| {
        if (elab_names.findModule(self, link.target)) |m| return m;
        link = for (self.ctx.file.paramsets) |*p| {
            if (p.name == link.target) break p;
        } else return null;
    }
    return null;
}

/// §7.8.5's generated instance name, and the flat name of the segment it
/// bridges to the lower connections (its `lower_port`, seen from inside it).
///
///     merged  SigName__ModuleName__BottomDiscipline
///     split   SigName__InstName__PortName
fn segmentName(
    self: *Flatten,
    path: []const u8,
    r: Rule,
    merged: bool,
    lower_port: Ast.StrId,
    h: Hit,
    owner: Hit,
) Error!struct { instance: Ast.StrId, segment: Ast.StrId } {
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

fn ident(self: *Flatten, name: Ast.StrId, tok: u32) Error!Ast.ExprId {
    return self.ctx.file.exprs.add(self.ctx.arena, .{ .tag = .ident, .main_tok = tok, .str = name });
}

/// The index into `inst.ports` that binds `p`, the `pi`'th declared port.
pub fn connIndex(inst: *const Ast.Instance, p: Ast.Port, pi: usize) ?usize {
    const named = inst.ports.len != 0 and inst.ports[0].name != .none;
    if (!named) return if (pi < inst.ports.len) pi else null;
    for (inst.ports, 0..) |c, i| if (c.name == p.connName()) return i;
    return null;
}

fn domain(file: *const Ast.SourceFile, d: Ast.StrId) ?Ast.DisciplineDecl.Domain {
    return discipline.domainOf(discipline.declOf(file, d) orelse return null);
}

/// Reads a §7.7.1 connect statement as a `Rule`: the module's two ports split
/// into the continuous and the discrete side (§7.6 "The port disciplines define the
/// default type of disciplines which shall be bridged by the connect module.
/// The directional qualifiers of the discrete port determine the default
/// scenarios"), then the statement's overrides applied by domain ("one shall
/// be discrete and the other continuous"). Null for a statement this pass
/// cannot read: an unknown module was E0915 already. `report` is true for the
/// one call per statement `checkConnectRules` makes, so a conflicting override
/// is diagnosed once per compilation and not once per module that has ports.
pub fn ruleOf(self: *Flatten, ins: *const Ast.ConnectInsertion, report: bool) Error!?Rule {
    const file = self.ctx.file;
    const m = elab_names.findModule(self, ins.module) orelse return null;
    if (!m.is_connect or m.ports.len != 2) return null;
    var cont: ?Rule.Side = null;
    var disc: ?Rule.Side = null;
    for (m.ports) |p| {
        const side: Rule.Side = .{ .port = p.name, .discipline = p.discipline, .dir = p.direction };
        switch (domain(file, p.discipline) orelse return null) {
            .continuous => cont = side,
            .discrete => disc = side,
            .unspecified => return null,
        }
    }
    var r: Rule = .{ .ins = ins, .module = m, .cont = cont orelse return null, .disc = disc orelse return null };
    if (ins.overrides) |o| for ([_]struct { Ast.Direction, Ast.StrId }{ .{ o.a_dir, o.a }, .{ o.b_dir, o.b } }) |ov| {
        const side = switch (domain(file, ov[1]) orelse return null) {
            .continuous => &r.cont,
            .discrete => &r.disc,
            .unspecified => return null,
        };
        // "the specified disciplines shall be compatible for both the
        // continuous and discrete disciplines of the given connect module"
        if (discipline.disciplineConflict(file, side.discipline, ov[1])) |why| {
            if (report) try self.err(ins.main_tok, .E0915, "`{s}` cannot stand for `{s}`'s `{s}` ({s})", .{
                file.str(ov[1]), file.str(m.name), file.str(side.discipline), why,
            });
            return null;
        }
        side.discipline = ov[1];
        if (ov[0] != .unspecified) side.dir = ov[0];
    };
    return r;
}

/// §7.6 Table 7-2, "The following combinations of directional qualifiers are
/// supported for the continuous and discrete disciplines of a connect module":
/// input/output, output/input, inout/inout, read after §7.7.1's direction
/// overrides, which "are used to define the type of connect module". Any other
/// pair names no scenario the module could be inserted in, so the statement
/// is refused (E0982). A port with no direction is not judged here.
pub fn checkDirections(self: *Flatten, r: Rule) Error!void {
    const c = r.cont.dir;
    const d = r.disc.dir;
    if (c == .unspecified or d == .unspecified) return;
    if ((c == .input and d == .output) or (c == .output and d == .input) or (c == .inout and d == .inout)) return;
    const file = self.ctx.file;
    try self.err(r.ins.main_tok, .E0982, "`{s}`'s continuous port `{s}` is `{t}` and its discrete port `{s}` is `{t}`", .{
        file.str(r.module.name), file.str(r.cont.port), c, file.str(r.disc.port), d,
    });
}

/// §7.7.3 "Any parameters declared in the connect module can be specified":
/// the statement's `#(...)` is an A.4.1 parameter_value_assignment on the
/// module it names, so a name that module does not declare, a localparam
/// (§3.4.5) or an ordered list longer than its overridable parameters is the
/// same E0907 an instance gets, judged at the statement whether or not any
/// port selects it. `report` as in `ruleOf`. Returns whether every entry
/// named an overridable parameter.
pub fn paramsDeclared(self: *Flatten, ins: *const Ast.ConnectInsertion, m: *const Ast.ModuleDecl, report: bool) Error!bool {
    const file = self.ctx.file;
    if (ins.params.len == 0) return true;
    const named = ins.params[0].name != .none;
    if (!named) {
        const n = elab_override.overridableCount(m.params);
        if (ins.params.len <= n) return true;
        if (report) try self.err(ins.params[n].main_tok, .E0907, "`{s}` declares {d} overridable parameter{s}, and this connect statement sets {d}", .{
            file.str(m.name), n, if (n == 1) "" else "s", ins.params.len,
        });
        return false;
    }
    var ok = true;
    for (ins.params) |o| {
        var target = o.name;
        for (m.aliasparams) |al| if (al.alias == o.name) {
            target = al.target;
            break;
        };
        if (hier_param.Kind.fromName(file.str(target)) != null) continue;
        const decl = for (m.params) |*p| {
            if (p.name == target) break p;
        } else null;
        if (decl != null and !decl.?.is_local) continue;
        ok = false;
        if (report) try self.err(o.main_tok, .E0907, "`{s}` is {s} of connect module `{s}`", .{
            file.str(o.name), if (decl == null) "not a parameter" else "a localparam", file.str(m.name),
        });
    }
    return ok;
}

/// The first of `rules` that `matches` the port, and how many do: §7.8.4's
/// "one (and only one)" is a count of one.
fn matchRules(file: *const Ast.SourceFile, rules: []const Rule, dir: Ast.Direction, upper: Ast.StrId, lower: Ast.StrId) struct { ?usize, usize } {
    var found: ?usize = null;
    var count: usize = 0;
    for (rules, 0..) |r, ri| if (matches(file, r, dir, upper, lower)) {
        count += 1;
        if (found == null) found = ri;
    };
    return .{ found, count };
}

/// Does connect rule `r` bridge a port of direction `dir` whose upper and
/// lower connections have these disciplines? §7.6's three examples, which
/// state the matching in terms of data flow: a d2a (discrete input, continuous
/// output) "can bridge a mixed input port whose upper connection is compatible
/// with discipline ddiscrete and whose lower connection is compatible with
/// electrical, or a mixed output port whose upper connection is compatible
/// with discipline electrical and whose lower connection is compatible with
/// ddiscrete"; an inout/inout bidir "can bridge any mixed port". So the rule's
/// input side faces the port's source: the upper connection of an input port,
/// the lower of an output port. "Compatible" is §3.11.1's.
fn matches(file: *const Ast.SourceFile, r: Rule, dir: Ast.Direction, upper: Ast.StrId, lower: Ast.StrId) bool {
    const compat = struct {
        fn f(fl: *const Ast.SourceFile, a: Ast.StrId, b: Ast.StrId) bool {
            // §3.6.2.4 a net with no discipline that digital behavioral code
            // uses is discrete and binds no nature, which §3.11.1's
            // Natureless Discipline Rule makes compatible with every
            // discrete discipline.
            if (b == .none) return domain(fl, a) == .discrete;
            return discipline.disciplineConflict(fl, a, b) == null and domain(fl, a) == domain(fl, b);
        }
    }.f;
    if (r.cont.dir == .inout and r.disc.dir == .inout) {
        const c, const d = if (domain(file, upper) == .continuous) .{ upper, lower } else .{ lower, upper };
        return compat(file, r.cont.discipline, c) and compat(file, r.disc.discipline, d);
    }
    const in_side, const out_side = if (r.cont.dir == .input and r.disc.dir == .output)
        .{ r.cont, r.disc }
    else if (r.cont.dir == .output and r.disc.dir == .input)
        .{ r.disc, r.cont }
    else
        return false; // not a Table 7-2 combination
    const source, const sink = switch (dir) {
        .input => .{ upper, lower },
        .output => .{ lower, upper },
        // A unidirectional bridge does not cover an inout port, and a port
        // with no direction has no source side to face.
        .inout, .unspecified => return false,
    };
    return compat(file, in_side.discipline, source) and compat(file, out_side.discipline, sink);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const fixture = @import("fixture.zig");

test connIndex {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var file: Ast.SourceFile = .empty;
    const pa = try file.intern(a, "a");
    const pb = try file.intern(a, "b");
    const pc = try file.intern(a, "c");
    const ext = try file.intern(a, "ext");
    const port_a: Ast.Port = .{ .name = pa };
    const port_b: Ast.Port = .{ .name = pb };
    const port_c: Ast.Port = .{ .name = pc };
    // §6.2.2 an ordered list binds by position; a short one leaves the rest
    // unbound, and an empty one binds nothing.
    const ordered: Ast.Instance = .{ .module = pa, .name = pa, .ports = &.{ .{}, .{} } };
    try std.testing.expectEqual(@as(?usize, 0), connIndex(&ordered, port_a, 0));
    try std.testing.expectEqual(@as(?usize, 1), connIndex(&ordered, port_b, 1));
    try std.testing.expectEqual(@as(?usize, null), connIndex(&ordered, port_c, 2));
    const empty: Ast.Instance = .{ .module = pa, .name = pa };
    try std.testing.expectEqual(@as(?usize, null), connIndex(&empty, port_a, 0));
    // A named list binds by name, the first of a repeated one (the second
    // is `checkConnectionShape`'s E0906), whatever the declaration order.
    const named: Ast.Instance = .{ .module = pa, .name = pa, .ports = &.{ .{ .name = pb }, .{ .name = pa }, .{ .name = pa } } };
    try std.testing.expectEqual(@as(?usize, 1), connIndex(&named, port_a, 0));
    try std.testing.expectEqual(@as(?usize, 0), connIndex(&named, port_b, 1));
    try std.testing.expectEqual(@as(?usize, null), connIndex(&named, port_c, 2));
    // A.1.3 a `.ext(c)` port connects by its external name, not its net's.
    const port_ext: Ast.Port = .{ .name = pc, .external_name = ext };
    const by_ext: Ast.Instance = .{ .module = pa, .name = pa, .ports = &.{.{ .name = ext }} };
    try std.testing.expectEqual(@as(?usize, 0), connIndex(&by_ext, port_ext, 0));
    try std.testing.expectEqual(@as(?usize, null), connIndex(&by_ext, port_c, 0));
}

test matches {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\discipline ca; domain continuous; enddiscipline
        \\discipline dd; domain discrete; enddiscipline
        \\module top; endmodule
    );
    const file = &f.file;
    const ca = fixture.id(file, "ca").?;
    const dd = fixture.id(file, "dd").?;
    const m = &file.modules[0];
    const ins: Ast.ConnectInsertion = .{ .module = m.name };
    // §7.6 Example 2's a2d: continuous input, discrete output. Port names
    // are not what `matches` reads.
    const a2d: Rule = .{
        .ins = &ins,
        .module = m,
        .cont = .{ .port = m.name, .discipline = ca, .dir = .input },
        .disc = .{ .port = m.name, .discipline = dd, .dir = .output },
    };
    // It "can bridge a mixed input port whose upper connection is compatible
    // with electrical and whose lower connection is compatible with
    // ddiscrete": the input faces the port's source, its upper connection.
    try std.testing.expect(matches(file, a2d, .input, ca, dd));
    // An output port's source is its lower connection, so the same
    // disciplines the other way round match, and these do not.
    try std.testing.expect(matches(file, a2d, .output, dd, ca));
    try std.testing.expect(!matches(file, a2d, .output, ca, dd));
    // A unidirectional bridge covers no inout and no undirected port.
    try std.testing.expect(!matches(file, a2d, .inout, ca, dd));
    try std.testing.expect(!matches(file, a2d, .unspecified, ca, dd));
    // §3.6.2.4 a behavioral net with no discipline is discrete and natureless,
    // compatible with every discrete discipline (§3.11.1).
    try std.testing.expect(matches(file, a2d, .input, ca, .none));
    // An inout/inout bridge "can bridge any mixed port", either way round.
    var bidir = a2d;
    bidir.cont.dir = .inout;
    bidir.disc.dir = .inout;
    try std.testing.expect(matches(file, bidir, .input, ca, dd));
    try std.testing.expect(matches(file, bidir, .output, dd, ca));
    try std.testing.expect(matches(file, bidir, .inout, dd, ca));
    // A direction pair outside Table 7-2 bridges nothing.
    var bad = a2d;
    bad.disc.dir = .input;
    try std.testing.expect(!matches(file, bad, .input, ca, dd));
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

test "§7.6 Table 7-2: a connect module whose port directions name no scenario is E0982" {
    const src =
        \\discipline ca; domain continuous; enddiscipline
        \\discipline dd; domain discrete; enddiscipline
        \\connectmodule bridge(a, d); input a; {s} d; ca a; dd d; endmodule
        \\module top(p); inout p; ca p; endmodule
        \\connectrules r; connect bridge; endconnectrules
    ;
    var bad: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer bad.deinit();
    try fixture.parse(&bad, try bad.arena.allocator().print(src, .{"input"}));
    try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(bad.ctx()));
    try std.testing.expect(fixture.hasCode(&bad.bag, .E0982));

    // input/output is the first of the table's three pairs.
    var good: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer good.deinit();
    try fixture.parse(&good, try good.arena.allocator().print(src, .{"output"}));
    _ = try elaborate.elaborate(good.ctx());
}
