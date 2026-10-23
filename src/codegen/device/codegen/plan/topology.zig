//! Topology: lowered contributions and the branch currents `plan/names.zig`
//! allocated -> `Topology`, the §5.4.2/§5.6 branch facts the residual is
//! assembled from (free flow unknowns, collapsible §5.6.5 switch branches,
//! static retention). The emitter asks the helpers through `Gen.input()`.
//! Clauses: §1.3.1.1, §1.3.4, §1.3.4.2, §3.6.2.2, §4.4, §5.4.2, §5.4.2.1,
//! §5.6.1.3, §5.6.5, §5.6.6.

const std = @import("std");
const Mir = @import("ir").Mir;
const Lower = @import("ir").Lowered;
const Input = @import("prove").Input;

/// Every fallible call here fails only on allocation.
pub const Error = std.mem.Allocator.Error;
const none_u32 = std.math.maxInt(u32);
const assert = std.debug.assert;

/// The §5.4.2/§5.6 branch facts the residual is assembled from.
pub const Topology = struct {
    /// §5.4.2.1/§5.6.6 the branch-flow unknowns no branch row defines, in
    /// slot order. See `FreeFlow` and `emitStamps`.
    free_flows: []const FreeFlow = &.{},
    /// The §5.6.5 switch branches `collapse` aliases away (`collapsePairs`).
    /// Built once, before any residual is emitted, because `emitSwitchRow`
    /// needs the membership test.
    cpairs: []const CollapsePair = &.{},

    /// The `FreeFlow` for the pair `(hi, lo)`, if that branch has one. The
    /// pair is ordered: `(lo, hi)` is another branch. O(free flows).
    pub fn freeFlowOf(self: Topology, hi: u32, lo: u32) ?FreeFlow {
        for (self.free_flows) |f| if (f.hi == hi and f.lo == lo) return f;
        return null;
    }

    /// Whether the branch whose flow unknown is `u` is one `collapse`
    /// aliases away. O(pairs).
    pub fn collapsible(self: Topology, u: u32) bool {
        for (self.cpairs) |p| if (p.flow_u == u) return true;
        return false;
    }
};

/// Returns the branch facts for the branch currents `branch_u` (per
/// contribution, `none_u32` where none); slices are owned by `in.arena`.
/// Asserts that `branch_u` has one entry per contribution.
pub fn plan(in: Input, branch_u: []const u32) Error!Topology {
    assert(branch_u.len == in.lowered.contributions.items.len);
    return .{
        .free_flows = try freeFlows(in, branch_u),
        .cpairs = try collapsePairs(in, branch_u),
    };
}

/// §5.6.1.3 what is known statically about a `.direct` contribution's
/// retention this cycle, read off `Lower.Contribution.wrote_val`.
pub const Retention = union(enum) {
    /// The flag folded to 1.0: a value is retained on every path (the common
    /// unconditional case, a static row).
    on,
    /// Folded to 0.0: discarded on every path (§5.6.1.3's unconditional
    /// replacement). The accumulators folded to `.f_zero` with it, so no row
    /// is emitted.
    off,
    /// A phi: which quantity the branch retains depends on the cycle's
    /// execution path, so the branch row's content is selected at run time on
    /// this flag (carried as a core field).
    runtime: Mir.Value,
};

/// Returns what is statically known about `c`'s §5.6.1.3 retention.
pub fn retention(self: Input, c: Lower.Contribution) Retention {
    const v = self.an.rv(c.wrote_val);
    return switch (self.mir.valueDef(v)) {
        .float_const => |x| if (x != 0.0) Retention.on else Retention.off,
        .int_const => |x| if (x != 0) Retention.on else Retention.off,
        .undef, .str_const, .param_ref, .block_param, .inst_result => .{ .runtime = v },
    };
}

