//! The derivative lattice: `Analysis`'s CFG, steer and type tables +
//! `Lowered` in; `dep_words`, `dep_zero` and the four dependency columns
//! (`deps`, `xdeps`, `pdeps`, `acdyn`) out, each a fixpoint over one flat
//! operand graph decoded from the MIR once. The one writer of those tables.
//!
//! Every column starts at no bits and a bit spreads from the probes outwards,
//! so the fixpoint is monotone: it only gains bits and stops after at most
//! (longest chain) sweeps. Value order is definition order except across a
//! back edge, which is why it iterates: a loop-carried phi needs the round
//! after its body.
//!
//! LRM clauses this file's code cites: §2.9, §3.2.2, §4.2.12, §4.4, §4.5,
//! §5.10.
//!
//! Contents:
//! - `pub fn build(an: *Analysis, arena: Allocator, lowered: *const Lowered) Analysis.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const op_kind = @import("ir").op;
const Analysis = @import("Analysis.zig");

const none = Analysis.none;

/// `fixDeps`' input, decoded once so a sweep reads flat rows instead of
/// re-decoding every instruction (decoding per Value per sweep measured
/// 9.4 ms of `build`'s 11.4 on psp103). Per Value: its rule (`kind`) and its
/// alias-resolved operands `ops[off[v]..off[v + 1]]`; the first `n_d[v]`
/// enter the derivative, the rest only steer the value. An alias reads its
/// target as one derivative operand, so it settles to the target's bits.
const DepGraph = struct {
    kind: []Kind,
    n_d: []u32,
    off: []u32,
    ops: []u32,

    /// How a Value combines its operands' bits (see `fixDeps`).
    const Kind = enum(u8) {
        /// The union of its operands: every value but the four below.
        plain,
        /// §4.4 a probe: its unknown's bit, none in `acdyn`.
        probe,
        /// A call that reads per-instance state (`readsInstance`): `pdeps`
        /// sets its bit 0 and ignores the arguments.
        instance_call,
        /// A `$prev`/charge path latch: `pdeps` sets bit 0 as well.
        latch,
        /// A frequency-dependent operator (`op.acDynamic`): `acdyn` takes its
        /// first argument's whole `deps`.
        ac_dynamic,
    };
};

/// Which column `fixDeps` fills.
const Column = enum {
    deriv,
    value,
    ac_dyn,
    point,

    /// The columns that ask whether the value varies, so take what steers it
    /// and not only what enters its derivative.
    fn steered(c: Column) bool {
        return c == .value or c == .point;
    }
};

/// Fills the dependency tables, in `arena`. Asserts that `steer_off`,
/// `def_block` and the CFG tables are filled.
pub fn build(an: *Analysis, arena: Allocator, lowered: *const Lowered) Analysis.Error!void {
    assert(an.steer_off.len == an.nb + 1);
    assert(an.def_block.len == an.nv);
    // One bit per unknown; a probe past `Lowered.nodes` (a hand-built test
    // MIR) still gets its own bit.
    var n_u: usize = lowered.nodes.len;
    for (0..an.nv) |v| {
        const d = an.mir.valueDef(@fromBackingInt(@intCast(v)));
        if (d == .block_param) n_u = @max(n_u, @as(usize, d.block_param) + 1);
    }
    an.dep_words = @intCast(@max(1, @divCeil(n_u, 64)));
    const zero = try arena.alloc(u64, an.dep_words);
    @memset(zero, 0);
    an.dep_zero = zero;
    const g = try buildGraph(an, arena);
    an.deps = try fixDeps(an, arena, g, .deriv);
    an.xdeps = try fixDeps(an, arena, g, .value);
    an.pdeps = an.xdeps;
    for (0..an.mir.instCount()) |i| {
        if (!readsInstance(an, @fromBackingInt(@intCast(i)))) continue;
        an.pdeps = try fixDeps(an, arena, g, .point);
        break;
    }
    // After `deps`, which an operator's `acdyn` reads.
    for (0..an.mir.instCount()) |i| {
        const inst: Mir.Inst = @fromBackingInt(@intCast(i));
        if (an.mir.instOp(inst) != .call) continue;
        if (!op_kind.acDynamic(Mir.callee.opKind(an.mir.instData(inst).call.callee))) continue;
        an.acdyn = try fixDeps(an, arena, g, .ac_dyn);
        break;
    }
    assert(an.deps.len == @as(usize, an.nv) * an.dep_words);
    assert(an.xdeps.len == an.deps.len);
}

