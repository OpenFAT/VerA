//! MIR instruction rows: operands in, an encoded `InstRow` (plus `extra`
//! words) appended to a block out, and the row back to its decoded
//! `InstData`. Encoder and decoder share this file so the per-class encoding
//! (`Mir.InstRow`'s table) has one home; `prove/verify.zig` decodes the raw
//! columns independently.
//!
//! Cites: §4.2 (operators), §4.2.12 (`?:`), §3.2.2 (arrays), §4.3, §4.5,
//! §4.7 and chapter 9 (calls), §5.8 (branch), §5.9 (jump), §2.9
//! (`vera_timepoint`).
//!
//! Contents:
//! - `pub fn emit(mir: *Mir, gpa: Allocator, block: Block, op: Opcode, ops: []const Value) Allocator.Error!Value`
//! - `pub fn emitAnew(mir: *Mir, gpa: Allocator, block: Block, array: u32) Allocator.Error!Value`
//! - `pub fn emitAnewCached(mir: *Mir, gpa: Allocator, block: Block, array: u32, tp: u32, slot: u32) Allocator.Error!Value`
//! - `pub fn emitBranch(mir: *Mir, gpa: Allocator, block: Block, cond: Value, then_block: Block, else_block: Block) Allocator.Error!Inst`
//! - `pub fn emitJump(mir: *Mir, gpa: Allocator, block: Block, target: Block) Allocator.Error!Inst`
//! - `pub fn emitCall(mir: *Mir, gpa: Allocator, block: Block, name: StrId, args: []const Value) Allocator.Error!Value`
//! - `pub fn emitPhi(mir: *Mir, gpa: Allocator, block: Block, pairs: []const PhiPair) Allocator.Error!Value`
//! - `pub fn setPhiPairs(mir: *Mir, gpa: Allocator, inst: Inst, pairs: []const PhiPair) Allocator.Error!void`
//! - `pub fn addExtra(mir: *Mir, gpa: Allocator, words: []const u32) Allocator.Error!u32`
//! - `pub fn instCount(mir: *const Mir) u32`
//! - `pub fn instRow(mir: *const Mir, inst: Inst) InstRow`
//! - `pub fn instTok(mir: *const Mir, inst: Inst) u32`
//! - `pub fn instOp(mir: *const Mir, inst: Inst) Opcode`
//! - `pub fn instBlock(mir: *const Mir, inst: Inst) Block`
//! - `pub fn instResult(mir: *const Mir, inst: Inst) Value`
//! - `pub fn instData(mir: *const Mir, inst: Inst) InstData`
//! - `pub fn phiPair(mir: *const Mir, inst: Inst, i: u32) PhiPair`
//! - `pub fn phiIn(mir: *const Mir, inst: Inst, from: Block) ?Value`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Mir = @import("Mir.zig");
const values = @import("mir_values.zig");
const Inst = Mir.Inst;
const Value = Mir.Value;
const Block = Mir.Block;
const StrId = Mir.StrId;
const Opcode = Mir.Opcode;
const InstRow = Mir.InstRow;
const InstData = Mir.InstData;
const PhiPair = Mir.PhiPair;
const Callee = Mir.Callee;

/// Appends a value-producing instruction to `block` and returns its result.
/// Invalidates every `InstIterator` (each `emit*` appends to `insts`) and,
/// for a ternary or store, the `args` of every earlier `instData` call view.
/// Asserts that `op`'s class takes `ops.len` operands (see `InstRow`'s
/// encoding table); phi, branch, jump, call and anew have their own builders.
pub fn emit(mir: *Mir, gpa: Allocator, block: Block, op: Opcode, ops: []const Value) Allocator.Error!Value {
    const want = Mir.opcode.operandCount(Mir.opClass(op)) orelse unreachable; // dedicated builders
    assert(ops.len == want);
    const b: u32 = switch (ops.len) {
        1 => 0,
        2 => @backingInt(ops[1]),
        3 => try addExtra(mir, gpa, &.{ @backingInt(ops[1]), @backingInt(ops[2]) }),
        else => unreachable, // operandCount is 1, 2 or 3
    };
    const v = try addResultInst(mir, gpa, block, .{ .op = op, .a = @backingInt(ops[0]), .b = b });
    assert(instOp(mir, @fromBackingInt(mir.defs.items(.payload)[@backingInt(v) - Value.first_dynamic])) == op);
    return v;
}

