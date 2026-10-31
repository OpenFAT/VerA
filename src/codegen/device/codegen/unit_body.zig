//! One unit's slice plan (`Gen.cur.plan`) -> its body text: the slot
//! declarations (each slot declared where `probeBody`'s dry run found it can
//! be, the out-of-SSA slots hoisted into one array per mask), the §3.2.2 local
//! arrays, and the relooped CFG (`cfg.zig`) that computes the unit's target or
//! every core live-out.
//! Cites: §3.2, §3.2.2, §5.6.1.3, §5.10.
//!
//! Contents:
//! - `pub const Probe = struct`
//! - `pub const Hoist = struct`
//! - `pub const Place = struct`
//! - `pub fn zigTy(t: VTy) []const u8`
//! - `pub fn slotTy(self: *Gen, i: usize) Error![]const u8`
//! - `pub fn writeSlotRef(self: *Gen, i: usize) Error!void`
//! - `pub fn slotMask(self: *Gen, i: usize) ?[]const u64`
//! - `pub fn slotRefStr(self: *Gen, i: usize) Error![]const u8`
//! - `pub fn zeroOf(t: VTy) []const u8`
//! - `pub fn scopeOpen(self: *Gen) Error!void`
//! - `pub fn scopeClose(self: *Gen, at: usize) void`
//! - `pub fn probeDef(self: *Gen, slot: u32, movable: bool) void`
//! - `pub fn probeUse(self: *Gen, slot: u32) void`
//! - `pub fn emitUnitBody(self: *Gen, target: Mir.Value) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_cfg = @import("cfg.zig");
const gen_setup = @import("setup.zig");
const render_array = @import("render_array.zig");
const gen_wide = @import("wide.zig");
const family = @import("family.zig");
const gen_mask = @import("mask.zig");
const Mir = @import("ir").Mir;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const VTy = codegen.VTy;

/// The dry run `probeBody` makes of a body, and what it learned (`Gen.probe`).
/// Arena lists, cleared per run.
pub const Probe = struct {
    /// Set for the duration of the dry run; every recorder below is a no-op
    /// otherwise.
    active: bool = false,
    /// Where each slot's declaration goes, by slot. Meaningful only on the
    /// out-of-SSA path (`straight` declares everything at its definition).
    place: std.ArrayList(Place) = .empty,
    /// Emitted lexical scopes, as half-open output offsets: `sc_end` their
    /// closing offset once written, and `sc_open` the stack of indices into
    /// `sc_end` still being written.
    sc_end: std.ArrayList(u32) = .empty,
    sc_open: std.ArrayList(u32) = .empty,
};

/// The out-of-SSA slots that survived `probeBody` as hoisted function-scope
/// arrays (`Gen.hoist`): one array per real mask (`h<g>`) plus `hi`/`hs`,
/// rather than one `var tN` apiece. Arena lists, rebuilt per body by
/// `emitUnitBody`.
pub const Hoist = struct {
    /// Per slot: its index inside its type's hoist array, or `none_u32` for a
    /// slot that keeps its own name. All-`none_u32` while probing, so the dry
    /// run names every slot `tN`; `probeBody` only compares offsets within
    /// its own text.
    idx: std.ArrayList(u32) = .empty,
    // Per real hoist element (indexed by `idx`): its mask, and where it
    // lives, array `h<grp>` at `[pos]`.
    mask: std.ArrayList([]u64) = .empty,
    grp: std.ArrayList(u32) = .empty,
    pos: std.ArrayList(u32) = .empty,
    // Per array `h<g>`: it holds every element of mask `gmask[g]` (distinct,
    // in first-use order) and is `glen[g]` long.
    gmask: std.ArrayList([]const u64) = .empty,
    glen: std.ArrayList(u32) = .empty,
};
// =======================================================================
// Units
// =======================================================================

