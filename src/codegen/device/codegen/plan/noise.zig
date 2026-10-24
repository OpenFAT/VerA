//! §4.6.3/§4.6.4 small-signal sources: lowered contributions -> `Noise`, the
//! flattened rows `noise_gens`, `noisePsd`, `ac_gens` and `acStim` are
//! emitted from, with §4.6.4.3/.4 tables folded and sorted. Refusals
//! (E0519/E0520) are recorded for `Gen.prepare` to report. Clauses:
//! §1.3.1.1, §4.6.3, §4.6.4, §4.6.4.1, §4.6.4.3, §4.6.4.4, §4.6.4.6.

const std = @import("std");
const Mir = @import("ir").Mir;
const Lower = @import("ir").Lowered;
const diag = @import("diag");
const Input = @import("prove").Input;
const plan_topo = @import("topology.zig");

/// Every fallible call here fails only on allocation.
pub const Error = std.mem.Allocator.Error;

/// The small-signal plan: noise rows, folded tables, AC stimulus rows and
/// the refusals found on the way.
pub const Noise = struct {
    /// §4.6.4 `noise_gens` and `noisePsd`, one row each.
    rows: []NoiseRow = &.{},
    /// §4.6.4.3/.4 `noise_tables`, one entry per tabulated generator, folded
    /// and sorted. Position k is `rows[j].table == k`.
    tabs: []const []const [2]f64 = &.{},
    /// The same knots as `tabs`, in the same order, as MIR values, only for a
    /// table an A.8.2 `parameter_identifier` made model-dependent: `tabs`
    /// holds its declared defaults, and only this can state the card's. An
    /// empty slice is a table of literals, and so is every position past the
    /// end (the slice stops at the last parametric table). See
    /// `emitNoiseTablePoints`.
    tab_vals: []const []const [2]Mir.Value = &.{},
    /// §4.6.3 `ac_gens` and `acStim`, one row each. Same walk as `rows`,
    /// separated by `kind`: a stimulus is not a generator and must never
    /// reach `noise_gens`.
    ac_rows: []NoiseRow = &.{},
    /// The §4.6.4 export VerA will not write, as the message the generated
    /// `@compileError` carries. The first one wins; the diagnostics carry the
    /// rest.
    fatal: ?[]const u8 = null,
    /// Every refusal, in the order found, for the caller to report.
    refusals: std.ArrayList(Refusal) = .empty,

    /// One recorded E0519/E0520, for the caller to report at `tok`.
    pub const Refusal = struct { code: diag.Code, tok: u32, msg: []const u8 };
};

/// One row of `noise_gens` and of the `noisePsd` result. The two tables are
/// positional in each other (`PsdTerm` k belongs to `noise_gens[k]`), so
/// they are built once here.
pub const NoiseRow = struct {
    /// The generator's `nodes` rows: `hi` and `lo`, or `row == col` for a
    /// generator to §1.3.1.1 ground, or `row == col` on the branch current
    /// of a potential contribution (`neg`).
    row: u32,
    col: u32,
    /// §4.6.4.1 a generator in a potential contribution is a voltage in
    /// series with its branch, so it enters the branch-current row, which
    /// `dispatch.zig` writes as `V(hi,lo) − <value>`: the row's sign goes
    /// into the emitted coefficient (or magnitude).
    neg: bool = false,
    kind: Lower.NoiseKind,
    /// §4.6.4.6 dense generator id: rows sharing it are one generator. At
    /// most the row count, which a `u32` index everywhere else bounds.
    source: u32,
    /// §4.6.4.1/.2 the PSD itself: `S(f) = pwr` for white, `pwr/f^exp` for
    /// flicker. rv-resolved, so `.f_zero` means "no generator at this bias".
    /// Both `.f_zero` on a §4.6.4.3/.4 row, whose PSD is `table` instead.
    pwr: Mir.Value,
    exp: Mir.Value,
    /// §4.6.4.3/.4 index into `Noise.tabs`, null on a parametric row.
    table: ?u16 = null,
    /// §4.6.4.1/.2/.3 the source's label, empty when unnamed. See
    /// `Lower.NoiseSrc.name` for why it never merges rows.
    name: []const u8 = "",
    /// §4.6.4.6 the factor this branch applies to the generator, rv-resolved
    /// like `pwr`. `.f_zero` means the source never reached a contributed
    /// value, which cannot happen through `plan` and is read as 1.
    coeff: Mir.Value,
};

