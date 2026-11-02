//! A honoured `$limit` site's arguments (sign, algorithm arguments, seed) and
//! the §9.17.1 `$discontinuity(-1)` condition -> where each is read from at
//! clamp time: a literal or parameter over `Model`, a `setup` root latched in
//! `Model.su`, or a field of `<core>__limit`, the core's slice this file emits
//! for the rest. `cg_limit.zig` (the `limit` hook) and `cg_limit_seed.zig`
//! (`seed`) render every argument through `writeArg`.
//! Cites: §4.5.15, §9.17.1, §9.17.3.
//!
//! Contents:
//! - `pub fn emitCore(g: *Gen) Error!void`
//! - `pub fn usesCore(g: *const Gen) bool`
//! - `pub fn anyArg(g: *const Gen, comptime pred: fn (*const Gen, Mir.Value) bool) bool`
//! - `pub fn isRoot(g: *const Gen, v0: Mir.Value) bool`
//! - `pub fn paramLeaf(g: *const Gen, v: Mir.Value) bool`
//! - `pub fn coreName(g: *Gen) Error![]const u8`
//! - `pub fn writeArg(g: *Gen, v: Mir.Value, field: []const u32) Error!void`
//! - `pub fn seedUsesCore(g: *const Gen) bool`
//! - `pub fn seedValue(lc: LimitCall) Mir.Value`

const std = @import("std");
const assert = std.debug.assert;
const Mir = @import("ir").Mir;
const Analysis = @import("prove").Analysis;
const cg = @import("codegen.zig");
const gen_unit = @import("codegen/unit.zig");
const plan_limit = @import("codegen/plan/limit.zig");
const Gen = cg.Gen;
const Error = cg.Error;
const LimitCall = plan_limit.LimitCall;
const none_u32 = cg.none_u32;

comptime {
    // `emitCore` walks `sign` then `argv` as one array, indexed against arity.
    assert(@typeInfo(@FieldType(LimitCall, "argv")).array.len >= 2);
}

/// Emits `<core>__limit`: the core's slice computing only the clamp arguments
/// that are neither a leaf nor a setup root, so `limit` pays for its
/// thresholds and not for every current and charge of the model. Called from
/// `emitUnits`, so its range tiles with the other unit declarations. Sets
/// `g.lim_idx` (value -> slice field, `none_u32` elsewhere, arena-owned);
/// emits nothing and leaves it empty when no argument needs the core.
/// Asserts that it runs once per device. Invalidates slices of `g.out.items`.
pub fn emitCore(g: *Gen) Error!void {
    assert(g.lim_idx.len == 0);
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
            assert(@backingInt(r) < idx.len);
            if (idx[@backingInt(r)] != none_u32) continue;
            idx[@backingInt(r)] = @intCast(vals.items.len);
            try vals.append(g.arena, r);
        }
    }
    // `usesCore` held, so some argument or the condition is a core value.
    assert(vals.items.len != 0);
    assert(vals.items.len <= g.an.nv);
    g.lim_idx = idx;
    assert(g.lim_idx.len == g.an.nv);
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

/// Returns true when a clamp or the §9.17.1 verdict reads a value out of the
/// shared core at clamp time, so `limit` must run its slice of the core
/// (`emitCore`). An argument that is a literal, a parameter or a `setup` root
/// (latched in `Model.su`) needs no core.
pub fn usesCore(g: *const Gen) bool {
    const uses = rejectsInCore(g) or anyArg(g, needsCore);
    // Negative space: with no site and no request there is nothing to read.
    if (uses) assert(g.limits.calls.len != 0 or g.lowered.uses.contains(.reject_iteration));
    return uses;
}

/// Returns true when `pred` holds for any clamp's sign or algorithm argument
/// that is not `.f_zero` (an absent sign).
pub fn anyArg(g: *const Gen, comptime pred: fn (*const Gen, Mir.Value) bool) bool {
    for (g.limits.calls) |lc| {
        if (lc.sign != .f_zero and pred(g, lc.sign)) return true;
        assert(lc.alg.arity() <= lc.argv.len);
        for (lc.argv[0..lc.alg.arity()]) |v| {
            if (v != .f_zero and pred(g, v)) return true;
        }
    }
    return false;
}

/// Returns true when `v0` is a `setup` root, read as `model.su` and never
/// evaluated by `limit` or `seed`. Asserts that the setup table, when
/// planned, has one entry per value.
pub fn isRoot(g: *const Gen, v0: Mir.Value) bool {
    if (g.su.idx.len == 0) return false;
    assert(g.su.idx.len == g.an.nv);
    const i = @backingInt(g.an.rv(v0));
    assert(i < g.su.idx.len);
    return g.su.idx[i] != none_u32;
}

