//! A module or block's declarations in its scope in, its slots, events, named blocks and implicit nets out.
//! Cites: IEEE 1364-2005 §3.2, §4.5 implicit nets, §4.9, §9.8, §12.5.
//!
//! Contents:
//! - `pub const size_mismatch`
//! - `pub fn declare(r: *Run, e: *Elab, m: *const Ast.ModuleDecl, scope: u32, binds: []const PortBind, over: []const Ast.ParamOverride, depth: u32) Error!void`
//! - `pub fn declareHead(r: *Run, e: *Elab, m: *const Ast.ModuleDecl, scope: u32, over: []const Ast.ParamOverride, depth: u32) Error!void`
//! - `pub fn declareBody(r: *Run, e: *Elab, m: *const Ast.ModuleDecl, scope: u32, binds: []const PortBind, depth: u32) Error!void`
//! - `pub fn sameRange(r: *Run, a: Ast.Dim, b: Ast.Dim, tok: u32) Error!bool`
//! - `pub fn declareEvents(r: *Run, events: []const Ast.EventDecl) Error!void`
//! - `pub fn blockScopes(r: *Run, scope: u32, s: Ast.StmtId) Error!void`
//! - `W.expr(_: @This(), _: Ast.ExprId, _: Ast.SourceFile.Edge) Error!void {}`
//! - `W.stmt(w: @This(), c: Ast.StmtId) Error!void`
//! - `pub fn blockScope(r: *Run, scope: u32, s: Ast.StmtId) Error!u32`
//! - `W.expr(_: @This(), _: Ast.ExprId, _: Ast.SourceFile.Edge) error{Found}!void {}`
//! - `W.stmt(w: @This(), c: Ast.StmtId) error{Found}!void`
//! Pass one of elaboration: the parsed design and its root definitions ->
//! the slot space, the nets and the driver rows (`Elab`), the scope tree
//! (`Run.hier.scopes`) and every name bound in it, before any expression is
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
const elab_defparams = @import("elab_defparams.zig");
const elab_drivers = @import("elab_drivers.zig");
const elab_generate = @import("elab_generate.zig");
const elab_params = @import("elab_params.zig");
const elab_paths = @import("elab_paths.zig");
const elab_ports = @import("elab_ports.zig");
const elab_slots = @import("elab_slots.zig");
const elab_warnings = @import("elab_warnings.zig");
const Elab = elab.Elab;
const PortBind = elab.PortBind;
const Sink = elab.Sink;
const bindDefparam = elab_defparams.bindDefparam;
const bridged = elab_drivers.bridged;
const continuous = elab_drivers.continuous;
const declareArray = elab_slots.declareArray;
const declareDrivers = elab_drivers.declareDrivers;
const declareNet = elab_generate.declareNet;
const declareParams = elab_params.declareParams;
const digitalWrites = elab_drivers.digitalWrites;
const expressionPorts = elab_ports.expressionPorts;
const frame = elab_slots.frame;
const generate = elab_generate.generate;
const groupPorts = elab_ports.groupPorts;
const ieee1364 = elab_params.ieee1364;
const instantiate = elab.instantiate;
const internalDominates = elab_warnings.internalDominates;
const isGenerate = elab_generate.isGenerate;
const max_depth = elab.max_depth;
const max_insts = elab.max_insts;
const mintNet = elab_slots.mintNet;
const mintVar = elab_slots.mintVar;
const newScope = elab.newScope;
const pathDelays = elab_paths.pathDelays;
const portWidth = elab_ports.portWidth;
const promoteWreal = elab_slots.promoteWreal;
const putRange = elab_ports.putRange;
const sendPort = elab_warnings.sendPort;
const usesReal = elab_slots.usesReal;
const warnPort = elab_warnings.warnPort;

pub const size_mismatch = "§6.5.7.1: the sizes of the port and the net connected to it shall match";

/// One instance's storage: its variables, its nets, its ports' nets, and the
/// driver rows its continuous assignments and port connections contribute.
/// Recurses into child instances AFTER its own nets exist, so a port connection
/// always resolves against a parent that is fully declared.
pub fn declare(r: *Run, e: *Elab, m: *const Ast.ModuleDecl, scope: u32, binds: []const PortBind, over: []const Ast.ParamOverride, depth: u32) Error!void {
    assert(scope < r.hier.scopes.items.len);
    assert(r.growing != null); // Pass one: storage still grows.
    const insts = e.insts.items.len;
    try declareHead(r, e, m, scope, over, depth);
    try declareBody(r, e, m, scope, binds, depth);
    assert(e.insts.items.len > insts); // This instance and its children.
}

