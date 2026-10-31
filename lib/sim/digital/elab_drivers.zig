//! The continuous assignments, gates, switches and port bridges of an instance in, the driver rows of `Elab` and the nets they drive out.
//! Cites: IEEE 1364-2005 §6.1, §6.5.7.1, §7.1, §7.6, §7.8, §12.3.9.2.
//!
//! Contents:
//! - `pub fn declareDrivers(r: *Run, e: *Elab, scope: u32, items: Ast.GenItems, lanes_at: []const LaneSeg) Error!void`
//! - `pub fn bridged(r: *Run, e: *Elab, m: *const Ast.ModuleDecl, scope: u32) Error!Bridged`
//! - `pub fn scopePath(r: *Run, scope: u32) Error![]const u8`
//! - `pub fn digitalWrites(r: *Run, m: *const Ast.ModuleDecl) Error!std.AutoHashMapUnmanaged(Ast.StrId, void)`
//! - `W.expr(_: @This(), _: Ast.ExprId, _: Ast.SourceFile.Edge) Error!void {}`
//! - `W.stmt(w: @This(), s: Ast.StmtId) Error!void`
//! - `pub fn continuous(file: *const Ast.SourceFile, name: Ast.StrId) bool`
//! Pass one of elaboration: the parsed design and its root definitions ->
//! the slot space, the nets and the driver rows (`Elab`), the scope tree
//! (`Run.scope_info`) and every name bound in it, before any expression is
//! compiled. §6.2.2's walk of the instance tree is parent-first, so a port
//! connection always resolves against a parent that is fully declared.
//! `elaborate` (root.zig) runs it, then compiles what it built.
//! Clauses: IEEE 1364-2005 §4.5 implicit nets, §4.9 arrays, §4.10 and §12.2
//! parameters and defparams, §6.5/§6.5.7.1 ports, §7.1, §7.6 and §7.8 gates,
//! switches and pulls, §8 UDPs, §10 subroutine frames, §12.1.2 instance
//! arrays, §12.1.3 recursive instantiation, §12.3 port connections, §12.4
//! generate, §12.5 named blocks, §12.8.2, §19.9 unconnected_drive; VAMS §3.7
//! wreal, §6.3 the host's parameters, §7.2 continuous and discrete, §7.8.4
//! inserted connect modules.
const std = @import("std");
const assert = std.debug.assert;
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const diag = @import("diag");
const root = @import("root.zig");
const Run = root.Run;
const Error = root.Error;
const Frame = root.Frame;
const VecRange = root.VecRange;
const Span = root.Span;
const isRoot = root.isRoot;
const expectRun = root.expectRun;
const expectRejected = root.expectRejected;
const compile = @import("compile.zig");
const evaluate = @import("evaluate.zig");
const deep = @import("base").deep_stack;
const binding = @import("bind.zig");
const Type = compile.Type;
const net_mod = @import("net.zig");
const Net = net_mod.Net;
const NetCold = net_mod.NetCold;
const Udp = net_mod.Udp;
const Slice = net_mod.Slice;
const Tran = net_mod.Tran;
const Signal = net_mod.Signal;
const Source = net_mod.Source;
const filled = net_mod.filled;
const undriven = net_mod.undriven;
const elab = @import("elab.zig");
const elab_declare = @import("elab_declare.zig");
const elab_params = @import("elab_params.zig");
const elab_ports = @import("elab_ports.zig");
const elab_slots = @import("elab_slots.zig");
const elab_warnings = @import("elab_warnings.zig");
const Elab = elab.Elab;
const Sink = elab.Sink;
const SinkOf = elab_ports.SinkOf;
const concatLeaves = elab_ports.concatLeaves;
const declare = elab_declare.declare;
const findModule = elab.findModule;
const mintNet = elab_slots.mintNet;
const names = elab_params.names;
const portWidth = elab_ports.portWidth;
const sendPort = elab_warnings.sendPort;
const sink = elab_ports.sink;

/// `bridged`'s answer: `m`'s instances and primitives as insertion left
/// them.
const Bridged = struct {
    instances: []const Ast.Instance,
    gates: []const Ast.GateInst,
    pulls: []const Ast.PullInst,
    switches: []const Ast.SwitchInst,
    lanes: []const LaneSeg = &.{},
};

