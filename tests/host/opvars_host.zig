//! The operating-point variables a device reports (`contract` `op_vars` and
//! `opVars`): OSDI's opvars, the module-scope variables with a §2.9.2 `desc`
//! (§3.2.1's output variables). Oracle: the design's equations worked by hand
//! at two bias points (ir = V(a, c)/r, g = d(ir)/dV(a) = 1/r, region 2 above
//! 0.5 V and 1 below, idle never assigned), and the declaration order of the
//! variables that carry a `desc` (`units` alone, or no attribute, is none).
//! device tests/host/output_variables_desc_reported.va

const std = @import("std");
const contract = @import("contract");
const D = @import("device");

const n_u = @typeInfo(D.U).@"enum".field_names.len;
const lanes = blk: {
    var out: [n_u]u8 = undefined;
    for (&out, 0..) |*lane, i| lane.* = i;
    break :blk out;
};
/// Every unknown in a lane, as `eval`'s family: a `ddx` reads its partial.
const Dual = contract.RefFamily(f64, &lanes, .{});
/// No lanes: a `ddx` reads 0.
const Val = contract.RefFamily(f64, &@as([n_u]u8, @splat(contract.no_lane)), .{});

fn at(va: f64) [n_u]f64 {
    var x: [n_u]f64 = @splat(0.0);
    x[@backingInt(D.U.a)] = va;
    return x;
}

/// A card and instance at the defaults (r = 1 kohm), prepared in the order
/// `contract` fixes: `derive`, `setup`, `setupInstance`.
fn card() struct { m: D.Model, inst: D.Instance } {
    var m: D.Model = .{};
    if (@hasDecl(D, "derive")) D.derive(Val, &m);
    if (@hasDecl(D, "setup")) D.setup(Val, &m);
    var inst: D.Instance = .{};
    if (@hasDecl(D, "setupInstance")) D.setupInstance(&m, &inst);
    return .{ .m = m, .inst = inst };
}

test "op_vars names the desc-carrying module variables, in declaration order" {
    const want = [_][]const u8{ "ir", "g", "region", "idle" };
    try std.testing.expectEqual(want.len, D.op_vars.len);
    for (want, D.op_vars) |w, got| try std.testing.expectEqualStrings(w, got);
}

test "opVars reports each variable's end-of-block value at x" {
    const c = card();
    const hi = D.opVars(Dual, at(1.0), &c.m, &c.inst, .{});
    try std.testing.expectApproxEqRel(1e-3, hi[0], 1e-15);
    try std.testing.expectApproxEqRel(1e-3, hi[1], 1e-15);
    try std.testing.expectEqual(2.0, hi[2]);
    try std.testing.expectEqual(0.0, hi[3]);
    // The other arm of the `if`, and a current that follows the bias.
    const lo = D.opVars(Dual, at(0.25), &c.m, &c.inst, .{});
    try std.testing.expectApproxEqRel(2.5e-4, lo[0], 1e-15);
    try std.testing.expectApproxEqRel(1e-3, lo[1], 1e-15);
    try std.testing.expectEqual(1.0, lo[2]);
    try std.testing.expectEqual(0.0, lo[3]);
}

test "opVars with a value-only family reads a ddx as 0 and every value unchanged" {
    const c = card();
    const v = D.opVars(Val, at(1.0), &c.m, &c.inst, .{});
    try std.testing.expectApproxEqRel(1e-3, v[0], 1e-15);
    try std.testing.expectEqual(0.0, v[1]);
    try std.testing.expectEqual(2.0, v[2]);
}
