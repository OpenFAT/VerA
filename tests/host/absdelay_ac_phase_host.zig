//! §4.5.7 absdelay's small-signal slot, assembled the way a host assembles
//! it: `contract.acDynSlots` says that under `.ac` the device's `eval` and `q`
//! leave out every partial through the delay, and `acDyn` supplies it, so
//!
//!     A(ω)[slot] = G[slot] + jω·C[slot] + acDyn[slot]
//!
//! The device is absdelay_ac_phase.va, at V(in) = 0.75. Row `a` is
//! 2·V(in) + absdelay(V(in), 1n) and row `d` is ddt(1n·absdelay(V(in), 1n)).
//! At the operating point (`.dc`) the delay is transparent, "absdelay()
//! returns the value of its input", so ∂a/∂V(in) = 2 + 1 = 3 and
//! ∂q_d/∂V(in) = 1n. Under `.ac` the flat 2 stays in G and the delay moves to
//! `acDyn`: at 125 MHz, θ = ωτ = π/4, A[a, in] = 2 + e^(−jπ/4) and
//! A[d, in] = jω·1n·e^(−jπ/4) = (π/4)(sin θ + j·cos θ). A device that kept
//! the transparent partial in G under `.ac` would read 3 + e^(−jπ/4): the
//! delay counted twice. `zig build test` emits the device and runs this file.
//! device tests/verilog-a/ch04_expressions/absdelay_ac_phase.va

const std = @import("std");
const contract = @import("contract");
const D = @import("device");

const n_u = @typeInfo(D.U).@"enum".field_names.len;
const Dual = contract.RefFamily(f64, &lanes, .{});
const lanes = blk: {
    var l: [n_u]u8 = undefined;
    for (&l, 0..) |*e, u| e.* = u;
    break :blk l;
};

const in = @backingInt(D.U.in);
const a = @backingInt(D.U.a);
const d = @backingInt(D.U.d);

fn slot(r: usize, c: usize) usize {
    for (D.ac_dyn_slots, 0..) |s, k| if (s == r * n_u + c) return k;
    unreachable;
}

test "§4.5.7 under .ac the delay's partial leaves G and C for acDyn" {
    const model: D.Model = .{};
    var inst: D.Instance = .{};
    var x: [n_u]f64 = @splat(0.0);
    x[in] = 0.75;

    const dc: contract.SimState = .{ .kind = .dc };
    const ac: contract.SimState = .{ .kind = .ac };
    const g_dc = D.eval(Dual, &x, &model, &inst, dc);
    const g_ac = D.eval(Dual, &x, &model, &inst, ac);
    const q_dc = contract.qRows(D, Dual, D.q(Dual, &x, &model, &inst, dc));
    const q_ac = contract.qRows(D, Dual, D.q(Dual, &x, &model, &inst, ac));
    try std.testing.expectEqual(@as(f64, 3.0), g_dc[a].ddxAt(in));
    try std.testing.expectEqual(@as(f64, 2.0), g_ac[a].ddxAt(in));
    try std.testing.expectEqual(@as(f64, 1e-9), q_dc[d].ddxAt(in));
    try std.testing.expectEqual(@as(f64, 0.0), q_ac[d].ddxAt(in));
    // The values do not move: the operating point is the same point.
    try std.testing.expectEqual(g_dc[a].v, g_ac[a].v);

    const w = 2.0 * std.math.pi * 125e6;
    var out: [D.ac_dyn_slots.len]std.math.Complex(f64) = undefined;
    D.acDyn(f64, &model, &inst, &x, ac, w, &out);
    const h = std.math.sqrt1_2;
    const aa = out[slot(a, in)];
    try std.testing.expectApproxEqAbs(2.0 + h, g_ac[a].ddxAt(in) + aa.re, 1e-12);
    try std.testing.expectApproxEqAbs(-h, aa.im, 1e-12);
    // C is real, so jω·C lands on the imaginary part.
    const dd = out[slot(d, in)];
    try std.testing.expectApproxEqAbs(std.math.pi / 4.0 * h, g_ac[d].ddxAt(in) + dd.re, 1e-12);
    try std.testing.expectApproxEqAbs(std.math.pi / 4.0 * h, w * q_ac[d].ddxAt(in) + dd.im, 1e-12);
}
