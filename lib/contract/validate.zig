//! A device type in, a compile error naming the first broken contract rule
//! (or nothing) out: `validate(D)`, the spine that runs every rule in order,
//! and the allowlist of the names a device may make `pub`.
//! Cites: every clause the rules cite (`validate_entries.zig`,
//! `validate_tables.zig`, and the tables' own files); §2.9.2, §4.5.11,
//! §4.5.12 for the allowlist's entries.
//!
//! Contents:
//! - `pub fn validate(comptime D: type) void`

const std = @import("std");
const assert = std.debug.assert;
const ac = @import("ac.zig");
const build_config = @import("build_config.zig");
const entries = @import("validate_entries.zig");
const host_fields = @import("host_fields.zig");
const masks = @import("masks.zig");
const noise = @import("noise.zig");
const rows = @import("rows.zig");
const tables = @import("validate_tables.zig");
const shape = @import("validate_shape.zig");
const mocks = @import("mock_devices.zig");
const testing = std.testing;

/// The pub names `validate` accepts. An enum, not a string map: `@hasField`
/// is one lookup, where building a `StaticStringMap` at comptime cost every
/// device build analysis time.
const AllowedPubDecl = enum {
    U,
    num_ports,
    vera_version,
    Model,
    Instance,
    eval,
    q,
    evalQ,
    limit,
    limit_reads,
    limit_writes,
    sim_reads,
    deriv_reads,
    ddx_reads,
    jac_const,
    seed,
    collapse,
    collapse_full,
    initState,
    updateState,
    advanceIteration,
    checkConvergence,
    stateCtl,
    State,
    state_class,
    acceptQ,
    Setup,
    setup,
    setupInstance,
    setup_simparams,
    setup_chunks,
    jac_f32,
    jac_f32_host,
    batch_lead,
    batch_inst,
    // Nothing steers on a `.val()` of an x-dependent value, draws a per-call
    // scalar, or collapses an x-dependent chain to its value.
    batch_ok,
    mutable_eval,
    noiseTablePoints,
    // §9.4 display tasks and §9.5 file I/O, one accepted-point phase (§9.5.9
    // performs file writes only at an accepted point), kept out of `eval` so
    // the residual stays a pure function of x. A device built for a solver has
    // no display phase, and its `$fopen` returns §9.5.1's failure value 0.
    display,
    // §9.4.1/§9.5.9 the same phase by `SayPass`, for `$debug`/`$fdebug`,
    // which show output at every iteration.
    displayPass,
    file_io,
    attempt,
    u_kinds,
    u_abstol,
    u_nodeset,
    decl_meta,
    op_vars,
    opVars,
    instance_params,
    jac_pattern,
    q_pattern,
    jac_rows,
    q_rows,
    n_q,
    q_stamps,
    q_lte,
    q_site_pattern,
    noise_gens,
    noisePsd,
    noise_tables,
    ac_gens,
    acStim,
    ac_dyn_slots,
    acDyn,
    systf_calls,
    status_sites,
    // §9.4 the device's display tasks as records a host renders (`SaySite`).
    say_sites,
    say,
    mc_param,
    derive,
    checkShape,
    checkCard,
    checkRange,
    precompute,
    constant,
    nextBreakpoint,
    pendingBreakpoint,
    delays,
    // Clause 12: the §5.6 contribution rows an analog VPI host reads §12.10's
    // flows from, emitted only under `codegen.Options.vpi_contribs`.
    vpiContribs,
    vpi_contrib_access,
    vpi_contrib_hi,
    vpi_contrib_lo,
    vpi_contrib_flow_u,
    // Each instance's own share of a row several instances' unnamed branches
    // share (§5.4.1), the §11.6.7 flow of that instance's branch; emitted
    // under `vpi_contribs` when a row is shared.
    vpiShares,
    vpi_share_row,
    lane_masks,
};

