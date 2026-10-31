//! The passes over a lowered MIR: `Mir` + `Lowered` (`ir`) in; CFG and value
//! facts (`Analysis`), if-converted MIR (`ifconv`), a float-mode verdict per
//! unit (`proof`), the setup tiers (`setup`: solve invariance; `timepoint`:
//! the `vera_timepoint` check; `held`: the §3.2 held-row mask, which lowering
//! applies) and the MIR postcondition (`verify`) out. Re-exports only; the
//! files import each other directly. `contract`: the proof's transfer
//! functions use the devices' `exp`/`log`/`pow` (`contract.gm`).
//!
//! Contents:
//! - `pub const Analysis`, `pub const verify`, `pub const timepoint`, `pub const held`
//! - `pub const Input`, `pub const strArg`, `pub const Fixture`
//! - `pub const ifconv`, `pub const proof`, `pub const setup`

/// Dependency, type and fold tables over a finished MIR.
pub const Analysis = @import("Analysis.zig");
/// The MIR's postcondition, checked after lowering and each MIR pass.
pub const verify = @import("verify.zig");
/// The `vera_timepoint` (§2.9) per-iteration variance check.
pub const timepoint = @import("timepoint.zig");
/// §3.2 held-slot pruning: the held-row mask lowering applies.
pub const held = @import("held.zig");
/// What a setup tier or a codegen `plan/` function reads.
pub const Input = @import("input.zig").Input;
/// The literal string at a call argument, or null.
pub const strArg = @import("input.zig").strArg;
/// Test-only: a hand-built `Mir` + `Lowered` for planner tests.
pub const Fixture = @import("fixture.zig").Fixture;
/// Branch → `select` conversion over MIR.
pub const ifconv = @import("ifconv.zig");
/// Per-unit float-mode verdict from the finiteness proof.
pub const proof = @import("proof.zig");
/// Solve invariance, which codegen reads as a value.
pub const setup = @import("setup.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("Interval.zig");
    _ = @import("transfer.zig");
    _ = @import("cfg.zig");
    _ = @import("invariance.zig");
    _ = @import("falsify.zig");
}
