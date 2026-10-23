//! The analog model (§11.6): a `CompileResult`, an elaborated and flattened
//! design, -> a `Design`. The scope tree is elaboration's
//! (`CompileResult.unit_paths`, with the AST beside `Lowered`), a
//! flat declaration belongs to the scope its §6.7 path names, and the analog
//! classes (§11.6.2, §11.6.5-§11.6.7) and behaviour (§11.6.20/§11.6.21) come
//! after the declarations. Everything is copied into `Design.arena`, so the
//! compilation may be freed once `build` returns.
//!
//! `build`'s order: scopes, modules, ports, nets, variables, parameters,
//! `addAnalog`, `model.addModuleArrays`, `addAnalogCode`, `model.freeze`.

const std = @import("std");
const Ast = @import("frontend").Ast;
const Elaborate = @import("vera").Elaborate;
const Lowered = @import("ir").Lowered;
const CompileResult = @import("vera").CompileResult;
const attributes = @import("attributes.zig");
const code = @import("code.zig");
const model = @import("model.zig");
const root = @import("root.zig");

const Building = model.Building;
const Design = root.Design;
const Error = root.Error;
const Cold = root.Cold;
const addArray = model.addArray;
const addModuleArrays = model.addModuleArrays;
const freeze = model.freeze;
const joinPath = model.joinPath;
const lastComponent = model.lastComponent;
const nameTable = model.nameTable;

