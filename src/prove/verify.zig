//! MIR verifier: a `Mir` and the `Lowered` it indexes in, the first broken
//! invariant out, with the block and row it was found at. The postcondition of
//! lowering and of each MIR pass: src/Compilation.zig runs `check` after lowering,
//! `pruneHeld` and if-conversion when the module has runtime safety (Debug,
//! ReleaseSafe). The proof and codegen take `*const Mir`, so nothing later
//! can break one. The invariants are VerA's own, not an LRM rule.
//!
//! It checks only what a consumer relies on (`Invariant`). Left out because
//! the code does not maintain them: operand types (a real reaching an integer
//! op is converted at the use, `Analysis.VTy`); a terminator on every block
//! (an exit block, and an arm if-conversion emptied, have none); where a phi
//! row sits (ssa.zig mints phis on demand, anywhere in the chain), nor what
//! follows a terminator (`lower_var.hiddenHeldInt` seeds into a closed entry
//! block; codegen emits a block's rows before its terminator); a call's
//! argument count against `callee.arity` (the source arity: `$clog2` carries
//! a width too); and every use in an unreachable block, an orphaned row, or a
//! row whose result is aliased away, none of which codegen emits.
//!
//! LRM clauses this file's code cites: §4.5.14.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const Analysis = @import("analysis.zig");

const none = std.math.maxInt(u32);
const fd = Mir.Value.first_dynamic;

/// One rule `verify` checks.
pub const Invariant = enum {
    /// A block's `next` chain runs from `first` to `last`, each row on it
    /// names that block in its `block` column, and no row is on two chains.
    chain,
    /// A terminator defines no Value. Every other linked row defines a dynamic
    /// Value whose `defs` row points back at it, and every `inst_result`
    /// Value's row defines that Value.
    result,
    /// Every handle names something that exists: Values below the `defs`
    /// count, Blocks below the block count, phi and call payloads inside
    /// `extra`, interned strings, `Callee` tags, and alias chains that end.
    handle,
    /// At most one branch or jump per block (`Analysis.term` keeps one), and
    /// no edge into the entry block (`Analysis.is_merge` relies on that).
    terminator,
    /// A call's `Callee` is what its name resolves to (`Callee.fromName`).
    callee,
    /// Every operand, through `Mir.resolveAlias`, is defined by a linked row
    /// that dominates the use: an earlier row of the same block (a phi heads
    /// its block wherever it sits) or a dominating block. A phi operand is
    /// read at the end of its predecessor.
    dominance,
    /// A live phi in a reachable block has a pair for each reachable
    /// predecessor, and each pair names a block with an edge to it.
    phi_edges,
    /// A probe and a `ddx` lane name a solver unknown (`Lowered.nodes`): the
    /// derivative lanes codegen gives every value come from these alone.
    unknown,
    /// Rows of the `Lowered` tables the MIR indexes exist: a `param_ref`'s
    /// parameter, an `anew`'s array and timepoint slot. `held_vars` row i's
    /// seed is the `$held_*` call reading row i, or the `anew` of the array
    /// whose `held` is i (what `pruneHeld` renumbers).
    table,
    /// A load's or store's array operand is an array version: an `anew`, a
    /// `store` or a phi (`Analysis.arrOf(..).?` relies on it).
    array,
};

/// The first broken invariant `verify` found, and where.
const Violation = struct {
    invariant: Invariant,
    /// The block it was found in, or null for a table-wide rule.
    block: ?Mir.Block = null,
    /// The row it was found at, or `.none`.
    inst: Mir.Inst = .none,
    /// What is wrong, as a fixed phrase.
    what: []const u8,
};

/// Runs `verify` and panics on a violation, naming `pass`, the stage whose
/// output `mir` is. Does nothing without runtime safety (ReleaseFast,
/// ReleaseSmall), so those builds pay nothing. Fails only on allocation.
pub fn check(mir: *const Mir, lowered: *const Lowered, pass: []const u8) Allocator.Error!void {
    // This module's own optimize mode (0.17: `std.debug.runtime_safety` is
    // deprecated and reports the standard library's).
    if (!builtin.mode.runtimeSafety()) return;
    const v = try verify(mir, lowered) orelse return;
    const op: []const u8 = if (v.inst != .none and @backingInt(v.inst) < mir.insts.len) @tagName(mir.instOp(v.inst)) else "-";
    std.debug.panic("MIR verifier: after {s}, `{s}` broken in module `{s}`: {s} (block {?d}, inst {d} `{s}`)", .{
        pass,
        @tagName(v.invariant),
        mir.name,
        v.what,
        if (v.block) |b| @backingInt(b) else null,
        @backingInt(v.inst),
        op,
    });
}

