//! The model over a running digital design: a `sim.digital.Run` -> a
//! `Design` whose net, reg and variable rows are bound to the engine slot
//! that stores them (`Obj.slot`), which §12.16/§12.30 and cbValueChange read
//! and write through. The run must outlive the model.
//!
//! The shape is the engine's own elaboration, read back rather than redone:
//! every instance is a non-lexical row of `Run.scope_info`, in depth-first
//! pre-order with the root at 0, and `Run.names` keys each declared name by
//! that row's engine scope id. Task frames, named-block scopes and
//! loop-generate iterations are lexical rows: not instances, but a generate
//! iteration is a component of the path of an instance inside it.

const std = @import("std");
const Ast = @import("frontend").Ast;
const sim = @import("sim");
const attributes = @import("attributes.zig");
const code = @import("code.zig");
const model = @import("model.zig");
const root = @import("root.zig");

const Building = model.Building;
const Design = root.Design;
const Error = root.Error;
const Kind = root.Kind;
const Obj = root.Obj;
const addArray = model.addArray;
const addModuleArrays = model.addModuleArrays;
const addRange = model.addRange;
const freeze = model.freeze;
const joinPath = model.joinPath;
const lastComponent = model.lastComponent;
const nameTable = model.nameTable;
const vpiArray = root.vpiArray;
const vpiNet = root.vpiNet;
const vpiScope = root.vpiScope;
const vpiSize = root.vpiSize;

