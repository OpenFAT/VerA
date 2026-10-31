//! The dominator tree `SsaBuilder` reads through: one `Dom` row per block
//! (filled by `SsaBuilder.placeInTree` as each block is sealed) in, the
//! highest ancestor a read may skip to out (`skipUp`), compared by intervals
//! of the clock blocks are born on (`Span`).
//!
//! Cites: §5.8, §5.9 (the conditionals and loops whose blocks it orders).
//!
//! Contents:
//! - `pub const Dom = struct`
//! - `pub const no_dom: u32`
//! - `pub const Span = struct` (`all`, `none`, `join`, `misses`)
//! - `pub const Skip = struct`
//! - `pub fn skipUp(dom: []const Dom, w: Span, b: u32) Skip`

const std = @import("std");
const assert = std.debug.assert;

/// A block's node in the dominator tree, filled when it is sealed.
///
/// A read that reaches a sealed block with no cell for its place reads
/// back to the block's immediate dominator: its one predecessor, or
/// every predecessor of a join. Where nothing wrote the place in
/// between, that is the dominator's value, so `climb` goes straight
/// there, and on up while that holds. Without it a place read at the
/// end of a module climbs every block after its last write, and
/// memoizes a cell in each join: 10^4 instances, each with an `if`, a
/// named generate block's exit and its own branch share, took 5.5 s and
/// 865 MB.
///
/// "Nothing wrote it" compares when blocks got their rows (`born`): a
/// place whose written blocks were all born before, or all after, every
/// block between the dominator and this one (`span`) was written in none
/// of them. A block inside a loop (sealed while a header is open), a
/// loop header and a block that held an incomplete phi get the span
/// that holds everything, never skipped: a read there can mint a phi,
/// and the skip must leave the MIR exactly as Braun's walk does.
pub const Dom = struct {
    /// The immediate dominator, or `no_dom` for a root: the entry, or
    /// a block with an unsealed predecessor or predecessors in
    /// different trees (a loop header).
    parent: u32 = no_dom,
    /// An ancestor up to twice as far as the last one (Myers' skew
    /// binary jump pointers): a climb is O(log depth).
    jump: u32 = no_dom,
    depth: u32 = 0,
    /// `clock` when the block got its row.
    born: u32 = 0,
    /// `born` over this block and every block between `parent` and it:
    /// a place written in no block of it ends this block with the value
    /// it ended `parent` with.
    span: Span = .all,
    /// `span` over this block up to, not including, `jump`.
    jspan: Span = .all,
    /// Got a successor while unsealed (`open_loops`).
    header: bool = false,
    /// Held an incomplete phi.
    phi: bool = false,
    /// Has two or more predecessors.
    join: bool = false,
    /// A block from this one up to, not including, `jump` has two or
    /// more predecessors.
    jjoin: bool = false,

    comptime {
        // Per block, beside `block_state`; `skipUp` reads 26 of its 36 bytes.
        assert(@sizeOf(Dom) == 36);
    }
};

/// `Dom.parent` of a root, and `Dom.jump` before the block is placed.
pub const no_dom: u32 = std.math.maxInt(u32);

/// An interval of `born` clocks.
pub const Span = struct {
    lo: u32,
    hi: u32,

    /// Holds every clock: a span no skip passes.
    pub const all: Span = .{ .lo = 0, .hi = std.math.maxInt(u32) };
    /// Holds no clock: the identity of `join`.
    pub const none: Span = .{ .lo = std.math.maxInt(u32), .hi = 0 };

    /// Returns the smallest span holding both.
    pub fn join(a: Span, b: Span) Span {
        return .{ .lo = @min(a.lo, b.lo), .hi = @max(a.hi, b.hi) };
    }

    /// Every block born in `w` is outside `self`.
    pub fn misses(self: Span, w: Span) bool {
        return w.hi < self.lo or w.lo > self.hi;
    }
};

/// Where `skipUp` stopped, and whether it passed a join on the way.
pub const Skip = struct { to: u32, join: bool };

/// Returns the highest ancestor of `b` (itself included) where a place
/// written in blocks born in `w` ends with the value it has at the end of
/// `b`: up the tree while each block passed has a `span` `w` misses. `join`:
/// a block passed has two or more predecessors. Asserts that `b` is a row of
/// `dom`; each step lowers the depth, so the climb ends within it.
pub fn skipUp(dom: []const Dom, w: Span, b: u32) Skip {
    assert(b < dom.len);
    var x = b;
    var join = false;
    while (dom[x].parent != no_dom and dom[x].span.misses(w)) {
        const from = dom[x].depth;
        if (dom[x].jspan.misses(w)) {
            join = join or dom[x].jjoin;
            x = dom[x].jump;
        } else {
            join = join or dom[x].join;
            x = dom[x].parent;
        }
        assert(dom[x].depth < from); // a parent or a jump is an ancestor
    }
    assert(x == b or dom[x].depth < dom[b].depth);
    return .{ .to = x, .join = join };
}

// ---- private ----

test skipUp {
    // Oracle: a hand-built chain 0 <- 1 <- 2 <- 3 with every block born
    // at its own index. A write born at 0 is missed by every span above the
    // root, so the climb from 3 reaches the root; a write born at 2 stops it
    // at 2, whose own span holds that clock.
    var dom: [4]Dom = undefined;
    for (&dom, 0..) |*d, i| {
        const k: u32 = @intCast(i);
        // As `placeInTree` leaves them: a root jumps to itself over no
        // span, every other block to its parent over its own.
        d.* = .{ .born = k, .depth = k, .jump = k, .jspan = .none };
        if (k != 0) {
            d.parent = k - 1;
            d.span = .{ .lo = k, .hi = k };
            d.jump = k - 1;
            d.jspan = d.span;
        }
    }
    try std.testing.expectEqual(Skip{ .to = 0, .join = false }, skipUp(&dom, .{ .lo = 0, .hi = 0 }, 3));
    try std.testing.expectEqual(Skip{ .to = 2, .join = false }, skipUp(&dom, .{ .lo = 2, .hi = 2 }, 3));
    try std.testing.expectEqual(Skip{ .to = 1, .join = false }, skipUp(&dom, .{ .lo = 1, .hi = 1 }, 1));
}
