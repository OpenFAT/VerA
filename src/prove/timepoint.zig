//! VerA's `vera_timepoint` (§2.9) check: one cached statement (`TpBlock`)
//! and its module's `Input` in; the first value of the statement, or branch
//! condition inside it, that can move between the Newton iterations of one
//! timepoint (E0531, reported by codegen) out, or null. Optimistic and
//! monotone like `invariance.solve`: every value starts fixed and only falls.
//!   - A probe varies; a constant or parameter does not.
//!   - A call varies unless `callTimepoint` allows it over fixed arguments.
//!   - A pure op, select, load or store varies with an operand; an `anew` is
//!     fixed (zero, the accepted held state, or the cache).
//!   - A phi varies with an incoming value. Outside the statement it varies
//!     also when an incoming edge's predecessor ends in, or is control-
//!     dependent on, a varying branch: `if (V(a) > 0) y = 1; else y = 2;`.
//!     Inside, every branch is checked itself, so data suffices.
//!
//! LRM clauses this file's code cites: §2.9, §9.15.
//!
//! Contents:
//! - `pub const Error = Allocator.Error`
//! - `pub fn varying(in: Input, t: Lowered.TpBlock) Error!?Mir.Value`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const input = @import("input.zig");
const Input = input.Input;
const setup = @import("setup.zig");
const invariance = @import("invariance.zig");
const Fixture = @import("fixture.zig").Fixture;

/// Fails only on allocation, in `in.arena`.
pub const Error = Allocator.Error;

const Call = @FieldType(Mir.InstData, "call");
const none = std.math.maxInt(u32);

/// Returns the first varying branch condition inside `t`, else the first
/// varying value defined inside it, else null. Asserts that `in.an` is a full
/// `Analysis.build` and that `t`'s blocks are in it.
pub fn varying(in: Input, t: Lowered.TpBlock) Error!?Mir.Value {
    const a = in.arena;
    const nb = in.an.nb;
    const nv = in.an.nv;
    const miss: u32 = @backingInt(t.miss);
    const join: u32 = @backingInt(t.join);
    assert(miss < nb);
    assert(join < nb);
    const inside = try a.alloc(bool, nb);
    @memset(inside, false);
    // Each block is pushed at most once (its flag is set first).
    var stack: std.ArrayList(u32) = try .initCapacity(a, nb);
    inside[miss] = true;
    stack.appendAssumeCapacity(miss);
    while (stack.pop()) |b| for (in.an.succsOf(b)) |x| {
        if (x == join or inside[x]) continue;
        inside[x] = true;
        stack.appendAssumeCapacity(x);
    };
    const cds = try setup.controlDeps(in);
    const vary = try a.alloc(bool, nv);
    @memset(vary, false);
    // Bound: `vary` only rises; every round but the last sets one of `nv`.
    var rounds: usize = 0;
    var changed = true;
    while (changed) : (rounds += 1) {
        assert(rounds <= nv);
        changed = false;
        for (Mir.Value.first_dynamic..nv) |i| {
            if (vary[i]) continue;
            const v: Mir.Value = @fromBackingInt(@intCast(i));
            const r = in.an.rv(v);
            const now = if (r != v) varies(in, vary, r) else rule(in, vary, inside, cds, v);
            if (!now) continue;
            vary[i] = true;
            changed = true;
        }
    }
    for (0..nb) |bi| {
        if (!inside[bi]) continue;
        if (setup.branchCond(in, @intCast(bi))) |c| if (varies(in, vary, c)) return c;
    }
    // An alias is the value it names, wherever that is: a pass-through phi
    // the SSA builder placed inside and then folded away reads nothing here.
    for (Mir.Value.first_dynamic..nv) |i| {
        const v: Mir.Value = @fromBackingInt(@intCast(i));
        const b = in.an.def_block[i];
        if (vary[i] and in.an.rv(v) == v and b != none and inside[b]) return v;
    }
    return null;
}

// ---- private ----

