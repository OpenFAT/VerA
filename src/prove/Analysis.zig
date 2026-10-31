//! Analysis: a lowered module's target-independent facts. `Mir` + `Lowered`
//! in; the CFG (reverse postorder, predecessors and successors, dominator and
//! post-dominator trees, natural loops, flat per-block instruction pools) and
//! the per-Value tables (alias snapshot, emitted type, array owner, derivative
//! dependency masks, constant folds) out. Built once, then read-only. Nothing
//! here knows the target is Zig: per-unit scheduling tables are the emitter's.
//! The builders are this file's spine (`build`); each table has one writer:
//! `cfg.zig`, `postdom.zig`, `value_types.zig`, `deps.zig`, `folds.zig`.
//!
//! LRM clauses this file's code cites: §3.2.2, §3.4, §4.2, §4.4, §4.5.
//! IEEE 1364-2005 clauses cited: §5.4.
//!
//! Contents:
//! - `pub const Analysis = @This()` (fields: the tables below)
//! - `pub const Error = std.mem.Allocator.Error`
//! - `pub const VTy = Mir.callee.Ty`
//! - `pub const none: u32`, `pub const blocks_max: u32`
//! - `pub fn build(arena: Allocator, mir: *const Mir, lowered: *const Lowered) Error!Analysis`
//! - `pub fn buildStructure(arena: Allocator, mir: *const Mir) Error!Analysis`
//! - `pub fn buildLiteralFolds(an: *Analysis, arena: Allocator, lowered: *const Lowered) Error!void`
//! - `pub fn rv(an: *const Analysis, v: Mir.Value) Mir.Value`
//! - `pub fn predsOf(an: *const Analysis, b: u32) []const u32`
//! - `pub fn succsOf(an: *const Analysis, b: u32) []const u32`
//! - `pub fn domKids(an: *const Analysis, b: u32) []const u32`
//! - `pub fn blockInstsFlat(an: *const Analysis, b: u32) []const Mir.Inst`
//! - `pub fn dominates(an: *const Analysis, a: u32, x: u32) bool`
//! - `pub fn inLoop(an: *const Analysis, b: u32) bool`
//! - `pub fn intConst(an: *const Analysis, v: Mir.Value) ?i64`
//! - `pub fn tyOf(an: *const Analysis, v: Mir.Value) VTy`
//! - `pub fn tyOfParam(t: Lowered.Type) VTy`
//! - `pub fn arrOf(an: *const Analysis, v: Mir.Value) ?u32`
//! - `pub fn dFree(an: *const Analysis, v: Mir.Value) bool`
//! - `pub fn xDep(an: *const Analysis, v: Mir.Value) bool`
//! - `pub fn pointDep(an: *const Analysis, v: Mir.Value) bool`
//! - `pub fn foldConst(an: *const Analysis, v: Mir.Value, resolve_params: bool) ?f64`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const cfg = @import("cfg.zig");
const postdom = @import("postdom.zig");
const value_types = @import("value_types.zig");
const deps_build = @import("deps.zig");
const folds_build = @import("folds.zig");

/// File-as-struct: `@import("Analysis.zig")` is both the namespace and the type.
pub const Analysis = @This();

/// Every builder here fails only on allocation; a failed build leaves its
/// tables in the arena, which the caller frees whole.
pub const Error = Allocator.Error;

/// How a Value is emitted: the generic scalar `S` (real), a plain `i64`
/// (§3.2 integer), a string, or an IEEE 1364 §5.4 wide integer.
/// §4.2.1.1/§4.2.1.2 conversions are inserted at the use site, so a typing
/// miss degrades to a redundant cast, never to code that does not compile.
pub const VTy = Mir.callee.Ty;

/// The "no block" / "no row" sentinel of every `u32` column below.
pub const none: u32 = std.math.maxInt(u32);

/// Most blocks one module may hold: `none` and the virtual exit (`ipdom`'s
/// index `nb`) need two indices of their own.
pub const blocks_max: u32 = std.math.maxInt(u32) - 2;

/// Borrowed; must outlive the Analysis and not change after it is built.
mir: *const Mir,

