//! A04 — §4.5 stateful operators across a REJECTED TIMESTEP.
//!
//! WHY THIS IS NOT A `.va` FIXTURE. A rejected step is a sequence of host
//! calls, not a waveform: the driver evaluates a trial point, writes the
//! operators' accepted-step state, then decides the local error is too large,
//! REVERTS, and re-solves the same interval with a smaller dt. The `//!`
//! directive language walks `//! time` forward and calls `updateState` once per
//! entry, so it cannot express the revert at all. tests/limiter_host.zig
//! already established the pattern for exactly this problem on §4.5.15's
//! limiting state ("limiter state advances by generation and reverts a
//! rejected attempt") and tests/table_snapshot_host.zig for §9.21's snapshot;
//! this is their §4.5 operator-history counterpart.
//!
//! The subject is `slew` (rollback_a04_rollback_ops.va), an operator that
//! keeps its history in the device. idt and ddt keep none: they are host
//! unknowns (§4.5.2), whose history the host's integrator owns and reverts.
//!
//! WHAT THE LRM REQUIRES. §4.5.9 bounds the output's rate of change over the
//! ACCEPTED waveform, and the accepted output at t = 1ns is a property of the
//! circuit, not of how many trial points were discarded on the way there.
//! §4.5.15 says the same from the other side: "It is important to ensure that
//! all analog operators are evaluated every iteration of a simulation to ensure
//! that the internal state is maintained ... These restrictions help prevent
//! usage which could cause the internal state to be corrupted or become
//! out-of-date."
//!
//! So the requirement this file encodes is: after a trial step to t = 2ns is
//! REJECTED and the step re-taken to t = 1ns, every §4.5 operator shall read
//! exactly what it would have read had the 2ns attempt never happened.
//!
//! THE HAND DERIVATION. V(p) is driven to t/1ns volts, twice the 0.5 V/ns
//! limit, so the output rises exactly 0.5 per nanosecond from its last
//! accepted value.
//!
//!   step            t      dt     slew    why
//!   dc              0       0     0.0     §4.5.9 "In DC analysis, slew()
//!                                         simply passes the value of the
//!                                         destination to its output"
//!   trial (reject)  2ns   2ns     1.0     0 + 0.5e9 · 2ns
//!   REVERT           -      -       -     accepted state is the dc one
//!   retry (accept)  1ns   1ns     0.5     0 + 0.5e9 · 1ns, NOT 1.0 (the
//!                                         discarded attempt's output, which
//!                                         the input 1.0 does not clamp)
//!   next  (accept)  2ns   1ns     1.0     0.5 + 0.5e9 · 1ns
//!
//! The last row is what makes this a test rather than a tautology: the run
//! reaches t = 2ns twice, once on a discarded attempt and once for real, and
//! the output there is 1.0 both times. An implementation whose history is
//! path-dependent reads a different number the second time.
//!
//! `stateCtl` commits and reverts every field `updateState` advances,
//! `State.t_prev` included: a revert that left t_prev at the discarded 2ns
//! would make the retry's dt negative. tests/host/revert_host.zig asserts the same
//! for every other device-held history. `zig build test` emits the device from
//! rollback_a04_rollback_ops.va and runs this file.
//! device tests/verilog-a/ch04_expressions/rollback_a04_rollback_ops.va

const std = @import("std");
const contract = @import("contract");
const D = @import("device");

const n_u = @typeInfo(D.U).@"enum".field_names.len;

/// The reference family with no lanes: nothing here asks for a Jacobian.
const S = contract.RefFamily(f64, &@as([n_u]u8, @splat(contract.no_lane)), .{});

/// The slew output, read from row `p` and divided back out by the 1e-3 scale
/// the .va applies.
fn read(model: *const D.Model, inst: *D.Instance, x: [n_u]f64, sim: contract.SimState) f64 {
    const r: [n_u]S.Of(0) = D.eval(S, &x, model, inst, sim);
    return r[@backingInt(D.U.p)].v / 1.0e-3;
}

