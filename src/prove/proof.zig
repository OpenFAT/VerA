//! Numerical-safety pass: MIR and `Lowered` in, a float-mode `Verdict` per contribution unit out,
//! plus a compile error for any argument provably outside its math-function domain.
//! LRM §4.3.1/§4.3.2 (Tables 4-14/4-15), §4.2.4, §3.4.2, §3.6.1.2, §4.5.15, §5.8.4.
//! Domain checks are three-way: provably outside is an error, provably inside keeps `.optimized`,
//! unprovable is accepted and costs `.strict`. `exp` and `/` by zero are never errors.
//! The pass reads no target, inserts no clamp or `limexp`, and emits no runtime check.
//!
//! Layout: this file is the API and the spine (`proveOpts`). `prove/lattice.zig` holds the
//! interval values, `prove/transfer.zig` the per-opcode transfer functions, `prove/prover.zig`
//! the walk and the diagnostics; the source-level self-checks are `tests/unit.zig`'s
//! `proof_tests`.
//!
//! LRM clauses this file's code cites: §3.4, §4.2, §4.2.3, §4.2.5, §4.2.8,
//! §4.2.12, §4.3, §4.4, §5.4.3, §5.6.1.3, §5.6.7.

const std = @import("std");
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const Analysis = @import("analysis.zig");
const diag = @import("diag");
const proof_lattice = @import("lattice.zig");
const proof_prover = @import("prover.zig");

/// The float mode a unit's code may compile in (LRM §4.3).
/// `.optimized` asserts nnan and ninf, so a wrong `.optimized` is silent undefined behavior in
/// release builds, and every finiteness rule errs toward `.strict`:
///  1. Solver unknowns (§4.4) and model-card parameters (§3.4) are finite doubles by the host
///     contract; a probe's magnitude is still unknown. A parameter whose range admits `inf` is not
///     finite.
///  2. `exp`, `expm1`, `sinh`, `cosh` and `pow` overflow at device magnitudes, so their result is
///     finite only for a bounded argument.
///  3. `+ - * /` on finite operands do not overflow.
///  4. A `call` the prover does not model is not finite.
pub const FloatMode = enum {
    /// Proven finite: codegen emits `@setFloatMode(.optimized)`.
    optimized,
    /// Not provably finite: `@setFloatMode(.strict)`, where inf and NaN are IEEE-defined. Not an error.
    strict,

    /// Returns the mode for code shared by both units: `.strict` absorbs.
    /// A subexpression shared with a `.strict` unit stays reachable from it, so compiling it
    /// fast-math would assert a finiteness fact that unit never had. Codegen folds the shared
    /// core's mode through this join (`codegen/float/mode.zig` `coreMode`).
    pub fn strictest(a: FloatMode, b: FloatMode) FloatMode {
        return if (a == .strict or b == .strict) .strict else .optimized;
    }
};

/// The prover's result: one float mode per contribution unit and the domain-error count.
pub const Verdict = struct {
    /// `unit_modes[i]` rates `lowered.contributions.items[i]`: one unit per access and node pair
    /// (§5.6.1.3), or per statement for a §5.6.7 indirect contribution. A unit is `.optimized`
    /// only if both its `resist_val` and `react_val` slices are proven finite. §5.4.3 port probes
    /// add no unit. Any new unit kind must be appended after the contribution units.
    /// Allocated with the `gpa` passed to `proveOpts`; free with `deinit`.
    unit_modes: []const FloatMode,
    /// §4.3.2 domain violations reported into the `diag.Bag`, at most `max_errors`. Zero means
    /// the model is accepted. On errors `unit_modes` is still filled, all `.strict`, so a lint
    /// front end reports everything in one pass.
    error_count: u32,

    /// Returns true when no domain error was reported.
    pub fn ok(self: Verdict) bool {
        return self.error_count == 0;
    }

    /// Frees `unit_modes`; `gpa` must be the allocator passed to `proveOpts`.
    pub fn deinit(self: Verdict, gpa: std.mem.Allocator) void {
        gpa.free(self.unit_modes);
    }
};

/// Prover knobs.
pub const Options = struct {
    /// A host bound B with |unknown| <= B for every solver unknown. It makes probe-dependent
    /// transcendentals provable. `null` means unbounded but still finite (rule 1 on `FloatMode`).
    /// This is the hardware knob: a real solver has a compliance limit no language rule can see.
    unknown_bound: ?f64 = null,
};

/// Maximum domain errors counted and reported; one bad expression otherwise reports a cascade.
/// Violations past the cap are neither counted nor reported, so `Verdict.error_count` saturates
/// here.
pub const max_errors = 64;

/// Returns the number of units, the length of `Verdict.unit_modes`.
/// `names.assertCanonicalOrder` asserts that codegen agrees.
pub fn unitCount(lowered: *const Lowered) usize {
    return lowered.contributions.items.len;
}

/// Returns whether a value is a 0/1 predicate (§4.2.5/§4.2.8).
pub const isPredicateValue = proof_lattice.isPredicateValue;
/// Returns the LRM domain an opcode's argument must satisfy.
pub const domainOf = proof_lattice.domainOf;

/// Proves every §4.3.2 domain, reports violations (E0601-E0607, E0609) and finiteness lints
/// (W0650, W0651, W0653) into `bag`, and rates each unit.
/// Caller owns the returned `Verdict` and must free it with `deinit(gpa)`.
/// Fails only on allocation; scratch state lives in an arena on `gpa` that dies before return.
/// Reads `mir` and `lowered` only, so proving the same input twice gives the same verdict.
pub fn proveOpts(
    gpa: std.mem.Allocator,
    mir: *const Mir,
    lowered: *const Lowered,
    opts: Options,
    bag: *diag.Bag,
) !Verdict {
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();

    var p: proof_prover.Prover = .{
        .gpa = gpa,
        .arena = scratch.allocator(),
        .mir = mir,
        .lowered = lowered,
        .opts = opts,
        .bag = bag,
    };

    p.an = try Analysis.buildStructure(p.arena, mir, lowered);
    try p.an.buildLiteralFolds(); // §4.2.3 excludes provably untaken runtime errors

    try p.seedValues(); // §3.4.2 param ranges, §4.2 constants, §4.4 probes
    try p.buildClasses(); // structural congruence, so guards reach every copy
    try p.markSelectArms(); // §4.2.12 `?:` guards its own arms
    try p.walk(); // the one linear pass: intervals + domain checks
    const v = try p.verdict(); // per-unit join over the backward slices
    std.debug.assert(v.unit_modes.len == unitCount(lowered));
    std.debug.assert(v.error_count <= max_errors); // `Verdict.error_count` saturates
    return v;
}

test FloatMode {
    // `.strict` absorbs, in either position.
    try std.testing.expectEqual(FloatMode.optimized, FloatMode.strictest(.optimized, .optimized));
    try std.testing.expectEqual(FloatMode.strict, FloatMode.strictest(.optimized, .strict));
    try std.testing.expectEqual(FloatMode.strict, FloatMode.strictest(.strict, .optimized));
    try std.testing.expectEqual(FloatMode.strict, FloatMode.strictest(.strict, .strict));
}

test {
    _ = proof_lattice;
    _ = proof_prover;
    _ = @import("transfer.zig");
}
