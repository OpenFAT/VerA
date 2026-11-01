//! The model over a running digital design: a `sim.digital.Run` -> a
//! `Design` whose net, reg and variable rows are bound to the engine slot
//! that stores them (`Obj.slot`), which §12.16/§12.30 and cbValueChange read
//! and write through. The run must outlive the model.
//! Cites: IEEE 1364-2005 §12.3, §26.6.1-§26.6.12, §26.6.44; VAMS-2023 §11.2.2.
//!
//! The shape is the engine's own elaboration, read back rather than redone:
//! every instance is a non-lexical row of `Run.hier.scopes`, in depth-first
//! pre-order with the root at 0, and `Run.hier.names` keys each declared name
//! by that row's engine scope id.
//!
//! Contents:
//! - `pub fn buildDigital(model_gpa: std.mem.Allocator, r: *sim.digital.Run) Error!Design`

const std = @import("std");
const Ast = @import("frontend").Ast;
const sim = @import("sim");
const model = @import("model.zig");
const model_arrays = @import("model_arrays.zig");
const schema = @import("schema.zig");
const ObjId = schema.ObjId;
const udp = @import("udp.zig");
const user = @import("vpi_user.zig");
const Builder = @import("Builder.zig");
const Design = @import("Design.zig");
const attribute = @import("attribute.zig");
const session = @import("session.zig");
const Building = model.Building;
const ByOwner = attribute.ByOwner;
const Edge = schema.Edge;
const Error = session.Error;
const Kind = schema.Kind;
const List = schema.List;
const Obj = schema.Obj;
const Prop = schema.Prop;
const Rows = model.Rows;

