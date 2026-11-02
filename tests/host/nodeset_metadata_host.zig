//! Emitted §3.6.3.2 nodeset metadata -> host-selected initial values and
//! evaluated cubic residuals. A null array element supplies no nodeset;
//! an explicit zero supplies zero, even when the host's fallback is 7 V.
//! For f(V)=(V-1)(V-2)(V-3), f(2.75)=-21/64, f(7)=120 and f(0)=-6.
//! These are exact binary values. The host runs the compiler's output,
//! rather than inspecting generated text. Invalid constant initializers
//! are covered by the neighbouring nodeset_not_constant.va fixture.
//! device tests/verilog-a/ch03_data_types/nodeset_02_nodeset_bus_null_element.va

const std = @import("std");
const contract = @import("contract");
const D = @import("device");

const n_u = @typeInfo(D.U).@"enum".field_names.len;
const lanes = blk: {
    var out: [n_u]u8 = undefined;
    for (&out, 0..) |*lane, i| lane.* = i;
    break :blk out;
};
const Dual = contract.RefFamily(f64, &lanes, .{});
// The device ABI encodes '[' and ']' as Z5b and Z5d in enum fields.
const a = @backingInt(D.U.nZ5b0Z5d);
const b = @backingInt(D.U.nZ5b1Z5d);
const c = @backingInt(D.U.nZ5b2Z5d);
const g = @backingInt(D.U.g);

test "§3.6.3.2 null nodeset preserves the host fallback; explicit zero replaces it" {
    try std.testing.expectEqual(@as(?f64, 2.75), D.u_nodeset[a]);
    try std.testing.expectEqual(@as(?f64, null), D.u_nodeset[b]);
    try std.testing.expectEqual(@as(?f64, 0.0), D.u_nodeset[c]);
    try std.testing.expectEqual(@as(?f64, null), D.u_nodeset[g]);

    var x: [n_u]f64 = @splat(7.0);
    for (D.u_nodeset, &x) |hint, *value| if (hint) |v| {
        value.* = v;
    };
    x[g] = 0.0;
    try std.testing.expectEqual(@as(f64, 2.75), x[a]);
    try std.testing.expectEqual(@as(f64, 7.0), x[b]);
    try std.testing.expectEqual(@as(f64, 0.0), x[c]);

    const model: D.Model = .{};
    const inst: D.Instance = .{};
    const residual = D.eval(Dual, &x, &model, &inst, .{ .kind = .dc });
    try std.testing.expectEqual(@as(f64, -0.328125), residual[a].v);
    try std.testing.expectEqual(@as(f64, 120.0), residual[b].v);
    try std.testing.expectEqual(@as(f64, -6.0), residual[c].v);
}
