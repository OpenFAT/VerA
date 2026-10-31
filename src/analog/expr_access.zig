const std = @import("std");
const Lower = @import("Lower.zig");
const lower_analog_op = @import("analog_op.zig");
const lower_contrib = @import("contrib.zig");
const lower_hier_name = @import("hier_name.zig");
const lower_node = @import("node.zig");
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Elaborate = @import("elab").Elaborate;
const diag = @import("diag");
const lower_expr = @import("expr.zig");
const Oom = Lower.Oom;
const ground = Lower.ground;
const TypedValue = Lower.TypedValue;
const Accum = Lower.Accum;
const poison = Lower.poison;

/// §4.4.1 access function: `V(a)`, `V(a,b)`, `I(br)`.
/// A potential is the difference of two node unknowns; a flow that is *read*
/// makes the branch current an unknown of its own (§5.4.2).
pub fn lowerBranchAccess(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    if (self.restrict) |ctx| {
        try self.err(self.file.exprs.mainTok(e), .E0421, "not allowed in {s}", .{ctx});
        return poison;
    }
    // VerA's `vera_timepoint` (§2.9): a probe is the iterate.
    if (self.tp_cur != null) {
        try self.err(self.file.exprs.mainTok(e), .E0530, "a probe (§4.4)", .{});
        return poison;
    }
    // §3.12.1: a port branch names the §5.4.3 port flow, so `I(pb)` and
    // `I(<p>)` are one quantity and read the one unknown. Ahead of `branchOf`
    // because the name is not in `branches` and would otherwise fall through to
    // `nodeOf` and become an implicit net.
    if (try lower_contrib.portBranchOf(self, e)) |p| return portFlowRead(self, e, p);
    const t = try lower_contrib.branchOf(self, e) orelse return poison;
    try self.branch_reads.append(self.arena, .{
        .access = t.access,
        .hi = t.hi,
        .lo = t.lo,
        .tok = self.file.exprs.mainTok(e),
    });
    // §1.3.1.2: the reversed spelling of a branch is the same quantity with the
    // opposite sign. For the potential that is just which way the subtraction
    // runs; for the flow it is the whole point — `t` has already been
    // canonicalised, so `I(n,p)` reads the ONE `flow(p,n)` unknown negated
    // instead of minting a second, independent one that nothing constrains.
    switch (t.access) {
        .potential => {
            // §9.20 through `aliasProbe`: a parameter may choose the node.
            const hi = try lower_hier_name.aliasProbe(self, t.hi);
            if (t.lo == ground)
                return .{ .v = if (t.neg) try self.emit(.fneg, &.{hi}) else hi, .ty = .real };
            const lo = try lower_hier_name.aliasProbe(self, t.lo);
            const d = if (t.neg) [2]Mir.Value{ lo, hi } else [2]Mir.Value{ hi, lo };
            return .{ .v = try self.emit(.fsub, &d), .ty = .real };
        },
        .flow => {
            try lower_hier_name.refuseRuntime(self, self.file.exprs.mainTok(e), t.hi, t.lo);
            // §5.4.2.2 "Both the potential and the flow of a source branch are
            // accessible in expressions anywhere in the module." A flow
            // source's branch flow has no row pinning an unknown, so the read
            // is the value retained on the branch (§5.6.1.2): the accumulator
            // at `self.cur`. An ordinary expression reads mid-block and sees
            // sequential retention; a §9.4 display operand is lowered from
            // `lowerDeferredDisplays` past the whole block and sees the
            // converged end-of-cycle value, retention-select phis included.
            //
            // §5.6.6 first: inside a `<+`'s own right-hand side, a read of the
            // same branch is the implicit form, whose value is the branch-flow
            // unknown, never the retained prefix. Checked ahead of `flowAccum`
            // because `contribIndex` has already created the statement's own
            // entry. Codegen's `FreeFlow` row defines the unknown,
            // `x[u] − Σ contributions = 0`, like `portFlowRead`'s for `I(<p>)`.
            const implicit = if (self.contrib_target) |ct|
                ct.access == .flow and ct.hi == t.hi and ct.lo == t.lo and ct.br == t.br
            else
                false;
            // Only once a flow contribution has already been lowered onto this
            // pair. An uncontributed branch is a §5.4.2.1 flow probe, and a
            // potential source's branch current is pinned by its branch row;
            // both read the unknown, including §5.6.8.1's hierarchical case
            // (`potentialSourceHere`).
            if (!implicit and !potentialSourceHere(self, t)) if (flowAccum(self, t)) |acc| {
                // §5.6.1.2: the retained value of a source branch is the whole
                // of what was contributed to it, reactive half included.
                //
                // The reactive half is retained as a charge, so reading the
                // flow back differentiates it again with a second `ddt`
                // instance of its own. Only when there is a reactive half: a
                // resistive branch emits no operator and cannot trip §5.8.1's
                // conditional-operator rule.
                const r = try self.builder.readVariable(acc.resist, self.cur);
                const q = try self.builder.readVariable(acc.react, self.cur);
                const v = if (q == .f_zero) r else blk: {
                    // The charge's own sites already carry its truncation check.
                    const dq = try lower_analog_op.opDdt(self, self.file.exprs.mainTok(e), q, flowAbstol(self, t.hi), false);
                    break :blk if (r == .f_zero) dq else try self.emit(.fadd, &.{ r, dq });
                };
                return .{ .v = if (t.neg) try self.emit(.fneg, &.{v}) else v, .ty = .real };
            };
            const u = try lower_node.flowUnknown(self, t.hi, t.lo);
            const v = try lower_node.probe(self, u);
            return .{ .v = if (t.neg) try self.emit(.fneg, &.{v}) else v, .ty = .real };
        },
    }
}

