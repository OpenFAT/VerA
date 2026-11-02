//! The setup tier: a lowered module and its `Analysis` (`Input`) in;
//! `Invariance` out, the values that are the same at every Newton iterate and
//! time point, so `setup` computes them once per card, instance and
//! temperature, with the blocks that may hold them and the home of each
//! value computed outside its own block. Codegen reads the answer as a value
//! (`Gen.sinv`); the emitter half is `src/codegen/device/codegen/setup.zig`.
//! Also the control dependences the tiers and codegen's planners share. The
//! fixpoint itself is `invariance.zig`'s.
//!
//! LRM clauses this file's code cites: §3.4, §5.10.2.
//!
//! Contents:
//! - `pub const Error = Allocator.Error`
//! - `pub const Invariance = struct`, `Invariance.movedTo(s: Invariance, b: u32) []const Mir.Value`
//! - `pub const ControlDep = struct { branch: u32, edge: Edge }`, `pub const Edge = enum(u8)`
//! - `pub const ControlDeps = struct`, `ControlDeps.of(c: ControlDeps, b: u32) []const ControlDep`
//! - `pub fn plan(in: Input) Error!Invariance`
//! - `pub fn candidate(in: Input, invariant: []const bool, v: Mir.Value) bool`
//! - `pub fn branchCond(in: Input, bi: u32) ?Mir.Value`
//! - `pub fn thenOf(in: Input, bi: u32) u32`, `pub fn elseOf(in: Input, bi: u32) u32`
//! - `pub fn controlDeps(in: Input) Error!ControlDeps`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Input = @import("input.zig").Input;
const invariance = @import("invariance.zig");
const Fixture = @import("fixture.zig").Fixture;

/// Every fallible call here fails only on allocation, in `in.arena`.
pub const Error = Allocator.Error;

/// The solve-invariance answer, per Value, per block and per loop header.
/// Every slice is owned by the `Input.arena` it was planned in.
pub const Invariance = struct {
    /// Value → solve-invariant.
    invariant: []bool = &.{},
    /// Block → placeable: `setup` may compute what it defines.
    placeable: []bool = &.{},
    /// Loop header → a branch inside it is per-eval, so `setup` stops there.
    loop_varying: []bool = &.{},
    /// Value → the placeable block `setup` computes it in, for an invariant
    /// value whose own block is not placeable; `none` for every other value.
    /// `moved`/`moved_off` list the same values per home block, ascending.
    home: []u32 = &.{},
    moved: []Mir.Value = &.{},
    moved_off: []u32 = &.{},

    /// Returns the values `setup` computes at the end of block `b`,
    /// ascending. Asserts that `b` is a block of the analysis planned over.
    pub fn movedTo(s: Invariance, b: u32) []const Mir.Value {
        if (s.moved_off.len == 0) return &.{};
        assert(b + 1 < s.moved_off.len);
        assert(s.moved_off[b] <= s.moved_off[b + 1]);
        return s.moved[s.moved_off[b]..s.moved_off[b + 1]];
    }
};

/// Which edge of a branch a block hangs on.
pub const Edge = enum(u8) { then_edge, else_edge };

/// One control dependence: a block depends on the branch ending block
/// `branch` through its `edge`.
pub const ControlDep = struct {
    branch: u32,
    edge: Edge,
};

// One per (block, controlling branch) pair (psp103: 2596, hisimhv_va: 4824),
// read in block order by `invariance.solve` and the timepoint rule.
comptime {
    assert(@sizeOf(ControlDep) == 8);
}

/// Per-block control dependences, flat: `deps[off[b]..off[b + 1]]`, each
/// block's entries in branch-block order, `then` edge before `else`.
pub const ControlDeps = struct {
    off: []u32,
    deps: []ControlDep,

    /// Returns block `b`'s control dependences. Asserts `b` is in range.
    pub fn of(c: ControlDeps, b: u32) []const ControlDep {
        assert(b + 1 < c.off.len);
        assert(c.off[b] <= c.off[b + 1]);
        return c.deps[c.off[b]..c.off[b + 1]];
    }
};

/// The "no block" sentinel of `Invariance.home`.
const none = std.math.maxInt(u32);

