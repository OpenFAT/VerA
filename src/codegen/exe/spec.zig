//! The testbench spec, types only: what a fixture's `//!` lines say (`Spec`),
//! split by reader (`Bench`, what a runner renders; `Harness`, what the
//! caller compiles, runs and judges with), and `Facts`, what the caller
//! copies in from the compile. `parse.zig` writes a `Spec`; the renderers
//! read a `Bench` and its `Facts`.
//! Cites: §2.4, §2.9.2, §3.4, §3.6.1.2, §4.5.2, §4.6.1, §4.6.3, §4.6.4,
//! §4.6.4.1-.6, §5.6, §5.6.1.2, §5.10, §6.3.4, §7.2.2, §7.3, §7.4.4, §7.8.4,
//! §8.2, §8.5, §9.4, §9.10, §9.15, §9.17.3; Annex E.
//!
//! Contents:
//! - `pub const points_max: u32`
//! - `pub const ParseError = Allocator.Error || error{ UnknownDirective, BadNumber, BadSyntax, BadLrmSection, BadUnknownName }`
//! - `pub const RenderError = Allocator.Error || error{ WriteFailed, TooManyPoints }`
//! - `pub const Diagnostics = struct { line: u32 }`
//! - `pub const Spec = struct { bench: Bench, harness: Harness }`, `Spec.parse`
//! - `pub const Bench = struct`
//! - `pub const Harness = struct`
//! - `pub const Facts = struct`
//! - `pub const Mixed = struct`
//! - `pub const Binding = struct { name, value }`
//! - `pub const Sweep = struct { name, values }`
//! - `pub const LimitCase = struct { old, want }`
//! - `pub const Analysis = enum`, `pub const Print = enum { residual, none }`
//! - `pub const NoiseWant = struct`, `NoiseWant.Interp`, `NoiseWant.Corr`, `NoiseWant.needsPoint(w: NoiseWant) bool`
//! - `pub const AcWant = struct`, `AcWant.needsPoint(w: AcWant) bool`
//! - `pub const AcDynWant = struct`

const std = @import("std");
const Allocator = std.mem.Allocator;
const Lowered = @import("ir").Lowered;

/// Most operating points one bench may expand to: the product of every
/// `sweep` and `psweep` length (`error.TooManyPoints` past it). Each point is
/// a straight-line block of the runner's source, so this bounds its size.
pub const points_max: u32 = 4096;

/// Every way `Spec.parse` fails. The failing line is in `Diagnostics.line`;
/// `arena` may hold the partial result, nothing else is written.
pub const ParseError = Allocator.Error || error{
    /// A `//!` line opened with a word that is no directive. Refused so a
    /// typo cannot silently check nothing.
    UnknownDirective,
    /// An operand was not a number, or not the plain decimal digits a count
    /// or an exit status takes.
    BadNumber,
    /// An operand does not have its directive's documented form (a missing
    /// `name = value`, an unknown field key, an empty name), or two lines
    /// contradict each other (`reject` beside `checks`, `warn` beside `nowarn`).
    BadSyntax,
    /// A `//! lrm` or `//! inherited` cite is not a section number.
    BadLrmSection,
    /// A `bias`/`sweep`/`wave`/`seed`/`abstol`/`limit` line named something
    /// that is not a solver unknown, such as the branch potential `V(a,c)`.
    BadUnknownName,
};

/// Every way a renderer fails. Nothing is written on `TooManyPoints`; on
/// the others the writer holds a prefix of the runner. `OutOfMemory` is the
/// mixed runner's `scratch` running out.
pub const RenderError = Allocator.Error || error{
    /// The writer failed (an `Allocating` writer's out of memory).
    WriteFailed,
    /// The `sweep` and `psweep` lengths multiply past `points_max`.
    TooManyPoints,
};

/// Where `Spec.parse` failed, filled only on error.
pub const Diagnostics = struct {
    /// 1-based line of the rejected directive; 0 when two lines contradict
    /// each other and no one line is at fault. Saturates past 2^32 - 1.
    line: u32 = 0,
};

