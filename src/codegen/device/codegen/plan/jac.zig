//! `deriv_reads` and `jac_const`: the evidence the emitter accumulates while
//! writing (every `x[u]` and `.ddxAt(u)` it spells, every dispatcher row's
//! constant coefficients) -> which derivative lanes `eval`/`q` read, and the
//! exact constant partials of every column they do not. Soundness is argued
//! at `dispatch.emitDerivReads`, which formats the result. Clauses: §4.5.14
//! (`ddx` reads a lane), §5.6.5 (a collapsible switch row's guarded stamps).

const std = @import("std");
const assert = std.debug.assert;
const gen_mask = @import("../mask.zig");

/// One constant partial: `g` of `eval`, `c` of `q`, at (row, col). Absent is 0.
/// `when` is a GUARDED entry's collapse pair (`plan/topology.zig`
/// `cpairs` index): it holds only while that pair's retention flag is set
/// and the host has not collapsed it (`contract.JacWhen`).
pub const Entry = struct { row: u32, col: u32, g: f64, c: f64, when: ?u32 = null };

/// One recorded coefficient of a row: `k · x[col]`.
pub const Term = struct { col: u32, k: f64 };
/// One row of `Jac.lin`: its terms, one per column, in first-write order.
pub const LinRow = std.ArrayList(Term);

/// Returns the coefficient row `row` holds on `col`, 0 when it has none.
pub fn lookup(row: LinRow, col: u32) f64 {
    for (row.items) |t| if (t.col == col) return t.k;
    return 0;
}

/// The two emitted tables.
pub const JacConst = struct {
    /// The emitted `deriv_reads`: every lane `eval`/`q` may read, `w` words.
    mask: []u64,
    /// Sorted by (row, col); only columns outside `mask`, only nonzero pairs.
    entries: []Entry,
};

/// Returns the emitted `deriv_reads` mask and the constant-partial table,
/// both owned by `arena`. Masks are `w` words (`codegen/mask.zig`).
///
/// `lin[react][row]` holds the exact coefficient of each `x[col]` in
/// `res[row]` as far as the stamps are linear. `guarded` are the stamps that
/// hold only under a collapse guard, one entry per (row, col, pair).
/// `ddx_reads` and `limit`'s writes are ORed into the mask for `contract`'s
/// rules. A (row, col) the table would have to state twice (unguarded and
/// guarded, or under two guards) keeps its lane instead: `contract` wants
/// (row, col) unique.
///
/// Asserts that both `lin` halves hold `n_u` rows and that every guarded
/// entry lies inside the matrix. Each row costs its terms, sorted, and a
/// scan of `guarded`, so the whole is O(terms · log terms + n_u · guarded +
/// guarded²).
pub fn plan(
    arena: std.mem.Allocator,
    n_u: u32,
    deriv_reads: []const u64,
    ddx_reads: []const u64,
    limit_writes: []const u64,
    lin: [2][]const LinRow,
    guarded: []const Entry,
) std.mem.Allocator.Error!JacConst {
    const mask = try gen_mask.join(arena, deriv_reads, ddx_reads);
    gen_mask.orIn(mask, limit_writes);
    const n = n_u;
    assert(lin[0].len == n and lin[1].len == n);
    for (guarded) |e| assert(e.row < n and e.col < n);
    for (guarded, 0..) |e, k| {
        const clash = lookup(lin[0][e.row], e.col) != 0 or lookup(lin[1][e.row], e.col) != 0 or
            for (guarded[0..k]) |p| {
                if (p.row == e.row and p.col == e.col) break true;
            } else false;
        if (clash) gen_mask.set(mask, e.col);
    }
    var out: std.ArrayList(Entry) = .empty;
    var cols: std.ArrayList(u32) = .empty;
    for (0..n) |r| {
        // The row's candidate columns, ascending and once each.
        cols.clearRetainingCapacity();
        for (lin) |half| for (half[r].items) |t| try cols.append(arena, t.col);
        for (guarded) |e| if (e.row == r) try cols.append(arena, e.col);
        std.mem.sort(u32, cols.items, {}, std.sort.asc(u32));
        var prev: ?u32 = null;
        for (cols.items) |c| {
            if (prev == c) continue;
            prev = c;
            if (gen_mask.has(mask, c)) continue;
            const g = lookup(lin[0][r], c);
            const q = lookup(lin[1][r], c);
            if (g != 0 or q != 0) {
                try out.append(arena, .{ .row = @intCast(r), .col = c, .g = g, .c = q });
                continue;
            }
            for (guarded) |e| {
                if (e.row == r and e.col == c and (e.g != 0 or e.c != 0)) try out.append(arena, e);
            }
        }
    }
    return .{ .mask = mask, .entries = out.items };
}