/// Returns a fresh version of §3.2.2 memory-backed array `array` (see
/// `Opcode.anew`). `array` indexes `Lowered.mem_arrays`.
pub fn emitAnew(mir: *Mir, gpa: Allocator, block: Block, array: u32) Allocator.Error!Value {
    const v = try addResultInst(mir, gpa, block, .{ .op = .anew, .a = array });
    assert(mir.insts.items(.b)[mir.insts.len - 1] == 0); // no cache slot
    return v;
}

/// Returns a version of `array` filled from slot `slot` of `vera_timepoint`
/// statement `tp`'s cache (`Lowered.TpBlock`). Invalidates earlier `instData`
/// call `args`.
pub fn emitAnewCached(mir: *Mir, gpa: Allocator, block: Block, array: u32, tp: u32, slot: u32) Allocator.Error!Value {
    const start = try addExtra(mir, gpa, &.{ tp, slot });
    // `b` is 1 + the pair's start, so 0 still reads as "no cache slot".
    const v = try addResultInst(mir, gpa, block, .{ .op = .anew, .a = array, .b = start + 1 });
    assert(mir.insts.items(.b)[mir.insts.len - 1] != 0);
    return v;
}

/// Appends a §5.8 two-way branch, the block's terminator. Asserts that both
/// targets are blocks of this Mir. Invalidates earlier `instData` call `args`.
pub fn emitBranch(mir: *Mir, gpa: Allocator, block: Block, cond: Value, then_block: Block, else_block: Block) Allocator.Error!Inst {
    assert(@backingInt(then_block) < mir.blockCount());
    assert(@backingInt(else_block) < mir.blockCount());
    try mir.insts.ensureUnusedCapacity(gpa, 1); // no orphan `extra` pair on a failed row
    const start = try addExtra(mir, gpa, &.{ @backingInt(then_block), @backingInt(else_block) });
    return addInst(mir, gpa, block, .{ .op = .branch, .a = @backingInt(cond), .b = start });
}

/// Appends a §5.9 unconditional jump, the block's terminator. Asserts that
/// `target` is a block of this Mir.
pub fn emitJump(mir: *Mir, gpa: Allocator, block: Block, target: Block) Allocator.Error!Inst {
    assert(@backingInt(target) < mir.blockCount());
    const inst = try addInst(mir, gpa, block, .{ .op = .jump, .a = @backingInt(target) });
    assert(mir.blockLast(block) == inst);
    return inst;
}

/// Appends a call by name (§4.3 math, §4.5 analog operator, §4.7 function,
/// ch9 system function) and returns its result. The one place a name becomes
/// a `Callee`; the raw name is kept for `.systf`. Invalidates every
/// `InstIterator` and the `args` of every earlier `instData` call view.
/// Asserts that `name` is interned here and `args` fits the count field
/// (the 24 bits above `callee_bits`).
pub fn emitCall(mir: *Mir, gpa: Allocator, block: Block, name: StrId, args: []const Value) Allocator.Error!Value {
    assert(args.len < 1 << (32 - Mir.callee_bits));
    assert(name != .none);
    try mir.extra.ensureUnusedCapacity(gpa, 1 + args.len);
    const start = try addExtra(mir, gpa, &.{@backingInt(name)});
    _ = try addExtra(mir, gpa, @ptrCast(args));
    const tag: u32 = @backingInt(Callee.fromName(mir.strings.get(name)));
    const v = try addResultInst(mir, gpa, block, .{
        .op = .call,
        .a = tag | @as(u32, @intCast(args.len)) << Mir.callee_bits,
        .b = start,
    });
    assert(mir.extra.items.len == start + 1 + args.len);
    return v;
}

/// Appends a phi and returns its result. `pairs` may be empty for an
/// incomplete phi (Braun et al.); fill it later with `setPhiPairs`.
/// Invalidates every `InstIterator` and earlier `instData` call `args`.
pub fn emitPhi(mir: *Mir, gpa: Allocator, block: Block, pairs: []const PhiPair) Allocator.Error!Value {
    assert(pairs.len <= Mir.extra_max / 2);
    const start = try addExtraPairs(mir, gpa, pairs);
    const v = try addResultInst(mir, gpa, block, .{ .op = .phi, .a = @intCast(pairs.len), .b = start });
    assert(mir.insts.items(.a)[mir.insts.len - 1] == pairs.len);
    return v;
}

