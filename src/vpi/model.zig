//! The rows every model builder shares: `Building` (a scope under
//! construction), the §11.6.10/§11.6.11 array rows, IEEE 1364-2005 §26.6.6
//! vector-bit rows, §26.6.10 range rows, §6.2.2 instance-array rows, and
//! `freeze`, which turns a
//! builder's growable lists into the fixed `Design` tables. The builders are
//! model_analog.zig (over `Lowered`) and model_digital.zig (over a
//! `sim.digital.Run`); both append rows to one `Rows`.
//!
//! Every builder keeps the `Scope` invariant (root.zig): the module rows come
//! first, in scope order. Row strings and slices live in `Design.arena`; the
//! growable lists live in `gpa` until `freeze` copies them.

const std = @import("std");
const Ast = @import("frontend").Ast;
const Elaborate = @import("vera").Elaborate;
const sim = @import("sim");
const code = @import("code.zig");
const root = @import("root.zig");

const Design = root.Design;
const Error = root.Error;
const Kind = root.Kind;
const Obj = root.Obj;
const Cold = root.Cold;
const Scope = root.Scope;
const vpiBit = root.vpiBit;
const vpiIndex = root.vpiIndex;
const vpiParent = root.vpiParent;
const vpiScope = root.vpiScope;
const vpiSize = root.vpiSize;

/// The rows a builder appends: the `Obj` table and the `Cold` rows its
/// `Obj.cold` indexes. Both live in `gpa`, the `Design`'s allocator, until
/// `freeze` hands them to the `Design`; everything else a builder grows is
/// scratch, in an arena it frees when it returns.
pub const Rows = struct {
    gpa: std.mem.Allocator,
    hot: std.ArrayList(Obj) = .empty,
    cold: std.ArrayList(Cold) = .empty,

    /// Frees whatever `freeze` did not take.
    pub fn deinit(rows: *Rows) void {
        rows.hot.deinit(rows.gpa);
        rows.cold.deinit(rows.gpa);
    }

    /// Appends row `o`, with no cold fields. Invalidates pointers into `hot`.
    pub fn append(rows: *Rows, o: Obj) Error!void {
        try rows.hot.append(rows.gpa, o);
    }

    /// Appends row `o` with cold fields `c`. Invalidates pointers into `hot`
    /// and `cold`.
    pub fn appendCold(rows: *Rows, o: Obj, c: Cold) Error!void {
        try rows.hot.ensureUnusedCapacity(rows.gpa, 1);
        var row = o;
        row.cold = @intCast(rows.cold.items.len);
        try rows.cold.append(rows.gpa, c);
        rows.hot.appendAssumeCapacity(row);
    }

    /// Row `at`'s cold fields to write, its `Cold` row added on first use.
    /// Invalidates earlier results of `coldFor` and `coldOf`.
    pub fn coldFor(rows: *Rows, at: u32) Error!*Cold {
        const o = &rows.hot.items[at];
        if (o.cold == root.no_cold) {
            try rows.cold.append(rows.gpa, .{});
            o.cold = @intCast(rows.cold.items.len - 1);
        }
        return &rows.cold.items[o.cold];
    }

    /// Row `at`'s cold fields to read: `Cold{}` when it has none.
    pub fn coldOf(rows: *const Rows, at: u32) *const Cold {
        const c = rows.hot.items[at].cold;
        return if (c == root.no_cold) &empty_cold else &rows.cold.items[c];
    }

    const empty_cold: Cold = .{};
};

/// A scope under construction: the definition it instantiates, plus the
/// growable sets that become `Scope`'s slices.
pub const Building = struct {
    decl: *const Ast.ModuleDecl,
    def_name: []const u8,
    library: []const u8 = "work",
    config: []const u8 = "",
    path: []const u8,
    time_unit: ?i8 = null,
    time_precision: ?i8 = null,
    parent: ?u32,
    /// A digital model's `digital.Run` scope id for this instance.
    engine: u32 = 0,
    children: std.ArrayList(u32) = .empty,
    ports: std.ArrayList(u32) = .empty,
    nets: std.ArrayList(u32) = .empty,
    regs: std.ArrayList(u32) = .empty,
    params: std.ArrayList(u32) = .empty,
    integers: std.ArrayList(u32) = .empty,
    reals: std.ArrayList(u32) = .empty,
    reg_arrays: std.ArrayList(u32) = .empty,
    net_arrays: std.ArrayList(u32) = .empty,
    variables: std.ArrayList(u32) = .empty,
    module_arrays: std.ArrayList(u32) = .empty,
    nodes: std.ArrayList(u32) = .empty,
    branches: std.ArrayList(u32) = .empty,
    code: code.ScopeLists = .{},

    /// Frees the growable lists, which live in `gpa`; the strings they index
    /// are the arena's and stay.
    pub fn deinit(s: *Building, gpa: std.mem.Allocator) void {
        inline for (id_lists) |f| @field(s, f).deinit(gpa);
        s.code.deinit(gpa);
    }

    /// The object-index lists a `Scope` carries under the same names, which
    /// `freeze` copies one for one.
    const id_lists = .{ "children", "ports", "nets", "regs", "params", "integers", "reals", "reg_arrays", "net_arrays", "variables", "module_arrays", "nodes", "branches" };
};

