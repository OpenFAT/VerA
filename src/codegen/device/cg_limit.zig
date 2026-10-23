//! Honoured `$limit(V(a,b), "alg", args…)` sites -> the device's `limit` hook
//! (one clamp per site, writing a corrected `x`) and the slice of the core its
//! arguments need, `limit_reads`/`limit_writes`, and the cold-start `seed`
//! (SPICE MODEINITJCT). A §9.17.1 `$discontinuity(-1)` request is `limit`'s
//! `converged` verdict, read off the same slice. LRM §4.5.15, §9.17.1, §9.17.3.
//! The host clamps `x` before `eval`, so `eval` renders the string form as the
//! identity of its probe; a second clamp would use the wrong `x_old`. The
//! user-function form is lowered instead. Limiters live in `limit_kernels.zig`.

const std = @import("std");
const Mir = @import("ir").Mir;
const Analysis = @import("prove").Analysis;
const cg = @import("codegen.zig");
const gen_unit = @import("codegen/unit.zig");
const Gen = cg.Gen;
const Error = cg.Error;
// The pure half: which sites are honoured, and the questions both halves ask.
const plan_limit = @import("codegen/plan/limit.zig");
const gen_mask = @import("codegen/mask.zig");
const LimitCall = plan_limit.LimitCall;
const Ladder = plan_limit.Ladder;
const Rung = plan_limit.Rung;

const none_u32 = cg.none_u32;

// -------------------------------------------------------- the live sets

/// Which unknowns `limit` touches: `reads` is every `cur[u]`/`old[u]` the body
/// loads, `writes` every `x[u]` it or `seed` can store. The host uses them to
/// skip gathering and storing unknowns the clamps never see (a MOS ladder reads
/// four of eight and writes two).
///
/// Both masks must stay supersets: a missing `reads` bit hands a clamp an
/// undefined probe, a missing `writes` bit silently drops a limit. `unionSite`
/// mirrors `emitClamp`/`emitLadder` site for site.
/// `Gen.mw` words each (`codegen/mask.zig`).
const Live = struct { reads: []u64, writes: []u64 };

/// Sets unknown `u` in `m`; `none_u32` (no node) sets nothing.
fn put(m: []u64, u: u32) void {
    if (u != none_u32) gen_mask.set(m, u);
}

fn unionSite(lv: Live, g: *const Gen, lc: LimitCall) void {
    put(lv.reads, lc.hi);
    put(lv.reads, lc.lo);
    put(lv.writes, if (g.limits.writable(lc.lo)) lc.lo else lc.hi);
}

/// Returns the `limit_reads`/`limit_writes` masks, from the arena; every
/// unknown is read when a clamp reads the core.
pub fn liveSets(g: *const Gen) Error!Live {
    const lv: Live = .{ .reads = try gen_mask.zero(g.arena, g.mw), .writes = try gen_mask.zero(g.arena, g.mw) };
    // A core re-entry is seeded from EVERY entry of `old` (`emit`'s `xr` loop).
    // One word is all ones, as the `u64` mask always was; a wider one names
    // the unknowns, since a literal past `u<n_u>` does not fit.
    if (usesCore(g)) {
        if (g.mw == 1) lv.reads[0] = std.math.maxInt(u64) else for (0..g.names.n_u) |u| gen_mask.set(lv.reads, @intCast(u));
    }
    for (g.limits.calls, 0..) |lc, i| switch (lc.alg) {
        .fetlimds => {
            const lad = g.limits.ladderOf(i).?;
            if (i != @min(lad.gs, lad.gd)) continue;
            // The two mode arms unioned: the shared gate is read, and both
            // channel nodes are read AND written (which one takes the fetlim
            // correction and which the limvds one swaps with the mode).
            const gs = g.limits.calls[lad.gs];
            const gd = g.limits.calls[lad.gd];
            for ([_]u32{ gs.hi, gs.lo, gd.lo }) |u| put(lv.reads, u);
            put(lv.writes, gs.lo);
            put(lv.writes, gd.lo);
        },
        // The rung reads the bulk and both channel nodes, and writes the bulk.
        .pnjlimds => {
            const r = g.limits.rungOf(i).?;
            if (i != @min(r.bs, r.bd)) continue;
            const bs = g.limits.calls[r.bs];
            for ([_]u32{ bs.hi, bs.lo, g.limits.calls[r.bd].lo }) |u| put(lv.reads, u);
            put(lv.writes, bs.hi);
        },
        .limvds => if (!g.limits.limvdsClaimed(i)) unionSite(lv, g, lc),
        .pnjlim, .fetlim, .steplim => unionSite(lv, g, lc),
    };
    // `seed` corrects the same node `emitClamp` does, but it is ORed in
    // anyway: the host initialises `lim_x` through `seed` and reads it back
    // through `limit`, so a bit in one and not the other is a stale slot.
    // The seed tree writes every node it places, its roots included.
    for (g.limits.seed_steps) |st| put(lv.writes, st.node);
    if (!g.limits.seed_tree) for (g.limits.calls) |lc| {
        if (lc.alg != .pnjlim or lc.argv[1] == .f_zero) continue;
        put(lv.writes, if (g.limits.writable(lc.lo)) lc.lo else lc.hi);
    };
    gen_mask.orIn(lv.reads, lv.writes);
    return lv;
}

