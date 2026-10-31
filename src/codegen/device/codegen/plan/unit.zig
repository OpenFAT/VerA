//! Per-unit plan for one emitted declaration: a target `Mir.Value` -> its
//! backward slice over the shared CFG, use counts, inline and dead-branch
//! decisions, and unit-local slots (§4.2.12 lazy arms, §5.9 loops). Clauses:
//! §3.2.2, §4.2.12, §4.3.1, §4.5, §4.5.14, §4.6.3, §5.9, §9.4, §9.5.
//!
//! Contents:
//! - `pub const UnitPlan = @This()`
//! - `pub const Error = std.mem.Allocator.Error`
//! - `pub fn init(arena: std.mem.Allocator, mir: *const Mir, an: *const Analysis, display: Display) Error!UnitPlan`
//! - `pub fn literal(self: *const UnitPlan, v: Mir.Value) bool`
//! - `pub inline fn isRoot(self: *const UnitPlan, v: Mir.Value) bool`
//! - `pub inline fn cached(self: *const UnitPlan, v: Mir.Value) bool`
//! - `pub fn analyze(self: *UnitPlan, target: Mir.Value, in_common: bool) Error!void`
//! - `pub fn homeBlock(self: *const UnitPlan, v: usize) u32`
//! - `pub inline fn dispHere(self: *const UnitPlan) Display`
//! - `pub inline fn tested(self: *const UnitPlan, cond: Mir.Value) bool`

const std = @import("std");
const Mir = @import("ir").Mir;
const Analysis = @import("prove").Analysis;

// Shared with the emitter: `Display` is the §9.4 mode, and `callArgIsValue`
// classifies a call's arguments the same way for the plan and for the text.
// They live in `args.zig` so this file imports no emitter.
const cg = @import("args.zig");
const Display = cg.Display;
const assert = std.debug.assert;
const plan_inline = @import("inline.zig");
const Fixture = @import("prove").Fixture;
const plan_branches = @import("branches.zig");

arena: std.mem.Allocator,
mir: *const Mir,
an: *const Analysis,

/// §9.4 artifact mode: decides whether a display task's operand is a value
/// the slice must reach.
display: Display,

/// Is the unit being analyzed the §9.4/§9.5 display unit? Set by the emitter
/// before `analyze`, and read only through `dispHere`.
///
/// The artifact mode alone is not enough: a §9.5 call's value is live in the
/// residual (`I(p,n) <+ V(p,n) + code`) while the descriptor operation itself
/// runs only in the display unit, so its operands are a live slice there and
/// dead everywhere else. Marking them everywhere would emit unread locals,
/// which Zig rejects.
display_unit: bool = false,

/// §9.5 values that carry a file call's result, through any operand or phi.
/// Only the display unit performs the call; every other unit reads the result
/// it last produced (`emitFileCallDropped`), which inside one point is the
/// previous point's. So in the display unit such a value is never a cache
/// read: `fd = $fopen(..)` under `@(initial_step)` then `$ftell(fd)` must see
/// the descriptor the open just returned. Empty under `.drop`.
file_dep: std.DynamicBitSetUnmanaged = .{},

/// Per memory-backed array: its storage carries derivative lanes
/// (`Gen.arr_s`). The core returns an array's PLAIN values
/// (`renderArrayOut`), so the display unit, where a §4.5.14 `ddx` may read
/// an element's lane, recomputes such an array instead of reading the cache.
arr_lanes: []const bool = &.{},

/// The shared core's dedup index, from `plan/core.zig`, stable for the whole
/// compilation. A value with an entry is read out of the core rather than
/// recomputed, unless this unit re-runs the loop that defines it.
lo_idx: []const u32 = &.{},

/// The core's live-out values, in `lo_idx` order.
lo_vals: []const Mir.Value = &.{},

/// The setup roots (codegen/setup.zig `planSetup`): value -> its `Model.su`
/// index, or `none_u32`. A root is a leaf here like a core-cached value:
/// computed outside every body, read as a field, valid in all units
/// including the core.
su_idx: []const u32 = &.{},

/// False while `setup` itself is planned (there the roots are the targets
/// being computed, not leaves) and before `planSetup` wires `su_idx`.
su_on: bool = false,

/// Planning `setup`: only branches on an invariant condition are tested
/// (`sinv`); every other one is taken `then` without reading its condition.
setup_mode: bool = false,