/// Terminal `term` (`Ast.PrimTerm.term`) of lane `j` (0 the leftmost index,
/// IEEE 1364-2005 §7.1.6) of row `row` of a module's gates is `seg`: a
/// bridged lane of an instance array, which shares one row with the others.
const LaneSeg = struct { row: usize, j: usize, term: u32, seg: Ast.ExprId };

/// The driver rows of `items`' continuous assignments, gates, switches and
/// pull sources, their names resolved in `scope`. `items.events` and
/// `items.discrete` are not read. `lanes` re-points single lanes of
/// `items.gates`' instance arrays (`bridged`).
pub fn declareDrivers(r: *Run, e: *Elab, scope: u32, items: Ast.GenItems, lanes_at: []const LaneSeg) Error!void {
    assert(scope < r.hier.scopes.items.len);
    r.scope = scope;
    for (items.assigns) |a| {
        const net = try drivenNet(r, e, scope, a.target, a.main_tok, .assign, .{ a.strength0, a.strength1 });
        try e.wires.append(r.arena, .{ .net = net, .scope = scope, .source = .{ .expr = .{ .e = a.value } }, .s0 = a.strength0, .s1 = a.strength1, .delay = a.delay, .tok = a.main_tok });
    }
    // §7.1 a gate instance is one more driver of its output net, so it joins
    // the same list an `assign` does and resolves against them.
    var gate_names: std.AutoHashMapUnmanaged(Ast.StrId, u32) = .empty;
    for (items.gates, 0..) |g, gi| {
        // A `buf`/`not` with several outputs is one instance of several rows.
        if (g.name != .none) {
            const seen = try gate_names.getOrPut(r.arena, g.name);
            if (seen.found_existing and seen.value_ptr.* != g.main_tok)
                return r.fail(g.main_tok, "§7.1.5: `{s}` names two instances; one instance identifier has one range", .{r.file.str(g.name)});
            seen.value_ptr.* = g.main_tok;
            try r.hier.prim_names.put(r.arena, .{ .scope = scope, .str = g.name }, g.main_tok);
        }
        const net = try drivenNet(r, e, scope, g.out, g.main_tok, .gate, .{ g.strength0, g.strength1 });
        const width = e.nets.items[net].resolved.width;
        // IEEE 1364-2005 §7.1.5/§7.1.6: an instance array is one gate per
        // index, and a terminal as wide as the array gives each gate one bit
        // (the leftmost index the most significant), while a scalar one is
        // shared by all of them.
        const lanes: u32 = if (g.range) |rg| try r.declaredWidth(rg, g.main_tok) else 1;
        // §7.8.5's tables are one bit wide, so a plain gate's output is too.
        if (width != 1 and width != lanes) return r.fail(g.main_tok, "a gate's output terminal is one bit, or one per instance of an array", .{});
        for (0..lanes) |j| {
            const lane: ?u32 = if (g.range == null) null else @intCast(lanes - 1 - j);
            // A lane VAMS §7.8.4 bridged reads or drives its own segment, one
            // bit, where the others share the row's terminal.
            var ins = g.ins;
            var lane_net = net;
            var out_bit = if (width == 1) null else lane;
            for (lanes_at) |ls| if (ls.row == gi and ls.j == j) {
                if (ls.term == 0) {
                    lane_net = try drivenNet(r, e, scope, ls.seg, g.main_tok, .gate, .{ g.strength0, g.strength1 });
                    out_bit = null;
                } else {
                    const copy = try r.arena.dupe(Ast.ExprId, ins);
                    copy[ls.term - 1] = ls.seg;
                    ins = copy;
                }
            };
            try e.wires.append(r.arena, .{
                .net = lane_net,
                .scope = scope,
                .source = .{ .gate = .{ .kind = g.kind, .ins = ins, .lane = lane, .lanes = lanes, .out_bit = out_bit } },
                .s0 = g.strength0,
                .s1 = g.strength1,
                .delay = g.delay,
                .tok = g.main_tok,
            });
        }
    }
    // IEEE 1364-2005 §7.6/§7.7 switches. A MOS switch drives its output net
    // with what it passes, as a gate does; a CMOS switch is an n-type and a
    // p-type sharing data and output. A pass switch joins its two nets into
    // one resolution while it conducts.
    for (items.switches) |sw| {
        if (sw.name != .none) try r.hier.prim_names.put(r.arena, .{ .scope = scope, .str = sw.name }, sw.main_tok);
        const resistive = switch (sw.kind) {
            .rcmos, .rnmos, .rpmos, .rtran, .rtranif0, .rtranif1 => true,
            .cmos, .nmos, .pmos, .tran, .tranif0, .tranif1 => false,
        };
        switch (sw.kind) {
            .nmos, .pmos, .rnmos, .rpmos, .cmos, .rcmos => {
                // A.3.3's output terminal is a net_lvalue: a net, or a
                // constant bit-select of one (`nmos (o[1], i, en)`, iverilog's
                // rise_fall_decay2), which the switch drives alone.
                const at: Sink = if (r.file.exprs.tag(sw.terms[0]) == .index)
                    try sink(r, e, sw.terms[0], sw.main_tok, .gate)
                else blk: {
                    const n = r.net_of.get(try r.scalarSlot(sw.terms[0])) orelse return r.fail(sw.main_tok, "a switch's output and inout terminals are nets", .{});
                    break :blk .{ .net = n, .lo = 0, .width = e.nets.items[n].resolved.width };
                };
                r.scope = scope;
                const out = at.net;
                const width = at.width;
                // §7.1.5/§7.1.6 an instance array is one switch per index, as a gate array is.
                const lanes: u32 = if (sw.range) |rg| try r.declaredWidth(rg, sw.main_tok) else 1;
                if (width != 1 and (width != lanes or at.lo != 0)) return r.fail(sw.main_tok, "a MOS switch's output terminal is one bit, or one per instance of an array", .{});
                const whole = e.nets.items[out].resolved.width;
                const cmos = sw.kind == .cmos or sw.kind == .rcmos;
                const n_type = sw.kind == .nmos or sw.kind == .rnmos;
                for (0..lanes) |j| {
                    const lane: ?u32 = if (sw.range == null) null else @intCast(lanes - 1 - j);
                    for (0..@as(usize, if (cmos) 2 else 1)) |half| try e.wires.append(r.arena, .{
                        .net = out,
                        .scope = scope,
                        .source = .{ .mos = .{ .data = sw.terms[1], .gate = sw.terms[2 + half], .n_type = if (cmos) half == 0 else n_type, .resistive = resistive, .lane = lane, .out_bit = if (whole == 1) null else if (width == 1) at.lo else lane } },
                        .delay = sw.delay,
                        .tok = sw.main_tok,
                    });
                }
            },
            .tran, .rtran, .tranif0, .tranif1, .rtranif0, .rtranif1 => {
                const gated = sw.kind != .tran and sw.kind != .rtran;
                // §7.6: the controlled ones take "zero, one, or two delays"
                // (the grammar already refuses any on tran and rtran).
                // One value fills all three fields (`parseDelay3`), so only a
                // third value of its own is a third delay.
                if (sw.delay.off != .none and sw.delay.off != sw.delay.rise) return r.fail(sw.main_tok, "§7.6: a pass switch takes at most two delays", .{});
                // §7.1.5/§7.1.6 an instance array is one switch per index,
                // lane `k` taking bit `k` of a terminal as wide as the array.
                // ponytail: a control as wide as the array is not split.
                const lanes: u32 = if (sw.range) |rg| try r.declaredWidth(rg, sw.main_tok) else 1;
                for (0..lanes) |k| {
                    const ta = try switchTerminal(r, e, sw.terms[0], sw.main_tok, lanes, @intCast(k));
                    const tb = try switchTerminal(r, e, sw.terms[1], sw.main_tok, lanes, @intCast(k));
                    try e.trans.append(r.arena, .{
                        .tran = .{
                            .a = ta.net,
                            .b = tb.net,
                            .a_bit = ta.bit,
                            .b_bit = tb.bit,
                            .ctrl = if (gated) sw.terms[2] else .none,
                            .on = if (sw.kind == .tranif0 or sw.kind == .rtranif0) .zero else .one,
                            .state = if (gated) .unknown else .on,
                            .target = if (gated) .unknown else .on,
                            .resistive = resistive,
                        },
                        .scope = scope,
                        .tok = sw.main_tok,
                        // Typed and valued with the drivers' (`elaborateDeep`).
                        .delay = sw.delay,
                    });
                }
            },
        }
    }
    // IEEE 1364-2005 §7.8 a pullup/pulldown "shall place a logic value 1 [0]
    // on the nets connected", at pull strength unless one is written: a
    // constant driver, the same row `unconnected_drive` contributes.
    for (items.pulls) |p| {
        // A.3.3 its terminal is a net_lvalue, a bit-select of a vector net included.
        const net = try drivenNet(r, e, scope, p.out, p.main_tok, .gate, .{ p.strength, p.strength });
        try e.wires.append(r.arena, .{ .net = net, .scope = scope, .source = .{ .pull = if (p.one) .one else .zero }, .s0 = p.strength, .s1 = p.strength, .tok = p.main_tok });
    }
}

