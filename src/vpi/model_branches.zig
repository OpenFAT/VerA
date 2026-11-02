//! The analog classes of the analog model: the source's natures and
//! disciplines (§11.6.2), each continuous net's node (§11.6.5), every
//! declared and unnamed branch (§11.6.6, §5.4.2) with its two quantities
//! (§11.6.7), and the contribution rows behind each branch's values, appended
//! to the builder's `Rows`.
//! Cites: VAMS-2023 §1.3.1, §3.6, §5.4.1, §5.4.2, §5.6.8.2, §11.6.2,
//! §11.6.5-§11.6.7.
//!
//! Contents:
//! - `pub fn addAnalog( gpa: std.mem.Allocator, arena: std.mem.Allocator, objects: *Rows, scopes: []Building, by_path: *const std.StringHashMapUnmanaged(u32), res: *const Result, top_name: []const u8, ) Error!struct`

const std = @import("std");
const Ast = @import("frontend").Ast;
const Result = @import("vera").Result;
const elab = @import("elab");
const Lowered = @import("ir").Lowered;
const model = @import("model.zig");
const model_analog = @import("model_analog.zig");
const schema = @import("schema.zig");
const ObjId = schema.ObjId;
const session = @import("session.zig");
const Building = model.Building;
const Cold = schema.Cold;
const Error = session.Error;
const Rows = model.Rows;

const UnnamedKey = struct { scope: u32, hi: u32, lo: u32 };

