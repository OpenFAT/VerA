//! Pass one of elaboration: the parsed design and its root definitions ->
//! the slot space, the nets and the driver rows (`Elab`), the scope tree
//! (`Run.scope_info`) and every name bound in it, before any expression is
//! compiled. §6.2.2's walk of the instance tree is parent-first, so a port
//! connection always resolves against a parent that is fully declared.
//! `elaborate` (root.zig) runs it, then compiles what it built.
//! Cites: IEEE 1364-2005 §4.5 implicit nets, §4.9 arrays, §4.10 and §12.2
//! parameters and defparams, §6.5/§6.5.7.1 ports, §7.1, §7.6 and §7.8 gates,
//! switches and pulls, §8 UDPs, §10 subroutine frames, §12.1.2 instance
//! arrays, §12.1.3 recursive instantiation, §12.3 port connections, §12.4
//! generate, §12.5 named blocks, §12.8.2, §19.9 unconnected_drive; VAMS §3.7
//! wreal, §6.3 the host's parameters, §7.2 continuous and discrete, §7.8.4
//! inserted connect modules.
//!
//! Pass one's steps live beside it: elab_defparams, elab_declare, elab_params,
//! elab_ports, elab_drivers, elab_paths, elab_generate, elab_slots, elab_udps;
//! this file walks the instance tree and re-exports what root.zig and the
//! rest of the interpreter call as `elab.<name>`.
//!
//! Contents:
//! - `pub const bindDefparam`
//! - `pub const checkDefparams`
//! - `pub const declare`
//! - `pub const blockScope`
//! - `pub const pathTable`
//! - `pub const netSlot`
//! - `pub const frame`
//! - `pub const earlyFrame`
//! - `pub const mintNet`
//! - `pub const checkUdp`
//! - `pub const max_depth: u32`
//! - `pub const max_insts: usize`
//! - `pub const PortBind = union(enum)`
//! - `pub const Sink = struct`
//! - `pub const Sinks = struct`
//! - `pub const Elab = struct`
//! - `pub fn pickTops(r: *Run, modules: []const Ast.ModuleDecl) Error![]const u32`
//! - `pub fn isScope(r: *const Run, s: u32, n: []const u8, k: ?i64) bool`
//! - `pub fn findModule(r: *Run, name: Ast.StrId, tok: u32) Error!*const Ast.ModuleDecl`
//! - `pub fn defOf(r: *const Run, m: *const Ast.ModuleDecl) u32`
//! - `pub fn instantiate(r: *Run, e: *Elab, scope: u32, inst: *const Ast.Instance, depth: u32) Error!void`
//! - `pub fn newScope(r: *Run, tok: u32) Error!u32`
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
const elab_declare = @import("elab_declare.zig");
const elab_defparams = @import("elab_defparams.zig");
const elab_drivers = @import("elab_drivers.zig");
const elab_generate = @import("elab_generate.zig");
const elab_params = @import("elab_params.zig");
const elab_paths = @import("elab_paths.zig");
const elab_ports = @import("elab_ports.zig");
const elab_slots = @import("elab_slots.zig");
const elab_udps = @import("elab_udps.zig");
const elab_warnings = @import("elab_warnings.zig");
const bindPort = elab_ports.bindPort;
const childPortWidth = elab_ports.childPortWidth;
const concatLeaves = elab_ports.concatLeaves;
const continuous = elab_drivers.continuous;
const declareBody = elab_declare.declareBody;
const declareHead = elab_declare.declareHead;
const declareUdp = elab_udps.declareUdp;
const expressionPorts = elab_ports.expressionPorts;
const findUdp = elab_udps.findUdp;
const generate = elab_generate.generate;
const generatedModules = elab_generate.generatedModules;
const groupByName = elab_ports.groupByName;
const internalDominates = elab_warnings.internalDominates;
const names = elab_params.names;
const nthGroup = elab_ports.nthGroup;
const portByName = elab_ports.portByName;
const selectable = elab_generate.selectable;
const sink = elab_ports.sink;
const warnCell = elab_warnings.warnCell;

/// `elab_defparams.bindDefparam`.
pub const bindDefparam = elab_defparams.bindDefparam;

/// `elab_defparams.checkDefparams`.
pub const checkDefparams = elab_defparams.checkDefparams;

/// `elab_declare.declare`.
pub const declare = elab_declare.declare;

/// `elab_declare.blockScope`.
pub const blockScope = elab_declare.blockScope;

/// `elab_paths.pathTable`.
pub const pathTable = elab_paths.pathTable;

/// `elab_slots.netSlot`.
pub const netSlot = elab_slots.netSlot;

/// `elab_slots.frame`.
pub const frame = elab_slots.frame;

/// `elab_slots.earlyFrame`.
pub const earlyFrame = elab_slots.earlyFrame;

/// `elab_slots.mintNet`.
pub const mintNet = elab_slots.mintNet;

/// `elab_udps.checkUdp`.
pub const checkUdp = elab_udps.checkUdp;

/// `declare`'s cap on the instance tree's depth, in levels (§12.1.3).
pub const max_depth: u32 = 256;

/// `declare`'s cap on the instances of the whole tree (§12.1.3).
pub const max_insts: usize = 1 << 18;

/// What the parent decided one port connection is. §6.5.7.1's "matching size
/// rule" plus IEEE 1364 clause 12's "a port is a connection, not an
/// assignment": wherever one net can stand for both sides, `collapse` makes
/// them the same net, the only model under which a child's drive strength
/// survives the boundary. The other two arms are for a connection no single
/// net can express.
pub const PortBind = union(enum) {
    /// §6.2.2 an unconnected port: the child's net exists and nothing feeds it.
    open,
    /// The parent net index this port IS, and the connection naming it
    /// (`expr` in `scope`), which a §12.3.8 width mismatch reads instead.
    collapse: struct { net: u32, expr: Ast.ExprId, scope: u32, tok: u32 },
    /// An input port fed by a parent expression that is not one whole net.
    receive: struct { expr: Ast.ExprId, scope: u32, tok: u32, slice: ?Slice = null },
    /// An output port whose parent side is not one whole net: the operands
    /// of its §12.3.9.2 structural net expression, leftmost first (§6.5.7.1
    /// joins them highest-order first).
    send: Sinks,
    /// An inout port whose parent side is not one whole net: each port bit
    /// joined to its parent bit by an always-on pass switch, operands as
    /// `send`'s. A supply strength crossing it drops to strong (§7.11's
    /// switch rule), which a real port does not do.
    // ponytail: a strength-preserving join is the upgrade.
    join: Sinks,
    /// One external port of a module with port expressions (`groupPorts`),
    /// at its first reference: the connection, made in `scope`.
    group: struct { conn: Ast.PortConn, scope: u32 },
};