/// Block count.
nb: u32 = 0,
/// Reverse-postorder number per block, `none` if unreachable.
rpo_num: []u32 = &.{},
/// Reachable blocks in reverse postorder; `rpo[0]` is the entry.
rpo: []u32 = &.{},
/// Immediate dominator per block (`idom[0] == 0`), `none` if unreachable.
idom: []u32 = &.{},
/// Reachable predecessors of block `b`, in the reverse postorder of the edge's
/// source: `pred_pool[pred_off[b]..pred_off[b + 1]]` (`predsOf`).
pred_pool: []u32 = &.{},
pred_off: []u32 = &.{},
/// Successors of block `b`, in branch order (then, else), a duplicate kept:
/// `succ_pool[succ_off[b]..succ_off[b + 1]]` (`succsOf`).
succ_pool: []u32 = &.{},
succ_off: []u32 = &.{},
/// Dominator-tree children of block `b`, in RPO order:
/// `kid_pool[kid_off[b]..kid_off[b + 1]]` (`domKids`). Every reachable block
/// but the entry has one parent, so the pool is `rpo.len - 1` words.
kid_pool: []u32 = &.{},
kid_off: []u32 = &.{},
/// Euler-tour numbering of the dominator tree, so `dominates` is O(1)
/// (`none` = block not in the tree).
dom_in: []u32 = &.{},
dom_out: []u32 = &.{},
/// Block has two or more predecessors (never the entry). `[]bool`: every
/// probe is one block at a time and block counts are small.
is_merge: []bool = &.{},
/// Block is a loop header (it dominates one of its predecessors).
is_loop: []bool = &.{},
/// The outermost loop header whose natural loop contains this block, or
/// `none`. Outermost, so a whole nest is one decision for the emitter.
loop_of: []u32 = &.{},
/// Every row of block `b`, in chain (emission) order:
/// `inst_pool[inst_off[b]..inst_off[b + 1]]` (`blockInstsFlat`).
inst_pool: []Mir.Inst = &.{},
inst_off: []u32 = &.{},
/// Non-aliased phis of block `b`, in chain order: `phi_pool[phi_off[b]..]`.
phi_pool: []Mir.Inst = &.{},
phi_off: []u32 = &.{},
/// What a unit body can emit of block `b`: every row but phis, terminators
/// and rows aliased away, in chain order: `stmt_pool[stmt_off[b]..]`.
stmt_pool: []Mir.Inst = &.{},
stmt_off: []u32 = &.{},
/// Merge-block dominator children of `b`, in `domKids` order:
/// `mk_pool[mk_off[b]..mk_off[b + 1]]`.
mk_pool: []u32 = &.{},
mk_off: []u32 = &.{},
/// MIR `op` column, borrowed from `mir`.
i_op: []const Mir.Opcode = &.{},
/// MIR `result` column, borrowed from `mir`.
i_res: []const Mir.Value = &.{},
/// Terminator per block, `.none` if the block has none.
term: []Mir.Inst = &.{},
/// Immediate post-dominator per block, `nb + 1` long: index `nb` is a virtual
/// exit that every block with no successor, and every block that cannot
/// reach one, flows to (`ipdom[nb] == nb`). `build` only.
ipdom: []u32 = &.{},
/// The branch conditions that pick which edge reaches block `b`, so which
/// incoming value its phis take: `steer_pool[steer_off[b]..steer_off[b + 1]]`.
/// A branch steers its immediate post-dominator, and every branch inside a
/// loop nest steers each header of that nest. `build` only.
steer_pool: []Mir.Value = &.{},
steer_off: []u32 = &.{},

/// Value count, sentinels included.
nv: u32 = 0,
/// `mir.resolveAlias` evaluated once for every Value, so `rv` is one load and
/// readers never write through `resolveAlias`'s path compression.
alias: []Mir.Value = &.{},
/// Block a Value is defined in (`none` for constants, parameters, probes).
/// `build` only.
def_block: []u32 = &.{},
/// Emitted type per Value. `build` only.
vty: []VTy = &.{},
/// Per Value, the bits of a `.wide` one; 0 for every other. `build` only.
wide_w: []u32 = &.{},
/// §3.2.2 per Value: the `Lowered.mem_arrays` row an array version belongs to
/// (an `anew`, a `store`, or a phi over them), `none` for every scalar.
arr_of: []u32 = &.{},
/// Words per Value in every dependency column: `max(1, ceil(n_u / 64))`,
/// `n_u` the unknown count (`Lowered.nodes`, or past the highest probe).
dep_words: u32 = 1,
/// Per Value, `dep_words` words (`deps[v * dep_words ..][0..dep_words]`):
/// bit `u` (word `u / 64`, bit `u % 64`) set means `∂value/∂x[u]` may be
/// nonzero. The structural Jacobian, sound in one direction: a set bit is
/// always safe. `xdeps`, `pdeps` and `acdyn` have the same shape.
deps: []u64 = &.{},
/// Which unknowns the value can vary with (`xDep`): `deps`, plus what passes
/// a `dstop`, plus what steers it without entering its derivative.
xdeps: []u64 = &.{},
/// `xdeps` plus the per-instance values (a §5.10 held variable, `$mfactor`,
/// a path latch); the same slice as `xdeps` when the module reads none.
pdeps: []u64 = &.{},
/// The unknowns whose derivative reaches a value through an operator whose
/// small-signal response depends on frequency (`op.acDynamic`); empty when
/// the module calls no such operator.
acdyn: []u64 = &.{},
/// `dep_words` zero words.
dep_zero: []const u64 = &.{},
/// `foldConst`'s answer per Value: `[0]` sees a parameter as the host sets
/// it, `[1]` looks through it to its declared default.
folds: [2]folds_build.FoldColumn = .{ .{}, .{} },

