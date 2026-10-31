//! One-to-many traversal: a reference handle and a type -> a heap `Iter`
//! over object indices (or over handles it owns), live while it is a key of
//! `Design.iters`: vpi_scan frees it on exhaustion, vpi_free_object on
//! request. The relations computed per call are reverse_index.zig's.
//! Cites: VAMS-2023 §12.23, §12.35, §12.4, §11.6; IEEE 1364-2005 §26.6.39,
//! §26.6.43.
//!
//! Contents:
//! - `pub fn vpi_iterate(obj_type: c_int, ref: abi.vpiHandle) abi.vpiHandle`
//! - `pub fn oomIter() abi.vpiHandle`
//! - `pub fn ownedIter(d: *Design, out: *std.ArrayList(abi.vpiHandle)) abi.vpiHandle`
//! - `pub fn vpi_scan(itr: abi.vpiHandle) abi.vpiHandle`
//! - `pub fn destroyIter(d: *Design, it: *Iter) void`

const std = @import("std");
const abi = @import("abi.zig");
const attribute = @import("attribute.zig");
const callback = @import("callback.zig");
const delays = @import("delays.zig");
const reverse_index = @import("reverse_index.zig");
const run = @import("run.zig");
const schema = @import("schema.zig");
const status = @import("status.zig");
const systf = @import("systf.zig");
const trust = @import("trust.zig");
const user = @import("vpi_user.zig");
const Design = @import("Design.zig");
const Iter = schema.Iter;

/// "If there are no objects of type `type` associated with the reference handle
/// `ref`, then `vpi_iterate()` shall return NULL."
///
/// So an EMPTY set and an UNSUPPORTED relationship have the same return value,
/// and the difference between them is the error status: a module with no regs
/// is NULL with no error, `vpi_iterate(vpiPort, some_reg)` is NULL with one. An
/// application that does not check errors sees the documented empty loop either
/// way; one that does can tell a fact about the design from a limit of VerA's.
pub export fn vpi_iterate(obj_type: c_int, ref: abi.vpiHandle) abi.vpiHandle {
    const h = iterate(obj_type, ref);
    if (trust.asIter(h)) |it| {
        it.use = ref;
        it.ty = obj_type;
    }
    return h;
}

pub fn oomIter() abi.vpiHandle {
    status.fail("NOMEM", "vpi_iterate: out of memory", .{});
    return null;
}

/// `newHandleIter` over `out`'s handles, which it takes: `out` is left
/// empty, or freed when the slice cannot be made.
pub fn ownedIter(d: *Design, out: *std.ArrayList(abi.vpiHandle)) abi.vpiHandle {
    const handles = out.toOwnedSlice(d.gpa) catch {
        out.deinit(d.gpa);
        return oomIter();
    };
    return newHandleIter(d, handles);
}

