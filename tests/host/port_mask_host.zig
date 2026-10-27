//! §9.19 `$port_connected` on a top-level device reads the host-written
//! `Model.port_connected__` mask (tests/conformance/tests/verilog-a/ch09_system_tasks/port_mask.va).
//! device tests/verilog-a/ch09_system_tasks/port_mask.va

const std = @import("std");
const contract = @import("contract");
const D = @import("device");

const n_u = contract.nU(D);
const S0 = contract.RefFamily(f64, &@as([n_u]u8, @splat(contract.no_lane)), .{});

fn gds(m: *D.Model) f64 {
    if (@hasDecl(D, "setup")) D.setup(S0, m);
    var inst: D.Instance = .{};
    if (@hasDecl(D, "setupInstance")) D.setupInstance(m, &inst);
    var x: [n_u]f64 = @splat(0.0);
    x[@backingInt(D.U.d)] = 1.0;
    const r = D.eval(S0, &x, m, &inst, .{});
    return r[@backingInt(D.U.d)].v;
}

test "every port connected by default" {
    var m: D.Model = .{};
    try std.testing.expectEqual(std.math.maxInt(u64), m.port_connected__);
    // temp connected (2e-3) + sub connected (1e-3), at V(d,s) = 1.
    try std.testing.expectEqual(@as(f64, 3e-3), gds(&m));
}

test "a 4-terminal card: sub and temp not connected" {
    var m: D.Model = .{};
    m.port_connected__ = 0b001111; // d g s b; sub (4) and temp (5) cleared
    try std.testing.expectEqual(@as(f64, 1e-3), gds(&m));
}

test "only temp cleared" {
    var m: D.Model = .{};
    m.port_connected__ = ~(@as(u64, 1) << 5);
    try std.testing.expectEqual(@as(f64, 2e-3), gds(&m));
}
