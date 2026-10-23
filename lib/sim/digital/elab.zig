//! Pass one of elaboration: the parsed design and its root definitions ->
//! the slot space, the nets and the driver rows (`Elab`), the scope tree
//! (`Run.scope_info`) and every name bound in it, before any expression is
//! compiled. §6.2.2's walk of the instance tree is parent-first, so a port
//! connection always resolves against a parent that is fully declared.
//! `elaborate` (root.zig) runs it, then compiles what it built.
//! Clauses: IEEE 1364-2005 §4.5 implicit nets, §4.9 arrays, §4.10 and §12.2
//! parameters and defparams, §6.5/§6.5.7.1 ports, §7.1, §7.6 and §7.8 gates,
//! switches and pulls, §8 UDPs, §10 subroutine frames, §12.1.2 instance
//! arrays, §12.3 port connections, §12.4 generate, §12.5 named blocks,
//! §12.8.2, §19.9 unconnected_drive; VAMS §3.7 wreal, §6.3 the host's
//! parameters, §7.2 continuous and discrete, §7.8.4 inserted connect modules.
const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;

/// `declare`'s caps on the instance tree: levels, and instances in all.
const max_depth: u32 = 256;
const max_insts: usize = 1 << 18;
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

/// What the parent decided one port connection is. §6.5.7.1's "matching size
/// rule" plus IEEE 1364 clause 12's "a port is a connection, not an
/// assignment": wherever one net can stand for both sides, `collapse` makes
/// them the same net, the only model under which a child's drive strength
/// survives the boundary. The other two arms are for a connection no single
/// net can express.
const PortBind = union(enum) {
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
    /// `send`'s.
    /// ponytail: a supply strength crossing it drops to strong (§7.11's
    /// switch rule), which a real port does not do.
    join: Sinks,
    /// One external port of a module with port expressions (`groupPorts`),
    /// at its first reference: the connection, made in `scope`.
    group: struct { conn: Ast.PortConn, scope: u32 },
};

/// One operand of a structural net expression: `width` bits of net `net`
/// from bit position `lo` up.
const Sink = struct { net: u32, lo: u32, width: u32 };
/// A port connection's structural net expression, as `Sink`s.
const Sinks = struct { operands: []const Sink, tok: u32 };

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
    trans: std.ArrayList(struct { tran: Tran, scope: u32, tok: u32 }) = .empty,
    /// §6.6 the processes and variables of each elaborated generate block,
    /// with its scope; the variables for their §6.2.1 initializers.
    procs: std.ArrayList(struct { scope: u32, blocks: []const Ast.DiscreteBlock, vars: []const Ast.VarDecl }) = .empty,
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
        if (for (modules[d + 1 ..], r.def_lib[d + 1 ..]) |later, l| {
            if (later.name == candidate.name and l == r.def_lib[d]) break true;
        } else false) continue;
        tops.appendAssumeCapacity(d);
    }
    if (tops.items.len == 0) return r.fail(0, "digital execution found no top-level module", .{});
    return tops.items;
}

/// IEEE 1364-2005 §12.2.1 registers defparam `d`, declared in `decl`: its
/// unfolded instance selects folded there, then its first segment resolved
/// as §12.6 resolves a hierarchical name. It names a child of `decl` when
/// one of `children` (the instances the declaring text writes) has that
/// name, else `decl` or a scope above it by name, else a child that
/// elaboration mints later.
pub fn bindDefparam(r: *Run, decl: u32, d: Ast.Defparam, children: []const Ast.Instance) Error!void {
    var path: []const u8 = r.file.str(d.path);
    if (d.indices.len != 0) {
        var out: std.ArrayList(u8) = .empty;
        var rest = path;
        for (d.indices) |x| {
            const at = std.mem.find(u8, rest, "[]").?; // the parser spelled one per index
            const k = (try r.constant(x, d.main_tok)).asInt() orelse return r.exprFail(x, "§12.2.1: a defparam's instance select is x or z");
            try out.print(r.arena, "{s}[{d}]", .{ rest[0..at], k });
            rest = rest[at + 2 ..];
        }
        try out.appendSlice(r.arena, rest);
        path = out.items;
    }
    const b = try defparamBase(r, decl, path, children, d.main_tok);
    try r.defparams.put(r.arena, .{ .scope = b.at, .path = b.rest }, .{ .d = d, .decl = decl });
    try r.bound_defparams.append(r.arena, .{ .decl = decl, .path = path, .at = b.at, .rest = b.rest, .tok = d.main_tok });
}

/// The scope defparam `path` (declared in `decl`) is relative to once its
/// first segment is resolved, and the rest of it. `children` is pass one's
/// static view of `decl`'s children; null reads the complete hierarchy.
fn defparamBase(r: *Run, decl: u32, path: []const u8, children: ?[]const Ast.Instance, tok: u32) Error!struct { at: u32, rest: []const u8 } {
    const dot = std.mem.findScalar(u8, path, '.') orelse return .{ .at = decl, .rest = path };
    const name, const index = segment(path[0..dot]);
    if (children) |list| {
        for (list) |c| if (c.name != .none and std.mem.eql(u8, r.file.str(c.name), name)) return .{ .at = decl, .rest = path };
    } else for (r.scope_info.items, 0..) |info, s| if (s != decl and info.parent == decl and isScope(r, @intCast(s), name, index)) return .{ .at = decl, .rest = path };
    var s = decl;
    while (true) {
        if (isScope(r, s, name, index)) return .{ .at = s, .rest = path[dot + 1 ..] };
        const info = r.scope_info.items[s];
        // §12.2.1: "a defparam statement in a hierarchy in or under a
        // generate block instance ... or an array of instances ... shall
        // not change a parameter value outside that hierarchy."
        if (index != null and info.index != null and info.name != .none and std.mem.eql(u8, r.file.str(info.name), name))
            return r.fail(tok, "§12.2.1: a defparam inside `{s}[{d}]` cannot change a parameter outside the generate block instance or array element it is in", .{ name, info.index.? });
        if (isRoot(r, s)) break;
        s = info.parent;
    }
    for (r.roots) |t| if (isScope(r, t, name, index)) return .{ .at = t, .rest = path[dot + 1 ..] };
    return .{ .at = decl, .rest = path };
}

/// A hierarchical name segment `name` or `name[k]`; a `k` that is not a
/// decimal integer reads as no index.
fn segment(seg: []const u8) struct { []const u8, ?i64 } {
    const bracket = std.mem.findScalar(u8, seg, '[') orelse return .{ seg, null };
    return .{ seg[0..bracket], std.fmt.parseInt(i64, seg[bracket + 1 .. seg.len - 1], 10) catch null };
}

/// Whether scope `s` is named `n`, with array or generate index `k`.
fn isScope(r: *const Run, s: u32, n: []const u8, k: ?i64) bool {
    const info = r.scope_info.items[s];
    return info.name != .none and std.mem.eql(u8, r.file.str(info.name), n) and std.meta.eql(info.index, k);
}

/// The scope defparam path `rest` names below `at` (its last segment, the
/// parameter, dropped), in the complete hierarchy; null when a segment
/// names no scope.
fn defparamScope(r: *const Run, at: u32, rest: []const u8) ?u32 {
    var s = at;
    var it = std.mem.splitScalar(u8, rest[0 .. std.mem.findScalarLast(u8, rest, '.') orelse return s], '.');
    // ponytail: a scan of every scope per segment; elaboration runs it once
    // per defparam. A (parent, name, index) map if designs grow huge.
    next: while (it.next()) |seg| {
        const name, const index = segment(seg);
        for (r.scope_info.items, 0..) |info, c| if (c != s and info.parent == s and isScope(r, @intCast(c), name, index)) {
            s = @intCast(c);
            continue :next;
        };
        return null;
    }
    return s;
}

/// Whether scope `s` is `outer` or lies under it.
fn within(r: *const Run, s: u32, outer: u32) bool {
    var at = s;
    while (at != outer) : (at = r.scope_info.items[at].parent) if (isRoot(r, at)) return false;
    return true;
}

/// IEEE 1364-2005 §12.8.2: "It shall be an error if a hierarchical name in a
/// defparam is resolved before the hierarchy is completely elaborated and
/// that name would resolve differently once the model is completely
/// elaborated."
pub fn checkDefparams(r: *Run) Error!void {
    for (r.bound_defparams.items) |b| {
        const now = try defparamBase(r, b.decl, b.path, null, b.tok);
        if (now.at != b.at or !std.mem.eql(u8, now.rest, b.rest))
            return r.fail(b.tok, "§12.8.2: this defparam's hierarchical name was resolved before the hierarchy was complete and would resolve differently once it is", .{});
        // §12.2.1: "a defparam statement in a hierarchy in or under a
        // generate block instance ... or an array of instances ... shall not
        // change a parameter value outside that hierarchy", however its path
        // is spelled (`defparamBase` refuses the upward relative form early).
        // §12.2.1: the hierarchical name names a parameter: E0901 when no
        // scope holds it, E0907 when a named instance has no such parameter.
        // A mixed design's defparam may name a VAMS §7.8.5 inserted connect
        // module, which only the analog elaboration builds.
        const target = defparamScope(r, b.at, b.rest) orelse if (r.mixed)
            continue
        else
            return r.failWith(.E0901, b.tok, "§12.2.1: this defparam's hierarchical name `{s}` names nothing in the design", .{b.path});
        const leaf = b.rest[if (std.mem.findScalarLast(u8, b.rest, '.')) |d| d + 1 else 0..];
        const slot = if (r.file.strings.find(leaf)) |str| r.names.get(.{ .scope = target, .str = str }) else null;
        // A mixed design leaves the analog block's parameters unbound here.
        if (!r.mixed and (slot == null or !r.params.contains(slot.?))) {
            if (slot == null and target == b.at and std.mem.findScalar(u8, b.rest, '.') == null)
                return r.failWith(.E0901, b.tok, "§12.2.1: this defparam's hierarchical name `{s}` names nothing in the design", .{b.path});
            return r.failWith(.E0907, b.tok, "§12.2.1: this defparam names `{s}`, which is no parameter of its module", .{leaf});
        }
        var s = b.decl;
        while (true) : (s = r.scope_info.items[s].parent) {
            const info = r.scope_info.items[s];
            if ((info.index != null or info.lexical) and !within(r, target, s)) {
                var name: std.ArrayList(u8) = .empty;
                try name.appendSlice(r.arena, r.file.str(info.name));
                if (info.index) |k| try name.print(r.arena, "[{d}]", .{k});
                return r.fail(b.tok, "§12.2.1: a defparam inside `{s}` cannot change a parameter outside the generate block instance or array element it is in", .{name.items});
            }
            if (isRoot(r, s)) break;
        }
    }
}

fn findModule(r: *Run, name: Ast.StrId, tok: u32) Error!*const Ast.ModuleDecl {
    for (r.file.modules) |*m| if (m.name == name) return connectable(r, m, tok);
    return r.fail(tok, "undeclared module in instantiation", .{});
}

/// `m`, unless it is a connect module and this is not a mixed design.
fn connectable(r: *Run, m: *const Ast.ModuleDecl, tok: u32) Error!*const Ast.ModuleDecl {
    // VAMS §7.1: a connect module "can be manually inserted (by the user) or
    // automatically inserted (by the simulator)", in a mixed design, which is
    // the only one that can hold its continuous half.
    if (m.is_connect and !r.mixed) return r.fail(tok, "a connect module is inserted by §7.6 discipline resolution, not instantiated", .{});
    return m;
}

/// The `file.modules` row `m` is.
pub fn defOf(r: *const Run, m: *const Ast.ModuleDecl) u32 {
    return @intCast(m - r.file.modules.ptr);
}

