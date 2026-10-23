//! Solve invariance: lowered MIR -> `Sinv`, the values that are the same at
//! every Newton iterate and time point, so `setup` computes them once per
//! card, instance and temperature. Codegen reads the answer as a value
//! (`Gen.sinv`). `pruneHeld` finds the §3.2 held slots a card cannot observe,
//! rewrites the MIR and returns the rows to keep, which lowering applies
//! (`Lower.dropHeld`): only lowering writes `Lowered`. The emitter half
//! (setup roots, `pub fn setup`) is `src/codegen/device/codegen/setup.zig`.
//!
//! LRM clauses this file's code cites: §2.9, §3.2, §4.4, §5.2.1, §5.6.1.2,
//! §5.10, §5.10.2, §6.3.6, §9.10, §9.15, §9.19.
//! IEEE 1364-2005 clauses cited: §17.11.

const std = @import("std");
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const Analysis = @import("analysis.zig");
const Input = @import("input.zig").Input;
const strArg = @import("input.zig").strArg;

/// Every fallible call here fails only on allocation.
pub const Error = std.mem.Allocator.Error;
const none_u32 = std.math.maxInt(u32);
/// `Scan.home`'s "not asked yet"; `none_u32` is an answer there.
const unknown_home: u32 = none_u32 - 1;
const assert = std.debug.assert;

/// The answer, per value, per block and per loop header.
pub const Sinv = struct {
    /// Value → solve-invariant.
    val: []bool = &.{},
    /// Block → placeable: `setup` may compute what it defines.
    blk: []bool = &.{},
    /// Loop header → a branch inside it is per-eval, so `setup` stops there.
    loop_varying: []bool = &.{},
    /// Value → the placeable block `setup` computes it in, for an invariant
    /// value whose own block is not placeable (`Scan.speculable`); `none_u32`
    /// for every other value. `moved`/`moved_off` list the same values per
    /// home block in ascending value order.
    home: []u32 = &.{},
    moved: []Mir.Value = &.{},
    moved_off: []u32 = &.{},

    /// The values `setup` computes at the end of block `b`, ascending.
    /// Asserts `b` is a block of the analysis `plan` ran over.
    pub fn movedTo(s: Sinv, b: u32) []const Mir.Value {
        if (s.moved_off.len == 0) return &.{};
        assert(b + 1 < s.moved_off.len);
        return s.moved[s.moved_off[b]..s.moved_off[b + 1]];
    }
};

/// One control dependence: block B depends on the branch at `a` through its
/// `then` edge (`then == true`) or its `else` edge.
pub const Cd = struct {
    a: u32,
    then: bool,

    // One per (block, controlling branch) pair (psp103: 2596, hisimhv_va:
    // 4824), read in block order by `solve` and `tpRule`: 8 bytes.
    comptime {
        std.debug.assert(@sizeOf(Cd) == 8);
    }
};

/// §5.10.2 `initial_step` with no analysis list, or §5.2.1 `analog initial`:
/// the condition `setup` treats as true. A qualified `initial_step("tran")`
/// is not one: in DC it keeps its initializer, so it is not a card function.
fn initCond(in: Input, cond: Mir.Value) bool {
    const def = in.mir.valueDef(in.an.rv(cond));
    if (def != .inst_result or in.mir.instOp(def.inst_result) != .call) return false;
    const d = in.mir.instData(def.inst_result).call;
    return switch (d.callee) {
        .analog_initial => true,
        .initial_step => d.args.len == 0,
        else => false, // else: every other callee is not the §5.10.2 first-point flag
    };
}

/// Returns the condition of the `branch` ending block `bi`, or null when the
/// block ends otherwise.
pub fn branchCond(in: Input, bi: u32) ?Mir.Value {
    const t = in.an.term[bi];
    if (t == .none or in.mir.instOp(t) != .branch) return null;
    return in.mir.instData(t).branch.cond;
}

fn thenOf(in: Input, bi: u32) u32 {
    assert(in.mir.instOp(in.an.term[bi]) == .branch);
    return @backingInt(in.mir.instData(in.an.term[bi]).branch.then_block);
}

fn elseOf(in: Input, bi: u32) u32 {
    assert(in.mir.instOp(in.an.term[bi]) == .branch);
    return @backingInt(in.mir.instData(in.an.term[bi]).branch.else_block);
}

