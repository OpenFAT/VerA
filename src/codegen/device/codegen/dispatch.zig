//! Core live-outs -> the host entry points: `eval` (resistive), `q` (reactive,
//! one charge per site), `evalQ`, and the structural Jacobian tables
//! (`jac_pattern`, `q_pattern`, `ac_dyn_slots`, `deriv_reads`, `jac_const`)
//! from the evidence the stamps leave in `Jac`. Stamps follow §1.3.1.2
//! reference directions. The §4.6.3/§4.6.4 source tables are `noise.zig`.
//! LRM: §1.3.1.2, §2.9, §5.4.2.1, §5.4.3, §5.6, §5.6.1.2, §5.6.1.3, §5.6.6, §9.4.

const std = @import("std");
const plan_jac = @import("plan/jac.zig");
const plan_topo = @import("plan/topology.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_file = @import("file.zig");
const gen_instance = @import("instance.zig");
const gen_unit = @import("unit.zig");
const family = @import("family.zig");
const gen_mask = @import("mask.zig");
const Mir = @import("ir").Mir;
const Lower = @import("ir").Lowered;
const assert = std.debug.assert;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;

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

/// Past this many words an n_u × n_u bit table (`jac_pattern`, `q_pattern`,
/// `q_site_pattern`) is not emitted, and a host takes every row's lanes from
/// `deriv_reads` (`contract.rowMask`). ponytail: n² bits; 2^16 words is
/// 2048 unknowns. Sparse row lists are the upgrade if a bigger device needs
/// per-row lanes.
const max_table_words = 1 << 16;

/// Whether the n_u × n_u pattern tables are emitted (`max_table_words`).
fn tables(self: *const Gen) bool {
    return @as(usize, self.names.n_u) * self.mw <= max_table_words;
}

/// Allocates the lane masks the renderer writes (`deriv_reads`,
/// `ddx_reads`) on the arena. Runs once, after `Gen.mw` is known and before
/// any unit is rendered.
pub fn alloc(self: *Gen) Error!void {
    self.jac.deriv_reads = try gen_mask.zero(self.arena, self.mw);
    self.jac.ddx_reads = try gen_mask.zero(self.arena, self.mw);
}

/// Emits `eval`, and `q`/`evalQ`/the charge-site tables when any charge site
/// exists, then the pattern tables, `display` and (optionally) `vpiContribs`.
/// Allocates `jac.pat`, `jac.dpat`, `jac.rows` and `jac.lin` on the arena.
/// Runs once per device; asserts the evidence is still empty.
pub fn emitDispatchers(self: *Gen) Error!void {
    assert(!self.jac.on and self.jac.guarded.items.len == 0);
    const n = self.names.n_u;
    self.jac.on = true;
    for (&self.jac.pat, &self.jac.rows, &self.jac.lin) |*p, *r, *l| {
        if (tables(self)) p.* = try gen_mask.zero(self.arena, n * self.mw);
        r.* = try gen_mask.zero(self.arena, self.mw);
        l.* = try self.arena.alloc(plan_jac.LinRow, n);
        @memset(l.*, .empty);
    }
    if (tables(self) or self.acdyn.len != 0) self.jac.dpat = try gen_mask.zero(self.arena, n * self.mw);

    try emitEval(self);
    const any_q = anyQ(self);
    if (any_q) {
        qPattern(self);
        try emitQ(self);
        try emitFused(self);
        try emitQSites(self);
    }
    // After the dispatchers: the pattern is accumulated as each row is written.
    try emitPattern(self, any_q);
    try emitAcDyn(self, any_q);
    try emitDisplay(self);
    if (self.vpi_contribs) try emitVpiContribs(self);
}

/// Emits `vpiContribs` (`Options.vpi_contribs`): each §5.6 contribution's
/// resistive and reactive value at `x`, by `Lowered.contributions` index,
/// beside the row shape (access, the `U` of each terminal and of a potential
/// source's flow unknown, -1 for ground or none). A §11.6.7 flow-source flow
/// is its row value plus d/dt of the reactive half, which the host forms.
/// Reads `core` as `eval` and `q` do, so the numbers are the residual's own.
/// Then `vpiShares` and `vpi_share_row` when instances share a row.
fn emitVpiContribs(self: *Gen) Error!void {
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
    return if (n == Lower.ground) -1 else n;
}

/// Returns whether any charge site gets a slot, that is, whether `q` is emitted.
pub fn anyQ(self: *const Gen) bool {
    return self.qs.sites.len != 0;
}

/// Fills `q_pattern`/`q_rows` from the sites: row `ru` is written when a site
/// stamps it, and its columns are the union of those sites' dependences.
fn qPattern(self: *Gen) void {
    for (self.qs.stamps) |st| {
        const k = self.qs.sites[st.slot];
        const site = self.lowered.charge_sites.items[k].final;
        if (self.jac.pat[1].len != 0) gen_mask.orIn(rowOf(self, self.jac.pat[1], st.row), family.mask(self, site));
        if (self.jac.dpat.len != 0) gen_mask.orIn(rowOf(self, self.jac.dpat, st.row), family.acDyn(self, site));
        gen_mask.set(self.jac.rows[1], st.row);
    }
}

/// The core field holding slot `j`'s charge.
fn siteField(self: *const Gen, j: usize) u32 {
    const k = self.qs.sites[j];
    return self.core.lo_idx[@backingInt(self.an.rv(self.lowered.charge_sites.items[k].final))];
}

/// Writes a `contract.Sites(Self, S)` literal: every site's charge, in slot order.
pub fn writeSites(self: *Gen) Error!void {
    try self.b("@as(contract.Sites(Self, S), .{{", .{});
    for (0..self.qs.sites.len) |j| try self.b("{s}m.f{d}", .{ if (j == 0) " " else ", ", siteField(self, j) });
    try self.b(" }})", .{});
}

/// Emits `q`, the §5.6.1.2 reactive residual as one charge per site
/// (`plan/qsite.zig`). `q_stamps` says which rows each enters, so a host
/// integrates and truncation-checks each charge on its own.
fn emitQ(self: *Gen) Error!void {
    try self.w(
        \\/// §5.6.1.2 the charges, one per `ddt` site (`n_q`, `q_stamps`, `q_lte`);
        \\/// the host differentiates each and stamps it into its rows.
        \\pub fn q(comptime S: type, x: *const [n_u]S.V, model: *const Model, inst: InstancePtr, sim: contract.SimState) contract.Sites(Self, S) {{
        \\
    , .{});
    try writeLead(self, "q", "out");
    if (gen_instance.hasStatus(self)) {
        try self.w(
            \\    var out: contract.Sites(Self, S) = zSitesZero(S);
            \\    if (inst.vera_status__ == 0) {{
            \\        const m = @call(.always_inline, core, .{{ S, zProbe(S, x), model, inst, sim{s} }});
            \\        zStatusStore(inst, m);
            \\        if (inst.vera_status__ == 0) out = 
        , .{self.heldArg(false)});
        try writeSites(self);
        try self.w(";\n    }}\n" ++ status_tail, .{});
        return;
    }
    try self.w(
        \\    const m = @call(.always_inline, core, .{{ S, zProbe(S, x), model, inst, sim{s} }});
        \\
    , .{self.heldArg(false)});
    try self.w("    return ", .{});
    try writeSites(self);
    try self.w(";\n}}\n\n", .{});
}

/// Emits `n_q`, `q_stamps`, `q_lte` and `q_site_pattern` (`contract.QSites`).
fn emitQSites(self: *Gen) Error!void {
    try self.w(
        \\/// §5.6.1.2 how many charge sites `q` returns.
        \\pub const n_q: usize = {d};
        \\
        \\/// Row `row` of the reactive residual is `Σ sign · q[site]` over its
        \\/// entries. Sorted by (row, site).
        \\pub const q_stamps = [_]contract.QStamp(U){{
        \\
    , .{self.qs.sites.len});
    for (self.qs.stamps) |st| try self.w("    .{{ .site = {d}, .row = .{s}, .sign = {s} }},\n", .{
        st.slot, self.names.u_names[st.row], try gen_file.fmtF64(self, st.sign),
    });
    try self.w(
        \\}};
        \\
        \\/// Which charge sites join the host's local-truncation-error check
        \\/// (VerA's `vera_lte` attribute; all of them unless a model says so).
        \\pub const q_lte = [n_q]bool{{
    , .{});
    for (self.qs.sites, 0..) |k, j| try self.w("{s}{}", .{ if (j == 0) " " else ", ", self.lowered.charge_sites.items[k].lte });
    try self.w(" }};\n\n", .{});
    if (!tables(self)) return;
    var tb: [16]u8 = undefined;
    try self.w("/// Bit `cu` of `q_site_pattern[k]` is set when `∂q[k]/∂x[cu]` can be nonzero.\npub const q_site_pattern = [n_q]{s}{{\n", .{gen_mask.typeName(&tb, self.names.n_u)});
    for (self.qs.sites) |k| try self.w("    0x{f},\n", .{gen_mask.hex(family.mask(self, self.lowered.charge_sites.items[k].final), true)});
    try self.w("}};\n\n", .{});
}

/// Emits the §5.6 structural Jacobian: which columns of each residual row can
/// be nonzero, as a comptime constant so the host can drop the structurally
/// zero stamps, and which rows each half writes. The column tables only up
/// to `max_table_words`.
fn emitPattern(self: *Gen, any_q: bool) Error!void {
    if (tables(self)) {
        try self.w(
            \\/// §5.6 structural Jacobian: bit `cu` of `jac_pattern[ru]` is set
            \\/// when `∂eval(x)[ru]/∂x[cu]` can be nonzero. A clear bit is a
            \\/// stamp with no physics behind it, and the host may drop it at
            \\/// compile time. Over-approximate: a set bit costs a stamp that
            \\/// happens to be zero, never a missing matrix entry.
            \\
        , .{});
        try emitPatternRows(self, "jac_pattern", self.jac.pat[0]);
    }
    try emitWrittenRows(self, "jac_rows", "eval", self.jac.rows[0]);
    if (!any_q) return;
    if (tables(self)) {
        try self.w("/// Same, for `q`'s reactive residual (`dQ/dx`).\n", .{});
        try emitPatternRows(self, "q_pattern", self.jac.pat[1]);
    }
    try emitWrittenRows(self, "q_rows", "q", self.jac.rows[1]);
}

/// Emits `ac_dyn_slots` and `acDyn` (`contract.acDynSlots`) when a
/// frequency-dependent operator reaches a residual row.
fn emitAcDyn(self: *Gen, any_q: bool) Error!void {
    const n = self.names.n_u;
    if (self.jac.dpat.len == 0) return;
    // A mask has no bit at or past `n`, so its count is its slot count.
    var slots: std.ArrayList(u32) = try .initCapacity(self.arena, gen_mask.count(self.jac.dpat));
    for (0..n) |r| for (0..n) |c| {
        if (gen_mask.has(rowOf(self, self.jac.dpat, @intCast(r)), c)) slots.appendAssumeCapacity(@intCast(r * n + c));
    };
    std.debug.assert(slots.items.len == slots.capacity);
    if (slots.items.len == 0) return;
    try self.w(
        \\/// §4.5.7/§4.5.11/§4.5.12 the slots `row * n_u + col` whose small-signal
        \\/// value depends on frequency; `acDyn` supplies them (`contract.acDynSlots`).
        \\pub const ac_dyn_slots = [_]u32{{
    , .{});
    for (slots.items, 0..) |k, i| try self.w("{s}{d}", .{ if (i == 0) " " else ", ", k });
    try self.w(
        \\ }};
        \\
        \\/// Each `ac_dyn_slots` entry's complex term at `omega`, one per lane of `F`
        \\/// (`contract.acDynSlots`).
        \\pub fn acDyn(comptime F: type, model: *const Model, inst: InstancePtr, x: *const [n_u]f64, sim: contract.SimState, omega: F, out: *[ac_dyn_slots.len]std.math.Complex(F)) void {{
        \\    const S = zAc(F);
        \\    var xs = zProbe(S, x);
        \\    inline for (0..n_u) |u| xs[u].w = &omega;
        \\    const m = @call(.always_inline, core, .{{ S, xs, model, inst, sim{s} }});
        \\    const g = zResidual(S, xs, m);
        \\
    , .{self.heldArg(false)});
    if (any_q) {
        try self.b("    const c = contract.qRows(Self, S, ", .{});
        try writeSites(self);
        try self.b(");\n", .{});
    }
    try self.w(
        \\    inline for (ac_dyn_slots, 0..) |s, k| {{
        \\        const r = s / n_u;
        \\        const u = s % n_u;
        \\
    , .{});
    // A = G + jωC: the charge's complex lanes enter rotated by jω.
    if (any_q) try self.w(
        \\        const re = g[r].acRe(u) - omega * c[r].acIm(u);
        \\        const im = g[r].acIm(u) + omega * c[r].acRe(u);
        \\
    , .{}) else try self.w(
        \\        const re = g[r].acRe(u);
        \\        const im = g[r].acIm(u);
        \\
    , .{});
    try self.w(
        \\        out[k] = .{{ .re = re, .im = im }};
        \\    }}
        \\}}
        \\
        \\
    , .{});
}

/// Emits which §5.6 residual rows the half ever writes. A row outside the set
/// is zero at every bias, so a host may drop it whole. The host cannot infer
/// this from the pattern: a term with no unknown in it (an independent
/// current source) writes its row with a clear pattern.
fn emitWrittenRows(self: *Gen, name: []const u8, half: []const u8, mask: []const u64) Error!void {
    var tb: [16]u8 = undefined;
    try self.w(
        \\/// §5.6 which residual rows `{s}` ever WRITES: bit `ru` set means
        \\/// `res[ru]` is assigned somewhere in it. A CLEAR bit is the only
        \\/// licence to skip a row's stamp entirely — a clear PATTERN row is
        \\/// not, because a term that depends on no unknown writes the row
        \\/// with an empty column mask. Over-approximate the same way: a set
        \\/// bit costs a stamp that happens to be zero.
        \\pub const {s}: {s} = 0x{f};
        \\
        \\
    , .{ half, name, gen_mask.typeName(&tb, self.names.n_u), gen_mask.hex(mask, true) });
}

fn emitPatternRows(self: *Gen, name: []const u8, rows: []const u64) Error!void {
    var tb: [16]u8 = undefined;
    try self.w("pub const {s} = [n_u]{s}{{\n", .{ name, gen_mask.typeName(&tb, self.names.n_u) });
    for (0..self.names.n_u) |i| try self.w("    0x{f}, // {s}\n", .{ gen_mask.hex(rowOf(self, rows, @intCast(i)), true), self.names.u_names[i] });
    try self.w("}};\n\n", .{});
}

/// Emits `display`, the §9.4 entry point a host calls to run the module's
/// display tasks, or under `.record` the site table and `say`, the entry
/// point that records them (`contract.SaySite`). Separate from `eval` so the
/// host decides when text happens rather than getting it once per Newton
/// iteration. Not emitted under `display == .drop`. The unit's `S` result is
/// discarded.
fn emitDisplay(self: *Gen) Error!void {
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
            const at = gen_instance.srcLine(self, site.tok);
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
    self.core_wanted = false;
    self.core_hoisted = true;
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
    const stamps = try emitStamps(self, false);
    self.core_hoisted = false;
    // `uses.x` also counts a row that reads `x` only through the core, so ask
    // the text: every direct read is `x[@intFromEnum(U.<name>)]`.
    if (std.mem.find(u8, self.out.items[at_mut..], "x[@intFromEnum(") == null) gen_unit.patchParam(self, at_x, "x".len);
    if (!self.core_wanted) gen_unit.patchParam(self, at_m, "m".len);
    if (stamps == 0) self.out.items[at_mut..][0.."const".len].* = "const".*;
    try self.w("    return res;\n}}\n\n", .{});

    try self.w("/// §5.6 resistive residual: KCL at every unknown (§1.3.2)\n", .{});
    const st = gen_instance.hasStatus(self);
    if (self.core_wanted and (self.lowered.timepoints.items.len != 0 or st)) {
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
    } else if (self.core_wanted) {
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

/// Writes the lead loop an entry point opens with (`batch_lead`): a family
/// running the protocol (`S.Inner`) evaluates the batch once per leader,
/// merging each run's points that followed the leader's path, until every
/// point has run on its own. A scalar family skips it at compile time. The
/// first run is inlined and the re-runs (divergent batches) share one
/// out-of-line copy, so a coherent batch costs one inlined body.
fn writeLead(self: *Gen, call: []const u8, ret: []const u8) Error!void {
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

/// §9.7.3 a status device's entry points (`gen_instance.hasStatus`): a
/// latched status returns zero rows without running the core, and the core's
/// own report latches and does the same. One result variable, seeded zero,
/// and one return: an early `return` per guard left three copies of the
/// result in the GPU frame, the paths merged by a pointer phi that SROA
/// cannot split (bsimcmg's `evalQ`: 20.8 → 9.8 KB). `status_tail` closes it.
const status_tail = "    return out;\n}}\n\n";

/// VerA's `vera_timepoint` (§2.9) store inside a status guard's block.
fn tp8(self: *const Gen) []const u8 {
    return if (self.lowered.timepoints.items.len != 0) "        zTpStore(inst, sim, m);\n" else "";
}

/// Emits the §5.6 stamp rows for one residual half into a `res` the caller
/// has declared. Accumulates `uses.x`/`uses.model`/`uses.inst`, `jac.pat`, `jac.rows`
/// and `lin`, and returns the row count so the caller can back-patch its
/// signature. Opens a `core` call unless `core_hoisted` is set.
fn emitStamps(self: *Gen, react: bool) Error!u32 {
    var stamps: u32 = 0;
    // Which half `patRow` accumulates into. `eval`/`q` and `evalQ` emit the
    // same rows, so the second pass ORs in bits the first already set.
    self.jac.react = react;
    // `lin` is a replay, not an accumulation: `evalQ` re-emits the same
    // stamps, and adding them twice would double every coefficient. The
    // guarded stamps are eval-only (`emitSwitchRow`), so eval resets them.
    for (self.jac.lin[@intFromBool(react)]) |*l| l.clearRetainingCapacity();
    if (!react) self.jac.guarded.clearRetainingCapacity();
    // One core evaluation per residual, not one per contribution: LLVM does
    // not merge them (see `plan_core.plan`'s header).
    var opened = false;
    if (self.lowered.table_effect != .f_zero) {
        opened = true;
        self.uses.x = true;
        self.uses.model = true;
        self.uses.inst = true;
        self.core_wanted = true;
        if (!self.core_hoisted) try self.b("    const m = @call(.always_inline, core, .{{ S, x, model, inst, sim{s} }});\n", .{self.heldArg(false)});
        try self.b("    _ = m.f{d};\n", .{coreIdx(self, self.an.rv(self.lowered.table_effect)).?});
    }

    for (self.lowered.contributions.items, 0..) |c, i| {
        const val = if (react) self.an.rv(c.react_val) else self.an.rv(c.resist_val);
        self.jac.cur_dyn = try contribDyn(self, i, c, react);
        // §5.6.1.3 a `.flow` entry whose branch row is runtime-selected is
        // consumed by that row (`I_b − value`); its KCL current is the ±I_b
        // the potential entry already stamps. Stamping the value here too
        // would inject it twice.
        if (c.kind == .direct and c.access == .flow and plan_topo.flowIsMerged(self.input(), i)) continue;
        // §5.6.1.3's three-way rule is decided per cycle. `.on`/`.off` fold
        // statically; `.runtime` keeps the row alive in every case, because
        // the open-circuit form (`res[u] = I_b`) pins the branch current when
        // nothing is retained.
        const run_pot: ?plan_topo.Retention = if (c.kind == .direct and c.access == .potential) ret: {
            const r = plan_topo.retention(self.input(), c);
            break :ret if (r == .runtime) r else null;
        } else null;
        // A zero half normally contributes nothing, and §5.6.1.3's
        // `discardOpposite` relies on that: it writes `.f_zero` to BOTH
        // `acc.resist` and `acc.react`, so a discarded contribution still
        // emits no row at all, in either residual.
        //
        // The exception is the inductor. A §5.6 potential contribution's
        // resistive row `V(hi) - V(lo) - c` defines its branch flow unknown,
        // and the same row enters KCL at hi and lo (§1.3.1.2).
        // `V(l) <+ L*ddt(I(l))` has `resist_val == .f_zero` and a live
        // `react_val`; skipping it would leave the flow column with no pivot.
        // Only `c` is zero, and at DC `V(hi) - V(lo) = 0` is an inductor.
        //
        // A runtime-selected row's q half is live only when SOME selectable
        // form has a flux: its own react, or the switch partner's.
        const partner_react: Mir.Value = if (run_pot != null) blk: {
            const j = plan_topo.switchFlowOf(self.input(), i) orelse break :blk .f_zero;
            break :blk self.an.rv(self.lowered.contributions.items[j].react_val);
        } else .f_zero;
        const live = if (react)
            val != .f_zero or partner_react != .f_zero
        else
            val != .f_zero or run_pot != null or
                (c.access == .potential and self.an.rv(c.react_val) != .f_zero);
        if (!live) continue;
        self.uses.x = true;
        // `model`/`inst` are read through `core` alone, so a residual whose
        // every live row is zero never opens one (an unused parameter would
        // fail the host's build). A runtime-selected row always opens it: its
        // retention flag is a core field (`buildJobs`).
        if (val != .f_zero or run_pot != null) {
            self.uses.model = true;
            self.uses.inst = true;
            if (!opened) {
                opened = true;
                self.core_wanted = true;
                if (!self.core_hoisted) {
                    try self.ind(1);
                    try self.b("const m = @call(.always_inline, core, .{{ S, x, model, inst, sim{s} }});\n", .{self.heldArg(false)});
                }
            }
        }
        stamps += 1;
        try self.ind(1);
        try self.b("{{\n", .{});
        try self.ind(2);
        // `.f_zero` is rendered inline, never planned into `core` (see
        // `plan_core.plan`), so there is no `m.f<k>` to read for it.
        if (val == .f_zero)
            try self.b("const c = S.con(0.0);\n", .{})
        else
            try self.b("const c = m.f{d};\n", .{self.core.lo_idx[@backingInt(val)]});
        if (c.kind == .indirect) {
            // §5.6.7 nullor: `out` is driven by a source whose current is
            // the unknown `ib`, and the row is the constraint alone,
            // `<probe> − <equation>`, with no V(hi,lo) term: "the source
            // voltage needs to be adjusted so that the given equation is
            // satisfied". The ib column is filled only by the two KCL stamps.
            const u = self.names.branch_u[i];
            assert(!react); // splitContribution never runs on an indirect
            try self.ind(2);
            try self.b("const ib = x[@intFromEnum(U.{s})];\n", .{self.names.u_names[u]});
            try stamp(self, 2, c.hi, .add, "ib", try bits(self, &.{u}, &.{}), u);
            try stamp(self, 2, c.lo, .sub, "ib", try bits(self, &.{u}, &.{}), u);
            try self.ind(2);
            patRow(self, @intCast(u), family.mask(self, val));
            linClear(self, u);
            try rowSet(self, u);
            try self.b("c", .{});
            try rowEnd(self);
            try self.ind(1);
            try self.b("}}\n", .{});
            continue;
        }
        switch (c.access) {
            .flow => if (plan_topo.flowOnlySignalFlowNet(self.input(), c)) |n| {
                // §1.3.4.2 a flow signal-flow net has no potential, so its
                // one unknown is its flow and the contribution is that
                // unknown's defining equation. A KCL stamp here would write a
                // row with no `x` in it. See `flowOnlySignalFlowNet`.
                if (!react) {
                    try self.ind(2);
                    patRow(self, n, try bits(self, &.{n}, &.{family.mask(self, val)}));
                    linClear(self, n);
                    try linTerm(self, n, n, 1);
                    try rowSet(self, n);
                    try self.b("x[@intFromEnum(U.{s})].sub(c)", .{self.names.u_names[n]});
                    try rowEnd(self);
                } else {
                    try self.ind(2);
                    patRow(self, n, family.mask(self, val));
                    linClear(self, n);
                    try rowSet(self, n);
                    try self.b("c.neg()", .{});
                    try rowEnd(self);
                }
            } else {
                // §1.3.1.2: the value flows INTO hi and OUT OF lo.
                try stamp(self, 2, c.hi, .add, "c", family.mask(self, val), null);
                try stamp(self, 2, c.lo, .sub, "c", family.mask(self, val), null);
                // §5.6.6: the model also reads `I(hi,lo)`, so this current is
                // an unknown whose row is `x[u] − Σ contributions`. Accumulated
                // here (contributions to one branch are one sum, §5.6.1) and
                // closed with the `+ x[u]` term after the loop.
                if (self.topo.freeFlowOf(c.hi, c.lo)) |f| {
                    assert(f.sourced);
                    try stamp(self, 2, @intCast(f.u), .sub, "c", family.mask(self, val), null);
                }
            },
            .potential => {
                // §5.6 branch relation: the branch current is its own
                // unknown; its row carries V(hi,lo) − <value>.
                if (run_pot) |ret| {
                    try emitSwitchRow(self, i, c, ret.runtime, react);
                } else if (!react) {
                    const u = self.names.branch_u[i];
                    try self.ind(2);
                    try self.b("const ib = x[@intFromEnum(U.{s})];\n", .{self.names.u_names[u]});
                    try stamp(self, 2, c.hi, .add, "ib", try bits(self, &.{u}, &.{}), u);
                    try stamp(self, 2, c.lo, .sub, "ib", try bits(self, &.{u}, &.{}), u);
                    try self.ind(2);
                    patRow(self, @intCast(u), try bits(self, &.{ c.hi, c.lo }, &.{family.mask(self, val)}));
                    try linBranch(self, u, c.hi, c.lo);
                    try rowSet(self, u);
                    try nodeVoltage(self, c.hi);
                    try self.b(".sub(", .{});
                    try nodeVoltage(self, c.lo);
                    try self.b(").sub(c)", .{});
                    try rowEnd(self);
                } else {
                    const u = self.names.branch_u[i];
                    // §5.6.1.2 the reactive part of a branch relation is a
                    // flux: v − dφ/dt = 0 ⇒ q on this row is −φ.
                    try self.ind(2);
                    patRow(self, @intCast(u), family.mask(self, val));
                    linClear(self, u);
                    try rowSet(self, u);
                    try self.b("c.neg()", .{});
                    try rowEnd(self);
                }
            },
        }
        try self.ind(1);
        try self.b("}}\n", .{});
    }

    self.jac.cur_dyn = &.{};

    // §5.4.2 the branch-flow unknowns no branch row defines (`FreeFlow`).
    // Both rows are purely resistive: a §5.6.6 implicit sum's reactive half
    // is already on this row as `−Σ q`, and a §5.4.2.1 probe is a short,
    // which stores no charge.
    if (!react) for (self.topo.free_flows) |f| {
        self.uses.x = true;
        stamps += 1;
        if (f.sourced) {
            // Closes `res[u] = x[u] − Σ contributions`, whose `−Σ` half the
            // contribution loop accumulated.
            try self.ind(1);
            patRow(self, @intCast(f.u), try bits(self, &.{f.u}, &.{}));
            try linTerm(self, f.u, f.u, 1);
            try rowSet(self, f.u);
            try self.b("res[@intFromEnum(U.{0s})].add(x[@intFromEnum(U.{0s})])", .{self.names.u_names[f.u]});
            try rowEnd(self);
        } else {
            // §5.4.2.1 "The branch potential of a flow probe is zero (0)",
            // the ammeter of Figure 5-1. Its current enters KCL at both ends,
            // which makes it a short rather than an observation.
            try stamp(self, 1, f.hi, .add, try self.arena.print("x[@intFromEnum(U.{s})]", .{self.names.u_names[f.u]}), try bits(self, &.{f.u}, &.{}), f.u);
            try stamp(self, 1, f.lo, .sub, try self.arena.print("x[@intFromEnum(U.{s})]", .{self.names.u_names[f.u]}), try bits(self, &.{f.u}, &.{}), f.u);
            try self.ind(1);
            patRow(self, @intCast(f.u), try bits(self, &.{ f.hi, f.lo }, &.{}));
            try linBranch(self, f.u, f.hi, f.lo);
            try rowSet(self, f.u);
            try nodeVoltage(self, f.hi);
            try self.b(".sub(", .{});
            try nodeVoltage(self, f.lo);
            try self.b(")", .{});
            try rowEnd(self);
        }
    };

    // §5.4.3 `I(<p>)` = "the flow into a port of a module". By KCL that is
    // exactly what this module has just stamped at p, so the row reuses the
    // accumulation above instead of restating it:
    //
    //     eval:  res[flow(<p>)] = x[flow(<p>)] − res[p]
    //     q:     res[flow(<p>)] =              − res[p]
    //
    // Total residual x − (I_dc + d/dt q_p) = 0, so the reactive half of the
    // port current comes along: §5.4.3's own diode example probes a node
    // with a `ddt` junction capacitance. Emitted after the contribution loop
    // because it reads the finished res[p].
    for (self.lowered.port_probes.items) |pp| {
        self.uses.x = true;
        stamps += 1;
        try self.ind(1);
        // Reads the finished res[port], so this row's columns are that row's.
        patRow(self, pp.u, try bits(self, if (react) &.{} else &.{pp.u}, &.{try patOf(self, pp.port)}));
        if (self.jac.dpat.len != 0) gen_mask.orIn(rowOf(self, self.jac.dpat, pp.u), rowOf(self, self.jac.dpat, pp.port));
        try linPortProbe(self, pp.u, pp.port, !react);
        if (react) {
            try rowSet(self, pp.u);
            try self.b("res[@intFromEnum(U.{s})].neg()", .{self.names.u_names[pp.port]});
            try rowEnd(self);
        } else {
            try rowSet(self, pp.u);
            try self.b("x[@intFromEnum(U.{0s})].sub(res[@intFromEnum(U.{1s})])", .{
                self.names.u_names[pp.u], self.names.u_names[pp.port],
            });
            try rowEnd(self);
        }
    }

    return stamps;
}

/// Emits `evalQ`: both §5.6/§5.6.1.2 residuals from one core evaluation,
/// where calling `eval` and `q` separately runs the model twice. `eval` and
/// `q` are unchanged; DC should keep calling `eval`. Emitted only when there
/// is a reactive half.
fn emitFused(self: *Gen) Error!void {
    try self.w(
        \\/// §5.6 + §5.6.1.2 both residuals from ONE core evaluation.
        \\/// Equivalent to `.{{ .res = eval(...), .q = q(...) }}`, at half the cost.
        \\pub fn evalQ(comptime S: type, x: *const [n_u]S.V, model: *const Model, inst: InstancePtr, sim: contract.SimState) struct {{ res: contract.Rows(Self, S), q: contract.Sites(Self, S) }} {{
        \\
    , .{});
    try writeLead(self, "evalQ", ".{ .res = out.res, .q = out.q }");
    const tp = if (self.lowered.timepoints.items.len != 0) "    zTpStore(inst, sim, m);\n" else "";
    if (gen_instance.hasStatus(self)) {
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
        try writeSites(self);
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
    try writeSites(self);
    try self.b(" }};\n}}\n\n", .{});
}

/// Emits the §5.6.1.3 runtime-selected branch row: §5.6.5's switch branch,
/// and the clause's "otherwise the branch is an open circuit" case for a lone
/// conditional potential contribution.
///
/// The matrix structure stays constant: the branch always carries its flow
/// unknown I_b, stamped ±I_b into the two KCL rows, and only the branch row's
/// content is selected per cycle on the retention flags:
///
///     V retained this cycle:  res[u] = V(hi) − V(lo) − c_V   (potential source)
///     else I retained:        res[u] = I_b − c_I             (flow source)
///     else:                   res[u] = I_b                   (open: pins I_b = 0)
///
/// `S.sel` carries the winner's dual, so the Jacobian switches coherently
/// with the row: ±1 on the node columns for the potential form, 1 on the
/// I_b column (and −∂c_I/∂x) for the flow form, a bare 1 on I_b for the
/// open circuit, so never singular. In the q residual the same select runs
/// over the fluxes (−φ, §5.6.1.2), the open case contributing none.
///
/// The flow form's ±c_I KCL stamps are not emitted (`flowIsMerged`): the
/// retained flow reaches KCL through I_b, which the row pins to c_I.
///
/// A collapsible branch (`collapsePairs`) is the exception: `collapse`
/// deletes I_b from the host's maps, so the row is split on the retention
/// flag, a `buildFree` value fixed for the whole simulation (a real `if`):
///
///   flag set (0 V arm, dead short): the host aliased hi, lo and I_b onto
///     one unknown, so ±I_b and `V(hi) − V(lo)` would add and subtract the
///     same slot, and float addition there is not exact. A host that applied
///     the aliases gets no stamps; one that did not keeps the full equations.
///   flag clear: I_b does not exist. The branch is a plain conductance whose
///     flow reaches KCL directly, like an unswitched `.flow` (`switchOpen`).
///
/// The guard (`contract.JacWhen`): when the flag depends on the card alone
/// (`CollapsePair.card`), the flag-set arm's coefficients (±1) are constants
/// per card and leave as `jac_const` entries guarded by the published `Model`
/// field, so ib keeps no lane. Any other runtime row keeps every lane.
fn emitSwitchRow(self: *Gen, i: usize, c: Lower.Contribution, flag: Mir.Value, react: bool) Error!void {
    const u = self.names.branch_u[i];
    const partner = plan_topo.switchFlowOf(self.input(), i);
    const split = collapsible(self, i);
    const guard = guardOf(self, i);
    // Every coefficient on this row, and ib's in KCL, is picked per cycle by
    // a runtime flag, so every unknown it names keeps a lane, as does
    // whatever the row held before, unless the guard states them.
    if (guard) |k| {
        if (!react) {
            try guardTerm(self, c.hi, u, 1, k);
            try guardTerm(self, c.lo, u, -1, k);
            try guardTerm(self, u, c.hi, 1, k);
            try guardTerm(self, u, c.lo, -1, k);
        }
    } else gen_mask.orIn(self.jac.deriv_reads, try bits(self, &.{ u, c.hi, c.lo }, &.{}));
    linDynamic(self, u);
    const d: u32 = if (split) 4 else 2;
    if (split) {
        try self.ind(2);
        try self.b("if (", .{});
        try coreRef(self, flag);
        if (self.an.vty[@backingInt(self.an.rv(flag))] == .int)
            try self.b(" != 0) {{\n", .{})
        else
            try self.b(".val() != 0.0) {{\n", .{});
        try self.ind(3);
        try self.b("if (comptime !(@hasDecl(S, \"collapse_applied\") and S.collapse_applied)) {{\n", .{});
    }
    if (!react) {
        try self.ind(d);
        try self.b("const ib = x[@intFromEnum(U.{s})];\n", .{self.names.u_names[u]});
        // Guarded: the constant is `guardTerm`'s, not an unconditional `lin`.
        const col: ?u32 = if (guard == null) u else null;
        try stamp(self, d, c.hi, .add, "ib", try bits(self, &.{u}, &.{}), col);
        try stamp(self, d, c.lo, .sub, "ib", try bits(self, &.{u}, &.{}), col);
        try self.ind(d);
        patRow(self, @intCast(u), try bits(self, &.{ u, c.hi, c.lo }, &.{try switchRowDeps(self, i, c, react)}));
        try rowSet(self, u);
        try self.b("S.sel(", .{});
        try coreRef(self, flag);
        try self.b(", ", .{});
        try nodeVoltage(self, c.hi);
        try self.b(".sub(", .{});
        try nodeVoltage(self, c.lo);
        try self.b(").sub(c), ", .{});
        try switchElse(self, partner, react);
        try self.b(")", .{});
        try rowEnd(self);
    } else {
        try self.ind(d);
        patRow(self, @intCast(u), try bits(self, &.{u}, &.{try switchRowDeps(self, i, c, react)}));
        try rowSet(self, u);
        try self.b("S.sel(", .{});
        try coreRef(self, flag);
        try self.b(", c.neg(), ", .{});
        try switchElse(self, partner, react);
        try self.b(")", .{});
        try rowEnd(self);
    }
    if (split) {
        try self.ind(3);
        try self.b("}}\n", .{});
        try self.ind(2);
        try self.b("}} else {{\n", .{});
        try self.ind(3);
        try self.b("const flow = ", .{});
        try switchOpen(self, partner, react);
        try self.b(";\n", .{});
        const deps = try switchRowDeps(self, i, c, react);
        try stamp(self, 3, c.hi, .add, "flow", deps, null);
        try stamp(self, 3, c.lo, .sub, "flow", deps, null);
        try self.ind(2);
        try self.b("}}\n", .{});
    }
}

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

/// Returns whether `collapse` aliases potential contribution `i` away. Keyed on the
/// branch-flow unknown, which `contribIndex` makes unique per branch.
pub fn collapsible(self: *const Gen, i: usize) bool {
    const u = self.names.branch_u[i];
    return u != none_u32 and self.topo.collapsible(u);
}

/// Returns the `cpairs` index whose card-only flag guards contribution `i`'s
/// constants (`emitSwitchRow`), or null.
fn guardOf(self: *const Gen, i: usize) ?u32 {
    const u = self.names.branch_u[i];
    if (u == none_u32) return null;
    for (self.topo.cpairs, 0..) |p, k| if (p.flow_u == u) return if (p.card) @intCast(k) else null;
    return null;
}

/// One guarded constant: `g` at (row, col) of eval, under pair `k`'s guard.
/// Ground has no row and no column.
fn guardTerm(self: *Gen, row: u32, col: u32, g: f64, k: u32) Error!void {
    if (row == Lower.ground or col == Lower.ground) return;
    try self.jac.guarded.append(self.arena, .{ .row = row, .col = col, .g = g, .c = 0, .when = k });
}

/// Returns `<flow unknown>__retained`: the `Model` field `derive` publishes
/// pair `k`'s retention flag in, and the name a guarded `jac_const` entry cites.
pub fn guardField(self: *const Gen, k: u32) Error![]const u8 {
    return self.arena.print("{s}__retained", .{self.names.u_names[self.topo.cpairs[k].flow_u]});
}

/// The value the branch row would have PINNED I_b to, for the arm where
/// I_b no longer exists: the partner's retained flow, or zero when nothing
/// is retained (§5.6.1.3's open circuit). `switchElse` writes the same
/// cases as a residual (`I_b − c` and `−φ`); this is that residual solved
/// for I_b, so the signs are the plain `.flow` stamp's.
fn switchOpen(self: *Gen, partner: ?usize, react: bool) Error!void {
    const j = partner orelse return self.b("S.con(0.0)", .{});
    const f = self.lowered.contributions.items[j];
    const fv = self.an.rv(if (react) f.react_val else f.resist_val);
    switch (plan_topo.retention(self.input(), f)) {
        .off => try self.b("S.con(0.0)", .{}),
        .on => try coreRef(self, fv),
        .runtime => |fw| {
            try self.b("S.sel(", .{});
            try coreRef(self, fw);
            try self.b(", ", .{});
            try coreRef(self, fv);
            try self.b(", S.con(0.0))", .{});
        },
    }
}

/// The not-a-potential-source-this-cycle half of a selected branch row:
/// the flow form when the switch partner retained one, the open circuit
/// otherwise. `react` picks the residual: I_b/current for eval, flux for q.
fn switchElse(self: *Gen, partner: ?usize, react: bool) Error!void {
    const open: []const u8 = if (react) "S.con(0.0)" else "ib";
    const j = partner orelse return self.b("{s}", .{open});
    const f = self.lowered.contributions.items[j];
    const fv = self.an.rv(if (react) f.react_val else f.resist_val);
    switch (plan_topo.retention(self.input(), f)) {
        // Discarded on every path: the partner entry is dead and the else
        // case is §5.6.1.3's open circuit.
        .off => try self.b("{s}", .{open}),
        // Unreachable by construction (a runtime potential flag implies a
        // conditional discard of the partner), but the general form is
        // correct if lowering ever changes: the flow is always retained.
        .on => if (react) {
            try coreRef(self, fv);
            try self.b(".neg()", .{});
        } else {
            try self.b("ib.sub(", .{});
            try coreRef(self, fv);
            try self.b(")", .{});
        },
        .runtime => |fw| {
            try self.b("S.sel(", .{});
            try coreRef(self, fw);
            if (react) {
                try self.b(", ", .{});
                try coreRef(self, fv);
                try self.b(".neg(), {s})", .{open});
            } else {
                try self.b(", ib.sub(", .{});
                try coreRef(self, fv);
                try self.b("), {s})", .{open});
            }
        },
    }
}

/// One value as the residual reads it: a core field, or the inline zero
/// `plan_core.plan` never plans (`.f_zero` has no `m.f<k>`).
fn coreRef(self: *Gen, v: Mir.Value) Error!void {
    if (v == .f_zero) return self.b("S.con(0.0)", .{});
    try self.b("m.f{d}", .{self.core.lo_idx[@backingInt(v)]});
}

/// A stamp's sign; its tag names are the emitted row methods `.add`/`.sub`.
const StampSign = enum { add, sub };

/// Emits one term into row `node`: `sign` (`add`/`sub`) of `val`, recording
/// `bits` in the row pattern. `col` names the unknown when `val` is exactly `x[col]` (a ±1 term
/// whose coefficient `Gen.jac.lin` records), and is null for a core value, whose
/// lanes `renderValueRef` already marked. Ground has no row and writes nothing.
pub fn stamp(self: *Gen, depth: u32, node: u32, sign: StampSign, val: []const u8, deps: []const u64, col: ?u32) Error!void {
    if (node == Lower.ground) return; // §1.3.1.1 ground has no equation
    patRow(self, node, deps);
    if (col) |k| try linTerm(self, node, k, switch (sign) {
        .add => 1,
        .sub => -1,
    });
    try self.ind(depth);
    try rowSet(self, node);
    try self.b("res[@intFromEnum(U.{s})].{s}({s})", .{ self.names.u_names[node], @tagName(sign), val });
    try rowEnd(self);
}

/// `res[@intFromEnum(U.<u>)] = zRow(S, .<u>, `: row `u` is typed by its
/// pattern (`contract.rowMask`), so every value assigned to it widens there.
/// `rowEnd` closes it.
fn rowSet(self: *Gen, u: u32) Error!void {
    const n = self.names.u_names[u];
    try self.b("res[@intFromEnum(U.{s})] = ", .{n});
    try self.b("zRow(S, .{s}, ", .{n});
}

fn rowEnd(self: *Gen) Error!void {
    try self.b(");\n", .{});
}

/// Records that row `node` of the half being emitted (`jac.react`) gained a
/// term whose derivative lives in `deps`, and that the row is written at all
/// (`rows`). Ground has no row. Every `res[...]` writer calls this.
fn patRow(self: *Gen, node: u32, deps: []const u64) void {
    if (node == Lower.ground or !self.jac.on) return;
    const half = self.jac.pat[@intFromBool(self.jac.react)];
    if (half.len != 0) gen_mask.orIn(rowOf(self, half, node), deps);
    // A superset: a stamp of `x[u]` itself (an `ib`) is marked when the
    // contribution reaches `u` through an operator too.
    if (self.jac.cur_dyn.len != 0 and self.jac.dpat.len != 0) for (rowOf(self, self.jac.dpat, node), self.jac.cur_dyn, deps) |*d, c, b| {
        d.* |= c & b;
    };
    gen_mask.set(self.jac.rows[@intFromBool(self.jac.react)], node);
}

/// Row `r` of a per-row mask table (`jac.pat`, `jac.dpat`): `Gen.mw` words.
fn rowOf(self: *const Gen, table: anytype, r: u32) @TypeOf(table) {
    return table[r * self.mw ..][0..self.mw];
}

/// Returns, from the arena, the mask of unknowns `us` (ground skipped,
/// `none_u32` every unknown) ORed with `deps`.
pub fn bits(self: *const Gen, us: []const u32, deps: []const []const u64) Error![]const u64 {
    const m = try gen_mask.zero(self.arena, self.mw);
    for (us) |u| {
        if (u == Lower.ground) continue;
        if (u == none_u32) {
            for (0..self.names.n_u) |k| gen_mask.set(m, @intCast(k));
            continue;
        }
        gen_mask.set(m, u);
    }
    for (deps) |d| gen_mask.orIn(m, d);
    return m;
}

/// Records that row `row` of the half being emitted gains `k · x[col]`. The
/// `lin*` writers mirror the `res[...]` text beside them as `patRow` does:
/// only a ±1 on an unknown is recorded; every other term is a core value
/// whose lanes are already marked.
fn linTerm(self: *Gen, row: u32, col: u32, k: f64) Error!void {
    if (row == Lower.ground or col == Lower.ground) return;
    const l = self.jac.lin[@intFromBool(self.jac.react)];
    if (l.len == 0) return;
    for (l[row].items) |*t| if (t.col == col) {
        t.k += k;
        return;
    };
    try l[row].append(self.arena, .{ .col = col, .k = 0 + k });
}

/// Records that row `row` is assigned a term with no recorded unknown in it.
fn linClear(self: *Gen, row: u32) void {
    const l = self.jac.lin[@intFromBool(self.jac.react)];
    if (l.len == 0) return;
    l[row].clearRetainingCapacity();
    // Its guarded constants go with the assignment too.
    if (self.jac.react) return;
    var k: usize = 0;
    while (k < self.jac.guarded.items.len) {
        if (self.jac.guarded.items[k].row == row) _ = self.jac.guarded.orderedRemove(k) else k += 1;
    }
}

/// Records that row `row` is assigned `V(hi) − V(lo) − <core value>`: §5.6's branch
/// relation, and §5.4.2.1's zero-potential flow probe.
fn linBranch(self: *Gen, row: u32, hi: u32, lo: u32) Error!void {
    linClear(self, row);
    try linTerm(self, row, hi, 1);
    try linTerm(self, row, lo, -1);
}

/// Records §5.4.3 `res[u] = x[u] − res[port]` (eval) or `−res[port]` (q):
/// the row is the finished port row negated, so its constants are too.
fn linPortProbe(self: *Gen, u: u32, port: u32, with_x: bool) Error!void {
    const l = self.jac.lin[@intFromBool(self.jac.react)];
    if (l.len == 0) return;
    assert(u != port);
    l[u].clearRetainingCapacity();
    for (l[port].items) |t| try l[u].append(self.arena, .{ .col = t.col, .k = -t.k });
    if (with_x) try linTerm(self, u, u, 1);
    // The port row's guarded constants are copied too, under the same guard
    // (`emitSwitchRow`): they are eval-only, and each is appended once per row.
    if (self.jac.react) return;
    const k0 = self.jac.guarded.items.len;
    for (0..k0) |k| {
        const e = self.jac.guarded.items[k];
        if (e.row != port) continue;
        try self.jac.guarded.append(self.arena, .{ .row = u, .col = e.col, .g = 0 - e.g, .c = 0 - e.c, .when = e.when });
    }
}

/// Records that row `row` is about to be written under a runtime condition:
/// its constants may not survive, so each of their columns keeps a lane.
fn linDynamic(self: *Gen, row: u32) void {
    const l = self.jac.lin[@intFromBool(self.jac.react)];
    if (l.len == 0) return;
    for (l[row].items) |t| {
        if (t.k != 0) gen_mask.set(self.jac.deriv_reads, t.col);
    }
}

/// Emits `deriv_reads`, `ddx_reads` and `jac_const` (`contract.derivReads`).
/// Must run after every unit and residual is written, since all three are
/// read off them. Sound because an unknown's lane matters only if emitted
/// text reads `x[u]` or `.ddxAt(u)`: `renderValueRef` marks every read in a
/// core or unit, `ddx` marks `ddx_reads`, and the dispatcher marks every
/// unknown under a runtime-selected row. An unmarked unknown is read only in
/// the dispatcher's unconditional ±1 stamps, which `lin` replays exactly.
pub fn emitDerivReads(self: *Gen, limit_writes: []const u64) Error!void {
    const jc = try plan_jac.plan(self.arena, self.names.n_u, self.jac.deriv_reads, self.jac.ddx_reads, limit_writes, .{ self.jac.lin[0], self.jac.lin[1] }, self.jac.guarded.items);
    var tb: [16]u8 = undefined;
    const ty = gen_mask.typeName(&tb, self.names.n_u);
    try self.w(
        \\/// Unknowns whose derivative lane `eval`/`q` read. Every other
        \\/// column's partials are constants, listed in `jac_const`; see
        \\/// `contract.derivReads`.
        \\pub const deriv_reads: {s} = 0x{f};
        \\
        \\/// The lanes §4.5.14 `ddx` reads by unknown index through `ddxAt`;
        \\/// see `contract.ddxReads`.
        \\pub const ddx_reads: {s} = 0x{f};
        \\
        \\/// The exact constant partials of the columns outside `deriv_reads`:
        \\/// `g` of `eval`, `c` of `q`. Sorted by (row, col); absent is 0.
        \\pub const jac_const = [_]contract.JacConst(U){{
        \\
    , .{ ty, gen_mask.hex(jc.mask, true), ty, gen_mask.hex(self.jac.ddx_reads, true) });
    for (jc.entries) |e| {
        try self.w("    .{{ .row = .{s}, .col = .{s}, .g = {s}, .c = {s}", .{
            self.names.u_names[e.row], self.names.u_names[e.col], try gen_file.fmtF64(self, e.g), try gen_file.fmtF64(self, e.c),
        });
        if (e.when) |k| try self.w(", .when = .{{ .flag = \"{s}\", .collapse_open = true }}", .{try guardField(self, k)});
        try self.w(" }},\n", .{});
    }
    try self.w("}};\n\n", .{});
    try family.emitLaneMasks(self, jc.mask);
}

/// The columns accumulated so far on row `u` of the half being emitted;
/// every column before the dispatchers allocate the patterns.
fn patOf(self: *const Gen, u: u32) Error![]const u64 {
    const half = self.jac.pat[@intFromBool(self.jac.react)];
    return if (half.len == 0) bits(self, &.{none_u32}, &.{}) else rowOf(self, half, u);
}

/// Returns the columns contribution `i`'s rows reach through a
/// frequency-dependent operator: its value's, and a §5.6.5 switch partner's,
/// whose value the same row selects (`switchRowDeps`). Empty for none.
fn contribDyn(self: *const Gen, i: usize, c: Lower.Contribution, react: bool) Error![]const u64 {
    if (self.acdyn.len == 0) return &.{};
    const own = family.acDyn(self, if (react) c.react_val else c.resist_val);
    const j = plan_topo.switchFlowOf(self.input(), i) orelse return own;
    const f = self.lowered.contributions.items[j];
    return bits(self, &.{}, &.{ own, family.acDyn(self, if (react) f.react_val else f.resist_val) });
}

/// Returns the columns of the row `emitSwitchRow` emits. The `S.sel` arm is
/// chosen at run time, so the row carries every arm's columns: its own
/// value, the switch partner's, and `ib`.
fn switchRowDeps(self: *const Gen, i: usize, c: Lower.Contribution, react: bool) Error![]const u64 {
    const own = family.mask(self, if (react) c.react_val else c.resist_val);
    const j = plan_topo.switchFlowOf(self.input(), i) orelse return bits(self, &.{self.names.branch_u[i]}, &.{own});
    const f = self.lowered.contributions.items[j];
    return bits(self, &.{self.names.branch_u[i]}, &.{ own, family.mask(self, if (react) f.react_val else f.resist_val) });
}

fn nodeVoltage(self: *Gen, node: u32) Error!void {
    if (node == Lower.ground) return self.b("S.con(0.0)", .{});
    try self.b("x[@intFromEnum(U.{s})]", .{self.names.u_names[node]});
}

/// Returns the core field holding `v`, or null when `v` is rendered inline
/// (structurally zero, or a constant `plan_core.plan` never carries).
pub fn coreIdx(self: *const Gen, v: Mir.Value) ?u32 {
    if (v == .f_zero) return null;
    const k = self.core.lo_idx[@backingInt(v)];
    return if (k == none_u32) null else k;
}