/// Every rule `validate` applies, in the order it applies them.
const rules = .{
    entries.requiredError,
    entries.unknownsError,
    entries.modelInstanceError,
    host_fields.hostFieldsError,
    entries.residualError,
    rows.qSitesError,
    entries.displayError,
    entries.permissionsError,
    entries.limitError,
    entries.derivReadsRuleError,
    entries.seedCollapseError,
    entries.stateError,
    entries.setupError,
    entries.iterationError,
    tables.unknownTablesError,
    tables.patternError,
    tables.rowsWrittenError,
    noise.noiseGensError,
    tables.vpiError,
    noise.noisePsdError,
    noise.noiseTablesError,
    ac.acGensError,
    ac.acDynError,
    tables.systfTableError,
    tables.cardHooksError,
    tables.breakpointsError,
    strayDeclError,
};

/// Checks device `D` against the contract at comptime; a violation is a compile
/// error naming the decl. Required: `U` (a dense enum, ports first; VerA
/// emits `enum(u8)` up to 256 unknowns, a wider unsigned tag past them),
/// `num_ports` (<= |U|; 0 is legal, §6.2), `Model` and `Instance` (structs
/// whose fields all have defaults and are value types), and
/// `eval(S, x, model, inst, sim) Rows(D, S)`. Every other decl is optional
/// and must be one `validate` knows. The entry points, in the order a host
/// calls them:
///
///   derive(S, *model)            after writing a card, before building instances
///                                (§6.3.4 parameters derived from others, and the
///                                row's sorted noise-table knots, `noiseTable`)
///   checkShape(&model)           after derive; non-null names a §3.4 shape
///                                parameter the card moved, so refuse the card
///   checkCard(&model)            after derive; non-null names a §9.18 system
///                                parameter the card put outside Table 9-29
///                                (optional; the host decides what to do)
///   checkRange(&model)           after derive; non-null names a §3.4
///                                parameter the card put outside its §3.4.2
///                                `from`/`exclude` ranges, so refuse the card
///   setup(S, &model)             after derive, and after every card,
///                                `temperature__` or `setup_simparams` write;
///                                fills `model.su`, once per Model row
///   setupInstance(&model, &inst) per instance after every `setup`, and after
///                                an instance write (optional: drops what the
///                                instance cached from the card)
///   collapse(S, &model, &inst)   once per instance at build: per internal unknown,
///                                the index it merges into, or null
///   initState(&model, &inst)     once per instance, before the first solve, and
///                                at the start of each later analysis: it resets
///                                what `updateState` advances in `inst` (§4.6.2)
///   seed(S, ...)                 once before Newton iteration 1
///   eval / q / evalQ             every iterate; `q` returns one charge per site
///                                (`Sites`), `evalQ` both from one evaluation
///   limit(S, ..., cur, old, sim) every iterate, on the instance's private limited
///                                image; returns `cur` where it does not clamp
///   advanceIteration / checkConvergence
///                                after each iterate / before accepting one
///   updateState(S, ..., x, &state, sim)
///                                at each accepted point; `acceptQ` fuses it with `q`
///   stateCtl(op)                 query, commit or revert the accepted state
///   display(S, &x, ...)          per accepted point, `--display=emit` artifacts only;
///                                a §9.7 `$finish`/`$stop`/`$fatal` exits the process
///   noisePsd / acStim            at any state vector, positional on
///                                `noise_gens` / `ac_gens`; `noisePsd` takes
///                                `eval`'s family, so a §4.5.14 `ddx` in a PSD
///                                argument reads its partial (a family without
///                                lanes reads it as 0)
///   acDyn(F, ..., omega, &out)   per small-signal frequency (or lane of them), positional on
///                                `ac_dyn_slots` (`acDynSlots`)
///   nextBreakpoint / pendingBreakpoint / delays
///                                transient breakpoint scheduling
///
/// The value-only hooks take the same `comptime S` as `eval`, with a family
/// whose `Of(m)` carries no lanes, so the host picks the arithmetic of every
/// path. Optional permissions: `jac_f32` (the host may carry lanes in f32;
/// absent, it must assume f64), `jac_f32_host` (take it on the CPU path too;
/// requires `jac_f32`), `batch_ok` (a family whose `V` holds several operating
/// points evaluates each exactly), `batch_lead` (it does so only through the
/// lead protocol; see `LeadState`), `batch_inst` (each point needs its own
/// `Instance`, through the family's `instLane`; see the lead protocol's
/// batch key), `mutable_eval` (see `InstancePtr`).
pub fn validate(comptime D: type) void {
    if (!build_config.validating) return;
    @setEvalBranchQuota(1_000_000);
    comptime assert(rules.len == 27);
    // In this order: a later rule may read a decl an earlier one checked.
    inline for (rules) |rule| {
        if (rule(D)) |m| @compileError(m);
    }
}