/// The §5.6.5 switch-branch partner of potential contribution `pi`: the one
/// `.flow` direct entry over the same (hi, lo, branch), or null.
/// `contribIndex` dedupes per (access, pair, branch), so there is at most
/// one. ponytail: O(n) scan per potential entry; contributions per module
/// are tens, same order as `plan/names.zig`'s branch-current scan.
/// Asserts that `pi` indexes a contribution.
pub fn switchFlowOf(self: Input, pi: usize) ?usize {
    assert(pi < self.lowered.contributions.items.len);
    const p = self.lowered.contributions.items[pi];
    for (self.lowered.contributions.items, 0..) |c, j| {
        if (j == pi or c.kind != .direct or c.access != .flow) continue;
        if (c.hi == p.hi and c.lo == p.lo and c.br == p.br) {
            assert(j != pi);
            return j;
        }
    }
    return null;
}

/// Is flow entry `j` consumed by a RUNTIME-selected potential row over the
/// same branch? Then its retained value reaches KCL through the branch
/// unknown (row `I_b − value`, stamps ±I_b), and stamping it here as well
/// would inject the current twice. Asserts that `j` indexes a contribution.
pub fn flowIsMerged(self: Input, j: usize) bool {
    assert(j < self.lowered.contributions.items.len);
    const f = self.lowered.contributions.items[j];
    if (f.kind != .direct or f.access != .flow) return false;
    for (self.lowered.contributions.items) |c| {
        if (c.kind != .direct or c.access != .potential) continue;
        if (c.hi != f.hi or c.lo != f.lo or c.br != f.br) continue;
        return retention(self, c) == .runtime;
    }
    return false;
}

/// §1.3.4/§3.6.2.2. Returns the contribution's net when that net is a
/// signal-flow port: a directional (`input`/`output`, §6.5.2.2) port whose
/// discipline binds only one nature, which has no conserved pair for a nodal
/// device to stamp. A single-nature `inout` port is rejected by lowering
/// (E0132, §1.3.4.1/§1.3.4.2); an internal net stamps as usual (§3.9).
///
/// §1.3.4.2's flow-only net is the one case the ordinary nodal stamp gets
/// wrong. Such a net has no potential (§1.3.4: "Potential for such a node is
/// not defined"), so the node's single unknown carries the flow, and
/// `I(out) <+ e` is the equation `x[out] - e = 0`, not a KCL injection.
/// §1.3.4.1's potential-only net needs nothing special: the KCL row at the net
/// is `ib = 0`, which leaves the branch row `V(out) - e = 0` to fix the
/// potential.
pub fn flowOnlySignalFlowNet(self: Input, c: Lower.Contribution) ?u32 {
    if (c.access != .flow or c.kind != .direct) return null;
    for ([_]u32{ c.hi, c.lo }) |n| {
        if (n >= self.lowered.nodes.len) continue; // ground
        switch (self.lowered.nodes.items(.dir)[n]) {
            .input, .output => {},
            .unspecified, .inout => continue,
        }
        const dname = self.lowered.nodes.items(.disc)[n];
        if (dname.len == 0) continue;
        const d = self.lowered.disciplines.get(dname) orelse continue;
        if (!d.has_potential and d.has_flow) {
            assert(n < self.lowered.nodes.len);
            return n;
        }
    }
    return null;
}

/// Is unknown `i` a flow (a current) rather than a potential?
pub fn isFlowUnknown(self: Input, i: u32) bool {
    if (i >= self.lowered.nodes.len) return true; // codegen-added branch current
    // §5.4.2/§5.4.3 lowering records the kind where it creates the slot; the
    // name cannot decide it, since §2.8.1 lets a net be declared `\flow(p,n)`.
    switch (self.lowered.nodes.items(.kind)[i]) {
        .net => {},
        .branch_flow, .port_flow => return true,
        .op_state => return false,
    }
    // §1.3.4.2 a flow signal-flow net has no potential ("Potential for such
    // a node is not defined"), so its one unknown is a flow even though it
    // is a plain node. Every caller (the host's `u_kinds`, the §3.6.1.2
    // tolerance, §4.5.15's refusal to `$limit` a current) wants the quantity,
    // not the spelling.
    const dname = self.lowered.nodes.items(.disc)[i];
    if (dname.len == 0) return false;
    const d = self.lowered.disciplines.get(dname) orelse return false;
    return d.has_flow and !d.has_potential;
}

