//! The OSDI 0.4 backend (`vera --emit-osdi`): the contract device of a `.va`
//! model or a `.v` design, built as a shared library under `lib/osdi_dyn.zig`,
//! the `dyn` module that maps the contract onto the OSDI descriptor ngspice
//! loads with `pre_osdi`. The build is `--emit-so`'s (`Compilation.compile`,
//! `zigbuild.compileRelease`); this file names what the target cannot carry
//! before a library is built: OSDI 0.4 has no slot for a step-rejection
//! request (E1099) or for the correlation of two noise rows of one generator
//! (W1098, docs/specification/Vague_Decisions.md VD-102).
//! Clauses: §4.6.4.6 (correlated noise), §9.17 (`$vera_reject_step`).

const diag = @import("diag");
const Lowered = @import("ir").Lowered;

/// Reports into `bag` what `lowered` asks of a host that OSDI 0.4 cannot
/// carry: E1099 refuses, W1098 warns. The caller reads `bag.failed()`.
pub fn check(bag: *diag.Bag, lowered: *const Lowered) error{OutOfMemory}!void {
    if (lowered.reject_step != .undef)
        try bag.add(.codegen, .E1099, .none, "`$vera_reject_step` asks the host to reject a step, and an OSDI 0.4 library has no slot to carry the request", .{});
    // `device/codegen/plan/noise.zig`'s rule: a generator id in two
    // contributions is one source in two rows.
    const shared = blk: {
        const cs = lowered.contributions.items;
        for (cs, 0..) |c, i| for (c.noise_srcs) |s| {
            if (s.kind == .ac_stim) continue;
            for (cs[i + 1 ..]) |d| for (d.noise_srcs) |t| {
                if (t.id == s.id) break :blk true;
            };
        };
        break :blk false;
    };
    if (shared) try bag.add(.codegen, .W1098, .none, "two noise rows share one generator (§4.6.4.6), and OSDI 0.4 has no slot for their correlation: this library's noise analysis treats them as independent sources", .{});
}