/// Returns true for a parameter leaf: a clamp argument that reads `Model`
/// directly. Asserts that `v` is a present argument (not `.f_zero`).
pub fn paramLeaf(g: *const Gen, v: Mir.Value) bool {
    assert(v != .f_zero);
    return g.mir.valueDef(g.an.rv(v)) == .param_ref and isLeaf(g, v);
}

/// Returns `<core>__limit`, the declaration `emitCore` writes, arena-owned.
/// Asserts that the device has a core to slice.
pub fn coreName(g: *Gen) Error![]const u8 {
    assert(g.core.name.len != 0);
    const name = try g.arena.print("{s}__limit", .{g.core.name});
    assert(name.len > g.core.name.len);
    return name;
}

/// Writes argument `v`: a literal, a parameter, a setup root, or field
/// `field[v]` of `m`, the core (`seed`, `g.core.lo_idx`) or `limit`'s slice
/// of it (`emitCore`, `g.lim_idx`). Asserts that `v` is not `.undef` and, for
/// a core value, that `field` maps every value and maps `v`.
/// Invalidates slices of `g.out.items`.
pub fn writeArg(g: *Gen, v: Mir.Value, field: []const u32) Error!void {
    assert(v != .undef);
    if (v == .f_zero) return g.w("0.0", .{});
    const i = @backingInt(g.an.rv(v));
    assert(i < g.an.nv);
    // Solve-invariant: `setup` latched it (codegen/setup.zig), so neither
    // `limit` nor `seed` evaluates the core for it.
    if (isRoot(g, v)) return g.w("{s}", .{try Gen.rootRef(g, v, false)});
    if (isLeaf(g, v)) return g.w("{s}", .{try g.f64Expr(v)});
    assert(field.len == g.an.nv);
    const k = field[i];
    assert(k != none_u32); // `buildJobs` and `emitCore` take every `argv`
    // An integer core field (a `parameter integer` sign) is a bare i64, not
    // a family value, so it has no `.val()`.
    if (g.an.vty[i] == .int)
        try g.w("m.f{d}", .{k})
    else
        try g.w("m.f{d}.val()", .{k});
}

/// `usesCore` for `seed`, which reads only each seeded site's value and sign.
/// Asserts that every seed step names a site in `g.limits.calls` or none.
pub fn seedUsesCore(g: *const Gen) bool {
    for (g.limits.seed_steps) |st| {
        if (st.site == none_u32) continue;
        assert(st.site < g.limits.calls.len);
        const lc = g.limits.calls[st.site];
        if (needsCore(g, seedValue(lc)) or needsCore(g, lc.sign)) return true;
    }
    if (g.limits.seed_tree) return false;
    // The per-junction form: no tree, so no step.
    assert(g.limits.seed_steps.len == 0);
    for (g.limits.calls) |lc| {
        if (lc.alg != .pnjlim or lc.argv[1] == .f_zero) continue;
        if (needsCore(g, lc.argv[1]) or needsCore(g, lc.sign)) return true;
    }
    return false;
}

/// Returns a tree edge's value: its seed argument, else its junction's vcrit
/// (`argv[1]`). Asserts that a site with no seed has a vcrit argument.
pub fn seedValue(lc: LimitCall) Mir.Value {
    if (lc.seed != .undef) return lc.seed;
    assert(lc.alg.arity() == 2);
    return lc.argv[1];
}

// ---- private ----

/// True when the model executes §9.17.1 `$discontinuity(-1)` under a
/// condition the core computes.
fn rejectsInCore(g: *const Gen) bool {
    return g.lowered.uses.contains(.reject_iteration) and needsCore(g, g.lowered.reject_iteration);
}

/// True when `v0` must be read from the core's live-outs (not a root or leaf).
fn needsCore(g: *const Gen, v0: Mir.Value) bool {
    if (v0 == .f_zero) return false;
    return !isRoot(g, v0) and !isLeaf(g, v0);
}

/// A literal or a parameter: rendered straight over `Model`, no core.
fn isLeaf(g: *const Gen, v0: Mir.Value) bool {
    assert(v0 != .f_zero);
    return switch (g.mir.valueDef(g.an.rv(v0))) {
        .float_const, .int_const => true,
        .param_ref => |p| blk: {
            assert(p < g.lowered.params.items.len);
            break :blk Analysis.tyOfParam(g.lowered.params.items[p].ty) != .str;
        },
        .undef, .str_const, .block_param, .inst_result => false,
    };
}
