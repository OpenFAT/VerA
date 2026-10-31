//! The device-table checks a runner makes once, before its points: the
//! expected rows of a `Bench` in, the runner's comparisons of them against
//! the device's comptime tables out. Each prints one `got=/want= ok=` line
//! per row plus one for the count. A table these lines name is published
//! only to a host, so the table is the one place its clause is observable.
//! Cites: §2.9.2, §3.2.1, §3.4.3, §3.6.1.2, §3.6.3.1, §4.6.3, §4.6.4,
//! §4.6.4.1-.4, §5.6.1.2, §9.17.3.
//!
//! Contents:
//! - `pub fn noiseTopology(w: *Writer, rows: []const NoiseWant) WriteError!void`
//! - `pub fn acTopology(w: *Writer, rows: []const AcWant) WriteError!void`
//! - `pub fn qSites(w: *Writer, rows: []const []const u8) WriteError!void`
//! - `pub fn seedCheck(w: *Writer, seeds: []const Binding) WriteError!void`
//! - `pub fn meta(w: *Writer, rows: []const []const u8) WriteError!void`
//! - `pub fn abstols(w: *Writer, rows: []const Binding) WriteError!void`

const std = @import("std");
const spec = @import("spec.zig");
const parts = @import("parts.zig");
const assert = std.debug.assert;
const AcWant = spec.AcWant;
const Binding = spec.Binding;
const NoiseWant = spec.NoiseWant;
const Writer = parts.Writer;
const WriteError = parts.WriteError;
const fmtF64 = parts.fmtF64;

/// Writes the §4.6.4 `noise_gens` checks: the row count and each row's
/// `kind(row,col)#source`, then the label and table fields of the rows that
/// state them (`labels`).
pub fn noiseTopology(w: *Writer, rows: []const NoiseWant) WriteError!void {
    try w.writeAll(
        \\
        \\    // §4.6.4: what this device tells a host about its noise
        \\    // generators. Nothing in the model's own text can see this —
        \\    // §4.6.2 makes every source read 0 outside a small-signal
        \\    // analysis — so the table is the only place the clause is
        \\    // observable, and a `//! noise` line is how a fixture reaches it.
        \\    {
        \\        const want = [_][]const u8{
        \\
    );
    for (rows) |e| {
        assert(e.topo.len != 0);
        try w.print("            \"{f}\",\n", .{std.zig.fmtString(e.topo)});
    }
    try w.writeAll(
        \\        };
        \\        if (comptime @hasDecl(D, "noise_gens")) {
        \\            std.debug.print("noise count got={d} want={d} ok={d}\n", .{
        \\                D.noise_gens.len, want.len, @intFromBool(D.noise_gens.len == want.len),
        \\            });
        \\            inline for (D.noise_gens, 0..) |g, i| {
        \\                // `U`'s tag names ARE the spelling contract — the same
        \\                // names a `//! bias` line uses and the same ones a
        \\                // diagnostic prints — so a fixture writes what it reads
        \\                // in the source.
        \\                // `#k` is §4.6.4.6's correlation column: two rows
        \\                // printing the same `#k` share one physical generator;
        \\                // `#null` is a row that declared no identity.
        \\                // Every field is comptime, so the row is too, at any length.
        \\                const got = comptime std.fmt.comptimePrint("{s}({s},{s})#{?d}", .{
        \\                    @tagName(g.kind),
        \\                    @tagName(@as(D.U, @fromBackingInt(@intCast(g.row)))),
        \\                    @tagName(@as(D.U, @fromBackingInt(@intCast(g.col)))),
        \\                    g.source,
        \\                });
        \\                const w_i: []const u8 = if (i < want.len) want[i] else "<none>";
        \\                std.debug.print("noise[{d}] got={s} want={s} ok={d}\n", .{
        \\                    i, got, w_i, @intFromBool(std.mem.eql(u8, got, w_i)),
        \\                });
        \\            }
        \\        } else {
        \\            // No table at all is the empty table: a device that
        \\            // declares no generator does not declare an empty one.
        \\            std.debug.print("noise count got=0 want={d} ok={d}\n", .{
        \\                want.len, @intFromBool(want.len == 0),
        \\            });
        \\        }
        \\    }
        \\
    );
    try labels(w, rows);
}