/// One operand of a structural net expression: `width` bits of net `net`
/// from bit position `lo` up.
pub const Sink = struct { net: u32, lo: u32, width: u32 };

/// A port connection's structural net expression, as `Sink`s.
pub const Sinks = struct { operands: []const Sink, tok: u32 };

/// Everything §6.2.2 elaboration accumulates before any expression is compiled:
/// a name lookup in pass two must not run against a slot space a later
/// instance is still growing, whose `Int.Literal` slices would move under it.
pub const Elab = struct {
    values: std.ArrayList(Int.Literal) = .empty,
    nets: std.ArrayList(Net) = .empty,
    /// The cold rows `Net.cold` indexes; `Run.net_cold` once elaborated.
    net_cold: std.ArrayList(NetCold) = .empty,
    /// Every net's per-bit signals, `Net.signal` the first of each;
    /// `Run.signals` once elaborated.
    signals: std.ArrayList(Signal) = .empty,
    wires: std.ArrayList(Wire) = .empty,
    /// One row per elaborated instance: the definition and its name scope.
    insts: std.ArrayList(struct { module: *const Ast.ModuleDecl, scope: u32 }) = .empty,
    /// §7.6 pass switches, with the instance scope their control is read in.
    trans: std.ArrayList(struct { tran: Tran, scope: u32, tok: u32, delay: Ast.Delay3 = .{} }) = .empty,
    /// §6.6 the processes and variables of each elaborated generate block,
    /// with its scope; the variables for their §6.2.1 initializers.
    procs: std.ArrayList(struct { scope: u32, blocks: []const Ast.DiscreteBlock, vars: []const Ast.VarDecl }) = .empty,
};

/// A.2.4 `net_assignment` and everything else that ends up as one driver of one
/// net: the module's own `assign`s, a `net_decl_assignment`, and the two halves
/// of a §6.5.7 port connection that could not collapse to a single net.
///
/// `scope` is the instance the EXPRESSION is written in, which for a port
/// connection is the parent and not the module that owns the net.
const Wire = struct {
    net: u32,
    scope: u32,
    source: Source,
    s0: Ast.Strength = .strong,
    s1: Ast.Strength = .strong,
    delay: Ast.Delay3 = .{},
    tok: u32,
};

/// §6.2.2: the roots of the design are the descriptions nothing instantiates
/// (IEEE 1364-2005 §12.1.1: "A model shall contain at least one top-level
/// module"), as `file.modules` rows.
pub fn pickTops(r: *Run, modules: []const Ast.ModuleDecl) Error![]const u32 {
    // IEEE 1364-2005 §13.3.1.1: a configuration's `design` statement names
    // the top-level cells, whatever else the source leaves uninstantiated.
    if (try binding.top(r)) |defs| {
        for (defs) |d| _ = try connectable(r, &r.file.modules[d], 0);
        return defs;
    }
    var tops: std.ArrayList(u32) = try .initCapacity(r.arena, modules.len); // each module once at most
    // §12.1.1: "an instantiated module is not a top", wherever it is
    // instantiated, a generate arm the scheme does not select included.
    var generated: std.ArrayList(Ast.StrId) = .empty;
    for (modules) |other| for (other.analog) |ab| try generatedModules(r.file, ab.body, &generated, r.arena);
    outer: for (modules) |*candidate| {
        if (candidate.is_connect) continue;
        for (modules) |other| for (other.instances) |inst| {
            if (inst.module == candidate.name) continue :outer;
        };
        if (std.mem.findScalar(Ast.StrId, generated.items, candidate.name) != null) continue;
        // §13.2.1.1: a later same-named cell of its library replaces it.
        const d = defOf(r, candidate);
        if (for (modules[d + 1 ..], r.hier.def_lib[d + 1 ..]) |later, l| {
            if (later.name == candidate.name and l == r.hier.def_lib[d]) break true;
        } else false) continue;
        tops.appendAssumeCapacity(d);
    }
    if (tops.items.len == 0) return r.fail(0, "digital execution found no top-level module", .{});
    return tops.items;
}

/// Whether scope `s` is named `n`, with array or generate index `k`.
pub fn isScope(r: *const Run, s: u32, n: []const u8, k: ?i64) bool {
    const info = r.hier.scopes.items[s];
    return info.name != .none and std.mem.eql(u8, r.file.str(info.name), n) and std.meta.eql(info.index, k);
}

pub fn findModule(r: *Run, name: Ast.StrId, tok: u32) Error!*const Ast.ModuleDecl {
    assert(tok < r.starts.len);
    for (r.file.modules) |*m| if (m.name == name) return connectable(r, m, tok);
    return r.fail(tok, "undeclared module in instantiation", .{});
}

/// The `file.modules` row `m` is.
pub fn defOf(r: *const Run, m: *const Ast.ModuleDecl) u32 {
    return @intCast(m - r.file.modules.ptr);
}

/// §6.2.2 one module or UDP instance, declared in `scope`, or IEEE 1364
/// §12.1.2's array of them, one instance per element from the lower index
/// up, each a scope named `u[k]` (the same order the analog elaborator uses).
pub fn instantiate(r: *Run, e: *Elab, scope: u32, inst: *const Ast.Instance, depth: u32) Error!void {
    assert(scope < r.hier.scopes.items.len);
    r.scope = scope;
    if (findUdp(r.file, inst.module)) |u| return declareUdp(r, e, scope, inst, u);
    // IEEE 1364-2005 A.4.1.1: a module_instantiation's `#` is a
    // parameter_value_assignment, so the UDP-shaped `m #1 u(w)` is no
    // module instance.
    if (inst.delay.any()) return r.fail(inst.main_tok, "A.4.1.1: a module instance takes no delay; `#( … )` is its parameter value assignment", .{});
    const range = inst.range orelse return instantiateOne(r, e, scope, inst, depth, null);
    const msb = try r.declaredBound(range.msb, inst.main_tok);
    const lsb = try r.declaredBound(range.lsb, inst.main_tok);
    var k = @min(msb, lsb);
    while (k <= @max(msb, lsb)) : (k += 1) try instantiateOne(r, e, scope, inst, depth, k);
}

