//! The Clause 12 analog host library: a `Bench` and its `Facts` in, the Zig
//! source of a shared library out. The device and solver behind a C
//! interface, stepped by a host that owns the time walk (`src/vpi/analog.zig`),
//! since §12.31.3 lets a VPI application force or reject a solution time.
//! Cites: §3.6.1, §5.4.1, §5.6, §12.7-§12.10, §12.18, §12.31.3.
//!
//! Contents:
//! - `pub fn writeVpiLib(w: *Writer, title: []const u8, bench: *const Bench, facts: Facts) Writer.Error!void`

const std = @import("std");
const spec = @import("spec.zig");
const parts = @import("parts.zig");
const text = @import("text.zig");
const assert = std.debug.assert;
const Bench = spec.Bench;
const Facts = spec.Facts;
const Writer = parts.Writer;
const fmtF64 = parts.fmtF64;

/// Writes the VPI host library for `bench` to `w`. It exports: open an
/// analysis of a kind, solve at t tentatively, accept the last solution,
/// read x, and read each §5.6 row's value and each instance's share of a
/// shared row (§5.4.1); the device must be compiled with
/// `Options.vpi_contribs`. Only an accepted solve writes history, so a
/// rejected point needs no undo. Every unknown is solved for (§3.6.1) unless
/// a `//! bias`/`//! wave` line pins it; the sweeps are not read. Asserts the
/// `Bench` invariants.
pub fn writeVpiLib(w: *Writer, title: []const u8, bench: *const Bench, facts: Facts) Writer.Error!void {
    assert(bench.times_s.len != 0);
    try parts.head(w, title, bench, facts);
    try parts.timeArrays(w, bench);
    try w.writeAll(text.vpi_body);

    // open: the card, the instance, the unknowns.
    try w.writeAll(
        \\export fn vera_vpi_open(kind: u8) callconv(.c) void {
        \\    g_model = .{};
        \\
    );
    for (bench.params) |p| try parts.setCard(w, "    ", "g_model", p.name, p.value);
    try parts.deriveCard(w, "    ", "g_model", bench.temperature_k);
    try w.writeAll("    g_inst = .{};\n");
    try w.writeAll(
        \\    run_kind = @fromBackingInt(kind);
        \\    sim_state = .{ .kind = run_kind };
        \\    if (comptime @hasDecl(D, "systf_calls")) g_inst.systf = if (host_call != null) &host_systf else &no_vpi_app;
        \\    if (comptime @hasField(D.Instance, "plusargs")) g_inst.plusargs = &.{};
        \\    if (comptime @hasField(D.Instance, "cwd")) g_inst.cwd = cwdPath();
        \\    if (comptime @hasField(D.Instance, "analysis_name")) g_inst.analysis_name = @tagName(sim_state.kind);
        \\    if (comptime @hasDecl(D, "setup")) D.setup(Dual, &g_model);
        \\    if (comptime @hasDecl(D, "setupInstance")) D.setupInstance(&g_model, &g_inst);
        \\    g_x = @splat(0.0);
        \\    g_forced = @splat(null);
        \\    if (comptime @hasDecl(D, "u_nodeset")) for (D.u_nodeset, 0..) |nodeset_i, i| {
        \\        if (nodeset_i) |v| g_x[i] = v;
        \\    };
        \\
    );
    for (bench.bias) |b| {
        assert(b.name.len != 0);
        try w.print("    set(&g_x, &g_forced, \"{f}\", {f});\n", .{ std.zig.fmtString(b.name), fmtF64(b.value) });
    }
    try w.writeAll(
        \\    g_state = newState(&g_model, &g_inst);
        \\    q_prev = @splat(0.0);
        \\    g_solved = false;
        \\}
        \\
        \\export fn vera_vpi_solve(t: f64, dt: f64, first: bool, last: bool) callconv(.c) bool {
        \\
    );
    for (bench.waves, 0..) |wv, k|
        try w.print("    set(&g_x, &g_forced, \"{f}\", pwl(&wave_{d}, t));\n", .{ std.zig.fmtString(wv.name), k });
    try w.writeAll(
        \\    atPoint(t, dt);
        \\    sim_state.initial_step = first;
        \\    sim_state.final_step = last;
        \\    sim_state.analog_initial = first;
        \\    g_solved = solve(&g_x, &g_forced, &g_model, &g_inst);
        \\    return g_solved;
        \\}
        \\
        \\const print_residual = false;
        \\
    );
}