/// The model's fixed arrays, from what a builder accumulated. `rows` must
/// hold the modules first and in scope order — the `Scope` invariant. Takes
/// `rows`' tables (no copy), leaving it empty; `rows.gpa` must be `d.gpa`.
pub fn freeze(d: *Design, rows: *Rows, scopes: []const Building) Error!void {
    const gpa = d.gpa;
    const arena = d.arena.allocator();
    d.objects = try rows.hot.toOwnedSlice(rows.gpa);
    d.cold = try rows.cold.toOwnedSlice(rows.gpa);
    const objects = d.objects;
    d.scopes = try gpa.alloc(Scope, scopes.len);
    for (scopes, d.scopes) |*s, *sc| {
        sc.* = .{
            .parent = s.parent,
            .def_name = s.def_name,
            .library = s.library,
            .config = s.config,
            .path = s.path,
            .time_unit = s.time_unit,
            .time_precision = s.time_precision,
            .internal = blk: {
                var n = s.children.items.len + s.code.internal.items.len;
                for (s.code.gen_arrays.items) |g| n += objects[g].lists[0].items.len;
                var all: std.ArrayList(u32) = try .initCapacity(arena, n);
                all.appendSliceAssumeCapacity(s.children.items);
                for (s.code.gen_arrays.items) |g| all.appendSliceAssumeCapacity(objects[g].lists[0].items);
                all.appendSliceAssumeCapacity(s.code.internal.items);
                break :blk all.items;
            },
            .lists = try s.code.freeze(arena),
            .engine = s.engine,
        };
        inline for (Building.id_lists) |f| @field(sc, f) = try arena.dupe(u32, @field(s, f).items);
    }
    d.top_modules = try arena.dupe(u32, &[_]u32{0});
    // A constant and a quantity have no name to be found by (§11.6.7 lists
    // none), and a node shares its net's name — the NET is what a name
    // denotes (§11.6.8), the node is reached from it. Disciplines and
    // natures live in their own namespace (§3.6), not the hierarchy's.
    for (d.objects, 0..) |o, i| switch (o.kind) {
        .constant, .quantity, .node, .discipline, .nature => {},
        // A named block, task, function or named event has a full name; a
        // statement or expression does not.
        .code => if (o.full.len != 0) try d.by_name.put(gpa, o.full, @intCast(i)),
        // An implicit net shares its name with the port that made it; the
        // name keeps denoting what the source declared.
        .net => if (!o.implicit or !d.by_name.contains(o.full)) try d.by_name.put(gpa, o.full, @intCast(i)),
        .module, .port, .reg, .parameter, .integer, .real_var, .time_var, .reg_array, .var_array, .net_array, .word, .var_select, .module_array, .branch => try d.by_name.put(gpa, o.full, @intCast(i)),
    };
}

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

/// The longest `[i]` an element name gets per dimension: an `i64` index.
pub const index_text_max = "[-9223372036854775808]".len;

