//! An instance's port connections in, each port bound to the net or expression it connects out, by position or by name, groups of instance arrays split.
//! Cites: IEEE 1364-2005 §12.1.2, §12.3, §12.3.6, §12.3.9.
//!
//! Contents:
//! - `pub const SinkOf = enum`
//! - `pub fn expressionPorts(m: *const Ast.ModuleDecl) bool`
//! - `pub fn nthGroup(m: *const Ast.ModuleDecl, n: usize) ?usize`
//! - `pub fn groupByName(m: *const Ast.ModuleDecl, name: Ast.StrId) ?usize`
//! - `pub fn groupPorts(r: *Run, e: *Elab, m: *const Ast.ModuleDecl, scope: u32, binds: []const PortBind) Error!void`
//! - `pub fn portByName(m: *const Ast.ModuleDecl, name: Ast.StrId) ?usize`
//! - `pub fn putRange(r: *Run, slot: u32, range: Ast.Dim, tok: u32) Error!void`
//! - `pub fn portWidth(r: *Run, p: Ast.Port) Error!u32`
//! - `pub fn childPortWidth(r: *Run, child: u32, p: Ast.Port) Error!u32`
//! - `pub fn bindPort(r: *Run, e: *Elab, port: Ast.Port, conn: Ast.PortConn, scope: u32) Error!PortBind`
//! - `pub fn concatLeaves(r: *Run, e: Ast.ExprId, out: *std.ArrayList(Ast.ExprId)) Error!void`
//! - `pub fn sink(r: *Run, e: *Elab, arg: Ast.ExprId, tok: u32, comptime who: SinkOf) Error!Sink`
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
const elab_drivers = @import("elab_drivers.zig");
const elab_params = @import("elab_params.zig");
const elab_slots = @import("elab_slots.zig");
const Elab = elab.Elab;
const PortBind = elab.PortBind;
const Sink = elab.Sink;
const Sinks = elab.Sinks;
const continuous = elab_drivers.continuous;
const mintNet = elab_slots.mintNet;
const names = elab_params.names;
const netSlot = elab_slots.netSlot;

/// What drives a structural net expression: an output port, a continuous
/// assignment (§6.1.1) or a gate's output terminal (A.3.3), which admit the
/// same forms.
pub const SinkOf = enum { port, assign, gate };

/// IEEE 1364-2005 §12.3.2: does `m` use A.1.3's port expressions beyond one
/// whole net per port (a concatenation, a bit- or part-select, a name more
/// than one port reference names)? Its ports are then connected one external
/// port at a time (`groupPorts`).
pub fn expressionPorts(m: *const Ast.ModuleDecl) bool {
    if (m.ports.len != 0) assert(!m.ports[0].concat_rest); // A concatenation continues a port before it.
    for (m.ports, 0..) |p, i| {
        if (p.name == .none) continue; // A.1.3: null ports name no shared internal net
        if (p.select != null or p.concat_rest) return true;
        for (m.ports[0..i]) |q| if (q.name == p.name) return true;
    }
    return false;
}

/// The first reference of the `n`th external port.
pub fn nthGroup(m: *const Ast.ModuleDecl, n: usize) ?usize {
    var i: usize = 0;
    var k: usize = 0;
    while (i < m.ports.len) : (i = groupEnd(m, i)) {
        if (k == n) return i;
        k += 1;
        assert(k <= m.ports.len); // A group holds one port at least.
    }
    assert(k <= n);
    return null;
}

/// The first reference of the external port named `name`: its `.name(...)`,
/// or a lone whole-net reference's own name (§12.3.6).
pub fn groupByName(m: *const Ast.ModuleDecl, name: Ast.StrId) ?usize {
    var i: usize = 0;
    while (i < m.ports.len) : (i = groupEnd(m, i)) {
        const p = m.ports[i];
        const own = if (p.external_name != .none) p.external_name else if (groupEnd(m, i) == i + 1 and p.select == null) p.name else .none;
        if (own == name) return i;
        assert(!p.concat_rest); // Groups are walked by their heads.
    }
    assert(i == m.ports.len);
    return null;
}