/// Replaces a phi's operand list (`sealBlock` fills incomplete phis).
/// Asserts that `inst` is a phi. Invalidates slices previously returned by
/// `instData`. On error the phi keeps its old pairs.
pub fn setPhiPairs(mir: *Mir, gpa: Allocator, inst: Inst, pairs: []const PhiPair) Allocator.Error!void {
    // ponytail: appends a fresh region and abandons the old one, a few dead
    // u32s per filled phi. Compact the pool only if `extra` shows in a profile.
    assert(instOp(mir, inst) == .phi);
    const start = try addExtraPairs(mir, gpa, pairs);
    mir.insts.items(.a)[@backingInt(inst)] = @intCast(pairs.len);
    mir.insts.items(.b)[@backingInt(inst)] = start;
    assert(instData(mir, inst).phi.count == pairs.len);
}

/// Appends raw u32s and returns the start index. Prefer the typed builders.
/// Invalidates slices previously returned by `instData`. Asserts that the
/// pool stays under `Mir.extra_max` words.
pub fn addExtra(mir: *Mir, gpa: Allocator, words: []const u32) Allocator.Error!u32 {
    const start = mir.extra.items.len;
    assert(start + words.len < Mir.extra_max);
    try mir.extra.appendSlice(gpa, words);
    assert(mir.extra.items.len == start + words.len);
    return @intCast(start);
}

/// Returns the number of instruction rows, linked or orphaned: every
/// `Inst` below it names a row.
pub fn instCount(mir: *const Mir) u32 {
    assert(mir.insts.len <= Mir.insts_max);
    return @intCast(mir.insts.len);
}

/// Returns every column of `inst`, the cold `tok` and `next` included; a hot
/// walk decodes through `instData` instead. Asserts that `inst` is a row.
pub fn instRow(mir: *const Mir, inst: Inst) InstRow {
    assert(inst != .none);
    assert(@backingInt(inst) < mir.insts.len);
    return mir.insts.get(@backingInt(inst));
}

/// Returns the token `inst` was lowered from (the finiteness diagnostics'
/// location), or `no_tok` when it has no AST origin. Asserts that `inst` is
/// a row.
pub fn instTok(mir: *const Mir, inst: Inst) u32 {
    assert(inst != .none);
    assert(@backingInt(inst) < mir.insts.len);
    return mir.insts.items(.tok)[@backingInt(inst)];
}

/// Returns the opcode of `inst`. Asserts that `inst` is a row.
pub fn instOp(mir: *const Mir, inst: Inst) Opcode {
    assert(inst != .none);
    assert(@backingInt(inst) < mir.insts.len);
    return mir.insts.items(.op)[@backingInt(inst)];
}

/// Returns the block `inst` is linked into (for an unlinked row, the one it
/// was last linked into). Asserts that `inst` is a row.
pub fn instBlock(mir: *const Mir, inst: Inst) Block {
    assert(inst != .none);
    assert(@backingInt(inst) < mir.insts.len);
    return mir.insts.items(.block)[@backingInt(inst)];
}

/// Returns the Value `inst` defines, or `.undef` for a terminator. Asserts
/// that `inst` is a row.
pub fn instResult(mir: *const Mir, inst: Inst) Value {
    assert(inst != .none);
    assert(@backingInt(inst) < mir.insts.len);
    return mir.insts.items(.result)[@backingInt(inst)];
}