/// Builds every table. Tables live in `arena` and borrow `mir`, which must
/// outlive the result and not change after. Asserts that `mir` has its entry
/// block and every row on at most one chain (`verify`'s `chain`). Writes
/// `mir`'s alias table (path compression) and nothing else.
pub fn build(arena: Allocator, mir: *const Mir, lowered: *const Lowered) Error!Analysis {
    var an = try buildStructure(arena, mir);
    try postdom.build(&an, arena);
    try value_types.build(&an, arena, lowered);
    try deps_build.build(&an, arena, lowered);
    try folds_build.build(&an, arena, lowered);
    assert(an.ipdom.len == an.nb + 1);
    assert(an.vty.len == an.nv);
    return an;
}

/// Builds the structural half alone: the alias snapshot and every CFG table
/// above `ipdom`. The per-Value tables stay empty. For the prover and the
/// verifier, which need no value types: building them twice per compile
/// measured slower. Same preconditions as `build`.
pub fn buildStructure(arena: Allocator, mir: *const Mir) Error!Analysis {
    var an: Analysis = .{ .mir = mir };
    an.nv = @intCast(mir.defs.len + Mir.Value.first_dynamic);
    an.alias = try arena.alloc(Mir.Value, an.nv);
    for (an.alias, 0..) |*p, v| p.* = mir.resolveAlias(@fromBackingInt(@intCast(v)));
    try cfg.build(&an, arena);
    assert(an.alias.len == an.nv);
    assert(an.rpo.len <= an.nb);
    return an;
}

/// Fills `folds[0]` alone after `buildStructure`: literal folds, which never
/// look through an overridable parameter default (§4.2.3, §6.3.4). The prover
/// needs that column and none of `build`'s others.
pub fn buildLiteralFolds(an: *Analysis, arena: Allocator, lowered: *const Lowered) Error!void {
    assert(an.alias.len == an.nv);
    an.folds[0] = try folds_build.column(an, arena, lowered, false);
    assert(an.folds[0].kind.len == an.nv);
}

/// Returns the Value `v` aliases to (the snapshot of `Mir.resolveAlias`).
pub fn rv(an: *const Analysis, v: Mir.Value) Mir.Value {
    return an.alias[@backingInt(v)];
}

/// Returns block `b`'s reachable predecessors. Asserts that `b < nb`.
pub fn predsOf(an: *const Analysis, b: u32) []const u32 {
    assert(b < an.nb);
    return an.pred_pool[an.pred_off[b]..an.pred_off[b + 1]];
}

/// Returns block `b`'s successors in branch order. Asserts that `b < nb`.
pub fn succsOf(an: *const Analysis, b: u32) []const u32 {
    assert(b < an.nb);
    return an.succ_pool[an.succ_off[b]..an.succ_off[b + 1]];
}

/// Returns block `b`'s dominator-tree children, in RPO order.
pub fn domKids(an: *const Analysis, b: u32) []const u32 {
    return an.kid_pool[an.kid_off[b]..an.kid_off[b + 1]];
}

/// Returns block `b`'s rows as a contiguous window (see `inst_pool`).
pub inline fn blockInstsFlat(an: *const Analysis, b: u32) []const Mir.Inst {
    return an.inst_pool[an.inst_off[b]..an.inst_off[b + 1]];
}

/// Returns whether block `a` dominates block `x`, in O(1) through the
/// Euler-tour interval. An unreachable block dominates only itself. Asserts
/// that both are below `nb`.
pub fn dominates(an: *const Analysis, a: u32, x: u32) bool {
    assert(a < an.nb);
    assert(x < an.nb);
    const ia = an.dom_in[a];
    const ix = an.dom_in[x];
    if (ia == none or ix == none) return a == x;
    return ia <= ix and an.dom_out[x] <= an.dom_out[a];
}

/// Returns whether block `b` is inside some loop's natural body.
pub fn inLoop(an: *const Analysis, b: u32) bool {
    return an.loop_of[b] != none;
}

