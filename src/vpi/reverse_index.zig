//! The relations vpi_iterate computes per call: IEEE 1364-2005 §26.6.22/
//! §26.6.23 drivers and loads, §26.6.43 vpiUse and §11.6.8's net ->> port,
//! answered from reverse indexes over the frozen rows (`Relations`) built on
//! the first such call.
//! Cites: IEEE 1364-2005 §26.6.6 Details b, i, j, l, §26.6.22, §26.6.23,
//! §26.6.25, §26.6.43; VAMS-2023 §11.6.8.
//!
//! Contents:
//! - `pub const Relations = struct`
//! - `pub fn Relations.deinit(r: *Relations, gpa: std.mem.Allocator) void`
//! - `pub fn uses(d: *Design, o: *const Obj) abi.vpiHandle`
//! - `pub fn lowConnPorts(d: *Design, o: *const Obj) abi.vpiHandle`
//! - `pub fn driversLoads(d: *Design, o: *const Obj, drivers: bool, local: bool) abi.vpiHandle`

const std = @import("std");
const sim = @import("sim");
const abi = @import("abi.zig");
const iterate = @import("iterate.zig");
const property = @import("property.zig");
const run = @import("run.zig");
const schema = @import("schema.zig");
const ObjId = schema.ObjId;
const status = @import("status.zig");
const trust = @import("trust.zig");
const user = @import("vpi_user.zig");
const Design = @import("Design.zig");
const model = @import("model.zig");
const Csr = model.Csr;
const Obj = schema.Obj;

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

/// IEEE 1364-2005 §26.6.25 simple expr ->> vpiUse: the objects (statements,
/// expressions, continuous assignments, terminals) that read or write `o`,
/// in object order. Details a): "For vectors, the vpiUse relationship shall
/// access any use of the vector or part-selects or bit-selects thereof", so
/// an object holding a select of `o` uses it too.
///
/// ponytail: a bit select's own uses only (Details b adds the parent
/// vector's and a containing part select's).
pub fn uses(d: *Design, o: *const Obj) abi.vpiHandle {
    switch (o.kind) {
        .net, .reg, .integer, .real_var, .time_var, .parameter, .word, .var_select => {},
        .code => if (o.vtype != user.vpiNetBit and o.vtype != user.vpiRegBit) return useFail(o),
        .module, .port, .reg_array, .var_array, .net_array, .module_array, .constant, .discipline, .nature, .node, .branch, .quantity => return useFail(o),
    }
    const target = d.idOf(o);
    const rel = relationsOf(d) orelse return null;
    // At most one handle per user row.
    var out = std.ArrayList(abi.vpiHandle).initCapacity(d.gpa, rel.users.of(target.index()).len) catch return iterate.oomIter();
    var last: u32 = std.math.maxInt(u32);
    for (rel.users.of(target.index())) |u| {
        if (u == last) continue;
        last = u;
        out.appendAssumeCapacity(trust.handleOf(d.obj(.at(u))));
    }
    return iterate.ownedIter(d, &out);
}