/// The calls whose value is the same at every Newton iteration of one
/// timepoint, given their arguments: the solve-invariant ones, the time and
/// analysis the host keys the cache on, the accepted held state, the cache
/// itself, and the pure synthetic reads lowering mints. An allowlist.
fn callTimepoint(in: Input, d: Call) bool {
    if (invariance.callInvariant(in, d)) return true;
    return switch (d.callee) {
        .@"$abstime", .@"$realtime", .analysis, .analog_initial, .initial_step, .final_step => true,
        // §9.15 `dt` moves with the timepoint, never within one; `iteration` does.
        .@"$simparam" => std.mem.eql(u8, input.strArg(in, d.args, 0) orelse return false, "dt"),
        .@"$held_real", .@"$held_int", .@"$held_str", .@"$held_wide", .@"$tp_hit", .@"$tp_int", .@"$tp_real", .@"$tp_wide" => true,
        .@"$idx", .@"$idx$int", .@"$idx$str", .limexp, .@"$str$cat", .@"$str$repeat", .@"$wide", .@"$wide$int" => true,
        else => false, // else: an ALLOWLIST — every other callee may read the iterate or state an iteration moves
    };
}

fn varies(in: Input, vary: []const bool, v0: Mir.Value) bool {
    const v = in.an.rv(v0);
    return switch (in.mir.valueDef(v)) {
        .undef, .float_const, .int_const, .str_const, .param_ref => false,
        .block_param => true,
        .inst_result => vary[@backingInt(v)],
    };
}

fn rule(in: Input, vary: []const bool, inside: []const bool, cds: setup.ControlDeps, v: Mir.Value) bool {
    const def = in.mir.valueDef(v);
    if (def != .inst_result) return varies(in, vary, v);
    const inst = def.inst_result;
    var g = in.mir.guardConds(inst);
    while (g.next()) |c| if (varies(in, vary, c)) return true;
    return switch (in.mir.instData(inst)) {
        .unary => |d| varies(in, vary, d.operand),
        .binary => |d| varies(in, vary, d.lhs) or varies(in, vary, d.rhs),
        .ternary => |d| varies(in, vary, d.cond) or varies(in, vary, d.then_val) or varies(in, vary, d.else_val),
        .call => |d| blk: {
            if (!callTimepoint(in, d)) break :blk true;
            for (d.args) |x| if (varies(in, vary, x)) break :blk true;
            break :blk false;
        },
        .anew, .branch, .jump => false,
        .load => |d| varies(in, vary, d.arr) or varies(in, vary, d.index),
        .store => |d| varies(in, vary, d.arr) or varies(in, vary, d.index) or varies(in, vary, d.value),
        .phi => |d| blk: {
            const blk_v = in.an.def_block[@backingInt(v)];
            const out = blk_v == none or !inside[blk_v];
            for (0..d.count) |k| {
                const pp = in.mir.phiPair(inst, @intCast(k));
                if (varies(in, vary, pp.value)) break :blk true;
                if (!out) continue;
                const pb: u32 = @backingInt(pp.block);
                if (setup.branchCond(in, pb)) |c| if (varies(in, vary, c)) break :blk true;
                for (cds.of(pb)) |cd| {
                    if (varies(in, vary, setup.branchCond(in, cd.branch).?)) break :blk true;
                }
            }
            break :blk false;
        },
    };
}

test "timepoint.varying: a probe inside the statement varies; the time and held state do not" {
    // entry: jump miss; miss: v = <x> * 2; jump join. `x` is a probe, then
    // `$abstime`, then a held read: only the first moves between iterations.
    for ([_]?[]const u8{ null, "$abstime", "$held_real" }) |callee| {
        var f: Fixture = .{ .arena = .init(std.testing.allocator) };
        try f.init(&.{"a"});
        defer f.deinit();
        const a = f.alloc();
        const miss = try f.mir.addBlock(a);
        const join = try f.mir.addBlock(a);
        _ = try f.mir.emitJump(a, .entry, miss);
        const x = if (callee) |c| try f.mir.emitCall(a, miss, try f.mir.internString(a, c), if (c[1] == 'h') &.{.zero} else &.{}) else try f.probe(0);
        const v = try f.mir.emit(a, miss, .fmul, &.{ x, .f_two });
        _ = try f.mir.emitJump(a, miss, join);
        const an = try f.analysis();
        const in: Input = .{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered };
        const got = try varying(in, .{ .tok = 0, .miss = miss, .join = join });
        try std.testing.expectEqual(if (callee == null) @as(?Mir.Value, v) else null, got);
    }
}