/// One collapsible §5.6.5 switch branch: when `flag` (a §5.6.1.3
/// retention flag, carried as a core field) is nonzero at build time,
/// the host aliases unknown `victim` and the branch-flow unknown
/// `flow_u` onto unknown `target`. Indices are `nodes`/U-enum space.
/// `card`: the flag is a function of the model card alone (`cardOnly`), so
/// `derive` can publish it as a `Model` field (the `jac_const` guard).
pub const CollapsePair = struct { victim: u32, target: u32, flow_u: u32, flag: Mir.Value, card: bool = false };

/// A §5.4.2 branch-flow unknown that no branch row defines.
///
/// Lowering mints one whenever the model reads `I(a,b)`, and only a §5.6
/// potential (or §5.6.7 indirect) contribution on the same pair gives it a
/// defining row (`branch_u`). What is left is two shapes the LRM states
/// outright, each needing its own row:
///
///   `sourced`: §5.6.6 implicit contribution. `I(b) <+ f(..., I(b))` reads
///   the unknown on its own right-hand side, and "the underlying
///   implementation of the simulator will find the value of I(diode) that
///   equals the sum of the contributions made to it". The row is
///   `x[u] - sum(contributions) = 0`; without it the self-reference
///   evaluates to 0 and the model is silently linearised.
///
///   not `sourced`: §5.4.2.1 flow probe. "If the flow of the branch appears
///   in an expression anywhere in the module, the branch is a flow probe ...
///   The branch potential of a flow probe is zero (0)." Figure 5-1 draws the
///   ammeter: the probe is a short, so its row is `V(hi) - V(lo) = 0` and its
///   current enters KCL at both ends.
const FreeFlow = struct { u: u32, hi: u32, lo: u32, sourced: bool };

/// `free_flows`, in unknown-slot order (`flow_unknowns` is a hash map, and
/// its iteration order is not the emitted order). Asserts that `branch_u`
/// has one entry per contribution.
fn freeFlows(self: Input, branch_u: []const u32) Error![]const FreeFlow {
    assert(branch_u.len == self.lowered.contributions.items.len);
    var out: std.ArrayList(FreeFlow) = .empty;
    var it = self.lowered.flow_unknowns.iterator();
    while (it.next()) |e| {
        const u: u32 = e.value_ptr.*;
        // A potential/indirect source already pins this current.
        if (std.mem.findScalar(u32, branch_u, u) != null) continue;
        var sourced = false;
        var signal_flow = false;
        for (self.lowered.contributions.items) |c| {
            if (c.kind != .direct or c.access != .flow) continue;
            if (c.hi != e.key_ptr.hi or c.lo != e.key_ptr.lo) continue;
            sourced = true;
            // §1.3.4.2 a flow-only signal-flow net's one unknown IS its
            // flow and the contribution already writes that row.
            if (flowOnlySignalFlowNet(self, c) != null) signal_flow = true;
        }
        if (signal_flow) continue;
        try out.append(self.arena, .{
            .u = u,
            .hi = e.key_ptr.hi,
            .lo = e.key_ptr.lo,
            .sourced = sourced,
        });
    }
    std.mem.sort(FreeFlow, out.items, {}, struct {
        fn lt(_: void, x: FreeFlow, y: FreeFlow) bool {
            return x.u < y.u;
        }
    }.lt);
    assert(out.items.len <= self.lowered.flow_unknowns.count());
    return out.items;
}

