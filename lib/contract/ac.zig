//! A device's small-signal declarations in, what a host adds to its complex
//! system out: the §4.6.3 AC stimuli (`AcGen`, `AcPhasor`, `acStimActive`)
//! and the Jacobian slots whose small-signal value depends on frequency
//! (`acDynSlots`). Also the rules `validate` applies to them.
//! Cites: VAMS-2023 §4.6.3 (`ac_stim`), §4.6.1 Table 4-21 (analysis names),
//! §4.5.7 (`absdelay`), §4.5.11 (`laplace_*`), §4.5.12 (`zi_*`), A.8.2;
//! docs/specification/Vague_Decisions.md VD-064, VD-109.
//!
//! Contents:
//! - `pub const AcPhasor = struct { mag: f64, phase: f64 }`
//! - `pub fn AcGen(comptime D: type) type`
//! - `pub fn acStimActive(name: []const u8, kind: AnalysisKind, label: []const u8) bool`
//! - `pub fn acDynSlots(comptime D: type) []const u32`
//! - `pub fn acGensError(comptime D: type) ?[]const u8`
//! - `pub fn acDynError(comptime D: type) ?[]const u8`

const std = @import("std");
const assert = std.debug.assert;
const masks = @import("masks.zig");
const sim_state = @import("sim_state.zig");
const shape = @import("validate_shape.zig");
const nU = masks.nU;
const AnalysisKind = sim_state.AnalysisKind;
const SimState = sim_state.SimState;
const testing = std.testing;
const mocks = @import("mock_devices.zig");

/// §4.6.3 one AC stimulus' phasor, `mag·e^(j·phase)`, position k of `acStim`'s
/// result. Evaluated at a state vector, since A.8.2 lets magnitude and phase
/// depend on the operating point. Polar, as the model wrote it. `mag` may be
/// negative (a per-use coefficient folded in); a host must not take its
/// absolute value.
pub const AcPhasor = struct {
    /// Magnitude, in the contributed nature's units.
    mag: f64 = 1,
    /// Phase, in radians.
    phase: f64 = 0,
};

comptime {
    // Budget: `acStim` returns one per stimulus per frequency point.
    assert(@sizeOf(AcPhasor) == 16);
}

/// §4.6.3 one AC stimulus: position k of `ac_gens` is an `ac_stim` call on the
/// (row, col) branch, and position k of `acStim`'s result is its phasor. The
/// (row, col) rule is `NoiseGen`'s: a stimulus in a potential contribution is
/// a voltage source in series with its branch, `row == col` on the branch's
/// current unknown, its phasor carrying that row's sign (a negative `mag`).
/// The residual carries only the phasor's real part, `mag·cos(phase)`. A host
/// that solves a complex small-signal system reads this table instead of that
/// residual term; adding both counts the real part twice.
pub fn AcGen(comptime D: type) type {
    const n = nU(D);
    comptime assert(n >= 1);
    return struct {
        row: std.math.IntFittingRange(0, n - 1),
        col: std.math.IntFittingRange(0, n - 1),
        /// §4.6.3 `analysis_name`: the source is active only in the
        /// small-signal analysis of this name, and zero in every other
        /// analysis; `acStimActive` is the rule.
        name: []const u8 = "ac",
    };
}

/// §4.6.3 whether an `ac_stim` whose `analysis_name` is `name` (`AcGen.name`)
/// is active in an analysis of `kind` that the host labels `label` (the
/// Table 9-28 `analysis_name` it publishes, `host_strings[analysis_name_idx__]`;
/// "" for none). Never in a large-signal analysis ("returns zero (0) during
/// large-signal analyses"). A small-signal analysis answers to its Table 4-21
/// spelling, "ac" or "noise" (VD-064), and to its label for any other name
/// (VD-109): `ac_stim("ac")` is active in every `.ac` analysis, and
/// `ac_stim("ac2")` only in one the host labels "ac2". The device's residual
/// applies the same rule; a host gating `ac_gens` calls this with the label it
/// published, so the two agree.
pub fn acStimActive(name: []const u8, kind: AnalysisKind, label: []const u8) bool {
    if (kind != .ac and kind != .noise) return false;
    assert(kind == .ac or kind == .noise);
    if (std.mem.eql(u8, name, "ac") or std.mem.eql(u8, name, "noise"))
        return std.mem.eql(u8, name, @tagName(kind));
    return std.mem.eql(u8, name, label);
}

/// Returns the device's `ac_dyn_slots`, or empty. Slot `row * n_u + col` is a
/// local Jacobian entry whose small-signal value depends on frequency: a
/// partial that flows through §4.5.7 `absdelay` (e^(−jω·td)), §4.5.11
/// `laplace_*` (H(jω)) or §4.5.12 `zi_*` (H(e^(jωT))). Under kind `.ac` or
/// `.noise`, `eval`, `q` and `evalQ` omit every such partial (the values
/// stay), and `acDyn(F, &model, inst, &x, sim, ω, &out)` writes the omitted
/// part of slot `ac_dyn_slots[k]` into `out[k]`, so the host's small-signal
/// matrix is
///
///     A(ω)[slot] = G[slot] + jω·C[slot] + out[k]
///
/// with G and C from the same `x` and `sim` passed to `acDyn`; `out[k]`
/// already carries the jω of a charge an operator feeds. `F` is `f64` or
/// `@Vector(W, f64)`: `omega` holds W frequencies and each `out[k]` part their
/// W terms, lane for lane, with no branch across lanes. At ω = 0 `out[k].re`
/// is exactly the partial the operator's DC form gives (absdelay 1, a
/// `laplace_*` H(0), a `zi_*` H(1), times the chain rule around it) and
/// `out[k].im` is 0. Pure, so a host may call it per frequency, in any
/// order. A superset: a listed slot may read 0.
/// `validate` checks the list is sorted and unique, inside `jac_pattern |
/// q_pattern`, and every column in `derivReads`.
pub fn acDynSlots(comptime D: type) []const u32 {
    return if (@hasDecl(D, "ac_dyn_slots")) D.ac_dyn_slots[0..] else &.{};
}

