//! The module-wide source sweeps, run once the analog blocks are lowered:
//! the contributions and access-function reads in, a diagnostic out for a
//! probe branch whose two quantities are both read (§1.3.1, E0423) and for a
//! loop of potential sources across module instances (§5.6.8.1, E0477).
//!
//! Cites: §1.3.1, §1.3.1.2, §5.4.2.1, §5.4.2.2, §5.6.1, §5.6.5, §5.6.7,
//! §5.6.7.2, §5.6.8.1, §5.6.8.2.
//!
//! Contents:
//! - `pub fn checkProbeBranches(self: *Lower) Oom!void`
//! - `pub fn pairKey(hi: u32, lo: u32) u64`
//! - `pub const HierPotential = struct`
//! - `pub fn checkHierParallel(self: *Lower, lhs: Ast.ExprId, target: Target) Oom!bool`
//! - `pub fn checkSourceLoops(self: *Lower) Oom!void`
//! - `pub fn samePair(a_hi: u32, a_lo: u32, b_hi: u32, b_lo: u32) bool`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Lower = @import("Lower.zig");
const lower_branch = @import("branch.zig");
const lower_node = @import("node.zig");
const Target = lower_branch.Target;
const Oom = Lower.Oom;
const unnamed_branch = Lower.unnamed_branch;
const ground = Lower.ground;

/// §5.6.8.1 one potential `<+` written through hierarchical net references.
pub const HierPotential = struct { hi: u32, lo: u32, unit: u32, tok: u32 };

/// §1.3.1: "The potential and flow of a probe branch may not both appear in
/// expressions in a given module." §5.4.2.1 states it as the ban — "using both
/// the potential and the flow of a probe branch is illegal" — and gives the
/// reason: it pins ONE of a probe's quantities at zero, the potential of a flow
/// probe or the flow of a potential probe, and which one is decided by which
/// the module reads. Reading both asks for two zeros at once.
///
/// Runs as a sweep after the module is lowered, because a branch is a probe only
/// if nothing is ever contributed to it (§1.3.1). A source branch is exempt:
/// §5.4.2.2 makes both of its quantities accessible.
pub fn checkProbeBranches(self: *Lower) Oom!void {
    assert(self.module != null); // a sweep over the whole module's reads
    assert(self.accum.items.len == self.out.contributions.items.len);
    // The first read of each quantity per unordered node pair: linear in the
    // reads (a generate loop of 10^5 blocks reads 10^5 times). The report is
    // the earliest read `a` with a later read `b` of the other quantity, at the
    // first such `b`: per pair that is the first reads of the two quantities.
    const reads = self.branch_reads.items;
    var first: std.AutoHashMapUnmanaged(u64, [2]u32) = .empty;
    defer first.deinit(self.arena);
    const none = std.math.maxInt(u32);
    for (reads, 0..) |r, i| {
        const g = try first.getOrPut(self.arena, pairKey(r.hi, r.lo));
        if (!g.found_existing) g.value_ptr.* = .{ none, none };
        const slot = &g.value_ptr[@backingInt(r.access)];
        if (slot.* == none) slot.* = @intCast(i);
    }
    // The pairs anything is contributed to, directly (§5.6.1) or indirectly
    // (§5.6.7): §1.3.1's "not a probe". Built at the first pair read both ways.
    var contributed: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer contributed.deinit(self.arena);
    for (reads, 0..) |a, i| {
        const f = first.get(pairKey(a.hi, a.lo)).?;
        if (f[0] == none or f[1] == none or @min(f[0], f[1]) != i) continue;
        if (contributed.count() == 0) for (self.out.contributions.items) |c| {
            try contributed.put(self.arena, pairKey(c.hi, c.lo), {});
        };
        if (contributed.contains(pairKey(a.hi, a.lo))) continue;
        var d = self.errWith(reads[@max(f[0], f[1])].tok, .E0423);
        d.msg("both quantities of the probe branch (`{s}`, `{s}`) are read", .{
            lower_node.nodeName(self, a.hi), lower_node.nodeName(self, a.lo),
        });
        d.note("nothing is contributed to that branch, so §1.3.1 makes it a probe; contribute to it to make it a source, or read only one quantity", .{});
        try d.emit();
        return; // one report per module: the second pair is the same defect
    }
}

/// `samePair`'s unordered pair as one map key.
pub fn pairKey(hi: u32, lo: u32) u64 {
    assert(hi != lo or hi == ground); // `branchOf` refuses `V(n, n)` (E0315)
    const key = @as(u64, @min(hi, lo)) << 32 | @max(hi, lo);
    assert(key >> 32 <= key & 0xffff_ffff); // the low word is the larger row
    return key;
}