/// `lin` rows from a dense `n × n` coefficient matrix: the tests' spelling.
fn rows(arena: std.mem.Allocator, n: u32, dense: []const f64) ![]LinRow {
    const out = try arena.alloc(LinRow, n);
    for (out, 0..) |*row, r| {
        row.* = .empty;
        for (0..n) |c| if (dense[r * n + c] != 0) try row.append(arena, .{ .col = @intCast(c), .k = dense[r * n + c] });
    }
    return out;
}

/// `plan` over dense `n × n` halves and one-word masks: the tests' spelling.
fn planDense(arena: std.mem.Allocator, n: u32, dr: u64, ddx: u64, lw: u64, g: []const f64, q: []const f64, guarded: []const Entry) !JacConst {
    return plan(arena, n, &.{dr}, &.{ddx}, &.{lw}, .{ try rows(arena, n, g), try rows(arena, n, q) }, guarded);
}

test "a column any lane reads leaves the table; the rest are listed in (row, col) order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // A 2-unknown resistor stamp, 1/R = 0.5, plus a capacitor on q's (1,1).
    const g = [_]f64{ 0.5, -0.5, -0.5, 0.5 };
    const q = [_]f64{ 0, 0, 0, 1e-12 };

    const none = (try planDense(arena.allocator(), 2, 0, 0, 0, &g, &q, &.{}));
    try std.testing.expectEqual(@as(u64, 0), none.mask[0]);
    try std.testing.expectEqualSlices(Entry, &.{
        .{ .row = 0, .col = 0, .g = 0.5, .c = 0 },
        .{ .row = 0, .col = 1, .g = -0.5, .c = 0 },
        .{ .row = 1, .col = 0, .g = -0.5, .c = 0 },
        .{ .row = 1, .col = 1, .g = 0.5, .c = 1e-12 },
    }, none.entries);

    // A `ddx` of unknown 1 puts its lane back: its column is no longer constant.
    const ddx = (try planDense(arena.allocator(), 2, 0, 0b10, 0, &g, &q, &.{}));
    try std.testing.expectEqual(@as(u64, 0b10), ddx.mask[0]);
    try std.testing.expectEqual(@as(usize, 2), ddx.entries.len);
}

test "a guarded stamp is listed with its guard; one that clashes puts its column back" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // Unknowns a, b, and the flow `ib` of a collapsible a–b short: the ±1
    // KCL stamps of ib exist only under pair 0's guard.
    const z: [9]f64 = @splat(0);
    const gd = [_]Entry{
        .{ .row = 0, .col = 2, .g = 1, .c = 0, .when = 0 },
        .{ .row = 1, .col = 2, .g = -1, .c = 0, .when = 0 },
    };
    const j = (try planDense(arena.allocator(), 3, 0b011, 0, 0, &z, &z, &gd));
    try std.testing.expectEqual(@as(u64, 0b011), j.mask[0]);
    try std.testing.expectEqualSlices(Entry, &gd, j.entries);
    // An unguarded stamp at the same (row, col): the column keeps its lane.
    var g1 = z;
    g1[0 * 3 + 2] = 1;
    const c = (try planDense(arena.allocator(), 3, 0b011, 0, 0, &g1, &z, &gd));
    try std.testing.expectEqual(@as(u64, 0b111), c.mask[0]);
    try std.testing.expectEqual(@as(usize, 0), c.entries.len);
}

