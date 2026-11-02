//! The core's live-outs for one residual half -> its §5.6 stamp rows
//! (`res[@intFromEnum(U.<u>)] = zRow(...)`): each contribution added at hi and
//! subtracted at lo by §1.3.1.2's reference directions, a potential source's
//! branch relation, a §5.4.3 port probe's mirror, and the evidence each stamp
//! leaves in `Gen.jac` (the row's column pattern and the frequency-dependent
//! columns).
//! Cites: §1.3.1.2, §5.4.2.1, §5.4.3, §5.6, §5.6.6.
//!
//! Contents:
//! - `pub fn emitStamps(self: *Gen, react: bool) Error!u32`
//! - `pub fn stamp(self: *Gen, depth: u32, node: u32, sign: StampSign, val: []const u8, deps: []const u64, col: ?u32) Error!void`
//! - `pub fn rowSet(self: *Gen, u: u32) Error!void`
//! - `pub fn rowEnd(self: *Gen) Error!void`
//! - `pub fn patRow(self: *Gen, node: u32, deps: []const u64) void`
//! - `pub fn rowOf(self: *const Gen, table: anytype, r: u32) @TypeOf(table)`
//! - `pub fn bits(self: *const Gen, us: []const u32, deps: []const []const u64) Error![]const u64`
//! - `pub fn nodeVoltage(self: *Gen, node: u32) Error!void`

