//! A module's behavioural items -> `.code` rows: named events, tasks and
//! functions, continuous assignments, primitives, module paths, timing checks
//! and processes (§11.6.3, §11.6.13, §11.6.15, §11.6.17, §11.6.21), each in
//! the builder's scope, with the delays §12.11 reads.
//! Cites: VAMS-2023 §11.6.3, §11.6.13, §11.6.15, §11.6.17, §11.6.21; IEEE
//! 1364-2005 §6.1.3, §7.1, §7.8, §26.3.4, §26.6.11, §26.6.24; A.7.5.1.
//!
//! Contents:
//! - `pub fn eventDecls(b: *Builder, declarations: []const Ast.EventDecl) Error!Builder.Events`
//! - `pub fn module(b: *Builder, m: *const Ast.ModuleDecl) Error!void`
//! - `pub fn reserveModule(b: *Builder, m: *const Ast.ModuleDecl) Error!void`
//! - `pub fn analogBlocks(b: *Builder, blocks: []const Ast.AnalogBlock) Error!void`
//! - `pub fn primitive(b: *Builder, vtype: c_int, prim_type: c_int, terms: []const Ast.ExprId, dirs: []const c_int, props: []const Prop) Error!ObjId`
//! - `pub fn subIndex(tasks: []const Ast.Subroutine, k: usize) usize`
//! - `pub fn modPath(b: *Builder, p: Ast.SpecPath) Error!void`
//! - `pub fn timingCheck(b: *Builder, t: Ast.TimingCheck) Error!void`
//! - `pub fn term(b: *Builder, vtype: c_int, e: Ast.ExprId, dir_code: c_int, edge: Ast.SpecEdge) Error!ObjId`
//! - `pub fn delayListExpr(b: *Builder, es: []const Ast.ExprId) Error!ObjId`
//! - `pub fn foldAll(b: *Builder, es: []const Ast.ExprId) Error![]const f64`
//! - `pub fn delayExpr(b: *Builder, d: Ast.Delay3) Error!ObjId`
//! - `pub fn delays(b: *Builder, d: Ast.Delay3) Error![]const f64`

const std = @import("std");
const Ast = @import("frontend").Ast;
const sim = @import("sim");
const code_tables = @import("code_tables.zig");
const model_arrays = @import("model_arrays.zig");
const schema = @import("schema.zig");
const ObjId = schema.ObjId;
const user = @import("vpi_user.zig");
const Builder = @import("Builder.zig");
const session = @import("session.zig");
const Edge = schema.Edge;
const Error = session.Error;
const List = schema.List;
const Prop = schema.Prop;

