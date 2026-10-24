//! Fixture `//!` directive parsing: raw .va source in, `tb.Directives` out
//! (analysis, bias, time, sweeps, expected noise/acstim/qsite tables, ...).
//! LRM: §1.3.1.1, §2.4, §2.6, §2.9.2, §3.2.1, §3.4.3, §3.6.3, §3.6.3.1, §4.6.3,
//! §4.6.4.3, §4.6.4.4, §4.6.4.6, §5.4.2, §5.4.3, §6.5.2.

const std = @import("std");
const tb = @import("../root.zig");
const naming = @import("ir").names;
const Lexer = @import("frontend").Lexer;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Error = tb.Error;
const Binding = tb.Binding;
const Sweep = tb.Sweep;
const Analysis = tb.Analysis;
const Directives = tb.Directives;
const NoiseWant = tb.NoiseWant;
const AcWant = tb.AcWant;
const AcDynWant = tb.AcDynWant;

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
};

/// Parses the `//!` lines of RAW source, before the preprocessor deletes
/// comments (§2.4). Other lines are ignored, so any .va is valid input.
/// A line is a directive exactly when, trimmed of spaces, tabs and `\r`, it
/// starts with `//!`; `tests/suite.zig`'s `hasDirective` keeps that rule.
/// Every slice in the result is allocated in `arena`. Fails on the first
/// malformed line, with the `tb.Error` that names what was wrong, and with
/// `error.BadSyntax` when lines contradict each other: `reject` beside
/// `reject-run`, `checks`, `warn` or `nowarn`; `warn` beside `nowarn`; a
/// `neighbour` on a fixture that refuses nothing; a `reject-run` whose
/// `exit` is 0.
pub fn parse(arena: Allocator, source: []const u8) Error!Directives {
    var d: Directives = .{};
    var analysis: ?Analysis = null;
    var params: std.ArrayList(Binding) = .empty;
    var bias: std.ArrayList(Binding) = .empty;
    var sweeps: std.ArrayList(Sweep) = .empty;
    var waves: std.ArrayList(Sweep) = .empty;
    var psweeps: std.ArrayList(Sweep) = .empty;
    var reject: std.ArrayList([]const u8) = .empty;
    var reject_run: std.ArrayList([]const u8) = .empty;
    var exit_set = false;
    var neighbours: std.ArrayList([]const u8) = .empty;
    var warn: std.ArrayList([]const u8) = .empty;
    var plusargs: std.ArrayList([]const u8) = .empty;
    var lrm: std.ArrayList([]const u8) = .empty;
    var spice: std.ArrayList([]const u8) = .empty;
    var noise: std.ArrayList(NoiseWant) = .empty;
    var qsites: std.ArrayList([]const u8) = .empty;
    var meta: std.ArrayList([]const u8) = .empty;
    var acstim: std.ArrayList(AcWant) = .empty;
    var acdyn: std.ArrayList(AcDynWant) = .empty;
    var seeds: std.ArrayList(Binding) = .empty;
    var abstols: std.ArrayList(Binding) = .empty;
    var limits: std.ArrayList(tb.LimitCase) = .empty;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, marker)) continue;
        const body = std.mem.trim(u8, line[marker.len..], " \t");
        if (body.len == 0) continue;

        const kw_end = std.mem.findAny(u8, body, " \t") orelse body.len;
        assert(kw_end != 0); // `body` is trimmed and nonempty.
        const kw = std.meta.stringToEnum(Keyword, body[0..kw_end]) orelse return error.UnknownDirective;
        const rest = std.mem.trim(u8, body[kw_end..], " \t");

        switch (kw) {
            .param, .bias => {
                // An empty list sets nothing: a forgotten operand, as `abstol`.
                if (rest.len == 0) return error.BadSyntax;
                try parseBindings(arena, rest, if (kw == .param) &params else &bias);
            },
            .sweep, .wave, .psweep => {
                const at = std.mem.findScalar(u8, rest, '=') orelse return error.BadSyntax;
                // A parameter has no access-function spelling, so `psweep` takes the
                // name as written; `unknownName` would only strip a `V(...)` that
                // cannot be there.
                const raw_name = std.mem.trim(u8, rest[0..at], " \t");
                const name = if (kw == .psweep) raw_name else try unknownName(arena, raw_name);
                if (name.len == 0) return error.BadSyntax;
                const entry: Sweep = .{
                    .name = try arena.dupe(u8, name),
                    .values = try parseNumbers(arena, rest[at + 1 ..]),
                };
                try (if (kw == .sweep) &sweeps else if (kw == .psweep) &psweeps else &waves)
                    .append(arena, entry);
            },
            .temp => {
                d.temp = try number(rest);
                if (!std.math.isFinite(d.temp)) return error.BadNumber;
            },
            .time => {
                const times = try parseNumbers(arena, rest);
                assert(times.len != 0); // `parseNumbers` refuses an empty list.
                // `dt` is the step from the previous time, and `sim.mixed.run`
                // requires the order. A lone NaN has no pair to fail it.
                for (times) |t| if (!std.math.isFinite(t)) return error.BadSyntax;
                for (times[0 .. times.len - 1], times[1..]) |a, b| if (!(b > a)) return error.BadSyntax;
                d.times = times;
            },
            .solve => {
                // A bare flag, and it composes with `bias`: `bias` still pins what
                // it names, `solve` frees only the rest. So a fixture that needs one
                // terminal grounded and another solved writes both lines, and no
                // per-unknown list is needed to say it.
                if (rest.len != 0) return error.BadSyntax;
                d.solve_free = true;
            },
            // `//! analysis <kind> [<name>]`: the name is §9.15's
            // `analysis_name`, the kind's own spelling when omitted.
            .analysis => {
                const kind_end = std.mem.findAny(u8, rest, " \t") orelse rest.len;
                analysis = std.meta.stringToEnum(Analysis, rest[0..kind_end]) orelse return error.BadSyntax;
                const name = std.mem.trim(u8, rest[kind_end..], " \t");
                if (std.mem.findAny(u8, name, " \t\"\\") != null) return error.BadSyntax;
                if (name.len != 0) d.analysis_name = try arena.dupe(u8, name);
            },
            .exit => {
                // `parseInt` alone also takes `+1` and `1_0`; `checks` refuses both.
                if (!digits(rest)) return error.BadNumber;
                d.expected_exit = std.fmt.parseInt(u8, rest, 10) catch return error.BadNumber;
                exit_set = true;
            },
            .checks => {
                if (d.expected_checks != null) return error.BadSyntax;
                if (!digits(rest)) return error.BadNumber;
                const count = std.fmt.parseInt(usize, rest, 10) catch return error.BadNumber;
                if (count == 0) return error.BadNumber;
                d.expected_checks = count;
            },
            .plusargs => {
                if (rest.len == 0) return error.BadSyntax;
                var args = std.mem.tokenizeAny(u8, rest, " \t");
                while (args.next()) |arg| {
                    if (arg.len < 2 or arg[0] != '+') return error.BadSyntax;
                    for (arg) |c| {
                        if (c < 0x21 or c > 0x7e or c == '\'' or c == '"' or c == '\\')
                            return error.BadSyntax;
                    }
                    try plusargs.append(arena, try arena.dupe(u8, arg));
                }
            },
            .reject, .@"reject-only" => {
                // The whole rest of the line is ONE substring, verbatim: message
                // fragments contain spaces and commas.
                if (rest.len == 0) return error.BadSyntax;
                try reject.append(arena, try arena.dupe(u8, rest));
                if (kw == .@"reject-only") d.reject_only = true;
            },
            .@"reject-run" => {
                // One verbatim substring of an `error[...]` line, as `reject`.
                if (rest.len == 0) return error.BadSyntax;
                try reject_run.append(arena, try arena.dupe(u8, rest));
            },
            .neighbour => {
                // A path, relative to the fixture's directory; the harness
                // checks that it names a collected positive fixture.
                if (rest.len == 0 or std.mem.findAny(u8, rest, " \t") != null) return error.BadSyntax;
                try neighbours.append(arena, try arena.dupe(u8, rest));
            },
            .warn => {
                // One verbatim substring, as `reject`.
                if (rest.len == 0) return error.BadSyntax;
                try warn.append(arena, try arena.dupe(u8, rest));
            },
            .nowarn => {
                if (rest.len != 0) return error.BadSyntax;
                d.nowarn = true;
            },
            .noise => {
                // `none` is the empty table, spelled rather than left as an absent
                // directive: "this model declares no generator" is a claim, and a
                // missing line is not one.
                if (!std.mem.eql(u8, rest, "none")) {
                    try noise.append(arena, try parseNoiseEntry(arena, rest));
                }
                d.asserts_noise = true;
            },
            .acstim => {
                // `none` is the empty table, for the reason `noise none` is.
                if (!std.mem.eql(u8, rest, "none")) {
                    try acstim.append(arena, try parseAcEntry(arena, rest));
                }
                d.asserts_acstim = true;
            },
            .acdyn => try acdyn.append(arena, try parseAcDynEntry(arena, rest)),
            .qsite => {
                // §5.6.1.2 one expected charge site, in slot order, in the form
                // the runner prints (`tb.Directives.qsites`). `none`: no site.
                if (rest.len == 0) return error.BadSyntax;
                if (!std.mem.eql(u8, rest, "none")) try qsites.append(arena, try arena.dupe(u8, rest));
                d.asserts_qsite = true;
            },
            .meta => {
                // `none` is the empty table, for the reason `noise none` is.
                if (!std.mem.eql(u8, rest, "none")) try meta.append(arena, try parseMetaEntry(arena, rest));
                d.asserts_meta = true;
            },
            .seed => {
                if (rest.len == 0) return error.BadSyntax;
                if (!std.mem.eql(u8, rest, "none")) try parseBindings(arena, rest, &seeds);
                d.asserts_seed = true;
            },
            .abstol => {
                if (rest.len == 0) return error.BadSyntax;
                try parseBindings(arena, rest, &abstols);
            },
            .limit => {
                const at = std.mem.find(u8, rest, "->") orelse return error.BadSyntax;
                var old: std.ArrayList(Binding) = .empty;
                var want: std.ArrayList(Binding) = .empty;
                try parseBindings(arena, rest[0..at], &old);
                try parseBindings(arena, rest[at + 2 ..], &want);
                if (want.items.len == 0) return error.BadSyntax;
                try limits.append(arena, .{ .old = old.items, .want = want.items });
            },
            .spice => {
                // Verbatim, including a leading `+`: the reader joins continuations
                // itself, so what it sees is the card as the annex prints it.
                if (rest.len == 0) return error.BadSyntax;
                try spice.append(arena, try arena.dupe(u8, rest));
            },
            .lrm => {
                if (!validSection(rest)) return error.BadLrmSection;
                try lrm.append(arena, try arena.dupe(u8, rest));
            },
            .inherited => {
                // `IEEE 1364-2005 18.1 (...)`: a clause §1.1 inherits whole. Not
                // an `lrm` cite, since `--coverage` counts this LRM's clauses only.
                // Checked here, then dropped: tests/suite.zig reads these lines
                // from raw source for measure B (`zig build suite -- ieee1364 --coverage`).
                if (!validInherited(rest)) return error.BadLrmSection;
            },
            .xfail => {
                // The whole rest of the line is the reason: prose for a human.
                if (rest.len == 0) return error.BadSyntax;
                d.xfail = try arena.dupe(u8, rest);
            },
            // §7.4.4's mode, as `vera --discipline-resolution=` selects it.
            .@"discipline-resolution" => d.discipline_resolution = std.meta.stringToEnum(@TypeOf(d.discipline_resolution), rest) orelse return error.BadSyntax,
            // §9.4 `vera --emit-exe --display=record`: the device's `say`.
            .display => d.display_record = if (std.mem.eql(u8, rest, "record")) true else return error.BadSyntax,
            .@"fd-exempt" => {
                // As `xfail`: the reason is the claim, so it is required.
                if (rest.len == 0) return error.BadSyntax;
                d.fd_exempt = try arena.dupe(u8, rest);
            },
            .print => {
                if (std.mem.eql(u8, rest, "none")) {
                    d.print_residual = false;
                } else if (std.mem.eql(u8, rest, "residual")) {
                    d.print_residual = true;
                } else return error.BadSyntax;
            },
        }
    }

    // §5.10.3.1 a grid that advances time is a transient analysis: run as dc,
    // `cross` would never fire on it.
    d.analysis = analysis orelse if (d.times.len > 1) .tran else .dc;
    d.params = params.items;
    d.bias = bias.items;
    d.sweeps = sweeps.items;
    d.waves = waves.items;
    d.psweeps = psweeps.items;
    d.reject = reject.items;
    d.reject_run = reject_run.items;
    // A construct is refused by the compiler or by the run, never both.
    if (d.reject.len != 0 and d.reject_run.len != 0) return error.BadSyntax;
    // A run-time refusal ends the run with a failure status: 1, the one every
    // run-time `error[...]` exits with, unless `//! exit` names another.
    if (d.reject_run.len != 0) {
        if (!exit_set) d.expected_exit = 1;
        if (d.expected_exit == 0) return error.BadSyntax;
    }
    d.neighbours = neighbours.items;
    // A legal neighbour is the other half of a refusal; a fixture that is
    // not one has none.
    if (d.neighbours.len != 0 and d.reject.len == 0 and d.reject_run.len == 0) return error.BadSyntax;
    d.plusargs = plusargs.items;
    if (d.expected_checks != null and d.reject.len != 0) return error.BadSyntax;
    d.warn = warn.items;
    // A refusal has no successful compile whose warnings could be judged.
    if ((d.warn.len != 0 or d.nowarn) and d.reject.len != 0) return error.BadSyntax;
    if (d.warn.len != 0 and d.nowarn) return error.BadSyntax;
    d.lrm = lrm.items;
    d.noise = noise.items;
    d.qsites = qsites.items;
    d.meta = meta.items;
    d.acstim = acstim.items;
    d.acdyn = acdyn.items;
    d.seeds = seeds.items;
    d.abstols = abstols.items;
    d.limits = limits.items;
    // One text blob, in source order: `spice_cards` wants netlist text, not a
    // list of lines, and joining here keeps the continuation rule in one place.
    if (spice.items.len != 0) d.spice = try std.mem.join(arena, "\n", spice.items);
    // The cross-line rules above, as the result states them.
    if (d.reject_run.len != 0) assert(d.expected_exit != 0);
    if (d.reject.len != 0) assert(d.expected_checks == null);
    assert(d.times.len != 0);
    return d;
}

