//! A minimal host: one VerA device (diode.va, imported as `device`) in a
//! circuit the host owns, solved by Newton's method.
//!
//!     1 V --[ R = 1 kOhm ]-- a --[ diode.va: rs, then the junction ]-- k = ground
//!
//! The device's unknowns are U = { a, k, ai }: its two ports, then its
//! internal node. The host grounds k and solves for a and ai.
//!
//! Contents:
//! - `pub const vera_validate_contract`
//! - `pub const calls_setup`
//! - `pub fn main() void`
const std = @import("std");
const contract = @import("contract");
const D = @import("device");

/// Turns on the contract's conformance checks for this program.
pub const vera_validate_contract = true;
/// What this host promises the device: it calls `setup` before `eval`.
pub const calls_setup = true;
comptime {
    contract.validateHost(@This(), D);
}

const n = contract.nU(D);
/// The family `eval` computes in: unknown u carries derivative lane u.
const S = contract.RefFamily(f64, &std.simd.iota(u8, n), .{});
/// The value-only family the card-time hooks compute in: no lanes.
const Val = contract.RefFamily(f64, &@as([n]u8, @splat(contract.no_lane)), .{});

pub fn main() void {
    // The card: every parameter at its default. Then the card-time hooks,
    // in the contract's order.
    var model: D.Model = .{};
    if (@hasDecl(D, "derive")) D.derive(Val, &model);
    D.setup(Val, &model);
    var inst: D.Instance = .{};
    if (@hasDecl(D, "setupInstance")) D.setupInstance(&model, &inst);

    const a = @backingInt(D.U.a);
    const ai = @backingInt(D.U.ai);
    const v_src = 1.0;
    const r_ext = 1000.0;

    // A starting guess near the junction's knee, as SPICE seeds a junction.
    var x: [n]f64 = @splat(0.0);
    x[a] = 0.6;
    x[ai] = 0.6;

    for (1..50) |it| {
        // One call: each row's value is the current leaving that node
        // through the device, and its lanes are the row of the Jacobian.
        const rows = D.eval(S, &x, &model, &inst, .{});
        var f: [n]f64 = undefined;
        var j: [n][n]f64 = undefined;
        inline for (0..n) |r| {
            f[r] = rows[r].v;
            j[r] = contract.denseRow(n, rows[r]);
        }
        // Columns outside `deriv_reads` carry no lane: their constant
        // partials are in `jac_const` (this diode has none).
        inline for (comptime contract.jacConst(D)) |e| {
            if (contract.jacConstApplies(D, e, &model, S.collapse_applied))
                j[@backingInt(e.row)][@backingInt(e.col)] = e.g;
        }
        // The host's own element: R from the source to a.
        f[a] += (x[a] - v_src) / r_ext;
        j[a][a] += 1.0 / r_ext;

        // Newton: solve J dx = -f on the free unknowns a and ai.
        const det = j[a][a] * j[ai][ai] - j[a][ai] * j[ai][a];
        const da = (-f[a] * j[ai][ai] + f[ai] * j[a][ai]) / det;
        const dai = (-f[ai] * j[a][a] + f[a] * j[ai][a]) / det;
        std.debug.print("iteration {d}: |f| = {e:.3} A\n", .{ it, @abs(f[a]) + @abs(f[ai]) });
        x[a] += da;
        x[ai] += dai;
        if (@abs(da) + @abs(dai) < 1e-12) break;
    }
    std.debug.print("V(a) = {d:.6} V, V(ai) = {d:.6} V, I = {d:.3} uA\n", .{ x[a], x[ai], (v_src - x[a]) / r_ext * 1e6 });
}
