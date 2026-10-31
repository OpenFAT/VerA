//! The VAMS §8 coordinator that steps a digital `Run` beside an analog solver:
//! the names callers reach as `sim.mixed.<name>` (src/vpi/host.zig, the
//! testbench runner src/codegen/exe/tb/runner_text.zig emits).
//! Cites: none here; each file's header names its clauses.
//!
//! Contents:
//! - `pub const run`
//! - `pub const Options`

const steps = @import("run.zig");

/// Runs one analysis over `opts.times` (`run.zig`).
pub const run = steps.run;
/// One analysis's timeline, as `run` reads it.
pub const Options = steps.Options;

test {
    _ = steps;
    _ = @import("coordinator.zig");
    _ = @import("monitors.zig");
}
