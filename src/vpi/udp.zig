//! The source's UDP definitions -> design-wide vpiUdpDefn rows, each with
//! its io decls, its table entries and its initial statement.
//! Cites: VAMS-2023 §11.6.14; IEEE 1364-2005 §26.6.14 Details a, A.5.3.
//!
//! Contents:
//! - `pub fn udpDefns( gpa: std.mem.Allocator, arena: std.mem.Allocator, objects: *Rows, file: *const Ast.SourceFile, attrs: *const ByOwner, out: *std.AutoHashMapUnmanaged(Ast.StrId, ObjId), ) Error![]const ObjId`

const std = @import("std");
const Ast = @import("frontend").Ast;
const code_tables = @import("code_tables.zig");
const schema = @import("schema.zig");
const ObjId = schema.ObjId;
const user = @import("vpi_user.zig");
const Builder = @import("Builder.zig");
const attribute = @import("attribute.zig");
const model = @import("model.zig");
const session = @import("session.zig");
const ByOwner = attribute.ByOwner;
const Edge = schema.Edge;
const Error = session.Error;
const List = schema.List;
const Prop = schema.Prop;
const Rows = model.Rows;
const ScopeLists = code_tables.ScopeLists;

/// §11.6.14 the UDP definitions of `file`, design-wide (the diagram's
/// circled arrow): each with its io decls (the output, then the inputs) and
/// its table entries, whose vpiSize is "number of symbol entries" — one per
/// input field (an edge `(01)` is one field), one for the current state of
/// a sequential entry, one for the output. An entry's value is its
/// decompilation, `1 1 : ? : 1`: the fields space-separated, a colon between
/// columns (§26.6.14 Details a). Asserts that `out` starts empty and that
/// every definition has its output port (A.5.1).
pub fn udpDefns(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    objects: *Rows,
    file: *const Ast.SourceFile,
    attrs: *const ByOwner,
    out: *std.AutoHashMapUnmanaged(Ast.StrId, ObjId),
) Error![]const ObjId {
    std.debug.assert(out.count() == 0);
    const defns = try arena.alloc(ObjId, file.udps.len);
    for (file.udps, defns) |*u, *at| {
        std.debug.assert(u.ports.len >= 1);
        const ios = try arena.alloc(ObjId, u.ports.len);
        for (u.ports, ios, 0..) |p, *io, k| {
            io.* = objects.next();
            try objects.append(.{ .kind = .code, .owner = .none, .name = try arena.dupe(u8, file.str(p)), .full = "", .vtype = user.vpiIODecl, .props = try code_tables.ioProps(arena, if (k == 0) user.vpiOutput else user.vpiInput, 1, false) });
        }
        const rows = try arena.alloc(ObjId, u.rows.len);
        for (u.rows, rows) |r, *row| {
            var fields: c_int = 0;
            var in_edge = false;
            // Each input symbol and its separator, then two " : c" columns.
            var text: std.ArrayList(u8) = try .initCapacity(arena, 2 * r.inputs.len + 8);
            for (r.inputs) |c| switch (c) {
                ' ', '\t' => {},
                else => {
                    if (!in_edge and text.items.len != 0) text.appendAssumeCapacity(' ');
                    text.appendAssumeCapacity(c);
                    if (c == '(') in_edge = true;
                    if (c == ')') in_edge = false;
                    if (!in_edge) fields += 1;
                },
            };
            if (u.is_sequential) text.printAssumeCapacity(" : {c}", .{r.state});
            text.printAssumeCapacity(" : {c}", .{r.output});
            row.* = objects.next();
            try objects.append(.{ .kind = .code, .owner = .none, .name = "", .full = "", .vtype = user.vpiTableEntry, .value = .{ .str = text.items }, .props = try arena.dupe(Prop, &.{
                .{ .prop = user.vpiSize, .value = fields + @intFromBool(u.is_sequential) + 1 },
            }) });
        }
        // A.5.3's `initial output = init_val`: an initial process whose
        // statement assigns the output its io decl names.
        var init = ObjId.none;
        if (u.init != .none) {
            var no_names: std.StringHashMapUnmanaged(ObjId) = .empty;
            var no_lists: ScopeLists = .{};
            var b: Builder = .{ .gpa = gpa, .arena = arena, .objects = objects, .file = file, .names = &no_names, .top_name = "", .scope = 0, .path = "", .lists = &no_lists, .attrs = attrs };
            const rhs = try b.expr(u.init);
            const assign = objects.next();
            try objects.append(.{ .kind = .code, .owner = .none, .name = "", .full = "", .vtype = user.vpiAssignment, .edges = try arena.dupe(Edge, &.{
                .{ .tag = user.vpiLhs, .to = ios[0] },
                .{ .tag = user.vpiRhs, .to = rhs },
            }), .props = try arena.dupe(Prop, &.{.{ .prop = user.vpiBlocking, .value = 1 }}) });
            init = objects.next();
            try objects.append(.{ .kind = .code, .owner = .none, .name = "", .full = "", .vtype = user.vpiInitial, .edges = try arena.dupe(Edge, &.{.{ .tag = user.vpiStmt, .to = assign }}) });
        }
        at.* = objects.next();
        try objects.appendCold(.{
            .kind = .code,
            .owner = .none,
            .name = "",
            .full = "",
            .vtype = user.vpiUdpDefn,
            .props = try arena.dupe(Prop, &.{
                .{ .prop = user.vpiSize, .value = @intCast(u.ports.len - 1) },
                .{ .prop = user.vpiPrimType, .value = if (u.is_sequential) user.vpiSeqPrim else user.vpiCombPrim },
            }),
            .edges = try arena.dupe(Edge, &.{.{ .tag = user.vpiInitial, .to = init }}),
            .lists = try arena.dupe(List, &.{
                .{ .tag = user.vpiIODecl, .items = ios },
                .{ .tag = user.vpiTableEntry, .items = rows },
            }),
        }, .{ .def_name = try arena.dupe(u8, file.str(u.name)) });
        try out.put(gpa, u.name, at.*);
    }
    // A name defined twice keeps its last definition.
    std.debug.assert(out.count() <= defns.len);
    return defns;
}