// ---- private ----

fn strayDeclError(comptime D: type) ?[]const u8 {
    const decls = @typeInfo(D).@"struct".decl_names;
    for (decls) |d| {
        if (@hasField(AllowedPubDecl, d)) continue;
        // `<module>__analog_op__{laplace,zi}_*__sec`: a §4.5.11/§4.5.12
        // filter's cascade coefficients, public because a small-signal host
        // builds H(jw) from them. The name embeds the module, so it cannot be
        // listed. TODO: drop once `laplace_*` lowers to internal unknowns and
        // `zi_*` has a complex AC stamp.
        // ponytail: the exemption is suffix-only; endsWith owns the length guard.
        if (std.mem.endsWith(u8, d, "__sec")) continue;
        return @typeName(D) ++ ": stray pub decl `" ++ d ++
            "` — only contract-recognized names may be pub";
    }
    return null;
}

test "validate: minimal resistor" {
    comptime validate(mocks.MockR);
}

test "validate: every contract member at once (allowlist cannot drift)" {
    comptime validate(mocks.MockAll);
    // Every allowlisted name is either declared above or is a required decl
    // mocks.MockAll already has, so an entry added to one and not the other fails.
    comptime for (@typeInfo(AllowedPubDecl).@"enum".field_names) |k| {
        if (!@hasDecl(mocks.MockAll, k))
            @compileError("AllowedPubDecl has `" ++ k ++ "` but mocks.MockAll does not declare it");
    };
}

test "display shapes: the generic 5-param form, wrong arities refused" {
    // A 2-arg `(Model, Instance)` display fails in the RUNNER's build, three
    // cache steps from the device that caused it, so it is refused at the
    // definition.
    const Bad = struct {
        pub const Model = struct {};
        pub const Instance = struct {};
        pub fn display(_: *const Model, _: *const Instance) void {}
        pub fn eval(_: f64) void {} // not generic: first param is not `type`
    };
    try testing.expect(comptime (shape.genericFnError(Bad, "display", "void") != null));
    try testing.expect(comptime (shape.genericFnError(Bad, "eval", "Rows(D, S)") != null));
    // The real shapes pass: mocks.MockAll.display mirrors codegen's emitted decl.
    try testing.expect(comptime (shape.genericFnError(mocks.MockAll, "display", "void") == null));
    try testing.expect(comptime (shape.genericFnError(mocks.MockAll, "eval", "Rows(D, S)") == null));
}

test "validate: a module with no port list (§6.2 optional, A.1.2)" {
    comptime validate(mocks.MockNoPorts);
    try testing.expectEqual(@as(usize, 0), mocks.MockNoPorts.num_ports);
}

test "validate: switch (state in Instance + attempt + limit)" {
    comptime validate(mocks.MockSw);
}

test "validate: tline (ac stamp + sim-state fields + metadata)" {
    comptime validate(mocks.MockTline);
}

test "updateState mutates Instance" {
    var inst: mocks.MockSw.Instance = .{};
    var s: mocks.MockSw.State = .{};
    const m: mocks.MockSw.Model = .{};
    _ = mocks.MockSw.updateState(void, &m, &inst, .{ 1.0, 0.0 }, &s, .{});
    try testing.expect(inst.closed);
    try testing.expectEqual(@as(u32, 1), s.flips);
}

test "limit reports its own convergence verdict" {
    const m: mocks.MockSw.Model = .{};
    const i: mocks.MockSw.Instance = .{};
    const r = mocks.MockSw.limit(void, &m, &i, .{ 1.0, 0.0 }, .{ 0.0, 0.0 }, .{});
    try testing.expect(r.converged);
    try testing.expectEqual(@as(f64, 1.0), r.x[0]);
}
