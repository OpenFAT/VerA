//! Prover: the state of one `proof.prove` call, as per-Value tables and the
//! guard-fact environment, plus the reads every prover pass shares. In: the
//! MIR, its `Analysis` structure and `Lowered`'s parameter ranges. The
//! passes that write these tables, one file each, run in the order
//! `proof.prove` calls them: `seed.zig`, `guards.zig` (classes, select arms),
//! `walk.zig`, `verdict.zig`; `domain.zig` and `message.zig` serve the walk.
//!
//! LRM clauses this file's code cites: §4.2.12, §4.4.
//!
//! Contents:
//! - `pub const Prover = @This()` (fields: the tables below)
//! - `pub const Fact = struct { v: u32, iv: Interval }`
//! - `pub const GuardRef = struct { start: u32, count: u32 }`
//! - `pub const Saved = struct`
//! - `pub const none: u32`
//! - `pub fn idxOf(p: *const Prover, v: Mir.Value) u32`
//! - `pub fn ivOf(p: *const Prover, v: Mir.Value) Interval`
//! - `pub fn ivAt(p: *const Prover, i: u32) Interval`
//! - `pub fn clsOf(p: *const Prover, i: u32) u32`
//! - `pub fn isFinite(p: *const Prover, v: Mir.Value) bool`
//! - `pub fn operands(p: *const Prover, inst: Mir.Inst, buf: *[3]Mir.Value) []const Mir.Value`
//! - `pub fn literalNumber(p: *const Prover, v: Mir.Value) ?f64`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const diag = @import("diag");
const Analysis = @import("Analysis.zig");
const Interval = @import("Interval.zig");

/// File-as-struct. Every slice lives in `arena`, which dies with
/// `proof.prove`; nothing here outlives the call.
pub const Prover = @This();

/// A guard fact: "this Value is confined to this interval here".
pub const Fact = struct { v: u32, iv: Interval };

/// Where a value's select-arm guard facts live in `facts`; `count == 0`: none.
pub const GuardRef = struct { start: u32 = 0, count: u32 = 0 };

/// What one fact push overwrote: class `cls`'s fact interval and its newest
/// active fact (a `saved` index). `seq` names the row, since a popped row's
/// index is reused by the next push.
pub const Saved = struct { prev: Interval, cls: u32, prev_top: u32, seq: u64 };

/// The "no index" sentinel of every `u32` table here.
pub const none: u32 = std.math.maxInt(u32);

// Row budgets: `Fact` per guard (psp103: 2,732 select-arm facts), `GuardRef`
// per value (psp103: 23,869), `Interval` per value (see its layout note),
// `Saved` per active fact.
comptime {
    assert(@sizeOf(Fact) == 32);
    assert(@sizeOf(GuardRef) == 8);
    assert(@sizeOf(Saved) == 40);
}

/// Backs the verdict, which outlives the call, and the dominator walk's
/// stack (see `walk.zig`).
gpa: Allocator,
/// Scratch arena; dies with `proof.prove`.
arena: Allocator,
/// Borrowed for the call.
mir: *const Mir,
/// Borrowed for the call.
lowered: *const Lowered,
/// The host's unknown bound (`proof.Options.unknown_bound`), NaN-free.
unknown_bound: ?f64,
/// Where every diagnostic goes. Shared with the other stages.
bag: *diag.Bag,
/// The CFG, dominator tree and literal folds. Read-only here.
an: Analysis,

// Per Value, indexed by `@backingInt(Mir.Value)`.

/// The value's own interval: its seed, met with its transfer once `walk`
/// defines it. Guard facts live per class in `civ`; `ivAt` reads both.
iv: []Interval = &.{},
/// The seed alone: what a value reads again once a guard fact that was
/// active at its definition is popped (`ivAt`).
seed: []Interval = &.{},
/// The class's newest active fact (a `saved` index, `none` = none) when the
/// value was defined, and that row's `seq`.
def_pos: []u32 = &.{},
def_seq: []u64 = &.{},
/// "Is a finite IEEE double" (the rules on `proof.FloatMode`), recorded at
/// definition time. `[]bool`, not a bit set: every access is a random probe.
finite: []bool = &.{},
/// Use count, saturating at 255: only "exactly one" scopes a §4.2.12 select
/// guard, so a wider count would buy nothing.
uses: []u8 = &.{},
/// The select-arm guard facts each value is evaluated under.
guard: []GuardRef = &.{},
/// Congruence class per value (`none` = alone). Two structurally identical
/// pure instructions compute the same number, so a guard fact about one
/// holds for all of them: what lets `if (V(p,n) > 0) ... ln(V(p,n))` prove,
/// since lowering emits a fresh `fsub` per `V(p,n)`.
class_of: []u32 = &.{},
/// Classes `guards.buildClasses` found; `civ` rows past them are lone values'.
n_classes: u32 = 0,
/// Select-arm guard facts, in arm order (`GuardRef` slices it).
facts: std.ArrayList(Fact) = .empty,

// The fact environment, indexed by `clsOf` (#29).