/// IEEE 1364-2005 §26.6.11: declarations and persistent element
/// identities. Storage order is the engine's increasing row-major order;
/// vpiRange retains source direction, vpiIndex runs innermost first.
/// Asserts that this builder's engine scope is the run's, and that every
/// declaration became one scalar or one array event.
pub fn eventDecls(b: *Builder, declarations: []const Ast.EventDecl) Error!Builder.Events {
    if (b.run) |r| std.debug.assert(b.engine < r.hier.scopes.items.len);
    var n_arrays: usize = 0;
    for (declarations) |e| n_arrays += @intFromBool(e.dims.len != 0);
    var scalars: std.ArrayList(ObjId) = try .initCapacity(b.arena, declarations.len - n_arrays);
    var arrays: std.ArrayList(ObjId) = try .initCapacity(b.arena, n_arrays);
    for (declarations) |e| {
        const slot = if (b.run) |r| r.hier.names.get(.{ .scope = b.engine, .str = e.name }) else null;
        const scope: []const Edge = if (b.inner == ObjId.none) &.{} else &.{.{ .tag = user.vpiScope, .to = b.inner }};
        const auto_prop: Prop = .{ .prop = user.vpiAutomatic, .value = @intFromBool(b.automatic) };
        const at = try b.code(if (e.dims.len == 0) user.vpiNamedEvent else user.vpiNamedEventArray, scope, &.{.{ .tag = user.vpiIndex, .items = &.{} }}, if (e.dims.len == 0) &.{ .{ .prop = user.vpiArray, .value = 0 }, auto_prop } else &.{auto_prop});
        try b.setName(at, try b.arena.dupe(u8, b.file.str(e.name)));
        b.objects.at(at).src_tok = e.main_tok;
        b.objects.at(at).automatic = b.automatic;
        try b.attributes(at, .{ .kind = .declaration, .tok = e.main_tok }, false);
        if (e.dims.len == 0) {
            b.objects.at(at).slot = .of(if (b.automatic) null else slot);
            scalars.appendAssumeCapacity(at);
            continue;
        }
        arrays.appendAssumeCapacity(at);
        const base = slot orelse continue;
        const arr = b.run.?.decls.arrays.get(base).?;
        const ranges = try b.arena.alloc(ObjId, e.dims.len);
        ranges[0] = try model_arrays.addRange(b.arena, b.objects, b.scope, arr.left, arr.right);
        for (arr.rest, ranges[1..]) |sp, *range| range.* = try model_arrays.addRange(b.arena, b.objects, b.scope, if (sp.descending) sp.high else sp.low, if (sp.descending) sp.low else sp.high);
        const members = try b.arena.alloc(ObjId, arr.count);
        for (members, 0..) |*member, k| {
            const indices = try b.arena.alloc(ObjId, e.dims.len);
            var suffix: std.ArrayList(u8) = try .initCapacity(b.arena, indices.len * model_arrays.index_text_max);
            var q: i64 = @intCast(k);
            for (indices, 0..) |*index, j| {
                const d = indices.len - 1 - j;
                const sp: sim.digital.Span = if (d == 0) .{ .low = arr.low, .high = arr.high } else arr.rest[d - 1];
                const count = sp.high - sp.low + 1;
                const i = sp.low + @mod(q, count);
                q = @divTrunc(q, count);
                index.* = try b.constant(.{ .int = i }, 32, user.vpiDecConst);
                var buf: [model_arrays.index_text_max]u8 = undefined;
                suffix.insertSliceAssumeCapacity(0, std.mem.print(&buf, "[{d}]", .{i}) catch unreachable);
            }
            const local = try b.arena.print("{s}{s}", .{ b.file.str(e.name), suffix.items });
            member.* = try b.code(user.vpiNamedEvent, &.{ .{ .tag = user.vpiParent, .to = at }, .{ .tag = user.vpiIndex, .to = indices[0] } }, &.{.{ .tag = user.vpiIndex, .items = indices }}, &.{ .{ .prop = user.vpiArray, .value = 1 }, auto_prop });
            if (scope.len != 0) b.objects.at(member.*).edges = try b.arena.dupe(Edge, &.{ b.objects.at(member.*).edges[0], b.objects.at(member.*).edges[1], scope[0] });
            try b.setName(member.*, local);
            b.objects.at(member.*).index = indices[0];
            b.objects.at(member.*).automatic = b.automatic;
            b.objects.at(member.*).slot = .of(if (b.automatic) null else base + @as(u32, @intCast(k)));
        }
        const cold = try b.objects.coldFor(at);
        cold.members = members;
        cold.range = ranges;
        b.objects.at(at).lists = try b.arena.dupe(List, &.{ .{ .tag = user.vpiNamedEvent, .items = members }, .{ .tag = user.vpiRange, .items = ranges } });
    }
    std.debug.assert(scalars.items.len + arrays.items.len == declarations.len);
    return .{ .scalars = scalars.items, .arrays = arrays.items };
}

