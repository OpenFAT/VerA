//! One-to-many traversal: §12.23 vpi_iterate and §12.35 vpi_scan. A
//! reference handle and a type -> a heap `Iter` over object indices (or over
//! handles it owns), live while it is a key of `Design.iters`: vpi_scan frees
//! it on exhaustion, vpi_free_object (root.zig) on request. IEEE 1364-2005
//! §26.6.22/§26.6.23 drivers and loads and §26.6.43 vpiUse are computed per
//! call, from reverse indexes (`Relations`) built on the first such call.

const std = @import("std");
const sim = @import("sim");
const callback = @import("callback.zig");
const code = @import("code.zig");
const delays = @import("delays.zig");
const property = @import("property.zig");
const root = @import("root.zig");
const coldOf = root.coldOf;
const Csr = @import("model.zig").Csr;
const run = @import("run.zig");
const systf = @import("systf.zig");

const Design = root.Design;
const Iter = root.Iter;
const Obj = root.Obj;
const asIter = root.asIter;
const asObj = root.asObj;
const codeProp = property.codeProp;
const describe = root.describe;
const edgeTo = root.edgeTo;
const enter = root.enter;
const fail = root.fail;
const handleOf = root.handleOf;
const no_obj = root.no_obj;
const object = root.object;
const typeName = root.typeName;
const typeOf = root.typeOf;
const vpiBranch = root.vpiBranch;
const vpiChild = root.vpiChild;
const vpiDirection = root.vpiDirection;
const vpiDiscipline = root.vpiDiscipline;
const vpiHandle = root.vpiHandle;
const vpiInout = root.vpiInout;
const vpiIntegerVar = root.vpiIntegerVar;
const vpiInternalScope = root.vpiInternalScope;
const vpiMemory = root.vpiMemory;
const vpiMemoryWord = root.vpiMemoryWord;
const vpiModule = root.vpiModule;
const vpiModuleArray = root.vpiModuleArray;
const vpiNature = root.vpiNature;
const vpiNet = root.vpiNet;
const vpiNetArray = root.vpiNetArray;
const vpiNode = root.vpiNode;
const vpiOutput = root.vpiOutput;
const vpiParameter = root.vpiParameter;
const vpiParent = root.vpiParent;
const vpiPort = root.vpiPort;
const vpiRealVar = root.vpiRealVar;
const vpiReg = root.vpiReg;
const vpiRegArray = root.vpiRegArray;
const vpiScope = root.vpiScope;
const vpiVarSelect = root.vpiVarSelect;
const vpiVariables = root.vpiVariables;

/// "If there are no objects of type `type` associated with the reference handle
/// `ref`, then `vpi_iterate()` shall return NULL."
///
/// So an EMPTY set and an UNSUPPORTED relationship have the same return value,
/// and the difference between them is the error status: a module with no regs
/// is NULL with no error, `vpi_iterate(vpiPort, some_reg)` is NULL with one. An
/// application that does not check errors sees the documented empty loop either
/// way; one that does can tell a fact about the design from a limit of VerA's.
pub export fn vpi_iterate(obj_type: c_int, ref: vpiHandle) vpiHandle {
    const h = iterate(obj_type, ref);
    if (asIter(h)) |it| {
        it.use = ref;
        it.ty = obj_type;
    }
    return h;
}