/// Drive the unknowns the way the .va's ramp asks: V(p) = t/1ns volts.
fn bias(t_ns: f64) [n_u]f64 {
    var x: [n_u]f64 = @splat(0.0);
    x[@backingInt(D.U.p)] = t_ns;
    return x;
}

test "§4.5.9 the output at an accepted time does not depend on rejected attempts" {
    const model: D.Model = .{};
    var inst: D.Instance = .{};
    var state = D.initState(&model, &inst);
    var sim: contract.SimState = .{};

    // ---- the operating point -------------------------------------------
    sim.t = 0.0;
    sim.dt = 0.0;
    const x0 = bias(0.0);
    // §4.5.9 "In DC analysis, slew() simply passes the value of the
    // destination to its output" — V(p,n) = 0 here.
    try std.testing.expectApproxEqAbs(0.0, read(&model, &inst, x0, sim), 1e-12);
    _ = D.updateState(S, &model, &inst, x0, &state, sim);
    _ = D.stateCtl(&model, &inst, &state, .commit);

    // ---- a trial step to 2ns that the driver will reject ----------------
    sim.t = 2.0e-9;
    sim.dt = 2.0e-9;
    const x2 = bias(2.0);
    // 0.5 V/ns over 2ns is 1.0, under the input's 2.0.
    try std.testing.expectApproxEqAbs(1.0, read(&model, &inst, x2, sim), 1e-9);
    _ = D.updateState(S, &model, &inst, x2, &state, sim);

    // ---- REJECTED. The driver reverts and halves the step. --------------
    _ = D.stateCtl(&model, &inst, &state, .revert);

    sim.t = 1.0e-9;
    sim.dt = 1.0e-9;
    const x1 = bias(1.0);
    // THE ASSERTION OF THIS FILE. 0 + 0.5 V/ns · 1ns = 0.5. Not 1.0, which is
    // what history left over from the discarded attempt reads (the input 1.0
    // does not clamp it).
    try std.testing.expectApproxEqAbs(0.5, read(&model, &inst, x1, sim), 1e-9);
    _ = D.updateState(S, &model, &inst, x1, &state, sim);
    _ = D.stateCtl(&model, &inst, &state, .commit);

    // ---- and the run reaches 2ns for real ------------------------------
    sim.t = 2.0e-9;
    sim.dt = 1.0e-9;
    // Same time, same circuit, different path to it: 0.5 + 0.5 = 1.0, the
    // identical number the rejected attempt produced.
    try std.testing.expectApproxEqAbs(1.0, read(&model, &inst, x2, sim), 1e-9);
}

test "§4.5.15 a revert leaves no half-advanced operator history behind" {
    // The structural half of the same rule, and the one that catches a partial
    // fix: a revert must restore the device state exactly, so a driver that
    // rejects several times in a row cannot accumulate a drift no single value
    // comparison would show. tests/limiter_host.zig asserts this same shape for
    // the limiter state (`expectEqualDeep(accepted, inst)`).

    const model: D.Model = .{};
    var inst: D.Instance = .{};
    var state = D.initState(&model, &inst);
    var sim: contract.SimState = .{};

    sim.t = 0.0;
    sim.dt = 0.0;
    _ = D.updateState(S, &model, &inst, bias(0.0), &state, sim);
    _ = D.stateCtl(&model, &inst, &state, .commit);
    const accepted = inst;
    const accepted_state = state;

    for ([_]f64{ 8.0, 4.0, 2.0 }) |t_ns| { // three rejected attempts, shrinking
        sim.t = t_ns * 1.0e-9;
        sim.dt = t_ns * 1.0e-9;
        _ = D.updateState(S, &model, &inst, bias(t_ns), &state, sim);
        _ = D.stateCtl(&model, &inst, &state, .revert);
        // Every field of Instance belongs to the device and must be restored
        // by the revert itself; time lives in the host's `SimState`.
        try std.testing.expectEqualDeep(accepted, inst);
        // `State` carries `t_prev`, which is what `dt` is measured against — a
        // revert that leaves it pointing at a discarded trial time makes the
        // next attempt's dt negative.
        try std.testing.expectEqualDeep(accepted_state, state);
    }
}
