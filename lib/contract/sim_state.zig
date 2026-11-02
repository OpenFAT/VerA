//! The host's analysis and a device's declarations in, the values that cross
//! every entry-point call out: the `SimState` a host passes by value, what
//! `updateState`, `limit` and `stateCtl` exchange, and the per-device
//! defaults of the optional declarations about them (`stateClass`,
//! `simReads`, `InstancePtr`).
//! Cites: VAMS-2023 §4.6.1 Table 4-21 (`analysis()`), §5.2.1 (`analog
//! initial`), §5.6.1.2 (path latches), §5.10.2 (initial and final step),
//! §9.10 (`$abstime`), §9.15 (`$simparam("dt")`, `"iteration"`), §9.17.1
//! (`$discontinuity`), §9.17.3 (limiting).
//!
//! Contents:
//! - `pub const UpdateResult = union(enum) { ok, request_reject_at: f64 }`
//! - `pub const StateClass = enum { none, path_latch, history }`
//! - `pub const StateCtlOp = enum(u8) { query, commit, revert }`
//! - `pub const AnalysisKind = enum(u8) { static, ic, nodeset, dc, tran, ac, noise }`
//! - `pub const SimState = extern struct`
//! - `pub const SimReads = struct { t: bool, dt: bool, iteration: bool }`
//! - `pub const Constant = struct { g: bool, c: bool }`
//! - `pub fn LimitResult(comptime n: usize) type`
//! - `pub fn stateClass(comptime D: type) StateClass`
//! - `pub fn simReads(comptime D: type) SimReads`
//! - `pub fn InstancePtr(comptime D: type) type`

const std = @import("std");
const assert = std.debug.assert;

/// What `updateState` returns: `.ok`, or a request that the host reject the
/// step and retry with its end at `request_reject_at` (an absolute time). In
/// a static solve (any `kind` but `.tran`) the request means "iterate again at
/// this point": the device's state moved, and the solve must see it.
pub const UpdateResult = union(enum) {
    ok,
    request_reject_at: f64,
};

/// What a device carries across accepted points, declared as `state_class`:
///   none: no `State` and no `updateState`.
///   path_latch: only the §5.6.1.2 path latches. `updateState` stages them and
///     `stateCtl(.commit)` latches them; no operator history, held FSM or
///     §9.13.1 seed.
///   history: anything else `updateState` advances.
pub const StateClass = enum { none, path_latch, history };

/// The operations of `stateCtl`, which a transient loop uses to reject and
/// retry a step after `updateState` has run on it. The host commits every
/// accepted point, the operating point included, before it may revert.
///   query: does the working state differ from the last accepted one in a
///     way that should reject the step (a flipped device state)?
///   commit: the step is accepted; accepted := working.
///   revert: the step is rejected; working := accepted, for every field
///     `updateState` advances and `State.t_prev`. Exact when at most one
///     `updateState` ran since the last commit or revert. Static-solve
///     iteration state (the levels a static solve iterates on) may survive
///     it; a device that keeps any rebuilds from the accepted state in every
///     `updateState`, so a host must not restore it either.
pub const StateCtlOp = enum(u8) { query, commit, revert };

/// §4.6.1 `analysis()`, Table 4-21: the analysis a `SimState` describes.
/// The tag names are the analysis names `analysis()` compares against.
pub const AnalysisKind = enum(u8) { static, ic, nodeset, dc, tran, ac, noise };

/// The analysis in force, passed by value to every entry point that reads it.
/// The host is its only writer, and one value serves every instance of a batch.
///   t: §9.10 `$abstime`, the time the solve is targeting.
///   dt: the step since the last accepted point. 0 marks the static solve
///     (DC, IC, a transient's first point) an operator's DC form keys on.
///     VerA's `$simparam("dt")` (§9.15) returns it unchanged.
///   kind: §4.6.1 `analysis()`.
///   initial_step, final_step: the §5.10.2 global events.
///   analog_initial: this evaluation is the first of a §5.2.1 sub-task (each
///     point of a parameter sweep), so `analog initial` runs.
///   iteration: §9.15 `$simparam("iteration")`, 1 at a solve's first iterate.
/// `extern`, 24 bytes, align 8, the same on every target (`iteration` at 20).
/// The defaults are a DC operating point at t = 0, which is what `collapse`
/// and `derive` evaluate at.
pub const SimState = extern struct {
    t: f64 = 0,
    dt: f64 = 0,
    kind: AnalysisKind = .dc,
    initial_step: bool = false,
    final_step: bool = false,
    analog_initial: bool = true,
    iteration: u32 = 1,
};