/// Returns the decoded view of `inst`. A call's `args` borrows `extra` and is
/// invalidated by any later append to the pool. Reads only the `op`/`a`/`b`
/// columns and `extra`. Asserts that `inst` is a row.
pub fn instData(mir: *const Mir, inst: Inst) InstData {
    assert(inst != .none);
    assert(@backingInt(inst) < mir.insts.len);
    const i = @backingInt(inst);
    const cols = mir.insts.slice();
    const op = cols.items(.op)[i];
    const a = cols.items(.a)[i];
    const b = cols.items(.b)[i];
    const x = mir.extra.items;
    return switch (Mir.opClass(op)) {
        .unary => .{ .unary = .{ .op = op, .operand = @fromBackingInt(a) } },
        .binary => .{ .binary = .{ .op = op, .lhs = @fromBackingInt(a), .rhs = @fromBackingInt(b) } },
        .ternary => .{ .ternary = .{
            .cond = @fromBackingInt(a),
            .then_val = @fromBackingInt(x[b]),
            .else_val = @fromBackingInt(x[b + 1]),
        } },
        .phi => .{ .phi = .{ .start = b, .count = a } },
        .branch => .{ .branch = .{
            .cond = @fromBackingInt(a),
            .then_block = @fromBackingInt(x[b]),
            .else_block = @fromBackingInt(x[b + 1]),
        } },
        .jump => .{ .jump = .{ .target = @fromBackingInt(a) } },
        .call => .{
            .call = .{
                .callee = @fromBackingInt(@as(u8, @truncate(a))),
                .name = mir.strings.get(@fromBackingInt(x[b])),
                // Borrowed slice into the payload pool; invalidated by further appends.
                .args = @ptrCast(x[b + 1 ..][0 .. a >> Mir.callee_bits]),
            },
        },
        .anew => .{ .anew = .{
            .array = a,
            .tp = if (b == 0) null else .{ .block = x[b - 1], .slot = x[b] },
        } },
        .load => .{ .load = .{ .op = op, .arr = @fromBackingInt(a), .index = @fromBackingInt(b) } },
        .store => .{ .store = .{
            .arr = @fromBackingInt(a),
            .index = @fromBackingInt(x[b]),
            .value = @fromBackingInt(x[b + 1]),
        } },
    };
}

/// Returns operand `i` of a phi (0..count-1 from `instData(...).phi`).
/// Asserts that `inst` is a phi and `i` is below its pair count.
pub fn phiPair(mir: *const Mir, inst: Inst, i: u32) PhiPair {
    const n = @backingInt(inst);
    assert(instOp(mir, inst) == .phi);
    assert(i < mir.insts.items(.a)[n]);
    const at = mir.insts.items(.b)[n] + i * 2;
    return .{
        .block = @fromBackingInt(mir.extra.items[at]),
        .value = @fromBackingInt(mir.extra.items[at + 1]),
    };
}

/// Returns phi `inst`'s incoming value on the edge from block `from`, or null
/// when no pair names `from`; the first pair wins if two do. O(pairs).
/// Asserts that `inst` is a phi.
pub fn phiIn(mir: *const Mir, inst: Inst, from: Block) ?Value {
    const d = instData(mir, inst).phi;
    for (0..d.count) |k| {
        const p = phiPair(mir, inst, @intCast(k));
        if (p.block == from) return p.value;
    }
    return null;
}

// ---- private ----

/// Appends `row` to the end of `block` and links it in, stamping its `tok`
/// and `block` columns. The caller set `row.result`.
fn addInst(mir: *Mir, gpa: Allocator, block: Block, row: InstRow) Allocator.Error!Inst {
    const i = mir.insts.len;
    assert(i < Mir.insts_max);
    assert(@backingInt(block) < mir.blocks.len);
    var stamped = row;
    stamped.tok = mir.cur_tok; // provenance: see InstRow.tok and cur_tok
    stamped.block = block;
    try mir.insts.append(gpa, stamped);
    const inst: Inst = @fromBackingInt(@intCast(i));

    const b = @backingInt(block);
    const last = mir.blocks.items(.last)[b];
    if (last == .none) {
        mir.blocks.items(.first)[b] = inst;
    } else {
        mir.insts.items(.next)[@backingInt(last)] = inst;
    }
    mir.blocks.items(.last)[b] = inst;
    assert(mir.insts.items(.next)[i] == .none);
    return inst;
}

/// Appends `row` to `block` with a fresh result Value, and returns it. Both
/// tables are reserved first, so on error no Value exists without its row.
fn addResultInst(mir: *Mir, gpa: Allocator, block: Block, row: InstRow) Allocator.Error!Value {
    try mir.insts.ensureUnusedCapacity(gpa, 1); // no result Value without its row
    const result = try values.addValue(mir, gpa, .inst_result, 0);
    var r = row;
    r.result = result;
    const inst = addInst(mir, gpa, block, r) catch unreachable; // capacity reserved above
    mir.defs.items(.payload)[@backingInt(result) - Value.first_dynamic] = @backingInt(inst);
    assert(instResult(mir, inst) == result);
    return result;
}