/// "Once `vpi_scan()` returns NULL, the iterator handle is no longer valid and
/// can not be used again" (§12.35), and §12.4 spells out the consequence: "The
/// iterator object shall automatically be freed when vpi_scan() returns NULL".
///
/// So exhaustion frees the iterator, and scanning it again is an invalid-handle
/// error rather than a use-after-free.
pub export fn vpi_scan(itr: abi.vpiHandle) abi.vpiHandle {
    const d = status.enter("vpi_scan") orelse return null;
    const it = trust.asIter(itr) orelse {
        status.fail("BADHANDLE", "vpi_scan: {s} is not a handle to a live iterator", .{trust.describe(itr)});
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
    return trust.handleOf(&d.objects[idx]);
}

/// Frees `it` and the handles it owns, and removes it from `d.iters` first,
/// so its handle is invalid (`asIter` null) before the memory is.
pub fn destroyIter(d: *Design, it: *Iter) void {
    _ = d.iters.remove(@intFromPtr(it));
    if (it.handles) |hs| d.gpa.free(hs);
    d.gpa.destroy(it);
}

// ---- private ----

fn iterate(obj_type: c_int, ref: abi.vpiHandle) abi.vpiHandle {
    const d = status.enter("vpi_iterate") orelse return null;
    if (status.unansweredType(obj_type)) |u| {
        status.failUnanswered("vpi_iterate", u);
        return null;
    }
    // IEEE 1364-2005 §26.6.39: object and time-queue associations, or a
    // NULL reference for global callbacks. Time queues are not Design rows.
    if (obj_type == user.vpiCallback) {
        if (ref != null and trust.asObj(ref) == null and run.asQueue(ref) == null) {
            _ = status.object("vpi_iterate", ref);
            return null;
        }
        return newHandleIter(d, callback.all(d.gpa, ref) catch return oomIter());
    }
    // §11.6.1 NOTE 1: "Top-level modules shall be accessed using vpi_iterate()
    // with a NULL reference object."
    if (ref == null) {
        if (obj_type == user.vpiUserSystf) {
            return newHandleIter(d, systf.all(d.gpa) catch return oomIter());
        }
        if (obj_type == user.vpiTimeQueue) {
            return newHandleIter(d, run.timeQueues(d.gpa) catch return oomIter());
        }
        // §11.6.2's circled arrows: disciplines and natures are design-wide.
        // An empty set (a digital design) is NULL with no error (§12.23).
        if (obj_type == user.vpiDiscipline or obj_type == user.vpiNature or obj_type == user.vpiUdpDefn) {
            const items = if (obj_type == user.vpiDiscipline) d.disciplines else if (obj_type == user.vpiNature) d.natures else d.udp_defns;
            return if (items.len == 0) null else newIter(d, items);
        }
        if (obj_type != user.vpiModule) {
            status.fail("NOTRAVERSE", "vpi_iterate: {d} is not iterable from a NULL reference", .{obj_type});
            return null;
        }
        return newIter(d, d.top_modules);
    }
    // IEEE 1364-2005 §26.6.16: inter-module path ->> its two ports, the
    // output port first.
    if (delays.asPath(ref)) |m| {
        if (obj_type == user.vpiPort) return newIter(d, &m.ports);
        status.fail("NOTRAVERSE", "vpi_iterate: an inter-module path is the reference object of vpiPort only, not {d}", .{obj_type});
        return null;
    }
    const o = status.object("vpi_iterate", ref) orelse return null;
    if (obj_type == user.vpiAttribute and attribute.supports(o))
        return if (schema.coldOf(o).attributes.len == 0) null else newIter(d, schema.coldOf(o).attributes);
    if (obj_type == user.vpiUse) return reverse_index.uses(d, o);
    // A behavioural object's double arrows are its `lists` rows, as are a
    // vector's bits. An empty row is an empty set (NULL, no error —
    // §11.6.23 NOTE 2's default case item among them); a tag a behavioural
    // object has no row for is no relationship.
    for (o.lists) |l| if (l.tag == obj_type) return if (l.items.len == 0) null else newIter(d, l.items);
    if (o.kind == .code) {
        status.fail("NOTRAVERSE", "vpi_iterate: a {s} is the reference object of no relationship {d}", .{ schema.typeName(o.vtype), obj_type });
        return null;
    }
    // §11.6.8 net ->> port, IEEE 1364-2005 §26.6.6: the ports of the net's
    // own module whose low connection it is. None is an empty set — NULL
    // without an error (§12.23) — not a missing relationship.
    if (o.kind == .net and obj_type == user.vpiPort) return reverse_index.lowConnPorts(d, o);
    // §11.6.11 (IEEE 1364 §26.6.7-9): an array's elements. A memory's words by
    // the legacy vpiMemoryWord tag or as vpiReg; a variable array's by
    // vpiVarSelect; an instance array's members by vpiModule.
    const elements: bool = switch (o.kind) {
        .reg_array => obj_type == user.vpiMemoryWord or obj_type == user.vpiReg,
        .var_array => obj_type == user.vpiVarSelect,
        .net_array => obj_type == user.vpiNet,
        .module_array => obj_type == user.vpiModule,
        else => false, // else: only the four array classes hold elements
    };
    if (elements) return newIter(d, schema.coldOf(o).members);
    if (obj_type == user.vpiRange and schema.coldOf(o).range.len != 0) return newIter(d, schema.coldOf(o).range);
    // The analog double arrows: node ->> net (§11.6.5), nature ->> nature
    // tagged vpiChild and nature ->> discipline (§11.6.2).
    const analog: ?[]const u32 = switch (o.kind) {
        .node => if (obj_type == user.vpiNet) schema.coldOf(o).nets else null,
        .nature => if (obj_type == user.vpiChild) schema.coldOf(o).children else if (obj_type == user.vpiDiscipline) schema.coldOf(o).users else null,
        else => null, // else: no other class but module draws a double arrow VerA holds
    };
    if (analog) |items| return if (items.len == 0) null else newIter(d, items);
    switch (obj_type) {
        user.vpiDriver, user.vpiLoad, user.vpiLocalDriver, user.vpiLocalLoad => if (o.kind == .net or o.kind == .reg)
            return reverse_index.driversLoads(d, o, obj_type == user.vpiDriver or obj_type == user.vpiLocalDriver, obj_type == user.vpiLocalDriver or obj_type == user.vpiLocalLoad),
        else => {},
    }
    if (o.kind != .module) {
        status.fail("NOTRAVERSE", "vpi_iterate: a {s} is the reference object of no one-to-many relationship {d}", .{ @tagName(o.kind), obj_type });
        return null;
    }
    const s = &d.scopes[o.scope];
    for (s.lists) |l| if (l.tag == obj_type) return if (l.items.len == 0) null else newIter(d, l.items);
    const items: []const u32 = switch (obj_type) {
        user.vpiModule => s.children,
        user.vpiInternalScope => s.internal,
        user.vpiPort => s.ports,
        user.vpiNet => s.nets,
        user.vpiReg => s.regs,
        user.vpiParameter => s.params,
        user.vpiIntegerVar => s.integers,
        user.vpiRealVar => s.reals,
        // IEEE 1364 §26.6.9: the legacy vpiMemory method returns the reg
        // arrays, as vpiRegArray objects.
        user.vpiMemory, user.vpiRegArray => s.reg_arrays,
        user.vpiNetArray => s.net_arrays,
        user.vpiVariables => s.variables,
        user.vpiModuleArray => s.module_arrays,
        // §11.6.1's `nodes` and `branches` classes (§11.6.5, §11.6.6).
        user.vpiNode => s.nodes,
        user.vpiBranch => s.branches,
        else => {
            status.fail("NOTRAVERSE", "vpi_iterate: no one-to-many relationship {d} from a module", .{obj_type});
            return null;
        },
    };
    if (items.len == 0) return null;
    return newIter(d, items);
}

/// An iterator over `handles`, which it takes ownership of; NULL, with no
/// error, for none (§12.23).
fn newHandleIter(d: *Design, handles: []abi.vpiHandle) abi.vpiHandle {
    if (handles.len == 0) {
        d.gpa.free(handles);
        return null;
    }
    const h = newIter(d, &.{});
    if (trust.asIter(h)) |it| it.handles = handles else d.gpa.free(handles);
    return h;
}

fn newIter(d: *Design, items: []const u32) abi.vpiHandle {
    const it = d.gpa.create(Iter) catch return oomIter();
    it.* = .{ .items = items };
    d.iters.put(d.gpa, @intFromPtr(it), it) catch {
        d.gpa.destroy(it);
        return oomIter();
    };
    return @ptrCast(it);
}
