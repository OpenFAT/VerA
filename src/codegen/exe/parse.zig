//! Directive parsing: raw .va source in, a `Spec` out. One pass over the
//! lines; each `//!` line is one keyword and its operands (`operands.zig`
//! reads those), and the cross-line rules run once at the end.
//! Cites: §2.4 (directives are comments, so a fixture stays one portable
//! .va file), §4.6.1, §5.10.3.1, §7.4.4, §9.4, §9.15.
//!
//! Contents:
//! - `pub fn parse(arena: Allocator, source: []const u8, diag: ?*Diagnostics) ParseError!Spec`

const std = @import("std");
const spec = @import("spec.zig");
const operands = @import("operands.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Binding = spec.Binding;
const Diagnostics = spec.Diagnostics;
const ParseError = spec.ParseError;
const Spec = spec.Spec;
const Sweep = spec.Sweep;

/// The directive line prefix. A plain `//` comment is never a directive.
const marker = "//!";

/// Every keyword a `//!` line may open with, spelled as written. Any other
/// word is `error.UnknownDirective`, so a typo cannot silently check nothing.
const Keyword = enum {
    param,
    bias,
    sweep,
    wave,
    psweep,
    temp,
    time,
    solve,
    analysis,
    exit,
    checks,
    plusargs,
    reject,
    @"reject-only",
    @"reject-run",
    neighbour,
    warn,
    nowarn,
    noise,
    acstim,
    acdyn,
    qsite,
    seed,
    meta,
    abstol,
    limit,
    spice,
    lrm,
    inherited,
    xfail,
    print,
    @"discipline-resolution",
    display,
    @"fd-exempt",
    stdout,
    expect,
    diagnostic,
    @"lrm-reject",
    @"inherited-reject",
};

/// The lists one parse appends to, in the arena, before `finish` slices
/// them into the `Spec`. A `*_named` flag is "a line was written", which
/// makes the matching `Bench` field non-null even when the list is empty.
const Builder = struct {
    spec: Spec = .{},
    analysis: ?spec.Analysis = null,
    exit_set: bool = false,
    params: std.ArrayList(Binding) = .empty,
    bias: std.ArrayList(Binding) = .empty,
    sweeps: std.ArrayList(Sweep) = .empty,
    waves: std.ArrayList(Sweep) = .empty,
    psweeps: std.ArrayList(Sweep) = .empty,
    noise: std.ArrayList(spec.NoiseWant) = .empty,
    noise_named: bool = false,
    acstim: std.ArrayList(spec.AcWant) = .empty,
    acstim_named: bool = false,
    acdyn: std.ArrayList(spec.AcDynWant) = .empty,
    qsites: std.ArrayList([]const u8) = .empty,
    qsites_named: bool = false,
    seeds: std.ArrayList(Binding) = .empty,
    seeds_named: bool = false,
    meta: std.ArrayList([]const u8) = .empty,
    meta_named: bool = false,
    abstols: std.ArrayList(Binding) = .empty,
    limits: std.ArrayList(spec.LimitCase) = .empty,
    plusargs: std.ArrayList([]const u8) = .empty,
    spice: std.ArrayList([]const u8) = .empty,
    reject: std.ArrayList([]const u8) = .empty,
    reject_run: std.ArrayList([]const u8) = .empty,
    neighbours: std.ArrayList([]const u8) = .empty,
    warn: std.ArrayList([]const u8) = .empty,
    lrm: std.ArrayList([]const u8) = .empty,
};

/// Parses the `//!` lines of RAW source, before the preprocessor deletes
/// comments (§2.4); every other line is ignored, so any .va is valid input.
/// A line is a directive exactly when, trimmed of spaces, tabs and `\r`, it
/// starts with `//!` (`tests/suite.zig`'s `hasDirective` keeps that rule).
/// Every slice of the result is allocated in `arena`. Fails on the first
/// malformed line, its number in `diag`, and with `error.BadSyntax` (line 0)
/// when lines contradict each other: `reject` beside `reject-run`, `checks`,
/// `warn` or `nowarn`; `warn` beside `nowarn`; a `neighbour` on a fixture
/// that refuses nothing; a `reject-run` whose `exit` is 0.
pub fn parse(arena: Allocator, source: []const u8, diag: ?*Diagnostics) ParseError!Spec {
    var b: Builder = .{};
    var line_no: u32 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        line_no +|= 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, marker)) continue;
        const body = std.mem.trim(u8, line[marker.len..], " \t");
        if (body.len == 0) continue;
        directive(arena, &b, body) catch |e| {
            if (diag) |d| d.line = line_no;
            return e;
        };
    }
    const result = finish(arena, &b) catch |e| {
        if (diag) |d| d.line = 0;
        return e;
    };
    assert(result.bench.times_s.len != 0);
    if (result.harness.reject_run.len != 0) assert(result.harness.expected_exit != 0);
    if (result.harness.reject.len != 0) assert(result.harness.expected_checks == null);
    return result;
}