/// Builds the digital model over run `r`. Value rows hold `r`'s slots and
/// behavioural rows its parsed source, so `r` must outlive the result.
/// `error.NotElaborated` for a design with a second top-level module, which
/// one `Design` cannot name. Caller owns the result and frees it with
/// `Design.deinit`. `model_gpa` holds the `Design`'s tables.
pub fn buildDigital(model_gpa: std.mem.Allocator, r: *sim.digital.Run) Error!Design {
    var d: Design = .{ .gpa = model_gpa, .arena = .init(model_gpa) };
    errdefer d.deinit();
    const arena = d.arena.allocator();
    // Everything below but the rows and the `Design` is scratch: many small
    // lists (a dozen per scope) and lookup tables, freed together on return,
    // rather than one `model_gpa` allocation each (with a page allocator,
    // a page each).
    var scratch: std.heap.ArenaAllocator = .init(model_gpa);
    defer scratch.deinit();
    const gpa = scratch.allocator();
    const file = r.file;
    const top_name = try arena.dupe(u8, file.str(r.scope_info.items[0].name));

    var n_scopes: usize = 0;
    for (r.scope_info.items) |info| n_scopes += @intFromBool(!info.lexical);
    var scopes: std.ArrayList(Building) = try .initCapacity(gpa, n_scopes);
    defer {
        for (scopes.items) |*s| s.deinit(gpa);
        scopes.deinit(gpa);
    }
    // The VPI scope of each engine instance scope; a lexical row has none.
    const vpi_of = try gpa.alloc(u32, r.scope_info.items.len);
    defer gpa.free(vpi_of);
    for (r.scope_info.items, 0..) |info, e| {
        if (info.lexical) continue;
        // ponytail: the model has one top-level module; a second (§12.1.1)
        // is refused until `Design` names objects from more than one root.
        if (e != 0 and info.parent == e) return error.NotElaborated;
        const at: u32 = @intCast(scopes.items.len);
        vpi_of[e] = at;
        var parent: ?u32 = null;
        var path: []const u8 = "";
        if (e != 0) {
            path = try pathComponent(arena, file, info);
            var p = info.parent;
            while (r.scope_info.items[p].lexical) : (p = r.scope_info.items[p].parent)
                path = try joinPath(arena, try pathComponent(arena, file, r.scope_info.items[p]), path);
            parent = vpi_of[p];
            path = try joinPath(arena, scopes.items[vpi_of[p]].path, path);
        }
        const m = &file.modules[info.def];
        const cfg = if (r.binds.get(@intCast(e))) |b| b.cfg else null;
        const mt = r.timeOf(@intCast(e));
        scopes.appendAssumeCapacity(.{
            .time_unit = @intCast(mt.unit_exp),
            .time_precision = @intCast(mt.unit_exp - @as(i32, std.math.log10_int(@as(u64, mt.scale.local_per_unit)))),
            .decl = m,
            .def_name = try arena.dupe(u8, file.str(m.name)),
            .library = try arena.dupe(u8, file.str(r.def_lib[info.def])),
            .config = if (cfg) |c| try arena.print("{s}.{s}", .{ file.str(r.cfg_lib[c]), file.str(file.configs[c].name) }) else "",
            .path = path,
            .parent = parent,
            .engine = @intCast(e),
        });
        if (parent) |p| try scopes.items[p].children.append(gpa, at);
    }

    var objects: model.Rows = .{ .gpa = model_gpa };
    defer objects.deinit();
    for (scopes.items, 0..) |s, i| try objects.append(.{
        .kind = .module,
        .owner = .of(s.parent),
        .scope = @intCast(i),
        .name = if (i == 0) top_name else lastComponent(s.path),
        .full = try joinPath(arena, top_name, s.path),
    });

    for (scopes.items, 0..) |*s, i| {
        const scope: u32 = @intCast(i);
        const eng = s.engine;
        const m = s.decl;
        for (m.ports, 0..) |p, k| {
            if (p.name == .none) continue; // IEEE 1364-2005 A.1.3 a null port names no net
            const at = r.names.get(.{ .scope = eng, .str = p.name });
            try s.ports.append(gpa, @intCast(objects.hot.items.len));
            var o = try digitalObj(r, arena, top_name, s.path, scope, p.name, .port, at);
            o.direction = p.direction;
            o.port_index = @intCast(k);
            o.src_tok = p.main_tok;
            try objects.append(o);
        }
        for (m.nets) |n| {
            const at = r.names.get(.{ .scope = eng, .str = n.name }) orelse continue;
            // IEEE 1364-2005 §26.6.6: a net array, over the engine's element
            // slots, each element a net of the declared type.
            if (r.arrays.get(at)) |a| {
                const local = try arena.dupe(u8, file.str(n.name));
                const arr = try addArray(arena, &objects, .net_array, scope, local, try joinPath(arena, top_name, try joinPath(arena, s.path, local)), .unspecified, a.low, a.high, a.rest, r.values[at].width, at);
                for (objects.coldOf(arr).members) |e| {
                    objects.hot.items[e].net_type = n.kind;
                    objects.hot.items[e].src_tok = n.main_tok;
                }
                const range = try arena.dupe(u32, &.{try addRange(arena, &objects, scope, a.left, a.right)});
                (try objects.coldFor(arr)).range = range;
                objects.hot.items[arr].src_tok = n.main_tok;
                try s.net_arrays.append(gpa, arr);
                continue;
            }
            try s.nets.append(gpa, @intCast(objects.hot.items.len));
            var o = try digitalObj(r, arena, top_name, s.path, scope, n.name, .net, at);
            o.net_type = n.kind;
            o.src_tok = n.main_tok;
            try objects.append(o);
            try addBits(arena, &objects, r, code.vpiNetBit);
        }
        // The implicit nets: a port declared with no net type (IEEE 1364-2005
        // §12.3.3), then §4.5's undeclared terminals and assignment targets,
        // in the order the engine declared them.
        // The slots `s` already has a net object for, so each name below
        // is one lookup rather than a scan of the scope's nets.
        var have: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer have.deinit(gpa);
        for (s.nets.items) |n| if (objects.hot.items[n].slot.get()) |slot| try have.put(gpa, slot, {});
        for (m.ports) |p| try implicitNet(gpa, arena, r, &objects, s, &have, scope, top_name, p.name);
        const ex = &file.exprs;
        var n_terms = m.gates.len + m.pulls.len + m.assigns.len;
        for (m.instances) |inst| n_terms += inst.ports.len;
        for (m.gates) |g| n_terms += g.ins.len;
        for (m.switches) |sw| n_terms += sw.terms.len;
        var terms: std.ArrayList(Ast.ExprId) = try .initCapacity(gpa, n_terms);
        defer terms.deinit(gpa);
        for (m.instances) |inst| for (inst.ports) |c| terms.appendAssumeCapacity(c.expr);
        for (m.gates) |g| {
            terms.appendAssumeCapacity(g.out);
            terms.appendSliceAssumeCapacity(g.ins);
        }
        for (m.switches) |sw| terms.appendSliceAssumeCapacity(sw.terms);
        for (m.pulls) |p| terms.appendAssumeCapacity(p.out);
        for (m.assigns) |a| terms.appendAssumeCapacity(a.target);
        for (terms.items) |x| if (x != .none and ex.tag(x) == .ident) try implicitNet(gpa, arena, r, &objects, s, &have, scope, top_name, ex.strOf(x));
        for (m.vars) |v| {
            const at = r.names.get(.{ .scope = eng, .str = v.name }) orelse continue;
            // §3.9 arrays: §11.6.11's classes, over the engine's own element
            // slots.
            if (r.arrays.get(at)) |a| {
                const is_reg = v.storage == .reg;
                const local = try arena.dupe(u8, file.str(v.name));
                // §26.6.7: a `real` array is a vpiRealVar with vpiArray set,
                // one of the scope's reals — as the analog model builds it.
                const real = !is_reg and v.ty == .real;
                const arr = try addArray(arena, &objects, if (is_reg) .reg_array else .var_array, scope, local, try joinPath(arena, top_name, try joinPath(arena, s.path, local)), if (real) .real else .integer, a.low, a.high, a.rest, r.values[at].width, at);
                // Two statements: addRange grows `objects`, moving `items`.
                const range = try arena.dupe(u32, &.{try addRange(arena, &objects, scope, a.left, a.right)});
                (try objects.coldFor(arr)).range = range;
                objects.hot.items[arr].src_tok = v.main_tok;
                try (if (is_reg) &s.reg_arrays else if (real) &s.reals else &s.integers).append(gpa, arr);
                if (!is_reg) try s.variables.append(gpa, arr);
                continue;
            }
            const kind: Kind = if (v.storage == .reg) .reg else if (v.storage == .time) .time_var else if (v.ty == .integer) .integer else if (v.ty == .real) .real_var else continue;
            if (kind != .reg) try s.variables.append(gpa, @intCast(objects.hot.items.len));
            // A time variable is in neither per-type list: its type is its own.
            if (kind != .time_var) try (if (kind == .reg) &s.regs else if (kind == .real_var) &s.reals else &s.integers).append(gpa, @intCast(objects.hot.items.len));
            var o = try digitalObj(r, arena, top_name, s.path, scope, v.name, kind, at);
            // IEEE 1364-2005 §4.8: `time` is unsigned, `integer` signed.
            o.is_signed = kind != .time_var and (v.is_signed or kind == .integer);
            o.src_tok = v.main_tok;
            try objects.append(o);
            if (kind == .reg) try addBits(arena, &objects, r, code.vpiRegBit);
        }
        // §11.6.12 parameters. The engine folds each into a slot of its own
        // (IEEE 1364 §12.2, `Run.params`), so NOTE 1's "final value of the
        // parameter after all module instantiation overrides and defparams
        // have been resolved" is that slot, read like any other value.
        for (m.params) |p| {
            const at = r.names.get(.{ .scope = eng, .str = p.name }) orelse continue;
            if (!r.params.contains(at)) continue;
            try s.params.append(gpa, @intCast(objects.hot.items.len));
            var o = try digitalObj(r, arena, top_name, s.path, scope, p.name, .parameter, at);
            o.ty = p.ty;
            o.is_local = p.is_local;
            o.src_tok = p.main_tok;
            try objects.append(o);
        }
    }
    try addModuleArrays(gpa, arena, &objects, scopes.items, top_name);
    try addGenScopes(gpa, arena, &objects, scopes.items, r, vpi_of);
    // §11.6.3/§11.6.16–§11.6.24, over each instance's own definition: the
    // engine ran these same bodies, one copy per instance.
    var udps: std.AutoHashMapUnmanaged(Ast.StrId, u32) = .empty;
    defer udps.deinit(gpa);
    var attrs: attributes.ByOwner = try .init(gpa, file);
    defer attrs.deinit(gpa);
    const udp_defns = try code.udpDefns(gpa, arena, &objects, file, &attrs, &udps);
    var names = try nameTable(gpa, objects.hot.items);
    defer names.deinit(gpa);
    var decls = try model.decls(gpa, objects.hot.items, scopes.items.len);
    defer decls.deinit(gpa);
    for (scopes.items, 0..) |*s, i| {
        var b: code.Builder = .{ .gpa = gpa, .arena = arena, .objects = &objects, .file = file, .names = &names, .top_name = top_name, .scope = @intCast(i), .path = s.path, .lists = &s.code, .udps = &udps, .run = r, .engine = s.engine, .attrs = &attrs };
        for (decls.of(i)) |at|
            try b.attributes(at, .{ .kind = .declaration, .tok = objects.hot.items[at].src_tok }, false);
        try b.module(s.decl);
        try addConnections(&b, scopes.items, r);
    }
    try freeze(&d, &objects, scopes.items);
    d.udp_defns = udp_defns;
    d.finest = @intCast(r.finest);
    d.search_up = false;
    d.file = file;
    return d;
}

