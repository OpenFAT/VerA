//! Scalar family text (`contract.family_fns`): a MIR value's unknown set
//! (`Analysis.unknownDeps`) in, the mask literals, `zTo`/`zOf` wrappers, the
//! per-device `lane_masks` table and the `contract.Constant` verdict out. A
//! mask is written only where values merge (hoisted slot, lazy `if` arms,
//! array element, kernel result, returned field, residual row); `zTo` fails
//! to compile on a value whose lanes the mask misses, so an unsound mask
//! cannot drop a lane silently.
//! Cites: none (it realises `contract.family_fns` and `contract.Constant`).
//!
//! Contents:
//! - `pub const Constant = struct { g: bool, c: bool }`
//! - `pub fn mask(self: *const Gen, v: Mir.Value) []const u64`
//! - `pub fn acDyn(self: *const Gen, v: Mir.Value) []const u64`
//! - `pub fn openTo(self: *Gen, m: []const u64) Error!void`
//! - `pub fn ofText(self: *Gen, m: []const u64) Error![]const u8`
//! - `pub fn note(self: *Gen, m: []const u64) Error!void`
//! - `pub fn emitLaneMasks(self: *Gen, deriv_reads: []const u64) Error!void`
//! - `pub fn constant(self: *Gen) Error!Constant`

const std = @import("std");
const assert = std.debug.assert;
const Mir = @import("ir").Mir;
const codegen = @import("../codegen.zig");
const gen_call = @import("call.zig");
const gen_dispatch = @import("dispatch.zig");
const gen_mask = @import("mask.zig");
const Gen = codegen.Gen;
const Error = codegen.Error;

/// `contract.Constant`: `g` when ∂eval/∂x cannot depend on x, `c` when ∂q/∂x
/// cannot, at every x and analysis point. False is always sound.
pub const Constant = struct { g: bool, c: bool };

/// The two fixpoints `constant` settles, read per value: the affine set and
/// the host-state cone, both `nv` long.
const Lattice = struct {
    g: *const Gen,
    aff: []const bool,
    host: []const bool,

    fn affine(k: Lattice, v: Mir.Value) bool {
        assert(k.aff.len == k.host.len);
        assert(k.aff.len == k.g.an.nv);
        return k.aff[@backingInt(k.g.an.rv(v))];
    }

    fn card(k: Lattice, v: Mir.Value) bool {
        assert(k.host.len == k.g.an.nv);
        return !k.g.an.xDep(v) and !k.host[@backingInt(k.g.an.rv(v))];
    }
};

/// Returns the unknowns `v` may depend on, `Gen.mw` words borrowed from
/// `Gen.deps`: its mask before `zdr` cuts it. Asserts that `deps` holds `mw`
/// words per value.
pub fn mask(self: *const Gen, v: Mir.Value) []const u64 {
    assert(self.deps.len == @as(usize, self.an.nv) * self.mw);
    const i: usize = @backingInt(self.an.rv(v));
    assert(i < self.an.nv);
    return self.deps[i * self.mw ..][0..self.mw];
}

/// Returns the unknowns whose derivative reaches `v` through a
/// frequency-dependent operator (`Analysis.acDynDeps`), `Gen.mw` words
/// borrowed from `Gen.acdyn` (or `Gen.zero_mask` when no operator is).
/// Asserts that a non-empty `acdyn` holds `mw` words per value.
pub fn acDyn(self: *const Gen, v: Mir.Value) []const u64 {
    if (self.acdyn.len == 0) {
        assert(self.zero_mask.len == self.mw);
        return self.zero_mask;
    }
    assert(self.acdyn.len == @as(usize, self.an.nv) * self.mw);
    const i: usize = @backingInt(self.an.rv(v));
    return self.acdyn[i * self.mw ..][0..self.mw];
}

/// Writes `zTo(S, 0x<m>, `; the caller writes the value and the closing `)`.
/// Asserts that `m` is `mw` words. Invalidates slices of `g.out.items`.
pub fn openTo(self: *Gen, m: []const u64) Error!void {
    assert(m.len == self.mw);
    const len_before = self.out.items.len;
    try self.b("zTo(S, 0x{f}, ", .{gen_mask.hex(m, false)});
    assert(self.out.items.len > len_before);
}

