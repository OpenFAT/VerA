//! `plan/noise.zig`'s `Noise` -> the host's small-signal source tables:
//! §4.6.4 `noise_gens`, `noise_tables`, `noiseTablePoints`, `noisePsd` and the
//! `<core>__noise` slice it reads, and §4.6.3 `ac_gens`/`acStim`. Every number
//! is either a `Model` expression or a core field, so a host evaluates the
//! sources at its own operating point. A source VerA cannot state becomes a
//! `@compileError` value, not a wrong table.
//! LRM: §4.6.3, §4.6.4, §4.6.4.1, §4.6.4.2, §4.6.4.3, §4.6.4.4, §4.6.4.6, A.8.2.

const std = @import("std");
const assert = std.debug.assert;
const plan_noise = @import("plan/noise.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_host = @import("host_expr.zig");
const gen_dispatch = @import("dispatch.zig");
const gen_mask = @import("mask.zig");
const gen_file = @import("file.zig");
const gen_setup = @import("setup.zig");
const gen_unit = @import("unit.zig");
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const coreIdx = gen_dispatch.coreIdx;

/// Emits the §4.6.4 noise tables: `noise_gens[k]` (branch and kind),
/// `noisePsd(x, m, i)[k]` (the PSD from the model's own expression at any
/// state vector) and `noise_tables` (the knots of §4.6.4.3/.4 table
/// sources). The kind alone cannot give the PSD: `white_noise(2·q·|I|)` and
/// `white_noise(4·k·T/R)` are the same call with different arguments.
///
/// One entry per generator, not per contribution (a branch may carry
/// several). §4.6.4.6 correlation is the `source` column: the declaring
/// call's AST id, renumbered densely in first-seen order. A table row's
/// `PsdTerm` is all zero, so `white + flicker/f^ef + table` is the whole
/// spectrum for every kind. A generator that cannot be exported (a
/// ground-ground branch, E0520; non-constant table pairs, E0519) replaces
/// the whole `noise_gens` decl with a `@compileError` (`refuseNoise`).
pub fn emitNoiseTable(self: *Gen) Error!void {
    if (self.noise.fatal) |msg| {
        // A `@compileError` value, not a statement: a host that never touches
        // noise still builds, and one that reads `noise_gens` gets this
        // message instead of a table missing a generator.
        try self.w("/// §4.6.4 refused by codegen; see the diagnostic.\n", .{});
        try self.w("pub const noise_gens = @compileError(\"{s}\");\n\n", .{msg});
        return;
    }
    if (self.noise.rows.len == 0) return;
    // `plan/noise.zig`'s `plan` gives a table row its `tabs` index and no other row one.
    for (self.noise.rows) |nr| switch (nr.kind) {
        .table, .table_log => assert(nr.table.? < self.noise.tabs.len),
        .thermal, .flicker => assert(nr.table == null),
        .ac_stim => unreachable, // split into `ac_rows` by `plan/noise.zig`
    };
    if (self.noise.tabs.len != 0) {
        try self.w(
            \\/// §4.6.4.3/.4 the tabulated PSDs, ascending in frequency (the
            \\/// clause's own sort, done here so the host never repeats it).
            \\pub const noise_tables = [_]contract.NoiseTable{{
            \\
        , .{});
        for (self.noise.tabs, 0..) |pts, k| {
            const log = for (self.noise.rows) |nr| {
                if (nr.table == @as(u16, @intCast(k))) break nr.kind == .table_log;
            } else false;
            try self.w("    .{{ .interp = .{s}, .points = &.{{", .{if (log) "log" else "linear"});
            for (pts, 0..) |p, i| {
                // `planNoiseTable` sorted the knots and refused a repeat or
                // a non-positive frequency (E0519).
                assert(p[0] > 0);
                if (i != 0) assert(pts[i - 1][0] < p[0]);
                try self.w("{s}.{{ {s}, {s} }}", .{
                    if (i == 0) " " else ", ",
                    try gen_file.fmtF64(self, p[0]),
                    try gen_file.fmtF64(self, p[1]),
                });
            }
            try self.w(" }} }},\n", .{});
        }
        try self.w("}};\n\n", .{});
        try emitNoiseTablePoints(self);
    }
    try self.w("/// §4.6.4 noise sources declared by the model.\npub const noise_gens = [_]contract.NoiseGen(Self){{\n", .{});
    for (self.noise.rows) |nr| {
        try self.w("    .{{ .row = @intFromEnum(U.{s}), .col = @intFromEnum(U.{s}), .kind = .{s}, .source = {d}", .{
            self.names.u_names[nr.row], self.names.u_names[nr.col], contractNoiseKind(nr.kind), nr.source,
        });
        if (nr.table) |k| try self.w(", .table = {d}", .{k});
        if (nr.name.len != 0) try self.w(", .name = \"{f}\"", .{std.zig.fmtString(nr.name)});
        try self.w(" }},\n", .{});
    }
    try self.w("}};\n\n", .{});

    // §4.6.4.1/.2 the PSDs, positionally, from one core sweep at the
    // caller's state vector, value-only unless a PSD argument reads `ddx`. A generator whose statement did not execute
    // at this bias reads the zero `probeBody` seeds, its physical answer.
    try self.w(
        \\/// §4.6.4.1/.2 each generator's PSD at `x`: S(f) = white + flicker/f^ef.
        \\/// Position k belongs to `noise_gens[k]`. A §4.6.4.3/.4 `.table` row
        \\/// reads zero here — its spectrum is `noise_tables[k]` instead.
        \\pub fn noisePsd(comptime
    , .{});
    const at_s = self.out.items.len + 1;
    try self.w(" S: type, ", .{});
    const at_x = self.out.items.len;
    try self.w("x: [n_u]f64, ", .{});
    const at_model = self.out.items.len;
    try self.w("model: *const Model, ", .{});
    const at_inst = self.out.items.len;
    try self.w("inst: *const Instance, ", .{});
    const at_sim = self.out.items.len;
    try self.w("sim: contract.SimState) [noise_gens.len]contract.PsdTerm {{\n", .{});
    const full = self.core;
    defer self.core = full;
    if (self.noise_core.lo_vals.len != 0) {
        self.core = self.noise_core;
        // §4.5.14 a `ddx` in a PSD argument needs its lanes seeded, as in
        // `eval`; a value-only family still reads it as 0 (#32).
        const xs = if (self.noise_reads_ddx) "zProbe(S, &x)" else "zVals(S, &x)";
        try self.w("    const m = {s}(S, {s}, model, {s}, sim{s});\n", .{ self.core.name, xs, try gen_setup.probeInstance(self), self.heldArg(true) });
    } else {
        gen_unit.patchParam(self, at_s, "S".len);
        gen_unit.patchParam(self, at_x, "x".len);
        gen_unit.patchParam(self, at_model, "model".len);
        gen_unit.patchParam(self, at_inst, "inst".len);
        gen_unit.patchParam(self, at_sim, "sim".len);
    }
    try self.w("    return .{{\n", .{});
    for (self.noise.rows) |nr| {
        // §4.6.4.6's per-use factor rides beside the PSD rather than folded
        // in: a table row's spectrum is comptime data that cannot absorb a
        // bias-dependent factor, and two rows sharing a source need both
        // coefficients, since their signed product is the cross-spectrum.
        const plain = try psdRef(self, nr.coeff, true);
        // A series generator enters its branch row `V(a,b) − <value>`: the
        // row's sign rides in the coefficient (`plan/noise.zig` `neg`).
        const coeff = if (nr.neg) try self.arena.print("-({s})", .{plain}) else plain;
        switch (nr.kind) {
            // §4.6.4.3/.4 the table is the spectrum: anything here would be
            // added to it, so the parametric part of a table row is zero.
            .table, .table_log => try self.w("        .{{ .white = 0, .coeff = {s} }}, // noise_tables[{d}]\n", .{ coeff, nr.table.? }),
            .flicker => try self.w("        .{{ .white = 0, .flicker = {s}, .ef = {s}, .coeff = {s} }},\n", .{
                try psdRef(self, nr.pwr, false), try psdRef(self, nr.exp, true), coeff,
            }),
            .thermal => try self.w("        .{{ .white = {s}, .coeff = {s} }},\n", .{ try psdRef(self, nr.pwr, false), coeff }),
            // Split off by `plan/noise.zig`; a stimulus never reaches this table.
            .ac_stim => unreachable,
        }
    }
    try self.w("    }};\n}}\n\n", .{});
}

/// Emits `<core>__noise`, the core's slice computing only the PSD arguments
/// `noisePsd` reads off it. Called from `emitUnits`, so its range tiles with
/// the other unit declarations.
pub fn emitNoiseCore(self: *Gen) Error!void {
    if (self.noise.fatal != null or self.noise.rows.len == 0) return;
    const keep = try self.arena.alloc(bool, self.core.lo_vals.len);
    @memset(keep, false);
    var any = false;
    for (self.noise.rows) |nr| for ([_]Mir.Value{ nr.pwr, nr.exp, nr.coeff }) |v| {
        const k = coreIdx(self, v) orelse continue;
        keep[k] = true;
        any = true;
    };
    if (!any) return;
    // `ddx` marks `jac.ddx_reads` as its text is emitted, so a mask cleared
    // around the slice says whether the PSD arguments read a lane (#32).
    const ddx_before = self.jac.ddx_reads;
    self.jac.ddx_reads = try gen_mask.zero(self.arena, self.mw);
    self.noise_core = try gen_unit.sliceCore(self, "noise", keep,
        \\/// §4.6.4 the PSD arguments the core computes, and only what they read:
        \\/// `noisePsd` evaluates them at the operating point `x`.
        \\
    );
    self.noise_reads_ddx = !std.mem.allEqual(u64, self.jac.ddx_reads, 0);
    gen_mask.orIn(self.jac.ddx_reads, ddx_before);
}

/// Emits `noiseTablePoints`: the knots of every §4.6.4.3 table as the model
/// card sets them, since "the vector can either be specified as an array
/// parameter" and `noise_tables` holds only the declared defaults. One flat
/// array in `noise_tables` order (a per-table return type would be generic,
/// which `contract.expectFn` cannot check); table k starts at the sum of the
/// earlier `noise_tables[i].points.len`. Emitted only when some knot is a
/// parameter. Re-sorted at run time, because §4.6.4.3's "the simulator shall
/// internally sort the pairs into ascending frequency" must hold for any card.
/// `derive` stores its result in the row (`Model.noise_table_points__`,
/// `contract.noiseTable`).
fn emitNoiseTablePoints(self: *Gen) Error!void {
    if (!hasCardKnots(self)) return;
    const total = cardKnotCount(self);
    assert(total > 0);
    assert(self.noise.tab_vals.len <= self.noise.tabs.len);
    try self.w(
        \\/// §4.6.4.3 every tabulated knot AT THIS CARD, in `noise_tables`
        \\/// order and ascending in frequency within each table. Table k is
        \\/// the segment starting at the sum of `noise_tables[i].points.len`
        \\/// for i < k; `noise_tables` itself carries the array parameter's
        \\/// DECLARED DEFAULTS, which is all a comptime table can hold.
        \\pub fn noiseTablePoints(
    , .{});
    const at_model = self.out.items.len;
    try self.w("model: *const Model) [{d}][2]f64 {{\n", .{total});
    const saved_model = self.uses.model;
    self.uses.model = false;
    var body: std.ArrayList(u8) = .empty;
    for (self.noise.tabs, 0..) |pts, k| {
        const mvs = if (k < self.noise.tab_vals.len) self.noise.tab_vals[k] else &.{};
        // A parametric table's MIR knots are positional against its points.
        if (mvs.len != 0) assert(mvs.len == pts.len);
        for (pts, 0..) |p, i| {
            const pair: [2][]const u8 = if (i < mvs.len) .{
                (try gen_host.f64Const(self, mvs[i][0], 0, false)) orelse try gen_file.fmtF64(self, p[0]),
                (try gen_host.f64Const(self, mvs[i][1], 0, false)) orelse try gen_file.fmtF64(self, p[1]),
            } else .{ try gen_file.fmtF64(self, p[0]), try gen_file.fmtF64(self, p[1]) };
            try body.print(self.arena, "        .{{ {s}, {s} }},\n", .{ pair[0], pair[1] });
        }
    }
    const reads_model = self.uses.model;
    self.uses.model = saved_model or reads_model;
    if (!reads_model) gen_unit.patchParam(self, at_model, "model".len);
    try self.w("    var pts: [{d}][2]f64 = .{{\n", .{total});
    try self.w("{s}", .{body.items});
    try self.w("    }};\n", .{});
    var at: usize = 0;
    for (self.noise.tabs) |pts| {
        try self.w("    contract.sortNoiseTable(pts[{d}..{d}]);\n", .{ at, at + pts.len });
        at += pts.len;
    }
    try self.w("    return pts;\n}}\n\n", .{});
}

/// Returns whether the device emits `noiseTablePoints`: a §4.6.4.3/.4 table
/// some knot of which is a parameter, so the `Model` row also carries
/// `noise_table_points__` and `derive` fills it. False when the noise tables
/// were refused, since then no `noise_tables` is emitted either.
pub fn hasCardKnots(self: *const Gen) bool {
    if (self.noise.fatal != null or self.noise.rows.len == 0) return false;
    for (self.noise.tab_vals) |mvs| if (mvs.len != 0) return true;
    return false;
}

/// The knots of every table, the length of `noiseTablePoints`' result.
pub fn cardKnotCount(self: *const Gen) usize {
    var total: usize = 0;
    for (self.noise.tabs) |pts| total += pts.len;
    return total;
}

/// Emits the §4.6.3 AC stimulus tables: `ac_gens[k]` (branch and analysis
/// name, model text) and `acStim(x, m, i)[k]` (`(mag, phase)`, which the
/// card or the solve may set). The residual is real and carries only
/// `mag·cos(phase)`; this table is the whole phasor, and a host solving a
/// complex system reads it instead of the residual term (`contract.AcGen`).
/// It takes the state vector because A.8.2 makes both arguments
/// `analog_expression`; a stimulus that folds renders over `Model` alone.
pub fn emitAcTable(self: *Gen) Error!void {
    if (self.noise.ac_rows.len == 0) return;

    // Rendered before anything is written, so the `x`/`model`/`inst`
    // parameters can be patched to `_` when nothing reached them, as
    // `emitUnit` does. The flags are Gen-wide, so they are saved.
    const saved_model = self.uses.model;
    const saved_inst = self.uses.inst;
    self.uses.model = false;
    self.uses.inst = false;
    const vals = try self.arena.alloc([2][]const u8, self.noise.ac_rows.len);
    var all_stated = true;
    var uses_core = false;
    for (self.noise.ac_rows, vals) |nr, *v| {
        assert(nr.kind == .ac_stim);
        // §4.6.4.6's per-use coefficient, folded into the magnitude: a real
        // factor scales a phasor exactly (a negative one rides as a negative
        // magnitude), and stimuli have no cross-spectrum or comptime table
        // to keep it out of.
        const mag = try acRef(self, nr.pwr, &uses_core);
        const phase = try acRef(self, nr.exp, &uses_core);
        const coeff = try acRef(self, nr.coeff, &uses_core);
        if (mag == null or phase == null or coeff == null) {
            all_stated = false;
            break;
        }
        const scaled = if (nr.coeff == .f_one) mag.? else try self.arena.print("({s}) * ({s})", .{ mag.?, coeff.? });
        // A series stimulus enters its branch row `V(a,b) − <value>`: the
        // row's sign rides as a negative magnitude (`plan/noise.zig` `neg`).
        v.* = .{ if (nr.neg) try self.arena.print("-({s})", .{scaled}) else scaled, phase.? };
    }
    const reads_model = self.uses.model or uses_core;
    const reads_inst = self.uses.inst or uses_core;
    self.uses.model = saved_model or reads_model;
    self.uses.inst = saved_inst or reads_inst;
    if (!all_stated) return refuseAc(self);

    try self.w("/// §4.6.3 AC stimulus sources declared by the model.\npub const ac_gens = [_]contract.AcGen(Self){{\n", .{});
    for (self.noise.ac_rows) |nr| {
        try self.w("    .{{ .row = @intFromEnum(U.{s}), .col = @intFromEnum(U.{s}), .name = \"{f}\" }},\n", .{
            self.names.u_names[nr.row], self.names.u_names[nr.col], std.zig.fmtString(nr.name),
        });
    }
    try self.w("}};\n\n", .{});

    try self.w(
        \\/// §4.6.3 each stimulus' phasor at `x`: mag·e^(j·phase), phase in
        \\/// radians. Position k belongs to `ac_gens[k]`.
        \\pub fn acStim(comptime
    , .{});
    const at_s = self.out.items.len + 1;
    try self.w(" S: type, ", .{});
    const at_x = self.out.items.len;
    try self.w("x: [n_u]f64, ", .{});
    const at_model = self.out.items.len;
    try self.w("model: *const Model, ", .{});
    const at_inst = self.out.items.len;
    try self.w("inst: *const Instance, ", .{});
    const at_sim = self.out.items.len;
    try self.w("sim: contract.SimState) [ac_gens.len]contract.AcPhasor {{\n", .{});
    if (!uses_core) {
        gen_unit.patchParam(self, at_s, "S".len);
        gen_unit.patchParam(self, at_x, "x".len);
        gen_unit.patchParam(self, at_sim, "sim".len);
    }
    if (!reads_model) gen_unit.patchParam(self, at_model, "model".len);
    if (!reads_inst) gen_unit.patchParam(self, at_inst, "inst".len);
    if (uses_core) {
        try self.w("    const m = core(S, zVals(S, &x), model, {s}, sim{s});\n", .{ try gen_setup.probeInstance(self), self.heldArg(true) });
    }
    try self.w("    return .{{\n", .{});
    for (vals) |v| try self.w("        .{{ .mag = {s}, .phase = {s} }},\n", .{ v[0], v[1] });
    try self.w("    }};\n}}\n\n", .{});
}

/// Returns one §4.6.3 magnitude, phase or §4.6.4.6 coefficient in `acStim`'s
/// frame: `f64Const` over `Model` when it folds, else the core field
/// `buildJobs` queued (setting `uses_core`). Null means neither, a planning
/// defect that `refuseAc` reports instead of exporting a wrong number.
fn acRef(self: *Gen, v: Mir.Value, uses_core: *bool) Error!?[]const u8 {
    if (try gen_host.f64Const(self, v, 0, false)) |s| return s;
    const k = self.core.lo_idx[@backingInt(v)];
    if (k == none_u32) return null;
    uses_core.* = true;
    return try self.arena.print("m.f{d}.val()", .{k});
}

/// Emits `ac_gens` as a `@compileError` value for a §4.6.3 stimulus VerA
/// cannot state, as `refuseNoise` does for `noise_gens`. No diagnostic of its
/// own: `emitCall` already reported E0515 on the same argument.
fn refuseAc(self: *Gen) Error!void {
    try self.w("/// §4.6.3 refused by codegen; see the diagnostic.\n", .{});
    try self.w("pub const ac_gens = @compileError(\"LRM 4.6.3: an ac_stim magnitude or " ++
        "phase must be a constant or parameter expression\");\n\n", .{});
}

/// Returns `Lowered.NoiseKind` as a `contract.NoiseGen.kind` name. §4.6.4.3
/// and §4.6.4.4 are one exported kind: the host reads `noise_tables` for
/// either, and the table's `interp` field says which interpolation.
fn contractNoiseKind(k: Lowered.NoiseKind) []const u8 {
    return switch (k) {
        .thermal => "thermal",
        .flicker => "flicker",
        .table, .table_log => "table",
        // §4.6.3 has no `NoiseGen.kind` because it has no `noise_gens` row.
        .ac_stim => unreachable,
    };
}

/// Returns one PSD argument as an `f64` expression in `noisePsd`'s body.
/// `is_exp` allows the inline-constant shortcut, which only the exponent may
/// take (see `buildJobs`).
fn psdRef(self: *Gen, v: Mir.Value, is_exp: bool) Error![]const u8 {
    if (v == .f_zero) return "0";
    if (is_exp) if (plan_noise.psdConst(self.mir, v)) |c| return try self.arena.print("{d}", .{c});
    const k = self.core.lo_idx[@backingInt(v)];
    // A live-out the planner dropped cannot happen (`buildJobs` queued it),
    // but a zero is the one answer that cannot invent noise.
    if (k == none_u32) return "0";
    return try self.arena.print("m.f{d}.val()", .{k});
}
