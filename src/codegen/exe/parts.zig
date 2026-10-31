//! The runner pieces every renderer shares: `Bench` and `Facts` values in,
//! Zig source lines out (the page head, a card's writes and derive, one
//! point's unknowns, the time and wave arrays, exact f64 literals).
//! Cites: §3.4.1, §4.2.1.1, §3.6.3.2, §4.5.2, §6.3.4, §9.7.1, §9.7.3, §9.10,
//! §9.15, §9.19.
//!
//! Contents:
//! - `pub const Writer = std.Io.Writer`, `pub const WriteError = Writer.Error`
//! - `pub const noise_close: []const u8`
//! - `pub fn head(w: *Writer, title: []const u8, bench: *const Bench, facts: Facts) WriteError!void`
//! - `pub fn setCard(w: *Writer, indent: []const u8, card: []const u8, name: []const u8, value: f64) WriteError!void`
//! - `pub fn deriveCard(w: *Writer, indent: []const u8, card: []const u8, temperature_k: ?f64) WriteError!void`
//! - `pub fn sweepPoint(w: *Writer, bench: *const Bench, count: u32, n: u32) WriteError!void`
//! - `pub fn swept(w: *Writer, bench: *const Bench, count: u32, n: u32) WriteError!void`
//! - `pub fn pointUnknowns(w: *Writer, bench: *const Bench, facts: Facts, row: Row, mdl: []const u8, fresh: bool) WriteError!void`
//! - `pub fn timeArrays(w: *Writer, bench: *const Bench) WriteError!void`
//! - `pub fn fmtF64(x: f64) std.fmt.Alt(f64, formatF64)`, `pub fn formatF64(x: f64, w: *Writer) WriteError!void`

const std = @import("std");
const spec = @import("spec.zig");
const points = @import("points.zig");
const text = @import("text.zig");
const assert = std.debug.assert;
const Bench = spec.Bench;
const Facts = spec.Facts;
const Row = points.Row;

/// The writer every renderer writes the runner to.
pub const Writer = std.Io.Writer;
/// What a write fails with.
pub const WriteError = Writer.Error;

/// The relative compare for the noise and AC numbers, emitted locally only
/// where a line asks for a number.
pub const noise_close =
    \\        const nclose = struct {
    \\            fn f(g: f64, w: f64, rt: f64) bool {
    \\                return @abs(g - w) <= rt * @max(@abs(g), @abs(w));
    \\            }
    \\        }.f;
    \\
;

/// Writes the page every runner opens with: the fixed head, the compile
/// switches of `facts`, `title`, the §9.15 analysis name, the fixed body.
pub fn head(w: *Writer, title: []const u8, bench: *const Bench, facts: Facts) WriteError!void {
    assert(text.head.len != 0);
    assert(text.body.len != 0);
    try w.writeAll(text.head);
    try w.print("/// Read by `contract.validating`: run the contract's conformance checks.\npub const vera_validate_contract = {};\n", .{facts.validate_contract});
    try w.print("/// The switch of `fdCheck`, `finiteCheck` and `stateCheck`: the suite's `--certify`.\nconst fd_certify = {};\n", .{facts.certify});
    try w.print("/// `finiteCheck`'s claim: every contribution unit was proved finite.\nconst finite_proved = {};\n", .{facts.finite_proved});
    try w.print("const title = \"{f}\";\n\n", .{std.zig.fmtString(title)});
    try w.print("/// `bigStack`'s share for the device's memory-backed arrays.\nconst mem_bytes: usize = {d};\n\n", .{facts.mem_bytes});
    // §9.15 `$simparam$str("analysis_name")`: this testbench's one analysis.
    const name = if (bench.analysis_name.len != 0) bench.analysis_name else @tagName(bench.analysis);
    try w.print("const analysis_name = \"{f}\";\n\n", .{std.zig.fmtString(name)});
    try w.writeAll(text.body);
}

/// Writes one card line, `<card>.<name> = value`, at `indent`, and the
/// §9.19 `$param_given` bit. Asserts that `card` and `name` are not empty.
pub fn setCard(w: *Writer, indent: []const u8, card: []const u8, name: []const u8, value: f64) WriteError!void {
    assert(card.len != 0);
    assert(name.len != 0);
    // §3.4.1/§4.2.1.1 via `cardValue`: a card is written in reals and an
    // integer parameter rounds, away from zero on a tie.
    try w.print("{s}{s}.{f} = cardValue(@TypeOf({s}.{f}), \"{f}\", {f});\n", .{
        indent, card, std.zig.fmtId(name), card, std.zig.fmtId(name), std.zig.fmtString(name), fmtF64(value),
    });
    // §9.19 `$param_given` reads the bit `setGiven` raises, when codegen emitted one.
    try w.print("{s}if (comptime @hasDecl(D.Model, \"setGiven\")) {s}.setGiven(\"{f}\");\n", .{
        indent, card, std.zig.fmtString(name),
    });
}