/// Builds the digital model over run `r`. Value rows hold `r`'s slots and
/// behavioural rows its parsed source, so `r` must outlive the result.
/// `error.NotElaborated` for a design with a second top-level module, which
/// one `Design` cannot name. Caller owns the result and frees it with
/// `Design.deinit`. `model_gpa` holds the `Design`'s tables. Asserts that
/// the run's first scope is the top instance, that every instance scope
/// became one scope here, and that the model has the one top.
pub fn buildDigital(model_gpa: std.mem.Allocator, r: *sim.digital.Run) Error!Design {
    std.debug.assert(r.hier.scopes.items.len >= 1);
    std.debug.assert(!r.hier.scopes.items[0].lexical);
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
    const top_name = try arena.dupe(u8, file.str(r.hier.scopes.items[0].name));

    var n_scopes: usize = 0;
    for (r.hier.scopes.items) |info| n_scopes += @intFromBool(!info.lexical);
    var scopes: std.ArrayList(Building) = try .initCapacity(gpa, n_scopes);
    defer {
        for (scopes.items) |*s| s.deinit(gpa);
        scopes.deinit(gpa);
    }
    // The VPI scope of each engine instance scope; a lexical row has none.
    const vpi_of = try gpa.alloc(u32, r.hier.scopes.items.len);
    defer gpa.free(vpi_of);
    for (r.hier.scopes.items, 0..) |info, e| {
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
            var climbed: usize = 0;
            while (r.hier.scopes.items[p].lexical) : (p = r.hier.scopes.items[p].parent) {
                std.debug.assert(climbed < r.hier.scopes.items.len);
                climbed += 1;
                path = try model.joinPath(arena, try pathComponent(arena, file, r.hier.scopes.items[p]), path);
            }
            parent = vpi_of[p];
            path = try model.joinPath(arena, scopes.items[vpi_of[p]].path, path);
        }
        const m = &file.modules[info.def];
        const cfg = if (r.hier.binds.get(@intCast(e))) |b| b.cfg else null;
        const mt = r.timeOf(@intCast(e));
        scopes.appendAssumeCapacity(.{
            .time_unit = @intCast(mt.unit_exp),
            .time_precision = @intCast(mt.unit_exp - @as(i32, std.math.log10_int(@as(u64, mt.scale.local_per_unit)))),
            .decl = m,
            .def_name = try arena.dupe(u8, file.str(m.name)),
            .library = try arena.dupe(u8, file.str(r.hier.def_lib[info.def])),
            .config = if (cfg) |c| try arena.print("{s}.{s}", .{ file.str(r.hier.cfg_lib[c]), file.str(file.configs[c].name) }) else "",
            .path = path,
            .parent = .of(parent),
            .engine = @intCast(e),
        });
        if (parent) |p| try scopes.items[p].children.append(gpa, .at(at));
    }
    std.debug.assert(scopes.items.len == n_scopes);

    var objects: Rows = .{ .gpa = model_gpa };
    defer objects.deinit();
    for (scopes.items, 0..) |s, i| try objects.append(.{
        .kind = .module,
        .owner = s.parent,
        .scope = @intCast(i),
        .name = if (i == 0) top_name else model.lastComponent(s.path),
        .full = try model.joinPath(arena, top_name, s.path),
    });

    for (scopes.items, 0..) |*s, i| {
        const scope: u32 = @intCast(i);
        const eng = s.engine;
        const m = s.decl;
        for (m.ports, 0..) |p, k| {
            if (p.name == .none) continue; // IEEE 1364-2005 A.1.3 a null port names no net
            const at = r.hier.names.get(.{ .scope = eng, .str = p.name });
            try s.ports.append(gpa, objects.next());
            var o = try digitalObj(r, arena, top_name, s.path, scope, p.name, .port, at);
            o.direction = p.direction;
            o.port_index = @intCast(k);
            o.src_tok = p.main_tok;
            try objects.append(o);
        }
        for (m.nets) |n| {
            const at = r.hier.names.get(.{ .scope = eng, .str = n.name }) orelse continue;
            // IEEE 1364-2005 §26.6.6: a net array, over the engine's element
            // slots, each element a net of the declared type.
            if (r.decls.arrays.get(at)) |a| {
                const local = try arena.dupe(u8, file.str(n.name));
                const arr = try model_arrays.addArray(arena, &objects, .net_array, scope, local, try model.joinPath(arena, top_name, try model.joinPath(arena, s.path, local)), .unspecified, a.low, a.high, a.rest, r.values[at].width, at);
                for (objects.coldOf(arr).members) |e| {
                    objects.at(e).net_type = n.kind;
                    objects.at(e).src_tok = n.main_tok;
                }
                const range = try arena.dupe(ObjId, &.{try model_arrays.addRange(arena, &objects, scope, a.left, a.right)});
                (try objects.coldFor(arr)).range = range;
                objects.at(arr).src_tok = n.main_tok;
                try s.net_arrays.append(gpa, arr);
                continue;
            }
            try s.nets.append(gpa, objects.next());
            var o = try digitalObj(r, arena, top_name, s.path, scope, n.name, .net, at);
            o.net_type = n.kind;
            o.src_tok = n.main_tok;
            try objects.append(o);
            try addBits(arena, &objects, r, user.vpiNetBit);
        }
        // The implicit nets: a port declared with no net type (IEEE 1364-2005
        // §12.3.3), then §4.5's undeclared terminals and assignment targets,
        // in the order the engine declared them.
        // The slots `s` already has a net object for, so each name below
        // is one lookup rather than a scan of the scope's nets.
        var have: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer have.deinit(gpa);
        for (s.nets.items) |n| if (objects.at(n).slot.get()) |slot| try have.put(gpa, slot, {});
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
            const at = r.hier.names.get(.{ .scope = eng, .str = v.name }) orelse continue;
            // §3.9 arrays: §11.6.11's classes, over the engine's own element
            // slots.
            if (r.decls.arrays.get(at)) |a| {
                const is_reg = v.storage == .reg;
                const local = try arena.dupe(u8, file.str(v.name));
                // §26.6.7: a `real` array is a vpiRealVar with vpiArray set,
                // one of the scope's reals — as the analog model builds it.
                const real = !is_reg and v.ty == .real;
                const arr = try model_arrays.addArray(arena, &objects, if (is_reg) .reg_array else .var_array, scope, local, try model.joinPath(arena, top_name, try model.joinPath(arena, s.path, local)), if (real) .real else .integer, a.low, a.high, a.rest, r.values[at].width, at);
                // Two statements: addRange grows `objects`, moving `items`.
                const range = try arena.dupe(ObjId, &.{try model_arrays.addRange(arena, &objects, scope, a.left, a.right)});
                (try objects.coldFor(arr)).range = range;
                objects.at(arr).src_tok = v.main_tok;
                try (if (is_reg) &s.reg_arrays else if (real) &s.reals else &s.integers).append(gpa, arr);
                if (!is_reg) try s.variables.append(gpa, arr);
                continue;
            }
            const kind: Kind = if (v.storage == .reg) .reg else if (v.storage == .time) .time_var else if (v.ty == .integer) .integer else if (v.ty == .real) .real_var else continue;
            if (kind != .reg) try s.variables.append(gpa, objects.next());
            // A time variable is in neither per-type list: its type is its own.
            if (kind != .time_var) try (if (kind == .reg) &s.regs else if (kind == .real_var) &s.reals else &s.integers).append(gpa, objects.next());
            var o = try digitalObj(r, arena, top_name, s.path, scope, v.name, kind, at);
            // IEEE 1364-2005 §4.8: `time` is unsigned, `integer` signed.
            o.is_signed = kind != .time_var and (v.is_signed or kind == .integer);
            o.src_tok = v.main_tok;
            try objects.append(o);
            if (kind == .reg) try addBits(arena, &objects, r, user.vpiRegBit);
        }
        // §11.6.12 parameters. The engine folds each into a slot of its own
        // (IEEE 1364 §12.2, `Run.decls.params`), so NOTE 1's "final value of the
        // parameter after all module instantiation overrides and defparams
        // have been resolved" is that slot, read like any other value.
        for (m.params) |p| {
            const at = r.hier.names.get(.{ .scope = eng, .str = p.name }) orelse continue;
            if (!r.decls.params.contains(at)) continue;
            try s.params.append(gpa, objects.next());
            var o = try digitalObj(r, arena, top_name, s.path, scope, p.name, .parameter, at);
            o.ty = p.ty;
            o.is_local = p.is_local;
            o.src_tok = p.main_tok;
            try objects.append(o);
        }
    }
    try model_arrays.addModuleArrays(gpa, arena, &objects, scopes.items, top_name);
    try addGenScopes(gpa, arena, &objects, scopes.items, r, vpi_of);
    // §11.6.3/§11.6.16–§11.6.24, over each instance's own definition: the
    // engine ran these same bodies, one copy per instance.
    var udps: std.AutoHashMapUnmanaged(Ast.StrId, ObjId) = .empty;
    defer udps.deinit(gpa);
    var attrs: ByOwner = try .init(gpa, file);
    defer attrs.deinit(gpa);
    const udp_defns = try udp.udpDefns(gpa, arena, &objects, file, &attrs, &udps);
    var names = try model.nameTable(gpa, objects.hot.items);
    defer names.deinit(gpa);
    var decls = try model.decls(gpa, objects.hot.items, scopes.items.len);
    defer decls.deinit(gpa);
    for (scopes.items, 0..) |*s, i| {
        var b: Builder = .{ .gpa = gpa, .arena = arena, .objects = &objects, .file = file, .names = &names, .top_name = top_name, .scope = @intCast(i), .path = s.path, .lists = &s.code, .udps = &udps, .run = r, .engine = s.engine, .attrs = &attrs };
        for (decls.of(i)) |at|
            try b.attributes(.at(at), .{ .kind = .declaration, .tok = objects.at(.at(at)).src_tok }, false);
        try b.module(s.decl);
        try addConnections(&b, scopes.items, r);
    }
    try model.freeze(&d, &objects, scopes.items);
    d.udp_defns = udp_defns;
    d.finest = @intCast(r.time.finest);
    d.search_up = false;
    d.file = file;
    std.debug.assert(d.top_modules.len == 1);
    return d;
}

