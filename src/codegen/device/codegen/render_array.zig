//! A §3.2.2 array value -> its storage and text: whether an array is stored
//! as `S` or plain `f64`/`i64`, read in place from its `Instance` field
//! (copy-on-write) or stored in place, the load `a[i]` with §3.2.2's zero
//! outside the array, the `anew`/`store` statements, and a held array's
//! end-of-block version as the core returns it.
//! Cites: §3.2.2, §5.10.
//!
//! Contents:
//! - `pub fn cow(self: *const Gen, id: u32) bool`
//! - `pub fn inPlace(self: *const Gen, id: u32) bool`
//! - `pub fn arrElemTy(self: *Gen, id: u32) Error![]const u8`
//! - `pub fn renderLoad(self: *Gen, inst: Mir.Inst) Error!void`
//! - `pub fn emitArrayStmt(self: *Gen, inst: Mir.Inst, depth: u32) Error!void`
//! - `pub fn renderArrayOut(self: *Gen, v: Mir.Value) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const float_lanes = @import("float/lanes.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_mask = @import("mask.zig");
const gen_instance = @import("instance.zig");
const gen_timepoint = @import("timepoint.zig");
const family = @import("family.zig");
const Mir = @import("ir").Mir;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const gen_render = @import("render.zig");

/// Returns whether array `id` is read in place from its `Instance` field
/// until first written.
pub fn cow(self: *const Gen, id: u32) bool {
    assert(id < self.lowered.mem_arrays.items.len);
    return self.lowered.mem_arrays.items[id].held != none_u32 and arrPlain(self, id);
}

/// Returns whether the slice being emitted stores held array `id` straight
/// into its `Instance` field (`plan.Core.in_place`, `state.zig`).
pub fn inPlace(self: *const Gen, id: u32) bool {
    assert(id < self.lowered.mem_arrays.items.len);
    // `inPlaceArrays` returns one flag per array, or none at all.
    if (self.core.in_place.len != 0) assert(self.core.in_place.len == self.lowered.mem_arrays.items.len);
    return self.core.in_place.len != 0 and self.core.in_place[id];
}

/// Returns the element type array `id` is stored as.
pub fn arrElemTy(self: *Gen, id: u32) Error![]const u8 {
    assert(id < self.lowered.mem_arrays.items.len);
    assert(self.arr_s.len == self.lowered.mem_arrays.items.len);
    if (self.lowered.mem_arrays.items[id].ty == .integer) return "i64";
    if (!self.arr_s[id]) return "f64";
    return family.ofText(self, self.arrMask(id));
}

/// Writes a load `a[i]`, with §3.2.2's zero for an index outside the array.
pub fn renderLoad(self: *Gen, inst: Mir.Inst) Error!void {
    assert(self.mir.instOp(inst) == .fload or self.mir.instOp(inst) == .iload);
    const d = self.mir.instData(inst).load;
    if (d.op == .iload) {
        try self.b("zArrLd(i64, ", .{});
        _ = try arrRef(self, d.arr);
        try self.b(", ", .{});
        try gen_render.renderVal(self, d.index, .int);
        return self.b(", 0)", .{});
    }
    assert(d.op == .fload);
    const at = self.out.items.len;
    try self.b("zArrLd(S, ", .{});
    if (try arrRef(self, d.arr)) {
        assert(self.out.items.len > at + "zArrLd(S, ".len);
        // Plain storage: re-spell the head, the index follows either way.
        const name = try self.arena.dupe(u8, self.out.items[at + "zArrLd(S, ".len ..]);
        self.out.shrinkRetainingCapacity(at);
        try self.b("S.con(zArrLd(f64, {s}, ", .{name});
        try gen_render.renderVal(self, d.index, .int);
        return self.b(", 0.0))", .{});
    }
    // The element type is the storage's `zOf`, and so is its zero. A version
    // whose elements depend on no unknown is read lane-free: the storage's
    // mask is the union over every version, and its lanes are zero here, so
    // `zStrip` drops them exactly instead of narrowing a lane `zTo` refuses.
    const id = self.an.arrOf(self.an.rv(d.arr)).?;
    const free = std.mem.allEqual(u64, family.mask(self, self.mir.instResult(inst)), 0) and !std.mem.allEqual(u64, self.arrMask(id), 0);
    const tail = try self.arena.dupe(u8, self.out.items[at + "zArrLd(S, ".len ..]);
    self.out.shrinkRetainingCapacity(at);
    if (free) try self.b("zStrip(S, ", .{});
    try self.b("zArrLd({s}, {s}, ", .{ try arrElemTy(self, id), tail });
    try gen_render.renderVal(self, d.index, .int);
    try self.b(", zTo(S, 0x{f}, S.con(0.0)))", .{gen_mask.hex(self.arrMask(id), false)});
    if (free) try self.b(")", .{});
}

