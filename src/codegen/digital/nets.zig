//! An elaborated `Run`'s nets and drivers -> which ones the emitted code
//! resolves through `rt.net` and which it stores directly: a net whose one
//! driver is its value as is (a plain copy, §6.1) is stored by its process;
//! every other net, and every net a switch, a `%v`, a dumped port or a forced
//! select reads the strength or the drivers of, gets an `rt.net` row.
//! Also the §18.3 `$dumpports` calls, which mark their ports' nets so.
//! Cites: IEEE 1364-2005 §6.1, §7.6, §7.8, §7.9, §7.10.2, §7.12, §9.3.2,
//! §18.3.1, §18.3.7.
//!
//! Contents:
//! - `pub const RtNet = enum(u32)`, `pub const RtDriver = enum(u32)`
//! - `pub const Rows = struct`
//! - `Rows.netRow(rows: *const Rows, k: u32) ?u32`
//! - `Rows.driverRow(rows: *const Rows, d: u32) ?u32`
//! - `pub const PortFile = struct`
//! - `pub fn plainDriver(r: *const Run, select_forced: []const bool, i: u32) bool`
//! - `pub fn logicGate(kind: Ast.GateKind) bool`
//! - `pub fn resolvedNets(em: *Emitter) Error!Rows`
//! - `pub fn portArgs(args: []const Ast.ExprId) []const Ast.ExprId`
//! - `pub fn portDumps(em: *Emitter) Error![]const PortFile`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const sim_digital = @import("sim").digital;
const Run = sim_digital.Run;
const no_cold = sim_digital.for_emitter.net.no_cold;
const vcd = sim_digital.for_emitter.vcd;
const Emitter = @import("Emitter.zig");
const Error = Emitter.Error;

/// A row of `rt.Design.nets`; `none` for a net its plain driver stores.
pub const RtNet = enum(u32) { none = std.math.maxInt(u32), _ };
/// A row of `rt.Design.drivers`; `none` for a driver of a stored net.
pub const RtDriver = enum(u32) { none = std.math.maxInt(u32), _ };

comptime {
    assert(@sizeOf(RtNet) == 4);
    assert(@sizeOf(RtDriver) == 4);
}

/// `resolvedNets`' result: per `Run` net and driver its `rt.net` row, and
/// the `Run` nets and drivers of those rows in row order. Invariant: `nets[i]`
/// has row `i`, and so has `drivers[i]`.
pub const Rows = struct {
    net_ix: []const RtNet = &.{},
    drv_ix: []const RtDriver = &.{},
    nets: []const u32 = &.{},
    drivers: []const u32 = &.{},

    /// Returns `Run` net `k`'s `rt.net` row, null for a stored net.
    pub fn netRow(rows: *const Rows, k: u32) ?u32 {
        assert(k < rows.net_ix.len);
        const ix = rows.net_ix[k];
        if (ix != .none) assert(rows.nets[@backingInt(ix)] == k);
        return if (ix == .none) null else @backingInt(ix);
    }

    /// Returns `Run` driver `d`'s `rt.net` row, null for a stored net's.
    pub fn driverRow(rows: *const Rows, d: u32) ?u32 {
        assert(d < rows.drv_ix.len);
        const ix = rows.drv_ix[d];
        if (ix != .none) assert(rows.drivers[@backingInt(ix)] == d);
        return if (ix == .none) null else @backingInt(ix);
    }
};

/// One `$dumpports` call: the pc it is at, its file and scopes (`evcd.task`'s,
/// resolved where it is emitted).
pub const PortFile = struct { pc: u32, name: []const u8, call: []const u8, scopes: []const u32 };

/// Returns whether driver `i` is its net's value as is (`resolution.plainCopy`,
/// with no delay). It stores the net itself; every other driver resolves in
/// `rt.net`. A logic gate is one on a scalar net: it never asserts §7.10.2's
/// H/L. `select_forced` is `layout.ForcedParts.select_forced`.
pub fn plainDriver(r: *const Run, select_forced: []const bool, i: u32) bool {
    assert(i < r.netlist.drivers.len);
    assert(select_forced.len == r.values.len);
    const d = r.netlist.drivers[i];
    const n = r.netlist.nets[d.net];
    const plain = switch (n.kind) {
        .wire, .tri, .uwire => true,
        .tri0, .tri1, .trireg, .wand, .wor, .triand, .trior, .supply0, .supply1, .wreal => false,
    };
    const source = switch (d.source) {
        .expr => true,
        .gate => |g| r.values[n.slot].width == 1 and logicGate(g.kind),
        .bridge, .udp, .mos, .pull => false,
    };
    return plain and source and r.netDrivers(d.net).len == 1 and !n.strength_read and n.cold == no_cold and !select_forced[n.slot] and
        d.s0 == .strong and d.s1 == .strong and !d.delay.present;
}

/// Returns whether `kind` is an and, or, xor, buf or not gate (or an
/// inverse), not a three-state `bufif`/`notif`, whose output can be z.
pub fn logicGate(kind: Ast.GateKind) bool {
    return switch (kind) {
        .g_and, .g_nand, .g_or, .g_nor, .g_xor, .g_xnor, .g_buf, .g_not => true,
        .g_bufif0, .g_bufif1, .g_notif0, .g_notif1 => false,
    };
}

