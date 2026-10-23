//! Float mode of the generated device: prover verdicts and options in, the
//! `@setFloatMode` of each body and the f32-Jacobian permission out. Pure.
//! `lanes.zig` holds the lane half; `Float` is the emit state both share.
//! LRM clauses cited: §4.3.

const std = @import("std");
const proof = @import("prove").proof;
const Job = @import("../plan/jobs.zig").Job;

/// The float state `Gen` carries while it writes.
pub const Float = struct {
    /// The body being emitted compiles `.strict`, which licenses the eager
    /// `sel` form (`lanes.eagerSafe`). Set by `emitUnit` and the core
    /// emitter; false elsewhere, so other paths keep the lazy `if`.
    strict: bool = false,
    /// Set once a residual or charge unit steers on an x-dependent value
    /// through a scalar (`lanes.pinLanes`). A device that finishes with it
    /// false emits `pub const batch_ok = true;`: eval/q with a `V` holding
    /// several operating points is then exact per point. Display units never
    /// set it; they are not part of the residual.
    pinned: bool = false,
    /// Set once a unit decides on an x-dependent value through the lead
    /// protocol (`lanes.leadLanes`). An unpinned device with it set is
    /// `batch_ok` only for a family that runs the protocol (`batch_lead`).
    lead: bool = false,
    /// Set once eval reads per-instance state as a value (`lanes.instLanes`:
    /// a held variable, a `$prev` path latch, `$mfactor`). A batch reads it
    /// per point through `S.instLane` (`batch_inst`).
    inst: bool = false,
    /// Which single-precision-Jacobian decls the device emits
    /// (`Options.jac_f32`/`jac_f32_host`).
    jac: Jac = .off,
};

/// The f32 Jacobian permission. Folds the two options into one value so the
/// invalid pair (`jac_f32_host` without `jac_f32`) cannot occur.
pub const Jac = enum {
    /// f64 derivatives only.
    off,
    /// `pub const jac_f32 = true`: a host MAY carry the derivative half in f32.
    permit,
    /// `jac_f32_host` too: the host should take it on its CPU path as well.
    host,

    /// Returns the permission for the two CLI options; `host` implies `permit`.
    pub fn of(jac_f32: bool, jac_f32_host: bool) Jac {
        if (jac_f32_host) return .host;
        return if (jac_f32) .permit else .off;
    }
};

/// Returns the mode the shared core compiles in: the strictest mode of every
/// job it serves, excluding the §9.4 display job (LRM §4.3).
pub fn coreMode(jobs: []const Job) proof.FloatMode {
    var mode: proof.FloatMode = .optimized;
    for (jobs) |job| {
        if (job.kind == .display) continue;
        mode = .strictest(mode, job.mode);
    }
    return mode;
}

test "the core is strict if any served job is; the f32 knob normalises host ⇒ permit" {
    const j = struct {
        fn of(kind: Job.Kind, mode: proof.FloatMode) Job {
            return .{ .kind = kind, .target = .f_zero, .mode = mode };
        }
    }.of;
    try std.testing.expectEqual(proof.FloatMode.optimized, coreMode(&.{ j(.resist, .optimized), j(.display, .strict) }));
    try std.testing.expectEqual(proof.FloatMode.strict, coreMode(&.{ j(.resist, .optimized), j(.held, .strict) }));
    try std.testing.expectEqual(Jac.host, Jac.of(false, true));
    try std.testing.expectEqual(Jac.permit, Jac.of(true, false));
    try std.testing.expectEqual(Jac.off, Jac.of(false, false));
}

test coreMode {
    // No served job (a display-only model) forces nothing: the join's identity.
    try std.testing.expectEqual(proof.FloatMode.optimized, coreMode(&.{}));
}