/// IEEE 1364-2005 §26.6.2/§26.6.5/§26.6.12, built in scope `b.scope`, whose
/// expressions the connections are: each parameter's declared range
/// (vpiLeftRange/vpiRightRange, NULL without one, Details c), and for each
/// child instance its ports' vpiHighConn and vpiConnByName and one param
/// assign per `#(...)` entry; an instance array's range and its connection
/// list as one vpiListOp operation.
///
/// ponytail: only instances written directly in the module body; one inside
/// a generate block has none of these (its `Ast.Instance` is the block's).
fn addConnections(b: *code.Builder, scopes: []Building, r: *const sim.digital.Run) Error!void {
    const s = &scopes[b.scope];
    const m = s.decl;
    const file = b.file;
    for (s.params.items) |at| {
        const p = for (m.params) |p| {
            if (std.mem.eql(u8, file.str(p.name), b.objects.hot.items[at].name)) break p;
        } else continue;
        const range = p.packed_range orelse Ast.Dim{ .msb = .none, .lsb = .none };
        const l = try b.expr(range.msb);
        const rr = try b.expr(range.lsb);
        b.objects.hot.items[at].edges = try b.arena.dupe(code.Edge, &.{ .{ .tag = code.vpiLeftRange, .to = l }, .{ .tag = code.vpiRightRange, .to = rr } });
    }
    // The child scopes each instance name made, in child order: `next`
    // chains the positions in `s.children` that share a name, from `heads`.
    var heads: std.AutoHashMapUnmanaged(Ast.StrId, u32) = .empty;
    defer heads.deinit(b.gpa);
    const next = try b.gpa.alloc(u32, s.children.items.len);
    defer b.gpa.free(next);
    var pos = s.children.items.len;
    while (pos > 0) {
        pos -= 1;
        const g = try heads.getOrPut(b.gpa, r.scope_info.items[scopes[s.children.items[pos]].engine].name);
        next[pos] = if (g.found_existing) g.value_ptr.* else code.none;
        g.value_ptr.* = @intCast(pos);
    }
    for (m.instances) |*inst| {
        if (inst.range) |range| for (s.module_arrays.items) |at| {
            if (!std.mem.eql(u8, b.objects.hot.items[at].name, file.str(inst.name))) continue;
            const conns = try b.gpa.alloc(Ast.ExprId, inst.ports.len);
            defer b.gpa.free(conns);
            for (inst.ports, conns) |c, *e| e.* = c.expr;
            const l = try b.expr(range.msb);
            const rr = try b.expr(range.lsb);
            const list = try b.operation(code.vpiListOp, conns);
            b.objects.hot.items[at].edges = try b.arena.dupe(code.Edge, &.{
                .{ .tag = code.vpiLeftRange, .to = l },
                .{ .tag = code.vpiRightRange, .to = rr },
                .{ .tag = code.vpiExpr, .to = list },
            });
        };
        var made = heads.get(inst.name) orelse code.none;
        while (made != code.none) : (made = next[made]) {
            const c = s.children.items[made];
            try b.attributes(c, .{ .kind = .declaration, .tok = inst.main_tok }, false);
            const child = scopes[c].decl;
            const named = inst.ports.len != 0 and inst.ports[0].name != .none;
            for (scopes[c].ports.items) |pt| b.objects.hot.items[pt].props = try b.arena.dupe(code.Prop, &.{.{ .prop = code.vpiConnByName, .value = @intFromBool(named) }});
            for (inst.ports, 0..) |conn, k| {
                // §12.3.6: by name, the port whose external name it is; in
                // order, the k-th port (a concatenation's pieces are one).
                var ordinal: usize = 0;
                const j = for (child.ports, 0..) |p, j| {
                    if (named) {
                        if ((if (p.external_name != .none) p.external_name else p.name) == conn.name) break j;
                    } else if (!p.concat_rest) {
                        if (ordinal == k) break j;
                        ordinal += 1;
                    }
                } else continue;
                const high = try b.expr(conn.expr);
                b.objects.hot.items[scopes[c].ports.items[j]].edges = try b.arena.dupe(code.Edge, &.{.{ .tag = code.vpiHighConn, .to = high }});
                try b.attributes(scopes[c].ports.items[j], .{ .kind = .declaration, .tok = conn.main_tok }, false);
            }
            for (inst.params, 0..) |o, k| {
                // §12.2.2.1: in order, the k-th parameter that is not local.
                var ordinal: usize = 0;
                const name = for (child.params) |p| {
                    if (p.is_local) continue;
                    if (if (o.name != .none) p.name == o.name else ordinal == k) break p.name;
                    ordinal += 1;
                } else continue;
                const lhs = for (scopes[c].params.items) |at| {
                    if (std.mem.eql(u8, b.objects.hot.items[at].name, file.str(name))) break at;
                } else code.none;
                const rhs = try b.expr(o.value);
                const at = try b.code(code.vpiParamAssign, &.{ .{ .tag = code.vpiLhs, .to = lhs }, .{ .tag = code.vpiRhs, .to = rhs } }, &.{}, &.{.{ .prop = code.vpiConnByName, .value = @intFromBool(o.name != .none) }});
                b.objects.hot.items[at].owner = .of(c);
                try scopes[c].code.param_assigns.append(b.gpa, at);
            }
        }
    }
}