/// IEEE 1364-2005 §26.6.10: a range object over `[left:right]`, its two
/// bounds decimal constants, its vpiSize the element count.
///
/// The caller adds one row for each dimension it models. Returns the range
/// row; invalidates pointers into `objects`.
pub fn addRange(arena: std.mem.Allocator, objects: *Rows, owner: u32, left: i64, right: i64) Error!u32 {
    const l: u32 = @intCast(objects.hot.items.len);
    try objects.append(.{ .kind = .constant, .owner = .of(owner), .name = "", .full = "", .size = 32, .value = .{ .int = left } });
    try objects.append(.{ .kind = .constant, .owner = .of(owner), .name = "", .full = "", .size = 32, .value = .{ .int = right } });
    const edges = try arena.dupe(code.Edge, &.{ .{ .tag = code.vpiLeftRange, .to = l }, .{ .tag = code.vpiRightRange, .to = l + 1 } });
    const size: c_int = @intCast(@abs(left - right) + 1);
    const props = try arena.dupe(code.Prop, &.{.{ .prop = vpiSize, .value = size }});
    try objects.append(.{ .kind = .code, .vtype = code.vpiRange, .owner = .of(owner), .name = "", .full = "", .edges = edges, .props = props });
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
        objects.hot.items[v].lists = &.{.{ .tag = vpiBit, .items = &.{} }};
        return;
    }
    std.debug.assert(vec.size == @abs(msb - lsb) + 1);
    const bits = try arena.alloc(u32, vec.size);
    const step: i64 = if (msb >= lsb) -1 else 1;
    // A generated vector's module owner is not its enclosing gen scope.
    // §26.6.6/§26.6.44: each bit retains the vector's containing scope.
    const scope: ?code.Edge = for (vec.edges) |edge| {
        if (edge.tag == vpiScope) break edge;
    } else null;
    for (bits, 0..) |*bit, k| {
        const i = msb + step * @as(i64, @intCast(k));
        const c: u32 = @intCast(objects.hot.items.len);
        try objects.append(.{ .kind = .constant, .owner = vec.owner, .name = "", .full = "", .size = 32, .value = .{ .int = i } });
        const edges = try arena.alloc(code.Edge, if (scope != null) 3 else 2);
        edges[0] = .{ .tag = vpiParent, .to = v };
        edges[1] = .{ .tag = vpiIndex, .to = c };
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
            .props = try arena.dupe(code.Prop, &.{.{ .prop = vpiSize, .value = 1 }}),
        });
    }
    objects.hot.items[v].lists = try arena.dupe(code.List, &.{.{ .tag = vpiBit, .items = bits }});
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
            const name = arrayBase(lastComponent(scopes[first].path)) orelse continue;
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
            const path = if (parent.path.len == 0) name else try joinPath(arena, parent.path, name);
            try objects.appendCold(.{
                .kind = .module_array,
                .owner = .of(@intCast(p)),
                .name = name,
                .full = try joinPath(arena, top_name, path),
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

/// Is child scope `c` an element of the instance array `name`?
fn sameArray(scopes: []const Building, c: u32, name: []const u8) bool {
    const other = arrayBase(lastComponent(scopes[c].path)) orelse return false;
    return std.mem.eql(u8, other, name);
}

fn scopeIndex(scopes: []Building, m: u32) i64 {
    return arrayIndex(lastComponent(scopes[m].path)).?;
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

/// Rows grouped by a dense u32 key: key `k`'s rows are
/// `rows[first[k]..first[k + 1]]`, in the order they were given.
pub const Csr = struct {
    first: []u32,
    rows: []u32,

    /// From `(key, row)` pairs, every key below `n_keys`, in two passes,
    /// O(keys + pairs). Caller owns the result and frees it with `deinit`
    /// and the same `gpa`.
    pub fn init(gpa: std.mem.Allocator, n_keys: usize, pairs: []const [2]u32) error{OutOfMemory}!Csr {
        const first = try gpa.alloc(u32, n_keys + 1);
        errdefer gpa.free(first);
        @memset(first, 0);
        for (pairs) |p| first[p[0] + 1] += 1;
        for (1..first.len) |k| first[k] += first[k - 1];
        const rows = try gpa.alloc(u32, pairs.len);
        errdefer gpa.free(rows);
        const fill = try gpa.dupe(u32, first[0..n_keys]);
        defer gpa.free(fill);
        for (pairs) |p| {
            rows[fill[p[0]]] = p[1];
            fill[p[0]] += 1;
        }
        std.debug.assert(first[n_keys] == pairs.len);
        return .{ .first = first, .rows = rows };
    }

    /// Frees both tables; `gpa` must be the one `init` used.
    pub fn deinit(c: *Csr, gpa: std.mem.Allocator) void {
        gpa.free(c.first);
        gpa.free(c.rows);
    }

    /// Key `key`'s rows; none for a key past the table.
    pub fn of(c: Csr, key: usize) []const u32 {
        if (key >= c.first.len - 1) return &.{};
        return c.rows[c.first[key]..c.first[key + 1]];
    }
};

/// The declarations each scope's attribute pass decorates, keyed by scope:
/// rows owned by one of the scopes, neither `.code` nor `.module`, with a
/// source token, in object order. Bucketed once rather than found by a scan
/// of every object per scope. Exact for a pass that runs scope by scope over
/// the rows that exist before it, because a scope's pass adds only rows it
/// owns, `.code` rows and ownerless ones. Caller owns the result
/// (`Csr.deinit` with the same `gpa`).
pub fn decls(gpa: std.mem.Allocator, objects: []const Obj, n_scopes: usize) Error!Csr {
    var pairs: std.ArrayList([2]u32) = .empty;
    defer pairs.deinit(gpa);
    for (objects, 0..) |o, at| {
        const owner = o.owner.get() orelse continue;
        if (owner < n_scopes and o.kind != .code and o.kind != .module and o.src_tok != 0) try pairs.append(gpa, .{ owner, @intCast(at) });
    }
    return .init(gpa, n_scopes, pairs.items);
}

/// §6.7 full name -> object, for resolving the identifiers of the
/// behavioural objects. Built in object order, so where a port and a net
/// share a name (a port of the top is declared as a net too) the net wins,
/// as it does in `by_name`.
pub fn nameTable(gpa: std.mem.Allocator, objects: []const Obj) Error!std.StringHashMapUnmanaged(u32) {
    var names: std.StringHashMapUnmanaged(u32) = .empty;
    errdefer names.deinit(gpa);
    for (objects, 0..) |o, i| switch (o.kind) {
        .constant, .quantity, .node, .discipline, .nature => {},
        .module, .port, .net, .reg, .parameter, .integer, .real_var, .time_var, .reg_array, .var_array, .net_array, .word, .var_select, .module_array, .branch, .code => if (o.full.len != 0) try names.put(gpa, o.full, @intCast(i)),
    };
    return names;
}

/// §6.7 join: `parent` and `local` with `Elaborate.sep` between them, or just
/// `local` when `parent` is the empty root path. `vpiFullName` is this applied
/// once more with the top module's own name on the left, which is the form
/// §12.21's own example passes (`vpi_handle_by_name("top.mod1", …)`).
pub fn joinPath(arena: std.mem.Allocator, parent: []const u8, local: []const u8) Error![]const u8 {
    if (parent.len == 0) return arena.dupe(u8, local);
    if (local.len == 0) return arena.dupe(u8, parent);
    return arena.print("{s}{c}{s}", .{ parent, Elaborate.sep, local });
}

/// The `vpiName` part of a §6.7 path: what follows the last `Elaborate.sep`,
/// or all of `path`. A slice of `path`, not a copy.
pub fn lastComponent(path: []const u8) []const u8 {
    const at = std.mem.findScalarLast(u8, path, Elaborate.sep) orelse return path;
    return path[at + 1 ..];
}

// ---------------------------------------------------------------------------
// Tests: the shared builders over hand-made rows
// ---------------------------------------------------------------------------

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

test "§6.7 paths: lastComponent and joinPath" {
    try std.testing.expectEqualStrings("c", lastComponent("a.b.c"));
    try std.testing.expectEqualStrings("abc", lastComponent("abc"));
    try std.testing.expectEqualStrings("", lastComponent("a."));
    try std.testing.expectEqualStrings("", lastComponent(""));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("x", try joinPath(a, "", "x"));
    try std.testing.expectEqualStrings("p", try joinPath(a, "p", ""));
    try std.testing.expectEqualStrings("p.x", try joinPath(a, "p", "x"));
    try std.testing.expectEqualStrings("", try joinPath(a, "", ""));
}

test "§11.6.11 addArray: elements row-major, named by every index, vpiIndex the innermost" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var rows: Rows = .{ .gpa = std.testing.allocator };
    defer rows.deinit();
    // `reg [7:0] m [1:2][0:1]`, its first element in engine slot 100.
    const at = try addArray(arena.allocator(), &rows, .reg_array, 0, "m", "t.m", .integer, 1, 2, &.{.{ .low = 0, .high = 1 }}, 8, 100);
    try std.testing.expectEqual(@as(u32, 4), rows.hot.items[at].size);
    const members = rows.coldOf(at).members;
    for (members, [_]struct { []const u8, i64, u32 }{
        .{ "t.m[1][0]", 0, 100 },
        .{ "t.m[1][1]", 1, 101 },
        .{ "t.m[2][0]", 0, 102 },
        .{ "t.m[2][1]", 1, 103 },
    }) |m, want| {
        const e = rows.hot.items[m];
        try std.testing.expectEqual(Kind.word, e.kind);
        try std.testing.expectEqual(@as(u32, 8), e.size);
        try std.testing.expectEqualStrings(want[0], e.full);
        try std.testing.expectEqual(@as(?u32, want[2]), e.slot.get());
        try std.testing.expectEqual(@as(?u32, at), e.parent.get());
        const index = e.index.get() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(want[1], rows.hot.items[index].value.?.int);
    }
}

test "IEEE 1364-2005 §26.6.10 addRange: bounds as written, size the element count either way" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var rows: Rows = .{ .gpa = std.testing.allocator };
    defer rows.deinit();
    for ([_]struct { i64, i64, c_int }{ .{ 7, 0, 8 }, .{ 0, 7, 8 }, .{ -3, 4, 8 }, .{ 5, 5, 1 } }) |case| {
        const at = try addRange(arena.allocator(), &rows, 0, case[0], case[1]);
        const r = rows.hot.items[at];
        try std.testing.expectEqual(code.vpiRange, r.vtype);
        try std.testing.expectEqual(case[2], r.props[0].value);
        try std.testing.expectEqual(case[0], rows.hot.items[r.edges[0].to].value.?.int);
        try std.testing.expectEqual(case[1], rows.hot.items[r.edges[1].to].value.?.int);
    }
}

/// Rows for the `decls` tests: two scopes, and every reason a row is not a
/// declaration.
const decl_rows = [_]Obj{
    .{ .kind = .module, .owner = .none, .name = "", .full = "", .src_tok = 1 },
    .{ .kind = .net, .owner = .of(1), .name = "", .full = "", .src_tok = 2 },
    .{ .kind = .net, .owner = .of(0), .name = "", .full = "", .src_tok = 3 },
    // Behavioural: not a declaration.
    .{ .kind = .code, .owner = .of(0), .name = "", .full = "", .src_tok = 4 },
    // No source token.
    .{ .kind = .reg, .owner = .of(0), .name = "", .full = "" },
    .{ .kind = .reg, .owner = .of(1), .name = "", .full = "", .src_tok = 5 },
    // No owner, and an owner past the scopes.
    .{ .kind = .net, .owner = .none, .name = "", .full = "", .src_tok = 6 },
    .{ .kind = .net, .owner = .of(7), .name = "", .full = "", .src_tok = 7 },
};

test "decls: each scope's declaration rows, in object order" {
    var d = try decls(std.testing.allocator, &decl_rows, 2);
    defer d.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u32, &.{2}, d.of(0));
    try std.testing.expectEqualSlices(u32, &.{ 1, 5 }, d.of(1));
    try std.testing.expectEqual(@as(usize, 0), d.of(2).len);
}