// -------------------------------------------------------------------- emit

/// Returns true when a clamp or the §9.17.1 verdict reads a value out of the
/// shared core at clamp time, so `limit` must run its slice of the core
/// (`emitCore`). An argument that is a literal, a parameter or a `setup` root
/// (latched in `Model.su`) needs no core.
fn usesCore(g: *const Gen) bool {
    return rejectsInCore(g) or anyArg(g, needsCore);
}

/// True when the model executes §9.17.1 `$discontinuity(-1)` under a
/// condition the core computes.
fn rejectsInCore(g: *const Gen) bool {
    return g.lowered.uses.contains(.reject_iteration) and needsCore(g, g.lowered.reject_iteration);
}

/// True when `pred` holds for any clamp's sign or algorithm argument that is
/// not `.f_zero` (an absent sign).
fn anyArg(g: *const Gen, comptime pred: fn (*const Gen, Mir.Value) bool) bool {
    for (g.limits.calls) |lc| {
        if (lc.sign != .f_zero and pred(g, lc.sign)) return true;
        for (lc.argv[0..lc.alg.arity()]) |v| {
            if (v != .f_zero and pred(g, v)) return true;
        }
    }
    return false;
}

/// `usesCore` for `seed`, which reads only each pnjlim site's `vcrit` and sign.
fn seedUsesCore(g: *const Gen) bool {
    for (g.limits.seed_steps) |st| {
        if (st.site == none_u32) continue;
        const lc = g.limits.calls[st.site];
        if (needsCore(g, seedValue(lc)) or needsCore(g, lc.sign)) return true;
    }
    if (g.limits.seed_tree) return false;
    for (g.limits.calls) |lc| {
        if (lc.alg != .pnjlim or lc.argv[1] == .f_zero) continue;
        if (needsCore(g, lc.argv[1]) or needsCore(g, lc.sign)) return true;
    }
    return false;
}

/// Returns `<core>__limit`, the declaration `emitCore` writes.
fn coreName(g: *Gen) Error![]const u8 {
    return g.arena.print("{s}__limit", .{g.core.name});
}

/// Emits `<core>__limit`: the core's slice computing only the clamp arguments
/// that are neither a leaf nor a setup root, so `limit` pays for its
/// thresholds and not for every current and charge of the model. Called from
/// `emitUnits`, so its range tiles with the other unit declarations.
pub fn emitCore(g: *Gen) Error!void {
    if (!usesCore(g)) return;
    const idx = try g.arena.alloc(u32, g.an.nv);
    @memset(idx, none_u32);
    var vals: std.ArrayList(Mir.Value) = .empty;
    if (rejectsInCore(g)) {
        const r = g.an.rv(g.lowered.reject_iteration);
        idx[@backingInt(r)] = 0;
        try vals.append(g.arena, r);
    }
    for (g.limits.calls) |lc| {
        for ([_]Mir.Value{lc.sign} ++ lc.argv, 0..) |v, k| {
            if (k > lc.alg.arity() or !needsCore(g, v)) continue;
            const r = g.an.rv(v);
            if (idx[@backingInt(r)] != none_u32) continue;
            idx[@backingInt(r)] = @intCast(vals.items.len);
            try vals.append(g.arena, r);
        }
    }
    g.lim_idx = idx;
    try gen_unit.emitSlice(g, try coreName(g), vals.items, idx, if (g.limits.calls.len != 0)
        \\/// §4.5.15 the `$limit` arguments the core computes, and only what they
        \\/// read: `limit` evaluates them at `old` once per instance per iterate.
        \\
    else
        \\/// §9.17.1 the `$discontinuity(-1)` request the core computes, and only
        \\/// what it reads: `limit` evaluates it at `old` once per instance per
        \\/// iterate.
        \\
    );
}

/// True when `v0` must be read from the core's live-outs (not a root or leaf).
fn needsCore(g: *const Gen, v0: Mir.Value) bool {
    if (v0 == .f_zero) return false;
    return !isRoot(g, v0) and !isLeaf(g, v0);
}

