//! The honoured `$limit` sites' cold-start values (`plan/limit.zig`'s
//! `seed_steps` or its per-junction vcrit bias) -> the device's `seed` hook,
//! SPICE `MODEINITJCT`: the limited image a host starts the first iterate
//! from, before any solve.
//! Cites: §4.5.15, §9.17.3.
//!
//! Contents:
//! - `pub fn emit(g: *Gen) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Mir = @import("ir").Mir;
const cg = @import("codegen.zig");
const plan_limit = @import("codegen/plan/limit.zig");
const args = @import("cg_limit_args.zig");
const Gen = cg.Gen;
const Error = cg.Error;
const none_u32 = cg.none_u32;

/// Emits `seed`: every pnjlim-limited branch starts at its own `vcrit`, where
/// the exponential is still Newton-tractable, instead of at 0 V, where the
/// junction has no current and no conductance; under a seed tree each seeded
/// branch starts at its own value. `fetlim`/`limvds` get nothing: a channel
/// is well-conditioned at 0 V. Emits nothing when no branch is seeded.
/// Asserts that every site it seeds names its nodes.
/// Invalidates slices of `g.out.items`.
pub fn emit(g: *Gen) Error!void {
    if (g.limits.seed_tree) return emitTree(g);
    assert(g.limits.seed_steps.len == 0);
    var any = false;
    for (g.limits.calls) |lc| {
        if (lc.alg == .pnjlim and lc.argv[1] != .f_zero) any = true;
    }
    if (!any) return;
    const len_before = g.out.items.len;
    const needs_core = args.seedUsesCore(g);
    const reads_model = needs_core or args.anyArg(g, args.paramLeaf) or args.anyArg(g, args.isRoot);
    try g.w(
        \\/// SPICE `MODEINITJCT`: start every pnjlim-limited junction at its own
        \\/// `vcrit` rather than at 0 V, where the junction is invisible to Newton.
        \\///
        \\/// The core runs at x = 0, and that is not an approximation of the
        \\/// operating point — `seed` IS the x = 0 point, so it is the only
        \\/// information there is. Unlike `limit`, these writes are NOT masked by
        \\/// the host: they happen once, pre-solve, and the first linear solve
        \\/// re-imposes every source constraint over them.
        \\
    , .{});
    try emitHead(g, needs_core, reads_model);
    for (g.limits.calls) |lc| {
        if (lc.alg != .pnjlim or lc.argv[1] == .f_zero) continue;
        assert(lc.hi != none_u32);
        // The junction sits across `V(hi, lo)`, and only the internal side is
        // ours to place. Two clamps on the same net are the same junction seen
        // twice, so the later one's bias is as right as the earlier.
        // A signed clamp seeds V = sign·vcrit: the junction is forward at
        // NEGATIVE probe voltage when the sign argument is negative.
        const on_lo = g.limits.writable(lc.lo);
        if (lc.sign != .f_zero) {
            try g.w("    s[@intFromEnum(U.{s})] = if (", .{g.names.u_names[if (on_lo) lc.lo else lc.hi]});
            try args.writeArg(g, lc.sign, g.core.lo_idx);
            try g.w(" < 0) {s}", .{if (on_lo) "" else "-"});
            try args.writeArg(g, lc.argv[1], g.core.lo_idx);
            try g.w(" else {s}", .{if (on_lo) "-" else ""});
            try args.writeArg(g, lc.argv[1], g.core.lo_idx);
        } else if (on_lo) {
            try g.w("    s[@intFromEnum(U.{s})] = -", .{g.names.u_names[lc.lo]});
            try args.writeArg(g, lc.argv[1], g.core.lo_idx);
        } else {
            try g.w("    s[@intFromEnum(U.{s})] = ", .{g.names.u_names[lc.hi]});
            try args.writeArg(g, lc.argv[1], g.core.lo_idx);
        }
        try g.w("; // V({s},{s}) = {s}vcrit\n", .{
            plan_limit.uName(g.names.u_names, lc.hi), plan_limit.uName(g.names.u_names, lc.lo),
            if (lc.sign != .f_zero) "±" else "",
        });
    }
    try g.w("    return s;\n}}\n\n", .{});
    assert(g.out.items.len > len_before);
}