/// Everything the `//!` lines of one fixture said. With no directives the
/// fixture runs one point, every unknown at zero and every parameter at its
/// §3.4 default. Every slice points into the arena `parse` was given, so a
/// `Spec` must not outlive it.
pub const Spec = struct {
    bench: Bench = .{},
    harness: Harness = .{},

    /// Parses the `//!` lines of RAW source (`parse.zig`).
    pub const parse = @import("parse.zig").parse;
};

/// What a runner renders: the card, the operating points, and the device
/// tables to check. Invariants `parse` establishes and the renderers assert:
/// `times_s` is non-empty, finite and strictly increasing; every `Sweep` has
/// at least one value.
pub const Bench = struct {
    /// §3.4 parameter overrides, in source order. A name is the parameter's
    /// source name and its `Model` field at once, so a host-written field
    /// (`gmin__`) is named as the device spells it.
    params: []const Binding = &.{},
    /// Unknowns held at a fixed value across the whole run. A name is a `U`
    /// member, resolved by the access-function rule (`V(a)`, `I(a,b)`, `x[a]`).
    bias: []const Binding = &.{},
    /// Swept unknowns: the operating points are the cartesian product of
    /// `sweeps` then `psweeps`, the last line varying fastest.
    sweeps: []const Sweep = &.{},
    /// §8.2 swept parameters: each point gets its own card and §6.3.4 `derive`.
    psweeps: []const Sweep = &.{},
    /// Per-timepoint values of an unknown, one per `times_s` entry; a short
    /// list holds its last value.
    waves: []const Sweep = &.{},
    /// §9.10 `$temperature`, in kelvin.
    temperature_k: f64 = 300.15,
    /// §9.10 `$abstime` values. Each operating point runs once per time, `dt`
    /// from the previous entry (§4.5.3), so §4.5 operators see a history.
    times_s: []const f64 = &.{0.0},
    /// §4.6.1. Unwritten: `.tran` under a grid of two or more times, else `.dc`.
    analysis: Analysis = .dc,
    /// §9.15 Table 9-28 `analysis_name`; empty means the kind's spelling.
    analysis_name: []const u8 = "",
    /// `//! solve`: unknowns no directive names are solved by Newton (§5.6);
    /// otherwise every unnamed unknown is tied to the reference.
    solve_free: bool = false,
    /// What the runner prints besides the model's own output and the gates.
    print: Print = .residual,
    /// §4.6.4 the expected `noise_gens` rows in table order; null when no
    /// `//! noise` line was written, empty for `//! noise none`.
    noise: ?[]const NoiseWant = null,
    /// §4.6.3 the expected `ac_gens` rows; null and empty as `noise`.
    acstim: ?[]const AcWant = null,
    /// `//! acdyn` lines, in source order.
    acdyn: []const AcDynWant = &.{},
    /// §5.6.1.2 the expected charge sites in slot order, each in the form the
    /// runner prints (`g+ s- lte`; another weight as `g*0.5`); null and empty
    /// as `noise`.
    qsites: ?[]const []const u8 = null,
    /// §9.17.3 exactly the lanes `seed` returns non-null, with their values;
    /// null and empty as `noise`.
    seeds: ?[]const Binding = null,
    /// §2.9.2 the expected `decl_meta` rows, each as the runner prints one
    /// (`kind name desc="..." units="..."`); null and empty as `noise`.
    meta: ?[]const []const u8 = null,
    /// §3.6.1.2 the tolerance the device publishes per named unknown.
    abstols: []const Binding = &.{},
    /// §9.17.3 `limit` cases, each run at the first point's solution.
    limits: []const LimitCase = &.{},
};