/// The next scope id. The caller appends its `scope_info` row, which must be
/// row `id` (ids are dense, root 0). Fails at 2^32 - 1 scopes.
pub fn newScope(r: *Run, tok: u32) Error!u32 {
    assert(tok < r.starts.len);
    r.hier.scope_count += 1;
    if (r.hier.scope_count == std.math.maxInt(u32)) return r.fail(tok, "too many digital instances", .{});
    try r.hier.scope_toks.put(r.arena, r.hier.scope_count, tok);
    return r.hier.scope_count;
}

// ---- private ----

/// `m`, unless it is a connect module and this is not a mixed design.
fn connectable(r: *Run, m: *const Ast.ModuleDecl, tok: u32) Error!*const Ast.ModuleDecl {
    assert(tok < r.starts.len);
    // VAMS §7.1: a connect module "can be manually inserted (by the user) or
    // automatically inserted (by the simulator)", in a mixed design, which is
    // the only one that can hold its continuous half.
    if (m.is_connect and !r.analog.mixed) return r.fail(tok, "a connect module is inserted by §7.6 discipline resolution, not instantiated", .{});
    return m;
}

/// §12.1.2: "If the bit length of a port expression is the same as the
/// port's, the expression is connected to each instance" (null: bind it
/// whole). One as wide as the port times the element count is split: IEEE
/// 1364-2005 §7.1.6, "each instance shall get a part-select of the port
/// expression as specified in the range, starting with the right-hand index".
fn arrayConn(r: *Run, e: *Elab, inst: *const Ast.Instance, child_scope: u32, port: Ast.Port, conn: Ast.PortConn, k: i64) Error!?PortBind {
    const refused = "§12.1.2: only an expression as wide as the port or as the port times the array size is connected across an instance array";
    const w = try childPortWidth(r, child_scope, port);
    // `typeOf` reads the slots elaborated so far, as `sink` does.
    r.values = e.values.items;
    try compile.checkExpr(r, conn.expr);
    const whole = compile.typeOf(r, conn.expr).width;
    // §12.1.2: "If the bit length of a port expression is the same as the
    // port, the expression is connected to each instance", whatever it is.
    if (whole == w) return null;
    const range = inst.range.?;
    const left = try r.declaredBound(range.msb, inst.main_tok);
    const right = try r.declaredBound(range.lsb, inst.main_tok);
    // Two i64 bounds can span 2^64 elements, and each port is up to u32
    // bits wide. Size in u128 before comparing: a mismatch is the same
    // §7.1.6 error even when the product would not fit a storage-slot width.
    const count = @abs(@as(i128, left) - right) + 1;
    if (whole != @as(u128, w) * count) return r.fail(conn.main_tok, refused, .{});
    const lo: u32 = @intCast(@abs(@as(i128, k) - right) * w);
    return switch (port.direction) {
        .input => .{ .receive = .{ .expr = conn.expr, .scope = r.scope, .tok = conn.main_tok, .slice = .{ .lo = lo, .total = whole } } },
        // The instance's bits [lo, lo + w) of the expression, which may be
        // a concatenation (the LRM's own `.out({bushigh, buslow})`): each
        // operand's share, rightmost operand the lowest bits. An inout's
        // share is joined as `bindPort` joins a select (iverilog's pr2219441).
        .output, .inout => blk: {
            var leaves: std.ArrayList(Ast.ExprId) = .empty;
            try concatLeaves(r, conn.expr, &leaves);
            var picked: std.ArrayList(Sink) = .empty;
            var at: u32 = 0;
            var i = leaves.items.len;
            while (i != 0) {
                i -= 1;
                const s = try sink(r, e, leaves.items[i], conn.main_tok, .port);
                const a = @max(at, lo);
                const b = @min(at + s.width, lo + w);
                if (a < b) try picked.insert(r.arena, 0, .{ .net = s.net, .lo = s.lo + (a - at), .width = b - a });
                at += s.width;
            }
            const s: Sinks = .{ .operands = picked.items, .tok = conn.main_tok };
            break :blk if (port.direction == .output) .{ .send = s } else .{ .join = s };
        },
        .unspecified => r.fail(conn.main_tok, refused, .{}),
    };
}