/// Is `v` a constant of the whole simulation, a function of Model and
/// Instance-at-build and nothing else? Stricter than `Analysis.dFree`,
/// which admits x-steered selects between constants (its ternary/phi
/// rule ignores the condition), and than `Analysis.xDep`, which asks only
/// whether x moves the value; a collapse decision taken once at build
/// must not move at all. Calls are allowlisted for that reason: `$abstime`, rng
/// draws, `$held_*` seeds and `analysis()` all change between
/// evaluations, so a new operator is unsound here until shown otherwise.
///
/// The phi rule leans on lowering's structured CFGs: the branch at the
/// join's immediate dominator is what steers a diamond's phi, and any
/// NESTED x-dependent steering surfaces as an inner phi in the incoming
/// values, which recursion refuses. Loop-carried phis are refused
/// outright.
fn buildFree(self: Input, v0: Mir.Value, depth: u32) bool {
    var budget: u32 = max_visits;
    return constFree(self, v0, depth, true, &budget);
}

/// `buildFree` without the Instance: no §9.10 `$temperature`/`$vt`, no
/// §6.3.6 `$mfactor`. What is left is a function of the model card, which
/// `derive` (it has no Instance) can compute.
fn cardOnly(self: Input, v0: Mir.Value) bool {
    var budget: u32 = max_visits;
    return constFree(self, v0, 0, false, &budget);
}

/// The most operand visits one `constFree` walk makes before it answers
/// false (the safe side: no collapse, or no guard). The walk does not
/// memoize, so a DAG that shares its operands (`x = x*x + x` repeated) is
/// exponential in its depth, and the depth cap alone still allows 2^64.
const max_visits = 1 << 16;

fn constFree(self: Input, v0: Mir.Value, depth: u32, env: bool, budget: *u32) bool {
    if (depth > 64 or budget.* == 0) return false;
    budget.* -= 1;
    const v = self.an.rv(v0);
    switch (self.mir.valueDef(v)) {
        .undef, .float_const, .int_const, .str_const, .param_ref => return true,
        .block_param => return false, // §4.4 probe: x by definition
        .inst_result => |inst| {
            const row = self.mir.instRow(inst);
            switch (Mir.opClass(row.op)) {
                // §3.2.2 array storage is written per evaluation (and a held
                // one carries the last accepted point): refused, like a call
                // off the allowlist.
                .branch, .jump, .anew, .load, .store => return false,
                .unary => return constFree(self, @fromBackingInt(@intCast(row.a)), depth + 1, env, budget),
                .binary => return constFree(self, @fromBackingInt(@intCast(row.a)), depth + 1, env, budget) and
                    constFree(self, @fromBackingInt(@intCast(row.b)), depth + 1, env, budget),
                .ternary => {
                    const d = self.mir.instData(inst).ternary;
                    return constFree(self, d.cond, depth + 1, env, budget) and
                        constFree(self, d.then_val, depth + 1, env, budget) and
                        constFree(self, d.else_val, depth + 1, env, budget);
                },
                .call => {
                    const d = self.mir.instData(inst).call;
                    switch (d.callee) {
                        .@"$param_given" => {},
                        .@"$temperature", .@"$vt", .@"$mfactor" => if (!env) return false,
                        else => return false, // else: ALLOWLISTED (above) — a new callee is unsound here until shown otherwise
                    }
                    for (d.args) |arg| {
                        if (!constFree(self, arg, depth + 1, env, budget)) return false;
                    }
                    return true;
                },
                .phi => {
                    const blk = self.an.def_block[@backingInt(v)];
                    if (blk == none_u32 or self.an.inLoop(blk)) return false;
                    const id = self.an.idom[blk];
                    if (id == none_u32) return false;
                    const ti = self.an.term[id];
                    if (ti == .none) return false;
                    const t = self.mir.instData(ti);
                    if (t != .branch) return false;
                    if (!constFree(self, t.branch.cond, depth + 1, env, budget)) return false;
                    const d = self.mir.instData(inst).phi;
                    for (0..d.count) |k| {
                        if (!constFree(self, self.mir.phiPair(inst, @intCast(k)).value, depth + 1, env, budget)) return false;
                    }
                    return true;
                },
            }
        },
    }
}