/// Flattens every contribution's generator set into `Noise.rows`, in the
/// order `noise_gens` declares them; slices are owned by `self.arena`.
/// §4.6.4.6's shared-generator identity (`NoiseSrc.id`) is renamed densely in
/// first-seen order. §4.6.3's `ac_stim` arrives on the same set and leaves in
/// `ac_rows`: it is a stimulus, not a generator. Refusals are recorded, not
/// reported.
pub fn plan(self: Input, branch_u: []const u32) Error!Noise {
    var out: Noise = .{};
    var rows: std.ArrayList(NoiseRow) = .empty;
    var ac: std.ArrayList(NoiseRow) = .empty;
    var ids: std.ArrayList(u32) = .empty;
    // §4.6.4.6 the ids of table calls already refused (E0519).
    var refused: std.ArrayList(u32) = .empty;
    var tabs: std.ArrayList([]const [2]f64) = .empty;
    var tab_vals: std.ArrayList([]const [2]Mir.Value) = .empty;
    for (self.lowered.contributions.items, 0..) |c, ci| {
        if (c.noise_srcs.len == 0) continue;
        // §1.3.1.1 ground is not an unknown: a to-ground generator is
        // spelled row == col, and one on ground-ground has neither. The
        // residual may drop such a contribution silently (KCL at the
        // reference node is not an equation), but a vanishing generator is a
        // PSD the host will never ask for, so it is reported (E0520).
        if (c.hi == Lower.ground and c.lo == Lower.ground) {
            try refuseNoise(self, &out, .E0520, c.noise_srcs[0].tok, "this small-signal source is on a " ++
                "ground-ground branch, which has no row or column to export it in", .{});
            continue;
        }
        // A current generator (a flow contribution) is between `hi` and
        // `lo`, KCL rows. §4.6.4.1 a voltage generator (a potential
        // contribution) is in series with the branch: it enters the branch
        // current's own row, `branch_u[i]` from `plan/names.zig`, as
        // `row == col` there, with `NoiseRow.neg` carrying the row's sign.
        // Not on a §5.6.5 switch branch: whether its current unknown exists
        // is decided per instance at run time, so the generator stays on
        // the nodes, where a host folds it into KCL either way.
        const series = c.kind == .direct and c.access == .potential and plan_topo.switchFlowOf(self, ci) == null;
        const row = if (series) branch_u[ci] else if (c.hi != Lower.ground) c.hi else c.lo;
        const col = if (series) row else if (c.lo != Lower.ground) c.lo else row;
        for (c.noise_srcs) |s| {
            // §4.6.3 a stimulus has no PSD, no table and no §4.6.4.6
            // identity: one call is one source, and `addNoiseSrc` already
            // made two uses of one call one row. `source` is carried only so
            // the struct is shared; nothing reads it.
            if (s.kind == .ac_stim) {
                try ac.append(self.arena, .{
                    .row = row,
                    .col = col,
                    .neg = series,
                    .kind = s.kind,
                    .source = 0,
                    .pwr = self.an.rv(s.pwr), // mag
                    .exp = self.an.rv(s.exp), // phase, radians
                    .name = s.name, // analysis_name
                    .coeff = if (s.coeff == .f_zero) .f_one else self.an.rv(s.coeff),
                });
                continue;
            }
            const seen = std.mem.findScalar(u32, ids.items, s.id);
            // §4.6.4.3/.4 the table, before the row: a generator VerA
            // cannot state gets no row, and the device is refused either
            // way. §4.6.4.6's shared generator shares its table too: one
            // call is one generator, so folding it twice would export the
            // same points under two indices.
            const table: ?u16 = switch (s.kind) {
                .thermal, .flicker, .ac_stim => null,
                .table, .table_log => rows_table: {
                    if (seen) |i| {
                        for (rows.items) |r| {
                            if (r.source == i and r.table != null) break :rows_table r.table;
                        }
                    }
                    // The same holds for a refusal: a call already refused
                    // through another branch is not refused a second time.
                    if (std.mem.findScalar(u32, refused.items, s.id) != null) continue;
                    break :rows_table (try planNoiseTable(self, &out, &tabs, &tab_vals, s)) orelse {
                        try refused.append(self.arena, s.id);
                        continue;
                    };
                },
            };
            const sid = seen orelse blk: {
                try ids.append(self.arena, s.id);
                break :blk ids.items.len - 1;
            };
            try rows.append(self.arena, .{
                .row = row,
                .col = col,
                .neg = series,
                .kind = s.kind,
                .source = @intCast(sid),
                .pwr = self.an.rv(s.pwr),
                .exp = self.an.rv(s.exp),
                .table = table,
                .name = s.name,
                .coeff = if (s.coeff == .f_zero) .f_one else self.an.rv(s.coeff),
            });
        }
    }
    out.rows = rows.items;
    out.tabs = tabs.items;
    out.tab_vals = tab_vals.items;
    out.ac_rows = ac.items;
    return out;
}

