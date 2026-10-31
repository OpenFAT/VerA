//! Array-shaped rows: an array object and its elements (§11.6.10/§11.6.11,
//! IEEE 1364-2005 §26.6.6-§26.6.9), a range object (§26.6.10), a vector's bit
//! objects (§26.6.6 Details a, §26.6.7) and §6.2.2's instance arrays, each
//! appended to a builder's `Rows`.
//! Cites: VAMS-2023 §6.2.2, §11.6.10, §11.6.11; IEEE 1364-2005 §26.6.1,
//! §26.6.6-§26.6.10.
//!
//! Contents:
//! - `pub const index_text_max = "[-9223372036854775808]".len`
//! - `pub fn addArray( arena: std.mem.Allocator, objects: *Rows, kind: Kind, owner: u32, name: []const u8, full: []const u8, ty: Ast.Type, low: i64, high: i64, rest: []const sim.digital.Span, width: u32, base: ?u32, ) Error!u32`
//! - `pub fn addRange(arena: std.mem.Allocator, objects: *Rows, owner: u32, left: i64, right: i64) Error!u32`
//! - `pub fn addBits(arena: std.mem.Allocator, objects: *Rows, msb: i64, lsb: i64, vtype: c_int) Error!void`
//! - `pub fn addModuleArrays(gpa: std.mem.Allocator, arena: std.mem.Allocator, objects: *Rows, scopes: []Building, top_name: []const u8) Error!void`

const std = @import("std");
const Ast = @import("frontend").Ast;
const sim = @import("sim");
const model = @import("model.zig");
const user = @import("vpi_user.zig");
const schema = @import("schema.zig");
const session = @import("session.zig");
const Building = model.Building;
const Edge = schema.Edge;
const Error = session.Error;
const Kind = schema.Kind;
const List = schema.List;
const Prop = schema.Prop;
const Rows = model.Rows;

/// The longest `[i]` an element name gets per dimension: an `i64` index.
pub const index_text_max = "[-9223372036854775808]".len;

/// §11.6.10/§11.6.11: an array object and, after it, each element preceded by
/// the constant its `vpiIndex` leads to — elements in increasing index,
/// row-major over the dimensions `[low:high]` then `rest`, so the element
/// count is IEEE 1364-2005 §26.6.6/§26.6.7's vpiSize. A multidimensional
/// element is named by all its indices (`m[1][2]`) and its vpiIndex is the
/// innermost ("the index for the reg", §26.6.7 m). The digital engine stores
/// element k of that order in `base + k` (`digital.Run.arrays`), which is the
/// slot given each element here. Returns the array row; invalidates pointers
/// into `objects`.
pub fn addArray(
    arena: std.mem.Allocator,
    objects: *Rows,
    kind: Kind,
    owner: u32,
    name: []const u8,
    full: []const u8,
    ty: Ast.Type,
    low: i64,
    high: i64,
    rest: []const sim.digital.Span,
    width: u32,
    base: ?u32,
) Error!u32 {
    const at: u32 = @intCast(objects.hot.items.len);
    var count: u32 = @intCast(high - low + 1);
    for (rest) |sp| count *= @intCast(sp.high - sp.low + 1);
    const members = try arena.alloc(u32, count);
    try objects.appendCold(.{ .kind = kind, .owner = .of(owner), .name = name, .full = full, .size = count, .ty = ty }, .{ .members = members });
    const elem: Kind = switch (kind) {
        .reg_array => .word,
        .net_array => .net,
        else => .var_select, // else: the one other array class addArray is given
    };
    var suffix: std.ArrayList(u8) = try .initCapacity(arena, (rest.len + 1) * index_text_max);
    for (0..count) |k| {
        // Peel the indices off `k`, innermost (fastest) dimension first.
        suffix.clearRetainingCapacity();
        var q: i64 = @intCast(k);
        var inner: i64 = 0;
        var d = rest.len + 1;
        while (d > 0) {
            d -= 1;
            const sp: sim.digital.Span = if (d == 0) .{ .low = low, .high = high } else rest[d - 1];
            const n = sp.high - sp.low + 1;
            const i = sp.low + @mod(q, n);
            q = @divTrunc(q, n);
            if (d == rest.len) inner = i;
            var buf: [index_text_max]u8 = undefined;
            suffix.insertSliceAssumeCapacity(0, std.mem.print(&buf, "[{d}]", .{i}) catch unreachable);
        }
        const c: u32 = @intCast(objects.hot.items.len);
        try objects.append(.{ .kind = .constant, .owner = .of(owner), .name = "", .full = "", .size = 32, .value = .{ .int = inner } });
        members[k] = @intCast(objects.hot.items.len);
        const local = try arena.print("{s}{s}", .{ name, suffix.items });
        try objects.append(.{
            .kind = elem,
            .owner = .of(owner),
            .name = local,
            .full = try arena.print("{s}{s}", .{ full, suffix.items }),
            .size = width,
            .ty = ty,
            .slot = .of(if (base) |b| b + @as(u32, @intCast(k)) else null),
            .parent = .of(at),
            .index = .of(c),
        });
    }
    return at;
}