/// What the caller compiles, runs and judges with; no renderer reads it.
pub const Harness = struct {
    /// Expected normal exit status; a signal always fails the fixture.
    expected_exit: u8 = 0,
    /// Exact number of runtime verdict columns across the run, when stated.
    expected_checks: ?u32 = null,
    /// Runtime argv entries in source order, each printable ASCII starting
    /// with `+` and holding another byte; no quoting or expansion.
    plusargs: []const []const u8 = &.{},
    /// Annex E `//! spice` netlist lines joined with `\n`, verbatim.
    spice: []const u8 = "",
    /// §7.4.4 the mode the fixture is compiled in.
    discipline_resolution: Lowered.DisciplineResolution = .basic,
    /// §9.4 the device records its display tasks (`--display=record`).
    display_record: bool = false,
    /// `//! reject` substrings: non-empty makes this a fixture that must not
    /// compile, every substring appearing in the diagnostics.
    reject: []const []const u8 = &.{},
    /// `//! reject-only`: every error must also match one of `reject`.
    reject_only: bool = false,
    /// `//! reject-run` substrings: the run (not the compile) refuses, exits
    /// `expected_exit` (non-zero) and prints an `error[...]` line per entry.
    reject_run: []const []const u8 = &.{},
    /// Legal twins of a refusal, relative to the fixture's directory.
    neighbours: []const []const u8 = &.{},
    /// Substrings each matching a warning the compile reported.
    warn: []const []const u8 = &.{},
    /// `//! nowarn`: the compile reports no warning at all.
    nowarn: bool = false,
    /// The clauses this fixture pins (`5.8`, `5.6.1.3:2`); no verdict reads them.
    lrm: []const []const u8 = &.{},
    /// `//! xfail` reason: a requirement VerA does not meet yet.
    xfail: ?[]const u8 = null,
    /// `//! fd-exempt` reason: the `--certify` gates do not apply.
    fd_exempt: ?[]const u8 = null,
};

/// What the caller learns from the compile and hands a renderer beside the
/// `Bench` (`compileFacts` fills the first three).
pub const Facts = struct {
    /// The discrete half to drive from `sim.mixed`, or null for the
    /// fixed-grid runner (`mixedPlan`).
    mixed: ?Mixed = null,
    /// §4.5.2 operator unknowns' `U` indices, ascending; never forced.
    op_states: []const u32 = &.{},
    /// Bytes of §3.2.2 memory-backed arrays an `eval` frame holds.
    mem_bytes: u64 = 0,
    /// The runner declares `vera_validate_contract` (`--validate-contract`).
    validate_contract: bool = false,
    /// The suite's `--certify`: the runner's FD, finite and state gates run.
    certify: bool = false,
    /// Every contribution unit was proved finite, the claim `certify` tests.
    finite_proved: bool = false,
};

/// What a mixed-signal runner needs from the compile besides the device: the
/// digital half to re-elaborate at startup (VAMS §7.2.2), and which device
/// fields carry its discrete values. A view: every slice borrows from the
/// `Lowered` and `Mir` it was taken from (`mixedPlan`).
pub const Mixed = struct {
    /// The compile's preprocessed text; `sim.digital.elaborate` parses it again.
    source: []const u8,
    /// The root module the device was lowered from.
    top: []const u8,
    /// IEEE 1364 §19.8 `timescale events at offsets into `source`.
    timescales: []const Lowered.TimescaleEvent,
    /// Digital-owned names the analog block reads, each a `Model` field.
    inputs: []const []const u8,
    /// §8.5.3.6 names read under an explicit D2A event (`<name>__1b` fields).
    snaps: []const []const u8 = &.{},
    /// §7.3.2 inputs read four-state, each with a `<name>__xz` field.
    xz: []const []const u8 = &.{},
    /// §7.3.1 `reg` inputs wider than 32 bits, parallel to their word counts.
    wide: []const []const u8 = &.{},
    words: []const u32 = &.{},
    /// §8.5 the explicit D2A terms, in site order.
    events: []const Lowered.DiscreteEvent = &.{},
    /// §7.8.4 the inserted connect modules the source hierarchy lacks.
    inserts: []const Lowered.Inserted = &.{},
    /// §7.3.6.4 analog variables a digital expression reads.
    reads: []const []const u8 = &.{},
    /// §7.3.3 digital probe terminals, parallel to their node pairs.
    probe_names: []const []const u8 = &.{},
    probe_nodes: []const [2][]const u8 = &.{},
    /// §5.10 held variables: the `Instance` fields a read is copied from.
    held: []const Lowered.HeldVar = &.{},
    /// §6.3.4 the card's parameters, and the names the discrete source reads.
    params: []const Lowered.ParamInfo = &.{},
    param_reads: []const []const u8 = &.{},
};

