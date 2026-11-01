//! Solve invariance as a fixpoint: `Input` in; `setup.Invariance`'s value,
//! block and loop-header flags out (`solve`), then each moved value's home
//! (`fillHomes`). Optimistic and monotone: every flag starts true and only
//! falls.
//!   - A constant, parameter or `undef` is invariant; a §4.4 probe is not.
//!   - A pure op is invariant when its operands are and its block is
//!     placeable, or, when it cannot fault, whatever its block
//!     (`Scan.speculable`); `setup` then computes it at its `home`.
//!   - A call is invariant only on the allowlist (`callInvariant`), over
//!     invariant arguments.
//!   - A phi is invariant when its block is placeable and every incoming edge
//!     comes from a placeable block with an invariant value, or is the
//!     initial-step exception below.
//!   - A block is placeable when every branch it is control-dependent on
//!     tests an invariant condition from a placeable block, and no loop with
//!     a per-eval branch can reach it.
//!
//! §5.10.2 initial-step exception: every variable `@(initial_step)` or
//! `analog initial` assigns is §5.10 held. It is initial-only when its
//! end-of-block value is the event join's `phi(held read, assigned value)`
//! and the assigned value is invariant: by induction every evaluation sees
//! the assigned value, so `setup` takes the event's arm unconditionally. A
//! write after the join (`k = k + 1`) breaks the identity. This relies on the
//! host evaluating an initial step before any other point, an obligation
//! stated on `setup`.
//!
//! LRM clauses this file's code cites: §3.2.2, §4.4, §5.2.1, §5.6.1.2,
//! §5.10, §5.10.2, §6.3.6, §9.10, §9.11, §9.12.1, §9.15, §9.19.
//! IEEE 1364-2005 clauses cited: §17.11.
//!
//! Contents:
//! - `pub const Error = Allocator.Error`
//! - `pub const Placing = enum { placing, invariance_only }`
//! - `pub fn solve(in: Input, placing: Placing) Error!setup.Invariance`
//! - `pub fn fillHomes(in: Input, r: *setup.Invariance) Error!void`
//! - `pub fn callInvariant(in: Input, d: Call) bool`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const input = @import("input.zig");
const Input = input.Input;
const setup = @import("setup.zig");

/// Fails only on allocation, in `in.arena`.
pub const Error = Allocator.Error;

/// Whether `solve` keeps the one rule about placement rather than invariance
/// (nothing a per-eval loop can reach is placeable). `.invariance_only` drops
/// it: a block after such a loop that depends only on invariant branches then
/// counts as fixed, and so does what it computes. `setup` cannot compute
/// those values, but they are the same at every evaluation of a card, which
/// is all `held.prune` asks.
pub const Placing = enum { placing, invariance_only };

const Call = @FieldType(Mir.InstData, "call");
const none = std.math.maxInt(u32);
/// `Scan.home`'s "not asked yet"; `none` is an answer there.
const unknown_home: u32 = none - 1;