// ---- private ----

/// The graph the four columns share: counted, then filled.
fn buildGraph(an: *const Analysis, arena: Allocator) Analysis.Error!DepGraph {
    const nv = an.nv;
    var g: DepGraph = .{
        .kind = try arena.alloc(DepGraph.Kind, nv),
        .n_d = try arena.alloc(u32, nv),
        .off = try arena.alloc(u32, nv + 1),
        .ops = &.{},
    };
    var n: u32 = 0;
    for (0..nv) |v| {
        g.off[v] = n;
        n += depRow(an, @intCast(v), &g, &.{});
    }
    g.off[nv] = n;
    g.ops = try arena.alloc(u32, n);
    for (0..nv) |v| {
        const wrote = depRow(an, @intCast(v), &g, g.ops[g.off[v]..g.off[v + 1]]);
        assert(wrote == g.off[v + 1] - g.off[v]);
    }
    return g;
}

/// Value `v`'s row of `g`: sets `kind[v]` and `n_d[v]`, writes its operands
/// to `out` (empty: count only) and returns how many it wrote or counted.
fn depRow(an: *const Analysis, v: u32, g: *DepGraph, out: []u32) u32 {
    const Row = struct {
        out: []u32,
        alias: []const Mir.Value,
        n: u32 = 0,
        fn put(r: *@This(), x: Mir.Value) void {
            if (r.out.len != 0) r.out[r.n] = @backingInt(r.alias[@backingInt(x)]);
            r.n += 1;
        }
    };
    var r: Row = .{ .out = out, .alias = an.alias };
    g.kind[v] = .plain;
    const val: Mir.Value = @fromBackingInt(v);
    if (an.rv(val) != val) {
        r.put(val);
        g.n_d[v] = r.n;
        return r.n;
    }
    const inst = switch (an.mir.valueDef(val)) {
        .block_param => {
            g.kind[v] = .probe;
            g.n_d[v] = 0;
            return 0;
        },
        .undef, .float_const, .int_const, .str_const, .param_ref => {
            g.n_d[v] = 0;
            return 0;
        },
        .inst_result => |inst| inst,
    };
    // A `dstop` operand steers its value but enters no derivative.
    var steer_first: ?Mir.Value = null;
    switch (an.mir.instData(inst)) {
        .branch, .jump, .anew => {},
        // A call inherits from its arguments and nothing else: all of §4.5
        // propagates its argument's derivative, and a ch9 systf's partials
        // arrive through `SystfHost.call`. Codegen spells a probe in one place
        // only, so a call cannot read one its arguments do not name.
        .call => |c| {
            if (readsInstance(an, inst)) {
                g.kind[v] = .instance_call;
            } else if (op_kind.acDynamic(Mir.callee.opKind(c.callee))) g.kind[v] = .ac_dynamic;
            for (c.args) |x| r.put(x);
        },
        .unary => |u| {
            if (u.op == .path_prev or u.op == .path_acc) g.kind[v] = .latch;
            if (u.op == .dstop) steer_first = u.operand else r.put(u.operand);
        },
        .binary => |b| {
            r.put(b.lhs);
            r.put(b.rhs);
        },
        // §4.2.12: the condition selects between arms rather than entering
        // the derivative; which arm is taken still moves with it: it steers.
        .ternary => |t| {
            r.put(t.then_val);
            r.put(t.else_val);
            steer_first = t.cond;
        },
        // §3.2.2 an array version carries the union of what was stored into
        // it; the index steers, for `select`'s reason.
        .load => |l| {
            r.put(l.arr);
            steer_first = l.index;
        },
        .store => |st| {
            r.put(st.arr);
            r.put(st.value);
            steer_first = st.index;
        },
        .phi => |d| for (0..d.count) |k| r.put(an.mir.phiPair(inst, @intCast(k)).value),
    }
    g.n_d[v] = r.n;
    if (steer_first) |x| r.put(x);
    // A join is a select on the edge that reached it: the edge's branches
    // (`steer_pool`) steer it as a condition does.
    if (an.mir.instOp(inst) == .phi) {
        const b = an.def_block[v];
        if (b != none) for (an.steer_pool[an.steer_off[b]..an.steer_off[b + 1]]) |c| r.put(c);
    }
    // A guarded row (`Mir.guard_of`) is steered by its guard's conditions.
    var it = an.mir.guardConds(inst);
    while (it.next()) |c| r.put(c);
    assert(g.n_d[v] <= r.n);
    return r.n;
}