/// A literal or a parameter: rendered straight over `Model`, no core.
fn isLeaf(g: *const Gen, v0: Mir.Value) bool {
    return switch (g.mir.valueDef(g.an.rv(v0))) {
        .float_const, .int_const => true,
        .param_ref => |p| Analysis.tyOfParam(g.lowered.params.items[p].ty) != .str,
        .undef, .str_const, .block_param, .inst_result => false,
    };
}

fn isRoot(g: *const Gen, v0: Mir.Value) bool {
    return g.su.idx.len != 0 and g.su.idx[@backingInt(g.an.rv(v0))] != none_u32;
}

/// A parameter leaf: a clamp argument that reads `Model` directly.
fn paramLeaf(g: *const Gen, v: Mir.Value) bool {
    return g.mir.valueDef(g.an.rv(v)) == .param_ref and isLeaf(g, v);
}

/// Emits `limit`, `limit_reads`/`limit_writes` and `seed` for a device with
/// honoured `$limit` sites, and reports declined sites (W0853), dropped seeds
/// (W0854) and seeds that read the solution (E0527, sets `any_fatal`).
/// Emits nothing but diagnostics when no site is honoured and the model has
/// no §9.17.1 `$discontinuity(-1)`.
pub fn emit(g: *Gen) Error!void {
    if (g.diags) |bag| inline for (.{ .{ .W0853, g.limits.declined }, .{ .W0854, g.limits.seed_dropped } }) |p| for (p[1]) |d| {
        var b = bag.build(.codegen, p[0], g.lowered.tokenSpan(d.tok));
        b.msg("{s}", .{d.msg});
        if (d.help) |h| b.help("{s}", .{h});
        try b.emit();
    };
    // `seed` runs before any solve, so there is no x for a seed to read.
    for (g.limits.calls) |lc| {
        if (lc.seed == .undef or !g.an.xDep(lc.seed)) continue;
        if (g.diags) |bag| try bag.add(.codegen, .E0527, g.lowered.tokenSpan(lc.tok), "", .{});
        g.any_fatal = true;
    }
    const rejects = g.lowered.uses.contains(.reject_iteration);
    if (g.limits.calls.len == 0 and !rejects) return;

    const needs_core = usesCore(g);
    // A setup root is a `model.su` read, so `model` stays named even when the
    // core call is gone, as it does for a parameter leaf. `inst` goes with the core.
    const reads_model = needs_core or anyArg(g, paramLeaf) or anyArg(g, isRoot) or (rejects and isRoot(g, g.lowered.reject_iteration));
    if (g.limits.calls.len != 0) try g.w(
        \\/// §4.5.15 `$limit`: SPICE voltage limiting, applied by the host between
        \\/// the linear solve and the next `eval`.
        \\///
        \\/// The clamps run in SOURCE ORDER and each reads the `x` the previous one
        \\/// left, because that is both the order the model wrote them in and the
        \\/// order ngspice's load routines apply them (fetlim → limvds → pnjlim on
        \\/// a JFET). Each clamp has ONE writer — the second-named node — so
        \\/// clamps that share their first-named node cannot fight (emitClamp
        \\/// says why a split breaks a BJT). A `fetlimds` pair and its `limvds`
        \\/// emit as ONE mode-swapped rung at the pair's source position: the leg
        \\/// that controls the channel in the OLD vds sign is clamped and the
        \\/// other derived, exactly ngspice's MOS ladder (emitLadder).
        \\
    , .{});
    if (rejects) try g.w(
        \\/// §9.17.1 `$discontinuity(-1)`: `converged` is false when the model,
        \\/// evaluated at `old`, requests that iterate be rejected.
        \\
    , .{});
    try g.w("pub fn limit(comptime {s}: type, {s}: *const Model, {s}: *const Instance, cur: [n_u]f64, {s}: [n_u]f64, {s}: contract.SimState) contract.LimitResult(n_u) {{\n", .{
        if (needs_core) "S" else "_",
        if (reads_model) "model" else "_",
        if (needs_core) "inst" else "_",
        if (needs_core or g.limits.calls.len != 0) "old" else "_",
        if (needs_core) "sim" else "_",
    });
    const probe_inst = if (needs_core) try g.probeInstance() else "inst";
    // §9.17.3 leaves the return value to the simulator, and ngspice's loads
    // take every limiter argument from the PREVIOUS load (mos1load.c:351
    // fetlims against the `von` stored at :535). So the slice that computes
    // the arguments runs at `old`, the previous iterate's limited point.
    if (needs_core) try g.w(
        \\    const m = {s}(S, zVals(S, &old), model, {s}, sim{s});
        \\
    , .{ try coreName(g), probe_inst, g.heldArg(true) });
    // A reject-only device clamps nothing, and a `var` never mutated is a
    // compile error.
    try g.w("    {s} x = cur;\n", .{if (g.limits.calls.len != 0) "var" else "const"});
    // Only `pnjlim` ever reports non-convergence, so a fetlim/limvds-only
    // device has nothing to track and `var ok` would never be mutated.
    var any_pnjlim = false;
    for (g.limits.calls) |lc| any_pnjlim = any_pnjlim or lc.alg == .pnjlim or lc.alg == .pnjlimds or lc.alg == .steplim;
    if (any_pnjlim) try g.w("    var ok = true;\n", .{});
    try emitSigns(g);
    for (g.limits.calls, 0..) |lc, i| switch (lc.alg) {
        // Collect kept only complete ladders; the earlier leg speaks for all
        // three sites, the partner and the claimed limvds stay silent.
        .fetlimds => {
            const lad = g.limits.ladderOf(i).?;
            if (i == @min(lad.gs, lad.gd)) try emitLadder(g, lad);
        },
        // Likewise the bulk rung, at its earlier leg.
        .pnjlimds => {
            const r = g.limits.rungOf(i).?;
            if (i == @min(r.bs, r.bd)) try emitRung(g, r);
        },
        .limvds => if (!g.limits.limvdsClaimed(i)) try emitClamp(g, lc),
        .pnjlim, .fetlim, .steplim => try emitClamp(g, lc),
    };
    try g.w("    return .{{ .x = x, .converged = ", .{});
    if (any_pnjlim) try g.w("ok", .{});
    if (any_pnjlim and rejects) try g.w(" and ", .{});
    if (rejects) {
        try writeArg(g, g.an.rv(g.lowered.reject_iteration), g.lim_idx);
        try g.w(" == 0", .{});
    } else if (!any_pnjlim) try g.w("true", .{});
    try g.w(" }};\n}}\n\n", .{});

    const lv = try liveSets(g);
    try g.w(
        \\/// Which unknowns `limit` and `seed` touch — `limit_reads` every
        \\/// `cur`/`old` entry the body loads, `limit_writes` every `x` entry it
        \\/// can store. Both are supersets. A host that gathers, copies and
        \\/// writes back all `n_u` spends that traffic on unknowns the ladder
        \\/// never looks at; ngspice's limiter memory is the branch voltages in
        \\/// `CKTstate0`, not every node the device touches.
        \\
    , .{});
    var tb: [16]u8 = undefined;
    const ty = gen_mask.typeName(&tb, g.names.n_u);
    try g.w("pub const limit_reads: {s} = 0x{f};\npub const limit_writes: {s} = 0x{f};\n\n", .{ ty, gen_mask.hex(lv.reads, false), ty, gen_mask.hex(lv.writes, false) });

    try emitSeed(g);
}