/// Returns the first broken invariant, or null. Its scratch is freed before
/// it returns; it writes nothing to `mir` but the alias table's path
/// compression (`Mir.resolveAlias`). The structural rules run first, so the
/// CFG the dominance rules build is known to be well formed. Fails only on
/// allocation.
pub fn verify(mir: *const Mir, lowered: *const Lowered) Allocator.Error!?Violation {
    if (mir.blockCount() == 0) return null;
    // Scratch outside the caller's allocator, as ssa.zig's `map_gpa`: an
    // arena grows by in-place resizes whose success depends on the address
    // space, so on the compile's gpa it would make tests/unit.zig's
    // allocation count vary from run to run.
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Each row's position in its block's chain; `none` for an orphan.
    const pos = try a.alloc(u32, mir.insts.len);
    @memset(pos, none);
    if (chains(mir, pos)) |v| return v;
    if (rows(mir, lowered)) |v| return v;
    if (try values(a, mir, lowered)) |v| return v;
    // Every handle is in range and every alias chain ends: the CFG and
    // dominator tree can be built.
    const an = try Analysis.buildStructure(a, mir, lowered);
    if (uses(mir, lowered, &an, pos)) |v| return v;
    return held(mir, lowered, &an);
}

fn bad(invariant: Invariant, block: ?Mir.Block, inst: Mir.Inst, what: []const u8) Violation {
    return .{ .invariant = invariant, .block = block, .inst = inst, .what = what };
}

fn valueCount(mir: *const Mir) usize {
    return mir.defs.len + fd;
}

fn blockOf(bi: usize) Mir.Block {
    return @fromBackingInt(@intCast(bi));
}

fn chains(mir: *const Mir, pos: []u32) ?Violation {
    const next = mir.insts.items(.next);
    const home = mir.insts.items(.block);
    for (mir.blocks.items(.first), mir.blocks.items(.last), 0..) |head, tail, bi| {
        const b = blockOf(bi);
        var prev: Mir.Inst = .none;
        var cur = head;
        var k: u32 = 0;
        while (cur != .none) : (cur = next[@backingInt(cur)]) {
            const i = @backingInt(cur);
            if (i >= pos.len) return bad(.chain, b, prev, "`next` names no row");
            if (pos[i] != none) return bad(.chain, b, cur, "a row is linked twice, or the chain cycles");
            if (home[i] != b) return bad(.chain, b, cur, "the row's `block` column names another block");
            pos[i] = k;
            k += 1;
            prev = cur;
        }
        if (prev != tail) return bad(.chain, b, tail, "`last` is not the end of the chain");
    }
    return null;
}