/// §4.6.4.3/.4 folds one `noise_table`/`noise_table_log` argument into a
/// sorted `(frequency, power)` table appended to `tabs`, and returns its
/// index, or null after recording an E0519 refusal.
///
/// All four of A.8.2's `noise_table_input_arg` spellings land here. Three are
/// literals by now: the assignment pattern, a file name ("shall be constant",
/// so `Lower.readNoiseTableFile` already flattened it) and a `[msb:lsb]`
/// slice of a parameter. The fourth, an array parameter, is a table the model
/// card owns: `tabs` gets the declared defaults (all a comptime `noise_tables`
/// can hold) and `tab_vals` gets the knots as MIR values, which
/// `emitNoiseTablePoints` renders over `Model` so a card override moves them.
/// Folding the default alone would silently ignore the override (E0515's
/// trap).
///
/// §4.6.4.3 lets the simulator sort ("shall internally sort the pairs into
/// ascending frequency if required"); sorting here gives the host an
/// invariant. Uniqueness ("Each frequency value must be unique") cannot be
/// repaired by sorting, so a repeat is an error. A card can defeat both at run
/// time: the generated accessor re-sorts, and uniqueness becomes the host's
/// precondition (`contract.NoiseTable`).
fn planNoiseTable(
    self: Input,
    out: *Noise,
    tabs: *std.ArrayList([]const [2]f64),
    tab_vals: *std.ArrayList([]const [2]Mir.Value),
    s: Lower.NoiseSrc,
) Error!?u16 {
    const vals = s.table;
    if (vals.len == 0) {
        try refuseNoise(self, out, .E0519, s.tok, "the argument is not a vector of " ++
            "(frequency, power) pairs", .{});
        return null;
    }
    if (vals.len % 2 != 0) {
        try refuseNoise(self, out, .E0519, s.tok, "the table has {d} values, which is not " ++
            "a whole number of (frequency, power) pairs", .{vals.len});
        return null;
    }
    // One array of both halves, so the sort permutes the values and the
    // defaults together: `noise_tables[k]` and `noiseTablePoints`'s k-th pair
    // must be the same knot.
    const Knot = struct { f: f64, p: f64, fv: Mir.Value, pv: Mir.Value };
    const knots = try self.arena.alloc(Knot, vals.len / 2);
    var parametric = false;
    for (knots, 0..) |*k, i| {
        const fv = vals[2 * i];
        const pv = vals[2 * i + 1];
        // `resolve_params = false` first, so "is this knot a literal?" is
        // answered before "what is it by default?". A table with no
        // parameter in it must not gain an accessor, because that would
        // oblige every host of the device to read one.
        const lit = self.an.foldConst(fv, false) != null and
            self.an.foldConst(pv, false) != null;
        const f = self.an.foldConst(fv, true);
        const pwr = self.an.foldConst(pv, true);
        if (f == null or pwr == null) {
            try refuseNoise(self, out, .E0519, s.tok, "the table has no value at compile " ++
                "time: a knot is computed during the solve, and 4.6.4.3's input is " ++
                "a vector, a file or a parameter", .{});
            return null;
        }
        if (!lit) parametric = true;
        k.* = .{ .f = f.?, .p = pwr.?, .fv = fv, .pv = pv };
    }
    std.mem.sort(Knot, knots, {}, struct {
        fn lt(_: void, x: Knot, y: Knot) bool {
            return x.f < y.f;
        }
    }.lt);
    const pts = try self.arena.alloc([2]f64, knots.len);
    for (knots, pts) |k, *p| p.* = .{ k.f, k.p };
    for (pts, 0..) |p, i| {
        if (!(p[0] > 0) or !std.math.isFinite(p[0])) {
            try refuseNoise(self, out, .E0519, s.tok, "frequency {d} is not a positive " ++
                "number of hertz", .{p[0]});
            return null;
        }
        if (!(p[1] >= 0) or !std.math.isFinite(p[1])) {
            try refuseNoise(self, out, .E0519, s.tok, "power {d} is not a non-negative " ++
                "spectral density", .{p[1]});
            return null;
        }
        // §4.6.4.4 interpolates log(power), and log(0) is not a point on
        // the line the clause's own formula draws.
        if (s.kind == .table_log and p[1] == 0) {
            try refuseNoise(self, out, .E0519, s.tok, "noise_table_log interpolates " ++
                "log(power), so a zero power at {d} Hz has no logarithm", .{p[0]});
            return null;
        }
        if (i != 0 and pts[i - 1][0] == p[0]) {
            try refuseNoise(self, out, .E0519, s.tok, "frequency {d} Hz appears twice, and " ++
                "LRM 4.6.4.3 requires each frequency value to be unique", .{p[0]});
            return null;
        }
    }
    try tabs.append(self.arena, pts);
    if (parametric) {
        const mvs = try self.arena.alloc([2]Mir.Value, knots.len);
        for (knots, mvs) |k, *m| m.* = .{ k.fv, k.pv };
        // Positional against `tabs`, so a constant table ahead of this one
        // still occupies its index.
        while (tab_vals.items.len + 1 < tabs.items.len) try tab_vals.append(self.arena, &.{});
        try tab_vals.append(self.arena, mvs);
    }
    return @intCast(tabs.items.len - 1);
}