fn addExtraPairs(mir: *Mir, gpa: Allocator, pairs: []const PhiPair) Allocator.Error!u32 {
    const start = mir.extra.items.len;
    assert(start + pairs.len * 2 < Mir.extra_max);
    try mir.extra.ensureUnusedCapacity(gpa, pairs.len * 2);
    for (pairs) |p| {
        mir.extra.appendAssumeCapacity(@backingInt(p.block));
        mir.extra.appendAssumeCapacity(@backingInt(p.value));
    }
    assert(mir.extra.items.len == start + pairs.len * 2);
    return @intCast(start);
}

/// Fails unless every side table agrees with `defs` and `insts`: the
/// invariants a builder call must keep even when it fails part way.
fn expectConsistent(mir: *const Mir) !void {
    const fd = Value.first_dynamic;
    try std.testing.expectEqual(mir.defs.len, mir.alias.items.len);
    var fit = mir.fconst_map.iterator();
    while (fit.next()) |e| {
        try std.testing.expect(@backingInt(e.value_ptr.*) - fd < mir.defs.len);
        try std.testing.expectEqual(e.key_ptr.*, @as(u64, @bitCast(mir.valueDef(e.value_ptr.*).float_const)));
    }
    var iit = mir.iconst_map.iterator();
    while (iit.next()) |e| {
        try std.testing.expect(@backingInt(e.value_ptr.*) - fd < mir.defs.len);
        try std.testing.expectEqual(e.key_ptr.*, mir.valueDef(e.value_ptr.*).int_const);
    }
    var git = mir.guard_of.valueIterator();
    while (git.next()) |lit| try std.testing.expect(lit.* < mir.guard_lits.items.len);
    // Every pool word belongs to exactly one constant row, in pool order.
    var next_const: u32 = 0;
    for (mir.defs.items(.kind), mir.defs.items(.payload), 0..) |kind, payload, i| {
        switch (kind) {
            .float_const, .int_const => {
                try std.testing.expectEqual(next_const, payload);
                next_const += 1;
            },
            .inst_result => {
                try std.testing.expect(payload < mir.insts.len);
                try std.testing.expectEqual(@as(u32, @intCast(i + fd)), @backingInt(mir.instResult(@fromBackingInt(payload))));
            },
            .undef, .str_const, .param_ref, .block_param => {},
        }
    }
    try std.testing.expectEqual(mir.consts.items.len, next_const);
}