/// Per linked row: its result, its handles, its place after the terminator.
fn rows(mir: *const Mir, lowered: *const Lowered) ?Violation {
    const nv = valueCount(mir);
    const nb = mir.blockCount();
    const extra = mir.extra.items;
    const n_callees = std.meta.tags(Mir.Callee).len;
    for (0..nb) |bi| {
        const b = blockOf(bi);
        var term: Mir.Inst = .none;
        var it = mir.blockInsts(b);
        while (it.next()) |inst| {
            const row = mir.instRow(inst);
            const class = Mir.opClass(row.op);
            switch (class) {
                .branch, .jump => if (row.result != .undef) return bad(.result, b, inst, "a terminator defines a Value"),
                .unary, .binary, .ternary, .phi, .call, .anew, .load, .store => {
                    const r = @backingInt(row.result);
                    if (r < fd or r >= nv) return bad(.result, b, inst, "the result is not a dynamic Value");
                    if (mir.valueKind(row.result) != .inst_result or mir.defs.items(.payload)[r - fd] != @backingInt(inst))
                        return bad(.result, b, inst, "the result's `defs` row does not point back at the row");
                },
            }
            switch (class) {
                .unary => if (row.a >= nv) return bad(.handle, b, inst, "an operand names no Value"),
                .binary, .load => if (row.a >= nv or row.b >= nv) return bad(.handle, b, inst, "an operand names no Value"),
                .ternary, .store => {
                    if (@as(u64, row.b) + 2 > extra.len) return bad(.handle, b, inst, "the operands run past `extra`");
                    if (row.a >= nv or extra[row.b] >= nv or extra[row.b + 1] >= nv) return bad(.handle, b, inst, "an operand names no Value");
                },
                .anew => {
                    if (row.a >= lowered.mem_arrays.items.len) return bad(.table, b, inst, "`anew` names no `mem_arrays` row");
                    if (row.b != 0) {
                        if (@as(u64, row.b) + 1 > extra.len) return bad(.handle, b, inst, "the `anew` slot runs past `extra`");
                        const tp = extra[row.b - 1];
                        const tps = lowered.timepoints.items;
                        if (tp >= tps.len or extra[row.b] >= tps[tp].slots.len)
                            return bad(.table, b, inst, "`anew` names no `timepoints` slot");
                    }
                },
                .phi => {
                    if (@as(u64, row.b) + 2 * @as(u64, row.a) > extra.len) return bad(.handle, b, inst, "the phi's pairs run past `extra`");
                    for (0..row.a) |k| {
                        const p = mir.phiPair(inst, @intCast(k));
                        if (@backingInt(p.block) >= nb) return bad(.handle, b, inst, "a phi pair names no block");
                        if (@backingInt(p.value) >= nv) return bad(.handle, b, inst, "a phi pair names no Value");
                    }
                },
                .branch => {
                    if (row.a >= nv) return bad(.handle, b, inst, "the condition names no Value");
                    if (@as(u64, row.b) + 2 > extra.len) return bad(.handle, b, inst, "the branch targets run past `extra`");
                    const then_b = extra[row.b];
                    const else_b = extra[row.b + 1];
                    if (then_b >= nb or else_b >= nb) return bad(.handle, b, inst, "a branch target names no block");
                    if (then_b == 0 or else_b == 0) return bad(.terminator, b, inst, "an edge into the entry block");
                },
                .jump => {
                    if (row.a >= nb) return bad(.handle, b, inst, "the jump target names no block");
                    if (row.a == 0) return bad(.terminator, b, inst, "an edge into the entry block");
                },
                .call => {
                    const n_args = row.a >> Mir.callee_bits;
                    if (@as(u8, @truncate(row.a)) >= n_callees) return bad(.handle, b, inst, "not a `Callee` tag");
                    if (@as(u64, row.b) + 1 + n_args > extra.len) return bad(.handle, b, inst, "the call's payload runs past `extra`");
                    if (extra[row.b] >= mir.strings.strings.items.len) return bad(.handle, b, inst, "the call's name is not an interned string");
                    for (extra[row.b + 1 ..][0..n_args]) |arg| if (arg >= nv) return bad(.handle, b, inst, "an argument names no Value");
                    const d = mir.instData(inst).call;
                    if (Mir.Callee.fromName(d.name) != d.callee) return bad(.callee, b, inst, "the `Callee` is not the one the call's name resolves to");
                },
            }
            switch (class) {
                .branch, .jump => {
                    if (term != .none) return bad(.terminator, b, inst, "a second terminator");
                    term = inst;
                },
                .unary, .binary, .ternary, .phi, .call, .anew, .load, .store => {},
            }
        }
    }
    return null;
}

/// Per dynamic Value: its payload names a row, and its alias chain ends.
fn values(a: Allocator, mir: *const Mir, lowered: *const Lowered) Allocator.Error!?Violation {
    const nv = valueCount(mir);
    const results = mir.insts.items(.result);
    const alias = mir.alias.items;
    if (alias.len != mir.defs.len) return bad(.handle, null, .none, "the alias table is not parallel to `defs`");
    for (mir.defs.items(.kind), mir.defs.items(.payload), alias, 0..) |kind, payload, to, i| {
        const v: Mir.Value = @fromBackingInt(@intCast(i + fd));
        switch (kind) {
            .undef, .float_const, .int_const => {},
            .str_const => if (payload >= mir.strings.strings.items.len) return bad(.handle, null, .none, "a string constant names no interned string"),
            .param_ref => if (payload >= lowered.params.items.len) return bad(.table, null, .none, "a `param_ref` names no `params` row"),
            .block_param => if (payload >= lowered.nodes.len) return bad(.unknown, null, .none, "a probe names no solver unknown"),
            .inst_result => if (payload >= results.len or results[@intCast(payload)] != v)
                return bad(.result, null, .none, "a Value's defining row does not define it"),
        }
        if (@backingInt(to) >= nv) return bad(.handle, null, .none, "an alias names no Value");
    }
    // An alias chain must end at a sentinel or a self-parent; a cycle would
    // spin `resolveAlias`. Linear: 1 marks the walk in progress, 2 a row an
    // earlier walk already saw end.
    const mark = try a.alloc(u8, alias.len);
    @memset(mark, 0);
    for (0..alias.len) |s| {
        var j = s;
        while (mark[j] == 0) {
            mark[j] = 1;
            const t = @backingInt(alias[j]);
            if (t < fd or t - fd == j) break;
            j = t - fd;
        } else if (mark[j] == 1) return bad(.handle, null, .none, "an alias chain cycles");
        j = s;
        while (mark[j] == 1) {
            mark[j] = 2;
            const t = @backingInt(alias[j]);
            if (t < fd or t - fd == j) break;
            j = t - fd;
        }
    }
    return null;
}