/// Writes the comptime §4.6.3 `ac_gens` checks: the source count, each
/// branch and each stated analysis name, in one block.
pub fn acTopology(w: *Writer, rows: []const AcWant) WriteError!void {
    try w.writeAll(
        \\
        \\    // §4.6.3: what this device tells a host about its AC stimuli. The
        \\    // model's own text cannot see this either — what a `CHECK` on
        \\    // `ac_stim` reads back is the residual's real part, `mag*cos(phase)`
        \\    // — so the phasor leaves through `ac_gens`/`acStim` and a
        \\    // `//! acstim` line is how a fixture reaches it.
        \\    {
        \\        const want = [_][]const u8{
        \\
    );
    for (rows) |e| try w.print("            \"{f}\",\n", .{std.zig.fmtString(e.topo)});
    try w.writeAll("        };\n");
    // A parallel `?[]const u8` column: `inline for` makes the index comptime,
    // so one lookup covers every line.
    try w.writeAll("        const want_name = [_]?[]const u8{");
    for (rows, 0..) |e, i| {
        const sep = if (i == 0) " " else ", ";
        if (e.name) |nm| try w.print("{s}\"{f}\"", .{ sep, std.zig.fmtString(nm) }) else try w.print("{s}null", .{sep});
    }
    try w.writeAll(
        \\ };
        \\        _ = &want_name;
        \\        if (comptime @hasDecl(D, "ac_gens")) {
        \\            std.debug.print("acstim count got={d} want={d} ok={d}\n", .{
        \\                D.ac_gens.len, want.len, @intFromBool(D.ac_gens.len == want.len),
        \\            });
        \\            inline for (D.ac_gens, 0..) |g, i| {
        \\                // `U`'s tag names ARE the spelling contract, same as the
        \\                // `//! noise` block and the same as `//! bias`.
        \\                const got = comptime std.fmt.comptimePrint("({s},{s})", .{
        \\                    @tagName(@as(D.U, @fromBackingInt(@intCast(g.row)))),
        \\                    @tagName(@as(D.U, @fromBackingInt(@intCast(g.col)))),
        \\                });
        \\                const w_i: []const u8 = if (i < want.len) want[i] else "<none>";
        \\                std.debug.print("acstim[{d}] got={s} want={s} ok={d}\n", .{
        \\                    i, got, w_i, @intFromBool(std.mem.eql(u8, got, w_i)),
        \\                });
        \\                if (i < want_name.len) if (want_name[i]) |wn| {
        \\                    std.debug.print("acstim[{d}].name got={s} want={s} ok={d}\n", .{
        \\                        i, g.name, wn, @intFromBool(std.mem.eql(u8, g.name, wn)),
        \\                    });
        \\                };
        \\            }
        \\        } else {
        \\            // No table at all is the empty table, for the reason the
        \\            // `noise_gens` block gives.
        \\            std.debug.print("acstim count got=0 want={d} ok={d}\n", .{
        \\                want.len, @intFromBool(want.len == 0),
        \\            });
        \\        }
        \\    }
        \\
    );
    assert(rows.len == 0 or rows[0].topo.len != 0);
}

