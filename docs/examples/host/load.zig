//! Loads the library `vera --emit-so` built and calls the one symbol its
//! `--dyn` module exported, at the operating point minimal-host.md solved.
//!
//! Contents:
//! - `pub fn main() !void`
const std = @import("std");

pub fn main() !void {
    var lib = try std.DynLib.open("build/libdiode.1.so");
    defer lib.close();
    const residual = lib.lookup(
        *const fn (x: *const [3]f64, f: *[3]f64, j: *[3][3]f64) callconv(.c) void,
        "device_residual",
    ) orelse return error.MissingSymbol;

    // U = { a, k, ai }.
    const x = [3]f64{ 0.632872, 0.0, 0.629200 };
    var f: [3]f64 = undefined;
    var j: [3][3]f64 = undefined;
    residual(&x, &f, &j);
    std.debug.print("f = {{ {e:.4}, {e:.4}, {e:.4} }}\n", .{ f[0], f[1], f[2] });
    std.debug.print("df[ai]/dx[ai] = {e:.4} S\n", .{j[2][2]});
}