// ---- private ----

/// IEEE 1364-2005 §26.6.2/§26.6.5/§26.6.12, built in scope `b.scope`, whose
/// expressions the connections are: each parameter's declared range
/// (vpiLeftRange/vpiRightRange, NULL without one, Details c), and for each
/// child instance its ports' vpiHighConn and vpiConnByName and one param
/// assign per `#(...)` entry; an instance array's range and its connection
/// list as one vpiListOp operation.
///
/// ponytail: only instances written directly in the module body; one inside
/// a generate block has none of these (its `Ast.Instance` is the block's).
///
/// Asserts that `b` builds one of `scopes` at module level, and that each
/// instance's chain of child scopes ends.
fn addConnections(b: *Builder, scopes: []Building, r: *const sim.digital.Run) Error!void {
    std.debug.assert(b.scope < scopes.len);
    std.debug.assert(b.inner == ObjId.none);
    const s = &scopes[b.scope];
    const m = s.decl;
    const file = b.file;
    for (s.params.items) |at| {
        const p = for (m.params) |p| {
            if (std.mem.eql(u8, file.str(p.name), b.objects.at(at).name)) break p;
        } else continue;
        const range = p.packed_range orelse Ast.Dim{ .msb = .none, .lsb = .none };
        const l = try b.expr(range.msb);
        const rr = try b.expr(range.lsb);
        b.objects.at(at).edges = try b.arena.dupe(Edge, &.{ .{ .tag = user.vpiLeftRange, .to = l }, .{ .tag = user.vpiRightRange, .to = rr } });
    }
    // The child scopes each instance name made, in child order: `next`
    // chains the positions in `s.children` that share a name, from `heads`.
    const end: u32 = std.math.maxInt(u32); // `next` past a name's last
    var heads: std.AutoHashMapUnmanaged(Ast.StrId, u32) = .empty;
    defer heads.deinit(b.gpa);
    const next = try b.gpa.alloc(u32, s.children.items.len);
    defer b.gpa.free(next);
    var pos = s.children.items.len;
    while (pos > 0) {
        std.debug.assert(pos <= next.len);
        pos -= 1;
        const g = try heads.getOrPut(b.gpa, r.hier.scopes.items[scopes[s.children.items[pos].index()].engine].name);
        next[pos] = if (g.found_existing) g.value_ptr.* else end;
        g.value_ptr.* = @intCast(pos);
    }
    for (m.instances) |*inst| {
        if (inst.range) |range| for (s.module_arrays.items) |at| {
            if (!std.mem.eql(u8, b.objects.at(at).name, file.str(inst.name))) continue;
            const conns = try b.gpa.alloc(Ast.ExprId, inst.ports.len);
            defer b.gpa.free(conns);
            for (inst.ports, conns) |c, *e| e.* = c.expr;
            const l = try b.expr(range.msb);
            const rr = try b.expr(range.lsb);
            const list = try b.operation(user.vpiListOp, conns);
            b.objects.at(at).edges = try b.arena.dupe(Edge, &.{
                .{ .tag = user.vpiLeftRange, .to = l },
                .{ .tag = user.vpiRightRange, .to = rr },
                .{ .tag = user.vpiExpr, .to = list },
            });
        };
        var made = heads.get(inst.name) orelse end;
        var steps: usize = 0;
        while (made != end) : (made = next[made]) {
            std.debug.assert(steps < next.len);
            steps += 1;
            const c = s.children.items[made];
            try b.attributes(c, .{ .kind = .declaration, .tok = inst.main_tok }, false);
            const child = scopes[c.index()].decl;
            const named = inst.ports.len != 0 and inst.ports[0].name != .none;
            for (scopes[c.index()].ports.items) |pt| b.objects.at(pt).props = try b.arena.dupe(Prop, &.{.{ .prop = user.vpiConnByName, .value = @intFromBool(named) }});
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
                b.objects.at(scopes[c.index()].ports.items[j]).edges = try b.arena.dupe(Edge, &.{.{ .tag = user.vpiHighConn, .to = high }});
                try b.attributes(scopes[c.index()].ports.items[j], .{ .kind = .declaration, .tok = conn.main_tok }, false);
            }
            for (inst.params, 0..) |o, k| {
                // §12.2.2.1: in order, the k-th parameter that is not local.
                var ordinal: usize = 0;
                const name = for (child.params) |p| {
                    if (p.is_local) continue;
                    if (if (o.name != .none) p.name == o.name else ordinal == k) break p.name;
                    ordinal += 1;
                } else continue;
                const lhs = for (scopes[c.index()].params.items) |at| {
                    if (std.mem.eql(u8, b.objects.at(at).name, file.str(name))) break at;
                } else ObjId.none;
                const rhs = try b.expr(o.value);
                const at = try b.code(user.vpiParamAssign, &.{ .{ .tag = user.vpiLhs, .to = lhs }, .{ .tag = user.vpiRhs, .to = rhs } }, &.{}, &.{.{ .prop = user.vpiConnByName, .value = @intFromBool(o.name != .none) }});
                b.objects.at(at).owner = c;
                try scopes[c.index()].code.param_assigns.append(b.gpa, at);
            }
        }
    }
}

