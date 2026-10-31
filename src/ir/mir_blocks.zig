//! MIR block chains: a block's intrusive `next` list of instruction rows in,
//! the same rows relinked out. Appending a block, walking its chain, and the
//! three edits the passes make (remove one row, move a whole block, move a
//! tail in front of a terminator), each keeping `BlockRow.first`/`last` and
//! every row's `block` column in step.
//!
//! Cites: §5.8, §5.9 (the blocks are the conditional and loop statements'
//! control flow); otherwise none: this edits VerA's own IR.
//!
//! Contents:
//! - `pub const InstIterator = struct`, `InstIterator.next(it: *InstIterator) ?Inst`
//! - `pub fn addBlock(mir: *Mir, gpa: Allocator) Allocator.Error!Block`
//! - `pub fn blockCount(mir: *const Mir) u32`
//! - `pub fn blockInsts(mir: *const Mir, block: Block) InstIterator`
//! - `pub fn blockLast(mir: *const Mir, block: Block) Inst`
//! - `pub fn unlink(mir: *Mir, block: Block, inst: Inst) void`
//! - `pub fn splice(mir: *Mir, to: Block, from: Block) void`
//! - `pub fn moveTailBefore(mir: *Mir, from: Block, after: Inst, to: Block) bool`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Mir = @import("Mir.zig");
const Inst = Mir.Inst;
const Block = Mir.Block;

/// Iterator over one block's instruction chain.
pub const InstIterator = struct {
    /// Borrowed `next` column. Adding instructions invalidates it: iterate only
    /// after the block is built, or rebind it to the grown column.
    next_col: []const Inst,
    cur: Inst,
    /// Rows returned so far; a chain longer than `next_col` is a cycle.
    steps: u32 = 0,

    /// Returns the next instruction, or null at the end of the chain.
    /// Asserts that the chain does not cycle.
    pub fn next(it: *InstIterator) ?Inst {
        if (it.cur == .none) return null;
        assert(it.steps < it.next_col.len); // more rows than exist ⇒ a cycle
        assert(@backingInt(it.cur) < it.next_col.len);
        const out = it.cur;
        it.cur = it.next_col[@backingInt(out)];
        it.steps += 1;
        return out;
    }
};

/// Appends an empty block and returns its handle; the first call returns
/// `.entry`. Asserts that the block count stays below `Mir.blocks_max`.
pub fn addBlock(mir: *Mir, gpa: Allocator) Allocator.Error!Block {
    const i = mir.blocks.len;
    assert(i < Mir.blocks_max);
    try mir.blocks.append(gpa, .{});
    assert(mir.blocks.len == i + 1);
    return @fromBackingInt(@intCast(i));
}

/// Returns the number of blocks.
pub fn blockCount(mir: *const Mir) u32 {
    assert(mir.blocks.len <= Mir.blocks_max);
    return @intCast(mir.blocks.len);
}

/// Returns an iterator over `block`'s instructions, in emission order (the
/// intrusive `next` chain). The iterator borrows the `next` column: any
/// append to `insts` (every `emit*`) invalidates it. Asserts that `block`
/// exists.
pub fn blockInsts(mir: *const Mir, block: Block) InstIterator {
    assert(@backingInt(block) < mir.blocks.len);
    const it: InstIterator = .{
        .next_col = mir.insts.items(.next),
        .cur = mir.blocks.items(.first)[@backingInt(block)],
    };
    if (it.cur != .none) assert(@backingInt(it.cur) < it.next_col.len);
    return it;
}

/// Returns the last instruction linked into `block`, or `.none` when it is
/// empty. Asserts that `block` exists.
pub fn blockLast(mir: *const Mir, block: Block) Inst {
    assert(@backingInt(block) < mir.blocks.len);
    const last = mir.blocks.items(.last)[@backingInt(block)];
    if (last != .none) assert(@backingInt(last) < mir.insts.len);
    return last;
}