/// Builds the analog model over `res`, whose `module` must be the
/// elaborated top (`error.NotElaborated` otherwise). The returned `Design`
/// owns every string and slice it reports (`Design.arena`); `res` may be
/// freed once this returns. Caller owns the result and frees it with
/// `Design.deinit`. `model_gpa` holds the `Design`'s tables.
pub fn build(model_gpa: std.mem.Allocator, res: *const CompileResult) Error!Design {
    const lowered = res.lowered;
    var d: Design = .{
        .gpa = model_gpa,
        .arena = .init(model_gpa),
        .objects = &.{},
        .scopes = &.{},
        .top_modules = &.{},
        .by_name = .empty,
        .iters = .empty,
    };
    errdefer d.deinit();
    const arena = d.arena.allocator();
    // Everything below but the rows and the `Design` is scratch: many small
    // lists (a dozen per scope) and lookup tables, freed together on return,
    // rather than one `model_gpa` allocation each (with a page allocator,
    // a page each).
    var scratch: std.heap.ArenaAllocator = .init(model_gpa);
    defer scratch.deinit();
    const gpa = scratch.allocator();

    const file = res.file;
    const flat = res.module orelse return error.NotElaborated;
    const top_name = try arena.dupe(u8, file.str(flat.name));

    // --- the scope tree ----------------------------------------------------
    // §11.6.1's `vpiInternalScope`, read from elaboration rather than walked
    // again: `CompileResult.unit_paths` is one row per inlined instance, depth first
    // in source order, with the definition it came from (`vpiDefName`).
    // Instance arrays, §6.4.2 paramsets and Annex E.2.1 were decided there. A
    // tree of one publishes no rows, so it is its own single row.
    const units = if (res.unit_paths.len != 0) res.unit_paths else &[_]Elaborate.UnitPath{
        .{ .module = top_name, .path = "", .decl = flat },
    };
    var scopes: std.ArrayList(Building) = try .initCapacity(gpa, units.len);
    defer {
        for (scopes.items) |*s| s.deinit(gpa);
        scopes.deinit(gpa);
    }
    // A path → scope index table: a unit finds its parent by it, and bucketing
    // the flattened declarations costs a lookup per declaration.
    var by_path: std.StringHashMapUnmanaged(u32) = .empty;
    defer by_path.deinit(gpa);
    for (units, 0..) |u, i| {
        const path = try arena.dupe(u8, std.mem.trimEnd(u8, u.path, &.{Elaborate.sep}));
        const at: u32 = @intCast(i);
        // Rows come parent first, so the parent is already in the table. Unit 0
        // is the top, whose path is "".
        const parent: ?u32 = if (i == 0) null else by_path.get(path[0 .. std.mem.findScalarLast(u8, path, Elaborate.sep) orelse 0]).?;
        scopes.appendAssumeCapacity(.{
            .decl = u.decl,
            .def_name = try arena.dupe(u8, u.module),
            .path = path,
            .parent = parent,
        });
        if (parent) |p| try scopes.items[p].children.append(gpa, at);
        try by_path.put(gpa, path, at);
    }

    // --- the objects -------------------------------------------------------
    var objects: model.Rows = .{ .gpa = model_gpa };
    defer objects.deinit();

    // Modules FIRST and in scope order: that is the `Scope` invariant, and it
    // is what lets an object's `owner` scope index double as its owner's
    // object index.
    for (scopes.items, 0..) |s, i| try objects.append(.{
        .kind = .module,
        .owner = .of(s.parent),
        .scope = @intCast(i),
        .name = if (i == 0) top_name else lastComponent(s.path),
        .full = try joinPath(arena, top_name, s.path),
    });

    // §11.6.4 ports. Read from the DEFINITION, not from the flattened module:
    // flattening collapses a child's port into the parent net it was bound to
    // (`Elaborate.Design.names`), so the flat module holds only the top's ports
    // and a child's would otherwise have no object at all — even though §6.7
    // still lets source name it and `hier_names` still resolves it.
    //
    // The SIZE comes back from the flat side through that same table: a port's
    // width is the width of the node it denotes, and `Lowered.vectors` is the
    // §3.6.3 range already folded, keyed by the flat name.
    for (scopes.items, 0..) |*s, i| {
        try s.ports.ensureTotalCapacityPrecise(gpa, s.decl.ports.len);
        for (s.decl.ports, 0..) |p, k| {
            const local = try arena.dupe(u8, file.str(p.name));
            const path = try joinPath(arena, s.path, local);
            const node = lowered.hier_names.get(path) orelse path;
            s.ports.appendAssumeCapacity(@intCast(objects.hot.items.len));
            try objects.append(.{
                .kind = .port,
                .owner = .of(@intCast(i)),
                .name = local,
                .full = try joinPath(arena, top_name, path),
                .size = vectorSize(lowered, node),
                .direction = p.direction,
                .port_index = @intCast(k),
                .src_tok = p.main_tok,
            });
        }
    }

    // §11.6.8/§11.6.9/§11.6.12 — the contents of every scope, from the
    // ELABORATED module. Each flat name is its own §6.7 path, so the scope it
    // belongs to is the part before the last `Elaborate.sep` and the `vpiName`
    // is the part after. A declaration whose path names no scope is dropped
    // rather than guessed at; nothing a flatten produces has one, and inventing
    // a scope for it would be inventing hierarchy.
    for (flat.nets) |n| {
        const flat_name = file.str(n.name);
        const split = (try splitPath(arena, &by_path, flat_name)) orelse continue;
        // §3.6.3's range as lowering folded it (`vectorSize`'s source); a
        // scalar is `[0:0]`, whose bit set is empty.
        const range = lowered.vectors.get(flat_name) orelse Lowered.VecRange{ .msb = 0, .lsb = 0 };
        try scopes.items[split.scope].nets.append(gpa, @intCast(objects.hot.items.len));
        try objects.append(.{
            .kind = .net,
            .owner = .of(split.scope),
            .name = split.local,
            .full = try joinPath(arena, top_name, flat_name),
            .size = range.size(),
            .net_type = n.kind,
            .src_tok = n.main_tok,
        });
        // IEEE 1364-2005 §26.6.6 Details a: the vector's bits, `bus[0]`..,
        // reached by vpiBit and §12.20's vpi_handle_by_index.
        try model.addBits(arena, &objects, range.msb, range.lsb, code.vpiNetBit);
    }
    for (flat.vars) |v| {
        // §11.6.9 is about REGS; `real` and `integer` are §11.6.10's
        // variables, with their own tags. Arrays of either are §11.6.11.
        const flat_name = file.str(v.name);
        const split = (try splitPath(arena, &by_path, flat_name)) orelse continue;
        if (v.dims.len == 1) {
            const dim = literalDim(file, v.dims[0]) orelse continue;
            const is_reg = v.storage == .reg;
            if (!is_reg and v.ty != .real and v.ty != .integer) continue;
            const at = try addArray(arena, &objects, if (is_reg) .reg_array else .var_array, split.scope, split.local, try joinPath(arena, top_name, flat_name), if (is_reg) .integer else v.ty, dim.low, dim.high, &.{}, if (is_reg) packedWidth(file, v) else if (v.ty == .real) 64 else 32, null);
            objects.hot.items[at].src_tok = v.main_tok;
            const list = if (is_reg) &scopes.items[split.scope].reg_arrays else if (v.ty == .real) &scopes.items[split.scope].reals else &scopes.items[split.scope].integers;
            try list.append(gpa, at);
            if (!is_reg) try scopes.items[split.scope].variables.append(gpa, at);
            continue;
        }
        if (v.dims.len != 0) continue;
        if (v.storage == .variable and (v.ty == .real or v.ty == .integer)) {
            const list = if (v.ty == .real) &scopes.items[split.scope].reals else &scopes.items[split.scope].integers;
            try list.append(gpa, @intCast(objects.hot.items.len));
            try scopes.items[split.scope].variables.append(gpa, @intCast(objects.hot.items.len));
            try objects.append(.{
                .kind = if (v.ty == .real) .real_var else .integer,
                .owner = .of(split.scope),
                .name = split.local,
                .full = try joinPath(arena, top_name, flat_name),
                .size = if (v.ty == .real) 64 else 32,
                .ty = v.ty,
                .src_tok = v.main_tok,
            });
            continue;
        }
        if (v.storage != .reg) continue;
        try scopes.items[split.scope].regs.append(gpa, @intCast(objects.hot.items.len));
        try objects.append(.{
            .kind = .reg,
            .owner = .of(split.scope),
            .name = split.local,
            .full = try joinPath(arena, top_name, flat_name),
            .size = packedWidth(file, v),
            .is_signed = v.is_signed,
            .src_tok = v.main_tok,
        });
    }
    for (flat.params) |p| {
        const flat_name = file.str(p.name);
        const split = (try splitPath(arena, &by_path, flat_name)) orelse continue;
        try scopes.items[split.scope].params.append(gpa, @intCast(objects.hot.items.len));
        try objects.append(.{
            .kind = .parameter,
            .owner = .of(split.scope),
            .name = split.local,
            .full = try joinPath(arena, top_name, flat_name),
            .ty = p.ty,
            .src_tok = p.main_tok,
            // §3.4.5, as the SOURCE wrote it. Elaboration turns a flattened
            // child's `parameter` into a `localparam` carrying its override, so
            // the flat row's `is_local` describes the flatten and not the
            // declaration; the definition still has the declaration. §11.6.12
            // NOTE 1 is the same sentence about the value beside it.
            .is_local = declaredLocal(scopes.items[split.scope].decl, file, split.local) orelse p.is_local,
            .value = if (lowered.consts.get(flat_name)) |c| switch (c) {
                .str => |text| .{ .str = try arena.dupe(u8, text) },
                else => c,
            } else null,
        });
    }
    const analog = try addAnalog(gpa, arena, &objects, scopes.items, &by_path, res, top_name);
    try addModuleArrays(gpa, arena, &objects, scopes.items, top_name);
    try addAnalogCode(gpa, arena, &objects, scopes.items, res, top_name);

    try freeze(&d, &objects, scopes.items);
    d.disciplines = analog.disciplines;
    d.natures = analog.natures;
    return d;
}

