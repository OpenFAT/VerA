//! One-to-one traversal and lookup: §12.19 vpi_handle, §12.21
//! vpi_handle_by_name, §12.20 vpi_handle_by_index and IEEE 1364-2005 §27.18
//! vpi_handle_by_multi_index. A handle plus a type, a name or an index -> the
//! handle of another `Design.objects` row, answered from the rows `open`
//! froze; nothing here allocates. NULL with no error is "no such object";
//! NULL with an error is a relationship the class's diagram does not draw.
//! §12.22 vpi_handle_multi is systf.zig's.

const std = @import("std");
const Elaborate = @import("vera").Elaborate;
const code = @import("code.zig");
const root = @import("root.zig");
const coldOf = root.coldOf;
const run = @import("run.zig");
const systf = @import("systf.zig");

const Obj = root.Obj;
const asIter = root.asIter;
const refused = root.refused;
const enter = root.enter;
const fail = root.fail;
const handleOf = root.handleOf;
const name_buf_len = root.name_buf_len;
const no_obj = root.no_obj;
const object = root.object;
const vpiActiveTimeFormat = root.vpiActiveTimeFormat;
const vpiBit = root.vpiBit;
const vpiBranch = root.vpiBranch;
const vpiDiscipline = root.vpiDiscipline;
const vpiFlow = root.vpiFlow;
const vpiFlowNature = root.vpiFlowNature;
const vpiHandle = root.vpiHandle;
const vpiIndex = root.vpiIndex;
const vpiModule = root.vpiModule;
const vpiModuleArray = root.vpiModuleArray;
const vpiNature = root.vpiNature;
const vpiNegNode = root.vpiNegNode;
const vpiNode = root.vpiNode;
const vpiParent = root.vpiParent;
const vpiPosNode = root.vpiPosNode;
const vpiPotential = root.vpiPotential;
const vpiPotentialNature = root.vpiPotentialNature;
const vpiScope = root.vpiScope;
const vpiUse = root.vpiUse;

// ---------------------------------------------------------------------------
// §12.19 vpi_handle — one-to-one traversal
// ---------------------------------------------------------------------------

