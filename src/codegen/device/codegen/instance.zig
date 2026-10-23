//! The device's per-instance state -> §4.5 `Instance` (environment, one
//! field group per stateful operator keyed by its stable unit name, §5.6.1.2
//! path latches, §5.10 held variables, `vera_timepoint` caches and the
//! §9.7.3 status latch), its `State` twin and `stateCtl`, which commits and
//! reverts every field `updateState` advances (`Gen.hist`). Field order is
//! part of the incremental-build contract: a new operator moves no existing
//! field.
//! LRM: §2.9, §4.5, §4.5.7, §4.5.11, §4.5.12, §5.6.1.2, §5.10, §9.7.3, §9.10,
//! §9.12, §9.13.1, §9.17.1, §9.17.2, §9.21.1.

const std = @import("std");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_call = @import("call.zig");
const gen_dispatch = @import("dispatch.zig");
const gen_file = @import("file.zig");
const gen_render = @import("render.zig");
const gen_state = @import("state.zig");
const gen_unit = @import("unit.zig");
const gen_wide = @import("wide.zig");
const opdb = @import("op_zig.zig");
const cg_filters = @import("../cg_filters.zig");
const cg_strcap = @import("../cg_strcap.zig");
const kt = @import("kernel_text.zig");
const Lowered = @import("ir").Lowered;
const Mir = @import("ir").Mir;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;

/// Length of the §4.5.7 absdelay history ring, in samples, of a site with no
/// constant `maxdelay`.
// ponytail: a fixed 1024 samples with linear interpolation. SPICE's
// maxstep = min(tstep, span/50) already allows td/dt = 100 steps per delay,
// and ch04_expressions/a04_05 needs 515. A ring that fills while its oldest
// sample is still inside the window is thinned (`hist_kernels.zHistThin`),
// never cut: §4.5.7 bounds no lookback, so dropping a sample the window needs
// would silently shorten the delay. The ring stays inline in `Instance` so
// value copies, `stateCtl` twins and batch lanes keep working on a GPU too.
const hist_len: usize = 1024;
/// The step a `maxdelay` site's ring is sized for: `ceil(maxdelay /
/// hist_min_step) + 2` samples, within [`hist_len`, `hist_max`]. 1 ps is
/// the step a transmission line with a 1-5 ns delay is resolved at.
const hist_min_step: f64 = 1e-12;
/// The largest ring a `maxdelay` sizes: 16384 samples, 256 KiB of
/// `Instance` per site (16.4 ns of delay at `hist_min_step`).
const hist_max: usize = 16384;

/// The ring length of absdelay unit `i`: `hist_len`, or, for a
/// §4.5.7 `maxdelay` that folds (its declared default when a parameter), enough
/// samples to hold that delay at `hist_min_step`, up to
/// `hist_max`. A longer window is kept by thinning (W1051).
fn histLen(self: *const Gen, i: usize) usize {
    const args = self.names.opArgs(self.mir, i);
    if (args.len < 3) return hist_len;
    const md = (self.an.foldConst(args[2], true) orelse return hist_len).f;
    const want = md / hist_min_step + 2.0;
    if (!(want > @as(f64, @floatFromInt(hist_len)))) return hist_len;
    if (!(want < @as(f64, @floatFromInt(hist_max)))) return hist_max;
    return @intFromFloat(@ceil(want));
}

