//! Emitted §6.3/§6.4.2 paramset bindings -> host card changes and shape checks.
//! At V(p)=1/2, numeric gain 4 plus string gain 5 plus single-member gain
//! 2*drive gives total current (9+2*drive)/2: 7.5 A at drive=3 and 8.5 A at 4.
//! Changing a selection input requires re-elaboration; changing drive alone
//! preserves the selected module and must continue to execute through derive.
//! device tests/verilog-a/ch06_hierarchy/paramset_outer_defparam_shape.va

const std = @import("std");
const contract = @import("contract");
const D = @import("device");
const n_u = @typeInfo(D.U).@"enum".field_names.len;
const S = contract.RefFamily(f64, &@as([n_u]u8, @splat(contract.no_lane)), .{});

fn current(card: *const D.Model) f64 {
    var model = card.*;
    var inst: D.Instance = .{};
    var x: [n_u]f64 = @splat(0.0);
    x[@backingInt(D.U.p)] = 0.5;
    if (@hasDecl(D, "setup")) D.setup(S, &model);
    const result = D.eval(S, &x, &model, &inst, .{});
    return result[@backingInt(D.U.p)].v;
}

test "paramset selections remain fixed while a single-member value follows a host write" {
    var model: D.Model = .{};
    D.derive(S, &model);
    try std.testing.expectEqual(@as(?[]const u8, null), D.checkShape(&model));
    try std.testing.expectEqual(@as(f64, 7.5), current(&model));

    model.drive = 4.0;
    D.derive(S, &model);
    try std.testing.expectEqual(@as(?[]const u8, null), D.checkShape(&model));
    try std.testing.expectEqual(@as(f64, 8.5), current(&model));
}

test "numeric and string selection inputs require re-elaboration after a host write" {
    var numeric: D.Model = .{};
    numeric.base = 7.0;
    D.derive(S, &numeric);
    try std.testing.expectEqualStrings("base", D.checkShape(&numeric).?);

    // The guard conservatively freezes the input, even when the new value
    // stays in the same bin; the host must recompile to reselect the member.
    numeric.base = 3.0;
    D.derive(S, &numeric);
    try std.testing.expectEqualStrings("base", D.checkShape(&numeric).?);

    var text: D.Model = .{};
    text.mode = "high";
    D.derive(S, &text);
    try std.testing.expectEqualStrings("mode", D.checkShape(&text).?);
}

test "an explicit integer shape uses its effective low 32 bits" {
    var model: D.Model = .{};
    // A host writes the ABI's i64 carrier. The declared integer sees 1,
    // so selection stays in its zero-current member and needs no rebuild.
    // This asserts selection only, not a raw parameter read by the device.
    model.choice = 4294967297;
    D.derive(S, &model);
    try std.testing.expectEqual(@as(?[]const u8, null), D.checkShape(&model));
    try std.testing.expectEqual(@as(f64, 7.5), current(&model));

    model.choice = 2;
    D.derive(S, &model);
    try std.testing.expectEqualStrings("choice", D.checkShape(&model).?);
}