/// Returns whether `cite` is a `//! lrm` cite: a chapter number or annex letter,
/// then dotted numbers (`5.8`, `A.8.3`, `B`), then optionally `:<n>`, the
/// n-th normative sentence of that clause (`5.6.1.3:2`). Syntax only: a
/// well-formed section the LRM does not have still passes.
pub fn validSection(cite: []const u8) bool {
    const colon = std.mem.findScalar(u8, cite, ':');
    if (colon) |c| if (!digits(cite[c + 1 ..]) or std.mem.eql(u8, cite[c + 1 ..], "0")) return false;
    const s = cite[0 .. colon orelse cite.len];
    var it = std.mem.splitScalar(u8, s, '.');
    const first = it.first();
    const annex = first.len == 1 and first[0] >= 'A' and first[0] <= 'H';
    if (!annex and !digits(first)) return false;
    while (it.next()) |part| if (!digits(part)) return false;
    return true;
}

/// Returns whether `s` is an `//! inherited` cite (`IEEE 1364-2005 17.2.9`,
/// optionally more clauses or a note). Only the first clause is checked.
fn validInherited(s: []const u8) bool {
    const std_name = "IEEE 1364-2005 ";
    if (!std.mem.startsWith(u8, s, std_name)) return false;
    const rest = s[std_name.len..];
    return validSection(rest[0 .. std.mem.findAny(u8, rest, " ,") orelse rest.len]);
}