/// Returns the integer literal `v` is through its aliases, or null for any
/// other definition.
pub fn intConst(an: *const Analysis, v: Mir.Value) ?i64 {
    return switch (an.mir.valueDef(an.rv(v))) {
        .int_const => |x| x,
        .undef, .float_const, .str_const, .param_ref, .block_param, .inst_result => null,
    };
}

/// Returns the emitted type of `v`. Asserts that `build` ran.
pub fn tyOf(an: *const Analysis, v: Mir.Value) VTy {
    assert(an.vty.len == an.nv);
    return an.vty[@backingInt(v)];
}

/// Returns the emitted type of a §3.4 parameter declared with type `t`.
pub fn tyOfParam(t: Lowered.Type) VTy {
    return switch (t) {
        .real, .unspecified => .real,
        .integer => .int,
        .string => .str,
    };
}

/// Returns the §3.2.2 array `v` is a version of, or null for a scalar.
/// Asserts that `build` ran.
pub fn arrOf(an: *const Analysis, v: Mir.Value) ?u32 {
    assert(an.arr_of.len == an.nv);
    const a = an.arr_of[@backingInt(an.rv(v))];
    return if (a == none) null else a;
}

/// Returns whether `v` is independent of every §4.4 probe, so its derivative
/// vanishes structurally (no bit of its `deps` row). `false` is always sound.
/// Worth knowing because `@setFloatMode(.strict)` forbids folding a multiply
/// by a literal zero. Asserts that `build` ran; so do `xDep` and `pointDep`.
pub fn dFree(an: *const Analysis, v: Mir.Value) bool {
    return std.mem.allEqual(u64, an.depsIn(an.deps, v), 0);
}

/// Returns whether `v`'s value varies with some §4.4 probe. `!dFree` implies
/// it; it also holds past a `dstop`, and for a select, join or array read
/// steered by a varying condition or index (`xdeps`).
pub fn xDep(an: *const Analysis, v: Mir.Value) bool {
    return !std.mem.allEqual(u64, an.depsIn(an.xdeps, v), 0);
}

/// Returns whether `v` can differ between two points of a batch that share
/// the `Model` row and the `SimState`: `xDep`, or it reads per-instance state
/// (a held variable, `$mfactor`, a path latch; contract.zig `batch_inst`).
pub fn pointDep(an: *const Analysis, v: Mir.Value) bool {
    return !std.mem.allEqual(u64, an.depsIn(an.pdeps, v), 0);
}

/// Returns `v` as a §4.2 constant expression read as a real, or null: for
/// parameter defaults (§6.3.4) and §4.5 operator control arguments.
/// `resolve_params` looks through a parameter to its declared default, which
/// only a Model default may do. O(1). Asserts that the column it reads was
/// built (`build`, or `buildLiteralFolds` for `resolve_params = false`).
pub fn foldConst(an: *const Analysis, v: Mir.Value, resolve_params: bool) ?f64 {
    const col = &an.folds[@intFromBool(resolve_params)];
    assert(col.kind.len == an.nv);
    const c = col.get(v) orelse return null;
    return c.asReal();
}

// ---- private ----

fn depsIn(an: *const Analysis, col: []const u64, v: Mir.Value) []const u64 {
    const w = an.dep_words;
    assert(col.len == @as(usize, an.nv) * w);
    return col[@as(usize, @backingInt(an.rv(v))) * w ..][0..w];
}

fn unknownDeps(an: *const Analysis, v: Mir.Value) []const u64 {
    return an.depsIn(an.deps, v);
}

fn acDynDeps(an: *const Analysis, v: Mir.Value) []const u64 {
    if (an.acdyn.len == 0) return an.dep_zero;
    return an.depsIn(an.acdyn, v);
}

fn wideWidth(an: *const Analysis, v: Mir.Value) u32 {
    return an.wide_w[@backingInt(v)];
}

test "a chain of joins built outer-first types every phi from the integer at its root" {
    // Three nested `if`s, each join's first operand the join inside it,
    // created outer-first as SSA construction does: two sweeps are not enough.
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    const lowered: Lowered = .{};
    var b: [4]Mir.Block = undefined;
    for (&b) |*x| x.* = try mir.addBlock(a);
    for (0..3) |i| _ = try mir.emitJump(a, b[i], b[i + 1]);
    const p3 = try mir.emitPhi(a, b[3], &.{});
    const p2 = try mir.emitPhi(a, b[2], &.{});
    const p1 = try mir.emitPhi(a, b[1], &.{.{ .block = b[0], .value = .one }});
    try mir.setPhiPairs(a, mir.valueDef(p2).inst_result, &.{.{ .block = b[1], .value = p1 }});
    try mir.setPhiPairs(a, mir.valueDef(p3).inst_result, &.{.{ .block = b[2], .value = p2 }});

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const an = try build(arena.allocator(), &mir, &lowered);
    for ([_]Mir.Value{ p1, p2, p3 }) |p| try std.testing.expectEqual(VTy.int, an.tyOf(p));
}

