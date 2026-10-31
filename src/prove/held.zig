//! §3.2 held-slot pruning: a lowered MIR and its `Lowered` in; the MIR with
//! every unobservable held slot's seed aliased to its initializer and the
//! kept rows renumbered, and the mask of `Lowered.held_vars` rows to keep,
//! out. Lowering applies the mask (`Lower.dropHeld`): only lowering writes
//! `Lowered`. Runs between lowering and if-conversion (`src/Compilation.zig`
//! stage 4.4): it needs solve invariance, and a select must not yet hide the
//! merges it reads.
//!
//! A `.unless_invariant` held variable has no read that reaches a later
//! write of the same evaluation (`lower_param.Exposed`), so its held value is
//! observed only where it merges with a write: a phi or a select fed by the
//! `$held_*` seed. When every such merge is solve-invariant (its block and
//! incoming edges depend only on invariant branches, a select's condition is
//! invariant), a fixed card either writes the variable before every read or
//! never writes it, so the slot always equals the declared initializer.
//! Every candidate is still held while invariance is solved, so a condition
//! over one reads as varying, which is conservative.
//!
//! LRM clauses this file's code cites: §3.2.
//!
//! Contents:
//! - `pub const Error = Allocator.Error`
//! - `pub fn prune(arena: Allocator, mir: *Mir, lowered: *const Lowered) Error!?[]const bool`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const Analysis = @import("Analysis.zig");
const Input = @import("input.zig").Input;
const setup = @import("setup.zig");
const invariance = @import("invariance.zig");
const Fixture = @import("fixture.zig").Fixture;

/// Fails only on allocation, in `arena`. A failure leaves the MIR's
/// instructions as they were; at most some integer constants were added.
pub const Error = Allocator.Error;

/// Finds the held slots the card makes unobservable, rewrites `mir` in place
/// and returns which `lowered.held_vars` rows to keep (one flag per row, in
/// `arena`), or null when every row stays and nothing changed. Lowering
/// applies the mask before the next MIR check, since the MIR already numbers
/// the kept rows densely. Invalidates every `Analysis` built over `mir`.
pub fn prune(arena: Allocator, mir: *Mir, lowered: *const Lowered) Error!?[]const bool {
    const held = lowered.held_vars.items;
    for (held) |h| {
        if (h.why == .unless_invariant) break;
    } else return null;
    const an = try Analysis.build(arena, mir, lowered);
    const in: Input = .{ .arena = arena, .mir = mir, .an = &an, .lowered = lowered };
    const s = try invariance.solve(in, .invariance_only);
    // At most one merge per instruction: sized once, never grown.
    var merges: std.ArrayList(Mir.Inst) = try .initCapacity(arena, mir.instCount());
    for (an.inst_pool) |inst| switch (mir.instOp(inst)) {
        .phi, .select => merges.appendAssumeCapacity(inst),
        else => {}, // else: only a phi or a select merges a held value with a write
    };
    const web = try arena.alloc(bool, an.nv);
    const keep = try arena.alloc(bool, held.len);
    for (held, keep) |h, *k| k.* = h.why != .unless_invariant or observed(in, s, merges.items, web, h.seed);
    // The fallible work, before the commit: each kept scalar seed's new row
    // argument, in row order, as the rewrite below will number them.
    const rows = try rowArgs(arena, mir, held, keep);

    for (held, keep) |h, k| {
        if (k) continue;
        // `.unless_invariant` is a scalar's reason only: `holdArray` rows are
        // `.event`, so no `mem_arrays` row is left pointing here.
        assert(h.array == Lowered.none_u32);
        const seed = an.rv(h.seed);
        const inst = mir.valueDef(seed).inst_result;
        mir.unlink(@fromBackingInt(an.def_block[@backingInt(seed)]), inst);
        mir.setAlias(seed, h.init);
    }
    // The seed's argument is its row (`gen_call.heldIdx`), counted over the
    // kept rows. A held array's seed is its `anew`, which carries no row: its
    // `mem_arrays` entry does, and `Lower.dropHeld` renumbers that.
    for (held, keep, rows) |h, k, row| {
        if (!k or h.array != Lowered.none_u32) continue;
        const inst = mir.valueDef(an.rv(h.seed)).inst_result;
        mir.extra.items[mir.insts.items(.b)[@backingInt(inst)] + 1] = @backingInt(row);
    }
    return keep;
}