/// Per-block control dependences, flat: `cd[off[b]..off[b + 1]]`, each
/// block's entries in branch-block order, `then` edge before `else`. Both
/// slices are owned by `in.arena`. `ipdom` is `Analysis.ipdom`; asserts that
/// it has the virtual exit (`Analysis.build` filled it).
pub fn controlDeps(in: Input, ipdom: []const u32) Error!struct { off: []u32, cd: []Cd } {
    const a = in.arena;
    const nb = in.an.nb;
    assert(ipdom.len == nb + 1);
    // Two walks of the post-dominator chains, counting then filling, rather
    // than a growable list per block: three exact arena allocations instead
    // of one list per block plus its doublings.
    const off = try a.alloc(u32, nb + 1);
    @memset(off, 0);
    var cd: []Cd = &.{};
    var at: []u32 = &.{}; // fill cursor per block
    for ([_]bool{ false, true }) |fill| {
        if (fill) {
            for (1..nb + 1) |b| off[b] += off[b - 1];
            cd = try a.alloc(Cd, off[nb]);
            at = try a.dupe(u32, off[0..nb]);
        }
        for (0..nb) |ai| {
            const A: u32 = @intCast(ai);
            if (branchCond(in, A) == null) continue;
            for ([_]u32{ thenOf(in, A), elseOf(in, A) }, [_]bool{ true, false }) |s, then| {
                var r = s;
                // Bound: a post-dominator chain holds each block once.
                var hops: usize = 0;
                while (r != ipdom[A] and r < nb) : (r = ipdom[r]) {
                    assert(hops < nb);
                    hops += 1;
                    if (fill) {
                        cd[at[r]] = .{ .a = A, .then = then };
                        at[r] += 1;
                    } else off[r + 1] += 1;
                    if (ipdom[r] == none_u32) break;
                }
            }
        }
    }
    for (0..nb) |b| assert(at[b] == off[b + 1]);
    return .{ .off = off, .cd = cd };
}

/// §9.10/§9.15/§9.19 and the pure math functions: the calls whose value is a
/// function of the `Model` row (its card and `temperature__`) alone, which
/// `setup` computes into `Model.su`. An allowlist: a callee not here is
/// per-eval. §6.3.6 `$mfactor` is an `Instance` field, so not here: instances
/// sharing a row may differ in it.
fn callInvariant(in: Input, d: anytype) bool {
    return switch (d.callee) {
        .@"$temperature", .@"$vt", .@"$param_given", .@"$port_connected" => true,
        // §9.15 Table 9-27: every literal name but `iteration`, which moves
        // with each Newton step, and `dt`, with each timepoint. `tnom` is a Model field the host writes with
        // the card; a published homotopy knob (gmin, gdev, sourceScaleFactor)
        // is invariant within a solve, and the host re-runs `setup` after
        // writing one (`setup_simparams` lists which).
        .@"$simparam" => !Lowered.simparamIsRuntime(strArg(in, d.args, 0) orelse return false),
        // IEEE 1364 §17.11 math and the §9.11/§9.12.1 conversions: pure.
        .@"$sqrt", .@"$exp", .@"$expm1", .@"$ln", .@"$ln1p", .@"$log", .@"$log10", .@"$floor", .@"$ceil" => true,
        .@"$sin", .@"$cos", .@"$tan", .@"$asin", .@"$acos", .@"$atan" => true,
        .@"$sinh", .@"$cosh", .@"$tanh", .@"$asinh", .@"$acosh", .@"$atanh" => true,
        .@"$pow", .@"$hypot", .@"$atan2", .@"$rtoi", .@"$itor", .@"$clog2" => true,
        else => false, // else: an ALLOWLIST — every other callee reads the solve, the time or state the host moves, until shown otherwise
    };
}