/// The behavioural contents of one digital module instance: its named
/// events, tasks and functions, continuous assignments and processes.
/// Asserts that the scope's row is its module's, and that every entered
/// subroutine was left again (the builder is back at module level).
pub fn module(b: *Builder, m: *const Ast.ModuleDecl) Error!void {
    std.debug.assert(b.objects.at(.at(b.scope)).kind == .module);
    const path = b.path;
    try b.attributes(.at(b.scope), .{ .kind = .declaration, .tok = m.main_tok }, true);
    try b.reserveModule(m);
    const events = try b.eventDecls(m.events);
    try b.lists.events.appendSlice(b.gpa, events.scalars);
    try b.lists.event_arrays.appendSlice(b.gpa, events.arrays);
    // §11.6.3 task and function, before any statement that calls one.
    for (m.tasks) |*t| {
        const at = try b.add(.{ .kind = .code, .owner = .of(b.scope), .name = "", .full = "", .vtype = if (t.is_function) user.vpiFunction else user.vpiTask });
        try b.setName(at, try b.arena.dupe(u8, b.file.str(t.name)));
        (if (t.is_function) &b.lists.functions else &b.lists.tasks).appendAssumeCapacity(at);
        // §26.6.18/§26.6.19: publish all function types before building
        // any body, including calls of a later-declared function.
        const frame = b.subFrame(t);
        if (t.is_function) b.objects.at(at).props = try b.arena.dupe(Prop, &.{
            .{ .prop = user.vpiSize, .value = b.declWidth(t.result, if (frame) |fr| fr.result else null) },
            .{ .prop = user.vpiSigned, .value = @intFromBool(t.result.is_signed) },
            .{ .prop = user.vpiFuncType, .value = code_tables.funcType(t.result) },
        });
    }
    for (m.tasks, 0..) |*t, k| {
        const at = (if (t.is_function) b.lists.functions.items else b.lists.tasks.items)[subIndex(m.tasks, k)];
        // A prefix on the declaration is in the containing scope;
        // only its formals/body see the subroutine's local parameters.
        try b.attributes(at, .{ .kind = .declaration, .tok = t.main_tok }, false);
        var inner: std.ArrayList(ObjId) = .empty;
        defer inner.deinit(b.gpa);
        const saved = try b.enter(at, b.objects.at(at).name, &inner);
        b.automatic = t.automatic;
        const frame = b.subFrame(t);
        if (frame) |fr| b.engine = fr.scope;
        const local_events = try b.eventDecls(t.events);
        var vars = try b.subVars(t);
        if (t.is_function) _ = try b.subVar(&vars, t.result, if (frame) |fr| fr.result else null, t.automatic);
        const ios = try b.arena.alloc(ObjId, t.ports.len);
        for (t.ports, ios, 0..) |p, *io, i| {
            const slot = if (frame) |fr| fr.ports[i] else null;
            const formal = try b.subVar(&vars, p.v, slot, t.automatic);
            const local = try b.arena.dupe(u8, b.file.str(p.v.name));
            io.* = try b.add(.{
                .kind = .code,
                .owner = .of(b.scope),
                .name = local,
                .full = "",
                .vtype = user.vpiIODecl,
                .src_tok = p.v.main_tok,
                .props = try code_tables.ioProps(b.arena, code_tables.direction(p.direction), b.declWidth(p.v, slot), p.v.is_signed),
                .edges = try b.arena.dupe(Edge, &.{ .{ .tag = user.vpiExpr, .to = formal }, .{ .tag = user.vpiScope, .to = at } }),
            });
        }
        for (t.vars) |v| {
            const slot = if (frame) |fr| b.run.?.hier.names.get(.{ .scope = fr.scope, .str = v.name }) else null;
            _ = try b.subVar(&vars, v, slot, t.automatic);
        }
        const body = try b.stmt(t.body);
        b.leave(saved);
        b.objects.at(at).edges = try b.arena.dupe(Edge, &.{.{ .tag = user.vpiStmt, .to = body }});
        b.objects.at(at).lists = try b.arena.dupe(List, &.{
            .{ .tag = user.vpiIODecl, .items = ios },
            .{ .tag = user.vpiReg, .items = vars.regs.items },
            .{ .tag = user.vpiIntegerVar, .items = vars.ints.items },
            .{ .tag = user.vpiRealVar, .items = vars.reals.items },
            .{ .tag = user.vpiNamedEvent, .items = local_events.scalars },
            .{ .tag = user.vpiNamedEventArray, .items = local_events.arrays },
            .{ .tag = user.vpiInternalScope, .items = try b.arena.dupe(ObjId, inner.items) },
        });
    }
    // §11.6.17.
    for (m.assigns) |a| {
        const lhs = try b.expr(a.target);
        const rhs = try b.expr(a.value);
        const delay = try b.delayExpr(a.delay);
        const at = try b.code(user.vpiContAssign, &.{
            .{ .tag = user.vpiLhs, .to = lhs },
            .{ .tag = user.vpiRhs, .to = rhs },
            .{ .tag = user.vpiDelay, .to = delay },
        }, &.{}, &.{.{ .prop = user.vpiNetDeclAssign, .value = 0 }});
        b.objects.at(at).delays = try b.delays(a.delay);
        b.objects.at(at).src_tok = a.main_tok;
        try b.attributes(at, .{ .kind = .declaration, .tok = a.main_tok }, false);
        b.lists.cont_assigns.appendAssumeCapacity(at);
    }
    // IEEE 1364-2005 §26.6.24: a net declaration assignment (A.2.4) is a
    // continuous assignment too, "-> net decl assign bool:
    // vpiNetDeclAssign". §6.1.3: "When there is a continuous assignment
    // in a declaration, the delay is part of the continuous assignment".
    for (m.nets) |n| {
        if (n.init == .none) continue;
        const at = try b.code(user.vpiContAssign, &.{
            .{ .tag = user.vpiLhs, .to = b.lookup(b.file.str(n.name)) },
            .{ .tag = user.vpiRhs, .to = try b.expr(n.init) },
            .{ .tag = user.vpiDelay, .to = try b.delayExpr(n.delay) },
        }, &.{}, &.{.{ .prop = user.vpiNetDeclAssign, .value = 1 }});
        b.objects.at(at).delays = try b.delays(n.delay);
        b.objects.at(at).src_tok = n.main_tok;
        b.lists.cont_assigns.appendAssumeCapacity(at);
    }
    // §11.6.13 gates, in source order, then pull sources, switches and
    // UDP instances.
    for (m.gates) |g| {
        const terms = try b.arena.alloc(Ast.ExprId, 1 + g.ins.len);
        terms[0] = g.out;
        @memcpy(terms[1..], g.ins);
        const at = try b.primitive(user.vpiGate, code_tables.gateType(g.kind), terms, &.{}, &.{
            .{ .prop = user.vpiArray, .value = @intFromBool(g.range != null) },
            .{ .prop = user.vpiStrength0, .value = code_tables.drive(g.strength0) },
            .{ .prop = user.vpiStrength1, .value = code_tables.drive(g.strength1) },
        });
        if (g.name != .none) try b.setName(at, try b.arena.dupe(u8, b.file.str(g.name)));
        const delay = try b.delayExpr(g.delay);
        b.objects.at(at).delays = try b.delays(g.delay);
        b.objects.at(at).src_tok = g.main_tok;
        try b.attributes(at, .{ .kind = .declaration, .tok = g.main_tok }, false);
        b.objects.at(at).edges = try b.arena.dupe(Edge, &.{.{ .tag = user.vpiDelay, .to = delay }});
    }
    // IEEE 1364-2005 §7.8: a pull source drives its one terminal, at its
    // strength on its own side (the other "shall be ignored").
    for (m.pulls) |p| {
        const side: c_int = if (p.one) user.vpiStrength1 else user.vpiStrength0;
        const at = try b.primitive(user.vpiGate, if (p.one) user.vpiPullupPrim else user.vpiPulldownPrim, &.{p.out}, &.{}, &.{
            .{ .prop = user.vpiArray, .value = 0 },
            .{ .prop = side, .value = code_tables.drive(p.strength) },
        });
        try b.attributes(at, .{ .kind = .declaration, .tok = p.main_tok }, false);
    }
    // §7.1/§7.6's switches: a MOS or CMOS switch's output, then its input
    // and controls; a pass switch's two inouts, then its enable.
    for (m.switches) |sw| {
        const pass = switch (sw.kind) {
            .tran, .rtran, .tranif0, .tranif1, .rtranif0, .rtranif1 => true,
            .cmos, .rcmos, .nmos, .pmos, .rnmos, .rpmos => false,
        };
        const dirs = try b.arena.alloc(c_int, sw.terms.len);
        for (dirs, 0..) |*dir, k| dir.* = (if (k == 0) (if (pass) user.vpiInout else user.vpiOutput) else if (pass and k == 1) user.vpiInout else user.vpiInput);
        const at = try b.primitive(user.vpiSwitch, code_tables.switchType(sw.kind), sw.terms, dirs, &.{.{ .prop = user.vpiArray, .value = 0 }});
        try b.attributes(at, .{ .kind = .declaration, .tok = sw.main_tok }, false);
    }
    if (b.udps) |udps| for (m.instances) |inst| {
        const defn = udps.get(inst.module) orelse continue;
        const terms = try b.arena.alloc(Ast.ExprId, inst.ports.len);
        for (inst.ports, terms) |c, *t| t.* = c.expr;
        const d = b.objects.at(defn).*;
        const at = try b.primitive(user.vpiUdp, d.props[1].value, terms, &.{}, &.{
            .{ .prop = user.vpiArray, .value = @intFromBool(inst.range != null) },
            .{ .prop = user.vpiStrength0, .value = code_tables.drive(inst.strength0) },
            .{ .prop = user.vpiStrength1, .value = code_tables.drive(inst.strength1) },
        });
        try b.setName(at, try b.arena.dupe(u8, b.file.str(inst.name)));
        const delay = try b.delayExpr(inst.delay);
        b.objects.at(at).delays = try b.delays(inst.delay);
        b.objects.at(at).src_tok = inst.main_tok;
        try b.attributes(at, .{ .kind = .declaration, .tok = inst.main_tok }, false);
        b.objects.at(at).edges = try b.arena.dupe(Edge, &.{
            .{ .tag = user.vpiUdpDefn, .to = defn },
            .{ .tag = user.vpiDelay, .to = delay },
        });
    };
    // §11.6.15 the specify block's module paths and timing checks.
    for (m.paths) |p| try b.modPath(p);
    for (m.timing_checks) |t| try b.timingCheck(t);
    // §11.6.21 initial and always.
    for (m.discrete) |d| {
        const body = try b.stmt(d.body);
        const at = try b.code(if (d.is_always) user.vpiAlways else user.vpiInitial, &.{.{ .tag = user.vpiStmt, .to = body }}, &.{}, &.{});
        try b.attributes(at, .{ .kind = .declaration, .tok = d.main_tok }, false);
        b.lists.processes.appendAssumeCapacity(at);
    }
    std.debug.assert(b.inner == ObjId.none);
    std.debug.assert(b.path.ptr == path.ptr and b.path.len == path.len);
}