/// Returns whether `s` is a nonempty run of ASCII decimal digits.
fn digits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// Returns whether `s` is a `//! noise` topology such as `thermal(p,n)#0`.
/// The kind is checked; node names are not, since directives are parsed before
/// the unknowns exist and a misspelled node fails the assertion anyway.
fn validNoiseEntry(s: []const u8) bool {
    const open = std.mem.findScalar(u8, s, '(') orelse return false;
    // `#<source>` after the branch is §4.6.4.6's correlation id; `#null` is
    // a row with no identity declared.
    const hash = std.mem.findScalarPos(u8, s, open, '#') orelse return false;
    if (hash == 0 or s[hash - 1] != ')') return false;
    // `s[open]` is `(` and `s[hash - 1]` is `)`, so the branch sits between.
    assert(hash > open + 1);
    const src = s[hash + 1 ..];
    // ponytail: reuse the nonempty decimal check; source IDs have no numeric bound.
    if (!std.mem.eql(u8, src, "null") and !digits(src)) return false;
    const kind = std.mem.trim(u8, s[0..open], " \t");
    // `table` is §4.6.4.3 AND §4.6.4.4: both export one kind, and which
    // interpolation applies is `noise_tables[k].interp`, not the row's tag.
    if (std.meta.stringToEnum(enum { thermal, shot, flicker, table }, kind) == null) return false;
    const inner = s[open + 1 .. hash - 1];
    const comma = std.mem.findScalar(u8, inner, ',') orelse return false;
    return std.mem.trim(u8, inner[0..comma], " \t").len != 0 and
        std.mem.trim(u8, inner[comma + 1 ..], " \t").len != 0;
}

