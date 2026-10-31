//! COMPAT SHIM, delete in pass 2: the pre-rewrite `tb` API (one flat
//! `Directives`, arena-returning renderers, the `zigbuild` re-exports) over
//! the new one, so the callers outside this module keep building until they
//! migrate. Every mapping is in the rewrite's api file (`exe.md`).
//! Cites: none (a shim; each wrapped function cites its own clauses).
//!
//! Contents:
//! - `pub const Error = ParseError || error{TooManyPoints}`
//! - `pub const max_points: usize`
//! - `pub const Directives = struct` (the old flat form)
//! - `pub fn parse(arena: Allocator, source: []const u8) Error!Directives`
//! - `pub fn renderRunner(arena: Allocator, title: []const u8, d: Directives) Error![]const u8`
//! - `pub fn renderVpiLib(arena: Allocator, title: []const u8, d: Directives) Error![]const u8`
//! - `pub fn expand(arena: Allocator, d: Directives) Error![]const []const f64`
//! - `pub fn shapeOverrides(arena: Allocator, d: Directives, lowered: *const Lowered) Allocator.Error![]const Lowered.ParamOverride`
//! - `pub const BuildOptions`, `BuildResult`, `buildExe`, `Staged`, `stageExe`, `buildBatch`, `batch_argv0`: `zigbuild`'s

const std = @import("std");
const Lowered = @import("ir").Lowered;
const zigbuild = @import("zigbuild");
const spec = @import("spec.zig");
const facts_ = @import("facts.zig");
const points = @import("points.zig");
const runner = @import("runner.zig");
const vpi = @import("vpi.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Binding = spec.Binding;
const Sweep = spec.Sweep;

/// The old error set: parse's and the renderers' in one.
pub const Error = spec.ParseError || error{TooManyPoints};
/// The old name of `points_max`.
pub const max_points: usize = spec.points_max;

/// The old flat form: `Bench`, `Harness` and `Facts` in one struct, with an
/// `asserts_*` flag beside each table `Bench` now makes optional.
pub const Directives = struct {
    params: []const Binding = &.{},
    bias: []const Binding = &.{},
    sweeps: []const Sweep = &.{},
    temp: f64 = 300.15,
    times: []const f64 = &.{0.0},
    waves: []const Sweep = &.{},
    psweeps: []const Sweep = &.{},
    analysis: spec.Analysis = .dc,
    analysis_name: []const u8 = "",
    solve_free: bool = false,
    print_residual: bool = true,
    expected_exit: u8 = 0,
    expected_checks: ?u32 = null,
    plusargs: []const []const u8 = &.{},
    spice: []const u8 = "",
    discipline_resolution: Lowered.DisciplineResolution = .basic,
    display_record: bool = false,
    noise: []const spec.NoiseWant = &.{},
    asserts_noise: bool = false,
    acstim: []const spec.AcWant = &.{},
    asserts_acstim: bool = false,
    acdyn: []const spec.AcDynWant = &.{},
    qsites: []const []const u8 = &.{},
    asserts_qsite: bool = false,
    seeds: []const Binding = &.{},
    asserts_seed: bool = false,
    meta: []const []const u8 = &.{},
    asserts_meta: bool = false,
    abstols: []const Binding = &.{},
    limits: []const spec.LimitCase = &.{},
    reject: []const []const u8 = &.{},
    reject_only: bool = false,
    reject_run: []const []const u8 = &.{},
    neighbours: []const []const u8 = &.{},
    warn: []const []const u8 = &.{},
    nowarn: bool = false,
    lrm: []const []const u8 = &.{},
    xfail: ?[]const u8 = null,
    mixed: ?spec.Mixed = null,
    op_states: []const u32 = &.{},
    mem_bytes: u64 = 0,
    validate_contract: bool = false,
    certify: bool = false,
    finite_proved: bool = false,
    fd_exempt: ?[]const u8 = null,
};

/// `zigbuild`'s, re-exported: callers now import `zigbuild` themselves.
pub const BuildOptions = zigbuild.BuildOptions;
pub const BuildResult = zigbuild.BuildResult;
pub const buildExe = zigbuild.buildExe;
pub const Staged = zigbuild.Staged;
pub const stageExe = zigbuild.stage;
pub const buildBatch = zigbuild.buildBatch;
pub const batch_argv0 = zigbuild.batch_argv0;

/// `Spec.parse(arena, source, null)`, flattened.
pub fn parse(arena: Allocator, source: []const u8) Error!Directives {
    const s = try spec.Spec.parse(arena, source, null);
    const b = s.bench;
    const h = s.harness;
    return .{
        .params = b.params,
        .bias = b.bias,
        .sweeps = b.sweeps,
        .temp = b.temperature_k,
        .times = b.times_s,
        .waves = b.waves,
        .psweeps = b.psweeps,
        .analysis = b.analysis,
        .analysis_name = b.analysis_name,
        .solve_free = b.solve_free,
        .print_residual = b.print == .residual,
        .expected_exit = h.expected_exit,
        .expected_checks = h.expected_checks,
        .plusargs = h.plusargs,
        .spice = h.spice,
        .discipline_resolution = h.discipline_resolution,
        .display_record = h.display_record,
        .noise = b.noise orelse &.{},
        .asserts_noise = b.noise != null,
        .acstim = b.acstim orelse &.{},
        .asserts_acstim = b.acstim != null,
        .acdyn = b.acdyn,
        .qsites = b.qsites orelse &.{},
        .asserts_qsite = b.qsites != null,
        .seeds = b.seeds orelse &.{},
        .asserts_seed = b.seeds != null,
        .meta = b.meta orelse &.{},
        .asserts_meta = b.meta != null,
        .abstols = b.abstols,
        .limits = b.limits,
        .reject = h.reject,
        .reject_only = h.reject_only,
        .reject_run = h.reject_run,
        .neighbours = h.neighbours,
        .warn = h.warn,
        .nowarn = h.nowarn,
        .lrm = h.lrm,
        .xfail = h.xfail,
        .fd_exempt = h.fd_exempt,
    };
}

/// `writeRunner` into an allocating writer over `arena`.
pub fn renderRunner(arena: Allocator, title: []const u8, d: Directives) Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const b = benchOf(d);
    runner.writeRunner(&aw.writer, arena, title, &b, factsOf(d)) catch |e| return switch (e) {
        error.WriteFailed, error.OutOfMemory => error.OutOfMemory,
        error.TooManyPoints => error.TooManyPoints,
    };
    return aw.written();
}

