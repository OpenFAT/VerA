//! §4.5 device-held history across a REJECTED time step: `stateCtl(.revert)`
//! leaves every operator, §5.10 held variable and §9.13.1 internal seed as the
//! last accepted point left it. A discarded attempt is not an instant of the
//! waveform, so the run that rejects shall read, row for row and bit for bit,
//! what the run that never tried the step reads.
//!
//! The device is tests/conformance/tests/verilog-a/ch04_expressions/revert_ops.va, one construct per output row. Both runs
//! accept the same points; the rejecting one also tries 4ns with V(a) = -1
//! after the 1ns point, twice, reverting each time. That attempt moves every
//! row's history: it crosses 0.5 falling (cross, last_crossing), leaves
//! `above` below its threshold before a retry above it, passes timer and
//! sampling instants, steps the filters, integrators and ramps, pushes a delay
//! sample, and draws from the seed. `zig build test` emits the device and runs
//! this file.
//! device tests/verilog-a/ch04_expressions/revert_ops.va

const std = @import("std");
const contract = @import("contract");
const D = @import("device");

const n_u = @typeInfo(D.U).@"enum".field_names.len;

/// The reference family with no lanes: nothing here asks for a Jacobian.
const S = contract.RefFamily(f64, &@as([n_u]u8, @splat(contract.no_lane)), .{});

/// (t, V(a)) at each accepted point, and the attempt rejected after the second.
const points = [_][2]f64{ .{ 0, 0 }, .{ 1e-9, 1 }, .{ 2e-9, 1 }, .{ 3e-9, 0 }, .{ 4e-9, 1 } };
const trial = [2]f64{ 4e-9, -1 };

const Run = struct {
    /// Each accepted point's residual, read before its `updateState`.
    r: [points.len][n_u]f64 = undefined,
    inst: D.Instance = .{},
    state: D.State = .{},
    /// The device at the 1ns point, and again after the last revert.
    accepted: struct { D.Instance, D.State } = undefined,
    reverted: struct { D.Instance, D.State } = undefined,
};

fn run(rejects: usize) Run {
    const model: D.Model = .{};
    var out: Run = .{};
    out.state = D.initState(&model, &out.inst);
    var t_prev: f64 = 0;
    for (points, 0..) |p, k| {
        if (k == 2) {
            out.accepted = .{ out.inst, out.state };
            for (0..rejects) |_| {
                _ = D.updateState(S, &model, &out.inst, bias(trial[1]), &out.state, simAt(trial[0], t_prev, false));
                _ = D.stateCtl(&model, &out.inst, &out.state, .revert);
            }
            out.reverted = .{ out.inst, out.state };
        }
        const sim = simAt(p[0], t_prev, k == 0);
        const x = bias(p[1]);
        const r: [n_u]S.Of(0) = D.eval(S, &x, &model, &out.inst, sim);
        for (r, 0..) |v, i| out.r[k][i] = v.v;
        _ = D.updateState(S, &model, &out.inst, x, &out.state, sim);
        _ = D.stateCtl(&model, &out.inst, &out.state, .commit);
        t_prev = p[0];
    }
    return out;
}

fn simAt(t: f64, t_prev: f64, dc: bool) contract.SimState {
    return .{ .t = t, .dt = t - t_prev, .kind = if (dc) .dc else .tran, .initial_step = dc, .analog_initial = dc };
}

fn bias(a: f64) [n_u]f64 {
    var x: [n_u]f64 = @splat(0.0);
    x[@backingInt(D.U.a)] = a;
    return x;
}

fn expectRow(row: D.U) !void {
    const want = run(0);
    const got = run(2);
    for (want.r, got.r) |w, g| try std.testing.expectEqual(w[@backingInt(row)], g[@backingInt(row)]);
}

test "§4.5.8 transition" {
    try expectRow(.o_tr);
}
test "§4.5.7 absdelay" {
    try expectRow(.o_ad);
}
test "§4.5.9 slew" {
    try expectRow(.o_sl);
}
test "§4.5.11 laplace" {
    try expectRow(.o_lp);
}
test "§4.5.12 zi" {
    try expectRow(.o_zi);
}
test "§4.5.10 last_crossing" {
    try expectRow(.o_lc);
}
test "§5.10.3.1 cross-held variable" {
    try expectRow(.o_cr);
}
test "§5.10.3.2 above-held variable" {
    try expectRow(.o_ab);
}
test "§5.10.3.3 timer-held variable" {
    try expectRow(.o_tm);
}
test "§4.5.5 idtmod" {
    try expectRow(.o_im);
}
test "§9.13.1 $arandom internal seed" {
    try expectRow(.o_rn);
}
test "§9.13.1 parameter seed survives rejected draws" {
    try expectRow(.o_rp);
}
test "omitted seed numbering is unchanged by explicit seed storage" {
    // Implementation choice, not a fixed LRM stream: all non-variable seed
    // sites count toward 1+7919*k. This omitted site follows one omitted and
    // two explicit sites, so k=3 and its initial seed is 23758. The unchanged
    // IEEE uniform wrapper then yields -506541885 and 430367027. Counting
    // only omitted sites would give k=1 and change an existing trajectory.
    const got = run(0);
    try std.testing.expectEqual(@as(f64, -506541885), got.r[0][@backingInt(D.U.o_ra)]);
    try std.testing.expectEqual(@as(f64, 430367027), got.r[1][@backingInt(D.U.o_ra)]);
}
test "§9.13.1 rejected first call restores the constant seed" {
    // AMS §9.13.1 assigns 7 to the hidden seed. The independent IEEE
    // §17.9.3 derivation in arandom_constant_seed_stream.va gives these first
    // two draws. Repeated evals consume nothing; a reverted update restores
    // both the seed and the first-call flag, while a committed one advances.
    const model: D.Model = .{};
    var inst: D.Instance = .{};
    var state = D.initState(&model, &inst);
    const x = bias(-1);
    const sim = simAt(0, 0, true);
    for (0..2) |_| {
        const r: [n_u]S.Of(0) = D.eval(S, &x, &model, &inst, sim);
        try std.testing.expectEqual(@as(f64, -2146999808), r[@backingInt(D.U.o_rc)].v);
    }
    _ = D.updateState(S, &model, &inst, x, &state, sim);
    _ = D.stateCtl(&model, &inst, &state, .revert);
    const retried: [n_u]S.Of(0) = D.eval(S, &x, &model, &inst, sim);
    try std.testing.expectEqual(@as(f64, -2146999808), retried[@backingInt(D.U.o_rc)].v);
    _ = D.updateState(S, &model, &inst, x, &state, sim);
    _ = D.stateCtl(&model, &inst, &state, .commit);
    const next: [n_u]S.Of(0) = D.eval(S, &x, &model, &inst, simAt(1e-9, 0, false));
    try std.testing.expectEqual(@as(f64, 1181502348), next[@backingInt(D.U.o_rc)].v);
}
test "§4.5 a revert leaves no field of Instance or State behind" {
    const want = run(0);
    const got = run(2);
    try std.testing.expectEqualDeep(got.accepted, got.reverted);
    try std.testing.expectEqualDeep(want.inst, got.inst);
    try std.testing.expectEqualDeep(want.state, got.state);
}
