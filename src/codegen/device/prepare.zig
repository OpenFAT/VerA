//! Device planning: `Gen`'s inputs in, every device plan `Gen` holds out
//! (names, topology, filters, limits, noise, solve invariance, charge sites,
//! jobs, the shared core, array storage types, the timepoint map and the
//! setup roots), decided before a byte is written. Each step is one planner
//! call; the order is the data dependence between them, stated at each step.
//! Diagnostics a planner records (E0519/E0520 noise, E0531 timepoint) are
//! reported here, into `Gen.diags`.
//! Cites: §2.9, §3.2.2, §4.5.15, §4.6.4, §5.10, §5.6.1.2, §9.4.
//!
//! Contents:
//! - `pub fn prepare(g: *Gen) Error!void`
//! - members: `DynCtrl.isDynamic`

const std = @import("std");
const assert = std.debug.assert;
const Mir = @import("ir").Mir;
const plan_setup = @import("prove").setup;
const UnitPlan = @import("codegen/plan/unit.zig");
const plan_names = @import("codegen/plan/names.zig");
const plan_topo = @import("codegen/plan/topology.zig");
const plan_limit = @import("codegen/plan/limit.zig");
const plan_noise = @import("codegen/plan/noise.zig");
const plan_jobs = @import("codegen/plan/jobs.zig");
const plan_core = @import("codegen/plan/core.zig");
const plan_qsite = @import("codegen/plan/qsite.zig");
const gen_mask = @import("codegen/mask.zig");
const gen_family = @import("codegen/family.zig");
const gen_dispatch = @import("codegen/dispatch.zig");
const gen_instance = @import("codegen/instance.zig");
const gen_timepoint = @import("codegen/timepoint.zig");
const gen_setup = @import("codegen/setup.zig");
const gen_host = @import("codegen/host_expr.zig");
const cg_filters = @import("cg_filters.zig");
const cg_display = @import("cg_display.zig");
const Gen = @import("Gen.zig");
const Error = @import("codegen.zig").Error;

const none_u32 = std.math.maxInt(u32);

/// The one fact `plan_jobs` needs from the renderer: does a §4.5 control
/// argument (or §4.6.3 stimulus) render host-side, or only off the core?
const DynCtrl = struct {
    g: *Gen,
    /// Whether `v` renders only off the core (`host_expr.ctrlIsDynamic`).
    pub fn isDynamic(d: DynCtrl, v: Mir.Value) Error!bool {
        return gen_host.ctrlIsDynamic(d.g, v);
    }
};

/// Writes every device plan into `g`. Fails only on allocation, except that
/// a refused noise export or a varying timepoint read sets `g.any_fatal`
/// (and reports into `g.diags` when the caller kept a bag).
/// Asserts that nothing was emitted yet.
pub fn prepare(g: *Gen) Error!void {
    assert(g.out.items.len == 0);
    assert(g.files.len == 0);
    // The emitted Zig runs about 24 bytes per MIR instruction; one guess up
    // front saves a dozen doublings.
    try g.out.ensureTotalCapacity(g.gpa, g.mir.insts.len * 24 + 4096);
    // Per-unit scratch, owned by plan/unit.zig.
    g.cur.plan = try UnitPlan.init(g.arena, g.mir, g.an, g.display);
    try arrayLanes(g);
    g.names = try plan_names.plan(g.input(), g.verdict.unit_modes.len);
    g.mw = @intCast(@max(1, std.math.divCeil(u32, g.names.n_u, 64) catch unreachable));
    g.deps = try widen(g.arena, g.an.deps, g.an.dep_words, g.mw);
    g.acdyn = try widen(g.arena, g.an.acdyn, g.an.dep_words, g.mw);
    g.zero_mask = try gen_mask.zero(g.arena, g.mw);
    try gen_dispatch.alloc(g);
    try arrayMasks(g);
    // After `plan_names.plan`, which fills the `branch_u` that `freeFlows`
    // subtracts.
    g.topo = try plan_topo.plan(g.input(), g.names.branch_u);
    try cg_filters.planAll(g);
    // Before `plan_jobs`: §4.5.15 the algorithm arguments of every honoured
    // `$limit` become core live-outs, and the job list is what queues them.
    g.limits = try plan_limit.plan(g.input(), g.names.u_names);
    // Before `plan_jobs`: §4.6.4 the PSD arguments become core live-outs
    // too. After `plan_names.plan`: a generator in a potential contribution
    // sits on its branch current.
    g.noise = try plan_noise.plan(g.input(), g.names.branch_u);
    try reportNoise(g);
    try reportTimepoints(g);
    // Solve invariance first: the charge-site plan reads it to leave the
    // time-constant charges out of `q`, and the jobs queue what it keeps.
    g.sinv = try plan_setup.plan(g.input());
    g.qs = try plan_qsite.plan(g.input(), g.names.branch_u, g.topo, g.sinv.val);
    if (g.display == .record) g.say = try cg_display.planSay(g);
    if (g.display == .emit) try cg_display.planPasses(g);
    g.jobs = try plan_jobs.plan(g.input(), .{
        .names = &g.names,
        .unit_modes = g.verdict.unit_modes,
        .limits = g.limits.calls,
        .noise = &g.noise,
        .emit_display = g.display == .emit,
        .record_display = g.say.len != 0,
        .q_sites = g.qs.sites,
        .vpi = g.vpi_contribs,
    }, DynCtrl{ .g = g });
    g.core = try plan_core.plan(g.input(), g.jobs.list);
    narrowHeldLanes(g);
    // After the core planner, which is what fills them. Stable for the rest
    // of the compilation; `cached` reads them per unit.
    g.cur.plan.lo_idx = g.core.lo_idx;
    g.cur.plan.lo_vals = g.core.lo_vals;
    g.cur.plan.arr_lanes = g.arr_s;
    // Reads the full core's `lo_idx` and the final `arr_s`.
    g.tp_lo_idx = g.core.lo_idx;
    g.tp_of_block = try gen_timepoint.tpBlocks(g);
    // Last, and before any emission: the roots are what the core's slice
    // reaches, and `emitInstance` sizes `Setup` from them.
    try gen_setup.planSetup(g);
    assert(g.out.items.len == 0);
    assert(g.arr_s.len == g.lowered.mem_arrays.items.len);
}

