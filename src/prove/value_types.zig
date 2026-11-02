//! Per-Value types: `Analysis`'s CFG tables + `Lowered` in; `def_block` (the
//! block defining each Value), `arr_of` (the §3.2.2 array each version
//! belongs to), `vty` (the emitted type) and `wide_w` (an IEEE 1364 §5.4
//! wide integer's bits) out. The one writer of those four tables.
//!
//! LRM clauses this file's code cites: §3.2, §3.2.2, §3.4, §4.2.1.1,
//! §4.2.1.2, §4.2.12.
//! IEEE 1364-2005 clauses cited: §5.4.
//!
//! Contents:
//! - `pub fn build(an: *Analysis, arena: Allocator, lowered: *const Lowered) Analysis.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const Analysis = @import("Analysis.zig");

const none = Analysis.none;

/// Fills `def_block`, `arr_of`, `vty` and `wide_w`, in that order, in
/// `arena`. Asserts that the CFG tables are filled.
pub fn build(an: *Analysis, arena: Allocator, lowered: *const Lowered) Analysis.Error!void {
    assert(an.alias.len == an.nv);
    assert(an.inst_off.len == an.nb + 1);
    an.def_block = try arena.alloc(u32, an.nv);
    @memset(an.def_block, none);
    for (0..an.nb) |bi| for (an.blockInstsFlat(@intCast(bi))) |inst| {
        const r = an.mir.instResult(inst);
        if (r != .undef) an.def_block[@backingInt(r)] = @intCast(bi);
    };
    try buildArrOf(an, arena, lowered);
    try buildTypes(an, arena, lowered);
    try buildWideWidths(an, arena, lowered);
    assert(an.vty.len == an.nv);
    assert(an.wide_w.len == an.nv);
}

// ---- private ----

/// `arr_of`: an `anew` names its array, a `store` inherits its operand's, a
/// phi takes any operand's (lowering joins only versions of one place). A
/// fixpoint, since a loop phi reads a store defined after it.
fn buildArrOf(an: *Analysis, arena: Allocator, lowered: *const Lowered) Analysis.Error!void {
    assert(an.alias.len == an.nv);
    an.arr_of = try arena.alloc(u32, an.nv);
    @memset(an.arr_of, none);
    if (lowered.mem_arrays.items.len == 0) return;
    // Bound: marking only adds, and each sweep that grows marks one more.
    var sweeps: u32 = 0;
    var grew = true;
    while (grew) : (sweeps += 1) {
        assert(sweeps <= an.nv);
        grew = false;
        for (Mir.Value.first_dynamic..an.nv) |i| {
            if (an.arr_of[i] != none) continue;
            const def = an.mir.valueDef(@fromBackingInt(@intCast(i)));
            if (def != .inst_result) continue;
            const inst = def.inst_result;
            const id: u32 = switch (an.mir.instData(inst)) {
                .anew => |d| d.array,
                .store => |d| an.arr_of[@backingInt(an.rv(d.arr))],
                .phi => |d| blk: {
                    for (0..d.count) |k| {
                        const a = an.arr_of[@backingInt(an.rv(an.mir.phiPair(inst, @intCast(k)).value))];
                        if (a != none) break :blk a;
                    }
                    break :blk none;
                },
                .unary, .binary, .ternary, .branch, .jump, .call, .load => none,
            };
            if (id == none) continue;
            assert(id < lowered.mem_arrays.items.len);
            an.arr_of[i] = id;
            grew = true;
        }
    }
}