/// Records one §4.6.4 export VerA refuses, for `Gen.prepare` to report the
/// way E0515 reports a control argument it cannot resolve: a source-level
/// diagnostic plus a generated `@compileError`, so a caller with no
/// diagnostic bag still cannot build a device whose noise table quietly lost
/// a generator. The first refusal also sets `fatal`.
fn refuseNoise(
    self: Input,
    out: *Noise,
    code: diag.Code,
    tok: u32,
    comptime fmt: []const u8,
    args: anytype,
) Error!void {
    const msg = try self.arena.print(fmt, args);
    try out.refusals.append(self.arena, .{ .code = code, .tok = tok, .msg = msg });
    if (out.fatal == null)
        out.fatal = try self.arena.print("LRM 4.6.4: {s}", .{msg});
}

/// Returns `v` as a compile-time f64, or null when only the core can answer.
pub fn psdConst(mir: *const Mir, v: Mir.Value) ?f64 {
    return switch (mir.valueDef(v)) {
        .float_const => |x| x,
        .int_const => |x| @floatFromInt(x),
        .undef, .str_const, .param_ref, .block_param, .inst_result => null,
    };
}

const Fixture = @import("prove").Fixture;

test "a noise table is sorted, and a repeated frequency is refused" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{ "a", "b" });
    defer f.deinit();
    const a = f.alloc();
    // noise_table({1e3, 2, 10, 4}) on I(a,b): stored ascending.
    const good = [_]Mir.Value{
        try f.mir.addFloatConst(a, 1e3), try f.mir.addFloatConst(a, 2),
        try f.mir.addFloatConst(a, 10),  try f.mir.addFloatConst(a, 4),
    };
    // noise_table({5, 1, 5, 2}) on I(b): 5 Hz twice.
    const dup = [_]Mir.Value{
        try f.mir.addFloatConst(a, 5), try f.mir.addFloatConst(a, 1),
        try f.mir.addFloatConst(a, 5), try f.mir.addFloatConst(a, 2),
    };
    const srcs0 = [_]Lower.NoiseSrc{.{ .kind = .table, .table = &good, .id = 1 }};
    const srcs1 = [_]Lower.NoiseSrc{.{ .kind = .table, .table = &dup, .id = 2 }};
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 0, .lo = 1, .noise_srcs = &srcs0 });
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 1, .lo = Lower.ground, .noise_srcs = &srcs1 });
    const an = try f.analysis();

    const n = try plan(.{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered }, &.{});
    try std.testing.expectEqual(@as(usize, 1), n.rows.len);
    try std.testing.expectEqual(@as(?u16, 0), n.rows[0].table);
    try std.testing.expectEqualSlices([2]f64, &.{ .{ 10, 4 }, .{ 1e3, 2 } }, n.tabs[0]);
    try std.testing.expectEqual(@as(usize, 1), n.refusals.items.len);
    try std.testing.expectEqual(diag.Code.E0519, n.refusals.items[0].code);
    try std.testing.expect(std.mem.startsWith(u8, n.fatal.?, "LRM 4.6.4: frequency 5 Hz appears twice"));
}