/// §11.6.8 / IEEE 1364-2005 §26.6.6: the ports of net `o`'s module it is the
/// low connection of. A port's low connection is the net its name declares in
/// the same scope, so these are the ports sharing `o`'s name, as `driversLoads`
/// finds them. The analog model's nets never are one — a port-connected name
/// is its `.port` row there (model/analog.zig) — so its set is always empty.
pub fn lowConnPorts(d: *Design, o: *const Obj) abi.vpiHandle {
    const owner = o.owner;
    if (owner == .none) return null;
    const ports = d.scope(owner).ports;
    var out = std.ArrayList(abi.vpiHandle).initCapacity(d.gpa, ports.len) catch return iterate.oomIter();
    for (ports) |p| if (std.mem.eql(u8, d.obj(p).name, o.name)) out.appendAssumeCapacity(trust.handleOf(d.obj(p)));
    return iterate.ownedIter(d, &out);
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
pub fn driversLoads(d: *Design, o: *const Obj, drivers: bool, local: bool) abi.vpiHandle {
    const rel = relationsOf(d) orelse return null;
    const target = d.idOf(o);
    const by_obj = rel.by_obj.of(target.index());
    const by_slot: []const u32 = if (o.slot.get()) |slot| rel.by_slot.of(slot) else &.{};
    const ports: []const u32 = if (o.kind == .net) if (o.owner != .none) rel.ports.of(o.owner.index()) else &.{} else &.{};
    var candidates = std.ArrayList(u32).initCapacity(d.gpa, by_obj.len + by_slot.len + ports.len) catch return iterate.oomIter();
    defer candidates.deinit(d.gpa);
    candidates.appendSliceAssumeCapacity(by_obj);
    candidates.appendSliceAssumeCapacity(by_slot);
    candidates.appendSliceAssumeCapacity(ports);
    std.mem.sortUnstable(u32, candidates.items, {}, std.sort.asc(u32));
    // At most one handle per candidate.
    var out = std.ArrayList(abi.vpiHandle).initCapacity(d.gpa, candidates.items.len) catch return iterate.oomIter();
    var last: u32 = std.math.maxInt(u32);
    for (candidates.items) |i| {
        if (i == last) continue;
        last = i;
        const x = d.obj(.at(i));
        if (local and x.owner != o.owner) continue;
        const hit = switch (x.kind) {
            .code => switch (x.vtype) {
                user.vpiPrimTerm => mentions(d, schema.edgeTo(x, user.vpiExpr), o) and switch (property.codeProp(x, user.vpiDirection)) {
                    user.vpiOutput => drivers,
                    user.vpiInout => true,
                    else => !drivers,
                },
                user.vpiContAssign => mentions(d, schema.edgeTo(x, if (drivers) user.vpiLhs else user.vpiRhs), o),
                user.vpiForce, user.vpiAssignStmt => activeOverride(d, x) and mentions(d, schema.edgeTo(x, if (drivers) user.vpiLhs else user.vpiRhs), o),
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
        if (hit) out.appendAssumeCapacity(trust.handleOf(d.obj(.at(i))));
    }
    return iterate.ownedIter(d, &out);
}

// ---- private ----

fn useFail(o: *const Obj) abi.vpiHandle {
    status.fail("NOTRAVERSE", "vpi_iterate: a {s} is no simple expression, so it has no vpiUse", .{schema.typeName(schema.typeOf(o))});
    return null;
}

/// `d`'s `Relations`, built on first use; null (and NOMEM recorded) when
/// they cannot be.
fn relationsOf(d: *Design) ?*const Relations {
    if (d.relations == null) d.relations = buildRelations(d) catch {
        _ = iterate.oomIter();
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
                for (x.edges) |e| if (e.tag != user.vpiParent and e.tag != user.vpiScope and e.tag != user.vpiModule) try addReach(gpa, d, &users, e.to, u);
                for (x.lists) |l| for (l.items) |i| try addReach(gpa, d, &users, i, u);
                switch (x.vtype) {
                    user.vpiPrimTerm => try addMentions(gpa, d, &by_obj, &by_slot, schema.edgeTo(x, user.vpiExpr), u),
                    user.vpiContAssign, user.vpiForce, user.vpiAssignStmt => {
                        try addMentions(gpa, d, &by_obj, &by_slot, schema.edgeTo(x, user.vpiLhs), u);
                        try addMentions(gpa, d, &by_obj, &by_slot, schema.edgeTo(x, user.vpiRhs), u);
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
fn addReach(gpa: std.mem.Allocator, d: *const Design, out: *std.ArrayList([2]u32), at: ObjId, u: u32) error{OutOfMemory}!void {
    if (at == .none) return;
    try out.append(gpa, .{ at.index(), u });
    const x = d.obj(at);
    if (x.kind != .code) return;
    switch (x.vtype) {
        user.vpiPartSelect, user.vpiIndexedPartSelect, user.vpiNetBit, user.vpiRegBit => {},
        else => return, // else: only a select names a part of another object
    }
    const parent = schema.edgeTo(x, user.vpiParent);
    if (parent != .none) try out.append(gpa, .{ parent.index(), u });
}

/// `mentions`' walk from `e`, inverted: every row it visits, and the slot of
/// every non-`.code` one, lead to candidate `u`.
fn addMentions(gpa: std.mem.Allocator, d: *const Design, by_obj: *std.ArrayList([2]u32), by_slot: *std.ArrayList([2]u32), e: ObjId, u: u32) error{OutOfMemory}!void {
    if (e == .none) return;
    try by_obj.append(gpa, .{ e.index(), u });
    const x = d.obj(e);
    if (x.kind != .code) {
        if (x.slot.get()) |s| try by_slot.append(gpa, .{ s, u });
        return;
    }
    switch (x.vtype) {
        user.vpiPartSelect, user.vpiNetBit, user.vpiRegBit => try addMentions(gpa, d, by_obj, by_slot, schema.edgeTo(x, user.vpiParent), u),
        user.vpiOperation, user.vpiFuncCall, user.vpiSysFuncCall => for (x.lists) |l| {
            if (l.tag != user.vpiOperand and l.tag != user.vpiArgument) continue;
            for (l.items) |i| try addMentions(gpa, d, by_obj, by_slot, i, u);
        },
        else => {}, // else: no other class is an expression with operands
    }
}

/// §26.6.6 i, j: activity belongs to the statement maintaining an override,
/// not to the object whose loads or drivers are being queried. In particular
/// a load is on the RHS, while the override registry is keyed by the LHS.
fn activeOverride(d: *const Design, o: *const Obj) bool {
    if (schema.coldOf(o).override_expr == .none) return false;
    const r = run.attached() orelse return false;
    var it = r.assigns.layers.valueIterator();
    while (it.next()) |layers| {
        if (if (o.vtype == user.vpiForce) layers.force else layers.assign) |range|
            if (overrideRange(d, o, r, range)) return true;
        if (o.vtype == user.vpiForce) for (layers.parts.items) |part|
            if (overrideRange(d, o, r, part.range)) return true;
    }
    return false;
}

fn overrideRange(d: *const Design, o: *const Obj, r: *const sim.digital.Run, range: sim.digital.PcRange) bool {
    // A VPI force has an empty range; it activates no HDL source statement.
    if (range.start == range.end) return false;
    if (r.instanceOf(r.program.scope_of.items[range.start]) != d.scope(o.owner).engine) return false;
    return switch (r.program.code.items[range.start]) {
        .override_eval => |op| op.value == schema.coldOf(o).override_expr and op.force == (o.vtype == user.vpiForce),
        else => false, // else: only an override_eval maintains a procedural continuous assignment
    };
}

/// Does expression `e` read `target`'s storage: is it the same slot (or the
/// same object), a select of it, or an operation or call with such an
/// operand?
fn mentions(d: *const Design, e: ObjId, target: *const Obj) bool {
    if (e == .none) return false;
    const x = d.obj(e);
    if (x == target or (x.slot != .none and x.slot == target.slot and x.kind != .code)) return true;
    if (x.kind != .code) return false;
    switch (x.vtype) {
        user.vpiPartSelect, user.vpiNetBit, user.vpiRegBit => return mentions(d, schema.edgeTo(x, user.vpiParent), target),
        user.vpiOperation, user.vpiFuncCall, user.vpiSysFuncCall => for (x.lists) |l| {
            if (l.tag != user.vpiOperand and l.tag != user.vpiArgument) continue;
            for (l.items) |i| if (mentions(d, i, target)) return true;
        },
        else => {}, // else: no other class is an expression with operands
    }
    return false;
}