fn declsOnce(a: std.mem.Allocator, objects: []const Obj) !void {
    var d = try decls(a, objects, 2);
    d.deinit(a);
}

test "decls frees what it built when an allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, declsOnce, .{@as([]const Obj, &decl_rows)});
}

test "Csr: every key's rows in the order given, against a scan of the pairs" {
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    var pairs: [64][2]u32 = undefined;
    for (0..40) |round| {
        // 1..5 keys, 0..64 pairs: empty keys, empty tables and repeats.
        const n_keys: usize = round % 5 + 1;
        const n = random.uintLessThan(usize, pairs.len + 1);
        for (pairs[0..n], 0..) |*p, i| p.* = .{ random.uintLessThan(u32, @intCast(n_keys)), @intCast(i) };
        var c: Csr = try .init(std.testing.allocator, n_keys, pairs[0..n]);
        defer c.deinit(std.testing.allocator);
        for (0..n_keys) |key| {
            var want: [64]u32 = undefined;
            var w: usize = 0;
            for (pairs[0..n]) |p| {
                if (p[0] != key) continue;
                want[w] = p[1];
                w += 1;
            }
            try std.testing.expectEqualSlices(u32, want[0..w], c.of(@intCast(key)));
        }
        // A key past the table has no rows.
        try std.testing.expectEqual(@as(usize, 0), c.of(@intCast(n_keys)).len);
        try std.testing.expectEqual(@as(usize, 0), c.of(std.math.maxInt(u32)).len);
        try std.testing.expectEqual(@as(usize, 0), c.of(std.math.maxInt(usize)).len);
    }
}

fn csrOnce(a: std.mem.Allocator, pairs: []const [2]u32) !void {
    var c: Csr = try .init(a, 3, pairs);
    c.deinit(a);
}

test "Csr.init frees what it built when an allocation fails" {
    const pairs = [_][2]u32{ .{ 2, 0 }, .{ 0, 1 }, .{ 2, 2 } };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, csrOnce, .{@as([]const [2]u32, &pairs)});
}