/// Sizes the scope lists only `module` fills to what it will append:
/// one per task or function, continuous assignment (with net
/// declaration assignments), primitive, module path and process; at most
/// one per timing check (an unknown one is skipped). Asserts that the lists
/// are still empty, and that each now holds what `module` appends.
pub fn reserveModule(b: *Builder, m: *const Ast.ModuleDecl) Error!void {
    std.debug.assert(b.lists.processes.items.len == 0);
    var n_fn: usize = 0;
    for (m.tasks) |t| n_fn += @intFromBool(t.is_function);
    var n_assign = m.assigns.len;
    for (m.nets) |n| n_assign += @intFromBool(n.init != .none);
    var n_prim = m.gates.len + m.pulls.len + m.switches.len;
    if (b.udps) |udps| for (m.instances) |inst| {
        n_prim += @intFromBool(udps.contains(inst.module));
    };
    const l = b.lists;
    try l.functions.ensureTotalCapacityPrecise(b.gpa, n_fn);
    try l.tasks.ensureTotalCapacityPrecise(b.gpa, m.tasks.len - n_fn);
    try l.cont_assigns.ensureTotalCapacityPrecise(b.gpa, n_assign);
    try l.primitives.ensureTotalCapacityPrecise(b.gpa, n_prim);
    try l.mod_paths.ensureTotalCapacityPrecise(b.gpa, m.paths.len);
    try l.tchks.ensureTotalCapacityPrecise(b.gpa, m.timing_checks.len);
    try l.processes.ensureTotalCapacityPrecise(b.gpa, m.discrete.len);
    std.debug.assert(l.tasks.capacity >= m.tasks.len - n_fn);
}