/// Emits `const zsg__k: f64 = ±1.0` once per distinct frame sign at the top of
/// `limit`, so the clamps of one MOSFET, which all read the same `type`, share
/// one compare-and-select. Named from the MIR value, so no state is shared.
fn emitSigns(g: *Gen) Error!void {
    var seen: std.ArrayList(u32) = .empty;
    defer seen.deinit(g.gpa);
    // Mirrors `emit`'s dispatch site for site. A claimed `limvds` emits no
    // clamp of its own but is the ladder's channel rung, so its sign is still
    // referenced. An unreferenced const is a Zig compile error.
    for (g.limits.calls, 0..) |lc, i| switch (lc.alg) {
        .fetlimds => {
            const lad = g.limits.ladderOf(i).?;
            if (i != @min(lad.gs, lad.gd)) continue;
            try oneSign(g, &seen, g.limits.calls[lad.gs].sign);
            try oneSign(g, &seen, g.limits.calls[lad.gd].sign);
            try oneSign(g, &seen, g.limits.calls[lad.ds].sign);
        },
        .pnjlimds => {
            const r = g.limits.rungOf(i).?;
            if (i != @min(r.bs, r.bd)) continue;
            try oneSign(g, &seen, g.limits.calls[r.bs].sign);
            try oneSign(g, &seen, g.limits.calls[r.bd].sign);
            try oneSign(g, &seen, g.limits.calls[r.ds].sign);
        },
        .limvds => if (!g.limits.limvdsClaimed(i)) try oneSign(g, &seen, lc.sign),
        .pnjlim, .fetlim, .steplim => try oneSign(g, &seen, lc.sign),
    };
}

