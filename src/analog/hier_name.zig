//! §9.16 `$simprobe` and §9.20 hierarchical reference strings.
//!
//! In: string-named instance/node references. Out: the flat unknown each one names,
//! resolved at compile time (the device has no runtime hierarchy).
//!
//! LRM clauses this file's code cites: §1.3.1.1, §3.6.3.2, §3.11.1, §5.2.1,
//! §5.4.3, §5.8.3, §6.2.1, §6.4.3, §6.7, §9.16, §9.20.

const std = @import("std");
const Lower = @import("lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_discipline = @import("discipline.zig");
const lower_expr = @import("expr.zig");
const lower_limit = @import("limit.zig");
const lower_node = @import("node.zig");
const lower_sysfunc = @import("sysfunc.zig");
const Ast = @import("frontend").Ast;
const Elaborate = @import("elab").Elaborate;
const Mir = @import("ir").Mir;
const Oom = Lower.Oom;
const ground = Lower.ground;
const TypedValue = Lower.TypedValue;
const poison = Lower.poison;
const astTy = Lower.astTy;

/// This file's private state on `Lower` (`Lower.hier_name_state`).
pub const State = struct {
    /// §9.20 the analog_net_reference of every alias call so far → the unknown that
    /// net was declared with, before any alias moved it. The key set answers "used as
    /// an analog_net_reference in another ... call", and the declared unknown keeps the
    /// port ban about the declaration, which `node_voltages` no longer shows once an
    /// alias has been applied.
    alias_home: std.StringHashMapUnmanaged(u32) = .empty,
    /// The conditions enclosing the analog-initial statement being lowered,
    /// outermost first (`pushCond`). An alias call under any of them is chosen
    /// by a parameter, so it goes to `runtime` instead of `node_voltages`.
    conds: std.ArrayList(Cond) = .empty,
    /// §9.20 + §5.2.1 the aliases a parameter chooses, keyed by the declared
    /// unknown of their analog_net_reference, which is what `node_voltages`
    /// names while one exists and what `aliasProbe` dispatches on.
    runtime: std.AutoHashMapUnmanaged(u32, Runtime) = .empty,
};

/// One enclosing `if`/`?:` condition (`labels` empty) or `case` arm (`e` the
/// subject, `labels` the arm's), and whether the lowered arm is where it holds.
pub const Cond = struct {
    e: Ast.ExprId,
    labels: []const Ast.ExprId = &.{},
    pol: bool,
    /// A.8.3 over literals, parameters and `analysis()` (`isAnalysisOrConst`):
    /// the same value wherever it is lowered, so a probe may re-lower it.
    pure: bool,
};

/// The alias binding of one net as a function of the model card: `base` (its
/// declared unknown, or an unconditional alias before these), then each
/// conditional call in source order, the last whose conditions hold winning.
pub const Runtime = struct {
    base: u32,
    entries: std.ArrayList(struct { target: u32, conds: []const Cond }) = .empty,
};

/// Enters an arm of a conditional inside `analog initial`; a no-op elsewhere,
/// where no alias call can be.
pub fn pushCond(self: *Lower, c: Cond) Oom!void {
    if (self.in_analog_initial) try self.hier_name_state.conds.append(self.arena, c);
}

/// Leaves the arm `pushCond` entered. Asserts that one is open.
pub fn popCond(self: *Lower) void {
    if (!self.in_analog_initial) return;
    const left = self.hier_name_state.conds.pop();
    std.debug.assert(left != null);
}

/// Returns the potential probe of node `idx`, following §9.20 aliases. For a net
/// whose alias a parameter chooses (§9.20 re-evaluates per sweep point, §5.2.1
/// re-executes `analog initial` on a parameter change), emits a select over the
/// candidates, re-lowering their conditions (`Cond.pure` makes that the same value).
pub fn aliasProbe(self: *Lower, idx: u32) Oom!Mir.Value {
    const set = self.hier_name_state.runtime.get(idx) orelse return lower_node.probe(self, idx);
    var v = try lower_node.probe(self, set.base);
    for (set.entries.items) |en| {
        var c: ?Mir.Value = null;
        for (en.conds) |t| {
            const b = try condValue(self, t);
            c = if (c) |p| try self.emit(.logand, &.{ p, b }) else b;
        }
        v = try self.emit(.select, &.{ c.?, try lower_node.probe(self, en.target), v });
    }
    return v;
}

fn condValue(self: *Lower, t: Cond) Oom!Mir.Value {
    var b: ?Mir.Value = null;
    if (t.labels.len == 0) {
        b = try self.toBool(try lower_expr.lowerExpr(self, t.e));
    } else {
        // §5.8.3 an arm matches any one of its labels.
        const sv = try lower_expr.lowerExpr(self, t.e);
        for (t.labels) |l| {
            const eq = try lower_expr.cmp(self, .eq, sv, try lower_expr.lowerExpr(self, l));
            b = if (b) |p| try self.emit(.logor, &.{ p, eq }) else eq;
        }
    }
    return if (t.pol) b.? else self.emit(.lognot, &.{b.?});
}

/// Reports an error when nodes `hi` or `lo` have a parameter-chosen alias. Only a
/// potential probe can follow one; a contribution, flow or `ddx` would need its
/// row or column chosen by the card as well.
/// ponytail: refused rather than routed; route them through the same select
/// the day a model needs one.
pub fn refuseRuntime(self: *Lower, tok: u32, hi: u32, lo: u32) Oom!void {
    const rt = &self.hier_name_state.runtime;
    const idx = if (rt.contains(hi)) hi else if (rt.contains(lo)) lo else return;
    try self.err(tok, .E0812, "`{s}` is aliased under a parameter condition; VerA answers only a potential probe of it, not a contribution, a flow or a ddx", .{lower_node.nodeName(self, idx)});
}

/// §9.20 one resolved `hierarchical_reference_string`: the unknown it names,
/// and whether the name was a node of the flat design itself (`direct`) rather
/// than a child port flattening bound to one.
const AliasHit = struct { idx: u32, direct: bool };

/// §9.20's validity list for `$analog_node_alias()` / `$analog_port_alias()`,
/// then the alias itself.
///
/// All six rules are properties of the call (its block, its guard, the shape of the
/// first argument, the constancy of the second, the relation between calls), which
/// codegen cannot recover, so they are checked here under one code (E0812), each
/// message quoting its sentence. The alias is a `node_voltages` write made in source
/// order, which gives §9.20's "the last evaluated call shall take precedence".
pub fn checkAliasCall(self: *Lower, e: Ast.ExprId, name: []const u8, args: []const Ast.ExprId) Oom!lower_limit.AliasResult {
    const ex = &self.file.exprs;
    // 1. "It shall be an error for the $analog_node_alias() and
    // $analog_port_alias() system functions to be used outside the analog
    // initial block." The next sentence gives the reason: both "shall be
    // re-evaluated each sweep point of a dc sweep", i.e. between solves.
    if (!self.in_analog_initial) {
        try self.err(self.file.exprs.mainTok(e), .E0812, "`{s}` is used outside an analog initial block", .{name});
        return .refused;
    }
    // 2. "shall not be used inside conditional ( if , case , or ?: ) statements
    // unless the conditional expression controlling the statement consists of
    // terms which can not change during the course of a simulation."
    //
    // That carve-out is `static_cond_depth`: A.8.3's
    // `analysis_or_constant_expression` is the same "cannot change during the
    // simulation" set, so a parameter or `analysis()` guard is admitted and
    // `$abstime` is not. A constant-folded `if` never raises either counter and
    // so never reaches here at all.
    //
    // `lowerModule` wraps `analog initial` in the `initial_step` guard, so the depth
    // inside it is already 1/0. That guard is the context the clause requires, not
    // a §9.20 conditional, so it is discounted (saturating; rule 1 guarantees it).
    if ((self.cond_depth -| 1) != self.static_cond_depth) {
        try self.err(self.file.exprs.mainTok(e), .E0812, "`{s}` is used inside conditional statement whose condition can change during the simulation", .{name});
        return .refused;
    }
    // 3/4/5. The analog_net_reference. "The analog_net_reference shall be either
    // a scalar or vector continuous node declared in the module containing the
    // system function call."
    const ref = if (args.len > 0) args[0] else Ast.ExprId.none;
    if (ref == .none) {
        try self.err(self.file.exprs.mainTok(e), .E0812, "`{s}` needs an analog_net_reference and a hierarchical_reference_string", .{name});
        return .refused;
    }
    // The analog_net_reference's own unknown, for the alias below.
    var local: u32 = ground;
    // "either a scalar or vector continuous node": a whole vector is its
    // elements, each checked and aliased like a scalar (`aliasVector`).
    var vector: ?Lower.VecRange = null;
    switch (ex.tag(ref)) {
        .ident => if (self.out.vectors.get(self.file.str(ex.strOf(ref)))) |r| {
            const rname = self.file.str(ex.strOf(ref));
            for (0..r.size()) |k| {
                const elem = try self.arena.print("{s}[{d}]", .{ rname, r.at(@intCast(k)) });
                const idx = self.hier_name_state.alias_home.get(elem) orelse self.node_voltages.get(elem) orelse ground;
                if (idx == ground) {
                    try self.err(self.file.exprs.mainTok(e), .E0812, "the analog_net_reference of `{s}` is not a continuous node declared in this module", .{name});
                    return .refused;
                }
                if (idx < self.out.num_ports) {
                    try self.err(self.file.exprs.mainTok(e), .E0812, "§9.20 does not allow the analog_net_reference to be a port: `{s}`", .{rname});
                    return .refused;
                }
            }
            vector = r;
        } else {
            const rname = self.file.str(ex.strOf(ref));
            // The net's declared unknown: `rname` may already be an alias, and
            // every rule below is about the declaration.
            const idx = self.hier_name_state.alias_home.get(rname) orelse self.node_voltages.get(rname);
            if (idx == null or idx.? == ground or self.vars.contains(rname)) {
                try self.err(self.file.exprs.mainTok(e), .E0812, "the analog_net_reference of `{s}` is not a continuous node declared in this module", .{name});
                return .refused;
            }
            // 4. "It shall be an error for the analog_net_reference to be a port
            // or to be involved in port connections." A port is already bound to
            // whatever the instantiating netlist connected it to, and the alias
            // would bind the same matrix position a second time.
            if (idx.? < self.out.num_ports) {
                try self.err(self.file.exprs.mainTok(e), .E0812, "§9.20 does not allow the analog_net_reference to be a port: `{s}`", .{rname});
                return .refused;
            }
            local = idx.?;
        },
        // 5. "If the analog_net_reference is a vector node, it shall reference
        // the full vector node, it shall be an error for it to be a bit select
        // or part select of a vector node." The hierarchical_reference_string,
        // by contrast, may name a scalar element.
        .index, .range => {
            try self.err(self.file.exprs.mainTok(e), .E0812, "a vector analog_net_reference must be the whole vector, not a bit select or part select", .{});
            return .refused;
        },
        else => { // else: §9.20 takes a node name and nothing else: E0812
            try self.err(self.file.exprs.mainTok(e), .E0812, "the analog_net_reference of `{s}` is not a continuous node declared in this module", .{name});
            return .refused;
        },
    }
    // 6. "The hierarchical_reference_string shall be a CONSTANT string value
    // (string literal or string parameter) containing a hierarchical reference
    // to a continuous node." `constEval` admits exactly those two spellings.
    const target = blk: {
        if (args.len > 1) if (lower_constfold.constEval(self, args[1])) |c| switch (c) {
            .str => |s| break :blk s,
            else => {},
        };
        try self.err(self.file.exprs.mainTok(e), .E0812, "the hierarchical_reference_string of `{s}` is not a constant string (a string literal or a string parameter)", .{name});
        return .refused;
    };
    // "It shall be an error for the hierarchical_reference_string to reference a
    // node that is used as an analog_net_reference in ANOTHER
    // $analog_node_alias or $analog_port_alias() system function call." The same
    // left argument twice is legal (the last-writer rule), so only the target is
    // compared against other references.
    //
    // Only a dotted-free string can name one: §6.7 says "the first name in a
    // path name can also be the top of a hierarchy which starts at the level
    // where the path is being used", so a bare name resolves locally, while
    // `$root.top.a` names something this module does not declare.
    const ref_name = self.file.str(ex.strOf(args[0]));
    if (std.mem.findScalar(u8, target, '.') == null and !std.mem.eql(u8, target, ref_name)) {
        if (self.hier_name_state.alias_home.contains(target)) {
            try self.err(self.file.exprs.mainTok(e), .E0812, "`\"{s}\"` is already the analog_net_reference of another $analog_node_alias/$analog_port_alias call", .{target});
            return .refused;
        }
    }
    if (vector) |r| return aliasVector(self, name, ref_name, r, target);
    // First call for this net records its declared unknown; a later one must
    // not overwrite it with the alias the earlier call installed.
    if (!self.hier_name_state.alias_home.contains(ref_name)) try self.hier_name_state.alias_home.put(self.arena, ref_name, local);
    return bindAlias(self, name, ref_name, local, target);
}

/// §9.20 a whole-vector analog_net_reference. The validity rules make the
/// target "a scalar continuous node or a scalar element of a continuous
/// vector node", and an aliased reference "shall refer to the same circuit
/// matrix position", so every element is aliased to that one node. The
/// elements share a declaration, so the target is valid for all or none:
/// the first element's answer is the call's.
fn aliasVector(self: *Lower, fname: []const u8, ref_name: []const u8, r: Lower.VecRange, target: []const u8) Oom!lower_limit.AliasResult {
    for (0..r.size()) |k| {
        const elem = try self.arena.print("{s}[{d}]", .{ ref_name, r.at(@intCast(k)) });
        const home = self.hier_name_state.alias_home.get(elem) orelse self.node_voltages.get(elem).?;
        if (!self.hier_name_state.alias_home.contains(elem)) try self.hier_name_state.alias_home.put(self.arena, elem, home);
        if (try bindAlias(self, fname, elem, home, target) != .bound) return .unresolved;
    }
    return .bound;
}

/// §9.20's topology edit, and the validity list that decides whether it happens.
///
/// "The return value for both system functions shall be one (1) if the
/// hierarchical_reference_string points to a valid continuous node and zero (0)
/// otherwise. If the hierarchical_reference_string references a valid continuous
/// node, then the analog_net_reference will be aliased to that hierarchical node
/// and shall refer to the same circuit matrix position."
///
/// The clause's three validity rules, in its order, after resolution: a scalar node
/// or scalar element (a scalarised vector base name resolves to nothing); compatible
/// disciplines (§3.11.1, `disciplineConflict`); and, for `$analog_port_alias()`, a port.
///
/// A surviving call is one `node_voltages` write. The aliased net keeps its `nodes`
/// row with no equation, because pruning it would renumber `U`, which the host reads.
/// A call under a parameter condition is recorded for `aliasProbe` to select at run
/// time; otherwise resolution is compile time.
///
/// ponytail: a string parameter the model card overrides is frozen at its default,
/// as §3.6.3.2's nodeset is. Upgrade: refuse a parameter-valued string whose default
/// and override could resolve differently.
fn bindAlias(self: *Lower, fname: []const u8, ref_name: []const u8, local: u32, target: []const u8) Oom!lower_limit.AliasResult {
    const hit = resolveAliasNode(self, target) orelse return .unresolved;
    // §1.3.1.1 ground is not an unknown, but it IS a valid continuous node and
    // the clause's own example aliases to it ("node n1 will be aliased to
    // top.gnd"). Probing an aliased-to-ground net then yields the literal 0,
    // which is what the reference node is.
    if (hit.idx != ground) {
        if (lower_discipline.nodeDisciplineConflict(
            self,
            self.out.nodes.items(.disc)[local],
            self.out.nodes.items(.disc)[hit.idx],
        ) != null) return .unresolved;
        if (self.out.disciplines.get(self.out.nodes.items(.disc)[hit.idx])) |info| {
            if (info.is_discrete) return .unresolved;
        }
    }
    if (std.mem.eql(u8, fname, "$analog_port_alias")) {
        // "the resolved hierarchical node reference shall be a port": a port of
        // the elaborated device, the only port whose flow §5.4.3 can read.
        //
        // ponytail: a child instance's port (`$analog_port_alias(n2, "top.r1.p")`)
        // returns 0. Flattening binds it to the parent net, whose flow every
        // instance on the net shares, so answering 1 would measure the wrong
        // quantity. Upgrade: a per-instance terminal flow unknown from elaboration.
        if (!hit.direct or hit.idx == ground or hit.idx >= self.out.num_ports) return .unresolved;
    }
    // A call under a parameter condition: `aliasProbe` chooses at run time, since
    // the model card may override the parameter. The net keeps its declared unknown.
    const st = &self.hier_name_state;
    var pure = st.conds.items.len != 0;
    for (st.conds.items) |c| pure = pure and c.pure;
    if (pure) {
        const gop = try st.runtime.getOrPut(self.arena, local);
        if (!gop.found_existing) gop.value_ptr.* = .{ .base = self.node_voltages.get(ref_name) orelse local };
        try gop.value_ptr.entries.append(self.arena, .{ .target = hit.idx, .conds = try self.arena.dupe(Cond, st.conds.items) });
        try self.node_voltages.put(self.arena, ref_name, local);
        return .bound;
    }
    // The alias itself: every later probe of the analog_net_reference lands on the
    // resolved node's unknown. An unconditional call overrides every conditional one.
    // ponytail: a condition that is static only as a value (a variable holding
    // a parameter, `isStaticValue`) cannot be re-lowered outside the block, so
    // it still binds here, at the last arm lowered.
    _ = st.runtime.remove(local);
    try self.node_voltages.put(self.arena, ref_name, hit.idx);
    return .bound;
}

/// §6.7 resolves a `hierarchical_reference_string` against the elaborated design.
/// `direct` says the name was a node of the flat design itself rather than a
/// child port that flattening bound to one (see `bindAlias`'s port rule).
///
/// Flattened names join path parts with `Elaborate.sep`, a period, so this is a map
/// lookup. A leading `$root.` is stripped (§6.2.1); the unstripped name is tried
/// first and the device's own module name stripped only after it fails, since §6.7
/// resolves the ambiguity "by giving priority to the local scope".
fn resolveAliasNode(self: *Lower, path: []const u8) ?AliasHit {
    if (lookupFlatNode(self, path)) |h| return h;
    var p = path;
    if (std.mem.startsWith(u8, p, "$root.")) p = p["$root.".len..];
    if (self.module) |m| {
        const mn = self.file.str(m.name);
        if (p.len > mn.len + 1 and p[mn.len] == Elaborate.sep and std.mem.startsWith(u8, p, mn))
            p = p[mn.len + 1 ..];
    }
    if (p.len == path.len) return null; // nothing stripped; already looked up
    return lookupFlatNode(self, p);
}

fn lookupFlatNode(self: *Lower, p: []const u8) ?AliasHit {
    if (self.node_voltages.get(p)) |i| return .{ .idx = i, .direct = true };
    // A child port bound to a parent net is the same signal as that net, and
    // `Design.names` holds exactly those aliases (`flatName`'s one exception).
    if (self.out.hier_names.get(p)) |flat| {
        if (self.node_voltages.get(flat)) |i| return .{ .idx = i, .direct = false };
    }
    return null;
}

/// §9.16 "the parent of the current instance": the caller's own instance path
/// with its last segment dropped, separator included, "" at the top. Joined to
/// an `inst_name` it gives the flat name of a sibling.
fn callerParentPath(self: *const Lower) []const u8 {
    if (self.cur_unit >= self.unit_paths.len) return "";
    const p = self.unit_paths[self.cur_unit].path;
    if (p.len == 0) return p;
    // `path` ends with the separator, so the caller's own segment is the text
    // between the previous separator and the last one.
    const cut = std.mem.findScalarLast(u8, p[0 .. p.len - 1], Elaborate.sep) orelse return "";
    return p[0 .. cut + 1];
}

/// Lowers `$simprobe(inst_name, param_name [, expression])` (LRM §9.16) to the
/// sibling instance's parameter or variable, resolved at compile time by flat name.
/// When the name does not resolve, returns `expression`, or reports an error when
/// there is none. A name that does not fold is refused (E0823): §9.16 resolves a
/// string variable at run time, and VerA has no run-time instance table.
pub fn lowerSimprobe(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const args = ex.args(e);
    if (args.len < 2) {
        try self.err(self.file.exprs.mainTok(e), .E0809, "`$simprobe` takes an instance name and a parameter name", .{});
        return poison;
    }
    const inst = lower_sysfunc.constStrArg(self, args[0]);
    const param = lower_sysfunc.constStrArg(self, args[1]);
    for ([2]?[]const u8{ inst, param }, args[0..2]) |name, arg| if (name == null) {
        var b = self.errWith(ex.mainTok(arg), .E0823);
        b.msg("this name has no value until the analog block runs", .{});
        b.note("§9.16 resolves a string variable when the probe runs; VerA resolves names at compile time", .{});
        b.help("spell the name as a string literal or a string parameter", .{});
        try b.emit();
        return poison;
    };
    {
        // §9.16: "the simulator will look for an instance called inst_name in
        // the parent of the current instance i.e. a sibling of the instance
        // containing the $simprobe() expression." The name is relative, so the
        // flat key is the caller's parent path joined to it.
        const path = try std.mem.concat(self.arena, u8, &.{
            callerParentPath(self), inst.?, &[_]u8{Elaborate.sep}, param.?,
        });
        // §6.4.3 "If a paramset output variable has the same name as a module
        // output variable, the paramset's value is reported for instances
        // using the paramset": first, and the nearest link's (last) wins.
        var k = self.ps_outputs.len;
        while (k > 0) {
            k -= 1;
            if (!std.mem.eql(u8, self.ps_outputs[k].report, path)) continue;
            const slot = self.vars.get(self.ps_outputs[k].flat) orelse break;
            return .{ .v = try self.builder.readVariable(slot.place, self.cur), .ty = slot.ty };
        }
        if (self.param_index.get(path)) |pi|
            return .{ .v = self.param_values.items[pi], .ty = astTy(self.out.params.items[pi].ty) };
        // §9.16: "$simprobe() queries the simulator for an output variable named
        // param_name in a sibling instance". A flattened child's variable is an
        // ordinary variable under its path name. The sibling's block was lowered
        // first (elaboration appends instances in tree order), so this reads the
        // value it computed for this evaluation.
        // §6.4.3 unless the instance's paramset hides it: "the module output
        // variable shall not be available for instances using the paramset".
        const hidden = for (self.ps_hidden) |h| {
            if (std.mem.eql(u8, h, path)) break true;
        } else false;
        if (!hidden) if (self.vars.get(path)) |slot|
            return .{ .v = try self.builder.readVariable(slot.place, self.cur), .ty = slot.ty };
    }
    // Unresolved. §9.16's own two outcomes, in the clause's order.
    if (args.len >= 3 and args[2] != .none) return lower_expr.lowerExpr(self, args[2]);
    var b = self.errWith(self.file.exprs.mainTok(e), .E0817);
    b.msg("`$simprobe(\"{s}\", \"{s}\")` names no parameter of the elaborated design", .{
        inst orelse "<expression>", param orelse "<expression>",
    });
    b.note("§9.16: with no third argument, an unresolvable probe \"shall generate an error\"", .{});
    b.help("supply the fallback expression §9.16 defines for this case: `$simprobe(inst, param, <value>)`", .{});
    try b.emit();
    return poison;
}

test callerParentPath {
    // §9.16 "the parent of the current instance": the instance path with its
    // own last segment dropped, separator kept, "" at the top and for a unit
    // the table does not hold.
    var h: Lower.Harness = undefined;
    try h.init(std.testing.allocator, "module m; endmodule");
    defer h.deinit();
    const units = [_]Elaborate.UnitPath{
        .{ .module = "top", .path = "", .decl = undefined },
        .{ .module = "a", .path = "u1.", .decl = undefined },
        .{ .module = "b", .path = "u1.u2.", .decl = undefined },
    };
    h.low.unit_paths = &units;
    const want = [_][]const u8{ "", "", "u1.", "" };
    for (want, 0..) |w, unit| {
        h.low.cur_unit = @intCast(unit);
        try std.testing.expectEqualStrings(w, callerParentPath(&h.low));
    }
}

test resolveAliasNode {
    // §6.7 resolution of a §9.20 hierarchical_reference_string in a design of
    // one module: the bare name, the module-qualified one and §6.2.1's
    // `$root.` spelling all reach the same node, and only a node is a hit.
    var h: Lower.Harness = undefined;
    try h.init(std.testing.allocator,
        \\module top(a, g);
        \\  inout a, g; electrical a, g;
        \\  electrical n1;
        \\  analog I(a, g) <+ V(a, g);
        \\endmodule
    );
    defer h.deinit();
    _ = try h.lower() orelse {
        h.dump();
        return error.TestUnexpectedResult;
    };
    const a = h.low.node_voltages.get("a").?;
    for ([_][]const u8{ "a", "top.a", "$root.top.a", "$root.a" }) |path| {
        const hit = resolveAliasNode(&h.low, path) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(a, hit.idx);
        try std.testing.expect(hit.direct);
    }
    try std.testing.expectEqual(h.low.node_voltages.get("n1").?, resolveAliasNode(&h.low, "top.n1").?.idx);
    for ([_][]const u8{ "top", "top.", "nosuch", "top.nosuch", "$root.", "other.a" }) |path|
        try std.testing.expect(resolveAliasNode(&h.low, path) == null);
}

test pushCond {
    // Outside an `analog initial` block no alias call can be, so a condition
    // is not recorded.
    var h: Lower.Harness = undefined;
    try h.init(std.testing.allocator, "module m; endmodule");
    defer h.deinit();
    try pushCond(&h.low, .{ .e = .none, .pol = true, .pure = true });
    try std.testing.expectEqual(0, h.low.hier_name_state.conds.items.len);
    popCond(&h.low);
    h.low.in_analog_initial = true;
    try pushCond(&h.low, .{ .e = .none, .pol = true, .pure = true });
    try std.testing.expectEqual(1, h.low.hier_name_state.conds.items.len);
    popCond(&h.low);
    try std.testing.expectEqual(0, h.low.hier_name_state.conds.items.len);
}

test "lowerSimprobe: §9.16's two outcomes for a name that does not resolve" {
    const decls = "  real y;\n  string s;";
    // "If ... the optional expression is not supplied, then an error".
    try Lower.expectBodyVerdict(decls, "    y = $simprobe(\"nosuch\", \"gain\");", .E0817);
    // With it, the expression is the value.
    try Lower.expectBodyVerdict(decls, "    y = $simprobe(\"nosuch\", \"gain\", 2.0);", null);
    // A string variable has no value until the block runs (E0823).
    try Lower.expectBodyVerdict(decls, "    s = \"u\";\n    y = $simprobe(s, \"gain\", 1.0);", .E0823);
}