const Scan = struct {
    in: Input,
    val: []bool,
    plc: []bool,
    varying: []bool,
    init_else: []bool,
    /// `homeOf`'s answers for the current `plc` (`unknown_home` = not asked
    /// yet); whoever changes `plc` refills it with `unknown_home`.
    home: []u32,

    fn sv(s: *const Scan, v0: Mir.Value) bool {
        const v = s.in.an.rv(v0);
        return switch (s.in.mir.valueDef(v)) {
            .undef, .float_const, .int_const, .str_const, .param_ref => true,
            .block_param => false,
            .inst_result => s.val[@backingInt(v)],
        };
    }

    /// The §5.10.2 exception's incoming value: the held read of the variable
    /// whose end-of-block value is `phi` itself.
    fn heldEquiv(s: *const Scan, phi: Mir.Value, v0: Mir.Value) bool {
        const in = s.in;
        const def = in.mir.valueDef(in.an.rv(v0));
        if (def != .inst_result or in.mir.instOp(def.inst_result) != .call) return false;
        const d = in.mir.instData(def.inst_result).call;
        switch (d.callee) {
            .@"$held_real", .@"$held_int", .@"$held_str", .@"$held_wide" => {},
            else => return false, // else: only the §5.10 held reads name a held variable
        }
        const held = in.lowered.held_vars.items;
        if (held.len == 0) return false;
        // The `held_vars` index is the call's literal argument (`gen_call.heldIdx`).
        const c = in.an.foldConst(if (d.args.len != 0) d.args[0] else .zero, false) orelse return false;
        const i: usize = @intFromFloat(c);
        return in.an.rv(held[@min(i, held.len - 1)].final) == phi;
    }

    /// Does the edge `src -> y` run only when the initial step does not?
    fn initElseEdge(s: *const Scan, src: u32, y: u32) bool {
        if (s.init_else[src]) return true;
        const c = branchCond(s.in, src) orelse return false;
        return initCond(s.in, c) and elseOf(s.in, src) == y and thenOf(s.in, src) != y;
    }

    /// A pure op in a block `setup` does not place, over operands that are
    /// the same at every evaluation: `setup` computes it anyway, at its
    /// `home`, and the core reads it only where it would have computed it.
    /// Sound only for an op that cannot fault when its guard is false: a real
    /// outside its domain is NaN or inf. So no integer arithmetic (a zero
    /// divisor traps), no `%`, and none of the four functions whose every
    /// spelling reports a domain error when `display == .emit` (`zDomain`).
    /// ln, log, ln1p, sqrt and pow report too, but have an unchecked
    /// spelling codegen uses for the values this admits
    /// (`opcode_zig.Row.checked`, `Setup.spec`). The cost: such a value,
    /// out of its domain, reaches `eval` as the IEEE NaN or inf unreported.
    fn speculable(s: *const Scan, inst: Mir.Inst, blk: u32) bool {
        const in = s.in;
        if (in.an.loop_of[blk] != none_u32 or s.homeOf(blk) == none_u32) return false;
        const row = in.mir.instRow(inst);
        const info = Mir.opcode.get(row.op);
        switch (info.fold) {
            .unary, .binary, .math, .to_real => {},
            .none, .identity, .to_int => return false,
        }
        if (info.int and !info.bool01) return false;
        switch (info.domain) {
            .all, .positive, .gt_neg_one, .non_negative, .pow_sign, .tan_poles => {},
            .unit_closed, .unit_open, .ge_one, .nonzero_divisor => return false,
        }
        return switch (Mir.opClass(row.op)) {
            .unary => s.anchored(@fromBackingInt(@intCast(row.a))),
            .binary => s.anchored(@fromBackingInt(@intCast(row.a))) and s.anchored(@fromBackingInt(@intCast(row.b))),
            .ternary, .phi, .branch, .jump, .call, .anew, .load, .store => false,
        };
    }

    /// An operand `setup` holds wherever it places a speculable op: a leaf,
    /// or an invariant value outside every loop. Its block dominates the
    /// user's, so it is placed at or above the user's `home`.
    fn anchored(s: *const Scan, v0: Mir.Value) bool {
        const v = s.in.an.rv(v0);
        if (s.in.mir.valueDef(v) != .inst_result) return s.sv(v);
        const b = s.in.an.def_block[@backingInt(v)];
        return s.val[@backingInt(v)] and b != none_u32 and s.in.an.loop_of[b] == none_u32;
    }

    /// The nearest placeable dominator of `b`, or `none_u32`. Memoized along
    /// the dominator path it climbs, which every block on it shares: n nested
    /// unplaceable `if`s would otherwise climb O(n) each (#29).
    fn homeOf(s: *const Scan, b0: u32) u32 {
        const nb = s.in.an.nb;
        assert(b0 < nb);
        var b = b0;
        // Bound: a dominator path holds each block once, so both climbs take
        // fewer than `nb` hops.
        var hops: usize = 0;
        const h = while (true) : (hops += 1) {
            assert(hops < nb);
            if (s.home[b] != unknown_home) break s.home[b];
            if (s.plc[b]) break b;
            const up = s.in.an.idom[b];
            if (up == none_u32 or up == b) break none_u32;
            b = up;
        };
        if (h != none_u32) assert(s.plc[h]);
        b = b0;
        hops = 0;
        while (s.home[b] == unknown_home) : (hops += 1) {
            assert(hops < nb);
            s.home[b] = h;
            if (b == h) break;
            const up = s.in.an.idom[b];
            if (up == none_u32 or up == b) break;
            b = up;
        }
        return h;
    }

    fn rule(s: *const Scan, v: Mir.Value) bool {
        const in = s.in;
        const def = in.mir.valueDef(v);
        if (def != .inst_result) return s.sv(v);
        const inst = def.inst_result;
        const blk = in.an.def_block[@backingInt(v)];
        if (blk == none_u32) return false;
        var g = in.mir.guardConds(inst);
        while (g.next()) |c| if (!(if (s.plc[blk]) s.sv(c) else s.anchored(c))) return false;
        if (!s.plc[blk]) return s.speculable(inst, blk);
        const row = in.mir.instRow(inst);
        switch (row.op) {
            .call => {
                const d = in.mir.instData(inst).call;
                if (!callInvariant(in, d)) return false;
                for (d.args) |arg| if (!s.sv(arg)) return false;
                return true;
            },
            .phi => {
                const d = in.mir.instData(inst).phi;
                var k: u32 = 0;
                while (k < d.count) : (k += 1) {
                    const p = in.mir.phiPair(inst, k);
                    const src: u32 = @backingInt(p.block);
                    if (s.plc[src] and s.sv(p.value) and !s.initElseEdge(src, blk)) continue;
                    if (s.initElseEdge(src, blk) and s.heldEquiv(v, p.value)) continue;
                    return false;
                }
                return true;
            },
            // §5.6.1.2 the path latches move with every accepted step.
            .path_prev, .path_acc, .branch, .jump => return false,
            .select => {
                const d = in.mir.instData(inst).ternary;
                return s.sv(d.cond) and s.sv(d.then_val) and s.sv(d.else_val);
            },
            else => return switch (Mir.opClass(row.op)) { // else: every other opcode is pure; its class names the operands
                .unary => s.sv(@fromBackingInt(@intCast(row.a))),
                .binary => s.sv(@fromBackingInt(@intCast(row.a))) and s.sv(@fromBackingInt(@intCast(row.b))),
                .ternary => s.sv(@fromBackingInt(@intCast(row.a))) and s.sv(@fromBackingInt(@intCast(row.b))) and s.sv(@fromBackingInt(@intCast(row.c))),
                .phi, .branch, .jump, .call => false,
                // §3.2.2 array storage is per evaluation: a setup root is one
                // `Setup` scalar, and an array version is not one.
                // ponytail: an invariant array (an `analog initial` table)
                // is recomputed per eval; the upgrade is a `[N]f64` Setup field.
                .anew, .load, .store => false,
            },
        }
    }
};