/// Writes, at `indent`, the §9.10 temperature into `card` when one is given
/// (the `Model` row holds it), then the §6.3.4 `derive` and the shape check
/// that complete it. Every card a runner builds ends this way, after its
/// `setCard` lines.
pub fn deriveCard(w: *Writer, indent: []const u8, card: []const u8, temperature_k: ?f64) WriteError!void {
    assert(card.len != 0);
    if (temperature_k) |t| assert(std.math.isFinite(t));
    if (temperature_k) |t| try w.print("{s}{s}.temperature__ = {f};\n", .{ indent, card, fmtF64(t) });
    try w.print("{0s}if (comptime @hasDecl(D, \"derive\")) D.derive(Val, &{1s});\n{0s}shapeCheck(&{1s});\n", .{ indent, card });
}

/// Writes the host's §9.7.1/§9.7.3 sweep point `n`: `name=value` per swept
/// column, which `veraDiag` reports in place of the time during a dc sweep.
/// Nothing when nothing is swept.
pub fn sweepPoint(w: *Writer, bench: *const Bench, count: u32, n: u32) WriteError!void {
    assert(n < count);
    if (points.columnCount(bench) == 0) return;
    try w.writeAll("        diag_sweep = \"");
    var row: Row = .init(bench, count, n);
    while (row.next()) |v| {
        const k = row.k - 1;
        try w.print("{s}{f}={d}", .{ if (k == 0) "" else " ", std.zig.fmtString(points.column(bench, k).name), v });
    }
    assert(row.k == points.columnCount(bench));
    try w.writeAll("\";\n");
}

/// Writes point `n`'s §8.2 card: a copy of `model` named `pm`, each `psweep`
/// column written into it, then its `derive`. Nothing without a `psweep`.
pub fn swept(w: *Writer, bench: *const Bench, count: u32, n: u32) WriteError!void {
    assert(n < count);
    if (bench.psweeps.len == 0) return;
    try w.writeAll("        var pm = model;\n");
    var row: Row = .init(bench, count, n);
    while (row.next()) |v| {
        const k = row.k - 1;
        if (k >= bench.sweeps.len) try setCard(w, "        ", "pm", points.column(bench, k).name, v);
    }
    assert(row.k == points.columnCount(bench));
    try deriveCard(w, "        ", "pm", null);
}

/// Writes one point's unknowns for the fixed-grid and mixed runners: `x`
/// and `forced`, the §3.6.3.2 nodeset, a fresh `State` on card `mdl` when the
/// point starts an analysis (`fresh`), then what the directives pin.
pub fn pointUnknowns(w: *Writer, bench: *const Bench, facts: Facts, row: Row, mdl: []const u8, fresh: bool) WriteError!void {
    assert(mdl.len != 0);
    assert(row.k == 0); // A row not yet read.
    // `forced` marks the unknowns the host drives rather than Newton. By
    // default every unknown is tied to the reference; `//! solve` unties
    // the ones no line names. §3.6.3.2 a nodeset is an initial guess: it
    // seeds `x` and does not touch `forced`, so it picks which root Newton
    // finds. It precedes the `//! bias` lines, which override it.
    try w.print(
        \\        var x: [n_u]f64 = @splat(0.0);
        \\        var forced: [n_u]?f64 = @splat({s});
        \\        if (comptime @hasDecl(D, "u_nodeset")) for (D.u_nodeset, 0..) |nodeset_i, i| {{
        \\            if (nodeset_i) |v| x[i] = v;
        \\        }};
        \\
    , .{if (bench.solve_free) "null" else "0.0"});
    if (fresh) try w.print("        state = newState(&{s}, &inst);\n", .{mdl});
    // §4.5.2 operator unknowns are never forced (`Facts.op_states`).
    for (facts.op_states) |u| try w.print("        forced[{d}] = null;\n", .{u});
    for (bench.bias) |b|
        try w.print("        set(&x, &forced, \"{f}\", {f});\n", .{ std.zig.fmtString(b.name), fmtF64(b.value) });
    var r = row;
    for (bench.sweeps) |s| {
        const v = r.next().?; // A row has one value per column.
        try w.print("        set(&x, &forced, \"{f}\", {f});\n", .{ std.zig.fmtString(s.name), fmtF64(v) });
    }
    assert(r.k == bench.sweeps.len);
}