/// Returns the solve-invariance fixpoint and each moved value's home, every
/// slice in `in.arena`. Optimistic and monotone (`invariance.solve`). Asserts
/// that `in.an` is a full `Analysis.build`.
pub fn plan(in: Input) Error!Invariance {
    assert(in.an.ipdom.len == in.an.nb + 1);
    var r = try invariance.solve(in, .placing);
    try invariance.fillHomes(in, &r);
    assert(r.home.len == in.an.nv);
    assert(r.moved_off.len == in.an.nb + 1);
    assert(r.moved.len == r.moved_off[in.an.nb]);
    return r;
}

/// Returns whether `setup` may hand `v` to eval: invariant, computed (not a
/// literal the renderer folds), one value per evaluation (outside every
/// loop), and of a type `Setup` has a field for. A §3.4 parameter a per-eval
/// body reads is one too: copied beside the derived values, so `eval` reads
/// one dense block (bsimcmg: 171 of 1,901 fields, spread over 74 cache lines).
/// Asserts that `invariant` has a row per Value.
pub fn candidate(in: Input, invariant: []const bool, v: Mir.Value) bool {
    assert(invariant.len == in.an.nv);
    assert(in.an.vty.len == in.an.nv); // `Analysis.build` ran
    const i = @backingInt(v);
    if (i < Mir.Value.first_dynamic or !invariant[i]) return false;
    // A string or a wide integer has no `Setup` field type.
    if (in.an.vty[i] == .str or in.an.vty[i] == .wide) return false;
    if (in.mir.valueDef(v) == .param_ref) return true;
    if (in.mir.valueDef(v) != .inst_result) return false;
    const b = in.an.def_block[i];
    if (b == none or in.an.loop_of[b] != none) return false;
    return in.an.foldConst(v, false) == null;
}

/// Returns the condition of the `branch` ending block `bi`, or null when the
/// block ends otherwise.
pub fn branchCond(in: Input, bi: u32) ?Mir.Value {
    assert(bi < in.an.nb);
    const t = in.an.term[bi];
    if (t == .none or in.mir.instOp(t) != .branch) return null;
    const c = in.mir.instData(t).branch.cond;
    assert(@backingInt(c) < in.an.nv);
    return c;
}

/// Returns the `then` target of the branch ending block `bi`. Asserts that
/// block `bi` ends in a branch.
pub fn thenOf(in: Input, bi: u32) u32 {
    assert(in.an.term[bi] != .none);
    assert(in.mir.instOp(in.an.term[bi]) == .branch);
    const r = @backingInt(in.mir.instData(in.an.term[bi]).branch.then_block);
    assert(r < in.an.nb);
    return r;
}

/// Returns the `else` target of the branch ending block `bi`. Asserts that
/// block `bi` ends in a branch.
pub fn elseOf(in: Input, bi: u32) u32 {
    assert(in.an.term[bi] != .none);
    assert(in.mir.instOp(in.an.term[bi]) == .branch);
    const r = @backingInt(in.mir.instData(in.an.term[bi]).branch.else_block);
    assert(r < in.an.nb);
    return r;
}

/// Returns every block's control dependences (the post-dominator frontier,
/// per edge), counted then filled, in `in.arena`. Asserts that `in.an.ipdom`
/// has the virtual exit (`Analysis.build` filled it).
pub fn controlDeps(in: Input) Error!ControlDeps {
    const a = in.arena;
    const nb = in.an.nb;
    const ipdom = in.an.ipdom;
    assert(ipdom.len == nb + 1);
    const off = try a.alloc(u32, nb + 1);
    @memset(off, 0);
    var deps: []ControlDep = &.{};
    var at: []u32 = &.{}; // fill cursor per block
    for ([_]bool{ false, true }) |fill| {
        if (fill) {
            for (1..nb + 1) |b| off[b] += off[b - 1];
            deps = try a.alloc(ControlDep, off[nb]);
            at = try a.dupe(u32, off[0..nb]);
        }
        for (0..nb) |ai| {
            const branch: u32 = @intCast(ai);
            if (branchCond(in, branch) == null) continue;
            for ([_]u32{ thenOf(in, branch), elseOf(in, branch) }, [_]Edge{ .then_edge, .else_edge }) |s, edge| {
                var r = s;
                // Bound: a post-dominator chain holds each block once.
                var hops: usize = 0;
                while (r != ipdom[branch] and r < nb) : (r = ipdom[r]) {
                    assert(hops < nb);
                    hops += 1;
                    if (fill) {
                        deps[at[r]] = .{ .branch = branch, .edge = edge };
                        at[r] += 1;
                    } else off[r + 1] += 1;
                    if (ipdom[r] == none) break;
                }
            }
        }
    }
    for (0..nb) |b| assert(at[b] == off[b + 1]);
    assert(deps.len == off[nb]);
    return .{ .off = off, .deps = deps };
}