const std = @import("std");
const plan_topo = @import("plan/topology.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const family = @import("family.zig");
const gen_mask = @import("mask.zig");
const Mir = @import("ir").Mir;
const Lower = @import("ir").Lowered;
const assert = std.debug.assert;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const gen_dispatch = @import("dispatch.zig");
const stamp_lin = @import("stamp_lin.zig");
const switch_row = @import("switch_row.zig");

/// A stamp's sign; its tag names are the emitted row methods `.add`/`.sub`.
const StampSign = enum { add, sub };

/// Emits the §5.6 stamp rows for one residual half into a `res` the caller
/// has declared. Accumulates `uses.x`/`uses.model`/`uses.inst`, `jac.pat`, `jac.rows`
/// and `lin`, and returns the row count so the caller can back-patch its
/// signature. Opens a `core` call unless `core_hoisted` is set.
pub fn emitStamps(self: *Gen, react: bool) Error!u32 {
    assert(self.names.n_u == self.names.u_names.len);
    assert(self.jac.lin[0].len == self.jac.lin[1].len);
    var stamps: u32 = 0;
    // Which half `patRow` accumulates into. `eval`/`q` and `evalQ` emit the
    // same rows, so the second pass ORs in bits the first already set.
    self.jac.react = react;
    // `lin` is a replay, not an accumulation: `evalQ` re-emits the same
    // stamps, and adding them twice would double every coefficient. The
    // guarded stamps are eval-only (`emitSwitchRow`), so eval resets them.
    for (self.jac.lin[@intFromBool(react)]) |*l| l.clearRetainingCapacity();
    if (!react) self.jac.guarded.clearRetainingCapacity();
    // One core evaluation per residual, not one per contribution: LLVM does
    // not merge them (see `plan_core.plan`'s header).
    var opened = false;
    if (self.lowered.table_effect != .f_zero) {
        opened = true;
        self.cur.uses.x = true;
        self.cur.uses.model = true;
        self.cur.uses.inst = true;
        self.cur.core_wanted = true;
        if (!self.cur.core_hoisted) try self.b("    const m = @call(.always_inline, core, .{{ S, x, model, inst, sim{s} }});\n", .{self.heldArg(false)});
        try self.b("    _ = m.f{d};\n", .{gen_dispatch.coreIdx(self, self.an.rv(self.lowered.table_effect)).?});
    }

    for (self.lowered.contributions.items, 0..) |c, i| {
        const val = if (react) self.an.rv(c.react_val) else self.an.rv(c.resist_val);
        self.jac.cur_dyn = try contribDyn(self, i, c, react);
        // §5.6.1.3 a `.flow` entry whose branch row is runtime-selected is
        // consumed by that row (`I_b − value`); its KCL current is the ±I_b
        // the potential entry already stamps. Stamping the value here too
        // would inject it twice.
        if (c.kind == .direct and c.access == .flow and plan_topo.flowIsMerged(self.input(), i)) continue;
        // §5.6.1.3's three-way rule is decided per cycle. `.on`/`.off` fold
        // statically; `.runtime` keeps the row alive in every case, because
        // the open-circuit form (`res[u] = I_b`) pins the branch current when
        // nothing is retained.
        const run_pot: ?plan_topo.Retention = if (c.kind == .direct and c.access == .potential) ret: {
            const r = plan_topo.retention(self.input(), c);
            break :ret if (r == .runtime) r else null;
        } else null;
        // A zero half normally contributes nothing, and §5.6.1.3's
        // `discardOpposite` relies on that: it writes `.f_zero` to BOTH
        // `acc.resist` and `acc.react`, so a discarded contribution still
        // emits no row at all, in either residual.
        //
        // The exception is the inductor. A §5.6 potential contribution's
        // resistive row `V(hi) - V(lo) - c` defines its branch flow unknown,
        // and the same row enters KCL at hi and lo (§1.3.1.2).
        // `V(l) <+ L*ddt(I(l))` has `resist_val == .f_zero` and a live
        // `react_val`; skipping it would leave the flow column with no pivot.
        // Only `c` is zero, and at DC `V(hi) - V(lo) = 0` is an inductor.
        //
        // A runtime-selected row's q half is live only when SOME selectable
        // form has a flux: its own react, or the switch partner's.
        const partner_react: Mir.Value = if (run_pot != null) blk: {
            const j = plan_topo.switchFlowOf(self.input(), i) orelse break :blk .f_zero;
            break :blk self.an.rv(self.lowered.contributions.items[j].react_val);
        } else .f_zero;
        const live = if (react)
            val != .f_zero or partner_react != .f_zero
        else
            val != .f_zero or run_pot != null or
                (c.access == .potential and self.an.rv(c.react_val) != .f_zero);
        if (!live) continue;
        self.cur.uses.x = true;
        // `model`/`inst` are read through `core` alone, so a residual whose
        // every live row is zero never opens one (an unused parameter would
        // fail the host's build). A runtime-selected row always opens it: its
        // retention flag is a core field (`buildJobs`).
        if (val != .f_zero or run_pot != null) {
            self.cur.uses.model = true;
            self.cur.uses.inst = true;
            if (!opened) {
                opened = true;
                self.cur.core_wanted = true;
                if (!self.cur.core_hoisted) {
                    try self.ind(1);
                    try self.b("const m = @call(.always_inline, core, .{{ S, x, model, inst, sim{s} }});\n", .{self.heldArg(false)});
                }
            }
        }
        stamps += 1;
        try self.ind(1);
        try self.b("{{\n", .{});
        try self.ind(2);
        // `.f_zero` is rendered inline, never planned into `core` (see
        // `plan_core.plan`), so there is no `m.f<k>` to read for it.
        if (val == .f_zero)
            try self.b("const c = S.con(0.0);\n", .{})
        else
            try self.b("const c = m.f{d};\n", .{self.core.lo_idx[@backingInt(val)]});
        if (c.kind == .indirect) {
            // §5.6.7 nullor: `out` is driven by a source whose current is
            // the unknown `ib`, and the row is the constraint alone,
            // `<probe> − <equation>`, with no V(hi,lo) term: "the source
            // voltage needs to be adjusted so that the given equation is
            // satisfied". The ib column is filled only by the two KCL stamps.
            const u = self.names.branch_u[i];
            assert(!react); // splitContribution never runs on an indirect
            try self.ind(2);
            try self.b("const ib = x[@intFromEnum(U.{s})];\n", .{self.names.u_names[u]});
            try stamp(self, 2, c.hi, .add, "ib", try bits(self, &.{u}, &.{}), u);
            try stamp(self, 2, c.lo, .sub, "ib", try bits(self, &.{u}, &.{}), u);
            try self.ind(2);
            patRow(self, @intCast(u), family.mask(self, val));
            stamp_lin.linClear(self, u);
            try rowSet(self, u);
            try self.b("c", .{});
            try rowEnd(self);
            try self.ind(1);
            try self.b("}}\n", .{});
            continue;
        }
        switch (c.access) {
            .flow => if (plan_topo.flowOnlySignalFlowNet(self.input(), c)) |n| {
                // §1.3.4.2 a flow signal-flow net has no potential, so its
                // one unknown is its flow and the contribution is that
                // unknown's defining equation. A KCL stamp here would write a
                // row with no `x` in it. See `flowOnlySignalFlowNet`.
                if (!react) {
                    try self.ind(2);
                    patRow(self, n, try bits(self, &.{n}, &.{family.mask(self, val)}));
                    stamp_lin.linClear(self, n);
                    try stamp_lin.linTerm(self, n, n, 1);
                    try rowSet(self, n);
                    try self.b("x[@intFromEnum(U.{s})].sub(c)", .{self.names.u_names[n]});
                    try rowEnd(self);
                } else {
                    try self.ind(2);
                    patRow(self, n, family.mask(self, val));
                    stamp_lin.linClear(self, n);
                    try rowSet(self, n);
                    try self.b("c.neg()", .{});
                    try rowEnd(self);
                }
            } else {
                // §1.3.1.2: the value flows INTO hi and OUT OF lo.
                try stamp(self, 2, c.hi, .add, "c", family.mask(self, val), null);
                try stamp(self, 2, c.lo, .sub, "c", family.mask(self, val), null);
                // §5.6.6: the model also reads `I(hi,lo)`, so this current is
                // an unknown whose row is `x[u] − Σ contributions`. Accumulated
                // here (contributions to one branch are one sum, §5.6.1) and
                // closed with the `+ x[u]` term after the loop.
                if (self.topo.freeFlowOf(c.hi, c.lo)) |f| {
                    assert(f.sourced);
                    try stamp(self, 2, @intCast(f.u), .sub, "c", family.mask(self, val), null);
                }
            },
            .potential => {
                // §5.6 branch relation: the branch current is its own
                // unknown; its row carries V(hi,lo) − <value>.
                if (run_pot) |ret| {
                    try switch_row.emitSwitchRow(self, i, c, ret.runtime, react);
                } else if (!react) {
                    const u = self.names.branch_u[i];
                    try self.ind(2);
                    try self.b("const ib = x[@intFromEnum(U.{s})];\n", .{self.names.u_names[u]});
                    try stamp(self, 2, c.hi, .add, "ib", try bits(self, &.{u}, &.{}), u);
                    try stamp(self, 2, c.lo, .sub, "ib", try bits(self, &.{u}, &.{}), u);
                    try self.ind(2);
                    patRow(self, @intCast(u), try bits(self, &.{ c.hi, c.lo }, &.{family.mask(self, val)}));
                    try stamp_lin.linBranch(self, u, c.hi, c.lo);
                    try rowSet(self, u);
                    try nodeVoltage(self, c.hi);
                    try self.b(".sub(", .{});
                    try nodeVoltage(self, c.lo);
                    try self.b(").sub(c)", .{});
                    try rowEnd(self);
                } else {
                    const u = self.names.branch_u[i];
                    // §5.6.1.2 the reactive part of a branch relation is a
                    // flux: v − dφ/dt = 0 ⇒ q on this row is −φ.
                    try self.ind(2);
                    patRow(self, @intCast(u), family.mask(self, val));
                    stamp_lin.linClear(self, u);
                    try rowSet(self, u);
                    try self.b("c.neg()", .{});
                    try rowEnd(self);
                }
            },
        }
        try self.ind(1);
        try self.b("}}\n", .{});
    }

    self.jac.cur_dyn = &.{};

    // §5.4.2 the branch-flow unknowns no branch row defines (`FreeFlow`).
    // Both rows are purely resistive: a §5.6.6 implicit sum's reactive half
    // is already on this row as `−Σ q`, and a §5.4.2.1 probe is a short,
    // which stores no charge.
    if (!react) for (self.topo.free_flows) |f| {
        self.cur.uses.x = true;
        stamps += 1;
        if (f.sourced) {
            // Closes `res[u] = x[u] − Σ contributions`, whose `−Σ` half the
            // contribution loop accumulated.
            try self.ind(1);
            patRow(self, @intCast(f.u), try bits(self, &.{f.u}, &.{}));
            try stamp_lin.linTerm(self, f.u, f.u, 1);
            try rowSet(self, f.u);
            try self.b("res[@intFromEnum(U.{0s})].add(x[@intFromEnum(U.{0s})])", .{self.names.u_names[f.u]});
            try rowEnd(self);
        } else {
            // §5.4.2.1 "The branch potential of a flow probe is zero (0)",
            // the ammeter of Figure 5-1. Its current enters KCL at both ends,
            // which makes it a short rather than an observation.
            try stamp(self, 1, f.hi, .add, try self.arena.print("x[@intFromEnum(U.{s})]", .{self.names.u_names[f.u]}), try bits(self, &.{f.u}, &.{}), f.u);
            try stamp(self, 1, f.lo, .sub, try self.arena.print("x[@intFromEnum(U.{s})]", .{self.names.u_names[f.u]}), try bits(self, &.{f.u}, &.{}), f.u);
            try self.ind(1);
            patRow(self, @intCast(f.u), try bits(self, &.{ f.hi, f.lo }, &.{}));
            try stamp_lin.linBranch(self, f.u, f.hi, f.lo);
            try rowSet(self, f.u);
            try nodeVoltage(self, f.hi);
            try self.b(".sub(", .{});
            try nodeVoltage(self, f.lo);
            try self.b(")", .{});
            try rowEnd(self);
        }
    };

    // §5.4.3 `I(<p>)` = "the flow into a port of a module". By KCL that is
    // exactly what this module has just stamped at p, so the row reuses the
    // accumulation above instead of restating it:
    //
    //     eval:  res[flow(<p>)] = x[flow(<p>)] − res[p]
    //     q:     res[flow(<p>)] =              − res[p]
    //
    // Total residual x − (I_dc + d/dt q_p) = 0, so the reactive half of the
    // port current comes along: §5.4.3's own diode example probes a node
    // with a `ddt` junction capacitance. Emitted after the contribution loop
    // because it reads the finished res[p].
    for (self.lowered.port_probes.items) |pp| {
        self.cur.uses.x = true;
        stamps += 1;
        try self.ind(1);
        // Reads the finished res[port], so this row's columns are that row's.
        patRow(self, pp.u, try bits(self, if (react) &.{} else &.{pp.u}, &.{try patOf(self, pp.port)}));
        if (self.jac.dpat.len != 0) gen_mask.orIn(rowOf(self, self.jac.dpat, pp.u), rowOf(self, self.jac.dpat, pp.port));
        try stamp_lin.linPortProbe(self, pp.u, pp.port, !react);
        try rowSet(self, pp.u);
        if (react)
            try self.b("res[@intFromEnum(U.{s})].neg()", .{self.names.u_names[pp.port]})
        else
            try self.b("x[@intFromEnum(U.{0s})].sub(res[@intFromEnum(U.{1s})])", .{
                self.names.u_names[pp.u], self.names.u_names[pp.port],
            });
        try rowEnd(self);
    }

    assert(self.jac.cur_dyn.len == 0);
    assert(stamps <= self.lowered.contributions.items.len + self.topo.free_flows.len + self.lowered.port_probes.items.len);
    return stamps;
}

/// Emits one term into row `node`: `sign` (`add`/`sub`) of `val`, recording
/// `bits` in the row pattern. `col` names the unknown when `val` is exactly `x[col]` (a ±1 term
/// whose coefficient `Gen.jac.lin` records), and is null for a core value, whose
/// lanes `renderValueRef` already marked. Ground has no row and writes nothing.
pub fn stamp(self: *Gen, depth: u32, node: u32, sign: StampSign, val: []const u8, deps: []const u64, col: ?u32) Error!void {
    assert(val.len != 0);
    assert(deps.len == 0 or deps.len == self.mw);
    if (node == Lower.ground) return; // §1.3.1.1 ground has no equation
    assert(node < self.names.n_u);
    patRow(self, node, deps);
    if (col) |k| try stamp_lin.linTerm(self, node, k, switch (sign) {
        .add => 1,
        .sub => -1,
    });
    try self.ind(depth);
    try rowSet(self, node);
    try self.b("res[@intFromEnum(U.{s})].{s}({s})", .{ self.names.u_names[node], @tagName(sign), val });
    try rowEnd(self);
    assert(std.mem.endsWith(u8, self.out.items, ");\n"));
}

/// `res[@intFromEnum(U.<u>)] = zRow(S, .<u>, `: row `u` is typed by its
/// pattern (`contract.rowMask`), so every value assigned to it widens there.
/// `rowEnd` closes it.
pub fn rowSet(self: *Gen, u: u32) Error!void {
    assert(u < self.names.n_u);
    try self.b("res[@intFromEnum(U.{0s})] = zRow(S, .{0s}, ", .{self.names.u_names[u]});
    assert(std.mem.endsWith(u8, self.out.items, ", "));
}

pub fn rowEnd(self: *Gen) Error!void {
    assert(self.out.items.len != 0);
    try self.b(");\n", .{});
    assert(std.mem.endsWith(u8, self.out.items, ");\n"));
}

/// Records that row `node` of the half being emitted (`jac.react`) gained a
/// term whose derivative lives in `deps`, and that the row is written at all
/// (`rows`). Ground has no row. Every `res[...]` writer calls this.
pub fn patRow(self: *Gen, node: u32, deps: []const u64) void {
    assert(deps.len == 0 or deps.len == self.mw);
    if (node == Lower.ground or !self.jac.on) return;
    const half = self.jac.pat[@intFromBool(self.jac.react)];
    assert(node < self.names.n_u);
    if (half.len != 0) gen_mask.orIn(rowOf(self, half, node), deps);
    // A superset: a stamp of `x[u]` itself (an `ib`) is marked when the
    // contribution reaches `u` through an operator too.
    if (self.jac.cur_dyn.len != 0 and self.jac.dpat.len != 0) for (rowOf(self, self.jac.dpat, node), self.jac.cur_dyn, deps) |*d, c, b| {
        d.* |= c & b;
    };
    gen_mask.set(self.jac.rows[@intFromBool(self.jac.react)], node);
    assert(gen_mask.has(self.jac.rows[@intFromBool(self.jac.react)], node));
}

/// Row `r` of a per-row mask table (`jac.pat`, `jac.dpat`): `Gen.mw` words.
pub fn rowOf(self: *const Gen, table: anytype, r: u32) @TypeOf(table) {
    assert(table.len % self.mw == 0);
    assert(r < table.len / self.mw);
    return table[r * self.mw ..][0..self.mw];
}

/// Returns, from the arena, the mask of unknowns `us` (ground skipped,
/// `none_u32` every unknown) ORed with `deps`.
pub fn bits(self: *const Gen, us: []const u32, deps: []const []const u64) Error![]const u64 {
    for (deps) |d| assert(d.len == self.mw);
    const m = try gen_mask.zero(self.arena, self.mw);
    for (us) |u| {
        if (u == Lower.ground) continue;
        if (u == none_u32) {
            for (0..self.names.n_u) |k| gen_mask.set(m, @intCast(k));
            continue;
        }
        gen_mask.set(m, u);
    }
    for (deps) |d| gen_mask.orIn(m, d);
    assert(m.len == self.mw);
    return m;
}

pub fn nodeVoltage(self: *Gen, node: u32) Error!void {
    assert(node == Lower.ground or node < self.names.n_u);
    if (node == Lower.ground) return self.b("S.con(0.0)", .{});
    try self.b("x[@intFromEnum(U.{s})]", .{self.names.u_names[node]});
    assert(std.mem.endsWith(u8, self.out.items, ")]"));
}

// ---- private ----

/// The columns accumulated so far on row `u` of the half being emitted;
/// every column before the dispatchers allocate the patterns.
fn patOf(self: *const Gen, u: u32) Error![]const u64 {
    assert(u < self.names.n_u);
    const half = self.jac.pat[@intFromBool(self.jac.react)];
    return if (half.len == 0) bits(self, &.{none_u32}, &.{}) else rowOf(self, half, u);
}

/// Returns the columns contribution `i`'s rows reach through a
/// frequency-dependent operator: its value's, and a §5.6.5 switch partner's,
/// whose value the same row selects (`switchRowDeps`). Empty for none.
fn contribDyn(self: *const Gen, i: usize, c: Lower.Contribution, react: bool) Error![]const u64 {
    assert(i < self.lowered.contributions.items.len);
    if (self.acdyn.len == 0) return &.{};
    const own = family.acDyn(self, if (react) c.react_val else c.resist_val);
    const j = plan_topo.switchFlowOf(self.input(), i) orelse return own;
    assert(j < self.lowered.contributions.items.len);
    const f = self.lowered.contributions.items[j];
    return bits(self, &.{}, &.{ own, family.acDyn(self, if (react) f.react_val else f.resist_val) });
}