test "64 unknowns fill one word; lane 63 and cell (63, 63) are reachable" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const z: [64 * 64]f64 = @splat(0);
    var g: [64 * 64]f64 = @splat(0);
    g[63 * 64 + 63] = 2;
    g[63 * 64 + 0] = 3; // column 0 is read, so this cell is not listed
    const j = (try planDense(arena.allocator(), 64, 1, 0, 0, &g, &z, &.{}));
    try std.testing.expectEqual(@as(u64, 1), j.mask[0]);
    try std.testing.expectEqualSlices(Entry, &.{.{ .row = 63, .col = 63, .g = 2, .c = 0 }}, j.entries);
    // A ddx of unknown 63 sets the top bit, and the column leaves the table.
    const top = try planDense(arena.allocator(), 64, 1, @as(u64, 1) << 63, 0, &g, &z, &.{});
    try std.testing.expectEqual((@as(u64, 1) << 63) | 1, top.mask[0]);
    try std.testing.expectEqual(@as(usize, 0), top.entries.len);
}

test "limiter writes join the mask; a guarded zero is no entry; two guards on one cell keep its lane" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const z: [9]f64 = @splat(0);
    var g: [9]f64 = @splat(0);
    g[2 * 3 + 2] = 4; // (2, 2): a constant the table states
    // `limit` writes unknown 2: its column is read back, so (2, 2) leaves.
    const lw = (try planDense(arena.allocator(), 3, 0, 0, 0b100, &g, &z, &.{}));
    try std.testing.expectEqual(@as(u64, 0b100), lw.mask[0]);
    try std.testing.expectEqual(@as(usize, 0), lw.entries.len);
    // A guarded stamp whose coefficients are both zero states nothing.
    const zero_gd = [_]Entry{.{ .row = 1, .col = 2, .g = 0, .c = 0, .when = 0 }};
    const zg = (try planDense(arena.allocator(), 3, 0b011, 0, 0, &z, &z, &zero_gd));
    try std.testing.expectEqual(@as(u64, 0b011), zg.mask[0]);
    try std.testing.expectEqual(@as(usize, 0), zg.entries.len);
    // The same cell under two guards: `contract` wants (row, col) unique, so
    // the column keeps its lane and neither guarded entry is listed.
    const two = [_]Entry{
        .{ .row = 0, .col = 2, .g = 1, .c = 0, .when = 0 },
        .{ .row = 0, .col = 2, .g = 1, .c = 0, .when = 1 },
    };
    const tg = (try planDense(arena.allocator(), 3, 0b011, 0, 0, &z, &z, &two));
    try std.testing.expectEqual(@as(u64, 0b111), tg.mask[0]);
    try std.testing.expectEqual(@as(usize, 0), tg.entries.len);
}

test "past 64 unknowns the mask is two words and column 64 is listed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = 65;
    const z: [n * n]f64 = @splat(0);
    var g: [n * n]f64 = @splat(0);
    g[64 * n + 64] = 2;
    g[0 * n + 64] = -2;
    const half = [2][]const LinRow{ try rows(a, n, &g), try rows(a, n, &z) };
    const j = try plan(a, n, &.{ 1, 0 }, &.{ 0, 0 }, &.{ 0, 0 }, half, &.{});
    try std.testing.expectEqualSlices(u64, &.{ 1, 0 }, j.mask);
    try std.testing.expectEqualSlices(Entry, &.{
        .{ .row = 0, .col = 64, .g = -2, .c = 0 },
        .{ .row = 64, .col = 64, .g = 2, .c = 0 },
    }, j.entries);
    // A read of unknown 64 sets bit 0 of the second word, and the column leaves.
    const r = try plan(a, n, &.{ 1, 1 }, &.{ 0, 0 }, &.{ 0, 0 }, half, &.{});
    try std.testing.expectEqual(@as(usize, 0), r.entries.len);
}