test "mir: const dedup, block chain, phi pairs, alias" {
    const gpa = std.testing.allocator;
    var mir: Mir = .{ .name = "diode" };
    defer mir.deinit(gpa);

    // sentinels + dedup (§4.2 constant expressions)
    try std.testing.expectEqual(Value.f_one, try mir.addFloatConst(gpa, 1.0));
    try std.testing.expectEqual(Value.zero, try mir.addIntConst(gpa, 0));
    const k = try mir.addFloatConst(gpa, 1.5);
    try std.testing.expectEqual(k, try mir.addFloatConst(gpa, 1.5));
    try std.testing.expectEqual(@as(f64, 1.5), mir.valueDef(k).float_const);
    // 0.0 and -0.0 are distinct bit patterns and must not collapse
    try std.testing.expect(try mir.addFloatConst(gpa, -0.0) != Value.f_zero);

    const entry = try mir.addBlock(gpa);
    const vd = try mir.addBlockParam(gpa, 0);
    const vs = try mir.addBlockParam(gpa, 1);
    const dv = try mir.emit(gpa, entry, .fsub, &.{ vd, vs });
    const id = try mir.emit(gpa, entry, .fmul, &.{ dv, k });
    try std.testing.expectEqual(@as(u32, 0), mir.valueDef(vd).block_param);

    // instruction chain + decoded view
    var it = mir.blockInsts(entry);
    const in0 = it.next().?;
    const in1 = it.next().?;
    try std.testing.expect(it.next() == null);
    try std.testing.expectEqual(dv, mir.instResult(in0));
    try std.testing.expectEqual(id, mir.instResult(in1));
    try std.testing.expectEqual(vs, mir.instData(in0).binary.rhs);
    try std.testing.expectEqual(in1, mir.valueDef(id).inst_result);

    // call (§4.3): name + args round-trip through the extra pool
    const nm = try mir.internString(gpa, "exp");
    try std.testing.expectEqual(nm, try mir.internString(gpa, "exp")); // deduped
    const e = try mir.emitCall(gpa, entry, nm, &.{id});
    const cd = mir.instData(mir.valueDef(e).inst_result).call;
    try std.testing.expectEqualStrings("exp", cd.name);
    try std.testing.expectEqual(Callee.systf, cd.callee); // bare `exp` is an opcode, not a callee
    try std.testing.expectEqualSlices(Value, &.{id}, cd.args);

    // phi (§5.8): empty then filled, and trivial-phi aliasing
    const join = try mir.addBlock(gpa);
    const p = try mir.emitPhi(gpa, join, &.{});
    const pi = mir.valueDef(p).inst_result;
    try std.testing.expectEqual(@as(u32, 0), mir.instData(pi).phi.count);
    try std.testing.expectEqual(join, mir.instBlock(pi));
    try std.testing.expectEqual(entry, mir.instBlock(in1));
    try mir.setPhiPairs(gpa, pi, &.{ .{ .block = entry, .value = id }, .{ .block = join, .value = e } });
    try std.testing.expectEqual(@as(u32, 2), mir.instData(pi).phi.count);
    try std.testing.expectEqual(e, mir.phiPair(pi, 1).value);
    try std.testing.expectEqual(id, mir.phiIn(pi, entry).?);
    try std.testing.expectEqual(@as(?Value, null), mir.phiIn(pi, @fromBackingInt(7)));

    mir.setAlias(p, e);
    try std.testing.expectEqual(e, mir.resolveAlias(p));
    try std.testing.expectEqual(id, mir.resolveAlias(id));

    try std.testing.expectEqual(@as(u32, 2), mir.blockCount());
}

test "mir: every builder encodes the operands its InstData view decodes" {
    const gpa = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(gpa);
    const entry = try mir.addBlock(gpa);
    const b1 = try mir.addBlock(gpa);
    const b2 = try mir.addBlock(gpa);
    try std.testing.expectEqual(Block.entry, entry);
    try std.testing.expectEqual(@as(u32, 3), mir.blockCount());
    try std.testing.expectEqual(Inst.none, mir.blockLast(b1));

    // §3.2.2 arrays: a fresh version, a cached one, a store and a load.
    mir.cur_tok = 42;
    const a0 = try mir.emitAnew(gpa, entry, 3);
    mir.cur_tok = Mir.no_tok;
    const a1 = try mir.emitAnewCached(gpa, entry, 3, 0, 5);
    const s = try mir.emit(gpa, entry, .store, &.{ a0, .zero, .f_one });
    const l = try mir.emit(gpa, entry, .iload, &.{ s, .one });
    const d0 = mir.instData(mir.valueDef(a0).inst_result).anew;
    try std.testing.expectEqual(@as(u32, 3), d0.array);
    try std.testing.expect(d0.tp == null);
    const d1 = mir.instData(mir.valueDef(a1).inst_result).anew;
    try std.testing.expectEqual(@as(u32, 0), d1.tp.?.block);
    try std.testing.expectEqual(@as(u32, 5), d1.tp.?.slot);
    const ds = mir.instData(mir.valueDef(s).inst_result).store;
    try std.testing.expectEqual(a0, ds.arr);
    try std.testing.expectEqual(Value.zero, ds.index);
    try std.testing.expectEqual(Value.f_one, ds.value);
    const dl = mir.instData(mir.valueDef(l).inst_result).load;
    try std.testing.expectEqual(Opcode.iload, dl.op);
    try std.testing.expectEqual(s, dl.arr);
    try std.testing.expectEqual(Value.one, dl.index);

    // Provenance and home block are stamped, never taken from the caller.
    const r0 = mir.instRow(mir.valueDef(a0).inst_result);
    try std.testing.expectEqual(@as(u32, 42), r0.tok);
    try std.testing.expectEqual(entry, r0.block);
    try std.testing.expectEqual(Mir.no_tok, mir.instTok(mir.valueDef(a1).inst_result));

    // §4.2.12 select, then the two terminators, which define no Value.
    const sel = try mir.emit(gpa, entry, .select, &.{ .one, .f_two, .f_ten });
    const dt = mir.instData(mir.valueDef(sel).inst_result).ternary;
    try std.testing.expectEqual(Value.one, dt.cond);
    try std.testing.expectEqual(Value.f_two, dt.then_val);
    try std.testing.expectEqual(Value.f_ten, dt.else_val);
    const br = try mir.emitBranch(gpa, entry, .one, b1, b2);
    try std.testing.expectEqual(Value.undef, mir.instResult(br));
    const dbr = mir.instData(br).branch;
    try std.testing.expectEqual(Value.one, dbr.cond);
    try std.testing.expectEqual(b1, dbr.then_block);
    try std.testing.expectEqual(b2, dbr.else_block);
    const j = try mir.emitJump(gpa, b1, b2);
    try std.testing.expectEqual(Value.undef, mir.instResult(j));
    try std.testing.expectEqual(b2, mir.instData(j).jump.target);
    try std.testing.expectEqual(j, mir.blockLast(b1));
    try std.testing.expectEqual(br, mir.blockLast(entry));

    // A call with no arguments, a known callee, and an unlisted `$` name.
    const t = try mir.emitCall(gpa, b2, try mir.internString(gpa, "$abstime"), &.{});
    const dc = mir.instData(mir.valueDef(t).inst_result).call;
    try std.testing.expectEqual(Callee.@"$abstime", dc.callee);
    try std.testing.expectEqual(@as(usize, 0), dc.args.len);
    const u = try mir.emitCall(gpa, b2, try mir.internString(gpa, "$my_task"), &.{ t, .one });
    const du = mir.instData(mir.valueDef(u).inst_result).call;
    try std.testing.expectEqual(Callee.systf, du.callee);
    try std.testing.expectEqualStrings("$my_task", du.name);
    try std.testing.expectEqualSlices(Value, &.{ t, .one }, du.args);
    // a0, a1, s, l, sel, br, j, t, u.
    try std.testing.expectEqual(@as(u32, 9), mir.instCount());
}