/// VAMS §7.8.4 `m`'s instances and primitives at `scope` as the analog
/// compile's connect module insertion left them (`Mixed.inserts`): every
/// re-pointed port or primitive terminal (§7.8.5.1's names, `Ast.primTerms`)
/// bound to its segment (a net of this scope, when the bridge's side of it is
/// discrete), and one instance of each bridge appended, taking the port's
/// upper connection. The source's own lists where nothing was inserted.
// ponytail: the bridge takes no parameter override (a mixed module's
// parameters are the analog block's), and a generate scope's path is not
// matched: insertion under a generate block reaches only the analog half.
pub fn bridged(r: *Run, e: *Elab, m: *const Ast.ModuleDecl, scope: u32) Error!Bridged {
    assert(scope < r.hier.scopes.items.len);
    var b: Bridged = .{ .instances = m.instances, .gates = m.gates, .pulls = m.pulls, .switches = m.switches };
    if (r.inserts.len == 0) return b;
    const arena = r.arena;
    const path = try scopePath(r, scope);
    // The source's instances and at most one bridge per inserted row.
    var out: std.ArrayList(Ast.Instance) = try .initCapacity(arena, m.instances.len + r.inserts.len);
    out.appendSliceAssumeCapacity(m.instances);
    // The primitives' terminals and copies of their rows, once one is bridged.
    var prims: ?[]const Ast.PrimTerm = null;
    var gates: []Ast.GateInst = &.{};
    var pulls: []Ast.PullInst = &.{};
    var switches: []Ast.SwitchInst = &.{};
    var lanes: std.ArrayList(LaneSeg) = .empty;
    for (r.inserts, r.insert_segs) |row, seg| {
        if (!std.mem.eql(u8, row.path, path)) continue;
        // The port's upper connection, and the width of the segment.
        const up: Ast.PortConn, const width: u32 = if (for (out.items[0..m.instances.len]) |*it| {
            if (std.mem.eql(u8, r.file.str(it.name), row.inst)) break it;
        } else null) |inst| conn: {
            const child = try findModule(r, inst.module, inst.main_tok);
            const pi = for (child.ports, 0..) |p, k| {
                if (std.mem.eql(u8, r.file.str(p.name), row.port)) break k;
            } else return r.fail(inst.main_tok, "the connect module inserted on `{s}{s}` names a port the module does not have", .{ path, row.inst });
            const named = inst.ports.len != 0 and inst.ports[0].name != .none;
            const ci = if (!named) pi else for (inst.ports, 0..) |c, k| {
                if (c.name == child.ports[pi].name) break k;
            } else continue;
            if (ci >= inst.ports.len) continue;
            const ports = try arena.dupe(Ast.PortConn, inst.ports);
            const up = ports[ci];
            ports[ci].expr = seg;
            inst.ports = ports;
            break :conn .{ up, try portWidth(r, child.ports[pi]) };
        } else prim: {
            if (prims == null) {
                prims = try Ast.primTerms(arena, r.file, m);
                gates = try arena.dupe(Ast.GateInst, m.gates);
                pulls = try arena.dupe(Ast.PullInst, m.pulls);
                switches = try arena.dupe(Ast.SwitchInst, m.switches);
            }
            for (prims.?) |t| {
                if (!std.mem.eql(u8, t.port, row.port)) continue;
                // An instance array's lane is `inst[k]` (`insert.plan`).
                if (t.range) |rg| {
                    const k = laneIndex(row.inst, t.inst) orelse continue;
                    const msb = try r.declaredBound(rg.msb, t.main_tok);
                    const lsb = try r.declaredBound(rg.lsb, t.main_tok);
                    if (k < @min(msb, lsb) or k > @max(msb, lsb)) continue;
                    try lanes.append(arena, .{ .row = t.row, .j = @intCast(@abs(k - msb)), .term = t.term, .seg = seg });
                } else {
                    if (!std.mem.eql(u8, t.inst, row.inst)) continue;
                    try Ast.setPrimTerm(arena, gates, pulls, switches, t, t.row, seg);
                }
                // A primitive's terminal is one bit (a vector is refused).
                break :prim .{ .{ .expr = t.expr, .main_tok = t.main_tok }, 1 };
            }
            return r.fail(m.main_tok, "the connect module inserted on `{s}{s}` names an instance the source does not hold", .{ path, row.inst });
        };
        for (out.items[m.instances.len..]) |o| {
            if (std.mem.eql(u8, r.file.str(o.name), row.name)) break;
        } else {
            const bridge = try findModule(r, try interned(r, row.module), up.main_tok);
            const lower = try interned(r, row.lower_port);
            for (bridge.ports) |p| if (p.name == lower and !continuous(r.file, p.discipline)) {
                _ = try mintNet(r, e, .wire, width, false, r.file.exprs.strOf(seg), up.main_tok);
                // The segment is the scope's from its start, as an implicit
                // net is: every re-pointed terminal reads it, wherever the
                // source spells its instance (`lookupAt`).
                try r.hier.bound_at.put(r.arena, .{ .scope = scope, .str = r.file.exprs.strOf(seg) }, 0);
            };
            const conns = try arena.alloc(Ast.PortConn, 2);
            conns[0] = .{ .name = try interned(r, row.upper_port), .expr = up.expr, .main_tok = up.main_tok };
            conns[1] = .{ .name = lower, .expr = seg, .main_tok = up.main_tok };
            out.appendAssumeCapacity(.{ .module = bridge.name, .name = try interned(r, row.name), .ports = conns, .main_tok = up.main_tok });
        }
    }
    b.instances = out.items;
    if (prims != null) {
        b.gates = gates;
        b.pulls = pulls;
        b.switches = switches;
        b.lanes = lanes.items;
    }
    return b;
}

