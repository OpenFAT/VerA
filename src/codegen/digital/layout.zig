//! An elaborated `Run` -> where things live in the emitted executable: each
//! slot's first plane word and the cells past the slots (§9.7.7 samples,
//! timed-task outputs, scratch words), the pcs a `disable` resumes a process
//! at, and the §9.3.2 forced selects with their `rt.State.parts` rows.
//! Cites: IEEE 1364-2005 §9.3.2 (force of a select), §9.7.7 (intra-
//! assignment timing), §10.2.2 (task outputs), §10.3 (disable).
//!
//! Contents:
//! - `pub const Planes = struct`
//! - `Planes.slotOff(p: *const Planes, at: u32) u32`
//! - `pub const word_cell: u32`
//! - `pub fn scratchCell(w: u32) u32`
//! - `pub fn returnCell(at: u32) u32`
//! - `pub const BlockEnds = struct`
//! - `BlockEnds.of(b: *const BlockEnds, pc: u32) []const u32`
//! - `pub const ForcedParts = struct`
//! - `ForcedParts.partOf(f: *const ForcedParts, slot: u32, sel: Bits) ?u32`
//! - `pub fn planes(arena: Allocator, r: *const Run) Allocator.Error!Planes`
//! - `pub fn cellOf(p: *Planes, arena: Allocator, cell: u32, w: u32) Allocator.Error!u32`
//! - `pub fn blockEnds(arena: Allocator, r: *const Run) Allocator.Error!BlockEnds`
//! - `pub fn forcedParts(arena: Allocator, r: *const Run) Allocator.Error!ForcedParts`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const sim_digital = @import("sim").digital;
const Run = sim_digital.Run;
const Bits = sim_digital.for_emitter.compile.Bits;
const plane_words = @import("plane_words.zig");

/// The planes' word layout: slot `s` starts at word `off[s]`; the slots take
/// `slot_words` words, the cells after them bring the count to `total`.
/// Invariant: `slot_words <= total`, and every `cells` value is a word in
/// `[slot_words, total)`.
pub const Planes = struct {
    off: []const u32 = &.{},
    slot_words: u32 = 0,
    total: u32 = 0,
    /// Per cell key (`cellOf`), its first word.
    cells: std.AutoHashMapUnmanaged(u32, u32) = .empty,

    /// Returns slot `at`'s first word; past the last slot, the end of theirs.
    pub fn slotOff(p: *const Planes, at: u32) u32 {
        assert(p.slot_words <= p.total);
        if (at < p.off.len) assert(p.off[at] <= p.slot_words);
        return if (at < p.off.len) p.off[at] else p.slot_words;
    }
};

/// The cell key of the 64-bit scratch word an integer or a real is staged
/// in before an assignment (`assign.assignWord`).
pub const word_cell: u32 = std.math.maxInt(u32);

/// Per pc, the pcs its process resumes at once the named block or inlined
/// task copy starting there is disabled (§10.3), as CSR: pc `p`'s run is
/// `ends[start[p]..start[p + 1]]`, in code order.
pub const BlockEnds = struct {
    start: []const u32 = &.{},
    ends: []const u32 = &.{},

    /// Returns the resume pcs of the disable targets starting at `pc`.
    pub fn of(b: *const BlockEnds, pc: u32) []const u32 {
        assert(pc + 1 < b.start.len);
        assert(b.start[pc] <= b.start[pc + 1]);
        return b.ends[b.start[pc]..b.start[pc + 1]];
    }
};

/// §9.3.2 the distinct selects the code forces, numbered slot by slot and
/// in code order within a slot (`rt.State.parts`), and per slot whether a
/// `force` holds a select of it, so its net resolves in `rt.net`, whose
/// `store` keeps the forced bits.
pub const ForcedParts = struct {
    parts: std.AutoHashMapUnmanaged(Key, u32) = .empty,
    /// Per slot plus one, its first row (`rt.Design.part_start`); empty when
    /// the design has no procedural continuous assignment at all.
    part_start: []const u32 = &.{},
    select_forced: []const bool = &.{},

    const Key = struct { slot: u32, bits: Bits };

    /// Returns the row of `slot`'s forced select `sel`; null when no
    /// `force` names it.
    pub fn partOf(f: *const ForcedParts, slot: u32, sel: Bits) ?u32 {
        assert(sel.width != 0);
        assert(slot < f.select_forced.len);
        return f.parts.get(.{ .slot = slot, .bits = sel });
    }
};

/// §10.2.2 keys at or past this hold a timed task's output formals between
/// its return and its call site's copy-out.
const return_base: u32 = 1 << 31;

/// Lays the slots out end to end, each `plane_words.words` of its width.
pub fn planes(arena: Allocator, r: *const Run) Allocator.Error!Planes {
    const off = try arena.alloc(u32, r.values.len);
    var total: u32 = 0;
    for (r.values, off) |v, *o| {
        o.* = total;
        total += plane_words.words(v.width);
    }
    assert(off.len == r.values.len);
    if (off.len != 0) assert(off[off.len - 1] <= total);
    return .{ .off = off, .slot_words = total, .total = total };
}