/// Per value: solve-invariant, while planning `setup`.
sinv: []const bool = &.{},

/// While planning `setup`: value -> the block `setup` computes it in when that
/// is not its own (`Sinv.home`).
su_home: []const u32 = &.{},

/// Set by `analyze`: did this unit end up reading the core? Drives the one
/// `const c = <module>__common__core(...)` line the emitter puts at the top.
uses_cache: bool = false,

/// Whether the unit being analyzed is the common declaration itself. Set by
/// `analyze` from its argument.
in_common: bool = false,

/// Per loop header: does this unit run the loop itself, so its values must be
/// recomputed rather than read from the core? Reset and refilled by `analyze`.
loop_recompute: std.DynamicBitSetUnmanaged = .{},

// ---- per-unit scratch ----
// The per-value and per-block flags are bitsets: one bit per row, and a
// clear is `unsetAll` over nv/64 words instead of nv bytes.
/// Per value: in this unit's slice.
needed: std.DynamicBitSetUnmanaged = .{},

/// The values `mark` reached for this unit, sorted ascending. Every per-unit
/// sweep iterates this instead of `0..nv`, since a unit touches a small slice.
live: std.ArrayList(Mir.Value) = .empty,

/// Per value: reads in eager positions.
eager_use: []u32 = &.{},

/// Per value: reads in lazy `select` arm positions (§4.2.12).
arm_use: []u32 = &.{},

/// Per value: rendered inside its user instead of getting a slot.
inlined: std.DynamicBitSetUnmanaged = .{},

/// Per value: the longest chain of inlined operands rendering it recurses
/// through. Written by `boundInlineDepth` for the values it visits.
inl_depth: []u16 = &.{},

/// The slice fits in the entry block with no phi (the common case).
straight: bool = false,

/// Blocks this unit defines something in, and blocks it needs a phi of.
/// Per-block, per-unit; `planDeadBranches` is the only reader.
blk_work: std.DynamicBitSetUnmanaged = .{},
blk_phi: std.DynamicBitSetUnmanaged = .{},

/// A `branch` whose two arms are indistinguishable to this unit: it neither
/// defines anything nor copies a phi on either side before they reconverge.
/// The condition is then never marked live, slotted or emitted.
dead_branch: std.DynamicBitSetUnmanaged = .{},

/// Local slot of a needed value, or `none_u32`. Unit-local, never a MIR
/// index: `ir/names.zig`'s header says why a MIR index in a name renumbers
/// every downstream declaration.
slot: []u32 = &.{},

/// Number of slots `analyze` assigned.
n_slots: u32 = 0,

pub const UnitPlan = @This();

/// Every fallible call here fails only on allocation.
pub const Error = std.mem.Allocator.Error;

const none_u32 = std.math.maxInt(u32);

comptime {
    // `inl_depth` is a `u16` that saturates; the cut must sit below that.
    assert(plan_inline.max_inline_depth < std.math.maxInt(u16));
}

/// Returns a plan with every per-value and per-block table allocated from
/// `arena` (which owns them) but not yet cleared; `analyze` clears them. Under
/// `.emit` it also computes `file_dep` once for the compilation.
pub fn init(
    arena: std.mem.Allocator,
    mir: *const Mir,
    an: *const Analysis,
    display: Display,
) Error!UnitPlan {
    var self: UnitPlan = .{ .arena = arena, .mir = mir, .an = an, .display = display };
    self.loop_recompute = try .initEmpty(arena, an.nb);
    self.needed = try .initEmpty(arena, an.nv);
    self.eager_use = try arena.alloc(u32, an.nv);
    self.arm_use = try arena.alloc(u32, an.nv);
    self.inlined = try .initEmpty(arena, an.nv);
    self.inl_depth = try arena.alloc(u16, an.nv);
    self.slot = try arena.alloc(u32, an.nv);
    // Per-block tables, cleared by `planDeadBranches` before every read.
    self.blk_work = try .initEmpty(arena, an.nb);
    self.blk_phi = try .initEmpty(arena, an.nb);
    self.dead_branch = try .initEmpty(arena, an.nb);
    if (display == .emit) try self.markFileDeps();
    return self;
}