/// Returns the solve-invariance fixpoint; every slice is owned by `in.arena`.
/// Optimistic and monotone: every flag starts true and only falls.
///   - A constant, parameter or `undef` is invariant; a §4.4 probe is not.
///   - A pure op is invariant when its operands are and its block is
///     placeable, or, when it cannot fault, whatever its block
///     (`Scan.speculable`); `setup` then computes it at its `home`.
///   - A call is invariant only on the allowlist (`callInvariant`), over
///     invariant arguments.
///   - A phi is invariant when its block is placeable and every incoming edge
///     comes from a placeable block with an invariant value, or is the
///     initial-step exception below.
///   - A block is placeable when every branch it is control-dependent on
///     (post-dominator frontier, per edge) tests an invariant condition from a
///     placeable block, and no loop with a per-eval branch can reach it.
///
/// §5.10.2 initial-step exception: every variable `@(initial_step)` or
/// `analog initial` assigns is §5.10 held. It is initial-only when its
/// end-of-block value is the event join's `phi(held read, assigned value)` and
/// the assigned value is invariant: by induction every evaluation sees the
/// assigned value, so `setup` takes the event's arm unconditionally. A write
/// after the join (`k = k + 1`) breaks the identity. This relies on the host
/// evaluating an initial step before any other point, an obligation stated on
/// `setup`.
pub fn plan(in: Input) Error!Sinv {
    var r = try solve(in, true);
    const a = in.arena;
    const s: Scan = .{ .in = in, .val = r.val, .plc = r.blk, .varying = r.loop_varying, .init_else = &.{}, .home = try a.alloc(u32, in.an.nb) };
    @memset(s.home, unknown_home);
    r.home = try a.alloc(u32, in.an.nv);
    @memset(r.home, none_u32);
    r.moved_off = try a.alloc(u32, in.an.nb + 1);
    @memset(r.moved_off, 0);
    var n: u32 = 0;
    for (Mir.Value.first_dynamic..in.an.nv) |i| {
        const v: Mir.Value = @fromBackingInt(@intCast(i));
        const b = in.an.def_block[i];
        if (!r.val[i] or b == none_u32 or r.blk[b] or in.an.rv(v) != v) continue;
        r.home[i] = s.homeOf(b);
        // `Scan.rule` admits a value outside a placeable block only through
        // `speculable`, which requires a home.
        assert(r.home[i] != none_u32);
        r.moved_off[r.home[i] + 1] += 1;
        n += 1;
    }
    for (0..in.an.nb) |b| r.moved_off[b + 1] += r.moved_off[b];
    r.moved = try a.alloc(Mir.Value, n);
    const fill = try a.dupe(u32, r.moved_off[0..in.an.nb]);
    for (r.home, 0..) |h, i| if (h != none_u32) {
        r.moved[fill[h]] = @fromBackingInt(@intCast(i));
        fill[h] += 1;
    };
    return r;
}