// ---- private ----

/// entry: if (V(a) > 0) then else; then, else: join. Blocks 0..3.
fn diamond(f: *Fixture) !struct { then_b: Mir.Block, else_b: Mir.Block, join: Mir.Block, c: Mir.Value } {
    assert(f.mir.blockCount() == 1); // `init`'s entry alone
    const a = f.alloc();
    const then_b = try f.mir.addBlock(a);
    const else_b = try f.mir.addBlock(a);
    const join = try f.mir.addBlock(a);
    const c = try f.mir.emit(a, .entry, .fgt, &.{ try f.probe(0), .f_zero });
    _ = try f.mir.emitBranch(a, .entry, c, then_b, else_b);
    _ = try f.mir.emitJump(a, then_b, join);
    _ = try f.mir.emitJump(a, else_b, join);
    assert(f.mir.blockCount() == 4);
    return .{ .then_b = then_b, .else_b = else_b, .join = join, .c = c };
}

test "a value of parameters and $temperature is solve-invariant; one reading a probe is not" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{"a"});
    defer f.deinit();
    const a = f.alloc();
    try f.lowered.params.append(a, .{ .name = "is", .ty = .real, .default = .f_one });
    const is = try f.mir.addParamRef(a, 0);
    const t = try f.call("$temperature", &.{});
    const et = try f.mir.emit(a, .entry, .exp, &.{t}); // exp($temperature)
    const k = try f.mir.emit(a, .entry, .fmul, &.{ is, et }); // is * exp(T)
    const i = try f.mir.emit(a, .entry, .fmul, &.{ k, try f.probe(0) }); // … * V(a)
    const it = try f.call("$simparam", &.{try f.mir.addStrConst(a, "iteration")});
    const dt = try f.call("$simparam", &.{try f.mir.addStrConst(a, "dt")});
    const an = try f.analysis();
    const in: Input = .{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered };

    const s = try plan(in);
    try std.testing.expect(s.invariant[@backingInt(t)] and s.invariant[@backingInt(et)] and s.invariant[@backingInt(k)]);
    try std.testing.expect(!s.invariant[@backingInt(i)]);
    // §9.15 `iteration` moves with every Newton step.
    try std.testing.expect(!s.invariant[@backingInt(it)]);
    // `dt` moves with every timepoint, so `setup` must not hoist it.
    try std.testing.expect(!s.invariant[@backingInt(dt)]);
    try std.testing.expect(s.placeable[0]);
    try std.testing.expect(candidate(in, s.invariant, k));
    try std.testing.expect(!candidate(in, s.invariant, i));
}