/// §11.6.21's third process, `analog`, over the flattened analog blocks
/// that belong to this scope (`AnalogBlock.unit`). Asserts that it builds in
/// an analog scope and adds one process per block of this scope.
pub fn analogBlocks(b: *Builder, blocks: []const Ast.AnalogBlock) Error!void {
    std.debug.assert(b.analog != null);
    var n: usize = 0;
    for (blocks) |blk| n += @intFromBool(blk.unit == b.scope);
    const before = b.lists.processes.items.len;
    try b.lists.processes.ensureUnusedCapacity(b.gpa, n);
    for (blocks) |blk| {
        if (blk.unit != b.scope) continue;
        const body = try b.stmt(blk.body);
        const at = try b.code(user.vpiAnalog, &.{.{ .tag = user.vpiStmt, .to = body }}, &.{}, &.{});
        try b.attributes(at, .{ .kind = .declaration, .tok = blk.main_tok }, false);
        b.lists.processes.appendAssumeCapacity(at);
    }
    std.debug.assert(b.lists.processes.items.len == before + n);
}

/// A §11.6.13 primitive with its terminals, vpiTermIndex in A.3.3's
/// order: each terminal's direction from `dirs`, or when empty, output
/// first and then the inputs. `props` are the class's own (vpiArray,
/// the strengths).
///
/// ponytail: an array of instances (IEEE 1364-2005 §7.1.5) is this one
/// object with vpiArray set, not one per index with a vpiIndex; splitting
/// it needs §7.1.6's terminal split. Asserts that `dirs` is empty or gives
/// every terminal its direction, and that each terminal got its row.
pub fn primitive(b: *Builder, vtype: c_int, prim_type: c_int, terms: []const Ast.ExprId, dirs: []const c_int, props: []const Prop) Error!ObjId {
    std.debug.assert(dirs.len == 0 or dirs.len == terms.len);
    std.debug.assert(prim_type > 0);
    var inputs: c_int = 0;
    for (terms, 0..) |_, k| inputs += @intFromBool(termDir(dirs, k) == user.vpiInput);
    const all = try std.mem.concat(b.arena, Prop, &.{
        &.{
            .{ .prop = user.vpiPrimType, .value = prim_type },
            // NOTE 1: "vpiSize shall return the number of inputs."
            .{ .prop = user.vpiSize, .value = inputs },
        },
        props,
    });
    const at = try b.code(vtype, &.{}, &.{}, all);
    const items = try b.arena.alloc(ObjId, terms.len);
    for (terms, items, 0..) |t, *item, k| {
        const e = try b.expr(t);
        item.* = try b.code(user.vpiPrimTerm, &.{
            .{ .tag = user.vpiExpr, .to = e },
            .{ .tag = user.vpiPrimitive, .to = at },
        }, &.{}, &.{
            .{ .prop = user.vpiDirection, .value = termDir(dirs, k) },
            .{ .prop = user.vpiTermIndex, .value = @intCast(k) },
        });
    }
    b.objects.at(at).lists = try b.arena.dupe(List, &.{.{ .tag = user.vpiPrimTerm, .items = items }});
    b.lists.primitives.appendAssumeCapacity(at);
    std.debug.assert(inputs <= terms.len);
    return at;
}