fn oneSign(g: *Gen, seen: *std.ArrayList(u32), v: Mir.Value) Error!void {
    if (v == .f_zero) return;
    const k = signKey(g, v);
    if (std.mem.findScalar(u32, seen.items, k) != null) return;
    try seen.append(g.gpa, k);
    try g.w("    const zsg__{d}: f64 = if (", .{k});
    try writeArg(g, v, g.lim_idx);
    try g.w(" < 0) -1.0 else 1.0;\n", .{});
}

fn signKey(g: *const Gen, v: Mir.Value) u32 {
    return @backingInt(g.an.rv(v));
}

fn emitClamp(g: *Gen, lc: LimitCall) Error!void {
    const signed = lc.sign != .f_zero;
    try g.w("    {{ // $limit(V({s},{s}), \"{t}\"){s}\n", .{
        plan_limit.uName(g.names.u_names, lc.hi),                 plan_limit.uName(g.names.u_names, lc.lo), lc.alg,
        if (signed) " in the frame of its sign argument" else "",
    });
    try g.w("        const vn = ", .{});
    try writeProbe(g, lc, "x");
    try g.w(";\n        const vo = ", .{});
    try writeProbe(g, lc, "old");
    try g.w(";\n", .{});
    if (signed) {
        // ±1 recovered from the model value: the limiters assume forward =
        // positive, so the clamp runs on sg·v and hands back sg·result.
        //
        // `limvds` alone frames on the old vds sign, not the sign argument:
        // ngspice's loads branch on `vdsold >= 0` (mos1load: `vds =
        // -DEVlimvds(-vds, -vdsold)` in inverse mode), which in node
        // coordinates is sign(vo). Framing on device type pins an inverted
        // FET at DEVlimvds's -0.5 bound, a clamp that moves the converged
        // solution and not just the trajectory.
        if (lc.alg == .limvds) {
            try g.w("        const sg: f64 = if (vo < 0) -1.0 else if (vo > 0) 1.0 else zsg__{d};\n", .{signKey(g, lc.sign)});
        } else {
            try g.w("        const sg: f64 = zsg__{d};\n", .{signKey(g, lc.sign)});
        }
    }
    try g.w("        const vl = {s}z{s}({s}vn, {s}vo", .{
        if (signed) "sg * " else "",
        switch (lc.alg) {
            .pnjlim => @as([]const u8, "Pnjlim"),
            .fetlim => "Fetlim",
            .limvds => "Limvds",
            .fetlimds => unreachable, // emitLadder owns every surviving site
            .pnjlimds => unreachable, // emitRung owns every surviving site
            .steplim => "Steplim",
        },
        if (signed) "sg * " else "",
        if (signed) "sg * " else "",
    });
    for (lc.argv[0..lc.alg.arity()]) |v| {
        try g.w(", ", .{});
        try writeArg(g, v, g.lim_idx);
    }
    try g.w(");\n", .{});

    // Single writer, never a split. Junctions share nodes (a BJT's vbe and
    // vbc clamps both span `bi`), so a dv/2 split makes sequential clamps
    // fight through the shared side and the final frame satisfies neither
    // probe. Anchoring the first-named node and writing the whole correction
    // to the second keeps every probe exactly its limited value: model
    // authors put the shared side first (V(bi,ei)), as ngspice's frame does.
    const w_lo = g.limits.writable(lc.lo);
    if (w_lo) {
        try g.w("        x[@intFromEnum(U.{s})] -= vl - vn;\n", .{g.names.u_names[lc.lo]});
    } else {
        try g.w("        x[@intFromEnum(U.{s})] += vl - vn;\n", .{g.names.u_names[lc.hi]});
    }
    // ngspice sets `icheck` from `DEVpnjlim` exactly where it moved `vnew`,
    // so "the value changed" is the flag. `fetlim`/`limvds` report nothing:
    // they shape the trajectory. `steplim` reports like pnjlim (ngspice's
    // B4SOIlimit sets Check=1 on every clamp).
    if (lc.alg == .pnjlim or lc.alg == .steplim) try g.w("        if (vl != vn) ok = false;\n", .{});
    try g.w("    }}\n", .{});
}

