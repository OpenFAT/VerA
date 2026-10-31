const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Lower = @import("Lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_discipline = @import("discipline.zig");
const lower_shape = @import("shape.zig");
const lower_expr_name = @import("expr_name.zig");
const lower_node = @import("node.zig");
const lower_node_discipline = @import("node_discipline.zig");
const Oom = Lower.Oom;
const ground = Lower.ground;
const VecRange = Lower.VecRange;

/// §3.12 the module's named branches: a node pair with a fresh `BranchInfo.id`
/// each (an A.2.3 branch array is one pair and several ids), a §3.12.1 port
/// branch as the port it names, and a branch with a vector terminal as a
/// vector branch. Runs after `declareNets`, so every terminal has its row.
pub fn declareBranches(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    assert(module.name != .none);
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
    assert(e == .none or self.exprValid(e));
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
                try lower_node_discipline.rejectImplicitNet(self, name, self.file.exprs.mainTok(e));
            return lower_node.internNode(self, name, "");
        },
        // §6.7.1 a hierarchical terminal, `V(u.a)`: elaboration named the child's
        // net `u.a`, so `flatName` resolves it. It never interns a new node:
        // §3.6.5's implicit net applies only to an undeclared simple name.
        .hier_ident => {
            if (try lower_expr_name.refuseUnnamedGen(self, e)) return ground;
            const name = try lower_expr_name.flatName(self, e);
            if (!self.node_voltages.contains(name)) {
                try self.err(self.file.exprs.mainTok(e), .E0901, "`{s}` names no net in the elaborated design", .{name});
                return ground;
            }
            return lower_node.internNode(self, name, "");
        },
        .index => {
            const base = ex.lhs(e);
            // `u.v[1]`: §6.7.1's hierarchical terminal, one element of it.
            const name = switch (ex.tag(base)) {
                .ident => self.file.str(ex.strOf(base)),
                .hier_ident => if (try lower_expr_name.refuseUnnamedGen(self, base)) return ground else try lower_expr_name.flatName(self, base),
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
pub fn netKey(self: *Lower, name: []const u8, tok: u32) Oom![]const u8 {
    assert(tok < self.tok_starts.len or self.tok_starts.len == 0 or tok == std.math.maxInt(u32));
    if (name.len == 0 or name[name.len - 1] != ']') return name;
    if (tok >= self.tok_starts.len) return name;
    const at = self.tok_starts[tok];
    if (at >= self.src.len or self.src[at] != '\\') return name;
    return self.arena.print("\\{s}", .{name});
}

/// `internNode` for a vector element, spelled as the source does (`bus[3]`).
/// Looks up on a stack buffer and allocates only for a new element.
pub fn internNodeElem(self: *Lower, base: []const u8, i: i64) Oom!u32 {
    var buf: [lower_shape.elem_key_len]u8 = undefined;
    const key = try lower_shape.elemKey(self, &buf, base, &.{i});
    const name = self.node_voltages.getKey(key) orelse try self.arena.print("{s}[{d}]", .{ base, i });
    return lower_node.internNode(self, name, "");
}

/// Folds a declared `[msb:lsb]` (§3.6.3 Syntax 3-6); the bounds are constant
/// expressions (`electrical [0:4-1] in;`, §6.5.2.2). Returns null after a diagnostic.
pub fn foldDim(self: *Lower, d: Ast.Dim, tok: u32) Oom!?VecRange {
    assert(tok < self.tok_starts.len or self.tok_starts.len == 0 or tok == std.math.maxInt(u32));
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
    if (n > lower_node.max_nodes) {
        try self.err(tok, .E1015, "the range [{d}:{d}] has {d} elements", .{ r.msb, r.lsb, n });
        return null;
    }
    return r;
}

// E0352 for a range bound that folded to a real with no integer value.
fn refuseBound(self: *Lower, tok: u32, which: []const u8, c: Lower.Const) Oom!?VecRange {
    assert(tok < self.tok_starts.len or self.tok_starts.len == 0 or tok == std.math.maxInt(u32));
    try self.err(tok, .E0352, "the {s} of the range is {e}, which is no integer", .{ which, c.asReal() });
    return null;
}

/// Returns a port's range from whichever of its two declarations carries one. When
/// both do, "the range specification between the two declarations of a port shall
/// be identical" (LRM §6.5.2.2), compared after folding: `input [0:3] in;
/// electrical [0:4-1] in;` is valid, `input [3:0] in; electrical [0:3] in;` is not.
pub fn portRange(self: *Lower, p: *const Ast.Port) Oom!?VecRange {
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
    assert(e == .none or self.exprValid(e));
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
    assert(e == .none or self.exprValid(e));
    assert(tok < self.tok_starts.len or self.tok_starts.len == 0 or tok == std.math.maxInt(u32));
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
        break :w lower_node.indexedRange(decl, a.?, width, ex.extraOf(sel) != 0);
    };
    if (!lower_node.partOf(decl, r)) {
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
        const hi = if (hv) |h| try lower_node.internNode(self, try self.arena.print("{s}[{d}]", .{ h.name, h.range.at(@intCast(k)) }), "") else h_scalar;
        const lo = if (lv) |l| try lower_node.internNode(self, try self.arena.print("{s}[{d}]", .{ l.name, l.range.at(@intCast(k)) }), "") else l_scalar;
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

/// Returns a fresh §5.4.1 branch identity, one per declared branch name (array
/// elements included). Ids are per-module, never reused, and private to lowering.
fn newBranchId(self: *Lower) u32 {
    self.node_state.last_branch_id += 1;
    return self.node_state.last_branch_id;
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
