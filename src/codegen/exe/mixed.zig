//! The VAMS §8 mixed-signal runner: a `Bench`, its `Facts` and the compile's
//! `Mixed` plan in, the testbench's Zig source out. The same device and
//! solver as the fixed-grid runner, with operating points from
//! `sim.mixed.run` (the declared `//! time`s plus every implicit D2A time)
//! and discrete inputs from the digital half, re-elaborated at startup. A
//! `//! wave` is piecewise linear here, equal to the fixed-grid runner's value
//! at every declared point. The device-table directives (noise, acstim,
//! qsite, seed, meta, limit, acdyn) are a compile error in the emitted runner.
//! Cites: §6.3, §6.7.1, §7.2.2, §7.3.1, §7.3.2, §7.3.3, §7.3.6.1, §7.3.6.4,
//! §7.8.4, §8.5, §8.5.3.6, §9.5.1.1; IEEE 1364 §19.8.
//!
//! Contents:
//! - `pub fn writeMixed(w: *Writer, scratch: Allocator, title: []const u8, bench: *const Bench, facts: Facts, mx: Mixed, count: u32) RenderError!void`

const std = @import("std");
const naming = @import("ir").names;
const HeldVar = @import("ir").Lowered.HeldVar;
const spec = @import("spec.zig");
const parts = @import("parts.zig");
const text = @import("text.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Bench = spec.Bench;
const Facts = spec.Facts;
const Mixed = spec.Mixed;
const RenderError = spec.RenderError;
const Writer = parts.Writer;
const fmtF64 = parts.fmtF64;

/// Writes the mixed-signal runner for `bench` to `w`. `count` is
/// `pointCount(bench)`; each point is its own analysis, with a fresh digital
/// elaboration and `State`. `scratch` is an arena: it holds the `Model` and
/// `Instance` field spellings (`naming`), free to reset once this returns.
pub fn writeMixed(w: *Writer, scratch: Allocator, title: []const u8, bench: *const Bench, facts: Facts, mx: Mixed, count: u32) RenderError!void {
    assert(count != 0);
    assert(mx.wide.len == mx.words.len);
    try parts.head(w, title, bench, facts);
    try w.writeAll(text.mixed_body);
    if (bench.noise != null or bench.acstim != null or bench.qsites != null or bench.seeds != null or bench.meta != null or bench.limits.len != 0 or bench.acdyn.len != 0)
        try w.writeAll("comptime { @compileError(title ++ \": //! noise, //! acstim, //! qsite, //! seed, //! meta, //! limit and //! acdyn are not read by the mixed-signal runner\"); }\n");

    try w.print("const mixed_source = \"{f}\";\n", .{std.zig.fmtString(mx.source)});
    try w.print("const mixed_top = \"{f}\";\n", .{std.zig.fmtString(mx.top)});
    try w.writeAll("const mixed_timescales = [_]TimescaleEvent{");
    for (mx.timescales) |ev| if (ev.value) |t|
        try w.print(" .{{ .at = {d}, .value = .{{ .unit = {f}, .precision = {f} }} }},", .{ ev.at, fmtF64(t.unit), fmtF64(t.precision) })
    else
        try w.print(" .{{ .at = {d}, .value = null }},", .{ev.at});
    try w.writeAll(" };\n");
    try parts.timeArrays(w, bench);

    // The adapter: `sim.mixed.run`'s `A`, with the waves set in `solveAt`.
    try w.writeAll(text.adapter_head);
    for (bench.waves, 0..) |wv, k|
        try w.print("        set(a.x, a.forced, \"{f}\", pwl(&wave_{d}, t));\n", .{ std.zig.fmtString(wv.name), k });
    try w.writeAll(text.adapter_tail);
    try tablesOf(w, scratch, bench, mx);
    try mainOf(w, bench, facts, count);
}

// ---- private ----

/// Writes the runner's comptime tables of the digital half: every port
/// beside its `Model` or `Instance` field, the inserted connect modules, the
/// held fields, the card's parameters and the probe terminals.
fn tablesOf(w: *Writer, scratch: Allocator, bench: *const Bench, mx: Mixed) (Allocator.Error || Writer.Error)!void {
    assert(mx.probe_names.len == mx.probe_nodes.len);
    // Each digital name beside its `Model` field.
    try w.writeAll("const input_ports = [_]Port{");
    for (mx.inputs) |name| try inputPorts(w, scratch, mx, name);
    try w.writeAll(" };\nconst snap_ports = [_]Port{");
    for (mx.snaps) |name| {
        const field = try naming.sanitizeAlloc(scratch, try naming.snapField(scratch, name));
        try w.print(" .{{ .name = \"{f}\", .field = \"{s}\" }},", .{ std.zig.fmtString(name), field });
    }
    try w.writeAll(" };\nconst event_ports = [_]EventPort{");
    for (mx.events) |ev| try w.print(" .{{ .name = \"{f}\", .edge = .{t}, .field = \"{s}\" }},", .{ std.zig.fmtString(ev.name), ev.edge, try naming.sanitizeAlloc(scratch, ev.param) });
    try w.writeAll(" };\n");
    // VAMS §7.8.4 the inserted connect modules, which the source the digital
    // half re-elaborates does not hold (`sim.digital.Insert`).
    try w.writeAll("const mixed_inserts = [_]sim.digital.Insert{");
    for (mx.inserts) |row| {
        try w.writeAll(" .{");
        inline for (@typeInfo(@TypeOf(row)).@"struct".field_names) |name|
            try w.print(" .{s} = \"{f}\",", .{ name, std.zig.fmtString(@field(row, name)) });
        try w.writeAll(" },");
    }
    try w.writeAll(" };\n");
    try a2dPorts(w, scratch, mx);
    // §8.5.3.6 the held fields only explicit D2A event statements assign.
    try w.writeAll(" };\nconst d2a_held = [_][]const u8{");
    for (mx.held) |h| if (h.d2a) {
        try w.print(" \"{s}\",", .{try naming.heldField(scratch, mx.top, h.name)});
    };
    // VAMS §6.3 the card's root parameters, so the digital half reads the
    // values `Model` gets (`sim.digital.Mixed.params`).
    try w.writeAll(" };\nconst mixed_params = [_]sim.digital.Param{");
    for (bench.params) |p| try w.print(" .{{ .name = \"{f}\", .value = {f} }},", .{ std.zig.fmtString(p.name), fmtF64(p.value) });
    // The host has already derived these values, including defaults that the
    // digital expression subset cannot evaluate. Copy from each analysis's
    // actual Model, after card writes and per-point parameter overrides.
    try w.writeAll(" };\nconst mixed_real_ports = [_]Port{");
    for (mx.params) |p| {
        if (p.ty != .real) continue;
        const read = for (mx.param_reads) |name| {
            if (std.mem.eql(u8, p.name, name)) break true;
        } else false;
        if (!read) continue;
        try w.print(" .{{ .name = \"{f}\", .field = \"{s}\" }},", .{ std.zig.fmtString(p.name), try naming.sanitizeAlloc(scratch, p.name) });
    }
    try w.writeAll(" };\nconst mixed_reads = blk: {\n    var names: [a2d_ports.len][]const u8 = undefined;\n    for (a2d_ports, &names) |p, *n| n.* = p.name;\n    const out = names;\n    break :blk out;\n};\n");
    // §7.3.3 / §6.7.1 each digital probe terminal's node pair (`terminal`),
    // as the `D.U` fields spell the nodes.
    try w.writeAll("const probe_terminals = std.StaticStringMap([2][]const u8).initComptime(.{");
    for (mx.probe_names, mx.probe_nodes) |name, pair| try w.print(" .{{ \"{f}\", .{{ \"{s}\", \"{s}\" }} }},", .{
        std.zig.fmtString(name),
        try naming.sanitizeAlloc(scratch, pair[0]),
        try naming.sanitizeAlloc(scratch, pair[1]),
    });
    try w.writeAll(" });\n\n");
}

/// Writes the `input_ports` rows of digital input `name`: one, or one per
/// 32-bit word of a §7.3.1 `reg` wider than 32 bits, and §7.3.2's `x`/`z` plane.
fn inputPorts(w: *Writer, scratch: Allocator, mx: Mixed, name: []const u8) (Allocator.Error || Writer.Error)!void {
    assert(name.len != 0);
    try w.print(" .{{ .name = \"{f}\", .field = \"{s}\"", .{ std.zig.fmtString(name), try naming.sanitizeAlloc(scratch, name) });
    const xz = for (mx.xz) |x| {
        if (std.mem.eql(u8, x, name)) break true;
    } else false;
    if (xz) {
        const field = try naming.sanitizeAlloc(scratch, try naming.xzField(scratch, name));
        try w.print(", .xz = \"{s}\"", .{field});
    }
    // Word 0 exactly, then one port per further word, each its own field.
    const n_words = for (mx.wide, mx.words) |wide, n| {
        if (std.mem.eql(u8, wide, name)) break n;
    } else 0;
    if (n_words != 0 and !xz) try w.writeAll(", .word = 0");
    try w.writeAll(" },");
    for (1..@max(n_words, 1)) |k| {
        const field = try naming.sanitizeAlloc(scratch, try naming.wordField(scratch, name, k));
        try w.print(" .{{ .name = \"{f}\", .field = \"{s}\", .word = {d} }},", .{ std.zig.fmtString(name), field, k });
    }
    assert(n_words <= std.math.maxInt(u32));
}

/// Writes the VAMS §7.3.6.4 `a2d_ports` rows, without the closing ` };`:
/// each analog variable a digital expression reads, beside the §5.10 held
/// `Instance` field its value is copied from and its §7.3.6.1 assignment
/// count, when it has one. A variable that is not held is left out, and the
/// digital half refuses the read.
fn a2dPorts(w: *Writer, scratch: Allocator, mx: Mixed) (Allocator.Error || Writer.Error)!void {
    assert(mx.top.len != 0);
    const prefix = HeldVar.assign_count_prefix;
    assert(prefix.len != 0);
    try w.writeAll("const a2d_ports = [_]Port{");
    for (mx.reads) |name| for (mx.held) |h| if (std.mem.eql(u8, h.name, name)) {
        try w.print(" .{{ .name = \"{f}\", .field = \"{s}\", .free = {}", .{ std.zig.fmtString(name), try naming.heldField(scratch, mx.top, name), h.why != .event });
        for (mx.held) |c| if (std.mem.startsWith(u8, c.name, prefix) and std.mem.eql(u8, c.name[prefix.len..], name)) {
            try w.print(", .count = \"{s}\"", .{try naming.heldField(scratch, mx.top, c.name)});
        };
        try w.writeAll(" },");
        break;
    };
}

/// Writes `main`: the card, the instance, the host bindings, then one
/// `runMixed` analysis per point.
fn mainOf(w: *Writer, bench: *const Bench, facts: Facts, count: u32) RenderError!void {
    assert(count != 0);
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
    try parts.deriveCard(w, "    ", "model", bench.temperature_k);
    try w.writeAll("    var inst: D.Instance = .{};\n");
    try w.print("    run_kind = .{t};\n    sim_state = .{{ .kind = run_kind }};\n", .{bench.analysis});
    try w.writeAll(
        \\    if (comptime @hasDecl(D, "systf_calls")) inst.systf = &no_vpi_app;
        \\    if (comptime @hasField(D.Instance, "plusargs")) inst.plusargs = plusargs(init);
        \\    if (comptime @hasField(D.Instance, "cwd")) inst.cwd = cwdPath();
        \\    if (comptime @hasField(D.Instance, "analysis_name")) inst.analysis_name = analysis_name;
        \\    if (comptime @hasDecl(D, "setup")) D.setup(Dual, &model);
        \\    if (comptime @hasDecl(D, "setupInstance")) D.setupInstance(&model, &inst);
        \\    if (print_residual) std.debug.print("=== {s} ===\n", .{title});
        \\    var n: usize = 0;
        \\    var state: State = undefined;
        \\
    );
    const mdl = if (bench.psweeps.len == 0) "model" else "pm";
    for (0..count) |pi| {
        const n: u32 = @intCast(pi);
        try w.writeAll("    {\n");
        try parts.sweepPoint(w, bench, count, n);
        // §9.5.1.1, as in the fixed-grid runner: every point here is an analysis.
        if (n != 0)
            try w.writeAll("        if (comptime contract.fileIo(D)) |f| if (f.new_analysis) |g| g();\n");
        try parts.swept(w, bench, count, n);
        try parts.pointUnknowns(w, bench, facts, .init(bench, count, n), mdl, true);
        try w.print("        runMixed(&{s}, &inst, &x, &forced, &state, &n);\n    }}\n", .{mdl});
    }
    try w.print("}}\n\nconst print_residual = {};\n", .{bench.print == .residual});
}