/// One instance's storage: its variables, its nets, its ports' nets, and the
/// driver rows its continuous assignments and port connections contribute.
/// Recurses into child instances AFTER its own nets exist, so a port connection
/// always resolves against a parent that is fully declared.
pub fn declare(r: *Run, e: *Elab, m: *const Ast.ModuleDecl, scope: u32, binds: []const PortBind, over: []const Ast.ParamOverride, depth: u32) Error!void {
    const arena = r.arena;
    if (deep.exhausted()) return r.deepFail(m.main_tok);
    // §12.1.3: a module may instantiate itself only under a generate that
    // terminates; one that does not grows the tree without end, and long
    // before the stack is deep the storage is (ivtest pr2728812c, a binary
    // tree of `sum` at n = 1, reached 25 GB). ponytail: caps, not a cycle
    // proof; no design this interpreter runs is this deep or this wide.
    if (depth >= max_depth or e.insts.items.len >= max_insts)
        return r.fail(m.main_tok, "instantiation past {d} levels or {d} instances: a module instantiates itself without a terminating generate (IEEE 1364-2005 §12.1.3)", .{ max_depth, max_insts });
    if (!r.mixed and (m.aliasparams.len != 0 or m.branches.len != 0 or m.functions.len != 0))
        return r.fail(m.main_tok, "digital execution currently requires a module with only variables, nets, events, instances and processes", .{});
    // A digital parse makes each generate construct an `analog` block over
    // an `if`; anything else there is a genuine analog block.
    if (!r.mixed) for (m.analog) |ab| if (!isGenerate(r.file, m, ab.body))
        return r.fail(ab.main_tok, "digital execution currently requires a module with only variables, nets, events, instances and processes", .{});
    r.scope = scope;
    try e.insts.append(arena, .{ .module = m, .scope = scope });
    // IEEE 1364-2005 §12.2 module parameters, in declaration order so a
    // default may name an earlier one. The mixed host supplies selected real
    // parameters from its derived Model. Other real, string and array
    // parameters stay on the analog side.
    for (m.defparams) |d| try bindDefparam(r, scope, d, m.instances);
    // §10: the instance's tasks and functions, named before its parameters
    // so a §10.4.5 constant function call in one can find its function.
    try r.sub_base.put(arena, scope, @intCast(r.subs.items.len));
    for (m.tasks) |*t| {
        // A mixed module's real-valued function is the analog side's to call
        // (VAMS §4.7); this engine holds no real, so it declares none.
        if (r.mixed and usesReal(t)) continue;
        const entry = try r.sub_by_name.getOrPut(arena, .{ .scope = scope, .str = t.name });
        if (entry.found_existing) return r.fail(t.main_tok, "duplicate task or function", .{});
        entry.value_ptr.* = @intCast(r.subs.items.len);
        try r.subs.append(arena, .{ .decl = t, .inst = scope, .frame = undefined });
    }
    try declareParams(r, scope, m.params, over);
    try declareEvents(r, m.events);
    const written = if (r.mixed) try digitalWrites(r, m) else std.AutoHashMapUnmanaged(Ast.StrId, void).empty;
    for (m.vars) |v| {
        // VAMS §7.3.6.4: an analog variable a digital expression reads is
        // declared, uninitialized, for the coordinator to write.
        if (r.mixed and scope == 0) if (for (r.a2d_reads) |n| {
            if (std.mem.eql(u8, n, r.file.str(v.name))) break true;
        } else false) {
            var read = v;
            read.init = .none;
            _ = try mintVar(r, read);
            continue;
        };
        // A mixed module's initialized variables, and its reals and `time`s no
        // discrete process writes, are the ANALOG block's (§7.2.2: "the domain
        // of a variable is that of the context from which its value is
        // assigned"); a digital process naming one is an undeclared name. A
        // `time` a discrete process writes is the digital engine's 64-bit
        // variable (IEEE 1364-2005 §4.8), `output time t` (A.2.1.2) included.
        if (r.mixed and (v.init != .none or ((v.ty != .integer or v.storage == .time) and !written.contains(v.name)))) continue;
        if (v.init != .none and v.dims.len != 0) return r.fail(v.main_tok, "an unpacked array declaration takes no initializer", .{});
        // IEEE 1364-2005 §12.3.3: "If either the port or the net/reg is
        // declared as signed, then the other shall also be considered signed."
        var d = v;
        for (m.ports) |p| if (p.name == v.name and p.is_signed) {
            d.is_signed = true;
        };
        _ = try mintVar(r, d);
    }
    // IEEE 1364-2005 §10.2/§10.4: each task and function is a scope of this
    // instance holding its formals, its locals and a function's result: the
    // storage a static subroutine shares between activations (§10.2.3).
    // Framed after the parameters its widths may read, unless a §10.4.5
    // constant function call framed it first (`earlyFrame`).
    for (r.subs.items[r.sub_base.get(scope).?..]) |*sub| {
        if (!sub.framed) {
            sub.frame = try frame(r, sub.decl, scope);
            sub.framed = true;
        }
        // §12.5: a task or function is a scope a hierarchical name reaches;
        // §10.2.1: "Automatic task items cannot be accessed by hierarchical
        // references" (`slot` names why).
        if (!sub.decl.automatic) try r.instances.put(r.arena, .{ .scope = scope, .str = sub.decl.name }, sub.frame.scope);
        try blockScopes(r, sub.frame.scope, sub.decl.body);
    }
    for (m.discrete) |d| try blockScopes(r, scope, d.body);
    for (m.nets) |n| try declareNet(r, e, scope, n);
    // §6.5 the ports, after the body nets: a port net minted here is the one a
    // body `wire w;` on the same name was folded into by the parser.
    const grouped = !r.mixed and expressionPorts(m);
    if (grouped) try groupPorts(r, e, m, scope, binds);
    for (if (grouped) m.ports[0..0] else m.ports, 0..) |p, i| {
        if (p.name == .none) continue; // IEEE 1364-2005 A.1.3 a null port connects nothing inside
        if (r.mixed and continuous(r.file, p.discipline)) continue; // §7.2.1 continuous
        if (p.external_name != .none and !p.concat_rest) for (m.ports[0..i]) |q| if (q.external_name == p.external_name)
            return r.fail(p.main_tok, "§12.3.2: a port defined twice in the list of ports: `{s}`", .{r.file.str(p.external_name)});
        if (p.direction == .unspecified) return r.fail(p.main_tok, "§12.3.3: port `{s}` has no direction declaration", .{r.file.str(p.name)});
        // §12.3.3: "the range specification between the two declarations of
        // a port shall be identical".
        if (p.range) |a| if (p.type_range) |b| if (try r.declaredBound(a.msb, p.main_tok) != try r.declaredBound(b.msb, p.main_tok) or
            try r.declaredBound(a.lsb, p.main_tok) != try r.declaredBound(b.lsb, p.main_tok))
            return r.fail(p.main_tok, "§12.3.3: the net declaration's range differs from its port declaration's: `{s}`", .{r.file.str(p.name)});
        // The same for a variable redeclaring the port. `integer` and `time`
        // write no range, so a port that writes one differs; a combined
        // `output reg [7:0] q` shares one range (and `output integer q`
        // writes none).
        // ponytail: `output q; integer q;` reads as the combined form.
        for (m.vars) |v| if (v.name == p.name and v.ty == .integer) {
            const differs = if (v.storage != .reg) p.range != null else if (p.range) |a| if (v.packed_range) |b|
                try r.declaredBound(a.msb, p.main_tok) != try r.declaredBound(b.msb, p.main_tok) or
                    try r.declaredBound(a.lsb, p.main_tok) != try r.declaredBound(b.lsb, p.main_tok)
            else
                true else v.packed_range != null;
            if (differs) return r.fail(v.main_tok, "§12.3.3: the variable declaration's range differs from its port declaration's: `{s}`", .{r.file.str(p.name)});
        };
        var bind = if (i < binds.len) binds[i] else PortBind.open;
        const width = try portWidth(r, p);
        // IEEE 1364-2005 §12.3.3: an output port "declared as a variable"
        // (`output q; reg q;`) is that variable, and it drives the net it
        // is connected to: one driver of it, as a continuous assignment is.
        if (r.names.get(.{ .scope = scope, .str = p.name })) |var_slot| {
            // §12.3.3: the parser folded the first net declaration into the
            // port (`Port.typed`), so a net already bound here is a second
            // one, unless it is the entry a folded `wire p = e;` leaves for
            // its initializer.
            if (r.net_of.contains(var_slot)) for (m.nets) |n| if (n.name == p.name and n.init == .none and n.discipline == .none) return r.fail(n.main_tok, "duplicate digital variable", .{});
            if (p.direction != .output) return r.fail(p.main_tok, "§12.3.3: only an output port may be declared as a variable", .{});
            switch (bind) {
                .open => {},
                .collapse => |c| try e.wires.append(arena, .{
                    .net = c.net,
                    .scope = scope,
                    .source = .{ .bridge = .{ .src = var_slot, .src_lo = 0, .dst_lo = 0, .width = @min(e.values.items[var_slot].width, e.nets.items[c.net].resolved.width) } },
                    .tok = p.main_tok,
                }),
                // §12.3.9.2 a select or concatenation outside: the variable
                // drives exactly those bits, as a net port's value does.
                .send => |c| try sendPort(r, e, c.operands, c.tok, var_slot, e.values.items[var_slot].width, scope),
                .receive, .join => unreachable, // `bindPort` makes them for an input or inout port only
                .group => unreachable, // `groupPorts` takes an expression-ported module's

            }
            continue;
        }
        if (bind == .collapse) collapse: {
            const c = bind.collapse;
            // VAMS §3.7: "When the two nets connected by a port are of net
            // type wreal and wire/tri, the resulting single net will be
            // assigned as wreal", on whichever side the wreal is.
            const outer = &e.nets.items[c.net];
            const merging = (p.kind == .wreal) != (outer.kind == .wreal);
            if (merging and p.kind == .wreal) try promoteWreal(r, e, c.net);
            // A port and a net of different sizes: VAMS 2023 §6.5.7.1 "The
            // sizes of the ports and net must match". IEEE 1364-2005
            // §12.3.9.2 instead makes the connection a continuous assignment,
            // which §5.6 zero-extends or truncates: two nets, not one.
            // ponytail: under 1364 an output narrower than its net (§5.6
            // zero-fills the net's high bits, which needs a constant driver)
            // and an inout are still refused.
            if (!merging and outer.resolved.width != width) {
                if (!ieee1364(r)) return r.fail(p.main_tok, size_mismatch, .{});
                switch (p.direction) {
                    .input => bind = .{ .receive = .{ .expr = c.expr, .scope = c.scope, .tok = c.tok } },
                    .output => bind = .{ .send = .{ .operands = try arena.dupe(Sink, &.{.{ .net = c.net, .lo = 0, .width = outer.resolved.width }}), .tok = c.tok } },
                    .inout, .unspecified => return r.fail(p.main_tok, size_mismatch, .{}),
                }
                break :collapse;
            }
            _ = try warnPort(r, p, outer.kind);
            // §12.3.10.1: the merged net takes the dominating type, which in
            // Table 12-1's "int" cells is the port's own (`tri0` inside a
            // `wire` stays a tri0 and reads 0 undriven).
            if (!merging and internalDominates(p.kind, outer.kind)) {
                outer.kind = p.kind;
                e.values.items[outer.slot] = try filled(arena, width, e.values.items[outer.slot].signed, undriven(p.kind));
                r.values = e.values.items;
            }
            try r.bind(p.name, outer.slot, p.main_tok);
            if (p.is_signed != e.values.items[outer.slot].signed)
                try r.port_signed.put(arena, .{ .scope = scope, .str = p.name }, p.is_signed);
            continue;
        }
        // `p.kind`, not `.wire`: the parser folds a body declaration naming a
        // header port into the `Port` (`inout t; tri0 t;` is one `Port`), and
        // §7.9 resolution and `netPull`'s undriven value both read the net type.
        const at = try mintNet(r, e, p.kind, width, p.is_signed, p.name, p.main_tok);
        if (p.kind != .wreal) if (p.range orelse p.type_range) |range| try putRange(r, e.nets.items[at].slot, range, p.main_tok);
        switch (bind) {
            // IEEE 1364 §19.9: an unconnected input port declared in an
            // `unconnected_drive` region is pulled to a logic level through a
            // pull-strength driver: one driver among drivers, meeting the net's
            // own type in §7.9 resolution. The analog half
            // (`src/analog/node.zig`'s `applyUnconnectedDrive`) cannot tie
            // with a `tri0` or lose to a `supply0`.
            .open => if (p.direction == .input) {
                const drive = Front.Preprocessor.DriveRegion.inForce(r.drives, r.starts[@min(p.main_tok, r.starts.len - 1)], .default);
                if (drive != .float) try e.wires.append(arena, .{
                    .net = at,
                    .scope = scope,
                    .source = .{ .pull = if (drive == .pull1) .one else .zero },
                    .s0 = .pull,
                    .s1 = .pull,
                    .tok = p.main_tok,
                });
            },
            .collapse => {},
            .receive => |c| {
                // §12.3.10 a select of one net still joins the port to that
                // net, so Table 12-1's warn cells apply (no merge: a select is
                // not a whole net).
                const ex = &r.file.exprs;
                if (ex.tag(c.expr) == .index and ex.tag(ex.lhs(c.expr)) == .ident) {
                    if (r.lookup(c.scope, ex.strOf(ex.lhs(c.expr)))) |slot| if (r.net_of.get(slot)) |net| {
                        _ = try warnPort(r, p, e.nets.items[net].kind);
                    };
                }
                try e.wires.append(arena, .{ .net = at, .scope = c.scope, .source = .{ .expr = .{ .e = c.expr, .slice = c.slice } }, .tok = c.tok });
            },
            .group => unreachable, // `groupPorts` takes an expression-ported module's
            .send => |c| {
                for (c.operands) |op| if (try warnPort(r, p, e.nets.items[op.net].kind)) break;
                try sendPort(r, e, c.operands, c.tok, e.nets.items[at].slot, width, scope);
            },
            .join => |c| {
                for (c.operands) |op| if (try warnPort(r, p, e.nets.items[op.net].kind)) break;
                // §6.5.7.1: the rightmost operand takes the port's low bits.
                var lo: u32 = 0;
                var k = c.operands.len;
                while (k != 0) {
                    k -= 1;
                    const op = c.operands[k];
                    if (lo + op.width > width) return r.fail(c.tok, size_mismatch, .{});
                    for (0..op.width) |j| try e.trans.append(arena, .{
                        .tran = .{ .a = at, .b = op.net, .a_bit = lo + @as(u32, @intCast(j)), .b_bit = op.lo + @as(u32, @intCast(j)) },
                        .scope = scope,
                        .tok = c.tok,
                    });
                    lo += op.width;
                }
                if (lo != width) return r.fail(c.tok, size_mismatch, .{});
            },
        }
    }
    // §10.4.2: "It is illegal to declare another object with the same name
    // as the function in the scope where the function is declared."
    for (r.subs.items[r.sub_base.get(scope).?..]) |sub| if (r.names.contains(.{ .scope = scope, .str = sub.decl.name }))
        return r.fail(sub.decl.main_tok, "§10.4.2: duplicate declaration of `{s}`, a task or function name in this scope", .{r.file.str(sub.decl.name)});
    try implicitNets(r, e, scope, m);
    // §3.8: every attribute value is a constant expression, judged once the
    // instance's names are all bound (a mixed module's are the analog
    // compile's to judge).
    if (!r.mixed) try compile.checkAttributes(r, m.attrs, scope);
    const b = try bridged(r, e, m, scope);
    try declareDrivers(r, e, scope, .{ .assigns = m.assigns, .gates = b.gates, .pulls = b.pulls, .switches = b.switches }, b.lanes);
    try pathDelays(r, e, m, scope);
    for (b.instances) |*inst| try instantiate(r, e, scope, inst, depth);
    for (m.analog) |ab| if (isGenerate(r.file, m, ab.body)) try generate(r, e, m, scope, ab.body, depth);
}

