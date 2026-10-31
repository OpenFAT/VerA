//! A port connection or a cell's ports in, the W-coded warnings §12.3 asks a tool to give out (width mismatch, a port driven from inside).
//! Cites: IEEE 1364-2005 §12.3.8, §12.3.9.
//!
//! Contents:
//! - `pub fn sendPort(r: *Run, e: *Elab, operands: []const Sink, tok: u32, src: u32, width: u32, scope: u32) Error!void`
//! - `pub fn warnPort(r: *Run, p: Ast.Port, external: Ast.NetKind) Error!bool`
//! - `pub fn internalDominates(internal: Ast.NetKind, external: Ast.NetKind) bool`
//! - `pub fn warnCell(internal: Ast.NetKind, external: Ast.NetKind) bool`
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
const Elab = elab.Elab;
const Sink = elab.Sink;
const ieee1364 = elab_params.ieee1364;
const size_mismatch = elab_declare.size_mismatch;

/// §12.3.9.2 an output port's value, slot `src` of `width` bits, bridged
/// into the operands of the structural net expression it connects to (or a
/// hidden net into a continuous assignment's concatenated target).
/// §6.5.7.1 joins them highest-order first, so the rightmost operand takes
/// the port's low bits.
pub fn sendPort(r: *Run, e: *Elab, operands: []const Sink, tok: u32, src: u32, width: u32, scope: u32) Error!void {
    var lo: u32 = 0;
    var k = operands.len;
    while (k != 0) {
        k -= 1;
        const op = operands[k];
        // Under IEEE 1364-2005 §12.3.9.2 the connection is a continuous
        // assignment of the port to the operands, which §5.6 widens (zero,
        // or a signed port's sign) and truncates: operands past the port's
        // width take the widening, a port past theirs sends its low bits.
        const copy = @min(op.width, width - lo);
        if (copy != op.width and !ieee1364(r)) return r.fail(tok, size_mismatch, .{});
        try e.wires.append(r.arena, .{
            .net = op.net,
            .scope = scope,
            .source = .{ .bridge = .{
                .src = src,
                .src_lo = lo,
                .dst_lo = op.lo,
                .width = copy,
                .ext = op.width - copy,
                .sign_at = if (e.values.items[src].signed and width != 0) width - 1 else null,
            } },
            .tok = tok,
        });
        lo += copy;
    }
    if (lo != width and !ieee1364(r)) return r.fail(tok, size_mismatch, .{});
}

/// IEEE 1364-2005 §12.3.10 Table 12-1's "warn" (W1160) for port `p` joined
/// to a net of type `external`, whole or through a select. Returns whether
/// it warned.
pub fn warnPort(r: *Run, p: Ast.Port, external: Ast.NetKind) Error!bool {
    if (!warnCell(p.kind, external)) return false;
    const at = r.starts[@min(p.main_tok, r.starts.len - 1)];
    try r.bag.add(.lower, .W1160, .{ .start = at, .end = at }, "§12.3.10: a `{s}` port joined to a `{s}` net is a Table 12-1 warn cell of the net type table", .{ @tagName(p.kind), @tagName(external) });
    return true;
}

/// IEEE 1364-2005 §12.3.10 Table 12-1's "int" cells: does the internal (port)
/// net type dominate the external one? Every other cell is "ext".
pub fn internalDominates(internal: Ast.NetKind, external: Ast.NetKind) bool {
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
pub fn warnCell(internal: Ast.NetKind, external: Ast.NetKind) bool {
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