/// Removes `inst` from `block`'s chain; the rows after it stay linked. The row
/// is orphaned, not reused, and keeps its `block` column. Asserts that
/// `inst` is linked into `block`. This operation is O(n) in the block's length.
pub fn unlink(mir: *Mir, block: Block, inst: Inst) void {
    assert(inst != .none);
    assert(@backingInt(block) < mir.blocks.len);
    const next = mir.insts.items(.next);
    const first = mir.blocks.items(.first);
    const last = mir.blocks.items(.last);
    const b = @backingInt(block);
    var prev: Inst = .none;
    var cur = first[b];
    var steps: usize = 0;
    while (cur != inst) : (cur = next[@backingInt(cur)]) {
        assert(cur != .none); // the chain ended without reaching `inst`
        assert(steps < next.len); // a cycle
        steps += 1;
        prev = cur;
    }
    const after = next[@backingInt(inst)];
    if (prev == .none) first[b] = after else next[@backingInt(prev)] = after;
    if (last[b] == inst) last[b] = prev;
    next[@backingInt(inst)] = .none;
    // An empty chain has neither end; a nonempty one has both.
    assert((first[b] == .none) == (last[b] == .none));
}

/// Relinks every row of `from`, in order, at the end of `to`; `from` is left
/// empty. Asserts that both blocks exist and `to != from`.
pub fn splice(mir: *Mir, to: Block, from: Block) void {
    assert(to != from);
    assert(@backingInt(to) < mir.blocks.len);
    assert(@backingInt(from) < mir.blocks.len);
    const first = mir.blocks.items(.first);
    const last = mir.blocks.items(.last);
    const head = first[@backingInt(from)];
    if (head == .none) return;
    restamp(mir, head, to);
    const next = mir.insts.items(.next);
    const tail = last[@backingInt(to)];
    if (tail == .none) first[@backingInt(to)] = head else next[@backingInt(tail)] = head;
    last[@backingInt(to)] = last[@backingInt(from)];
    first[@backingInt(from)] = .none;
    last[@backingInt(from)] = .none;
    assert(last[@backingInt(to)] != .none);
}

/// Unlinks every instruction of `from` after `after` (all of them when `after`
/// is `.none`) and relinks them, in order, in front of `to`'s terminator. For a
/// value computed after a join that one incoming edge has to carry: the
/// operands must already be available at the end of `to`. Returns true when
/// it moved the tail or there was none to move; moves nothing and returns
/// false when `to` has no terminator yet or is `from`. O(len(`to`) + moved).
/// Asserts that both blocks exist and `after`, when given, is a row.
pub fn moveTailBefore(mir: *Mir, from: Block, after: Inst, to: Block) bool {
    assert(@backingInt(from) < mir.blocks.len);
    assert(@backingInt(to) < mir.blocks.len);
    if (after != .none) assert(@backingInt(after) < mir.insts.len);
    const next = mir.insts.items(.next);
    const first = mir.blocks.items(.first);
    const last = mir.blocks.items(.last);
    const head = if (after == .none) first[@backingInt(from)] else next[@backingInt(after)];
    if (head == .none) return true;
    if (from == to) return false;
    // `to`'s terminator and the row before it.
    var prev: Inst = .none;
    var term = first[@backingInt(to)];
    var steps: usize = 0;
    while (term != .none) : (term = next[@backingInt(term)]) {
        assert(steps < next.len); // a cycle
        steps += 1;
        switch (Mir.opClass(mir.insts.items(.op)[@backingInt(term)])) {
            .branch, .jump => break,
            .unary, .binary, .ternary, .phi, .call, .anew, .load, .store => prev = term,
        }
    } else return false;
    const tail = last[@backingInt(from)];
    restamp(mir, head, to);
    if (after == .none) first[@backingInt(from)] = .none else next[@backingInt(after)] = .none;
    last[@backingInt(from)] = after;
    next[@backingInt(tail)] = term;
    if (prev == .none) first[@backingInt(to)] = head else next[@backingInt(prev)] = head;
    assert(next[@backingInt(tail)] == term);
    return true;
}