/// Returns a row for every net some driver of which is not plain, and every
/// net a switch reads or a `%v`, a dumped port or a forced select reads the
/// strength of (§7.12). Reads `em.forced`, which must be laid out first. A
/// VAMS `wreal` net is refused.
pub fn resolvedNets(em: *Emitter) Error!Rows {
    const r = em.r;
    const all_nets = r.netlist.nets;
    const all_drivers = r.netlist.drivers;
    const net_ix = try em.arena.alloc(RtNet, all_nets.len);
    const drv_ix = try em.arena.alloc(RtDriver, all_drivers.len);
    @memset(net_ix, .none);
    @memset(drv_ix, .none);
    // A subset of the nets, and of their drivers, each once.
    var rt_nets: std.ArrayList(u32) = try .initCapacity(em.arena, all_nets.len);
    var rt_drivers: std.ArrayList(u32) = try .initCapacity(em.arena, all_drivers.len);
    for (all_nets, 0..) |n, k| {
        // §7.6 a switch terminal resolves with the nets it is joined to.
        const resolved = n.strength_read or r.netCold(n).trans.len != 0 or em.forced.select_forced[n.slot] or for (r.netDrivers(@intCast(k))) |di| {
            if (!plainDriver(r, em.forced.select_forced, di)) break true;
        } else false;
        if (!resolved) continue;
        if (n.kind == .wreal) return em.refuse("a VAMS wreal net");
        net_ix[k] = @fromBackingInt(@as(u32, @intCast(rt_nets.items.len)));
        rt_nets.appendAssumeCapacity(@intCast(k));
        for (r.netDrivers(@intCast(k))) |di| {
            drv_ix[di] = @fromBackingInt(@as(u32, @intCast(rt_drivers.items.len)));
            rt_drivers.appendAssumeCapacity(di);
        }
    }
    assert(rt_nets.items.len <= all_nets.len);
    assert(rt_drivers.items.len <= all_drivers.len);
    return .{ .net_ix = net_ix, .drv_ix = drv_ix, .nets = rt_nets.items, .drivers = rt_drivers.items };
}

/// Returns `evcd.task`'s arguments: a null-only list is none (§18.3.7's
/// "name()").
pub fn portArgs(args: []const Ast.ExprId) []const Ast.ExprId {
    const given = if (args.len == 1 and args[0] == .none) &.{} else args;
    assert(given.len <= args.len);
    return given;
}

/// Returns every §18.3.1 `$dumpports` call's file and scopes, as
/// `evcd.task` finds them when it runs. What it reads of a port is its net's
/// drivers and their strengths, so each port's net is marked `strength_read`
/// in `em.r` and resolves in `rt.net`; call before `resolvedNets`.
pub fn portDumps(em: *Emitter) Error![]const PortFile {
    const r = em.r;
    const ex = &r.file.exprs;
    var files: std.ArrayList(PortFile) = .empty;
    for (r.program.code.items, 0..) |ins, pc| {
        if (ins != .task or ins.task.task != .ports or ins.task.task.ports != .ports) continue;
        const t = ins.task;
        r.scope = r.program.scope_of.items[pc];
        const given = portArgs(r.program.exprs(t.args));
        var scopes: std.ArrayList(u32) = try .initCapacity(em.arena, @max(given.len, 1));
        var name: []const u8 = "dumpports.vcd";
        for (given, 0..) |e, i| {
            if (ex.tag(e) == .ident or ex.tag(e) == .hier_ident) switch (vcd.target(r, e) catch return em.refuse("a $dumpports scope the engine resolves only at run time")) {
                .scope => |sc| {
                    scopes.appendAssumeCapacity(sc);
                    continue;
                },
                .slot => {},
            };
            if (i + 1 != given.len) continue;
            if (ex.tag(e) != .str_literal) return em.refuse("a $dumpports file name held in a variable");
            name = r.file.str(ex.strOf(e));
        }
        if (scopes.items.len == 0) scopes.appendAssumeCapacity(r.instanceOf(r.scope));
        for (scopes.items) |sc| for (r.file.modules[r.hier.scopes.items[sc].def].ports) |mp| {
            const slot = r.hier.names.get(.{ .scope = sc, .str = mp.name }) orelse continue;
            if (r.netlist.slot_nets.get(slot)) |n| r.netlist.nets[n].strength_read = true;
        };
        try files.append(em.arena, .{ .pc = @intCast(pc), .name = name, .call = vcd.callText(r.text, r.starts[t.tok]), .scopes = scopes.items });
    }
    if (files.items.len != 0) try em.xMeaning("§18.3 extended VCD, whose port states are strengths", null);
    assert(files.items.len <= r.program.code.items.len);
    return files.items;
}

test logicGate {
    // §7.8.5: only the enable gates (Table 7-4's bufif/notif) can drive z.
    try std.testing.expect(logicGate(.g_nand));
    try std.testing.expect(logicGate(.g_not));
    try std.testing.expect(!logicGate(.g_bufif0));
    try std.testing.expect(!logicGate(.g_notif1));
}