/// The meet of the active guard facts on each class: one row per class, then
/// one per value outside every class.
civ: []Interval = &.{},
/// Each class's newest active fact, a `saved` index (`none` = none).
ctop: []u32 = &.{},
/// Undo log for guard application: one row per fact, whatever its class's
/// size, so n nested guards on one class cost O(n).
saved: std.ArrayList(Saved) = .empty,
/// Rows pushed so far: each row's `seq`.
push_seq: u64 = 0,

/// Blocks `walk` has reached.
visited_block: []bool = &.{},
/// §4.2.3 suppresses runtime domain errors on a provably untaken edge.
domain_active: bool = true,
/// §4.3.2 violations reported so far, at most `proof.errors_max`.
error_count: u8 = 0,

/// Returns the alias-resolved index of `v` (the ssa.zig contract): one load
/// through `Analysis`'s snapshot.
pub fn idxOf(p: *const Prover, v: Mir.Value) u32 {
    assert(p.an.alias.len == p.an.nv);
    const r = @backingInt(p.an.rv(v));
    assert(r < p.an.nv);
    return r;
}

/// Returns `v`'s interval here (`ivAt` of its alias target).
pub fn ivOf(p: *const Prover, v: Mir.Value) Interval {
    assert(p.iv.len == p.an.nv); // `seed.seedValues` ran
    return p.ivAt(p.idxOf(v));
}

/// Returns value `i`'s interval here: its own, met with its class's active
/// facts. A value defined under a fact that has since been popped reads its
/// seed again, not its transfer (`def_pos`). The meet order (definition,
/// seed, facts in push order) is the order per-member writes once ran in, so
/// every end, its openness and the sign of a zero end come out as they did.
/// Asserts that the fact environment is built.
pub fn ivAt(p: *const Prover, i: u32) Interval {
    assert(i < p.def_pos.len);
    assert(p.civ.len == p.ctop.len);
    const pos = p.def_pos[i];
    const defined = pos == none or
        (pos < p.saved.items.len and p.saved.items[pos].seq == p.def_seq[i]);
    if (!defined) assert(pos != none); // only a popped fact reverts to the seed
    const own = if (defined) p.iv[i] else p.seed[i];
    return own.meet(p.civ[p.clsOf(i)]);
}

/// Returns the `civ` row of value `i`: its class, or a row of its own.
pub fn clsOf(p: *const Prover, i: u32) u32 {
    assert(i < p.class_of.len);
    const c = p.class_of[i];
    if (c != none) assert(c < p.n_classes);
    const row = if (c != none) c else p.n_classes + i;
    assert(row < p.civ.len);
    return row;
}

/// Returns whether `v` was proven a finite double where it was defined.
pub fn isFinite(p: *const Prover, v: Mir.Value) bool {
    assert(p.finite.len == p.an.nv); // `seed.seedValues` ran
    return p.finite[p.idxOf(v)];
}

/// Returns `inst`'s operands, the fixed ones written into `buf`; a call's
/// arguments are borrowed from the MIR instead. A phi's are (block, value)
/// pairs, read through `Mir.phiPair`, so it answers none.
pub fn operands(p: *const Prover, inst: Mir.Inst, buf: *[3]Mir.Value) []const Mir.Value {
    const ops: []const Mir.Value = switch (p.mir.instData(inst)) {
        .unary => |u| blk: {
            buf[0] = u.operand;
            break :blk buf[0..1];
        },
        .binary => |b| blk: {
            buf.* = .{ b.lhs, b.rhs, .undef };
            break :blk buf[0..2];
        },
        .ternary => |t| blk: {
            buf.* = .{ t.cond, t.then_val, t.else_val };
            break :blk buf[0..3];
        },
        .branch => |b| blk: {
            buf[0] = b.cond;
            break :blk buf[0..1];
        },
        .call => |c| c.args,
        .jump, .phi, .anew => buf[0..0],
        .load => |l| blk: {
            buf.* = .{ l.arr, l.index, .undef };
            break :blk buf[0..2];
        },
        .store => |st| blk: {
            buf.* = .{ st.arr, st.index, st.value };
            break :blk buf[0..3];
        },
    };
    if (p.mir.instOp(inst) == .phi) assert(ops.len == 0);
    if (p.mir.instOp(inst) != .call) assert(ops.len <= buf.len);
    return ops;
}

/// Returns `v` as a number literal: an integer or real constant, or an
/// `if_cast` of an integer constant (a widened `0` in `real_value > 0`).
/// Null for every other definition.
pub fn literalNumber(p: *const Prover, v: Mir.Value) ?f64 {
    const r: ?f64 = switch (p.mir.valueDef(p.an.rv(v))) {
        .int_const => |c| @floatFromInt(c),
        .float_const => |c| c,
        .inst_result => |inst| blk: {
            if (p.mir.instOp(inst) != .if_cast) break :blk null;
            const def = p.mir.valueDef(p.an.rv(p.mir.instData(inst).unary.operand));
            break :blk if (def == .int_const) @as(f64, @floatFromInt(def.int_const)) else null;
        },
        .undef, .str_const, .param_ref, .block_param => null,
    };
    if (p.mir.valueKind(p.an.rv(v)) == .float_const or p.mir.valueKind(p.an.rv(v)) == .int_const) assert(r != null);
    if (p.mir.valueKind(p.an.rv(v)) == .param_ref) assert(r == null); // a card can override it
    return r;
}