test "ipdom: a loop with no exit flows to the virtual exit" {
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    const lowered: Lowered = .{};
    const entry = try mir.addBlock(a);
    const l = try mir.addBlock(a);
    _ = try mir.emitJump(a, entry, l);
    _ = try mir.emitJump(a, l, l);

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const an = try build(arena.allocator(), &mir, &lowered);
    // No block returns, so both are given an edge to the exit (2).
    try std.testing.expectEqualSlices(u32, &.{ 2, 2, 2 }, an.ipdom);
}

test "a dstop clears the derivative bits and keeps the value varying" {
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    const lowered: Lowered = .{};
    _ = try mir.addBlock(a);
    const va = try mir.addBlockParam(a, 0);
    const vb = try mir.addBlockParam(a, 1);
    const stopped = try mir.emit(a, .entry, .dstop, &.{va});
    const prod = try mir.emit(a, .entry, .fmul, &.{ stopped, vb });

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const an = try build(arena.allocator(), &mir, &lowered);
    try std.testing.expect(an.dFree(stopped) and an.xDep(stopped));
    // The product keeps its other operand's lane, and varies through both.
    try std.testing.expectEqualSlices(u64, &.{0b10}, an.unknownDeps(prod));
    try std.testing.expectEqual(@as(u64, 0b11), an.xdeps[@backingInt(prod)]);
}

test "a ?: steered by a probe varies with no derivative lane; one on a constant does not vary" {
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    const lowered: Lowered = .{};
    _ = try mir.addBlock(a);
    const va = try mir.addBlockParam(a, 0);
    const two = try mir.addFloatConst(a, 2.0);
    const three = try mir.addFloatConst(a, 3.0);
    // `V * (V > 0.4 ? 2.0 : 3.0)`: ∂/∂V is 2 or 3, picked by x.
    const c = try mir.emit(a, .entry, .fgt, &.{ va, try mir.addFloatConst(a, 0.4) });
    const sel = try mir.emit(a, .entry, .select, &.{ c, two, three });
    const g = try mir.emit(a, .entry, .fmul, &.{ va, sel });
    const fixed = try mir.emit(a, .entry, .select, &.{ .one, two, three });

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const an = try build(arena.allocator(), &mir, &lowered);
    // The taken arm's derivative is a constant's: no lane. Its value is 2 or
    // 3 as x moves: it varies.
    try std.testing.expectEqualSlices(u64, &.{0}, an.unknownDeps(sel));
    try std.testing.expect(an.xDep(sel) and an.pointDep(sel));
    try std.testing.expectEqualSlices(u64, &.{0b1}, an.unknownDeps(g));
    try std.testing.expect(an.dFree(fixed) and !an.xDep(fixed));
}

test "a join steered by a probe varies with no derivative lane; one steered by a constant does not vary" {
    // b0: br (V > 0) b1 b2; b1, b2: jump b3; b3: p1 = phi(2, 3); br 1 b4 b5;
    // b4, b5: jump b6; b6: p2 = phi(2, 3).
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    const lowered: Lowered = .{};
    var b: [7]Mir.Block = undefined;
    for (&b) |*x| x.* = try mir.addBlock(a);
    const va = try mir.addBlockParam(a, 0);
    const two = try mir.addFloatConst(a, 2.0);
    const three = try mir.addFloatConst(a, 3.0);
    const c = try mir.emit(a, b[0], .fgt, &.{ va, .f_zero });
    _ = try mir.emitBranch(a, b[0], c, b[1], b[2]);
    _ = try mir.emitJump(a, b[1], b[3]);
    _ = try mir.emitJump(a, b[2], b[3]);
    const p1 = try mir.emitPhi(a, b[3], &.{ .{ .block = b[1], .value = two }, .{ .block = b[2], .value = three } });
    _ = try mir.emitBranch(a, b[3], .one, b[4], b[5]);
    _ = try mir.emitJump(a, b[4], b[6]);
    _ = try mir.emitJump(a, b[5], b[6]);
    const p2 = try mir.emitPhi(a, b[6], &.{ .{ .block = b[4], .value = two }, .{ .block = b[5], .value = three } });

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const an = try build(arena.allocator(), &mir, &lowered);
    try std.testing.expect(an.dFree(p1) and an.xDep(p1));
    try std.testing.expect(an.dFree(p2) and !an.xDep(p2));
}