/// Is `v` zero on every path: `.f_zero`, a fold to 0.0, or a phi or select
/// all of whose arms are? The accumulator of a §5.6.5 potential arm contributing
/// `<+ 0.0` is exactly this shape: entry-seeded 0, `discardOpposite`'s 0
/// on the flow arm, `0 + 0.0` on its own.
fn zeroOnEveryPath(self: Input, v0: Mir.Value, depth: u32) bool {
    if (depth > 16) return false;
    const v = self.an.rv(v0);
    if (v == .f_zero) return true;
    if (self.an.foldConst(v, false)) |k| return k == 0.0;
    const def = self.mir.valueDef(v);
    if (def != .inst_result) return false;
    const op = self.mir.instRow(def.inst_result).op;
    if (op == .phi) {
        const d = self.mir.instData(def.inst_result).phi;
        for (0..d.count) |k| {
            if (!zeroOnEveryPath(self, self.mir.phiPair(def.inst_result, @intCast(k)).value, depth + 1)) return false;
        }
        return true;
    }
    // The same join after if-conversion (prove/ifconv.zig): a diamond's phi
    // becomes `select(c, then, else)`, zero on every path exactly when both
    // arms are, so a collapse does not depend on whether ifconv converted
    // the diamond.
    if (op == .select) {
        const d = self.mir.instData(def.inst_result).ternary;
        return zeroOnEveryPath(self, d.then_val, depth + 1) and zeroOnEveryPath(self, d.else_val, depth + 1);
    }
    return false;
}

/// Does any MIR value read unknown `u` (a §4.4/§5.4.2 probe of it)? Every
/// read of an unknown is its `block_param` value, so this is a scan of the
/// value table, run once per collapse candidate (a model has few).
fn unknownProbed(self: Input, u: u32) bool {
    for (Mir.Value.first_dynamic..self.an.nv) |i| {
        const def = self.mir.valueDef(@fromBackingInt(@intCast(i)));
        if (def == .block_param and def.block_param == u) return true;
    }
    return false;
}

/// The §5.6.5 switch branches this model can collapse: runtime-selected
/// potential rows whose retained value is the constant 0 V and 0 flux (a
/// selected nonzero source is a real source, not a short) and whose retention
/// flag is fixed at build time (`buildFree`). ngspice does the same in its
/// setup routines (DIOsetup: `posPrimeNode = posNode` when RS == 0); keeping
/// the pair apart behind a selected 0 V short costs the host an unknown, a
/// branch row, and catastrophic cancellation when its LU eliminates the short.
/// Asserts that `branch_u` has one entry per contribution.
fn collapsePairs(self: Input, branch_u: []const u32) Error![]CollapsePair {
    assert(branch_u.len == self.lowered.contributions.items.len);
    var out: std.ArrayList(CollapsePair) = .empty;
    const np: u32 = @intCast(self.lowered.num_ports);
    for (self.lowered.contributions.items, 0..) |c, i| {
        if (c.kind != .direct or c.access != .potential) continue;
        const ret = retention(self, c);
        if (ret != .runtime) continue;
        if (!buildFree(self, ret.runtime, 0)) continue;
        if (!zeroOnEveryPath(self, c.resist_val, 0)) continue;
        if (!zeroOnEveryPath(self, c.react_val, 0)) continue;
        const fu = branch_u[i];
        if (fu == none_u32) continue;
        // §5.4.2 a flow probe of the branch reads I_b, which `collapse` turns
        // into the far node's VOLTAGE: the model would read that, not its
        // current. Such a branch keeps its row (static_switch_elision.va).
        if (unknownProbed(self, fu)) continue;
        // Only a non-port internal node is the host's to move, and only
        // onto a real unknown (§1.3.1.1 ground has none). The host
        // resolves aliases in ascending unknown order, so the target
        // must precede both movers.
        const hi_free = c.hi != Lower.ground and c.hi >= np;
        const lo_free = c.lo != Lower.ground and c.lo >= np;
        if (!hi_free and !lo_free) continue;
        const victim: u32 = if (hi_free and lo_free) @max(c.hi, c.lo) else if (hi_free) c.hi else c.lo;
        const target: u32 = if (hi_free and lo_free) @min(c.hi, c.lo) else if (hi_free) c.lo else c.hi;
        if (target == Lower.ground) continue;
        if (target >= victim or target >= fu) continue;
        // The host aliases in ascending unknown order (above): the target
        // precedes both movers, and is never the ground.
        assert(target < victim);
        assert(target < fu);
        assert(victim >= np);
        try out.append(self.arena, .{ .victim = victim, .target = target, .flow_u = fu, .flag = ret.runtime, .card = cardOnly(self, ret.runtime) });
    }
    assert(out.items.len <= self.lowered.contributions.items.len);
    return out.items;
}

