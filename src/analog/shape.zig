//! §3.2.2/§3.4.4 array shapes and §3.4.8 assignment patterns: the shared
//! arithmetic every array declaration, reference and initializer goes through.
//!
//! In: declared dimensions and pattern expressions. Out: folded `Bounds`, the
//! row-major cell order (`shapeSubscripts`, `flatIndex`), the scalarized
//! element names `name[i][j]` (`elemName`, `elemKey`), and one expression
//! per cell of a pattern (`flattenPattern`). Owns no table: everything here is
//! a pure function of the shape, or allocates its answer in the arena.
//!
//! LRM clauses this file's code cites: §2.7, §3.2, §3.2.2, §3.3, §3.4, §3.4.4,
//! §3.4.8, §3.6.3.2, §4.2.1.1, §4.2.13, §4.2.14.

const std = @import("std");
const Lower = @import("lower.zig");
const lower_constfold = @import("constfold.zig");
const Ast = @import("frontend").Ast;
const diag = @import("diag");
const Oom = Lower.Oom;
/// One declared array dimension, normalized so `lo <= hi`.
pub const Bounds = struct {
    lo: i64,
    hi: i64,
    /// The declaration wrote `[hi:lo]`.
    descending: bool = false,

    /// Returns the number of indices in the dimension.
    pub fn count(b: Bounds) i64 {
        return b.hi - b.lo + 1;
    }
};

comptime {
    std.debug.assert(@sizeOf(Bounds) == 24); // one per dimension, read per subscript
}

/// §3.2/§3.2.2/§3.4.4 `{ [msb:lsb] }` — one `Bounds` per declared dimension,
/// outermost first, so `flag_array[0:8][0:3]` is `{{0,8},{0,3}}`.
///
/// §3.2 puts no limit on the count: a multidimensional array is scalarized
/// cell by cell (see `shapeCells`). Returns null after reporting E0307/E0308.
pub fn dimsBounds(self: *Lower, dims: []const Ast.Dim, tok: u32, name: []const u8) Oom!?[]const Bounds {
    if (dims.len == 0) {
        try self.err(tok, .E0307, "`{s}` has no dimensions", .{name});
        return null;
    }
    const out = try self.arena.alloc(Bounds, dims.len);
    for (dims, out) |d, *b| {
        const a = lower_constfold.shapeEval(self, d.msb) orelse {
            try self.err(tok, .E0308, "in the bounds of `{s}`", .{name});
            return null;
        };
        const c = lower_constfold.shapeEval(self, d.lsb) orelse {
            try self.err(tok, .E0308, "in the bounds of `{s}`", .{name});
            return null;
        };
        // §3.2: a bound "shall evaluate to a positive integer, a negative
        // integer, or zero", and §4.2.1.1 rounds a real to none when it is a
        // NaN, an infinity or past i64. Saturating one instead would turn a
        // NaN bound into a silent zero.
        const x = a.asIntExact() orelse {
            try self.err(tok, .E0308, "in the bounds of `{s}`: {e} is no integer", .{ name, a.asReal() });
            return null;
        };
        const y = c.asIntExact() orelse {
            try self.err(tok, .E0308, "in the bounds of `{s}`: {e} is no integer", .{ name, c.asReal() });
            return null;
        };
        b.* = .{ .lo = @min(x, y), .hi = @max(x, y), .descending = x > y };
    }
    var cells: i128 = 1;
    for (out) |b| {
        cells *= @as(i128, b.hi) - b.lo + 1;
        if (cells > max_cells) {
            try self.err(tok, .E1016, "`{s}`", .{name});
            return null;
        }
    }
    return out;
}

/// E1016's bound on an array's or a pattern's cells: a cell is indexed by a
/// `u32` (`MemArray.len`). Not a design limit: each cell is at least a
/// scalar of lowering state, so an array reaching it has run out of memory
/// first (#29; the bound was 2^20 cells).
const max_cells = std.math.maxInt(u32);

/// How many scalars a declared shape becomes.
pub fn shapeCells(dims: []const Bounds) usize {
    var n: usize = 1;
    for (dims) |d| n *= @intCast(d.count());
    return n;
}