/// Task or function `k`'s position among the `tasks` of its own kind (the
/// tasks list or the functions list). Asserts that `k` is one of `tasks`
/// and the position is among the `k` before it.
pub fn subIndex(tasks: []const Ast.Subroutine, k: usize) usize {
    std.debug.assert(k < tasks.len);
    var n: usize = 0;
    for (tasks[0..k]) |t| {
        if (t.is_function == tasks[k].is_function) n += 1;
    }
    std.debug.assert(n <= k);
    return n;
}

/// §11.6.15 a module path: `vpiModPathIn` / `vpiModPathOut` path terms
/// (each ->vpiExpr its terminal, with vpiDirection and vpiEdge),
/// ->vpiCondition its `if` expression, and vpiPathType, vpiPolarity,
/// vpiDataPolarity. Its delays are the A.7.4 list, for §12.11. Asserts
/// that a path lands in the list `reserveModule` sized, as one more path.
pub fn modPath(b: *Builder, p: Ast.SpecPath) Error!void {
    const before = b.lists.mod_paths.items.len;
    std.debug.assert(before < b.lists.mod_paths.capacity);
    const ins = try b.arena.alloc(ObjId, p.ins.len);
    for (p.ins, ins) |e, *t| t.* = try b.term(user.vpiPathTerm, e, user.vpiInput, p.edge);
    const outs = try b.arena.alloc(ObjId, p.outs.len);
    for (p.outs, outs) |e, *t| t.* = try b.term(user.vpiPathTerm, e, user.vpiOutput, .none);
    const cond = if (p.cond != .none) try b.expr(p.cond) else ObjId.none;
    const data = try b.term(user.vpiPathTerm, p.data, user.vpiInput, .none);
    const at = try b.code(user.vpiModPath, &.{
        .{ .tag = user.vpiCondition, .to = cond },
        .{ .tag = user.vpiDelay, .to = try b.delayListExpr(p.delays) },
        .{ .tag = user.vpiModDataPathIn, .to = data },
    }, &.{
        .{ .tag = user.vpiModPathIn, .items = ins },
        .{ .tag = user.vpiModPathOut, .items = outs },
    }, &.{
        .{ .prop = user.vpiPathType, .value = if (p.full) user.vpiPathFull else user.vpiPathParallel },
        .{ .prop = user.vpiPolarity, .value = code_tables.polarity(p.polarity) },
        .{ .prop = user.vpiDataPolarity, .value = code_tables.polarity(p.data_polarity) },
        .{ .prop = user.vpiModPathHasIfNone, .value = @intFromBool(p.ifnone) },
    });
    b.objects.at(at).delays = try b.foldAll(p.delays);
    b.objects.at(at).src_tok = p.main_tok;
    b.lists.mod_paths.appendAssumeCapacity(at);
    std.debug.assert(b.lists.mod_paths.items.len == before + 1);
}