/// "Return the object of type `type` associated with object `ref`."
///
/// Two tags default to the module owner read from two diagrams:
/// `vpiScope` is §11.6.12's "scope has a double-headed relationship with the
/// parameter object", `vpiModule` is §11.6.4's "ports has a one-to-one
/// relationship back to module". A module's own containing scope is its parent
/// instance, and the top module has none — NULL, and NOT an error: "no such
/// object" is this routine's ordinary answer at the root of the hierarchy.
/// An explicit vpiScope edge takes precedence for a lexical containing scope.
pub export fn vpi_handle(obj_type: c_int, ref: vpiHandle) vpiHandle {
    // §11.6.16 NOTE 1: the call whose compiletf/sizetf/derivtf is running
    // (systf.buildCalls). Outside one the answer is "no such object", which
    // is NULL and not an error — the same answer vpiScope gives at the root.
    if (obj_type == systf.vpiSysTfCall and ref == null) {
        if (refused("vpi_handle")) return null;
        const at = systf.active orelse return null;
        return handleOf(&root.design.?.objects[at]);
    }
    const d = enter("vpi_handle") orelse return null;
    if (root.unansweredType(obj_type)) |u| {
        root.failUnanswered("vpi_handle", u);
        return null;
    }
    // IEEE 1364-2005 §26.6.16 draws an inter-module path's ports as a
    // double arrow only.
    if (@import("delays.zig").asPath(ref) != null) {
        fail("NOTRAVERSE", "vpi_handle: an inter-module path has no one-to-one relationship {d}; vpi_iterate(vpiPort) reaches its ports", .{obj_type});
        return null;
    }
    // IEEE 1364-2005 §26.6.43: an iterator's one edge, NULL when it was made
    // from a NULL reference (Details b).
    if (asIter(ref)) |it| {
        if (obj_type == vpiUse) return it.use;
        fail("NOTRAVERSE", "vpi_handle: an iterator has no relationship {d}", .{obj_type});
        return null;
    }
    // IEEE 1364-2005 §26.6.41's circled single arrow. Before any invocation
    // there is no active call, even though its source object already exists.
    if (obj_type == vpiActiveTimeFormat and ref == null) {
        const r = run.attached() orelse return null;
        const active = r.active_timeformat orelse return null;
        for (d.objects) |*call| {
            if (call.vtype != code.vpiSysTaskCall or call.src_stmt == .none) continue;
            const owner = call.owner.get() orelse continue;
            if (d.scopes[owner].engine == active.scope and r.file.stmtTok(call.src_stmt) == active.tok)
                return handleOf(call);
        }
        fail("NOCALL", "vpi_handle: the active $timeformat call has no VPI source object", .{});
        return null;
    }
    const o = object("vpi_handle", ref) orelse return null;
    // §11.6.2/§11.6.5–§11.6.7's single arrows. Each edge is answered only
    // from the classes whose diagram draws it; from any other class it is
    // NOTRAVERSE, like every relationship a diagram does not draw.
    // §11.6.3/§11.6.16–§11.6.24: a behavioural object's single arrows are
    // its own `edges` rows (code.zig), as are the few a declared object
    // carries (a port's vpiHighConn, a range's bounds). A tag it does not
    // carry falls through to the containing-scope edge, and past that is
    // NOTRAVERSE.
    for (o.edges) |e| if (e.tag == obj_type) {
        if (e.to == no_obj) return null;
        return handleOf(&d.objects[e.to]);
    };
    // §11.6.16: sys task/func call -> user systf, for a name some
    // application registered (NOTE 3); NULL for a built-in one.
    if (o.kind == .code and obj_type == systf.vpiUserSystf and (o.vtype == code.vpiSysTaskCall or o.vtype == code.vpiSysFuncCall)) {
        const reg = systf.regOf(o) orelse return null;
        return @ptrCast(reg);
    }
    if (analogEdge(o, obj_type)) |edge| {
        const at = edge orelse return null;
        return handleOf(&d.objects[at]);
    }
    switch (obj_type) {
        vpiScope, vpiModule => {
            // A discipline, nature or quantity is not declared in a module:
            // no module arrow leaves it (§11.6.2, §11.6.7).
            switch (o.kind) {
                .discipline, .nature, .quantity => return noEdge(obj_type, o),
                .module, .port, .net, .reg, .parameter, .integer, .real_var, .time_var, .reg_array, .var_array, .net_array, .word, .var_select, .module_array, .constant, .node, .branch => {},
                // An expression is in no scope (§11.6.19 draws no scope
                // arrow); a statement, process or declaration is (§11.6.21
                // stmt -> scope).
                .code => if (o.owner == .none) return noEdge(obj_type, o),
            }
            const owner = o.owner.get() orelse return null;
            return handleOf(&d.objects[owner]);
        },
        // §11.6.11: a word or variable select's array. A module in an
        // instance array reaches its array by vpiModuleArray (§26.6.1).
        vpiParent, vpiModuleArray => {
            if (obj_type == vpiParent and o.kind != .word and o.kind != .var_select) return noEdge(obj_type, o);
            if (obj_type == vpiModuleArray and o.kind != .module) return noEdge(obj_type, o);
            const p = o.parent.get() orelse return null;
            return handleOf(&d.objects[p]);
        },
        // The index expression of an element. A module that is not in an
        // array has none, and that is an answer — NULL — not an error.
        vpiIndex => {
            switch (o.kind) {
                .word, .var_select, .module => {},
                else => return noEdge(obj_type, o),
            }
            const c = o.index.get() orelse return null;
            return handleOf(&d.objects[c]);
        },
        else => {
            fail("NOTRAVERSE", "vpi_handle: no one-to-one relationship {d} from a {s}", .{ obj_type, @tagName(o.kind) });
            return null;
        },
    }
}

