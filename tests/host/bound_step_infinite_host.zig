//! Emitted §9.17.2 `$bound_step` -> the step bound a host reads from
//! `Instance.bound_step` after `updateState`. An infinite argument is
//! non-negative and bounds nothing: alone it publishes +inf, and beside
//! $bound_step(2n) the smallest active argument, 2e-9, wins.
//! Device: bound_step_infinite_is_no_bound.va (V(c) selects the second call).
//! device tests/verilog-a/ch09_system_tasks/bound_step_infinite_is_no_bound.va

const std = @import("std");
const contract = @import("contract");
const D = @import("device");
const n_u = @typeInfo(D.U).@"enum".field_names.len;
const S = contract.RefFamily(f64, &@as([n_u]u8, @splat(contract.no_lane)), .{});

fn published(vc: f64) f64 {
    var model: D.Model = .{};
    if (@hasDecl(D, "setup")) D.setup(S, &model);
    var inst: D.Instance = .{};
    if (@hasDecl(D, "setupInstance")) D.setupInstance(&model, &inst);
    var state = D.initState(&model, &inst);
    var x: [n_u]f64 = @splat(0.0);
    x[@backingInt(D.U.c)] = vc;
    const sim: contract.SimState = .{ .t = 1e-9, .dt = 1e-9, .kind = .tran };
    _ = D.eval(S, &x, &model, &inst, sim);
    _ = D.updateState(S, &model, &inst, x, &state, sim);
    return inst.bound_step;
}

test "§9.17.2 an infinite $bound_step argument bounds nothing" {
    try std.testing.expectEqual(std.math.inf(f64), published(0.0));
    try std.testing.expectEqual(@as(f64, 2e-9), published(1.0));
}