const Fixture = @import("prove").Fixture;

test "a probed flow no source defines is free; one a potential source drives is not" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{ "a", "b", "flow(a,b)", "flow(b,0)" });
    defer f.deinit();
    const a = f.alloc();
    f.lowered.nodes.items(.kind)[2] = .{ .branch_flow = 0 };
    f.lowered.nodes.items(.kind)[3] = .{ .branch_flow = 1 };
    try f.lowered.flow_unknowns.put(a, .{ .hi = 0, .lo = 1 }, 2);
    try f.lowered.flow_unknowns.put(a, .{ .hi = 1, .lo = Lower.ground }, 3);
    // I(a,b) <+ …  sources the (a,b) flow; V(b) <+ …  drives (b,0)'s current.
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 0, .lo = 1 });
    try f.lowered.contributions.append(a, .{ .access = .potential, .hi = 1, .lo = Lower.ground });
    const an = try f.analysis();

    const t = try plan(.{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered }, &.{ none_u32, 3 });
    try std.testing.expectEqual(@as(usize, 1), t.free_flows.len);
    try std.testing.expectEqual(FreeFlow{ .u = 2, .hi = 0, .lo = 1, .sourced = true }, t.free_flows[0]);
    try std.testing.expectEqual(@as(?FreeFlow, null), t.freeFlowOf(1, Lower.ground));
    // No runtime-retained potential row, so nothing collapses.
    try std.testing.expectEqual(@as(usize, 0), t.cpairs.len);
}

test "free flows come out in unknown order, unsourced when only probed, and skip a signal-flow net" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{ "a", "b", "o", "flow(b,a)", "flow(a,b)", "flow(o)" });
    defer f.deinit();
    const a = f.alloc();
    // `o` is an output port of a flow-only discipline (§1.3.4.2).
    try f.lowered.disciplines.put(a, "current", .{ .has_flow = true });
    f.lowered.nodes.items(.disc)[2] = "current";
    f.lowered.nodes.items(.dir)[2] = .output;
    // Inserted highest unknown first: the hash map's order is not the answer.
    try f.lowered.flow_unknowns.put(a, .{ .hi = 2, .lo = Lower.ground }, 5);
    try f.lowered.flow_unknowns.put(a, .{ .hi = 0, .lo = 1 }, 4);
    try f.lowered.flow_unknowns.put(a, .{ .hi = 1, .lo = 0 }, 3);
    // I(a,b) <+ … sources (a,b); (b,a) is only probed; I(o) <+ … writes o's own row.
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 0, .lo = 1 });
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 2, .lo = Lower.ground });
    const an = try f.analysis();
    const in: Input = .{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered };

    const ff = try freeFlows(in, &.{ none_u32, none_u32 });
    try std.testing.expectEqualSlices(FreeFlow, &.{
        .{ .u = 3, .hi = 1, .lo = 0, .sourced = false },
        .{ .u = 4, .hi = 0, .lo = 1, .sourced = true },
    }, ff);
    try std.testing.expectEqual(@as(?u32, 2), flowOnlySignalFlowNet(in, f.lowered.contributions.items[1]));
    try std.testing.expectEqual(@as(?u32, null), flowOnlySignalFlowNet(in, f.lowered.contributions.items[0]));
}