/// Where one slot's declaration ends up, and the evidence for it.
///
/// `max_use` is an output offset and `scope` an index into `Probe.sc_end`.
/// The emitted scopes nest, so once `pinned` rules out a read before the
/// definition, "every use is lexically inside the block that defines this
/// slot" is exactly `max_use < sc_end[scope]`, with no dominator query needed.
/// `defs`/`uses` saturate at 255: every reader asks only 0, 1 or more.
pub const Place = struct {
    defs: u8 = 0,
    uses: u8 = 0,
    max_use: u32 = 0,
    scope: u32 = 0,
    /// Something disqualifies this slot from `const`-at-definition: a
    /// second assignment (a real phi), a phi copy on a CFG edge, or a use
    /// emitted before the assignment (a loop-carried read).
    pinned: bool = false,
    /// Set once, after the probe: declare at the definition instead of at
    /// function scope.
    at_def: bool = false,

    // One per slot of the body being probed (psp103's `setup`: 6854;
    // hisimhv_va: 10097), walked whole by `probeBody`: 12 bytes, two
    // offsets and four one-byte facts.
    comptime {
        std.debug.assert(@sizeOf(Place) == 12);
    }
};

/// Returns the Zig type a value of type `t` is emitted as. A `.wide` value's
/// type is its width's (`slotTy`).
pub fn zigTy(t: VTy) []const u8 {
    return switch (t) {
        .real => "S",
        .int => "i64",
        .str => "[]const u8",
        .wide => unreachable, // `slotTy` spells it from the value's width
    };
}

/// Returns the Zig type value `i` is emitted as.
pub fn slotTy(self: *Gen, i: usize) Error![]const u8 {
    assert(i < self.an.nv);
    assert(self.an.vty.len == self.an.nv);
    if (self.an.vty[i] == .wide) return gen_wide.zigTy(self, self.an.wide_w[i]);
    return zigTy(self.an.vty[i]);
}

/// Writes the name value `i`'s slot is read and written under: its own `tN`
/// or an element of a hoist array. Every slotted use goes through it.
pub fn writeSlotRef(self: *Gen, i: usize) Error!void {
    assert(i < self.an.nv);
    assert(self.cur.plan.slot[i] != none_u32);
    if (slotArr(self, i)) |arr| {
        const k = slotNum(self, i);
        if (self.an.vty[i] == .real) return self.b("h{d}[{d}]", .{ self.cur.hoist.grp.items[k], self.cur.hoist.pos.items[k] });
        return self.b("{s}[{d}]", .{ arr, k });
    }
    return self.b("t{d}", .{slotNum(self, i)});
}

/// Returns the mask of value `i`'s slot when it is an element of the real
/// hoist array (what a write into it widens to), or null for a `const`.
pub fn slotMask(self: *Gen, i: usize) ?[]const u64 {
    assert(i < self.an.nv);
    if (self.an.vty[i] != .real) return null;
    if (slotArr(self, i) == null) return null;
    return self.cur.hoist.mask.items[slotNum(self, i)];
}

/// Returns `writeSlotRef`'s text as an arena-owned string, for a caller that
/// needs the name as a value (`f64Const`).
pub fn slotRefStr(self: *Gen, i: usize) Error![]const u8 {
    assert(i < self.an.nv);
    assert(self.cur.plan.slot[i] != none_u32);
    if (slotArr(self, i)) |arr| {
        const k = slotNum(self, i);
        if (self.an.vty[i] == .real) return self.arena.print("h{d}[{d}]", .{ self.cur.hoist.grp.items[k], self.cur.hoist.pos.items[k] });
        return self.arena.print("{s}[{d}]", .{ arr, k });
    }
    return self.arena.print("t{d}", .{slotNum(self, i)});
}

/// Returns the zero a slot of type `t` starts at when it must be defined on
/// every path. Matches `renderVal`'s rendering of an `.undef` operand.
pub fn zeroOf(t: VTy) []const u8 {
    return switch (t) {
        .real => "S.con(0.0)",
        .int => "0",
        .str => "\"\"",
        .wide => unreachable, // its zero has its width (`slotZero`)
    };
}