fn iterate(obj_type: c_int, ref: vpiHandle) vpiHandle {
    const d = enter("vpi_iterate") orelse return null;
    if (root.unansweredType(obj_type)) |u| {
        root.failUnanswered("vpi_iterate", u);
        return null;
    }
    // IEEE 1364-2005 §26.6.39: object and time-queue associations, or a
    // NULL reference for global callbacks. Time queues are not Design rows.
    if (obj_type == callback.vpiCallback) {
        if (ref != null and asObj(ref) == null and run.asQueue(ref) == null) {
            _ = object("vpi_iterate", ref);
            return null;
        }
        return newHandleIter(d, callback.all(d.gpa, ref) catch return oomIter());
    }
    // §11.6.1 NOTE 1: "Top-level modules shall be accessed using vpi_iterate()
    // with a NULL reference object."
    if (ref == null) {
        if (obj_type == systf.vpiUserSystf) {
            return newHandleIter(d, systf.all(d.gpa) catch return oomIter());
        }
        if (obj_type == run.vpiTimeQueue) {
            return newHandleIter(d, run.timeQueues(d.gpa) catch return oomIter());
        }
        // §11.6.2's circled arrows: disciplines and natures are design-wide.
        // An empty set (a digital design) is NULL with no error (§12.23).
        if (obj_type == vpiDiscipline or obj_type == vpiNature or obj_type == code.vpiUdpDefn) {
            const items = if (obj_type == vpiDiscipline) d.disciplines else if (obj_type == vpiNature) d.natures else d.udp_defns;
            return if (items.len == 0) null else newIter(d, items);
        }
        if (obj_type != vpiModule) {
            fail("NOTRAVERSE", "vpi_iterate: {d} is not iterable from a NULL reference", .{obj_type});
            return null;
        }
        return newIter(d, d.top_modules);
    }
    // IEEE 1364-2005 §26.6.16: inter-module path ->> its two ports, the
    // output port first.
    if (delays.asPath(ref)) |m| {
        if (obj_type == vpiPort) return newIter(d, &m.ports);
        fail("NOTRAVERSE", "vpi_iterate: an inter-module path is the reference object of vpiPort only, not {d}", .{obj_type});
        return null;
    }
    const o = object("vpi_iterate", ref) orelse return null;
    if (obj_type == code.vpiAttribute and @import("attributes.zig").supports(o))
        return if (coldOf(o).attributes.len == 0) null else newIter(d, coldOf(o).attributes);
    if (obj_type == code.vpiUse) return uses(d, o);
    // A behavioural object's double arrows are its `lists` rows, as are a
    // vector's bits. An empty row is an empty set (NULL, no error —
    // §11.6.23 NOTE 2's default case item among them); a tag a behavioural
    // object has no row for is no relationship.
    for (o.lists) |l| if (l.tag == obj_type) return if (l.items.len == 0) null else newIter(d, l.items);
    if (o.kind == .code) {
        fail("NOTRAVERSE", "vpi_iterate: a {s} is the reference object of no relationship {d}", .{ typeName(o.vtype), obj_type });
        return null;
    }
    // §11.6.8 net ->> port, IEEE 1364-2005 §26.6.6: the ports of the net's
    // own module whose low connection it is. None is an empty set — NULL
    // without an error (§12.23) — not a missing relationship.
    if (o.kind == .net and obj_type == vpiPort) return lowConnPorts(d, o);
    // §11.6.11 (IEEE 1364 §26.6.7-9): an array's elements. A memory's words by
    // the legacy vpiMemoryWord tag or as vpiReg; a variable array's by
    // vpiVarSelect; an instance array's members by vpiModule.
    const elements: bool = switch (o.kind) {
        .reg_array => obj_type == vpiMemoryWord or obj_type == vpiReg,
        .var_array => obj_type == vpiVarSelect,
        .net_array => obj_type == vpiNet,
        .module_array => obj_type == vpiModule,
        else => false, // else: only the four array classes hold elements
    };
    if (elements) return newIter(d, coldOf(o).members);
    if (obj_type == code.vpiRange and coldOf(o).range.len != 0) return newIter(d, coldOf(o).range);
    // The analog double arrows: node ->> net (§11.6.5), nature ->> nature
    // tagged vpiChild and nature ->> discipline (§11.6.2).
    const analog: ?[]const u32 = switch (o.kind) {
        .node => if (obj_type == vpiNet) coldOf(o).nets else null,
        .nature => if (obj_type == vpiChild) coldOf(o).children else if (obj_type == vpiDiscipline) coldOf(o).users else null,
        else => null, // else: no other class but module draws a double arrow VerA holds
    };
    if (analog) |items| return if (items.len == 0) null else newIter(d, items);
    switch (obj_type) {
        code.vpiDriver, code.vpiLoad, code.vpiLocalDriver, code.vpiLocalLoad => if (o.kind == .net or o.kind == .reg)
            return driversLoads(d, o, obj_type == code.vpiDriver or obj_type == code.vpiLocalDriver, obj_type == code.vpiLocalDriver or obj_type == code.vpiLocalLoad),
        else => {},
    }
    if (o.kind != .module) {
        fail("NOTRAVERSE", "vpi_iterate: a {s} is the reference object of no one-to-many relationship {d}", .{ @tagName(o.kind), obj_type });
        return null;
    }
    const s = &d.scopes[o.scope];
    for (s.lists) |l| if (l.tag == obj_type) return if (l.items.len == 0) null else newIter(d, l.items);
    const items: []const u32 = switch (obj_type) {
        vpiModule => s.children,
        vpiInternalScope => s.internal,
        vpiPort => s.ports,
        vpiNet => s.nets,
        vpiReg => s.regs,
        vpiParameter => s.params,
        vpiIntegerVar => s.integers,
        vpiRealVar => s.reals,
        // IEEE 1364 §26.6.9: the legacy vpiMemory method returns the reg
        // arrays, as vpiRegArray objects.
        vpiMemory, vpiRegArray => s.reg_arrays,
        vpiNetArray => s.net_arrays,
        vpiVariables => s.variables,
        vpiModuleArray => s.module_arrays,
        // §11.6.1's `nodes` and `branches` classes (§11.6.5, §11.6.6).
        vpiNode => s.nodes,
        vpiBranch => s.branches,
        else => {
            fail("NOTRAVERSE", "vpi_iterate: no one-to-many relationship {d} from a module", .{obj_type});
            return null;
        },
    };
    if (items.len == 0) return null;
    return newIter(d, items);
}