/// Writes the `//! time` grid as `times` and each `//! wave` as `wave_<k>`.
pub fn timeArrays(w: *Writer, bench: *const Bench) WriteError!void {
    // `parse` gives every grid and every wave at least one value.
    assert(bench.times_s.len != 0);
    try w.writeAll("const times = [_]f64{");
    try f64List(w, bench.times_s);
    try w.writeAll(" };\n");
    for (bench.waves, 0..) |wv, k| {
        assert(wv.values.len != 0);
        try w.print("const wave_{d} = [_]f64{{", .{k});
        try f64List(w, wv.values);
        try w.writeAll(" };\n");
    }
}

/// Formats `x` as a Zig expression that evaluates to the same f64, bit for
/// bit, wherever an f64 is expected: a shortest round-trip literal, or a
/// `std.math` call for inf and nan, which have no literal.
pub fn fmtF64(x: f64) std.fmt.Alt(f64, formatF64) {
    return .{ .data = x };
}

/// The `fmtF64` formatter.
pub fn formatF64(x: f64, w: *Writer) WriteError!void {
    if (std.math.isNan(x)) return w.writeAll("std.math.nan(f64)");
    if (std.math.isInf(x)) return w.writeAll(if (x > 0) "std.math.inf(f64)" else "-std.math.inf(f64)");
    // `{d}` writes these as integer literals, which Zig reads as a
    // comptime_int: `-0` loses its sign, and past 2^53 the shortest digits
    // are not the double's own integer. `{e}` is a float literal.
    if (x == 0 and std.math.signbit(x)) return w.writeAll("-0.0");
    if (@abs(x) >= 0x1p53) return w.print("{e}", .{x});
    assert(std.math.isFinite(x));
    try w.print("{d}", .{x});
}

// ---- private ----

/// Writes `xs` as the inside of a Zig array literal: ` a, b, c`, each by `fmtF64`.
fn f64List(w: *Writer, xs: []const f64) WriteError!void {
    assert(xs.len != 0);
    for (xs, 0..) |x, i| try w.print("{s}{f}", .{ if (i == 0) " " else ", ", fmtF64(x) });
}

/// Asserts that `fmtF64(x)` is a literal Zig reads back as `x`, bit for bit.
fn expectExactLiteral(x: f64) !void {
    var buf: [512]u8 = undefined;
    const lit = try std.mem.print(&buf, "{f}", .{fmtF64(x)});
    errdefer std.debug.print("fmtF64({e}) = {s}\n", .{ x, lit });
    const unsigned = if (lit[0] == '-') lit[1..] else lit;
    switch (std.zig.parseNumberLiteral(unsigned)) {
        .float => {},
        .int => |v| {
            try std.testing.expect(!(x == 0 and std.math.signbit(x)));
            const nearest: f64 = @floatFromInt(v);
            try std.testing.expect(nearest < 0x1p64 and @as(u64, @intFromFloat(nearest)) == v);
        },
        .big_int, .failure => return error.TestUnexpectedResult,
    }
    const back = try std.fmt.parseFloat(f64, lit);
    try std.testing.expectEqual(@as(u64, @bitCast(x)), @as(u64, @bitCast(back)));
}
test fmtF64 {
    // The oracle is Zig's own reading of the text. `parseNumberLiteral`
    // classifies it as the tokenizer does: a float literal is rounded
    // correctly (`parseFloat`), but an integer literal is a comptime_int,
    // which an f64 holds exactly only when the double is that integer, and
    // which has no negative zero.
    const edge = [_]f64{
        0.0,
        -0.0,
        1.0,
        -1.0,
        0.5,
        2.5e-3,
        300.15,
        1e20,
        0x1p53,
        0x1p53 + 2.0,
        1e23,
        -1e23,
        std.math.floatMax(f64),
        std.math.floatMin(f64),
        std.math.floatTrueMin(f64),
        -std.math.floatTrueMin(f64),
    };
    for (edge) |x| try expectExactLiteral(x);
    var prng = std.Random.DefaultPrng.init(0x5eed_f64);
    const r = prng.random();
    for (0..4096) |_| {
        const x: f64 = @bitCast(r.int(u64));
        if (!std.math.isFinite(x)) continue;
        try expectExactLiteral(x);
    }
    // inf and nan have no literal.
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("std.math.nan(f64)", try std.mem.print(&buf, "{f}", .{fmtF64(std.math.nan(f64))}));
    try std.testing.expectEqualStrings("-std.math.inf(f64)", try std.mem.print(&buf, "{f}", .{fmtF64(-std.math.inf(f64))}));
}
