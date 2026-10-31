//! The analog testbench backend behind `vera --emit-exe`: a fixture's `//!`
//! directives in, a runner's Zig source out, built over the `display = .emit`
//! device. The runner prints a transcript (every `$strobe`, plus residual and
//! Jacobian per operating point). Directives are comments (§2.4), so a
//! fixture stays one portable .va file.
//! Cites: §2.4, §9.4; each file cites its own clauses.
//!
//! The pipeline a caller runs (`src/Compilation.zig --emit-exe`, `tests/suite.zig`):
//!
//!     var diag: tb.Diagnostics = .{};
//!     const s = try tb.Spec.parse(arena, source, &diag);
//!     // compile the device; again with `tb.shapeCards(arena, s.bench.params, lowered)`
//!     // as `param_overrides` when that is non-empty (§3.4 shape parameters)
//!     var facts = try tb.compileFacts(arena, lowered, mir);
//!     facts.validate_contract = true;
//!     try tb.warnGridEvents(bag, lowered, mir);
//!     var aw: std.Io.Writer.Allocating = .init(gpa);
//!     try tb.writeRunner(&aw.writer, arena, stem, &s.bench, facts);
//!     // then `zigbuild.buildExe(..., aw.written(), ...)`
//!
//! `tb.writeVpiLib` takes the runner's place for the Clause 12 analog host.
//! `s.harness` is the caller's: what to compile with, and how to judge the run.
//!
//! Contents:
//! - from `spec.zig`: `Spec`, `Spec.parse`, `Bench`, `Harness`, `Facts`, `Mixed`, `Binding`, `Sweep`,
//!   `LimitCase`, `Analysis`, `Print`, `NoiseWant`, `AcWant`, `AcDynWant`, `Diagnostics`,
//!   `ParseError`, `RenderError`, `points_max`
//! - from `operands.zig`: `validSection`
//! - from `facts.zig`: `compileFacts`, `shapeCards`, `memBytes`, `opStates`, `mixedPlan`, `warnGridEvents`
//! - from `points.zig`: `pointCount`, `Row`
//! - from `runner.zig`: `writeRunner`; from `vpi.zig`: `writeVpiLib`

const spec = @import("spec.zig");
const operands = @import("operands.zig");
const facts = @import("facts.zig");
const points = @import("points.zig");
const runner = @import("runner.zig");
const vpi = @import("vpi.zig");

pub const Spec = spec.Spec;
pub const Bench = spec.Bench;
pub const Harness = spec.Harness;
pub const Facts = spec.Facts;
pub const Mixed = spec.Mixed;
pub const Binding = spec.Binding;
pub const Sweep = spec.Sweep;
pub const LimitCase = spec.LimitCase;
pub const Analysis = spec.Analysis;
pub const Print = spec.Print;
pub const NoiseWant = spec.NoiseWant;
pub const AcWant = spec.AcWant;
pub const AcDynWant = spec.AcDynWant;
pub const Diagnostics = spec.Diagnostics;
pub const ParseError = spec.ParseError;
pub const RenderError = spec.RenderError;
pub const points_max = spec.points_max;

pub const validSection = operands.validSection;

pub const compileFacts = facts.compileFacts;
pub const shapeCards = facts.shapeCards;
pub const memBytes = facts.memBytes;
pub const opStates = facts.opStates;
pub const mixedPlan = facts.mixedPlan;
pub const warnGridEvents = facts.warnGridEvents;

pub const pointCount = points.pointCount;
pub const Row = points.Row;

pub const writeRunner = runner.writeRunner;
pub const writeVpiLib = vpi.writeVpiLib;

test {
    _ = @import("parse.zig");
    _ = operands;
    _ = points;
    _ = @import("parts.zig");
}