/// Emits `Instance`: environment (§9.10) plus one field group per stateful
/// §4.5 operator, keyed by the stable unit name so adding an unrelated
/// operator never renumbers existing state.
pub fn emitInstance(self: *Gen) Error!void {
    self.held_in_place = try gen_state.inPlaceArrays(self);
    try self.w(
        \\/// Per-instance state. The host owns every field above the operator
        \\/// block: `mfactor` (§6.3.6); the temperature is `Model.temperature__`.
        \\/// Time, step and analysis reach every entry point as `contract.SimState`.
        \\/// Every per-instance value `eval` reads lives here; what only
        \\/// `updateState` and `stateCtl` read lives in `State`.
        \\pub const Instance = struct {{
        \\    mfactor: f64 = 1.0,
        \\    /// §9.17.2 `$bound_step`: upper bound the model asks for on the
        \\    /// NEXT timestep, in seconds. `inf` = unconstrained. Written by
        \\    /// `updateState`; the host reads it after every accepted step and
        \\    /// shall ignore it outside a time-domain analysis (§9.17.2).
        \\    bound_step: f64 = std.math.inf(f64),
        \\    /// §9.17.1 `$discontinuity`: degree of the announced
        \\    /// discontinuity (0 = the equation itself, 1 = its slope, …), or
        \\    /// -1 for "none announced this step". Written by `updateState`.
        \\    discontinuity_order: i32 = -1,
        \\
    , .{});
    // §2.8.3/§12.32: only a device with a `$name` left to a VPI application
    // has a binding to hold; the slot is 8 bytes on every instance.
    if (self.lowered.uses.contains(.systf)) try self.w(
        "    /// §2.8.3/§12.32 the VPI application. Read only by a `$name`\n" ++
            "    /// this compiler could not resolve; `contract.validateHost`\n" ++
            "    /// is what keeps it non-null when `systf_calls` is not empty.\n" ++
            "    systf: ?*const contract.SystfHost = null,\n",
        .{},
    );
    // §9.17 the two fields `updateState` resets every accepted point are
    // history only where an operator moves them off the reset value; without
    // one they are the same constant before and after any revert, and their
    // `State` twins would be dead copies.
    if (writesSchedule(self, .bound_step)) try self.hist.append(self.arena, "bound_step");
    if (writesSchedule(self, .discontinuity)) try self.hist.append(self.arena, "discontinuity_order");
    if (try gen_call.anyCrossLocated(self)) {
        try self.w(
            \\    /// §5.10.3.1 the earliest time inside its own tolerance box at
            \\    /// which a `cross` the accepted step found late should have
            \\    /// fired (`zCrossRetry`); `inf` = every event was in its box.
            \\    /// Written by `updateState`. The fixed-grid testbench solves a
            \\    /// point there first (VD-066); another host may ignore it.
            \\    vera_cross_retry__: f64 = std.math.inf(f64),
            \\
        , .{});
        try self.hist.append(self.arena, "vera_cross_retry__");
    }
    // §9.12 / IEEE 1364 §17.10: only a model that searches the plusargs has
    // somewhere for the host to write them.
    if (self.lowered.uses.contains(.plusargs)) try self.w(
        "    /// §9.12 the invocation's command-line arguments, in supplied order,\n" ++
            "    /// written by the host. Entries not starting with `+` are skipped.\n" ++
            "    plusargs: []const [:0]const u8 = &.{{}},\n",
        .{},
    );
    // §9.15 Table 9-28: only a model that asks has somewhere for the host to
    // write its working directory and its name for the analysis. A host that
    // cannot put a pointer here (a GPU copy) writes the `Model` indices
    // instead (`emitModel`, `contract.host_strings`).
    if (self.lowered.uses.contains(.host_strings)) try self.w(
        "    /// §9.15 `$simparam$str(\"cwd\")`: the directory the simulator was\n" ++
            "    /// started in, written by the host.\n" ++
            "    cwd: []const u8 = \"\",\n" ++
            "    /// §9.15 `$simparam$str(\"analysis_name\")`: the host's name for the\n" ++
            "    /// current analysis (\"tran1\", \"mydc\"), written before it runs.\n" ++
            "    analysis_name: []const u8 = \"\",\n",
        .{},
    );
    for (self.lowered.table_samples.items, 0..) |count, site| {
        try self.w("    table_{d}: [{d}]f64 = @splat(0.0),\n", .{ site, count });
    }
    // §9.21.1 + §9.3 (VD-095): `table_kept` marks the sites whose capture an
    // accepted point made (`updateState`, committed and reverted by
    // `stateCtl`, kept across analyses); `table_ready` the sites captured so
    // far in the current evaluation, which starts from `table_kept`.
    if (self.lowered.table_samples.items.len != 0) try self.w(
        "    table_ready: [{0d}]bool = @splat(false),\n    table_kept: [{0d}]bool = @splat(false),\n",
        .{self.lowered.table_samples.items.len},
    );
    if (self.lowered.limit_slots.items.len != 0) try self.w(
        "    limiter_previous: [{d}]f64 = @splat(0.0),\n",
        .{self.lowered.limit_slots.items.len},
    );
    // §9.13.1's "internal seed", one slot per seedless call site. The default
    // is a fixed value, not a clock read, so a run is reproducible and
    // §9.13.2's "shall always return the same value given the same seed" can
    // be checked. Distinct per site: the internal seed "gets updated every
    // time the call ... is made", so two call sites are two streams.
    if (self.lowered.rng_auto_seeds.items.len != 0) {
        try self.w(
            "    /// §9.13.1 the internal seed of each seedless `$random`/`$arandom`\n" ++
                "    /// call site. Advanced by `updateState` on the ACCEPTED step and only\n" ++
                "    /// READ by `eval`: a draw that moved between Newton iterations would\n" ++
                "    /// make the residual non-deterministic and the solve would not converge.\n" ++
                "    rng_auto: [{d}]i64 = .{{",
            .{self.lowered.rng_auto_seeds.items.len},
        );
        for (self.lowered.rng_auto_seeds.items, 0..) |seed, k| try self.w("{s}{d}", .{
            if (k == 0) "" else ", ", seed,
        });
        try self.w("}},\n", .{});
        try self.hist.append(self.arena, "rng_auto");
    }
    for (self.names.units, 0..) |u, i| {
        if (u.role != .analog_op) continue;
        const n = self.names.unit_names[i];
        // Operators whose Instance shape is fixed are a table read (op_zig.zig).
        for (opdb.get(u.op).slots) |s| {
            if (s.note.len == 0) {
                try self.w("    {s}__{s}: f64 = {s},\n", .{ n, s.suffix, s.default });
            } else {
                try self.w("    {s}__{s}: f64 = {s}, // {s}\n", .{ n, s.suffix, s.default, s.note });
            }
            try keepHist(self, "{s}__{s}", .{ n, s.suffix });
        }
        // Operators whose field count depends on the call (`shape = .from_args`).
        switch (u.op) {
            .absdelay => {
                try self.w(
                    "    {s}__t: [{d}]f64 = @splat(0.0), // §4.5.7 delay ring\n" ++
                        "    {s}__v: [{d}]f64 = @splat(0.0),\n" ++
                        "    {s}__head: u64 = 0,\n" ++
                        "    {s}__w: f64 = 0.0, // §4.5.7 the window the ring keeps (`zHistThin`)\n",
                    .{ n, histLen(self, i), n, histLen(self, i), n, n },
                );
                // The ring itself is not copied: `stateCtl` keeps the one
                // sample the next push overwrites (`emitStateCtl`).
                try keepHist(self, "{s}__head", .{n});
                // `updateState` rewrites the window, so a revert restores it.
                try keepHist(self, "{s}__w", .{n});
                // §4.5.7 the frozen td of the two-argument form. Emitted only
                // for a signal-valued td; a constant or parameter one is
                // already its own first value.
                if (try gen_call.absdelayFreezes(self, self.names.opArgs(self.mir, i))) {
                    try self.w("    {s}__td: f64 = 0.0, // §4.5.7 td, frozen at the first evaluation\n", .{n});
                    try keepHist(self, "{s}__td", .{n});
                }
                if (try gen_call.absdelayMaxdSampled(self, self.names.opArgs(self.mir, i))) {
                    try self.w("    {s}__maxd: f64 = 0.0, // §4.5.14 maxdelay, sampled at the start of the analysis\n", .{n});
                    try keepHist(self, "{s}__maxd", .{n});
                }
            },
            // §4.5.11/§4.5.12 direct-form-I history of the cascade: `deg`
            // past inputs and past outputs per section, newest first. The
            // shape comes from the flattened call, so it is a codegen-time
            // constant even though every coefficient is a runtime Model read.
            .laplace, .zi => {
                if (self.names.opInstOf(@intCast(i)) == null) continue;
                const p = cg_filters.planOf(self, i);
                if (p.err != null) continue;
                try self.w("    {s}__u: [{d}]f64 = @splat(0.0), // §4.5.{s}\n", .{
                    n, p.ns * p.deg, if (u.op == .zi) "12" else "11",
                });
                try self.w("    {s}__y: [{d}]f64 = @splat(0.0),\n", .{ n, p.ns * p.deg });
                try keepHist(self, "{s}__u", .{n});
                try keepHist(self, "{s}__y", .{n});
                if (p.sampled.len != 0) {
                    try self.w("    {s}__k: [{d}]f64 = @splat(0.0), // §4.5.14 coefficients, sampled at the start of the analysis\n", .{ n, p.sampled.len });
                    try keepHist(self, "{s}__k", .{n});
                }
                // §4.5.12 the filter's clock as a count of samples taken, not
                // the next sample time: `next += zn*T` drifts off the k·T grid
                // by an ulp or two (1e-9 + 1e-9 + 1e-9 > 3e-9 in f64), and a
                // timepoint under the drifted clock loses a sample for good.
                if (u.op == .zi) {
                    try self.w("    {s}__nk: f64 = 0.0, // §4.5.12 samples taken\n    {s}__out: f64 = 0.0,\n", .{ n, n });
                    try keepHist(self, "{s}__nk", .{n});
                    try keepHist(self, "{s}__out", .{n});
                    // §4.5.12 τ/t0: where the running transition starts from,
                    // and when (`zZiEvalRamp`).
                    if (p.tau != null) {
                        try self.w("    {s}__from: f64 = 0.0,\n    {s}__ts: f64 = -std.math.inf(f64),\n", .{ n, n });
                        try keepHist(self, "{s}__from", .{n});
                        try keepHist(self, "{s}__ts", .{n});
                    }
                }
            },
            // Every `.static` and `.none` row: already handled above, or
            // (§9.17) writing the two unconditional fields and no per-unit
            // one at all.
            .none, .idt_hold, .idtmod, .transition, .slew, .last_crossing, .cross, .above, .timer, .bound_step, .discontinuity => {},
        }
    }
    // §5.6.1.2 path-integrated reactive latches (ngspice NIintegrate
    // semantics): pb__k is the ddt operand at the last accepted solve, pq__k
    // the sum of committed A·ΔB increments (the charge base, fixed across one
    // Newton attempt). Zero defaults make the first committed increment A·B,
    // as ngspice MODEINITTRAN seeds qgs = capgs·vgs. `eval` reads these; their
    // staged twins, which only `updateState` and the commit touch, live in
    // `State` (`emitStateTwins`), so they cost `eval` no cache line.
    for (0..self.core.prev_lo.len) |k| {
        try self.w("    pb__{d}: f64 = 0.0, // path_prev latch\n", .{k});
    }
    for (0..self.core.acc_lo.len) |k| {
        try self.w("    pq__{d}: f64 = 0.0, // path_acc latch\n", .{k});
    }
    // §5.10 event-assigned variables. Last, so a model that gains one moves
    // no operator field. The default is the declared initializer, which only
    // the first evaluation (before any `updateState`) can observe.
    for (self.lowered.held_vars.items, 0..) |h, i| {
        // ponytail: a parameter-dependent initializer takes the parameter's
        // spec default, like every §4.5 operator control argument, because a
        // struct field default is comptime and a model card is not. Upgrade
        // path: write it in `initState`, which already takes `*Instance`.
        try self.hist.append(self.arena, self.names.held_names[i]);
        // Why it is held (`HeldVar.Why`), so a reader of the device can tell
        // a latch from retention: tools/external_vampyre.py compares the
        // `retained` ones with a linter's hidden state.
        const note = try self.arena.print("// §5.10 held across evaluations: {t}", .{h.why});
        if (h.array != none_u32) {
            try emitHeldArrayField(self, h, self.names.held_names[i], note);
            if (dirtyTracked(self, h.array)) try self.w(
                "    {s}__dirty: [2]i64 = .{{ 0, {d} }}, // §5.10 elements written since the last stateCtl\n",
                .{ self.names.held_names[i], self.lowered.mem_arrays.items[h.array].len - 1 },
            );
            continue;
        }
        if (h.ty == .string) {
            // §3.3 a string's initial value is "" unless declared. Its own
            // bytes (`ZStrHeld`, #19), never a slice of a `$sformat` site's
            // `zSBuf`, which the site rewrites when it runs again.
            const s = switch (self.mir.valueDef(self.an.rv(h.init))) {
                .str_const => |s| s,
                else => "", // else: a non-literal initializer starts from §3.3's empty string, as a real starts from its spec default
            };
            // Sized for the longest text the model can hold there (`cg_strcap`).
            try self.w("    {s}: ", .{self.names.held_names[i]});
            try cg_strcap.emitHeldType(self, i);
            try self.w(" = ", .{});
            try cg_strcap.emitHeldCopy(self, i);
            try self.w("\"{f}\"), {s}\n", .{ std.zig.fmtString(s), note });
            continue;
        }
        if (h.ty == .wide) {
            // IEEE 1364 §5.4 a wide `reg`: its literal initializer's bits
            // (`gen_wide.emitConstInit`), else zero.
            try self.w("    {s}: {s} = ", .{ self.names.held_names[i], try gen_wide.zigTy(self, h.width) });
            if (!try gen_wide.emitConstInit(self, h.init)) try self.w("zwZero({d})", .{h.width});
            try self.w(", {s}\n", .{note});
            continue;
        }
        const init = self.an.foldConst(self.an.rv(h.init), true);
        const v: f64 = if (init) |c| c.f else 0.0;
        if (h.ty == .integer) {
            try self.w("    {s}: i64 = {d}, {s}\n", .{
                // Saturating like every other fold-side real -> int cast: an
                // initializer of `1e300` must not panic the compiler.
                self.names.held_names[i], std.math.lossyCast(i64, @round(v)), note,
            });
        } else {
            try self.w("    {s}: f64 = {s}, {s}\n", .{
                self.names.held_names[i], try gen_file.fmtF64(self, v), note,
            });
        }
    }
    // A `State` with no field at all is zero-sized and comptime-known, and a
    // host that stores it beside its `Instance` (`.{ inst, st }`) can no longer
    // take its bytes: keep the §9.17 twins as its content rather than emit an
    // empty `State`.
    if (self.hist.items.len == 0 and !pathLatches(self) and self.lowered.limit_slots.items.len == 0)
        try self.hist.appendSlice(self.arena, &.{ "bound_step", "discontinuity_order" });
    try emitTpFields(self);
    if (hasStatus(self)) try self.w(
        \\    /// §9.7.3 the first `$fatal`/`$error` reported, `contract.statusSite`'s
        \\    /// code; 0 = ok. Sticky until `initState` or `setupInstance`.
        \\    vera_status__: u32 = 0,
        \\    /// The reported site's numeric arguments (`contract.formatStatus`).
        \\    vera_status_args__: [{d}]f64 = @splat(0.0),
        \\
    , .{Lowered.status_arg_max});
    try self.w("}};\n\n", .{});
    try emitTpHelpers(self);
    try emitStatusHelpers(self);
}

/// §9.7.3 `initState` and `setupInstance` clear a latched status (a `w` format).
pub const status_drop = "    inst.vera_status__ = 0;\n    inst.vera_status_args__ = @splat(0.0);\n";

/// Whether the device reports §9.7.3 `$fatal`/`$error` as a status
/// (`Lowered.status`): a printing artifact runs them in its display chain.
pub fn hasStatus(self: *const Gen) bool {
    return self.display != .emit and self.lowered.status != .undef;
}

/// The core result's spelling of status value `v`: its field, its folded
/// constant, or 0 for an argument the site never set.
fn statusVal(self: *Gen, v: Mir.Value) Error![]const u8 {
    if (v == .undef) return "0.0";
    if (self.an.foldConst(v, false)) |c| return gen_file.fmtF64(self, c.f);
    const k = gen_dispatch.coreIdx(self, self.an.rv(v)).?;
    return self.arena.print("m.f{d}.val()", .{k});
}

/// §9.7.3 `status_sites`, `zStatusStore` (which `eval`, `q` and `evalQ` call
/// on the core result: the first status reported sticks) and `status_drop`
/// (`initState`, `setup`).
fn emitStatusHelpers(self: *Gen) Error!void {
    if (!hasStatus(self)) return;
    try self.w(
        \\/// §9.7.3 every `$fatal`/`$error` in the analog context: a device cannot
        \\/// print or stop its host, so the first one an evaluation reaches latches
        \\/// `Instance.vera_status__` (`contract.formatStatus` renders it), and
        \\/// from then on `eval`, `q` and `evalQ` return all-zero rows and
        \\/// `updateState` leaves the state alone.
        \\pub const status_sites = [_]contract.StatusSite{{
        \\
    , .{});
    for (self.lowered.status_sites.items) |s| {
        const at = srcLine(self, s.tok);
        try self.w("    .{{ .severity = .{s}, .fmt = \"{f}\", .file = \"{f}\", .line = {d} }},\n", .{
            if (s.fatal) "fatal" else "@\"error\"", std.zig.fmtString(s.fmt), std.zig.fmtString(at.file), at.line,
        });
    }
    try self.w("}};\n\n", .{});
    const code = try statusVal(self, self.lowered.status);
    // The `.{ }` below spells four arguments.
    comptime std.debug.assert(Lowered.status_arg_max == 4);
    var args: [Lowered.status_arg_max][]const u8 = undefined;
    var reads_m = std.mem.startsWith(u8, code, "m.");
    for (&args, self.lowered.status_args) |*s, a| {
        s.* = try statusVal(self, a);
        reads_m = reads_m or std.mem.startsWith(u8, s.*, "m.");
    }
    try self.w("/// §9.7.3 latch the first status reported; later ones change nothing.\n", .{});
    try self.w("inline fn zStatusStore(inst: *Instance, {s}: anytype) void {{\n", .{if (reads_m) "m" else "_"});
    try self.w("    if (inst.vera_status__ != 0) return;\n", .{});
    try self.w("    const code: f64 = {s};\n", .{code});
    try self.w("    if (code == 0.0) return;\n    inst.vera_status__ = @intFromFloat(code);\n", .{});
    try self.w("    inst.vera_status_args__ = .{{ {s}, {s}, {s}, {s} }};\n}}\n\n", .{ args[0], args[1], args[2], args[3] });
    // Every charge zero, value and derivative lanes, as `zRowsZero` does
    // for the rows. Unreferenced (so unanalysed) without a reactive half.
    try self.w(
        \\fn zSitesZero(comptime S: type) contract.Sites(Self, S) {{
        \\    var r: contract.Sites(Self, S) = undefined;
        \\    inline for (0..contract.nQ(Self)) |k| r[k] = zTo(S, contract.siteMask(Self, k), S.con(0.0));
        \\    return r;
        \\}}
        \\
        \\
    , .{});
}

/// The source file and 1-based line of token `tok`, through the diagnostic
/// bag's source map (an `include`d file names itself). Empty and 0 when
/// codegen runs without a bag.
pub fn srcLine(self: *const Gen, tok: u32) struct { file: []const u8, line: u32 } {
    const bag = self.diags orelse return .{ .file = "", .line = 0 };
    if (tok >= self.lowered.tok_starts.len) return .{ .file = "", .line = 0 };
    const start = self.lowered.tok_starts[tok];
    const at = bag.locate(.{ .start = start, .end = start }, null);
    const off = bag.toSourceOffset(at.file, at.offset);
    const text = bag.sourceText(at.file);
    return .{
        .file = bag.fileName(at.file),
        .line = @intCast(1 + std.mem.count(u8, text[0..@min(off, text.len)], "\n")),
    };
}

/// VerA's `vera_timepoint` (§2.9): each cached statement's `Instance` fields,
/// `tp<b>_t`/`tp<b>_k` (the time and `zTpKey` it was filled at; NaN when
/// dropped) and one `tp<b>_s<k>` per slot. Not history: `stateCtl` drops
/// them rather than restoring them (`zTpDrop`).
fn emitTpFields(self: *Gen) Error!void {
    for (self.lowered.timepoints.items, 0..) |t, b| {
        try self.w("    /// vera_timepoint {d}: the timepoint its cache holds, NaN when dropped.\n", .{b});
        try self.w("    tp{d}_t: f64 = " ++ kt.nan_lit ++ ",\n    tp{d}_k: u8 = 0,\n", .{ b, b });
        for (t.slots, 0..) |sl, k| {
            // A slot nothing reads after the statement is not queued (`plan_jobs`).
            if (gen_dispatch.coreIdx(self, self.an.rv(sl.final)) == null) continue;
            if (sl.array != none_u32) {
                const m = self.lowered.mem_arrays.items[sl.array];
                try self.w("    tp{d}_s{d}: [{d}]{s} = @splat(0), // {s}\n", .{ b, k, m.len, if (m.ty == .integer) "i64" else "f64", sl.name });
            } else {
                if (sl.ty == .wide)
                    try self.w("    tp{d}_s{d}: ZW({d}) = zwZero({d}), // {s}\n", .{ b, k, sl.width, sl.width, sl.name })
                else
                    try self.w("    tp{d}_s{d}: {s} = 0, // {s}\n", .{ b, k, if (sl.ty == .integer) "i64" else "f64", sl.name });
            }
        }
    }
}

/// VerA's `vera_timepoint` (§2.9): whether slot `sl`'s cache is a §5.10
/// copy-on-write held array (`render.cow`) that the statement's stores write
/// in place, in its `tp<b>_s<k>` field, when the core is handed a mutable
/// `Instance` (`eval`, `evalQ`). A local copy of a held history and its copy
/// in the core's result are what put txl's 2048-deep history at 165 KB of
/// GPU stack, and the coupled lines' at 307-612 KB (#82).
pub fn tpInPlace(self: *const Gen, sl: Lowered.TpSlot) bool {
    if (sl.array == none_u32 or !gen_render.cow(self, sl.array)) return false;
    // The slot's field exists only when the full core carries the final
    // version (`emitTpFields`); a slice's `plan.lo_idx` is its own.
    const v = self.an.rv(sl.final);
    return v != .f_zero and self.tp_lo_idx[@backingInt(v)] != none_u32;
}

/// Whether some `vera_timepoint` slot is stored in place (`tpInPlace`).
pub fn anyTpInPlace(self: *const Gen) bool {
    for (self.lowered.timepoints.items) |t| for (t.slots) |sl| if (tpInPlace(self, sl)) return true;
    return false;
}

/// Returns `Gen.tp_of_block`: per MIR block, the innermost `vera_timepoint`
/// statement whose miss arm holds it (the blocks its miss block reaches
/// before the join, as `plan_setup.timepointVarying` walks them), or
/// `none_u32`. Empty when no slot is stored in place.
pub fn tpBlocks(self: *Gen) Error![]const u32 {
    if (!anyTpInPlace(self)) return &.{};
    const nb = self.an.nb;
    const of = try self.arena.alloc(u32, nb);
    @memset(of, none_u32);
    const seen = try self.arena.alloc(bool, nb);
    var stack: std.ArrayList(u32) = try .initCapacity(self.arena, nb);
    // Source order: a statement nested in another comes after it, so its
    // blocks end up naming the inner one.
    for (self.lowered.timepoints.items, 0..) |t, b| {
        @memset(seen, false);
        const miss: u32 = @backingInt(t.miss);
        const join: u32 = @backingInt(t.join);
        seen[miss] = true;
        stack.appendAssumeCapacity(miss);
        // Each block is pushed at most once (its flag is set first).
        while (stack.pop()) |x| {
            of[x] = @intCast(b);
            for (self.an.succs[x]) |y| {
                if (y == join or seen[y]) continue;
                seen[y] = true;
                stack.appendAssumeCapacity(y);
            }
        }
    }
    return of;
}

/// The `tp<b>_s<k>` slot a store to array `id` in MIR block `bi` writes in
/// place (`tpInPlace`), or null when the store is outside every statement or
/// its statement does not cache `id` in place.
pub fn tpSlotAt(self: *const Gen, bi: u32, id: u32) ?struct { b: u32, k: u32 } {
    if (self.tp_of_block.len == 0) return null;
    const b = self.tp_of_block[bi];
    if (b == none_u32) return null;
    for (self.lowered.timepoints.items[b].slots, 0..) |sl, k| {
        if (sl.array == id and tpInPlace(self, sl)) return .{ .b = b, .k = @intCast(k) };
    }
    return null;
}

/// VerA's `vera_timepoint` (§2.9): at statement join `bi`, for every
/// in-place array slot whose hit arm this body emits, points `p<id>` at the
/// slot, copying the version in when the statement stored none (`zTpFill`):
/// then the slot holds what the statement left whichever arm ran, and
/// `zTpStore` has nothing to copy. In `updateState`'s slice, which stores the
/// array in its field, the field takes that role instead (`zTpHeld`).
pub fn emitTpFills(self: *Gen, bi: u32, depth: u32) Error!void {
    if (self.tp_of_block.len == 0) return;
    for (self.lowered.timepoints.items, 0..) |t, b| {
        if (@backingInt(t.join) != bi) continue;
        for (t.slots, 0..) |sl, k| {
            if (!tpInPlace(self, sl)) continue;
            // Whenever the hit arm re-points `p<id>` in this body: something
            // after the join reads that version, so the miss arm's version
            // (which `p<id>` holds there) is computed too.
            if (!hitEmitted(self, @intCast(b), @intCast(k))) continue;
            const m = self.lowered.mem_arrays.items[sl.array];
            const ty = if (m.ty == .integer) "i64" else "f64";
            self.uses.inst = true;
            try self.ind(depth);
            // `updateState`'s slice stores the array in its field
            // (`render.inPlace`): a hit's cached version is copied there.
            if (gen_render.inPlace(self, sl.array)) {
                const f = self.names.held_names[m.held];
                if (dirtyTracked(self, sl.array))
                    try self.b("zTpHeld({s}, {d}, &inst.{s}, &p{d}, &inst.{s}__dirty);\n", .{ ty, m.len, f, sl.array, f })
                else
                    try self.b("zTpHeld({s}, {d}, &inst.{s}, &p{d}, null);\n", .{ ty, m.len, f, sl.array });
                continue;
            }
            try self.b("zTpFill({s}, {d}, &inst.tp{d}_s{d}, &p{d});\n", .{ ty, m.len, b, k, sl.array });
        }
    }
}

/// Whether the body being emitted computes the `anew` that reads slot
/// `k` of statement `b` (the hit arm's `p<id> = &inst.tp<b>_s<k>`).
fn hitEmitted(self: *const Gen, b: u32, k: u32) bool {
    for (self.an.i_op, 0..) |op, ii| {
        if (op != .anew) continue;
        const inst: Mir.Inst = @fromBackingInt(@intCast(ii));
        const tp = self.mir.instData(inst).anew.tp orelse continue;
        if (tp.block != b or tp.slot != k) continue;
        // As `cfg.emitStmt` decides it emits the statement.
        const v = self.an.i_res[ii];
        if (self.plan.needed.isSet(@backingInt(v)) and !self.plan.cached(v)) return true;
    }
    return false;
}

/// VerA's `vera_timepoint` (§2.9): `zTpDrop`, which every entry point that
/// moves what a cached statement reads calls (`initState`, `setup`,
/// `updateState`, `stateCtl`), and `zTpStore`, which `eval` and `evalQ`
/// call on the core result: a statement that ran on a stale cache fills it.
fn emitTpHelpers(self: *Gen) Error!void {
    const tps = self.lowered.timepoints.items;
    if (tps.len == 0) return;
    try self.w("/// vera_timepoint: drop every per-timepoint cache.\nfn zTpDrop(inst: *Instance) void {{\n", .{});
    for (0..tps.len) |b| try self.w("    inst.tp{d}_t = " ++ kt.nan_lit ++ ";\n", .{b});
    try self.w("}}\n\n", .{});
    try self.w("/// vera_timepoint: store what a statement that ran on a stale cache assigned.\n", .{});
    try self.w("inline fn zTpStore(inst: *Instance, sim: contract.SimState, m: anytype) void {{\n", .{});
    for (tps, 0..) |t, b| {
        // An unconditional statement's mark folds to 1 and is no core field.
        if (gen_dispatch.coreIdx(self, self.an.rv(t.mark))) |mk| try self.w("    if (m.f{d} != 0 and ", .{mk}) else try self.w("    if (", .{});
        try self.w("!zTpHit(inst.tp{d}_t, inst.tp{d}_k, sim)) {{\n", .{ b, b });
        for (t.slots, 0..) |sl, k| {
            const fk = gen_dispatch.coreIdx(self, self.an.rv(sl.final)) orelse continue;
            // The core already left it in its slot (`emitTpFills`).
            if (tpInPlace(self, sl)) continue;
            const val = sl.array == none_u32 and sl.ty == .real;
            try self.w("        inst.tp{d}_s{d} = m.f{d}{s};\n", .{ b, k, fk, if (val) ".val()" else "" });
        }
        try self.w("        inst.tp{d}_t = sim.t;\n        inst.tp{d}_k = zTpKey(sim);\n    }}\n", .{ b, b });
    }
    try self.w("}}\n\n", .{});
}

/// Returns whether some operator's accepted-step code writes the §9.17 field
/// `which` names (`.bound_step`: `Instance.bound_step`; `.discontinuity`:
/// `Instance.discontinuity_order`) after `updateState`'s unconditional reset:
/// the operator itself, a §4.5.7 `absdelay` bounding the step at its delay,
/// or a §4.5.12 `zi` filter at its period and on each sample.
fn writesSchedule(self: *const Gen, comptime which: @import("ir").op.OpKind) bool {
    for (self.names.units) |u| {
        if (u.role != .analog_op) continue;
        switch (u.op) {
            .zi => return true,
            .absdelay => if (which == .bound_step) return true,
            .bound_step => if (which == .bound_step) return true,
            .discontinuity => if (which == .discontinuity) return true,
            .none, .idt_hold, .idtmod, .transition, .slew, .last_crossing, .cross, .above, .timer, .laplace => {},
        }
    }
    return false;
}

/// Records `Instance` field `fmt` as history `stateCtl` commits and reverts.
fn keepHist(self: *Gen, comptime fmt: []const u8, args: anytype) Error!void {
    try self.hist.append(self.arena, try self.arena.print(fmt, args));
}

/// Emits a §3.2.2/§5.10 held array's `Instance` field: plain values,
/// defaulting element by element to the declared initializer (§3.2's zero
/// where the pattern is silent), the spec default as for a held scalar.
fn emitHeldArrayField(self: *Gen, h: Lowered.HeldVar, name: []const u8, comment: []const u8) Error!void {
    const m = self.lowered.mem_arrays.items[h.array];
    const ty: []const u8 = if (m.ty == .integer) "i64" else "f64";
    var all_zero = true;
    for (h.inits) |iv| {
        const c = self.an.foldConst(self.an.rv(iv), true) orelse continue;
        if (c.f != 0.0) all_zero = false;
    }
    if (all_zero) return self.w("    {s}: [{d}]{s} = @splat(0), {s}\n", .{ name, m.len, ty, comment });
    try self.w("    {s}: [{d}]{s} = .{{", .{ name, m.len, ty });
    for (0..m.len) |k| {
        const c = if (k < h.inits.len) self.an.foldConst(self.an.rv(h.inits[k]), true) else null;
        const v: f64 = if (c) |x| x.f else 0.0;
        if (k != 0) try self.w(", ", .{});
        if (m.ty == .integer) try self.w("{d}", .{std.math.lossyCast(i64, @round(v))}) else try self.w("{s}", .{try gen_file.fmtF64(self, v)});
    }
    try self.w(" }}, {s}\n", .{comment});
}

/// Returns whether the module's §5.10 held state is fed by `cross`/`above`
/// edges: a hysteresis FSM (a switch) that gets `stateCtl`
/// (contract.StateCtlOp). The host rejects a converged step whose accepted
/// solution flipped the latch and shrinks toward the crossing, so the
/// discontinuity lands sharp instead of smearing across one step.
fn fsmStateCtl(self: *const Gen) bool {
    for (self.lowered.held_vars.items) |h| {
        if (h.why == .event) break;
    } else return false;
    for (self.names.units) |u| {
        if (u.role != .analog_op) continue;
        switch (u.op) {
            .cross, .above => return true,
            .none, .idt_hold, .idtmod, .absdelay, .transition, .slew, .last_crossing, .laplace, .zi, .timer, .bound_step, .discontinuity => {},
        }
    }
    return false;
}

/// Returns whether held array `id` keeps a `__dirty` index range: it is
/// stored in place (`Gen.held_in_place`) and long enough that `stateCtl`
/// copying only the elements written since the last commit or revert beats
/// copying it whole. Below `dirty_min_len` the per-store range update costs
/// more than the copy it saves (coupled_ltra: updateState +30% with every
/// held array tracked, `git show 6e59b3d4^:docs/measurements/device-runtime-2026-10-01.md`).
pub fn dirtyTracked(self: *const Gen, id: u32) bool {
    return self.held_in_place.len != 0 and self.held_in_place[id] and
        self.lowered.mem_arrays.items[id].len >= dirty_min_len;
}

/// Shortest held array `dirtyTracked` keeps a range for (elements).
const dirty_min_len = 64;

/// Returns the `Lowered.held_vars` row's array id when it is dirty-tracked.
fn dirtyArray(self: *const Gen, h: Lowered.HeldVar) ?u32 {
    if (h.array == none_u32 or !dirtyTracked(self, h.array)) return null;
    return h.array;
}

/// Returns the module's `Lowered.held_vars` row named `name`, if any.
fn heldNamed(self: *const Gen, name: []const u8) ?Lowered.HeldVar {
    for (self.names.held_names, self.lowered.held_vars.items) |n, h| {
        if (std.mem.eql(u8, n, name)) return h;
    }
    return null;
}

/// Returns the element type of held array row `h`'s `Instance` field.
fn elemTy(self: *const Gen, h: Lowered.HeldVar) []const u8 {
    return if (self.lowered.mem_arrays.items[h.array].ty == .integer) "i64" else "f64";
}

/// Returns whether the module has any path latch. Every gate on the latch
/// machinery tests this, not `acc_lo`: the reactive lowering plants prev+acc
/// pairs, but a source-level `$prev` site arrives alone and still needs its
/// updateState staging and commit advance.
pub fn pathLatches(self: *const Gen) bool {
    return self.core.acc_lo.len != 0 or self.core.prev_lo.len != 0;
}

/// Returns whether some §5.10 held variable is a string: its `Instance`
/// field is a `ZStrHeld`, which the string kernels define.
pub fn heldString(self: *const Gen) bool {
    for (self.lowered.held_vars.items) |h| {
        if (h.ty == .string) return true;
    }
    return false;
}

/// Emits `State`'s `stateCtl` twins: the §5.6.1.2 staged path-latch operands
/// (`wb__k`/`wq__k`, which `updateState` writes and `stateCtl(.commit)` moves
/// into `Instance.pb__k`/`pq__k`), one twin per `Gen.hist` field, typed and
/// defaulted as that `Instance` field, plus `t_prev__acc` when `t_prev` and
/// each §4.5.7 ring's overwritten sample. Requires `emitInstance` to have run
/// and `z_inst0` (a default `Instance`) to be declared.
pub fn emitStateTwins(self: *Gen, t_prev: bool) Error!void {
    for (0..self.core.prev_lo.len) |k| try self.w("    wb__{d}: f64 = 0.0, // path_prev staged\n", .{k});
    for (0..self.core.acc_lo.len) |k| try self.w("    wq__{d}: f64 = 0.0, // path_acc staged\n", .{k});
    if (t_prev) try self.w("    t_prev__acc: f64 = 0.0,\n", .{});
    for (self.hist.items) |h| try self.w("    {s}: @TypeOf(z_inst0.{s}) = z_inst0.{s},\n", .{ h, h, h });
    // Not `hist`: `initState` keeps a capture across analyses (VD-095).
    if (self.lowered.table_samples.items.len != 0)
        try self.w("    table_kept: [{d}]bool = @splat(false),\n", .{self.lowered.table_samples.items.len});
    for (self.names.units, 0..) |u, i| {
        if (u.role == .analog_op and u.op == .absdelay)
            try self.w("    {0s}__t__acc: f64 = 0.0,\n    {0s}__v__acc: f64 = 0.0,\n    {0s}__t__acc2: f64 = 0.0,\n    {0s}__v__acc2: f64 = 0.0,\n", .{self.names.unit_names[i]});
    }
}

/// Emits the `stateCtl` hook; every `updateState` has one. `query` compares
/// the held state a `cross`/`above` FSM writes (`fsmStateCtl`) and nothing
/// else, since other history moving is not a step-reject condition. `commit`
/// latches the §5.6.1.2 path latches (`pb = wb`, `pq += wq`, `wq = 0`) and
/// copies every field `updateState` advances into its `State` twin
/// (`emitStateTwins`); `revert` copies the twins back, so a rejected step
/// leaves the device as the last accepted point did (§4.5). A §4.5.7 ring
/// keeps only the sample the next push overwrites, which is exact while one
/// `updateState` runs between `stateCtl` calls. Tag order mirrors
/// contract.StateCtlOp, which the host converts by ordinal.
pub fn emitStateCtl(self: *Gen, t_prev: bool) Error!void {
    const fsm = fsmStateCtl(self);
    try self.w(
        \\/// §4.5 the step decision after `updateState` (`contract.StateCtlOp`):
        \\/// `.commit` latches the path latches and copies the history into
        \\/// `state`; `.revert` copies it back, so a rejected step leaves the
        \\/// instance as the last accepted point did. Returns true only for a
        \\/// `.query` whose accepted solution flipped a `cross`/`above` latch.
        \\
    , .{});
    try self.w("pub fn stateCtl(_: *const Model, ", .{});
    const at_inst = self.out.items.len;
    try self.w("inst: *Instance, ", .{});
    const at_state = self.out.items.len;
    try self.w(
        \\state: *State, op: contract.StateCtlOp) bool {{
        \\    if (op == .query) {{
        \\        return
    , .{});
    const body = self.out.items.len;
    // VerA's `vera_timepoint` (§2.9): a commit or a revert moves the held
    // state a cached statement reads.
    const tp_drop = if (self.lowered.timepoints.items.len != 0) "        zTpDrop(inst);\n" else "";
    // §9.21.1 (VD-095) the kept captures are history; the working ones of
    // the last evaluation are dropped either way, as the next evaluation
    // would drop them.
    const tables = self.lowered.table_samples.items.len != 0;
    const tbl_commit = if (tables) "        state.table_kept = inst.table_kept;\n        inst.table_ready = inst.table_kept;\n" else "";
    const tbl_revert = if (tables) "        inst.table_kept = state.table_kept;\n        inst.table_ready = inst.table_kept;\n" else "";
    var first = true;
    for (self.names.held_names, self.lowered.held_vars.items) |n, h| {
        if (!fsm) break;
        if (h.why != .event) continue;
        // §3.2.2 a held array (and a wide `reg`) compares element by element;
        // a string by text.
        if (h.array != none_u32 or h.ty == .wide)
            try self.w("{s}!std.meta.eql(inst.{s}, state.{s})", .{ if (first) " " else "\n            or ", n, n })
        else if (h.ty == .string)
            try self.w("{s}!std.mem.eql(u8, inst.{s}.get(), state.{s}.get())", .{ if (first) " " else "\n            or ", n, n })
        else
            try self.w("{s}(inst.{s} != state.{s})", .{ if (first) " " else "\n            or ", n, n });
        first = false;
    }
    if (first) try self.w(" false", .{});
    try self.w(
        \\;
        \\    }}
        \\    if (op == .commit) {{
        \\{s}{s}
    , .{ tp_drop, tbl_commit });
    if (self.lowered.limit_slots.items.len != 0) try self.w(
        "        state.limiter_previous = inst.limiter_previous;\n",
        .{},
    );
    for (0..self.core.prev_lo.len) |k| try self.w("        inst.pb__{d} = state.wb__{d};\n", .{ k, k });
    for (0..self.core.acc_lo.len) |k| try self.w("        inst.pq__{d} += state.wq__{d};\n        state.wq__{d} = 0.0;\n", .{ k, k, k });
    for (self.hist.items) |h| {
        if (heldNamed(self, h)) |hv| if (dirtyArray(self, hv) != null) {
            try self.w("        zArrSync({1s}, &state.{0s}, &inst.{0s}, &inst.{0s}__dirty);\n", .{ h, elemTy(self, hv) });
            continue;
        };
        try self.w("        state.{s} = inst.{s};\n", .{ h, h });
    }
    for (self.names.units, 0..) |u, i| {
        if (u.role == .analog_op and u.op == .absdelay) try self.w(
            "        state.{0s}__t__acc = inst.{0s}__t[@intCast(inst.{0s}__head % {1d})];\n        state.{0s}__v__acc = inst.{0s}__v[@intCast(inst.{0s}__head % {1d})];\n" ++
                // The sample a thinning push overwrites (`zHistRevert`).
                "        state.{0s}__t__acc2 = inst.{0s}__t[@intCast((inst.{0s}__head + 1) % {1d})];\n        state.{0s}__v__acc2 = inst.{0s}__v[@intCast((inst.{0s}__head + 1) % {1d})];\n",
            .{ self.names.unit_names[i], histLen(self, i) },
        );
    }
    if (t_prev) try self.w("        state.t_prev__acc = state.t_prev;\n", .{});
    try self.w("    }} else {{\n{s}{s}", .{ tp_drop, tbl_revert });
    // The count the rejected push left, before `__head` is restored.
    for (self.names.units, 0..) |u, i| {
        if (u.role == .analog_op and u.op == .absdelay)
            try self.w("        const zh{d} = inst.{s}__head;\n", .{ i, self.names.unit_names[i] });
    }
    if (self.lowered.limit_slots.items.len != 0) try self.w(
        "        inst.limiter_previous = state.limiter_previous;\n",
        .{},
    );
    for (self.hist.items) |h| {
        if (heldNamed(self, h)) |hv| if (dirtyArray(self, hv) != null) {
            try self.w("        zArrSync({1s}, &inst.{0s}, &state.{0s}, &inst.{0s}__dirty);\n", .{ h, elemTy(self, hv) });
            continue;
        };
        try self.w("        inst.{s} = state.{s};\n", .{ h, h });
    }
    // After `__head` is back: the slot the rejected push overwrote, and a
    // thinning it did undone (`zHistRevert`).
    for (self.names.units, 0..) |u, i| {
        if (u.role == .analog_op and u.op == .absdelay) try self.w(
            "        zHistRevert(&inst.{0s}__t, &inst.{0s}__v, inst.{0s}__head, zh{1d}, state.{0s}__t__acc, state.{0s}__v__acc, state.{0s}__t__acc2, state.{0s}__v__acc2);\n",
            .{ self.names.unit_names[i], i },
        );
    }
    if (t_prev) try self.w("        state.t_prev = state.t_prev__acc;\n", .{});
    try self.w(
        \\    }}
        \\    return false;
        \\}}
        \\
        \\
    , .{});
    // A device whose only accepted-step work is constant (the §9.17 resets)
    // or `$vera_reject_step` has nothing to commit.
    gen_unit.patchUnless(self, at_state, body, "state");
    gen_unit.patchUnless(self, at_inst, body, "inst");
}
