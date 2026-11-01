//! Core live-outs -> the host entry points: `eval` (resistive), `q` (reactive,
//! one charge per site), `evalQ`, and the structural Jacobian tables
//! (`jac_pattern`, `q_pattern`, `ac_dyn_slots`, `deriv_reads`, `jac_const`)
//! from the evidence the stamps leave in `Jac`. Stamps follow §1.3.1.2
//! reference directions. The §4.6.3/§4.6.4 source tables are `noise.zig`.
//! LRM: §1.3.1.2, §2.9, §5.4.2.1, §5.4.3, §5.6, §5.6.1.2, §5.6.1.3, §5.6.6, §9.4.
//!
//! Contents:
//! - `pub const Jac = struct`
//! - `pub const status_tail = "    return out;\n}}\n\n"`
//! - `pub fn alloc(self: *Gen) Error!void`
//! - `pub fn emitDispatchers(self: *Gen) Error!void`
//! - `pub fn anyQ(self: *const Gen) bool`
//! - `pub fn coreIdx(self: *const Gen, v: Mir.Value) ?u32`
//! - `pub fn tables(self: *const Gen) bool`
//! - `pub fn writeLead(self: *Gen, call: []const u8, ret: []const u8) Error!void`

const std = @import("std");
const plan_jac = @import("plan/jac.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_file = @import("file.zig");
const gen_instance = @import("instance.zig");
const gen_status = @import("status.zig");
const gen_unit = @import("unit.zig");
const gen_mask = @import("mask.zig");
const Mir = @import("ir").Mir;
const Lower = @import("ir").Lowered;
const assert = std.debug.assert;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const gen_stamps = @import("stamps.zig");
const jac_tables = @import("jac_tables.zig");
const dispatch_q = @import("dispatch_q.zig");

/// The Jacobian evidence emission leaves behind (`Gen.jac`), read by the
/// pattern tables and `emitDerivReads` after the dispatchers. Written by the
/// dispatchers through `patRow` and the `lin*` recorders, except the two lane
/// masks, which the renderer (`x[u]`) and `ddx` (`.ddxAt(u)`) also set.
/// `[2]` columns are indexed by `@intFromBool(react)`: 0 `eval`, 1 `q`.
/// `pat`, `dpat` and `lin` are arena slices allocated by `emitDispatchers`;
/// empty before it.
pub const Jac = struct {
    /// Structural Jacobian columns per residual row: `pat[react][ru]` has bit
    /// `cu` set when `∂res[ru]/∂x[cu]` can be nonzero. `emitStamps` fills it as
    /// it writes each row. The host reads the emitted constant to drop
    /// structurally-zero stamps at compile time. `Gen.mw` words per row.
    pat: [2][]u64 = .{ &.{}, &.{} },
    /// Which residual rows each half ever writes: bit `ru` of `rows[react]` is
    /// set when the emitted `eval` (resp. `q`) contains any `res[ru] = ...`.
    /// Not `pat[react][ru] != 0`: a term that depends on no unknown writes the
    /// row with a clear pattern (an independent current source), and a host
    /// that read a clear pattern as "identically zero" would drop it.
    /// Set beside `pat` in `patRow`, which every `res[...]` writer goes through.
    rows: [2][]u64 = .{ &.{}, &.{} },
    /// Which half of `pat` the current `emitStamps` writes.
    react: bool = false,
    /// Set once `emitDispatchers` has allocated the evidence; `patRow` records
    /// nothing before.
    on: bool = false,
    /// Per residual row, either half: the columns whose partial reaches it
    /// through a frequency-dependent operator (`Analysis.acDynDeps`), the
    /// source of `ac_dyn_slots`. `patRow` fills it from `cur_dyn`. `Gen.mw`
    /// words per row.
    dpat: []u64 = &.{},
    /// `acDynDeps` of the contribution `emitStamps` is writing; empty for none.
    cur_dyn: []const u64 = &.{},
    /// Unknowns whose derivative lane `eval`/`q` may read: the mask behind the
    /// emitted `deriv_reads`. Syntactic, so a superset: every `x[u]`
    /// `renderValueRef` writes, every `.ddxAt(u)`, and every dispatcher term
    /// with a non-constant coefficient. See `emitDerivReads`. Allocated by
    /// `alloc`, before any unit is rendered.
    deriv_reads: []u64 = &.{},
    /// The lanes a §4.5.14 `ddx` reads BY INDEX (`.ddxAt(u)`): the emitted
    /// `ddx_reads`, and a subset of `deriv_reads` by construction.
    ddx_reads: []u64 = &.{},
    /// The dispatcher's constant-coefficient terms, per half and row:
    /// `lin[react][row]` holds the exact coefficient of each `x[col]` in
    /// `res[row]` as far as the stamps are linear (`plan_jac.lookup`). Only
    /// the columns OUTSIDE `deriv_reads` leave as `jac_const`; inside, the
    /// lane carries them.
    lin: [2][]plan_jac.LinRow = .{ &.{}, &.{} },
    /// The constants of a collapsible switch row that hold only under its
    /// guard (`emitSwitchRow`), eval half; `plan/jac.zig` merges them into
    /// `jac_const` with a `.when`. Arena list.
    guarded: std.ArrayList(plan_jac.Entry) = .empty,
};
// =======================================================================
// Dispatchers: §5.6 residual assembly, §1.3.1.2 reference directions
// =======================================================================

/// §9.7.3 a status device's entry points (`gen_status.hasStatus`): a
/// latched status returns zero rows without running the core, and the core's
/// own report latches and does the same. One result variable, seeded zero,
/// and one return: an early `return` per guard left three copies of the
/// result in the GPU frame, the paths merged by a pointer phi that SROA
/// cannot split (bsimcmg's `evalQ`: 20.8 → 9.8 KB). `status_tail` closes it.
pub const status_tail = "    return out;\n}}\n\n";

/// Past this many words an n_u × n_u bit table (`jac_pattern`, `q_pattern`,
/// `q_site_pattern`) is not emitted, and a host takes every row's lanes from
/// `deriv_reads` (`contract.rowMask`). ponytail: n² bits; 2^16 words is
/// 2048 unknowns. Sparse row lists are the upgrade if a bigger device needs
/// per-row lanes.
const max_table_words = 1 << 16;

/// §5.10.2 the device-side end of a display pass, after `display` or
/// `displayPass`: the same text under both.
const finish_pass_txt =
    \\/// §5.10.2 a `$finish`/`$stop` recorded during the pass: `$finish` first
    \\/// raises `final_step` and re-runs the chain so the event's own tasks
    \\/// print, then the run ends. `final_step` and `zFinish` make the nested
    \\/// pass terminate without repeating either.
    \\fn zFinishPass(comptime S: type, x: *const [n_u]S.V, model: *const Model, inst: InstancePtr, sim: contract.SimState) void {{
    \\    if (zFinish == 0) return;
    \\    if (zFinish == 1 and !sim.final_step) {{
    \\        var zfs = sim;
    \\        zfs.final_step = true;
    \\        _ = eval(S, x, model, inst, zfs);
    \\        display(S, x, model, inst, zfs);
    \\    }}
    \\    _ = zHalt(0);
    \\}}
    \\
    \\
;

/// Allocates the lane masks the renderer writes (`deriv_reads`,
/// `ddx_reads`) on the arena. Runs once, after `Gen.mw` is known and before
/// any unit is rendered.
pub fn alloc(self: *Gen) Error!void {
    assert(self.mw >= 1);
    assert(self.jac.deriv_reads.len == 0);
    self.jac.deriv_reads = try gen_mask.zero(self.arena, self.mw);
    self.jac.ddx_reads = try gen_mask.zero(self.arena, self.mw);
    assert(self.jac.deriv_reads.len == self.mw);
    assert(self.jac.ddx_reads.len == self.mw);
}

/// Emits `eval`, and `q`/`evalQ`/the charge-site tables when any charge site
/// exists, then the pattern tables, `display` and (optionally) `vpiContribs`.
/// Allocates `jac.pat`, `jac.dpat`, `jac.rows` and `jac.lin` on the arena.
/// Runs once per device; asserts the evidence is still empty.
pub fn emitDispatchers(self: *Gen) Error!void {
    assert(!self.jac.on);
    assert(self.jac.guarded.items.len == 0);
    const n = self.names.n_u;
    self.jac.on = true;
    for (&self.jac.pat, &self.jac.rows, &self.jac.lin) |*p, *r, *l| {
        if (tables(self)) p.* = try gen_mask.zero(self.arena, n * self.mw);
        r.* = try gen_mask.zero(self.arena, self.mw);
        l.* = try self.arena.alloc(plan_jac.LinRow, n);
        @memset(l.*, .empty);
    }
    assert(self.jac.rows[1].len == self.mw);
    assert(self.jac.lin[1].len == n);
    if (tables(self) or self.acdyn.len != 0) self.jac.dpat = try gen_mask.zero(self.arena, n * self.mw);

    try emitEval(self);
    const any_q = anyQ(self);
    if (any_q) {
        dispatch_q.qPattern(self);
        try dispatch_q.emitQ(self);
        try emitFused(self);
        try dispatch_q.emitQSites(self);
    }
    // After the dispatchers: the pattern is accumulated as each row is written.
    try jac_tables.emitPattern(self, any_q);
    try jac_tables.emitAcDyn(self, any_q);
    try emitDisplay(self);
    if (self.vpi_contribs) try emitVpiContribs(self);
    assert(self.jac.on);
}

/// Returns whether any charge site gets a slot, that is, whether `q` is emitted.
pub fn anyQ(self: *const Gen) bool {
    assert(self.qs.sites.len <= self.lowered.charge_sites.items.len);
    return self.qs.sites.len != 0;
}

/// Returns the core field holding `v`, or null when `v` is rendered inline
/// (structurally zero, or a constant `plan_core.plan` never carries).
pub fn coreIdx(self: *const Gen, v: Mir.Value) ?u32 {
    assert(self.core.lo_idx.len == self.an.nv);
    if (v == .f_zero) return null;
    const k = self.core.lo_idx[@backingInt(v)];
    if (k != none_u32) assert(k < self.core.lo_vals.len);
    return if (k == none_u32) null else k;
}

/// Whether the n_u × n_u pattern tables are emitted (`max_table_words`).
pub fn tables(self: *const Gen) bool {
    assert(self.mw >= 1);
    return @as(usize, self.names.n_u) * self.mw <= max_table_words;
}

/// Writes the lead loop an entry point opens with (`batch_lead`): a family
/// running the protocol (`S.Inner`) evaluates the batch once per leader,
/// merging each run's points that followed the leader's path, until every
/// point has run on its own. A scalar family skips it at compile time. The
/// first run is inlined and the re-runs (divergent batches) share one
/// out-of-line copy, so a coherent batch costs one inlined body.
pub fn writeLead(self: *Gen, call: []const u8, ret: []const u8) Error!void {
    assert(call.len != 0);
    assert(ret.len != 0);
    if (!gen_file.batchLead(self)) return;
    try self.w(
        \\    if (comptime zLeads(S)) {{
        \\        S.leadBegin();
        \\        var out = @call(.always_inline, {0s}, .{{ S.Inner, x, model, inst, sim }});
        \\        while (S.leadNext()) S.leadMerge(&out, @call(.never_inline, {0s}, .{{ S.Inner, x, model, inst, sim }}));
        \\        return {1s};
        \\    }}
        \\
    , .{ call, ret });
}

// ---- private ----

/// Emits `vpiContribs` (`Options.vpi_contribs`): each §5.6 contribution's
/// resistive and reactive value at `x`, by `Lowered.contributions` index,
/// beside the row shape (access, the `U` of each terminal and of a potential
/// source's flow unknown, -1 for ground or none). A §11.6.7 flow-source flow
/// is its row value plus d/dt of the reactive half, which the host forms.
/// Reads `core` as `eval` and `q` do, so the numbers are the residual's own.
/// Then `vpiShares` and `vpi_share_row` when instances share a row.
fn emitVpiContribs(self: *Gen) Error!void {
    assert(self.vpi_contribs);
    assert(self.jac.on);
    const cs = self.lowered.contributions.items;
    try self.w("/// Clause 12 (`Options.vpi_contribs`): the §5.6 contribution rows.\n", .{});
    try self.w("pub const vpi_contrib_access = [_]u8{{", .{});
    for (cs) |c| try self.w(" {d},", .{@backingInt(c.access)});
    try self.w(" }};\npub const vpi_contrib_hi = [_]i32{{", .{});
    for (cs) |c| try self.w(" {d},", .{nodeCol(c.hi)});
    try self.w(" }};\npub const vpi_contrib_lo = [_]i32{{", .{});
    for (cs) |c| try self.w(" {d},", .{nodeCol(c.lo)});
    try self.w(" }};\npub const vpi_contrib_flow_u = [_]i32{{", .{});
    for (self.names.branch_u) |u| try self.w(" {d},", .{if (u == none_u32) @as(i64, -1) else u});
    try self.w(" }};\n", .{});
    try emitVpiValues(self, "vpiContribs", cs);
    // §5.4.1 one instance's flow is its own share of a row several share.
    const ss = self.lowered.contrib_shares.items;
    if (ss.len == 0) return;
    try self.w("/// Clause 12: each instance's own share of a shared row, by\n/// `Lowered.contrib_shares` index; `vpi_share_row` is the row's.\n", .{});
    try self.w("pub const vpi_share_row = [_]u32{{", .{});
    for (ss) |sh| try self.w(" {d},", .{sh.row});
    try self.w(" }};\n", .{});
    try emitVpiValues(self, "vpiShares", ss);
}

/// Emits `pub fn <name>`, returning each item's `resist_val` and `react_val`
/// read out of `core` (0.0 for a value the core does not return).
fn emitVpiValues(self: *Gen, name: []const u8, items: anytype) Error!void {
    assert(name.len != 0);
    assert(self.core.lo_idx.len == self.an.nv);
    try self.w("pub fn {s}(comptime S: type, x: *const [n_u]S.V, model: *const Model, inst: InstancePtr, sim: contract.SimState) [{d}][2]f64 {{\n", .{ name, items.len });
    const uses_core = for (items) |c| {
        if (coreIdx(self, self.an.rv(c.resist_val)) != null or coreIdx(self, self.an.rv(c.react_val)) != null) break true;
    } else false;
    if (uses_core)
        try self.w("    const m = @call(.always_inline, core, .{{ S, zProbe(S, x), model, inst, sim{s} }});\n", .{self.heldArg(false)})
    else
        try self.w("    _ = x;\n    _ = model;\n    _ = inst;\n    _ = sim;\n", .{});
    try self.w("    return .{{\n", .{});
    for (items) |c| {
        try self.w("        .{{ ", .{});
        for ([_]Mir.Value{ c.resist_val, c.react_val }, 0..) |v, k| {
            if (k != 0) try self.w(", ", .{});
            if (coreIdx(self, self.an.rv(v))) |f|
                try self.w("m.f{d}.val()", .{f})
            else
                try self.w("0.0", .{});
        }
        try self.w(" }},\n", .{});
    }
    try self.w("    }};\n}}\n\n", .{});
}

fn nodeCol(n: u32) i64 {
    assert(n != Lower.none_u32); // a contribution terminal is a `nodes` row or `ground`
    return if (n == Lower.ground) -1 else n;
}

/// Emits `display`, the §9.4 entry point a host calls to run the module's
/// display tasks, or under `.record` the site table and `say`, the entry
/// point that records them (`contract.SaySite`). Separate from `eval` so the
/// host decides when text happens rather than getting it once per Newton
/// iteration. Not emitted under `display == .drop`. The unit's `S` result is
/// discarded.
fn emitDisplay(self: *Gen) Error!void {
    assert(self.display != .drop or self.jobs.display_name.len == 0);
    if (self.display != .record) assert(self.say.len == 0);
    if (self.jobs.display_name.len == 0) return;
    if (self.display == .record) {
        try self.w(
            \\/// §9.4 every display task `say` records, in source order: a device
            \\/// cannot print, so a host calls `say` at an accepted point and renders
            \\/// the records with `contract.formatSay`.
            \\pub const say_sites = [_]contract.SaySite{{
            \\
        , .{});
        for (self.say) |site| {
            const at = gen_status.srcLine(self, site.tok);
            try self.w("    .{{ .fmt = \"{f}\", .file = \"{f}\", .line = {d}, .nargs = {d} }},\n", .{
                std.zig.fmtString(site.fmt), std.zig.fmtString(at.file), at.line, site.vals.len,
            });
        }
        try self.w(
            \\}};
            \\
            \\/// §9.4/§9.4.6 run this module's display tasks at `x`, the accepted point
            \\/// or (`out.pass = .iteration`, `$debug` only) an iterate, and append
            \\/// each one that runs and `out.pass` records to `out` (`contract.Say`).
            \\pub fn say(comptime S: type, x: *const [n_u]S.V, model: *const Model, inst: InstancePtr, sim: contract.SimState, out: *contract.Say) void {{
            \\    _ = {s}(S, zProbe(S, x), model, inst, sim, out);
            \\}}
            \\
            \\
        , .{self.jobs.display_name});
        return;
    }
    if (self.passes) return self.w(
        \\/// §9.4 run this module's display tasks once, in source order.
        \\pub fn display(comptime S: type, x: *const [n_u]S.V, model: *const Model, inst: InstancePtr, sim: contract.SimState) void {{
        \\    displayPass(S, x, model, inst, sim, .all);
        \\}}
        \\
        \\/// §9.4.1/§9.5.9 run the tasks `pass` performs at `x`: `.iteration`
        \\/// after each iteration of the solver, at its iterate (`$debug`,
        \\/// `$fdebug`, and at the first iterate the §9.5 calls of `analog
        \\/// initial`); `.accepted` at the accepted point of a solve that ran
        \\/// those passes; `.all` (`display`) at one that ran none.
        \\pub fn displayPass(comptime S: type, x: *const [n_u]S.V, model: *const Model, inst: InstancePtr, sim: contract.SimState, comptime pass: contract.SayPass) void {{
        \\    _ = {s}(S, zProbe(S, x), model, inst, sim, pass);
        \\    zFinishPass(S, x, model, inst, sim);
        \\}}
        \\
    ++ finish_pass_txt, .{self.jobs.display_name});
    try self.w(
        \\/// §9.4 run this module's display tasks once, in source order.
        \\pub fn display(comptime S: type, x: *const [n_u]S.V, model: *const Model, inst: InstancePtr, sim: contract.SimState) void {{
        \\    _ = {s}(S, zProbe(S, x), model, inst, sim);
        \\    zFinishPass(S, x, model, inst, sim);
        \\}}
        \\
    ++ finish_pass_txt, .{self.jobs.display_name});
}

/// Emits `eval` over `zResidual`: the §5.6 rows, emitted once and shared with
/// `evalQ`, which passes them its own core result.
fn emitEval(self: *Gen) Error!void {
    assert(!self.cur.core_hoisted);
    self.cur.core_wanted = false;
    self.cur.core_hoisted = true;
    // `model` and `inst` reach a row only through `core`, so the rows take
    // its result and not them.
    try self.w("/// §5.6 the resistive rows over the core result `m`: `eval` and `evalQ`.\n", .{});
    try self.w("inline fn zResidual(comptime S: type, ", .{});
    const at_x = self.out.items.len;
    try self.w("x: anytype, ", .{});
    const at_m = self.out.items.len;
    try self.w("m: anytype) contract.Rows(Self, S) {{\n    ", .{});
    const at_mut = self.out.items.len;
    try self.w("var   res: contract.Rows(Self, S) = zRowsZero(S);\n", .{});
    const stamps = try gen_stamps.emitStamps(self, false);
    assert(self.cur.core_hoisted);
    self.cur.core_hoisted = false;
    // `uses.x` also counts a row that reads `x` only through the core, so ask
    // the text: every direct read is `x[@intFromEnum(U.<name>)]`.
    if (std.mem.find(u8, self.out.items[at_mut..], "x[@intFromEnum(") == null) gen_unit.patchParam(self, at_x, "x".len);
    if (!self.cur.core_wanted) gen_unit.patchParam(self, at_m, "m".len);
    if (stamps == 0) self.out.items[at_mut..][0.."const".len].* = "const".*;
    try self.w("    return res;\n}}\n\n", .{});

    try self.w("/// §5.6 resistive residual: KCL at every unknown (§1.3.2)\n", .{});
    const st = gen_status.hasStatus(self);
    if (self.cur.core_wanted and (self.lowered.timepoints.items.len != 0 or st)) {
        // VerA's `vera_timepoint` (§2.9): the core result fills a stale cache.
        // §9.7.3 a status latches, and a latched one zeroes every row.
        const tp = if (self.lowered.timepoints.items.len != 0) "    zTpStore(inst, sim, m);\n" else "";
        if (st) try self.w(
            \\pub fn eval(comptime S: type, x: *const [n_u]S.V, model: *const Model, inst: InstancePtr, sim: contract.SimState) contract.Rows(Self, S) {{
            \\    var out: contract.Rows(Self, S) = zRowsZero(S);
            \\    if (inst.vera_status__ == 0) {{
            \\        const xs = zProbe(S, x);
            \\        const m = @call(.always_inline, core, .{{ S, xs, model, inst, sim{s} }});
            \\{s}        zStatusStore(inst, m);
            \\        if (inst.vera_status__ == 0) out = zResidual(S, xs, m);
            \\    }}
            \\
        ++ status_tail, .{ self.heldArg(false), tp8(self) }) else try self.w(
            \\pub fn eval(comptime S: type, x: *const [n_u]S.V, model: *const Model, inst: InstancePtr, sim: contract.SimState) contract.Rows(Self, S) {{
            \\    const xs = zProbe(S, x);
            \\    const m = @call(.always_inline, core, .{{ S, xs, model, inst, sim{s} }});
            \\{s}    return zResidual(S, xs, m);
            \\}}
            \\
            \\
        , .{ self.heldArg(false), tp });
    } else if (self.cur.core_wanted) {
        try self.w(
            \\pub fn eval(comptime S: type, x: *const [n_u]S.V, model: *const Model, inst: InstancePtr, sim: contract.SimState) contract.Rows(Self, S) {{
            \\
        , .{});
        try writeLead(self, "eval", "out");
        try self.w(
            \\    const xs = zProbe(S, x);
            \\    return zResidual(S, xs, @call(.always_inline, core, .{{ S, xs, model, inst, sim{s} }}));
            \\}}
            \\
            \\
        , .{self.heldArg(false)});
    } else try self.w(
        \\pub fn eval(comptime S: type, x: *const [n_u]S.V, _: *const Model, _: InstancePtr, _: contract.SimState) contract.Rows(Self, S) {{
        \\    return zResidual(S, zProbe(S, x), {{}});
        \\}}
        \\
        \\
    , .{});
}

/// VerA's `vera_timepoint` (§2.9) store inside a status guard's block.
fn tp8(self: *const Gen) []const u8 {
    assert(self.lowered.timepoints.items.len <= std.math.maxInt(u32));
    return if (self.lowered.timepoints.items.len != 0) "        zTpStore(inst, sim, m);\n" else "";
}

/// Emits `evalQ`: both §5.6/§5.6.1.2 residuals from one core evaluation,
/// where calling `eval` and `q` separately runs the model twice. `eval` and
/// `q` are unchanged; DC should keep calling `eval`. Emitted only when there
/// is a reactive half.
fn emitFused(self: *Gen) Error!void {
    assert(self.qs.sites.len != 0);
    assert(self.jac.on);
    try self.w(
        \\/// §5.6 + §5.6.1.2 both residuals from ONE core evaluation.
        \\/// Equivalent to `.{{ .res = eval(...), .q = q(...) }}`, at half the cost.
        \\pub fn evalQ(comptime S: type, x: *const [n_u]S.V, model: *const Model, inst: InstancePtr, sim: contract.SimState) struct {{ res: contract.Rows(Self, S), q: contract.Sites(Self, S) }} {{
        \\
    , .{});
    try writeLead(self, "evalQ", ".{ .res = out.res, .q = out.q }");
    const tp = if (self.lowered.timepoints.items.len != 0) "    zTpStore(inst, sim, m);\n" else "";
    if (gen_status.hasStatus(self)) {
        try self.w(
            \\    var res: contract.Rows(Self, S) = zRowsZero(S);
            \\    var qs: contract.Sites(Self, S) = zSitesZero(S);
            \\    if (inst.vera_status__ == 0) {{
            \\        const xs = zProbe(S, x);
            \\        const m = @call(.always_inline, core, .{{ S, xs, model, inst, sim{s} }});
            \\{s}        zStatusStore(inst, m);
            \\        if (inst.vera_status__ == 0) {{
            \\            res = zResidual(S, xs, m);
            \\            qs = 
        , .{ self.heldArg(false), tp8(self) });
        try dispatch_q.writeSites(self);
        try self.w(";\n        }}\n    }}\n    return .{{ .res = res, .q = qs }};\n}}\n\n", .{});
        return;
    }
    try self.w(
        \\    const xs = zProbe(S, x);
        \\    const m = @call(.always_inline, core, .{{ S, xs, model, inst, sim{s} }});
        \\{s}
    , .{ self.heldArg(false), tp });
    // §5.6.1.2 the charges, one per site, off the same core.
    try self.b("    return .{{ .res = zResidual(S, xs, m), .q = ", .{});
    try dispatch_q.writeSites(self);
    try self.b(" }};\n}}\n\n", .{});
}
