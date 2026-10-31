//! Numerical safety: a MIR and its `Lowered` in, a float-mode `Verdict` per
//! contribution unit out, plus a coded error for every argument provably
//! outside its math function's domain. Domain checks are three-way
//! (`domain.zig`): provably outside is an error, provably inside keeps
//! `.optimized`, unprovable is accepted and costs `.strict`. `exp` and `/` by
//! zero are never errors. The pass reads no target, inserts no clamp or
//! `limexp`, and emits no runtime check. This file is the API and the spine
//! (`prove`); the passes are `seed.zig`, `guards.zig`, `walk.zig` and
//! `verdict.zig` over the state in `Prover.zig`.
//!
//! LRM clauses this file's code cites: §3.4, §4.2.3, §4.2.12, §4.3, §4.3.2,
//! §4.4, §5.4.3, §5.6.1.3, §5.6.7.
//!
//! Contents:
//! - `pub const FloatMode = enum(u8) { optimized, strict }`, `FloatMode.strictest(a: FloatMode, b: FloatMode) FloatMode`
//! - `pub const Verdict = struct`, `Verdict.ok(v: Verdict) bool`, `Verdict.deinit(v: Verdict, gpa: Allocator) void`
//! - `pub const Options = struct { unknown_bound: ?f64 = null }`
//! - `pub const Error = Allocator.Error`
//! - `pub const errors_max: u8`
//! - `pub fn prove(gpa: Allocator, mir: *const Mir, lowered: *const Lowered, options: Options, bag: *diag.Bag) Error!Verdict`
//! - `pub fn unitCount(lowered: *const Lowered) usize`

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const diag = @import("diag");
const Analysis = @import("Analysis.zig");
const Prover = @import("Prover.zig");
const seed = @import("seed.zig");
const guards = @import("guards.zig");
const walk = @import("walk.zig");
const verdict = @import("verdict.zig");

/// The float mode a unit's code may compile in (§4.3). `.optimized` asserts
/// nnan and ninf, so a wrong `.optimized` is silent undefined behavior in
/// release builds, and every finiteness rule errs toward `.strict`:
///  1. Solver unknowns (§4.4) and model-card parameters (§3.4) are finite
///     doubles by the host contract; a probe's magnitude is still unknown. A
///     parameter whose range admits `inf` is not finite.
///  2. `exp`, `expm1`, `sinh`, `cosh` and `pow` overflow at device
///     magnitudes, so their result is finite only for a bounded argument.
///  3. `+ - * /` on finite operands do not overflow.
///  4. A `call` the prover does not model is not finite.
pub const FloatMode = enum(u8) {
    /// Proven finite: codegen emits `@setFloatMode(.optimized)`.
    optimized,
    /// Not provably finite: `@setFloatMode(.strict)`, where inf and NaN are
    /// IEEE-defined. Not an error.
    strict,

    /// Returns the mode for code shared by both units: `.strict` absorbs. A
    /// subexpression shared with a `.strict` unit stays reachable from it, so
    /// compiling it fast-math would assert a fact that unit never had.
    /// Codegen folds the shared core's mode through this join
    /// (`codegen/float/mode.zig` `coreMode`).
    pub fn strictest(a: FloatMode, b: FloatMode) FloatMode {
        return if (a == .strict or b == .strict) .strict else .optimized;
    }
};

/// The prover's result. Invariant: a nonzero `error_count` rates every unit
/// `.strict`.
pub const Verdict = struct {
    /// `unit_modes[i]` rates `lowered.contributions.items[i]`: one unit per
    /// access and node pair (§5.6.1.3), or per statement for a §5.6.7
    /// indirect contribution. A unit is `.optimized` only if both its
    /// `resist_val` and `react_val` slices are proven finite. §5.4.3 port
    /// probes add no unit; a new unit kind is appended after these. Allocated
    /// with the `gpa` passed to `prove`; free with `deinit`.
    unit_modes: []const FloatMode,
    /// §4.3.2 domain violations reported into the bag, saturating at
    /// `errors_max`. Zero means the model is accepted.
    error_count: u8,

    /// Returns true when no domain error was reported.
    pub fn ok(v: Verdict) bool {
        return v.error_count == 0;
    }

    /// Frees `unit_modes`; `gpa` must be the allocator passed to `prove`.
    pub fn deinit(v: Verdict, gpa: Allocator) void {
        gpa.free(v.unit_modes);
    }
};

