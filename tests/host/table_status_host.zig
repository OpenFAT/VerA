//! The `*const Instance` entries of a device whose core writes `Instance`
//! (§9.21.1 first-call table samples) beside a §9.7.3 status site: `noisePsd`
//! and `acStim` run the core on a copy (`codegen/setup.zig` `probeInstance`),
//! compile against a const instance, and leave the caller's untouched.
//! The device is tests/conformance/tests/verilog-a/ch09_system_tasks/table_status.va; `zig build test` emits it and runs this.
//! device tests/verilog-a/ch09_system_tasks/table_status.va

const std = @import("std");
const contract = @import("contract");
const D = @import("device");

const n_u = contract.nU(D);
const S0 = contract.RefFamily(f64, &@as([n_u]u8, @splat(contract.no_lane)), .{});

test "noisePsd and acStim take a *const Instance and leave it untouched" {
    var m: D.Model = .{};
    var inst: D.Instance = .{};
    _ = D.initState(&m, &inst);
    if (@hasDecl(D, "setup")) D.setup(S0, &m);
    if (@hasDecl(D, "setupInstance")) D.setupInstance(&m, &inst);
    const ci: *const D.Instance = &inst;
    var xv: [n_u]f64 = @splat(0.0);
    xv[@backingInt(D.U.a)] = 0.5;
    const psd = D.noisePsd(S0, xv, &m, ci, .{});
    try std.testing.expectEqual(@as(f64, 4e-21), psd[0].white);
    const ac = D.acStim(S0, xv, &m, ci, .{});
    try std.testing.expectEqual(@as(usize, 1), ac.len);
    // The first-call table sampled into the probe copy, not the caller's.
    try std.testing.expect(!inst.table_ready[0]);
    try std.testing.expectEqual(@as(u32, 0), inst.vera_status__);
}
