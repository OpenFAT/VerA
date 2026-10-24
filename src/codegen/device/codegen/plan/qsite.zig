//! §5.6.1.2 charge sites: lowered contributions, topology and solve
//! invariance -> `QSites`, the charges `q` returns (one slot per reactive
//! term, not per row, so a host's truncation-error check can include or skip
//! each charge alone) and the signed rows each stamps. `dispatch.emitQ`
//! formats it. Clauses: §1.3.1.2, §4.5.15, §5.4.2, §5.4.3, §5.6, §5.6.1.2,
//! §5.6.1.3, §5.6.5.

const std = @import("std");
const Mir = @import("ir").Mir;
const Lower = @import("ir").Lowered;
const Input = @import("prove").Input;
const plan_topo = @import("topology.zig");
const assert = std.debug.assert;

/// Every fallible call here fails only on allocation.
pub const Error = std.mem.Allocator.Error;
const none_u32 = std.math.maxInt(u32);

/// One row entry: row `row` gains `sign · q[slot]`.
pub const Stamp = struct { slot: u32, row: u32, sign: f64 };

/// The charges `q` returns, one slot per site, and where each one stamps.
pub const QSites = struct {
    /// Slot → `Lowered.charge_sites` index, in source order.
    sites: []u32 = &.{},
    /// Sorted by (row, slot), no duplicate pair, no zero sign.
    stamps: []Stamp = &.{},
};

/// One signed contribution term of a row, before sites are expanded.
const Term = struct { sign: f64, contrib: u32 };