fn instantiateOne(r: *Run, e: *Elab, scope: u32, inst: *const Ast.Instance, depth: u32, index: ?i64) Error!void {
    assert(scope < r.hier.scopes.items.len);
    const arena = r.arena;
    r.scope = scope;
    const bound = try binding.child(r, scope, inst);
    const child = try connectable(r, &r.file.modules[bound.def], inst.main_tok);
    try checkLists(r, child, inst);
    const binds_out = try arena.alloc(PortBind, child.ports.len);
    @memset(binds_out, .open);
    // The child's scope and parameters first: its port ranges may name them.
    const child_scope = try newScope(r, inst.main_tok);
    try r.hier.scopes.append(arena, .{ .parent = scope, .name = inst.name, .def = bound.def, .index = index });
    try r.hier.binds.put(arena, child_scope, bound.ctx);
    try declareHead(r, e, child, child_scope, inst.params, depth + 1);
    r.scope = scope;
    const grouped = !r.analog.mixed and expressionPorts(child);
    if (grouped) {
        if (index != null) return r.fail(inst.main_tok, "§12.1.2: an instance array of a module with port expressions is not implemented by digital execution", .{});
        for (inst.ports, 0..) |conn, i| {
            const at = if (conn.name != .none)
                groupByName(child, conn.name) orelse return r.fail(conn.main_tok, "the instantiated module has no such port", .{})
            else
                nthGroup(child, i) orelse return r.fail(conn.main_tok, "more port connections than the module has ports", .{});
            binds_out[at] = .{ .group = .{ .conn = conn, .scope = scope } };
        }
    }
    for (if (grouped) inst.ports[0..0] else inst.ports, 0..) |conn, i| {
        // IEEE 1364-2005 §12.3.2/§12.3.6: a header port `.name(expr)` is
        // connected by its external name, and when its expression is a
        // concatenation of internal ports every one of them is a slice
        // of the one connection, leftmost the most significant.
        if (conn.name != .none and portByName(child, conn.name) == null) {
            const first = for (child.ports, 0..) |p, k| {
                if (p.external_name == conn.name) break k;
            } else return r.fail(conn.main_tok, "the instantiated module has no such port", .{});
            if (index != null) return r.fail(conn.main_tok, "§12.1.2: a concatenated port across an instance array is not implemented by digital execution", .{});
            var total: u32 = 0;
            var last = first;
            while (last < child.ports.len and (last == first or child.ports[last].concat_rest)) : (last += 1)
                total += try childPortWidth(r, child_scope, child.ports[last]);
            var lo = total;
            for (child.ports[first..last], first..) |p, k| {
                if (p.direction != .input) return r.fail(conn.main_tok, "only an input port may be a concatenation of internal ports", .{});
                const w = try childPortWidth(r, child_scope, p);
                lo -= w;
                r.scope = scope;
                binds_out[k] = if (conn.expr == .none) .open else .{ .receive = .{ .expr = conn.expr, .scope = scope, .tok = conn.main_tok, .slice = .{ .lo = lo, .total = total } } };
            }
            continue;
        }
        const at = if (conn.name == .none) i else portByName(child, conn.name).?;
        if (at >= child.ports.len) return r.fail(conn.main_tok, "more port connections than the module has ports", .{});
        // A.1.3: a null port keeps its header position but connects
        // nothing inside, including across an array of instances.
        if (child.ports[at].name == .none) continue;
        r.scope = scope;
        // A continuous port is the analog solver's on both sides (§7.2.1),
        // so a mixed design's digital half connects nothing through it,
        // as the child's own port loop skips it.
        if (r.analog.mixed and continuous(r.file, child.ports[at].discipline)) continue;
        if (index) |k| if (conn.expr != .none) if (try arrayConn(r, e, inst, child_scope, child.ports[at], conn, k)) |split| {
            binds_out[at] = split;
            continue;
        };
        binds_out[at] = try bindPort(r, e, child.ports[at], conn, scope);
    }
    // §12.4's path is walked by name, so the instance's own identifier has
    // to outlive the recursion that consumes it. An array element's path
    // carries its index, which that walk does not read: not registered.
    if (inst.name != .none) if (index) |k| try selectable(r, scope, inst.name, k, child_scope) else try r.hier.instances.put(arena, .{ .scope = scope, .str = inst.name }, child_scope);
    try declareBody(r, e, child, child_scope, binds_out, depth + 1);
    r.scope = scope;
}

/// IEEE 1364-2005 §12.2.2 and §12.3.6: an instance's parameter value
/// assignments, and its port connections, are each all ordered or all named;
/// a named one names a parameter (not a local one) or a port once; and no
/// more ordered values are given than the module has parameters.
fn checkLists(r: *Run, child: *const Ast.ModuleDecl, inst: *const Ast.Instance) Error!void {
    for (inst.params, 0..) |o, i| {
        if ((o.name == .none) != (inst.params[0].name == .none))
            return r.fail(o.main_tok, "§12.2.2: a parameter value assignment mixes ordered and named parameter assignments", .{});
        if (o.name == .none) continue;
        const name = r.file.str(o.name);
        // A.4.1.1's `.name()` assigns nothing (§12.2.2.2: "without assigning
        // anything to it"), so it is no second assignment.
        if (o.value != .none) for (inst.params[0..i]) |q| if (q.name == o.name and q.value != .none) return r.fail(o.main_tok, "§12.2.2.2: parameter `{s}` is assigned twice", .{name});
        const p = for (child.params) |p| {
            if (p.name == o.name) break p;
        } else return r.fail(o.main_tok, "§12.2.2.2: the module has no such parameter: `{s}`", .{name});
        if (p.is_local) return r.fail(o.main_tok, "§12.2: `{s}` is a local parameter, which a parameter value assignment cannot override", .{name});
    }
    if (inst.params.len != 0 and inst.params[0].name == .none) {
        var n: usize = 0;
        for (child.params) |p| n += @intFromBool(!p.is_local);
        // §12.2.2.1 says nothing of a value past the last parameter; it is
        // ignored with a warning, as iverilog ignores it (ivtest param_test3;
        // specification/Vague_Decisions.md VD-139).
        if (inst.params.len > n) {
            const at = r.starts[@min(inst.params[n].main_tok, r.starts.len - 1)];
            try r.bag.add(.lower, .W1161, .{ .start = at, .end = at }, "§12.2.2.1: {d} more parameter value(s) than the module has parameters ({d}); the extra ones are ignored", .{ inst.params.len - n, n });
        }
    }
    for (inst.ports, 0..) |c, i| {
        if ((c.name == .none) != (inst.ports[0].name == .none))
            return r.fail(c.main_tok, "§12.3.6: an instance mixes ordered and named port connections", .{});
        if (c.name == .none) continue;
        for (inst.ports[0..i]) |q| if (q.name == c.name) return r.fail(c.main_tok, "§12.3.6: port `{s}` is connected twice", .{r.file.str(c.name)});
    }
}

test "VAMS §7.2.2 the digital half of a mixed-signal module elaborates beside its analog half" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    // Already preprocessed text, as an analog compile hands it over: the
    // timescale arrives in `Mixed`, not as a directive.
    var r = try root.elaborate(arena.allocator(),
        \\discipline electrical potential Voltage; flow Current; enddiscipline
        \\module helper(a); inout a; electrical a; analog V(a) <+ 0; endmodule
        \\module dac(out);
        \\  inout out; electrical out; electrical inner;
        \\  parameter real gain = 2.0;
        \\  reg [3:0] code; real x;
        \\  initial begin code = 4'd3; #5 code = 4'd7; end
        \\  analog begin x = gain * code; V(out) <+ x; end
        \\endmodule
    , .{ .mixed = .{ .top = "dac", .timescales = &.{.{ .at = 0, .value = .{ .unit = 1e-9, .precision = 1e-9 } }} } }, &bag, &output.writer);
    const at = r.slotOf("code").?;
    // The continuous half is not the digital engine's to hold.
    try std.testing.expectEqual(@as(?u32, null), r.slotOf("x"));
    try std.testing.expectEqual(@as(?u32, null), r.slotOf("out"));
    try std.testing.expectEqual(@as(?u32, null), r.slotOf("inner"));
    _ = try r.runUntil(0);
    try std.testing.expectEqual(@as(?i64, 3), r.values[at].asInt());
    _ = try r.runUntil(5);
    try std.testing.expectEqual(@as(?i64, 7), r.values[at].asInt());
}