/// Parses one `//! noise` line: the topology, then `key=value` fields.
/// The topology ends at the first space after the `#`, because the branch may
/// contain spaces (`thermal(p, n)#0`).
fn parseNoiseEntry(arena: Allocator, s: []const u8) Error!NoiseWant {
    const hash = std.mem.findScalar(u8, s, '#') orelse return error.BadSyntax;
    const end = std.mem.findAnyPos(u8, s, hash + 1, " \t") orelse s.len;
    const topo = s[0..end];
    if (!validNoiseEntry(topo)) return error.BadSyntax;

    var w: NoiseWant = .{ .topo = try arena.dupe(u8, topo) };
    var corrs: std.ArrayList(NoiseWant.Corr) = .empty;
    var fields = std.mem.tokenizeAny(u8, s[end..], " \t");
    while (fields.next()) |f| {
        const at = std.mem.findScalar(u8, f, '=') orelse return error.BadSyntax;
        const key = f[0..at];
        const val = f[at + 1 ..];
        if (std.mem.eql(u8, key, "name")) {
            w.name = try arena.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "white")) {
            w.white = try number(val);
        } else if (std.mem.eql(u8, key, "flicker")) {
            w.flicker = try number(val);
        } else if (std.mem.eql(u8, key, "ef")) {
            w.ef = try number(val);
        } else if (std.mem.eql(u8, key, "rtol")) {
            w.rtol = try number(val);
        } else if (std.mem.eql(u8, key, "interp")) {
            if (!std.mem.eql(u8, val, "linear") and !std.mem.eql(u8, val, "log")) return error.BadSyntax;
            w.interp = try arena.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "points") or std.mem.eql(u8, key, "psd")) {
            // Both are `<f>:<v>` pairs: knots, or densities at frequencies.
            var pts: std.ArrayList([2]f64) = .empty;
            var it = std.mem.tokenizeScalar(u8, val, ',');
            while (it.next()) |pair| {
                const colon = std.mem.findScalar(u8, pair, ':') orelse return error.BadSyntax;
                try pts.append(arena, .{ try number(pair[0..colon]), try number(pair[colon + 1 ..]) });
            }
            if (pts.items.len == 0) return error.BadSyntax;
            if (std.mem.eql(u8, key, "points")) w.points = pts.items else w.psd = pts.items;
        } else if (std.mem.eql(u8, key, "corr")) {
            // `<j>:<rho>`: the other row by its table index, then ρ.
            const colon = std.mem.findScalar(u8, val, ':') orelse return error.BadSyntax;
            if (!digits(val[0..colon])) return error.BadSyntax;
            try corrs.append(arena, .{
                .with = std.fmt.parseInt(u16, val[0..colon], 10) catch return error.BadNumber,
                .rho = try number(val[colon + 1 ..]),
            });
        } else return error.BadSyntax;
    }
    w.corrs = corrs.items;
    return w;
}