/// `name`, when it denotes a net of the engine that no net object of `s`
/// holds yet (`have`, the slots of `s`'s nets): that net, added to `s`'s
/// nets and to `have`.
fn implicitNet(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    r: *const sim.digital.Run,
    objects: *model.Rows,
    s: *Building,
    have: *std.AutoHashMapUnmanaged(u32, void),
    scope: u32,
    top_name: []const u8,
    name: Ast.StrId,
) Error!void {
    const at = r.names.get(.{ .scope = s.engine, .str = name }) orelse return;
    if (!r.net_of.contains(at)) return;
    if ((try have.getOrPut(gpa, at)).found_existing) return;
    try s.nets.append(gpa, @intCast(objects.hot.items.len));
    var o = try digitalObj(r, arena, top_name, s.path, scope, name, .net, at);
    o.implicit = true;
    try objects.append(o);
}

/// One declared name of `scope`, bound to the slot `at` that stores it.
fn digitalObj(
    r: *const sim.digital.Run,
    arena: std.mem.Allocator,
    top_name: []const u8,
    path: []const u8,
    scope: u32,
    name: Ast.StrId,
    kind: Kind,
    at: ?u32,
) Error!Obj {
    const local = try arena.dupe(u8, r.file.str(name));
    return .{
        .kind = kind,
        .owner = .of(scope),
        .name = local,
        .full = try joinPath(arena, top_name, try joinPath(arena, path, local)),
        .size = if (at) |a| r.values[a].width else 1,
        .slot = .of(at),
    };
}