/// IEEE 1364-2005 §12.3.2/§12.3.3 the ports of an expression-ported module:
/// one net (or output variable) per port name, then each external port's
/// connection split among its references, leftmost the most significant.
pub fn groupPorts(r: *Run, e: *Elab, m: *const Ast.ModuleDecl, scope: u32, binds: []const PortBind) Error!void {
    assert(scope < r.hier.scopes.items.len);
    for (m.ports, 0..) |p, i| {
        if (p.name == .none) continue; // A.1.3: a null port declares no internal net
        if (for (m.ports[0..i]) |q| {
            if (q.name == p.name) break true;
        } else false) continue;
        if (p.direction == .unspecified) return r.fail(p.main_tok, "§12.3.3: port `{s}` has no direction declaration", .{r.file.str(p.name)});
        if (r.hier.names.contains(.{ .scope = scope, .str = p.name })) {
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
        assert(end > i);
        i = end;
    }
}

/// A port by the name a named connection may use: its own, when the header
/// gave it no external name. A concatenation with no external name has none
/// (§12.3.6: it connects by position only).
pub fn portByName(m: *const Ast.ModuleDecl, name: Ast.StrId) ?usize {
    assert(name != .none);
    for (m.ports, 0..) |p, k| {
        if (p.concat_rest or (k + 1 < m.ports.len and m.ports[k + 1].concat_rest)) continue;
        if (if (p.external_name == .none) p.name == name else p.external_name == name) return k;
    }
    return null;
}

/// Records `slot`'s declared `[msb:lsb]` (`Run.typing.vec_ranges`).
pub fn putRange(r: *Run, slot: u32, range: Ast.Dim, tok: u32) Error!void {
    assert(tok < r.starts.len);
    assert(range.msb != .none);
    try r.typing.vec_ranges.put(r.arena, slot, .{ .msb = try r.declaredBound(range.msb, tok), .lsb = try r.declaredBound(range.lsb, tok) });
    assert(r.typing.vec_ranges.contains(slot));
}

/// A port's declared width, evaluated in the scope being elaborated: a
/// child port's range is read before the child's parameters exist.
pub fn portWidth(r: *Run, p: Ast.Port) Error!u32 {
    assert(p.main_tok < r.starts.len);
    if (p.kind == .wreal) return 64; // VAMS §3.7: a wreal holds a real's 64 bits.
    const w = if (p.range orelse p.type_range) |range| try r.declaredWidth(range, p.main_tok) else 1;
    assert(w >= 1);
    return w;
}

/// `portWidth` of a child's port, its range read in `child`, the child
/// instance's scope with its parameters already valued (`declareHead`), not
/// in the parent's, where the same name may be another parameter or none.
pub fn childPortWidth(r: *Run, child: u32, p: Ast.Port) Error!u32 {
    assert(child < r.hier.scopes.items.len);
    const saved = r.scope;
    defer assert(r.scope == saved); // Runs after the restore below.
    defer r.scope = saved;
    r.scope = child;
    return portWidth(r, p);
}

/// §6.5.7 one port connection, decided in the PARENT's scope.
pub fn bindPort(r: *Run, e: *Elab, port: Ast.Port, conn: Ast.PortConn, scope: u32) Error!PortBind {
    assert(scope < r.hier.scopes.items.len);
    if (conn.expr == .none) return .open;
    const ex = &r.file.exprs;
    // §12.3.7: "The real data type shall not be directly connected to a port."
    if (ex.tag(conn.expr) == .ident) if (r.lookup(scope, ex.strOf(conn.expr))) |at| if (r.decls.reals.contains(at) and !r.netlist.slot_nets.contains(at))
        return r.exprFail(conn.expr, "§12.3.7: a real cannot be connected to a port");
    // One whole net on the outside is a collapse, the only arm under which
    // the child's drive strengths reach the parent's resolution unchanged
    // (IEEE 1364 clause 12: a port is a connection). `declare` size-checks
    // it once the port's own width is known.
    assert(conn.expr != .none);
    if (ex.tag(conn.expr) == .ident) {
        if (r.netlist.slot_nets.get(try r.scalarSlot(conn.expr))) |net| return .{ .collapse = .{ .net = net, .expr = conn.expr, .scope = scope, .tok = conn.main_tok } };
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
pub fn concatLeaves(r: *Run, e: Ast.ExprId, out: *std.ArrayList(Ast.ExprId)) Error!void {
    assert(e != .none);
    const ex = &r.file.exprs;
    if (ex.tag(e) != .concat) return out.append(r.arena, e);
    const before = out.items.len;
    for (ex.args(e)) |x| try concatLeaves(r, x, out);
    assert(out.items.len >= before + ex.args(e).len); // One leaf per operand at least.
}

/// IEEE 1364-2005 §12.3.9.2 one operand of a structural net expression: a
/// net, a net array element, or a constant bit-select or part-select of a
/// vector net.
pub fn sink(r: *Run, e: *Elab, arg: Ast.ExprId, tok: u32, comptime who: SinkOf) Error!Sink {
    assert(arg != .none);
    assert(tok < r.starts.len);
    const ex = &r.file.exprs;
    r.values = e.values.items;
    const lvalue = " a net, a net array element, a constant bit-select or part-select of a vector net, or a concatenation of them";
    const not_net, const refused = switch (who) {
        .port => .{ "an output port can only drive a net", "§12.3.9.2: an output port connects to" ++ lvalue },
        .assign => .{ "a continuous assignment can only drive a net", "§6.1.1: a continuous assignment connects to" ++ lvalue },
        .gate => .{ "a gate's output terminal must be a net", "A.3.3: a gate's output terminal is a net_lvalue:" ++ lvalue },
    };
    // A.8.5's hierarchical_net_identifier: a net named through a scope
    // (`what[i].slice`, iverilog's pr1755629) is a net as much as a local one.
    if (ex.tag(arg) == .ident or ex.tag(arg) == .hier_ident or try r.indexedArray(arg) != null) {
        const net = r.netlist.slot_nets.get(try netSlot(r, arg, tok)) orelse return r.exprFail(arg, not_net);
        return .{ .net = net, .lo = 0, .width = e.nets.items[net].resolved.width };
    }
    // §6.1.1/A.8.5: the select may stand on a net array element, `b[i][j]`.
    if (ex.tag(arg) != .index or (ex.tag(ex.lhs(arg)) != .ident and ex.tag(ex.lhs(arg)) != .hier_ident and try r.indexedArray(ex.lhs(arg)) == null)) return r.exprFail(arg, refused);
    const rg = ex.rhs(arg);
    const index = switch (ex.tag(rg)) {
        .range => Ast.ExprId.none,
        .indexed_range => ex.lhs(rg),
        else => rg, // else: a bit-select's index
    };
    try compile.checkExpr(r, arg);
    if (index != .none and !compile.constantExpression(r, index)) return r.exprFail(arg, refused);
    const net = r.netlist.slot_nets.get(try netSlot(r, ex.lhs(arg), tok)) orelse return r.exprFail(arg, not_net);
    const sel = (try evaluate.selection(r, r.arena, arg)) orelse return r.exprFail(arg, "§12.3.9.2: the select's index is x or z");
    if (sel.first < 0 or sel.first + sel.count > e.nets.items[net].resolved.width) return r.exprFail(arg, "§12.3.9.2: the select is outside its net");
    return .{ .net = net, .lo = @intCast(sel.first), .width = sel.count };
}

// ---- private ----

/// One past the last reference of the external port starting at `i`.
fn groupEnd(m: *const Ast.ModuleDecl, i: usize) usize {
    assert(i < m.ports.len);
    var end = i + 1;
    while (end < m.ports.len and m.ports[end].concat_rest) end += 1;
    assert(end <= m.ports.len);
    return end;
}

/// One external port's connection `conn` (made in `parent`) split among its
/// references `refs` (declared in `scope`). An input reference receives its
/// bits of the connected expression, an output one drives its bits of the
/// connected nets, and an inout one is joined to them bit by bit, as a
/// `tran` joins two nets (§7.6).
fn connectGroup(r: *Run, e: *Elab, refs: []const Ast.Port, conn: Ast.PortConn, parent: u32, scope: u32) Error!void {
    assert(scope < r.hier.scopes.items.len);
    if (conn.expr == .none) return;
    assert(parent < r.hier.scopes.items.len);
    assert(refs.len >= 1);
    const Ref = struct { slot: u32, lo: u32, width: u32, at: u32, dir: Ast.Direction };
    const list = try r.arena.alloc(Ref, refs.len);
    var total: u32 = 0;
    r.scope = scope;
    var k = refs.len;
    while (k != 0) {
        k -= 1;
        const p = refs[k];
        const slot = r.hier.names.get(.{ .scope = scope, .str = p.name }).?; // `groupPorts` declared every name
        var lo: u32 = 0;
        var w = e.values.items[slot].width;
        if (p.select) |sel| {
            const range = r.typing.vec_ranges.get(slot) orelse VecRange{ .msb = @as(i64, w) - 1, .lsb = 0 };
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
        const dst = r.netlist.slot_nets.get(ref.slot) orelse return r.fail(conn.main_tok, "§12.3.3: an input port reference names a net", .{});
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
                const net = r.netlist.slot_nets.get(ref.slot) orelse return r.fail(conn.main_tok, "§12.3.3: an inout port reference names a net", .{});
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
