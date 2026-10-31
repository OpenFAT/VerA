//! Name suggestions: an unknown name and the names in scope in, the nearest
//! one out, for the did-you-mean help line of every "unknown name"
//! diagnostic. Pure functions over borrowed strings: no allocation, no bag.
//!
//! Cites no LRM clause: a suggestion is help text, not a language rule. The
//! distance is optimal string alignment (Damerau-Levenshtein restricted to
//! adjacent transpositions).
//!
//! Contents:
//! - `pub const name_len_max: usize`
//! - `pub fn editDistance(a: []const u8, b: []const u8, limit: usize) usize`
//! - `pub fn didYouMean(name: []const u8, candidates: []const []const u8) ?[]const u8`
//! - `pub fn didYouMeanMap(comptime V: type, name: []const u8, map: std.StringHashMapUnmanaged(V)) ?[]const u8`
//! - `pub const Nearest = struct`, `init`, `offer`, `best`

const std = @import("std");
const assert = std.debug.assert;

/// Longest name `editDistance` measures; a longer one always measures above
/// the limit, because names that long are not the ones a typo suggestion
/// helps with.
pub const name_len_max: usize = 64;

/// The running minimum of `(editDistance(name, c), c)`: what `didYouMean`
/// computes, for a caller that walks its own candidates (any container, any
/// order) and offers each.
pub const Nearest = struct {
    name: []const u8,
    /// One edit per three characters, and always at least one, so `vd` still
    /// suggests `vds` but `a` suggests only another one-character name.
    limit: usize,
    /// The nearest candidate offered so far, or null.
    best: ?[]const u8 = null,
    best_distance: usize,

    /// Returns a search for names near `name`, with nothing offered yet.
    pub fn init(name: []const u8) Nearest {
        const limit = @max(1, name.len / 3);
        const n: Nearest = .{ .name = name, .limit = limit, .best_distance = limit + 1 };
        assert(n.limit >= 1);
        assert(n.best == null);
        return n;
    }

    /// Considers `candidate`; `name` itself is never a suggestion.
    pub fn offer(self: *Nearest, candidate: []const u8) void {
        if (std.mem.eql(u8, candidate, self.name)) return;
        const d = editDistance(self.name, candidate, self.limit);
        if (d > self.limit) return;
        const better = if (self.best) |b| d < self.best_distance or
            (d == self.best_distance and std.mem.lessThan(u8, candidate, b)) else true;
        if (better) {
            self.best = candidate;
            self.best_distance = d;
        }
        assert(self.best != null);
        assert(self.best_distance <= self.limit);
    }
};

/// Returns the optimal string alignment distance of `a` and `b` when it is
/// at most `limit`, and some value above `limit` otherwise, so a hopeless
/// pair exits early. O(a.len * b.len) at worst; no allocation.
pub fn editDistance(a: []const u8, b: []const u8, limit: usize) usize {
    if (a.len > name_len_max or b.len > name_len_max) return limit + 1;
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;
    if (a.len > b.len + limit or b.len > a.len + limit) return limit + 1;

    // `u8` cells: a distance never exceeds the longer input (<= the max), so
    // the widest value any `@min` sees is the max plus one.
    const Row = [name_len_max + 1]u8;
    // SAFETY: row j of `prev` is written before it is read, for j <= b.len,
    // and `prev2` is read only from the second row on, after it was `prev`.
    var rows: [3]Row = undefined;
    var prev2: *Row = &rows[0];
    var prev: *Row = &rows[1];
    var cur: *Row = &rows[2];

    for (0..b.len + 1) |j| prev[j] = @intCast(j);
    for (a, 0..) |ca, i| {
        cur[0] = @intCast(i + 1);
        var row_min = cur[0];
        for (b, 0..) |cb, j| {
            const cost: u8 = @intFromBool(ca != cb);
            var v = @min(cur[j] + 1, prev[j + 1] + 1, prev[j] + cost);
            if (i > 0 and j > 0 and ca == b[j - 1] and a[i - 1] == cb) v = @min(v, prev2[j - 1] + 1);
            cur[j + 1] = v;
            row_min = @min(row_min, v);
        }
        if (row_min > limit) return limit + 1;
        // `cur` takes over the row nobody reads again, so the three never alias.
        const spent = prev2;
        prev2 = prev;
        prev = cur;
        cur = spent;
    }
    assert(prev[b.len] <= @max(a.len, b.len));
    return prev[b.len];
}

/// Returns the candidate nearest to `name`, or null when nothing is close
/// enough or the only match is `name` itself. Ties break on the candidate,
/// lexicographically, so the answer does not depend on candidate order.
pub fn didYouMean(name: []const u8, candidates: []const []const u8) ?[]const u8 {
    var n: Nearest = .init(name);
    for (candidates) |c| n.offer(c);
    return n.best;
}

/// Returns `didYouMean` over the keys of `map`, streamed without allocating.
/// The answer does not depend on the map's iteration order.
pub fn didYouMeanMap(comptime V: type, name: []const u8, map: std.StringHashMapUnmanaged(V)) ?[]const u8 {
    var n: Nearest = .init(name);
    var it = map.keyIterator();
    while (it.next()) |k| n.offer(k.*);
    return n.best;
}