const size_mismatch = "§6.5.7.1: the sizes of the port and the net connected to it shall match";

/// §12.3.9.2 an output port's value, slot `src` of `width` bits, bridged
/// into the operands of the structural net expression it connects to (or a
/// hidden net into a continuous assignment's concatenated target).
/// §6.5.7.1 joins them highest-order first, so the rightmost operand takes
/// the port's low bits.
fn sendPort(r: *Run, e: *Elab, operands: []const Sink, tok: u32, src: u32, width: u32, scope: u32) Error!void {
    var lo: u32 = 0;
    var k = operands.len;
    while (k != 0) {
        k -= 1;
        const op = operands[k];
        if (lo + op.width > width) return r.fail(tok, size_mismatch, .{});
        try e.wires.append(r.arena, .{
            .net = op.net,
            .scope = scope,
            .source = .{ .bridge = .{ .src = src, .src_lo = lo, .dst_lo = op.lo, .width = op.width } },
            .tok = tok,
        });
        lo += op.width;
    }
    // Under IEEE 1364-2005 a port wider than its operands sends only its low
    // `lo` bits: §12.3.9.2's continuous assignment truncates (§5.6).
    if (lo != width and !ieee1364(r)) return r.fail(tok, size_mismatch, .{});
}

/// Whether the design is read as IEEE 1364 (`--std=1364-*`), whose §12.3.9.2
/// port connection converts widths, rather than Verilog-AMS, whose §6.5.7.1
/// requires them to match.
fn ieee1364(r: *const Run) bool {
    return switch (r.opts.language) {
        .v1364_1995, .v1364_2001, .v1364_2001_noconfig, .v1364_2005 => true,
        .vams_2_3, .vams_2023 => false,
    };
}

/// IEEE 1364-2005 §12.2 the parameters `params` of `scope` (an instance, or a
/// §12.5 named block, which `over` never reaches), in declaration order so a
/// default may name an earlier one.
fn declareParams(r: *Run, scope: u32, params: []const Ast.ParamDecl, over: []const Ast.ParamOverride) Error!void {
    const arena = r.arena;
    const g = r.growing.?;
    const path = if (r.real_card.len != 0) try scopePath(r, scope) else "";
    var positional: usize = 0;
    for (params) |p| {
        const pos = positional;
        if (!p.is_local) positional += 1;
        const real_value = for (r.real_card) |c| {
            if (std.mem.startsWith(u8, c.name, path) and std.mem.eql(u8, c.name[path.len..], r.file.str(p.name))) break c.value;
        } else null;
        if (p.dims.len != 0 or p.ty == .string or (r.mixed and p.ty == .real and real_value == null)) {
            if (r.mixed) continue;
            return r.fail(p.main_tok, "only scalar integral and real parameters are implemented by digital execution", .{});
        }
        // The host has applied §6.3 overrides and dependent defaults already;
        // re-evaluating one here could reject a legal analog constant function
        // or silently restore a default instead of this analysis's card.
        // §12.2: a range or a type (`signed` is one) converts the value like
        // an assignment; otherwise the parameter takes the type of its value.
        const declared: ?u32 = if (p.packed_range) |range| try r.declaredWidth(range, p.main_tok) else if (p.ty == .integer) @as(u32, if (p.is_time) 64 else 32) else null;
        const pv: ParamValue = if (real_value) |v| .{ .v = try evaluate.realLiteral(arena, v), .real = true } else (try paramValue(r, p, scope, over, pos, declared orelse 0)) orelse continue;
        const ty: compile.Type = if (p.packed_range != null)
            .{ .width = declared.?, .signed = p.is_signed }
        else if (p.ty == .integer)
            // §4.10.1: `time` is unsigned 64-bit, `integer` signed 32-bit.
            .{ .width = declared.?, .signed = !p.is_time }
        else if (p.ty == .real or (pv.real and !p.is_signed))
            compile.real_type
        else
            .{ .width = if (pv.real) 64 else pv.v.width, .signed = p.is_signed or pv.v.signed };
        const converted = try evaluate.convertValue(arena, pv.v, pv.real, ty);
        const at: u32 = @intCast(g.items.len);
        try r.bind(p.name, at, p.main_tok);
        const slot_value = try filled(arena, ty.width, ty.signed, .zero);
        @memcpy(slot_value.planes, converted.planes);
        try g.append(arena, slot_value);
        try r.params.put(arena, at, {});
        if (ty.real) try r.reals.put(arena, at, {});
        if (p.is_spec) try r.specparams.put(arena, at, p.main_tok);
        // §4.10.1: a select of a ranged parameter indexes its declared range.
        if (p.packed_range) |range| try putRange(r, at, range, p.main_tok);
    }
    r.values = g.items;
}

/// IEEE 1364-2005 §12.3.10 Table 12-1's "warn" (W1160) for port `p` joined
/// to a net of type `external`, whole or through a select. Returns whether
/// it warned.
fn warnPort(r: *Run, p: Ast.Port, external: Ast.NetKind) Error!bool {
    if (!warnCell(p.kind, external)) return false;
    const at = r.starts[@min(p.main_tok, r.starts.len - 1)];
    try r.bag.add(.lower, .W1160, .{ .start = at, .end = at }, "§12.3.10: a `{s}` port joined to a `{s}` net is a Table 12-1 warn cell of the net type table", .{ @tagName(p.kind), @tagName(external) });
    return true;
}

/// IEEE 1364-2005 §12.3.10 Table 12-1's "int" cells: does the internal (port)
/// net type dominate the external one? Every other cell is "ext".
fn internalDominates(internal: Ast.NetKind, external: Ast.NetKind) bool {
    const wire = external == .wire or external == .tri;
    return switch (internal) {
        .wire, .tri, .wreal => false,
        .wand, .triand, .wor, .trior, .trireg => wire,
        .tri0, .tri1 => wire or external == .trireg,
        .uwire => wire or switch (external) {
            .wand, .triand, .wor, .trior, .trireg, .tri0, .tri1 => true,
            else => false, // else: uwire, the supplies and wreal are "ext" in the uwire row
        },
        .supply0, .supply1 => switch (external) {
            .supply0, .supply1, .wreal => false,
            else => true, // else: every non-supply column of the supply rows is "int"
        },
    };
}

/// IEEE 1364-2005 §12.3.10 Table 12-1: is the pair of an internal (port)
/// and external (connected) net type a "warn" cell?
fn warnCell(internal: Ast.NetKind, external: Ast.NetKind) bool {
    const Col = enum { wire, wand, wor, trireg, tri0, tri1, uwire, supply0, supply1, wreal };
    const col = struct {
        fn of(k: Ast.NetKind) Col {
            return switch (k) {
                .wire, .tri => .wire,
                .wand, .triand => .wand,
                .wor, .trior => .wor,
                .trireg => .trireg,
                .tri0 => .tri0,
                .tri1 => .tri1,
                .uwire => .uwire,
                .supply0 => .supply0,
                .supply1 => .supply1,
                .wreal => .wreal,
            };
        }
    }.of;
    const warns: []const Col = switch (col(internal)) {
        .wire, .wreal => &.{},
        .wand => &.{ .wor, .trireg, .tri0, .tri1, .uwire },
        .wor => &.{ .wand, .trireg, .tri0, .tri1, .uwire },
        .trireg => &.{ .wand, .wor, .uwire },
        .tri0 => &.{ .wand, .wor, .tri1, .uwire },
        .tri1 => &.{ .wand, .wor, .tri0, .uwire },
        .uwire => &.{ .wand, .wor, .trireg, .tri0, .tri1 },
        .supply0 => &.{.supply1},
        .supply1 => &.{.supply0},
    };
    return std.mem.findScalar(Col, warns, col(external)) != null;
}

/// IEEE 1364-2005 §4.5: an undeclared identifier in the terminal list of a
/// module or primitive instance, or on the left of a continuous assignment,
/// is an implicit scalar net of the `default_nettype in force there (§19.2).
/// A terminal's identifiers count wherever they stand in its expression
/// (`.r(!r)`); an assignment's target only as the whole of it.
fn implicitNets(r: *Run, e: *Elab, scope: u32, m: *const Ast.ModuleDecl) Error!void {
    for (m.instances) |inst| for (inst.ports) |c| try implicitTerminal(r, e, scope, m, c.expr);
    for (m.gates) |g| {
        try implicitNet(r, e, scope, m, g.out);
        for (g.ins) |x| try implicitTerminal(r, e, scope, m, x);
    }
    for (m.switches) |sw| for (sw.terms) |x| try implicitNet(r, e, scope, m, x);
    for (m.pulls) |p| try implicitNet(r, e, scope, m, p.out);
    for (m.assigns) |a| try implicitNet(r, e, scope, m, a.target);
}

/// Every identifier of terminal expression `x` through `implicitNet`.
fn implicitTerminal(r: *Run, e: *Elab, scope: u32, m: *const Ast.ModuleDecl, x: Ast.ExprId) Error!void {
    const ex = &r.file.exprs;
    if (x == .none) return;
    if (ex.tag(x) == .ident) return implicitNet(r, e, scope, m, x);
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(x, &buf)) |c| try implicitTerminal(r, e, scope, m, c);
}

fn implicitNet(r: *Run, e: *Elab, scope: u32, m: *const Ast.ModuleDecl, x: Ast.ExprId) Error!void {
    const ex = &r.file.exprs;
    if (x == .none or ex.tag(x) != .ident) return;
    const tok = ex.mainTok(x);
    if (r.names.contains(.{ .scope = scope, .str = ex.strOf(x) })) {
        // §4.5: "has not been declared previously". A net declared after
        // this use was already implicitly declared here, so it declares
        // the name a second time.
        for (m.nets) |n| if (n.name == ex.strOf(x) and n.main_tok > tok and n.discipline == .none) return r.fail(n.main_tok, "duplicate digital variable", .{});
        return;
    }
    const t = Front.Preprocessor.NetTypeRegion.inForce(r.nettypes, r.starts[@min(tok, r.starts.len - 1)], .default);
    // `default_nettype none: the name stays undeclared.
    const kind = std.meta.stringToEnum(Ast.NetKind, @tagName(t)) orelse return;
    _ = try mintNet(r, e, kind, 1, false, ex.strOf(x), tok);
}

/// §5.10.4 a named event gets a slot so `-> e` and `@(e)` have a rendezvous
/// point on the waiter list; the stored value is never read or written.
fn declareEvents(r: *Run, events: []const Ast.EventDecl) Error!void {
    const g = r.growing.?;
    for (events) |event| {
        const at: u32 = @intCast(g.items.len);
        try r.bind(event.name, at, event.main_tok);
        const count = try declareArray(r, at, event.dims, event.main_tok);
        if (count > std.math.maxInt(u32) - g.items.len) return r.fail(event.main_tok, "too many digital storage slots", .{});
        for (0..count) |i| {
            try g.append(r.arena, try filled(r.arena, 1, false, .x));
            try r.events.put(r.arena, at + @as(u32, @intCast(i)), .{ .tok = event.main_tok, .scope = r.scope });
        }
        r.values = g.items;
    }
}

/// Does statement `s` hold a named block with declarations of its own?
fn declares(file: *const Ast.SourceFile, s: Ast.StmtId) bool {
    const W = struct {
        f: *const Ast.SourceFile,
        pub fn expr(_: @This(), _: Ast.ExprId, _: Ast.SourceFile.Edge) error{Found}!void {}
        pub fn stmt(w: @This(), c: Ast.StmtId) error{Found}!void {
            if (c == .none) return;
            switch (w.f.stmt(c)) {
                .block => |b| if (b.vars.len != 0 or b.params.len != 0 or b.events.len != 0) return error.Found,
                else => {}, // else: only a block declares
            }
            try w.f.stmtEdges(c, w);
        }
    };
    (W{ .f = file }).stmt(s) catch return true;
    return false;
}