/// §5.6.8.1 "In these cases, a new unnamed branch is created in the module
/// containing the direct contribution statements. ... The simulator shall
/// check if the contribution produces a solvable set of equations, e.g. no
/// voltage source loops created."
///
/// A potential `<+` to `V(drv.x)` is therefore a second unnamed branch beside
/// any potential source `drv` has on the same pair: two potential sources in
/// parallel. `contribIndex` keys an unnamed branch on its node pair alone and
/// would sum them, so the loop is found here, before that merge, in either
/// lowering order. Conditional statements count too. Returns true when it
/// reported.
pub fn checkHierParallel(self: *Lower, lhs: Ast.ExprId, target: Target) Oom!bool {
    assert(lhs == .none or self.exprValid(lhs));
    assert(self.nodeValid(target.hi));
    assert(self.nodeValid(target.lo));
    if (target.access != .potential or target.br != unnamed_branch) return false;
    const hier = hierNetForm(self, lhs);
    const clash: ?u32 = blk: {
        for (self.hier_potentials.items) |h| {
            if (h.unit != self.cur_unit and samePair(h.hi, h.lo, target.hi, target.lo)) break :blk h.tok;
        }
        if (hier) for (self.out.contributions.items) |c| {
            if (c.kind != .direct or c.access != .potential or c.br != unnamed_branch) continue;
            if (c.unit != self.cur_unit and samePair(c.hi, c.lo, target.hi, target.lo)) break :blk c.tok;
        };
        break :blk null;
    };
    if (hier) try self.hier_potentials.append(self.arena, .{ .hi = target.hi, .lo = target.lo, .unit = self.cur_unit, .tok = self.file.exprs.mainTok(lhs) });
    const other = clash orelse return false;
    var d = self.errWith(self.file.exprs.mainTok(lhs), .E0477);
    d.msg("`V({s},{s})` closes a loop of potential sources with a contribution from another module instance", .{
        lower_node.nodeName(self, target.hi), lower_node.nodeName(self, target.lo),
    });
    d.label(self.tokenSpan(other), "the other potential source on the same two nets", .{});
    d.note("a hierarchical net reference creates a new branch in the writing module (5.6.8.1), in parallel with this one", .{});
    try d.emit();
    return true;
}

/// §5.6.8.1 "The simulator shall check if the contribution produces a solvable
/// set of equations, e.g. no voltage source loops created." §5.6.8.2 repeats the
/// sentence for hierarchical contributions to a child's branches.
///
/// A loop of POTENTIAL sources fixes the sum of its branch potentials twice
/// (KVL) and leaves the branch flows around it undetermined, whatever the
/// values: the system is singular. The sweep is a union-find over the node
/// rows, one edge per potential-source row that is a source on EVERY path —
/// an unconditional direct row (`wrote_val` is the constant 1.0; a switch arm
/// is not always a potential source, §5.6.5) or an indirect row (always
/// unconditional, §5.6.7). An edge whose two ends are already joined closes a
/// loop.
///
/// Reported only when the loop's rows come from more than one module instance
/// (`Contribution.unit`), the case these clauses create and no single module's
/// author can see. A loop inside one module is not reported.
pub fn checkSourceLoops(self: *Lower) Oom!void {
    assert(self.accum.items.len == self.out.contributions.items.len);
    assert(self.module != null);
    const Edge = struct { a: u32, b: u32, unit: u32 };
    const n_nodes: u32 = @intCast(self.out.nodes.len + 1); // the last row is ground
    const Ix = struct {
        n: u32,
        fn of(ix: @This(), node: u32) u32 {
            return if (node == ground) ix.n - 1 else node;
        }
    };
    const ix: Ix = .{ .n = n_nodes };
    const root = try self.arena.alloc(u32, n_nodes);
    for (root, 0..) |*r, i| r.* = @intCast(i);
    var edges: std.ArrayList(Edge) = .empty;
    for (self.out.contributions.items) |c| {
        if (c.access != .potential) continue;
        switch (c.kind) {
            .direct => if (c.wrote_val != .f_one) continue,
            .indirect => {},
        }
        const a = ix.of(c.hi);
        const b = ix.of(c.lo);
        const ra = find(root, a);
        const rb = find(root, b);
        if (ra != rb) {
            root[ra] = rb;
            try edges.append(self.arena, .{ .a = a, .b = b, .unit = c.unit });
            continue;
        }
        // Closed. The loop is this row plus the forest path from a to b; walk
        // that path (breadth-first over the accepted edges) and ask whether any
        // row on it belongs to another instance.
        // ponytail: O(nodes·edges) per closed loop; an adjacency list if a
        // design closes many single-instance loops.
        const via = try self.arena.alloc(u32, n_nodes); // edge index that reached the node
        @memset(via, std.math.maxInt(u32));
        var queue: std.ArrayList(u32) = .empty;
        try queue.append(self.arena, a);
        var head: usize = 0;
        via[a] = @intCast(edges.items.len); // sentinel: the start
        while (head < queue.items.len and via[b] == std.math.maxInt(u32)) : (head += 1) {
            const at = queue.items[head];
            for (edges.items, 0..) |e, k| {
                const next = if (e.a == at) e.b else if (e.b == at) e.a else continue;
                if (via[next] != std.math.maxInt(u32)) continue;
                via[next] = @intCast(k);
                try queue.append(self.arena, next);
            }
        }
        // `ra == rb`: every union above appended its edge, so the forest joins them.
        assert(via[b] != std.math.maxInt(u32));
        var other: ?u32 = null;
        var at = b;
        while (at != a and via[at] < edges.items.len) {
            const e = edges.items[via[at]];
            if (e.unit != c.unit) other = e.unit;
            at = if (e.a == at) e.b else e.a;
        }
        const theirs = other orelse continue;
        const their_path = if (theirs < self.design.units.len) self.design.units.items(.path)[theirs] else "";
        var d = self.errWith(c.tok, .E0477);
        d.msg("`V({s},{s})` closes a loop of potential sources with a contribution from `{s}`", .{
            lower_node.nodeName(self, c.hi),
            lower_node.nodeName(self, c.lo),
            if (their_path.len != 0)
                their_path[0 .. their_path.len - 1] // drop the trailing separator
            else
                "the top-level module",
        });
        d.note("a loop of potential sources fixes its potentials twice and leaves its flows undetermined", .{});
        try d.emit();
        return; // one report: every further loop through this component is the same defect
    }
}