/// Parses one `//! meta` line into the row text the runner prints:
/// `<kind> <name>`, then ` desc="..."` and ` units="..."` when given, in that
/// order whatever order the line wrote them in. A value is any text without
/// a `"`, so a description may hold spaces; it cannot hold a quote.
fn parseMetaEntry(arena: Allocator, s: []const u8) Error![]const u8 {
    var it = std.mem.tokenizeAny(u8, s, " \t");
    const kind = it.next() orelse return error.BadSyntax;
    if (std.meta.stringToEnum(enum { parameter, variable, net }, kind) == null) return error.BadSyntax;
    const name = it.next() orelse return error.BadSyntax;
    var desc: ?[]const u8 = null;
    var units: ?[]const u8 = null;
    var rest = std.mem.trim(u8, it.rest(), " \t");
    while (rest.len != 0) {
        const eq = std.mem.findScalar(u8, rest, '=') orelse return error.BadSyntax;
        const key = rest[0..eq];
        if (eq + 1 >= rest.len or rest[eq + 1] != '"') return error.BadSyntax;
        const close = std.mem.findScalarPos(u8, rest, eq + 2, '"') orelse return error.BadSyntax;
        const val = rest[eq + 2 .. close];
        const slot = if (std.mem.eql(u8, key, "desc")) &desc else if (std.mem.eql(u8, key, "units")) &units else return error.BadSyntax;
        if (slot.* != null) return error.BadSyntax;
        slot.* = val;
        rest = std.mem.trimStart(u8, rest[close + 1 ..], " \t");
    }
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "{s} {s}", .{ kind, name });
    if (desc) |v| try out.print(arena, " desc=\"{s}\"", .{v});
    if (units) |v| try out.print(arena, " units=\"{s}\"", .{v});
    return out.items;
}