/// Writes the statement an `anew` or `store` is, at its place in the block.
pub fn emitArrayStmt(self: *Gen, inst: Mir.Inst, depth: u32) Error!void {
    assert(self.mir.instOp(inst) == .anew or self.mir.instOp(inst) == .store);
    try self.ind(depth);
    switch (self.mir.instData(inst)) {
        .anew => |d| {
            const m = self.lowered.mem_arrays.items[d.array];
            const plain = arrPlain(self, d.array);
            // VerA's `vera_timepoint` (§2.9): the version a cached statement
            // left, from its `Instance` slot; a copy-on-write array reads it
            // in place, as a held one reads its own field.
            if (d.tp) |tp| {
                self.cur.uses.inst = true;
                float_lanes.instPin(self);
                if (cow(self, d.array)) return self.b("p{d} = &inst.tp{d}_s{d};\n", .{ d.array, tp.block, tp.slot });
                if (plain) return self.b("a{d} = inst.tp{d}_s{d};\n", .{ d.array, tp.block, tp.slot });
                return self.b("for (&a{d}, inst.tp{d}_s{d}) |*zd, zs| zd.* = zTo(S, 0x{f}, S.con(zs));\n", .{ d.array, tp.block, tp.slot, gen_mask.hex(self.arrMask(d.array), false) });
            }
            if (m.uninit) {
                // `(* vera_scratch = "uninit" *)` (§2.9): `a<id>` stays the
                // `undefined` it was declared, and the author writes every
                // element before reading it. Under runtime safety a broken
                // promise reads NaN (`S.con` carries zero lanes; `scale` by
                // NaN makes each one NaN) or minInt instead of stale bytes.
                // Otherwise an empty asm that may have written the array
                // ("memory" clobber, its address as input) freezes it: LLVM
                // must treat the contents as defined but unknown, so a broken
                // promise reads a stable garbage value, not undef/poison.
                if (m.ty == .integer) {
                    try self.b("if (std.debug.runtime_safety) @memset(&a{d}, std.math.minInt(i64))", .{d.array});
                } else if (plain) {
                    try self.b("if (std.debug.runtime_safety) @memset(&a{d}, std.math.nan(f64))", .{d.array});
                } else {
                    try self.b("if (std.debug.runtime_safety) @memset(&a{d}, zTo(S, 0x{f}, S.con(std.math.nan(f64))).scale(std.math.nan(f64)))", .{ d.array, gen_mask.hex(self.arrMask(d.array), false) });
                }
                return self.b(" else asm volatile (\"\" : : [p] \"r\" (&a{d}) : .{{ .memory = true }});\n", .{d.array});
            }
            // §3.2 every evaluation starts it at zero.
            if (m.held == none_u32) {
                if (!plain) return self.b("@memset(&a{d}, zTo(S, 0x{f}, S.con(0.0)));\n", .{ d.array, gen_mask.hex(self.arrMask(d.array), false) });
                return self.b("@memset(&a{d}, {s});\n", .{ d.array, if (m.ty == .integer) "0" else "0.0" });
            }
            // §5.10 a held array starts from what the last accepted
            // evaluation left in its `Instance` field.
            self.cur.uses.inst = true;
            float_lanes.instPin(self); // a held array is one instance's
            const f = self.names.held_names[m.held];
            if (plain) return self.b("p{d} = &inst.{s};\n", .{ d.array, f });
            return self.b("for (&a{d}, inst.{s}) |*zd, zs| zd.* = zTo(S, 0x{f}, S.con(zs));\n", .{ d.array, f, gen_mask.hex(self.arrMask(d.array), false) });
        },
        .store => |d| {
            const id = self.an.arrOf(d.arr).?;
            const m = self.lowered.mem_arrays.items[id];
            // Only a §5.10 held array has an `Instance` field to store into.
            if (inPlace(self, id)) assert(m.held != none_u32);
            const r = self.an.rv(self.mir.instResult(inst));
            if (self.cur.emitting_common and self.core.held_only.len != 0 and self.core.held_only[@backingInt(r)]) {
                self.cur.uses.held = true;
                try self.b("if (held) ", .{});
            }
            const ty = try arrElemTy(self, id);
            // A store made from another store's version writes storage that
            // one has already copied in; the seed, or a join that may be it,
            // goes through `zArrW`.
            const after_store = switch (self.mir.valueDef(self.an.rv(d.arr))) {
                .inst_result => |di| self.mir.instOp(di) == .store,
                else => false, // else: an array version is an instruction result
            };
            // VerA's `vera_timepoint` (§2.9): inside a statement that caches
            // the array, the copy goes to its slot (`zArrWT`), always through
            // the pointer check: a store before the statement may have
            // copied it into `a<id>` already.
            const tp = gen_timepoint.tpSlotAt(self, @backingInt(self.mir.instBlock(inst)), id);
            if (tp != null) self.cur.uses.inst = true;
            if (inPlace(self, id) and gen_instance.dirtyTracked(self, id))
                try self.b("zArrStD({s}, p{d}, &inst.{s}__dirty, ", .{ ty, id, self.names.held_names[m.held] })
            else if (inPlace(self, id))
                try self.b("zArrSt({s}, p{d}, ", .{ ty, id })
            else if (tp) |s|
                try self.b("zArrSt({s}, zArrWT({s}, {d}, &inst.tp{d}_s{d}, &a{d}, &p{d}), ", .{ ty, ty, m.len, s.b, s.k, id, id })
            else if (cow(self, id) and !after_store)
                try self.b("zArrSt({s}, zArrW({s}, {d}, &a{d}, &p{d}), ", .{ ty, ty, m.len, id, id })
            else
                try self.b("zArrSt({s}, &a{d}, ", .{ ty, id });
            try gen_render.renderVal(self, d.index, .int);
            try self.b(", ", .{});
            if (m.ty == .integer) {
                try gen_render.renderVal(self, d.value, .int);
            } else if (arrPlain(self, id)) {
                // No load reads this element's derivative, so only the value
                // is kept: a scalar collapse, which pins.
                float_lanes.pinLanes(self, d.value);
                try self.b("(", .{});
                try gen_render.renderVal(self, d.value, .real);
                try self.b(").val()", .{});
            } else {
                try family.openTo(self, self.arrMask(id));
                try gen_render.renderVal(self, d.value, .real);
                try self.b(")", .{});
            }
            return self.b(");\n", .{});
        },
        .unary, .binary, .ternary, .phi, .branch, .jump, .call, .load => unreachable, // `emitBlockInsts` sends only array versions
    }
}