// ---- private ----

/// Writes `to` into the `block` column of `head` and every row after it.
fn restamp(mir: *Mir, head: Inst, to: Block) void {
    const next = mir.insts.items(.next);
    const home = mir.insts.items(.block);
    var moved = head;
    var steps: usize = 0;
    while (moved != .none) : (moved = next[@backingInt(moved)]) {
        assert(steps < next.len); // a cycle
        steps += 1;
        home[@backingInt(moved)] = to;
    }
    assert(steps != 0);
}

test "mir: block chain edits agree with a list-per-block model (seeded)" {
    // Model-based: every chain edit is mirrored on plain lists, and the
    // chains, `last` and the `block` column are compared after each one.
    const gpa = std.testing.allocator;
    const nb = 4;
    var prng = std.Random.DefaultPrng.init(0x6d69_7263);
    const r = prng.random();
    const Edit = enum { value, jump, unlink, splice, move };
    for (0..40) |round| {
        errdefer std.debug.print("chain model: round {d}\n", .{round});
        var mir: Mir = .{};
        defer mir.deinit(gpa);
        var model: [nb]std.ArrayList(Inst) = @splat(.empty);
        defer for (&model) |*l| l.deinit(gpa);
        var blocks: [nb]Block = undefined;
        for (&blocks) |*b| b.* = try mir.addBlock(gpa);

        for (0..60) |_| {
            const bi = r.uintLessThan(usize, nb);
            switch (r.enumValue(Edit)) {
                .value => {
                    _ = try mir.emit(gpa, blocks[bi], .fneg, &.{.f_one});
                    try model[bi].append(gpa, mir.blockLast(blocks[bi]));
                },
                .jump => {
                    const to = blocks[r.uintLessThan(usize, nb)];
                    try model[bi].append(gpa, try mir.emitJump(gpa, blocks[bi], to));
                },
                .unlink => if (model[bi].items.len != 0) {
                    const k = r.uintLessThan(usize, model[bi].items.len);
                    mir.unlink(blocks[bi], model[bi].orderedRemove(k));
                },
                .splice => {
                    const ti = r.uintLessThan(usize, nb);
                    if (ti != bi) {
                        mir.splice(blocks[ti], blocks[bi]);
                        try model[ti].appendSlice(gpa, model[bi].items);
                        model[bi].clearRetainingCapacity();
                    }
                },
                .move => {
                    const ti = r.uintLessThan(usize, nb);
                    const from = &model[bi];
                    // `after` is none (move every row) or one of `from`'s rows.
                    const keep = r.uintLessThan(usize, from.items.len + 1);
                    const after: Inst = if (keep == 0) .none else from.items[keep - 1];
                    const tail_len = from.items.len - keep;
                    const term_at: ?usize = for (model[ti].items, 0..) |inst, k| {
                        if (mir.instOp(inst) == .jump) break k;
                    } else null;
                    // The documented order: nothing to move, then `to` is
                    // `from`, then `to` has no terminator.
                    const moved = if (tail_len == 0) true else if (ti == bi) false else term_at != null;
                    try std.testing.expectEqual(moved, mir.moveTailBefore(blocks[bi], after, blocks[ti]));
                    if (tail_len != 0 and moved) {
                        try model[ti].insertSlice(gpa, term_at.?, from.items[keep..]);
                        from.shrinkRetainingCapacity(keep);
                    }
                },
            }
            for (blocks, model) |b, m| {
                var it = mir.blockInsts(b);
                for (m.items) |linked| {
                    try std.testing.expectEqual(linked, it.next().?);
                    try std.testing.expectEqual(b, mir.instBlock(linked));
                }
                try std.testing.expect(it.next() == null);
                const last: Inst = if (m.items.len == 0) .none else m.items[m.items.len - 1];
                try std.testing.expectEqual(last, mir.blockLast(b));
            }
        }
    }
}