/// Emits one `fetlimds` pair and its `limvds` as ngspice's MOS gate ladder
/// (mos1load.c:351-373): branch on the sign of the old vds, clamp the
/// controlling gate leg, re-clamp the channel, derive the other leg. In node
/// coordinates "derive the other" is a write-target choice: correcting the
/// source-side node moves vgs and vds and leaves vgd; correcting the
/// drain-side node moves vgd and vds and leaves vgs. vgdo needs no storage:
/// old[g]−old[di] is vgso−vdso.
///
/// The channel rung frames on `sgt` (normal arm) or `-sgt` (inverse arm),
/// the frame the standalone `limvds` clamp recovers from sign(vo).
fn emitLadder(g: *Gen, lad: Ladder) Error!void {
    const gs = g.limits.calls[lad.gs];
    const gd = g.limits.calls[lad.gd];
    const ds = g.limits.calls[lad.ds];
    const ng = g.names.u_names[gs.hi]; // shared gate
    const nd = g.names.u_names[gd.lo]; // drain-side channel node (the limvds hi)
    const ns = g.names.u_names[gs.lo]; // source-side channel node (the limvds lo)
    try g.w("    {{ // \"fetlimds\" mode ladder (ngspice mos1load.c): fetlim V({s},{s}) | V({s},{s})\n", .{ ng, ns, ng, nd });
    try g.w("        // by the sign of OLD V({s},{s}), then limvds, then derive the other leg.\n", .{ nd, ns });
    try g.w("        const vdso = old[@intFromEnum(U.{s})] - old[@intFromEnum(U.{s})];\n", .{ nd, ns });
    try writeSign(g, "sgt", ds.sign);
    try g.w("        if (sgt * vdso >= 0.0) {{ // normal mode: vgs controls\n", .{});
    try emitLeg(g, gs, nd, ns, false);
    try g.w("        }} else {{ // inverse mode: vgd controls\n", .{});
    try emitLeg(g, gd, nd, ns, true);
    try g.w("        }}\n    }}\n", .{});
}

/// Emits one ladder arm: fetlim the controlling leg (writing its own
/// second-named node, so the other leg's probe is untouched), then limvds the
/// channel V(nd,ns) against the old vds, writing the node the fetlim left alone.
fn emitLeg(g: *Gen, leg: LimitCall, nd: []const u8, ns: []const u8, inv: bool) Error!void {
    const ngate = g.names.u_names[leg.hi];
    const nw = g.names.u_names[leg.lo];
    try g.w("            const vn = x[@intFromEnum(U.{s})] - x[@intFromEnum(U.{s})];\n", .{ ngate, nw });
    try g.w("            const vo = old[@intFromEnum(U.{s})] - old[@intFromEnum(U.{s})];\n", .{ ngate, nw });
    if (leg.sign == .f_zero) {
        try g.w("            const vl = zFetlim(vn, vo, ", .{});
    } else {
        try g.w("            const sg: f64 = zsg__{d};\n", .{signKey(g, leg.sign)});
        try g.w("            const vl = sg * zFetlim(sg * vn, sg * vo, ", .{});
    }
    try writeArg(g, leg.argv[0], g.lim_idx);
    try g.w(");\n", .{});
    try g.w("            x[@intFromEnum(U.{s})] -= vl - vn;\n", .{nw});
    const neg: []const u8 = if (inv) "-" else "";
    try g.w("            const dn = x[@intFromEnum(U.{s})] - x[@intFromEnum(U.{s})];\n", .{ nd, ns });
    try g.w("            const dl = {s}sgt * zLimvds({s}sgt * dn, {s}sgt * vdso);\n", .{ neg, neg, neg });
    if (inv) {
        try g.w("            x[@intFromEnum(U.{s})] -= dl - dn;\n", .{ns});
    } else {
        try g.w("            x[@intFromEnum(U.{s})] += dl - dn;\n", .{nd});
    }
}

/// Emits one `pnjlimds` pair and its `limvds` as ngspice's MOS bulk rung
/// (mos1load.c:376-384): branch on the sign of the limited vds (the ladder has
/// run), pnjlim vbs or vbd from its raw value against its old one, and put the
/// bulk where that leaves the limited junction. Only the bulk moves.
fn emitRung(g: *Gen, r: Rung) Error!void {
    const bs = g.limits.calls[r.bs];
    const bd = g.limits.calls[r.bd];
    const ds = g.limits.calls[r.ds];
    const nb = g.names.u_names[bs.hi];
    const ns = g.names.u_names[bs.lo];
    const nd = g.names.u_names[bd.lo];
    try g.w("    {{ // \"pnjlimds\" bulk rung (ngspice mos1load.c): pnjlim V({s},{s}) | V({s},{s})\n", .{ nb, ns, nb, nd });
    try g.w("        // by the sign of the LIMITED V({s},{s}), then derive the other junction.\n", .{ nd, ns });
    try writeSign(g, "sgt", ds.sign);
    try g.w("        if (sgt * (x[@intFromEnum(U.{s})] - x[@intFromEnum(U.{s})]) >= 0.0) {{\n", .{ nd, ns });
    try emitJunction(g, bs);
    try g.w("        }} else {{\n", .{});
    try emitJunction(g, bd);
    try g.w("        }}\n    }}\n", .{});
}