/// `ac_gens` is `[k]AcGen(D)` (whose integer widths range-check row and
/// col), `acStim` comes with it and has its shape.
pub fn acGensError(comptime D: type) ?[]const u8 {
    if (shape.arrayError(D, "ac_gens", AcGen(D))) |m| return m;
    if (shape.requireWithError(D, "acStim", "ac_gens")) |m| return m;
    if (!@hasDecl(D, "acStim")) return null;
    return shape.genericError(D, "acStim", 5, "fn (comptime S: type, [n_u]f64, *const Model, *const Instance, SimState) [ac_gens.len]AcPhasor");
}

/// `validate`'s `ac_dyn_slots`/`acDyn` rules, returned so each is testable.
pub fn acDynError(comptime D: type) ?[]const u8 {
    const name = @typeName(D);
    if (@hasDecl(D, "ac_dyn_slots") != @hasDecl(D, "acDyn")) return name ++ ": ac_dyn_slots and acDyn come together";
    if (!@hasDecl(D, "ac_dyn_slots")) return null;
    const info = @typeInfo(@TypeOf(D.ac_dyn_slots));
    if (info != .array or info.array.child != u32) return name ++ ".ac_dyn_slots must be [k]u32";
    const f = @typeInfo(@TypeOf(D.acDyn));
    if (f != .@"fn" or f.@"fn".param_types.len != 7 or f.@"fn".param_types[0] != type)
        return name ++ ".acDyn: expected fn (comptime F: type, *const Model, InstancePtr, *const [n_u]f64, SimState, F, *[ac_dyn_slots.len]std.math.Complex(F)) void";
    const n = nU(D);
    for (D.ac_dyn_slots, 0..) |s, i| {
        if (s >= n * n) return name ++ ".ac_dyn_slots: a slot at or past n_u * n_u";
        if (i != 0 and s <= D.ac_dyn_slots[i - 1]) return name ++ ".ac_dyn_slots must be sorted with no duplicates";
        const r = s / n;
        const c = s % n;
        const M = masks.Mask(D);
        const jp: M = if (@hasDecl(D, "jac_pattern")) D.jac_pattern[r] else ~@as(M, 0);
        const qp: M = if (@hasDecl(D, "q_pattern")) D.q_pattern[r] else if (@hasDecl(D, "q")) ~@as(M, 0) else 0;
        if (((jp | qp) >> @intCast(c)) & 1 == 0) return name ++ ".ac_dyn_slots: a slot outside jac_pattern | q_pattern";
        if ((masks.derivReads(D) >> @intCast(c)) & 1 == 0) return name ++ ".ac_dyn_slots: a slot whose column is outside deriv_reads";
    }
    return null;
}

test "§4.6.3 acStimActive: the kind's spelling, else the host's label, never large-signal" {
    try testing.expect(acStimActive("ac", .ac, ""));
    try testing.expect(acStimActive("ac", .ac, "ac1"));
    try testing.expect(!acStimActive("ac", .noise, ""));
    try testing.expect(acStimActive("noise", .noise, "mynoise"));
    try testing.expect(acStimActive("myac", .ac, "myac"));
    try testing.expect(acStimActive("myac", .noise, "myac"));
    try testing.expect(!acStimActive("myac", .ac, "ac"));
    // "returns zero (0) during large-signal analyses", whatever the label.
    try testing.expect(!acStimActive("tran1", .tran, "tran1"));
    try testing.expect(!acStimActive("tran", .tran, ""));
    try testing.expect(!acStimActive("dc", .dc, "dc"));
}

test "ac_dyn_slots: each rule refuses its own mistake" {
    try testing.expect(comptime (acDynError(mocks.MockAll) == null));
    const Of = struct {
        fn dev(comptime slots: []const u32, comptime dr: u64) type {
            return struct {
                pub const U = enum(u8) { p, n };
                pub const jac_pattern = [2]u64{ 0b10, 0b00 };
                pub const deriv_reads: u64 = dr;
                pub const ac_dyn_slots = slots[0..slots.len].*;
                pub fn acDyn(comptime F: type, _: *const void, _: *const void, _: *const [2]f64, _: SimState, _: F, _: *[slots.len]std.math.Complex(F)) void {}
            };
        }
    };
    // Slot 1 is (p, n): inside the pattern, its column a lane.
    try testing.expect(comptime (acDynError(Of.dev(&.{1}, 0b10)) == null));
    // Past n_u², unsorted, outside the pattern, a column with no lane.
    try testing.expect(comptime (acDynError(Of.dev(&.{4}, 0b10)) != null));
    try testing.expect(comptime (acDynError(Of.dev(&.{ 1, 1 }, 0b10)) != null));
    try testing.expect(comptime (acDynError(Of.dev(&.{0}, 0b11)) != null));
    try testing.expect(comptime (acDynError(Of.dev(&.{1}, 0b01)) != null));
    // The two decls come together.
    try testing.expect(comptime (acDynError(struct {
        pub const U = enum(u8) { p, n };
        pub const ac_dyn_slots = [_]u32{1};
    }) != null));
}