// ---- private ----

/// Whether a merge of `seed`'s forward web varies from one evaluation to the
/// next.
fn observed(in: Input, s: setup.Invariance, merges: []const Mir.Inst, web: []bool, seed: Mir.Value) bool {
    const mir = in.mir;
    const an = in.an;
    assert(web.len == an.nv);
    @memset(web, false);
    web[@backingInt(an.rv(seed))] = true;
    // Bound: `web` only rises; every round but the last adds one merge.
    var rounds: usize = 0;
    var changed = true;
    while (changed) : (rounds += 1) {
        assert(rounds <= merges.len);
        changed = false;
        for (merges) |m| {
            const r = an.rv(mir.instResult(m));
            if (web[@backingInt(r)]) continue;
            const blk = an.def_block[@backingInt(r)];
            var feeds = false;
            var fixed = blk != Analysis.none and s.placeable[blk];
            switch (mir.instData(m)) {
                .phi => |d| for (0..d.count) |k| {
                    const p = mir.phiPair(m, @intCast(k));
                    feeds = feeds or web[@backingInt(an.rv(p.value))];
                    fixed = fixed and s.placeable[@backingInt(p.block)];
                },
                .ternary => |d| {
                    feeds = web[@backingInt(an.rv(d.then_val))] or web[@backingInt(an.rv(d.else_val))];
                    fixed = fixed and s.invariant[@backingInt(an.rv(d.cond))];
                },
                else => unreachable, // else: `merges` holds phis and selects only
            }
            if (!feeds) continue;
            if (!fixed) return true;
            web[@backingInt(r)] = true;
            changed = true;
        }
    }
    return false;
}

/// Each held row's new seed argument, `.undef` for a dropped row or an
/// array's: its index among the kept rows, as an integer constant.
fn rowArgs(arena: Allocator, mir: *Mir, held: []const Lowered.HeldVar, keep: []const bool) Error![]Mir.Value {
    assert(held.len == keep.len);
    const rows = try arena.alloc(Mir.Value, held.len);
    var i: usize = 0;
    for (held, keep, rows) |h, k, *row| {
        row.* = .undef;
        if (!k) continue;
        defer i += 1;
        if (h.array != Lowered.none_u32) continue;
        row.* = try mir.addIntConst(arena, @intCast(i));
    }
    assert(i <= held.len);
    return rows;
}

test "held.prune leaves a module with no card-conditional retention untouched" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{"a"});
    defer f.deinit();
    const a = f.alloc();
    const seed = try f.call("$held_real", &.{.zero});
    try f.lowered.held_vars.append(a, .{ .name = "x", .ty = .real, .init = .f_zero, .seed = seed, .final = seed, .why = .retained });
    const n_insts = f.mir.insts.len;
    // Nothing to decide, so no mask: the spine has nothing to apply.
    try std.testing.expect(try prune(a, &f.mir, &f.lowered) == null);
    try std.testing.expectEqual(@as(usize, 1), f.lowered.held_vars.items.len);
    try std.testing.expectEqual(n_insts, f.mir.insts.len);
    try std.testing.expect(!f.mir.hasAlias(seed));
}

test "held.prune: a held slot read only under card-fixed control is aliased to its initializer and dropped" {
    // entry: s = $held_real(0) (`.unless_invariant`), k = s + 1. Nothing
    // merges `s` with a write, so no card can observe the slot.
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{"a"});
    defer f.deinit();
    const a = f.alloc();
    const seed = try f.call("$held_real", &.{.zero});
    const k = try f.mir.emit(a, .entry, .fadd, &.{ seed, .f_one });
    try f.lowered.held_vars.append(a, .{ .name = "s", .ty = .real, .init = .f_two, .seed = seed, .final = seed, .why = .unless_invariant });
    const keep = (try prune(a, &f.mir, &f.lowered)).?;
    try std.testing.expectEqualSlices(bool, &.{false}, keep);
    try std.testing.expectEqual(Mir.Value.f_two, f.mir.resolveAlias(seed));
    // The seed row left its block's chain; its user still reads through it.
    var it = f.mir.blockInsts(.entry);
    while (it.next()) |inst| try std.testing.expect(f.mir.instResult(inst) != seed);
    try std.testing.expectEqual(seed, f.mir.instData(f.mir.valueDef(k).inst_result).binary.lhs);
}