/// One round's view of the flags `solve` lowers. Every slice is borrowed
/// from `solve` or `fillHomes`.
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
        assert(@backingInt(v) < s.val.len);
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
        assert(in.an.rv(phi) == phi); // `rule` asks only for an unaliased phi
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

    /// Whether the edge `src -> y` runs only when the initial step does not.
    fn initElseEdge(s: *const Scan, src: u32, y: u32) bool {
        assert(s.init_else.len == s.in.an.nb); // `solve`'s scan, not `fillHomes'`
        assert(y < s.in.an.nb);
        if (s.init_else[src]) return true;
        const c = setup.branchCond(s.in, src) orelse return false;
        return initCond(s.in, c) and setup.elseOf(s.in, src) == y and setup.thenOf(s.in, src) != y;
    }

    /// A pure op in a block `setup` does not place, over operands that are
    /// the same at every evaluation: `setup` computes it anyway, at its
    /// `home`, and the core reads it only where it would have. Sound only
    /// for an op that cannot fault when its guard is false: a real outside
    /// its domain is NaN or inf. So no integer arithmetic (a zero divisor
    /// traps), no `%`, and none of the four functions whose every spelling
    /// reports a domain error when `display == .emit` (`zDomain`). ln, log,
    /// ln1p, sqrt and pow report too, but have an unchecked spelling codegen
    /// uses for the values this admits (`opcode_zig.Row.checked`,
    /// `Setup.spec`). The cost: such a value, out of its domain, reaches
    /// `eval` as the IEEE NaN or inf unreported.
    fn speculable(s: *const Scan, inst: Mir.Inst, blk: u32) bool {
        const in = s.in;
        assert(!s.plc[blk]); // `rule` asks only outside a placeable block
        if (in.an.loop_of[blk] != none or s.homeOf(blk) == none) return false;
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
        const r = switch (Mir.opClass(row.op)) {
            .unary => s.anchored(@fromBackingInt(@intCast(row.a))),
            .binary => s.anchored(@fromBackingInt(@intCast(row.a))) and s.anchored(@fromBackingInt(@intCast(row.b))),
            .ternary, .phi, .branch, .jump, .call, .anew, .load, .store => false,
        };
        if (r) assert(s.home[blk] != none); // `fillHomes` relies on the home
        return r;
    }

    /// An operand `setup` holds wherever it places a speculable op: a leaf,
    /// or an invariant value outside every loop. Its block dominates the
    /// user's, so it is placed at or above the user's `home`.
    fn anchored(s: *const Scan, v0: Mir.Value) bool {
        const v = s.in.an.rv(v0);
        if (s.in.mir.valueDef(v) != .inst_result) return s.sv(v);
        const b = s.in.an.def_block[@backingInt(v)];
        const r = s.val[@backingInt(v)] and b != none and s.in.an.loop_of[b] == none;
        if (r) assert(b < s.in.an.nb);
        return r;
    }

    /// The nearest placeable dominator of `b0`, or `none`. Memoized along the
    /// dominator path it climbs, which every block on it shares: n nested
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
            if (up == none or up == b) break none;
            b = up;
        };
        if (h != none) assert(s.plc[h]);
        b = b0;
        hops = 0;
        while (s.home[b] == unknown_home) : (hops += 1) {
            assert(hops < nb);
            s.home[b] = h;
            if (b == h) break;
            const up = s.in.an.idom[b];
            if (up == none or up == b) break;
            b = up;
        }
        assert(s.home[b0] == h);
        return h;
    }

    fn rule(s: *const Scan, v: Mir.Value) bool {
        const in = s.in;
        assert(in.an.rv(v) == v); // an alias carries its target's answer
        const def = in.mir.valueDef(v);
        if (def != .inst_result) return s.sv(v);
        const inst = def.inst_result;
        const blk = in.an.def_block[@backingInt(v)];
        if (blk == none) return false;
        assert(blk < in.an.nb);
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
                for (0..d.count) |k| {
                    const p = in.mir.phiPair(inst, @intCast(k));
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
                .ternary => unreachable, // `.select`, the one ternary opcode, returned above
                .phi, .branch, .jump, .call => false,
                // §3.2.2 array storage is per evaluation: a setup root is one
                // `Setup` scalar, and an array version is not one.
                // ponytail: an invariant array (an `analog initial` table) is
                // recomputed per eval; the upgrade is a `[N]f64` Setup field.
                .anew, .load, .store => false,
            },
        }
    }
};

