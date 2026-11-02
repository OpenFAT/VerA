//! `acDyn`'s two promises every host leans on, over any device that declares
//! `ac_dyn_slots` (build.zig runs it on the absdelay, laplace and zi AC
//! fixtures):
//!
//!  - ω = 0 is DC, exactly: what the operators' DC forms (§4.5.7 absdelay
//!    returns its input, §4.5.11 H(0), §4.5.12 H(1)) put in `eval` under
//!    `.dc`, `eval` under `.ac` leaves out and `acDyn(0)` returns, to the bit,
//!    with no imaginary part. A pole-zero host takes the DC gain this way.
//!  - lanes are frequencies: `acDyn` with `F = @Vector(4, f64)` fills each
//!    lane with what the scalar call at that lane's ω returns, bit for bit.
//!
//! The device is evaluated at its operating point V(in) = 0.5.
//! device tests/verilog-a/ch04_expressions/absdelay_ac_phase.va
//! device tests/verilog-a/ch04_expressions/laplace_ac_response.va
//! device tests/verilog-a/ch04_expressions/zi_ac_response.va

const std = @import("std");
const contract = @import("contract");
const D = @import("device");

const n_u = @typeInfo(D.U).@"enum".field_names.len;
const Dual = contract.RefFamily(f64, &lanes, .{});
const lanes: [n_u]u8 = std.simd.iota(u8, n_u);
const C = std.math.Complex;

fn bias() [n_u]f64 {
    var x: [n_u]f64 = @splat(0.0);
    x[@backingInt(D.U.in)] = 0.5;
    return x;
}

test "acDyn at ω = 0 is the DC partial eval leaves out under .ac" {
    const model: D.Model = .{};
    var inst: D.Instance = .{};
    const x = bias();
    const g_dc = D.eval(Dual, &x, &model, &inst, .{ .kind = .dc });
    const g_ac = D.eval(Dual, &x, &model, &inst, .{ .kind = .ac });
    var out: [D.ac_dyn_slots.len]C(f64) = undefined;
    D.acDyn(f64, &model, &inst, &x, .{ .kind = .ac }, 0.0, &out);
    inline for (D.ac_dyn_slots, out) |s, v| {
        const r = s / n_u;
        const u = s % n_u;
        try std.testing.expectEqual(g_dc[r].ddxAt(u), g_ac[r].ddxAt(u) + v.re);
        try std.testing.expectEqual(@as(f64, 0.0), @abs(v.im));
    }
}

test "acDyn over a vector of frequencies is the scalar call per lane" {
    const model: D.Model = .{};
    var inst: D.Instance = .{};
    const x = bias();
    const ws = [4]f64{ 0.0, 2.0 * std.math.pi * 1e6, 2.0 * std.math.pi * 250e3, 1.0 };
    const V = @Vector(4, f64);
    var vec: [D.ac_dyn_slots.len]C(V) = undefined;
    D.acDyn(V, &model, &inst, &x, .{ .kind = .ac }, ws, &vec);
    inline for (ws, 0..) |w, i| {
        var one: [D.ac_dyn_slots.len]C(f64) = undefined;
        D.acDyn(f64, &model, &inst, &x, .{ .kind = .ac }, w, &one);
        for (vec, one) |v, o| {
            try std.testing.expectEqual(o.re, v.re[i]);
            try std.testing.expectEqual(o.im, v.im[i]);
        }
    }
}