/// The analog one-to-one edge `obj_type` from `o`: null when `o`'s class
/// draws no such edge (the caller goes on to the other relationships), else
/// the target — itself null for "no such object".
fn analogEdge(o: *const Obj, obj_type: c_int) ??u32 {
    return switch (o.kind) {
        .net => switch (obj_type) {
            vpiNode => coldOf(o).node,
            vpiDiscipline => coldOf(o).disc,
            else => null, // else: every other tag is one of the net's non-analog edges
        },
        .node => switch (obj_type) {
            vpiDiscipline => coldOf(o).disc,
            else => null, // else: vpiModule/vpiScope are the shared owner edge
        },
        .branch => switch (obj_type) {
            vpiPosNode => coldOf(o).pos,
            vpiNegNode => coldOf(o).neg,
            vpiDiscipline => coldOf(o).disc,
            vpiFlow => coldOf(o).flow,
            vpiPotential => coldOf(o).pot,
            else => null, // else: vpiModule/vpiScope are the shared owner edge
        },
        .quantity => switch (obj_type) {
            vpiBranch => coldOf(o).branch,
            vpiNature => coldOf(o).nature,
            else => null, // else: a quantity draws no other single arrow
        },
        .discipline => switch (obj_type) {
            vpiFlowNature => coldOf(o).flow,
            vpiPotentialNature => coldOf(o).pot,
            else => null, // else: a discipline draws no other single arrow
        },
        .nature => switch (obj_type) {
            vpiParent => coldOf(o).nature,
            else => null, // else: a nature draws no other single arrow
        },
        .port => switch (obj_type) {
            vpiNode => coldOf(o).node,
            else => null, // else: a port's other edges are the shared owner edge
        },
        .module, .reg, .parameter, .integer, .real_var, .time_var, .reg_array, .var_array, .net_array, .word, .var_select, .module_array, .constant, .code => null,
    };
}

fn noEdge(obj_type: c_int, o: *const Obj) vpiHandle {
    fail("NOTRAVERSE", "vpi_handle: a {s} has no relationship {d}", .{ @tagName(o.kind), obj_type });
    return null;
}

// ---------------------------------------------------------------------------
// §12.21 vpi_handle_by_name
// ---------------------------------------------------------------------------

/// "The name can be hierarchical or simple. If `scope` is NULL, then `name`
/// shall be searched for from the top level of hierarchy. Otherwise, `name`
/// shall be searched for from `scope` using the scope search rules defined by
/// the Verilog-AMS HDL."
///
/// §6.7's search rule is upward: a name not found in the enclosing scope is
/// looked for in ITS parent, and so on to the top. That loop is the whole of
/// the `scope != NULL` arm. With a NULL scope the name is absolute and matched
/// against `vpiFullName` — the property §12.21 says the routine "can be applied
/// to all objects with". A digital run searches `scope` alone instead
/// (`Design.search_up`).
pub export fn vpi_handle_by_name(name: [*c]const u8, scope: vpiHandle) vpiHandle {
    const d = enter("vpi_handle_by_name") orelse return null;
    if (name == null) {
        fail("BADNAME", "vpi_handle_by_name: the name is NULL", .{});
        return null;
    }
    const want = std.mem.span(name);
    if (scope) |s| {
        const from = object("vpi_handle_by_name", s) orelse return null;
        // §6.7's upward search. `scope` need not be a module: the scope of a
        // non-module object is the one it is declared in, and the scope of a
        // module is itself.
        var at: ?u32 = if (from.kind == .module) from.scope else from.owner.get();
        while (at) |sc| : (at = if (d.search_up) d.scopes[sc].parent else null) {
            var buf: [name_buf_len]u8 = undefined;
            const full = std.mem.print(&buf, "{s}{c}{s}", .{ d.objects[sc].full, Elaborate.sep, want }) catch continue;
            if (d.by_name.get(full)) |i| return handleOf(&d.objects[i]);
        }
        if (!d.search_up) {
            fail("NONAME", "vpi_handle_by_name: `{s}` names no object in that scope", .{want});
            return null;
        }
        // The search ends at the top, where a hierarchical name is an absolute
        // one: `vpi_handle_by_name("top.u.k", any_scope)` is §12.21's
        // "hierarchical" spelling and resolves as it would with a NULL scope.
        if (d.by_name.get(want)) |i| return handleOf(&d.objects[i]);
        fail("NONAME", "vpi_handle_by_name: `{s}` names no object from that scope", .{want});
        return null;
    }
    if (d.by_name.get(want)) |i| return handleOf(&d.objects[i]);
    fail("NONAME", "vpi_handle_by_name: `{s}` names no object in the design", .{want});
    return null;
}

// ---------------------------------------------------------------------------
// §12.20 vpi_handle_by_index
// ---------------------------------------------------------------------------