/// Dominance, phi edges, array operands and `ddx` lanes, per linked row.
fn uses(mir: *const Mir, lowered: *const Lowered, an: *const Analysis, pos: []const u32) ?Violation {
    for (0..mir.blockCount()) |i| {
        const b = blockOf(i);
        const bi: u32 = @intCast(i);
        // Codegen emits neither an unreachable block nor a row aliased away.
        const reachable = an.rpo_num[bi] != none;
        var it = mir.blockInsts(b);
        while (it.next()) |inst| {
            const r = mir.instResult(inst);
            const live = reachable and an.rv(r) == r;
            const at = pos[@backingInt(inst)];
            switch (mir.instData(inst)) {
                .phi => |d| if (live) {
                    for (0..d.count) |k| {
                        const p = mir.phiPair(inst, @intCast(k));
                        const pb = @backingInt(p.block);
                        if (std.mem.findScalar(u32, an.succs[pb], bi) == null)
                            return bad(.phi_edges, b, inst, "a pair names a block with no edge to the phi's");
                        if (an.rpo_num[pb] == none) continue; // never taken
                        if (available(mir, an, pos, p.value, pb, none)) |why| return bad(.dominance, b, inst, why);
                    }
                    for (an.preds[bi]) |pb| {
                        for (0..d.count) |k| {
                            if (@backingInt(mir.phiPair(inst, @intCast(k)).block) == pb) break;
                        } else return bad(.phi_edges, b, inst, "a reachable predecessor has no pair");
                    }
                },
                .unary => |u| if (live) {
                    if (available(mir, an, pos, u.operand, bi, at)) |why| return bad(.dominance, b, inst, why);
                },
                .binary => |o| if (live) for ([_]Mir.Value{ o.lhs, o.rhs }) |v| {
                    if (available(mir, an, pos, v, bi, at)) |why| return bad(.dominance, b, inst, why);
                },
                .ternary => |t| if (live) for ([_]Mir.Value{ t.cond, t.then_val, t.else_val }) |v| {
                    if (available(mir, an, pos, v, bi, at)) |why| return bad(.dominance, b, inst, why);
                },
                .branch => |br| if (live) {
                    if (available(mir, an, pos, br.cond, bi, at)) |why| return bad(.dominance, b, inst, why);
                },
                .jump, .anew => {},
                .call => |c| {
                    if (live) for (c.args) |v| {
                        if (available(mir, an, pos, v, bi, at)) |why| return bad(.dominance, b, inst, why);
                    };
                    // §4.5.14 ddx(f, k): codegen reads lane k of f's derivative.
                    if (c.callee == .ddx) {
                        const k = if (c.args.len == 2) an.intConst(c.args[1]) else null;
                        if (k == null or k.? < 0 or k.? >= lowered.nodes.len) return bad(.unknown, b, inst, "a `ddx` lane names no solver unknown");
                    }
                },
                .load => |l| {
                    if (!version(mir, an, l.arr)) return bad(.array, b, inst, "a load's array operand is not an array version");
                    if (live) for ([_]Mir.Value{ l.arr, l.index }) |v| {
                        if (available(mir, an, pos, v, bi, at)) |why| return bad(.dominance, b, inst, why);
                    };
                },
                .store => |s| {
                    if (!version(mir, an, s.arr)) return bad(.array, b, inst, "a store's array operand is not an array version");
                    if (live) for ([_]Mir.Value{ s.arr, s.index, s.value }) |v| {
                        if (available(mir, an, pos, v, bi, at)) |why| return bad(.dominance, b, inst, why);
                    };
                },
            }
        }
    }
    return null;
}

/// Null when `v` is available at row position `at` of block `b` (`none`: at
/// its end, where a phi reads it); else why not.
fn available(mir: *const Mir, an: *const Analysis, pos: []const u32, v: Mir.Value, b: u32, at: u32) ?[]const u8 {
    const r = an.rv(v);
    if (mir.valueKind(r) != .inst_result) return null; // a constant, parameter or probe
    const d = mir.valueDef(r).inst_result;
    if (pos[@backingInt(d)] == none) return "an operand's defining row is linked into no block";
    const db = @backingInt(mir.instBlock(d));
    if (db == b) {
        if (at == none or mir.instOp(d) == .phi or pos[@backingInt(d)] < at) return null;
        return "an operand is defined at or after its use in the same block";
    }
    if (!an.dominates(db, b)) return "an operand's definition does not dominate its use";
    return null;
}