/// §11.6.2's natures and disciplines, §11.6.5's nodes, §11.6.6's branches and
/// §11.6.7's quantities — the analog classes, read from the elaborated
/// declarations exactly as nets are: the DECLARATIONS are the source's
/// (`file.natures`, `file.disciplines`), the node of each net and the
/// terminals of each branch are the flattened module's.
///
/// Natures are appended first, then disciplines, so a discipline's nature
/// edges and a nature's `users` are indices known when they are written.
/// Asserts that every scope's module row is made, and that the sets
/// returned are natures and disciplines.
pub fn addAnalog(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    objects: *Rows,
    scopes: []Building,
    by_path: *const std.StringHashMapUnmanaged(u32),
    res: *const Result,
    top_name: []const u8,
) Error!struct { disciplines: []const ObjId, natures: []const ObjId } {
    std.debug.assert(scopes.len <= objects.hot.items.len);
    const lowered = res.lowered;
    const file = res.file;
    const flat = res.module.?;

    // --- natures: one object each, then the vpiParent edge and its inverse.
    const natures = try arena.alloc(ObjId, file.natures.len);
    var nature_at: std.StringHashMapUnmanaged(ObjId) = .empty;
    defer nature_at.deinit(gpa);
    for (file.natures, natures) |n, *at| {
        const name = try arena.dupe(u8, file.str(n.name));
        at.* = objects.next();
        try objects.append(.{ .kind = .nature, .owner = .none, .name = name, .full = name });
        try nature_at.put(gpa, name, at.*);
    }
    // --- disciplines, each with the natures it binds.
    const disciplines = try arena.alloc(ObjId, file.disciplines.len);
    var disc_at: std.StringHashMapUnmanaged(ObjId) = .empty;
    defer disc_at.deinit(gpa);
    for (file.disciplines, disciplines) |dd, *at| {
        const name = try arena.dupe(u8, file.str(dd.name));
        at.* = objects.next();
        try objects.appendCold(.{ .kind = .discipline, .owner = .none, .name = name, .full = name }, .{
            .flow = if (dd.flow == .none) .none else nature_at.get(file.str(dd.flow)) orelse .none,
            .pot = if (dd.potential == .none) .none else nature_at.get(file.str(dd.potential)) orelse .none,
        });
        try disc_at.put(gpa, name, at.*);
    }
    // §3.6.1.1 a derived nature's parent: a nature by name, or — A.1.6's
    // `discipline_identifier . potential_or_flow` — the nature that discipline
    // binds on that side.
    for (file.natures, natures) |n, at| {
        if (n.parent == .none) continue;
        const pname = file.str(n.parent);
        const parent: ObjId = if (n.parent_access) |side| blk: {
            const di = disc_at.get(pname) orelse break :blk .none;
            break :blk switch (side) {
                .potential => objects.coldOf(di).pot,
                .flow => objects.coldOf(di).flow,
            };
        } else nature_at.get(pname) orelse .none;
        (try objects.coldFor(at)).nature = parent;
    }
    // The inverse edges, nature ->> nature (vpiChild) and nature ->> discipline.
    for (natures) |at| {
        var n_kids: usize = 0;
        for (natures) |other| n_kids += @intFromBool(objects.coldOf(other).nature == at);
        var kids: std.ArrayList(ObjId) = try .initCapacity(arena, n_kids);
        for (natures) |other| if (objects.coldOf(other).nature == at) kids.appendAssumeCapacity(other);
        var n_users: usize = 0;
        for (disciplines) |di| n_users += @intFromBool(binds(objects.coldOf(di), at));
        var users: std.ArrayList(ObjId) = try .initCapacity(arena, n_users);
        for (disciplines) |di| if (binds(objects.coldOf(di), at)) users.appendAssumeCapacity(di);
        const c = try objects.coldFor(at);
        c.children = kids.items;
        c.users = users.items;
    }

    // --- nodes: one per net of a continuous discipline (§3.6.2.2: a
    // discipline binding natures and not declared `domain discrete`).
    var net_at: std.StringHashMapUnmanaged(ObjId) = .empty;
    defer net_at.deinit(gpa);
    // A top-level port is its own net here (its declaration is the port's,
    // not a separate §11.6.8 object), so it is keyed too — nets after ports,
    // so a name that is both resolves to the net.
    for (objects.hot.items, 0..) |o, i| if (o.kind == .port and o.owner == ObjId.at(0)) try net_at.put(gpa, o.full, .at(i));
    for (objects.hot.items, 0..) |o, i| if (o.kind == .net) try net_at.put(gpa, o.full, .at(i));
    const Decl = struct { name: Ast.StrId, discipline: Ast.StrId };
    var decls: std.ArrayList(Decl) = try .initCapacity(gpa, flat.ports.len + flat.nets.len);
    defer decls.deinit(gpa);
    for (flat.ports) |p| decls.appendAssumeCapacity(.{ .name = p.name, .discipline = p.discipline });
    for (flat.nets) |n| decls.appendAssumeCapacity(.{ .name = n.name, .discipline = n.discipline });
    for (decls.items) |n| {
        if (n.discipline == .none) continue;
        const di = disc_at.get(file.str(n.discipline)) orelse continue;
        if (file.disciplines[di.index() - disciplines[0].index()].domain == .discrete) continue;
        const full = try model.joinPath(arena, top_name, file.str(n.name));
        const net = net_at.get(full) orelse continue;
        // A port declared and then typed by a net declaration is one node.
        if (objects.coldOf(net).node != .none) continue;
        const at = objects.next();
        const src = objects.at(net).*;
        try objects.appendCold(.{
            .kind = .node,
            .owner = src.owner,
            .name = src.name,
            .full = src.full,
            .size = src.size,
        }, .{
            .disc = di,
            // node <->> nets: the §11.6.8 net, when the name has one. A
            // top-level port's node reaches its port instead (§11.6.4's
            // port -> nodes edge), and has no net object to list.
            .nets = if (src.kind == .net) try arena.dupe(ObjId, &.{net}) else &.{},
        });
        const net_cold = try objects.coldFor(net);
        net_cold.node = at;
        net_cold.disc = di;
        try scopes[src.owner.index()].nodes.append(gpa, at);
    }
    // Each node's solver row: the `Lowered.nodes` row spelled by the node's
    // flattened name (`nodes` rows are named as `nets` are, §6.7 paths).
    for (lowered.nodes.items(.name), lowered.nodes.items(.kind), 0..) |name, kind, row| {
        if (kind != .net) continue;
        const denoted = lowered.hier_names.get(name) orelse name;
        const net = net_at.get(try model.joinPath(arena, top_name, denoted)) orelse continue;
        const node = objects.coldOf(net).node;
        if (node == .none) continue;
        if (objects.coldOf(node).row == null) (try objects.coldFor(node)).row = @intCast(row);
    }
    // The node object each solver row is the row of, the earliest when two
    // share one: what an unnamed branch's terminals resolve to. Every node
    // exists by now; branches add none.
    const node_of_row = try gpa.alloc(ObjId, lowered.nodes.len);
    defer gpa.free(node_of_row);
    @memset(node_of_row, .none);
    for (objects.hot.items, 0..) |o, i| if (o.kind == .node) if (objects.coldOf(.at(i)).row) |row| {
        if (row < node_of_row.len and node_of_row[row] == .none) node_of_row[row] = .at(i);
    };

    // --- branches, each with its two quantities. `named` keeps them in
    // object order: the rows a named contribution below is matched against.
    // At most one per declared branch.
    var named: std.ArrayList(ObjId) = try .initCapacity(gpa, flat.branches.len);
    defer named.deinit(gpa);
    for (flat.branches) |b| {
        const flat_name = file.str(b.name);
        const split = (try model_analog.splitPath(arena, by_path, flat_name)) orelse continue;
        const pos = try terminalNode(objects, &net_at, arena, res, top_name, b.hi);
        const neg = if (b.lo == .none) ObjId.none else try terminalNode(objects, &net_at, arena, res, top_name, b.lo);
        const full = try model.joinPath(arena, top_name, flat_name);
        const at = try addBranch(objects, split.scope, split.local, full, .{
            .disc = if (pos != .none) objects.coldOf(pos).disc else .none,
            .pos = pos,
            .neg = neg,
            .hi_row = if (pos != .none) objects.coldOf(pos).row orelse Lowered.ground else Lowered.ground,
            .lo_row = if (neg != .none) objects.coldOf(neg).row orelse Lowered.ground else Lowered.ground,
        });
        if (full.len != 0) named.appendAssumeCapacity(at);
        try scopes[split.scope].branches.append(gpa, at);
    }

    // --- the rows behind each branch's values, and the UNNAMED branches.
    //
    // §5.4.2: "an unnamed branch ... between two nets" exists wherever an
    // access function names the pair, so a `<+` in an instance declares one —
    // and §11.6.6 draws it like any other: `vpi_iterate(vpiBranch, module)`
    // reaches it and `vpiFlow`/`vpiPotential` reach its quantities. The
    // flattened design keeps §5.4.1's ONE unnamed branch per pair, so the
    // INSTANCE a row belongs to is `Contribution.unit`, the one lowering
    // recorded as it lowered that instance's analog block. A potential and a
    // flow row of one instance over one pair are one branch.
    const rows = lowered.contributions.items;
    var unnamed: std.AutoHashMapUnmanaged(UnnamedKey, ObjId) = .empty;
    defer unnamed.deinit(gpa);
    for (rows, 0..) |c, k| {
        const idx: u32 = @intCast(k);
        if (c.br != Lowered.unnamed_branch) {
            // A named branch: the one of this pair its instance declares. Two
            // named branches over one pair are told apart by an id lowering
            // keeps to itself, so this model does not guess between them.
            var found: ObjId = .none;
            var twice = false;
            for (named.items) |i| {
                if (!branchSpans(objects, objects.coldOf(i), c.hi, c.lo)) continue;
                if (found != .none) twice = true;
                found = i;
            }
            const b = found;
            if (b == .none) continue;
            try bindRow(objects, b, c, idx, null);
            const bc = try objects.coldFor(b);
            bc.flow_unknowable = bc.flow_unknowable or twice;
            continue;
        }
        try unnamedBranch(gpa, objects, scopes, &unnamed, by_path, res, node_of_row, c, idx, c.unit);
        for (lowered.contrib_sharers.items) |sh| {
            if (sh.row == idx) try unnamedBranch(gpa, objects, scopes, &unnamed, by_path, res, node_of_row, c, idx, sh.unit);
        }
    }
    std.debug.assert(natures.len == 0 or objects.at(natures[0]).kind == .nature);
    std.debug.assert(disciplines.len == 0 or objects.at(disciplines[0]).kind == .discipline);
    return .{ .disciplines = disciplines, .natures = natures };
}