test "a loop counter whose exit test reads a probe varies with no derivative lane" {
    // b0: jump b1; b1: i = phi(0, i + 1); br (V > i) b2 b3; b2: jump b1.
    // How many times round, so the `i` that leaves, moves with x.
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    const lowered: Lowered = .{};
    var b: [4]Mir.Block = undefined;
    for (&b) |*x| x.* = try mir.addBlock(a);
    const va = try mir.addBlockParam(a, 0);
    _ = try mir.emitJump(a, b[0], b[1]);
    const i = try mir.emitPhi(a, b[1], &.{});
    const c = try mir.emit(a, b[1], .fgt, &.{ va, i });
    _ = try mir.emitBranch(a, b[1], c, b[2], b[3]);
    const next = try mir.emit(a, b[2], .iadd, &.{ i, .one });
    _ = try mir.emitJump(a, b[2], b[1]);
    try mir.setPhiPairs(a, mir.valueDef(i).inst_result, &.{ .{ .block = b[0], .value = .zero }, .{ .block = b[2], .value = next } });

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const an = try build(arena.allocator(), &mir, &lowered);
    try std.testing.expect(an.dFree(i) and an.xDep(i));
}

test "acdyn: an absdelay's input deps reach the value, a direct path does not" {
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    const lowered: Lowered = .{};
    _ = try mir.addBlock(a);
    const va = try mir.addBlockParam(a, 0);
    const vb = try mir.addBlockParam(a, 1);
    const td = try mir.addFloatConst(a, 1e-9);
    const dly = try mir.emitCall(a, .entry, try mir.internString(a, "absdelay"), &.{ va, td });
    const sum = try mir.emit(a, .entry, .fadd, &.{ dly, vb });

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const an = try build(arena.allocator(), &mir, &lowered);
    // x[0] reaches `sum` only through the delay, x[1] only directly.
    try std.testing.expectEqualSlices(u64, &.{0b11}, an.unknownDeps(sum));
    try std.testing.expectEqualSlices(u64, &.{0b01}, an.acDynDeps(sum));
    try std.testing.expectEqualSlices(u64, &.{0}, an.acDynDeps(va));
}

test "analysis: the per-block pools are the chain, filtered" {
    // b0: p = V(a); live = -p; dead = -p (aliased to live); br p b1 b2.
    // b1, b2: jump b3. b3: phi live, phi dead (aliased).
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    const lowered: Lowered = .{};
    const b0 = try mir.addBlock(a);
    const b1 = try mir.addBlock(a);
    const b2 = try mir.addBlock(a);
    const b3 = try mir.addBlock(a);
    const p = try mir.addBlockParam(a, 0);
    const live = try mir.emit(a, b0, .fneg, &.{p});
    const dead = try mir.emit(a, b0, .fneg, &.{p});
    mir.setAlias(dead, live);
    _ = try mir.emitBranch(a, b0, p, b1, b2);
    _ = try mir.emitJump(a, b1, b3);
    _ = try mir.emitJump(a, b2, b3);
    const ph = try mir.emitPhi(a, b3, &.{ .{ .block = b1, .value = live }, .{ .block = b2, .value = p } });
    const ph_dead = try mir.emitPhi(a, b3, &.{ .{ .block = b1, .value = p }, .{ .block = b2, .value = p } });
    mir.setAlias(ph_dead, p);

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const an = try build(arena.allocator(), &mir, &lowered);
    const inst = struct {
        fn of(m: *const Mir, v: Mir.Value) Mir.Inst {
            return m.valueDef(v).inst_result;
        }
    }.of;
    // b0's window is its whole chain; its statements skip the aliased row
    // and the terminator.
    try std.testing.expectEqual(@as(usize, 3), an.blockInstsFlat(0).len);
    try std.testing.expectEqualSlices(Mir.Inst, &.{inst(&mir, live)}, an.stmt_pool[an.stmt_off[0]..an.stmt_off[1]]);
    try std.testing.expectEqualSlices(Mir.Inst, &.{inst(&mir, ph)}, an.phi_pool[an.phi_off[3]..an.phi_off[4]]);
    try std.testing.expectEqual(an.stmt_off[3], an.stmt_off[4]);
    // b3 is b0's only merge-block dominator child; b1 and b2 are not merges.
    try std.testing.expectEqualSlices(u32, &.{3}, an.mk_pool[an.mk_off[0]..an.mk_off[1]]);
    try std.testing.expectEqual(an.mk_off[1], an.mk_off[an.nb]);
    try std.testing.expectEqual(@as(u32, 0), an.def_block[@backingInt(live)]);
    try std.testing.expectEqual(@as(u32, 3), an.def_block[@backingInt(ph)]);
    // b0's successors in branch order; b3's predecessors in the reverse
    // postorder of the edge's source: the DFS finishes b1 (taken first)
    // before b2, so b2 comes first.
    try std.testing.expectEqualSlices(u32, &.{ 2, 1 }, an.predsOf(3));
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, an.succsOf(0));
}