// ---- private ----

/// Applies one directive line's `body` (the text after `//!`, trimmed and
/// non-empty) to `b`.
fn directive(arena: Allocator, b: *Builder, body: []const u8) ParseError!void {
    assert(body.len != 0);
    assert(std.mem.trim(u8, body, " \t").len == body.len);
    const kw_end = std.mem.findAny(u8, body, " \t") orelse body.len;
    assert(kw_end != 0); // `body` is trimmed and nonempty.
    const kw = std.meta.stringToEnum(Keyword, body[0..kw_end]) orelse return error.UnknownDirective;
    const rest = std.mem.trim(u8, body[kw_end..], " \t");
    const bench = &b.spec.bench;
    const harness = &b.spec.harness;

    switch (kw) {
        .param, .bias => {
            // An empty list sets nothing: a forgotten operand, as `abstol`.
            if (rest.len == 0) return error.BadSyntax;
            try operands.bindings(arena, rest, if (kw == .param) &b.params else &b.bias);
        },
        .sweep, .wave, .psweep => {
            const at = std.mem.findScalar(u8, rest, '=') orelse return error.BadSyntax;
            // A parameter has no access-function spelling, so `psweep` takes the
            // name as written; `unknownName` would only strip a `V(...)` that
            // cannot be there.
            const raw_name = std.mem.trim(u8, rest[0..at], " \t");
            const name = if (kw == .psweep) raw_name else try operands.unknownName(arena, raw_name);
            if (name.len == 0) return error.BadSyntax;
            const entry: Sweep = .{
                .name = try arena.dupe(u8, name),
                .values = try operands.numbers(arena, rest[at + 1 ..]),
            };
            const list = switch (kw) {
                .sweep => &b.sweeps,
                .psweep => &b.psweeps,
                else => &b.waves, // else: the prong is `.sweep, .wave, .psweep`.
            };
            try list.append(arena, entry);
        },
        .temp => {
            bench.temperature_k = try operands.number(rest);
            if (!std.math.isFinite(bench.temperature_k)) return error.BadNumber;
        },
        .time => {
            const times = try operands.numbers(arena, rest);
            assert(times.len != 0); // `numbers` refuses an empty list.
            // `dt` is the step from the previous time, and `sim.mixed.run`
            // requires the order. A lone NaN has no pair to fail it.
            for (times) |t| if (!std.math.isFinite(t)) return error.BadSyntax;
            for (times[0 .. times.len - 1], times[1..]) |t0, t1| if (!(t1 > t0)) return error.BadSyntax;
            bench.times_s = times;
        },
        .solve => {
            // A bare flag, and it composes with `bias`: `bias` still pins what
            // it names, `solve` frees only the rest.
            if (rest.len != 0) return error.BadSyntax;
            bench.solve_free = true;
        },
        // `//! analysis <kind> [<name>]`: the name is §9.15's `analysis_name`.
        .analysis => {
            const kind_end = std.mem.findAny(u8, rest, " \t") orelse rest.len;
            b.analysis = std.meta.stringToEnum(spec.Analysis, rest[0..kind_end]) orelse return error.BadSyntax;
            const name = std.mem.trim(u8, rest[kind_end..], " \t");
            if (std.mem.findAny(u8, name, " \t\"\\") != null) return error.BadSyntax;
            if (name.len != 0) bench.analysis_name = try arena.dupe(u8, name);
        },
        .exit => {
            // `exit any`: the harness takes any status 0-125; `--run` checks
            // nothing, so the line sets nothing here.
            if (std.mem.eql(u8, rest, "any")) return;
            // `parseInt` alone also takes `+1` and `1_0`; `checks` refuses both.
            if (!operands.digits(rest)) return error.BadNumber;
            harness.expected_exit = std.fmt.parseInt(u8, rest, 10) catch return error.BadNumber;
            b.exit_set = true;
        },
        .checks => {
            if (harness.expected_checks != null) return error.BadSyntax;
            if (!operands.digits(rest)) return error.BadNumber;
            const count = std.fmt.parseInt(u32, rest, 10) catch return error.BadNumber;
            if (count == 0) return error.BadNumber;
            harness.expected_checks = count;
        },
        .plusargs => try operands.plusargs(arena, rest, &b.plusargs),
        // The whole rest of the line is ONE substring, verbatim: message
        // fragments contain spaces and commas.
        .reject, .@"reject-only" => {
            try appendText(arena, &b.reject, rest);
            if (kw == .@"reject-only") harness.reject_only = true;
        },
        .@"reject-run" => try appendText(arena, &b.reject_run, rest),
        .neighbour => {
            // A path relative to the fixture's directory; the harness checks
            // that it names a collected positive fixture.
            if (std.mem.findAny(u8, rest, " \t") != null) return error.BadSyntax;
            try appendText(arena, &b.neighbours, rest);
        },
        .warn => try appendText(arena, &b.warn, rest),
        .nowarn => {
            if (rest.len != 0) return error.BadSyntax;
            harness.nowarn = true;
        },
        // `none` is the empty table, spelled rather than left as an absent
        // directive: "this model declares no generator" is a claim, and a
        // missing line is not one. `acstim`, `qsite`, `seed`, `meta` alike.
        .noise => {
            if (!std.mem.eql(u8, rest, "none")) try b.noise.append(arena, try operands.noiseEntry(arena, rest));
            b.noise_named = true;
        },
        .acstim => {
            if (!std.mem.eql(u8, rest, "none")) try b.acstim.append(arena, try operands.acEntry(arena, rest));
            b.acstim_named = true;
        },
        .acdyn => try b.acdyn.append(arena, try operands.acDynEntry(arena, rest)),
        .qsite => {
            if (rest.len == 0) return error.BadSyntax;
            if (!std.mem.eql(u8, rest, "none")) try b.qsites.append(arena, try arena.dupe(u8, rest));
            b.qsites_named = true;
        },
        .meta => {
            if (!std.mem.eql(u8, rest, "none")) try b.meta.append(arena, try operands.metaEntry(arena, rest));
            b.meta_named = true;
        },
        .seed => {
            if (rest.len == 0) return error.BadSyntax;
            if (!std.mem.eql(u8, rest, "none")) try operands.bindings(arena, rest, &b.seeds);
            b.seeds_named = true;
        },
        .abstol => {
            if (rest.len == 0) return error.BadSyntax;
            try operands.bindings(arena, rest, &b.abstols);
        },
        .limit => try b.limits.append(arena, try operands.limitCase(arena, rest)),
        // Verbatim, including a leading `+`: the reader joins continuations
        // itself, so what it sees is the card as the annex prints it.
        .spice => try appendText(arena, &b.spice, rest),
        .lrm => {
            if (!operands.validSection(rest)) return error.BadLrmSection;
            try b.lrm.append(arena, try arena.dupe(u8, rest));
        },
        // A rejection test's cite, and `IEEE 1364-2005 18.1 (...)`, a clause
        // §1.1 inherits whole: checked as `lrm` is, then dropped.
        .@"lrm-reject" => if (!operands.validSection(rest)) return error.BadLrmSection,
        .inherited, .@"inherited-reject" => if (!operands.validInherited(rest)) return error.BadLrmSection,
        // The reason is prose for a human, and it is the claim: required.
        .xfail => harness.xfail = try requiredText(arena, rest),
        .@"fd-exempt" => harness.fd_exempt = try requiredText(arena, rest),
        .@"discipline-resolution" => harness.discipline_resolution = std.meta.stringToEnum(@TypeOf(harness.discipline_resolution), rest) orelse return error.BadSyntax,
        // §9.4 `vera --emit-exe --display=record`: the device's `say`.
        .display => harness.display_record = if (std.mem.eql(u8, rest, "record")) true else return error.BadSyntax,
        // The conformance harness's own verdicts (`stdout TEXT`, `expect
        // stdout GOLD`, `expect vcd OUT == GOLD`, `diagnostic`), which `--run`
        // has no use for: dropped, and the two that take an operand need one.
        .stdout, .expect => if (rest.len == 0) return error.BadSyntax,
        .diagnostic => {},
        .print => bench.print = std.meta.stringToEnum(spec.Print, rest) orelse return error.BadSyntax,
    }
}