/// Whether `v` renders as its literal: a lane-free real computed by a pure
/// op from literals alone (`foldConst` that looks through no parameter).
/// Such a value is a leaf, read nothing, and has no slot: `render.renderInst`
/// writes `S.con(<literal>)` at each read.
pub fn literal(self: *const UnitPlan, v: Mir.Value) bool {
    const i = @backingInt(v);
    if (i < Mir.Value.first_dynamic or self.an.vty[i] != .real or !self.an.dFree(v)) return false;
    const def = self.mir.valueDef(v);
    if (def != .inst_result) return false;
    switch (Mir.opClass(self.mir.instOp(def.inst_result))) {
        .unary, .binary, .ternary => {},
        .phi, .branch, .jump, .call, .anew, .load, .store => return false,
    }
    return self.an.foldConst(v, false) != null;
}

/// Is this Value a setup root here? Unlike `cached` it is true inside the
/// common declaration too: `setup` writes the field before any solve, so
/// every body may read it.
pub inline fn isRoot(self: *const UnitPlan, v: Mir.Value) bool {
    if (!self.su_on) return false;
    return self.su_idx[@backingInt(v)] != none_u32;
}

/// Is this Value read out of the common declaration's cache HERE? False inside
/// the common declaration itself, where it is computed, and false for a value
/// defined inside a loop this unit re-runs.
pub inline fn cached(self: *const UnitPlan, v: Mir.Value) bool {
    // Builtin literals need no core dependency (`analyze` skips their slots).
    // A held first-call flag can publish `.one`, but another unit still
    // renders that literal directly instead of referencing an absent `c`.
    if (@backingInt(v) < Mir.Value.first_dynamic) return false;
    if (self.in_common or self.lo_idx[@backingInt(v)] == none_u32) return false;
    if (self.display_unit and self.file_dep.bit_length != 0 and self.file_dep.isSet(@backingInt(v))) return false;
    if (self.display_unit and self.arr_lanes.len != 0) {
        const id = self.an.arr_of[@backingInt(v)];
        if (id != none_u32 and self.arr_lanes[id]) return false;
    }
    // §5.9 A unit that re-materializes a loop must not read that loop's values
    // out of the cache (see `analyze`).
    const blk = self.an.def_block[@backingInt(v)];
    if (blk != none_u32) {
        const l = self.an.loop_of[blk];
        if (l != none_u32 and self.loop_recompute.isSet(l)) return false;
    }
    return true;
}

/// Plans the unit that computes `target`, or with `in_common` the core's whole
/// live-out set `lo_vals` (then `target` is ignored). Overwrites every
/// per-unit table, including `slot` and `n_slots`.
///
/// A fixpoint: a §5.9 loop the unit must re-run changes the slice, which can
/// mark further loops. Marking only adds, so it converges.
///
/// Asserts that `lo_idx` is wired (one entry per value, `plan/core.zig`), and
/// `su_idx` too while `su_on`, and `sinv`/`su_home` while `setup_mode`.
pub fn analyze(self: *UnitPlan, target: Mir.Value, in_common: bool) Error!void {
    assert(self.lo_idx.len == self.an.nv);
    if (self.su_on) assert(self.su_idx.len == self.an.nv);
    if (self.setup_mode) assert(self.sinv.len == self.an.nv);
    if (self.setup_mode) assert(self.su_home.len == self.an.nv);
    assert(self.loop_recompute.bit_length == self.an.nb);
    self.in_common = in_common;
    self.loop_recompute.unsetAll();
    // Bound: every round but the last sets at least one of the `nb`
    // `loop_recompute` flags (`markRecomputedLoops`), so at most `nb + 1`.
    var rounds: usize = 0;
    while (true) : (rounds += 1) {
        assert(rounds <= self.an.nb);
        try self.analyzeUnitOnce(target);
        if (!self.markRecomputedLoops()) {
            assert(self.n_slots <= self.live.items.len);
            return;
        }
    }
}

/// The block this unit computes `v` in.
pub fn homeBlock(self: *const UnitPlan, v: usize) u32 {
    assert(v < self.an.nv);
    if (self.setup_mode and self.su_home[v] != none_u32) return self.su_home[v];
    return self.an.def_block[v];
}

/// The §9.4 mode as the unit being analyzed sees it: a task's operands are a
/// live slice only in the one unit that renders the task.
pub inline fn dispHere(self: *const UnitPlan) Display {
    return if (self.display_unit) self.display else .drop;
}