/// Returns the first word of cell `cell`, a `w`-bit value, placing it past
/// every word so far on first use. A cell is written before it is read.
pub fn cellOf(p: *Planes, arena: Allocator, cell: u32, w: u32) Allocator.Error!u32 {
    assert(p.slot_words <= p.total);
    const g = try p.cells.getOrPut(arena, cell);
    if (!g.found_existing) {
        g.value_ptr.* = p.total;
        p.total += plane_words.words(w);
    }
    assert(g.value_ptr.* >= p.slot_words);
    return g.value_ptr.*;
}

/// Returns the cell key of a `w`-bit scratch value: the characters of a
/// §17.2.3 string, a §17.5 PLA's outputs. One cell per width.
pub fn scratchCell(w: u32) u32 {
    const key = word_cell - plane_words.words(w);
    assert(key >= return_base); // A width has fewer than 2^31 words.
    return key;
}

/// Returns the cell key of timed-task output formal `at` (§10.2.2).
pub fn returnCell(at: u32) u32 {
    assert(at < return_base - 1);
    const key = return_base + at;
    assert(key < scratchCell(std.math.maxInt(u32)));
    return key;
}

/// Collects every `disable` target's resume pcs by the pc it starts at: a
/// `.disable_block`'s block, each inlined copy of a `.disable_task`'s task.
pub fn blockEnds(arena: Allocator, r: *const Run) Allocator.Error!BlockEnds {
    const code = r.program.code.items;
    const start = try arena.alloc(u32, code.len + 1);
    @memset(start, 0);
    // Counted into `start[pc + 1]`, then summed: a stable counting sort.
    for (code) |ins| switch (ins) {
        .disable_block => |b| start[b.start + 1] += 1,
        .disable_task => |idx| for (r.routines.rows.items[idx].ranges.items) |rg| {
            start[rg.start + 1] += 1;
        },
        else => {}, // else: only a `disable` resumes a process somewhere it did not suspend
    };
    for (1..start.len) |i| start[i] += start[i - 1];
    const ends = try arena.alloc(u32, start[code.len]);
    const fill = try arena.dupe(u32, start[0..code.len]);
    for (code) |ins| switch (ins) {
        .disable_block => |b| {
            ends[fill[b.start]] = b.end;
            fill[b.start] += 1;
        },
        .disable_task => |idx| for (r.routines.rows.items[idx].ranges.items) |rg| {
            ends[fill[rg.start]] = rg.end;
            fill[rg.start] += 1;
        },
        else => {}, // else: as the count above
    };
    for (fill, start[1..]) |f, s| assert(f == s);
    return .{ .start = start, .ends = ends };
}

/// Numbers the distinct selects the code forces (§9.3.2), slot by slot and
/// in code order within a slot: a net may have any number of them.
pub fn forcedParts(arena: Allocator, r: *const Run) Allocator.Error!ForcedParts {
    const code = r.program.code.items;
    const forced = try arena.alloc(bool, r.values.len);
    @memset(forced, false);
    var any = false;
    for (code) |ins| if (ins == .override_on) {
        any = true;
        if (ins.override_on.bits.some() != null) forced[ins.override_on.slot] = true;
    };
    var out: ForcedParts = .{ .select_forced = forced };
    if (!any) return out;
    const start = try arena.alloc(u32, r.values.len + 1);
    @memset(start, 0);
    // First each one's place within its slot, counted in `start[slot + 1]`.
    for (code) |ins| if (ins == .override_on) if (ins.override_on.bits.some()) |b| {
        const slot = ins.override_on.slot;
        const gop = try out.parts.getOrPut(arena, .{ .slot = slot, .bits = b });
        if (gop.found_existing) continue;
        gop.value_ptr.* = start[slot + 1];
        start[slot + 1] += 1;
    };
    for (1..start.len) |i| start[i] += start[i - 1];
    var it = out.parts.iterator();
    while (it.next()) |e| e.value_ptr.* += start[e.key_ptr.slot];
    assert(out.parts.count() == start[r.values.len]);
    out.part_start = start;
    return out;
}

test "blockEnds: two disable targets at one pc keep code order; a pc with none is empty" {
    // Hand-built: code order puts block end 9 before 7 at start pc 2.
    const b: BlockEnds = .{ .start = &.{ 0, 0, 0, 2, 2 }, .ends = &.{ 9, 7 } };
    try std.testing.expectEqualSlices(u32, &.{ 9, 7 }, b.of(2));
    try std.testing.expectEqualSlices(u32, &.{}, b.of(0));
}

test "cellOf: a cell is placed once, past the slots, and a second width grows the planes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var p: Planes = .{ .off = &.{ 0, 1 }, .slot_words = 3, .total = 3 };
    try std.testing.expectEqual(@as(u32, 3), try cellOf(&p, arena.allocator(), word_cell, 64));
    try std.testing.expectEqual(@as(u32, 3), try cellOf(&p, arena.allocator(), word_cell, 64));
    try std.testing.expectEqual(@as(u32, 4), try cellOf(&p, arena.allocator(), scratchCell(130), 130));
    try std.testing.expectEqual(@as(u32, 7), p.total);
    try std.testing.expectEqual(@as(u32, 3), p.slotOff(2));
}