test "isFlowUnknown answers the quantity, not the spelling" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    // A net literally named `flow(p,n)` (§2.8.1) is still a potential.
    try f.init(&.{ "flow(p,n)", "ib", "ip", "st", "sig" });
    defer f.deinit();
    const a = f.alloc();
    f.lowered.nodes.items(.kind)[1] = .{ .branch_flow = 0 };
    f.lowered.nodes.items(.kind)[2] = .{ .port_flow = 0 };
    f.lowered.nodes.items(.kind)[3] = .{ .op_state = 1e-6 };
    try f.lowered.disciplines.put(a, "current", .{ .has_flow = true });
    f.lowered.nodes.items(.disc)[4] = "current";
    const an = try f.analysis();
    const in: Input = .{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered };
    try std.testing.expect(!isFlowUnknown(in, 0));
    try std.testing.expect(isFlowUnknown(in, 1));
    try std.testing.expect(isFlowUnknown(in, 2));
    try std.testing.expect(!isFlowUnknown(in, 3));
    // §1.3.4.2 a flow-only net's one unknown is a flow.
    try std.testing.expect(isFlowUnknown(in, 4));
    // A branch current codegen appends past `nodes`.
    try std.testing.expect(isFlowUnknown(in, 5));
}

test "§5.6.1.3 retention reads the folded flag; a runtime flag merges its switch partner" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{ "a", "b" });
    defer f.deinit();
    const a = f.alloc();
    const sel = try f.mir.emit(a, .entry, .fgt, &.{ try f.probe(0), .f_zero });
    // 0: V(a,b) retained by a runtime flag; 1: I(a,b) its §5.6.5 partner;
    // 2: I(a,b) on a named branch, not the partner.
    try f.lowered.contributions.append(a, .{ .access = .potential, .hi = 0, .lo = 1, .wrote_val = sel });
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 0, .lo = 1, .wrote_val = .f_one });
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 0, .lo = 1, .br = 5, .wrote_val = .zero });
    const an = try f.analysis();
    const in: Input = .{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered };
    const cs = f.lowered.contributions.items;
    try std.testing.expectEqual(Retention{ .runtime = sel }, retention(in, cs[0]));
    try std.testing.expectEqual(Retention.on, retention(in, cs[1]));
    try std.testing.expectEqual(Retention.off, retention(in, cs[2])); // integer 0 folds too
    try std.testing.expectEqual(@as(?usize, 1), switchFlowOf(in, 0));
    try std.testing.expect(flowIsMerged(in, 1));
    try std.testing.expect(!flowIsMerged(in, 2));
    try std.testing.expect(!flowIsMerged(in, 0)); // a potential entry is never merged
}

test "zeroOnEveryPath: a select or phi of zeros is zero; one nonzero arm is not" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{"a"});
    defer f.deinit();
    const a = f.alloc();
    const c = try f.mir.emit(a, .entry, .fgt, &.{ try f.probe(0), .f_zero });
    const zz = try f.mir.emit(a, .entry, .select, &.{ c, .f_zero, .zero });
    const z1 = try f.mir.emit(a, .entry, .select, &.{ c, .f_zero, .f_one });
    const nested = try f.mir.emit(a, .entry, .select, &.{ c, zz, .f_zero });
    const then_b = try f.mir.addBlock(a);
    const join = try f.mir.addBlock(a);
    _ = try f.mir.emitBranch(a, .entry, c, then_b, join);
    _ = try f.mir.emitJump(a, then_b, join);
    const phi = try f.mir.emitPhi(a, join, &.{ .{ .block = .entry, .value = .f_zero }, .{ .block = then_b, .value = zz } });
    const an = try f.analysis();
    const in: Input = .{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered };
    try std.testing.expect(zeroOnEveryPath(in, zz, 0));
    try std.testing.expect(!zeroOnEveryPath(in, z1, 0));
    try std.testing.expect(zeroOnEveryPath(in, nested, 0));
    try std.testing.expect(zeroOnEveryPath(in, phi, 0));
    // The walk gives up past depth 16: unknown is not zero.
    try std.testing.expect(!zeroOnEveryPath(in, nested, 17));
    try std.testing.expect(!zeroOnEveryPath(in, c, 0));
}