test "rows: to-ground is row == col, ground-ground is E0520, a stimulus goes to ac_rows, ids rename densely" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{ "a", "b" });
    defer f.deinit();
    const a = f.alloc();
    const pwr = try f.mir.addFloatConst(a, 1.6e-21);
    const mag = try f.mir.addFloatConst(a, 0.5);
    // §4.6.4.6 ids are AST expression ids: sparse, renamed 0, 1 in first-seen order.
    const th = [_]Lower.NoiseSrc{.{ .kind = .thermal, .id = 900, .pwr = pwr }};
    const fl = [_]Lower.NoiseSrc{
        .{ .kind = .flicker, .id = 40, .pwr = pwr, .coeff = .f_two },
        .{ .kind = .ac_stim, .id = 41, .pwr = mag, .exp = .f_zero, .name = "ac" },
    };
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 1, .lo = Lower.ground, .noise_srcs = &th });
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = Lower.ground, .lo = 0, .noise_srcs = &fl });
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = Lower.ground, .lo = Lower.ground, .noise_srcs = &th });
    const an = try f.analysis();

    const n = try plan(.{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered }, &.{});
    try std.testing.expectEqual(@as(usize, 2), n.rows.len);
    // I(b) to ground: row = col = b. I(<gnd>, a): row = col = a.
    try std.testing.expectEqual(@as(u32, 1), n.rows[0].row);
    try std.testing.expectEqual(@as(u32, 1), n.rows[0].col);
    try std.testing.expectEqual(@as(u32, 0), n.rows[0].source);
    // An unclaimed coefficient reads as 1; a claimed one is kept.
    try std.testing.expectEqual(Mir.Value.f_one, n.rows[0].coeff);
    try std.testing.expectEqual(@as(u32, 0), n.rows[1].row);
    try std.testing.expectEqual(@as(u32, 0), n.rows[1].col);
    try std.testing.expectEqual(@as(u32, 1), n.rows[1].source);
    try std.testing.expectEqual(Mir.Value.f_two, n.rows[1].coeff);
    // §4.6.3 a stimulus is not a generator.
    try std.testing.expectEqual(@as(usize, 1), n.ac_rows.len);
    try std.testing.expectEqual(Lower.NoiseKind.ac_stim, n.ac_rows[0].kind);
    try std.testing.expectEqual(mag, n.ac_rows[0].pwr);
    try std.testing.expectEqualStrings("ac", n.ac_rows[0].name);
    // The ground-ground generator is refused, once, and is the fatal one.
    try std.testing.expectEqual(@as(usize, 1), n.refusals.items.len);
    try std.testing.expectEqual(diag.Code.E0520, n.refusals.items[0].code);
    try std.testing.expect(std.mem.startsWith(u8, n.fatal.?, "LRM 4.6.4: this small-signal source is on a ground-ground branch"));
}