/// The §5.6.1.2 retained-flow accumulator of the branch (hi, lo), if a `<+` has
/// already made it a flow source. Keyed exactly like `contribIndex` — on the
/// canonicalised pair, so `I(n,p)` finds the one entry `I(p,n)` created.
///
/// Not keyed on the unit, unlike `discardOpposite`: §5.5.5 lets "a module
/// access the potential and flow of a branch in another module instance ...
/// providing that value is available in the other instance", and a hierarchical
/// `I(x1.p, x1.n)` is exactly that read. §5.5.4's new-branch rule is about the
/// access functions whose examples are all POTENTIAL probes, which draw no flow
/// — see `potentialSourceHere` for the case where this unit's OWN source is the
/// branch being read.
fn flowAccum(self: *const Lower, t: lower_contrib.Target) ?Accum {
    const i = lower_contrib.directRow(self, .{ .access = .flow, .hi = t.hi, .lo = t.lo, .br = t.br }) orelse return null;
    // §5.6.8.2/§6.7.1 an instance's own unnamed branch, when several share
    // the row. An instance that contributed nothing to the pair reads the
    // row, as a parent reading its child's flow always has.
    if (self.out.contributions.items[i].shared and t.br == Lower.unnamed_branch)
        if (self.unit_accum.get(.{ .row = i, .unit = t.unit })) |pa| return pa;
    return self.accum.items[i];
}

/// §3.6.1.2 the flow tolerance of the discipline at node `n`, which is what
/// codegen's `abstolOf` gives a branch current; annex D's 1e-12 without one.
fn flowAbstol(self: *const Lower, n: u32) f64 {
    if (n == ground) return 1e-12;
    const info = self.out.disciplines.get(self.out.nodes.items(.disc)[n]) orelse return 1e-12;
    return info.flow_abstol;
}