/// IEEE 1364-2005 §26.6.10: a range object over `[left:right]`, its two
/// bounds decimal constants, its vpiSize the element count.
///
/// The caller adds one row for each dimension it models. Returns the range
/// row; invalidates pointers into `objects`.
pub fn addRange(arena: std.mem.Allocator, objects: *Rows, owner: u32, left: i64, right: i64) Error!u32 {
    const l: u32 = @intCast(objects.hot.items.len);
    try objects.append(.{ .kind = .constant, .owner = .of(owner), .name = "", .full = "", .size = 32, .value = .{ .int = left } });
    try objects.append(.{ .kind = .constant, .owner = .of(owner), .name = "", .full = "", .size = 32, .value = .{ .int = right } });
    const edges = try arena.dupe(Edge, &.{ .{ .tag = user.vpiLeftRange, .to = l }, .{ .tag = user.vpiRightRange, .to = l + 1 } });
    const size: c_int = @intCast(@abs(left - right) + 1);
    const props = try arena.dupe(Prop, &.{.{ .prop = user.vpiSize, .value = size }});
    try objects.append(.{ .kind = .code, .vtype = user.vpiRange, .owner = .of(owner), .name = "", .full = "", .edges = edges, .props = props });
    return l + 2;
}

/// IEEE 1364-2005 §26.6.6 Details a / §26.6.7: the bits of the vector net or
/// reg last appended, `vtype` vpiNetBit or vpiRegBit, from its declared `msb`
/// to its `lsb`, each named `v[i]`, with vpiParent the vector and vpiIndex
/// `i`. The vector reaches them by vpiBit; a scalar's set is empty, and its
/// bounds are not read. Asserts that the vector's `size` is the range's.
/// Invalidates pointers into `objects`.
pub fn addBits(arena: std.mem.Allocator, objects: *Rows, msb: i64, lsb: i64, vtype: c_int) Error!void {
    const v: u32 = @intCast(objects.hot.items.len - 1);
    const vec = objects.hot.items[v];
    if (vec.size < 2) {
        objects.hot.items[v].lists = &.{.{ .tag = user.vpiBit, .items = &.{} }};
        return;
    }
    std.debug.assert(vec.size == @abs(msb - lsb) + 1);
    const bits = try arena.alloc(u32, vec.size);
    const step: i64 = if (msb >= lsb) -1 else 1;
    // A generated vector's module owner is not its enclosing gen scope.
    // §26.6.6/§26.6.44: each bit retains the vector's containing scope.
    const scope: ?Edge = for (vec.edges) |edge| {
        if (edge.tag == user.vpiScope) break edge;
    } else null;
    for (bits, 0..) |*bit, k| {
        const i = msb + step * @as(i64, @intCast(k));
        const c: u32 = @intCast(objects.hot.items.len);
        try objects.append(.{ .kind = .constant, .owner = vec.owner, .name = "", .full = "", .size = 32, .value = .{ .int = i } });
        const edges = try arena.alloc(Edge, if (scope != null) 3 else 2);
        edges[0] = .{ .tag = user.vpiParent, .to = v };
        edges[1] = .{ .tag = user.vpiIndex, .to = c };
        if (scope) |edge| edges[2] = edge;
        bit.* = @intCast(objects.hot.items.len);
        try objects.append(.{
            .kind = .code,
            .vtype = vtype,
            .owner = vec.owner,
            .name = try arena.print("{s}[{d}]", .{ vec.name, i }),
            .full = try arena.print("{s}[{d}]", .{ vec.full, i }),
            .src_tok = vec.src_tok,
            .edges = edges,
            .props = try arena.dupe(Prop, &.{.{ .prop = user.vpiSize, .value = 1 }}),
        });
    }
    objects.hot.items[v].lists = try arena.dupe(List, &.{.{ .tag = user.vpiBit, .items = bits }});
}