/// Splits a leading `(<row>,<col>)` off `s`: both names trimmed, and the text
/// after the `)`.
fn parsePair(s: []const u8) Error!struct { row: []const u8, col: []const u8, rest: []const u8 } {
    if (s.len == 0 or s[0] != '(') return error.BadSyntax;
    const close = std.mem.findScalar(u8, s, ')') orelse return error.BadSyntax;
    assert(close != 0); // `s[0]` is `(`.
    const inner = s[1..close];
    const comma = std.mem.findScalar(u8, inner, ',') orelse return error.BadSyntax;
    const row = std.mem.trim(u8, inner[0..comma], " \t");
    const col = std.mem.trim(u8, inner[comma + 1 ..], " \t");
    if (row.len == 0 or col.len == 0) return error.BadSyntax;
    return .{ .row = row, .col = col, .rest = s[close + 1 ..] };
}

/// Parses one `//! acstim` line (§4.6.3): the branch, then `key=value` fields.
/// A stimulus has no kind tag and no `#source`. The branch is canonicalised to
/// `(p,n)`, the device's spelling, so `(p, n)` compares equal.
fn parseAcEntry(arena: Allocator, s: []const u8) Error!AcWant {
    const pr = try parsePair(s);
    var w: AcWant = .{ .topo = try arena.print("({s},{s})", .{ pr.row, pr.col }) };
    var fields = std.mem.tokenizeAny(u8, pr.rest, " \t");
    while (fields.next()) |f| {
        const at = std.mem.findScalar(u8, f, '=') orelse return error.BadSyntax;
        const key = f[0..at];
        const val = f[at + 1 ..];
        if (std.mem.eql(u8, key, "name")) {
            w.name = try arena.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "mag")) {
            w.mag = try number(val);
        } else if (std.mem.eql(u8, key, "phase")) {
            w.phase = try number(val);
        } else if (std.mem.eql(u8, key, "rtol")) {
            w.rtol = try number(val);
        } else return error.BadSyntax;
    }
    return w;
}

/// Parses one `//! acdyn` line (`tb.AcDynWant`): the slot, then `f`, `re` and
/// `im`, all required, and an optional `tol`.
fn parseAcDynEntry(arena: Allocator, s: []const u8) Error!AcDynWant {
    const pr = try parsePair(s);
    var f: ?f64 = null;
    var re: ?f64 = null;
    var im: ?f64 = null;
    var tol: f64 = 1e-12;
    var fields = std.mem.tokenizeAny(u8, pr.rest, " \t");
    while (fields.next()) |fd| {
        const at = std.mem.findScalar(u8, fd, '=') orelse return error.BadSyntax;
        const key = fd[0..at];
        const val = try number(fd[at + 1 ..]);
        if (std.mem.eql(u8, key, "f")) {
            f = val;
        } else if (std.mem.eql(u8, key, "re")) {
            re = val;
        } else if (std.mem.eql(u8, key, "im")) {
            im = val;
        } else if (std.mem.eql(u8, key, "tol")) {
            tol = val;
        } else return error.BadSyntax;
    }
    return .{
        .row = try arena.dupe(u8, pr.row),
        .col = try arena.dupe(u8, pr.col),
        .f = f orelse return error.BadSyntax,
        .re = re orelse return error.BadSyntax,
        .im = im orelse return error.BadSyntax,
        .tol = tol,
    };
}

