//! Post-dominance and join steering: `Analysis`'s CFG tables in; `ipdom`
//! (Cooper, Harvey and Kennedy over the reverse CFG, with a virtual exit) and
//! `steer_off`/`steer_pool` (the branch conditions that pick which edge
//! reaches a join) out. The one writer of those tables.
//!
//! LRM clauses this file's code cites: §4.2.12, §5.9.
//!
//! Contents:
//! - `pub fn build(an: *Analysis, arena: Allocator) Analysis.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Analysis = @import("Analysis.zig");

const none = Analysis.none;

/// Fills `ipdom`, then `steer_off`/`steer_pool`, in `arena`. Asserts that the
/// CFG tables (`cfg.build`) are filled.
pub fn build(an: *Analysis, arena: Allocator) Analysis.Error!void {
    assert(an.rpo.len != 0);
    assert(an.loop_of.len == an.nb);
    try buildPostDominators(an, arena);
    try buildSteer(an, arena);
    assert(an.ipdom.len == an.nb + 1);
    assert(an.steer_off.len == an.nb + 1);
}

// ---- private ----

/// `ipdom`, `nb + 1` long. Blocks with no successor end the body; a block
/// that cannot reach one (a loop with no exit) gets a virtual edge, so every
/// block has an ipdom.
fn buildPostDominators(an: *Analysis, arena: Allocator) Analysis.Error!void {
    const nb = an.nb;
    const exit = nb;
    const reaches = try arena.alloc(bool, nb + 1);
    @memset(reaches, false);
    // Each block is pushed at most once (its flag is set first).
    var stack: std.ArrayList(u32) = try .initCapacity(arena, nb);
    for (0..nb) |b| if (an.succsOf(@intCast(b)).len == 0) {
        reaches[b] = true;
        stack.appendAssumeCapacity(@intCast(b));
    };
    while (stack.pop()) |b| for (an.predsOf(b)) |p| {
        if (reaches[p]) continue;
        reaches[p] = true;
        stack.appendAssumeCapacity(p);
    };
    const to_exit = try arena.alloc(bool, nb);
    for (0..nb) |b| to_exit[b] = an.succsOf(@intCast(b)).len == 0 or !reaches[b];

    // Postorder of the reverse CFG from `exit`: its successors there are the
    // CFG predecessors, and `exit`'s are every `to_exit` block.
    const po = try arena.alloc(u32, nb + 1);
    const num = try arena.alloc(u32, nb + 1);
    @memset(num, none);
    const seen = try arena.alloc(bool, nb + 1);
    @memset(seen, false);
    var n_po: u32 = 0;
    const Frame = struct { b: u32, i: u32 };
    // Each block and `exit` is pushed at most once (`seen`).
    var dfs: std.ArrayList(Frame) = try .initCapacity(arena, nb + 1);
    dfs.appendAssumeCapacity(.{ .b = exit, .i = 0 });
    seen[exit] = true;
    while (dfs.items.len != 0) {
        const top = &dfs.items[dfs.items.len - 1];
        const next: ?u32 = blk: {
            if (top.b == exit) {
                while (top.i < nb) : (top.i += 1) {
                    if (to_exit[top.i] and !seen[top.i]) break :blk top.i;
                }
                break :blk null;
            }
            const ps = an.predsOf(top.b);
            while (top.i < ps.len) : (top.i += 1) {
                if (!seen[ps[top.i]]) break :blk ps[top.i];
            }
            break :blk null;
        };
        if (next) |n| {
            top.i += 1;
            seen[n] = true;
            dfs.appendAssumeCapacity(.{ .b = n, .i = 0 });
        } else {
            num[top.b] = n_po;
            po[n_po] = top.b;
            n_po += 1;
            _ = dfs.pop();
        }
    }
    // `exit` roots the walk, so it is numbered last; each block at most once.
    assert(n_po <= nb + 1);
    assert(po[n_po - 1] == exit);

    const ipdom = try arena.alloc(u32, nb + 1);
    @memset(ipdom, none);
    ipdom[exit] = exit;
    // Bound: a block's ipdom is set once from `none`, then its chain only
    // shrinks, at most `nb + 1` times. Every round but the last changes one.
    const rounds_max = (@as(usize, nb) + 1) * (@as(usize, nb) + 2) + 1;
    var rounds: usize = 0;
    var changed = true;
    while (changed) : (rounds += 1) {
        assert(rounds < rounds_max);
        changed = false;
        var k = n_po;
        while (k > 0) {
            k -= 1;
            const b = po[k];
            if (b == exit) continue;
            var new: u32 = none;
            // Reverse-graph predecessors of b are its CFG successors (and the
            // virtual exit).
            const extra: []const u32 = if (to_exit[b]) &.{exit} else &.{};
            for ([_][]const u32{ an.succsOf(b), extra }) |list| for (list) |s| {
                if (ipdom[s] == none) continue;
                new = if (new == none) s else intersect(ipdom, num, s, new);
            };
            if (new != none and ipdom[b] != new) {
                ipdom[b] = new;
                changed = true;
            }
        }
    }
    assert(ipdom[exit] == exit);
    an.ipdom = ipdom;
}