/// Emits one rung arm: pnjlim the raw `V(hi, lo)` (from `cur`, before the
/// ladder moved `lo`) and write the bulk `hi` to the limited value above `x[lo]`.
fn emitJunction(g: *Gen, leg: LimitCall) Error!void {
    const nb = g.names.u_names[leg.hi];
    const nj = g.names.u_names[leg.lo];
    try g.w("            const vn = cur[@intFromEnum(U.{s})] - cur[@intFromEnum(U.{s})];\n", .{ nb, nj });
    try g.w("            const vo = old[@intFromEnum(U.{s})] - old[@intFromEnum(U.{s})];\n", .{ nb, nj });
    if (leg.sign == .f_zero) {
        try g.w("            const vl = zPnjlim(vn, vo, ", .{});
    } else {
        try g.w("            const sg: f64 = zsg__{d};\n", .{signKey(g, leg.sign)});
        try g.w("            const vl = sg * zPnjlim(sg * vn, sg * vo, ", .{});
    }
    try writeArg(g, leg.argv[0], g.lim_idx);
    try g.w(", ", .{});
    try writeArg(g, leg.argv[1], g.lim_idx);
    try g.w(");\n", .{});
    try g.w("            x[@intFromEnum(U.{s})] = x[@intFromEnum(U.{s})] + vl;\n", .{ nb, nj });
    try g.w("            if (vl != vn) ok = false;\n", .{});
}

/// Emits `const NAME: f64 = ±1.0` from a sign argument, or 1.0 when unsigned.
fn writeSign(g: *Gen, name: []const u8, v: Mir.Value) Error!void {
    if (v == .f_zero) return g.w("        const {s}: f64 = 1.0;\n", .{name});
    try g.w("        const {s}: f64 = zsg__{d};\n", .{ name, signKey(g, v) });
}

fn writeProbe(g: *Gen, lc: LimitCall, arr: []const u8) Error!void {
    try g.w("{s}[@intFromEnum(U.{s})]", .{ arr, g.names.u_names[lc.hi] });
    if (lc.lo != none_u32) try g.w(" - {s}[@intFromEnum(U.{s})]", .{ arr, g.names.u_names[lc.lo] });
}

/// Writes argument `v`: a literal, a parameter, a setup root, or field
/// `field[v]` of `m`, the core (`seed`) or `limit`'s slice of it (`emitCore`).
fn writeArg(g: *Gen, v: Mir.Value, field: []const u32) Error!void {
    if (v == .f_zero) return g.w("0.0", .{});
    const i = @backingInt(g.an.rv(v));
    // Solve-invariant: `setup` latched it (codegen/setup.zig), so neither
    // `limit` nor `seed` evaluates the core for it.
    if (isRoot(g, v)) return g.w("{s}", .{try Gen.rootRef(g, v, false)});
    if (isLeaf(g, v)) return g.w("{s}", .{try g.f64Expr(v)});
    const k = field[i];
    std.debug.assert(k != none_u32); // `buildJobs` and `emitCore` take every `argv`
    // An integer core field (a `parameter integer` sign) is a bare i64, not
    // a family value, so it has no `.val()`.
    if (g.an.vty[i] == .int)
        try g.w("m.f{d}", .{k})
    else
        try g.w("m.f{d}.val()", .{k});
}

/// Emits `seed`, SPICE `MODEINITJCT`: every pnjlim-limited branch starts at its
/// own `vcrit`, where the exponential is still Newton-tractable, instead of at
/// 0 V, where the junction has no current and no conductance. `fetlim`/`limvds`
/// get nothing: a channel is well-conditioned at 0 V.
fn emitSeed(g: *Gen) Error!void {
    if (g.limits.seed_tree) return emitSeedTree(g);
    var any = false;
    for (g.limits.calls) |lc| {
        if (lc.alg == .pnjlim and lc.argv[1] != .f_zero) any = true;
    }
    if (!any) return;
    const needs_core = seedUsesCore(g);
    const reads_model = needs_core or anyArg(g, paramLeaf) or anyArg(g, isRoot);
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
    for (g.limits.calls) |lc| {
        if (lc.alg != .pnjlim or lc.argv[1] == .f_zero) continue;
        // The junction sits across `V(hi, lo)`, and only the internal side is
        // ours to place. Two clamps on the same net are the same junction seen
        // twice, so the later one's bias is as right as the earlier.
        // A signed clamp seeds V = sign·vcrit: the junction is forward at
        // NEGATIVE probe voltage when the sign argument is negative.
        const on_lo = g.limits.writable(lc.lo);
        if (lc.sign != .f_zero) {
            try g.w("    s[@intFromEnum(U.{s})] = if (", .{g.names.u_names[if (on_lo) lc.lo else lc.hi]});
            try writeArg(g, lc.sign, g.core.lo_idx);
            try g.w(" < 0) {s}", .{if (on_lo) "" else "-"});
            try writeArg(g, lc.argv[1], g.core.lo_idx);
            try g.w(" else {s}", .{if (on_lo) "-" else ""});
            try writeArg(g, lc.argv[1], g.core.lo_idx);
        } else if (on_lo) {
            try g.w("    s[@intFromEnum(U.{s})] = -", .{g.names.u_names[lc.lo]});
            try writeArg(g, lc.argv[1], g.core.lo_idx);
        } else {
            try g.w("    s[@intFromEnum(U.{s})] = ", .{g.names.u_names[lc.hi]});
            try writeArg(g, lc.argv[1], g.core.lo_idx);
        }
        try g.w("; // V({s},{s}) = {s}vcrit\n", .{
            plan_limit.uName(g.names.u_names, lc.hi), plan_limit.uName(g.names.u_names, lc.lo),
            if (lc.sign != .f_zero) "±" else "",
        });
    }
    try g.w("    return s;\n}}\n\n", .{});
}