/// ponytail: the defining opcode only, not `Analysis.buildArrOf`'s fixpoint, so
/// a phi over no version at all passes. Run that fixpoint here if one appears.
fn version(mir: *const Mir, an: *const Analysis, v: Mir.Value) bool {
    const def = mir.valueDef(an.rv(v));
    if (def != .inst_result) return false;
    return switch (mir.instOp(def.inst_result)) {
        .anew, .store, .phi => true,
        else => false, // else: only those three opcodes yield an array version
    };
}

/// `held_vars` row i is what codegen reads as row i: a scalar's seed is the
/// `$held_*` call (`$held_real`, `$held_int`, `$held_str`, `$held_wide`) whose argument is
/// i, an array's seed the `anew` of the array whose `held` is i.
fn held(mir: *const Mir, lowered: *const Lowered, an: *const Analysis) ?Violation {
    for (lowered.held_vars.items, 0..) |h, i| {
        if (@backingInt(h.seed) >= an.nv) return bad(.handle, null, .none, "a `held_vars` seed names no Value");
        const seed = mir.valueDef(an.rv(h.seed));
        const inst = if (seed == .inst_result) seed.inst_result else return bad(.table, null, .none, "a `held_vars` seed is not a row");
        if (h.array != Lowered.none_u32) {
            if (h.array >= lowered.mem_arrays.items.len or lowered.mem_arrays.items[h.array].held != i)
                return bad(.table, mir.instBlock(inst), inst, "a held array's `mem_arrays` row does not name its `held_vars` row");
            continue;
        }
        const ok = switch (mir.instData(inst)) {
            .call => |c| (c.callee == .@"$held_real" or c.callee == .@"$held_int" or c.callee == .@"$held_str" or c.callee == .@"$held_wide") and c.args.len == 1 and (an.intConst(c.args[0]) orelse -1) == @as(i64, @intCast(i)),
            .unary, .binary, .ternary, .phi, .branch, .jump, .anew, .load, .store => false,
        };
        if (!ok) return bad(.table, mir.instBlock(inst), inst, "a `held_vars` seed is not the `$held_*` call reading its row");
    }
    return null;
}

// -------------------------------------------------------------------------

/// The handles a breaker needs from `sample`.
const Sample = struct {
    then_b: Mir.Block,
    else_b: Mir.Block,
    join: Mir.Block,
    t: Mir.Value,
    e: Mir.Value,
    p: Mir.Value,
    phi: Mir.Inst,
    ddx: Mir.Inst,
    anew: Mir.Inst,
    store: Mir.Inst,
    load: Mir.Inst,
    seed: Mir.Inst,
};

/// A well-formed module touching every invariant:
///   entry: seed = $held_real(0); c = V(a) > 0; branch c then else
///   then:  t = V(a) * k; jump join          else: e = -V(a); jump join
///   join:  m = phi(then: t, else: e); ddx(m, 0); a0 = anew 0;
///          s = store a0[0] = m; fload s[0]
fn sample(a: Allocator, mir: *Mir, lw: *Lowered) !Sample {
    try lw.nodes.append(a, .{ .name = "a", .kind = .net, .disc = "", .dir = .unspecified });
    try lw.params.append(a, .{ .name = "k", .ty = .real, .default = .f_one });
    try lw.mem_arrays.append(a, .{ .name = "m", .len = 2, .ty = .real });
    const entry = try mir.addBlock(a);
    const then_b = try mir.addBlock(a);
    const else_b = try mir.addBlock(a);
    const join = try mir.addBlock(a);
    const p = try mir.addBlockParam(a, 0);
    const k = try mir.addParamRef(a, 0);
    const seed = try mir.emitCall(a, entry, try mir.internString(a, "$held_real"), &.{.zero});
    try lw.held_vars.append(a, .{ .name = "h", .ty = .real, .init = .f_zero, .seed = seed });
    const c = try mir.emit(a, entry, .fgt, &.{ p, .f_zero });
    _ = try mir.emitBranch(a, entry, c, then_b, else_b);
    const t = try mir.emit(a, then_b, .fmul, &.{ p, k });
    _ = try mir.emitJump(a, then_b, join);
    const e = try mir.emit(a, else_b, .fneg, &.{p});
    _ = try mir.emitJump(a, else_b, join);
    const m = try mir.emitPhi(a, join, &.{ .{ .block = then_b, .value = t }, .{ .block = else_b, .value = e } });
    const d = try mir.emitCall(a, join, try mir.internString(a, "ddx"), &.{ m, .zero });
    const a0 = try mir.emitAnew(a, join, 0);
    const s = try mir.emit(a, join, .store, &.{ a0, .zero, m });
    const l = try mir.emit(a, join, .fload, &.{ s, .zero });
    return .{
        .then_b = then_b,
        .else_b = else_b,
        .join = join,
        .t = t,
        .e = e,
        .p = p,
        .phi = mir.valueDef(m).inst_result,
        .ddx = mir.valueDef(d).inst_result,
        .anew = mir.valueDef(a0).inst_result,
        .store = mir.valueDef(s).inst_result,
        .load = mir.valueDef(l).inst_result,
        .seed = mir.valueDef(seed).inst_result,
    };
}