test "§12.3.3 an output port declared as a variable drives the net it connects to" {
    try expectRun(
        \\`timescale 1ns/1ps
        \\module inv(d, q);
        \\input d; output q; reg q;
        \\always @(d) q = ~d;
        \\endmodule
        \\module top;
        \\reg a; wire b, c;
        \\inv u(a, b), v(b, c);
        \\initial begin #0 a = 1'b0; #1 $display("b=%b c=%b", b, c); a = 1'b1; #1 $display("b=%b c=%b", b, c); end
        \\endmodule
    , "b=1 c=0\nb=0 c=1\n");
}

test "§12.1.2 an instance array is one instance per element, each connected" {
    try expectRun(
        \\`timescale 1ns/1ps
        \\module leaf(a);
        \\input a;
        \\wire a;
        \\initial #1 $display("%m %b", a);
        \\endmodule
        \\module top;
        \\reg r;
        \\leaf u[1:0](r);
        \\initial r = 1'b1;
        \\endmodule
    , "top.u[0] 1\ntop.u[1] 1\n");
    try expectRun(
        \\`timescale 1ns/1ps
        \\module leaf(a);
        \\input a;
        \\initial #1 $display("%m %b", a);
        \\endmodule
        \\module top;
        \\reg [1:0] r;
        \\leaf u[1:0](r);
        \\initial r = 2'b10;
        \\endmodule
    , "top.u[0] 0\ntop.u[1] 1\n");
    try expectRejected(
        \\module leaf(a);
        \\input a;
        \\endmodule
        \\module top;
        \\reg [2:0] r;
        \\leaf u[1:0](r);
        \\endmodule
    , "across an instance array");
}

test "§12.1.3 a module instantiating itself outside a terminating generate is refused, not elaborated without end" {
    // ivtest pr2728812c's shape: `sum` at n = 1 makes two more at n = 1.
    try expectRejected(
        \\module sum #(parameter n = 4) (input c, output s);
        \\wire a1, a2;
        \\sum #(n/2) s0 (c, a1);
        \\sum #(n-n/2) s1 (c, a2);
        \\assign s = a1 ^ a2;
        \\endmodule
        \\module top;
        \\reg c;
        \\wire s;
        \\sum #(5) u (c, s);
        \\endmodule
    , "instantiates itself without a terminating generate");
}

test "§10.4.5 a constant function call in a parameter's value runs at elaboration" {
    try expectRun(
        \\module ram_model;
        \\parameter ram_depth = 256;
        \\localparam addr_width = clogb2(ram_depth);
        \\reg [addr_width - 1:0] address;
        \\function integer clogb2;
        \\  input [31:0] value;
        \\  begin
        \\    value = value - 1;
        \\    for (clogb2 = 0; value > 0; clogb2 = clogb2 + 1)
        \\      value = value >> 1;
        \\  end
        \\endfunction
        \\initial #1 $display("%0d %0d %b", addr_width, clogb2(5), address);
        \\endmodule
        \\module top;
        \\ram_model #(421) a();
        \\ram_model b();
        \\endmodule
    , "9 3 xxxxxxxxx\n8 3 xxxxxxxx\n");
    try expectRejected(
        \\module m;
        \\reg [3:0] g;
        \\function integer f;
        \\  input integer x;
        \\  f = x + g;
        \\endfunction
        \\localparam P = f(1);
        \\endmodule
    , "§10.4.5");
}

test "§4.5 an implicit net is of the default net type; `default_nettype none makes none" {
    try expectRun(
        \\`default_nettype tri0
        \\module top;
        \\assign k = 1'bz;
        \\initial #1 $display("%b", k);
        \\endmodule
    , "0\n");
    try expectRejected(
        \\`default_nettype none
        \\module top;
        \\assign k = 1'b1;
        \\endmodule
    , "undeclared");
}

test "§19.9 unconnected_drive pulls an open input port and loses to a stronger driver" {
    try expectRun(
        \\`timescale 1ns/1ps
        \\`unconnected_drive pull1
        \\module child(a, b);
        \\input a;
        \\input b;
        \\wire a, b;
        \\endmodule
        \\`nounconnected_drive
        \\module top;
        \\wire s;
        \\assign (strong0, strong1) s = 1'b0;
        \\child u( , s);
        \\initial #0 $display("open=%b driven=%b", u.a, u.b);
        \\endmodule
    , "open=1 driven=0\n");
}

test "§19.9 nounconnected_drive leaves an open input port floating" {
    try expectRun(
        \\`timescale 1ns/1ps
        \\module child(a);
        \\input a;
        \\wire a;
        \\endmodule
        \\module top;
        \\child u( );
        \\initial #0 $display("%b", u.a);
        \\endmodule
    , "z\n");
}

test "§12.2 parameters fold into bounds, delays and expressions" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m #(parameter W = 4) ();
        \\localparam [2:0] SEVEN = 15, D = W / 2;
        \\parameter integer N = -W;
        \\reg [W-1:0] r; reg [-2:1] neg; wire #D late;
        \\reg s; assign late = s;
        \\initial begin
        \\  r = 5'h1f; neg = 17; s = 1;
        \\  #1 $display("%b %0d %0d %b %b %b", r, SEVEN, N, neg, late, W == 4);
        \\  #2 $display("%b", late);
        \\end
        \\endmodule
    , "1111 7 -4 0001 x 1\n1\n");
}

