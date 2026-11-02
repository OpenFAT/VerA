//! A `--dyn` module: `vera --emit-so` compiles it with the generated device
//! and calls `exportDevice(D, name)` once, at compile time. Whatever it
//! exports is the shared library's interface; here, one C-ABI function.
//!
//! Contents:
//! - `pub const vera_validate_contract`
//! - `pub const calls_setup`

const std = @import("std");
const contract = @import("contract");

/// The shim `vera --emit-so` generates forwards this to the root module, so
/// the contract's conformance checks run on this build.
pub const vera_validate_contract = true;
/// What this host promises the device: it calls `setup` before `eval`.
pub const calls_setup = true;

pub fn exportDevice(comptime D: type, comptime name: []const u8) void {
    _ = name;
    contract.validateHost(@This(), D);
    @export(&Export(D).residual, .{ .name = "device_residual" });
}

// ---- private ----

fn Export(comptime D: type) type {
    return struct {
        const n = contract.nU(D);
        const S = contract.RefFamily(f64, &std.simd.iota(u8, n), .{});
        const Val = contract.RefFamily(f64, &@as([n]u8, @splat(contract.no_lane)), .{});

        /// The residual `f` and Jacobian `j` (row-major) at `x`, for the
        /// default card, as a DC operating point.
        fn residual(x: *const [n]f64, f: *[n]f64, j: *[n][n]f64) callconv(.c) void {
            var model: D.Model = .{};
            if (@hasDecl(D, "derive")) D.derive(Val, &model);
            if (@hasDecl(D, "setup")) D.setup(Val, &model);
            const inst: D.Instance = .{};
            const rows = D.eval(S, x, &model, &inst, .{});
            inline for (0..n) |r| {
                f[r] = rows[r].v;
                j[r] = contract.denseRow(n, rows[r]);
            }
        }
    };
}
