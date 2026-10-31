//! The fixed-grid runner: a `Bench` and its `Facts` in, the testbench's Zig
//! source out, written to the caller's writer. The sweeps are expanded here,
//! so the runner is straight-line code whose output order is the text's: one
//! block per operating point, one solve per `//! time` inside it. A bench
//! whose `Facts.mixed` is set goes to `mixed.zig` instead.
//! Cites: §2.8.3, §4.5.2, §4.6.1, §4.6.2, §4.6.3, §4.6.4, §5.2.1, §5.6,
//! §5.6.1.2, §5.10.2 (Table 5-1), §5.10.3.1, §6.3.4, §8.2, §9.5.1.1, §9.15,
//! §9.17.3, §12.32.
//!
//! Contents:
//! - `pub fn writeRunner(w: *Writer, scratch: Allocator, title: []const u8, bench: *const Bench, facts: Facts) RenderError!void`

const std = @import("std");
const spec = @import("spec.zig");
const parts = @import("parts.zig");
const points = @import("points.zig");
const tables = @import("table_checks.zig");
const at_point = @import("point_checks.zig");
const mixed = @import("mixed.zig");
const text = @import("text.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Bench = spec.Bench;
const Facts = spec.Facts;
const RenderError = spec.RenderError;
const Writer = parts.Writer;
const fmtF64 = parts.fmtF64;

/// Where one solve sits: time `t`, the `k`-th of the grid, in point `n` of
/// `count`; `solve` numbers it across the whole run.
const Step = struct { t: f64, k: usize, n: u32, solve: u32, count: u32, per_block: bool };

/// Writes the runner's Zig source for `bench` to `w`: the mixed-signal
/// runner when `facts.mixed` is set, else the fixed-grid one. `title` keys
/// each transcript block (the fixture's file stem). The runner prints to
/// stderr through `std.debug.print`, the stream generated `$strobe` uses, so
/// the interleaving is deterministic. `scratch` holds the mixed runner's
/// field spellings and may be freed once this returns. Fails with
/// `error.TooManyPoints`, writing nothing, past `points_max`. Asserts the
/// `Bench` invariants.
pub fn writeRunner(w: *Writer, scratch: Allocator, title: []const u8, bench: *const Bench, facts: Facts) RenderError!void {
    const count = try points.pointCount(bench);
    assert(count != 0);
    assert(bench.times_s.len != 0);
    if (facts.mixed) |mx| return mixed.writeMixed(w, scratch, title, bench, facts, mx, count);

    try parts.head(w, title, bench, facts);
    try prologue(w, bench);
    // Once, before the points: these are comptime tables, or the cold start.
    if (bench.noise) |rows| try tables.noiseTopology(w, rows);
    if (bench.acstim) |rows| try tables.acTopology(w, rows);
    if (bench.qsites) |rows| try tables.qSites(w, rows);
    if (bench.seeds) |rows| try tables.seedCheck(w, rows);
    if (bench.meta) |rows| try tables.meta(w, rows);
    try tables.abstols(w, bench.abstols);

    // Sweep outer, time inner. With `//! time` each sweep point is its own
    // transient analysis with a fresh `State`, so no bias inherits another's
    // §4.5 operator history or §4.6.2 variables; a dc sweep's points share
    // them and are the steps of one analysis.
    const per_block = bench.times_s.len > 1;
    // `//! psweep` gives each point its own model card: §8.2 sub-tasks, each
    // re-derived per §6.3.4. Without it the shared `model` is used.
    const mdl = if (bench.psweeps.len == 0) "model" else "pm";
    var solves: u32 = 0;
    for (0..count) |pi| {
        const n: u32 = @intCast(pi);
        try w.writeAll("    {\n");
        try parts.sweepPoint(w, bench, count, n);
        // §9.5.1.1 a block after the first is a following analysis of the same
        // process, so a file it reopens "w" keeps earlier output.
        if (per_block and n != 0)
            try w.writeAll("        if (comptime contract.fileIo(D)) |f| if (f.new_analysis) |g| g();\n");
        if (bench.psweeps.len != 0) {
            try parts.swept(w, bench, count, n);
            // §6.3.4: setup also derives from the swept card.
            try w.writeAll("        if (comptime @hasDecl(D, \"setup\")) D.setup(Dual, &pm);\n");
            try w.writeAll("        if (comptime @hasDecl(D, \"setupInstance\")) D.setupInstance(&pm, &inst);\n");
        }
        // §4.6.2 a new analysis re-initializes its variables (`initState`);
        // the steps of one dc sweep are one analysis and keep them.
        try parts.pointUnknowns(w, bench, facts, .init(bench, count, n), mdl, per_block or n == 0);
        for (bench.times_s, 0..) |t, k| {
            try timePoint(w, bench, .{ .t = t, .k = k, .n = n, .solve = solves, .count = count, .per_block = per_block }, mdl);
            solves += 1;
        }
        try w.writeAll("    }\n");
    }
    // One block of `times_s` per point.
    assert(solves == count * bench.times_s.len);
    try w.print("}}\n\nconst print_residual = {};\n", .{bench.print == .residual});
}

// ---- private ----

/// Writes the big-stack `main`, the card, the instance and the host
/// bindings, up to the title line: everything before the first table check.
fn prologue(w: *Writer, bench: *const Bench) RenderError!void {
    assert(bench.times_s.len != 0);
    try w.writeAll(text.big_stack);
    try w.writeAll(
        \\pub fn main(init: std.process.Init.Minimal) void {
        \\    if (comptime big_stack) return bigStack(init);
        \\    @call(.never_inline, run, .{init});
        \\}
        \\fn run(init: std.process.Init.Minimal) void {
        \\    var model: D.Model = .{};
        \\
    );
    for (bench.params) |p| try parts.setCard(w, "    ", "model", p.name, p.value);
    // §6.3.4: the card is complete only now. Unconditional, so a §3.4.5
    // localparam is derived even with no `//! param` line.
    try parts.deriveCard(w, "    ", "model", bench.temperature_k);
    try w.writeAll(
        \\
        \\    var inst: D.Instance = .{};
        \\
    );
    try w.print("    run_kind = .{t};\n    sim_state = .{{ .kind = run_kind }};\n", .{bench.analysis});
    // §2.8.3/§12.32: this testbench is a host, so it binds `no_vpi_app` for
    // the device's unresolved `$name`s and passes `validateHost` like any other.
    try w.writeAll(
        \\    if (comptime @hasDecl(D, "systf_calls")) inst.systf = &no_vpi_app;
        \\    if (comptime @hasField(D.Instance, "plusargs")) inst.plusargs = plusargs(init);
        \\    // §9.15 Table 9-28 through the GPU-safe channel a GPU host uses: the
        \\    // bytes in `contract.host_strings`, the row only their indices. The
        \\    // `Instance.cwd`/`analysis_name` slices stay "", so a device that
        \\    // read them instead answers "" and its fixture fails.
        \\    var tb_strings = [_][]const u8{ "", "", analysis_name };
        \\    if (comptime @hasField(D.Model, "cwd_idx__")) {
        \\        tb_strings[1] = cwdPath();
        \\        contract.host_strings = &tb_strings;
        \\        model.cwd_idx__ = 1;
        \\        model.analysis_name_idx__ = 2;
        \\    }
        \\    // The solve-invariant slice: after the card and the temperature
        \\    // write, before the first evaluation — the ordering a host keeps.
        \\    // With `Dual` itself as the value scalar, so every latched value is
        \\    // the bits `eval` would have computed.
        \\    if (comptime @hasDecl(D, "setup")) D.setup(Dual, &model);
        \\    if (comptime @hasDecl(D, "setupInstance")) D.setupInstance(&model, &inst);
        \\    // §4.6.2 one per analysis: `initState` at each analysis's first point.
        \\    var state: State = undefined;
        \\    _ = &state;
        \\
        \\    if (print_residual) std.debug.print("=== {s} ===\n", .{title});
        \\
    );
}

/// Writes one solve of the grid: the waves at this time, the step, the
/// §5.10.2 global events, the solve and its retries, the model's output and
/// (at the run's first solve) the point checks, then the accepted step.
fn timePoint(w: *Writer, bench: *const Bench, s: Step, mdl: []const u8) RenderError!void {
    assert(s.k < bench.times_s.len);
    assert(s.n < s.count);
    const last = bench.times_s.len - 1;
    // `locate` draws a wave between the last accepted point and this.
    if (bench.waves.len != 0) try w.writeAll("        forced_prev = forced;\n");
    for (bench.waves) |wv| {
        assert(wv.values.len != 0); // `numbers` refuses an empty list.
        // A short `wave` holds its last value.
        const v = wv.values[@min(s.k, wv.values.len - 1)];
        try w.print("        set(&x, &forced, \"{f}\", {f});\n", .{ std.zig.fmtString(wv.name), fmtF64(v) });
    }
    // The first time is the DC point, dt = 0, which operator kernels answer
    // with their DC form (§4.5.4 initial condition, §4.5.11 DC gain), and
    // which `atPoint` makes a transient's "ic" (Table 4-22).
    const dt: f64 = if (s.k == 0) 0.0 else bench.times_s[s.k] - bench.times_s[s.k - 1];
    try w.print("        atPoint({f}, {f});\n", .{ fmtF64(s.t), fmtF64(dt) });
    // §5.10.2 / Table 5-1: `initial_step` fires on an analysis's first point
    // and `final_step` on its last; a one-point fixture gets both, as Table
    // 5-1's DCOP column does. Written at every point: a stale `true` would
    // fire an event twice.
    try w.print("        sim_state.initial_step = {};\n        sim_state.final_step = {};\n", .{
        s.k == 0 and (s.per_block or s.n == 0),
        s.k == last and (s.per_block or s.n + 1 == s.count),
    });
    // §5.2.1 `analog initial` re-runs per sub-task: the first time of every
    // block, unlike `initial_step` (visible under `//! psweep`).
    try w.print("        sim_state.analog_initial = {};\n", .{s.k == 0});
    // §5.6 the model prints at a solution: solve first, then `point`.
    try w.print("        var solved{d} = solve(&x, &forced, &{s}, &inst);\n", .{ s.solve, mdl });
    // §5.10.3.1 a crossing found outside its tolerance box gets its own
    // point first (`locate`), and this one is solved again.
    try w.print("        if (crossRetry(&{1s}, &inst, &x, &state)) |r| solved{0d} = locate(r, {0d}, &x, &forced, &{1s}, &inst, &state, 0);\n", .{ s.solve, mdl });
    try w.print("        point({d}, &x, &{s}, &inst);\n", .{ s.solve, mdl });
    // The bias- and card-dependent checks are stated at the run's first
    // solve, the one every fixture has.
    if (s.solve == 0) {
        if (bench.noise) |rows| try at_point.noisePsd(w, rows, mdl);
        if (bench.acstim) |rows| try at_point.acStim(w, rows, mdl);
        try at_point.acDyn(w, bench.acdyn, mdl);
        try at_point.limits(w, bench.limits, mdl);
    }
    // §4.5.2 accepted-step bookkeeping: only `updateState` writes the history
    // `eval` reads. VerA's `$vera_reject_step`: a rejected step is retried.
    try w.print("        if (stepPost(&{s}, &inst, &x, &state, solved{d})) |r| retry(r, {d}, &x, &forced, &{s}, &inst, &state, 0);\n", .{ mdl, s.solve, s.solve, mdl });
}
