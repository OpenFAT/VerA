//! The analog model: a `vera.Result` (an elaborated, flattened design) ->
//! a `Design`. The scope tree is elaboration's (`Result.unit_paths`), a
//! flat declaration belongs to the scope its §6.7 path names, and the analog
//! classes (model_branches.zig) and behaviour (§11.6.20/§11.6.21) come after
//! the declarations. Everything is copied into `Design.arena`, so the
//! compilation may be freed once `build` returns.
//! Cites: VAMS-2023 §3.4.5, §3.6.3, §6.7, §11.6.1-§11.6.12, §11.6.20,
//! §11.6.21; IEEE 1364-2005 §26.3.3.
//!
//! Contents:
//! - `pub fn build(model_gpa: std.mem.Allocator, res: *const Result) Error!Design`
//! - `pub fn splitPath( arena: std.mem.Allocator, by_path: *const std.StringHashMapUnmanaged(u32), flat: []const u8, ) Error!?struct`

const std = @import("std");
const Ast = @import("frontend").Ast;
const Result = @import("vera").Result;
const elab = @import("elab");
const Lowered = @import("ir").Lowered;
const model = @import("model.zig");
const model_arrays = @import("model_arrays.zig");
const model_branches = @import("model_branches.zig");
const schema = @import("schema.zig");
const ObjId = schema.ObjId;
const user = @import("vpi_user.zig");
const Builder = @import("Builder.zig");
const Design = @import("Design.zig");
const attribute = @import("attribute.zig");
const session = @import("session.zig");
const Building = model.Building;
const ByOwner = attribute.ByOwner;
const Error = session.Error;
const Loc = schema.Loc;
const Rows = model.Rows;

