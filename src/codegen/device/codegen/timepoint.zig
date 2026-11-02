//! VerA's `vera_timepoint` statements (§2.9, `Lowered.timepoints`) -> each
//! cached statement's `Instance` fields, the in-place cache slots of §5.10
//! copy-on-write arrays and the block map that finds them, the fills at each
//! statement join, and `zTpDrop`/`zTpStore`.
//! Cites: §2.9, §5.10.
//!
//! Contents:
//! - `pub fn tpInPlace(self: *const Gen, sl: Lowered.TpSlot) bool`
//! - `pub fn anyTpInPlace(self: *const Gen) bool`
//! - `pub fn tpBlocks(self: *Gen) Error![]const u32`
//! - `pub fn tpSlotAt(self: *const Gen, bi: u32, id: u32) ?struct { b: u32, k: u32 }`
//! - `pub fn emitTpFills(self: *Gen, bi: u32, depth: u32) Error!void`
//! - `pub fn emitTpFields(self: *Gen) Error!void`
//! - `pub fn emitTpHelpers(self: *Gen) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_dispatch = @import("dispatch.zig");
const render_array = @import("render_array.zig");
const kt = @import("kernel_text.zig");
const Lowered = @import("ir").Lowered;
const Mir = @import("ir").Mir;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const gen_instance = @import("instance.zig");

/// VerA's `vera_timepoint` (§2.9): whether slot `sl`'s cache is a §5.10
/// copy-on-write held array (`render.cow`) that the statement's stores write
/// in place, in its `tp<b>_s<k>` field, when the core is handed a mutable
/// `Instance` (`eval`, `evalQ`). A local copy of a held history and its copy
/// in the core's result are what put txl's 2048-deep history at 165 KB of
/// GPU stack, and the coupled lines' at 307-612 KB (#82).
pub fn tpInPlace(self: *const Gen, sl: Lowered.TpSlot) bool {
    assert(self.arr_s.len == self.lowered.mem_arrays.items.len);
    if (sl.array == none_u32 or !render_array.cow(self, sl.array)) return false;
    assert(sl.array < self.lowered.mem_arrays.items.len);
    // The slot's field exists only when the full core carries the final
    // version (`emitTpFields`); a slice's `plan.lo_idx` is its own.
    const v = self.an.rv(sl.final);
    if (v == .f_zero) return false;
    assert(@backingInt(v) < self.tp_lo_idx.len);
    return self.tp_lo_idx[@backingInt(v)] != none_u32;
}

/// Whether some `vera_timepoint` slot is stored in place (`tpInPlace`).
pub fn anyTpInPlace(self: *const Gen) bool {
    assert(self.tp_lo_idx.len == 0 or self.tp_lo_idx.len == self.an.nv);
    for (self.lowered.timepoints.items) |t| for (t.slots) |sl| if (tpInPlace(self, sl)) return true;
    return false;
}

/// Returns `Gen.tp_of_block`: per MIR block, the innermost `vera_timepoint`
/// statement whose miss arm holds it (the blocks its miss block reaches
/// before the join, as `prove.timepoint.varying` walks them), or
/// `none_u32`. Empty when no slot is stored in place.
pub fn tpBlocks(self: *Gen) Error![]const u32 {
    assert(self.tp_of_block.len == 0);
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
            for (self.an.succsOf(x)) |y| {
                if (y == join or seen[y]) continue;
                seen[y] = true;
                stack.appendAssumeCapacity(y);
            }
        }
        assert(stack.items.len == 0);
        assert(of[miss] == b);
    }
    assert(of.len == self.an.nb);
    return of;
}

/// The `tp<b>_s<k>` slot a store to array `id` in MIR block `bi` writes in
/// place (`tpInPlace`), or null when the store is outside every statement or
/// its statement does not cache `id` in place.
pub fn tpSlotAt(self: *const Gen, bi: u32, id: u32) ?struct { b: u32, k: u32 } {
    assert(id < self.lowered.mem_arrays.items.len);
    assert(self.tp_of_block.len == 0 or bi < self.tp_of_block.len);
    if (self.tp_of_block.len == 0) return null;
    const b = self.tp_of_block[bi];
    if (b == none_u32) return null;
    assert(b < self.lowered.timepoints.items.len);
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
    assert(bi < self.an.nb);
    assert(self.tp_of_block.len == 0 or self.tp_of_block.len == self.an.nb);
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
            assert(m.held != none_u32); // `tpInPlace` holds only a held array.
            const ty = if (m.ty == .integer) "i64" else "f64";
            self.cur.uses.inst = true;
            try self.ind(depth);
            // `updateState`'s slice stores the array in its field
            // (`render.inPlace`): a hit's cached version is copied there.
            if (render_array.inPlace(self, sl.array)) {
                assert(m.held < self.names.held_names.len);
                const f = self.names.held_names[m.held];
                if (gen_instance.dirtyTracked(self, sl.array))
                    try self.b("zTpHeld({s}, {d}, &inst.{s}, &p{d}, &inst.{s}__dirty);\n", .{ ty, m.len, f, sl.array, f })
                else
                    try self.b("zTpHeld({s}, {d}, &inst.{s}, &p{d}, null);\n", .{ ty, m.len, f, sl.array });
                continue;
            }
            try self.b("zTpFill({s}, {d}, &inst.tp{d}_s{d}, &p{d});\n", .{ ty, m.len, b, k, sl.array });
        }
    }
}

/// VerA's `vera_timepoint` (§2.9): each cached statement's `Instance` fields,
/// `tp<b>_t`/`tp<b>_k` (the time and `zTpKey` it was filled at; NaN when
/// dropped) and one `tp<b>_s<k>` per slot. Not history: `stateCtl` drops
/// them rather than restoring them (`zTpDrop`).
pub fn emitTpFields(self: *Gen) Error!void {
    assert(self.out.items.len != 0);
    const at = self.out.items.len;
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
    if (self.lowered.timepoints.items.len != 0) assert(self.out.items.len > at);
    if (self.lowered.timepoints.items.len == 0) assert(self.out.items.len == at);
}

/// VerA's `vera_timepoint` (§2.9): `zTpDrop`, which every entry point that
/// moves what a cached statement reads calls (`initState`, `setup`,
/// `updateState`, `stateCtl`), and `zTpStore`, which `eval` and `evalQ`
/// call on the core result: a statement that ran on a stale cache fills it.
pub fn emitTpHelpers(self: *Gen) Error!void {
    assert(self.out.items.len != 0);
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
    assert(std.mem.endsWith(u8, self.out.items, "}\n\n"));
}

// ---- private ----

/// Whether the body being emitted computes the `anew` that reads slot
/// `k` of statement `b` (the hit arm's `p<id> = &inst.tp<b>_s<k>`).
fn hitEmitted(self: *const Gen, b: u32, k: u32) bool {
    assert(b < self.lowered.timepoints.items.len);
    assert(k < self.lowered.timepoints.items[b].slots.len);
    for (self.an.i_op, 0..) |op, ii| {
        if (op != .anew) continue;
        const inst: Mir.Inst = @fromBackingInt(@intCast(ii));
        const tp = self.mir.instData(inst).anew.tp orelse continue;
        if (tp.block != b or tp.slot != k) continue;
        // As `cfg.emitStmt` decides it emits the statement.
        const v = self.an.i_res[ii];
        if (self.cur.plan.needed.isSet(@backingInt(v)) and !self.cur.plan.cached(v)) return true;
    }
    return false;
}