/// Records that a lexical scope opens at the current output offset. No-op
/// unless `probe.active`.
pub fn scopeOpen(self: *Gen) Error!void {
    assert(self.cur.probe.sc_open.items.len <= self.cur.probe.sc_end.items.len);
    if (!self.cur.probe.active) return;
    try self.cur.probe.sc_end.append(self.arena, 0);
    try self.cur.probe.sc_open.append(self.arena, @intCast(self.cur.probe.sc_end.items.len - 1));
}

/// Records that the innermost open scope ends at `at`, which is not always
/// `out.len`: the `cfg.zig` peephole rewinds over a label it drops.
/// No-op unless `probe.active`.
pub fn scopeClose(self: *Gen, at: usize) void {
    assert(at <= self.out.items.len);
    if (!self.cur.probe.active) return;
    assert(self.cur.probe.sc_open.items.len != 0);
    self.cur.probe.sc_end.items[self.cur.probe.sc_open.pop().?] = @intCast(at);
}

/// Records the definition of `slot` at the current offset while `probe.active`.
/// `movable` is false for a phi copy: `emitPhiCopies` writes the slot from
/// several edges, and even a single-edge copy lands in an arm its merge
/// block's readers are lexically outside of.
pub fn probeDef(self: *Gen, slot: u32, movable: bool) void {
    assert(slot < self.cur.plan.n_slots);
    if (!self.cur.probe.active) return;
    const p = &self.cur.probe.place.items[slot];
    if (p.defs == 0) p.scope = self.cur.probe.sc_open.last().?;
    p.defs +|= 1;
    if (p.defs > 1 or !movable) p.pinned = true;
}

/// Records a read of `slot` at the current offset while `probe.active`.
pub fn probeUse(self: *Gen, slot: u32) void {
    assert(slot < self.cur.plan.n_slots);
    if (!self.cur.probe.active) return;
    const p = &self.cur.probe.place.items[slot];
    p.uses +|= 1;
    // Read before written in the text: a loop-carried value, or a slot the
    // emitter never assigns at all (which is the `undefined`/zero seed the
    // hoist exists to provide).
    if (p.defs == 0) p.pinned = true;
    p.max_use = @max(p.max_use, @as(u32, @intCast(self.out.items.len)));
}