// ---- private ----

/// A branch row of `scope` with cold fields `c`, then its flow and potential
/// quantities (`c.flow`, `c.pot` are set to them), each of the nature its
/// discipline binds on that side (§11.6.7). Returns the branch row;
/// invalidates pointers into `objects`.
fn addBranch(objects: *Rows, scope: u32, name: []const u8, full: []const u8, c: Cold) Error!ObjId {
    std.debug.assert(c.flow == .none);
    std.debug.assert(c.pot == .none);
    const at = objects.next();
    var bc = c;
    bc.flow = .at(at.index() + 1);
    bc.pot = .at(at.index() + 2);
    try objects.appendCold(.{ .kind = .branch, .owner = .of(scope), .name = name, .full = full }, bc);
    const d: ?Cold = if (c.disc != .none) objects.coldOf(c.disc).* else null;
    try objects.appendCold(.{ .kind = .quantity, .owner = .of(scope), .name = "", .full = "" }, .{ .branch = at, .nature = if (d) |o| o.flow else .none });
    try objects.appendCold(.{ .kind = .quantity, .owner = .of(scope), .name = "", .full = "" }, .{ .branch = at, .nature = if (d) |o| o.pot else .none });
    std.debug.assert(objects.next().index() == at.index() + 3);
    return at;
}