test "wideWidth: a `$wide` root's width reaches a select over it" {
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    var lowered: Lowered = .{};
    defer lowered.wide_nodes.deinit(a);
    try lowered.wide_nodes.append(a, .{ .op = .leaf_int, .width = 40 });
    _ = try mir.addBlock(a);
    const w = try mir.emitCall(a, .entry, try mir.internString(a, "$wide"), &.{.zero});
    const p = try mir.addBlockParam(a, 0);
    const sel = try mir.emit(a, .entry, .select, &.{ p, w, w });
    const r = try mir.emit(a, .entry, .fneg, &.{p});

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const an = try build(arena.allocator(), &mir, &lowered);
    try std.testing.expectEqual(VTy.wide, an.tyOf(w));
    try std.testing.expectEqual(@as(u32, 40), an.wideWidth(w));
    try std.testing.expectEqual(@as(u32, 40), an.wideWidth(sel));
    try std.testing.expectEqual(@as(u32, 0), an.wideWidth(r));
}

test "analysis: dependency masks are exact past 64 unknowns" {
    // 70 unknowns, so two words a value. `far` reads unknown 67 only: word 1
    // bit 3. A delay over it puts the same bit in `acdyn`.
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    var lowered: Lowered = .{};
    defer lowered.nodes.deinit(a);
    for (0..70) |_| try lowered.nodes.append(a, .{ .name = "n", .kind = .net, .disc = "", .dir = .unspecified });
    _ = try mir.addBlock(a);
    const far = try mir.addBlockParam(a, 67);
    const near = try mir.addBlockParam(a, 1);
    const prod = try mir.emit(a, .entry, .fmul, &.{ far, .f_two });
    const sum = try mir.emit(a, .entry, .fadd, &.{ near, prod });
    const k = try mir.emit(a, .entry, .fadd, &.{ .f_one, .f_two });
    const dly = try mir.emitCall(a, .entry, try mir.internString(a, "absdelay"), &.{ far, try mir.addFloatConst(a, 1e-9) });
    const stopped = try mir.emit(a, .entry, .dstop, &.{sum});

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const an = try build(arena.allocator(), &mir, &lowered);
    try std.testing.expectEqual(@as(u32, 2), an.dep_words);
    try std.testing.expectEqualSlices(u64, &.{ 0, 1 << 3 }, an.unknownDeps(prod));
    try std.testing.expectEqualSlices(u64, &.{ 1 << 1, 1 << 3 }, an.unknownDeps(sum));
    try std.testing.expectEqualSlices(u64, &.{ 0, 0 }, an.unknownDeps(k));
    try std.testing.expectEqualSlices(u64, &.{ 0, 1 << 3 }, an.acDynDeps(dly));
    try std.testing.expectEqualSlices(u64, &.{ 0, 0 }, an.acDynDeps(prod));
    try std.testing.expect(!an.dFree(prod) and !an.dFree(sum) and an.dFree(k));
    // A `dstop` keeps the value varying in both words, with no derivative.
    try std.testing.expect(an.dFree(stopped) and an.xDep(stopped) and an.pointDep(stopped));
    try std.testing.expectEqualSlices(u64, &.{ 1 << 1, 1 << 3 }, an.xdeps[@backingInt(stopped) * 2 ..][0..2]);
}