/// Emits the body computing `target` (or every live-out, while
/// `emitting_common`): slot declarations, then the structured control flow.
/// Requires `self.cur.plan` to be analyzed for this unit.
pub fn emitUnitBody(self: *Gen, target: Mir.Value) Error!void {
    assert(self.cur.plan.slot.len == self.an.nv);
    assert(!self.cur.probe.active);
    // First, before anything can emit a slot name: slot numbering is
    // unit-local, so the previous unit's hoist indices would rename this
    // unit's slots. Both paths below can emit before the real assignment.
    self.cur.hoist.idx.clearRetainingCapacity();
    try self.cur.hoist.idx.appendNTimes(self.arena, none_u32, self.cur.plan.n_slots);

    // One call at the top of the body, so the shared core is evaluated
    // exactly once per unit.
    if (self.cur.plan.uses_cache) {
        self.cur.uses.x = true;
        self.cur.uses.model = true;
        self.cur.uses.inst = true;
        self.cur.uses.sim = true;
        try self.ind(1);
        try self.b("const c = @call(.always_inline, core, .{{ S, x, model, inst, sim{s} }});\n", .{self.heldArg(true)});
    }
    try declareArrays(self);
    if (self.cur.plan.straight) {
        try gen_cfg.emitBlockInsts(self, 0, 1, true);
        try gen_cfg.emitReturn(self, 1, target);
        return;
    }
    // Out-of-SSA: a function-scope `var` per surviving value that needs one.
    // A labelled-block reconstruction can put a definition inside a scope its
    // uses are lexically outside of; `probeBody` finds those, and
    // `emitBlockInsts` declares the rest as `const` at the definition.
    // Left hoisted: values assigned more than once (a real phi), assigned by
    // `emitPhiCopies`, read outside the assigning block, or never assigned.
    //
    // `undefined` is safe for every slot except one the function returns: the
    // return is reached from exit blocks the definition need not dominate
    // (`if (c) I <+ transition(x)`), and `updateState` would push that value
    // into operator history. Zero is the right value, not just a safe one:
    // the arm did not execute, so it contributed nothing, the same reason
    // lowering seeds a §5.6 accumulator with `.f_zero`.
    try probeBody(self, target);
    if (gen_setup.mergePays(self)) {
        self.su.merge = true;
        try probeBody(self, target);
    }
    const ret = self.an.rv(target);

    // One array per type instead of one `var` per slot. Two passes: assign
    // every survivor its index, so the lengths are known, then emit the
    // declarations.
    var n_hoist: [std.enums.values(VTy).len]u32 = @splat(0);
    // IEEE 1364 §5.4 a `.wide` slot: its own `var tN`, of its width's type.
    var own: std.ArrayList(Mir.Value) = .empty;
    defer own.deinit(self.arena);
    // A returned slot cannot be seeded `undefined` (see above), and an array
    // is declared once for all its elements, so those get an explicit store
    // after the declaration.
    var seeded: std.ArrayList(Mir.Value) = .empty;
    defer seeded.deinit(self.arena);
    for (self.cur.plan.live.items) |lv| {
        const v = @backingInt(lv);
        if (self.cur.plan.slot[v] == none_u32) continue;
        const p = self.cur.probe.place.items[self.cur.plan.slot[v]];
        if (p.at_def) continue;
        // Never assigned and never read: `mark` kept the value alive but the
        // emitted tree reaches neither end. Declaring it would be an unused local.
        if (p.defs == 0 and p.uses == 0) continue;
        const returned = if (self.cur.emitting_common) self.cur.plan.lo_idx[v] != none_u32 else lv == ret;
        if (returned) try seeded.append(self.arena, lv);
        if (self.an.vty[v] == .wide) {
            try own.append(self.arena, lv);
            continue;
        }
        const ty = @backingInt(self.an.vty[v]);
        self.cur.hoist.idx.items[self.cur.plan.slot[v]] = n_hoist[ty];
        n_hoist[ty] += 1;
    }
    try hoistMasks(self, n_hoist[@backingInt(VTy.real)]);
    for ([_]VTy{ .real, .int, .str }) |ty| {
        const n = n_hoist[@backingInt(ty)];
        if (n == 0) continue;
        try self.ind(1);
        if (ty == .real) {
            for (self.cur.hoist.gmask.items, self.cur.hoist.glen.items, 0..) |m, len, g| {
                if (g != 0) try self.ind(1);
                try self.b("var h{d}: [{d}]zOf(S, 0x{f}) = undefined;\n", .{ g, len, gen_mask.hex(m, false) });
            }
            continue;
        }
        try self.b("var {s}: [{d}]{s} = undefined;\n", .{ hoistArray(ty), n, zigTy(ty) });
    }
    for (own.items) |lv| {
        try self.ind(1);
        try self.b("var t{d}: {s} = undefined;\n", .{ self.cur.plan.slot[@backingInt(lv)], try slotTy(self, @backingInt(lv)) });
    }
    for (seeded.items) |lv| {
        const v = @backingInt(lv);
        try self.ind(1);
        try writeSlotRef(self, v);
        try self.b(" = ", .{});
        const m = slotMask(self, v);
        if (m) |k| try family.openTo(self, k);
        try self.b("{s}", .{try slotZero(self, v)});
        if (m != null) try self.b(")", .{});
        try self.b(";\n", .{});
    }
    // The probes' arms were rewound with their text.
    self.cur.init_arms.clearRetainingCapacity();
    try gen_setup.emitRoot(self, target);
}

// ---- private ----