/// Writes a held array's end-of-block version as the core's plain
/// `[len]f64`/`[len]i64`.
pub fn renderArrayOut(self: *Gen, v: Mir.Value) Error!void {
    assert(self.an.arrOf(v) != null);
    const id = self.an.arrOf(v).?;
    if (cow(self, id)) return self.b("p{d}.*", .{id});
    if (arrPlain(self, id)) return self.b("a{d}", .{id});
    try self.b("zArrVal({s}, {d}, &a{d})", .{ try arrElemTy(self, id), self.lowered.mem_arrays.items[id].len, id });
}

// ---- private ----

/// Is array `id`'s storage plain `f64`/`i64` rather than `S`?
fn arrPlain(self: *const Gen, id: u32) bool {
    assert(id < self.lowered.mem_arrays.items.len);
    assert(self.arr_s.len == self.lowered.mem_arrays.items.len);
    return self.lowered.mem_arrays.items[id].ty == .integer or !self.arr_s[id];
}

/// Write a pointer to the storage array version `v` is read from; true when
/// it holds plain values (a cached version always does).
fn arrRef(self: *Gen, v0: Mir.Value) Error!bool {
    assert(self.an.arrOf(self.an.rv(v0)) != null);
    assert(self.an.arrOf(self.an.rv(v0)) != null);
    const v = self.an.rv(v0);
    if (self.cur.plan.cached(v)) {
        try self.b("&c.f{d}", .{self.core.lo_idx[@backingInt(v)]});
        return true;
    }
    const id = self.an.arrOf(v).?;
    try self.b("{s}{d}", .{ if (cow(self, id)) "p" else "&a", id });
    return arrPlain(self, id);
}