test "§12.2 a parameter takes a defparam over a named or positional override over its default" {
    // §12.2.2 `#(.n(v))` and `#(v)` are constant expressions in the
    // instantiating module (`k` is the parent's); §12.2.1 a defparam wins.
    try expectRun(
        \\module c; parameter a = 1, b = 2; localparam l = a + b;
        \\initial #1 $display("%m %0d %0d %0d", a, b, l);
        \\endmodule
        \\module top; parameter k = 5;
        \\c #(.b(k * 2)) u1(); c #(7) u2(); c u3();
        \\defparam u3.a = k + 1;
        \\endmodule
    , "top.u1 1 10 11\ntop.u2 7 2 9\ntop.u3 6 2 8\n");
}

test "VAMS §6.3 a mixed root reads the card's value and an instance its override; an unused real stays analog" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    var r = try root.elaborate(arena.allocator(),
        \\discipline electrical potential Voltage; flow Current; enddiscipline
        \\module h; parameter integer sel = 0; integer got; initial got = sel; endmodule
        \\module top(p); inout p; electrical p;
        \\  parameter integer n = 1; parameter real g = 2.0; integer seen;
        \\  h #(.sel(3)) u();
        \\  initial seen = n;
        \\  analog V(p) <+ g;
        \\endmodule
    , .{ .mixed = .{ .top = "top", .timescales = &.{.{ .at = 0, .value = .{ .unit = 1e-9, .precision = 1e-9 } }}, .params = &.{.{ .name = "n", .value = 4 }} } }, &bag, &output.writer);
    _ = try r.runUntil(0);
    try std.testing.expectEqual(@as(?i64, 4), r.values[r.slotOf("seen").?].asInt());
    try std.testing.expectEqual(@as(?i64, 3), r.values[r.slotOf("u.got").?].asInt());
    try std.testing.expectEqual(@as(?u32, null), r.slotOf("g"));
}

test "VAMS §6.3.4 selected real parameters arrive from the derived host model" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    var r = try root.elaborate(arena.allocator(),
        \\discipline electrical potential Voltage; flow Current; enddiscipline
        \\module m(p); inout p; electrical p;
        \\  parameter real base = 2.0, unused = 7.0;
        \\  parameter real selected = ln(base);
        \\  parameter inferred = 2.0 * base;
        \\  localparam real local = 2.0 * selected;
        \\  initial #1 $display("%g %g %g", selected, inferred, local);
        \\  analog I(p) <+ 0.0;
        \\endmodule
    , .{ .mixed = .{
        .top = "m",
        .timescales = &.{.{ .at = 0, .value = .{ .unit = 1e-9, .precision = 1e-9 } }},
        .real_params = &.{
            .{ .name = "selected", .value = 0.25 },
            .{ .name = "inferred", .value = 4.0 },
            .{ .name = "local", .value = 0.5 },
        },
    } }, &bag, &output.writer);
    // The host overrode selected and derived local. ln() is intentionally
    // outside digital constant evaluation: the supplied value is authoritative.
    _ = try r.runUntil(1);
    try std.testing.expectEqualStrings("0.25 4 0.5\n", output.written());
    try std.testing.expectEqual(@as(?u32, null), r.slotOf("base"));
    try std.testing.expectEqual(@as(?u32, null), r.slotOf("unused"));
    for ([_][]const u8{ "selected", "inferred", "local" }) |name|
        try std.testing.expect(r.decls.reals.contains(r.slotOf(name).?));
}

test "§12.4.2 a conditional generate instantiates only its selected arm" {
    try expectRun(
        \\module a; initial $display("a"); endmodule
        \\module b; initial $display("b"); endmodule
        \\module m #(parameter P = 1) ();
        \\generate if (P == 0) begin : g0 a u(); end else if (P == 1) begin : g1 b u(); end endgenerate
        \\endmodule
    , "b\n");
}

test "§12.4.1/§12.4.2 a loop generate unrolls and a case generate selects" {
    try expectRun(
        \\module c(input [3:0] v); initial #1 $display("%m %0d", v); endmodule
        \\module d; initial #2 $display("d"); endmodule
        \\module m;
        \\genvar i;
        \\for (i = 3; i > 0; i = i - 2) begin : g c u(i + 1); end
        \\generate case (2'b1x) 2'b10: begin : e c u(0); end 2'b1x: begin : f d u(); end endcase endgenerate
        \\endmodule
    , "m.g[3].u 4\nm.g[1].u 2\nd\n");
    try expectRejected("module c; endmodule\nmodule m; genvar i; for (i = 0; i < 2; i = i) begin : g c u(); end endmodule", "genvar value is repeated");
}

test "§12.3.6 an external port name, alone or over a concatenation" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module c(.in({a, b}), .o(y)); input [1:0] a; input b; output y; assign y = a[1] ^ b; endmodule
        \\module m; wire q; c u(.in(3'b101), .o(q)); initial #1 $display("%b %b%b", q, u.a, u.b); endmodule
    , "0 101\n");
}

test "§12.3.11 the sign attribute does not cross a port, and a signed net is signed" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module sc(input signed [7:0] v, output n); assign n = v < 0; endmodule
        \\module uc(v, n); input [7:0] v; output n; assign n = v < 0; endmodule
        \\module m;
        \\wire [7:0] pu = 8'hff;
        \\wire signed [7:0] ps = 8'hff;
        \\wire a, b;
        \\sc x(pu, a);
        \\uc y(ps, b);
        \\initial #1 $display("%b%b %0d %0d", a, b, ps, pu);
        \\endmodule
    , "10 -1 255\n");
}

test "§7.8 pullup and pulldown are drivers at the strength of their own side" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\wire a, b, c, d;
        \\pullup (weak0, strong1) pa(a);
        \\pullup (strong0, weak1) pb(b);
        \\pulldown da(a), db(b);
        \\pullup (c);
        \\reg r;
        \\assign (weak0, weak1) d = r;
        \\pullup (d);
        \\initial begin r = 0; #1 $display("%b%b%b%b", a, b, c, d); end
        \\endmodule
    , "1011\n");
}

