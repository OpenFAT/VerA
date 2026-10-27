//! `.v` contract devices built by `vera --emit-so` (LLVM, so linked against
//! the prebuilt engine, `sim/rt/engine.zig`) against the same devices
//! compiled here whole: the same transient (`tests/host/vdev_dyn.zig`) must keep
//! the same output levels, ramps and next events at every point. v_count's
//! outputs move on its own clock, v_a2d's on input crossings; v_buf's on
//! every input edge. A device that loaded nothing or ran no point would
//! hash the start value, so that is refused too.
const std = @import("std");
const options = @import("vdev_so_options");
const vdyn = @import("vdev_dyn");

fn same(comptime name: []const u8, comptime D: type) !void {
    var lib = try @import("dynlib").DynLib.open(@field(options, name));
    defer lib.close();
    const run = lib.lookup(*const fn (u64) callconv(.c) u64, "vdev_run") orelse return error.MissingSymbol;
    const steps = 400;
    const want = vdyn.Run(D).run(steps);
    try std.testing.expect(want != vdyn.Run(D).run(0));
    try std.testing.expectEqual(want, run(steps));
}

test "a device on the prebuilt engine runs as the whole engine does" {
    try same("v_count", @import("v_count"));
    try same("v_a2d", @import("v_a2d"));
    try same("v_buf", @import("v_buf"));
}