/// `placing == false` drops the one rule about placement rather than
/// invariance (nothing a per-eval loop can reach is placeable). A block after
/// such a loop that depends only on invariant branches then counts as fixed,
/// and so does what it computes: `setup` cannot compute those values, but
/// they are the same at every evaluation of a card, which is all `pruneHeld`
/// asks.
fn solve(in: Input, placing: bool) Error!Sinv {
    const a = in.arena;
    const nb = in.an.nb;
    const nv = in.an.nv;
    const cds = try controlDeps(in, in.an.ipdom);
    var s: Scan = .{
        .in = in,
        .val = try a.alloc(bool, nv),
        .plc = try a.alloc(bool, nb),
        .varying = try a.alloc(bool, nb),
        .init_else = try a.alloc(bool, nb),
        .home = try a.alloc(u32, nb),
    };
    @memset(s.val, true);
    @memset(s.plc, true);
    const reach = try a.alloc(bool, nb);
    // Each block is pushed at most once (its flag is set first).
    var stack: std.ArrayList(u32) = try .initCapacity(a, nb);
    // Bound: optimistic and monotone. Every round but the last lowers at
    // least one of the `nv` value or `nb` block flags, so at most
    // `nv + nb + 1` rounds.
    var rounds: usize = 0;
    while (true) : (rounds += 1) {
        assert(rounds <= @as(usize, nv) + nb);
        var changed = false;
        // Loops with a per-eval branch, and everything they can reach.
        @memset(s.varying, false);
        for (0..nb) |bi| {
            const c = branchCond(in, @intCast(bi)) orelse continue;
            const h = in.an.loop_of[bi];
            if (h != none_u32 and !s.sv(c)) s.varying[h] = true;
        }
        @memset(reach, false);
        for (0..nb) |bi| if (s.varying[bi]) {
            reach[bi] = true;
            stack.appendAssumeCapacity(@intCast(bi));
        };
        while (stack.pop()) |b| for (in.an.succs[b]) |x| {
            if (reach[x]) continue;
            reach[x] = true;
            stack.appendAssumeCapacity(x);
        };
        // Placeable blocks, and the initial-step else arms.
        for (0..nb) |bi| {
            var ok = !(placing and reach[bi]);
            var ie = false;
            for (cds.cd[cds.off[bi]..cds.off[bi + 1]]) |d| {
                const c = branchCond(in, d.a).?;
                if (initCond(in, c)) {
                    if (!d.then) {
                        ie = true;
                        ok = false;
                    }
                } else if (!s.sv(c)) ok = false;
                if (!s.plc[d.a]) ok = false;
            }
            s.init_else[bi] = ie;
            if (s.plc[bi] and !ok) {
                s.plc[bi] = false;
                changed = true;
            }
        }
        @memset(s.home, unknown_home); // `plc` may have fallen above
        for (Mir.Value.first_dynamic..nv) |i| {
            if (!s.val[i]) continue;
            const v: Mir.Value = @fromBackingInt(@intCast(i));
            if (in.an.rv(v) != v) {
                // An alias carries its target's answer.
                if (!s.sv(v)) {
                    s.val[i] = false;
                    changed = true;
                }
                continue;
            }
            if (!s.rule(v)) {
                s.val[i] = false;
                changed = true;
            }
        }
        if (!changed) break;
    }
    return .{ .val = s.val, .blk = s.plc, .loop_varying = s.varying };
}

/// Is `v` a value `setup` may hand eval? Invariant, computed (not a literal
/// the renderer folds), one value per evaluation (outside every loop), and of
/// a type `Setup` has a field for.
pub fn candidate(in: Input, sinv: []const bool, v: Mir.Value) bool {
    const i = @backingInt(v);
    if (i < Mir.Value.first_dynamic or !sinv[i]) return false;
    // A string or a wide integer has no `Setup` field type.
    if (in.an.vty[i] == .str or in.an.vty[i] == .wide) return false;
    // A §3.4 parameter a per-eval body reads is copied beside the derived
    // values, so `eval` reads one dense block and not the card's own lines
    // (bsimcmg: 171 of 1,901 fields, spread over 74 cache lines).
    if (in.mir.valueDef(v) == .param_ref) return true;
    if (in.mir.valueDef(v) != .inst_result) return false;
    const b = in.an.def_block[i];
    if (b == none_u32 or in.an.loop_of[b] != none_u32) return false;
    return in.an.foldConst(v, false) == null;
}

/// VerA's `vera_timepoint` (§2.9): the calls whose value is the same at
/// every Newton iteration of one timepoint, given their arguments. The
/// solve-invariant ones (`callInvariant`), the time and analysis the host
/// keys the cache on, the accepted held state, the cache itself, and the
/// pure synthetic reads lowering mints. An allowlist, as `callInvariant` is.
fn callTimepoint(in: Input, d: anytype) bool {
    if (callInvariant(in, d)) return true;
    return switch (d.callee) {
        .@"$abstime", .@"$realtime", .analysis, .analog_initial, .initial_step, .final_step => true,
        // §9.15 `dt` moves with the timepoint, never within one; `iteration` does.
        .@"$simparam" => std.mem.eql(u8, strArg(in, d.args, 0) orelse return false, "dt"),
        .@"$held_real", .@"$held_int", .@"$held_str", .@"$held_wide", .@"$tp_hit", .@"$tp_int", .@"$tp_real", .@"$tp_wide" => true,
        .@"$idx", .@"$idx$int", .@"$idx$str", .limexp, .@"$str$cat", .@"$str$repeat", .@"$wide", .@"$wide$int" => true,
        else => false, // else: an ALLOWLIST — every other callee may read the iterate or state an iteration moves
    };
}

