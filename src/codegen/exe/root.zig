//! Testbench generation: a .va's `//!` directives in, a runner program out
//! that is built with the `display = .emit` device and prints a transcript
//! (every `$strobe`, plus residual and Jacobian per operating point).
//! Directives are comments (§2.4) so a fixture stays one portable .va file.
//! Sweeps are expanded here, so the runner is straight-line code whose output
//! order is the text's. LRM: §9.4.
//!
//! The pipeline a caller runs (`src/main.zig --emit-exe`, `tests/suite.zig`):
//! `parse` the raw source; compile the device, again with `shapeOverrides`
//! when a `//! param` names a shape parameter; fill the non-directive fields
//! of `Directives` (`opStates`, `mixedPlan`); `renderRunner` (or
//! `renderVpiLib`); then `buildExe`, or `stageExe` and `buildBatch` for many.
//! This file owns the directive types; `tb/directive.zig` parses them,
//! `tb/runner.zig` renders them over the fixed text in `tb/runner_text.zig`,
//! and `zigbuild` (`src/zigbuild/exe.zig`) builds the result.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Lowered = @import("ir").Lowered;

/// Errors from directive parsing and point expansion.
pub const Error = Allocator.Error || error{
    /// A `//!` line named an unknown directive. Refused so a typo cannot
    /// silently check nothing.
    UnknownDirective,
    /// A directive's operand was not a number, or not the plain decimal
    /// digits a count or an exit status takes.
    BadNumber,
    /// A directive's operands do not have its documented form (a missing
    /// `name = value`, an unknown field key, an empty name), or two lines
    /// contradict each other (`reject` beside `checks`, `warn` beside
    /// `nowarn`).
    BadSyntax,
    /// The cartesian product of the `sweep` lines exceeded `max_points`.
    TooManyPoints,
    /// A `//! lrm` cite is not a section number: see `validSection`.
    BadLrmSection,
    /// A `bias`/`sweep`/`wave` line named something that is not a solver
    /// unknown, such as the branch potential `V(a,c)`.
    BadUnknownName,
};

/// One `name = value` binding: a model parameter, or a fixed unknown.
pub const Binding = struct { name: []const u8, value: f64 };

/// One `//! limit` line: the `old` lanes that differ from `cur`, and the
/// wanted outputs, where `converged` names the verdict pseudo-lane.
pub const LimitCase = struct { old: []const Binding, want: []const Binding };

/// One `//! sweep <unknown> = v, v, …` line.
pub const Sweep = struct { name: []const u8, values: []const f64 };

/// §4.6.1 analysis kinds, spelled as the generated `AnalysisKind` enum does.
pub const Analysis = enum { static, ic, nodeset, dc, tran, ac, noise };