/// A branch the unit being planned actually tests: every one, except while
/// planning `setup`, which takes a per-eval branch `then` untested.
pub inline fn tested(self: *const UnitPlan, cond: Mir.Value) bool {
    return !self.setup_mode or self.sinv[@backingInt(cond)];
}

// ---- private ----

/// Fill `file_dep`. A fixpoint because a loop phi reads a value defined after
/// it; marking only ever adds, so it converges.
fn markFileDeps(self: *UnitPlan) Error!void {
    self.file_dep = try .initEmpty(self.arena, self.an.nv);
    // Bound: every round but the last sets at least one of the `nv` flags,
    // so the loop runs at most `nv + 1` rounds.
    var rounds: usize = 0;
    var grew = true;
    while (grew) : (rounds += 1) {
        assert(rounds <= self.an.nv);
        grew = false;
        for (Mir.Value.first_dynamic..self.an.nv) |i| {
            if (self.file_dep.isSet(i)) continue;
            const def = self.mir.valueDef(@fromBackingInt(@intCast(i)));
            if (def != .inst_result) continue;
            const inst = def.inst_result;
            const hit = switch (self.mir.instData(inst)) {
                .unary => |d| self.fileDep(d.operand),
                .binary => |d| self.fileDep(d.lhs) or self.fileDep(d.rhs),
                .ternary => |d| self.fileDep(d.cond) or self.fileDep(d.then_val) or self.fileDep(d.else_val),
                .call => |d| Mir.callee.isFileCall(d.callee) or for (d.args) |a| {
                    if (self.fileDep(a)) break true;
                } else false,
                .phi => |d| blk: {
                    var k: u32 = 0;
                    while (k < d.count) : (k += 1)
                        if (self.fileDep(self.mir.phiPair(inst, k).value)) break :blk true;
                    break :blk false;
                },
                .branch, .jump, .anew => false,
                .load => |d| self.fileDep(d.arr) or self.fileDep(d.index),
                .store => |d| self.fileDep(d.arr) or self.fileDep(d.index) or self.fileDep(d.value),
            };
            if (hit) {
                self.file_dep.set(i);
                grew = true;
            }
        }
    }
}

inline fn fileDep(self: *const UnitPlan, v: Mir.Value) bool {
    return self.file_dep.isSet(@backingInt(self.an.rv(v)));
}

/// §5.9 Marks the loops this unit must run itself; returns whether any were
/// newly marked.
///
/// The common declaration runs a loop to completion and publishes one
/// snapshot. A unit with a private value inside that loop re-runs it, and
/// reading its counter and exit condition from the cache (their final values)
/// would run the copy zero times. So such a unit uses only local values of the
/// loop, and every other unit keeps reading the core. Not hoisting loop values
/// at all is also sound, but measured 2-5x larger output on models with loops.
fn markRecomputedLoops(self: *UnitPlan) bool {
    if (self.in_common) return false;
    var grew = false;
    for (self.live.items) |lv| {
        const v = @backingInt(lv);
        if (self.cached(lv) or self.isRoot(lv)) continue; // computed elsewhere
        const blk = self.an.def_block[v];
        if (blk == none_u32) continue;
        const l = self.an.loop_of[blk];
        if (l == none_u32 or self.loop_recompute.isSet(l)) continue;
        self.loop_recompute.set(l);
        grew = true;
    }
    return grew;
}