/// Returns the zero value `i`'s slot starts at (`zeroOf`).
fn slotZero(self: *Gen, i: usize) Error![]const u8 {
    assert(i < self.an.nv);
    if (self.an.vty[i] == .wide) return self.arena.print("zwZero({d})", .{self.an.wide_w[i]});
    return zeroOf(self.an.vty[i]);
}

/// Returns the name of the hoist array a slot of type `t` lives in (`Hoist.idx`).
/// A `.wide` slot keeps its own `var tN`: its type is its width's.
fn hoistArray(t: VTy) []const u8 {
    return switch (t) {
        .real => "h",
        .int => "hi",
        .str => "hs",
        .wide => unreachable, // never hoisted (`emitUnitBody`)
    };
}

// `slotArr`/`slotNum` are the one place that knows whether a slot is its own
// `tN` or a hoist-array element, so declaration and use cannot drift apart.
fn slotArr(self: *Gen, i: usize) ?[]const u8 {
    assert(self.cur.plan.slot[i] != none_u32);
    const s = self.cur.plan.slot[i];
    if (s < self.cur.hoist.idx.items.len and self.cur.hoist.idx.items[s] != none_u32) return hoistArray(self.an.vty[i]);
    return null;
}

fn slotNum(self: *Gen, i: usize) u32 {
    assert(self.cur.plan.slot[i] != none_u32);
    const s = self.cur.plan.slot[i];
    if (s < self.cur.hoist.idx.items.len and self.cur.hoist.idx.items[s] != none_u32) return self.cur.hoist.idx.items[s];
    return s;
}

/// Every real hoist element's mask: the union over the values that share it.
fn hoistMasks(self: *Gen, n: u32) Error!void {
    self.cur.hoist.mask.clearRetainingCapacity();
    try self.cur.hoist.mask.ensureTotalCapacityPrecise(self.arena, n);
    for (0..n) |_| self.cur.hoist.mask.appendAssumeCapacity(try gen_mask.zero(self.arena, self.mw));
    assert(self.cur.hoist.mask.items.len == n);
    for (self.cur.plan.live.items) |lv| {
        const v = @backingInt(lv);
        if (self.an.vty[v] != .real or self.cur.plan.slot[v] == none_u32) continue;
        const k = self.cur.hoist.idx.items[self.cur.plan.slot[v]];
        if (k == none_u32) continue;
        gen_mask.orIn(self.cur.hoist.mask.items[k], family.mask(self, lv));
    }
    for (self.cur.hoist.mask.items) |m| try family.note(self, m);
    // One array per distinct mask: a `@Tuple` with one field per slot is
    // most of a large body's sema time (psp103 `setup`: 1,576 fields, 9
    // masks; `git show 6e59b3d4^:docs/measurements/codegen-levers-2026-09-30.md` lever 5), and
    // every element keeps exactly the type its tuple field had.
    // One `grp`/`pos` entry per hoist element.
    self.cur.hoist.grp.clearRetainingCapacity();
    try self.cur.hoist.grp.ensureTotalCapacityPrecise(self.arena, n);
    self.cur.hoist.pos.clearRetainingCapacity();
    try self.cur.hoist.pos.ensureTotalCapacityPrecise(self.arena, n);
    self.cur.hoist.gmask.clearRetainingCapacity();
    self.cur.hoist.glen.clearRetainingCapacity();
    for (self.cur.hoist.mask.items) |m| {
        // ponytail: linear scan; a body has 1-30 distinct masks.
        const g = for (self.cur.hoist.gmask.items, 0..) |gm, j| {
            if (std.mem.eql(u64, gm, m)) break j;
        } else blk: {
            try self.cur.hoist.gmask.append(self.arena, m);
            try self.cur.hoist.glen.append(self.arena, 0);
            break :blk self.cur.hoist.gmask.items.len - 1;
        };
        self.cur.hoist.grp.appendAssumeCapacity(@intCast(g));
        self.cur.hoist.pos.appendAssumeCapacity(self.cur.hoist.glen.items[g]);
        self.cur.hoist.glen.items[g] += 1;
    }
}