/// Everything the `//!` lines of one fixture said. With no directives the
/// fixture runs one point, every unknown at zero and every parameter at its
/// §3.4 default. Slices are owned by the arena `parse` was given.
pub const Directives = struct {
    /// §3.4 parameter overrides, in source order. A name is the parameter's
    /// source name and its `Model` field at once, so a host-written field
    /// (`gmin__`) is named as the device spells it.
    params: []const Binding = &.{},
    /// Unknowns held at a fixed value across the whole sweep. A name is a
    /// `U` member, resolved by the parser's access-function rule
    /// (`V(a)`, `I(a,b)`, `x[a]`).
    bias: []const Binding = &.{},
    /// Swept unknowns. The operating points are the cartesian product, last
    /// line varying fastest.
    sweeps: []const Sweep = &.{},
    /// §9.10 `$temperature`, in kelvin.
    temp: f64 = 300.15,
    /// §9.10 `$abstime` values, finite and strictly increasing. Each operating point
    /// runs once per time, with `dt` from the previous entry (§4.5.3) and
    /// `updateState` after each, so §4.5 stateful operators see transient
    /// history. `sim.mixed.run` takes the same list and requires the order.
    times: []const f64 = &.{0.0},
    /// Per-timepoint values for an unknown: `//! wave V(in) = 0, 1, 1, 0`, one
    /// entry per `//! time`. A short list holds its last value.
    waves: []const Sweep = &.{},
    /// Swept parameters (§8.2 parametric sweep): each point gets its own model
    /// card and `derive` (§6.3.4). Varies fastest in the cartesian product.
    psweeps: []const Sweep = &.{},
    /// §4.6.1. Unwritten, `.tran` under a `//! time` grid, else `.dc`.
    analysis: Analysis = .dc,
    /// §9.15 Table 9-28 `analysis_name`, the optional second word of
    /// `//! analysis`; empty means the kind's spelling ("dc", "tran", "ac"),
    /// the name §4.6.3's `ac_stim` defaults to.
    analysis_name: []const u8 = "",
    /// `//! solve`: unknowns no other directive names are solved by Newton on
    /// the device's own residual (§5.6). Off by default, every unnamed unknown
    /// is tied to the reference, so `//! bias V(p) = 0.5` on a resistor puts
    /// 0.5 V across it. Needed where the target is a solution, as in §5.6.7's
    /// indirect contribution.
    solve_free: bool = false,
    /// Print the residual and its Jacobian after each point's display output.
    /// `//! print none` leaves only the model's own output.
    print_residual: bool = true,
    /// Expected normal process exit status; signals always fail the fixture.
    expected_exit: u8 = 0,
    /// Optional exact number of runtime verdict columns across the whole run.
    /// A missing or duplicated check must not pass an exhaustive inventory.
    expected_checks: ?usize = null,
    /// Runtime argv entries, in source order. Repeatable `//! plusargs` lines
    /// split on ASCII space/tab only; no quoting, escaping or shell expansion.
    /// Each printable-ASCII token starts with '+' and contains another byte.
    plusargs: []const []const u8 = &.{},
    /// `//! spice <netlist line>` lines joined with newlines in source order:
    /// the Annex E SPICE netlist the fixture is compiled against. Verbatim,
    /// `+` continuations included; `spice_cards.synthesize` reads it.
    spice: []const u8 = "",
    /// `//! discipline-resolution basic|detail`: the §7.4.4 mode the fixture
    /// is compiled in (`vera --discipline-resolution=`).
    discipline_resolution: Lowered.DisciplineResolution = .basic,
    /// `//! display record`: the testbench is built over a device that
    /// records its §9.4 display tasks (`contract.SaySite`) and prints what
    /// `say` records (`vera --emit-exe --display=record`), not one that prints.
    display_record: bool = false,
    /// `//! noise <kind>(<row>,<col>)#<source>`, one per expected `noise_gens`
    /// entry, in table order; `//! noise none` asserts an empty table. Equal
    /// `#k` on two lines assert one shared generator (§4.6.4.6), distinct `#k`
    /// independence. §4.6.4 generators read 0 outside small-signal analysis
    /// (§4.6.2), so the published table is what a fixture asserts. The runner
    /// prints one `got=/want= ok=` line per entry plus one for the count.
    noise: []const NoiseWant = &.{},
    /// Whether any `//! noise` line was written. `//! noise none` asserts an
    /// empty table; an absent directive asserts nothing.
    asserts_noise: bool = false,
    /// `//! acstim (<row>,<col>) [name=<analysis>] [mag=<v>] [phase=<v>]`, one
    /// per expected `ac_gens` entry, in table order; `//! acstim none` asserts
    /// an empty table. A §4.6.3 stimulus is a phasor that only a host sees
    /// (`ac_gens`/`acStim`), so the published table is what a fixture asserts.
    acstim: []const AcWant = &.{},
    /// Whether any `//! acstim` line was written (see `asserts_noise`).
    asserts_acstim: bool = false,
    /// `//! acdyn` lines, in source order (`AcDynWant`).
    acdyn: []const AcDynWant = &.{},
    /// `//! qsite <row><sign>... lte|nolte`, one per expected §5.6.1.2 charge
    /// site in slot order; `//! qsite none` asserts none. Each names the rows
    /// the site stamps and their sign (`g+ s-`; another weight prints as
    /// `g*0.5`) and whether `q_lte` checks it (`contract.QStamp`).
    qsites: []const []const u8 = &.{},
    /// Whether any `//! qsite` line was written (see `asserts_noise`).
    asserts_qsite: bool = false,
    /// `//! seed V(a) = v, ...`: exactly the lanes the device's §9.17.3 cold
    /// start (`seed`) returns non-null, with their values; every other lane
    /// must be null, and every non-null one must be in `limit_writes`.
    /// `//! seed none` asserts no lane is seeded. Lines accumulate.
    seeds: []const Binding = &.{},
    /// Whether any `//! seed` line was written (see `asserts_noise`).
    asserts_seed: bool = false,
    /// `//! meta <kind> <name> [desc="..."] [units="..."]`, one per expected
    /// `decl_meta` row (`contract.DeclMeta`) in table order, stored in the
    /// form the runner prints a row (`kind name desc="..." units="..."`, the
    /// two fields in that order and only when present). `//! meta none`
    /// asserts no row. §2.9.2's `desc`/`units` reach only a host, so the
    /// published table is what a fixture asserts.
    meta: []const []const u8 = &.{},
    /// Whether any `//! meta` line was written (see `asserts_noise`).
    asserts_meta: bool = false,
    /// `//! abstol <unknown> = v, ...`: the §3.6.1.2 tolerance the device
    /// publishes for each named unknown (`u_abstol`). Lines accumulate.
    abstols: []const Binding = &.{},
    /// `//! limit V(a) = v, ... -> V(b) = w, ..., converged = 0|1`, one case per
    /// line: `limit` run at the first point's `x` as `cur`, with `old` = `cur`
    /// except the lanes left of `->`, must return the lanes right of it (and
    /// the verdict, if named). The testbench never limits on its own, so a
    /// published clamp is observable only through this.
    limits: []const LimitCase = &.{},
    /// `//! reject <substring>`, one per line. Non-empty makes this a reject
    /// fixture: it must not compile, and every substring must appear in the
    /// diagnostics.
    reject: []const []const u8 = &.{},
    /// `//! reject-only <substring>`: a `reject` line whose substrings must
    /// also match EVERY error the compile reported, so an incidental error
    /// on legal source cannot ride inside a passing refusal.
    reject_only: bool = false,
    /// `//! reject-run <substring>`, one per line: a refusal the TESTBENCH
    /// makes, not the compiler. The fixture compiles and runs; the run must
    /// exit nonzero (`expected_exit`, 1 unless `//! exit` says otherwise) and
    /// print an `error[...]` line holding each substring, and every
    /// `error[...]` line it prints must hold one of them (`reject-only`'s
    /// rule, always on). The `ok=` lines printed before the refusal are
    /// judged as a positive fixture's are. Never with `reject`.
    reject_run: []const []const u8 = &.{},
    /// `//! neighbour <path>`, one per line, relative to the fixture's
    /// directory: the legal variant of a refused construct, which must be a
    /// collected fixture that compiles and asserts. Only on a reject fixture.
    neighbours: []const []const u8 = &.{},
    /// `//! warn <substring>`, one per line: each must match a WARNING the
    /// compile reported, by code or text as `reject` matches. The fixture
    /// still compiles and runs; a warning nobody named does not fail it.
    warn: []const []const u8 = &.{},
    /// `//! nowarn`: the compile reports no warning at all. Never with `warn`.
    nowarn: bool = false,
    /// `//! lrm <section>`, one per line: the clauses this fixture pins. No
    /// verdict depends on it; failure reports and `--coverage` read it.
    /// `<section>:<n>` pins the n-th normative sentence of the clause, a row
    /// of `tests/conformance/vera/ledger/OBLIGATIONS.tsv`.
    lrm: []const []const u8 = &.{},
    /// `//! xfail <reason>`: the fixture states an LRM requirement VerA does
    /// not meet yet. With `reject`, VerA wrongly accepts the construct;
    /// without, VerA cannot yet compile and pass a legal example.
    xfail: ?[]const u8 = null,
    /// Not a directive: set by the caller from the compile (`mixedPlan`) when
    /// the module has a discrete half, so the runner drives the device from
    /// `sim.mixed` instead of fixed operating points.
    mixed: ?Mixed = null,
    /// Not a directive: the `U` indices of the §4.5.2 operator unknowns
    /// (`opStates`). Never forced, even without `//! solve`: each row is its
    /// operator's own equation, and a tied one would pin the operator at 0.
    op_states: []const u32 = &.{},
    /// Not a directive: the bytes of the module's §3.2.2 memory-backed
    /// arrays (`memBytes`), which an `eval` frame holds, so the runner can
    /// size its stack for them.
    mem_bytes: u64 = 0,
    /// Not a directive: the runner's root declares `vera_validate_contract`,
    /// so `contract`'s conformance checks run on the device and this host
    /// (`vera --validate-contract`; the fixture suite always sets it).
    validate_contract: bool = false,
    /// Not a directive: the suite's `--certify`. The
    /// runner checks every Jacobian entry against a central difference at
    /// each point (`fdCheck`), a proved-finite device at random points
    /// (`finiteCheck`), and the revert path at each accepted point
    /// (`stateCheck`).
    certify: bool = false,
    /// Not a directive: every contribution unit of the device was proved
    /// finite (`proof.Verdict.unit_modes` all `.optimized`), the claim
    /// `finiteCheck` tests under `certify`.
    finite_proved: bool = false,
    /// `//! fd-exempt <reason>`: the `certify` gates do not apply to this
    /// fixture, by design and for the stated reason (a `vera_nodiff`
    /// region, a limited iterate). Reviewable, never silent.
    fd_exempt: ?[]const u8 = null,
};