/// §5.6.8.1: "Direct contribution statements can contribute to a branch between
/// combinations of local and hierarchical nets. In these cases, a new unnamed
/// branch is created in the module containing the direct contribution
/// statements." So a potential `<+` written here is a source branch of this
/// instance, in parallel with whatever another instance retained over the same
/// node pair: §5.4.1's "only one unnamed branch between any two nets" is a
/// per-instance rule, and flattening has already collapsed the pairs.
///
/// The flow of that source is the branch-current unknown codegen pins with its
/// branch row, never the parallel branch's accumulator, which would read back
/// the child's conduction current.
///
/// `unit` is the id of the contribution that opened the entry (see its doc), so
/// a second instance potential-sourcing a pair another already sources reads the
/// accumulator instead — two ideal potential sources in parallel is a degenerate
/// topology the clause does not describe either way.
fn potentialSourceHere(self: *const Lower, t: lower_contrib.Target) bool {
    for (self.out.contributions.items) |c| {
        if (c.kind == .direct and c.access == .potential and c.hi == t.hi and c.lo == t.lo and
            c.br == t.br and c.unit == self.cur_unit) return true;
    }
    return false;
}

/// LRM §5.4.3 port access — `I(<p>)`.
///
/// "The port access function accesses the flow into a port of a module. ...
/// However (<>) is used to delimit the port name, e.g., I(<a>) accesses the
/// current through module port a."
///
/// By KCL that current is the sum of everything this module stamps at `p`, the
/// residual codegen is assembling, so it cannot be an expression over the other
/// units without a cycle. It becomes its own solver unknown, like the §5.4.2
/// branch-flow unknown, and codegen pins it with the row `x[u] − Σ stamps at p`.
pub fn lowerPortAccess(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    if (self.restrict) |ctx| {
        try self.err(self.file.exprs.mainTok(e), .E0421, "not allowed in {s}", .{ctx});
        return poison;
    }
    // VerA's `vera_timepoint` (§2.9): a probe is the iterate.
    if (self.tp_cur != null) {
        try self.err(self.file.exprs.mainTok(e), .E0530, "a probe (§4.4)", .{});
        return poison;
    }
    if (try instancePortFlow(self, e)) |tv| return tv;
    const p = try nodeUnrefused(self, self.file.exprs.lhs(e)) orelse return poison;
    return portFlowRead(self, e, p);
}

/// `nodeOf`, or null when it refused the terminal (E0351/E0352). It stands
/// ground in for a refused one, and ground is no port: a caller that went on
/// would report the same mistake a second time, as E0508.
fn nodeUnrefused(self: *Lower, e: Ast.ExprId) Oom!?u32 {
    const had = self.had_error;
    self.had_error = false;
    const p = try lower_node.nodeOf(self, e);
    const refused = self.had_error;
    self.had_error = had or refused;
    return if (refused) null else p;
}

