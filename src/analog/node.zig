//! §1.3.1 nodes: nets, ports, ground and the solver-unknown order.
//!
//! In: net and port declarations. Out: `nodes` (the U-enum index codegen depends on),
//! implicit nets, and the port/branch tables.
//!
//! Spine, in `lowerModule`'s order: `declarePorts`, `declareNets`,
//! `bindPortConnections`, `resolveDisciplines`, `declareBranches`. After them,
//! rows are only appended (implicit nets, §5.4.2 flow unknowns, §4.5.2 operator
//! states), so a row index, once handed out, is stable. A row is a `u32`;
//! past its index space (`max_nodes`), E1015.
//!
//! LRM clauses this file's code cites: §1, §1.3.1.1, §1.3.4, §1.3.4.1,
//! §1.3.4.2, §2.7, §2.8.1, §3.4, §3.4.4, §3.6.1.2, §3.6.2.1, §3.6.2.2, §3.6.3,
//! §3.6.3.2, §3.6.4, §3.6.5, §3.9, §3.11, §3.12, §3.12.1, §3.13.3, §4.2.1.1,
//! §4.4, §5.4.1, §5.4.3, §5.5.2, §5.5.3, §5.6.1.3, §5.9.3, §6.5, §6.5.2,
//! §6.5.2.2, §6.5.5, §6.5.7.1, §6.7.1, §7.2.4, §7.4, §7.4.4, §10.2.
//! IEEE 1364-2005 clauses cited: §5.2.1, §19.2, §19.9.