test "§4.6.4.3 table checks: no vector, an odd count, a non-positive frequency, a negative power, log of zero" {
    const Case = struct { kind: Lower.NoiseKind, knots: []const f64, msg: []const u8 };
    const cases = [_]Case{
        .{ .kind = .table, .knots = &.{}, .msg = "not a vector of (frequency, power) pairs" },
        .{ .kind = .table, .knots = &.{ 1, 2, 3 }, .msg = "has 3 values" },
        .{ .kind = .table, .knots = &.{ 0, 2 }, .msg = "frequency 0 is not a positive number of hertz" },
        .{ .kind = .table, .knots = &.{ 10, -1 }, .msg = "power -1 is not a non-negative spectral density" },
        .{ .kind = .table_log, .knots = &.{ 10, 0 }, .msg = "has no logarithm" },
    };
    for (cases) |cs| {
        var f: Fixture = .{ .arena = .init(std.testing.allocator) };
        try f.init(&.{"a"});
        defer f.deinit();
        const a = f.alloc();
        const vals = try a.alloc(Mir.Value, cs.knots.len);
        for (cs.knots, vals) |k, *v| v.* = try f.mir.addFloatConst(a, k);
        const srcs = try a.dupe(Lower.NoiseSrc, &.{.{ .kind = cs.kind, .table = vals, .id = 1 }});
        try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 0, .lo = Lower.ground, .noise_srcs = srcs });
        const an = try f.analysis();
        const n = try plan(.{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered }, &.{});
        try std.testing.expectEqual(@as(usize, 0), n.rows.len);
        try std.testing.expectEqual(@as(usize, 1), n.refusals.items.len);
        try std.testing.expectEqual(diag.Code.E0519, n.refusals.items[0].code);
        try std.testing.expect(std.mem.find(u8, n.refusals.items[0].msg, cs.msg) != null);
    }
    // A zero power is legal in a linear table: §4.6.4.3 asks only for a power.
    {
        var f: Fixture = .{ .arena = .init(std.testing.allocator) };
        try f.init(&.{"a"});
        defer f.deinit();
        const a = f.alloc();
        const vals = [_]Mir.Value{ try f.mir.addFloatConst(a, 10), .f_zero };
        const srcs = [_]Lower.NoiseSrc{.{ .kind = .table, .table = &vals, .id = 1 }};
        try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 0, .lo = Lower.ground, .noise_srcs = &srcs });
        const an = try f.analysis();
        const n = try plan(.{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered }, &.{});
        try std.testing.expectEqual(@as(usize, 0), n.refusals.items.len);
        try std.testing.expectEqualSlices([2]f64, &.{.{ 10, 0 }}, n.tabs[0]);
    }
}

test "a parameter knot keeps its MIR values beside the defaults; a literal table before it pads tab_vals" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{ "a", "b" });
    defer f.deinit();
    const a = f.alloc();
    try f.lowered.params.append(a, .{ .name = "fc", .ty = .real, .default = try f.mir.addFloatConst(a, 5.0) });
    const fc = try f.mir.addParamRef(a, 0);
    const three = try f.mir.addFloatConst(a, 3.0);
    const lit = [_]Mir.Value{ .f_one, .f_two };
    const par = [_]Mir.Value{ fc, three };
    const s0 = [_]Lower.NoiseSrc{.{ .kind = .table, .table = &lit, .id = 1 }};
    const s1 = [_]Lower.NoiseSrc{.{ .kind = .table, .table = &par, .id = 2 }};
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 0, .lo = 1, .noise_srcs = &s0 });
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 1, .lo = 0, .noise_srcs = &s1 });
    const an = try f.analysis();

    const n = try plan(.{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered }, &.{});
    try std.testing.expectEqual(@as(usize, 2), n.tabs.len);
    // The declared default is what a comptime table can hold.
    try std.testing.expectEqualSlices([2]f64, &.{.{ 5, 3 }}, n.tabs[1]);
    try std.testing.expectEqual(@as(usize, 2), n.tab_vals.len);
    try std.testing.expectEqual(@as(usize, 0), n.tab_vals[0].len);
    try std.testing.expectEqualSlices([2]Mir.Value, &.{.{ fc, three }}, n.tab_vals[1]);
}