/// IEEE 1364-2005 §26.6.25 simple expr ->> vpiUse: the objects (statements,
/// expressions, continuous assignments, terminals) that read or write `o`,
/// in object order. Details a): "For vectors, the vpiUse relationship shall
/// access any use of the vector or part-selects or bit-selects thereof", so
/// an object holding a select of `o` uses it too.
///
/// ponytail: a bit select's own uses only (Details b adds the parent
/// vector's and a containing part select's).
fn uses(d: *Design, o: *const Obj) vpiHandle {
    switch (o.kind) {
        .net, .reg, .integer, .real_var, .time_var, .parameter, .word, .var_select => {},
        .code => if (o.vtype != code.vpiNetBit and o.vtype != code.vpiRegBit) return useFail(o),
        .module, .port, .reg_array, .var_array, .net_array, .module_array, .constant, .discipline, .nature, .node, .branch, .quantity => return useFail(o),
    }
    const target = d.indexOf(o);
    const rel = relationsOf(d) orelse return null;
    // At most one handle per user row.
    var out = std.ArrayList(vpiHandle).initCapacity(d.gpa, rel.users.of(target).len) catch return oomIter();
    var last: u32 = no_obj;
    for (rel.users.of(target)) |u| {
        if (u == last) continue;
        last = u;
        out.appendAssumeCapacity(handleOf(&d.objects[u]));
    }
    return ownedIter(d, &out);
}

fn useFail(o: *const Obj) vpiHandle {
    fail("NOTRAVERSE", "vpi_iterate: a {s} is no simple expression, so it has no vpiUse", .{typeName(typeOf(o))});
    return null;
}

/// §11.6.8 / IEEE 1364-2005 §26.6.6: the ports of net `o`'s module it is the
/// low connection of. A port's low connection is the net its name declares in
/// the same scope, so these are the ports sharing `o`'s name, as `driversLoads`
/// finds them. The analog model's nets never are one — a port-connected name
/// is its `.port` row there (model/analog.zig) — so its set is always empty.
fn lowConnPorts(d: *Design, o: *const Obj) vpiHandle {
    const owner = o.owner.get() orelse return null;
    const ports = d.scopes[owner].ports;
    var out = std.ArrayList(vpiHandle).initCapacity(d.gpa, ports.len) catch return oomIter();
    for (ports) |p| if (std.mem.eql(u8, d.objects[p].name, o.name)) out.appendAssumeCapacity(handleOf(&d.objects[p]));
    return ownedIter(d, &out);
}