/// Emits the body once as a dry run to learn, per slot, where its assignment
/// lands relative to its reads, then rewinds `out`. A dry run rather than a
/// dominator query because the emitted nesting is not the CFG (dead branches,
/// dropped labels and inlined arms). Safe to run twice: emission only appends
/// to `out` and sets monotone flags, and `fatal` is set-once.
fn probeBody(self: *Gen, target: Mir.Value) Error!void {
    assert(!self.cur.probe.active);
    self.cur.probe.place.clearRetainingCapacity();
    try self.cur.probe.place.appendNTimes(self.arena, .{}, self.cur.plan.n_slots);
    self.cur.probe.sc_end.clearRetainingCapacity();
    self.cur.probe.sc_open.clearRetainingCapacity();

    const at = self.out.items.len;
    self.su.exits = 0;
    self.su.store_bytes = 0;
    self.cur.probe.active = true;
    try scopeOpen(self); // the function body itself
    try gen_setup.emitRoot(self, target);
    scopeClose(self, self.out.items.len);
    self.cur.probe.active = false;
    self.su.lines = std.mem.count(u8, self.out.items[at..], "\n");
    self.out.shrinkRetainingCapacity(at);

    for (self.cur.probe.place.items) |*p| {
        // `uses == 0` keeps its `var`: a slot that is written and never read
        // is legal Zig, but the same code as an unused `const` is not.
        p.at_def = !p.pinned and p.defs == 1 and p.uses != 0 and
            p.max_use < self.cur.probe.sc_end.items[p.scope];
    }
}

/// Declares §3.2.2 `var a<id>: [len]T` for each memory-backed array this body
/// writes or reads locally, in array order. Its first `anew` fills it.
fn declareArrays(self: *Gen) Error!void {
    assert(self.arr_s.len == self.lowered.mem_arrays.items.len);
    const n = self.lowered.mem_arrays.items.len;
    if (n == 0) return;
    const seen = try self.arena.alloc(bool, n);
    @memset(seen, false);
    // §5.10 a copy-on-write array needs its local storage only if a store
    // writes it; until one does, `p<id>` is the whole of it.
    const stored = try self.arena.alloc(bool, n);
    @memset(stored, false);
    for (self.cur.plan.live.items) |lv| {
        const id = self.an.arrOf(lv) orelse continue;
        if (self.cur.plan.cached(lv)) continue;
        seen[id] = true;
        const def = self.mir.valueDef(lv);
        if (def == .inst_result and self.mir.instOp(def.inst_result) == .store) stored[id] = true;
    }
    for (seen, stored, 0..) |s, st, id| {
        if (!s) continue;
        const len = self.lowered.mem_arrays.items[id].len;
        const ty = try render_array.arrElemTy(self, @intCast(id));
        if (render_array.inPlace(self, @intCast(id))) {
            try self.ind(1);
            try self.b("var p{d}: *[{d}]{s} = undefined;\n", .{ id, len, ty });
            continue;
        }
        if (render_array.cow(self, @intCast(id))) {
            try self.ind(1);
            try self.b("var p{d}: *const [{d}]{s} = undefined;\n", .{ id, len, ty });
            if (!st) continue;
        }
        try self.ind(1);
        try self.b("var a{d}: [{d}]{s} = undefined;\n", .{ id, len, ty });
    }
}

test zigTy {
    try std.testing.expectEqualStrings("S", zigTy(.real));
    try std.testing.expectEqualStrings("i64", zigTy(.int));
    try std.testing.expectEqualStrings("[]const u8", zigTy(.str));
}

test zeroOf {
    // The hoisted seed and `renderVal`'s `.undef` operand: one spelling per type.
    try std.testing.expectEqualStrings("S.con(0.0)", zeroOf(.real));
    try std.testing.expectEqualStrings("0", zeroOf(.int));
    try std.testing.expectEqualStrings("\"\"", zeroOf(.str));
}
