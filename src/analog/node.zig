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
const Lower = @import("lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_contrib = @import("contrib.zig");
const lower_discipline = @import("discipline.zig");
const discipline_rules = @import("elab").discipline_rules;
const Elaborate = @import("elab").Elaborate;
const lower_expr = @import("expr.zig");
const lower_shape = @import("shape.zig");
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Preprocessor = @import("frontend").Preprocessor;
const assert = std.debug.assert;
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
const max_nodes = ground;

// ---- the module's declarations, in `lowerModule`'s order ---------------------

/// §6.5 interns the module's ports as the first `nodes` rows, in declaration
/// order, which is the host device's terminal order; a §3.6.3 vector port is
/// one row per element, msb first. Sets `Lowered.num_ports` to the row count
/// after them.
pub fn declarePorts(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    for (module.ports) |p| {
        // §3.6.3/§6.5.2 a vector port is N terminals, in declaration order.
        if (try portRange(self, &p)) |r| {
            const name = self.file.str(p.name);
            const disc = strOrEmpty(self, p.discipline);
            for (0..r.size()) |k| {
                const idx = try internNode(self, try self.arena.print("{s}[{d}]", .{ name, r.at(@intCast(k)) }), disc);
                self.out.nodes.items(.dir)[idx] = p.direction;
            }
            try self.out.vectors.put(self.arena, name, r);
            continue;
        }
        const idx = try internNode(self, try netKey(self, self.file.str(p.name), p.main_tok), strOrEmpty(self, p.discipline));
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
    for (module.nets) |n| {
        if (self.out.discrete_inputs.contains(self.file.str(n.name))) continue;
        // §2.8.1 vs §3.6.3 (see `netKey`). A ranged declaration is a vector and
        // its own name never reaches the node table, so the key is the scalar
        // path's and the `vectors` entry below keeps the declared spelling.
        const name = try netKey(self, self.file.str(n.name), n.main_tok);
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
            if (try foldDim(self, d, n.main_tok)) |r| {
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
                    const idx = try internNode(self, try self.arena.print("{s}[{d}]", .{ name, r.at(@intCast(k)) }), strOrEmpty(self, n.discipline));
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
        const idx = try internNode(self, name, strOrEmpty(self, n.discipline));
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
    for (self.port_widths) |pw| {
        const port: u64 = if (pw.range) |d| ((try foldDim(self, d, pw.main_tok)) orelse continue).size() else 1;
        const net: u64 = if (self.out.vectors.get(pw.net)) |v| v.size() else if (self.node_voltages.contains(pw.net)) 1 else continue;
        if (port != net)
            try self.err(pw.main_tok, .E0925, "`{s}` is {d} wide and the port it connects is {d}", .{ pw.net, net, port });
    }

    // §6.5.7.1 a vector port bound to a concatenated net expression or to
    // §6.5.5's sub-range of a net: element k of the port IS bit k of the
    // connection, so its key names that bit's node.
    var bits: std.ArrayList(u32) = .empty;
    for (self.port_concats) |pc| {
        bits.clearRetainingCapacity();
        var ok = for (pc.parts) |part| {
            if (!try partNodes(self, part, pc.main_tok, &bits)) break false;
        } else true;
        const r: ?VecRange = if (pc.range) |d| (try foldDim(self, d, pc.main_tok)) orelse continue else null;
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
    for (0..r.size()) |k| try out.append(self.arena, try internNodeElem(self, part.net, r.at(@intCast(k))));
    return true;
}

/// IEEE 1364-2005 §5.2.1's `base +: width` (`down` false) or `base -: width`
/// on a net declared `decl`: `+:` counts up from the base, `-:` down, and the
/// part reads in the declaration's direction. Saturates rather than overflow;
/// a saturated bound then lies outside `decl` (`partOf`).
fn indexedRange(decl: VecRange, base: i64, width: i64, down: bool) VecRange {
    const lo_i = if (down) base -| (width - 1) else base;
    const hi_i = if (down) base else base +| (width - 1);
    return if (decl.msb < decl.lsb) .{ .msb = lo_i, .lsb = hi_i } else .{ .msb = hi_i, .lsb = lo_i };
}

/// Whether `r` is a part of `decl` (IEEE 1364-2005 §5.2.1): both bounds lie
/// within it, and the msb is on the declared msb's side.
fn partOf(decl: VecRange, r: VecRange) bool {
    return decl.has(r.msb) and decl.has(r.lsb) and (r.msb == r.lsb or (r.msb < r.lsb) == (decl.msb < decl.lsb));
}

/// §7.4 resolution, as far as VerA implements it: §10.2's default discipline
/// on every port and net, after every declaration is interned. Then the rules
/// that need a net's final discipline: §3.9 primitive terminals, §1.3.4's
/// `inout` ban on signal-flow ports (E0360) and §3.6.3.2's ban on a discrete
/// net's nodeset (E0366).
pub fn resolveDisciplines(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    // §7.4 discipline resolution, the one rule of it VerA implements: §10.2's
    // default. It runs here, after every declaration has been interned: a port
    // and a body declaration of the same net are two entries
    // (`module (p); inout p; electrical p;`), and a default written at the
    // first would make the second a §7.4.4 second declaration (E0902).
    //
    // A vector is scalarised by now, so the default is applied to the
    // elements: `p` itself is not a node.
    //
    // §10.2 picks the default by the signal's net type, which the parser
    // folds into a port from its body declaration (`inout q; tri q;`).
    for (module.ports) |p| try applyDefaultToAll(self, self.file.str(p.name), p.main_tok, qualifierOf(p.kind));
    for (module.nets) |n| if (!self.out.discrete_inputs.contains(self.file.str(n.name)))
        try applyDefaultToAll(self, self.file.str(n.name), n.main_tok, qualifierOf(n.kind));
    // §3.9 a digital primitive on a continuous net needs the default the loops
    // above just applied — after them, so a net it made discrete is not mixed.
    try checkPrimitiveDisciplines(self, module);

    // §1.3.4.1 "Nets of potential signal flow disciplines in modules may only
    // be bound to `input` or `output` ports of the module, not to `inout`
    // ports"; §1.3.4.2 says the same of flow signal-flow disciplines. The
    // sibling of E0425, which rules on the contribution target rather than the
    // declaration.
    //
    // Here and not in the port loop, because only now is the discipline known:
    // `inout p; voltage p;` splits direction and discipline across two
    // declarations, and §10.2's default arrives in the `applyDefaultToAll`
    // loops above.
    //
    // `.unspecified` is deliberately not caught: §6.5.2 leaves a port with no
    // direction declaration to §3.9, and the clause names `inout` only.
    for (module.ports) |p| {
        if (p.direction != .inout) continue;
        const base = self.file.str(p.name);
        // A vector port is N nets sharing one declaration and therefore one
        // discipline (§6.5.2), so the first element answers for all of them and
        // the violation is reported once, at the declaration that commits it.
        var key_buf: [lower_shape.elem_key_len]u8 = undefined;
        const probe_name = if (self.out.vectors.get(base)) |r| try lower_shape.elemKey(self, &key_buf, base, &.{r.at(0)}) else base;
        const idx = self.node_voltages.get(probe_name) orelse continue;
        if (idx == ground) continue;
        const dname = self.out.nodes.items(.disc)[idx];
        if (!isSignalFlow(self, dname)) continue;
        var b = self.errWith(p.main_tok, .E0360);
        b.msg("`{s}` is an `inout` port of discipline `{s}`, which binds a {s} nature only", .{
            base, dname, if (self.out.disciplines.get(dname).?.has_potential) "potential" else "flow",
        });
        b.help("declare `{s}` as `input` or `output`", .{base});
        try b.emit();
    }

    // §3.6.3.2: "Nets with continuous disciplines are allowed to have
    // initializers on their net discipline declarations; however, nets of
    // non-continuous disciplines are not."
    //
    // Here for the same reason E0360 is here and not at the declaration: a net
    // and its discipline can arrive in two declarations, and §10.2's default
    // arrives in the `applyDefaultToAll` loops above. A net that still has no
    // discipline at this point is left alone — it is §3.6.5's implicit net,
    // whose domain is decided by resolution (§7.4) and not by this module, and
    // E0337 already rules on it if anything analog touches it.
    for (self.out.nodesets.items) |ns| {
        const dname = self.out.nodes.items(.disc)[ns.node];
        const info = self.out.disciplines.get(dname) orelse continue;
        if (!info.is_discrete) continue;
        var b = self.errWith(ns.tok, .E0366);
        b.msg("`{s}` is of discipline `{s}`, whose domain is discrete", .{ self.out.nodes.items(.name)[ns.node], dname });
        b.note("a nodeset is an initial guess for a POTENTIAL, and §3.6.2.2 leaves a discrete discipline with no nature to have one", .{});
        try b.emit();
    }
}

/// §3.12 the module's named branches: a node pair with a fresh `BranchInfo.id`
/// each (an A.2.3 branch array is one pair and several ids), a §3.12.1 port
/// branch as the port it names, and a branch with a vector terminal as a
/// vector branch. Runs after `declareNets`, so every terminal has its row.
pub fn declareBranches(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    // §3.12 named branches.
    for (module.branches) |b| {
        const base = self.file.str(b.name);
        // A.2.3 `list_of_branch_identifiers ::= branch_identifier [ range ]
        // { , branch_identifier [ range ] }`: a branch array, several branches
        // over one declared terminal pair. Folded here and not in the parser
        // because the bounds are constant EXPRESSIONS (same reason as §6.5.2.2's
        // port ranges), and the elements are registered under their scalarised
        // names so `V(pair[1])` resolves through the ordinary branch lookup.
        const arr: ?VecRange = if (b.range) |d|
            (try foldDim(self, d, b.main_tok) orelse continue)
        else
            null;
        if (b.is_port_branch) {
            // §3.12.1 "A port branch is a special type of branch used to access
            // the flow into a port of a module (see 5.4.3). It is a branch
            // between the upper and lower connections of the port." Recorded as
            // the port and not as a node pair, because those two connections are
            // one node here: a pair would give an identically zero potential and
            // an unconstrained second flow unknown. The flow is `I(<p>)`'s (see
            // `lowerBranchAccess`).
            const p = try nodeOf(self, b.hi);
            for (0..(if (arr) |r| r.size() else 1)) |k| {
                const key = if (arr) |r| try self.arena.print("{s}[{d}]", .{ base, r.at(@intCast(k)) }) else base;
                try self.port_branches.put(self.arena, key, p);
            }
        } else if (arr) |r| {
            // A.2.3's branch array: the elements share one (hi, lo) and are
            // separate branches over it (§5.4.1 "any number of named branches
            // between any two signals"), so each takes its own identity and its
            // own accumulator: `br1[0]` and `br1[1]` are two sources.
            const hi = try nodeOf(self, b.hi);
            const lo = if (b.lo == .none) ground else try nodeOf(self, b.lo);
            try lower_discipline.checkNetCompat(self, b.main_tok, hi, lo); // §3.12 → §3.11
            for (0..r.size()) |k|
                try self.branches.put(self.arena, try self.arena.print("{s}[{d}]", .{ base, r.at(@intCast(k)) }), .{
                    .hi = hi,
                    .lo = lo,
                    .id = newBranchId(self),
                });
        } else if (try vecTerminal(self, b.hi, b.main_tok)) |hv| {
            // §3.12 a branch with a vector terminal is a vector branch.
            try declareVectorBranch(self, &b, hv, try vecTerminal(self, b.lo, b.main_tok));
            continue;
        } else if (try vecTerminal(self, b.lo, b.main_tok)) |lv| {
            try declareVectorBranch(self, &b, null, lv);
            continue;
        } else if (partSelect(self, b.hi) or partSelect(self, b.lo)) {
            continue; // `vecTerminal` has refused the part (E0352)
        } else {
            const hi = try nodeOf(self, b.hi);
            const lo = if (b.lo == .none) ground else try nodeOf(self, b.lo);
            // §3.12: "The disciplines for the specified nets shall be
            // compatible (see 3.11)." Only the two-terminal form has two
            // disciplines to compare; the one-terminal form's second net is
            // ground, and §3.12 says the branch then "derives" its discipline
            // from the one net that is named.
            try lower_discipline.checkNetCompat(self, b.main_tok, hi, lo);
            try self.branches.put(self.arena, base, .{ .hi = hi, .lo = lo, .id = newBranchId(self) });
        }
        // The base name is a vector, so `V(pair)` and `V(pair[9])` get the
        // vector diagnostics (E0351/E0352) rather than interning an implicit
        // net, as `declareVectorBranch` arranges for a vector terminal.
        if (arr) |r| try self.out.vectors.put(self.arena, base, r);
    }
}

/// The declared discipline's spelling, `""` for none (§3.6.5, §3.9).
fn strOrEmpty(self: *const Lower, id: Ast.StrId) []const u8 {
    return if (id == .none) "" else self.file.str(id);
}
// ---- nodes --------------------------------------------------------------------

/// Reports whether `dname` is a §1.3.4 signal-flow discipline: exactly one of its
/// two natures is bound. A discipline binding both is conservative (§3.6.2.1); one
/// binding neither (natureless continuous, or discrete) is not signal-flow either.
pub fn isSignalFlow(self: *const Lower, dname: []const u8) bool {
    if (dname.len == 0) return false;
    const d = self.out.disciplines.get(dname) orelse return false;
    return d.has_potential != d.has_flow;
}

/// Applies the `default_discipline in force at `main_tok` for a `q` signal to
/// net `name`, or to each scalarised element when it is a §3.6.3 vector (LRM §10.2).
fn applyDefaultToAll(self: *Lower, name: []const u8, main_tok: u32, q: ?Preprocessor.Qualifier) Oom!void {
    const r = self.out.vectors.get(name) orelse
        return applyDefaultDiscipline(self, try netKey(self, name, main_tok), main_tok, q);
    var key_buf: [lower_shape.elem_key_len]u8 = undefined;
    for (0..r.size()) |k|
        try applyDefaultDiscipline(self, try lower_shape.elemKey(self, &key_buf, name, &.{r.at(@intCast(k))}), main_tok, q);
}

/// §10.2 the Syntax 10-1 `qualifier` a net of type `kind` answers to. Null for
/// `uwire`, which the list lacks, so only an unqualified default applies.
fn qualifierOf(kind: Ast.NetKind) ?Preprocessor.Qualifier {
    return std.meta.stringToEnum(Preprocessor.Qualifier, @tagName(kind));
}

/// §10.2: "The default discipline is applied ... to all discrete signals without a
/// discipline declaration that appear in the text stream following the use of the
/// `default_discipline directive." So only a net that still has none, and only a
/// directive preceding its declaration, qualified for its type `q` or unqualified.
fn applyDefaultDiscipline(self: *Lower, name: []const u8, main_tok: u32, q: ?Preprocessor.Qualifier) Oom!void {
    if (self.directives.disciplines.len == 0) return;
    const idx = self.node_voltages.get(name) orelse return;
    if (idx == ground) return;
    if (self.out.nodes.items(.disc)[idx].len != 0) return;
    const dname = defaultDisciplineAt(self, main_tok, q) orelse return;
    // A default naming a discipline that was never declared supplies no
    // nature, so the net stays bare and E0337 reports it.
    if (!self.out.disciplines.contains(dname)) return;
    self.out.nodes.items(.disc)[idx] = dname;
}

/// §10.2 the `default_discipline in force for a `q` signal at token `main_tok`, or null.
fn defaultDisciplineAt(self: *const Lower, main_tok: u32, q: ?Preprocessor.Qualifier) ?[]const u8 {
    if (main_tok >= self.tok_starts.len) return null;
    return Preprocessor.DefaultDiscipline.inForce(self.directives.disciplines, self.tok_starts[main_tok], q);
}

/// §3.9 "For digital primitives the domain is discrete and thus the discipline
/// is set via the default_discipline directive as it is for digital modules.
/// If the discipline of digital connections (vpiLoConn) to a mixed net are
/// unknown then the default_discipline must be specified (via the directive or
/// other vendor specific method). If not specified, an error will result
/// during discipline resolution." Reports E0960.
///
/// Every gate, pull source or switch terminal is such a digital connection, and
/// its net is mixed when the net's own discipline is continuous. VerA has no
/// vendor-specific method, so only the directive in force at the primitive can
/// supply the connection's discipline. Must run after `applyDefaultToAll`.
fn checkPrimitiveDisciplines(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    for (module.gates) |g| {
        try checkPrimitiveTerminal(self, g.out, g.main_tok, "gate");
        for (g.ins) |t| try checkPrimitiveTerminal(self, t, g.main_tok, "gate");
    }
    for (module.pulls) |p| try checkPrimitiveTerminal(self, p.out, p.main_tok, "pull source");
    for (module.switches) |sw| for (sw.terms) |t| try checkPrimitiveTerminal(self, t, sw.main_tok, "switch");
}

fn checkPrimitiveTerminal(self: *Lower, term: Ast.ExprId, prim_tok: u32, what: []const u8) Oom!void {
    const ex = &self.file.exprs;
    const base = self.file.lvalueBase(term);
    if (base == .none or ex.tag(base) != .ident) return;
    if (defaultDisciplineAt(self, prim_tok, .wire) != null) return;
    const name = self.file.str(ex.strOf(base));
    // A vector is scalarised by now and its elements share one discipline
    // (§3.6.3), so the first element answers for the whole net.
    var key_buf: [lower_shape.elem_key_len]u8 = undefined;
    const key = if (self.out.vectors.get(name)) |r| try lower_shape.elemKey(self, &key_buf, name, &.{r.at(0)}) else name;
    const idx = self.node_voltages.get(key) orelse return;
    if (idx == ground) return;
    const dname = self.out.nodes.items(.disc)[idx];
    const decl = lower_discipline.disciplineDecl(self, dname) orelse return;
    if (discipline_rules.domainOf(decl) != .continuous) return;
    var b = self.errWith(ex.mainTok(base), .E0960);
    b.msg("`{s}` is of continuous discipline `{s}` and a terminal of a digital {s}", .{ name, dname, what });
    b.note("the primitive's side of the net is discrete, so the net is mixed, and no `default_discipline is in force to name that side's discipline", .{});
    b.help("put `default_discipline logic (or another discrete discipline) before the primitive", .{});
    try b.emit();
}

/// Reports an error when IEEE 1364 §19.2 `` `default_nettype none `` is in force at
/// `main_tok`, on a name about to become a §3.6.5 implicit net. Other net types are
/// a no-op: VerA's analog nets have a discipline, not a net type.
///
/// ponytail: the other ten values are accepted and dropped; they differ only in
/// how multiple drivers resolve, which VerA does not model. Upgrade: a discrete
/// net type on `Ast.NetDecl`.
pub fn rejectImplicitNet(self: *Lower, name: []const u8, main_tok: u32) Oom!void {
    if (Preprocessor.NetTypeRegion.inForce(self.directives.nettypes, self.tokStart(main_tok), .default) != .none) return;
    var b = self.errWith(main_tok, .E0367);
    b.msg("`{s}` was never declared, and `default_nettype none is in force", .{name});
    b.note("§3.6.5 would make it an implicit net; IEEE 1364 §19.2's `none` is what withdraws that", .{});
    b.help("declare it — `electrical {s};` — or go back to `default_nettype wire", .{name});
    try b.emit();
}

/// Applies IEEE 1364 §19.9 `unconnected_drive to the internal nets §6.2.2 gave
/// unconnected `input` ports: `pull0` holds the port at potential 0 and `pull1` at 1,
/// in its discipline's potential units, through a potential source. Must run after
/// the declarations are interned and before the analog blocks lower. Skips a net
/// whose discipline binds no potential.
///
/// ponytail: 1.0 stands in for §19.9's Pu1 strength; the upgrade is discrete net
/// resolution, where a pull is a driver rather than a potential.
pub fn applyUnconnectedDrive(self: *Lower) Oom!void {
    if (self.directives.drives.len == 0) return;
    for (self.unconnected_inputs) |site| {
        const drive = Preprocessor.DriveRegion.inForce(self.directives.drives, self.tokStart(site.main_tok), .default);
        if (drive == .float) continue;
        const idx = self.node_voltages.get(site.name) orelse continue;
        if (idx == ground) continue;
        const info = self.out.disciplines.get(self.out.nodes.items(.disc)[idx]) orelse continue;
        if (!info.has_potential) continue;
        const target: lower_contrib.Target = .{ .access = .potential, .hi = idx, .lo = ground };
        const acc = self.accum.items[try lower_contrib.contribIndex(self, target, site.main_tok)];
        const old = try self.builder.readVariable(acc.resist, self.cur);
        const level: Mir.Value = if (drive == .pull1) .f_one else .f_zero;
        try self.builder.writeVariable(acc.resist, self.cur, try self.emit(.fadd, &.{ old, level }));
        // §5.6.1.3: retained on every path, like an unconditional `<+`.
        try self.builder.writeVariable(acc.wrote, self.cur, .f_one);
    }
}

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

/// §3.12.1 "A port branch ... is a branch between the upper and lower
/// connections of the port", Syntax 3-9 `branch ( < port_identifier > )`.
/// Checked per source module, since after flattening a child's port may be an
/// internal node of the device.
pub fn checkPortBranchDecls(self: *Lower) Oom!void {
    const ex = &self.file.exprs;
    for (self.file.modules[self.file.builtin_modules..]) |*m| for (m.branches) |b| {
        if (!b.is_port_branch) continue;
        const t = if (ex.tag(b.hi) == .index) ex.lhs(b.hi) else b.hi;
        if (ex.tag(t) != .ident) continue; // nodeOf reports a malformed terminal
        const name = ex.strOf(t);
        for (m.ports) |p| {
            if (p.name == name) break;
        } else try self.err(b.main_tok, .E0372, "`{s}` is declared over `{s}`, which is not a port of `{s}`", .{
            self.file.str(b.name), self.file.str(name), self.file.str(m.name),
        });
    };
}

/// Resolves a net reference, `n` or `n[i]`, to a `nodes` row. An access function
/// takes "scalars or individual elements of a vector" (§5.5.2), so a bare vector
/// name reports E0351 and an undeclared element E0351/E0352.
pub fn nodeOf(self: *Lower, e: Ast.ExprId) Oom!u32 {
    if (e == .none) return ground;
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .ident => {
            // §2.8.1, see `netKey`. The reference to `\bus[0] ` is an `.ident`
            // and the reference to element 0 of `bus` is an `.index`, so the two
            // never share a path here; only the KEY had to be kept apart.
            const name = try netKey(self, self.file.str(ex.strOf(e)), ex.mainTok(e));
            if (self.out.vectors.get(name)) |r| {
                try self.err(self.file.exprs.mainTok(e), .E0351, "`{s}` is a vector [{d}:{d}]; name one element of it", .{ name, r.msb, r.lsb });
                return ground;
            }
            // IEEE 1364 §19.2's `none`: this is the one place an undeclared name
            // becomes a net. Checked here, not in `internNode`, which also interns
            // every declared net.
            if (!self.node_voltages.contains(name))
                try rejectImplicitNet(self, name, self.file.exprs.mainTok(e));
            return internNode(self, name, "");
        },
        // §6.7.1 a hierarchical terminal, `V(u.a)`: elaboration named the child's
        // net `u.a`, so `flatName` resolves it. It never interns a new node:
        // §3.6.5's implicit net applies only to an undeclared simple name.
        .hier_ident => {
            if (try lower_expr.refuseUnnamedGen(self, e)) return ground;
            const name = try lower_expr.flatName(self, e);
            if (!self.node_voltages.contains(name)) {
                try self.err(self.file.exprs.mainTok(e), .E0901, "`{s}` names no net in the elaborated design", .{name});
                return ground;
            }
            return internNode(self, name, "");
        },
        .index => {
            const base = ex.lhs(e);
            // `u.v[1]`: §6.7.1's hierarchical terminal, one element of it.
            const name = switch (ex.tag(base)) {
                .ident => self.file.str(ex.strOf(base)),
                .hier_ident => if (try lower_expr.refuseUnnamedGen(self, base)) return ground else try lower_expr.flatName(self, base),
                else => { // else: a select of anything but a net name is no net reference: E0306
                    try self.err(self.file.exprs.mainTok(e), .E0306, "", .{});
                    return ground;
                },
            };
            const r = self.out.vectors.get(name) orelse {
                try self.err(self.file.exprs.mainTok(e), .E0351, "`{s}` was not declared with a range", .{name});
                return ground;
            };
            // A part-select names several nets: a vector branch's terminal
            // (`vecTerminal`), never one node.
            if (partSelect(self, e)) {
                try self.err(self.file.exprs.mainTok(e), .E0351, "a part-select of `{s}` names several nets; a branch declaration takes one (§3.12), a probe one element", .{name});
                return ground;
            }
            // §5.5.2 "The index must be a constant expression, though it may
            // include genvar variables"; `tryUnrollFor` binds the genvar in
            // `consts` for each unrolled copy.
            const c = lower_constfold.constEval(self, ex.rhs(e)) orelse {
                try self.err(self.file.exprs.mainTok(e), .E0352, "index into `{s}` is not a constant expression", .{name});
                return ground;
            };
            // §4.2.1.1: a NaN, an infinity or a real past i64 rounds to no
            // integer, so it names no element (a saturated one named one).
            const i = c.asIntExact() orelse {
                try self.err(self.file.exprs.mainTok(e), .E0352, "index {e} into `{s}` is no integer", .{ c.asReal(), name });
                return ground;
            };
            if (!r.has(i)) {
                try self.err(self.file.exprs.mainTok(e), .E0352, "`{s}` is [{d}:{d}], so {d} is not one of its elements", .{ name, r.msb, r.lsb, i });
                return ground;
            }
            return internNodeElem(self, name, i);
        },
        else => { // else: not a net reference: E0306
            try self.err(self.file.exprs.mainTok(e), .E0306, "", .{});
            return ground;
        },
    }
}

/// The node-table key for a net named by the source identifier at `tok`.
///
/// §2.8.1: "Escaped identifiers shall start with the backslash character (\) and
/// end with white space ... Neither the leading backslash character nor the
/// terminating white space is considered to be part of the identifier." So
/// `electrical \bus[0] ;` declares a SCALAR net whose name is the five
/// characters `bus[0]`, the same as `internNodeElem`'s name for element 0 of
/// `electrical [0:1] bus`, which is a generated name (§3.13.3) and a different
/// object. Only the token still shows the `\` (the parser strips it), so an escaped
/// name ending in `]` gets the `\` back in its key; other names keep theirs.
///
/// ponytail: allocates a fresh arena copy per reference; such names are rare.
fn netKey(self: *Lower, name: []const u8, tok: u32) Oom![]const u8 {
    if (name.len == 0 or name[name.len - 1] != ']') return name;
    if (tok >= self.tok_starts.len) return name;
    const at = self.tok_starts[tok];
    if (at >= self.src.len or self.src[at] != '\\') return name;
    return self.arena.print("\\{s}", .{name});
}

/// `internNode` for a vector element, spelled as the source does (`bus[3]`).
/// Looks up on a stack buffer and allocates only for a new element.
fn internNodeElem(self: *Lower, base: []const u8, i: i64) Oom!u32 {
    var buf: [lower_shape.elem_key_len]u8 = undefined;
    const key = try lower_shape.elemKey(self, &buf, base, &.{i});
    const name = self.node_voltages.getKey(key) orelse try self.arena.print("{s}[{d}]", .{ base, i });
    return internNode(self, name, "");
}

/// Folds a declared `[msb:lsb]` (§3.6.3 Syntax 3-6); the bounds are constant
/// expressions (`electrical [0:4-1] in;`, §6.5.2.2). Returns null after a diagnostic.
pub fn foldDim(self: *Lower, d: Ast.Dim, tok: u32) Oom!?VecRange {
    const msb = lower_constfold.shapeEval(self, d.msb) orelse {
        try self.err(tok, .E0352, "the msb of the range is not a constant expression", .{});
        return null;
    };
    const lsb = lower_constfold.shapeEval(self, d.lsb) orelse {
        try self.err(tok, .E0352, "the lsb of the range is not a constant expression", .{});
        return null;
    };
    // §4.2.1.1 rounds a real to no integer when it is a NaN, an infinity or
    // past i64; saturating one would make a NaN bound a silent zero.
    const r: VecRange = .{
        .msb = msb.asIntExact() orelse return refuseBound(self, tok, "msb", msb),
        .lsb = lsb.asIntExact() orelse return refuseBound(self, tok, "lsb", lsb),
    };
    const n = @abs(@as(i128, r.msb) - r.lsb) + 1;
    if (n > max_nodes) {
        try self.err(tok, .E1015, "the range [{d}:{d}] has {d} elements", .{ r.msb, r.lsb, n });
        return null;
    }
    return r;
}

// E0352 for a range bound that folded to a real with no integer value.
fn refuseBound(self: *Lower, tok: u32, which: []const u8, c: Lower.Const) Oom!?VecRange {
    try self.err(tok, .E0352, "the {s} of the range is {e}, which is no integer", .{ which, c.asReal() });
    return null;
}

/// Returns a port's range from whichever of its two declarations carries one. When
/// both do, "the range specification between the two declarations of a port shall
/// be identical" (LRM §6.5.2.2), compared after folding: `input [0:3] in;
/// electrical [0:4-1] in;` is valid, `input [3:0] in; electrical [0:3] in;` is not.
fn portRange(self: *Lower, p: *const Ast.Port) Oom!?VecRange {
    const dir_r = if (p.range) |d| try foldDim(self, d, p.main_tok) else null;
    const ty_r = if (p.type_range) |d| try foldDim(self, d, p.main_tok) else null;
    if (dir_r) |a| if (ty_r) |b| {
        if (a.msb != b.msb or a.lsb != b.lsb)
            try self.err(p.main_tok, .E0350, "`{s}` is [{d}:{d}] where it is given a direction and [{d}:{d}] where it is given a discipline", .{
                self.file.str(p.name), a.msb, a.lsb, b.msb, b.lsb,
            });
    };
    return dir_r orelse ty_r;
}

/// Whether branch terminal `e` is a part-select, `a[2:1]` or `a[b +: w]`.
fn partSelect(self: *const Lower, e: Ast.ExprId) bool {
    const ex = &self.file.exprs;
    if (e == .none or ex.tag(e) != .index) return false;
    return ex.tag(ex.rhs(e)) == .range or ex.tag(ex.rhs(e)) == .indexed_range;
}

/// A vector branch terminal: the vector `name` and the elements it covers.
const VecTerm = struct { name: []const u8, range: VecRange };

/// The vector a branch terminal names, or null when it is a scalar
/// (`branch (a[1], b)` is two scalars) or not a net reference at all. A.2.1.3's
/// `net_identifier [ constant_range_expression ]` selects part of one: `a[2:1]`,
/// or IEEE 1364-2005 §5.2.1's `a[b +: w]` / `a[b -: w]`, whose bounds fold and
/// lie within the declaration, the msb on the declared msb's side (E0352).
/// Null after such a diagnostic; `declareBranches` then skips the branch
/// (`partSelect`) rather than have `nodeOf` refuse the range again.
pub fn vecTerminal(self: *Lower, e: Ast.ExprId, tok: u32) Oom!?VecTerm {
    if (e == .none) return null;
    const ex = &self.file.exprs;
    if (ex.tag(e) == .ident) {
        const name = self.file.str(ex.strOf(e));
        return .{ .name = name, .range = self.out.vectors.get(name) orelse return null };
    }
    if (!partSelect(self, e)) return null;
    const sel = ex.rhs(e);
    if (ex.tag(ex.lhs(e)) != .ident) {
        // ponytail: a hierarchical terminal's part (`u.v[1:0]`) needs the
        // flat name's vector; refused by name until a fixture needs it.
        try self.err(tok, .E0351, "a part-select of a hierarchical branch terminal", .{});
        return null;
    }
    const name = self.file.str(ex.strOf(ex.lhs(e)));
    const decl = self.out.vectors.get(name) orelse {
        try self.err(tok, .E0351, "`{s}` was not declared with a range", .{name});
        return null;
    };
    // §4.2.1.1: a bound that rounds to no integer (NaN, an infinity, past
    // i64) is no bound, as one that does not fold is not.
    const a: ?i64 = if (lower_constfold.constEval(self, ex.lhs(sel))) |c| c.asIntExact() else null;
    const b: ?i64 = if (lower_constfold.constEval(self, ex.rhs(sel))) |c| c.asIntExact() else null;
    if (a == null or b == null) {
        try self.err(tok, .E0352, "the part-select of `{s}` has a bound that is not a constant integer", .{name});
        return null;
    }
    const r: VecRange = if (ex.tag(sel) == .range) .{ .msb = a.?, .lsb = b.? } else w: {
        const width = b.?;
        if (width < 1) {
            try self.err(tok, .E0352, "the indexed part-select of `{s}` is {d} wide", .{ name, width });
            return null;
        }
        break :w indexedRange(decl, a.?, width, ex.extraOf(sel) != 0);
    };
    if (!partOf(decl, r)) {
        try self.err(tok, .E0352, "`{s}` is [{d}:{d}], so [{d}:{d}] is not a part of it", .{ name, decl.msb, decl.lsb, r.msb, r.lsb });
        return null;
    }
    return .{ .name = name, .range = r };
}

/// §3.12 a vector branch. The LRM's own example:
///
///     electrical [3:5]a;
///     electrical [1:3]b;
///     branch (a,b) br1;  // Branch br1 is of size 3 and can be indexed 0 to 2
///
/// The terminals pair "in a parallel one-to-one fashion" in declaration order, a
/// scalar terminal repeats (Figure 3-2), and the branch is indexed `[0:size-1]`.
/// Elements are registered in `branches` under scalarised names; the base name
/// goes into `vectors` for the vector diagnostics.
pub fn declareVectorBranch(self: *Lower, b: *const Ast.BranchDecl, hv: ?VecTerm, lv: ?VecTerm) Oom!void {
    const name = self.file.str(b.name);
    if (hv) |h| if (lv) |l| {
        if (h.range.size() != l.range.size()) {
            try self.err(b.main_tok, .E0353, "`{s}` joins a size-{d} vector to a size-{d} one", .{ name, h.range.size(), l.range.size() });
            return;
        }
    };
    const size = if (hv) |h| h.range.size() else lv.?.range.size();
    // A scalar terminal is the same node on every element (Figure 3-2).
    const h_scalar = if (hv == null) try nodeOf(self, b.hi) else ground;
    const l_scalar = if (lv == null) try nodeOf(self, b.lo) else ground;
    for (0..size) |k| {
        const hi = if (hv) |h| try internNode(self, try self.arena.print("{s}[{d}]", .{ h.name, h.range.at(@intCast(k)) }), "") else h_scalar;
        const lo = if (lv) |l| try internNode(self, try self.arena.print("{s}[{d}]", .{ l.name, l.range.at(@intCast(k)) }), "") else l_scalar;
        // §3.12 → §3.11 once: every element pairs the same two disciplines.
        if (k == 0) try lower_discipline.checkNetCompat(self, b.main_tok, hi, lo);
        try self.branches.put(self.arena, try self.arena.print("{s}[{d}]", .{ name, @as(i64, @intCast(k)) }), .{
            .hi = hi,
            .lo = lo,
            .id = newBranchId(self),
        });
    }
    try self.out.vectors.put(self.arena, name, .{ .msb = 0, .lsb = @as(i64, size) - 1 });
}

/// Returns the name codegen prints for a `nodes` row, or "gnd" for `ground`.
pub fn nodeName(self: *const Lower, idx: u32) []const u8 {
    return self.out.nodeName(idx);
}

/// Returns a fresh §5.4.1 branch identity, one per declared branch name (array
/// elements included). Ids are per-module, never reused, and private to lowering.
fn newBranchId(self: *Lower) u32 {
    self.node_state.last_branch_id += 1;
    return self.node_state.last_branch_id;
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

test "lower: §5.5.2 an access function takes a scalar or one element of a vector" {
    const decls = "  electrical [1:0] b;\n  real y;\n  integer j;";
    const cases = [_]struct { body: []const u8, want: ?@import("diag").Code }{
        .{ .body = "    y = V(b[1]) - V(b[0]);", .want = null },
        // A bare vector names several nets (E0351).
        .{ .body = "    y = V(b);", .want = .E0351 },
        .{ .body = "    y = V(b[2]);", .want = .E0352 },
        // "The index must be a constant expression".
        .{ .body = "    j = 0;\n    y = V(b[j]);", .want = .E0352 },
        // §4.2.1.1 gives NaN no integer, so it names no element.
        .{ .body = "    y = V(b[0.0/0.0]);", .want = .E0352 },
    };
    for (cases) |c| try Lower.expectBodyVerdict(decls, c.body, c.want);
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
