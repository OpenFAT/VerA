//! A UDP instance in, its §8 table checked and bound out.
//! Cites: IEEE 1364-2005 §8.1 to §8.6.
//!
//! Contents:
//! - `pub fn findUdp(file: *const Ast.SourceFile, name: Ast.StrId) ?*const Ast.UdpDecl`
//! - `pub fn declareUdp(r: *Run, e: *Elab, scope: u32, inst: *const Ast.Instance, u: *const Ast.UdpDecl) Error!void`
//! - `pub fn checkUdp(r: *Run, u: *const Ast.UdpDecl) Error!void`
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
const elab_ports = @import("elab_ports.zig");
const Elab = elab.Elab;
const sink = elab_ports.sink;

pub fn findUdp(file: *const Ast.SourceFile, name: Ast.StrId) ?*const Ast.UdpDecl {
    assert(name != .none);
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
pub fn declareUdp(r: *Run, e: *Elab, scope: u32, inst: *const Ast.Instance, u: *const Ast.UdpDecl) Error!void {
    assert(scope < r.hier.scopes.items.len);
    const tok = inst.main_tok;
    try r.hier.prim_names.put(r.arena, .{ .scope = scope, .str = inst.name }, inst.main_tok);
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
    assert(inst.ports.len == u.ports.len);
}

/// The IEEE 1364-2005 §8.1 rules on a UDP declaration itself.
pub fn checkUdp(r: *Run, u: *const Ast.UdpDecl) Error!void {
    const tok = u.main_tok;
    assert(tok < r.starts.len);
    assert(u.ports.len > 0);
    if (u.outputs != 1) return r.fail(tok, "§8.1.1: a UDP has exactly one output port", .{});
    if (u.output != u.ports[0]) return r.fail(tok, "§8.1.1: the output port shall be the first port of a UDP", .{});
    // A.5.1 udp_port_list: the output, then at least one input. `udpRows`
    // splits each table row into `ports.len - 1` input fields.
    if (u.ports.len < 2) return r.fail(tok, "A.5.1: a UDP has an output port and at least one input port", .{});
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