const std = @import("std");
const assert = std.debug.assert;
const Elaborate = @import("elab").Elaborate;
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Lower = @import("Lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_shape = @import("shape.zig");
const lower_node_discipline = @import("node_discipline.zig");
const lower_node_ref = @import("node_ref.zig");
const Oom = Lower.Oom;
const ground = Lower.ground;
const unnamed_branch = Lower.unnamed_branch;
const NodeKind = Lower.NodeKind;
const VecRange = Lower.VecRange;

/// This file's private state on `Lower` (`Lower.node_state`).
pub const State = struct {
    /// Last `BranchInfo.id` handed out. Starts at `unnamed_branch`, so the first
    /// declared branch is 1 and no named branch can ever be mistaken for §5.4.1
    /// Example 2's single implicit branch of a node pair.
    last_branch_id: u32 = unnamed_branch,
    /// Every spelling handed to `nodes`, so `appendNode` can keep them unique for
    /// the emitted `U` enum. Not an identity table: two different unknowns may want
    /// one spelling (see `uniqueSpelling`).
    spellings: std.StringHashMapUnmanaged(void) = .empty,
    /// Deduped probe Value per `nodes` row; `.undef` = not probed yet.
    probe_cache: std.ArrayList(Mir.Value) = .empty,
    /// `op_state` rows minted so far, the `<k>` of `opStateNode`'s spelling.
    op_states: u32 = 0,
    /// E1015 was reported: `nodes` is full.
    full: bool = false,
};

/// The most rows `nodes` holds: a row is a u32 below `ground`. Not a design
/// limit: a row costs tens of bytes of lowering state alone, so a module
/// reaching it has run out of memory first (#29).
pub const max_nodes = ground;

// ---- the module's declarations, in `lowerModule`'s order ---------------------

/// §6.5 interns the module's ports as the first `nodes` rows, in declaration
/// order, which is the host device's terminal order; a §3.6.3 vector port is
/// one row per element, msb first. Sets `Lowered.num_ports` to the row count
/// after them.
pub fn declarePorts(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    assert(module.name != .none);
    for (module.ports) |p| {
        // §3.6.3/§6.5.2 a vector port is N terminals, in declaration order.
        if (try lower_node_ref.portRange(self, &p)) |r| {
            const name = self.file.str(p.name);
            const disc = lower_node_discipline.strOrEmpty(self, p.discipline);
            for (0..r.size()) |k| {
                const idx = try internNode(self, try self.arena.print("{s}[{d}]", .{ name, r.at(@intCast(k)) }), disc);
                self.out.nodes.items(.dir)[idx] = p.direction;
            }
            try self.out.vectors.put(self.arena, name, r);
            continue;
        }
        const idx = try internNode(self, try lower_node_ref.netKey(self, self.file.str(p.name), p.main_tok), lower_node_discipline.strOrEmpty(self, p.discipline));
        // §6.5.2.2. Recorded here and nowhere else: only a port can be
        // directional, and this loop is the only place the direction is known.
        self.out.nodes.items(.dir)[idx] = p.direction;
        // §1.3.4.1/§1.3.4.2's "not to `inout` ports" is checked below the net
        // loop (E0360): the discipline is not known yet here.
    }
    self.out.num_ports = @intCast(self.out.nodes.len);
}

/// §3.6.3 interns the module's internal nets after the ports, records their
/// §3.6.3.2 nodesets, and binds §3.6.4 ground declarations to `ground`. A net
/// the discrete half owns (`Lowered.discrete_inputs`) never becomes a row.
pub fn declareNets(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    assert(module.name != .none);
    for (module.nets) |n| {
        if (self.out.discrete_inputs.contains(self.file.str(n.name))) continue;
        // §2.8.1 vs §3.6.3 (see `netKey`). A ranged declaration is a vector and
        // its own name never reaches the node table, so the key is the scalar
        // path's and the `vectors` entry below keeps the declared spelling.
        const name = try lower_node_ref.netKey(self, self.file.str(n.name), n.main_tok);
        // §3.6.3 a vector net is N independent nets, scalarised here.
        //
        // §3.6.3.2's bus initializer is scalarised with them: "In the case of
        // analog buses, a constant array expression is used as an initializer.
        // A null value in the constant array indicates that no nodeset value is
        // being specified for this element of the bus." `flattenPattern` is
        // already the per-cell reader the §3.4.4 parameter arrays use, and it
        // answers `.none` for both spellings of "nothing here" — the clause's
        // hole and a pattern shorter than the bus.
        if (n.range) |d| {
            if (try lower_node_ref.foldDim(self, d, n.main_tok)) |r| {
                // Only a pattern seeds nodesets. A non-pattern initializer
                // (`wire [3:0] wbus = 4'h5;`) is A.2.2.1's continuous assignment
                // of one value to the whole vector, legal 1364, not §3.6.3.2's
                // bus form, so it is not an error.
                // ponytail: the value is dropped. When `assign` is modeled, it
                // becomes that continuous assignment instead.
                const seeds: []const Ast.ExprId = if (n.init == .none or
                    self.file.exprs.tag(n.init) != .assign_pattern)
                    &.{}
                else
                    try lower_shape.flattenPattern(self, n.init, &.{lower_shape.Bounds{ .lo = 0, .hi = r.size() - 1 }}, true);
                for (0..r.size()) |k| {
                    const idx = try internNode(self, try self.arena.print("{s}[{d}]", .{ name, r.at(@intCast(k)) }), lower_node_discipline.strOrEmpty(self, n.discipline));
                    if (k < seeds.len and seeds[k] != .none)
                        try recordNodeset(self, idx, seeds[k], n.main_tok, name);
                }
                try self.out.vectors.put(self.arena, name, r);
            }
            continue;
        }
        if (n.is_ground) {
            // §3.6.4 "Each ground declaration is associated with an already
            // declared net of continuous discipline. ... The net must be
            // assigned a continuous discipline to be declared ground." The
            // global reference node is the zero of a potential, and §3.6.2.2
            // leaves a discrete discipline with no nature to have one.
            //
            // The discipline can come from either spelling: `ground <disc> g;`
            // carries it here, `<disc> g; ground g;` left it on the node the
            // earlier declaration interned.
            const dname = if (n.discipline != .none)
                self.file.str(n.discipline)
            else if (self.node_voltages.get(name)) |idx|
                (if (idx == ground) "" else self.out.nodes.items(.disc)[idx])
            else
                "";
            if (self.out.disciplines.get(dname)) |info| {
                if (info.is_discrete)
                    try self.err(n.main_tok, .E0344, "`{s}` is of discipline `{s}`, whose domain is discrete", .{ name, dname });
            }
            try self.node_voltages.put(self.arena, name, ground);
            continue;
        }
        // §7.4.4, printed again as step 3 of F.2.1/F.2.2: "More than one
        // conflicting discipline declaration from the same context ... is an
        // error. In this case, conflicting simply means an attempt to declare
        // more than one discipline regardless of whether the disciplines are
        // compatible or not." So the test is a second declaration, not a
        // mismatch. This is the only site that sees both shapes (a port
        // interned by the loop above; a body declaration re-disciplining it).
        //
        // Both sides must be non-empty: §3.6.5 implicit nets and §3.9 undeclared
        // ports carry `""`, and a later declaration of one of those is the
        // first declaration, not a conflict.
        if (n.discipline != .none) if (self.node_voltages.get(name)) |idx| {
            const had = if (idx == ground) "" else self.out.nodes.items(.disc)[idx];
            if (had.len != 0) {
                var b = self.errWith(n.main_tok, .E0902);
                b.msg("`{s}` is already of discipline `{s}`", .{ name, had });
                b.note("`{s}` would be its second, and §7.4.4 forbids a second declaration whether or not the two are compatible", .{self.file.str(n.discipline)});
                try b.emit();
                continue; // keep the FIRST declaration; do not silently overwrite it
            }
        };
        const idx = try internNode(self, name, lower_node_discipline.strOrEmpty(self, n.discipline));
        // §3.6.3.2 the net_decl_assignment, folded. `consts` is already loaded
        // (the parameter loop runs above the port loop), so a nodeset written
        // over a parameter folds here and not later.
        //
        // §3.6.3.2 gives initializers to "net discipline declarations" of
        // continuous disciplines. On a mixed module's net with no discipline
        // (`wire (strong1, pull0) w = a;`) the assignment is IEEE 1364-2005
        // §6.1.3's instead, "a continuous assignment that is part of the net
        // declaration": the digital engine's driver of w
        // (`sim.digital.elab.declareNet`), not a nodeset. The interned node's
        // discipline decides, not the entry's: `electrical p = 5.0;` on a
        // header port is an entry with none over a port that has one.
        const undisciplined = idx != ground and self.out.nodes.items(.disc)[idx].len == 0;
        if (n.init != .none and !(self.out.mixed_signal and undisciplined)) try recordNodeset(self, idx, n.init, n.main_tok, name);
    }
}

/// §6.5.7.1 the port connections elaboration recorded: E0925 when a port and
/// its net differ in width, and each element of a port bound to a
/// concatenation or a select named as the net it is (E0925 when the counts
/// differ).
pub fn bindPortConnections(self: *Lower) Oom!void {
    // §6.5.7.1 "The sizes of the ports and net must match." A net this module
    // never interned (a discrete input) has no width here to compare.
    for (self.design.port_widths) |pw| {
        const port: u64 = if (pw.range) |d| ((try lower_node_ref.foldDim(self, d, pw.main_tok)) orelse continue).size() else 1;
        const net: u64 = if (self.out.vectors.get(pw.net)) |v| v.size() else if (self.node_voltages.contains(pw.net)) 1 else continue;
        if (port != net)
            try self.err(pw.main_tok, .E0925, "`{s}` is {d} wide and the port it connects is {d}", .{ pw.net, net, port });
    }

    // §6.5.7.1 a vector port bound to a concatenated net expression or to
    // §6.5.5's sub-range of a net: element k of the port IS bit k of the
    // connection, so its key names that bit's node.
    var bits: std.ArrayList(u32) = .empty;
    for (self.design.port_concats) |pc| {
        bits.clearRetainingCapacity();
        var ok = for (pc.parts) |part| {
            if (!try partNodes(self, part, pc.main_tok, &bits)) break false;
        } else true;
        const r: ?VecRange = if (pc.range) |d| (try lower_node_ref.foldDim(self, d, pc.main_tok)) orelse continue else null;
        const width: usize = if (r) |v| v.size() else 1;
        if (ok and bits.items.len != width) {
            ok = false;
            if (r == null)
                try self.err(pc.main_tok, .E0925, "the connection is {d} nets wide and the port it connects is scalar", .{bits.items.len})
            else
                try self.err(pc.main_tok, .E0925, "the connection is {d} nets wide and the port it connects is {d}", .{ bits.items.len, width });
        }
        // A refused connection binds the port to ground, as `nodeOf` stands
        // ground in for a refused terminal, so the child's own accesses of the
        // port add no diagnostics of their own.
        // §6.5.5 a scalar port on one bit of a net (`.v(bus[1])`) is that bit.
        const v = r orelse {
            try self.node_voltages.put(self.arena, pc.name, if (ok) bits.items[0] else ground);
            continue;
        };
        for (0..width) |k|
            try self.node_voltages.put(self.arena, try self.arena.print("{s}[{d}]", .{ pc.name, v.at(@intCast(k)) }), if (ok) bits.items[k] else ground);
        try self.out.vectors.put(self.arena, pc.name, v);
    }
}

/// Appends the nodes of one member of a port connection, msb first: every
/// element of a vector net (a concatenation's operand, §6.5.7.1), one net,
/// or the elements a constant select names (§6.5.5), which must be a part of
/// the net's declared range (E0351 on a net with none, E0352 outside it).
/// Returns false after the diagnostic.
fn partNodes(self: *Lower, part: Elaborate.NetPart, tok: u32, out: *std.ArrayList(u32)) Oom!bool {
    assert(tok < self.tok_starts.len or self.tok_starts.len == 0 or tok == std.math.maxInt(u32));
    const decl = self.out.vectors.get(part.net) orelse {
        if (part.sel == .whole) {
            try out.append(self.arena, try internNode(self, part.net, ""));
            return true;
        }
        try self.err(tok, .E0351, "`{s}` was not declared with a range", .{part.net});
        return false;
    };
    const r: VecRange = switch (part.sel) {
        .whole => decl, // §6.5.7.1 a vector net in a concatenation: all of it
        .bit => .{ .msb = part.a, .lsb = part.a },
        .range => .{ .msb = part.a, .lsb = part.b },
        .up, .down => if (part.b < 1) {
            try self.err(tok, .E0352, "the indexed part-select of `{s}` is {d} wide", .{ part.net, part.b });
            return false;
        } else indexedRange(decl, part.a, part.b, part.sel == .down),
    };
    if (!partOf(decl, r)) {
        if (part.sel == .bit)
            try self.err(tok, .E0352, "`{s}` is [{d}:{d}], so {d} is not one of its elements", .{ part.net, decl.msb, decl.lsb, part.a })
        else
            try self.err(tok, .E0352, "`{s}` is [{d}:{d}], so [{d}:{d}] is not a part of it", .{ part.net, decl.msb, decl.lsb, r.msb, r.lsb });
        return false;
    }
    for (0..r.size()) |k| try out.append(self.arena, try lower_node_ref.internNodeElem(self, part.net, r.at(@intCast(k))));
    return true;
}

/// IEEE 1364-2005 §5.2.1's `base +: width` (`down` false) or `base -: width`
/// on a net declared `decl`: `+:` counts up from the base, `-:` down, and the
/// part reads in the declaration's direction. Saturates rather than overflow;
/// a saturated bound then lies outside `decl` (`partOf`).
pub fn indexedRange(decl: VecRange, base: i64, width: i64, down: bool) VecRange {
    const lo_i = if (down) base -| (width - 1) else base;
    const hi_i = if (down) base else base +| (width - 1);
    return if (decl.msb < decl.lsb) .{ .msb = lo_i, .lsb = hi_i } else .{ .msb = hi_i, .lsb = lo_i };
}

/// Whether `r` is a part of `decl` (IEEE 1364-2005 §5.2.1): both bounds lie
/// within it, and the msb is on the declared msb's side.
pub fn partOf(decl: VecRange, r: VecRange) bool {
    return decl.has(r.msb) and decl.has(r.lsb) and (r.msb == r.lsb or (r.msb < r.lsb) == (decl.msb < decl.lsb));
}

// ---- nodes --------------------------------------------------------------------

/// Returns the `nodes` row of net `name`, creating it on first use. Undeclared names
/// are implicit nets (§3.6.5); rows are created in source order.
pub fn internNode(self: *Lower, name: []const u8, discipline: []const u8) Oom!u32 {
    const gop = try self.node_voltages.getOrPut(self.arena, name);
    if (gop.found_existing) {
        if (discipline.len != 0 and gop.value_ptr.* != ground)
            self.out.nodes.items(.disc)[gop.value_ptr.*] = discipline;
        return gop.value_ptr.*;
    }
    const idx = try appendNode(self, name, discipline, .net);
    gop.value_ptr.* = idx;
    return idx;
}

/// §7.2.4: the node's potential tolerance is the smallest among the
/// continuous segments sharing it. Preserve the net's resolved discipline:
/// §5.5.3 still reads that net's local nature attributes, not this minimum.
pub fn collectSignalAbstols(self: *Lower, segments: []const Elaborate.SignalDiscipline) Oom!void {
    var key_buf: [lower_shape.elem_key_len]u8 = undefined;
    for (segments) |s| {
        const info = self.out.disciplines.get(s.discipline) orelse continue;
        if (info.is_discrete or !info.has_potential) continue;
        if (self.out.vectors.get(s.net)) |r| {
            for (0..r.size()) |k| {
                const key = try lower_shape.elemKey(self, &key_buf, s.net, &.{r.at(@intCast(k))});
                collectNodeAbstol(self, key, info.potential_abstol);
            }
        } else collectNodeAbstol(self, s.net, info.potential_abstol);
    }
}

fn collectNodeAbstol(self: *Lower, name: []const u8, abstol: f64) void {
    const idx = self.node_voltages.get(name) orelse return;
    if (idx == ground) return;
    const local = self.out.disciplines.get(self.out.nodes.items(.disc)[idx]) orelse return;
    if (local.is_discrete or !local.has_potential) return;
    const slot = &self.out.nodes.items(.potential_abstol)[idx];
    slot.* = @min(slot.* orelse local.potential_abstol, abstol);
}

/// Folds one §3.6.3.2 net_decl_assignment into a nodeset value for `node`.
/// "The initializer shall be a constant_expression": a failed fold reports E0365.
/// Parameters fold (§3.4). A string folds to 0.0, the unknown's own start value.
///
/// ponytail: the value is frozen at the parameter's declared default, so a card
/// override leaves a stale initial guess (never a wrong answer). Upgrade: keep the
/// `Ast.ExprId` and export `nodeset(model)` the way `derive()` is.
fn recordNodeset(self: *Lower, node: u32, e: Ast.ExprId, tok: u32, name: []const u8) Oom!void {
    assert(self.nodeValid(node));
    assert(e == .none or self.exprValid(e));
    const c = lower_constfold.constEval(self, e) orelse {
        var b = self.errWith(tok, .E0365);
        b.msg("the initializer of `{s}` is not a constant expression", .{name});
        b.note("§3.6.3.2 gives it to the analog solver as a nodeset value for the potential of `{s}`, which is fixed before the solve starts", .{name});
        try b.emit();
        return;
    };
    try self.out.nodesets.append(self.arena, .{ .node = node, .value = c.asReal(), .tok = tok });
}

/// Mints the §4.5.2 unknown one analog operator site introduces, spelled
/// `<op>$<k>`. Never deduped: each site owns its own unknown and row.
pub fn opStateNode(self: *Lower, op: []const u8, abstol: f64) Oom!u32 {
    const name = try self.arena.print("{s}${d}", .{ op, self.node_state.op_states });
    self.node_state.op_states += 1;
    return appendNode(self, name, "", .{ .op_state = abstol });
}

/// The one place a `nodes` row is created, fixing its kind and spelling together.
/// Does not dedupe: each caller owns identity (`node_voltages` for a net,
/// `flow_unknowns` for a branch, `port_probes` for a port), and two distinct
/// unknowns may ask for one name.
fn appendNode(self: *Lower, name: []const u8, discipline: []const u8, kind: NodeKind) Oom!u32 {
    if (self.out.nodes.len == max_nodes) {
        const m = self.module.?;
        if (!self.node_state.full) try self.err(m.main_tok, .E1015, "`{s}` needs more than {d} nets and unknowns", .{ self.file.str(m.name), max_nodes });
        self.node_state.full = true;
        return 0; // stands in for the row, so lowering reports the rest
    }
    assert(self.node_state.probe_cache.items.len == self.out.nodes.len); // one cache slot per row
    const idx: u32 = @intCast(self.out.nodes.len);
    const spelling = try uniqueSpelling(self, name);
    try self.node_state.spellings.put(self.arena, spelling, {});
    try self.out.nodes.append(self.arena, .{ .name = spelling, .kind = kind, .disc = discipline, .dir = .unspecified });
    try self.node_state.probe_cache.append(self.arena, .undef);
    assert(self.node_state.probe_cache.items.len == self.out.nodes.len);
    assert(idx < ground); // a row never spells the reference node
    return idx;
}

/// `name`, or the first `name#k` nobody has taken, since each slot is one `U` member.
/// Two slots can want one spelling: a net named `gnd` (§2.7) against the reference
/// node, or an escaped net `\flow(p,n)` (§2.8.1) against branch (p,n). `#` is not a
/// §2.7 identifier character, so a suffixed name cannot collide with a source one.
/// The suffix falls on the later slot, so it depends only on source order.
fn uniqueSpelling(self: *Lower, name: []const u8) Oom![]const u8 {
    if (!self.node_state.spellings.contains(name)) return name;
    // Losing candidates are built on the stack; only the winner reaches the arena.
    var buf: [spelling_buf_len]u8 = undefined;
    var k: u32 = 1;
    while (true) : (k += 1) {
        const cand = std.mem.print(&buf, "{s}#{d}", .{ name, k }) catch
            try self.arena.print("{s}#{d}", .{ name, k });
        if (!self.node_state.spellings.contains(cand)) return self.arena.dupe(u8, cand);
    }
}

/// Widest spelling `uniqueSpelling` builds without spilling: two 1024-character
/// identifiers (the bound `elem_key_len` uses), punctuation, and `#` with a `u32`.
const spelling_buf_len = 2 * 1024 + 32;

/// Returns the name codegen prints for a `nodes` row, or "gnd" for `ground`.
pub fn nodeName(self: *const Lower, idx: u32) []const u8 {
    return self.out.nodeName(idx);
}

/// Returns the §4.4 potential probe of one node, deduped so a node is one
/// `block_param` (codegen's `x[idx]`); ground is the literal 0 (§1.3.1.1).
pub fn probe(self: *Lower, idx: u32) Oom!Mir.Value {
    if (idx == ground) return .f_zero;
    if (self.node_state.probe_cache.items[idx] != .undef) return self.node_state.probe_cache.items[idx];
    const v = try self.mir.addBlockParam(self.arena, idx);
    self.node_state.probe_cache.items[idx] = v;
    return v;
}

/// Returns the `nodes` row of branch (hi, lo)'s current, the solver unknown a §5.4.2
/// flow read creates. Deduped on the node pair (the §5.4.1 identity), not the
/// printed name, since a net called `gnd` prints like the reference node.
pub fn flowUnknown(self: *Lower, hi: u32, lo: u32) Oom!u32 {
    assert(self.nodeValid(hi));
    assert(self.nodeValid(lo));
    const gop = try self.out.flow_unknowns.getOrPut(self.arena, .{ .hi = hi, .lo = lo });
    if (gop.found_existing) return gop.value_ptr.*;
    const name = try self.arena.print("flow({s},{s})", .{ nodeName(self, hi), nodeName(self, lo) });
    // The tolerance node is the HIGH one: a branch unknown carries no discipline
    // of its own (§3.6.1.2's abstol has to come from somewhere).
    const u = try appendNode(self, name, "", .{ .branch_flow = hi });
    gop.value_ptr.* = u;
    return u;
}

/// Returns the §5.4.3 unknown carrying `I(<p>)`, spelled `flow(<p>)`. `port_probes`
/// is the identity (a linear scan over the module's ports), so a net spelled
/// `flow(<p>)` cannot take over the port's current.
pub fn portFlowUnknown(self: *Lower, p: u32) Oom!u32 {
    assert(self.nodeValid(p));
    for (self.out.port_probes.items) |pp| {
        if (pp.port == p) return pp.u;
    }
    const name = try self.arena.print("flow(<{s}>)", .{nodeName(self, p)});
    const u = try appendNode(self, name, "", .{ .port_flow = p });
    try self.out.port_probes.append(self.arena, .{ .port = p, .u = u });
    return u;
}

test "lower: §6.5 the ports are the first rows, in declaration order, a vector msb first" {
    var h: Lower.Harness = undefined;
    try h.init(std.testing.allocator,
        \\module m(a, b);
        \\  inout a;
        \\  inout [1:0] b;
        \\  electrical a;
        \\  electrical [1:0] b;
        \\  electrical n;
        \\  analog I(a) <+ V(a);
        \\endmodule
    );
    defer h.deinit();
    const out = try h.lower() orelse {
        h.dump();
        return error.TestUnexpectedResult;
    };
    const want = [_][]const u8{ "a", "b[1]", "b[0]", "n" };
    try std.testing.expectEqual(want.len, out.nodes.len);
    for (want, out.nodes.items(.name)) |w, got| try std.testing.expectEqualStrings(w, got);
    try std.testing.expectEqual(3, out.num_ports);
    for (out.nodes.items(.dir)[0..3]) |d| try std.testing.expectEqual(Ast.Direction.inout, d);
    try std.testing.expectEqual(Ast.Direction.unspecified, out.nodes.items(.dir)[3]);
}

test "lower: §3.6.3.2 a net_decl_assignment folds to a nodeset, a bus element by element" {
    var h: Lower.Harness = undefined;
    try h.init(std.testing.allocator,
        \\module m(p);
        \\  inout p; electrical p;
        \\  parameter real v0 = 0.5;
        \\  electrical q = v0;
        \\  electrical [1:0] bus = '{0.25, 0.75};
        \\  analog I(p) <+ V(p);
        \\endmodule
    );
    defer h.deinit();
    const out = try h.lower() orelse {
        h.dump();
        return error.TestUnexpectedResult;
    };
    // The bus pattern is positional from the declared msb (`VecRange.at`).
    const want = [_]struct { name: []const u8, value: f64 }{
        .{ .name = "q", .value = 0.5 },
        .{ .name = "bus[1]", .value = 0.25 },
        .{ .name = "bus[0]", .value = 0.75 },
    };
    try std.testing.expectEqual(want.len, out.nodesets.items.len);
    for (want, out.nodesets.items) |w, ns| {
        try std.testing.expectEqualStrings(w.name, out.nodes.items(.name)[ns.node]);
        try std.testing.expectEqual(w.value, ns.value);
    }
}

test "lower: §3.6.3 net declarations: one discipline each, constant ranges and nodesets" {
    const cases = [_]struct { decls: []const u8, want: ?@import("diag").Code }{
        // §7.4.4: a second declaration, compatible or not (E0902).
        .{ .decls = "  electrical q;\n  electrical q;", .want = .E0902 },
        // §3.6.3.2 "The initializer shall be a constant_expression" (E0365).
        .{ .decls = "  real v;\n  electrical q = v;", .want = .E0365 },
        // One row per element, any count the u32 row space holds (#29):
        // 70001 rows was past the old u16 space.
        .{ .decls = "  electrical [0:70000] w;", .want = null },
        // Past the u32 row space is E1015, before a row is allocated.
        .{ .decls = "  electrical [0:5000000000] w;", .want = .E1015 },
        // §3.6.3 a range bound is a constant integer; NaN is none (E0352).
        .{ .decls = "  electrical [0:0.0/0.0] w;", .want = .E0352 },
        // §3.12.1 a port branch is over a port (E0372).
        .{ .decls = "  electrical q;\n  branch (<q>) pb;", .want = .E0372 },
    };
    for (cases) |c| try Lower.expectBodyVerdict(c.decls, "", c.want);
}

test "lower: §6.5.2.2 the two declarations of a port carry identical ranges once folded" {
    // The clause's own pair of examples.
    try Lower.expectVerdict(
        \\module m(a);
        \\  input [0:3] a;
        \\  electrical [0:4-1] a;
        \\  analog I(a[0]) <+ V(a[0]);
        \\endmodule
    , null);
    try Lower.expectVerdict(
        \\module m(a);
        \\  input [3:0] a;
        \\  electrical [0:3] a;
        \\  analog I(a[0]) <+ V(a[0]);
        \\endmodule
    , .E0350);
}

test uniqueSpelling {
    // One `U` member per row: a taken spelling gets the first free `#k`.
    var h: Lower.Harness = undefined;
    try h.init(std.testing.allocator, "module m; endmodule");
    defer h.deinit();
    const s = &h.low.node_state.spellings;
    try std.testing.expectEqualStrings("x", try uniqueSpelling(&h.low, "x"));
    try s.put(h.low.arena, "x", {});
    try std.testing.expectEqualStrings("x#1", try uniqueSpelling(&h.low, "x"));
    try s.put(h.low.arena, "x#1", {});
    try std.testing.expectEqualStrings("x#2", try uniqueSpelling(&h.low, "x"));
    // A name too long for the stack buffer spills and still gets its suffix.
    const long: [spelling_buf_len]u8 = @splat('y');
    try s.put(h.low.arena, &long, {});
    const got = try uniqueSpelling(&h.low, &long);
    try std.testing.expectEqual(long.len + 2, got.len);
    try std.testing.expectEqualStrings("#1", got[long.len..]);
}

test indexedRange {
    // IEEE 1364-2005 §5.2.1: `base +: w` counts up from base and `base -: w`
    // down, and the part reads in the declaration's direction.
    const desc: VecRange = .{ .msb = 7, .lsb = 0 };
    const asc: VecRange = .{ .msb = 0, .lsb = 7 };
    const cases = [_]struct { decl: VecRange, base: i64, width: i64, down: bool, want: VecRange }{
        .{ .decl = desc, .base = 3, .width = 2, .down = false, .want = .{ .msb = 4, .lsb = 3 } },
        .{ .decl = desc, .base = 3, .width = 2, .down = true, .want = .{ .msb = 3, .lsb = 2 } },
        .{ .decl = asc, .base = 3, .width = 2, .down = false, .want = .{ .msb = 3, .lsb = 4 } },
        .{ .decl = asc, .base = 3, .width = 2, .down = true, .want = .{ .msb = 2, .lsb = 3 } },
        .{ .decl = desc, .base = 5, .width = 1, .down = false, .want = .{ .msb = 5, .lsb = 5 } },
    };
    for (cases) |c| {
        const got = indexedRange(c.decl, c.base, c.width, c.down);
        try std.testing.expectEqual(c.want.msb, got.msb);
        try std.testing.expectEqual(c.want.lsb, got.lsb);
    }
    // Saturated rather than overflowed, and then no part of anything.
    const far = indexedRange(desc, std.math.maxInt(i64), 2, false);
    try std.testing.expectEqual(std.math.maxInt(i64), far.msb);
    try std.testing.expect(!partOf(desc, far));
}

test partOf {
    const desc: VecRange = .{ .msb = 7, .lsb = 0 };
    try std.testing.expect(partOf(desc, .{ .msb = 4, .lsb = 3 }));
    try std.testing.expect(partOf(desc, .{ .msb = 5, .lsb = 5 }));
    try std.testing.expect(partOf(desc, .{ .msb = 7, .lsb = 0 }));
    // The msb on the declared lsb's side.
    try std.testing.expect(!partOf(desc, .{ .msb = 3, .lsb = 4 }));
    try std.testing.expect(!partOf(desc, .{ .msb = 8, .lsb = 7 }));
    try std.testing.expect(!partOf(desc, .{ .msb = 0, .lsb = -1 }));
}