/// Appends `text` to `list`, refusing an empty operand.
fn appendText(arena: Allocator, list: *std.ArrayList([]const u8), text: []const u8) ParseError!void {
    if (text.len == 0) return error.BadSyntax;
    const len_before = list.items.len;
    try list.append(arena, try arena.dupe(u8, text));
    assert(list.items.len == len_before + 1);
    assert(list.items[len_before].len == text.len);
}

/// Returns a copy of `text`, refusing an empty operand.
fn requiredText(arena: Allocator, text: []const u8) ParseError![]const u8 {
    if (text.len == 0) return error.BadSyntax;
    const copy = try arena.dupe(u8, text);
    assert(copy.len == text.len);
    assert(copy.len != 0);
    return copy;
}

/// Slices `b`'s lists into its `Spec` and applies the cross-line rules.
fn finish(arena: Allocator, b: *Builder) ParseError!Spec {
    const bench = &b.spec.bench;
    const harness = &b.spec.harness;
    // §5.10.3.1 a grid that advances time is a transient analysis: run as dc,
    // `cross` would never fire on it.
    bench.analysis = b.analysis orelse if (bench.times_s.len > 1) .tran else .dc;
    bench.params = b.params.items;
    bench.bias = b.bias.items;
    bench.sweeps = b.sweeps.items;
    bench.waves = b.waves.items;
    bench.psweeps = b.psweeps.items;
    bench.noise = if (b.noise_named) b.noise.items else null;
    bench.acstim = if (b.acstim_named) b.acstim.items else null;
    bench.acdyn = b.acdyn.items;
    bench.qsites = if (b.qsites_named) b.qsites.items else null;
    bench.seeds = if (b.seeds_named) b.seeds.items else null;
    bench.meta = if (b.meta_named) b.meta.items else null;
    bench.abstols = b.abstols.items;
    bench.limits = b.limits.items;

    harness.plusargs = b.plusargs.items;
    harness.reject = b.reject.items;
    harness.reject_run = b.reject_run.items;
    harness.neighbours = b.neighbours.items;
    harness.warn = b.warn.items;
    harness.lrm = b.lrm.items;
    // One text blob, in source order: `spice_cards` wants netlist text, and
    // joining here keeps the continuation rule in one place.
    if (b.spice.items.len != 0) harness.spice = try std.mem.join(arena, "\n", b.spice.items);

    // A construct is refused by the compiler or by the run, never both.
    if (harness.reject.len != 0 and harness.reject_run.len != 0) return error.BadSyntax;
    // A run-time refusal ends the run with a failure status: 1, the one every
    // run-time `error[...]` exits with, unless `//! exit` names another.
    if (harness.reject_run.len != 0) {
        if (!b.exit_set) harness.expected_exit = 1;
        if (harness.expected_exit == 0) return error.BadSyntax;
    }
    // A legal neighbour is the other half of a refusal.
    if (harness.neighbours.len != 0 and harness.reject.len == 0 and harness.reject_run.len == 0) return error.BadSyntax;
    if (harness.expected_checks != null and harness.reject.len != 0) return error.BadSyntax;
    // A refusal has no successful compile whose warnings could be judged.
    if ((harness.warn.len != 0 or harness.nowarn) and harness.reject.len != 0) return error.BadSyntax;
    if (harness.warn.len != 0 and harness.nowarn) return error.BadSyntax;

    assert(bench.times_s.len != 0);
    if (bench.noise == null) assert(b.noise.items.len == 0);
    return b.spec;
}