/// IEEE 1364-2005 §26.6.22/§26.6.23: the drivers (`drivers`) or loads of net
/// or reg `o`. A prim term drives what its output terminal names, loads what
/// an input names, and does both through an inout; a continuous assignment
/// drives its left side and loads what its right side reads; a force or
/// assign stmt does too while one is active (§26.6.6 Details i, j). A net
/// collapsed across a port is one simulated net (§12.3.10), so what drives
/// or loads it in another instance is listed too (Details b). `local`
/// (vpiLocalDriver/vpiLocalLoad, Details l) keeps what `o`'s own module
/// contains, "including any ports connected to the net (output and inout
/// ports are loads, input and inout ports are drivers)"; the module's ports
/// are listed for vpiDriver and vpiLoad as well.
///
/// The rows tested are `Relations`' candidates for `o`, a superset of the
/// hits, in object order.
///
/// ponytail: the parent's instance ports, delay terms and cont assign bits
/// are not listed. Each needs its own relation.
fn driversLoads(d: *Design, o: *const Obj, drivers: bool, local: bool) vpiHandle {
    const rel = relationsOf(d) orelse return null;
    const target = d.indexOf(o);
    const by_obj = rel.by_obj.of(target);
    const by_slot: []const u32 = if (o.slot.get()) |slot| rel.by_slot.of(slot) else &.{};
    const ports: []const u32 = if (o.kind == .net) if (o.owner.get()) |owner| rel.ports.of(owner) else &.{} else &.{};
    var candidates = std.ArrayList(u32).initCapacity(d.gpa, by_obj.len + by_slot.len + ports.len) catch return oomIter();
    defer candidates.deinit(d.gpa);
    candidates.appendSliceAssumeCapacity(by_obj);
    candidates.appendSliceAssumeCapacity(by_slot);
    candidates.appendSliceAssumeCapacity(ports);
    std.mem.sortUnstable(u32, candidates.items, {}, std.sort.asc(u32));
    // At most one handle per candidate.
    var out = std.ArrayList(vpiHandle).initCapacity(d.gpa, candidates.items.len) catch return oomIter();
    var last: u32 = no_obj;
    for (candidates.items) |i| {
        if (i == last) continue;
        last = i;
        const x = &d.objects[i];
        if (local and x.owner != o.owner) continue;
        const hit = switch (x.kind) {
            .code => switch (x.vtype) {
                code.vpiPrimTerm => mentions(d, edgeTo(x, code.vpiExpr), o) and switch (codeProp(x, vpiDirection)) {
                    vpiOutput => drivers,
                    vpiInout => true,
                    else => !drivers,
                },
                code.vpiContAssign => mentions(d, edgeTo(x, if (drivers) code.vpiLhs else code.vpiRhs), o),
                code.vpiForce, code.vpiAssignStmt => activeOverride(d, x) and mentions(d, edgeTo(x, if (drivers) code.vpiLhs else code.vpiRhs), o),
                else => false, // else: §26.6.22/§26.6.23 list no other behavioural class
            },
            .port => o.kind == .net and x.owner == o.owner and std.mem.eql(u8, x.name, o.name) and switch (x.direction) {
                .input => drivers,
                .output => !drivers,
                .inout => true,
                .unspecified => false,
            },
            else => false, // else: no other class drives or loads a net or reg
        };
        if (hit) out.appendAssumeCapacity(handleOf(&d.objects[i]));
    }
    return ownedIter(d, &out);
}

fn oomIter() vpiHandle {
    fail("NOMEM", "vpi_iterate: out of memory", .{});
    return null;
}

/// Reverse indexes over the frozen rows for the relations computed per
/// call: §26.6.43 vpiUse and §26.6.22/§26.6.23 drivers and loads. Built on
/// the first such vpi_iterate (`relationsOf`) and kept in `Design` until
/// `close`; nothing it indexes changes after `open`.
pub const Relations = struct {
    /// Object -> the `.code` rows with an edge (other than vpiParent,
    /// vpiScope and vpiModule: a select's vpiParent is the vector it selects
    /// from, not a use) or list item that is it or a select of it: exactly
    /// `uses`' answer, ascending, a row repeated once per item.
    users: Csr,
    /// Object -> the driver and load candidates (prim terms, continuous
    /// assignments, force and assign statements) whose `mentions` walk of a
    /// terminal or side visits it.
    by_obj: Csr,
    /// Engine slot -> the candidates whose walk visits a non-`.code` row
    /// stored in that slot (`mentions`' same-storage case).
    by_slot: Csr,
    /// Scope -> its `.port` rows.
    ports: Csr,

    /// Frees the four indexes; `gpa` must be `Design.gpa`, which built them.
    pub fn deinit(r: *Relations, gpa: std.mem.Allocator) void {
        r.users.deinit(gpa);
        r.by_obj.deinit(gpa);
        r.by_slot.deinit(gpa);
        r.ports.deinit(gpa);
    }
};

/// `d`'s `Relations`, built on first use; null (and NOMEM recorded) when
/// they cannot be.
fn relationsOf(d: *Design) ?*const Relations {
    if (d.relations == null) d.relations = buildRelations(d) catch {
        _ = oomIter();
        return null;
    };
    return &d.relations.?;
}