/// Does discipline `d` bind nature `at` on either side? Asserts that `at`
/// is a row and `d` is a discipline's (no net's discipline edge).
fn binds(d: *const Cold, at: ObjId) bool {
    std.debug.assert(at != .none);
    std.debug.assert(d.disc == .none);
    return d.flow == at or d.pot == at;
}

/// The §5.4.2 unnamed branch instance `unit` declares over row `idx`'s pair,
/// made on first sight and bound to the row. Asserts that the instance's
/// scope is one of `scopes` and its branch row is a branch.
fn unnamedBranch(
    gpa: std.mem.Allocator,
    objects: *Rows,
    scopes: []Building,
    unnamed: *std.AutoHashMapUnmanaged(UnnamedKey, ObjId),
    by_path: *const std.StringHashMapUnmanaged(u32),
    res: *const Result,
    node_of_row: []const ObjId,
    c: Lowered.Contribution,
    idx: u32,
    unit: u32,
) Error!void {
    const lowered = res.lowered;
    const scope: u32 = if (unit < res.unit_paths.len)
        by_path.get(std.mem.trimEnd(u8, res.unit_paths.items(.path)[unit], &.{elab.sep})) orelse 0
    else
        0;
    std.debug.assert(scope < scopes.len);
    const g = try unnamed.getOrPut(gpa, .{ .scope = scope, .hi = c.hi, .lo = c.lo });
    if (!g.found_existing) {
        const pos = nodeOfRow(node_of_row, c.hi);
        const neg = nodeOfRow(node_of_row, c.lo);
        // §5.4.2 gives an unnamed branch no name; `vpiName` answers the empty
        // string, as §11.6.7's unnamed quantity does.
        const at = try addBranch(objects, scope, "", "", .{
            .disc = if (pos != .none) objects.coldOf(pos).disc else if (neg != .none) objects.coldOf(neg).disc else .none,
            .pos = pos,
            .neg = neg,
            .hi_row = c.hi,
            .lo_row = c.lo,
        });
        try scopes[scope].branches.append(gpa, at);
        g.value_ptr.* = at;
    }
    // §5.4.1 the instance's own share of a row others share too.
    const share: ?u32 = for (lowered.contrib_shares.items, 0..) |sh, s| {
        if (sh.row == idx and sh.unit == unit) break @intCast(s);
    } else null;
    std.debug.assert(objects.at(g.value_ptr.*).kind == .branch);
    try bindRow(objects, g.value_ptr.*, c, idx, share);
}

