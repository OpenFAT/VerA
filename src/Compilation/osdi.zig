//! What an OSDI 0.4 library cannot carry, named before `--emit-osdi` builds
//! one: lowering's tables in, diagnostics out. OSDI 0.4 has no slot for a
//! step-rejection request (E1099 refuses) or for the correlation of two noise
//! rows of one generator (W1098 warns, docs/specification/Vague_Decisions.md
//! VD-102). The build itself is `--emit-so`'s (`library.zig`) under
//! `lib/osdi_dyn.zig`, the `dyn` that maps the contract onto the descriptor
//! ngspice loads with `pre_osdi`.
//!
//! Cites: §4.6.4.6 (correlated noise), §9.17 (`$vera_reject_step`).
//!
//! Contents:
//! - `pub fn check(bag: *diag.Bag, lowered: *const Lowered) error{OutOfMemory}!void`

const std = @import("std");
const assert = std.debug.assert;
const diag = @import("diag");
const Lowered = @import("ir").Lowered;

/// Reports into `bag` what `lowered` asks of a host that OSDI 0.4 cannot
/// carry: E1099 refuses, W1098 warns. The caller reads `bag.failed()`.
pub fn check(bag: *diag.Bag, lowered: *const Lowered) error{OutOfMemory}!void {
    const before = bag.err_count;
    if (lowered.reject_step != .undef)
        try bag.add(.codegen, .E1099, .none, "`$vera_reject_step` asks the host to reject a step, and an OSDI 0.4 library has no slot to carry the request", .{});
    if (sharesGenerator(lowered.contributions.items))
        try bag.add(.codegen, .W1098, .none, "two noise rows share one generator (§4.6.4.6), and OSDI 0.4 has no slot for their correlation: this library's noise analysis treats them as independent sources", .{});
    assert(bag.err_count >= before);
}

// ---- private ----

/// Whether one noise generator id appears in two contributions: one source
/// in two rows (`device/codegen/plan/noise.zig`'s rule). An AC stimulus is
/// no generator.
// ponytail: O(n²) in the noise rows, a handful per model; a sorted id
// column if a model ever carries thousands.
fn sharesGenerator(cs: []const Lowered.Contribution) bool {
    if (cs.len < 2) return false; // One row cannot share with another.
    for (cs, 0..) |c, i| for (c.noise_srcs) |s| {
        if (s.kind == .ac_stim) continue;
        for (cs[i + 1 ..]) |d| for (d.noise_srcs) |t| {
            if (t.id == s.id) return true;
        };
    };
    return false;
}