/// IEEE 1364-2005 §12.5 "each ... named begin-end or fork-join block shall
/// define a new branch of the hierarchy": the named blocks of statement `s`,
/// run in `scope`, that declare something or enclose one that does, each a
/// scope with its declarations, made in pass one so a hierarchical name
/// compiled first (`b.mod_1.x` from a sibling block) finds them. `compile`
/// enters the scope `block_scopes` records.
fn blockScopes(r: *Run, scope: u32, s: Ast.StmtId) Error!void {
    if (s == .none) return;
    const W = struct {
        r: *Run,
        scope: u32,
        pub fn expr(_: @This(), _: Ast.ExprId, _: Ast.SourceFile.Edge) Error!void {}
        pub fn stmt(w: @This(), c: Ast.StmtId) Error!void {
            try blockScopes(w.r, w.scope, c);
        }
    };
    var inner = scope;
    switch (r.file.stmt(s)) {
        .block => |b| if (b.name != .none and !r.block_scopes.contains(.{ .scope = scope, .stmt = s }) and declares(r.file, s)) {
            inner = try blockScope(r, scope, s);
        },
        else => {}, // else: only a block is a scope
    }
    try r.file.stmtEdges(s, W{ .r = r, .scope = inner });
}

/// Block `s`'s scope under `scope`, its parameters, events and variables
/// declared there. Pass two calls it for an automatic activation's copy.
pub fn blockScope(r: *Run, scope: u32, s: Ast.StmtId) Error!u32 {
    const b = r.file.stmt(s).block;
    const tok = r.file.stmtTok(s);
    const at = try newScope(r, tok);
    try r.scope_info.append(r.arena, .{ .parent = scope, .name = b.name, .def = r.scope_info.items[scope].def, .lexical = true });
    try r.block_scopes.put(r.arena, .{ .scope = scope, .stmt = s }, at);
    if (b.name != .none) try r.instances.put(r.arena, .{ .scope = scope, .str = b.name }, at);
    const saved = r.scope;
    defer r.scope = saved;
    r.scope = at;
    try declareParams(r, at, b.params, &.{});
    try declareEvents(r, b.events);
    for (b.vars) |v| {
        if (v.init != .none) return r.fail(v.main_tok, "an initialized block-local variable is not implemented", .{});
        _ = try mintVar(r, v);
    }
    return at;
}