const Breaker = *const fn (Allocator, *Mir, *Lowered, Sample) anyerror!void;

const cases = [_]struct { want: ?Invariant, name: []const u8, f: Breaker }{
    .{ .want = null, .name = "untouched", .f = struct {
        fn f(_: Allocator, _: *Mir, _: *Lowered, _: Sample) anyerror!void {}
    }.f },
    .{ .want = .chain, .name = "a row's block column disagrees with its chain", .f = struct {
        fn f(_: Allocator, mir: *Mir, _: *Lowered, s: Sample) anyerror!void {
            mir.insts.items(.block)[@backingInt(s.load)] = s.then_b;
        }
    }.f },
    .{ .want = .result, .name = "a Value's defs row points at another row", .f = struct {
        fn f(_: Allocator, mir: *Mir, _: *Lowered, s: Sample) anyerror!void {
            mir.defs.items(.payload)[@backingInt(s.t) - fd] = @backingInt(s.load);
        }
    }.f },
    .{ .want = .handle, .name = "an operand past the defs table", .f = struct {
        fn f(_: Allocator, mir: *Mir, _: *Lowered, s: Sample) anyerror!void {
            mir.insts.items(.b)[@backingInt(s.load)] = 9999;
        }
    }.f },
    .{ .want = .handle, .name = "an alias cycle", .f = struct {
        fn f(_: Allocator, mir: *Mir, _: *Lowered, s: Sample) anyerror!void {
            mir.setAlias(s.t, s.e);
            mir.setAlias(s.e, s.t);
        }
    }.f },
    .{ .want = .terminator, .name = "a second terminator", .f = struct {
        fn f(a: Allocator, mir: *Mir, _: *Lowered, s: Sample) anyerror!void {
            _ = try mir.emitJump(a, s.then_b, s.else_b);
        }
    }.f },
    .{ .want = null, .name = "a row after the terminator", .f = struct {
        fn f(a: Allocator, mir: *Mir, _: *Lowered, s: Sample) anyerror!void {
            _ = try mir.emit(a, s.then_b, .fneg, &.{s.p});
        }
    }.f },
    .{ .want = .terminator, .name = "an edge into the entry block", .f = struct {
        fn f(a: Allocator, mir: *Mir, _: *Lowered, s: Sample) anyerror!void {
            _ = try mir.emitJump(a, s.join, .entry);
        }
    }.f },
    .{ .want = .callee, .name = "a callee its name does not resolve to", .f = struct {
        fn f(_: Allocator, mir: *Mir, _: *Lowered, s: Sample) anyerror!void {
            const a = &mir.insts.items(.a)[@backingInt(s.ddx)];
            a.* = a.* >> Mir.callee_bits << Mir.callee_bits | @backingInt(Mir.Callee.limexp);
        }
    }.f },
    .{
        .want = .dominance,
        .name = "a use in a sibling arm",
        .f = struct {
            fn f(a: Allocator, mir: *Mir, _: *Lowered, s: Sample) anyerror!void {
                // Before the else arm's jump: the arm's own value is not in scope.
                const tail = mir.blockLast(s.else_b);
                mir.unlink(s.else_b, tail);
                _ = try mir.emit(a, s.else_b, .fadd, &.{ s.t, s.e });
                _ = try mir.emitJump(a, s.else_b, s.join);
            }
        }.f,
    },
    .{ .want = .dominance, .name = "a use of an orphaned row", .f = struct {
        fn f(_: Allocator, mir: *Mir, _: *Lowered, s: Sample) anyerror!void {
            mir.unlink(s.then_b, mir.valueDef(s.t).inst_result);
        }
    }.f },
    .{ .want = .phi_edges, .name = "a phi missing a predecessor", .f = struct {
        fn f(a: Allocator, mir: *Mir, _: *Lowered, s: Sample) anyerror!void {
            try mir.setPhiPairs(a, s.phi, &.{.{ .block = s.then_b, .value = s.t }});
        }
    }.f },
    .{ .want = .unknown, .name = "a probe past the unknowns", .f = struct {
        fn f(a: Allocator, mir: *Mir, _: *Lowered, _: Sample) anyerror!void {
            _ = try mir.addBlockParam(a, 1);
        }
    }.f },
    .{ .want = .unknown, .name = "a ddx lane past the unknowns", .f = struct {
        fn f(a: Allocator, mir: *Mir, _: *Lowered, s: Sample) anyerror!void {
            const at = mir.insts.items(.b)[@backingInt(s.ddx)];
            mir.extra.items[at + 2] = @backingInt(try mir.addIntConst(a, 1));
        }
    }.f },
    .{ .want = .table, .name = "a param_ref past the params", .f = struct {
        fn f(a: Allocator, mir: *Mir, _: *Lowered, _: Sample) anyerror!void {
            _ = try mir.addParamRef(a, 1);
        }
    }.f },
    .{ .want = .table, .name = "a held row whose seed reads another row", .f = struct {
        fn f(a: Allocator, _: *Mir, lw: *Lowered, _: Sample) anyerror!void {
            try lw.held_vars.insert(a, 0, .{ .name = "g", .ty = .real, .init = .f_zero, .seed = lw.held_vars.items[0].seed });
        }
    }.f },
    .{ .want = .array, .name = "a load from a scalar", .f = struct {
        fn f(_: Allocator, mir: *Mir, _: *Lowered, s: Sample) anyerror!void {
            mir.insts.items(.a)[@backingInt(s.load)] = @backingInt(s.p);
        }
    }.f },
    .{ .want = .array, .name = "a store into a scalar", .f = struct {
        fn f(_: Allocator, mir: *Mir, _: *Lowered, s: Sample) anyerror!void {
            mir.insts.items(.a)[@backingInt(s.store)] = @backingInt(s.p);
        }
    }.f },
    .{ .want = .chain, .name = "a chain that cycles", .f = struct {
        fn f(_: Allocator, mir: *Mir, _: *Lowered, s: Sample) anyerror!void {
            mir.insts.items(.next)[@backingInt(mir.blockLast(s.else_b))] = mir.valueDef(s.e).inst_result;
        }
    }.f },
    .{ .want = .chain, .name = "`last` is not the end of the chain", .f = struct {
        fn f(_: Allocator, mir: *Mir, _: *Lowered, s: Sample) anyerror!void {
            mir.blocks.items(.last)[@backingInt(s.join)] = s.phi;
        }
    }.f },
    .{ .want = .result, .name = "a terminator defines a Value", .f = struct {
        fn f(_: Allocator, mir: *Mir, _: *Lowered, s: Sample) anyerror!void {
            mir.insts.items(.result)[@backingInt(mir.blockLast(s.then_b))] = s.t;
        }
    }.f },
    .{ .want = .handle, .name = "a phi pair names no block", .f = struct {
        fn f(_: Allocator, mir: *Mir, _: *Lowered, s: Sample) anyerror!void {
            mir.extra.items[mir.insts.items(.b)[@backingInt(s.phi)]] = 999;
        }
    }.f },
    .{ .want = .handle, .name = "a branch target names no block", .f = struct {
        fn f(_: Allocator, mir: *Mir, _: *Lowered, _: Sample) anyerror!void {
            mir.extra.items[mir.insts.items(.b)[@backingInt(mir.blockLast(.entry))] + 1] = 99;
        }
    }.f },
    .{ .want = .handle, .name = "a call's callee is not a `Callee` tag", .f = struct {
        fn f(_: Allocator, mir: *Mir, _: *Lowered, s: Sample) anyerror!void {
            mir.insts.items(.a)[@backingInt(s.ddx)] = 255;
        }
    }.f },
    .{ .want = .handle, .name = "a call's name is not an interned string", .f = struct {
        fn f(_: Allocator, mir: *Mir, _: *Lowered, s: Sample) anyerror!void {
            mir.extra.items[mir.insts.items(.b)[@backingInt(s.ddx)]] = 9999;
        }
    }.f },
    .{ .want = .handle, .name = "a string constant names no interned string", .f = struct {
        fn f(a: Allocator, mir: *Mir, _: *Lowered, _: Sample) anyerror!void {
            _ = try mir.addStrConst(a, "x");
            mir.defs.items(.payload)[mir.defs.len - 1] = 9999;
        }
    }.f },
    .{ .want = .handle, .name = "an alias names no Value", .f = struct {
        fn f(_: Allocator, mir: *Mir, _: *Lowered, s: Sample) anyerror!void {
            mir.alias.items[@backingInt(s.t) - fd] = @fromBackingInt(99_999);
        }
    }.f },
    .{ .want = .handle, .name = "the alias table is shorter than `defs`", .f = struct {
        fn f(_: Allocator, mir: *Mir, _: *Lowered, _: Sample) anyerror!void {
            _ = mir.alias.pop();
        }
    }.f },
    .{ .want = .table, .name = "an `anew` past the `mem_arrays` rows", .f = struct {
        fn f(_: Allocator, mir: *Mir, _: *Lowered, s: Sample) anyerror!void {
            mir.insts.items(.a)[@backingInt(s.anew)] = 5;
        }
    }.f },
    .{ .want = .table, .name = "an `anew` past the `timepoints` slots", .f = struct {
        fn f(_: Allocator, mir: *Mir, _: *Lowered, s: Sample) anyerror!void {
            mir.insts.items(.b)[@backingInt(s.anew)] = 1;
        }
    }.f },
    .{ .want = .table, .name = "a held array whose `mem_arrays` row names another", .f = struct {
        fn f(a: Allocator, mir: *Mir, lw: *Lowered, s: Sample) anyerror!void {
            try lw.held_vars.append(a, .{ .name = "arr", .ty = .real, .init = .f_zero, .seed = mir.instResult(s.anew), .array = 0 });
        }
    }.f },
    .{ .want = .table, .name = "a held seed that is a constant", .f = struct {
        fn f(_: Allocator, _: *Mir, lw: *Lowered, _: Sample) anyerror!void {
            lw.held_vars.items[0].seed = .f_zero;
        }
    }.f },
    .{ .want = .handle, .name = "a held seed past the Values", .f = struct {
        fn f(_: Allocator, _: *Mir, lw: *Lowered, _: Sample) anyerror!void {
            lw.held_vars.items[0].seed = @fromBackingInt(99_999);
        }
    }.f },
    .{ .want = .dominance, .name = "a use before its definition in the same block", .f = struct {
        fn f(a: Allocator, mir: *Mir, _: *Lowered, s: Sample) anyerror!void {
            const late = try mir.emit(a, s.join, .fneg, &.{s.p});
            mir.insts.items(.b)[@backingInt(s.load)] = @backingInt(late);
        }
    }.f },
    .{ .want = .phi_edges, .name = "a phi pair from a block with no edge to it", .f = struct {
        fn f(a: Allocator, mir: *Mir, _: *Lowered, s: Sample) anyerror!void {
            try mir.setPhiPairs(a, s.phi, &.{
                .{ .block = s.then_b, .value = s.t },
                .{ .block = s.else_b, .value = s.e },
                .{ .block = .entry, .value = s.p },
            });
        }
    }.f },
    .{ .want = .unknown, .name = "a ddx with no lane argument", .f = struct {
        fn f(_: Allocator, mir: *Mir, _: *Lowered, s: Sample) anyerror!void {
            const a = &mir.insts.items(.a)[@backingInt(s.ddx)];
            a.* = @as(u8, @truncate(a.*)) | @as(u32, 1) << Mir.callee_bits;
        }
    }.f },
    // What the header leaves out on purpose: an unreachable block is never
    // emitted, so its uses and its phis go unchecked.
    .{ .want = null, .name = "an unreachable block may use anything", .f = struct {
        fn f(a: Allocator, mir: *Mir, _: *Lowered, s: Sample) anyerror!void {
            const dead = try mir.addBlock(a);
            _ = try mir.emit(a, dead, .fadd, &.{ s.t, s.e });
            _ = try mir.emitPhi(a, dead, &.{});
            _ = try mir.emitJump(a, dead, s.join);
        }
    }.f },
};

test "verify: a well-formed MIR passes, and each broken invariant is named" {
    for (cases) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var lw: Lowered = .{};
        var mir: Mir = .{};
        const s = try sample(a, &mir, &lw);
        try case.f(a, &mir, &lw, s);
        const got = try verify(&mir, &lw);
        errdefer std.debug.print("case `{s}`: got `{s}` ({s})\n", .{ case.name, if (got) |v| @tagName(v.invariant) else "none", if (got) |v| v.what else "" });
        try std.testing.expectEqual(case.want, if (got) |v| v.invariant else null);
    }
}