/// The subscripts of the `k`th cell of a ROW-MAJOR walk — the last dimension
/// varies fastest, which is the order §3.4.8's nested assignment pattern lists
/// its elements in (`'{ '{a,b}, '{c,d} }` is rows of columns). A descending
/// dimension (`[hi:lo]` as declared) is walked from its left bound, `hi`.
/// `k` is below `shapeCells(dims)`; a larger one wraps in the outermost
/// dimension. Asserts that `out` has one slot per dimension.
pub fn shapeSubscripts(dims: []const Bounds, k: usize, out: []i64) void {
    std.debug.assert(out.len == dims.len);
    var rest = k;
    var i = dims.len;
    while (i > 0) {
        i -= 1;
        const n: usize = @intCast(dims[i].count());
        const offset: i64 = @intCast(rest % n);
        out[i] = if (dims[i].descending) dims[i].hi - offset else dims[i].lo + offset;
        rest /= n;
    }
}

/// The flat element index of an in-range subscript tuple: row-major, each
/// dimension counted from its left bound — `shapeSubscripts`' inverse and
/// `lower_stmt.runtimeArrayIndex`'s order. Asserts one subscript per dimension;
/// the caller has range-checked them (`lower_stmt.checkSubscripts`), since an
/// out-of-range subscript can alias another cell.
pub fn flatIndex(dims: []const Bounds, idx: []const i64) i64 {
    var flat: i64 = 0;
    for (dims, idx) |d, i| flat = flat * d.count() + (if (d.descending) d.hi - i else i - d.lo);
    return flat;
}

/// How many subscripts fit on the stack. NOT a proved bound — §3.2 puts no limit
/// on a declaration's dimension count, though its own examples go two deep — so
/// this is the spill shape and not a fixed buffer: eight covers everything real
/// and anything wider allocates. `indexChain` uses the same spill threshold.
pub const max_stack_dims = 8;

/// Returns scratch for one cell's `n` subscripts: `buf` when it fits, else an
/// arena slice. Call once per `shapeSubscripts` walk, not once per cell.
pub fn subscriptBuf(self: *Lower, buf: *[max_stack_dims]i64, n: usize) Oom![]i64 {
    return if (n <= buf.len) buf[0..n] else try self.arena.alloc(i64, n);
}

/// The scalarized key for one array element, `name[i]` / `name[i][j]`
/// (§3.2, §3.2.2, §3.4.4).
///
/// Only the two DECLARATION sites need this: `vars` and `param_index` retain
/// the key, so it has to outlive the call. Every *lookup* goes through
/// `elemKey` instead — see there.
pub fn elemName(self: *Lower, name: []const u8, idx: []const i64) Oom![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(self.arena, name);
    for (idx) |i| try out.print(self.arena, "[{d}]", .{i});
    return out.toOwnedSlice(self.arena);
}

/// Widest `name[i][j]…` formatted without spilling: §2.7's 1024-character
/// identifier plus four subscripts of `[`, a 20-character `i64` and `]`. A
/// deeper array spills to the arena (see `elemKey`).
pub const elem_key_len = 1024 + 22 * 4;

/// `name[i][j]` for a *lookup*, formatted into the caller's stack buffer.
///
/// `HashMap.get` never retains the key, so a lookup needs no arena copy. The
/// result borrows `buf` and must not outlive the caller's frame.
///
/// ponytail: an over-long identifier, or more than four dimensions, falls back
/// to the arena. Truncating the key instead would alias two distinct elements.
pub fn elemKey(self: *Lower, buf: *[elem_key_len]u8, name: []const u8, idx: []const i64) Oom![]const u8 {
    if (name.len > buf.len) return try elemName(self, name, idx);
    @memcpy(buf[0..name.len], name);
    var n = name.len;
    for (idx) |i| {
        const s = std.mem.print(buf[n..], "[{d}]", .{i}) catch
            return try elemName(self, name, idx);
        n += s.len;
    }
    return buf[0..n];
}