// ---- private ----

/// Emits the seed tree's `seed` (`plan/limit.zig` `planSeed`): the host's
/// limited image is node values, so each seeded branch is solved into them
/// down the tree from a root at 0 V. ngspice MODEINITJCT (mos1load.c:397-408)
/// seeds the branches instead: vgs = vto, vds = 0, vbs = -1.
fn emitTree(g: *Gen) Error!void {
    assert(g.limits.seed_tree);
    if (g.limits.seed_steps.len == 0) return;
    const len_before = g.out.items.len;
    const needs_core = args.seedUsesCore(g);
    var reads_param = false;
    var reads_root = false;
    for (g.limits.seed_steps) |st| {
        if (st.site == none_u32) continue;
        const lc = g.limits.calls[st.site];
        for ([_]Mir.Value{ args.seedValue(lc), lc.sign }) |v| {
            if (v == .f_zero) continue;
            reads_param = reads_param or args.paramLeaf(g, v);
            reads_root = reads_root or args.isRoot(g, v);
        }
    }
    try g.w(
        \\/// SPICE `MODEINITJCT` with `$limit`'s seed argument: each seeded branch starts at
        \\/// its own value (vcrit for a junction that names none), solved into node
        \\/// values from a root at 0 V. These are the instance's private limited
        \\/// image, and every lane written here is in `limit_writes`.
        \\
    , .{});
    try emitHead(g, needs_core, needs_core or reads_param or reads_root);
    for (g.limits.seed_steps) |st| {
        assert(st.node < g.names.n_u);
        const nn = g.names.u_names[st.node];
        if (st.site == none_u32) {
            try g.w("    s[@intFromEnum(U.{s})] = 0.0; // root\n", .{nn});
            continue;
        }
        const lc = g.limits.calls[st.site];
        // A step places one end of its own site's branch.
        assert(st.node == lc.hi or st.node == lc.lo);
        // lim(hi) = lim(lo) + sign·seed
        try g.w("    s[@intFromEnum(U.{s})] = ", .{nn});
        if (st.from == none_u32) try g.w("0.0", .{}) else try g.w("s[@intFromEnum(U.{s})].?", .{g.names.u_names[st.from]});
        try g.w(" {s} ", .{if (st.node == lc.hi) "+" else "-"});
        if (lc.sign != .f_zero) {
            try g.w("@as(f64, if (", .{});
            try args.writeArg(g, lc.sign, g.core.lo_idx);
            try g.w(" < 0) -1.0 else 1.0) * ", .{});
        }
        try g.w("(", .{});
        try args.writeArg(g, args.seedValue(lc), g.core.lo_idx);
        try g.w("); // V({s},{s}) = {s}\n", .{
            plan_limit.uName(g.names.u_names, lc.hi),   plan_limit.uName(g.names.u_names, lc.lo),
            if (lc.seed != .undef) "seed" else "vcrit",
        });
    }
    try g.w("    return s;\n}}\n\n", .{});
    assert(g.out.items.len > len_before);
}

/// Writes `seed`'s signature, the core call at x = 0 when a seed reads the
/// core, and the `s` it fills. The two `seed` forms share it byte for byte.
fn emitHead(g: *Gen, needs_core: bool, reads_model: bool) Error!void {
    if (needs_core) assert(reads_model);
    try g.w("pub fn seed(comptime {s}: type, {s}: *const Model, {s}: *const Instance, {s}: contract.SimState) [n_u]?f64 {{\n", .{
        if (needs_core) "S" else "_",
        if (reads_model) "model" else "_",
        if (needs_core) "inst" else "_",
        if (needs_core) "sim" else "_",
    });
    const probe_inst = if (needs_core) try g.probeInstance() else "inst";
    if (needs_core) try g.w(
        \\    const xr: [n_u]zOf(S, 0) = @splat(S.con(0.0));
        \\    const m = core(S, xr, model, {s}, sim{s});
        \\
    , .{ probe_inst, g.heldArg(true) });
    try g.w("    var s: [n_u]?f64 = @splat(null);\n", .{});
}