/// Writes the §5.6.1.2 charge-site check: the site layout is a comptime
/// property of the device, printed as `//! qsite` writes a row.
pub fn qSites(w: *Writer, rows: []const []const u8) WriteError!void {
    try w.writeAll(
        \\
        \\    // §5.6.1.2 the charge sites a host tapes one by one: which rows
        \\    // each stamps (`q_stamps`) and whether `q_lte` checks it.
        \\    {
        \\        const want = [_][]const u8{
        \\
    );
    for (rows) |e| {
        assert(e.len != 0);
        try w.print("            \"{f}\",\n", .{std.zig.fmtString(e)});
    }
    try w.writeAll(
        \\        };
        \\        const nq = if (comptime @hasDecl(D, "q")) contract.nQ(D) else 0;
        \\        std.debug.print("qsite count got={d} want={d} ok={d}\n", .{ nq, want.len, @intFromBool(nq == want.len) });
        \\        if (comptime @hasDecl(D, "q")) {
        \\            inline for (0..nq) |k| {
        \\                // Built at comptime from comptime stamps, so a site with
        \\                // many rows is never cut short.
        \\                const got = comptime blk: {
        \\                    @setEvalBranchQuota(1_000_000);
        \\                    var s: []const u8 = "";
        \\                    for (contract.qStamps(D)) |e| if (e.site == k) {
        \\                        s = s ++ if (e.sign == 1) @tagName(e.row) ++ "+ " else if (e.sign == -1) @tagName(e.row) ++ "- " else std.fmt.comptimePrint("{s}*{d} ", .{ @tagName(e.row), e.sign });
        \\                    };
        \\                    break :blk s ++ if (contract.qLte(D)[k]) "lte" else "nolte";
        \\                };
        \\                const w_k: []const u8 = if (k < want.len) want[k] else "<none>";
        \\                std.debug.print("qsite[{d}] got={s} want={s} ok={d}\n", .{ k, got, w_k, @intFromBool(std.mem.eql(u8, got, w_k)) });
        \\            }
        \\        }
        \\    }
        \\
    );
}

/// Writes the §9.17.3 cold-start check, once after `setup`, where a host
/// calls `seed` before solving: exactly the `seeds` lanes are non-null, with
/// their values, and each is in `limit_writes`.
pub fn seedCheck(w: *Writer, seeds: []const Binding) WriteError!void {
    try w.writeAll(
        \\
        \\    // §9.17.3 the cold start a host writes into its limited image.
        \\    {
        \\        const got: [n_u]?f64 = if (comptime @hasDecl(D, "seed")) D.seed(Val, &model, &inst, sim_state) else @splat(null);
        \\
    );
    // `//! seed none` writes no lane, and a `var` nothing writes is an
    // AstGen error ("never mutated").
    try w.print("        {s} want: [n_u]?f64 = @splat(null);\n", .{if (seeds.len == 0) "const" else "var"});
    for (seeds) |b| {
        assert(b.name.len != 0);
        try w.print("        want[ix(\"{f}\")] = {f};\n", .{ std.zig.fmtString(b.name), fmtF64(b.value) });
    }
    try w.writeAll(
        \\        const writes: u64 = if (comptime @hasDecl(D, "limit_writes")) D.limit_writes else 0;
        \\        for (got, want, 0..) |g, w, i| {
        \\            if (g == null and w == null) continue;
        \\            const ok = g != null and w != null and near(g.?, w.?);
        \\            std.debug.print("seed[{s}] got={?d} want={?d} ok={d}\n", .{ @tagName(@as(D.U, @fromBackingInt(@intCast(i)))), g, w, @intFromBool(ok) });
        \\            if (g != null) std.debug.print("seed[{s}] in limit_writes ok={d}\n", .{
        \\                @tagName(@as(D.U, @fromBackingInt(@intCast(i)))), @intFromBool(i < 64 and (writes >> @intCast(i)) & 1 != 0),
        \\            });
        \\        }
        \\    }
        \\
    );
}

