//! IEEE 1364-2005 §5.4 wide `reg`s in a DEVICE: tests/conformance/tests/verilog-ams/ch07_mixed_signal/wide_reg_held_across_evaluations.va,
//! whose `analog initial` assigns a 72-bit `reg` (one native `u72`) and a
//! 300-bit one (ten 32-bit limbs). `updateState` keeps both whole in
//! `Instance` for the next evaluation (`wide_kernels.zig`, `analog/wide.zig`).
//! `wide_gpu.zig` compiles the same entry points for NVPTX and AMDGCN.
//! device tests/verilog-ams/ch07_mixed_signal/wide_reg_held_across_evaluations.va

const std = @import("std");
const contract = @import("contract");
const D = @import("device");

const n_u = @typeInfo(D.U).@"enum".field_names.len;
const S = contract.RefFamily(f64, &.{0}, .{});
const S0 = contract.RefFamily(f64, &@as([n_u]u8, @splat(contract.no_lane)), .{});

fn sim(initial: bool) contract.SimState {
    return .{ .t = 0, .dt = 0, .kind = .dc, .initial_step = initial, .analog_initial = initial };
}

/// The one `Instance` field of type `T`.
fn field(comptime T: type, inst: *const D.Instance) T {
    const info = @typeInfo(D.Instance).@"struct";
    inline for (info.field_names, info.field_types) |name, FT| {
        if (FT == T) return @field(inst, name);
    }
    @compileError("no Instance field of this type");
}

test "IEEE 1364 §5.4 a wide reg an analog initial block assigns is held whole" {
    var m: D.Model = .{};
    var inst: D.Instance = .{};
    var st = D.initState(&m, &inst);
    if (@hasDecl(D, "setup")) D.setup(S0, &m);
    if (@hasDecl(D, "setupInstance")) D.setupInstance(&m, &inst);
    const xv: [n_u]f64 = @splat(0.0);
    _ = D.eval(S, &xv, &m, &inst, sim(true));
    _ = D.updateState(S0, &m, &inst, xv, &st, sim(true));
    try std.testing.expectEqual(@as(u72, 0xA5_0000_0000_0000_0003), field(u72, &inst));
    // 2**299 + 5: limb 0 holds 5, limb 9 bit 11 (299 = 9 * 32 + 11).
    const big = field([10]u32, &inst);
    try std.testing.expectEqual(@as(u32, 5), big[0]);
    for (big[1..9]) |l| try std.testing.expectEqual(@as(u32, 0), l);
    try std.testing.expectEqual(@as(u32, 1 << 11), big[9]);
    // A later evaluation reads them and leaves them.
    _ = D.eval(S, &xv, &m, &inst, sim(false));
    _ = D.updateState(S0, &m, &inst, xv, &st, sim(false));
    try std.testing.expectEqual(@as(u72, 0xA5_0000_0000_0000_0003), field(u72, &inst));
    try std.testing.expectEqual(@as(u32, 1 << 11), field([10]u32, &inst)[9]);
}