/// `name`, when it denotes a net of the engine that no net object of `s`
/// holds yet (`have`, the slots of `s`'s nets): that net, added to `s`'s
/// nets and to `have`. Asserts that `scope` is a module row already made,
/// and that a net added is an implicit one `have` now holds.
fn implicitNet(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    r: *const sim.digital.Run,
    objects: *Rows,
    s: *Building,
    have: *std.AutoHashMapUnmanaged(u32, void),
    scope: u32,
    top_name: []const u8,
    name: Ast.StrId,
) Error!void {
    std.debug.assert(scope < objects.hot.items.len);
    const at = r.hier.names.get(.{ .scope = s.engine, .str = name }) orelse return;
    if (!r.netlist.slot_nets.contains(at)) return;
    if ((try have.getOrPut(gpa, at)).found_existing) return;
    try s.nets.append(gpa, objects.next());
    var o = try digitalObj(r, arena, top_name, s.path, scope, name, .net, at);
    o.implicit = true;
    try objects.append(o);
    std.debug.assert(have.contains(at));
}

/// One declared name of `scope`, bound to the slot `at` that stores it.
/// Asserts that `at` is one of the run's slots and the full name is under
/// the top's.
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
    std.debug.assert(at == null or at.? < r.values.len);
    const local = try arena.dupe(u8, r.file.str(name));
    const full = try model.joinPath(arena, top_name, try model.joinPath(arena, path, local));
    std.debug.assert(std.mem.startsWith(u8, full, top_name));
    return .{
        .kind = kind,
        .owner = .of(scope),
        .name = local,
        .full = full,
        .size = if (at) |a| r.values[a].width else 1,
        .slot = .of(at),
    };
}