/// Writes the comptime §2.9.2 `decl_meta` checks: the row count, then each
/// row printed as `//! meta` writes it.
pub fn meta(w: *Writer, rows: []const []const u8) WriteError!void {
    try w.writeAll(
        \\
        \\    // §2.9.2/§3.2.1/§3.4.3/§3.6.3.1: the `desc` and `units` a host shows
        \\    // in help messages and operating-point reports. The model's own
        \\    // text cannot read an attribute back, so `decl_meta` is the only
        \\    // place the clauses are observable.
        \\    {
        \\        const want = [_][]const u8{
        \\
    );
    for (rows) |e| {
        assert(e.len != 0);
        try w.print("            \"{f}\",\n", .{std.zig.fmtString(e)});
    }
    try w.writeAll(
        \\        };
        \\        if (comptime @hasDecl(D, "decl_meta")) {
        \\            std.debug.print("meta count got={d} want={d} ok={d}\n", .{
        \\                D.decl_meta.len, want.len, @intFromBool(D.decl_meta.len == want.len),
        \\            });
        \\            inline for (D.decl_meta, 0..) |m, i| {
        \\                const got = comptime row: {
        \\                    const dsc: []const u8 = if (m.desc) |v| " desc=\"" ++ v ++ "\"" else "";
        \\                    const uni: []const u8 = if (m.units) |v| " units=\"" ++ v ++ "\"" else "";
        \\                    break :row @tagName(m.kind) ++ " " ++ m.name ++ dsc ++ uni;
        \\                };
        \\                const w_i: []const u8 = if (i < want.len) want[i] else "<none>";
        \\                std.debug.print("meta[{d}] got={s} want={s} ok={d}\n", .{
        \\                    i, got, w_i, @intFromBool(std.mem.eql(u8, got, w_i)),
        \\                });
        \\            }
        \\        } else {
        \\            // No table at all is the empty table, for the reason the
        \\            // `noise_gens` block gives.
        \\            std.debug.print("meta count got=0 want={d} ok={d}\n", .{
        \\                want.len, @intFromBool(want.len == 0),
        \\            });
        \\        }
        \\    }
        \\
    );
}

/// Writes the §3.6.1.2 checks of the tolerance the device publishes for each
/// named unknown (`u_abstol`); a name the device lacks prints `got=none`.
pub fn abstols(w: *Writer, rows: []const Binding) WriteError!void {
    for (rows) |b| {
        assert(b.name.len != 0);
        try w.print(
            \\    if (comptime std.meta.stringToEnum(D.U, "{0f}")) |u| {{
            \\        const g = u_abstol[@backingInt(u)];
            \\        std.debug.print("abstol[{0f}] got={{e}} want={{e}} ok={{d}}\n", .{{ g, @as(f64, {1f}), @intFromBool(near(g, {1f})) }});
            \\    }} else std.debug.print("abstol[{0f}] got=none want={{e}} ok=0\n", .{{@as(f64, {1f})}});
            \\
        , .{ std.zig.fmtString(b.name), fmtF64(b.value) });
    }
}

// ---- private ----

/// Writes the checks of the comptime §4.6.4 fields: the source label
/// (§4.6.4.1-.3) and the tabulated spectrum (§4.6.4.3/.4), one guarded
/// statement per row that states one.
fn labels(w: *Writer, rows: []const NoiseWant) WriteError!void {
    var any_points = false;
    var any_label = false;
    for (rows) |r| {
        any_points = any_points or r.points != null or r.psd != null;
        any_label = any_label or r.name != null or r.interp != null;
    }
    if (!any_points and !any_label) return;
    try w.writeAll("    if (comptime @hasDecl(D, \"noise_gens\")) {\n");
    if (any_points) try w.writeAll(parts.noise_close);
    for (rows, 0..) |r, k| {
        if (r.name == null and r.interp == null and r.points == null and r.psd == null) continue;
        try w.print("        if (comptime D.noise_gens.len > {d}) {{\n", .{k});
        if (r.name) |nm| try w.print(
            "            std.debug.print(\"noise[{d}].name got={{s}} want={{s}} ok={{d}}\\n\", .{{\n" ++
                "                D.noise_gens[{d}].name, \"{f}\",\n" ++
                "                @intFromBool(std.mem.eql(u8, D.noise_gens[{d}].name, \"{f}\")),\n" ++
                "            }});\n",
            .{ k, k, std.zig.fmtString(nm), k, std.zig.fmtString(nm) },
        );
        if (r.interp != null or r.points != null or r.psd != null) try spectrum(w, r, k);
        try w.writeAll("        }\n");
    }
    try w.writeAll("    }\n");
    assert(any_points or any_label);
}

