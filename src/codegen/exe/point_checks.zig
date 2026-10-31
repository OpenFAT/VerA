//! The device checks a runner makes at its first operating point: the rows
//! of a `Bench` that read the bias or the card in, the runner's comparisons
//! of `noisePsd`, `acStim`, `acDyn` and `limit` against them out. `mdl` names
//! the card the point was solved on (`model`, or `pm` under a `psweep`).
//! Cites: §4.6.3, §4.6.4.1, §4.6.4.2, §4.6.4.6, §9.17.3; A.8.2.
//!
//! Contents:
//! - `pub fn noisePsd(w: *Writer, rows: []const NoiseWant, mdl: []const u8) WriteError!void`
//! - `pub fn acStim(w: *Writer, rows: []const AcWant, mdl: []const u8) WriteError!void`
//! - `pub fn acDyn(w: *Writer, rows: []const AcDynWant, mdl: []const u8) WriteError!void`
//! - `pub fn limits(w: *Writer, cases: []const LimitCase, mdl: []const u8) WriteError!void`

const std = @import("std");
const spec = @import("spec.zig");
const parts = @import("parts.zig");
const assert = std.debug.assert;
const AcDynWant = spec.AcDynWant;
const AcWant = spec.AcWant;
const LimitCase = spec.LimitCase;
const NoiseWant = spec.NoiseWant;
const Writer = parts.Writer;
const WriteError = parts.WriteError;
const fmtF64 = parts.fmtF64;

/// Writes the §4.6.4.1/.2 `white`, `flicker` and `ef` checks and the
/// §4.6.4.6 correlations, read from `noisePsd` at the enclosing point.
/// Nothing when no row needs a point.
pub fn noisePsd(w: *Writer, rows: []const NoiseWant, mdl: []const u8) WriteError!void {
    assert(mdl.len != 0);
    for (rows) |r| {
        if (r.needsPoint()) break;
    } else return;
    assert(rows.len != 0);
    try w.writeAll("        if (comptime @hasDecl(D, \"noisePsd\")) {\n");
    try w.writeAll(parts.noise_close);
    try w.print("            const psd = D.noisePsd(Dual, x, &{s}, &inst, sim_state);\n", .{mdl});
    for (rows, 0..) |r, k| {
        if (!r.needsPoint()) continue;
        try w.print("            if (comptime D.noise_gens.len > {d}) {{\n", .{k});
        // §4.6.4.6: a density is scaled by the square of the use's
        // coefficient, an exponent is not scaled at all.
        const fields = [_]struct { []const u8, ?f64, bool }{
            .{ "white", r.white, true },
            .{ "flicker", r.flicker, true },
            .{ "ef", r.ef, false },
        };
        for (fields) |f| {
            const want = f[1] orelse continue;
            try w.print("                std.debug.print(\"noise[{d}].{s} got={{d}} want={{d}} ok={{d}}\\n\", .{{\n                    ", .{ k, f[0] });
            try psdTerm(w, k, f[0], f[2]);
            try w.print(", {f},\n                    @intFromBool(nclose(", .{fmtF64(want)});
            try psdTerm(w, k, f[0], f[2]);
            try w.print(", {f}, {f})),\n                }});\n", .{ fmtF64(want), fmtF64(r.rtol) });
        }
        // §4.6.4.6 the correlation coefficient of rows k and j, from what a
        // host is handed: one shared `source` is one generator, so the two
        // contributions move together, scaled by `coeff_k` and `coeff_j`,
        // and ρ is the sign of their product; a `corr_with` link carries a
        // partial ρ; anything else is independent. A zero coefficient makes
        // ρ 0/0, a NaN that compares false.
        for (r.corrs) |c| try w.print(
            \\                if (comptime D.noise_gens.len > {1d}) {{
            \\                    const sgn = (psd[{0d}].coeff * psd[{1d}].coeff) / (@abs(psd[{0d}].coeff) * @abs(psd[{1d}].coeff));
            \\                    const linked = if (psd[{0d}].corr_with) |o| o == {1d} else false;
            \\                    const back = if (psd[{1d}].corr_with) |o| o == {0d} else false;
            \\                    const rho: f64 = if ({0d} == {1d}) 1.0
            \\                        else if (D.noise_gens[{0d}].source != null and D.noise_gens[{0d}].source == D.noise_gens[{1d}].source) sgn
            \\                        else if (linked) psd[{0d}].corr * sgn
            \\                        else if (back) psd[{1d}].corr * sgn
            \\                        else 0.0;
            \\                    std.debug.print("noise[{0d}].corr[{1d}] got={{d}} want={{d}} ok={{d}}\n", .{{ rho, @as(f64, {2f}), @intFromBool(nclose(rho, {2f}, {3f})) }});
            \\                }} else std.debug.print("noise[{0d}].corr[{1d}] got=none want={{d}} ok=0\n", .{{@as(f64, {2f})}});
            \\
        , .{ k, c.with, fmtF64(c.rho), fmtF64(r.rtol) });
        try w.writeAll("            }\n");
    }
    try w.writeAll("        }\n");
}