/// What a mixed-signal testbench needs from the compile besides the device:
/// the digital half to re-elaborate at startup (VAMS §7.2.2), and which
/// device parameters are its host-written discrete inputs.
pub const Mixed = struct {
    /// The compile's preprocessed text; `sim.digital.elaborate` parses it again.
    source: []const u8,
    /// The root module the device was lowered from.
    top: []const u8,
    /// IEEE 1364 §19.8 the `timescale events at offsets into `source`
    /// (`Lowered.timescales`); empty when the source gave none.
    timescales: []const Lowered.TimescaleEvent,
    /// Digital-owned names the analog block reads, each a `Model` field.
    inputs: []const []const u8,
    /// §8.5.3.6 digital names read under an explicit D2A event, each a
    /// `<name>__1b` `Model` field.
    snaps: []const []const u8 = &.{},
    /// §7.3.2 inputs read four-state, each with a `<name>__xz` `Model` field.
    xz: []const []const u8 = &.{},
    /// §7.3.1 inputs that are a `reg` wider than 32 bits, beside their
    /// number of 32-bit words (`Lowered.discrete_words`).
    wide: []const []const u8 = &.{},
    words: []const u32 = &.{},
    /// §8.5 the explicit D2A terms, in site order.
    events: []const Lowered.DiscreteEvent = &.{},
    /// §7.8.4 the inserted connect modules, which the source hierarchy the
    /// digital half re-elaborates does not hold.
    inserts: []const Lowered.Inserted = &.{},
    /// §7.3.6.4 analog variables a digital expression reads
    /// (`Lowered.discrete_reads`).
    reads: []const []const u8 = &.{},
    /// §7.3.3 digital probe terminals and their node pairs
    /// (`Lowered.discrete_probes`).
    probe_names: []const []const u8 = &.{},
    probe_nodes: []const [2][]const u8 = &.{},
    /// The device's §5.10 held variables: the `Instance` fields a read
    /// variable's value can be copied from.
    held: []const Lowered.HeldVar = &.{},
    /// §6.3.4 model parameters and those the discrete source depends on.
    /// Only the selected real values need transport: the digital engine can
    /// already evaluate its integral parameters and their explicit cards.
    params: []const Lowered.ParamInfo = &.{},
    param_reads: []const []const u8 = &.{},
};