/// §11.6.15 a timing check: vpiTchkType, ->vpiTchkRefTerm its first event,
/// ->vpiTchkDataTerm its second (not `$period`/`$width`, which have one),
/// ->vpiTchkNotifier the reg a violation toggles, when written. Its
/// "limits" are §12.11's delays: "the no_of_delays value shall match the
/// number of limits existing in the timing check". Asserts that a known
/// check's limits are within its argument slots, and that it lands as one
/// more check in the list `reserveModule` sized.
pub fn timingCheck(b: *Builder, t: Ast.TimingCheck) Error!void {
    const name = b.file.str(t.name);
    const kind = code_tables.tchk_kinds.get(name) orelse return;
    std.debug.assert(kind.n_limits <= kind.limits.len);
    const before = b.lists.tchks.items.len;
    // A.7.5.1: `$setup ( data_event , reference_event , …)` is the one
    // command that writes its data event first.
    const r: usize = if (kind.data_first) 1 else 0;
    const dt: usize = 1 - r;
    const ref = try b.term(user.vpiTchkTerm, arg(t, r), 0, if (t.edges.len > r) t.edges[r] else .none);
    const data = if (kind.data) try b.term(user.vpiTchkTerm, arg(t, dt), 0, if (t.edges.len > dt) t.edges[dt] else .none) else ObjId.none;
    const notifier = if (arg(t, kind.notifier) != .none) try b.expr(arg(t, kind.notifier)) else ObjId.none;
    // Details b: every argument written, in order, the events as their
    // tchk terms.
    const args = try b.arena.alloc(ObjId, t.args.len);
    for (t.args, args, 0..) |a, *out, k| out.* = if (k == r) ref else if (kind.data and k == dt) data else if (k == kind.notifier) notifier else try b.expr(a);
    var limit_buf: [kind.limits.len]Ast.ExprId = undefined;
    const limits = limit_buf[0..kind.n_limits];
    for (kind.limits[0..kind.n_limits], limits) |k, *l| l.* = arg(t, k);
    const at = try b.code(user.vpiTchk, &.{
        .{ .tag = user.vpiTchkRefTerm, .to = ref },
        .{ .tag = user.vpiTchkDataTerm, .to = data },
        .{ .tag = user.vpiTchkNotifier, .to = notifier },
        .{ .tag = user.vpiDelay, .to = try b.delayListExpr(limits) },
    }, &.{.{ .tag = user.vpiExpr, .items = try b.many(args) }}, &.{.{ .prop = user.vpiTchkType, .value = kind.type }});
    b.objects.at(at).delays = try b.foldAll(limits);
    b.objects.at(at).src_tok = t.main_tok;
    b.lists.tchks.appendAssumeCapacity(at);
    std.debug.assert(b.lists.tchks.items.len == before + 1);
}

/// A path or timing-check terminal: its expression, direction and edge.
/// Asserts that `vtype` is a terminal class and the row made is one.
pub fn term(b: *Builder, vtype: c_int, e: Ast.ExprId, dir_code: c_int, edge: Ast.SpecEdge) Error!ObjId {
    std.debug.assert(vtype == user.vpiPathTerm or vtype == user.vpiTchkTerm);
    if (e == .none) return ObjId.none;
    const x = try b.expr(e);
    const props: [2]Prop = .{ .{ .prop = user.vpiDirection, .value = dir_code }, .{ .prop = user.vpiEdge, .value = switch (edge) {
        .none => user.vpiNoEdge,
        .posedge => user.vpiPosedge,
        .negedge => user.vpiNegedge,
        .edge => user.vpiAnyEdge,
    } } };
    const at = try b.code(vtype, &.{.{ .tag = user.vpiExpr, .to = x }}, &.{}, props[@intFromBool(dir_code == 0)..]);
    std.debug.assert(b.objects.at(at).vtype == vtype);
    return at;
}