fn analyzeUnitOnce(self: *UnitPlan, target: Mir.Value) Error!void {
    // A full clear: `analyze` runs a handful of times per compilation (setup,
    // the core, the §9.4 display unit), so there is no partial reset to keep
    // in sync with every new table.
    self.needed.unsetAll();
    @memset(self.eager_use, 0);
    @memset(self.arm_use, 0);
    self.inlined.unsetAll();
    @memset(self.slot, none_u32);
    self.live.clearRetainingCapacity();
    self.n_slots = 0;

    var work: std.ArrayList(Mir.Value) = .empty;
    defer work.deinit(self.arena);
    // The common declaration's targets are its whole live-out set and
    // `target` is ignored, so slicing, use counting and CFG reconstruction
    // are shared.
    if (self.in_common) {
        for (self.lo_vals) |v| try self.mark(&work, v);
    } else {
        try self.mark(&work, target);
    }
    try self.closeSlice(&work);
    // Whether the unit needs the CFG is decided from the target's own slice;
    // only then do branch conditions become live (a condition the unit never
    // branches on would be a local nothing reads, a hard error in Zig).
    self.straight = plan_branches.isStraightLine(self);
    if (!self.straight) {
        // Only the branches this unit can observe: most units hold a few
        // private values scattered through a CFG of hundreds of blocks, and
        // rebuilding all of it emits empty `if (c) { break :B } else
        // { break :B }` scaffolding. Marking is monotone (a newly live
        // condition only adds work to a block, which can only revive a
        // branch), so this converges. Bound: every round but the last marks
        // at least one value `needed` that was not, so at most `nv + 1`.
        var rounds: usize = 0;
        while (true) : (rounds += 1) {
            assert(rounds <= self.an.nv);
            plan_branches.planDeadBranches(self);
            var grew = false;
            for (self.an.rpo) |bi| {
                const t = self.an.term[bi];
                if (t == .none) continue;
                if (self.mir.instOp(t) != .branch) continue;
                if (self.dead_branch.isSet(bi)) continue;
                const cond = self.an.rv(self.mir.instData(t).branch.cond);
                if (self.needed.isSet(@backingInt(cond)) or !self.tested(cond)) continue;
                try self.mark(&work, cond);
                grew = true;
            }
            try self.closeSlice(&work);
            if (!grew) break;
        }
    }

    // Ascending value order, so the two sweeps below see exactly the order a
    // full 0..nv scan would. Values are unique ⇒ unstable sort is fine.
    std.mem.sortUnstable(Mir.Value, self.live.items, {}, ltValue);

    // Use counting: a `select` arm (§4.2.12) is a LAZY position.
    plan_inline.countUses(self, target);

    // Descending value order is a topological order for pure ops (a result
    // is always created after its operands), so one sweep suffices.
    var k = self.live.items.len;
    while (k > 0) {
        k -= 1;
        const v = @backingInt(self.live.items[k]);
        if (v < Mir.Value.first_dynamic) break; // sentinels sort first
        if (self.eager_use[v] != 0 or self.arm_use[v] == 0) continue;
        // Read at more than one arm position: a slot, computed once where it
        // is defined, rather than re-rendering its whole slice at every arm.
        // Eager is sound here: proof.markSelectArms guards only a slice owned
        // through use-count-1 links, so a value with two uses (and whatever it
        // alone reads) was proved on every path. And ifconv's `.pure` pass
        // keeps an arm holding a domain-restricted op as a CFG diamond; one
        // its `.speculate` pass moved carries a guard and runs on a safe
        // argument off it (`render.renderSubst`, §4.2.12/§4.3.2).
        // One arm position stays inlined: laziness that costs nothing.
        if (self.arm_use[v] > 1) continue;
        // A live-out is a FIELD of the returned cache, so it has to exist as
        // a value; inlining it into its uses would render its expression at
        // every one of them, including the `return`.
        if (self.in_common and self.lo_idx[v] != none_u32) continue;
        const def = self.mir.valueDef(@as(Mir.Value, @fromBackingInt(@intCast(v))));
        if (def != .inst_result) continue;
        const op = self.mir.instOp(def.inst_result);
        // A `call` is never inlined: §4.5 operators and ch9 functions are
        // evaluated once per step regardless of which arm is taken. Nor is
        // §3.2.2 array storage: a load must run where it stands, before any
        // later store to the same storage (`Mir.Opcode.store`).
        if (op == .call or op == .phi) continue;
        switch (Mir.opClass(op)) {
            .anew, .load, .store => continue,
            .unary, .binary, .ternary, .phi, .branch, .jump, .call => {},
        }
        self.inlined.set(v);
        // Its own operands are read lazily now too.
        plan_inline.addUses(self, def.inst_result, true);
    }

    plan_inline.fuseSingleUse(self);
    plan_inline.boundInlineDepth(self);

    // Slots for everything that survives as a statement, in ascending value
    // order: a unit-local dense index, never a MIR value index.
    self.uses_cache = false;
    for (self.live.items) |lv| {
        const v = @backingInt(lv);
        if (v < Mir.Value.first_dynamic or self.inlined.isSet(v)) continue;
        // An Instance-field read needs no statement, slot or core call; it
        // is valid in every body including the core itself.
        if (self.isRoot(lv)) continue;
        // A cache read is a field access valid anywhere in the body, so it
        // needs no statement and no slot. This is what lets most units come
        // out straight-line.
        if (self.cached(lv)) {
            self.uses_cache = true;
            continue;
        }
        // A literal is written where it is read (`render.renderInst`). After
        // the cache test: a cached literal renders as its cache read
        // (`renderValueRef` asks `cached` first), which needs `c`.
        if (self.literal(lv)) {
            self.inlined.set(v);
            continue;
        }
        // §3.2.2 an array version is its storage, not a value: `anew` and
        // `store` are statements without a slot, and an array phi is the
        // same storage on every edge.
        if (self.an.arrOf(lv) != null) continue;
        const def = self.mir.valueDef(lv);
        if (def != .inst_result) continue;
        // §4.5 an operator's input is not a marked operand (`callArgIsValue`
        // says no, so the §4.5.2 one-evaluation-per-step rule holds), but
        // `emitOperator` still renders it, and outside the core that is a
        // cache read. Without this the §9.4 display unit, the one unit not
        // folded into the core, emits `c.f1` with no `c`.
        const d = self.mir.instData(def.inst_result);
        if (d == .call and @import("ir").op.needsInput(Mir.callee.opKind(d.call.callee)) and d.call.args.len != 0 and
            self.cached(self.an.rv(d.call.args[0]))) self.uses_cache = true;
        // §4.6.3 the same for `ac_stim`'s magnitude and phase (A.8.2
        // `analog_expression`s that `emitCall` renders through `ctrlEval`).
        // `callArgIsValue` says no because the usual constant spelling is
        // consumed at codegen time; a solve-computed one is a core live-out,
        // so outside the core it is a cache read. Argument 0 is the analysis
        // name and is never rendered.
        // §4.5.14 likewise a filter coefficient the solve moves, which
        // `emitOperator` reads live at the static point (`sampledCoefs`).
        if (d == .call and (Mir.callee.opKind(d.call.callee) == .laplace or Mir.callee.opKind(d.call.callee) == .zi)) {
            for (d.call.args[@min(1, d.call.args.len)..]) |a| {
                if (self.cached(self.an.rv(a))) self.uses_cache = true;
            }
        }
        if (d == .call and d.call.callee == .ac_stim) {
            for (d.call.args, 0..) |a, ai| {
                if (ai != 0 and self.cached(self.an.rv(a))) self.uses_cache = true;
            }
        }
        self.slot[v] = self.n_slots;
        self.n_slots += 1;
    }
}