/// Emits the seed tree's `seed` (`plan/limit.zig` `planSeed`): the host's
/// limited image is node values, so each seeded branch is solved into them
/// down the tree from a root at 0 V. ngspice MODEINITJCT (mos1load.c:397-408)
/// seeds the branches instead: vgs = vto, vds = 0, vbs = -1.
fn emitSeedTree(g: *Gen) Error!void {
    if (g.limits.seed_steps.len == 0) return;
    const needs_core = seedUsesCore(g);
    var reads_param = false;
    var reads_root = false;
    for (g.limits.seed_steps) |st| {
        if (st.site == none_u32) continue;
        const lc = g.limits.calls[st.site];
        for ([_]Mir.Value{ seedValue(lc), lc.sign }) |v| {
            if (v == .f_zero) continue;
            reads_param = reads_param or paramLeaf(g, v);
            reads_root = reads_root or isRoot(g, v);
        }
    }
    try g.w(
        \\/// SPICE `MODEINITJCT` with `$limit`'s seed argument: each seeded branch starts at
        \\/// its own value (vcrit for a junction that names none), solved into node
        \\/// values from a root at 0 V. These are the instance's private limited
        \\/// image, and every lane written here is in `limit_writes`.
        \\
    , .{});
    try g.w("pub fn seed(comptime {s}: type, {s}: *const Model, {s}: *const Instance, {s}: contract.SimState) [n_u]?f64 {{\n", .{
        if (needs_core) "S" else "_",
        if (needs_core or reads_param or reads_root) "model" else "_",
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
    for (g.limits.seed_steps) |st| {
        const nn = g.names.u_names[st.node];
        if (st.site == none_u32) {
            try g.w("    s[@intFromEnum(U.{s})] = 0.0; // root\n", .{nn});
            continue;
        }
        const lc = g.limits.calls[st.site];
        // lim(hi) = lim(lo) + sign·seed
        try g.w("    s[@intFromEnum(U.{s})] = ", .{nn});
        if (st.from == none_u32) try g.w("0.0", .{}) else try g.w("s[@intFromEnum(U.{s})].?", .{g.names.u_names[st.from]});
        try g.w(" {s} ", .{if (st.node == lc.hi) "+" else "-"});
        if (lc.sign != .f_zero) {
            try g.w("@as(f64, if (", .{});
            try writeArg(g, lc.sign, g.core.lo_idx);
            try g.w(" < 0) -1.0 else 1.0) * ", .{});
        }
        try g.w("(", .{});
        try writeArg(g, seedValue(lc), g.core.lo_idx);
        try g.w("); // V({s},{s}) = {s}\n", .{
            plan_limit.uName(g.names.u_names, lc.hi),   plan_limit.uName(g.names.u_names, lc.lo),
            if (lc.seed != .undef) "seed" else "vcrit",
        });
    }
    try g.w("    return s;\n}}\n\n", .{});
}

/// A tree edge's value: its seed argument, else its junction's vcrit.
fn seedValue(lc: LimitCall) Mir.Value {
    return if (lc.seed != .undef) lc.seed else lc.argv[1];
}

test put {
    // No node, no bit; past 64 the second word.
    var m: [2]u64 = @splat(0);
    put(&m, none_u32);
    try std.testing.expectEqualSlices(u64, &.{ 0, 0 }, &m);
    put(&m, 0);
    put(&m, 64);
    try std.testing.expectEqualSlices(u64, &.{ 1, 1 }, &m);
}
