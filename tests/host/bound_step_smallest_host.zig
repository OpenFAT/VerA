//! §9.17.2 "the smallest $bound_step() argument currently active": runs
//! bound_step_smallest_active_wins.va's updateState at two biases and reads
//! the bound a host would use for the next step. At V(p,n) = 1 the calls
//! 3n, 1n and 2n all run (1e-9); at V(p,n) = 0 the 1n call's guard is false
//! (2e-9). The host runs the compiler's output, not its text.
//! device tests/verilog-a/ch09_system_tasks/bound_step_smallest_active_wins.va

const std = @import("std");
const contract = @import("contract");
const D = @import("device");

const n_u = @typeInfo(D.U).@"enum".field_names.len;
const S = contract.RefFamily(f64, &@as([n_u]u8, @splat(contract.no_lane)), .{});

fn boundAt(v: f64) f64 {
    const model: D.Model = .{};
    var inst: D.Instance = .{};
    var state = D.initState(&model, &inst);
    var x: [n_u]f64 = @splat(0.0);
    x[@backingInt(D.U.p)] = v;
    const sim: contract.SimState = .{ .t = 1e-9, .dt = 1e-9, .kind = .tran };
    _ = D.updateState(S, &model, &inst, x, &state, sim);
    return inst.bound_step;
}

test "§9.17.2 the smallest active $bound_step argument is the bound" {
    try std.testing.expectEqual(@as(f64, 1e-9), boundAt(1.0));
    try std.testing.expectEqual(@as(f64, 2e-9), boundAt(0.0));
}