test "a legal wreal runs, and hears none of the structural wreal codes" {
    // §3.7's compatible list is wire, tri and wreal, and one driver is legal.
    const legal = [_][]const u8{
        "module m; real a; wreal w; assign w = a; endmodule",
        "module c(o); output o; wreal o; endmodule\nmodule m; wire n; c u(.o(n)); endmodule",
        "module c(o); output o; wreal o; endmodule\nmodule m; tri n; c u(n); endmodule",
        "module c(o); output o; wreal o; endmodule\nmodule m; wreal n; c u(n); endmodule",
    };
    for (legal) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var bag = diag.Bag.init(arena.allocator());
        var output = std.Io.Writer.Allocating.init(arena.allocator());
        try root.run(arena.allocator(), source, .{}, &bag, &output.writer);
        var messages = std.Io.Writer.Allocating.init(arena.allocator());
        try diag.render(&bag, &messages.writer, .{});
        try std.testing.expect(std.mem.find(u8, messages.written(), "E0918") == null);
        try std.testing.expect(std.mem.find(u8, messages.written(), "E0919") == null);
    }
}

test "the net and array declaration boundaries are explicit" {
    // §6.1/§6.2.2: neither form of assignment accepts the other's target.
    try expectRejected("module m; wire w; initial w = 1; endmodule", "no procedural assignment to a net");
    try expectRejected("module m; reg r; initial $display(\"before\"); assign r = 1; endmodule", "can only drive a net");
    try expectRejected("module m; wire w; reg a; assign w[0] = a; endmodule", "a scalar has no bits to select");
    // §7.9 uwire resolves nothing, so a second driver is an error.
    try expectRejected("module m; uwire u; reg a,b; assign u = a; assign u = b; endmodule", "uwire net accepts a single driver");
    // §6.5.3 a wreal has at most one driver, and §3.7 closes the list of net
    // types a port may join it to.
    try expectRejected("module m; real a,b; wreal w; assign w = a; assign w = b; endmodule", "E0918");
    try expectRejected("module m; real a; wreal w = a; assign w = a; endmodule", "E0918");
    try expectRejected("module c(o); output o; wreal o; endmodule\nmodule m; wand n; c u(.o(n)); endmodule", "E0919");
    try expectRejected("module c(o); output o; wand o; endmodule\nmodule m; wreal n; c u(n); endmodule", "E0919");
    // A.2.2.2: every alternative pairs ONE 0-side spec with ONE 1-side spec,
    // and `charge_strength` is a different production that A.2.1.3 grants only
    // to `trireg`. A parser that read "any parenthesised strength after any net
    // type" would accept both of these.
    try expectRejected("module m; wire w; reg a; assign (strong0, pull0) w = a; endmodule", "pairs one 0-side with one 1-side");
    try expectRejected("module m; wire (small) w; reg a; assign w = a; endmodule", "charge strength is only legal on a trireg");
    // A.2.2.3's `delay_value` admits an `identifier`, which must name a
    // parameter; this one names nothing.
    try expectRejected("`timescale 1ns/1ns\nmodule m; wire #w y; reg a; assign y = a; endmodule", "undeclared digital variable");
    // §3.9 an array has no value of its own, and a select is not an element.
    try expectRejected("module m; reg [3:0] mem [0:3]; initial $display(\"%b\",mem); endmodule", "requires an element index");
    try expectRejected("module m; reg [3:0] mem [0:1]; reg a; initial @(mem) a = 1; endmodule", "requires an element index");
    try expectRejected("module m; reg [3:0] a; integer i; initial $display(\"%b\",a[i:0]); endmodule", "constant expression is required");
    try expectRejected("module m; reg [3:0] mem [0:1][0:1]; initial $display(\"%b\", mem[0]); endmodule", "requires an element index");
    try expectRun("module m; reg [3:0] mem [0:1]; initial begin mem[65'h1] = 15; $display(\"%h\", mem[65'h1]); end endmodule", "f\n");
    // §3.6 a disciplined net belongs to the analog solver, not to this executor.
    // A.2.4's `net_decl_assignment` on an undisciplined net runs.
    try expectRejected("module m; electrical e; initial $display(\"x\"); endmodule", "disciplined and ground");
    try expectRejected("module m; wire [p:0] w; initial $display(\"x\"); endmodule", "undeclared digital variable");
    try expectRejected("module m; reg [3:0] a; wire [a:0] w; initial $display(\"x\"); endmodule", "constant expression is required");
    try expectRejected("module m; parameter P = 1; initial P = 2; endmodule", "parameter is a constant");
}

test "§12.3.10 Table 12-1: a warn cell warns either way round, and no type warns against itself" {
    const kinds = [_]Ast.NetKind{ .wire, .tri, .tri0, .tri1, .triand, .trior, .trireg, .wand, .wor, .uwire, .supply0, .supply1, .wreal };
    for (kinds) |i| {
        try std.testing.expect(!warnCell(i, i));
        // A type never dominates itself, and of two types at most one
        // dominates the other ("int" and "ext" are a cell's two answers).
        try std.testing.expect(!internalDominates(i, i));
        for (kinds) |x| {
            try std.testing.expectEqual(warnCell(i, x), warnCell(x, i));
            try std.testing.expect(!(internalDominates(i, x) and internalDominates(x, i)));
        }
    }
}

test "§6.1.1/A.3.3 a driver of a variable's select names the construct that drives it" {
    // Each construct says what it is: the refusal is not an output port's
    // when no port is involved.
    try expectRejected("module m; reg [1:0] a; assign a[0] = 1'b1; endmodule", "a continuous assignment can only drive a net");
    try expectRejected("module m; reg [1:0] a; reg b; and g(a[0], b, b); endmodule", "a gate's output terminal must be a net");
}

test "§4.9 a net array element driven by a constant index" {
    // §4.9.1 one net per element; `assign w[1] = ...` drives element 1 only.
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\wire w [0:2];
        \\assign w[1] = 1'b1;
        \\initial #1 $display("%b%b%b", w[0], w[1], w[2]);
        \\endmodule
    , "z1z\n");
}