/// IEEE 1364-2005 §26.3.4 vpiDelay: the one delay expression, or a
/// vpiListOp operation over several; `none` when none is written. Asserts
/// that the answer is `none` exactly when nothing is written or the one
/// delay has no object.
pub fn delayListExpr(b: *Builder, es: []const Ast.ExprId) Error!ObjId {
    const at = try switch (es.len) {
        0 => ObjId.none,
        1 => b.expr(es[0]),
        else => b.operation(user.vpiListOp, es),
    };
    std.debug.assert(es.len != 0 or at == ObjId.none);
    std.debug.assert(es.len < 2 or at != ObjId.none);
    return at;
}

/// Every expression folded to a literal, or none of them when one does
/// not fold (a specparam name, which this model does not elaborate).
/// Asserts that a fold is all or nothing.
pub fn foldAll(b: *Builder, es: []const Ast.ExprId) Error![]const f64 {
    const out = try b.arena.alloc(f64, es.len);
    for (es, out) |e, *v| v.* = code_tables.literal(b.file, e) orelse return &.{};
    std.debug.assert(out.len == es.len);
    std.debug.assert(out.len == 0 or !std.math.isNan(out[0]));
    return out;
}

/// IEEE 1364-2005 §26.3.4 vpiDelay: "an expression that evaluates to a
/// constant if there is only one delay specified or an operation if
/// there are more than one delay specified. If multiple delays are
/// specified, then the operation's vpiOpType shall be vpiListOp."
/// Asserts that a written delay has its rise value, and that the answer
/// is a row when one is made.
pub fn delayExpr(b: *Builder, d: Ast.Delay3) Error!ObjId {
    if (!d.any()) return ObjId.none;
    std.debug.assert(d.rise != .none);
    // `parseDelay3` spreads a single delay over all three transitions.
    if (d.fall == d.rise) return b.expr(d.rise);
    const at = try b.operation(user.vpiListOp, if (d.off == .none) &.{ d.rise, d.fall } else &.{ d.rise, d.fall, d.off });
    std.debug.assert(at.index() < b.objects.hot.items.len);
    return at;
}

/// The literal rise, fall and turn-off delays written, as reals, or none
/// when one is not a literal. Asserts that the delays written are a prefix
/// of the three, and that a written delay has its rise value.
pub fn delays(b: *Builder, d: Ast.Delay3) Error![]const f64 {
    if (!d.any()) return &.{};
    std.debug.assert(d.rise != .none);
    var out: [3]f64 = undefined;
    var n: usize = 0;
    for ([_]Ast.ExprId{ d.rise, d.fall, d.off }) |e| {
        if (e == .none) break;
        out[n] = code_tables.literal(b.file, e) orelse return &.{};
        n += 1;
    }
    std.debug.assert(n >= 1 and n <= out.len);
    return b.arena.dupe(f64, out[0..n]);
}

// ---- private ----

/// Terminal `k`'s direction: `dirs[k]`, or output first and inputs after
/// when `dirs` is empty. Asserts that `k` is a terminal of `dirs` when it
/// has any, and that the answer is a direction code.
fn termDir(dirs: []const c_int, k: usize) c_int {
    std.debug.assert(dirs.len == 0 or k < dirs.len);
    const d = if (dirs.len != 0) dirs[k] else if (k == 0) user.vpiOutput else user.vpiInput;
    std.debug.assert(d >= user.vpiInput and d <= user.vpiNoDirection);
    return d;
}

/// Timing-check argument `k`, or `.none` past those written. Asserts that
/// `k` is a slot `tchk_kinds` reads (a notifier's, slot 4, is the last) of
/// a named check.
fn arg(tc: Ast.TimingCheck, k: usize) Ast.ExprId {
    std.debug.assert(k <= 4);
    std.debug.assert(tc.name != .none);
    return if (k < tc.args.len) tc.args[k] else .none;
}