/// Returns `zOf(S, 0x<m>)` as text for a `{s}` slot, owned by `g.arena`.
/// Asserts that `m` is `mw` words.
pub fn ofText(self: *Gen, m: []const u64) Error![]const u8 {
    assert(m.len == self.mw);
    const text = try self.arena.print("zOf(S, 0x{f})", .{gen_mask.hex(m, false)});
    assert(text.len > "zOf(S, 0x)".len);
    return text;
}

/// Records one real the shared core declares at mask `m`, for `lane_masks`.
/// Ignored in `setup` (value scalar) and in a `probeBody` dry run. `m` is
/// borrowed until `emitLaneMasks`. Asserts that `m` is `mw` words.
pub fn note(self: *Gen, m: []const u64) Error!void {
    assert(m.len == self.mw);
    if (self.cur.probe.active or !self.cur.emitting_common or self.su.mode) return;
    const n_before = self.fam_masks.items.len;
    try self.fam_masks.append(self.arena, m);
    assert(self.fam_masks.items.len == n_before + 1);
}

/// Writes `lane_masks`: every distinct mask a real was declared at, cut to
/// `deriv_reads`, with its use count. A host sizes its lane types from it.
/// Sorts `fam_masks` in place. Not written past 64 unknowns, where a
/// `contract.LaneUse` mask cannot hold one; `contract.laneMasks` then gives
/// one entry, `deriv_reads`. Asserts that `deriv_reads` is `mw` words.
/// Invalidates slices of `g.out.items`.
pub fn emitLaneMasks(self: *Gen, deriv_reads: []const u64) Error!void {
    assert(deriv_reads.len == self.mw);
    if (self.mw > 1) return;
    const ms = self.fam_masks.items;
    for (ms) |*m| {
        const c = try self.arena.dupe(u64, m.*);
        gen_mask.andIn(c, deriv_reads);
        m.* = c;
    }
    // The cut leaves every mask a subset of `deriv_reads`.
    for (ms) |m| assert(gen_mask.subset(m, deriv_reads));
    std.mem.sort([]const u64, ms, {}, gen_mask.lessThan);
    try self.w(
        \\/// Every distinct `Of` mask a real in this device is declared at, and
        \\/// how many are (`contract.laneMasks`).
        \\pub const lane_masks = [_]contract.LaneUse{{
        \\
    , .{});
    var i: usize = 0;
    var uses_total: usize = 0;
    while (i < ms.len) {
        var j = i;
        while (j < ms.len and std.mem.eql(u64, ms[j], ms[i])) j += 1;
        assert(j > i);
        try self.w("    .{{ .mask = 0x{f}, .uses = {d} }},\n", .{ gen_mask.hex(ms[i], false), j - i });
        uses_total += j - i;
        i = j;
    }
    assert(i == ms.len);
    assert(uses_total == ms.len);
    try self.w("}};\n\n", .{});
}

/// Returns `contract.Constant` for this device (see `Constant`).
///
/// A value is affine in x when its lanes depend on the card alone: a probe, a
/// card constant, a sum or negation of affine values, an affine value times or
/// divided by a card constant, or a select or join on a card constant over
/// affine arms. A card constant varies with neither x nor host-rewritten state
/// (`gen_call.readsHostState`): `$abstime * V` has a constant partial at every
/// x and a different one at every time. Two `nv`-long scratch columns live
/// on `g.gpa` for the call. Asserts that the value table holds every
/// builtin value.
pub fn constant(self: *Gen) Error!Constant {
    const nv = self.an.nv;
    // `host` and `aff` are scratch of this pass (two nv-long columns, 250 KiB
    // on hisimhv_va): on the gpa, freed on return.
    assert(nv >= Mir.Value.first_dynamic);
    const host = try self.gpa.alloc(bool, nv);
    defer self.gpa.free(host);
    @memset(host, false);
    var steered = false;
    for (0..self.mir.insts.len) |i| {
        const inst: Mir.Inst = @fromBackingInt(@intCast(i));
        if (self.mir.instOp(inst) == .branch and self.an.xDep(self.mir.instData(inst).branch.cond)) steered = true;
    }
    // The host-state cone, then the affine set: both monotone, so each
    // fixpoint settles in at most (longest chain) sweeps.
    // Each sweep that changes anything sets at least one of the `nv` flags,
    // so at most nv + 1 sweeps run.
    var changed = true;
    var sweeps: usize = 0;
    while (changed) : (sweeps += 1) {
        assert(sweeps <= nv);
        changed = false;
        for (0..nv) |v| {
            if (host[v] or !hostStep(self, @fromBackingInt(@intCast(v)), host)) continue;
            host[v] = true;
            changed = true;
        }
    }
    const aff = try self.gpa.alloc(bool, nv);
    defer self.gpa.free(aff);
    @memset(aff, true);
    changed = true;
    sweeps = 0;
    while (changed) : (sweeps += 1) {
        assert(sweeps <= nv);
        changed = false;
        for (0..nv) |v| {
            if (!aff[v] or affineStep(self, @fromBackingInt(@intCast(v)), aff, host, steered)) continue;
            aff[v] = false;
            changed = true;
        }
    }
    const k: Lattice = .{ .g = self, .aff = aff, .host = host };
    var g = self.lowered.table_effect == .f_zero;
    var c = gen_dispatch.anyQ(self);
    for (self.lowered.contributions.items) |ct| {
        g = g and k.affine(ct.resist_val) and k.card(ct.wrote_val);
        c = c and k.affine(ct.react_val) and k.card(ct.wrote_val);
    }
    for (self.qs.sites) |s| c = c and k.affine(self.lowered.charge_sites.items[s].final);
    return .{ .g = g, .c = c };
}

// ---- private ----

/// One step of the host-state cone: a call that reads host state, or any
/// operand in the cone.
fn hostStep(self: *const Gen, v: Mir.Value, host: []const bool) bool {
    assert(host.len == self.an.nv);
    assert(@backingInt(v) < self.an.nv);
    const in = struct {
        fn f(g: *const Gen, h: []const bool, o: Mir.Value) bool {
            return h[@backingInt(g.an.rv(o))];
        }
    }.f;
    const def = self.mir.valueDef(self.an.rv(v));
    if (def != .inst_result) return false;
    const inst = def.inst_result;
    var g = self.mir.guardConds(inst);
    while (g.next()) |c| if (in(self, host, c)) return true;
    return switch (self.mir.instData(inst)) {
        .call => |c| gen_call.readsHostState(self, inst) or for (c.args) |a| {
            if (in(self, host, a)) break true;
        } else false,
        .unary => |u| in(self, host, u.operand),
        .binary => |b| in(self, host, b.lhs) or in(self, host, b.rhs),
        .ternary => |t| in(self, host, t.cond) or in(self, host, t.then_val) or in(self, host, t.else_val),
        .phi => |d| for (0..d.count) |j| {
            if (in(self, host, self.mir.phiPair(inst, @intCast(j)).value)) break true;
        } else false,
        .load => |l| in(self, host, l.arr) or in(self, host, l.index),
        .store => |s| in(self, host, s.arr) or in(self, host, s.index) or in(self, host, s.value),
        .anew, .branch, .jump => false,
    };
}

/// One step of the affine set, given the current answer for the operands.
fn affineStep(self: *const Gen, v: Mir.Value, aff: []const bool, host: []const bool, steered: bool) bool {
    assert(aff.len == self.an.nv);
    assert(host.len == aff.len);
    const k: Lattice = .{ .g = self, .aff = aff, .host = host };
    if (k.card(v)) return true;
    const def = self.mir.valueDef(self.an.rv(v));
    switch (def) {
        .block_param, .undef, .float_const, .int_const, .str_const, .param_ref => return true,
        .inst_result => |inst| return switch (self.mir.instData(inst)) {
            // `dstop`'s lanes are zero at every x.
            .unary => |u| if (u.op == .fneg) k.affine(u.operand) else u.op == .dstop,
            .binary => |b| if (b.op == .fadd or b.op == .fsub)
                k.affine(b.lhs) and k.affine(b.rhs)
            else if (b.op == .fmul)
                (k.card(b.lhs) and k.affine(b.rhs)) or (k.card(b.rhs) and k.affine(b.lhs))
            else if (b.op == .fdiv)
                k.affine(b.lhs) and k.card(b.rhs)
            else
                false,
            .ternary => |t| k.card(t.cond) and k.affine(t.then_val) and k.affine(t.else_val),
            // A join is a select on the branch that reached it.
            .phi => |d| !steered and for (0..d.count) |j| {
                if (!k.affine(self.mir.phiPair(inst, @intCast(j)).value)) break false;
            } else true,
            .call, .load, .store, .anew, .branch, .jump => false,
        },
    }
}
