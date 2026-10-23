//! Analog lowering: an elaborated design (`elab`, §6.2.2) → SSA `Mir` plus the
//! `Lowered` tables (`ir`), through SSA construction. Re-exports only; the
//! files import each other directly. Code after lowering reads `ir`'s types,
//! not this module; the spine (`vera`) and the
//! tests that lower source import it.

/// The pass: `Lower.lower` runs it whole, `Lower.Harness` is its test support.
pub const Lower = @import("lower.zig");
/// Braun et al.'s SSA builder, one per `Lower` pass; exported for the unit
/// tests and `vera`'s per-stage checks.
pub const Ssa = @import("ssa.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