/// §11.6.2's natures and disciplines, §11.6.5's nodes, §11.6.6's branches and
/// §11.6.7's quantities — the analog classes, read from the elaborated
/// declarations exactly as nets are: the DECLARATIONS are the source's
/// (`file.natures`, `file.disciplines`), the node of each net and the
/// terminals of each branch are the flattened module's.
///
/// Natures are appended first, then disciplines, so a discipline's nature
/// edges and a nature's `users` are indices known when they are written.
fn addAnalog(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    objects: *model.Rows,
    scopes: []Building,
    by_path: *const std.StringHashMapUnmanaged(u32),
    res: *const CompileResult,
    top_name: []const u8,
) Error!struct { disciplines: []const u32, natures: []const u32 } {
    const lowered = res.lowered;
    const file = res.file;
    const flat = res.module.?;

    // --- natures: one object each, then the vpiParent edge and its inverse.
    const natures = try arena.alloc(u32, file.natures.len);
    var nature_at: std.StringHashMapUnmanaged(u32) = .empty;
    defer nature_at.deinit(gpa);
    for (file.natures, natures) |n, *at| {
        const name = try arena.dupe(u8, file.str(n.name));
        at.* = @intCast(objects.hot.items.len);
        try objects.append(.{ .kind = .nature, .owner = .none, .name = name, .full = name });
        try nature_at.put(gpa, name, at.*);
    }
    // --- disciplines, each with the natures it binds.
    const disciplines = try arena.alloc(u32, file.disciplines.len);
    var disc_at: std.StringHashMapUnmanaged(u32) = .empty;
    defer disc_at.deinit(gpa);
    for (file.disciplines, disciplines) |dd, *at| {
        const name = try arena.dupe(u8, file.str(dd.name));
        at.* = @intCast(objects.hot.items.len);
        try objects.appendCold(.{ .kind = .discipline, .owner = .none, .name = name, .full = name }, .{
            .flow = if (dd.flow == .none) null else nature_at.get(file.str(dd.flow)),
            .pot = if (dd.potential == .none) null else nature_at.get(file.str(dd.potential)),
        });
        try disc_at.put(gpa, name, at.*);
    }
    // §3.6.1.1 a derived nature's parent: a nature by name, or — A.1.6's
    // `discipline_identifier . potential_or_flow` — the nature that discipline
    // binds on that side.
    for (file.natures, natures) |n, at| {
        if (n.parent == .none) continue;
        const pname = file.str(n.parent);
        const parent: ?u32 = if (n.parent_access) |side| blk: {
            const di = disc_at.get(pname) orelse break :blk null;
            break :blk switch (side) {
                .potential => objects.coldOf(di).pot,
                .flow => objects.coldOf(di).flow,
            };
        } else nature_at.get(pname);
        (try objects.coldFor(at)).nature = parent;
    }
    // The inverse edges, nature ->> nature (vpiChild) and nature ->> discipline.
    for (natures) |at| {
        var n_kids: usize = 0;
        for (natures) |other| n_kids += @intFromBool(objects.coldOf(other).nature == at);
        var kids: std.ArrayList(u32) = try .initCapacity(arena, n_kids);
        for (natures) |other| if (objects.coldOf(other).nature == at) kids.appendAssumeCapacity(other);
        var n_users: usize = 0;
        for (disciplines) |di| n_users += @intFromBool(binds(objects.coldOf(di), at));
        var users: std.ArrayList(u32) = try .initCapacity(arena, n_users);
        for (disciplines) |di| if (binds(objects.coldOf(di), at)) users.appendAssumeCapacity(di);
        const children = kids.items;
        const users_of = users.items;
        const c = try objects.coldFor(at);
        c.children = children;
        c.users = users_of;
    }

    // --- nodes: one per net of a continuous discipline (§3.6.2.2: a
    // discipline binding natures and not declared `domain discrete`).
    var net_at: std.StringHashMapUnmanaged(u32) = .empty;
    defer net_at.deinit(gpa);
    // A top-level port is its own net here (its declaration is the port's,
    // not a separate §11.6.8 object), so it is keyed too — nets after ports,
    // so a name that is both resolves to the net.
    for (objects.hot.items, 0..) |o, i| if (o.kind == .port and o.owner.get() == 0) try net_at.put(gpa, o.full, @intCast(i));
    for (objects.hot.items, 0..) |o, i| if (o.kind == .net) try net_at.put(gpa, o.full, @intCast(i));
    const Decl = struct { name: Ast.StrId, discipline: Ast.StrId };
    var decls: std.ArrayList(Decl) = try .initCapacity(gpa, flat.ports.len + flat.nets.len);
    defer decls.deinit(gpa);
    for (flat.ports) |p| decls.appendAssumeCapacity(.{ .name = p.name, .discipline = p.discipline });
    for (flat.nets) |n| decls.appendAssumeCapacity(.{ .name = n.name, .discipline = n.discipline });
    for (decls.items) |n| {
        if (n.discipline == .none) continue;
        const di = disc_at.get(file.str(n.discipline)) orelse continue;
        if (file.disciplines[di - disciplines[0]].domain == .discrete) continue;
        const full = try joinPath(arena, top_name, file.str(n.name));
        const net = net_at.get(full) orelse continue;
        // A port declared and then typed by a net declaration is one node.
        if (objects.coldOf(net).node != null) continue;
        const at: u32 = @intCast(objects.hot.items.len);
        const src = objects.hot.items[net];
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
            .nets = if (src.kind == .net) try arena.dupe(u32, &.{net}) else &.{},
        });
        const net_cold = try objects.coldFor(net);
        net_cold.node = at;
        net_cold.disc = di;
        try scopes[src.owner.get().?].nodes.append(gpa, at);
    }
    // Each node's solver row: the `Lowered.nodes` row spelled by the node's
    // flattened name (`nodes` rows are named as `nets` are, §6.7 paths).
    for (lowered.nodes.items(.name), lowered.nodes.items(.kind), 0..) |name, kind, row| {
        if (kind != .net) continue;
        const denoted = lowered.hier_names.get(name) orelse name;
        const net = net_at.get(try joinPath(arena, top_name, denoted)) orelse continue;
        const node = objects.coldOf(net).node orelse continue;
        if (objects.coldOf(node).row == null) (try objects.coldFor(node)).row = @intCast(row);
    }
    // The node object each solver row is the row of, the earliest when two
    // share one: what an unnamed branch's terminals resolve to. Every node
    // exists by now; branches add none.
    const node_of_row = try gpa.alloc(?u32, lowered.nodes.len);
    defer gpa.free(node_of_row);
    @memset(node_of_row, null);
    for (objects.hot.items, 0..) |o, i| if (o.kind == .node) if (objects.coldOf(@intCast(i)).row) |row| {
        if (row < node_of_row.len and node_of_row[row] == null) node_of_row[row] = @intCast(i);
    };

    // --- branches, each with its two quantities. `named` keeps them in
    // object order: the rows a named contribution below is matched against.
    // At most one per declared branch.
    var named: std.ArrayList(u32) = try .initCapacity(gpa, flat.branches.len);
    defer named.deinit(gpa);
    for (flat.branches) |b| {
        const flat_name = file.str(b.name);
        const split = (try splitPath(arena, by_path, flat_name)) orelse continue;
        const pos = try terminalNode(objects, &net_at, arena, res, top_name, b.hi);
        const neg = if (b.lo == .none) null else try terminalNode(objects, &net_at, arena, res, top_name, b.lo);
        const full = try joinPath(arena, top_name, flat_name);
        const at = try addBranch(objects, split.scope, split.local, full, .{
            .disc = if (pos) |p| objects.coldOf(p).disc else null,
            .pos = pos,
            .neg = neg,
            .hi_row = if (pos) |p| objects.coldOf(p).row orelse Lowered.ground else Lowered.ground,
            .lo_row = if (neg) |n| objects.coldOf(n).row orelse Lowered.ground else Lowered.ground,
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
    var unnamed: std.AutoHashMapUnmanaged(UnnamedKey, u32) = .empty;
    defer unnamed.deinit(gpa);
    for (rows, 0..) |c, k| {
        const idx: u32 = @intCast(k);
        if (c.br != Lowered.unnamed_branch) {
            // A named branch: the one of this pair its instance declares. Two
            // named branches over one pair are told apart by an id lowering
            // keeps to itself, so this model does not guess between them.
            var found: ?u32 = null;
            var twice = false;
            for (named.items) |i| {
                if (!branchSpans(objects, objects.coldOf(i), c.hi, c.lo)) continue;
                if (found != null) twice = true;
                found = i;
            }
            const b = found orelse continue;
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
    return .{ .disciplines = disciplines, .natures = natures };
}

/// A branch row of `scope` with cold fields `c`, then its flow and potential
/// quantities (`c.flow`, `c.pot` are set to them), each of the nature its
/// discipline binds on that side (§11.6.7). Returns the branch row;
/// invalidates pointers into `objects`.
fn addBranch(objects: *model.Rows, scope: u32, name: []const u8, full: []const u8, c: Cold) Error!u32 {
    const at: u32 = @intCast(objects.hot.items.len);
    var bc = c;
    bc.flow = at + 1;
    bc.pot = at + 2;
    try objects.appendCold(.{ .kind = .branch, .owner = .of(scope), .name = name, .full = full }, bc);
    const d: ?Cold = if (c.disc) |di| objects.coldOf(di).* else null;
    try objects.appendCold(.{ .kind = .quantity, .owner = .of(scope), .name = "", .full = "" }, .{ .branch = at, .nature = if (d) |o| o.flow else null });
    try objects.appendCold(.{ .kind = .quantity, .owner = .of(scope), .name = "", .full = "" }, .{ .branch = at, .nature = if (d) |o| o.pot else null });
    return at;
}

/// Does discipline `d` bind nature `at` on either side?
fn binds(d: *const Cold, at: u32) bool {
    return d.flow == at or d.pot == at;
}

const UnnamedKey = struct { scope: u32, hi: u32, lo: u32 };

/// The §5.4.2 unnamed branch instance `unit` declares over row `idx`'s pair,
/// made on first sight and bound to the row.
fn unnamedBranch(
    gpa: std.mem.Allocator,
    objects: *model.Rows,
    scopes: []Building,
    unnamed: *std.AutoHashMapUnmanaged(UnnamedKey, u32),
    by_path: *const std.StringHashMapUnmanaged(u32),
    res: *const CompileResult,
    node_of_row: []const ?u32,
    c: Lowered.Contribution,
    idx: u32,
    unit: u32,
) Error!void {
    const lowered = res.lowered;
    const scope: u32 = if (unit < res.unit_paths.len)
        by_path.get(std.mem.trimEnd(u8, res.unit_paths[unit].path, &.{Elaborate.sep})) orelse 0
    else
        0;
    const g = try unnamed.getOrPut(gpa, .{ .scope = scope, .hi = c.hi, .lo = c.lo });
    if (!g.found_existing) {
        const pos = nodeOfRow(node_of_row, c.hi);
        const neg = nodeOfRow(node_of_row, c.lo);
        // §5.4.2 gives an unnamed branch no name; `vpiName` answers the empty
        // string, as §11.6.7's unnamed quantity does.
        const at = try addBranch(objects, scope, "", "", .{
            .disc = if (pos) |p| objects.coldOf(p).disc else if (neg) |n| objects.coldOf(n).disc else null,
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
    try bindRow(objects, g.value_ptr.*, c, idx, share);
}

/// Record contribution row `k` as the source of branch `at`'s potential or
/// flow; `share`, its `Lowered.contrib_shares` entry when `k` is shared.
fn bindRow(objects: *model.Rows, at: u32, c: Lowered.Contribution, k: u32, share: ?u32) Error!void {
    const unnamed = objects.hot.items[at].full.len == 0;
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
}

/// The node object whose solver row is `row` (`node_of_row`, built in
/// `addAnalog`); null for ground (§1.3.1.1 has no node row for it) and for a
/// row no node object carries.
fn nodeOfRow(node_of_row: []const ?u32, row: u32) ?u32 {
    if (row == Lowered.ground or row >= node_of_row.len) return null;
    return node_of_row[row];
}

/// Does named branch `o` join rows `hi` and `lo`, in either order? §5.4.2's
/// reference direction is the declaration's, and contributions are
/// canonicalised to one spelling of the pair, so both orders are the branch.
fn branchSpans(objects: *const model.Rows, o: *const Cold, hi: u32, lo: u32) bool {
    const p: u32 = if (o.pos) |n| objects.coldOf(n).row orelse return false else Lowered.ground;
    const n: u32 = if (o.neg) |m| objects.coldOf(m).row orelse return false else Lowered.ground;
    return (p == hi and n == lo) or (p == lo and n == hi);
}

/// The node a branch terminal names: an identifier, read through
/// `hier_names` as every flattened name is, to the net it denotes. Null
/// for anything else (a bit-select of a vector node is §11.6.5's node BIT,
/// which the model does not hold).
fn terminalNode(
    objects: *const model.Rows,
    net_at: *const std.StringHashMapUnmanaged(u32),
    arena: std.mem.Allocator,
    res: *const CompileResult,
    top_name: []const u8,
    e: Ast.ExprId,
) Error!?u32 {
    const lowered = res.lowered;
    const file = res.file;
    if (file.exprs.tag(e) != .ident) return null;
    const name = file.str(file.exprs.strOf(e));
    const denoted = lowered.hier_names.get(name) orelse name;
    const net = net_at.get(try joinPath(arena, top_name, denoted)) orelse return null;
    return objects.coldOf(net).node;
}

/// §11.6.20/§11.6.21 the analog model's behaviour: each flattened `analog`
/// block, in the scope of the instance that wrote it, with its statements,
/// contributions and expressions.
fn addAnalogCode(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    objects: *model.Rows,
    scopes: []Building,
    res: *const CompileResult,
    top_name: []const u8,
) Error!void {
    const lowered = res.lowered;
    const flat = res.module.?;
    var an: code.Builder.Analog = .{ .lowered = lowered };
    defer an.branches.deinit(gpa);
    defer an.flow_access.deinit(gpa);
    for (objects.hot.items, 0..) |o, i| switch (o.kind) {
        // Keyed by the declared name a statement spells; an unnamed branch
        // (§5.4.2) has none, and a statement reaches it by its node pair.
        .branch => if (o.full.len > top_name.len) try an.branches.put(gpa, o.full[top_name.len + 1 ..], @intCast(i)),
        .discipline => if (lowered.disciplines.get(o.name)) |info| try an.flow_access.put(gpa, @intCast(i), info.flow_access),
        .module, .port, .net, .reg, .parameter, .integer, .real_var, .time_var, .reg_array, .var_array, .net_array, .word, .var_select, .module_array, .constant, .nature, .node, .quantity, .code => {},
    };
    var names = try nameTable(gpa, objects.hot.items);
    defer names.deinit(gpa);
    var decls = try model.decls(gpa, objects.hot.items, scopes.len);
    defer decls.deinit(gpa);
    var attrs: attributes.ByOwner = try .init(gpa, res.file);
    defer attrs.deinit(gpa);
    for (scopes, 0..) |*s, i| {
        var b: code.Builder = .{ .gpa = gpa, .arena = arena, .objects = objects, .file = res.file, .names = &names, .top_name = top_name, .scope = @intCast(i), .path = s.path, .lists = &s.code, .analog = &an, .attrs = &attrs };
        try b.attributes(@intCast(i), .{ .kind = .declaration, .tok = s.decl.main_tok }, true);
        for (decls.of(i)) |at|
            try b.attributes(at, .{ .kind = .declaration, .tok = objects.hot.items[at].src_tok }, false);
        // The child scopes each instance name made, in child order: `next`
        // chains the positions in `s.children` that share a name.
        var heads: std.StringHashMapUnmanaged(u32) = .empty;
        defer heads.deinit(gpa);
        const next = try gpa.alloc(u32, s.children.items.len);
        defer gpa.free(next);
        var pos = s.children.items.len;
        while (pos > 0) {
            pos -= 1;
            const g = try heads.getOrPut(gpa, objects.hot.items[s.children.items[pos]].name);
            next[pos] = if (g.found_existing) g.value_ptr.* else code.none;
            g.value_ptr.* = @intCast(pos);
        }
        for (s.decl.instances) |inst| {
            var made = heads.get(b.file.str(inst.name)) orelse code.none;
            while (made != code.none) : (made = next[made]) {
                const child = s.children.items[made];
                // §11.6.1: the instance is where the module is USED
                // (IEEE 1364-2005 §26.3.3), the line `u1(...)` is written on.
                (try objects.coldFor(child)).loc = try srcLoc(arena, res, inst.main_tok);
                try b.attributes(child, .{ .kind = .declaration, .tok = inst.main_tok }, false);
                for (inst.ports, 0..) |conn, k| {
                    const pt = if (conn.name == .none) (if (k < scopes[child].ports.items.len) scopes[child].ports.items[k] else continue) else for (scopes[child].ports.items) |p| {
                        if (std.mem.eql(u8, objects.hot.items[p].name, b.file.str(conn.name))) break p;
                    } else continue;
                    try b.attributes(pt, .{ .kind = .declaration, .tok = conn.main_tok }, false);
                }
            }
        }
        try b.analogBlocks(flat.analog);
    }
}

/// IEEE 1364-2005 §26.3.3: the file and 1-based line token `tok` was written
/// at, through the compilation's source map (an `include`d file names
/// itself, a macro expansion its invocation); null for a token lowering has
/// no start for. The file name is copied into `arena`.
fn srcLoc(arena: std.mem.Allocator, res: *const CompileResult, tok: u32) Error!?root.Loc {
    const starts = res.lowered.tok_starts;
    if (tok >= starts.len) return null;
    const bag = res.diags;
    const at = bag.locate(.{ .start = starts[tok], .end = starts[tok] }, null);
    const off = bag.toSourceOffset(at.file, at.offset);
    const text = bag.sourceText(at.file);
    return .{
        .line = @intCast(1 + std.mem.count(u8, text[0..@min(off, text.len)], "\n")),
        .file = try arena.dupe(u8, bag.fileName(at.file)),
    };
}

/// §3.4.5 as the SOURCE wrote it: is `name` a `localparam` of `decl`? `null`
/// when `decl` declares no such parameter, which is the case for a parameter
/// elaboration synthesized rather than copied.
fn declaredLocal(decl: *const Ast.ModuleDecl, file: *const Ast.SourceFile, name: []const u8) ?bool {
    for (decl.params) |p| {
        if (std.mem.eql(u8, file.str(p.name), name)) return p.is_local;
    }
    return null;
}

/// §3.6.3 a vector net is N nets, and §11.6.8's `vpiSize` is that N.
/// `Lowered.vectors` is the folded `[msb:lsb]` keyed by the flat name — the same
/// fold lowering scalarised the net with, so this cannot disagree with the
/// device's terminal count. A name absent from it is a scalar.
fn vectorSize(lowered: *const Lowered, flat_name: []const u8) u32 {
    const r = lowered.vectors.get(flat_name) orelse return 1;
    return @intCast(@abs(r.msb - r.lsb) + 1);
}

/// §11.6.9's `vpiSize` for a `reg [msb:lsb]`.
///
/// ponytail: literal bounds only (`Lowered.vectors` holds nets and ports, not
/// regs). A non-literal range returns 0, which `vpi_get(vpiSize, ...)` reports
/// as `vpiUndefined` plus an error. Upgrade path: lowering interns packed regs
/// into `vectors` as it does nets, and this function disappears.
fn packedWidth(file: *const Ast.SourceFile, v: Ast.VarDecl) u32 {
    const range = v.packed_range orelse return 1;
    if (file.exprs.tag(range.msb) != .int_literal or file.exprs.tag(range.lsb) != .int_literal) return 0;
    const hi = file.exprs.intValue(range.msb);
    const lo = file.exprs.intValue(range.lsb);
    if (hi < 0 or lo < 0) return 0;
    return @intCast(@abs(hi - lo) + 1);
}

/// Split a flattened declaration's name into the scope it belongs to and the
/// §11.6 `vpiName` inside it.
///
/// The last `Elaborate.sep` is the split, and that is exact rather than a
/// heuristic: §6.6 generate blocks add no path component in this compiler (they
/// unroll inside a body, not into the declaration space), and `parser.internTok`
/// substitutes a space for a period inside a §2.8.1 escaped identifier — so a
/// period in a flattened name IS a join.
/// `tests/conformance/tests/verilog-a/ch06_hierarchy/escaped_period_is_not_a_path.va` is the
/// fixture on that substitution.
fn splitPath(
    arena: std.mem.Allocator,
    by_path: *const std.StringHashMapUnmanaged(u32),
    flat: []const u8,
) Error!?struct { scope: u32, local: []const u8 } {
    const at = std.mem.findScalarLast(u8, flat, Elaborate.sep);
    const path = if (at) |i| flat[0..i] else "";
    const scope = by_path.get(path) orelse return null;
    return .{ .scope = scope, .local = try arena.dupe(u8, if (at) |i| flat[i + 1 ..] else flat) };
}

/// A declared unpacked dimension, folded when both bounds are literal integers
/// — the same rule `packedWidth` applies. Null otherwise: the array is then
/// not modelled rather than modelled with a guessed size.
fn literalDim(file: *const Ast.SourceFile, dim: Ast.Dim) ?struct { low: i64, high: i64 } {
    if (file.exprs.tag(dim.msb) != .int_literal or file.exprs.tag(dim.lsb) != .int_literal) return null;
    const a = file.exprs.intValue(dim.msb);
    const b = file.exprs.intValue(dim.lsb);
    return .{ .low = @min(a, b), .high = @max(a, b) };
}