/// Returns the emitted `U` enum member a directive name refers to.
/// `V(a)`, `x[a]` and `a` all name node `a`. `I(a)` is the §5.4.2 flow
/// `flow(a,gnd)` (§1.3.1.1: every ground is `gnd`), `I(a,b)` is `flow(a,b)`
/// and `I(<p>)` the §5.4.3 port flow `flow(<p>)`. A name that is not a Zig
/// identifier goes through `naming.sanitize`, as codegen spells `U`; a legal
/// identifier is taken as written, so an escaped member (`flowZ28pZ2cnZ29`)
/// is not escaped twice. Fails with `error.BadUnknownName` for a branch
/// potential `V(a,b)`, which is not an unknown, and with `error.BadSyntax`
/// when the access function names nothing (`V()`, `I()`, `I(a,)`, `x[]`).
/// Result may alias `raw` or be allocated in `arena`.
///
/// This is a text mapping because `ix()` resolves it against `U` at the
/// runner's compile time. `I(a)` is ambiguous on a module with a net named
/// `gnd`; such a fixture writes the member as `emitTopology` prints it.
fn unknownName(arena: Allocator, raw: []const u8) Error![]const u8 {
    var s = std.mem.trim(u8, raw, " \t");
    if (std.mem.startsWith(u8, s, "V(") and std.mem.endsWith(u8, s, ")")) {
        s = std.mem.trim(u8, s[2 .. s.len - 1], " \t");
        // §5.4.2's branch potential V(a,c) is derived from two nets and has
        // no row to pin. Refused here: sanitized into an identifier, it would
        // fail the testbench build, which the harness reports as an engine bug.
        if (std.mem.findScalar(u8, s, ',') != null) return error.BadUnknownName;
    }
    if (std.mem.startsWith(u8, s, "I(") and std.mem.endsWith(u8, s, ")")) {
        const inner = std.mem.trim(u8, s[2 .. s.len - 1], " \t");
        if (std.mem.findScalar(u8, inner, ',')) |comma| {
            // Each terminal trimmed, as codegen spells `flow(a,b)`.
            const a = std.mem.trim(u8, inner[0..comma], " \t");
            const b = std.mem.trim(u8, inner[comma + 1 ..], " \t");
            if (a.len == 0 or b.len == 0) return error.BadSyntax;
            s = try arena.print("flow({s},{s})", .{ a, b });
        } else if (inner.len != 0 and inner[0] == '<') {
            if (std.mem.trim(u8, inner, "<> \t").len == 0) return error.BadSyntax;
            s = try arena.print("flow({s})", .{inner});
        } else {
            if (inner.len == 0) return error.BadSyntax;
            s = try arena.print("flow({s},gnd)", .{inner}); // §5.4.2 I(a) ≡ I(a,gnd)
        }
    }
    if (std.mem.startsWith(u8, s, "x[") and std.mem.endsWith(u8, s, "]")) s = s[2 .. s.len - 1];
    s = std.mem.trim(u8, s, " \t");
    // `V()`, `x[]`: an access function that names nothing.
    if (s.len == 0) return error.BadSyntax;
    if (std.zig.isValidId(s)) return s;
    // Worst case is three bytes out per byte in (`Z` plus two hex digits),
    // plus the one `Z` a Zig-reserved word picks up.
    const buf = try arena.alloc(u8, s.len * 3 + 1);
    const id = naming.sanitize(buf, s) catch unreachable;
    assert(id.len >= s.len);
    assert(std.zig.isValidId(id));
    return id;
}

/// Appends the `name = value` pairs in `rest`, split on top-level commas so
/// the comma in §5.4.2's `I(a,b)` stays inside its name. Only `(` nests: a
/// §6.5.2 element `d[1]` holds no comma. Names are resolved by `unknownName`.
fn parseBindings(arena: Allocator, rest: []const u8, out: *std.ArrayList(Binding)) Error!void {
    var depth: u32 = 0;
    var start: usize = 0;
    for (rest, 0..) |ch, i| switch (ch) {
        '(' => depth += 1,
        ')' => depth -|= 1,
        ',' => if (depth == 0) {
            try oneBinding(arena, rest[start..i], out);
            start = i + 1;
        },
        else => {},
    };
    assert(start <= rest.len);
    try oneBinding(arena, rest[start..], out);
}

fn oneBinding(arena: Allocator, item: []const u8, out: *std.ArrayList(Binding)) Error!void {
    const t = std.mem.trim(u8, item, " \t");
    if (t.len == 0) return;
    const at = std.mem.findScalar(u8, t, '=') orelse return error.BadSyntax;
    const name = std.mem.trim(u8, t[0..at], " \t");
    if (name.len == 0) return error.BadSyntax;
    try out.append(arena, .{
        .name = try unknownName(arena, name),
        .value = try number(t[at + 1 ..]),
    });
}

/// Parses a comma list of `number`s into `arena`. Empty items are skipped;
/// a list with no number at all is `error.BadSyntax`.
fn parseNumbers(arena: Allocator, rest: []const u8) Error![]const f64 {
    var out: std.ArrayList(f64) = .empty;
    var it = std.mem.splitScalar(u8, rest, ',');
    while (it.next()) |item| {
        const t = std.mem.trim(u8, item, " \t");
        if (t.len == 0) continue;
        try out.append(arena, try number(t));
    }
    if (out.items.len == 0) return error.BadSyntax;
    return out.items;
}