/// Builds the analog model over `res`, whose `module` must be the
/// elaborated top (`error.NotElaborated` otherwise). The returned `Design`
/// owns every string and slice it reports (`Design.arena`); `res` may be
/// freed once this returns. Caller owns the result and frees it with
/// `Design.deinit`. `model_gpa` holds the `Design`'s tables. Asserts that
/// every unit became one scope, and the model has the one top.
pub fn build(model_gpa: std.mem.Allocator, res: *const Result) Error!Design {
    const lowered = res.lowered;
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

    const file = res.file;
    const flat = res.module orelse return error.NotElaborated;
    const top_name = try arena.dupe(u8, file.str(flat.name));

    // --- the scope tree ----------------------------------------------------
    // §11.6.1's `vpiInternalScope`, read from elaboration rather than walked
    // again: `Result.unit_paths` is one row per inlined instance, depth first
    // in source order, with the definition it came from (`vpiDefName`).
    // Instance arrays, §6.4.2 paramsets and Annex E.2.1 were decided there. A
    // tree of one publishes no rows, so it is its own single row.
    const units = res.unit_paths;
    const n_units = @max(units.len, 1);
    var scopes: std.ArrayList(Building) = try .initCapacity(gpa, n_units);
    defer {
        for (scopes.items) |*s| s.deinit(gpa);
        scopes.deinit(gpa);
    }
    // A path → scope index table: a unit finds its parent by it, and bucketing
    // the flattened declarations costs a lookup per declaration.
    var by_path: std.StringHashMapUnmanaged(u32) = .empty;
    defer by_path.deinit(gpa);
    for (0..n_units) |i| {
        const u_path = if (units.len != 0) units.items(.path)[i] else "";
        const u_module = if (units.len != 0) file.str(units.items(.module)[i]) else top_name;
        const u_decl = if (units.len != 0) units.items(.decl)[i].get(file) else flat;
        const path = try arena.dupe(u8, std.mem.trimEnd(u8, u_path, &.{elab.sep}));
        const at: u32 = @intCast(i);
        // Rows come parent first, so the parent is already in the table. Unit 0
        // is the top, whose path is "".
        const parent: ?u32 = if (i == 0) null else by_path.get(path[0 .. std.mem.findScalarLast(u8, path, elab.sep) orelse 0]).?;
        scopes.appendAssumeCapacity(.{
            .decl = u_decl,
            .def_name = try arena.dupe(u8, u_module),
            .path = path,
            .parent = .of(parent),
        });
        if (parent) |p| try scopes.items[p].children.append(gpa, .at(at));
        try by_path.put(gpa, path, at);
    }
    std.debug.assert(scopes.items.len == n_units);

    // --- the objects -------------------------------------------------------
    var objects: Rows = .{ .gpa = model_gpa };
    defer objects.deinit();

    // Modules FIRST and in scope order: that is the `Scope` invariant, and it
    // is what lets an object's `owner` scope index double as its owner's
    // object index.
    for (scopes.items, 0..) |s, i| try objects.append(.{
        .kind = .module,
        .owner = s.parent,
        .scope = @intCast(i),
        .name = if (i == 0) top_name else model.lastComponent(s.path),
        .full = try model.joinPath(arena, top_name, s.path),
    });

    // §11.6.4 ports. Read from the DEFINITION, not from the flattened module:
    // flattening collapses a child's port into the parent net it was bound to
    // (`elab.Design.names`), so the flat module holds only the top's ports
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
            const path = try model.joinPath(arena, s.path, local);
            const node = lowered.hier_names.get(path) orelse path;
            s.ports.appendAssumeCapacity(objects.next());
            try objects.append(.{
                .kind = .port,
                .owner = .of(@intCast(i)),
                .name = local,
                .full = try model.joinPath(arena, top_name, path),
                .size = vectorSize(lowered, node),
                .direction = p.direction,
                .port_index = @intCast(k),
                .src_tok = p.main_tok,
            });
        }
    }

    // §11.6.8/§11.6.9/§11.6.12 — the contents of every scope, from the
    // ELABORATED module. Each flat name is its own §6.7 path, so the scope it
    // belongs to is the part before the last `elab.sep` and the `vpiName`
    // is the part after. A declaration whose path names no scope is dropped
    // rather than guessed at; nothing a flatten produces has one, and inventing
    // a scope for it would be inventing hierarchy.
    for (flat.nets) |n| {
        const flat_name = file.str(n.name);
        const split = (try splitPath(arena, &by_path, flat_name)) orelse continue;
        // §3.6.3's range as lowering folded it (`vectorSize`'s source); a
        // scalar is `[0:0]`, whose bit set is empty.
        const range = lowered.vectors.get(flat_name) orelse Lowered.VecRange{ .msb = 0, .lsb = 0 };
        try scopes.items[split.scope].nets.append(gpa, objects.next());
        try objects.append(.{
            .kind = .net,
            .owner = .of(split.scope),
            .name = split.local,
            .full = try model.joinPath(arena, top_name, flat_name),
            .size = range.size(),
            .net_type = n.kind,
            .src_tok = n.main_tok,
        });
        // IEEE 1364-2005 §26.6.6 Details a: the vector's bits, `bus[0]`..,
        // reached by vpiBit and §12.20's vpi_handle_by_index.
        try model_arrays.addBits(arena, &objects, range.msb, range.lsb, user.vpiNetBit);
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
            const at = try model_arrays.addArray(arena, &objects, if (is_reg) .reg_array else .var_array, split.scope, split.local, try model.joinPath(arena, top_name, flat_name), if (is_reg) .integer else v.ty, dim.low, dim.high, &.{}, if (is_reg) packedWidth(file, v) else if (v.ty == .real) 64 else 32, null);
            objects.at(at).src_tok = v.main_tok;
            const list = if (is_reg) &scopes.items[split.scope].reg_arrays else if (v.ty == .real) &scopes.items[split.scope].reals else &scopes.items[split.scope].integers;
            try list.append(gpa, at);
            if (!is_reg) try scopes.items[split.scope].variables.append(gpa, at);
            continue;
        }
        if (v.dims.len != 0) continue;
        if (v.storage == .variable and (v.ty == .real or v.ty == .integer)) {
            const list = if (v.ty == .real) &scopes.items[split.scope].reals else &scopes.items[split.scope].integers;
            try list.append(gpa, objects.next());
            try scopes.items[split.scope].variables.append(gpa, objects.next());
            try objects.append(.{
                .kind = if (v.ty == .real) .real_var else .integer,
                .owner = .of(split.scope),
                .name = split.local,
                .full = try model.joinPath(arena, top_name, flat_name),
                .size = if (v.ty == .real) 64 else 32,
                .ty = v.ty,
                .src_tok = v.main_tok,
            });
            continue;
        }
        if (v.storage != .reg) continue;
        try scopes.items[split.scope].regs.append(gpa, objects.next());
        try objects.append(.{
            .kind = .reg,
            .owner = .of(split.scope),
            .name = split.local,
            .full = try model.joinPath(arena, top_name, flat_name),
            .size = packedWidth(file, v),
            .is_signed = v.is_signed,
            .src_tok = v.main_tok,
        });
    }
    for (flat.params) |p| {
        const flat_name = file.str(p.name);
        const split = (try splitPath(arena, &by_path, flat_name)) orelse continue;
        try scopes.items[split.scope].params.append(gpa, objects.next());
        try objects.append(.{
            .kind = .parameter,
            .owner = .of(split.scope),
            .name = split.local,
            .full = try model.joinPath(arena, top_name, flat_name),
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
    const analog = try model_branches.addAnalog(gpa, arena, &objects, scopes.items, &by_path, res, top_name);
    try model_arrays.addModuleArrays(gpa, arena, &objects, scopes.items, top_name);
    try addAnalogCode(gpa, arena, &objects, scopes.items, res, top_name);

    try model.freeze(&d, &objects, scopes.items);
    d.disciplines = analog.disciplines;
    d.natures = analog.natures;
    std.debug.assert(d.top_modules.len == 1);
    return d;
}

/// Split a flattened declaration's name into the scope it belongs to and the
/// §11.6 `vpiName` inside it.
///
/// The last `elab.sep` is the split, and that is exact rather than a
/// heuristic: §6.6 generate blocks add no path component in this compiler (they
/// unroll inside a body, not into the declaration space), and `parser.internTok`
/// substitutes a space for a period inside a §2.8.1 escaped identifier — so a
/// period in a flattened name IS a join.
/// `tests/conformance/tests/verilog-a/ch06_hierarchy/escaped_period_is_not_a_path.va` is the
/// fixture on that substitution. Asserts that `flat` is a name, and that a
/// split finds one of the table's scopes and keeps the name's last part.
pub fn splitPath(
    arena: std.mem.Allocator,
    by_path: *const std.StringHashMapUnmanaged(u32),
    flat: []const u8,
) Error!?struct { scope: u32, local: []const u8 } {
    std.debug.assert(flat.len != 0);
    const at = std.mem.findScalarLast(u8, flat, elab.sep);
    const path = if (at) |i| flat[0..i] else "";
    const scope = by_path.get(path) orelse return null;
    std.debug.assert(scope < by_path.count());
    return .{ .scope = scope, .local = try arena.dupe(u8, if (at) |i| flat[i + 1 ..] else flat) };
}

// ---- private ----

/// §11.6.20/§11.6.21 the analog model's behaviour: each flattened `analog`
/// block, in the scope of the instance that wrote it, with its statements,
/// contributions and expressions. Asserts that every scope's module row is
/// made, and that each instance's chain of child scopes ends.
fn addAnalogCode(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    objects: *Rows,
    scopes: []Building,
    res: *const Result,
    top_name: []const u8,
) Error!void {
    std.debug.assert(scopes.len <= objects.hot.items.len);
    const lowered = res.lowered;
    const flat = res.module.?;
    var an: Builder.Analog = .{ .lowered = lowered };
    defer an.branches.deinit(gpa);
    defer an.flow_access.deinit(gpa);
    for (objects.hot.items, 0..) |o, i| switch (o.kind) {
        // Keyed by the declared name a statement spells; an unnamed branch
        // (§5.4.2) has none, and a statement reaches it by its node pair.
        .branch => if (o.full.len > top_name.len) try an.branches.put(gpa, o.full[top_name.len + 1 ..], .at(i)),
        .discipline => if (lowered.disciplines.get(o.name)) |info| try an.flow_access.put(gpa, .at(i), info.flow_access),
        .module, .port, .net, .reg, .parameter, .integer, .real_var, .time_var, .reg_array, .var_array, .net_array, .word, .var_select, .module_array, .constant, .nature, .node, .quantity, .code => {},
    };
    var names = try model.nameTable(gpa, objects.hot.items);
    defer names.deinit(gpa);
    var decls = try model.decls(gpa, objects.hot.items, scopes.len);
    defer decls.deinit(gpa);
    var attrs: ByOwner = try .init(gpa, res.file);
    defer attrs.deinit(gpa);
    for (scopes, 0..) |*s, i| {
        var b: Builder = .{ .gpa = gpa, .arena = arena, .objects = objects, .file = res.file, .names = &names, .top_name = top_name, .scope = @intCast(i), .path = s.path, .lists = &s.code, .analog = &an, .attrs = &attrs };
        try b.attributes(.at(i), .{ .kind = .declaration, .tok = s.decl.main_tok }, true);
        for (decls.of(i)) |at|
            try b.attributes(.at(at), .{ .kind = .declaration, .tok = objects.at(.at(at)).src_tok }, false);
        // The child scopes each instance name made, in child order: `next`
        // chains the positions in `s.children` that share a name.
        const end: u32 = std.math.maxInt(u32); // `next` past a name's last
        var heads: std.StringHashMapUnmanaged(u32) = .empty;
        defer heads.deinit(gpa);
        const next = try gpa.alloc(u32, s.children.items.len);
        defer gpa.free(next);
        var pos = s.children.items.len;
        while (pos > 0) {
            std.debug.assert(pos <= next.len);
            pos -= 1;
            const g = try heads.getOrPut(gpa, objects.at(s.children.items[pos]).name);
            next[pos] = if (g.found_existing) g.value_ptr.* else end;
            g.value_ptr.* = @intCast(pos);
        }
        for (s.decl.instances) |inst| {
            var made = heads.get(b.file.str(inst.name)) orelse end;
            var steps: usize = 0;
            while (made != end) : (made = next[made]) {
                std.debug.assert(steps < next.len);
                steps += 1;
                const child = s.children.items[made];
                // §11.6.1: the instance is where the module is USED
                // (IEEE 1364-2005 §26.3.3), the line `u1(...)` is written on.
                (try objects.coldFor(child)).loc = try srcLoc(arena, res, inst.main_tok);
                try b.attributes(child, .{ .kind = .declaration, .tok = inst.main_tok }, false);
                for (inst.ports, 0..) |conn, k| {
                    const pt = if (conn.name == .none) (if (k < scopes[child.index()].ports.items.len) scopes[child.index()].ports.items[k] else continue) else for (scopes[child.index()].ports.items) |p| {
                        if (std.mem.eql(u8, objects.at(p).name, b.file.str(conn.name))) break p;
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
///
/// Asserts that the line is 1-based and the copy spells the file's name.
fn srcLoc(arena: std.mem.Allocator, res: *const Result, tok: u32) Error!?Loc {
    const starts = res.lowered.tok_starts;
    if (tok >= starts.len) return null;
    var at = schema.locate(res.diags, starts[tok]);
    std.debug.assert(at.line >= 1);
    const name = at.file;
    at.file = try arena.dupe(u8, name);
    std.debug.assert(std.mem.eql(u8, at.file, name));
    return at;
}

/// §3.4.5 as the SOURCE wrote it: is `name` a `localparam` of `decl`? `null`
/// when `decl` declares no such parameter, which is the case for a parameter
/// elaboration synthesized rather than copied. Asserts that `name` is a
/// name of a named definition.
fn declaredLocal(decl: *const Ast.ModuleDecl, file: *const Ast.SourceFile, name: []const u8) ?bool {
    std.debug.assert(name.len != 0);
    std.debug.assert(decl.name != .none);
    for (decl.params) |p| {
        if (std.mem.eql(u8, file.str(p.name), name)) return p.is_local;
    }
    return null;
}

/// §3.6.3 a vector net is N nets, and §11.6.8's `vpiSize` is that N.
/// `Lowered.vectors` is the folded `[msb:lsb]` keyed by the flat name — the same
/// fold lowering scalarised the net with, so this cannot disagree with the
/// device's terminal count. A name absent from it is a scalar.
///
/// Asserts that `flat_name` is a name and its size at least one net.
fn vectorSize(lowered: *const Lowered, flat_name: []const u8) u32 {
    std.debug.assert(flat_name.len != 0);
    const n = if (lowered.vectors.get(flat_name)) |r| r.size() else 1;
    std.debug.assert(n >= 1);
    return n;
}

/// §11.6.9's `vpiSize` for a `reg [msb:lsb]`.
///
/// ponytail: literal bounds only (`Lowered.vectors` holds nets and ports, not
/// regs). A non-literal range returns 0, which `vpi_get(vpiSize, ...)` reports
/// as `vpiUndefined` plus an error. Upgrade path: lowering interns packed regs
/// into `vectors` as it does nets, and this function disappears.
///
/// Asserts that a folded width is positive and fits a `u32`.
fn packedWidth(file: *const Ast.SourceFile, v: Ast.VarDecl) u32 {
    const range = v.packed_range orelse return 1;
    if (file.exprs.tag(range.msb) != .int_literal or file.exprs.tag(range.lsb) != .int_literal) return 0;
    const hi = file.exprs.intValue(range.msb);
    const lo = file.exprs.intValue(range.lsb);
    if (hi < 0 or lo < 0) return 0;
    const w = @abs(hi - lo) + 1;
    std.debug.assert(w >= 1);
    std.debug.assert(w <= std.math.maxInt(u32));
    return @intCast(w);
}

/// A declared unpacked dimension, folded when both bounds are literal integers
/// — the same rule `packedWidth` applies. Null otherwise: the array is then
/// not modelled rather than modelled with a guessed size. Asserts that the
/// dimension has both bounds written.
fn literalDim(file: *const Ast.SourceFile, dim: Ast.Dim) ?struct { low: i64, high: i64 } {
    std.debug.assert(dim.msb != .none);
    std.debug.assert(dim.lsb != .none);
    if (file.exprs.tag(dim.msb) != .int_literal or file.exprs.tag(dim.lsb) != .int_literal) return null;
    const a = file.exprs.intValue(dim.msb);
    const b = file.exprs.intValue(dim.lsb);
    return .{ .low = @min(a, b), .high = @max(a, b) };
}