/// §5.4.3 "The port access function accesses the flow into a port of a
/// module", and A.8.9 lets the port be hierarchical
/// (`analog_port_reference ::= hierarchical_port_identifier`; §6.7.1 "flow
/// access for ... port branches can be done hierarchically"): `I(<u.p>)` is
/// the flow into instance `u` through its own port `p`, not the flow through
/// the net `p` is joined to. By KCL it is what `u`'s hierarchy conducts away
/// from that net: the sum of the flow contributions its units made to
/// branches touching the net, an instance's own share of a row several
/// instances share (`unit_accum`, §5.6.8.2), the reactive half through one
/// `ddt`. Null when `e`'s port is not hierarchical (the module's own port).
///
/// Read as a sum of accumulators, so every block of `u`'s hierarchy must be
/// lowered before the read, and every branch of it at the net must be a flow
/// source: a potential source's or an indirect branch's current is a solver
/// unknown whose static retention codegen decides. Either case is E0997.
fn instancePortFlow(self: *Lower, e: Ast.ExprId) Oom!?TypedValue {
    const ex = &self.file.exprs;
    const lhs = ex.lhs(e);
    if (ex.tag(lhs) != .hier_ident) return null;
    const path = try Elaborate.flatReference(self.file, self.arena, self.module, lhs);
    const cut = std.mem.findScalarLast(u8, path, Elaborate.sep) orelse return null;
    const inst = path[0 .. cut + 1];
    const units = self.design.units;
    const lo: u32 = for (units, 0..) |u, i| {
        if (std.mem.eql(u8, u.path, inst)) break @intCast(i);
    } else return null;
    // Units are numbered depth first, so `inst`'s hierarchy is one run.
    var hi = lo + 1;
    while (hi < units.len and std.mem.startsWith(u8, units[hi].path, inst)) hi += 1;
    const port_name = path[cut + 1 ..];
    const decl = units[lo].decl;
    for (decl.ports) |pt| {
        if (std.mem.eql(u8, self.file.str(pt.name), port_name)) break;
    } else {
        try self.err(ex.mainTok(e), .E0508, "`{s}` is not a port of `{s}`", .{ path, self.file.str(decl.name) });
        return poison;
    }
    const name = self.file.str(ex.strOf(e));
    const global = self.access_kind.get(name) orelse return null; // `portFlowRead` names it (E0501)
    if (global == .potential and !self.access_both.contains(name)) return null; // and this (E0507)
    const p = try nodeUnrefused(self, lhs) orelse return poison;
    const access = try lower_contrib.accessOn(self, e, name, global, p, Lower.ground);
    if (access == .potential) return null;
    try lower_contrib.checkAccessMatch(self, e, name, access, p);
    if (try ammeterFlow(self, lower_node.nodeName(self, p))) |tv| return tv;
    // Every block of the hierarchy is behind this one.
    for (self.cur_block..self.module.?.analog.len) |j| {
        const unit = self.module.?.analog[j].unit;
        if (unit < lo or unit >= hi) continue;
        var b = self.errWith(ex.mainTok(e), .E0997);
        b.msg("`{s}(<{s}>)` is read before `{s}`'s own analog blocks are lowered", .{ name, path, inst[0 .. inst.len - 1] });
        b.note("VerA sums the instance's contributions at the port; read it from a module instantiated above it, after it", .{});
        try b.emit();
        return poison;
    }
    var resist: Mir.Value = .f_zero;
    var react: Mir.Value = .f_zero;
    for (self.out.contributions.items, self.accum.items, 0..) |c, acc, i| {
        if (c.hi != p and c.lo != p) continue;
        if (c.kind != .direct or c.access != .flow) {
            if (c.unit < lo or c.unit >= hi) continue;
            var b = self.errWith(ex.mainTok(e), .E0997);
            b.msg("`{s}` drives `{s}` through a {s}", .{ inst[0 .. inst.len - 1], path, if (c.kind != .direct) "§5.6.7 indirect branch" else "potential source" });
            b.note("that branch's current is a solver unknown; VerA sums only flow contributions at a hierarchical port", .{});
            try b.emit();
            return poison;
        }
        const neg = c.lo == p;
        if (c.shared) {
            for (lo..hi) |k| if (self.unit_accum.get(.{ .row = @intCast(i), .unit = @intCast(k) })) |pa| {
                resist = try addSigned(self, resist, try self.builder.readVariable(pa.resist, self.cur), neg);
                react = try addSigned(self, react, try self.builder.readVariable(pa.react, self.cur), neg);
            };
        } else if (c.unit >= lo and c.unit < hi) {
            resist = try addSigned(self, resist, try self.builder.readVariable(acc.resist, self.cur), neg);
            react = try addSigned(self, react, try self.builder.readVariable(acc.react, self.cur), neg);
        }
    }
    if (react != .f_zero) {
        // The charges' own sites already carry their truncation check.
        const dq = try lower_analog_op.opDdt(self, ex.mainTok(e), react, flowAbstol(self, p), false);
        resist = if (resist == .f_zero) dq else try self.emit(.fadd, &.{ resist, dq });
    }
    return .{ .v = resist, .ty = .real };
}