test "IEEE 1364-2005 §12.3.9.2 a port of another width converts as an assignment, §12.3.8 coerces a port used the other way" {
    // Oracle: iverilog -g2005 prints this line for the same source. An
    // output narrower than its net widens (zero, or a signed port's sign);
    // an inout joins the bits both sides have; an input the module drives
    // is coerced to inout; a tran array splits a part-select (§7.1.6).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    try root.run(arena.allocator(),
        \\module lo(output [1:0] o, output signed [1:0] so, inout [1:0] io, input [1:0] ci);
        \\  assign o = 2'b10; assign so = 2'b10; assign io = 2'b01; assign ci = 2'b11;
        \\endmodule
        \\module top;
        \\  wire [3:0] o, so, io; wire [2:0] ci; wire [3:0] t; wire [1:0] p;
        \\  lo u(o, so, io, ci);
        \\  tran g[1:0](p, t[2:1]);
        \\  assign p = 2'b10;
        \\  initial #1 $display("%b %b %b %b %b", o, so, io, ci, t);
        \\endmodule
    , .{ .language = .v1364_2005 }, &bag, &output.writer);
    try std.testing.expectEqualStrings("0010 1110 zz01 z11 z10z\n", output.written());
}

test "§10.4.5 a constant function's disable of its own named block ends the block" {
    // Oracle: iverilog -g2005 prints 8 (ivtest constfunc9/10's form): the
    // function is compiled early, before every process exists, so it binds
    // its `disable` then (`root.bindDisables`).
    try root.expectRun(
        \\module m;
        \\  function [31:0] g(input [5:0] x);
        \\  begin : body
        \\    g = 1;
        \\    while (1) begin : loop
        \\      if (x == 0) disable body;
        \\      g = 2 * g;
        \\      x = x - 1;
        \\      disable loop;
        \\      g = 0;
        \\    end
        \\  end
        \\  endfunction
        \\  localparam q = g(3);
        \\  initial $display("%0d", q);
        \\endmodule
    , "8\n");
}

test "§12.7 a gate, switch or UDP instance name hides an outer name of the same spelling" {
    // iverilog's gate_instance_shadow_fail family: the inner `i_g` is an
    // instance, so neither the outer variable nor the outer function is
    // what `i_g` names inside the block.
    try expectRejected("module m; integer i_g = 23; if (1) begin : g wire o; and i_g(o, 1'b1, 1'b1); initial $display(\"%0d\", i_g); end endmodule", "undeclared digital variable");
    try expectRejected("module m; function integer i_g(input integer v); i_g = v; endfunction if (1) begin : g wire o; initial $display(\"%0d\", i_g(1)); and i_g(o, 1'b1, 1'b1); end endmodule", "undeclared function");
    // Only from the instance on (iverilog's gate_instance_reference_order).
    try expectRun("module m; parameter i_g = 23; if (1) begin : g wire o; initial #1 $display(\"%0d\", i_g); and i_g(o, 1'b1, 1'b1); end endmodule", "23\n");
    // The neighbour: a differently named gate hides nothing.
    // (#1: the block's initial runs before the outer initializer at time 0,
    // iverilog's order, which prints x.)
    try expectRun("module m; integer i_g = 23; if (1) begin : g wire o; and a(o, 1'b1, 1'b1); initial #1 $display(\"%0d\", i_g); end endmodule", "23\n");
}

test "§12.2.2.2 an empty named parameter assignment assigns nothing, so it is no second assignment" {
    // iverilog's parameter_named_empty.
    try expectRun("module M #(parameter V = 1); endmodule module t; M #(.V(), .V()) a(); M #(.V(), .V(2)) b(); M #(.V(3), .V()) c(); initial $display(\"%0d %0d %0d\", a.V, b.V, c.V); endmodule", "1 2 3\n");
    try expectRejected("module M #(parameter V = 1); endmodule module t; M #(.V(1), .V(), .V(2)) a(); endmodule", "is assigned twice");
}

test "§4.10.3 a specify block's specparam may name a later one of the block" {
    // Only a specparam "declared outside a specify block shall be declared
    // before it is referenced" (iverilog's specparam_specify_reference_order).
    try expectRun("module m; specify specparam v = d + 1; specparam d = 41; endspecify initial $display(\"%0d\", v); endmodule", "42\n");
    try expectRejected("module m; specparam v = d; specparam d = 41; initial $display(\"%0d\", v); endmodule", "");
}

test "A.3.3 a MOS switch drives a constant bit-select of a vector net" {
    // iverilog's rise_fall_decay2: each switch drives its own bit, the
    // others' bits stay z.
    try expectRun("module m; reg i; wire [2:0] o; nmos a(o[0], i, 1'b1); pmos b(o[2], i, 1'b0); initial begin i = 1; #1 $display(\"%b\", o); end endmodule", "1z1\n");
}

test "A.8.5 a continuous assignment drives a hierarchical net or a select of one" {
    // iverilog's pr1755629: `what[i].slice[i]`, a net of a loop generate's
    // iteration named from another one.
    try expectRun("module m; genvar i; for (i = 0; i < 2; i = i + 1) begin : w wire [1:0] s; end for (i = 0; i < 2; i = i + 1) begin : a assign w[i].s[i] = 1'b1; end initial #1 $display(\"%b %b\", w[0].s, w[1].s); endmodule", "z1 1z\n");
}

test "§14.6.1 `PATHPULSE$ = 3;`, the clause's own unparenthesized form, is a reject limit" {
    // ISP RAS test_14_06_01_1 is the clause's example.
    try expectRun("module m(input a, output q); assign q = a; specify (a => q) = 12; specparam PATHPULSE$a$q = (2, 9), PATHPULSE$ = 3; endspecify endmodule module t; reg a; wire q; m u(a, q); initial begin a = 0; #20 $display(\"%b\", q); end endmodule", "0\n");
}

test "§7.1.6 an instance array's port is sized by the child's parameters, not a parent parameter of the same name" {
    // Oracle: iverilog -g2005 prints 010011. `W` is 3 in each `c` (the
    // override), 2 in `top`: a port sized in the parent's scope would be
    // 2 bits and the 6-bit connection no multiple of it (ISP RAS
    // test_07_01_06_4, the clause's MxN pipeline, names the child's `bits`).
    try expectRun(
        \\module c(q, d); parameter W = 1; output [W-1:0] q; input [W-1:0] d; assign q = ~d; endmodule
        \\module top; parameter W = 2; wire [5:0] o; reg [5:0] i; c #(3) u[1:0](o, i); initial begin i = 6'b101100; #1 $display("%b", o); end endmodule
    , "010011\n");
}