test "every keyword has a well-formed line, and its empty operand is a flag or refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // `good` parses on its own. `empty` is what `//! <keyword>` alone gives:
    // null for a bare flag, else the refusal the keyword's grammar names, so
    // a line whose operand was forgotten never checks nothing. The switch
    // is exhaustive: a new keyword does not compile until it has both.
    const Case = struct { good: []const u8, empty: ?ParseError };
    for (std.meta.tags(Keyword)) |kw| {
        const c: Case = switch (kw) {
            .param => .{ .good = "//! param g = 2m, is = 1e-14", .empty = error.BadSyntax },
            .bias => .{ .good = "//! bias V(n) = 0, I(a,b) = 0.25", .empty = error.BadSyntax },
            .sweep => .{ .good = "//! sweep V(p) = 0, 1", .empty = error.BadSyntax },
            .wave => .{ .good = "//! wave V(in) = 0, 1", .empty = error.BadSyntax },
            .psweep => .{ .good = "//! psweep r = 1, 2", .empty = error.BadSyntax },
            .temp => .{ .good = "//! temp 350", .empty = error.BadNumber },
            .time => .{ .good = "//! time 0, 1n, 2n", .empty = error.BadSyntax },
            .solve => .{ .good = "//! solve", .empty = null },
            .analysis => .{ .good = "//! analysis tran mytran", .empty = error.BadSyntax },
            .exit => .{ .good = "//! exit any\n//! exit 2", .empty = error.BadNumber },
            .checks => .{ .good = "//! checks 3", .empty = error.BadNumber },
            .plusargs => .{ .good = "//! plusargs +a=1 +b", .empty = error.BadSyntax },
            .reject => .{ .good = "//! reject E0310", .empty = error.BadSyntax },
            .@"reject-only" => .{ .good = "//! reject-only E0310", .empty = error.BadSyntax },
            .@"reject-run" => .{ .good = "//! reject-run E0816", .empty = error.BadSyntax },
            .neighbour => .{ .good = "//! reject E0310\n//! neighbour legal.va", .empty = error.BadSyntax },
            .warn => .{ .good = "//! warn W0853", .empty = error.BadSyntax },
            .nowarn => .{ .good = "//! nowarn", .empty = null },
            .noise => .{ .good = "//! noise thermal(a,b)#0 white=4e-18", .empty = error.BadSyntax },
            .acstim => .{ .good = "//! acstim (p,n) mag=1", .empty = error.BadSyntax },
            .acdyn => .{ .good = "//! acdyn (out,in) f=1k re=0 im=1", .empty = error.BadSyntax },
            .qsite => .{ .good = "//! qsite g+ s- lte", .empty = error.BadSyntax },
            .seed => .{ .good = "//! seed V(a) = 1", .empty = error.BadSyntax },
            .meta => .{ .good = "//! meta net d desc=\"drain\"", .empty = error.BadSyntax },
            .abstol => .{ .good = "//! abstol V(a) = 1e-6", .empty = error.BadSyntax },
            .limit => .{ .good = "//! limit V(b) = 0 -> V(b) = 0.1", .empty = error.BadSyntax },
            .spice => .{ .good = "//! spice R1 a b 1k", .empty = error.BadSyntax },
            .lrm => .{ .good = "//! lrm 5.6.1.3:2", .empty = error.BadLrmSection },
            .inherited => .{ .good = "//! inherited IEEE 1364-2005 18.1", .empty = error.BadLrmSection },
            .xfail => .{ .good = "//! xfail reason", .empty = error.BadSyntax },
            .print => .{ .good = "//! print none", .empty = error.BadSyntax },
            .@"discipline-resolution" => .{ .good = "//! discipline-resolution detail", .empty = error.BadSyntax },
            .display => .{ .good = "//! display record", .empty = error.BadSyntax },
            .@"fd-exempt" => .{ .good = "//! fd-exempt a vera_nodiff region", .empty = error.BadSyntax },
            .stdout => .{ .good = "//! stdout b7-analog-time: t=0.0025", .empty = error.BadSyntax },
            .expect => .{ .good = "//! expect vcd out.vcd == gold.vcd", .empty = error.BadSyntax },
            .diagnostic => .{ .good = "//! diagnostic", .empty = null },
            .@"lrm-reject" => .{ .good = "//! lrm-reject 12.32", .empty = error.BadLrmSection },
            .@"inherited-reject" => .{ .good = "//! inherited-reject IEEE 1364-2005 9.2", .empty = error.BadLrmSection },
        };
        _ = try parse(arena, c.good, null);
        const line = try arena.print("//! {t}\n", .{kw});
        if (c.empty) |e| {
            try std.testing.expectError(e, parse(arena, line, null));
        } else _ = try parse(arena, line, null);
    }
}

test "Diagnostics names the rejected line, or line 0 for a contradiction" {
    // Oracle: the line numbers of the hand-written sources below.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostics = .{};
    try std.testing.expectError(error.BadNumber, parse(arena, "module m;\n//! temp 300\n\n  //! temp warm\r\n", &diag));
    try std.testing.expectEqual(4, diag.line);
    try std.testing.expectError(error.UnknownDirective, parse(arena, "//! sweeep V(a) = 1", &diag));
    try std.testing.expectEqual(1, diag.line);
    // Each line is legal alone; together they contradict.
    try std.testing.expectError(error.BadSyntax, parse(arena, "//! warn W1\n//! nowarn\n", &diag));
    try std.testing.expectEqual(0, diag.line);
}