/// Returns the fixpoint's value, block and loop-header flags (`home` and
/// `moved` stay empty), every slice in `in.arena`. Asserts that `in.an` is a
/// full `Analysis.build`.
pub fn solve(in: Input, placing: Placing) Error!setup.Invariance {
    const a = in.arena;
    const nb = in.an.nb;
    const nv = in.an.nv;
    assert(in.an.def_block.len == nv);
    const cds = try setup.controlDeps(in);
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
    // Bound: every round but the last lowers one of the `nv` value or `nb`
    // block flags, so at most `nv + nb + 1` rounds.
    var rounds: usize = 0;
    while (true) : (rounds += 1) {
        assert(rounds <= @as(usize, nv) + nb);
        var changed = false;
        // Loops with a per-eval branch, and everything they can reach.
        @memset(s.varying, false);
        for (0..nb) |bi| {
            const c = setup.branchCond(in, @intCast(bi)) orelse continue;
            const h = in.an.loop_of[bi];
            if (h != none and !s.sv(c)) s.varying[h] = true;
        }
        @memset(reach, false);
        for (0..nb) |bi| if (s.varying[bi]) {
            reach[bi] = true;
            stack.appendAssumeCapacity(@intCast(bi));
        };
        while (stack.pop()) |b| for (in.an.succsOf(b)) |x| {
            if (reach[x]) continue;
            reach[x] = true;
            stack.appendAssumeCapacity(x);
        };
        // Placeable blocks, and the initial-step else arms.
        for (0..nb) |bi| {
            var ok = !(placing == .placing and reach[bi]);
            var ie = false;
            for (cds.of(@intCast(bi))) |d| {
                const c = setup.branchCond(in, d.branch).?;
                if (initCond(in, c)) {
                    if (d.edge == .else_edge) {
                        ie = true;
                        ok = false;
                    }
                } else if (!s.sv(c)) ok = false;
                if (!s.plc[d.branch]) ok = false;
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
            // An alias carries its target's answer.
            const ok = if (in.an.rv(v) != v) s.sv(v) else s.rule(v);
            if (ok) continue;
            s.val[i] = false;
            changed = true;
        }
        if (!changed) break;
    }
    assert(s.val.len == nv);
    assert(s.plc.len == nb);
    assert(stack.items.len == 0);
    return .{ .invariant = s.val, .placeable = s.plc, .loop_varying = s.varying };
}

/// Fills `r.home`, `r.moved` and `r.moved_off`: for each invariant value
/// outside a placeable block, the nearest placeable dominator `setup`
/// computes it in. Asserts that `r` came from `solve(.placing)` over `in`.
pub fn fillHomes(in: Input, r: *setup.Invariance) Error!void {
    const a = in.arena;
    assert(r.invariant.len == in.an.nv);
    assert(r.placeable.len == in.an.nb);
    assert(r.loop_varying.len == in.an.nb);
    const s: Scan = .{ .in = in, .val = r.invariant, .plc = r.placeable, .varying = r.loop_varying, .init_else = &.{}, .home = try a.alloc(u32, in.an.nb) };
    @memset(s.home, unknown_home);
    r.home = try a.alloc(u32, in.an.nv);
    @memset(r.home, none);
    r.moved_off = try a.alloc(u32, in.an.nb + 1);
    @memset(r.moved_off, 0);
    var n: u32 = 0;
    for (Mir.Value.first_dynamic..in.an.nv) |i| {
        const v: Mir.Value = @fromBackingInt(@intCast(i));
        const b = in.an.def_block[i];
        if (!r.invariant[i] or b == none or r.placeable[b] or in.an.rv(v) != v) continue;
        r.home[i] = s.homeOf(b);
        // `Scan.rule` admits a value outside a placeable block only through
        // `speculable`, which requires a home.
        assert(r.home[i] != none);
        r.moved_off[r.home[i] + 1] += 1;
        n += 1;
    }
    for (0..in.an.nb) |b| r.moved_off[b + 1] += r.moved_off[b];
    r.moved = try a.alloc(Mir.Value, n);
    const fill = try a.dupe(u32, r.moved_off[0..in.an.nb]);
    for (r.home, 0..) |h, i| if (h != none) {
        r.moved[fill[h]] = @fromBackingInt(@intCast(i));
        fill[h] += 1;
    };
    assert(r.moved_off[in.an.nb] == n);
}

/// Returns whether call `d`'s value is a function of the `Model` row (its
/// card and `temperature__`) alone, which `setup` computes into `Model.su`:
/// §9.10/§9.15/§9.19 and the pure math functions. An allowlist: a callee not
/// here is per-eval. §6.3.6 `$mfactor` is an `Instance` field, so not here:
/// instances sharing a row may differ in it.
pub fn callInvariant(in: Input, d: Call) bool {
    const r = switch (d.callee) {
        .@"$temperature", .@"$vt", .@"$param_given", .@"$port_connected" => true,
        // §9.15 Table 9-27: every literal name but `iteration`, which moves
        // with each Newton step, and `dt`, with each timepoint. `tnom` is a
        // Model field the host writes with the card; a published homotopy
        // knob is invariant within a solve, and the host re-runs `setup`
        // after writing one (`setup_simparams` lists which).
        .@"$simparam" => !Lowered.simparamIsRuntime(input.strArg(in, d.args, 0) orelse return false),
        // IEEE 1364 §17.11 math and the §9.11/§9.12.1 conversions: pure.
        .@"$sqrt", .@"$exp", .@"$expm1", .@"$ln", .@"$ln1p", .@"$log", .@"$log10", .@"$floor", .@"$ceil" => true,
        .@"$sin", .@"$cos", .@"$tan", .@"$asin", .@"$acos", .@"$atan" => true,
        .@"$sinh", .@"$cosh", .@"$tanh", .@"$asinh", .@"$acosh", .@"$atanh" => true,
        .@"$pow", .@"$hypot", .@"$atan2", .@"$rtoi", .@"$itor", .@"$clog2" => true,
        else => false, // else: an ALLOWLIST — every other callee reads the solve, the time or state the host moves, until shown otherwise
    };
    if (d.callee == .@"$mfactor") assert(!r); // an `Instance` field
    if (d.callee == .@"$abstime") assert(!r); // moves with every timepoint
    return r;
}

// ---- private ----

/// §5.10.2 `initial_step` with no analysis list, or §5.2.1 `analog initial`:
/// the condition `setup` treats as true. A qualified `initial_step("tran")`
/// is not one: in DC it keeps its initializer, so it is not a card function.
fn initCond(in: Input, cond: Mir.Value) bool {
    assert(@backingInt(cond) < in.an.nv);
    const def = in.mir.valueDef(in.an.rv(cond));
    if (def != .inst_result or in.mir.instOp(def.inst_result) != .call) return false;
    const d = in.mir.instData(def.inst_result).call;
    return switch (d.callee) {
        .analog_initial => true,
        .initial_step => d.args.len == 0,
        else => false, // else: every other callee is not the §5.10.2 first-point flag
    };
}