/// `vty`: constants and opcodes decide themselves, then `select` and `phi`
/// copy an operand's, to a fixpoint. SSA construction creates a chain of
/// joins outer-first, so the outer phi precedes its operand in value order
/// and each sweep settles one more link. Terminates: every refined value
/// copies one other value's type (a functional graph); a chain settles a link
/// per sweep, and a cycle is uniform after one sweep.
fn buildTypes(an: *Analysis, arena: Allocator, lowered: *const Lowered) Analysis.Error!void {
    assert(an.arr_of.len == an.nv); // `buildArrOf` ran
    an.vty = try arena.alloc(Analysis.VTy, an.nv);
    for (0..an.nv) |v| {
        if (an.arr_of[v] != none) {
            an.vty[v] = if (lowered.mem_arrays.items[an.arr_of[v]].ty == .integer) .int else .real;
            continue;
        }
        an.vty[v] = switch (an.mir.valueDef(@fromBackingInt(@intCast(v)))) {
            .undef, .float_const, .block_param => .real,
            .int_const => .int,
            .str_const => .str,
            .param_ref => |p| Analysis.tyOfParam(lowered.params.items[p].ty),
            .inst_result => |inst| blk: {
                const op = an.mir.instOp(inst);
                if (op == .call) break :blk Mir.callee.ty(an.mir.instData(inst).call.callee);
                if (op == .phi or op == .select) break :blk .real; // refined below
                break :blk if (Mir.opIsInteger(op)) .int else .real;
            },
        };
    }
    // Bound: each changing sweep settles one more refined value.
    var sweeps: u32 = 0;
    var changed = true;
    while (changed) : (sweeps += 1) {
        assert(sweeps <= an.nv);
        changed = false;
        for (Mir.Value.first_dynamic..an.nv) |v| {
            const def = an.mir.valueDef(@fromBackingInt(@intCast(v)));
            if (def != .inst_result) continue;
            const inst = def.inst_result;
            const src: Mir.Value = switch (Mir.opClass(an.mir.instOp(inst))) {
                .ternary => an.rv(an.mir.instData(inst).ternary.then_val), // `select`, the only ternary
                .phi => blk: {
                    const d = an.mir.instData(inst).phi;
                    if (d.count == 0) continue;
                    const first = an.rv(an.mir.phiPair(inst, 0).value);
                    if (first == .undef) continue;
                    break :blk first;
                },
                .unary, .binary, .branch, .jump, .call, .anew, .load, .store => continue,
            };
            const t = an.vty[@backingInt(src)];
            if (an.vty[v] == t) continue;
            an.vty[v] = t;
            changed = true;
        }
    }
}

/// `wide_w`: from the defining call (`$wide`'s root node, a held variable's
/// or a timepoint slot's width) or, for a `select` or `phi`, from the operand
/// `vty` copied.
fn buildWideWidths(an: *Analysis, arena: Allocator, lowered: *const Lowered) Analysis.Error!void {
    assert(an.vty.len == an.nv); // `buildTypes` ran
    an.wide_w = try arena.alloc(u32, an.nv);
    @memset(an.wide_w, 0);
    if (lowered.wide_nodes.items.len == 0) return;
    // Bound: a width only goes from 0 to set, so each changing sweep sets one.
    var sweeps: u32 = 0;
    var changed = true;
    while (changed) : (sweeps += 1) {
        assert(sweeps <= an.nv);
        changed = false;
        for (Mir.Value.first_dynamic..an.nv) |v| {
            if (an.vty[v] != .wide or an.wide_w[v] != 0) continue;
            const def = an.mir.valueDef(@fromBackingInt(@intCast(v)));
            if (def != .inst_result) continue;
            const inst = def.inst_result;
            const w: u32 = switch (Mir.opClass(an.mir.instOp(inst))) {
                .ternary => an.wide_w[@backingInt(an.rv(an.mir.instData(inst).ternary.then_val))],
                .phi => an.wide_w[@backingInt(an.rv(an.mir.phiPair(inst, 0).value))],
                .call => callWidth(an, lowered, an.mir.instData(inst).call),
                .unary, .binary, .branch, .jump, .anew, .load, .store => 0,
            };
            if (w == 0) continue;
            an.wide_w[v] = w;
            changed = true;
        }
    }
    // The pair of `Analysis.wideWidth`: only a `.wide` value has bits.
    for (an.wide_w, an.vty) |w, t| if (w != 0) assert(t == .wide);
}

/// The width a `.wide` call states through its literal row arguments, or 0
/// while an argument is not one.
fn callWidth(an: *const Analysis, lowered: *const Lowered, d: @FieldType(Mir.InstData, "call")) u32 {
    assert(Mir.callee.ty(d.callee) == .wide); // asked only for a `.wide` value
    const k: usize = @intCast(intArg(an, d.args, 0) orelse return 0);
    return switch (d.callee) {
        .@"$wide" => lowered.wide_nodes.items[k].width,
        .@"$held_wide" => lowered.held_vars.items[k].width,
        .@"$tp_wide" => lowered.timepoints.items[k].slots[@intCast(intArg(an, d.args, 1) orelse return 0)].width,
        else => 0, // else: `Callee.table` types only these three `.wide`
    };
}

fn intArg(an: *const Analysis, args: []const Mir.Value, i: usize) ?i64 {
    if (i < args.len) assert(@backingInt(args[i]) < an.nv);
    return if (i < args.len) an.intConst(args[i]) else null;
}