// ---- private ----

/// §3.2.2 marks each `Lowered.mem_arrays` row whose storage carries a
/// derivative: some load reads a version a derivative-carrying store reached.
fn arrayLanes(g: *Gen) Error!void {
    g.arr_s = try g.arena.alloc(bool, g.lowered.mem_arrays.items.len);
    @memset(g.arr_s, false);
    if (g.arr_s.len == 0) return;
    for (g.an.i_op, 0..) |op, ii| {
        if (op != .fload) continue;
        const arr: Mir.Value = @fromBackingInt(@intCast(g.mir.insts.items(.a)[ii]));
        if (!g.an.dFree(arr)) g.arr_s[g.an.arrOf(arr).?] = true;
    }
    assert(g.arr_s.len == g.lowered.mem_arrays.items.len);
}

/// `col` (`words` words per value) at `mw` words per value: `col` itself when
/// `words == mw`, else a zero-extended copy from `arena`.
fn widen(arena: std.mem.Allocator, col: []const u64, words: u32, mw: u32) Error![]const u64 {
    assert(words <= mw);
    assert(words > 0);
    if (words == mw) return col;
    const n = col.len / words;
    const out = try gen_mask.zero(arena, @intCast(n * mw));
    for (0..n) |i| @memcpy(out[i * mw ..][0..words], col[i * words ..][0..words]);
    assert(out.len == n * mw);
    return out;
}

/// One storage holds every version of its array, so its elements are typed
/// by the union of their masks.
fn arrayMasks(g: *Gen) Error!void {
    g.arr_mask = try gen_mask.zero(g.arena, @intCast(g.arr_s.len * g.mw));
    if (g.arr_mask.len == 0) return;
    for (0..g.an.nv) |v| {
        const id = g.an.arrOf(@fromBackingInt(@intCast(v))) orelse continue;
        gen_mask.orIn(g.arrMask(id), gen_family.mask(g, @fromBackingInt(@intCast(v))));
    }
    assert(g.arr_mask.len == g.arr_s.len * g.mw);
}

/// Reports every §4.6.4 export `plan_noise` refused (E0519/E0520).
fn reportNoise(g: *Gen) Error!void {
    for (g.noise.refusals.items) |r| {
        assert(r.msg.len != 0);
        if (g.diags) |bag| try bag.add(.codegen, r.code, g.lowered.tokenSpan(r.tok), "{s}", .{r.msg});
        g.any_fatal = true;
    }
    if (g.noise.refusals.items.len != 0) assert(g.any_fatal);
}

/// VerA's `vera_timepoint` (§2.9): a cached statement may read nothing a
/// Newton iteration moves (E0531, labelled at the value's own token when it
/// has one).
fn reportTimepoints(g: *Gen) Error!void {
    for (g.lowered.timepoints.items) |t| {
        const v = try plan_setup.timepointVarying(g.input(), t) orelse continue;
        g.any_fatal = true;
        const bag = g.diags orelse continue;
        var d = bag.build(.codegen, .E0531, g.lowered.tokenSpan(t.tok));
        const def = g.mir.valueDef(v);
        const tok = if (def == .inst_result) g.mir.insts.items(.tok)[@backingInt(def.inst_result)] else Mir.no_tok;
        if (tok != Mir.no_tok) d.label(g.lowered.tokenSpan(tok), "this value can change between iterations", .{});
        try d.emit();
        assert(g.any_fatal);
    }
}

/// §5.10 a held array's storage carries a derivative only for a load
/// `eval`/`q` returns something from: the rest are read by the value-only
/// consumers (`updateState` and `acceptQ` read `.val()`), so the lanes such
/// a load would carry are never observed. Except by a §4.5.14 `ddx` in a
/// display task: the display unit is a consumer `eval_need` does not see,
/// and it reads lanes.
fn narrowHeldLanes(g: *Gen) void {
    const has_display = g.display == .emit or g.say.len != 0 or g.lowered.op_vars.items.len != 0;
    const display_ddx = has_display and for (g.an.i_op, 0..) |op, ii| {
        if (op == .call and g.mir.instData(@fromBackingInt(@intCast(ii))).call.callee == .ddx) break true;
    } else false;
    if (g.core.eval_need.len == 0 or display_ddx) return;
    assert(g.core.eval_need.len == g.an.nv);
    for (g.arr_s, 0..) |*s, id| {
        if (!s.* or g.lowered.mem_arrays.items[id].held == none_u32) continue;
        s.* = for (g.an.i_op, 0..) |op, ii| {
            if (op != .fload) continue;
            const arr: Mir.Value = @fromBackingInt(@intCast(g.mir.insts.items(.a)[ii]));
            if (g.an.arrOf(arr).? != id or g.an.dFree(arr)) continue;
            if (g.core.eval_need[@backingInt(g.an.rv(g.an.i_res[ii]))]) break true;
        } else false;
    }
}