/// Returns the width of packed range `range` (`constfold.packedWidth`), or
/// null when it does not fold. Marks every parameter either bound reads a
/// shape (`shapeEval`) first: a model card cannot resize a packed range.
pub fn packedShapeWidth(self: *Lower, range: Ast.Dim) ?u32 {
    _ = lower_constfold.shapeEval(self, range.msb);
    _ = lower_constfold.shapeEval(self, range.lsb);
    return lower_constfold.packedWidth(self, range);
}

/// §3.4.8/§3.3's nested assignment pattern, flattened to one expression per
/// cell of `dims` in the same row-major order `shapeSubscripts` walks. §3.3's
/// own example is
///
///     string paths[0:2][0:1] = '{ '{"dir1","fileA"}, '{"dir2","fileA"}, … };
///
/// — an element list per dimension, so the flattening is one recursion per
/// dimension rather than a single `args` read. A cell the pattern does not
/// reach is `.none`, which every caller reads as §3.2's zero (or "").
/// A `.concat` is accepted alongside `.assign_pattern` because the parser folds
/// `{a,b}` to the same node shape and §3.4.4's diagnostic (E0349) already
/// covers the spelling.
///
/// `holes_ok` is §3.6.3.2's bus nodeset alone: "a null value in the constant
/// array indicates that no nodeset value is being specified for this element".
/// Everywhere else A.8.1's assignment_pattern has no empty element, and one is
/// E0894 rather than a silent zero.
pub fn flattenPattern(self: *Lower, e: Ast.ExprId, dims: []const Bounds, holes_ok: bool) Oom![]const Ast.ExprId {
    if (!holes_ok) try refuseHoles(self, e);
    const out = try self.arena.alloc(Ast.ExprId, shapeCells(dims));
    try fillPattern(self, e, dims, out);
    return out;
}

fn refuseHoles(self: *Lower, e: Ast.ExprId) Oom!void {
    const ex = &self.file.exprs;
    if (e == .none or ex.tag(e) != .assign_pattern) return;
    for (ex.args(e)) |el| {
        if (el == .none) {
            try self.err(ex.mainTok(e), .E0894, "an element of this assignment pattern is empty (A.8.1)", .{});
            return;
        }
        try refuseHoles(self, el);
    }
}

fn fillPattern(self: *Lower, e: Ast.ExprId, dims: []const Bounds, out: []Ast.ExprId) Oom!void {
    if (dims.len == 0) {
        std.debug.assert(out.len == 1);
        out[0] = e;
        return;
    }
    const ex = &self.file.exprs;
    const elems: []const Ast.ExprId = if (e != .none and
        (ex.tag(e) == .assign_pattern or ex.tag(e) == .concat))
        try patternElems(self, e)
    else
        &.{};
    const stride = shapeCells(dims[1..]);
    std.debug.assert(out.len == stride * @as(usize, @intCast(dims[0].count()))); // `flattenPattern` sized it
    for (0..@intCast(dims[0].count())) |k| {
        const child = if (k < elems.len) elems[k] else Ast.ExprId.none;
        try fillPattern(self, child, dims[1..], out[k * stride ..][0..stride]);
    }
}

/// The elements of a pattern (or brace list), with A.8.1's replication form
/// unrolled when the parser could not: `'{N{a, b}}` whose count is a
/// constant_expression rather than a literal (§4.2.14), carried as one
/// `.pattern_repl` element. The count folds like an array bound — parameters
/// included (§3.4) — and must be a non-negative integer (§4.2.13), else E0223
/// and no elements, so every cell keeps its §3.2 zero default.
pub fn patternElems(self: *Lower, e: Ast.ExprId) Oom![]const Ast.ExprId {
    const ex = &self.file.exprs;
    const elems = ex.args(e);
    if (elems.len != 1 or ex.tag(elems[0]) != .pattern_repl) return elems;
    const count = ex.lhs(elems[0]);
    const group = ex.args(ex.rhs(elems[0]));
    const c = lower_constfold.shapeEval(self, count);
    const n = if (c) |v| switch (v) {
        .int => |i| i,
        else => null,
    } else null;
    if (n == null or n.? < 0) {
        try self.err(ex.mainTok(count), .E0223, "", .{});
        return &.{};
    }
    const cells = @as(i128, n.?) * group.len;
    if (cells > max_cells) {
        try self.err(ex.mainTok(count), .E1016, "the pattern has {d} elements", .{cells});
        return &.{};
    }
    const out = try self.arena.alloc(Ast.ExprId, @intCast(cells));
    for (0..@intCast(n.?)) |k| @memcpy(out[k * group.len ..][0..group.len], group);
    return out;
}