/// Whether `inst` reads a per-instance value (`pdeps`' seeds).
fn readsInstance(an: *const Analysis, inst: Mir.Inst) bool {
    return switch (an.mir.instData(inst)) {
        .call => |c| switch (c.callee) {
            .@"$held_real", .@"$held_int", .@"$held_str", .@"$held_wide", .@"$mfactor" => true,
            else => false, // else: only the held reads and `$mfactor` read the instance
        },
        .unary => |u| u.op == .path_prev or u.op == .path_acc,
        else => false, // else: only a call or a latch reads the instance as a value
    };
}

/// The fixpoint of column `which` over `g`, swept in value order until
/// nothing changes. Per column, a Value's bits are:
///   deriv  `probe`: its unknown's bit; else its derivative operands'.
///   value  `probe`: its bit; else every operand's.
///   point  as `value`, plus bit 0 for an `instance_call` (over its steering
///          operands only) and a `latch`.
///   ac_dyn `probe`: none; `ac_dynamic`: its first argument's `deps`; else
///          its derivative operands'.
fn fixDeps(an: *const Analysis, arena: Allocator, g: DepGraph, which: Column) Analysis.Error![]u64 {
    // One word, the common case, gets a body with the width known: the
    // generic one costs 1.8x there (psp103 `build`: 9.4 ms against 5.3).
    return if (an.dep_words == 1) fixDepsWide(an, arena, g, which, 1) else fixDepsWide(an, arena, g, which, 0);
}

/// `fixDeps` at `words_ct` words a value, or `dep_words` when it is 0.
fn fixDepsWide(an: *const Analysis, arena: Allocator, g: DepGraph, which: Column, comptime words_ct: u32) Analysis.Error![]u64 {
    const w: usize = if (words_ct != 0) words_ct else an.dep_words;
    assert(w == an.dep_words);
    assert(g.off.len == @as(usize, an.nv) + 1);
    const col = try arena.alloc(u64, @as(usize, an.nv) * w);
    @memset(col, 0);
    const d = (try arena.alloc(u64, w))[0..w];
    const s = (try arena.alloc(u64, w))[0..w];
    // Bound: monotone, and every changing sweep sets at least one of the
    // `nv * 64 * w` bits.
    const sweeps_max = @as(usize, an.nv) * 64 * w + 1;
    var sweeps: usize = 0;
    var changed = true;
    while (changed) : (sweeps += 1) {
        assert(sweeps < sweeps_max);
        changed = false;
        for (0..an.nv) |v| {
            const row = g.ops[g.off[v]..g.off[v + 1]];
            @memset(d, 0);
            @memset(s, 0);
            for (row[0..g.n_d[v]]) |o| orInto(d, col[@as(usize, o) * w ..][0..w]);
            if (which.steered()) for (row[g.n_d[v]..]) |o| orInto(s, col[@as(usize, o) * w ..][0..w]);
            switch (g.kind[v]) {
                .probe => {
                    @memset(d, 0);
                    if (which != .ac_dyn) {
                        const u = an.mir.valueDef(@fromBackingInt(@intCast(v))).block_param;
                        d[u / 64] = @as(u64, 1) << @intCast(u % 64);
                    }
                },
                // Bit 0 marks "reads the instance": `pointDep` asks only
                // whether any bit is set.
                .instance_call => if (which == .point) {
                    @memset(d, 0);
                    d[0] = 1;
                },
                .latch => if (which == .point) {
                    d[0] |= 1;
                },
                .ac_dynamic => if (which == .ac_dyn) {
                    if (g.n_d[v] == 0) @memset(d, 0) else @memcpy(d, an.deps[@as(usize, row[0]) * w ..][0..w]);
                },
                .plain => {},
            }
            orInto(d, s);
            const at = col[v * w ..][0..w];
            if (std.mem.eql(u64, at, d)) continue;
            @memcpy(at, d);
            changed = true;
        }
    }
    return col;
}

fn orInto(acc: []u64, x: []const u64) void {
    for (acc, x) |*a, b| a.* |= b;
}