/// "Return a handle to an object based on the index number of the object within
/// a parent object. ... This function can be used to access all objects which
/// can access an expression using `vpiIndex`."
///
/// The indexed objects are §26.6.11 named events and §11.6.11 array elements — memory words and
/// variable selects — the members of a §6.2.2 instance array ("for a memory
/// word, obj is the associated memory"), and the bits of a digital vector
/// net or reg (IEEE 1364-2005 §26.6.6/§26.6.7). `index` is the element's own
/// declared index, the value its vpiIndex constant holds.
///
/// ponytail: port bits and the analog model's reg bits have no bit objects,
/// so indexing one of those vectors is still §12.2's error indication.
pub export fn vpi_handle_by_index(obj: vpiHandle, index: c_int) vpiHandle {
    const d = enter("vpi_handle_by_index") orelse return null;
    const o = object("vpi_handle_by_index", obj) orelse return null;
    // §12.32.3's and §12.22.2's own listings: on a system task or function
    // call, index 0 is "the returned value" — the function call itself, which
    // is what §12.30 puts a return value on — and 1..n are its arguments.
    if (o.kind == .code and (o.vtype == code.vpiSysFuncCall or o.vtype == code.vpiSysTaskCall)) {
        if (index == 0 and o.vtype == code.vpiSysFuncCall) return handleOf(o);
        for (o.lists) |l| if (l.tag == code.vpiArgument) {
            if (index >= 1 and index <= l.items.len) return handleOf(&d.objects[l.items[@intCast(index - 1)]]);
        };
        fail("NOINDEX", "vpi_handle_by_index: `{s}` has no argument {d}", .{ o.name, index });
        return null;
    }
    if (coldOf(o).members.len != 0) {
        if (o.kind == .code and o.vtype == code.vpiNamedEventArray and coldOf(o).range.len != 1) {
            fail("NOINDEX", "vpi_handle_by_index: `{s}` requires {d} event-array indices", .{ o.full, coldOf(o).range.len });
            return null;
        }
        for (coldOf(o).members) |m| {
            const c = d.objects[m].index.get() orelse continue;
            if (d.objects[c].value.?.int == index) return handleOf(&d.objects[m]);
        }
        fail("NOINDEX", "vpi_handle_by_index: `{s}` has no element {d}", .{ o.full, index });
        return null;
    }
    if (o.kind != .code) for (o.lists) |l| if (l.tag == vpiBit) {
        for (l.items) |bit| {
            const ix = root.edgeTo(&d.objects[bit], vpiIndex);
            if (ix != no_obj and d.objects[ix].value.?.int == index) return handleOf(&d.objects[bit]);
        }
        fail("NOINDEX", "vpi_handle_by_index: `{s}` has no bit {d}", .{ o.full, index });
        return null;
    };
    fail(
        "NOINDEX",
        "vpi_handle_by_index: a {s} has no indexed object at {d} — bit-level objects are not modelled",
        .{ @tagName(o.kind), index },
    );
    return null;
}

/// IEEE 1364-2005 §27.18: "If the indices provided do not lead to the
/// construction of a legal Verilog index select expression, the routine shall
/// return a null handle." One index is vpi_handle_by_index.
///
/// Named event arrays accept one index per dimension. Other array classes
/// still route only a single index through vpi_handle_by_index; their
/// multidimensional selection remains a VerA limit.
pub export fn vpi_handle_by_multi_index(obj: vpiHandle, num_index: c_int, index_array: ?[*]const c_int) vpiHandle {
    const d = enter("vpi_handle_by_multi_index") orelse return null;
    const o = object("vpi_handle_by_multi_index", obj) orelse return null;
    const idx = index_array orelse {
        fail("NOINDEX", "vpi_handle_by_multi_index: index_array is NULL", .{});
        return null;
    };
    if (o.kind == .code and o.vtype == code.vpiNamedEventArray) {
        if (num_index > 0 and num_index == coldOf(o).range.len) for (coldOf(o).members) |m| {
            for (d.objects[m].lists) |l| {
                if (l.tag != vpiIndex) continue;
                const matches = for (l.items, 0..) |ix, k| {
                    if (d.objects[ix].value.?.int != idx[l.items.len - 1 - k]) break false;
                } else true;
                if (matches) return handleOf(&d.objects[m]);
            }
        };
        fail("NOINDEX", "vpi_handle_by_multi_index: no event in `{s}` has the supplied indices", .{o.full});
        return null;
    }
    if (num_index != 1) {
        fail("NOINDEX", "vpi_handle_by_multi_index: `{s}` takes one index here, not {d} (a VerA limit)", .{ o.full, num_index });
        return null;
    }
    return vpi_handle_by_index(obj, idx[0]);
}