/// VerA's `vera_timepoint` (§2.9): a value of statement `t`, or a branch
/// condition inside it, that can move between the Newton iterations of one
/// timepoint (E0531), or null. Optimistic and monotone like `solve`: every
/// value starts fixed and only falls.
///   - A probe varies; a constant or parameter does not.
///   - A call varies unless `callTimepoint` allows it over fixed arguments.
///   - A pure op, select, load or store varies with an operand; an `anew` is
///     fixed (zero, the accepted held state, or the cache).
///   - A phi varies with an incoming value. Outside the statement it varies
///     also when an incoming edge's predecessor ends in, or is control-
///     dependent on, a varying branch: `if (V(a) > 0) y = 1; else y = 2;`.
///     Inside, every branch is checked itself, so data suffices.
pub fn timepointVarying(in: Input, t: Lowered.TpBlock) Error!?Mir.Value {
    const a = in.arena;
    const nb = in.an.nb;
    const nv = in.an.nv;
    const inside = try a.alloc(bool, nb);
    @memset(inside, false);
    // Each block is pushed at most once (its flag is set first).
    var stack: std.ArrayList(u32) = try .initCapacity(a, nb);
    const miss: u32 = @backingInt(t.miss);
    const join: u32 = @backingInt(t.join);
    inside[miss] = true;
    stack.appendAssumeCapacity(miss);
    while (stack.pop()) |b| for (in.an.succs[b]) |x| {
        if (x == join or inside[x]) continue;
        inside[x] = true;
        stack.appendAssumeCapacity(x);
    };
    const cds = try controlDeps(in, in.an.ipdom);
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
            const now = if (r != v) varies(in, vary, r) else tpRule(in, vary, inside, cds, v);
            if (!now) continue;
            vary[i] = true;
            changed = true;
        }
    }
    for (0..nb) |bi| {
        if (!inside[bi]) continue;
        if (branchCond(in, @intCast(bi))) |c| if (varies(in, vary, c)) return c;
    }
    // An alias is the value it names, wherever that is: a pass-through phi
    // the SSA builder placed inside and then folded away reads nothing here.
    for (Mir.Value.first_dynamic..nv) |i| {
        const v: Mir.Value = @fromBackingInt(@intCast(i));
        const b = in.an.def_block[i];
        if (vary[i] and in.an.rv(v) == v and b != none_u32 and inside[b]) return v;
    }
    return null;
}

fn varies(in: Input, vary: []const bool, v0: Mir.Value) bool {
    const v = in.an.rv(v0);
    return switch (in.mir.valueDef(v)) {
        .undef, .float_const, .int_const, .str_const, .param_ref => false,
        .block_param => true,
        .inst_result => vary[@backingInt(v)],
    };
}

fn tpRule(in: Input, vary: []const bool, inside: []const bool, cds: anytype, v: Mir.Value) bool {
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
            const out = blk_v == none_u32 or !inside[blk_v];
            for (0..d.count) |k| {
                const pp = in.mir.phiPair(inst, @intCast(k));
                if (varies(in, vary, pp.value)) break :blk true;
                if (!out) continue;
                const pb: u32 = @backingInt(pp.block);
                if (branchCond(in, pb)) |c| if (varies(in, vary, c)) break :blk true;
                for (cds.cd[cds.off[pb]..cds.off[pb + 1]]) |cd| {
                    if (varies(in, vary, branchCond(in, cd.a).?)) break :blk true;
                }
            }
            break :blk false;
        },
    };
}