/// Returns the charge-site slots and the rows each stamps; slices are owned
/// by `in.arena`. Every row is exactly `sum(sign * q[site])`:
///   - a flow contribution: +1 at hi, -1 at lo (§1.3.1.2), and -1 on a
///     sourced §5.4.2 free-flow row;
///   - a §1.3.4.2 flow-only signal-flow net: -1 on the net's own row;
///   - a potential contribution: -1 on its branch row (a flux, v - dphi/dt);
///   - a §5.6.1.3 runtime-selected branch row (§5.6.5 switch): -1 for the
///     potential's sites and -1 for the switch partner's flow, or on a
///     collapsible branch the partner's +1/-1 at hi/lo. The row `S.sel`s
///     between them and `discardOpposite` zeroes the unused side's
///     accumulator and sites, so the static sum is the select;
///   - a §5.4.3 port probe: minus the finished port row.
/// A site whose charge is constant or solve-invariant has dq/dt = 0 and gets
/// no slot; nor does a site that stamps no row (a ground-ground branch).
/// `branch_u` is `Names.branch_u`, one entry per contribution; `sinv` is
/// `Sinv.val`. O(rows · terms · sites); a module has tens of each.
pub fn plan(in: Input, branch_u: []const u32, topo: plan_topo.Topology, sinv: []const bool) Error!QSites {
    const a = in.arena;
    const lw = in.lowered;

    // Which rows each contribution's reactive value enters. `rows` is keyed
    // by row index; a row is a list of terms, cleared by an ASSIGNMENT.
    var rows: std.AutoArrayHashMapUnmanaged(u32, std.ArrayList(Term)) = .empty;
    const Rows = struct {
        fn add(al: std.mem.Allocator, m: *std.AutoArrayHashMapUnmanaged(u32, std.ArrayList(Term)), row: u32, t: Term) Error!void {
            if (row == Lower.ground) return; // §1.3.1.1 ground has no row
            const g = try m.getOrPut(al, row);
            if (!g.found_existing) g.value_ptr.* = .empty;
            try g.value_ptr.append(al, t);
        }
        fn assign(al: std.mem.Allocator, m: *std.AutoArrayHashMapUnmanaged(u32, std.ArrayList(Term)), row: u32, t: Term) Error!void {
            if (row == Lower.ground) return;
            const g = try m.getOrPut(al, row);
            g.value_ptr.* = .empty;
            try g.value_ptr.append(al, t);
        }
    };

    for (lw.contributions.items, 0..) |c, ci| {
        const i: u32 = @intCast(ci);
        if (c.kind != .direct) continue; // §5.6.7 an indirect row has no reactive half
        switch (c.access) {
            .flow => {
                // Carried by the runtime-selected branch row below.
                if (plan_topo.flowIsMerged(in, i)) continue;
                if (plan_topo.flowOnlySignalFlowNet(in, c)) |nn| {
                    try Rows.assign(a, &rows, nn, .{ .sign = -1, .contrib = i });
                    continue;
                }
                try Rows.add(a, &rows, c.hi, .{ .sign = 1, .contrib = i });
                try Rows.add(a, &rows, c.lo, .{ .sign = -1, .contrib = i });
                if (topo.freeFlowOf(c.hi, c.lo)) |f| try Rows.add(a, &rows, f.u, .{ .sign = -1, .contrib = i });
            },
            .potential => {
                const u = branch_u[i];
                if (u == none_u32) continue;
                try Rows.assign(a, &rows, u, .{ .sign = -1, .contrib = i });
                if (plan_topo.retention(in, c) != .runtime) continue;
                const j = plan_topo.switchFlowOf(in, i) orelse continue;
                if (plan_topo.retention(in, lw.contributions.items[j]) == .off) continue;
                const jj: u32 = @intCast(j);
                if (topo.collapsible(u)) {
                    try Rows.add(a, &rows, c.hi, .{ .sign = 1, .contrib = jj });
                    try Rows.add(a, &rows, c.lo, .{ .sign = -1, .contrib = jj });
                } else try Rows.add(a, &rows, u, .{ .sign = -1, .contrib = jj });
            },
        }
    }
    // §5.4.3 the port probes read the FINISHED port rows, in order.
    for (lw.port_probes.items) |pp| {
        const src = rows.get(pp.port);
        const g = try rows.getOrPut(a, pp.u);
        g.value_ptr.* = .empty;
        if (src) |s| for (s.items) |t| try g.value_ptr.append(a, .{ .sign = -t.sign, .contrib = t.contrib });
    }

    // Slots: the sites that stamp something and are not constant in time.
    const ns = lw.charge_sites.items.len;
    const stamps_of = try a.alloc(bool, ns);
    @memset(stamps_of, false);
    var it = rows.iterator();
    while (it.next()) |e| for (e.value_ptr.items) |t| {
        for (lw.charge_sites.items, 0..) |s, k| {
            if (s.contrib == t.contrib) stamps_of[k] = true;
        }
    };
    const slot_of = try a.alloc(u32, ns);
    var sites: std.ArrayList(u32) = .empty;
    for (lw.charge_sites.items, 0..) |s, k| {
        slot_of[k] = none_u32;
        if (!stamps_of[k] or !live(in, sinv, s.final)) continue;
        slot_of[k] = @intCast(sites.items.len);
        try sites.append(a, @intCast(k));
    }

    // Expand every row's terms into (slot, sign), merging repeats.
    var out: std.ArrayList(Stamp) = .empty;
    it = rows.iterator();
    while (it.next()) |e| {
        const row = e.key_ptr.*;
        for (e.value_ptr.items) |t| for (lw.charge_sites.items, 0..) |s, k| {
            if (s.contrib != t.contrib or slot_of[k] == none_u32) continue;
            const sg = t.sign * s.sign;
            for (out.items) |*o| {
                if (o.row == row and o.slot == slot_of[k]) {
                    o.sign += sg;
                    break;
                }
            } else try out.append(a, .{ .slot = slot_of[k], .row = row, .sign = sg });
        };
    }
    var kept: usize = 0;
    for (out.items) |o| {
        if (o.sign == 0) continue;
        out.items[kept] = o;
        kept += 1;
    }
    out.shrinkRetainingCapacity(kept);
    std.mem.sortUnstable(Stamp, out.items, {}, struct {
        fn lt(_: void, x: Stamp, y: Stamp) bool {
            return if (x.row != y.row) x.row < y.row else x.slot < y.slot;
        }
    }.lt);
    // Exit invariant `QSites.stamps` states: strictly ascending (row, slot),
    // so no pair twice, and no zero sign.
    for (out.items, 0..) |o, k| {
        assert(o.sign != 0);
        if (k != 0) {
            const p = out.items[k - 1];
            assert(p.row < o.row or (p.row == o.row and p.slot < o.slot));
        }
    }
    return .{ .sites = sites.items, .stamps = out.items };
}

/// Does a charge with this end-of-block value move in time?
fn live(in: Input, sinv: []const bool, v0: Mir.Value) bool {
    const v = in.an.rv(v0);
    if (in.an.foldConst(v, false) != null) return false;
    const i = @backingInt(v);
    return !(i < sinv.len and sinv[i] and in.mir.valueDef(v) == .inst_result);
}