/// `declare`'s first half: the instance's defparams, tasks and functions,
/// and parameters, which an instance's parent needs before it binds the
/// ports (a port range may name a parameter, IEEE 1364-2005 §12.2).
pub fn declareHead(r: *Run, e: *Elab, m: *const Ast.ModuleDecl, scope: u32, over: []const Ast.ParamOverride, depth: u32) Error!void {
    assert(scope < r.hier.scopes.items.len);
    const arena = r.arena;
    if (deep.exhausted()) return r.deepFail(m.main_tok);
    // §12.1.3: a module may instantiate itself only under a generate that
    // terminates; one that does not grows the tree without end, and long
    // before the stack is deep the storage is (ivtest pr2728812c, a binary
    // tree of `sum` at n = 1, reached 25 GB). ponytail: caps, not a cycle
    // proof; no design this interpreter runs is this deep or this wide.
    if (depth >= max_depth or e.insts.items.len >= max_insts)
        return r.fail(m.main_tok, "instantiation past {d} levels or {d} instances: a module instantiates itself without a terminating generate (IEEE 1364-2005 §12.1.3)", .{ max_depth, max_insts });
    if (!r.analog.mixed and (m.aliasparams.len != 0 or m.branches.len != 0 or m.functions.len != 0))
        return r.fail(m.main_tok, "digital execution currently requires a module with only variables, nets, events, instances and processes", .{});
    // A digital parse makes each generate construct an `analog` block over
    // an `if`; anything else there is a genuine analog block.
    if (!r.analog.mixed) for (m.analog) |ab| if (!isGenerate(r.file, m, ab.body))
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
    try r.routines.base.put(arena, scope, @intCast(r.routines.rows.items.len));
    for (m.tasks) |*t| {
        // A mixed module's real-valued function is the analog side's to call
        // (VAMS §4.7); this engine holds no real, so it declares none.
        if (r.analog.mixed and usesReal(t)) continue;
        const entry = try r.routines.by_name.getOrPut(arena, .{ .scope = scope, .str = t.name });
        if (entry.found_existing) return r.fail(t.main_tok, "duplicate task or function", .{});
        entry.value_ptr.* = @intCast(r.routines.rows.items.len);
        try r.routines.rows.append(arena, .{ .decl = t, .inst = scope, .frame = undefined });
    }
    try declareParams(r, scope, m.params, over);
    assert(r.routines.base.get(scope).? <= r.routines.rows.items.len);
    assert(e.insts.items[e.insts.items.len - 1].scope == scope or e.insts.items.len > 1);
}