/// Writes row `k`'s §4.6.4.3/.4 table checks: `interp`, `points` and `psd`.
/// Only a `.table` row has a spectrum; on another row they FAIL with a
/// reason instead of crashing on `g.table.?`.
fn spectrum(w: *Writer, r: NoiseWant, k: usize) WriteError!void {
    assert(r.interp != null or r.points != null or r.psd != null);
    try w.print(
        \\            if (D.noise_gens[{d}].table) |ti| {{
        \\                const tbl = contract.noiseTable(D, &model, ti);
        \\
    , .{k});
    if (r.interp) |ip| try w.print(
        "                std.debug.print(\"noise[{d}].interp got={{s}} want={{s}} ok={{d}}\\n\", .{{\n" ++
            "                    @tagName(tbl.interp), \"{t}\",\n" ++
            "                    @intFromBool(std.mem.eql(u8, @tagName(tbl.interp), \"{t}\")),\n" ++
            "                }});\n",
        .{ k, ip, ip },
    );
    if (r.points) |pts| {
        // §4.6.4.3 `tbl` is the table as a host reads it, `contract.noiseTable`:
        // the derived row's own sorted copy of the card's knots when a knot is
        // a parameter (`noise_tables` holds only the declared defaults).
        try w.writeAll(
            \\                const got_pts = tbl.points;
            \\
        );
        try w.writeAll("                const want_pts = [_][2]f64{");
        try pairList(w, pts);
        try w.print(
            \\ }};
            \\                var pts_ok = got_pts.len == want_pts.len;
            \\                if (pts_ok) for (got_pts, want_pts) |g, wp| {{
            \\                    if (!nclose(g[0], wp[0], {f}) or !nclose(g[1], wp[1], {f})) {{
            \\                        pts_ok = false;
            \\                        break;
            \\                    }}
            \\                }};
            \\                std.debug.print("noise[{d}].points got={{any}} want={{any}} ok={{d}}\n", .{{
            \\                    got_pts, want_pts, @intFromBool(pts_ok),
            \\                }});
            \\
        , .{ fmtF64(r.rtol), fmtF64(r.rtol), k });
    }
    if (r.psd) |ps| {
        // §4.6.4.3/.4 the density a host integrates, from the same table: the
        // clause's interpolation and end clamps.
        try w.writeAll("                const want_psd = [_][2]f64{");
        try pairList(w, ps);
        try w.print(
            \\ }};
            \\                var got_psd: [want_psd.len]f64 = undefined;
            \\                var psd_ok = true;
            \\                for (want_psd, &got_psd) |fw, *g| {{
            \\                    g.* = contract.noiseTableAt(tbl, fw[0]);
            \\                    if (!nclose(g.*, fw[1], {f})) psd_ok = false;
            \\                }}
            \\                std.debug.print("noise[{d}].psd got={{any}} want={{any}} ok={{d}}\n", .{{
            \\                    got_psd, want_psd, @intFromBool(psd_ok),
            \\                }});
            \\
        , .{ fmtF64(r.rtol), k });
    }
    try w.print(
        \\            }} else std.debug.print("noise[{d}].table got=none want=a table ok=0\n", .{{}});
        \\
    , .{k});
}

/// Writes `pts` as the inside of a `[_][2]f64` literal: ` .{ f, v }, ...`.
fn pairList(w: *Writer, pts: []const [2]f64) WriteError!void {
    assert(pts.len != 0); // `pairs` refuses an empty list.
    for (pts, 0..) |p, i| try w.print("{s}.{{ {f}, {f} }}", .{ if (i == 0) " " else ", ", fmtF64(p[0]), fmtF64(p[1]) });
}