/// §6.7 the instance path of `scope`, each name followed by `.`: the prefix
/// the analog compile's flatten gives the names declared there.
pub fn scopePath(r: *Run, scope: u32) Error![]const u8 {
    if (scope == 0) return "";
    const info = r.hier.scopes.items[scope];
    return r.arena.print("{s}{s}.", .{ try scopePath(r, info.parent), r.file.str(info.name) });
}

/// VAMS §7.2.2: the variables a discrete process of `m` writes, the ones
/// whose domain is digital.
pub fn digitalWrites(r: *Run, m: *const Ast.ModuleDecl) Error!std.AutoHashMapUnmanaged(Ast.StrId, void) {
    var out: std.AutoHashMapUnmanaged(Ast.StrId, void) = .empty;
    const W = struct {
        r: *Run,
        m: *const Ast.ModuleDecl,
        out: *std.AutoHashMapUnmanaged(Ast.StrId, void),
        // One list for the whole walk: drained before the walk descends.
        writes: *std.ArrayList(Ast.ExprId),
        pub fn expr(_: @This(), _: Ast.ExprId, _: Ast.SourceFile.Edge) Error!void {}
        pub fn stmt(w: @This(), s: Ast.StmtId) Error!void {
            if (s == .none) return;
            w.writes.clearRetainingCapacity();
            try w.r.file.stmtWrites(w.m.functions, s, w.r.arena, w.writes);
            for (w.writes.items) |x| {
                const t = w.r.file.lvalueBase(x);
                if (t != .none) try w.out.put(w.r.arena, w.r.file.exprs.strOf(t), {});
            }
            try w.r.file.stmtEdges(s, w);
        }
    };
    var writes: std.ArrayList(Ast.ExprId) = .empty;
    const w: W = .{ .r = r, .m = m, .out = &out, .writes = &writes };
    for (m.discrete) |blk| try w.stmt(blk.body);
    return out;
}