test "lower: §3.2 a multidimensional array is scalarized row-major" {
    // The ORDER is the load-bearing part: §3.3's own initializer
    // `string paths[0:2][0:1] = '{ '{"dir1","fileA"}, … }` is rows of columns,
    // so cell k of the flat walk must be `[k / cols][k % cols]`. Transposing it
    // reads one cell where another was written, and every value in that example
    // is plausible in both places — which is why the fixture checks all six.
    const dims = [_]Bounds{ .{ .lo = 0, .hi = 2 }, .{ .lo = 0, .hi = 1 } };
    try std.testing.expectEqual(@as(usize, 6), shapeCells(&dims));
    var idx: [2]i64 = undefined;
    const want = [_][2]i64{
        .{ 0, 0 }, .{ 0, 1 },
        .{ 1, 0 }, .{ 1, 1 },
        .{ 2, 0 }, .{ 2, 1 },
    };
    for (want, 0..) |w, k| {
        shapeSubscripts(&dims, k, &idx);
        try std.testing.expectEqualSlices(i64, &w, &idx);
    }
    // A non-zero `lo` offsets the subscript and not the walk (§3.2.2 counts
    // elements): `[1:3]` puts the first cell at 1.
    const off = [_]Bounds{.{ .lo = 1, .hi = 3 }};
    var one: [1]i64 = undefined;
    shapeSubscripts(&off, 0, &one);
    try std.testing.expectEqual(@as(i64, 1), one[0]);
    shapeSubscripts(&off, 2, &one);
    try std.testing.expectEqual(@as(i64, 3), one[0]);
}

test "lower: §3.2.2 every shape of up to three small dimensions walks each cell once" {
    // Exhaustive over a small domain: every (lo, hi) pair in [-2, 2], either
    // declared direction, one to three dimensions. The oracle is the inverse:
    // `flatIndex` of the k-th cell's subscripts is k, and each subscript lies
    // in its dimension. Together they make the walk a bijection.
    var choices: [30]Bounds = undefined;
    var n: usize = 0;
    var lo: i64 = -2;
    while (lo <= 2) : (lo += 1) {
        var hi = lo;
        while (hi <= 2) : (hi += 1) {
            for ([_]bool{ false, true }) |descending| {
                choices[n] = .{ .lo = lo, .hi = hi, .descending = descending };
                n += 1;
            }
        }
    }
    try std.testing.expectEqual(choices.len, n);
    var dims_buf: [3]Bounds = undefined;
    var idx_buf: [3]i64 = undefined;
    for (1..4) |rank| {
        for (0..std.math.pow(usize, choices.len, rank)) |combo| {
            var c = combo;
            for (dims_buf[0..rank]) |*d| {
                d.* = choices[c % choices.len];
                c /= choices.len;
            }
            const dims = dims_buf[0..rank];
            const idx = idx_buf[0..rank];
            for (0..shapeCells(dims)) |k| {
                shapeSubscripts(dims, k, idx);
                for (dims, idx) |d, i| try std.testing.expect(i >= d.lo and i <= d.hi);
                try std.testing.expectEqual(@as(i64, @intCast(k)), flatIndex(dims, idx));
            }
        }
    }
}

test "lower: §3.3 a pattern is positional from the declared left bound" {
    // `real x[2:0] = '{a, b, c}` puts `a` in x[2]: a descending dimension's
    // first cell is its left bound, `hi`.
    const dims = [_]Bounds{.{ .lo = 0, .hi = 2, .descending = true }};
    var one: [1]i64 = undefined;
    for ([_]i64{ 2, 1, 0 }, 0..) |want, k| {
        shapeSubscripts(&dims, k, &one);
        try std.testing.expectEqual(want, one[0]);
    }
}