/// The driver rows of `items`' continuous assignments, gates, switches and
/// pull sources, their names resolved in `scope`. `items.events` and
/// `items.discrete` are not read. `lanes` re-points single lanes of
/// `items.gates`' instance arrays (`bridged`).
fn declareDrivers(r: *Run, e: *Elab, scope: u32, items: Ast.GenItems, lanes_at: []const LaneSeg) Error!void {
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
        const resistive = switch (sw.kind) {
            .rcmos, .rnmos, .rpmos, .rtran, .rtranif0, .rtranif1 => true,
            .cmos, .nmos, .pmos, .tran, .tranif0, .tranif1 => false,
        };
        switch (sw.kind) {
            .nmos, .pmos, .rnmos, .rpmos, .cmos, .rcmos => {
                const out = r.net_of.get(try r.scalarSlot(sw.terms[0])) orelse return r.fail(sw.main_tok, "a switch's output and inout terminals are nets", .{});
                const width = e.nets.items[out].resolved.width;
                // §7.1.5/§7.1.6 an instance array is one switch per index, as a gate array is.
                const lanes: u32 = if (sw.range) |rg| try r.declaredWidth(rg, sw.main_tok) else 1;
                if (width != 1 and width != lanes) return r.fail(sw.main_tok, "a MOS switch's output terminal is one bit, or one per instance of an array", .{});
                const cmos = sw.kind == .cmos or sw.kind == .rcmos;
                const n_type = sw.kind == .nmos or sw.kind == .rnmos;
                for (0..lanes) |j| {
                    const lane: ?u32 = if (sw.range == null) null else @intCast(lanes - 1 - j);
                    for (0..@as(usize, if (cmos) 2 else 1)) |half| try e.wires.append(r.arena, .{
                        .net = out,
                        .scope = scope,
                        .source = .{ .mos = .{ .data = sw.terms[1], .gate = sw.terms[2 + half], .n_type = if (cmos) half == 0 else n_type, .resistive = resistive, .lane = lane, .out_bit = if (width == 1) null else lane } },
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
                            .delay = try r.declaredDelay3(sw.delay, sw.main_tok),
                        },
                        .scope = scope,
                        .tok = sw.main_tok,
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

/// IEEE 1364-2005 §14.2 the module paths of `m` in instance `scope`, one
/// `net.Path` row per source on each destination net: which path's delay
/// times a transition is decided when it is scheduled (§14.3.3,
/// `resolution.pathDelay`). A destination's select is read as its whole
/// net, and a parallel path as a full one.
/// ponytail: per-bit destinations would time each bit on its own; the net
/// takes the smallest delay its changed bits select.
fn pathDelays(r: *Run, e: *Elab, m: *const Ast.ModuleDecl, scope: u32) Error!void {
    const ex = &r.file.exprs;
    r.scope = scope;
    for (m.paths) |p| {
        if (p.edge == .edge) return r.fail(p.main_tok, "§14.2.3: a module path's edge is posedge or negedge", .{});
        // §14.3.1: "If the path delay expression results in a negative
        // value, it shall be treated as zero."
        var ticks: [12]u64 = undefined;
        for (p.delays, ticks[0..p.delays.len]) |d, *t| {
            const v = try r.constant(d, p.main_tok);
            const negative = !compile.typeOf(r, d).real and v.signed and (v.asInt() orelse 0) < 0;
            t.* = if (negative) 0 else (try r.declaredDelay3(.{ .rise = d, .fall = d, .off = d }, p.main_tok)).rise;
        }
        const table = net_mod.pathTable(ticks[0..p.delays.len]);
        for (p.outs) |o| {
            const dst = if (ex.tag(o) == .index) ex.lhs(o) else o;
            const at = try r.scalarSlot(dst);
            // §14.2.1: the destination is "a net or variable that is
            // connected to a module output port or inout port". A variable
            // port reaches its outside through its §12.3.3 bridge, so the
            // path times the net that bridge drives; an unconnected one has
            // no outside to time.
            var dests: std.ArrayList(u32) = .empty;
            if (r.net_of.get(at)) |net| {
                try dests.append(r.arena, net);
            } else {
                const is_port = for (m.ports) |pt| {
                    if (pt.name == ex.strOf(dst)) break true;
                } else false;
                if (!is_port) return r.fail(p.main_tok, "§14.2.1: a module path destination is a net or variable connected to an output or inout port", .{});
                for (e.wires.items) |w| if (w.source == .bridge and w.source.bridge.src == at) try dests.append(r.arena, w.net);
            }
            var rows: std.ArrayList(net_mod.Path) = .empty;
            for (p.ins) |in| {
                const src_expr = if (ex.tag(in) == .index) ex.lhs(in) else in;
                const src = try r.scalarSlot(src_expr);
                var bit: u32 = 0;
                if (ex.tag(in) == .index) {
                    try compile.checkExpr(r, in);
                    const sel = (try evaluate.selection(r, r.arena, in)) orelse return r.fail(p.main_tok, "§14.2: a module path source's select is x, z or outside its port", .{});
                    bit = @intCast(@max(sel.first, 0));
                }
                try rows.append(r.arena, .{ .src = src, .src_bit = bit, .edge = p.edge, .cond = p.cond, .ifnone = p.ifnone, .scope = scope, .table = table });
            }
            for (dests.items) |net| {
                const n = &e.nets.items[net];
                if (n.cold == net_mod.no_cold) {
                    n.cold = @intCast(e.net_cold.items.len);
                    try e.net_cold.append(r.arena, .{});
                }
                const cold = &e.net_cold.items[n.cold];
                cold.paths = try std.mem.concat(r.arena, net_mod.Path, &.{ cold.paths, rows.items });
            }
        }
    }
}

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

/// VAMS §7.8.4 `m`'s instances and primitives at `scope` as the analog
/// compile's connect module insertion left them (`Mixed.inserts`): every
/// re-pointed port or primitive terminal (§7.8.5.1's names, `Ast.primTerms`)
/// bound to its segment (a net of this scope, when the bridge's side of it is
/// discrete), and one instance of each bridge appended, taking the port's
/// upper connection. The source's own lists where nothing was inserted.
// ponytail: the bridge takes no parameter override (a mixed module's
// parameters are the analog block's), and a generate scope's path is not
// matched: insertion under a generate block reaches only the analog half.
fn bridged(r: *Run, e: *Elab, m: *const Ast.ModuleDecl, scope: u32) Error!Bridged {
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

/// The index `k` of an instance-array lane's name `base[k]`, or null.
fn laneIndex(name: []const u8, base: []const u8) ?i64 {
    if (name.len < base.len + 3 or !std.mem.startsWith(u8, name, base) or name[base.len] != '[' or name[name.len - 1] != ']') return null;
    return std.fmt.parseInt(i64, name[base.len + 1 .. name.len - 1], 10) catch null;
}

/// A name `elaborate` made sure the file holds.
fn interned(r: *Run, name: []const u8) Error!Ast.StrId {
    return r.file.strings.find(name) orelse r.fail(0, "the inserted connect module names `{s}`, which the source does not declare", .{name});
}

/// §6.7 the instance path of `scope`, each name followed by `.`: the prefix
/// the analog compile's flatten gives the names declared there.
fn scopePath(r: *Run, scope: u32) Error![]const u8 {
    if (scope == 0) return "";
    const info = r.scope_info.items[scope];
    return r.arena.print("{s}{s}.", .{ try scopePath(r, info.parent), r.file.str(info.name) });
}

/// §7.6 "the bidirectional terminals of all six devices shall be connected
/// only to scalar nets or bit-selects of vector nets": the net, and the bit
/// position a constant select names against its declared range. Lane `lane`
/// of an instance array `lanes` wide takes bit `lane` of a net that wide
/// (§7.1.6).
fn switchTerminal(r: *Run, e: *Elab, t: Ast.ExprId, tok: u32, lanes: u32, lane: u32) Error!struct { net: u32, bit: u32 } {
    const ex = &r.file.exprs;
    if (ex.tag(t) != .index) {
        const net = r.net_of.get(try r.scalarSlot(t)) orelse return r.fail(tok, "a switch's output and inout terminals are nets", .{});
        const width = e.nets.items[net].resolved.width;
        if (lanes > 1 and width == lanes) return .{ .net = net, .bit = lane };
        if (width != 1) return r.fail(tok, "§7.6: a pass switch terminal is a scalar net or a bit-select of a vector net", .{});
        return .{ .net = net, .bit = 0 };
    }
    if (ex.tag(ex.rhs(t)) == .range) return r.fail(tok, "§7.6: a pass switch terminal is a scalar net or a bit-select of a vector net", .{});
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

/// IEEE 1364-2005 §12.4 a generate construct as a digital parse leaves it:
/// an `if` or `case` whose arms are blocks, or a `for` over a genvar (§12.4.1:
/// what tells a loop generate from a loop statement is its genvar).
fn isGenerate(file: *const Ast.SourceFile, m: *const Ast.ModuleDecl, s: Ast.StmtId) bool {
    return switch (file.stmt(s)) {
        .if_stmt => |i| i.is_generate,
        .case_stmt => |c| c.is_generate,
        .for_stmt => |f| genvarOf(file, m, f) != null,
        else => false, // else: every other analog-block body is analog behaviour
    };
}

/// §12.4.1 the genvar a loop generate's `genvar_initialization` assigns, or
/// null when the loop's index is no genvar of `m`.
fn genvarOf(file: *const Ast.SourceFile, m: *const Ast.ModuleDecl, f: anytype) ?Ast.StrId {
    if (f.init == .none) return null;
    const init = switch (file.stmt(f.init)) {
        .assign => |a| a,
        else => return null, // else: A.4.2 genvar_initialization is an assignment
    };
    if (file.exprs.tag(init.target) != .ident) return null;
    const name = file.exprs.strOf(init.target);
    return if (std.mem.findScalar(Ast.StrId, m.genvars, name) != null) name else null;
}

/// §12.4: the scheme's constant expressions select at most one arm of an
/// `if` or `case` (§12.4.2) and unroll a `for` once per genvar value
/// (§12.4.1), and only the selected blocks' instances come into existence
/// (§12.1.1: an instance in an unselected arm still makes its module no
/// top-level one).
/// A block's events, drivers and processes are declared in the scope it is
/// elaborated in (`Ast.GenItems`), which is the block's own (`armScope`).
/// ponytail: the parser hoists a generate block's nets to the module, so they
/// are the enclosing instance's names. A part-select bound written with a genvar is folded once, with
/// the first iteration's value; a bit-select is read per iteration.
fn generate(r: *Run, e: *Elab, m: *const Ast.ModuleDecl, scope: u32, s: Ast.StmtId, depth: u32) Error!void {
    if (s == .none) return;
    const tok = r.file.stmtTok(s);
    switch (r.file.stmt(s)) {
        .empty => {},
        .if_stmt => |i| {
            r.scope = scope;
            const cond = (try r.constant(i.cond, tok)).truth();
            const arm = if (cond == .one) i.then_s else i.else_s;
            try generate(r, e, m, try armScope(r, scope, arm, tok), arm, depth);
        },
        // §12.4.2: "the case_generate_item selected is the one whose
        // expression matches the case expression", the default otherwise.
        .case_stmt => |c| {
            r.scope = scope;
            const value = try r.constant(c.scrutinee, tok);
            var chosen: ?Ast.StmtId = null;
            var fallback: Ast.StmtId = .none;
            for (c.arms) |arm| {
                if (arm.labels.len == 0) fallback = arm.body;
                for (arm.labels) |label| {
                    if (chosen != null) break;
                    const l = try r.constant(label, tok);
                    const ty: Type = .{ .width = @max(l.width, value.width), .signed = l.signed and value.signed };
                    if ((try evaluate.convert(r.arena, value, ty)).equality(.case_equal, try evaluate.convert(r.arena, l, ty)) == .one) chosen = arm.body;
                }
            }
            const arm = chosen orelse fallback;
            try generate(r, e, m, try armScope(r, scope, arm, tok), arm, depth);
        },
        // §12.4.1: the genvar steps through its values in the module's scope,
        // and each iteration's block is a scope of its own, `name[value]`, in
        // which the genvar is a local parameter holding that value.
        .for_stmt => |f| {
            const gv = genvarOf(r.file, m, f) orelse return r.fail(tok, "§12.4.1: a loop generate's index is a genvar", .{});
            const step = switch (r.file.stmt(f.step)) {
                .assign => |a| a,
                else => return r.fail(tok, "§12.4.1: a loop generate's iteration assigns its genvar", .{}), // else: A.4.2 genvar_iteration is an assignment
            };
            if (r.file.exprs.tag(step.target) != .ident or r.file.exprs.strOf(step.target) != gv)
                return r.fail(tok, "§12.4.1: a loop generate's iteration assigns its genvar", .{});
            r.scope = scope;
            if (r.scope_info.items[scope].index != null and r.names.contains(.{ .scope = scope, .str = gv }))
                return r.fail(tok, "§12.4.1: two nested loop generate constructs cannot use the same genvar", .{});
            const at = r.names.get(.{ .scope = scope, .str = gv }) orelse try genvarSlot(r, e, gv, tok);
            try setGenvar(r, e, at, try r.constant(r.file.stmt(f.init).assign.value, tok));
            // §12.4.3 an unnamed block's external name, genblk<n>.
            const name: Ast.StrId, const implicit = switch (r.file.stmt(f.body)) {
                .block => |b| .{ b.gen_name, b.name == .none },
                else => .{ .none, true }, // else: a lone item is an unnamed generate block
            };
            // §12.4.1: "It shall be an error if a genvar value is repeated".
            // A genvar holds 32 bits, so a loop that does not terminate
            // repeats one within 2^32 iterations: this set is the loop's
            // non-termination test, and no count bounds a loop that ends.
            var seen: std.AutoHashMapUnmanaged(i64, void) = .empty;
            while ((try r.constant(f.cond, tok)).truth() == .one) {
                const value = e.values.items[at].asInt() orelse return r.fail(tok, "§12.4.1: a genvar shall not be x or z", .{});
                if ((try seen.fetchPut(r.arena, value, {})) != null) return r.fail(tok, "§12.4.1: a genvar value is repeated, so this loop generate does not terminate", .{});
                const iter = try newScope(r, tok);
                try r.scope_info.append(r.arena, .{ .parent = scope, .name = name, .def = defOf(r, m), .lexical = true, .index = value, .implicit = implicit });
                try selectable(r, scope, name, value, iter);
                r.scope = iter;
                try setGenvar(r, e, try genvarSlot(r, e, gv, tok), e.values.items[at]);
                try generate(r, e, m, iter, f.body, depth);
                r.scope = scope;
                try setGenvar(r, e, at, try r.constant(step.value, tok));
            }
        },
        .block => |b| {
            r.scope = scope;
            // §12.4.1: so are its parameters, first, as its nets' ranges and
            // nested generate conditions may read them.
            try declareParams(r, scope, b.params, &.{});
            // A.1.4: its tasks and functions too, named and framed in its
            // scope (`sub_by_name` keyed by the generate scope).
            const sub_first = r.subs.items.len;
            for (b.gen.tasks) |*t| {
                const entry = try r.sub_by_name.getOrPut(r.arena, .{ .scope = scope, .str = t.name });
                if (entry.found_existing) return r.fail(t.main_tok, "duplicate task or function", .{});
                entry.value_ptr.* = @intCast(r.subs.items.len);
                try r.subs.append(r.arena, .{ .decl = t, .inst = scope, .frame = undefined });
            }
            for (r.subs.items[sub_first..]) |*sub| {
                sub.frame = try frame(r, sub.decl, scope);
                sub.framed = true;
                if (!sub.decl.automatic) try r.instances.put(r.arena, .{ .scope = scope, .str = sub.decl.name }, sub.frame.scope);
                try blockScopes(r, sub.frame.scope, sub.decl.body);
            }
            r.scope = scope;
            // §12.4: a generate block's nets are its scope's, one set per
            // loop iteration.
            for (b.gen.nets) |n| try declareNet(r, e, scope, n);
            if (b.gen.nets.len != 0) try r.gen_nets.put(r.arena, scope, b.gen.nets);
            for (b.gen.defparams) |d| try bindDefparam(r, scope, d, b.instances);
            try declareEvents(r, b.gen.events);
            try declareDrivers(r, e, scope, b.gen.*, &.{});
            // §12.4: so are its variables, which §12.5 names reach as
            // `blk[i].v` (#56). A mixed design's are the analog block's
            // (§7.2.2), as `declare` leaves a module's.
            // ponytail: a mixed design's generate-block variables stay
            // undeclared here; give them `declare`'s domain test when a
            // digital process there needs to write one.
            const vars: []const Ast.VarDecl = if (r.mixed) &.{} else b.vars;
            for (vars) |v| {
                if (v.init != .none and v.dims.len != 0) return r.fail(v.main_tok, "an unpacked array declaration takes no initializer", .{});
                _ = try mintVar(r, v);
            }
            if (b.gen.discrete.len != 0 or vars.len != 0) try e.procs.append(r.arena, .{ .scope = scope, .blocks = b.gen.discrete, .vars = vars });
            for (b.gen.discrete) |d| try blockScopes(r, scope, d.body);
            for (b.instances) |*inst| try instantiate(r, e, scope, inst, depth);
            // A mixed design's generate block also holds its analog blocks,
            // which are the analog compile's.
            for (b.body) |inner| if (!r.mixed or isGenerate(r.file, m, inner)) try generate(r, e, m, scope, inner, depth);
        },
        else => return r.fail(tok, "only generate constructs of instances are implemented by digital execution", .{}), // else: analog behaviour inside a generate block
    }
}

/// One A.2.1.3 net declaration of `scope`: the net, or a §4.9.1 net
/// array's elements, and a net_decl_assignment's driver.
fn declareNet(r: *Run, e: *Elab, scope: u32, n: Ast.NetDecl) Error!void {
    const arena = r.arena;
    // §7.2.1: a disciplined net is continuous, the analog solver's.
    if (r.mixed and (n.is_ground or continuous(r.file, n.discipline))) return;
    if (!r.mixed and (n.discipline != .none or n.is_ground))
        return r.fail(n.main_tok, "disciplined and ground nets are not implemented by digital execution", .{});
    const width = if (n.range) |range| try r.declaredWidth(range, n.main_tok) else 1;
    // A.2.4 `net_decl_assignment` names no dimension.
    if (n.dims.len != 0 and n.init != .none) return r.fail(n.main_tok, "a net array declaration takes no assignment", .{});
    // §4.9.1 a net array is one net per element, on consecutive slots,
    // the layout a variable array's elements have.
    const base: u32 = @intCast(e.values.items.len);
    const count = try declareArray(r, base, n.dims, n.main_tok);
    for (0..count) |k| {
        const at = try mintNet(r, e, n.kind, width, n.is_signed, if (k == 0) n.name else .none, n.main_tok);
        if (n.range) |range| try putRange(r, e.nets.items[at].slot, range, n.main_tok);
        var net = &e.nets.items[at];
        // §6.1.3: beside a net_decl_assignment the `delay3` "is part of the
        // continuous assignment and is not a net delay", so it times that one
        // driver (below) and never the net's other drivers.
        const net_delay: Ast.Delay3 = if (n.init == .none) n.delay else .{};
        var cold: NetCold = .{ .delay = try r.declaredDelay3(net_delay, n.main_tok) };
        // A.2.1.3 gives `trireg` its own alternatives, and in them the third
        // `delay3` value is the CHARGE DECAY TIME. It is not a turn-off delay:
        // a trireg in the capacitive state does not turn off, it holds, so the
        // net's own turn-off falls back to §7.14's "smallest of the delays".
        if (n.kind == .trireg and net_delay.off != .none) {
            cold.decay = cold.delay.off;
            cold.delay.off = @min(cold.delay.rise, cold.delay.fall);
        }
        if (cold.delay.present or cold.decay != null) {
            net.cold = @intCast(e.net_cold.items.len);
            try e.net_cold.append(arena, cold);
        }
        net.charge = n.charge;
        // A.2.4 `net_decl_assignment` is a continuous assignment written on the
        // declaration: one more driver of that net, timed by the declaration's
        // `delay3` exactly as `assign #d` would be.
        if (n.init != .none)
            try e.wires.append(arena, .{ .net = at, .scope = scope, .source = .{ .expr = .{ .e = n.init } }, .s0 = n.strength0, .s1 = n.strength1, .delay = n.delay, .tok = n.main_tok });
    }
}

/// IEEE 1364-2005 §12.4.2/§12.4.3 the scope a conditional generate's chosen
/// block `s` is elaborated in: a new one under `scope`, named as the block or
/// `genblk<n>`, unless `s` is no block or a directly nested construct (the
/// parser leaves those unnamed), which is not a scope.
fn armScope(r: *Run, scope: u32, s: Ast.StmtId, tok: u32) Error!u32 {
    if (s == .none) return scope;
    const name = switch (r.file.stmt(s)) {
        .block => |b| b.gen_name,
        else => return scope, // else: an empty arm declares nothing
    };
    if (name == .none) return scope;
    const at = try newScope(r, tok);
    try r.scope_info.append(r.arena, .{ .parent = scope, .name = name, .def = r.scope_info.items[scope].def, .lexical = true });
    // §12.4.3: "an unnamed generate block has no name that can be used in a
    // hierarchical name".
    if (r.file.stmt(s).block.name != .none) try r.instances.put(r.arena, .{ .scope = scope, .str = name }, at);
    return at;
}

/// §12.5 element `k` of the instance array or loop generate `name` in
/// `scope`, reachable as `name[k]` (the spelling the parser gives an
/// instance select) when the source writes one.
fn selectable(r: *Run, scope: u32, name: Ast.StrId, k: i64, at: u32) Error!void {
    if (name == .none) return;
    var buf: [256]u8 = undefined;
    const text = std.mem.print(&buf, "{s}[{d}]", .{ r.file.str(name), k }) catch return;
    if (r.file.strings.find(text)) |str| try r.instances.put(r.arena, .{ .scope = scope, .str = str }, at);
}

/// A genvar's storage in the current scope: a 32-bit signed constant
/// (§3.5 "an integer"), which `constant` folds like any parameter.
fn genvarSlot(r: *Run, e: *Elab, name: Ast.StrId, tok: u32) Error!u32 {
    const at: u32 = @intCast(e.values.items.len);
    try r.bind(name, at, tok);
    try e.values.append(r.arena, try filled(r.arena, 32, true, .x));
    r.values = e.values.items;
    try r.params.put(r.arena, at, {});
    return at;
}

fn setGenvar(r: *Run, e: *Elab, at: u32, value: Int.Literal) Error!void {
    @memcpy(e.values.items[at].planes, (try evaluate.convert(r.arena, value, .{ .width = 32, .signed = true })).planes);
}

/// Every module a generate construct instantiates, in either arm.
fn generatedModules(file: *const Ast.SourceFile, s: Ast.StmtId, out: *std.ArrayList(Ast.StrId), a: std.mem.Allocator) std.mem.Allocator.Error!void {
    if (s == .none) return;
    switch (file.stmt(s)) {
        .if_stmt => |i| {
            try generatedModules(file, i.then_s, out, a);
            try generatedModules(file, i.else_s, out, a);
        },
        .case_stmt => |c| for (c.arms) |arm| try generatedModules(file, arm.body, out, a),
        .for_stmt => |f| try generatedModules(file, f.body, out, a),
        .block => |b| {
            for (b.instances) |inst| try out.append(a, inst.module);
            for (b.body) |inner| try generatedModules(file, inner, out, a);
        },
        else => {}, // else: no other statement holds an instance
    }
}

/// IEEE 1364-2005 §12.2 the value parameter `p` of the instance `scope`
/// takes, from the first of: a `defparam` naming it (§12.2.1, which "shall
/// take precedence"), the instance's `#( … )` by name or position (§12.2.2),
/// at a mixed design's root the host's card (the `Model` value the analog
/// block reads), and its declared default. Each is a constant expression in
/// the scope that wrote it. null: in a mixed design, a value this engine does
/// not fold (a real, or one naming the analog block's), so the parameter is
/// the analog block's alone. `real`: `v` holds a real's 64 bits.
fn paramValue(r: *Run, p: Ast.ParamDecl, scope: u32, over: []const Ast.ParamOverride, pos: usize, width: u32) Error!?ParamValue {
    const Src = struct { e: Ast.ExprId, scope: u32 };
    const src: Src = blk: {
        // A defparam's path is relative to the scope `bindDefparam` bound
        // it to, so each enclosing scope is asked for the path from it down
        // to `p`.
        var at = scope;
        var path: []const u8 = r.file.str(p.name);
        while (true) {
            if (r.defparams.get(.{ .scope = at, .path = path })) |dp| {
                if (p.is_local) return r.fail(dp.d.main_tok, "§12.2: `{s}` is a local parameter, which a defparam cannot override", .{r.file.str(p.name)});
                break :blk .{ .e = dp.d.value, .scope = dp.decl };
            }
            const info = r.scope_info.items[at];
            if (isRoot(r, at)) {
                // §12.2.1: a defparam in one top-level module may name a
                // parameter under another by its full hierarchical name.
                const full = try r.arena.print("{s}.{s}", .{ r.file.str(info.name), path });
                for (r.roots) |t| {
                    if (t == at) continue;
                    if (r.defparams.get(.{ .scope = t, .path = full })) |dp| break :blk .{ .e = dp.d.value, .scope = dp.decl };
                }
                break;
            }
            path = if (info.index) |k|
                try r.arena.print("{s}[{d}].{s}", .{ r.file.str(info.name), k, path })
            else
                try r.arena.print("{s}.{s}", .{ r.file.str(info.name), path });
            at = info.parent;
        }
        if (!p.is_local) for (over, 0..) |o, i| {
            if (o.value != .none and (o.name == p.name or (o.name == .none and i == pos)))
                break :blk .{ .e = o.value, .scope = r.scope_info.items[scope].parent };
        };
        break :blk .{ .e = p.default, .scope = scope };
    };
    r.scope = src.scope;
    defer r.scope = scope;
    if (r.mixed and !compile.constantExpression(r, src.e)) return null;
    // Parameters bind before any other name of the instance, so a name that
    // does not resolve yet is no previously defined parameter.
    if (unresolved(r, src.e)) |x| return r.exprFail(x, "§4.10.1: a parameter's value is a constant expression of numbers and previously defined parameters, and this name is neither");
    const value = try r.constant(src.e, p.main_tok);
    // §4.10.3: "module parameters shall not be assigned a constant
    // expression that includes any specify parameters".
    if (!p.is_spec and readsSpecparam(r, src.e))
        return r.exprFail(src.e, "§4.10.3: a module parameter cannot be assigned an expression that includes a specify parameter");
    if (r.mixed and compile.typeOf(r, src.e).real) return null;
    if (isRoot(r, scope) and !p.is_local) for (r.opts.params) |o| if (std.mem.eql(u8, o.name, r.file.str(p.name))) {
        // `vera --param`: a string-defaulted parameter takes the text as a
        // §3.6 string; otherwise an integer's text is an integer, a real's a
        // real and any other text a string, as the literal would be.
        if (r.file.exprs.tag(p.default) == .str_literal) return .{ .v = try evaluate.stringLiteral(r.arena, o.text) };
        if (std.fmt.parseInt(i64, o.text, 10)) |n| {
            const w = try filled(r.arena, 64, true, .zero);
            w.values()[0] = @bitCast(n);
            const fits = std.math.cast(i32, n) != null;
            return .{ .v = try evaluate.normalize(r.arena, w, .{ .width = if (fits) 32 else 64, .signed = true }) };
        } else |_| {}
        if (!std.math.isNan(o.value)) return .{ .v = try evaluate.realLiteral(r.arena, o.value), .real = true };
        return .{ .v = try evaluate.stringLiteral(r.arena, o.text) };
    };
    if (scope == 0 and !p.is_local) for (r.card) |c| if (std.mem.eql(u8, c.name, r.file.str(p.name))) {
        // VAMS §6.3: the card sets the root's parameter as a `#( … )` would;
        // an integer one takes the value rounded, as the device's does.
        const w = try filled(r.arena, 64, true, .zero);
        w.values()[0] = @bitCast(std.math.lossyCast(i64, @round(c.value)));
        return .{ .v = try evaluate.normalize(r.arena, w, .{ .width = 32, .signed = true }) };
    };
    if (compile.typeOf(r, src.e).real) return .{ .v = try evaluate.realLiteral(r.arena, try evaluate.evalReal(r, r.arena, src.e)), .real = true };
    // §4.10.1/§5.4.1: a declared range or type is the context the value is
    // evaluated in, as an assignment's left side is.
    if (width > value.width) return .{ .v = try evaluate.eval(r, r.arena, src.e, width) };
    return .{ .v = value };
}

const ParamValue = struct { v: Int.Literal, real: bool = false };

/// The first name in `e` that does not resolve in the current scope.
fn unresolved(r: *Run, e: Ast.ExprId) ?Ast.ExprId {
    const ex = &r.file.exprs;
    if (ex.tag(e) == .ident) return if (r.lookup(r.scope, ex.strOf(e)) == null) e else null;
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (c != .none) if (unresolved(r, c)) |x| return x;
    return null;
}

/// Does `e`, read in the current scope, name a specparam?
fn readsSpecparam(r: *Run, e: Ast.ExprId) bool {
    const ex = &r.file.exprs;
    if (ex.tag(e) == .ident) return if (r.lookup(r.scope, ex.strOf(e))) |at| r.specparams.contains(at) else false;
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (c != .none and readsSpecparam(r, c)) return true;
    return false;
}

/// §6.2.2 one module or UDP instance, declared in `scope`, or IEEE 1364
/// §12.1.2's array of them, one instance per element from the lower index
/// up, each a scope named `u[k]` (the same order the analog elaborator uses).
fn instantiate(r: *Run, e: *Elab, scope: u32, inst: *const Ast.Instance, depth: u32) Error!void {
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

/// §12.1.2: "If the bit length of a port expression is the same as the
/// port's, the expression is connected to each instance" (null: bind it
/// whole). One as wide as the port times the element count is split: IEEE
/// 1364-2005 §7.1.6, "each instance shall get a part-select of the port
/// expression as specified in the range, starting with the right-hand index".
// ponytail: only a whole identifier is sized and split here; general
// expressions wait for a design that needs them.
fn arrayConn(r: *Run, e: *Elab, inst: *const Ast.Instance, port: Ast.Port, conn: Ast.PortConn, k: i64) Error!?PortBind {
    const refused = "§12.1.2: only a whole net or variable, as wide as the port or as the port times the array size, is connected across an instance array by digital execution";
    const w = try portWidth(r, port);
    // §12.1.2: "If the bit length of a port expression is the same as the
    // port, the expression is connected to each instance", whatever it is.
    if (r.file.exprs.tag(conn.expr) != .ident) {
        try compile.checkExpr(r, conn.expr);
        return if (compile.typeOf(r, conn.expr).width == w) null else r.fail(conn.main_tok, refused, .{});
    }
    const whole = e.values.items[try r.scalarSlot(conn.expr)].width;
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
        .output => blk: {
            const s = try sink(r, e, conn.expr, conn.main_tok, .port);
            const operands = try r.arena.dupe(Sink, &.{.{ .net = s.net, .lo = s.lo + lo, .width = w }});
            break :blk .{ .send = .{ .operands = operands, .tok = conn.main_tok } };
        },
        .inout, .unspecified => r.fail(conn.main_tok, refused, .{}),
    };
}

fn instantiateOne(r: *Run, e: *Elab, scope: u32, inst: *const Ast.Instance, depth: u32, index: ?i64) Error!void {
    const arena = r.arena;
    r.scope = scope;
    const bound = try binding.child(r, scope, inst);
    const child = try connectable(r, &r.file.modules[bound.def], inst.main_tok);
    try checkLists(r, child, inst);
    const binds_out = try arena.alloc(PortBind, child.ports.len);
    @memset(binds_out, .open);
    const grouped = !r.mixed and expressionPorts(child);
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
                total += try portWidth(r, child.ports[last]);
            var lo = total;
            for (child.ports[first..last], first..) |p, k| {
                if (p.direction != .input) return r.fail(conn.main_tok, "only an input port may be a concatenation of internal ports", .{});
                const w = try portWidth(r, p);
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
        if (r.mixed and continuous(r.file, child.ports[at].discipline)) continue;
        if (index) |k| if (conn.expr != .none) if (try arrayConn(r, e, inst, child.ports[at], conn, k)) |split| {
            binds_out[at] = split;
            continue;
        };
        binds_out[at] = try bindPort(r, e, child.ports[at], conn, scope);
    }
    const child_scope = try newScope(r, inst.main_tok);
    try r.scope_info.append(arena, .{ .parent = scope, .name = inst.name, .def = bound.def, .index = index });
    try r.binds.put(arena, child_scope, bound.ctx);
    // §12.4's path is walked by name, so the instance's own identifier has
    // to outlive the recursion that consumes it. An array element's path
    // carries its index, which that walk does not read: not registered.
    if (inst.name != .none) if (index) |k| try selectable(r, scope, inst.name, k, child_scope) else try r.instances.put(arena, .{ .scope = scope, .str = inst.name }, child_scope);
    try declare(r, e, child, child_scope, binds_out, inst.params, depth + 1);
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
        for (inst.params[0..i]) |q| if (q.name == o.name) return r.fail(o.main_tok, "§12.2.2.2: parameter `{s}` is assigned twice", .{name});
        const p = for (child.params) |p| {
            if (p.name == o.name) break p;
        } else return r.fail(o.main_tok, "§12.2.2.2: the module has no such parameter: `{s}`", .{name});
        if (p.is_local) return r.fail(o.main_tok, "§12.2: `{s}` is a local parameter, which a parameter value assignment cannot override", .{name});
    }
    if (inst.params.len != 0 and inst.params[0].name == .none) {
        var n: usize = 0;
        for (child.params) |p| n += @intFromBool(!p.is_local);
        if (inst.params.len > n) return r.fail(inst.params[n].main_tok, "§12.2.2.1: more parameter values than the module has parameters", .{});
    }
    for (inst.ports, 0..) |c, i| {
        if ((c.name == .none) != (inst.ports[0].name == .none))
            return r.fail(c.main_tok, "§12.3.6: an instance mixes ordered and named port connections", .{});
        if (c.name == .none) continue;
        for (inst.ports[0..i]) |q| if (q.name == c.name) return r.fail(c.main_tok, "§12.3.6: port `{s}` is connected twice", .{r.file.str(c.name)});
    }
}

/// VAMS §7.2.2: the variables a discrete process of `m` writes, the ones
/// whose domain is digital.
fn digitalWrites(r: *Run, m: *const Ast.ModuleDecl) Error!std.AutoHashMapUnmanaged(Ast.StrId, void) {
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
fn continuous(file: *const Ast.SourceFile, name: Ast.StrId) bool {
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

/// The next scope id. The caller appends its `scope_info` row, which must be
/// row `id` (ids are dense, root 0). Fails at 2^32 - 1 scopes.
pub fn newScope(r: *Run, tok: u32) Error!u32 {
    r.scopes += 1;
    if (r.scopes == std.math.maxInt(u32)) return r.fail(tok, "too many digital instances", .{});
    return r.scopes;
}

/// One variable's storage in the current scope (a whole value, or §3.9's
/// array of them), bound to its name. Works in both passes: an automatic
/// task inlined at a call site gets fresh storage while pass two compiles it.
fn mintVar(r: *Run, v: Ast.VarDecl) Error!u32 {
    const g = r.growing.?;
    if (v.ty == .string) return r.fail(v.main_tok, "string variables are not implemented", .{});
    const real = v.ty == .real;
    // §4.8: `integer` is 32 signed bits and `time` 64 unsigned ones.
    // §4.8: a real is a double, held as its 64 bits.
    const width: u32 = if (real) 64 else if (v.packed_range) |range| try r.declaredWidth(range, v.main_tok) else switch (v.storage) {
        .reg => 1,
        .variable => 32,
        .time => 64,
    };
    const base: u32 = @intCast(g.items.len);
    try r.bind(v.name, base, v.main_tok);
    if (v.packed_range) |range| try putRange(r, base, range, v.main_tok);
    const count = try declareArray(r, base, v.dims, v.main_tok);
    if (count > std.math.maxInt(u32) - g.items.len) return r.fail(v.main_tok, "too many digital storage slots", .{});
    const signed = switch (v.storage) {
        .reg => v.is_signed,
        .variable => true,
        .time => false,
    };
    // §4.8: "the default initial value for real ... shall be 0.0"; every
    // other variable starts at x (§3.2).
    for (0..count) |i| {
        try g.append(r.arena, try filled(r.arena, width, signed or real, if (real) .zero else .x));
        if (real) try r.reals.put(r.arena, base + @as(u32, @intCast(i)), {});
    }
    r.values = g.items;
    return base;
}

/// §4.9 the `arrays` row of the array whose first element is `base`, declared
/// with `dims`, and its element count; 1, and no row, for no dimensions.
fn declareArray(r: *Run, base: u32, dims: []const Ast.Dim, tok: u32) Error!u32 {
    if (dims.len == 0) return 1;
    var count: u32 = 1;
    const spans = try r.arena.alloc(Span, dims.len);
    var left: i64 = 0;
    var right: i64 = 0;
    for (dims, spans, 0..) |d, *s, k| {
        const lo = try r.declaredBound(d.lsb, tok);
        const hi = try r.declaredBound(d.msb, tok);
        if (k == 0) {
            left = hi;
            right = lo;
        }
        s.* = .{ .low = @min(lo, hi), .high = @max(lo, hi), .descending = hi > lo };
        const size = std.math.cast(u32, @as(i128, s.high) - s.low + 1) orelse return r.fail(tok, "unpacked array size is outside the supported u32 range", .{});
        count = std.math.mul(u32, count, size) catch return r.fail(tok, "unpacked array size is outside the supported u32 range", .{});
    }
    try r.arrays.put(r.arena, base, .{ .count = count, .low = spans[0].low, .high = spans[0].high, .left = left, .right = right, .rest = spans[1..] });
    return count;
}

/// §4.9.1 the slot a driver, a port connection or a §9.3.2 `force` drives: a whole net, or one
/// element of a net array named with a constant index per dimension.
pub fn netSlot(r: *Run, e: Ast.ExprId, tok: u32) Error!u32 {
    const arr = (try r.indexedArray(e)) orelse return r.scalarSlot(e);
    const ex = &r.file.exprs;
    const c = r.chainBase(e);
    var offset: evaluate.Offset = .{};
    var inside = true;
    var x = e;
    var k = c.depth;
    while (k != 0) : (x = ex.lhs(x)) {
        k -= 1;
        inside = offset.add(arr, k, try r.declaredBound(ex.rhs(x), tok)) and inside;
    }
    if (!inside) return r.fail(tok, "§4.9: an array index is outside its declared range", .{});
    return try r.slot(c.base) + offset.at;
}

fn usesReal(t: *const Ast.Subroutine) bool {
    if (t.is_function and t.result.ty != .integer) return true;
    for (t.ports) |p| if (p.v.ty != .integer) return true;
    for (t.vars) |v| if (v.ty != .integer) return true;
    return false;
}

/// A fresh frame for `t` inside instance `inst`: its static one in pass one,
/// an automatic task's per-call-site one in pass two.
pub fn frame(r: *Run, t: *const Ast.Subroutine, inst: u32) Error!Frame {
    const g = r.growing.?;
    // §10.4.4 c) and d): at least one input, and no output or inout.
    if (t.is_function) {
        for (t.ports) |p| if (p.direction != .input)
            return r.fail(p.v.main_tok, "§10.4.4: a function argument is an input, not an output or inout", .{});
        if (t.ports.len == 0) return r.fail(t.main_tok, "§10.4.1: a function shall have at least one input declared", .{});
    }
    const scope = try newScope(r, t.main_tok);
    try r.scope_info.append(r.arena, .{ .parent = inst, .name = t.name, .def = r.scope_info.items[inst].def, .lexical = true });
    const saved = r.scope;
    r.scope = scope;
    defer r.scope = saved;
    // §4.10: parameters are constants, not automatic variables. Keep their
    // slots outside the activation's saved/reset range on both execution
    // paths. Declaring them first also lets formal ranges read them.
    try declareParams(r, scope, t.params, &.{});
    const first: u32 = @intCast(g.items.len);
    const ports = try r.arena.alloc(u32, t.ports.len);
    // §10.2.1/§10.4.1: a non-ANSI port's type may come from a following
    // declaration of its name (`input x; real x;`), which declares the port.
    // ponytail: the two declarations' ranges are not compared, and an ANSI
    // port redeclared in the body is taken the same way, not refused.
    for (t.ports, ports) |p, *slot| slot.* = try mintVar(r, for (t.vars) |v| {
        if (v.name == p.v.name) break v;
    } else p.v);
    const result = if (t.is_function) try mintVar(r, t.result) else 0;
    try declareEvents(r, t.events);
    vars: for (t.vars) |v| {
        for (t.ports) |p| if (p.v.name == v.name) continue :vars;
        if (v.init != .none) return r.fail(v.main_tok, "an initialized task or function variable is not implemented", .{});
        _ = try mintVar(r, v);
    }
    if (t.automatic) for (first..g.items.len) |at| try r.auto_slots.put(r.arena, @intCast(at), {});
    return .{ .scope = scope, .ports = ports, .result = result, .first = first, .count = @as(u32, @intCast(g.items.len)) - first };
}

/// §10.4.5: function `idx`, called by a constant function call before its
/// instance's frames exist (a parameter's value), framed, judged a constant
/// function and compiled now, so `exec.callSync` can run it during
/// elaboration.
pub fn earlyFrame(r: *Run, idx: u32, tok: u32) Error!void {
    const sub = &r.subs.items[idx];
    sub.frame = try frame(r, sub.decl, sub.inst);
    sub.framed = true;
    if (try compile.notConstant(r, idx)) |why|
        return r.fail(tok, "§10.4.5: a function called during elaboration is a constant function, and {s}", .{why});
    const saved = r.scope;
    defer r.scope = saved;
    try compile.compileSub(r, idx);
}

/// VAMS §3.7's port merge: a wire or tri joined to a wreal port becomes one
/// wreal net, for every other connection to it too. `Front.wreal.check` has
/// already refused the net types §3.7 does not call compatible.
fn promoteWreal(r: *Run, e: *Elab, net: u32) Error!void {
    const n = &e.nets.items[net];
    if (n.kind == .wreal) return;
    n.kind = .wreal;
    n.resolved = try filled(r.arena, 64, false, .z);
    e.values.items[n.slot] = try filled(r.arena, 64, true, .zero);
    r.values = e.values.items;
    try r.reals.put(r.arena, n.slot, {});
}

/// Allocate one net and its slot, and bind `name` (unless `.none`) to it in the current scope.
pub fn mintNet(r: *Run, e: *Elab, kind: Ast.NetKind, width: u32, signed: bool, name: Ast.StrId, tok: u32) Error!u32 {
    if (e.values.items.len == std.math.maxInt(u32)) return r.fail(tok, "too many digital storage slots", .{});
    const slot: u32 = @intCast(e.values.items.len);
    const at: u32 = @intCast(e.nets.items.len);
    if (name != .none) try r.bind(name, slot, tok);
    // §3.7: a net with no driver is z, not x, except where the net type itself
    // supplies a value. VAMS §3.7:
    // a wreal carries a real and "shall have an initial value of zero".
    const wreal = kind == .wreal;
    try e.values.append(r.arena, try filled(r.arena, if (wreal) 64 else width, signed or wreal, if (wreal) .zero else undriven(kind)));
    if (wreal) try r.reals.put(r.arena, slot, {});
    if (e.signals.items.len > std.math.maxInt(u32) - width) return r.fail(tok, "too many digital net bits", .{});
    const signal: u32 = @intCast(e.signals.items.len);
    try e.signals.appendNTimes(r.arena, .{}, width);
    try e.nets.append(r.arena, .{ .kind = kind, .slot = slot, .resolved = try filled(r.arena, if (wreal) 64 else width, false, .z), .signal = signal, .tok = tok });
    try r.net_of.put(r.arena, slot, at);
    return at;
}

fn findUdp(file: *const Ast.SourceFile, name: Ast.StrId) ?*const Ast.UdpDecl {
    for (file.udps) |*u| if (u.name == name) return u;
    return null;
}

/// IEEE 1364-2005 §8 one UDP instance, or §8.6's array of them: one more
/// driver of its output net per instance, as a gate is (§8.1: "UDPs are
/// instantiated exactly the same way as gate primitives"), whose value is its
/// table's. An array's instances split a vector terminal one bit each, the
/// leftmost index the most significant (§7.1.6). §8.5: a sequential UDP's
/// state starts at its `initial` value, or x, and that value is on the output
/// at time 0 whatever the instance delay.
fn declareUdp(r: *Run, e: *Elab, scope: u32, inst: *const Ast.Instance, u: *const Ast.UdpDecl) Error!void {
    const tok = inst.main_tok;
    if (inst.ports.len != u.ports.len) return r.fail(tok, "§8: a UDP instance connects its output and every input, in order", .{});
    for (inst.ports) |c| if (c.name != .none or c.expr == .none)
        return r.fail(c.main_tok, "§8: a UDP instance connects its terminals by position, none left open", .{});
    // `inv #(2, 3) g(q, a)` parses as a parameter value assignment; on a
    // UDP it is A.5.4's `delay2`.
    var delay = inst.delay;
    if (inst.params.len != 0) {
        if (inst.params.len > 2) return r.fail(tok, "§8.6: a UDP instance takes at most two delays", .{});
        for (inst.params) |o| if (o.name != .none) return r.fail(o.main_tok, "§8.6: a UDP instance's `#( )` is a delay, not a parameter value assignment", .{});
        for (inst.params) |o| if (o.scaled_literal_tok) |scaled_tok|
            return r.failWith(.E0247, scaled_tok, "a scaled literal in `{s}`'s UDP delay", .{r.file.str(inst.module)});
        delay = .{ .rise = inst.params[0].value, .fall = inst.params[inst.params.len - 1].value, .off = if (inst.params.len == 1) inst.params[0].value else .none };
    }
    const out = try sink(r, e, inst.ports[0].expr, tok, .port);
    const lanes: u32 = if (inst.range) |rg| try r.declaredWidth(rg, tok) else 1;
    if (out.width != 1 and out.width != lanes) return r.fail(tok, "§8.6: a UDP's output terminal is one bit, or one per instance of an array", .{});
    const wide = e.nets.items[out.net].resolved.width != 1;
    const rows = (try net_mod.udpRows(r.arena, u)) orelse return r.fail(u.main_tok, "a UDP table entry needs one field per input", .{});
    const ins = try r.arena.alloc(Ast.ExprId, u.ports.len - 1);
    for (inst.ports[1..], ins) |c, *in| in.* = c.expr;
    const ex = &r.file.exprs;
    const state: Int.Bit = if (u.init == .none) .x else switch (ex.tag(u.init)) {
        .int_literal => if (ex.intValue(u.init) == 0) .zero else .one,
        .logic_literal => ex.logicValue(u.init).bit(0),
        else => return r.exprFail(u.init, "a UDP initial value is 0, 1 or x"), // else: A.5.3 init_val is a literal
    };
    for (0..lanes) |j| {
        const lane: u32 = @intCast(lanes - 1 - j);
        const prev = try r.arena.alloc(Int.Bit, ins.len);
        @memset(prev, .x);
        const udp = try r.arena.create(Udp);
        udp.* = .{
            .rows = rows,
            .sequential = u.is_sequential,
            .ins = ins,
            .prev = prev,
            .state = state,
            .lane = if (inst.range == null) null else lane,
            .out_bit = if (!wide) null else out.lo + if (out.width == 1) 0 else lane,
        };
        try e.wires.append(r.arena, .{ .net = out.net, .scope = scope, .source = .{ .udp = udp }, .s0 = inst.strength0, .s1 = inst.strength1, .delay = delay, .tok = tok });
    }
}

/// The IEEE 1364-2005 §8.1 rules on a UDP declaration itself.
pub fn checkUdp(r: *Run, u: *const Ast.UdpDecl) Error!void {
    const tok = u.main_tok;
    if (u.outputs != 1) return r.fail(tok, "§8.1.1: a UDP has exactly one output port", .{});
    if (u.output != u.ports[0]) return r.fail(tok, "§8.1.1: the output port shall be the first port of a UDP", .{});
    if (u.is_sequential and !u.has_reg) return r.fail(tok, "§8.1.2: a sequential UDP's output needs a reg declaration", .{});
    if (!u.is_sequential and u.has_reg) return r.fail(tok, "§8.1.2: a combinational UDP cannot contain a reg declaration", .{});
    if (u.init == .none) return;
    if (u.init_target != u.ports[0]) return r.fail(tok, "§8.1.3: a UDP initial statement assigns the output", .{});
    const ex = &r.file.exprs;
    const width: u32 = switch (ex.tag(u.init)) {
        .int_literal => ex.intLiteral(u.init).width,
        .logic_literal => ex.logicValue(u.init).width,
        else => 1, // else: `declareUdp` refuses anything but a literal
    };
    if (width > 1) return r.exprFail(u.init, "§8.1.3: a UDP initial value is a single-bit literal");
}

/// IEEE 1364-2005 §12.3.2: does `m` use A.1.3's port expressions beyond one
/// whole net per port (a concatenation, a bit- or part-select, a name more
/// than one port reference names)? Its ports are then connected one external
/// port at a time (`groupPorts`).
fn expressionPorts(m: *const Ast.ModuleDecl) bool {
    for (m.ports, 0..) |p, i| {
        if (p.name == .none) continue; // A.1.3: null ports name no shared internal net
        if (p.select != null or p.concat_rest) return true;
        for (m.ports[0..i]) |q| if (q.name == p.name) return true;
    }
    return false;
}

/// One past the last reference of the external port starting at `i`.
fn groupEnd(m: *const Ast.ModuleDecl, i: usize) usize {
    var end = i + 1;
    while (end < m.ports.len and m.ports[end].concat_rest) end += 1;
    return end;
}

/// The first reference of the `n`th external port.
fn nthGroup(m: *const Ast.ModuleDecl, n: usize) ?usize {
    var i: usize = 0;
    var k: usize = 0;
    while (i < m.ports.len) : (i = groupEnd(m, i)) {
        if (k == n) return i;
        k += 1;
    }
    return null;
}

/// The first reference of the external port named `name`: its `.name(...)`,
/// or a lone whole-net reference's own name (§12.3.6).
fn groupByName(m: *const Ast.ModuleDecl, name: Ast.StrId) ?usize {
    var i: usize = 0;
    while (i < m.ports.len) : (i = groupEnd(m, i)) {
        const p = m.ports[i];
        const own = if (p.external_name != .none) p.external_name else if (groupEnd(m, i) == i + 1 and p.select == null) p.name else .none;
        if (own == name) return i;
    }
    return null;
}

/// IEEE 1364-2005 §12.3.2/§12.3.3 the ports of an expression-ported module:
/// one net (or output variable) per port name, then each external port's
/// connection split among its references, leftmost the most significant.
fn groupPorts(r: *Run, e: *Elab, m: *const Ast.ModuleDecl, scope: u32, binds: []const PortBind) Error!void {
    for (m.ports, 0..) |p, i| {
        if (p.name == .none) continue; // A.1.3: a null port declares no internal net
        if (for (m.ports[0..i]) |q| {
            if (q.name == p.name) break true;
        } else false) continue;
        if (p.direction == .unspecified) return r.fail(p.main_tok, "§12.3.3: port `{s}` has no direction declaration", .{r.file.str(p.name)});
        if (r.names.contains(.{ .scope = scope, .str = p.name })) {
            if (p.direction != .output) return r.fail(p.main_tok, "§12.3.3: only an output port may be declared as a variable", .{});
            continue;
        }
        const range = p.range orelse p.type_range;
        const width = if (range) |rg| try r.declaredWidth(rg, p.main_tok) else 1;
        const at = try mintNet(r, e, p.kind, width, p.is_signed, p.name, p.main_tok);
        if (range) |rg| try putRange(r, e.nets.items[at].slot, rg, p.main_tok);
    }
    var i: usize = 0;
    while (i < m.ports.len) {
        const end = groupEnd(m, i);
        if (m.ports[i].name != .none and i < binds.len and binds[i] == .group)
            try connectGroup(r, e, m.ports[i..end], binds[i].group.conn, binds[i].group.scope, scope);
        i = end;
    }
}

/// One external port's connection `conn` (made in `parent`) split among its
/// references `refs` (declared in `scope`). An input reference receives its
/// bits of the connected expression, an output one drives its bits of the
/// connected nets, and an inout one is joined to them bit by bit, as a
/// `tran` joins two nets (§7.6).
fn connectGroup(r: *Run, e: *Elab, refs: []const Ast.Port, conn: Ast.PortConn, parent: u32, scope: u32) Error!void {
    if (conn.expr == .none) return;
    const Ref = struct { slot: u32, lo: u32, width: u32, at: u32, dir: Ast.Direction };
    const list = try r.arena.alloc(Ref, refs.len);
    var total: u32 = 0;
    r.scope = scope;
    var k = refs.len;
    while (k != 0) {
        k -= 1;
        const p = refs[k];
        const slot = r.names.get(.{ .scope = scope, .str = p.name }).?; // `groupPorts` declared every name
        var lo: u32 = 0;
        var w = e.values.items[slot].width;
        if (p.select) |sel| {
            const range = r.vec_ranges.get(slot) orelse VecRange{ .msb = @as(i64, w) - 1, .lsb = 0 };
            const a = range.position(try r.declaredBound(sel.msb, p.main_tok));
            const b = range.position(try r.declaredBound(sel.lsb, p.main_tok));
            if (@min(a, b) < 0 or @max(a, b) >= w) return r.fail(p.main_tok, "§12.3.2: a port reference's select is outside its net", .{});
            lo = @intCast(@min(a, b));
            w = @intCast(@abs(a - b) + 1);
        }
        list[k] = .{ .slot = slot, .lo = lo, .width = w, .at = total, .dir = p.direction };
        total += w;
    }
    r.scope = parent;
    // Inputs: the expression, as wide as the port, on a net of its own whose
    // bits each input reference takes.
    var fed: ?u32 = null;
    for (list) |ref| if (ref.dir == .input) {
        const dst = r.net_of.get(ref.slot) orelse return r.fail(conn.main_tok, "§12.3.3: an input port reference names a net", .{});
        const h = fed orelse blk: {
            const n = try mintNet(r, e, .wire, total, false, .none, conn.main_tok);
            try e.wires.append(r.arena, .{ .net = n, .scope = parent, .source = .{ .expr = .{ .e = conn.expr } }, .tok = conn.main_tok });
            fed = n;
            break :blk n;
        };
        try e.wires.append(r.arena, .{ .net = dst, .scope = scope, .source = .{ .bridge = .{ .src = e.nets.items[h].slot, .src_lo = ref.at, .dst_lo = ref.lo, .width = ref.width } }, .tok = conn.main_tok });
    };
    if (for (list) |ref| {
        if (ref.dir != .input) break false;
    } else true) return;
    // Outputs and inouts: the connected nets, bit ranges from the least
    // significant (§12.3.9.2).
    var leaves: std.ArrayList(Ast.ExprId) = .empty;
    try concatLeaves(r, conn.expr, &leaves);
    const sinks = try r.arena.alloc(struct { s: Sink, at: u32 }, leaves.items.len);
    var at: u32 = 0;
    var j = leaves.items.len;
    while (j != 0) {
        j -= 1;
        sinks[j] = .{ .s = try sink(r, e, leaves.items[j], conn.main_tok, .port), .at = at };
        at += sinks[j].s.width;
    }
    for (list) |ref| for (sinks) |s| {
        const from = @max(ref.at, s.at);
        const to = @min(ref.at + ref.width, s.at + s.s.width);
        if (from >= to) continue;
        switch (ref.dir) {
            .output => try e.wires.append(r.arena, .{ .net = s.s.net, .scope = scope, .source = .{ .bridge = .{ .src = ref.slot, .src_lo = ref.lo + from - ref.at, .dst_lo = s.s.lo + from - s.at, .width = to - from } }, .tok = conn.main_tok }),
            .inout => {
                const net = r.net_of.get(ref.slot) orelse return r.fail(conn.main_tok, "§12.3.3: an inout port reference names a net", .{});
                for (from..to) |b| try e.trans.append(r.arena, .{
                    .tran = .{
                        .a = net,
                        .b = s.s.net,
                        .a_bit = @intCast(ref.lo + b - ref.at),
                        .b_bit = @intCast(s.s.lo + b - s.at),
                        .ctrl = .none,
                        .on = .one,
                        .state = .on,
                        .target = .on,
                        .resistive = false,
                        .delay = .{},
                    },
                    .scope = scope,
                    .tok = conn.main_tok,
                });
            },
            .input, .unspecified => {},
        }
    };
}

/// A port by the name a named connection may use: its own, when the header
/// gave it no external name. A concatenation with no external name has none
/// (§12.3.6: it connects by position only).
fn portByName(m: *const Ast.ModuleDecl, name: Ast.StrId) ?usize {
    for (m.ports, 0..) |p, k| {
        if (p.concat_rest or (k + 1 < m.ports.len and m.ports[k + 1].concat_rest)) continue;
        if (if (p.external_name == .none) p.name == name else p.external_name == name) return k;
    }
    return null;
}

/// Records `slot`'s declared `[msb:lsb]` (`Run.vec_ranges`).
fn putRange(r: *Run, slot: u32, range: Ast.Dim, tok: u32) Error!void {
    try r.vec_ranges.put(r.arena, slot, .{ .msb = try r.declaredBound(range.msb, tok), .lsb = try r.declaredBound(range.lsb, tok) });
}

/// A port's declared width, evaluated in the scope being elaborated.
/// ponytail: a child port whose range names the child's parameters is sized
/// before the child exists; the literal ranges every fixture writes are fine.
fn portWidth(r: *Run, p: Ast.Port) Error!u32 {
    if (p.kind == .wreal) return 64;
    return if (p.range orelse p.type_range) |range| r.declaredWidth(range, p.main_tok) else 1;
}

/// §6.5.7 one port connection, decided in the PARENT's scope.
fn bindPort(r: *Run, e: *Elab, port: Ast.Port, conn: Ast.PortConn, scope: u32) Error!PortBind {
    if (conn.expr == .none) return .open;
    const ex = &r.file.exprs;
    // §12.3.7: "The real data type shall not be directly connected to a port."
    if (ex.tag(conn.expr) == .ident) if (r.lookup(scope, ex.strOf(conn.expr))) |at| if (r.reals.contains(at) and !r.net_of.contains(at))
        return r.exprFail(conn.expr, "§12.3.7: a real cannot be connected to a port");
    // One whole net on the outside is a collapse, the only arm under which
    // the child's drive strengths reach the parent's resolution unchanged
    // (IEEE 1364 clause 12: a port is a connection). `declare` size-checks
    // it once the port's own width is known.
    if (ex.tag(conn.expr) == .ident) {
        if (r.net_of.get(try r.scalarSlot(conn.expr))) |net| return .{ .collapse = .{ .net = net, .expr = conn.expr, .scope = scope, .tok = conn.main_tok } };
    }
    return switch (port.direction) {
        // §6.5.2.2 an input port is a receiver: the child puts no driver on the
        // outside, so whatever the parent wrote feeds the port net.
        .input => .{ .receive = .{ .expr = conn.expr, .scope = scope, .tok = conn.main_tok } },
        // A net array element (§4.9.1) is sent to, not collapsed onto: the
        // array's name and its first element share a slot, which a child
        // port bound to that slot would read as the whole array.
        // ponytail: so a child's drive strength does not reach the element.
        .output, .inout => blk: {
            const args = if (ex.tag(conn.expr) == .concat) ex.args(conn.expr) else &.{conn.expr};
            const operands = try r.arena.alloc(Sink, args.len);
            for (args, operands) |arg, *out| out.* = try sink(r, e, arg, conn.main_tok, .port);
            const c: Sinks = .{ .operands = operands, .tok = conn.main_tok };
            break :blk if (port.direction == .output) .{ .send = c } else .{ .join = c };
        },
        .unspecified => r.fail(port.main_tok, "§6.5.2.2: this port has no direction declaration", .{}),
    };
}

/// The operands of `e`, a nested concatenation flattened in order, or `e`
/// itself.
fn concatLeaves(r: *Run, e: Ast.ExprId, out: *std.ArrayList(Ast.ExprId)) Error!void {
    const ex = &r.file.exprs;
    if (ex.tag(e) != .concat) return out.append(r.arena, e);
    for (ex.args(e)) |x| try concatLeaves(r, x, out);
}

/// What drives a structural net expression: an output port, a continuous
/// assignment (§6.1.1) or a gate's output terminal (A.3.3), which admit the
/// same forms.
const SinkOf = enum { port, assign, gate };

/// IEEE 1364-2005 §12.3.9.2 one operand of a structural net expression: a
/// net, a net array element, or a constant bit-select or part-select of a
/// vector net.
fn sink(r: *Run, e: *Elab, arg: Ast.ExprId, tok: u32, comptime who: SinkOf) Error!Sink {
    const ex = &r.file.exprs;
    r.values = e.values.items;
    const lvalue = " a net, a net array element, a constant bit-select or part-select of a vector net, or a concatenation of them";
    const not_net, const refused = switch (who) {
        .port => .{ "an output port can only drive a net", "§12.3.9.2: an output port connects to" ++ lvalue },
        .assign => .{ "a continuous assignment can only drive a net", "§6.1.1: a continuous assignment connects to" ++ lvalue },
        .gate => .{ "a gate's output terminal must be a net", "A.3.3: a gate's output terminal is a net_lvalue:" ++ lvalue },
    };
    if (ex.tag(arg) == .ident or try r.indexedArray(arg) != null) {
        const net = r.net_of.get(try netSlot(r, arg, tok)) orelse return r.exprFail(arg, not_net);
        return .{ .net = net, .lo = 0, .width = e.nets.items[net].resolved.width };
    }
    // §6.1.1/A.8.5: the select may stand on a net array element, `b[i][j]`.
    if (ex.tag(arg) != .index or (ex.tag(ex.lhs(arg)) != .ident and try r.indexedArray(ex.lhs(arg)) == null)) return r.exprFail(arg, refused);
    const rg = ex.rhs(arg);
    const index = switch (ex.tag(rg)) {
        .range => Ast.ExprId.none,
        .indexed_range => ex.lhs(rg),
        else => rg, // else: a bit-select's index
    };
    try compile.checkExpr(r, arg);
    if (index != .none and !compile.constantExpression(r, index)) return r.exprFail(arg, refused);
    const net = r.net_of.get(try netSlot(r, ex.lhs(arg), tok)) orelse return r.exprFail(arg, not_net);
    const sel = (try evaluate.selection(r, r.arena, arg)) orelse return r.exprFail(arg, "§12.3.9.2: the select's index is x or z");
    if (sel.first < 0 or sel.first + sel.count > e.nets.items[net].resolved.width) return r.exprFail(arg, "§12.3.9.2: the select is outside its net");
    return .{ .net = net, .lo = @intCast(sel.first), .width = sel.count };
}

// ---- tests ------------------------------------------------------------------

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
    , "1111 7 -4 0001 z 1\n1\n");
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
        try std.testing.expect(r.reals.contains(r.slotOf(name).?));
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