/// VAMS §3.6.2.2: is `name` a continuous discipline (the analog solver's)
/// rather than a discrete one such as Annex D's `ddiscrete`, whose nets are
/// §7.2's digital nets and this engine's? The discipline only says which
/// kernel resolves a net. `src/elab/discipline_rules.zig`'s `isContinuous`
/// restated, since `sim` cannot import `ir`: the last declaration wins, and
/// an undeclared domain is continuous when a nature is bound.
pub fn continuous(file: *const Ast.SourceFile, name: Ast.StrId) bool {
    if (name == .none) return false;
    var i = file.disciplines.len;
    while (i > 0) {
        i -= 1;
        const d = &file.disciplines[i];
        if (d.name != name) continue;
        return switch (d.domain) {
            .continuous => true,
            .discrete => false,
            .unspecified => d.potential != .none or d.flow != .none,
        };
    }
    return false;
}

// ---- private ----

/// The index `k` of an instance-array lane's name `base[k]`, or null.
fn laneIndex(name: []const u8, base: []const u8) ?i64 {
    if (name.len < base.len + 3 or !std.mem.startsWith(u8, name, base) or name[base.len] != '[' or name[name.len - 1] != ']') return null;
    return std.fmt.parseInt(i64, name[base.len + 1 .. name.len - 1], 10) catch null;
}