const Fixture = @import("prove").Fixture;

test "two charges on one pin are two slots; a flow contribution stamps +hi and −lo" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{ "g", "s", "d" });
    defer f.deinit();
    const a = f.alloc();
    const qgs = try f.mir.emit(a, .entry, .fmul, &.{ try f.probe(0), try f.probe(1) });
    const qgd = try f.mir.emit(a, .entry, .fmul, &.{ try f.probe(0), try f.probe(2) });
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 0, .lo = 1, .react_val = qgs, .wrote_val = .f_one });
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 0, .lo = 2, .react_val = qgd, .wrote_val = .f_one });
    try f.lowered.charge_sites.append(a, .{ .contrib = 0, .sign = 1, .final = qgs });
    try f.lowered.charge_sites.append(a, .{ .contrib = 1, .sign = 1, .final = qgd, .lte = false });
    const an = try f.analysis();
    const in: Input = .{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered };
    const sinv = try a.alloc(bool, an.nv);
    @memset(sinv, false);
    const branch_u = [_]u32{ none_u32, none_u32 };
    const q = try plan(in, &branch_u, .{}, sinv);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, q.sites);
    // The gate row g holds both, one stamp each; s and d one apiece.
    try std.testing.expectEqualSlices(Stamp, &.{
        .{ .slot = 0, .row = 0, .sign = 1 },
        .{ .slot = 1, .row = 0, .sign = 1 },
        .{ .slot = 0, .row = 1, .sign = -1 },
        .{ .slot = 1, .row = 2, .sign = -1 },
    }, q.stamps);
}

test "a flux on its branch row, a ground end, a port probe's mirror, and the charges that get no slot" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    // a, b; `ib` the branch current of V(a,b); `ip` the §5.4.3 probe of port a.
    try f.init(&.{ "a", "b", "ib", "ip" });
    defer f.deinit();
    const a = f.alloc();
    f.lowered.num_ports = 1;
    const va = try f.probe(0);
    const vb = try f.probe(1);
    const phi_l = try f.mir.emit(a, .entry, .fmul, &.{ va, vb }); // a flux
    const qa = try f.mir.emit(a, .entry, .fmul, &.{ va, va }); // a charge to ground
    const qinv = try f.mir.emit(a, .entry, .fmul, &.{ try f.mir.addParamRef(a, 0), .f_two }); // card-only
    const qlit = try f.mir.addFloatConst(a, 1e-12); // a literal
    try f.lowered.params.append(a, .{ .name = "c0", .ty = .real, .default = .f_one });
    // 0: V(a,b) <+ ddt(phi), unconditional: the flux stamps −1 on row ib.
    try f.lowered.contributions.append(a, .{ .access = .potential, .hi = 0, .lo = 1, .wrote_val = .f_one, .react_val = phi_l });
    // 1: I(a) <+ ddt(qa) + ddt(qinv) + ddt(qlit): only qa moves in time.
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 0, .lo = Lower.ground, .wrote_val = .f_one });
    try f.lowered.charge_sites.append(a, .{ .contrib = 0, .sign = 1, .final = phi_l });
    try f.lowered.charge_sites.append(a, .{ .contrib = 1, .sign = 1, .final = qa });
    try f.lowered.charge_sites.append(a, .{ .contrib = 1, .sign = 1, .final = qinv });
    try f.lowered.charge_sites.append(a, .{ .contrib = 1, .sign = 1, .final = qlit });
    try f.lowered.port_probes.append(a, .{ .port = 0, .u = 3 });
    const an = try f.analysis();
    const in: Input = .{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered };
    // `prove/setup.zig` would find qinv solve-invariant; stated here directly.
    const sinv = try a.alloc(bool, an.nv);
    @memset(sinv, false);
    sinv[@backingInt(qinv)] = true;

    const q = try plan(in, &.{ 2, none_u32 }, .{}, sinv);
    // Sites 2 (invariant) and 3 (literal) have dq/dt = 0.
    try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, q.sites);
    try std.testing.expectEqualSlices(Stamp, &.{
        // Row a: qa from I(a) (+1); ground has no row.
        .{ .slot = 1, .row = 0, .sign = 1 },
        // Row ib: the flux, −1 (v − dphi/dt).
        .{ .slot = 0, .row = 2, .sign = -1 },
        // Row ip: minus the finished port row a.
        .{ .slot = 1, .row = 3, .sign = -1 },
    }, q.stamps);
}
