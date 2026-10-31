//! One installed object model: the frozen rows (`objects`, `cold`,
//! `scopes`), the design-wide sets, the name index, and the routines' state
//! that lives as long as the model (live iterators, reverse indexes, declared
//! partials, user data). Built by model_analog.zig or model_digital.zig and
//! frozen by model.zig; freed by `deinit`.
//! Cites: VAMS-2023 §11.6.1 NOTE 1, §11.6.2, §11.6.14, §12.21; IEEE 1364-2005
//! §26.6.1 Details b, §27.19, §27.31.
//!
//! Contents:
//! - `pub fn indexOf(d: *const Design, o: *const Obj) u32`
//! - `pub fn deinit(self: *Design) void`

const std = @import("std");
const Ast = @import("frontend").Ast;
const reverse_index = @import("reverse_index.zig");
const schema = @import("schema.zig");
const systf = @import("systf.zig");
const Cold = schema.Cold;
const Iter = schema.Iter;
const Obj = schema.Obj;
const Pair = systf.Pair;
const Relations = reverse_index.Relations;
const Scope = schema.Scope;
const UserKey = systf.UserKey;

gpa: std.mem.Allocator,

/// Owns every name string and every slice below.
arena: std.heap.ArenaAllocator,

/// Allocated once and never resized: every object handle points into it,
/// and `object` accepts a pointer only if it lands here on an element
/// boundary. One object always yields one pointer, but applications must
/// still compare with `vpi_compare_objects` (§12.3).
objects: []Obj = &.{},

/// The `Cold` rows `Obj.cold` indexes, in no particular order.
cold: []Cold = &.{},

scopes: []Scope = &.{},

/// §11.6.1 NOTE 1 — what `vpi_iterate(vpiModule, NULL)` walks. One entry:
/// `Elaborate.pickTop` elaborates exactly one design root.
top_modules: []const u32 = &.{},

/// §11.6.2's two top-level sets: `vpi_iterate(vpiDiscipline, NULL)` and
/// `vpi_iterate(vpiNature, NULL)`, in declaration order. Empty for a
/// digital design, which declares neither.
disciplines: []const u32 = &.{},

natures: []const u32 = &.{},

/// §11.6.14's circled arrow: `vpi_iterate(vpiUdpDefn, NULL)`.
udp_defns: []const u32 = &.{},

/// How `vpi_handle_by_name` searches from a scope. Verilog-AMS §12.21
/// uses "the scope search rules defined by the Verilog-AMS HDL", §6.7's
/// upward walk; IEEE 1364-2005 §27.19 "search within that scope only".
/// The model over a 1364 digital run takes the second.
search_up: bool = true,

/// IEEE 1364-2005 §26.6.1 Details b: what vpiTimeUnit and
/// vpiTimePrecision of a NULL object answer, "the smallest time precision
/// of all modules". Null in the analog model.
finest: ?i8 = null,

/// The parsed source `src_expr`/`src_stmt` index, for a digital design
/// (the run it is read from outlives the model). Null for the analog
/// model, whose compilation may be freed once `open` returns.
file: ?*const Ast.SourceFile = null,

/// §11.6 `vpiFullName` → object index. Every object has one and they are
/// unique, which is what makes §12.21 a lookup rather than a tree walk.
by_name: std.StringHashMapUnmanaged(u32) = .empty,

/// The live iterators, keyed by handle value.
iters: std.AutoHashMapUnmanaged(usize, *Iter) = .empty,

/// iterate.zig's reverse indexes, built on first use; owned (`gpa`).
relations: ?Relations = null,

/// §12.32.2 the partials each analog call's derivtf declared, by call
/// object index (`systf.buildCalls`); the slices are owned (`gpa`).
partials: std.AutoHashMapUnmanaged(u32, []const Pair) = .empty,

/// IEEE 1364-2005 §27.31 user data, by call object index and the host
/// instance whose calltf was running (`systf.active_inst`).
userdata: std.AutoHashMapUnmanaged(UserKey, ?*anyopaque) = .empty,

const Design = @This();

/// The index of row `o`, which must point into `objects` (a pointer
/// `asObj` returned, or `&objects[i]`); any other pointer is a wrong
/// index or a safety panic.
pub fn indexOf(d: *const Design, o: *const Obj) u32 {
    return @intCast((@intFromPtr(o) - @intFromPtr(d.objects.ptr)) / @sizeOf(Obj));
}

/// Frees the model and every live iterator; all handles become invalid.
pub fn deinit(self: *Design) void {
    var pit = self.partials.valueIterator();
    while (pit.next()) |p| self.gpa.free(p.*);
    self.partials.deinit(self.gpa);
    self.userdata.deinit(self.gpa);
    var it = self.iters.valueIterator();
    while (it.next()) |p| {
        if (p.*.handles) |hs| self.gpa.free(hs);
        self.gpa.destroy(p.*);
    }
    self.iters.deinit(self.gpa);
    if (self.relations) |*r| r.deinit(self.gpa);
    self.by_name.deinit(self.gpa);
    self.gpa.free(self.objects);
    self.gpa.free(self.cold);
    self.gpa.free(self.scopes);
    self.arena.deinit();
    self.* = undefined;
}