fn buildRelations(d: *const Design) error{OutOfMemory}!Relations {
    const gpa = d.gpa;
    var users: std.ArrayList([2]u32) = .empty;
    defer users.deinit(gpa);
    var by_obj: std.ArrayList([2]u32) = .empty;
    defer by_obj.deinit(gpa);
    var by_slot: std.ArrayList([2]u32) = .empty;
    defer by_slot.deinit(gpa);
    var ports: std.ArrayList([2]u32) = .empty;
    defer ports.deinit(gpa);
    var n_slots: usize = 0;
    for (d.objects, 0..) |*x, at| {
        const u: u32 = @intCast(at);
        if (x.slot.get()) |s| n_slots = @max(n_slots, @as(usize, s) + 1);
        switch (x.kind) {
            .code => {
                for (x.edges) |e| if (e.tag != vpiParent and e.tag != vpiScope and e.tag != vpiModule) try addReach(gpa, d, &users, e.to, u);
                for (x.lists) |l| for (l.items) |i| try addReach(gpa, d, &users, i, u);
                switch (x.vtype) {
                    code.vpiPrimTerm => try addMentions(gpa, d, &by_obj, &by_slot, edgeTo(x, code.vpiExpr), u),
                    code.vpiContAssign, code.vpiForce, code.vpiAssignStmt => {
                        try addMentions(gpa, d, &by_obj, &by_slot, edgeTo(x, code.vpiLhs), u);
                        try addMentions(gpa, d, &by_obj, &by_slot, edgeTo(x, code.vpiRhs), u);
                    },
                    else => {}, // else: §26.6.22/§26.6.23 list no other behavioural class
                }
            },
            .port => if (x.owner.get()) |s| try ports.append(gpa, .{ s, u }),
            .module, .net, .reg, .parameter, .integer, .real_var, .time_var, .reg_array, .var_array, .net_array, .word, .var_select, .module_array, .constant, .discipline, .nature, .node, .branch, .quantity => {},
        }
    }
    var r: Relations = undefined;
    r.users = try .init(gpa, d.objects.len, users.items);
    errdefer r.users.deinit(gpa);
    r.by_obj = try .init(gpa, d.objects.len, by_obj.items);
    errdefer r.by_obj.deinit(gpa);
    r.by_slot = try .init(gpa, n_slots, by_slot.items);
    errdefer r.by_slot.deinit(gpa);
    r.ports = try .init(gpa, d.scopes.len, ports.items);
    return r;
}

/// Row `u` uses item `at` and, when `at` is a part or bit select, the
/// object its first vpiParent edge names.
fn addReach(gpa: std.mem.Allocator, d: *const Design, out: *std.ArrayList([2]u32), at: u32, u: u32) error{OutOfMemory}!void {
    if (at == no_obj) return;
    try out.append(gpa, .{ at, u });
    const x = &d.objects[at];
    if (x.kind != .code) return;
    switch (x.vtype) {
        code.vpiPartSelect, code.vpiIndexedPartSelect, code.vpiNetBit, code.vpiRegBit => {},
        else => return, // else: only a select names a part of another object
    }
    const parent = edgeTo(x, vpiParent);
    if (parent != no_obj) try out.append(gpa, .{ parent, u });
}

/// `mentions`' walk from `e`, inverted: every row it visits, and the slot of
/// every non-`.code` one, lead to candidate `u`.
fn addMentions(gpa: std.mem.Allocator, d: *const Design, by_obj: *std.ArrayList([2]u32), by_slot: *std.ArrayList([2]u32), e: u32, u: u32) error{OutOfMemory}!void {
    if (e == no_obj) return;
    try by_obj.append(gpa, .{ e, u });
    const x = &d.objects[e];
    if (x.kind != .code) {
        if (x.slot.get()) |s| try by_slot.append(gpa, .{ s, u });
        return;
    }
    switch (x.vtype) {
        code.vpiPartSelect, code.vpiNetBit, code.vpiRegBit => try addMentions(gpa, d, by_obj, by_slot, edgeTo(x, vpiParent), u),
        code.vpiOperation, code.vpiFuncCall, code.vpiSysFuncCall => for (x.lists) |l| {
            if (l.tag != code.vpiOperand and l.tag != code.vpiArgument) continue;
            for (l.items) |i| try addMentions(gpa, d, by_obj, by_slot, i, u);
        },
        else => {}, // else: no other class is an expression with operands
    }
}