/// One `//! noise` line:
///
///     //! noise <kind>(<row>,<col>)#<src> [name=<s>] [white=<v>] [flicker=<v>]
///                                        [ef=<v>] [corr=<j>:<rho>]... [rtol=<v>]
///     //! noise table(<row>,<col>)#<src> [name=<s>] interp=linear|log
///                                        points=<f>:<p>,<f>:<p>,…
///                                        psd=<f>:<S>,<f>:<S>,…
///
/// Fields after `topo` are optional and assert nothing when absent. `topo` is
/// checked against `noise_gens` at comptime; `white`, `flicker` and `ef` are
/// read from `noisePsd` at the first operating point. A table row is read as
/// a host reads it, `contract.noiseTable` on the derived card.
pub const NoiseWant = struct {
    /// `kind(row,col)#source`, verbatim, compared byte-exact against the
    /// device's own spelling of the row.
    topo: []const u8,
    /// §4.6.4.1/.2/.3 the source label. Byte-exact; `name=` with an empty
    /// value asserts the model supplied no name.
    name: ?[]const u8 = null,
    /// §4.6.4.1 `S(f) = white` and §4.6.4.2 `S(f) = flicker/f^ef`, read from
    /// `noisePsd(...)[k]`. `white` and `flicker` are the effective density
    /// including §4.6.4.6's `coeff²`, not the raw field; `ef` is unscaled.
    white: ?f64 = null,
    flicker: ?f64 = null,
    ef: ?f64 = null,
    /// Relative tolerance for the three above. Tight by default: a fixture
    /// asserts a derived number. A value through §9.15's k or q widens it.
    rtol: f64 = 1e-12,
    /// §4.6.4.3/.4 `noise_tables[noise_gens[k].table.?]`: `interp` is `linear`
    /// (§4.6.4.3) or `log` (§4.6.4.4), and `points` is the exported knot list,
    /// sorted by frequency.
    interp: ?[]const u8 = null,
    points: ?[]const [2]f64 = null,
    /// §4.6.4.3/.4 `psd=<f>:<S>,...`: the table's own density at each
    /// frequency f, `contract.noiseTableAt` over the card's knots, before
    /// §4.6.4.6's `coeff²`. Compared with `rtol`.
    psd: ?[]const [2]f64 = null,
    /// §4.6.4.6 `corr=<j>:<rho>`, repeatable: the correlation coefficient
    /// between this row's contribution and row j's, from the published
    /// table: the sign of `coeff_k · coeff_j` when the rows share a `source`
    /// (one generator, so |ρ| = 1), `PsdTerm.corr` times that sign when one
    /// row's `corr_with` names the other, else 0. Read at the first point,
    /// since a coefficient may depend on the bias. Compared with `rtol`.
    corrs: []const Corr = &.{},

    /// One `corr=<j>:<rho>` field.
    pub const Corr = struct {
        /// The other row, by its index in `noise_gens`.
        with: u16,
        rho: f64,
    };

    /// Returns whether this line asserts a bias-dependent density, which needs
    /// an operating point.
    pub fn needsPoint(self: NoiseWant) bool {
        return self.white != null or self.flicker != null or self.ef != null or self.corrs.len != 0;
    }
};