/// §5.6.7.2 "the same pair of analog nets (or any of its parallel branches)" —
/// unordered, since (a,b) and (b,a) are the same pair with opposite reference
/// directions (§1.3.1.2).
pub fn samePair(a_hi: u32, a_lo: u32, b_hi: u32, b_lo: u32) bool {
    const same = (a_hi == b_hi and a_lo == b_lo) or (a_hi == b_lo and a_lo == b_hi);
    if (same) assert(pairKey(a_hi, a_lo) == pairKey(b_hi, b_lo)); // the two spellings of one pair key alike
    return same;
}

// ---- private ----

/// Does the left-hand side reach another instance's nets by §5.6.8.1's spelling
/// — a hierarchical NET reference — rather than §5.6.8.2's `inst.branch(...)`?
fn hierNetForm(self: *const Lower, lhs: Ast.ExprId) bool {
    assert(lhs == .none or self.exprValid(lhs));
    assert(self.file.exprs.tag(lhs) == .branch_access);
    const ex = &self.file.exprs;
    if (ex.extraOf(lhs) == Ast.branch_ref_hier_unnamed) return false;
    for ([_]Ast.ExprId{ ex.lhs(lhs), ex.rhs(lhs) }) |t| {
        if (t != .none and ex.tag(t) == .hier_ident) return true;
    }
    return false;
}

fn find(root: []u32, x: u32) u32 {
    assert(x < root.len);
    var r = x;
    while (root[r] != r) r = root[r];
    var y = x;
    while (root[y] != r) {
        const next = root[y];
        root[y] = r;
        y = next;
    }
    assert(root[x] == r); // compressed: `x` points straight at its root
    return r;
}

test find {
    // 3 -> 2 -> 1 -> 0, a chain no union ever balanced.
    var root = [_]u32{ 0, 0, 1, 2 };
    try std.testing.expectEqual(@as(u32, 0), find(&root, 3));
    // Path compression: every node the walk passed now points at the root.
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 0, 0 }, &root);
    // A root is its own answer and moves nothing.
    try std.testing.expectEqual(@as(u32, 0), find(&root, 0));
}

test samePair {
    // §5.6.7.2/§1.3.1.2: (a,b) and (b,a) are one pair of nets.
    try std.testing.expect(samePair(1, 2, 2, 1));
    try std.testing.expect(samePair(1, 2, 1, 2));
    try std.testing.expect(!samePair(1, 2, 1, 3));
    try std.testing.expect(samePair(4, ground, ground, 4));
}