/// `declare`'s second half: everything after the parameters, the ports
/// bound by `binds` and the child instances last.
pub fn declareBody(r: *Run, e: *Elab, m: *const Ast.ModuleDecl, scope: u32, binds: []const PortBind, depth: u32) Error!void {
    assert(scope < r.hier.scopes.items.len);
    assert(depth < max_depth);
    assert(r.routines.base.contains(scope)); // `declareHead` ran.
    const arena = r.arena;
    r.scope = scope;
    try declareEvents(r, m.events);
    const written = if (r.analog.mixed) try digitalWrites(r, m) else std.AutoHashMapUnmanaged(Ast.StrId, void).empty;
    for (m.vars) |v| {
        // VAMS §7.3.6.4: an analog variable a digital expression reads is
        // declared, uninitialized, for the coordinator to write.
        if (r.analog.mixed and scope == 0) if (for (r.analog.a2d_reads) |n| {
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
        if (r.analog.mixed and (v.init != .none or ((v.ty != .integer or v.storage == .time) and !written.contains(v.name)))) continue;
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
    for (r.routines.rows.items[r.routines.base.get(scope).?..]) |*sub| {
        if (!sub.framed) {
            sub.frame = try frame(r, sub.decl, scope);
            sub.framed = true;
        }
        // §12.5: a task or function is a scope a hierarchical name reaches;
        // §10.2.1: "Automatic task items cannot be accessed by hierarchical
        // references" (`slot` names why).
        if (!sub.decl.automatic) try r.hier.instances.put(r.arena, .{ .scope = scope, .str = sub.decl.name }, sub.frame.scope);
        try blockScopes(r, sub.frame.scope, sub.decl.body);
    }
    for (m.discrete) |d| try blockScopes(r, scope, d.body);
    for (m.nets) |n| try declareNet(r, e, scope, n);
    // §6.5 the ports, after the body nets: a port net minted here is the one a
    // body `wire w;` on the same name was folded into by the parser.
    const grouped = !r.analog.mixed and expressionPorts(m);
    if (grouped) try groupPorts(r, e, m, scope, binds);
    for (if (grouped) m.ports[0..0] else m.ports, 0..) |p, i| {
        if (p.name == .none) continue; // IEEE 1364-2005 A.1.3 a null port connects nothing inside
        if (r.analog.mixed and continuous(r.file, p.discipline)) continue; // §7.2.1 continuous
        if (p.external_name != .none and !p.concat_rest) for (m.ports[0..i]) |q| if (q.external_name == p.external_name)
            return r.fail(p.main_tok, "§12.3.2: a port defined twice in the list of ports: `{s}`", .{r.file.str(p.external_name)});
        if (p.direction == .unspecified) return r.fail(p.main_tok, "§12.3.3: port `{s}` has no direction declaration", .{r.file.str(p.name)});
        // §12.3.3: "the range specification between the two declarations of
        // a port shall be identical".
        if (p.range) |a| if (p.type_range) |b| if (!try sameRange(r, a, b, p.main_tok))
            return r.fail(p.main_tok, "§12.3.3: the net declaration's range differs from its port declaration's: `{s}`", .{r.file.str(p.name)});
        // The same for a variable redeclaring the port. `integer` and `time`
        // write no range, so a port that writes one differs; a combined
        // `output reg [7:0] q` shares one range (and `output integer q`
        // writes none).
        // ponytail: `output q; integer q;` reads as the combined form.
        for (m.vars) |v| if (v.name == p.name and v.ty == .integer) {
            const differs = if (v.storage != .reg) p.range != null else if (p.range) |a| if (v.packed_range) |b|
                !try sameRange(r, a, b, p.main_tok)
            else
                true else v.packed_range != null;
            if (differs) return r.fail(v.main_tok, "§12.3.3: the variable declaration's range differs from its port declaration's: `{s}`", .{r.file.str(p.name)});
        };
        var bind = if (i < binds.len) binds[i] else PortBind.open;
        const width = try portWidth(r, p);
        // IEEE 1364-2005 §12.3.3: an output port "declared as a variable"
        // (`output q; reg q;`) is that variable, and it drives the net it
        // is connected to: one driver of it, as a continuous assignment is.
        if (r.hier.names.get(.{ .scope = scope, .str = p.name })) |var_slot| {
            // §12.3.3: the parser folded the first net declaration into the
            // port (`Port.typed`), so a net already bound here is a second
            // one, unless it is the entry a folded `wire p = e;` leaves for
            // its initializer.
            if (r.netlist.slot_nets.contains(var_slot)) for (m.nets) |n| if (n.name == p.name and n.init == .none and n.discipline == .none) return r.fail(n.main_tok, "duplicate digital variable", .{});
            if (p.direction != .output) return r.fail(p.main_tok, "§12.3.3: only an output port may be declared as a variable", .{});
            switch (bind) {
                .open => {},
                .collapse => |c| try e.wires.append(arena, .{
                    .net = c.net,
                    .scope = scope,
                    .source = .{
                        .bridge = .{
                            .src = var_slot,
                            .src_lo = 0,
                            .dst_lo = 0,
                            .width = @min(e.values.items[var_slot].width, e.nets.items[c.net].resolved.width),
                            // §12.3.9.2's widening (`sendPort`).
                            .ext = e.nets.items[c.net].resolved.width -| e.values.items[var_slot].width,
                            .sign_at = if (e.values.items[var_slot].signed) e.values.items[var_slot].width - 1 else null,
                        },
                    },
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
            // An inout joins the bits both sides have (§12.3.10).
            if (!merging and outer.resolved.width != width) {
                if (!ieee1364(r)) return r.fail(p.main_tok, size_mismatch, .{});
                const whole = try arena.dupe(Sink, &.{.{ .net = c.net, .lo = 0, .width = outer.resolved.width }});
                // §12.3.8: "A port that is declared as input (output) but
                // used as an output (input) or inout may be coerced to
                // inout"; iverilog coerces an input the module drives and an
                // output it does not, and so does VerA.
                const driven = assignsTo(r, m, p.name);
                bind = switch (p.direction) {
                    .input => if (driven) .{ .join = .{ .operands = whole, .tok = c.tok } } else .{ .receive = .{ .expr = c.expr, .scope = c.scope, .tok = c.tok } },
                    .output => if (!driven) .{ .join = .{ .operands = whole, .tok = c.tok } } else .{ .send = .{ .operands = whole, .tok = c.tok } },
                    .inout, .unspecified => .{ .join = .{ .operands = whole, .tok = c.tok } },
                };
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
                try r.decls.port_signed.put(arena, .{ .scope = scope, .str = p.name }, p.is_signed);
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
                const drive = Front.directive_events.DriveRegion.inForce(r.drives, r.starts[@min(p.main_tok, r.starts.len - 1)], .default);
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
                    if (r.lookup(c.scope, ex.strOf(ex.lhs(c.expr)))) |slot| if (r.netlist.slot_nets.get(slot)) |net| {
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
                    // IEEE 1364-2005 §12.3.10: a size mismatch joins the
                    // bits both sides have, rightmost first; the rest of
                    // either side connects nothing (iverilog's reading).
                    const n = @min(op.width, width - lo);
                    if (n != op.width and !ieee1364(r)) return r.fail(c.tok, size_mismatch, .{});
                    for (0..n) |j| try e.trans.append(arena, .{
                        .tran = .{ .a = at, .b = op.net, .a_bit = lo + @as(u32, @intCast(j)), .b_bit = op.lo + @as(u32, @intCast(j)) },
                        .scope = scope,
                        .tok = c.tok,
                    });
                    lo += n;
                }
                if (lo != width and !ieee1364(r)) return r.fail(c.tok, size_mismatch, .{});
            },
        }
    }
    // §10.4.2: "It is illegal to declare another object with the same name
    // as the function in the scope where the function is declared."
    for (r.routines.rows.items[r.routines.base.get(scope).?..]) |sub| if (r.hier.names.contains(.{ .scope = scope, .str = sub.decl.name }))
        return r.fail(sub.decl.main_tok, "§10.4.2: duplicate declaration of `{s}`, a task or function name in this scope", .{r.file.str(sub.decl.name)});
    try implicitNets(r, e, scope, m);
    // §3.8: every attribute value is a constant expression, judged once the
    // instance's names are all bound (a mixed module's are the analog
    // compile's to judge).
    if (!r.analog.mixed) try compile.checkAttributes(r, m.attrs, scope);
    const b = try bridged(r, e, m, scope);
    try declareDrivers(r, e, scope, .{ .assigns = m.assigns, .gates = b.gates, .pulls = b.pulls, .switches = b.switches }, b.lanes);
    try pathDelays(r, e, m, scope);
    for (b.instances) |*inst| try instantiate(r, e, scope, inst, depth);
    for (m.analog) |ab| if (isGenerate(r.file, m, ab.body)) try generate(r, e, m, scope, ab.body, depth);
}

/// Whether two declared `[msb:lsb]` ranges fold to the same bounds, as
/// §12.3.3 asks of a port's two declarations.
pub fn sameRange(r: *Run, a: Ast.Dim, b: Ast.Dim, tok: u32) Error!bool {
    assert(tok < r.starts.len);
    assert(a.msb != .none);
    assert(b.lsb != .none);
    return try r.declaredBound(a.msb, tok) == try r.declaredBound(b.msb, tok) and
        try r.declaredBound(a.lsb, tok) == try r.declaredBound(b.lsb, tok);
}

/// §5.10.4 a named event gets a slot so `-> e` and `@(e)` have a rendezvous
/// point on the waiter list; the stored value is never read or written.
pub fn declareEvents(r: *Run, events: []const Ast.EventDecl) Error!void {
    const g = r.growing.?;
    assert(r.scope < r.hier.scopes.items.len);
    for (events) |event| {
        const at: u32 = @intCast(g.items.len);
        try r.bind(event.name, at, event.main_tok);
        const count = try declareArray(r, at, event.dims, event.main_tok);
        if (count > std.math.maxInt(u32) - g.items.len) return r.fail(event.main_tok, "too many digital storage slots", .{});
        for (0..count) |i| {
            try g.append(r.arena, try filled(r.arena, 1, false, .x));
            try r.decls.events.put(r.arena, at + @as(u32, @intCast(i)), .{ .tok = event.main_tok, .scope = r.scope });
        }
        r.values = g.items;
        assert(r.values.len >= at + count);
    }
}

/// IEEE 1364-2005 §12.5 "each ... named begin-end or fork-join block shall
/// define a new branch of the hierarchy": the named blocks of statement `s`,
/// run in `scope`, that declare something or enclose one that does, each a
/// scope with its declarations, made in pass one so a hierarchical name
/// compiled first (`b.mod_1.x` from a sibling block) finds them. `compile`
/// enters the scope `block_scopes` records.
pub fn blockScopes(r: *Run, scope: u32, s: Ast.StmtId) Error!void {
    assert(scope < r.hier.scopes.items.len);
    if (s == .none) return;
    // One frame per statement level, as deep as the source nests.
    if (deep.exhausted()) return r.deepFail(r.file.stmtTok(s));
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
        .block => |b| if (b.name != .none and !r.hier.block_scopes.contains(.{ .scope = scope, .stmt = s }) and declares(r.file, s)) {
            inner = try blockScope(r, scope, s);
        },
        else => {}, // else: only a block is a scope
    }
    assert(inner < r.hier.scopes.items.len);
    try r.file.stmtEdges(s, W{ .r = r, .scope = inner });
}

/// Block `s`'s scope under `scope`, its parameters, events and variables
/// declared there. Pass two calls it for an automatic activation's copy.
pub fn blockScope(r: *Run, scope: u32, s: Ast.StmtId) Error!u32 {
    assert(scope < r.hier.scopes.items.len);
    const b = r.file.stmt(s).block;
    const tok = r.file.stmtTok(s);
    const at = try newScope(r, tok);
    try r.hier.scopes.append(r.arena, .{ .parent = scope, .name = b.name, .def = r.hier.scopes.items[scope].def, .lexical = true });
    try r.hier.block_scopes.put(r.arena, .{ .scope = scope, .stmt = s }, at);
    if (b.name != .none) try r.hier.instances.put(r.arena, .{ .scope = scope, .str = b.name }, at);
    const saved = r.scope;
    defer r.scope = saved;
    r.scope = at;
    try declareParams(r, at, b.params, &.{});
    try declareEvents(r, b.events);
    const automatic = r.routines.auto_scopes.contains(scope);
    if (automatic) try r.routines.auto_scopes.put(r.arena, at, {});
    for (b.vars) |v| {
        if (v.init != .none) return r.fail(v.main_tok, "an initialized block-local variable is not implemented", .{});
        const slot = try mintVar(r, v);
        if (automatic) try r.routines.auto_slots.put(r.arena, slot, {});
    }
    assert(r.hier.scopes.items[at].parent == scope);
    assert(r.hier.block_scopes.get(.{ .scope = scope, .stmt = s }).? == at);
    return at;
}

// ---- private ----

/// Whether one of `m`'s continuous assignments or gate outputs drives
/// `name` (whole, or a select of it), the use §12.3.8's coercion reads.
// ponytail: an instance's output port driving `name` is not looked for.
fn assignsTo(r: *const Run, m: *const Ast.ModuleDecl, name: Ast.StrId) bool {
    assert(name != .none);
    assert(r.file.modules.len > 0);
    for (m.assigns) |a| if (namesIn(r, a.target, name)) return true;
    for (m.gates) |g| if (namesIn(r, g.out, name)) return true;
    return false;
}

fn namesIn(r: *const Run, e: Ast.ExprId, name: Ast.StrId) bool {
    assert(e != .none);
    assert(name != .none);
    const ex = &r.file.exprs;
    return switch (ex.tag(e)) {
        .ident => ex.strOf(e) == name,
        .index => namesIn(r, ex.lhs(e), name),
        .concat => for (ex.args(e)) |x| {
            if (namesIn(r, x, name)) break true;
        } else false,
        else => false, // else: no other lvalue form names a net
    };
}

/// IEEE 1364-2005 §4.5: an undeclared identifier in the terminal list of a
/// module or primitive instance, or on the left of a continuous assignment,
/// is an implicit scalar net of the `default_nettype in force there (§19.2).
/// A terminal's identifiers count wherever they stand in its expression
/// (`.r(!r)`); an assignment's target only as the whole of it.
fn implicitNets(r: *Run, e: *Elab, scope: u32, m: *const Ast.ModuleDecl) Error!void {
    assert(scope < r.hier.scopes.items.len);
    assert(r.growing != null);
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
    assert(scope < r.hier.scopes.items.len);
    const ex = &r.file.exprs;
    if (x == .none) return;
    if (ex.tag(x) == .ident) return implicitNet(r, e, scope, m, x);
    assert(ex.tag(x) != .ident);
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(x, &buf)) |c| try implicitTerminal(r, e, scope, m, c);
}

fn implicitNet(r: *Run, e: *Elab, scope: u32, m: *const Ast.ModuleDecl, x: Ast.ExprId) Error!void {
    assert(scope < r.hier.scopes.items.len);
    const ex = &r.file.exprs;
    if (x == .none or ex.tag(x) != .ident) return;
    const tok = ex.mainTok(x);
    if (r.hier.names.contains(.{ .scope = scope, .str = ex.strOf(x) })) {
        // §4.5: "has not been declared previously". A net declared after
        // this use was already implicitly declared here, so it declares
        // the name a second time.
        for (m.nets) |n| if (n.name == ex.strOf(x) and n.main_tok > tok and n.discipline == .none) return r.fail(n.main_tok, "duplicate digital variable", .{});
        return;
    }
    const t = Front.directive_events.NetTypeRegion.inForce(r.nettypes, r.starts[@min(tok, r.starts.len - 1)], .default);
    // `default_nettype none: the name stays undeclared.
    const kind = std.meta.stringToEnum(Ast.NetKind, @tagName(t)) orelse return;
    _ = try mintNet(r, e, kind, 1, false, ex.strOf(x), tok);
    assert(r.hier.names.contains(.{ .scope = scope, .str = ex.strOf(x) }));
    // §4.5's implicit net is the scope's from its start, so a terminal
    // before the one that declares it reads it (`lookupAt`).
    try r.hier.bound_at.put(r.arena, .{ .scope = scope, .str = ex.strOf(x) }, 0);
}

/// Does statement `s` hold a named block with declarations of its own?
fn declares(file: *const Ast.SourceFile, s: Ast.StmtId) bool {
    assert(s != .none);
    assert(file.stmt(s) == .block); // `blockScopes` asks of a named block only.
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

test "blockScopes refuses a statement nest past its thread's stack with E0241, never a crash" {
    // Oracle: deep_stack's contract: a walk on a thread `runGuarded` did not
    // start (this test's; a host's) is given 4 MiB and refused by name past
    // it, never a segfault; while a design is elaborated that refusal is
    // E0241, "nested deeper than memory allows". `elaborate` walks the nest
    // on its own reservation; here the same walk runs on the caller's stack.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = 100_000;
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "module m; initial ");
    for (0..n) |_| try src.appendSlice(a, "begin ");
    try src.appendSlice(a, "$display(\"ok\");");
    for (0..n) |_| try src.appendSlice(a, " end");
    try src.appendSlice(a, " endmodule");
    var bag = diag.Bag.init(a);
    var out = std.Io.Writer.Allocating.init(a);
    var r = try root.elaborate(a, src.items, .{}, &bag, &out.writer);
    r.diag_stage = .lower; // As in pass one.
    try std.testing.expectError(error.DigitalFailed, blockScopes(&r, 0, r.file.modules[0].discrete[0].body));
    var messages = std.Io.Writer.Allocating.init(a);
    try diag.render(&bag, &messages.writer, .{});
    try std.testing.expect(std.mem.find(u8, messages.written(), "E0241") != null);
    try std.testing.expect(std.mem.find(u8, messages.written(), "exhausts the") != null);
}