test elemKey {
    // The lookup spelling is the declaration spelling, on the stack or spilled:
    // a key that fits, one that fills the buffer exactly (a 1024-character name
    // and four 22-character subscripts), and both ways past it.
    comptime std.debug.assert(elem_key_len == 1024 + 4 * "[-9223372036854775808]".len);
    var h: Lower.Harness = undefined;
    try h.init(std.testing.allocator, "module m; endmodule");
    defer h.deinit();
    const name_buf: [2000]u8 = @splat('n');
    const min = std.math.minInt(i64);
    const cases = [_]struct { name: []const u8, idx: []const i64 }{
        .{ .name = "a", .idx = &.{} },
        .{ .name = "a", .idx = &.{ -1, 0, std.math.maxInt(i64) } },
        .{ .name = name_buf[0..1024], .idx = &.{ min, min, min, min } },
        .{ .name = name_buf[0..1024], .idx = &.{ min, min, min, min, min } },
        .{ .name = name_buf[0..2000], .idx = &.{0} },
    };
    var key_buf: [elem_key_len]u8 = undefined;
    for (cases) |c| {
        const want = try elemName(&h.low, c.name, c.idx);
        try std.testing.expectEqualStrings(want, try elemKey(&h.low, &key_buf, c.name, c.idx));
    }
}

test "lower: §3.2 array bounds are constant integers (E0308), and the cells fit a u32 index (E1016)" {
    const cases = [_]struct { decls: []const u8, want: ?diag.Code }{
        .{ .decls = "  real a[3:0];", .want = null },
        .{ .decls = "  integer w;\n  real a[0:w];", .want = .E0308 },
        // 1024 * 1025 cells was past the old 2^20 E1016 cap (#29).
        .{ .decls = "  real a[0:1023][0:1024];", .want = null },
        // Past the u32 cell index is E1016, before a cell is allocated.
        .{ .decls = "  real a[0:65535][0:65536];", .want = .E1016 },
        // §3.2: a bound "shall evaluate to a positive integer, a negative
        // integer, or zero", and §4.2.1.1 gives NaN and an infinity no
        // integer, so such a bound is no bound at all.
        .{ .decls = "  real a[0:0.0/0.0];", .want = .E0308 },
        .{ .decls = "  real a[0:1.0/0.0];", .want = .E0308 },
        .{ .decls = "  real a[-1.0/0.0:0];", .want = .E0308 },
        // §4.2.14 a pattern's replication count folds like a bound and is
        // non-negative (§4.2.13): E0223, and past the u32 cell index E1016.
        .{ .decls = "  parameter integer c = 2;\n  real a[0:3] = '{c{1.0, 2.0}};", .want = null },
        .{ .decls = "  parameter integer c = -1;\n  real a[0:1] = '{c{1.0}};", .want = .E0223 },
        .{ .decls = "  parameter integer c = 2000000;\n  real a[0:1] = '{c{1.0}};", .want = null },
        // 2000000000 copies of three elements: 6e9, past the u32 index.
        .{ .decls = "  parameter integer c = 2000000000;\n  real a[0:1] = '{c{1.0, 2.0, 3.0}};", .want = .E1016 },
        // A pattern shorter than the array leaves the rest at §3.2's zero.
        .{ .decls = "  real a[0:2] = '{1.0, 2.0};", .want = null },
    };
    for (cases) |c| try Lower.expectBodyVerdict(c.decls, "", c.want);
}

test flatIndex {
    // Row-major, each dimension from its left bound, so `[1:0]` counts down.
    try std.testing.expectEqual(@as(i64, 3), flatIndex(&.{ .{ .lo = 0, .hi = 1 }, .{ .lo = 0, .hi = 2 } }, &.{ 1, 0 }));
    try std.testing.expectEqual(@as(i64, 1), flatIndex(&.{.{ .lo = 0, .hi = 1, .descending = true }}, &.{0}));
}