/// §3.2 finds the held slots the card makes unobservable, rewrites `mir` in
/// place, and returns which `lowered.held_vars` rows to keep (arena-owned,
/// one flag per row), or null when every row stays and nothing changed.
/// Lowering applies the mask (`Lower.dropHeld`) before the next MIR check,
/// since the MIR already numbers the kept rows densely.
///
/// A `.unless_invariant` held variable has no read that reaches a later write
/// of the same evaluation (`lower_param.Exposed`), so its held value is
/// observed only where it merges with a write: a phi or a select fed by the
/// `$held_*` seed. When every such merge is solve-invariant (its block and
/// incoming edges depend only on invariant branches, a select's condition is
/// invariant), a fixed card either writes the variable before every read or
/// never writes it, so the slot always equals the declared initializer. The
/// seed becomes an alias of the initializer and the remaining rows are
/// renumbered.
///
/// Runs between lowering and if-conversion (src/Compilation.zig stage 4.4): it needs
/// `plan`'s invariance, and a select must not yet hide the merges it reads.
/// Every candidate is still held while the plan runs, so a condition over one
/// reads as varying, which is conservative.
pub fn pruneHeld(arena: std.mem.Allocator, mir: *Mir, lowered: *const Lowered) Error!?[]const bool {
    const held = lowered.held_vars.items;
    for (held) |h| {
        if (h.why == .unless_invariant) break;
    } else return null;
    const an = try Analysis.build(arena, mir, lowered);
    const in: Input = .{ .arena = arena, .mir = mir, .an = &an, .lowered = lowered };
    const s = try solve(in, false);
    // At most one merge per instruction: sized once, never grown.
    var merges: std.ArrayList(Mir.Inst) = try .initCapacity(arena, mir.insts.len);
    for (0..an.nb) |bi| {
        var it = mir.blockInsts(@fromBackingInt(@intCast(bi)));
        while (it.next()) |inst| switch (mir.instOp(inst)) {
            .phi, .select => merges.appendAssumeCapacity(inst),
            else => {}, // else: only a phi or a select merges a held value with a write
        };
    }
    const web = try arena.alloc(bool, an.nv);
    const keep = try arena.alloc(bool, held.len);
    for (held, keep) |h, *k| {
        k.* = h.why != .unless_invariant or observed(in, s, merges.items, web, h.seed);
        if (k.*) continue;
        // `.unless_invariant` is a scalar's reason only: `holdArray` rows
        // are `.event`, so no `mem_arrays` row is left pointing here.
        assert(h.array == none_u32);
        const seed = an.rv(h.seed);
        const inst = mir.valueDef(seed).inst_result;
        mir.unlink(@fromBackingInt(an.def_block[@backingInt(seed)]), inst);
        mir.setAlias(seed, h.init);
    }
    // The seed's argument is its row (`gen_call.heldIdx`), counted over the
    // kept rows. A held array's seed is its `anew`, which carries no row: its
    // `mem_arrays` entry does, and `Lower.dropHeld` renumbers that.
    var i: usize = 0;
    for (held, keep) |h, k| {
        if (!k) continue;
        defer i += 1;
        if (h.array != none_u32) continue;
        const inst = mir.valueDef(an.rv(h.seed)).inst_result;
        mir.extra.items[mir.insts.items(.b)[@backingInt(inst)] + 1] = @backingInt(try mir.addIntConst(arena, @intCast(i)));
    }
    return keep;
}

/// Does a merge of `seed`'s forward web vary from one evaluation to the next?
fn observed(in: Input, s: Sinv, merges: []const Mir.Inst, web: []bool, seed: Mir.Value) bool {
    const mir = in.mir;
    const an = in.an;
    @memset(web, false);
    web[@backingInt(an.rv(seed))] = true;
    // Bound: `web` only rises; every round but the last adds one merge.
    var rounds: usize = 0;
    var changed = true;
    while (changed) : (rounds += 1) {
        assert(rounds <= merges.len);
        changed = false;
        for (merges) |m| {
            const r = an.rv(mir.instResult(m));
            if (web[@backingInt(r)]) continue;
            const blk = an.def_block[@backingInt(r)];
            var feeds = false;
            var fixed = blk != none_u32 and s.blk[blk];
            switch (mir.instData(m)) {
                .phi => |d| for (0..d.count) |k| {
                    const p = mir.phiPair(m, @intCast(k));
                    feeds = feeds or web[@backingInt(an.rv(p.value))];
                    fixed = fixed and s.blk[@backingInt(p.block)];
                },
                .ternary => |d| {
                    feeds = web[@backingInt(an.rv(d.then_val))] or web[@backingInt(an.rv(d.else_val))];
                    fixed = fixed and s.val[@backingInt(an.rv(d.cond))];
                },
                else => unreachable, // else: `merges` holds phis and selects only
            }
            if (!feeds) continue;
            if (!fixed) return true;
            web[@backingInt(r)] = true;
            changed = true;
        }
    }
    return false;
}

const Fixture = @import("fixture.zig").Fixture;

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
    try std.testing.expect(s.val[@backingInt(t)] and s.val[@backingInt(et)] and s.val[@backingInt(k)]);
    try std.testing.expect(!s.val[@backingInt(i)]);
    // §9.15 `iteration` moves with every Newton step.
    try std.testing.expect(!s.val[@backingInt(it)]);
    // `dt` moves with every timepoint, so `setup` must not hoist it.
    try std.testing.expect(!s.val[@backingInt(dt)]);
    try std.testing.expect(s.blk[0]);
    try std.testing.expect(candidate(in, s.val, k));
    try std.testing.expect(!candidate(in, s.val, i));
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
    try std.testing.expect(!s.blk[@backingInt(else_b)]);
    try std.testing.expect(s.val[@backingInt(p)]);
    try std.testing.expectEqual(@as(u32, 0), s.home[@backingInt(p)]);
    try std.testing.expectEqualSlices(Mir.Value, &.{p}, s.movedTo(0));
    try std.testing.expect(candidate(in, s.val, p));
    // A parameter leaf is a candidate too: `setup` copies it beside `p`.
    try std.testing.expect(candidate(in, s.val, mj));
    // An integer divide by zero traps, so it stays under its guard.
    try std.testing.expect(!s.val[@backingInt(d)]);
}