/// Parses a directive number, accepting §2.6 scale factors (`1u`).
fn number(raw: []const u8) Error!f64 {
    const t = std.mem.trim(u8, raw, " \t");
    if (t.len == 0) return error.BadNumber;
    const exp = Lexer.scaleExp(t[t.len - 1]) orelse
        return std.fmt.parseFloat(f64, t) catch error.BadNumber;

    // The suffix becomes an exponent and the text is parsed once, as the
    // model's lexer does: `200 * 1e-6` is not `200e-6`, and a `//! time 200u`
    // point must equal `200u` written in the model.
    const head = std.mem.trim(u8, t[0 .. t.len - 1], " \t");
    if (head.len == 0) return error.BadNumber;
    var buf: [64]u8 = undefined;
    assert(exp.len < buf.len); // `scaleExp`'s longest is `e-18`.
    if (head.len + exp.len > buf.len) return error.BadNumber;
    @memcpy(buf[0..head.len], head);
    @memcpy(buf[head.len..][0..exp.len], exp);
    return std.fmt.parseFloat(f64, buf[0 .. head.len + exp.len]) catch error.BadNumber;
}

test "every keyword has a well-formed line, and its empty operand is a flag or refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // `good` parses on its own. `empty` is what `//! <keyword>` alone gives:
    // null for a bare flag, else the refusal the keyword's grammar names, so
    // a line whose operand was forgotten never checks nothing. The switch
    // is exhaustive: a new keyword does not compile until it has both.
    const Case = struct { good: []const u8, empty: ?Error };
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
            .exit => .{ .good = "//! exit 2", .empty = error.BadNumber },
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
        };
        _ = try parse(arena, c.good);
        const line = try arena.print("//! {t}\n", .{kw});
        if (c.empty) |e| {
            try std.testing.expectError(e, parse(arena, line));
        } else _ = try parse(arena, line);
    }
}

test number {
    // §2.6 every scale factor, against the Zig literal with the same
    // exponent: the suffix becomes an exponent before the one parse, as
    // `Lexer.scaleExp` makes the model's lexer do.
    const cases = [_]struct { []const u8, f64 }{
        .{ "1T", 1e12 },
        .{ "1G", 1e9 },
        .{ "1M", 1e6 },
        .{ "1K", 1e3 },
        .{ "1k", 1e3 },
        .{ "1m", 1e-3 },
        .{ "1u", 1e-6 },
        .{ "1n", 1e-9 },
        .{ "1p", 1e-12 },
        .{ "1f", 1e-15 },
        .{ "1a", 1e-18 },
        .{ "-3k", -3e3 },
        .{ "2.5m", 2.5e-3 },
        .{ " 7u ", 7e-6 },
        .{ "300.15", 300.15 },
    };
    for (cases) |c| try std.testing.expectEqual(c[1], try number(c[0]));
    // Every other letter is not a scale factor, and a suffix needs a mantissa.
    for ("ABCDEFHIJLNOPQRSUVWXYZbcdeghijloqrstvwxyz") |letter| {
        const text = [2]u8{ '1', letter };
        try std.testing.expectError(error.BadNumber, number(&text));
    }
    try std.testing.expectError(error.BadNumber, number("u"));
    try std.testing.expectError(error.BadNumber, number(""));
    try std.testing.expectError(error.BadNumber, number("1e3k"));
}

test unknownName {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Each spelling lands on the member codegen prints: `naming.sanitize` of
    // `flow(a,b)` or `d[1]`, and a legal identifier as written.
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "a", "a" },
        .{ "V(a)", "a" },
        .{ "V( a )", "a" },
        .{ "x[a]", "a" },
        .{ "I(a)", "flowZ28aZ2cgndZ29" },
        .{ "I(a,b)", "flowZ28aZ2cbZ29" },
        // Whitespace inside the access function is not part of the name.
        .{ "I(a, b)", "flowZ28aZ2cbZ29" },
        .{ "I(<p>)", "flowZ28Z3cpZ3eZ29" },
        .{ "d[1]", "dZ5b1Z5d" },
        .{ "flowZ28pZ2cnZ29", "flowZ28pZ2cnZ29" },
    };
    for (cases) |c| try std.testing.expectEqualStrings(c[1], try unknownName(arena, c[0]));
    // §5.4.2 a branch potential is no unknown.
    try std.testing.expectError(error.BadUnknownName, unknownName(arena, "V(a,b)"));
    // An access function that names nothing is a typo, refused here rather
    // than as a testbench that does not build.
    for ([_][]const u8{ "V()", "V( )", "I()", "I(a,)", "I(,b)", "I(<>)", "x[]" }) |bad| {
        try std.testing.expectError(error.BadSyntax, unknownName(arena, bad));
    }
}