test "a pure op of parameters under a bias-dependent branch is invariant and computed at its placeable dominator; an integer divide is not" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{"a"});
    defer f.deinit();
    const a = f.alloc();
    try f.lowered.params.append(a, .{ .name = "mj", .ty = .real, .default = .f_one });
    try f.lowered.params.append(a, .{ .name = "n", .ty = .integer, .default = .zero });
    const mj = try f.mir.addParamRef(a, 0);
    const n = try f.mir.addParamRef(a, 1);
    // entry: if (V(a) > 0) then else; then/else: join.
    const then_b = try f.mir.addBlock(a);
    const else_b = try f.mir.addBlock(a);
    const join = try f.mir.addBlock(a);
    const c = try f.mir.emit(a, .entry, .fgt, &.{ try f.probe(0), try f.mir.addFloatConst(a, 0.0) });
    _ = try f.mir.emitBranch(a, .entry, c, then_b, else_b);
    const p = try f.mir.emit(a, else_b, .pow, &.{ try f.mir.addFloatConst(a, 0.5), mj }); // pow(0.5, mj)
    const d = try f.mir.emit(a, else_b, .idiv, &.{ n, n }); // n / n
    _ = try f.mir.emitJump(a, then_b, join);
    _ = try f.mir.emitJump(a, else_b, join);
    const an = try f.analysis();
    const in: Input = .{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered };

    const s = try plan(in);
    try std.testing.expect(!s.placeable[@backingInt(else_b)]);
    try std.testing.expect(s.invariant[@backingInt(p)]);
    try std.testing.expectEqual(@as(u32, 0), s.home[@backingInt(p)]);
    try std.testing.expectEqualSlices(Mir.Value, &.{p}, s.movedTo(0));
    try std.testing.expect(candidate(in, s.invariant, p));
    // A parameter leaf is a candidate too: `setup` copies it beside `p`.
    try std.testing.expect(candidate(in, s.invariant, mj));
    // An integer divide by zero traps, so it stays under its guard.
    try std.testing.expect(!s.invariant[@backingInt(d)]);
}

test "Analysis.ipdom and controlDeps of a diamond: each arm hangs on one edge of the branch" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{"a"});
    defer f.deinit();
    _ = try diamond(&f);
    const an = try f.analysis();
    const in: Input = .{ .arena = f.alloc(), .mir = &f.mir, .an = &an, .lowered = &f.lowered };

    // Every block reaches join (3); join reaches the virtual exit (4).
    try std.testing.expectEqualSlices(u32, &.{ 3, 3, 3, 4, 4 }, an.ipdom);
    const cds = try controlDeps(in);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 1, 2, 2 }, cds.off);
    try std.testing.expectEqualSlices(ControlDep, &.{ .{ .branch = 0, .edge = .then_edge }, .{ .branch = 0, .edge = .else_edge } }, cds.deps);
    try std.testing.expectEqualSlices(ControlDep, &.{.{ .branch = 0, .edge = .else_edge }}, cds.of(2));
}

test "solve invariance: the call allowlist, a branch on a probe, and what setup may hand eval" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{"a"});
    defer f.deinit();
    const a = f.alloc();
    try f.lowered.params.append(a, .{ .name = "g", .ty = .real, .default = .f_one });
    const g = try f.mir.addParamRef(a, 0);
    // In entry, before its branch: §9.15 a homotopy knob is fixed within a
    // solve, the time is not.
    const gmin = try f.call("$simparam", &.{try f.mir.addStrConst(a, "gmin")});
    const t = try f.call("$abstime", &.{});
    const root = try f.call("$sqrt", &.{g});
    const lit = try f.mir.emit(a, .entry, .fadd, &.{ .f_one, .f_one }); // folds
    const d = try diamond(&f);
    // A join on a probe-steered branch: its phi moves with the iterate.
    const sel = try f.mir.emitPhi(a, d.join, &.{ .{ .block = d.then_b, .value = g }, .{ .block = d.else_b, .value = .f_zero } });
    const an = try f.analysis();
    const in: Input = .{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered };

    const s = try plan(in);
    try std.testing.expect(s.invariant[@backingInt(gmin)]);
    try std.testing.expect(!s.invariant[@backingInt(t)]);
    try std.testing.expect(s.invariant[@backingInt(root)]);
    // The arms depend on a per-eval branch; the join does not.
    try std.testing.expect(!s.placeable[@backingInt(d.then_b)]);
    try std.testing.expect(!s.placeable[@backingInt(d.else_b)]);
    try std.testing.expect(s.placeable[@backingInt(d.join)]);
    try std.testing.expect(!s.invariant[@backingInt(sel)]);
    // Invariant but a literal the renderer folds: not a setup root.
    try std.testing.expect(s.invariant[@backingInt(lit)]);
    try std.testing.expect(!candidate(in, s.invariant, lit));
    try std.testing.expect(candidate(in, s.invariant, root));
    // Nothing moved into block 0's tail here.
    try std.testing.expectEqual(@as(usize, 0), s.movedTo(0).len);
}