/// One `scope_info` row's path component: its name, and `[k]` for an
/// instance array element or a loop-generate iteration (§12.4.1).
fn pathComponent(arena: std.mem.Allocator, file: *const Ast.SourceFile, info: anytype) Error![]const u8 {
    const name = file.str(info.name);
    const k = info.index orelse return arena.dupe(u8, name);
    return arena.print("{s}[{d}]", .{ name, k });
}

/// `model.addBits` over the engine's declared range of the vector last
/// appended (`Run.vecRange`); a row without an engine slot gets none.
fn addBits(arena: std.mem.Allocator, objects: *model.Rows, r: *const sim.digital.Run, vtype: c_int) Error!void {
    const slot = objects.hot.items[objects.hot.items.len - 1].slot.get() orelse return;
    const range = r.vecRange(slot);
    try model.addBits(arena, objects, range.msb, range.lsb, vtype);
}

/// IEEE 1364-2005 §26.6.44: each §12.4.1 loop generate directly inside an
/// instance is a gen scope array over its iterations, each a gen scope named
/// `name[i]` whose vpiIndex is `i`. Each scope exposes its scalar and vector
/// nets, which link back through vpiScope while keeping their module owner.
///
/// ponytail: a loop generate nested in another generate block, and a
/// conditional generate's scope, have no gen scope yet; both are rows of
/// `Run.scope_info` whose parent is itself lexical. Net arrays and other
/// declarations within a gen scope are not modelled yet.
fn addGenScopes(gpa: std.mem.Allocator, arena: std.mem.Allocator, objects: *model.Rows, scopes: []Building, r: *sim.digital.Run, vpi_of: []const u32) Error!void {
    const Key = struct { scope: u32, name: Ast.StrId };
    var groups: std.array_hash_map.Auto(Key, std.ArrayList(u32)) = .empty;
    defer {
        for (groups.values()) |*v| v.deinit(gpa);
        groups.deinit(gpa);
    }
    for (r.scope_info.items, 0..) |info, e| {
        // An instance array element has an index too, but is no lexical row.
        if (!info.lexical or info.index == null or r.scope_info.items[info.parent].lexical) continue;
        const g = try groups.getOrPut(gpa, .{ .scope = vpi_of[info.parent], .name = info.name });
        if (!g.found_existing) g.value_ptr.* = .empty;
        try g.value_ptr.append(gpa, @intCast(e));
    }
    for (groups.keys(), groups.values()) |k, rows| {
        const module_full = objects.hot.items[k.scope].full;
        const name = try arena.dupe(u8, r.file.str(k.name));
        const members = try arena.alloc(u32, rows.items.len);
        for (rows.items, members) |e, *m| {
            const i = r.scope_info.items[e].index.?;
            const c: u32 = @intCast(objects.hot.items.len);
            try objects.append(.{ .kind = .constant, .owner = .of(k.scope), .name = "", .full = "", .size = 32, .value = .{ .int = i } });
            const local = try arena.print("{s}[{d}]", .{ name, i });
            const full = try joinPath(arena, module_full, local);
            m.* = @intCast(objects.hot.items.len);
            try objects.append(.{
                .kind = .code,
                .vtype = code.vpiGenScope,
                .owner = .of(k.scope),
                .name = local,
                .full = full,
                .edges = try arena.dupe(code.Edge, &.{.{ .tag = code.vpiIndex, .to = c }}),
                .props = try arena.dupe(code.Prop, &.{
                    .{ .prop = vpiArray, .value = 1 },
                    .{ .prop = code.vpiProtected, .value = 0 },
                    .{ .prop = code.vpiImplicitDecl, .value = @intFromBool(r.scope_info.items[e].implicit) },
                }),
            });
            const gen_nets = r.gen_nets.get(e) orelse &.{};
            // At most one per generated net.
            var nets: std.ArrayList(u32) = try .initCapacity(arena, gen_nets.len);
            for (gen_nets) |n| {
                const slot = r.names.get(.{ .scope = e, .str = n.name }) orelse continue;
                if (r.arrays.contains(slot)) continue;
                const net_name = try arena.dupe(u8, r.file.str(n.name));
                nets.appendAssumeCapacity(@intCast(objects.hot.items.len));
                try objects.append(.{
                    .kind = .net,
                    .owner = .of(k.scope),
                    .name = net_name,
                    .full = try joinPath(arena, full, net_name),
                    .size = r.values[slot].width,
                    .slot = .of(slot),
                    .net_type = n.kind,
                    .src_tok = n.main_tok,
                    .src_engine = .of(e),
                    .edges = try arena.dupe(code.Edge, &.{.{ .tag = vpiScope, .to = m.* }}),
                });
                try addBits(arena, objects, r, code.vpiNetBit);
            }
            objects.hot.items[m.*].lists = try arena.dupe(code.List, &.{.{ .tag = vpiNet, .items = nets.items }});
        }
        const at: u32 = @intCast(objects.hot.items.len);
        try objects.append(.{
            .kind = .code,
            .vtype = code.vpiGenScopeArray,
            .owner = .of(k.scope),
            .name = name,
            .full = try joinPath(arena, module_full, name),
            .props = try arena.dupe(code.Prop, &.{.{ .prop = vpiSize, .value = @intCast(members.len) }}),
            .lists = try arena.dupe(code.List, &.{.{ .tag = code.vpiGenScope, .items = members }}),
        });
        try scopes[k.scope].code.gen_arrays.append(gpa, at);
    }
}