/// entry: if (V(a) > 0) then else; then, else: join. Blocks 0..3.
fn diamond(f: *Fixture) !struct { then_b: Mir.Block, else_b: Mir.Block, join: Mir.Block, c: Mir.Value } {
    const a = f.alloc();
    const then_b = try f.mir.addBlock(a);
    const else_b = try f.mir.addBlock(a);
    const join = try f.mir.addBlock(a);
    const c = try f.mir.emit(a, .entry, .fgt, &.{ try f.probe(0), .f_zero });
    _ = try f.mir.emitBranch(a, .entry, c, then_b, else_b);
    _ = try f.mir.emitJump(a, then_b, join);
    _ = try f.mir.emitJump(a, else_b, join);
    return .{ .then_b = then_b, .else_b = else_b, .join = join, .c = c };
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
    const cds = try controlDeps(in, an.ipdom);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 1, 2, 2 }, cds.off);
    try std.testing.expectEqualSlices(Cd, &.{ .{ .a = 0, .then = true }, .{ .a = 0, .then = false } }, cds.cd);
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
    try std.testing.expect(s.val[@backingInt(gmin)]);
    try std.testing.expect(!s.val[@backingInt(t)]);
    try std.testing.expect(s.val[@backingInt(root)]);
    // The arms depend on a per-eval branch; the join does not.
    try std.testing.expect(!s.blk[@backingInt(d.then_b)]);
    try std.testing.expect(!s.blk[@backingInt(d.else_b)]);
    try std.testing.expect(s.blk[@backingInt(d.join)]);
    try std.testing.expect(!s.val[@backingInt(sel)]);
    // Invariant but a literal the renderer folds: not a setup root.
    try std.testing.expect(s.val[@backingInt(lit)]);
    try std.testing.expect(!candidate(in, s.val, lit));
    try std.testing.expect(candidate(in, s.val, root));
    // Nothing moved into block 0's tail here.
    try std.testing.expectEqual(@as(usize, 0), s.movedTo(0).len);
}

test "pruneHeld leaves a module with no card-conditional retention untouched" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{"a"});
    defer f.deinit();
    const a = f.alloc();
    const seed = try f.call("$held_real", &.{.zero});
    try f.lowered.held_vars.append(a, .{ .name = "x", .ty = .real, .init = .f_zero, .seed = seed, .final = seed, .why = .retained });
    const n_insts = f.mir.insts.len;
    // Nothing to decide, so no mask: the spine has nothing to apply.
    try std.testing.expect(try pruneHeld(a, &f.mir, &f.lowered) == null);
    try std.testing.expectEqual(@as(usize, 1), f.lowered.held_vars.items.len);
    try std.testing.expectEqual(n_insts, f.mir.insts.len);
    try std.testing.expect(!f.mir.hasAlias(seed));
}

test "timepointVarying: a probe inside the statement varies; the time and held state do not" {
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
        const got = try timepointVarying(in, .{ .tok = 0, .miss = miss, .join = join });
        try std.testing.expectEqual(if (callee == null) @as(?Mir.Value, v) else null, got);
    }
}

test "pruneHeld: a held slot read only under card-fixed control is aliased to its initializer and dropped" {
    // entry: s = $held_real(0) (`.unless_invariant`), k = s + 1. Nothing
    // merges `s` with a write, so no card can observe the slot.
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{"a"});
    defer f.deinit();
    const a = f.alloc();
    const seed = try f.call("$held_real", &.{.zero});
    const k = try f.mir.emit(a, .entry, .fadd, &.{ seed, .f_one });
    try f.lowered.held_vars.append(a, .{ .name = "s", .ty = .real, .init = .f_two, .seed = seed, .final = seed, .why = .unless_invariant });
    const keep = (try pruneHeld(a, &f.mir, &f.lowered)).?;
    try std.testing.expectEqualSlices(bool, &.{false}, keep);
    try std.testing.expectEqual(Mir.Value.f_two, f.mir.resolveAlias(seed));
    // The seed row left its block's chain; its user still reads through it.
    var it = f.mir.blockInsts(.entry);
    while (it.next()) |inst| try std.testing.expect(f.mir.instResult(inst) != seed);
    try std.testing.expectEqual(seed, f.mir.instData(f.mir.valueDef(k).inst_result).binary.lhs);
}