/// Prover knobs.
pub const Options = struct {
    /// A host bound B with |unknown| <= B for every solver unknown. It makes
    /// probe-dependent transcendentals provable. `null` (or NaN, which bounds
    /// nothing) means unbounded but still finite (rule 1 on `FloatMode`).
    /// The hardware knob: a real solver has a compliance limit no language
    /// rule can see.
    unknown_bound: ?f64 = null,
};

/// `prove` fails only on allocation; the bag may hold diagnostics already
/// reported, and nothing else is left behind.
pub const Error = Allocator.Error;

/// Most domain errors counted and reported; one bad expression otherwise
/// reports a cascade. Past it violations are neither counted nor reported.
pub const errors_max: u8 = 64;

/// Proves every §4.3.2 domain, reports violations (E0601-E0607, E0609) and
/// finiteness lints (W0650, W0651, W0653) into `bag`, and rates each unit.
/// Caller owns the returned `Verdict` and must free it with `deinit(gpa)`.
/// Scratch state lives in an arena on `gpa` that dies before return. Reads
/// `mir` and `lowered` only, so proving the same input twice gives the same
/// verdict. Asserts that `mir` has its entry block.
pub fn prove(
    gpa: Allocator,
    mir: *const Mir,
    lowered: *const Lowered,
    options: Options,
    bag: *diag.Bag,
) Error!Verdict {
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const arena = scratch.allocator();

    var an = try Analysis.buildStructure(arena, mir);
    try an.buildLiteralFolds(arena, lowered); // §4.2.3 excludes provably untaken runtime errors
    var p: Prover = .{
        .gpa = gpa,
        .arena = arena,
        .mir = mir,
        .lowered = lowered,
        .unknown_bound = if (options.unknown_bound) |b| (if (math.isNan(b)) null else b) else null,
        .bag = bag,
        .an = an,
    };
    try seed.seedValues(&p); // §3.4.2 param ranges, §4.2 constants, §4.4 probes
    try guards.buildClasses(&p); // structural congruence, so guards reach every copy
    try guards.markSelectArms(&p); // §4.2.12 `?:` guards its own arms
    try walk.walk(&p); // the one linear pass: intervals + domain checks

    const modes = try gpa.alloc(FloatMode, unitCount(lowered));
    errdefer gpa.free(modes);
    try verdict.rateUnits(&p, modes); // per-unit join over the backward slices

    assert(modes.len == unitCount(lowered));
    assert(p.error_count <= errors_max);
    return .{ .unit_modes = modes, .error_count = p.error_count };
}

/// Returns the number of units, the length of `Verdict.unit_modes`.
/// `names.assertCanonicalOrder` asserts that codegen agrees.
pub fn unitCount(lowered: *const Lowered) usize {
    return lowered.contributions.items.len;
}

test FloatMode {
    // `.strict` absorbs, in either position: the four-row truth table.
    try std.testing.expectEqual(FloatMode.optimized, FloatMode.strictest(.optimized, .optimized));
    try std.testing.expectEqual(FloatMode.strict, FloatMode.strictest(.optimized, .strict));
    try std.testing.expectEqual(FloatMode.strict, FloatMode.strictest(.strict, .optimized));
    try std.testing.expectEqual(FloatMode.strict, FloatMode.strictest(.strict, .strict));
}

test {
    // The prover's passes, so their tests and decls are analysed with it.
    _ = @import("walk.zig");
    _ = @import("domain.zig");
    _ = @import("message.zig");
    _ = @import("verdict.zig");
}
