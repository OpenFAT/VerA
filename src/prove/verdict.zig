//! The verdict: the walk's finite bits in, one float mode per contribution
//! unit out, ANDed over the unit's backward slice and the branches that steer
//! its joins, with W0650 naming the value that broke an accepted unit's proof.
//!
//! LRM clauses this file's code cites: §4.3.2, §4.4, §5.6.1.3, §5.8, §9.19.
//!
//! Contents:
//! - `pub const Error = Allocator.Error`
//! - `pub fn rateUnits(p: *Prover, modes: []proof.FloatMode) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const Prover = @import("Prover.zig");
const proof = @import("proof.zig");
const message = @import("message.zig");
const none = Prover.none;

/// Fails only on allocation, in the arena or the diagnostics bag.
pub const Error = Allocator.Error;

/// Writes `modes[u]` for each contribution unit `u` (order:
/// `proof.Verdict.unit_modes`) and emits W0650 for each accepted `.strict`
/// unit. A rejected model rates every unit `.strict` and warns nothing, so
/// the error is not buried. Asserts that `walk` ran and that `modes` has one
/// row per unit.
pub fn rateUnits(p: *Prover, modes: []proof.FloatMode) Error!void {
    assert(p.visited_block.len == p.an.nb);
    assert(modes.len == p.lowered.contributions.items.len);
    // Generation-stamped, not re-cleared: "already on this slice" is
    // `seen[i] == u`. `none` is the pre-first stamp, since `u == 0` is one.
    const seen = try p.arena.alloc(u32, p.an.nv);
    @memset(seen, none);
    var stack: std.ArrayList(Mir.Value) = .empty;

    for (p.lowered.contributions.items, modes, 0..) |c, *mode, u| {
        const gen: u32 = @intCast(u);
        assert(gen != none);
        stack.clearRetainingCapacity();
        try stack.append(p.arena, c.resist_val);
        try stack.append(p.arena, c.react_val);
        // The first value with no finiteness evidence is the one the user has
        // to constrain, and so the one W0650 names.
        const culprit = try firstNotFinite(p, &stack, seen, gen);
        mode.* = if (culprit == null and p.error_count == 0) .optimized else .strict;
        if (culprit != null and p.error_count == 0) try warnNotFinite(p, u, c, culprit.?);
    }
    for (modes) |m| if (p.error_count != 0) assert(m == .strict);
}

// ---- private ----

/// The first value without a finite bit on the slice the stack roots, or
/// null when the whole slice is finite. Each value is visited once per
/// `gen`, so the walk is linear in the slice.
fn firstNotFinite(p: *Prover, stack: *std.ArrayList(Mir.Value), seen: []u32, gen: u32) Error!?Mir.Value {
    assert(seen.len == p.an.nv);
    assert(gen != none);
    while (stack.pop()) |v| {
        const i = p.idxOf(v);
        if (seen[i] == gen) continue;
        seen[i] = gen;
        if (!p.finite[i]) return v;
        const def = p.mir.valueDef(@fromBackingInt(@intCast(i)));
        if (def != .inst_result) continue;
        const inst = def.inst_result;
        const op = p.mir.instOp(inst);
        if (op == .phi) {
            // §5.8 the branches that pick a phi's operand are part of the unit
            // too: under `.optimized` a comparison on inf or NaN is poison,
            // and a branch on poison is undefined.
            const stop = p.an.idom[@backingInt(p.mir.instBlock(inst))];
            const ph = p.mir.instData(inst).phi;
            for (0..ph.count) |k| {
                const pair = p.mir.phiPair(inst, @intCast(k));
                try stack.append(p.arena, pair.value);
                try pushSteering(p, stack, @backingInt(pair.block), stop);
            }
            continue;
        }
        // §9.19 `$param_given` names its parameter; it never reads it.
        if (op == .call and p.mir.instData(inst).call.callee == .@"$param_given") continue;
        var buf: [3]Mir.Value = undefined;
        for (p.operands(inst, &buf)) |o| try stack.append(p.arena, o);
    }
    assert(stack.items.len == 0); // the whole slice was finite
    return null;
}

/// Pushes the condition of every branch on the dominator path from block
/// `from` up to block `stop`, both included: the decisions that choose the
/// edge a join is entered by. Bounded by the block count; an unreachable
/// `from` pushes nothing.
// ponytail: the whole idom path, not only the branches the join is
// control-dependent on, so a branch whose arms meet before the join is still
// counted. Precise is a post-dominance frontier from `Analysis`.
fn pushSteering(p: *Prover, stack: *std.ArrayList(Mir.Value), from: u32, stop: u32) Error!void {
    assert(from < p.an.nb); // a phi pair's block (`verify`'s `handle`)
    assert(stop == none or stop < p.an.nb);
    var b = from;
    for (0..p.an.nb) |_| {
        if (b == none or p.an.rpo_num[b] == none) return;
        const term = p.an.term[b];
        if (term != .none and p.mir.instOp(term) == .branch)
            try stack.append(p.arena, p.mir.instData(term).branch.cond);
        if (b == stop or b == 0) return;
        b = p.an.idom[b];
    }
}

/// W0650: a unit that is not provably finite. The model is legal, but the
/// unit rates `.strict`, and codegen compiles the shared core in the
/// strictest mode of its jobs (`float/mode.zig` `coreMode`), which costs
/// reassociation, fusion and vectorisation. The engine never inserts a clamp
/// or `limexp`, so it names the value that broke the proof instead.
fn warnNotFinite(p: *Prover, unit: usize, c: Lowered.Contribution, culprit: Mir.Value) Error!void {
    if (!p.bag.enabled(.W0650)) return;
    assert(!p.finite[p.idxOf(culprit)]);
    assert(p.error_count == 0); // a rejected model warns nothing
    assert(unit < p.lowered.contributions.items.len);

    const access: []const u8 = if (c.access == .potential) "V" else "I";
    var b = p.bag.build(.proof, .W0650, p.lowered.tokenSpan(c.tok));
    b.msg("unit {d} — {s}({s},{s}) — compiles with @setFloatMode(.strict)", .{
        unit,
        access,
        p.lowered.nodeName(c.hi),
        p.lowered.nodeName(c.lo),
    });

    const who = try message.describe(p, culprit);
    const def = message.valueSpan(p, culprit);
    if (!def.isNone()) {
        b.label(def, "{s} is not provably finite", .{who});
    } else {
        b.point("{s} is not provably finite", .{who});
    }

    // Name the recovery for this culprit only; `--explain` has the full set.
    switch (p.mir.valueDef(p.an.rv(culprit))) {
        .param_ref => b.help("give the parameter a range that excludes infinity, e.g. `from (0:inf)`", .{}),
        .block_param => b.help("a probe has unbounded magnitude; set `proof.Options.unknown_bound` to the solver's compliance limit", .{}),
        .inst_result => |inst| {
            // `walk.callTransfer` models these two from their argument, so
            // their argument is what to constrain.
            const call = p.mir.instOp(inst) == .call;
            const modelled = call and switch (p.mir.instData(inst).call.callee) {
                .limexp, .@"$vt" => true,
                else => false, // else: every other callee's range is `callAbstract`'s, argument-free
            };
            if (call and !modelled) {
                b.help("the prover does not model `{s}()`, so its range is unknown", .{p.mir.instData(inst).call.name});
            } else {
                b.help("constrain the operands with a range or a guard the prover can see", .{});
            }
        },
        .undef, .float_const, .int_const, .str_const => {},
    }
    b.note("`.strict` is correct and spec-legal — this warning is about speed, not correctness", .{});
    try b.emit();
}
