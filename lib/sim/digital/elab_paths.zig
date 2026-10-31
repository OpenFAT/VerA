//! A `specify` block's module paths in, the path delay tables and pulse limits of their destinations out.
//! Cites: IEEE 1364-2005 §14.3, §14.6.
//!
//! Contents:
//! - `pub fn pathDelays(r: *Run, e: *Elab, m: *const Ast.ModuleDecl, scope: u32) Error!void`
//! - `pub fn pathTable(r: *Run, delays: []const Ast.ExprId, tok: u32) Error!net_mod.PathTable`
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
const Elab = elab.Elab;

/// IEEE 1364-2005 §14.2 the module paths of `m` in instance `scope`, one
/// `net.Path` row per source on each destination net: which path's delay
/// times a transition is decided when it is scheduled (§14.3.3,
/// `resolution.pathDelay`). A destination's select is read as its whole
/// net, and a parallel path as a full one: the net takes the smallest delay
/// its changed bits select.
pub fn pathDelays(r: *Run, e: *Elab, m: *const Ast.ModuleDecl, scope: u32) Error!void {
    assert(scope < r.hier.scopes.items.len);
    // ponytail: per-bit destinations would time each bit on its own.
    const ex = &r.file.exprs;
    r.scope = scope;
    for (m.paths) |p| {
        if (p.edge == .edge) return r.fail(p.main_tok, "§14.2.3: a module path's edge is posedge or negedge", .{});
        const table = try pathTable(r, p.delays, p.main_tok);
        for (p.outs) |o| {
            const dst = if (ex.tag(o) == .index) ex.lhs(o) else o;
            const at = try r.scalarSlot(dst);
            // §14.2.1: the destination is "a net or variable that is
            // connected to a module output port or inout port". A variable
            // port reaches its outside through its §12.3.3 bridge, so the
            // path times the net that bridge drives; an unconnected one has
            // no outside to time.
            var dests: std.ArrayList(u32) = .empty;
            if (r.netlist.slot_nets.get(at)) |net| {
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
                const lim = try pulseLimits(r, m, ex.strOf(src_expr), ex.strOf(dst));
                try rows.append(r.arena, .{ .src = src, .src_bit = bit, .edge = p.edge, .cond = p.cond, .ifnone = p.ifnone, .scope = scope, .table = table, .delays = p.delays, .tok = p.main_tok, .reject = lim[0], .err = lim[1] });
            }
            for (dests.items) |net| {
                const n = &e.nets.items[net];
                if (n.cold == net_mod.no_cold) {
                    n.cold = @intCast(e.net_cold.items.len);
                    try e.net_cold.append(r.arena, .{});
                }
                const cold = &e.net_cold.items[n.cold];
                cold.paths = try std.mem.concat(r.arena, net_mod.Path, &.{ cold.paths, rows.items });
                // §14.6.4: the pulse style and showcancelled declarations
                // naming this output, the last of each pair winning.
                for (m.pulses) |pc| for (pc.outs) |o2| if (ex.strOf(if (ex.tag(o2) == .index) ex.lhs(o2) else o2) == ex.strOf(dst)) switch (pc.kind) {
                    .onevent, .ondetect => cold.ondetect = pc.kind == .ondetect,
                    .showcancelled, .noshowcancelled => cold.showcancelled = pc.kind == .showcancelled,
                    .limits => {},
                };
            }
        }
    }
    assert(r.scope == scope);
}

/// IEEE 1364-2005 §14.3.1 a path's A.7.4 delay expressions, folded in the
/// current scope (`r.scope`) to its transition table. "If the path delay
/// expression results in a negative value, it shall be treated as zero."
pub fn pathTable(r: *Run, delays: []const Ast.ExprId, tok: u32) Error!net_mod.PathTable {
    assert(tok < r.starts.len);
    assert(delays.len <= 12); // A.7.4: at most twelve path delay expressions.
    var ticks: [12]u64 = undefined;
    for (delays, ticks[0..delays.len]) |d, *t| {
        const v = try r.constant(d, tok);
        const negative = !compile.typeOf(r, d).real and v.signed and (v.asInt() orelse 0) < 0;
        t.* = if (negative) 0 else (try r.declaredDelay3(.{ .rise = d, .fall = d, .off = d }, tok)).rise;
    }
    return net_mod.pathTable(ticks[0..delays.len]);
}

// ---- private ----

/// IEEE 1364-2005 §14.6.1 the reject and error limits of `m`'s path from
/// `in` to `out`: `PATHPULSE$in$out`, else the module's `PATHPULSE$`, else
/// none (the default, the path delay). "If only the reject limit value is
/// specified, it shall apply to both the reject and error limits."
fn pulseLimits(r: *Run, m: *const Ast.ModuleDecl, in: Ast.StrId, out: Ast.StrId) Error![2]?u64 {
    assert(in != .none);
    assert(out != .none);
    const specific = try std.fmt.allocPrint(r.arena, "PATHPULSE${s}${s}", .{ r.file.str(in), r.file.str(out) });
    var pick: ?Ast.PulseControl = null;
    for (m.pulses) |pc| {
        if (pc.kind != .limits) continue;
        const name = r.file.str(pc.name);
        if (std.mem.eql(u8, name, specific)) pick = pc else if (std.mem.eql(u8, name, "PATHPULSE$") and (pick == null or std.mem.eql(u8, r.file.str(pick.?.name), "PATHPULSE$"))) pick = pc;
    }
    const pc = pick orelse return .{ null, null };
    const reject = (try r.declaredDelay3(.{ .rise = pc.reject, .fall = pc.reject, .off = pc.reject }, pc.main_tok)).rise;
    const err = if (pc.err == .none) reject else (try r.declaredDelay3(.{ .rise = pc.err, .fall = pc.err, .off = pc.err }, pc.main_tok)).rise;
    return .{ reject, @max(reject, err) };
}
