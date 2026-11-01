//! A `static` plan's settle nodes -> the settle event's Zig functions: the
//! nodes in topological order, 64 to a dirty word, each word a function of
//! its own, and `fn val<n>` of every pure node (a continuous assignment
//! that reads only nets and variables), which its process and the settle
//! event both store.
//! Cites: IEEE 1364-2005 §6.1 (a continuous assignment's value), §7.8.5
//! (gate values), §11.4.2 (active events in any order).
//!
//! Contents:
//! - `pub fn pureNodes(em: *Emitter, node_pc: []const u32) Error![]const bool`
//! - `pub fn settleFunctions(em: *Emitter, p: plan.Plan, entry_of: []const ?u32) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Emitter = @import("Emitter.zig");
const Error = Emitter.Error;
const assign = @import("assign.zig");
const drivers = @import("drivers.zig");
const plan = @import("plan.zig");
const plane_words = @import("plane_words.zig");
const processes = @import("processes.zig");

/// Returns per settle node whether its pc continuously assigns a value that
/// reads only nets and variables, of a net that is not a real.
pub fn pureNodes(em: *Emitter, node_pc: []const u32) Error![]const bool {
    const pure_nodes = try em.arena.alloc(bool, node_pc.len);
    for (pure_nodes, node_pc) |*x, pc| x.* = pureNode(em, pc);
    assert(pure_nodes.len == node_pc.len);
    return pure_nodes;
}

/// Writes `fn settle`, `fn settle<w>` per dirty word, and `fn val<n>` of
/// every pure node. `entry_of` names each pc's process function. Reads
/// `em.pure_nodes`, set from `pureNodes` first. A word gets the view's
/// fields and rebuilds it: passed whole, the view is read through a pointer
/// again after every store; and since Zig's compile time grows faster than
/// a function's size, each word is a function of its own.
pub fn settleFunctions(em: *Emitter, p: plan.Plan, entry_of: []const ?u32) Error!void {
    assert(p.node_pc.len != 0);
    assert(em.pure_nodes.len == p.node_pc.len);
    try em.print("fn settle(s: rt.View) rt.Error!void {{\n", .{});
    for (0..(p.node_pc.len + 63) / 64) |w| try em.print("    if (s.dirty[{d}] != 0) try @call(.never_inline, settle{d}, .{{ s.s, s.v, s.x, s.dirty }});\n", .{ w, w });
    try em.print("    s.s.settle = .idle;\n}}\n\n", .{});
    var lo: usize = 0;
    while (lo < p.node_pc.len) : (lo += 64) {
        try em.print("fn settle{d}(st: *S, v: [*]u64, x: [*]u64, dirty: [*]u64) rt.Error!void {{\n    @setEvalBranchQuota(1 << 30);\n", .{lo / 64});
        try em.print("    const s: rt.View = .{{ .s = st, .v = v, .x = x, .dirty = dirty }};\n", .{});
        for (p.node_pc[lo..@min(lo + 64, p.node_pc.len)], lo..) |pc, n| try settleNode(em, p, pc, @intCast(n), entry_of[pc].?);
        try em.print("    s.dirty[{d}] = 0;\n}}\n\n", .{lo / 64});
    }
    for (p.node_pc, em.pure_nodes, 0..) |pc, pure_node, n| if (pure_node) try nodeValue(em, pc, @intCast(n));
}

// ---- private ----

/// Whether the node at `pc` continuously assigns a value that reads only
/// nets and variables, of a net that is not a real.
fn pureNode(em: *Emitter, pc: u32) bool {
    const r = em.r;
    const i = switch (r.program.code.items[pc]) {
        .continuous => |i| i,
        else => return false, // else: an `always @*` node, whose body may do anything
    };
    assert(i < r.netlist.drivers.len);
    const d = r.netlist.drivers[i];
    return switch (d.source) {
        .expr => |x| pure(em, x.e) and !r.decls.reals.contains(r.netlist.nets[d.net].slot),
        .gate => true,
        .bridge, .udp, .mos, .pull => false,
    };
}

/// Whether `e` reads only nets and variables: no system or user function,
/// whose value or effect a re-evaluation could change.
fn pure(em: *Emitter, e: Ast.ExprId) bool {
    assert(e != .none);
    const ex = &em.r.file.exprs;
    switch (ex.tag(e)) {
        .sys_call, .call => return false,
        else => {}, // else: every other form is pure when its operands are
    }
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (c != .none and !pure(em, c)) return false;
    return true;
}

/// Node `n`, whose evaluation starts at `pc` in `fn proc<entry>`, in the
/// settle event. A pure node runs whenever a node of its word is dirty:
/// with no operand changed it computes the value its net already holds, and
/// storing that changes nothing (§6.1), so its own dirty bit need not be
/// tested. Any other node runs when its bit says an input changed.
fn settleNode(em: *Emitter, p: plan.Plan, pc: u32, n: u32, entry: u32) Error!void {
    const r = em.r;
    assert(n < p.node_pc.len);
    if (!em.pure_nodes[n]) return em.print("    if (s.take({d})) try proc{d}(s.s, {d});\n", .{ n, entry, pc });
    const slot = r.netlist.nets[r.netlist.drivers[r.program.code.items[pc].continuous].net].slot;
    if (!em.watched[slot]) return em.print("    try M.set(s, {d}, val{d}(s), {f});\n", .{ em.planes.off[slot], n, plane_words.full(em.slotWidth(slot)) });
    var wakes = em.reach[slot];
    wakes.comb = false;
    try em.print("    try M.putNode(s, {f}, {d}, {d}, val{d}(s), &.{{", .{ assign.fmtReach(wakes), slot, em.planes.off[slot], n });
    // A pure reader in this node's own dirty word runs after it anyway.
    for (p.comb[p.comb_start[slot]..p.comb_start[slot + 1]]) |e| if (e.node / 64 != n / 64 or !em.pure_nodes[e.node])
        try em.print(" .{{ .node = {d}, .word = {d}, .mask = 0x{x} }},", .{ e.node, e.word - em.planes.off[slot], e.mask });
    try em.print(" }});\n", .{});
}

/// `fn val<n>`: the value of pure node `n` (at `pc`), read through an
/// `rt.View`.
fn nodeValue(em: *Emitter, pc: u32, n: u32) Error!void {
    const r = em.r;
    assert(em.pure_nodes[n]);
    const d = r.netlist.drivers[r.program.code.items[pc].continuous];
    const slot = r.netlist.nets[d.net].slot;
    r.scope = d.scope;
    r.pc = pc;
    const head = em.out.written().len;
    try em.print("fn val{d}(s: rt.View) L.T({d}) {{\n    @setEvalBranchQuota(1 << 30);\n", .{ n, em.slotWidth(slot) });
    const body = em.out.written().len;
    if (d.source == .gate) try drivers.gateInputs(em, d.source.gate.ins, d.source.gate.lane);
    try em.print("    return ", .{});
    switch (d.source) {
        .expr => |x| try drivers.driverValue(em, x.e, x.slice, slot),
        .gate => |g| try drivers.gateLogic(em, g.kind, g.ins.len),
        .bridge, .udp, .mos, .pull => unreachable, // `pureNode` admits these two
    }
    try em.print(";\n}}\n\n", .{});
    if (!processes.usesS(em.out.written()[head..])) try em.insert(body, "    _ = s;\n");
}