fn mark(self: *UnitPlan, work: *std.ArrayList(Mir.Value), v0: Mir.Value) Error!void {
    const v = self.an.rv(v0);
    assert(@backingInt(v) < self.an.nv);
    if (self.needed.isSet(@backingInt(v))) return;
    self.needed.set(@backingInt(v));
    try self.live.append(self.arena, v);
    // A value read from the core's cache or from a setup root's Instance
    // field is a leaf here: its operands were computed there, and pulling
    // them in is the duplication the hoist removes.
    if (self.cached(v) or self.isRoot(v) or self.literal(v)) return;
    try work.append(self.arena, v);
}

fn markOperands(self: *UnitPlan, work: *std.ArrayList(Mir.Value), inst: Mir.Inst) Error!void {
    switch (self.mir.instData(inst)) {
        .unary => |d| try self.mark(work, d.operand),
        .binary => |d| {
            try self.mark(work, d.lhs);
            if (!plan_inline.foldedExponent(self, d)) try self.mark(work, d.rhs);
        },
        .ternary => |d| {
            try self.mark(work, d.cond);
            try self.mark(work, d.then_val);
            try self.mark(work, d.else_val);
        },
        .call => |d| for (d.args, 0..) |a, i| {
            if (cg.callArgIsValue(d.callee, i, self.dispHere())) try self.mark(work, a);
        },
        .phi => |d| {
            var i: u32 = 0;
            while (i < d.count) : (i += 1) try self.mark(work, self.mir.phiPair(inst, i).value);
        },
        .branch => |d| try self.mark(work, d.cond),
        .jump, .anew => {},
        .load => |d| {
            try self.mark(work, d.arr);
            try self.mark(work, d.index);
        },
        .store => |d| {
            try self.mark(work, d.arr);
            try self.mark(work, d.index);
            try self.mark(work, d.value);
        },
    }
}

fn closeSlice(self: *UnitPlan, work: *std.ArrayList(Mir.Value)) Error!void {
    while (work.pop()) |v| {
        const def = self.mir.valueDef(v);
        if (def != .inst_result) continue;
        try self.markOperands(work, def.inst_result);
    }
    assert(work.items.len == 0);
}