/// One `name = value` binding: a parameter card value or a pinned unknown.
pub const Binding = struct { name: []const u8, value: f64 };

/// One `sweep`/`psweep`/`wave` line: a name and its values, never empty.
pub const Sweep = struct { name: []const u8, values: []const f64 };

/// One `//! limit` line: the `old` lanes that differ from `cur`, and the
/// wanted outputs, where the name `converged` is the verdict pseudo-lane.
pub const LimitCase = struct { old: []const Binding, want: []const Binding };

/// §4.6.1 analysis kinds, spelled as the generated `AnalysisKind` enum does.
pub const Analysis = enum { static, ic, nodeset, dc, tran, ac, noise };

/// `//! print residual|none`: `none` leaves only the model's own output,
/// the gates' FAILs and `next_bp`.
pub const Print = enum { residual, none };

/// One `//! noise` row (§4.6.4). Fields after `topo` assert nothing when
/// absent. `topo` is checked against `noise_gens` at comptime; `white`,
/// `flicker`, `ef` and `corrs` are read from `noisePsd` at the first point.
pub const NoiseWant = struct {
    /// `kind(row,col)#source`, verbatim, compared byte-exact with the
    /// device's own spelling of the row.
    topo: []const u8,
    /// §4.6.4.1-.3 the source label, byte-exact; empty asserts no label.
    name: ?[]const u8 = null,
    /// §4.6.4.1/.2 the effective density including §4.6.4.6's `coeff²`.
    white: ?f64 = null,
    flicker: ?f64 = null,
    /// §4.6.4.2 the flicker exponent, unscaled.
    ef: ?f64 = null,
    /// Relative tolerance of every number on this row.
    rtol: f64 = 1e-12,
    /// §4.6.4.3/.4 the table's interpolation.
    interp: ?Interp = null,
    /// §4.6.4.3/.4 the table's exported knots, sorted by frequency.
    points: ?[]const [2]f64 = null,
    /// §4.6.4.3/.4 `<f>:<S>` pairs: the table's own density at f.
    psd: ?[]const [2]f64 = null,
    /// §4.6.4.6 the correlation coefficient with other rows.
    corrs: []const Corr = &.{},

    /// §4.6.4.3 `linear` or §4.6.4.4 `log`, spelled as `contract` tags it.
    pub const Interp = enum { linear, log };

    /// One `corr=<j>:<rho>` field.
    pub const Corr = struct {
        /// The other row, by its index in `noise_gens`.
        with: u16,
        rho: f64,
    };

    /// Returns whether this row asserts a bias-dependent number, which the
    /// runner reads at an operating point.
    pub fn needsPoint(w: NoiseWant) bool {
        return w.white != null or w.flicker != null or w.ef != null or w.corrs.len != 0;
    }
};

/// One `//! acstim` row (§4.6.3). `topo` and `name` are checked against
/// `ac_gens` at comptime; `mag` and `phase` are read at the first point.
pub const AcWant = struct {
    /// `(row,col)` without spaces, compared byte-exact.
    topo: []const u8,
    /// §4.6.3 `analysis_name`, byte-exact.
    name: ?[]const u8 = null,
    /// §4.6.3 magnitude and phase (radians).
    mag: ?f64 = null,
    phase: ?f64 = null,
    /// Relative tolerance of `mag` and `phase`.
    rtol: f64 = 1e-12,

    /// Returns whether this row reads the card, which needs a point.
    pub fn needsPoint(w: AcWant) bool {
        return w.mag != null or w.phase != null;
    }
};

/// One `//! acdyn` row: `acDyn`'s term at local Jacobian entry (row, col),
/// `U` tag names, at ω = 2πf and the first point. An unlisted slot reads 0.
pub const AcDynWant = struct {
    row: []const u8,
    col: []const u8,
    f_hz: f64,
    re: f64,
    im: f64,
    /// Absolute tolerance on each part.
    tol: f64 = 1e-12,
};