/// A name `elaborate` made sure the file holds.
fn interned(r: *Run, name: []const u8) Error!Ast.StrId {
    return r.file.strings.find(name) orelse r.fail(0, "the inserted connect module names `{s}`, which the source does not declare", .{name});
}

/// §7.6 "the bidirectional terminals of all six devices shall be connected
/// only to scalar nets or bit-selects of vector nets": the net, and the bit
/// position a constant select names against its declared range. Lane `lane`
/// of an instance array `lanes` wide takes bit `lane` of a net that wide
/// (§7.1.6).
fn switchTerminal(r: *Run, e: *Elab, t: Ast.ExprId, tok: u32, lanes: u32, lane: u32) Error!struct { net: u32, bit: u32 } {
    assert(t != .none);
    assert(tok < r.starts.len);
    const ex = &r.file.exprs;
    if (ex.tag(t) != .index) {
        const net = r.net_of.get(try r.scalarSlot(t)) orelse return r.fail(tok, "a switch's output and inout terminals are nets", .{});
        const width = e.nets.items[net].resolved.width;
        if (lanes > 1 and width == lanes) return .{ .net = net, .bit = lane };
        if (width != 1) return r.fail(tok, "§7.6: a pass switch terminal is a scalar net or a bit-select of a vector net", .{});
        return .{ .net = net, .bit = 0 };
    }
    if (ex.tag(ex.rhs(t)) == .range or ex.tag(ex.rhs(t)) == .indexed_range) {
        // §7.1.6: an array's lanes split a part-select as they split a
        // vector (iverilog's pr3296466d `tran t3[1:0](a, c[1:0])`).
        if (lanes > 1) {
            const s = try sink(r, e, t, tok, .gate);
            if (s.width == lanes) return .{ .net = s.net, .bit = s.lo + lane };
        }
        return r.fail(tok, "§7.6: a pass switch terminal is a scalar net or a bit-select of a vector net", .{});
    }
    const at = try r.scalarSlot(ex.lhs(t));
    const net = r.net_of.get(at) orelse return r.fail(tok, "a switch's output and inout terminals are nets", .{});
    const index = try r.declaredBound(ex.rhs(t), tok);
    const width: i64 = e.nets.items[net].resolved.width;
    const range = r.vec_ranges.get(at) orelse VecRange{ .msb = width - 1, .lsb = 0 };
    const pos = range.position(index);
    if (pos < 0 or pos >= width) return r.fail(tok, "a pass switch terminal selects a bit outside its net", .{});
    return .{ .net = net, .bit = @intCast(pos) };
}

/// The net a driver of the net lvalue `target` drives: that net when
/// `target` names one whole net, else a hidden net as wide as `target`,
/// bridged into each operand's bits as a §12.3.9.2 output port's value is.
/// The bridges drive at the driver's `strength` (§7.10), since the hidden
/// net's one driver is all their value comes from.
fn drivenNet(r: *Run, e: *Elab, scope: u32, target: Ast.ExprId, tok: u32, comptime who: SinkOf, strength: [2]Ast.Strength) Error!u32 {
    assert(scope < r.hier.scopes.items.len);
    assert(target != .none);
    assert(tok < r.starts.len);
    var leaves: std.ArrayList(Ast.ExprId) = .empty;
    try concatLeaves(r, target, &leaves);
    const operands = try r.arena.alloc(Sink, leaves.items.len);
    var width: u32 = 0;
    for (leaves.items, operands) |arg, *out| {
        out.* = try sink(r, e, arg, tok, who);
        width += out.width;
    }
    r.scope = scope;
    if (operands.len == 1 and operands[0].lo == 0 and operands[0].width == e.nets.items[operands[0].net].resolved.width) return operands[0].net;
    const net = try mintNet(r, e, .wire, width, false, .none, tok);
    const first = e.wires.items.len;
    try sendPort(r, e, operands, tok, e.nets.items[net].slot, width, scope);
    for (e.wires.items[first..]) |*w| w.s0, w.s1 = strength;
    return net;
}