fn ltValue(_: void, lhs: Mir.Value, rhs: Mir.Value) bool {
    return @backingInt(lhs) < @backingInt(rhs);
}

/// A plan over `f` whose core carries nothing (`lo_idx` all none).
fn emptyCorePlan(f: *Fixture, an: *const Analysis, display: Display) !UnitPlan {
    const a = f.alloc();
    const lo_idx = try a.alloc(u32, an.nv);
    @memset(lo_idx, none_u32);
    var p = try UnitPlan.init(a, &f.mir, an, display);
    p.lo_idx = lo_idx;
    return p;
}

test "a unit's slice stops at a value the core carries" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{"a"});
    defer f.deinit();
    const a = f.alloc();
    const va = try f.probe(0);
    const sq = try f.mir.emit(a, .entry, .fmul, &.{ va, va }); // V(a)^2
    const two = try f.mir.addFloatConst(a, 2.0);
    const t = try f.mir.emit(a, .entry, .fadd, &.{ sq, two }); // V(a)^2 + 2
    const an = try f.analysis();

    // `prepare` always wires the core's index; here the core carries nothing.
    const lo_idx = try a.alloc(u32, an.nv);
    @memset(lo_idx, none_u32);
    var p = try UnitPlan.init(a, &f.mir, &an, .drop);
    p.lo_idx = lo_idx;
    try p.analyze(t, false);
    try std.testing.expect(p.straight);
    try std.testing.expect(p.needed.isSet(@backingInt(sq)) and p.needed.isSet(@backingInt(va)));
    try std.testing.expect(!p.uses_cache);

    // Now the core returns `sq`: the unit reads it as a leaf, so `V(a)` is
    // no longer part of its slice.
    lo_idx[@backingInt(sq)] = 0;
    p.lo_vals = &.{sq};
    try p.analyze(t, false);
    try std.testing.expect(p.cached(sq) and p.uses_cache);
    try std.testing.expect(p.needed.isSet(@backingInt(sq)) and !p.needed.isSet(@backingInt(va)));
}

test "§4.2.12 a value read only in one select arm is inlined there; its condition fuses into the select" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{"a"});
    defer f.deinit();
    const a = f.alloc();
    const va = try f.probe(0);
    const c = try f.mir.emit(a, .entry, .fgt, &.{ va, .f_zero });
    const x = try f.mir.emit(a, .entry, .fmul, &.{ va, va });
    const s = try f.mir.emit(a, .entry, .select, &.{ c, x, .f_one });
    const an = try f.analysis();
    var p = try emptyCorePlan(&f, &an, .drop);
    try p.analyze(s, false);
    try std.testing.expect(p.straight);
    try std.testing.expect(p.inlined.isSet(@backingInt(x)) and p.slot[@backingInt(x)] == none_u32);
    try std.testing.expect(p.inlined.isSet(@backingInt(c)));
    // Only the target is a statement.
    try std.testing.expectEqual(@as(u32, 1), p.n_slots);
    try std.testing.expectEqual(@as(u32, 0), p.slot[@backingInt(s)]);
}

test "the core keeps every live-out as a field: none is inlined, each gets a slot" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{"a"});
    defer f.deinit();
    const a = f.alloc();
    const va = try f.probe(0);
    const x = try f.mir.emit(a, .entry, .fmul, &.{ va, va });
    const y = try f.mir.emit(a, .entry, .fadd, &.{ x, .f_one }); // x's one reader
    const an = try f.analysis();
    var p = try emptyCorePlan(&f, &an, .drop);
    const lo_idx = try a.alloc(u32, an.nv);
    @memset(lo_idx, none_u32);
    lo_idx[@backingInt(x)] = 0;
    lo_idx[@backingInt(y)] = 1;
    p.lo_idx = lo_idx;
    p.lo_vals = &.{ x, y };
    try p.analyze(.undef, true);
    // Outside the core x would fuse into y; inside it is a returned field.
    try std.testing.expect(!p.inlined.isSet(@backingInt(x)));
    try std.testing.expect(p.slot[@backingInt(x)] != none_u32 and p.slot[@backingInt(y)] != none_u32);
    // The core computes its values; it reads no cache.
    try std.testing.expect(!p.uses_cache and !p.cached(x));
}