/// §26.6.6 i, j: activity belongs to the statement maintaining an override,
/// not to the object whose loads or drivers are being queried. In particular
/// a load is on the RHS, while the override registry is keyed by the LHS.
fn activeOverride(d: *const Design, o: *const Obj) bool {
    if (coldOf(o).override_expr == .none) return false;
    const r = run.attached() orelse return false;
    var it = r.overrides.valueIterator();
    while (it.next()) |layers| {
        if (if (o.vtype == code.vpiForce) layers.force else layers.assign) |range|
            if (overrideRange(d, o, r, range)) return true;
        if (o.vtype == code.vpiForce) for (layers.parts.items) |part|
            if (overrideRange(d, o, r, part.range)) return true;
    }
    return false;
}

fn overrideRange(d: *const Design, o: *const Obj, r: *const sim.digital.Run, range: sim.digital.PcRange) bool {
    // A VPI force has an empty range; it activates no HDL source statement.
    if (range.start == range.end) return false;
    if (r.instanceOf(r.code_scope.items[range.start]) != d.scopes[o.owner.get().?].engine) return false;
    return switch (r.code.items[range.start]) {
        .override_eval => |op| op.value == coldOf(o).override_expr and op.force == (o.vtype == code.vpiForce),
        else => false, // else: only an override_eval maintains a procedural continuous assignment
    };
}

/// Does expression `e` read `target`'s storage: is it the same slot (or the
/// same object), a select of it, or an operation or call with such an
/// operand?
fn mentions(d: *const Design, e: u32, target: *const Obj) bool {
    if (e == no_obj) return false;
    const x = &d.objects[e];
    if (x == target or (x.slot != .none and x.slot == target.slot and x.kind != .code)) return true;
    if (x.kind != .code) return false;
    switch (x.vtype) {
        code.vpiPartSelect, code.vpiNetBit, code.vpiRegBit => return mentions(d, edgeTo(x, vpiParent), target),
        code.vpiOperation, code.vpiFuncCall, code.vpiSysFuncCall => for (x.lists) |l| {
            if (l.tag != code.vpiOperand and l.tag != code.vpiArgument) continue;
            for (l.items) |i| if (mentions(d, i, target)) return true;
        },
        else => {}, // else: no other class is an expression with operands
    }
    return false;
}

/// An iterator over `handles`, which it takes ownership of; NULL, with no
/// error, for none (§12.23).
fn newHandleIter(d: *Design, handles: []vpiHandle) vpiHandle {
    if (handles.len == 0) {
        d.gpa.free(handles);
        return null;
    }
    const h = newIter(d, &.{});
    if (asIter(h)) |it| it.handles = handles else d.gpa.free(handles);
    return h;
}

/// `newHandleIter` over `out`'s handles, which it takes: `out` is left
/// empty, or freed when the slice cannot be made.
fn ownedIter(d: *Design, out: *std.ArrayList(vpiHandle)) vpiHandle {
    const handles = out.toOwnedSlice(d.gpa) catch {
        out.deinit(d.gpa);
        return oomIter();
    };
    return newHandleIter(d, handles);
}

fn newIter(d: *Design, items: []const u32) vpiHandle {
    const it = d.gpa.create(Iter) catch return oomIter();
    it.* = .{ .items = items };
    d.iters.put(d.gpa, @intFromPtr(it), it) catch {
        d.gpa.destroy(it);
        return oomIter();
    };
    return @ptrCast(it);
}

/// "Once `vpi_scan()` returns NULL, the iterator handle is no longer valid and
/// can not be used again" (§12.35), and §12.4 spells out the consequence: "The
/// iterator object shall automatically be freed when vpi_scan() returns NULL".
///
/// So exhaustion frees the iterator, and scanning it again is an invalid-handle
/// error rather than a use-after-free.
pub export fn vpi_scan(itr: vpiHandle) vpiHandle {
    const d = enter("vpi_scan") orelse return null;
    const it = asIter(itr) orelse {
        fail("BADHANDLE", "vpi_scan: {s} is not a handle to a live iterator", .{describe(itr)});
        return null;
    };
    if (it.handles) |hs| {
        if (it.at >= hs.len) {
            destroyIter(d, it);
            return null;
        }
        it.at += 1;
        return hs[it.at - 1];
    }
    if (it.at >= it.items.len) {
        destroyIter(d, it);
        return null;
    }
    const idx = it.items[it.at];
    it.at += 1;
    return handleOf(&d.objects[idx]);
}

/// Frees `it` and the handles it owns, and removes it from `d.iters` first,
/// so its handle is invalid (`asIter` null) before the memory is.
pub fn destroyIter(d: *Design, it: *Iter) void {
    _ = d.iters.remove(@intFromPtr(it));
    if (it.handles) |hs| d.gpa.free(hs);
    d.gpa.destroy(it);
}