/// §5.4.3 the flow into an instance port elaboration split onto its own net
/// `internal` (`Lower.port_ammeters`), or null when it was not split: the
/// current of the branch from the parent's net into it. Nothing contributes
/// to that branch, so it is a §5.4.2.1 flow probe, Figure 5-1's ammeter,
/// and its unknown is keyed on the pair as `branchOf` orders it.
pub fn ammeterFlow(self: *Lower, internal: []const u8) Oom!?TypedValue {
    const am = for (self.design.port_ammeters) |am| {
        if (std.mem.eql(u8, am.internal, internal)) break am;
    } else return null;
    const into = try lower_node.internNode(self, am.internal, "");
    const from = try lower_node.internNode(self, am.bound, "");
    const u = try lower_node.flowUnknown(self, @min(from, into), @max(from, into));
    const v = try lower_node.probe(self, u);
    return .{ .v = if (from > into) try self.emit(.fneg, &.{v}) else v, .ty = .real };
}

/// `acc ± v`, folding a zero on either side.
fn addSigned(self: *Lower, acc: Mir.Value, v: Mir.Value, neg: bool) Oom!Mir.Value {
    if (v == .f_zero) return acc;
    if (acc == .f_zero) return if (neg) try self.emit(.fneg, &.{v}) else v;
    return self.emit(if (neg) .fsub else .fadd, &.{ acc, v });
}

/// The read half of §5.4.3, shared by `I(<p>)` and by a §3.12.1 port branch
/// named over the same port: the two spellings are one quantity, so they must
/// be one unknown and one set of rules. `p` is the port's `nodes` row —
/// resolved by the caller, because the two spellings name it differently (an
/// argument expression here, a branch declaration there).
fn portFlowRead(self: *Lower, e: Ast.ExprId, p: u32) Oom!TypedValue {
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    // An instance's own port, split onto its own net: the probe's current.
    if (try ammeterFlow(self, lower_node.nodeName(self, p))) |tv| return tv;
    const global = self.access_kind.get(name) orelse {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0501);
        b.msg("`{s}`", .{name});
        if (diag.didYouMeanMap(name, self.access_kind)) |s|
            b.suggestHere(s);
        try b.emit();
        return poison;
    };
    const access = try lower_contrib.accessOn(self, e, name, global, p, Lower.ground);
    // §5.4.3 "The expression V(<a>) is invalid for ports and nets, where V is a
    // potential access function." A port access reads a FLOW, always.
    if (access == .potential) {
        try self.err(self.file.exprs.mainTok(e), .E0507, "`{s}` is a potential access function", .{name});
        return poison;
    }
    // §4.4.2 "For port access functions, the expression list is a single port
    // of the module"; §5.4.1 "it must be a declared port of the module in which
    // the port access function is used." An internal net has no outside, so its
    // port flow would be an identically-zero substitute — reject instead.
    if (p == ground or p >= self.out.num_ports) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0508);
        b.msg("`{s}(<{s}>)`", .{ name, lower_node.nodeName(self, p) });
        if (diag.didYouMeanMap(lower_node.nodeName(self, p), self.node_voltages)) |s|
            b.help("did you mean `{s}`?", .{s});
        try b.emit();
        return poison;
    }
    // §4.4 the name still has to be the port discipline's flow access.
    try lower_contrib.checkAccessMatch(self, e, name, access, p);
    return .{ .v = try lower_node.probe(self, try lower_node.portFlowUnknown(self, p)), .ty = .real };
}

test "lowerPortAccess: §5.4.3 a port access reads the flow into a port of the module" {
    const cases = [_]struct { body: []const u8, want: ?diag.Code }{
        .{ .body = "    y = I(<p>);", .want = null },
        // "The expression V(<a>) is invalid for ports and nets".
        .{ .body = "    y = V(<p>);", .want = .E0507 },
        // "it must be a declared port of the module".
        .{ .body = "    y = I(<q>);", .want = .E0508 },
    };
    for (cases) |c| try Lower.expectBodyVerdict(lower_expr.test_decls, c.body, c.want);
    // §5.2.1: no probe in an analog initial block (E0421).
    try Lower.expectBodyVerdict(lower_expr.test_decls ++ "\n  analog initial begin\n    y0 = V(p);\n  end", "", .E0421);
}
