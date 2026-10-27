//! A04 — §4.5.4 idt's assert offset across a REJECTED TIMESTEP.
//!
//! The assert form keeps one piece of device history: `<n>__off`, the
//! V(s) - ic that `updateState` latches while assert is nonzero, so that once
//! assert falls the value is ic(ta) + the integral from ta. A host that runs
//! `updateState` on a trial point, finds the step rejected and calls
//! `stateCtl(.revert)` must get the offset of the last ACCEPTED point back:
//! "Once assert becomes zero, idt() returns the integral of the argument
//! starting from the last instant where assert was nonzero", and a discarded
//! trial point is not an instant of the waveform.
//!
//! THE HAND DERIVATION (device: idt_hold_revert.va, integrand 1e9,
//! ic = 7). The host solves ds/dt = 1e9 and holds s still while assert is
//! nonzero, so it hands the device these s values:
//!
//!   step            t      assert   s      off   idt    why
//!   dc              0      1        7      0     7      ic; off = 7 - 7
//!   accept          1ns    0        8      0     8      8 - 0
//!   trial (reject)  2ns    1        8      1     7      ic; off = 8 - 7
//!   REVERT          -      -        -      0     -      the 1ns point's
//!   retry (accept)  1.5ns  0        8.5    0     8.5    ta = 0: 7 + 1.5
//!
//! A revert that leaves the trial's offset reads 8.5 - 1 = 7.5 at the retry.
//!
//! `zig build test` emits the device and runs this file.
//! device tests/verilog-a/ch04_expressions/idt_hold_revert.va

const std = @import("std");
const contract = @import("contract");
const D = @import("device");

const n_u = @typeInfo(D.U).@"enum".field_names.len;

/// The reference family with no lanes: nothing here asks for a Jacobian.
const S = contract.RefFamily(f64, &@as([n_u]u8, @splat(contract.no_lane)), .{});

/// The idt value, read from row `a` and divided back out by the 1e-3 scale.
fn read(model: *const D.Model, inst: *D.Instance, x: [n_u]f64, sim: contract.SimState) f64 {
    const r: [n_u]S.Of(0) = D.eval(S, &x, model, inst, sim);
    return r[@backingInt(D.U.a)].v / 1.0e-3;
}

/// V(a) = assert, V(n) = 0, and the operator unknown s (U's last member).
fn bias(assert_: f64, s: f64) [n_u]f64 {
    var x: [n_u]f64 = @splat(0.0);
    x[@backingInt(D.U.a)] = assert_;
    x[n_u - 1] = s;
    return x;
}

fn step(model: *const D.Model, inst: *D.Instance, state: *D.State, t: f64, dt: f64, x: [n_u]f64, want: f64) !void {
    const sim: contract.SimState = .{ .t = t, .dt = dt, .kind = if (dt == 0.0) .dc else .tran };
    try std.testing.expectApproxEqAbs(want, read(model, inst, x, sim), 1e-9);
    _ = D.updateState(S, model, inst, x, state, sim);
}

test "§4.5.4 a rejected step leaves the idt assert offset as it was" {
    const model: D.Model = .{};
    var inst: D.Instance = .{};
    var state = D.initState(&model, &inst);

    try step(&model, &inst, &state, 0.0, 0.0, bias(1.0, 7.0), 7.0);
    _ = D.stateCtl(&model, &inst, &state, .commit);
    try step(&model, &inst, &state, 1.0e-9, 1.0e-9, bias(0.0, 8.0), 8.0);
    _ = D.stateCtl(&model, &inst, &state, .commit);
    const accepted = inst;

    try step(&model, &inst, &state, 2.0e-9, 1.0e-9, bias(1.0, 8.0), 7.0);
    _ = D.stateCtl(&model, &inst, &state, .revert);
    try std.testing.expectEqualDeep(accepted, inst);

    try step(&model, &inst, &state, 1.5e-9, 0.5e-9, bias(0.0, 8.5), 8.5);
}