/// One `//! acstim` line:
///
///     //! acstim (<row>,<col>) [name=<analysis>] [mag=<v>] [phase=<v>] [rtol=<v>]
///
/// Fields after `topo` are optional. `topo` and `name` are checked against
/// `ac_gens` at comptime; `mag` and `phase` may depend on the model card and
/// are read from `acStim(...)` at the first operating point.
pub const AcWant = struct {
    /// `(row,col)` without spaces, compared byte-exact with the device's spelling.
    topo: []const u8,
    /// §4.6.3 `analysis_name`: the small-signal analysis this source is active
    /// in. Byte-exact.
    name: ?[]const u8 = null,
    /// §4.6.3 magnitude and phase (radians), read from `acStim(...)[k]`.
    mag: ?f64 = null,
    phase: ?f64 = null,
    /// Relative tolerance for the two above (see `NoiseWant.rtol`).
    rtol: f64 = 1e-12,

    /// Returns whether this line reads the model card, which needs a point block.
    pub fn needsPoint(self: AcWant) bool {
        return self.mag != null or self.phase != null;
    }
};

/// One `//! acdyn` line:
///
///     //! acdyn (<row>,<col>) f=<Hz> re=<v> im=<v> [tol=<v>]
///
/// `acDyn`'s term at local Jacobian entry (row, col), `U` tag names, at
/// ω = 2πf and the first operating point (`contract.acDynSlots`). A slot the
/// device does not list reads 0.
pub const AcDynWant = struct {
    row: []const u8,
    col: []const u8,
    f: f64,
    re: f64,
    im: f64,
    /// Absolute tolerance on each part.
    tol: f64 = 1e-12,
};

/// Most operating points one fixture may expand to (`error.TooManyPoints`).
pub const max_points: usize = 4096;

// The aliases below are the testbench API, in the order a caller runs them;
// each is documented where it is defined.

const tb_directive = @import("tb/directive.zig");
pub const parse = tb_directive.parse;
/// Whether a `//! lrm` cite is a section number (`Error.BadLrmSection`).
pub const validSection = tb_directive.validSection;

const tb_runner = @import("tb/runner.zig");
pub const shapeOverrides = tb_runner.shapeOverrides;
pub const opStates = tb_runner.opStates;
pub const mixedPlan = tb_runner.mixedPlan;
pub const warnGridEvents = tb_runner.warnGridEvents;
pub const renderRunner = tb_runner.renderRunner;
/// The operating points `sweeps` expand to, in runner order.
pub const expand = tb_runner.expand;
pub const memBytes = tb_runner.memBytes;
pub const renderVpiLib = tb_runner.renderVpiLib;

const zigbuild = @import("zigbuild");
pub const BuildOptions = zigbuild.BuildOptions;
pub const BuildResult = zigbuild.BuildResult;
pub const buildExe = zigbuild.buildExe;
pub const Staged = zigbuild.Staged;
pub const stageExe = zigbuild.stage;
pub const buildBatch = zigbuild.buildBatch;
pub const batch_argv0 = zigbuild.batch_argv0;

test {
    _ = tb_directive;
    _ = tb_runner;
}