test foldConst {
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    var lowered: Lowered = .{};
    defer lowered.params.deinit(a);
    _ = try mir.addBlock(a);
    const k_default = try mir.addFloatConst(a, 2.5);
    try lowered.params.append(a, .{ .name = "k", .ty = .real, .default = k_default });
    const k = try mir.addParamRef(a, 0);
    const twice = try mir.emit(a, .entry, .fmul, &.{ k, .f_two });
    // §4.2.12 is lazy: `0 > 0 ? 1 % 0 : 10` folds to 10 although `1 % 0`
    // has no value (§4.2.4).
    const c = try mir.emit(a, .entry, .fgt, &.{ .f_zero, .f_zero });
    const bad = try mir.emit(a, .entry, .fmod, &.{ .f_one, .f_zero });
    const sel = try mir.emit(a, .entry, .select, &.{ c, bad, .f_ten });
    const isum = try mir.emit(a, .entry, .iadd, &.{ .one, .one });
    const probe = try mir.addBlockParam(a, 0);
    const varies = try mir.emit(a, .entry, .fadd, &.{ probe, .f_one });

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const an = try build(arena.allocator(), &mir, &lowered);
    // Only a Model default looks through a parameter to its declaration.
    try std.testing.expectEqual(@as(?f64, null), an.foldConst(twice, false));
    try std.testing.expectEqual(@as(f64, 5), an.foldConst(twice, true).?);
    try std.testing.expectEqual(@as(?f64, null), an.foldConst(bad, true));
    try std.testing.expectEqual(@as(f64, 10), an.foldConst(sel, false).?);
    try std.testing.expectEqual(@as(f64, 2), an.foldConst(isum, false).?);
    try std.testing.expectEqual(@as(?f64, null), an.foldConst(varies, true));
    try std.testing.expectEqual(@as(?f64, null), an.foldConst(.undef, true));
}

test "analysis: §3.2.2 array versions, value types and per-instance reads" {
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    var lowered: Lowered = .{};
    defer lowered.mem_arrays.deinit(a);
    defer lowered.params.deinit(a);
    try lowered.mem_arrays.append(a, .{ .name = "m", .len = 4, .ty = .integer });
    try lowered.params.append(a, .{ .name = "n", .ty = .integer, .default = .one });

    const entry = try mir.addBlock(a);
    const next = try mir.addBlock(a);
    const a0 = try mir.emitAnew(a, entry, 0);
    const st = try mir.emit(a, entry, .store, &.{ a0, .zero, .one });
    const ld = try mir.emit(a, entry, .iload, &.{ st, .zero });
    const held = try mir.emitCall(a, entry, try mir.internString(a, "$held_real"), &.{.zero});
    const from_held = try mir.emit(a, entry, .fadd, &.{ held, .f_one });
    const given = try mir.emitCall(a, entry, try mir.internString(a, "$param_given"), &.{});
    const text = try mir.addStrConst(a, "s");
    const n = try mir.addParamRef(a, 0);
    const probe = try mir.addBlockParam(a, 0);
    const isel = try mir.emit(a, entry, .select, &.{ probe, .one, .zero });
    const fsel = try mir.emit(a, entry, .select, &.{ probe, .f_one, .zero });
    _ = try mir.emitJump(a, entry, next);
    const ph = try mir.emitPhi(a, next, &.{.{ .block = entry, .value = st }});
    const phi_inst = mir.valueDef(ph).inst_result;

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const an = try build(arena.allocator(), &mir, &lowered);
    // An `anew`, a `store` from it and a phi over that are one array; a load
    // is a scalar. A version's type is its element type.
    for ([_]Mir.Value{ a0, st, ph }) |v| {
        try std.testing.expectEqual(@as(?u32, 0), an.arrOf(v));
        try std.testing.expectEqual(VTy.int, an.tyOf(v));
    }
    try std.testing.expectEqual(@as(?u32, null), an.arrOf(ld));
    try std.testing.expectEqual(VTy.int, an.tyOf(ld));
    // A call's type is its callee's; a select's is its then arm's.
    try std.testing.expectEqual(VTy.int, an.tyOf(given));
    try std.testing.expectEqual(VTy.real, an.tyOf(held));
    try std.testing.expectEqual(VTy.str, an.tyOf(text));
    try std.testing.expectEqual(VTy.int, an.tyOf(n));
    try std.testing.expectEqual(VTy.int, an.tyOf(isel));
    try std.testing.expectEqual(VTy.real, an.tyOf(fsel));
    // A held read varies per instance but not with x.
    try std.testing.expect(an.pointDep(from_held) and !an.xDep(from_held) and an.dFree(from_held));
    try std.testing.expect(!an.pointDep(given));
    // §4.2.12: the select's condition does not enter its derivative.
    try std.testing.expect(an.dFree(isel));
    // `phiIn` is the pair for the edge, null for an edge with none.
    try std.testing.expectEqual(@as(?Mir.Value, st), an.mir.phiIn(phi_inst, entry));
    try std.testing.expectEqual(@as(?Mir.Value, null), an.mir.phiIn(phi_inst, next));
    try std.testing.expectEqual(@as(u32, @backingInt(entry)), an.def_block[@backingInt(st)]);
    try std.testing.expectEqual(none, an.def_block[@backingInt(probe)]);
}
