//! The rows every model builder shares: `Rows` (the `Obj`/`Cold` tables
//! under construction), `Building` (a scope under construction), and
//! `freeze`, which turns a builder's growable lists into the fixed `Design`
//! tables; plus the §6.7 path helpers and the CSR grouping the builders and
//! the reverse indexes use.
//! Cites: VAMS-2023 §6.7, §11.6, §12.21.
//!
//! Every builder keeps the `Scope` invariant (schema.zig): the module rows
//! come first, in scope order. Row strings and slices live in `Design.arena`;
//! the growable lists live in `gpa` until `freeze` copies them.
//!
//! Contents:
//! - `pub const Rows = struct`
//! - `pub fn Rows.deinit(rows: *Rows) void`
//! - `pub fn Rows.append(rows: *Rows, o: Obj) Error!void`
//! - `pub fn Rows.appendCold(rows: *Rows, o: Obj, c: Cold) Error!void`
//! - `pub fn Rows.coldFor(rows: *Rows, at: u32) Error!*Cold`
//! - `pub fn Rows.coldOf(rows: *const Rows, at: u32) *const Cold`
//! - `pub const Building = struct`
//! - `pub fn Building.deinit(s: *Building, gpa: std.mem.Allocator) void`
//! - `pub const Csr = struct`
//! - `pub fn Csr.init(gpa: std.mem.Allocator, n_keys: usize, pairs: []const [2]u32) error{OutOfMemory}!Csr`
//! - `pub fn Csr.deinit(c: *Csr, gpa: std.mem.Allocator) void`
//! - `pub fn Csr.of(c: Csr, key: usize) []const u32`
//! - `pub fn freeze(d: *Design, rows: *Rows, scopes: []const Building) Error!void`
//! - `pub fn decls(gpa: std.mem.Allocator, objects: []const Obj, n_scopes: usize) Error!Csr`
//! - `pub fn nameTable(gpa: std.mem.Allocator, objects: []const Obj) Error!std.StringHashMapUnmanaged(u32)`
//! - `pub fn joinPath(arena: std.mem.Allocator, parent: []const u8, local: []const u8) Error![]const u8`
//! - `pub fn lastComponent(path: []const u8) []const u8`

const std = @import("std");
const Ast = @import("frontend").Ast;
const Elaborate = @import("vera").Elaborate;
const model_arrays = @import("model_arrays.zig");
const schema = @import("schema.zig");
const user = @import("vpi_user.zig");
const Design = @import("Design.zig");
const code_tables = @import("code_tables.zig");
const session = @import("session.zig");
const Cold = schema.Cold;
const Error = session.Error;
const Kind = schema.Kind;
const Obj = schema.Obj;
const Scope = schema.Scope;
const ScopeLists = code_tables.ScopeLists;

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
        if (o.cold == schema.no_cold) {
            try rows.cold.append(rows.gpa, .{});
            o.cold = @intCast(rows.cold.items.len - 1);
        }
        return &rows.cold.items[o.cold];
    }

    /// Row `at`'s cold fields to read: `Cold{}` when it has none.
    pub fn coldOf(rows: *const Rows, at: u32) *const Cold {
        const c = rows.hot.items[at].cold;
        return if (c == schema.no_cold) &empty_cold else &rows.cold.items[c];
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
    code: ScopeLists = .{},

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

// ---- private ----

fn declsOnce(a: std.mem.Allocator, objects: []const Obj) !void {
    var d = try decls(a, objects, 2);
    d.deinit(a);
}

fn csrOnce(a: std.mem.Allocator, pairs: []const [2]u32) !void {
    var c: Csr = try .init(a, 3, pairs);
    c.deinit(a);
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
    const at = try model_arrays.addArray(arena.allocator(), &rows, .reg_array, 0, "m", "t.m", .integer, 1, 2, &.{.{ .low = 0, .high = 1 }}, 8, 100);
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
        const at = try model_arrays.addRange(arena.allocator(), &rows, 0, case[0], case[1]);
        const r = rows.hot.items[at];
        try std.testing.expectEqual(user.vpiRange, r.vtype);
        try std.testing.expectEqual(case[2], r.props[0].value);
        try std.testing.expectEqual(case[0], rows.hot.items[r.edges[0].to].value.?.int);
        try std.testing.expectEqual(case[1], rows.hot.items[r.edges[1].to].value.?.int);
    }
}

test "decls: each scope's declaration rows, in object order" {
    var d = try decls(std.testing.allocator, &decl_rows, 2);
    defer d.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u32, &.{2}, d.of(0));
    try std.testing.expectEqualSlices(u32, &.{ 1, 5 }, d.of(1));
    try std.testing.expectEqual(@as(usize, 0), d.of(2).len);
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

test "Csr.init frees what it built when an allocation fails" {
    const pairs = [_][2]u32{ .{ 2, 0 }, .{ 0, 1 }, .{ 2, 2 } };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, csrOnce, .{@as([]const [2]u32, &pairs)});
}