/// §6.2.2 `name_of_module_instance ::= module_instance_identifier [ range ]`:
/// elaboration names each element `u[k]`, so sibling scopes that share the
/// identifier before `[` are one array. The array object goes in the parent
/// scope, and every member module learns its array and its index.
/// Invalidates pointers into `objects`.
pub fn addModuleArrays(gpa: std.mem.Allocator, arena: std.mem.Allocator, objects: *Rows, scopes: []Building, top_name: []const u8) Error!void {
    for (scopes, 0..) |*parent, p| {
        var i: usize = 0;
        while (i < parent.children.items.len) : (i += 1) {
            const first = parent.children.items[i];
            const name = arrayBase(model.lastComponent(scopes[first].path)) orelse continue;
            // Already grouped under an earlier sibling?
            if (objects.hot.items[first].parent != .none) continue;
            var n: u32 = 0;
            for (parent.children.items[i..]) |c| n += @intFromBool(sameArray(scopes, c, name));
            const members = try arena.alloc(u32, n);
            n = 0;
            for (parent.children.items[i..]) |c| if (sameArray(scopes, c, name)) {
                members[n] = c;
                n += 1;
            };
            std.mem.sort(u32, members, scopes, struct {
                fn lt(s: []Building, a: u32, b: u32) bool {
                    return scopeIndex(s, a) < scopeIndex(s, b);
                }
            }.lt);
            const at: u32 = @intCast(objects.hot.items.len);
            const path = if (parent.path.len == 0) name else try model.joinPath(arena, parent.path, name);
            try objects.appendCold(.{
                .kind = .module_array,
                .owner = .of(@intCast(p)),
                .name = name,
                .full = try model.joinPath(arena, top_name, path),
                .size = @intCast(members.len),
            }, .{ .members = members });
            try parent.module_arrays.append(gpa, at);
            for (members) |m| {
                const c: u32 = @intCast(objects.hot.items.len);
                try objects.append(.{ .kind = .constant, .owner = .of(@intCast(p)), .name = "", .full = "", .size = 32, .value = .{ .int = scopeIndex(scopes, m) } });
                objects.hot.items[m].parent = .of(at);
                objects.hot.items[m].index = .of(c);
            }
        }
    }
}

// ---- private ----

/// Is child scope `c` an element of the instance array `name`?
fn sameArray(scopes: []const Building, c: u32, name: []const u8) bool {
    const other = arrayBase(model.lastComponent(scopes[c].path)) orelse return false;
    return std.mem.eql(u8, other, name);
}

fn scopeIndex(scopes: []Building, m: u32) i64 {
    return arrayIndex(model.lastComponent(scopes[m].path)).?;
}

/// `u` of `u[3]`, or null when the name is not an array element's.
fn arrayBase(local: []const u8) ?[]const u8 {
    _ = arrayIndex(local) orelse return null;
    return local[0..std.mem.findScalarLast(u8, local, '[').?];
}

fn arrayIndex(local: []const u8) ?i64 {
    const open_at = std.mem.findScalarLast(u8, local, '[') orelse return null;
    if (local[local.len - 1] != ']') return null;
    return std.fmt.parseInt(i64, local[open_at + 1 .. local.len - 1], 10) catch null;
}

test "§6.2.2 instance-array names: the base and index of `u[k]`, and nothing else" {
    try std.testing.expectEqualStrings("u", arrayBase("u[3]") orelse "(null)");
    try std.testing.expectEqual(@as(?i64, 3), arrayIndex("u[3]"));
    try std.testing.expectEqual(@as(?i64, -2), arrayIndex("u[-2]"));
    // The last bracket is the element's: `a[1][2]` is element 2 of `a[1]`.
    try std.testing.expectEqualStrings("a[1]", arrayBase("a[1][2]") orelse "(null)");
    for ([_][]const u8{ "u", "u[]", "u[x]", "u]", "[", "u[3", "" }) |name| {
        try std.testing.expect(arrayBase(name) == null);
        try std.testing.expect(arrayIndex(name) == null);
    }
}