test "mir: a builder call that runs out of memory leaves every table consistent" {
    // Fault injection with recovery: fail allocation k, swallow the error,
    // keep building, and check the cross-table invariants after each run.
    var k: usize = 0;
    while (true) : (k += 1) {
        errdefer std.debug.print("failing allocation {d}\n", .{k});
        var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = k });
        const gpa = failing.allocator();
        var mir: Mir = .{};
        defer mir.deinit(gpa);
        const entry = mir.addBlock(gpa) catch null;
        for (0..3) |round| {
            const x: f64 = @floatFromInt(round);
            _ = mir.addFloatConst(gpa, 1.5 + x) catch {};
            _ = mir.addIntConst(gpa, 7 + @as(i64, @intCast(round))) catch {};
            const b = entry orelse continue;
            const v = mir.emit(gpa, b, .fneg, &.{.f_one}) catch continue;
            mir.addGuardLit(gpa, mir.valueDef(v).inst_result, v, true) catch {};
            _ = mir.emitCall(gpa, b, mir.internString(gpa, "exp") catch continue, &.{v}) catch {};
        }
        try expectConsistent(&mir);
        if (!failing.has_induced_failure) break;
    }
}

test "mir: building leaks nothing when any allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            var mir: Mir = .{};
            defer mir.deinit(gpa);
            try mir.reserve(gpa, 4, 4, 4);
            const entry = try mir.addBlock(gpa);
            const join = try mir.addBlock(gpa);
            const k = try mir.addFloatConst(gpa, 1.5);
            const n = try mir.addIntConst(gpa, 9);
            const s = try mir.addStrConst(gpa, "tran");
            const v = try mir.emit(gpa, entry, .fmul, &.{ k, try mir.addParamRef(gpa, 0) });
            try mir.addGuardLit(gpa, mir.valueDef(v).inst_result, n, true);
            _ = try mir.emitCall(gpa, entry, try mir.internString(gpa, "$strobe"), &.{ s, v });
            _ = try mir.emitBranch(gpa, entry, n, join, join);
            const p = try mir.emitPhi(gpa, join, &.{});
            try mir.setPhiPairs(gpa, mir.valueDef(p).inst_result, &.{.{ .block = entry, .value = v }});
        }
    }.run, .{});
}