/// A V(a,b) switch row retained under `flag`, its `<+ 0` arm, and branch
/// current 3; nets p (a port), a, b. Returns the planned pairs.
fn switchPairs(f: *Fixture, flag_of: enum { param, temperature, probe }, probe_flow: bool) ![]CollapsePair {
    const a = f.alloc();
    f.lowered.num_ports = 1;
    try f.lowered.params.append(a, .{ .name = "rs", .ty = .real, .default = .f_zero });
    const x = switch (flag_of) {
        .param => try f.mir.addParamRef(a, 0),
        .temperature => try f.call("$temperature", &.{}),
        .probe => try f.probe(1),
    };
    const flag = try f.mir.emit(a, .entry, .select, &.{ try f.mir.emit(a, .entry, .fgt, &.{ x, .f_zero }), .f_one, .f_zero });
    if (probe_flow) _ = try f.probe(3);
    try f.lowered.contributions.append(a, .{ .access = .potential, .hi = 1, .lo = 2, .wrote_val = flag });
    const an = try f.analysis();
    return collapsePairs(.{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered }, &.{3});
}

test "collapsePairs: a build-time 0 V switch collapses the higher internal net onto the lower" {
    {
        var f: Fixture = .{ .arena = .init(std.testing.allocator) };
        try f.init(&.{ "p", "a", "b", "flow(a,b)" });
        defer f.deinit();
        const ps = try switchPairs(&f, .param, false);
        try std.testing.expectEqual(@as(usize, 1), ps.len);
        try std.testing.expectEqual(@as(u32, 2), ps[0].victim);
        try std.testing.expectEqual(@as(u32, 1), ps[0].target);
        try std.testing.expectEqual(@as(u32, 3), ps[0].flow_u);
        // A function of the card alone: `derive` can publish it.
        try std.testing.expect(ps[0].card);
    }
    {
        // $temperature is fixed at build, but it is the instance's, not the card's.
        var f: Fixture = .{ .arena = .init(std.testing.allocator) };
        try f.init(&.{ "p", "a", "b", "flow(a,b)" });
        defer f.deinit();
        const ps = try switchPairs(&f, .temperature, false);
        try std.testing.expectEqual(@as(usize, 1), ps.len);
        try std.testing.expect(!ps[0].card);
    }
    {
        // A flag a probe steers changes per iterate: no build-time collapse.
        var f: Fixture = .{ .arena = .init(std.testing.allocator) };
        try f.init(&.{ "p", "a", "b", "flow(a,b)" });
        defer f.deinit();
        try std.testing.expectEqual(@as(usize, 0), (try switchPairs(&f, .probe, false)).len);
    }
    {
        // §5.4.2 the model reads I(a,b): collapsing would hand it a voltage.
        var f: Fixture = .{ .arena = .init(std.testing.allocator) };
        try f.init(&.{ "p", "a", "b", "flow(a,b)" });
        defer f.deinit();
        try std.testing.expectEqual(@as(usize, 0), (try switchPairs(&f, .param, true)).len);
    }
}

test "buildFree refuses a call off the allowlist and an operand chain deeper than 64" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{"a"});
    defer f.deinit();
    const a = f.alloc();
    const t = try f.call("$abstime", &.{});
    var chain = try f.mir.addFloatConst(a, 0.5);
    for (0..10) |_| chain = try f.mir.emit(a, .entry, .fneg, &.{chain});
    const short = chain;
    for (0..60) |_| chain = try f.mir.emit(a, .entry, .fneg, &.{chain});
    const an = try f.analysis();
    const in: Input = .{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered };
    // §9.15 time moves between evaluations.
    try std.testing.expect(!buildFree(in, t, 0));
    // Ten negations of a literal are a build-time constant; seventy are past
    // the depth the walk follows, and unknown is not constant.
    try std.testing.expect(buildFree(in, short, 0));
    try std.testing.expect(!buildFree(in, chain, 0));
}