/// Which `SimState` fields `eval`, `q` and `evalQ` read (`D.sim_reads`).
///   t, dt: read outside the `then` arm of a §5.10.2 `initial_step` event,
///     whose evaluations a host tells apart by `initial_step` itself. False
///     means every evaluation off the initial step is a function of the time
///     only through `kind`, `initial_step`, `final_step` and
///     `analog_initial`, so a host may reuse one across timepoints.
///   iteration: read anywhere.
/// `kind`, `initial_step`, `final_step` and `analog_initial` are not listed.
pub const SimReads = struct { t: bool = true, dt: bool = true, iteration: bool = true };

/// The device's optional `constant` declaration: `g`/`c` promise that dF/dx and
/// dQ/dx do not depend on x, so a host may build the stamp once and reuse it
/// every iteration. A wrong promise silently freezes the Jacobian.
pub const Constant = struct {
    g: bool = false,
    c: bool = false,
};

comptime {
    // Budget: returned once per instance per accepted point; a time and a tag.
    assert(@sizeOf(UpdateResult) <= 16);
    // The C-compatible layout a `.so` host and a GPU kernel share.
    assert(@sizeOf(SimState) == 24);
    assert(@offsetOf(SimState, "iteration") == 20);
    assert(@alignOf(SimState) == 8);
    assert(@sizeOf(AnalysisKind) == 1);
}

/// What `limit` returns: the limited unknowns, and `converged`, false when the
/// host must run another Newton iteration: a clamp was large enough (pnjlim's
/// clamp is; a small fetlim/limvds one is not), or the model evaluated at
/// `old` executed §9.17.1 `$discontinuity(-1)`.
pub fn LimitResult(comptime n: usize) type {
    return struct {
        x: [n]f64,
        converged: bool = false,
    };
}

/// Returns `D.state_class`, or for a device without the decl `history` when it
/// has `updateState` and `none` otherwise.
pub fn stateClass(comptime D: type) StateClass {
    if (@hasDecl(D, "state_class")) return D.state_class;
    return if (@hasDecl(D, "updateState")) .history else .none;
}

/// Returns `D.sim_reads`, or every field read when undeclared. A superset.
pub fn simReads(comptime D: type) SimReads {
    return if (@hasDecl(D, "sim_reads")) D.sim_reads else .{};
}

/// Returns the instance pointer type `eval`/`q` take: `*D.Instance` for a
/// device that declares `mutable_eval` (it initializes table state on its
/// first call, permanently and outside timestep rollback), so the host must
/// give each evaluation exclusive access; `*const D.Instance` otherwise.
pub fn InstancePtr(comptime D: type) type {
    return if (@hasDecl(D, "mutable_eval") and D.mutable_eval) *D.Instance else *const D.Instance;
}

test "stateClass, SimState and LimitResult defaults" {
    const testing = std.testing;
    try testing.expectEqual(StateClass.none, stateClass(struct {}));
    try testing.expectEqual(StateClass.history, stateClass(struct { // updateState, undeclared
        pub fn updateState() void {}
    }));
    try testing.expectEqual(StateClass.path_latch, stateClass(struct {
        pub const state_class: StateClass = .path_latch;
    }));
    // A DC operating point at t = 0, the first iterate of an analog initial.
    const s: SimState = .{};
    try testing.expectEqual(AnalysisKind.dc, s.kind);
    try testing.expect(s.analog_initial and !s.initial_step and !s.final_step);
    try testing.expectEqual(@as(u32, 1), s.iteration);
    try testing.expectEqual(@as(f64, 0), s.t);
    try testing.expectEqual(@as(f64, 0), s.dt);
    const r: LimitResult(2) = .{ .x = .{ 1, 2 } };
    try testing.expect(!r.converged);
    // Every field read when undeclared: the superset.
    try testing.expectEqual(SimReads{}, simReads(struct {}));
}

test InstancePtr {
    const Plain = struct {
        pub const Instance = struct {};
    };
    try std.testing.expect(InstancePtr(Plain) == *const Plain.Instance);
    const Mut = struct {
        pub const Instance = struct {};
        pub const mutable_eval = true;
    };
    try std.testing.expect(InstancePtr(Mut) == *Mut.Instance);
}