/// Record contribution row `k` as the source of branch `at`'s potential or
/// flow; `share`, its `Lowered.contrib_shares` entry when `k` is shared.
/// Asserts that `at` is a branch and the row is then recorded on it.
fn bindRow(objects: *Rows, at: ObjId, c: Lowered.Contribution, k: u32, share: ?u32) Error!void {
    std.debug.assert(objects.at(at).kind == .branch);
    const unnamed = objects.at(at).full.len == 0;
    const b = try objects.coldFor(at);
    if (unnamed) {
        b.hi_row = c.hi;
        b.lo_row = c.lo;
    } else b.flow_neg = b.hi_row != c.hi;
    switch (c.access) {
        .potential => b.contrib_pot = k,
        .flow => {
            b.contrib_flow = k;
            b.contrib_share = share;
            // A named branch's row is that branch's alone, however many
            // instances contribute to it (§5.6.8.2); an unnamed one's is
            // every instance's over the pair, so it needs the share.
            if (unnamed and c.shared and share == null) b.flow_unknowable = true;
        },
    }
    std.debug.assert(b.contrib_pot == k or b.contrib_flow == k);
}

/// The node object whose solver row is `row` (`node_of_row`, built in
/// `addAnalog`); null for ground (§1.3.1.1 has no node row for it) and for a
/// row no node object carries. Asserts that ground is no row of the table.
fn nodeOfRow(node_of_row: []const ObjId, row: u32) ObjId {
    std.debug.assert(node_of_row.len < Lowered.ground);
    if (row == Lowered.ground or row >= node_of_row.len) return .none;
    std.debug.assert(row < node_of_row.len);
    return node_of_row[row];
}

/// Does named branch `o` join rows `hi` and `lo`, in either order? §5.4.2's
/// reference direction is the declaration's, and contributions are
/// canonicalised to one spelling of the pair, so both orders are the branch.
///
/// Asserts that `o` is a branch's cold row: neither a quantity's branch
/// edge nor its nature.
fn branchSpans(objects: *const Rows, o: *const Cold, hi: u32, lo: u32) bool {
    std.debug.assert(o.branch == .none);
    std.debug.assert(o.nature == .none);
    const p: u32 = if (o.pos != .none) objects.coldOf(o.pos).row orelse return false else Lowered.ground;
    const n: u32 = if (o.neg != .none) objects.coldOf(o.neg).row orelse return false else Lowered.ground;
    return (p == hi and n == lo) or (p == lo and n == hi);
}

/// The node a branch terminal names: an identifier, read through
/// `hier_names` as every flattened name is, to the net it denotes. Null
/// for anything else (a bit-select of a vector node is §11.6.5's node BIT,
/// which the model does not hold). Asserts that a terminal is written and
/// the answer is `none` or a node.
fn terminalNode(
    objects: *const Rows,
    net_at: *const std.StringHashMapUnmanaged(ObjId),
    arena: std.mem.Allocator,
    res: *const Result,
    top_name: []const u8,
    e: Ast.ExprId,
) Error!ObjId {
    std.debug.assert(e != .none);
    const lowered = res.lowered;
    const file = res.file;
    if (file.exprs.tag(e) != .ident) return .none;
    const name = file.str(file.exprs.strOf(e));
    const denoted = lowered.hier_names.get(name) orelse name;
    const net = net_at.get(try model.joinPath(arena, top_name, denoted)) orelse return .none;
    const node = objects.coldOf(net).node;
    std.debug.assert(node == .none or objects.at(node).kind == .node);
    return node;
}
