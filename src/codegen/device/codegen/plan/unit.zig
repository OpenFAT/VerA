//! Per-unit plan for one emitted declaration: a target `Mir.Value` -> its
//! backward slice over the shared CFG, use counts, inline and dead-branch
//! decisions, and unit-local slots (§4.2.12 lazy arms, §5.9 loops). Clauses:
//! §3.2.2, §4.2.12, §4.3.1, §4.5, §4.5.14, §4.6.3, §5.9, §9.4, §9.5.

const std = @import("std");
const Mir = @import("ir").Mir;
const Analysis = @import("prove").Analysis;
// Shared with the emitter: `Display` is the §9.4 mode, and `callArgIsValue`
// classifies a call's arguments the same way for the plan and for the text.
// They live in `args.zig` so this file imports no emitter.
const cg = @import("args.zig");
const Display = cg.Display;
const assert = std.debug.assert;

pub const UnitPlan = @This();

/// How a CFG edge leaves its block once empty blocks are skipped: `continue`
/// to a loop header or `break` to a merge label (`edgeAct`).
const Act = union(enum) { cont: u32, brk: u32 };
/// Every fallible call here fails only on allocation.
pub const Error = std.mem.Allocator.Error;

const none_u32 = std.math.maxInt(u32);

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

/// The §9.4 mode as the unit being analyzed sees it: a task's operands are a
/// live slice only in the one unit that renders the task.
inline fn dispHere(self: *const UnitPlan) Display {
    return if (self.display_unit) self.display else .drop;
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

/// The block this unit computes `v` in.
fn homeBlock(self: *const UnitPlan, v: usize) u32 {
    assert(v < self.an.nv);
    if (self.setup_mode and self.su_home[v] != none_u32) return self.su_home[v];
    return self.an.def_block[v];
}

/// A branch the unit being planned actually tests: every one, except while
/// planning `setup`, which takes a per-eval branch `then` untested.
inline fn tested(self: *const UnitPlan, cond: Mir.Value) bool {
    return !self.setup_mode or self.sinv[@backingInt(cond)];
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
    self.straight = self.isStraightLine();
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
            self.planDeadBranches();
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
    self.countUses(target);

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
        self.addUses(def.inst_result, true);
    }

    self.fuseSingleUse();
    self.boundInlineDepth();

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
            if (!self.foldedExponent(d)) try self.mark(work, d.rhs);
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

fn countUses(self: *UnitPlan, target: Mir.Value) void {
    if (self.in_common) {
        for (self.lo_vals) |v| self.eager_use[@backingInt(v)] += 1;
    } else {
        self.eager_use[@backingInt(self.an.rv(target))] += 1;
    }
    for (self.live.items) |lv| {
        // A leaf: its operands are not here.
        if (self.cached(lv) or self.isRoot(lv) or self.literal(lv)) continue;
        const def = self.mir.valueDef(lv);
        if (def != .inst_result) continue;
        self.addUses(def.inst_result, false);
    }
    if (self.straight) return;
    for (self.an.rpo) |bi| {
        const t = self.an.term[bi];
        if (t == .none) continue;
        if (self.mir.instOp(t) != .branch) continue;
        // A dead branch emits no `if`, so its condition has no use here. It
        // must not be counted, or the value would be slotted and assigned
        // with nothing reading it, which Zig rejects.
        if (self.dead_branch.isSet(bi)) continue;
        const cond = self.an.rv(self.mir.instData(t).branch.cond);
        if (!self.tested(cond)) continue;
        self.eager_use[@backingInt(cond)] += 1;
    }
}

/// `undo = false` counts, `undo = true` moves this instruction's eager uses
/// into arm uses (called when the instruction itself became lazy).
fn addUses(self: *UnitPlan, inst: Mir.Inst, undo: bool) void {
    const bump = struct {
        fn f(g: *UnitPlan, v: Mir.Value, arm: bool, un: bool) void {
            const i = @backingInt(g.an.rv(v));
            if (!g.needed.isSet(i)) return;
            if (un) {
                if (arm) return; // already an arm use
                if (g.eager_use[i] > 0) g.eager_use[i] -= 1;
                g.arm_use[i] += 1;
            } else if (arm) {
                g.arm_use[i] += 1;
            } else {
                g.eager_use[i] += 1;
            }
        }
    }.f;
    switch (self.mir.instData(inst)) {
        .unary => |d| bump(self, d.operand, false, undo),
        .binary => |d| {
            bump(self, d.lhs, false, undo);
            if (!self.foldedExponent(d)) bump(self, d.rhs, false, undo);
        },
        .ternary => |d| {
            bump(self, d.cond, false, undo);
            bump(self, d.then_val, true, undo);
            bump(self, d.else_val, true, undo);
        },
        .call => |d| for (d.args, 0..) |a, i| {
            if (cg.callArgIsValue(d.callee, i, self.dispHere())) bump(self, a, false, undo);
        },
        .phi => |d| {
            var i: u32 = 0;
            while (i < d.count) : (i += 1) bump(self, self.mir.phiPair(inst, i).value, false, undo);
        },
        .branch, .jump, .anew => {},
        .load => |d| {
            bump(self, d.arr, false, undo);
            bump(self, d.index, false, undo);
        },
        .store => |d| {
            bump(self, d.arr, false, undo);
            bump(self, d.index, false, undo);
            bump(self, d.value, false, undo);
        },
    }
}

/// The deepest chain of inlined operands one statement may render.
const max_inline_depth = 256;
comptime {
    // `inl_depth` is a `u16` that saturates; the cut must sit below that.
    assert(max_inline_depth < std.math.maxInt(u16));
}

/// The renderer recurses once per inlined operand, so a fused chain as long
/// as the source (4096 summed contributions) overflows the compiler's stack.
/// Past `max_inline_depth` a FUSED value keeps its own statement, which is
/// where it stood before `fuseSingleUse` moved it. An arm-inlined value stays
/// inlined: it is lazy on purpose (§4.2.12).
fn boundInlineDepth(self: *UnitPlan) void {
    // Ascending value order is a topological order for everything that
    // inlines (operands are created before their results; a phi never
    // inlines), so every inlined operand's depth is already written.
    for (self.live.items) |lv| {
        const v = @backingInt(lv);
        if (v < Mir.Value.first_dynamic or !self.inlined.isSet(v)) continue;
        const ops: [3]Mir.Value = switch (self.mir.instData(self.mir.valueDef(lv).inst_result)) {
            .unary => |d| .{ d.operand, .undef, .undef },
            .binary => |d| .{ d.lhs, d.rhs, .undef },
            .ternary => |d| .{ d.cond, d.then_val, d.else_val },
            .load => |d| .{ d.arr, d.index, .undef },
            // A storage version renders as its array's name.
            .call, .phi, .branch, .jump, .anew, .store => @splat(.undef),
        };
        var d: u16 = 1;
        for (ops) |o0| {
            const o = @backingInt(self.an.rv(o0));
            // Saturating: an arm-inlined chain may run past a u16, and every
            // depth over `max_inline_depth` already decides the same way.
            if (o >= Mir.Value.first_dynamic and self.inlined.isSet(o)) d = @max(d, self.inl_depth[o] +| 1);
        }
        if (d > max_inline_depth and self.eager_use[v] != 0) {
            self.inlined.unset(v);
            d = 0;
        }
        self.inl_depth[v] = d;
    }
}

/// Fuses a value read exactly once, by a later statement of its own block,
/// into that statement instead of giving it a `const`. Clearing the slot is
/// the fusion: `renderValueRef` falls through to `renderInst` for anything
/// without a slot, so chains collapse transitively.
///
/// Sound because the use is single (`eager_use == 1 and arm_use == 0`; an arm
/// use is re-rendered per arm) and only pure statements lie between, so
/// nothing moves into a loop or past a side effect. Eager uses are not undone:
/// the expression still runs once, eagerly, a little later.
fn fuseSingleUse(self: *UnitPlan) void {
    assert(self.an.stmt_off.len == self.an.nb + 1);
    for (0..self.an.nb) |bi| {
        const stmts = self.an.stmt_pool[self.an.stmt_off[bi]..self.an.stmt_off[bi + 1]];
        if (stmts.len < 2) continue;
        for (stmts[0 .. stmts.len - 1], 0..) |inst, si| {
            const v = @backingInt(self.an.rv(self.an.i_res[@backingInt(inst)]));
            if (v < Mir.Value.first_dynamic) continue;
            if (!self.needed.isSet(v) or self.inlined.isSet(v)) continue;
            if (self.eager_use[v] != 1 or self.arm_use[v] != 0) continue;
            // A live-out is a FIELD of the returned cache (same reason as
            // the sweep above), and a cached value renders as `c.fN`
            // wherever it appears, so neither is ours to fuse.
            if (self.in_common and self.lo_idx[v] != none_u32) continue;
            if (self.cached(@fromBackingInt(@intCast(v)))) continue;
            const op = self.mir.instOp(inst);
            // `call` is an operator/function evaluated once per step (§4.5)
            // and `phi` is materialised as a `var`; neither is an expression.
            if (op == .call or op == .phi) continue;
            // §3.2.2 a load may move later only past what cannot store.
            const is_load = Mir.opClass(op) == .load;
            // The user may sit further down the same block as long as every
            // statement in between is pure: a pure op reads only SSA values,
            // so sliding another past it changes nothing. A `call` or `phi`
            // stops the scan, because §4.5 operators and §9.4 prints are side
            // effects the value must not cross. This lets ifconv's spliced
            // arms sit between a comparison and the select that consumes it.
            for (stmts[si + 1 ..]) |next| {
                if (self.eagerlyUses(next, @fromBackingInt(@intCast(v)))) {
                    self.inlined.set(v);
                    break;
                }
                const nop = self.mir.instOp(next);
                if (nop == .call or nop == .phi) break;
                switch (Mir.opClass(nop)) {
                    .unary, .binary, .ternary, .load => {},
                    // A pure op reads no storage, so it slides past a store;
                    // a load does not.
                    .anew, .store => if (is_load) break,
                    .phi, .branch, .jump, .call => break,
                }
            }
        }
    }
}

/// Does `inst` read `v` in an eager position? Mirrors `addUses`, including
/// its two exclusions (a folded constant exponent is never materialised, and
/// a non-value call argument is not an operand), so the counts it is checked
/// against cannot drift from this answer. A `ternary`'s arms are lazy
/// positions, counted in `arm_use`.
fn eagerlyUses(self: *const UnitPlan, inst: Mir.Inst, v: Mir.Value) bool {
    return switch (self.mir.instData(inst)) {
        .unary => |d| self.an.rv(d.operand) == v,
        .binary => |d| self.an.rv(d.lhs) == v or
            (!self.foldedExponent(d) and self.an.rv(d.rhs) == v),
        .ternary => |d| self.an.rv(d.cond) == v,
        .call => |d| for (d.args, 0..) |a, i| {
            if (cg.callArgIsValue(d.callee, i, self.dispHere()) and self.an.rv(a) == v) break true;
        } else false,
        .phi, .branch, .jump, .anew => false,
        .load => |d| self.an.rv(d.index) == v,
        .store => |d| self.an.rv(d.index) == v or self.an.rv(d.value) == v,
    };
}

/// §4.3.1 `pow(x, k)` with a constant exponent goes through the scalar's
/// `pow(S, f64)`, so the exponent is never materialised as a value.
///
/// `resolve_params = false` mirrors `Gen.renderOp`'s `.pow` arm: a parameter
/// exponent belongs to the model card, so it stays live and renders as
/// `S.con(model.<p>)`. Folding through its declared default would freeze an
/// overridden exponent at that default.
fn foldedExponent(self: *const UnitPlan, d: anytype) bool {
    return d.op == .pow and self.an.foldConst(d.rhs, false) != null;
}

/// Returns true when the slice lives entirely in the entry block and uses no
/// phi, so the unit emits flat `const` code. Valid after `analyze` marked the
/// slice.
fn isStraightLine(self: *const UnitPlan) bool {
    for (self.live.items) |lv| {
        const v = @backingInt(lv);
        if (v < Mir.Value.first_dynamic) continue;
        // A cache or Instance-field read is a field of a value the body
        // already holds, so it has no block of its own.
        if (self.cached(lv) or self.isRoot(lv)) continue;
        const db = self.homeBlock(v);
        if (db != none_u32 and db != 0) return false;
        const def = self.mir.valueDef(lv);
        if (def == .inst_result and self.mir.instOp(def.inst_result) == .phi) return false;
    }
    return true;
}

/// Marks in `dead_branch` every `branch` this unit cannot tell apart.
///
/// A branch is dead here when both edges reduce to the same control action
/// once the empty blocks between are skipped, and neither copies a phi on the
/// way. The unit then computes the same values and reaches the same place
/// whichever arm runs, so the condition is unobservable and the `if` goes.
fn planDeadBranches(self: *UnitPlan) void {
    assert(self.blk_work.bit_length == self.an.nb);
    assert(self.blk_phi.bit_length == self.an.nb);
    assert(self.dead_branch.bit_length == self.an.nb);
    self.blk_work.unsetAll();
    self.blk_phi.unsetAll();
    for (self.live.items) |lv| {
        const v = @backingInt(lv);
        if (v < Mir.Value.first_dynamic) continue;
        const db = self.homeBlock(v);
        if (db == none_u32) continue;
        // A phi marks its block even when cached: `blk_phi` means "the two
        // arms disagree at this SSA join", a property of the CFG and the
        // value, not of whether this unit reads the result from the cache.
        // A setup root's value is the same whichever way the unit goes
        // (`setup` decided every branch it depends on), so neither its phi
        // copies nor its block are work here.
        if (self.isRoot(lv)) continue;
        const def = self.mir.valueDef(lv);
        if (def == .inst_result and self.an.i_op[@backingInt(def.inst_result)] == .phi)
            self.blk_phi.set(db);
        // A cache read has no block of its own.
        if (self.cached(lv)) continue;
        self.blk_work.set(db);
    }
    self.dead_branch.unsetAll();
    // Innermost first (reverse RPO), so an arm whose only content is a branch
    // already found dead reads as the jump it will be emitted as (`edgeAct`).
    var k = self.an.rpo.len;
    while (k > 0) {
        k -= 1;
        const bi = self.an.rpo[k];
        const t = self.an.term[bi];
        if (t == .none or self.mir.instOp(t) != .branch) continue;
        const d = self.mir.instData(t).branch;
        const a = self.edgeAct(bi, @backingInt(d.then_block)) orelse continue;
        const b2 = self.edgeAct(bi, @backingInt(d.else_block)) orelse continue;
        if (std.meta.eql(a, b2)) self.dead_branch.set(bi);
    }
}

/// Returns the control action the edge `from0 -> to0` reduces to once empty
/// inline blocks are skipped, or null when the edge copies a phi, does work
/// this unit observes, or nests deeper than the walk tracks. Reads
/// `blk_work`/`blk_phi`/`dead_branch`, so it is valid only inside
/// `planDeadBranches` or after it.
fn edgeAct(self: *const UnitPlan, from0: u32, to0: u32) ?Act {
    assert(from0 < self.an.nb);
    assert(to0 < self.an.nb);
    var from = from0;
    var to = to0;
    var hops: u32 = 0;
    // Merge blocks whose labels a block walked through here opened: the walk
    // reaching one continues into it, because it is emitted INLINE right
    // after its label closes (`cfg.emitTree`), not broken to from outside.
    // ponytail: a fixed 32; a deeper nest answers null, the safe side.
    var opened: [32]u32 = undefined;
    var n_open: usize = 0;
    while (hops <= self.an.nb) : (hops += 1) {
        // A phi in `to` means `emitPhiCopies` copies a value on this edge, which
        // is the one thing the two arms cannot share.
        if (self.blk_phi.isSet(to)) return null;
        if (self.an.is_loop[to] and self.an.dominates(to, from)) return .{ .cont = to };
        if (self.an.is_merge[to] and std.mem.findScalar(u32, opened[0..n_open], to) == null) return .{ .brk = to };
        // Otherwise `to` is emitted INLINE here, so it has to be empty and
        // end in a plain jump for the two arms to stay indistinguishable.
        //
        // §5.9 and NOT inside a loop, even when empty. "Empty of values
        // this unit computes" is not "no effect" on a back edge: the arms
        // decide which loop-carried phi values get copied on the way round,
        // and `blk_phi` only guards a phi's own block. A loop-carried phi the
        // unit reads from the cache leaves it clear, so the two arms are not
        // interchangeable (the hazard `markRecomputedLoops` handles).
        if (self.an.is_loop[to] or self.an.inLoop(to) or self.blk_work.isSet(to)) return null;
        const labels = self.an.mk_pool[self.an.mk_off[to]..self.an.mk_off[to + 1]];
        if (n_open + labels.len > opened.len) return null;
        @memcpy(opened[n_open..][0..labels.len], labels);
        n_open += labels.len;
        const t = self.an.term[to];
        if (t == .none) return null;
        from = to;
        // A dead branch emits as the edge to its `then` block (`emitTerm`).
        to = switch (self.mir.instOp(t)) {
            .jump => @backingInt(self.mir.instData(t).jump.target),
            .branch => if (self.dead_branch.isSet(to)) @backingInt(self.mir.instData(t).branch.then_block) else return null,
            else => return null, // else: a terminator is a jump or a branch; anything else ends the walk
        };
    }
    return null;
}

const Fixture = @import("prove").Fixture;

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

/// A plan over `f` whose core carries nothing (`lo_idx` all none).
fn emptyCorePlan(f: *Fixture, an: *const Analysis, display: Display) !UnitPlan {
    const a = f.alloc();
    const lo_idx = try a.alloc(u32, an.nv);
    @memset(lo_idx, none_u32);
    var p = try UnitPlan.init(a, &f.mir, an, display);
    p.lo_idx = lo_idx;
    return p;
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