test "§4.6.4.1 a generator in a potential contribution is row == col on the branch current, its sign in `neg`" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{ "a", "b" });
    defer f.deinit();
    const a = f.alloc();
    const pwr = try f.mir.addFloatConst(a, 1e-18);
    const th = [_]Lower.NoiseSrc{.{ .kind = .thermal, .id = 7, .pwr = pwr }};
    const fl = [_]Lower.NoiseSrc{.{ .kind = .thermal, .id = 8, .pwr = pwr }};
    const sw = [_]Lower.NoiseSrc{.{ .kind = .thermal, .id = 9, .pwr = pwr }};
    try f.lowered.contributions.append(a, .{ .access = .potential, .hi = 0, .lo = 1, .noise_srcs = &th });
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 1, .lo = Lower.ground, .noise_srcs = &fl });
    // §5.6.5 a switch branch: a potential and a flow contribution over one pair.
    try f.lowered.contributions.append(a, .{ .access = .potential, .hi = 1, .lo = 0, .noise_srcs = &sw });
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 1, .lo = 0 });
    const an = try f.analysis();
    // `plan/names.zig` gave the potential branches the current unknowns 2 and 3.
    const n = try plan(.{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered }, &.{ 2, names_none, 3, names_none });
    try std.testing.expectEqual(@as(usize, 3), n.rows.len);
    try std.testing.expectEqual(@as(u32, 2), n.rows[0].row);
    try std.testing.expectEqual(@as(u32, 2), n.rows[0].col);
    try std.testing.expect(n.rows[0].neg);
    // The flow contribution is a current to ground: row == col == b.
    try std.testing.expectEqual(@as(u32, 1), n.rows[1].row);
    try std.testing.expectEqual(@as(u32, 1), n.rows[1].col);
    try std.testing.expect(!n.rows[1].neg);
    // The switch branch keeps the node form, (b, a), whether or not its
    // current unknown exists at run time.
    try std.testing.expectEqual(@as(u32, 1), n.rows[2].row);
    try std.testing.expectEqual(@as(u32, 0), n.rows[2].col);
    try std.testing.expect(!n.rows[2].neg);
}

/// `plan/names.zig`'s "no branch current" marker, for the tests' `branch_u`.
const names_none = std.math.maxInt(u32);

test "§4.6.4.6 one table call shared by two branches is one generator: one table, or one refusal" {
    for ([_]bool{ true, false }) |valid| {
        var f: Fixture = .{ .arena = .init(std.testing.allocator) };
        try f.init(&.{ "a", "b" });
        defer f.deinit();
        const a = f.alloc();
        const good = [_]Mir.Value{ try f.mir.addFloatConst(a, 10), .f_one };
        const odd = [_]Mir.Value{ try f.mir.addFloatConst(a, 10), .f_one, .f_two };
        const srcs = [_]Lower.NoiseSrc{.{ .kind = .table, .table = if (valid) good[0..] else odd[0..], .id = 7 }};
        try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 0, .lo = 1, .noise_srcs = &srcs });
        try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 1, .lo = Lower.ground, .noise_srcs = &srcs });
        const an = try f.analysis();

        const n = try plan(.{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered }, &.{});
        if (valid) {
            try std.testing.expectEqual(@as(usize, 2), n.rows.len);
            try std.testing.expectEqual(@as(usize, 1), n.tabs.len);
            try std.testing.expectEqual(@as(?u16, 0), n.rows[1].table);
            try std.testing.expectEqual(n.rows[0].source, n.rows[1].source);
        } else {
            // One call, one diagnostic: the second branch reaching it is not a
            // second table to refuse.
            try std.testing.expectEqual(@as(usize, 0), n.rows.len);
            try std.testing.expectEqual(@as(usize, 1), n.refusals.items.len);
        }
    }
}

test psdConst {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{"a"});
    defer f.deinit();
    const a = f.alloc();
    try std.testing.expectEqual(@as(?f64, 2.5), psdConst(&f.mir, try f.mir.addFloatConst(a, 2.5)));
    try std.testing.expectEqual(@as(?f64, 3), psdConst(&f.mir, try f.mir.addIntConst(a, 3)));
    // A parameter belongs to the card: only the core (or `Model`) can answer.
    try std.testing.expectEqual(@as(?f64, null), psdConst(&f.mir, try f.mir.addParamRef(a, 0)));
    try std.testing.expectEqual(@as(?f64, null), psdConst(&f.mir, try f.probe(0)));
}