fn intersect(ipdom: []const u32, num: []const u32, b1: u32, b2: u32) u32 {
    assert(ipdom.len == num.len);
    assert(b1 < num.len);
    assert(b2 < num.len);
    var f1 = b1;
    var f2 = b2;
    // Bound: every pass moves a finger to a higher postorder number, and each
    // finger can rise at most `num.len` times.
    var passes: usize = 0;
    while (f1 != f2) : (passes += 1) {
        assert(passes < 2 * num.len);
        while (num[f1] < num[f2]) f1 = ipdom[f1];
        while (num[f2] < num[f1]) f2 = ipdom[f2];
    }
    return f1;
}

/// `steer_off`/`steer_pool`, counted then filled: a branch steers its
/// immediate post-dominator, where its arms rejoin (the virtual exit has no
/// phis), and every branch inside a loop nest steers each header of that
/// nest (how many times round).
fn buildSteer(an: *Analysis, arena: Allocator) Analysis.Error!void {
    const nb = an.nb;
    var n_heads: u32 = 0;
    for (an.rpo) |h| n_heads += @intFromBool(an.is_loop[h]);
    const heads = try arena.alloc(u32, n_heads);
    n_heads = 0;
    for (an.rpo) |h| if (an.is_loop[h]) {
        heads[n_heads] = h;
        n_heads += 1;
    };
    an.steer_off = try arena.alloc(u32, nb + 1);
    @memset(an.steer_off, 0);
    var at: []u32 = &.{};
    for ([_]bool{ false, true }) |fill| {
        if (fill) {
            for (1..nb + 1) |b| an.steer_off[b] += an.steer_off[b - 1];
            an.steer_pool = try arena.alloc(Mir.Value, an.steer_off[nb]);
            at = try arena.dupe(u32, an.steer_off[0..nb]);
        }
        for (an.rpo) |bi| {
            const t = an.term[bi];
            if (t == .none or an.i_op[@backingInt(t)] != .branch) continue;
            const cond = an.mir.instData(t).branch.cond;
            const join = an.ipdom[bi];
            if (join < nb) {
                if (fill) {
                    an.steer_pool[at[join]] = cond;
                    at[join] += 1;
                } else an.steer_off[join + 1] += 1;
            }
            const nest = an.loop_of[bi];
            if (nest == none) continue;
            for (heads) |h| {
                if (an.loop_of[h] != nest) continue;
                if (fill) {
                    an.steer_pool[at[h]] = cond;
                    at[h] += 1;
                } else an.steer_off[h + 1] += 1;
            }
        }
    }
    for (0..nb) |b| assert(at[b] == an.steer_off[b + 1]);
}