/// One `scope_info` row's path component: its name, and `[k]` for an
/// instance array element or a loop-generate iteration (§12.4.1). Asserts
/// that the row is named and the component begins with its name.
fn pathComponent(arena: std.mem.Allocator, file: *const Ast.SourceFile, info: anytype) Error![]const u8 {
    std.debug.assert(info.name != .none);
    const name = file.str(info.name);
    const out = if (info.index) |k| try arena.print("{s}[{d}]", .{ name, k }) else try arena.dupe(u8, name);
    std.debug.assert(std.mem.startsWith(u8, out, name));
    return out;
}

/// `model.addBits` over the engine's declared range of the vector last
/// appended (`Run.vecRange`); a row without an engine slot gets none.
/// Asserts that a row was appended and its slot is the run's.
fn addBits(arena: std.mem.Allocator, objects: *Rows, r: *const sim.digital.Run, vtype: c_int) Error!void {
    std.debug.assert(objects.hot.items.len != 0);
    const slot = objects.at(.at(objects.hot.items.len - 1)).slot.get() orelse return;
    std.debug.assert(slot < r.values.len);
    const range = r.vecRange(slot);
    try model_arrays.addBits(arena, objects, range.msb, range.lsb, vtype);
}

/// IEEE 1364-2005 §26.6.44: each §12.4.1 loop generate directly inside an
/// instance is a gen scope array over its iterations, each a gen scope named
/// `name[i]` whose vpiIndex is `i`. Each scope exposes its scalar and vector
/// nets, which link back through vpiScope while keeping their module owner.
///
/// ponytail: a loop generate nested in another generate block, and a
/// conditional generate's scope, have no gen scope yet; both are rows of
/// `Run.hier.scopes` whose parent is itself lexical. Net arrays and other
/// declarations within a gen scope are not modelled yet.
///
/// Asserts that `vpi_of` maps every engine scope, and that each group's
/// instance is one of `scopes`.
fn addGenScopes(gpa: std.mem.Allocator, arena: std.mem.Allocator, objects: *Rows, scopes: []Building, r: *sim.digital.Run, vpi_of: []const u32) Error!void {
    std.debug.assert(vpi_of.len == r.hier.scopes.items.len);
    const Key = struct { scope: u32, name: Ast.StrId };
    var groups: std.array_hash_map.Auto(Key, std.ArrayList(u32)) = .empty;
    defer {
        for (groups.values()) |*v| v.deinit(gpa);
        groups.deinit(gpa);
    }
    for (r.hier.scopes.items, 0..) |info, e| {
        // An instance array element has an index too, but is no lexical row.
        if (!info.lexical or info.index == null or r.hier.scopes.items[info.parent].lexical) continue;
        const g = try groups.getOrPut(gpa, .{ .scope = vpi_of[info.parent], .name = info.name });
        if (!g.found_existing) g.value_ptr.* = .empty;
        try g.value_ptr.append(gpa, @intCast(e));
    }
    for (groups.keys(), groups.values()) |k, rows| {
        std.debug.assert(k.scope < scopes.len);
        const module_full = objects.at(.at(k.scope)).full;
        const name = try arena.dupe(u8, r.file.str(k.name));
        const members = try arena.alloc(ObjId, rows.items.len);
        for (rows.items, members) |e, *m| {
            const i = r.hier.scopes.items[e].index.?;
            const c = objects.next();
            try objects.append(.{ .kind = .constant, .owner = .of(k.scope), .name = "", .full = "", .size = 32, .value = .{ .int = i } });
            const local = try arena.print("{s}[{d}]", .{ name, i });
            const full = try model.joinPath(arena, module_full, local);
            m.* = objects.next();
            try objects.append(.{
                .kind = .code,
                .vtype = user.vpiGenScope,
                .owner = .of(k.scope),
                .name = local,
                .full = full,
                .edges = try arena.dupe(Edge, &.{.{ .tag = user.vpiIndex, .to = c }}),
                .props = try arena.dupe(Prop, &.{
                    .{ .prop = user.vpiArray, .value = 1 },
                    .{ .prop = user.vpiProtected, .value = 0 },
                    .{ .prop = user.vpiImplicitDecl, .value = @intFromBool(r.hier.scopes.items[e].implicit) },
                }),
            });
            const gen_nets = r.decls.gen_nets.get(e) orelse &.{};
            // At most one per generated net.
            var nets: std.ArrayList(ObjId) = try .initCapacity(arena, gen_nets.len);
            for (gen_nets) |n| {
                const slot = r.hier.names.get(.{ .scope = e, .str = n.name }) orelse continue;
                if (r.decls.arrays.contains(slot)) continue;
                const net_name = try arena.dupe(u8, r.file.str(n.name));
                nets.appendAssumeCapacity(objects.next());
                try objects.appendCold(.{
                    .kind = .net,
                    .owner = .of(k.scope),
                    .name = net_name,
                    .full = try model.joinPath(arena, full, net_name),
                    .size = r.values[slot].width,
                    .slot = .of(slot),
                    .net_type = n.kind,
                    .src_tok = n.main_tok,
                    .edges = try arena.dupe(Edge, &.{.{ .tag = user.vpiScope, .to = m.* }}),
                }, .{ .src_engine = e });
                try addBits(arena, objects, r, user.vpiNetBit);
            }
            objects.at(m.*).lists = try arena.dupe(List, &.{.{ .tag = user.vpiNet, .items = nets.items }});
        }
        const at = objects.next();
        try objects.append(.{
            .kind = .code,
            .vtype = user.vpiGenScopeArray,
            .owner = .of(k.scope),
            .name = name,
            .full = try model.joinPath(arena, module_full, name),
            .props = try arena.dupe(Prop, &.{.{ .prop = user.vpiSize, .value = @intCast(members.len) }}),
            .lists = try arena.dupe(List, &.{.{ .tag = user.vpiGenScope, .items = members }}),
        });
        try scopes[k.scope].code.gen_arrays.append(gpa, at);
    }
}