test "§9.4 a display task's operand is live only in the display unit of a printing artifact" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{"a"});
    defer f.deinit();
    const a = f.alloc();
    const va = try f.probe(0);
    const x = try f.mir.emit(a, .entry, .fmul, &.{ va, va });
    const task = try f.call("$strobe", &.{x});
    const an = try f.analysis();
    for ([_]struct { display: Display, unit: bool, live: bool }{
        .{ .display = .emit, .unit = true, .live = true },
        .{ .display = .emit, .unit = false, .live = false },
        .{ .display = .drop, .unit = true, .live = false },
    }) |cs| {
        var p = try emptyCorePlan(&f, &an, cs.display);
        p.display_unit = cs.unit;
        try p.analyze(task, false);
        try std.testing.expectEqual(cs.live, p.needed.isSet(@backingInt(x)));
    }
}

test "a setup root is a leaf: needed, but its operands are not, and it takes no slot" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{"a"});
    defer f.deinit();
    const a = f.alloc();
    try f.lowered.params.append(a, .{ .name = "k", .ty = .real, .default = .f_one });
    const k = try f.mir.addParamRef(a, 0);
    const r = try f.call("$sqrt", &.{k});
    const t = try f.mir.emit(a, .entry, .fmul, &.{ r, try f.probe(0) });
    const an = try f.analysis();
    var p = try emptyCorePlan(&f, &an, .drop);
    const su_idx = try a.alloc(u32, an.nv);
    @memset(su_idx, none_u32);
    su_idx[@backingInt(r)] = 0;
    p.su_idx = su_idx;
    p.su_on = true;
    try p.analyze(t, false);
    try std.testing.expect(p.isRoot(r) and p.needed.isSet(@backingInt(r)));
    try std.testing.expect(!p.needed.isSet(@backingInt(k)));
    try std.testing.expectEqual(none_u32, p.slot[@backingInt(r)]);
}

test "§5.8 a branch whose arms this unit cannot tell apart is dead: no `if`, its condition never live" {
    for ([_]bool{ false, true }) |via_phi| {
        var f: Fixture = .{ .arena = .init(std.testing.allocator) };
        try f.init(&.{"a"});
        defer f.deinit();
        const a = f.alloc();
        const va = try f.probe(0);
        const then_b = try f.mir.addBlock(a);
        const else_b = try f.mir.addBlock(a);
        const join = try f.mir.addBlock(a);
        const c = try f.mir.emit(a, .entry, .fgt, &.{ va, .f_zero });
        _ = try f.mir.emitBranch(a, .entry, c, then_b, else_b);
        _ = try f.mir.emitJump(a, then_b, join);
        _ = try f.mir.emitJump(a, else_b, join);
        // Either a value the join computes whichever arm ran, or a phi that
        // tells the arms apart.
        const t = if (via_phi)
            try f.mir.emitPhi(a, join, &.{ .{ .block = then_b, .value = va }, .{ .block = else_b, .value = .f_zero } })
        else
            try f.mir.emit(a, join, .fadd, &.{ va, .f_one });
        const an = try f.analysis();
        var p = try emptyCorePlan(&f, &an, .drop);
        try p.analyze(t, false);
        try std.testing.expect(!p.straight);
        try std.testing.expectEqual(!via_phi, p.dead_branch.isSet(0));
        try std.testing.expectEqual(via_phi, p.needed.isSet(@backingInt(c)));
    }
}

test "a select-arm chain longer than a u16 plans without overflowing its inline depth" {
    // s_k = select(c, s_{k-1}, 1): each s is read once, in an arm, so each is
    // inlined (lazy on purpose, §4.2.12) and its depth is one more than the
    // last. 70000 links pass 65535, the largest depth a u16 holds.
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{"a"});
    defer f.deinit();
    const a = f.alloc();
    const va = try f.probe(0);
    const c = try f.mir.emit(a, .entry, .fgt, &.{ va, .f_zero });
    var s = va;
    for (0..70000) |_| s = try f.mir.emit(a, .entry, .select, &.{ c, s, .f_one });
    const an = try f.analysis();
    var p = try emptyCorePlan(&f, &an, .drop);
    try p.analyze(s, false);
    // Two statements: the condition every select reads, and the target.
    try std.testing.expect(!p.inlined.isSet(@backingInt(s)) and !p.inlined.isSet(@backingInt(c)));
    try std.testing.expectEqual(@as(u32, 2), p.n_slots);
}