/// Writes the §4.6.3 `mag` and `phase` checks, read from `acStim` at the
/// enclosing point (A.8.2 makes both `analog_expression`s, so they may
/// depend on bias). Nothing when no row needs a point.
pub fn acStim(w: *Writer, rows: []const AcWant, mdl: []const u8) WriteError!void {
    assert(mdl.len != 0);
    for (rows) |r| {
        if (r.needsPoint()) break;
    } else return;
    assert(rows.len != 0);
    try w.writeAll("        if (comptime @hasDecl(D, \"acStim\")) {\n");
    try w.writeAll(parts.noise_close);
    try w.print("            const stim = D.acStim(Val, x, &{s}, &inst, sim_state);\n", .{mdl});
    for (rows, 0..) |r, k| {
        if (!r.needsPoint()) continue;
        try w.print("            if (comptime D.ac_gens.len > {d}) {{\n", .{k});
        const fields = [_]struct { []const u8, ?f64 }{ .{ "mag", r.mag }, .{ "phase", r.phase } };
        for (fields) |f| {
            const want = f[1] orelse continue;
            try w.print(
                "                std.debug.print(\"acstim[{d}].{s} got={{d}} want={{d}} ok={{d}}\\n\", .{{\n" ++
                    "                    stim[{d}].{s}, {f},\n" ++
                    "                    @intFromBool(nclose(stim[{d}].{s}, {f}, {f})),\n" ++
                    "                }});\n",
                .{ k, f[0], k, f[0], fmtF64(want), k, f[0], fmtF64(want), fmtF64(r.rtol) },
            );
        }
        try w.writeAll("            }\n");
    }
    try w.writeAll("        }\n");
}

/// Writes the `//! acdyn` checks: `acDyn`'s term at each named slot and
/// frequency, at the enclosing point.
pub fn acDyn(w: *Writer, rows: []const AcDynWant, mdl: []const u8) WriteError!void {
    assert(mdl.len != 0);
    for (rows) |r| {
        assert(r.row.len != 0);
        try w.print("        {{\n            const ad = acDynAt(ix(\"{f}\"), ix(\"{f}\"), 2.0 * std.math.pi * {f}, &x, &{s}, &inst);\n", .{
            std.zig.fmtString(r.row), std.zig.fmtString(r.col), fmtF64(r.f_hz), mdl,
        });
        const terms = [_]struct { []const u8, f64 }{ .{ "re", r.re }, .{ "im", r.im } };
        for (terms) |p| try w.print(
            "            std.debug.print(\"acdyn[({f},{f}) f={f}].{s} got={{e}} want={{e}} ok={{d}}\\n\", .{{ ad.{s}, @as(f64, {f}), @intFromBool(@abs(ad.{s} - {f}) <= {f}) }});\n",
            .{ std.zig.fmtString(r.row), std.zig.fmtString(r.col), fmtF64(r.f_hz), p[0], p[0], fmtF64(p[1]), p[0], fmtF64(p[1]), fmtF64(r.tol) },
        );
        try w.writeAll("        }\n");
    }
}

/// Writes the §9.17.3 `limit` checks at the first point, after the solve,
/// so `x` is the bias the fixture states: `old` is `x` but for the case's
/// lanes, and the result must hold each wanted lane (and the verdict).
pub fn limits(w: *Writer, cases: []const LimitCase, mdl: []const u8) WriteError!void {
    assert(mdl.len != 0);
    for (cases, 0..) |c, k| {
        assert(c.want.len != 0); // `limitCase` refuses a case that names no output.
        try w.writeAll("        {\n            var old = x;\n            _ = &old;\n");
        for (c.old) |b| try w.print("            old[ix(\"{f}\")] = {f};\n", .{ std.zig.fmtString(b.name), fmtF64(b.value) });
        try w.print(
            \\            if (comptime !@hasDecl(D, "limit")) {{
            \\                std.debug.print("limit[{d}] got=none want=limit ok=0\n", .{{}});
            \\            }} else {{
            \\                const r = D.limit(Val, &{s}, &inst, x, old, sim_state);
            \\
        , .{ k, mdl });
        for (c.want) |b| {
            if (std.mem.eql(u8, b.name, "converged")) {
                try w.print("                std.debug.print(\"limit[{d}].converged got={{d}} want={d} ok={{d}}\\n\", .{{ @intFromBool(r.converged), @intFromBool(r.converged == {}) }});\n", .{ k, @intFromBool(b.value != 0), b.value != 0 });
            } else {
                try w.print("                std.debug.print(\"limit[{d}].{f} got={{d}} want={{d}} ok={{d}}\\n\", .{{ r.x[ix(\"{f}\")], @as(f64, {f}), @intFromBool(near(r.x[ix(\"{f}\")], {f})) }});\n", .{
                    k, std.zig.fmtString(b.name), std.zig.fmtString(b.name), fmtF64(b.value), std.zig.fmtString(b.name), fmtF64(b.value),
                });
            }
        }
        try w.writeAll("            }\n        }\n");
    }
}

// ---- private ----

/// Writes row `k`'s §4.6.4.6 density term: `psd[k].<field>`, times `coeff²`
/// when `scaled` (a density; an exponent is not scaled).
fn psdTerm(w: *Writer, k: usize, field: []const u8, scaled: bool) WriteError!void {
    assert(field.len != 0);
    if (scaled) assert(!std.mem.eql(u8, field, "ef"));
    if (scaled)
        try w.print("psd[{d}].{s} * psd[{d}].coeff * psd[{d}].coeff", .{ k, field, k, k })
    else
        try w.print("psd[{d}].{s}", .{ k, field });
}