/// `writeVpiLib` into an allocating writer over `arena`.
pub fn renderVpiLib(arena: Allocator, title: []const u8, d: Directives) Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const b = benchOf(d);
    vpi.writeVpiLib(&aw.writer, title, &b, factsOf(d)) catch return error.OutOfMemory;
    return aw.written();
}

/// `pointCount` and `Row`, materialized into `arena`.
pub fn expand(arena: Allocator, d: Directives) Error![]const []const f64 {
    const b = benchOf(d);
    const count = try points.pointCount(&b);
    const dims = points.columnCount(&b);
    const rows = try arena.alloc([]const f64, count);
    for (rows, 0..) |*row, n| {
        const cells = try arena.alloc(f64, dims);
        var it: points.Row = .init(&b, count, @intCast(n));
        for (cells) |*c| c.* = it.next().?;
        row.* = cells;
    }
    assert(rows.len == count);
    return rows;
}

/// `shapeCards(arena, d.params, lowered)`.
pub fn shapeOverrides(arena: Allocator, d: Directives, lowered: *const Lowered) Allocator.Error![]const Lowered.ParamOverride {
    return facts_.shapeCards(arena, d.params, lowered);
}

// ---- private ----

fn benchOf(d: Directives) spec.Bench {
    return .{
        .params = d.params,
        .bias = d.bias,
        .sweeps = d.sweeps,
        .psweeps = d.psweeps,
        .waves = d.waves,
        .temperature_k = d.temp,
        .times_s = d.times,
        .analysis = d.analysis,
        .analysis_name = d.analysis_name,
        .solve_free = d.solve_free,
        .print = if (d.print_residual) .residual else .none,
        .noise = if (d.asserts_noise) d.noise else null,
        .acstim = if (d.asserts_acstim) d.acstim else null,
        .acdyn = d.acdyn,
        .qsites = if (d.asserts_qsite) d.qsites else null,
        .seeds = if (d.asserts_seed) d.seeds else null,
        .meta = if (d.asserts_meta) d.meta else null,
        .abstols = d.abstols,
        .limits = d.limits,
    };
}

fn factsOf(d: Directives) spec.Facts {
    return .{
        .mixed = d.mixed,
        .op_states = d.op_states,
        .mem_bytes = d.mem_bytes,
        .validate_contract = d.validate_contract,
        .certify = d.certify,
        .finite_proved = d.finite_proved,
    };
}
