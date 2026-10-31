//! Constant folding as a property of the MIR: `Analysis`'s alias snapshot +
//! `Lowered` in; `folds`, one `FoldColumn` per parameter policy, out. The
//! operators are the one constant kernel's (`opcode.fold`); this file only
//! decides which Values are leaves. The one writer of `folds`.
//!
//! LRM clauses this file's code cites: §3.2.2, §4.2, §4.2.12, §6.3.4, §9.15.
//!
//! Contents:
//! - `pub const FoldColumn = struct`, `FoldColumn.Kind = enum(u8)`, `FoldColumn.get(c: *const FoldColumn, v: Mir.Value) ?Const`
//! - `pub fn build(an: *Analysis, arena: Allocator, lowered: *const Lowered) Analysis.Error!void`
//! - `pub fn column(an: *const Analysis, arena: Allocator, lowered: *const Lowered, resolve_params: bool) Analysis.Error!FoldColumn`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const Const = Lowered.Const;
const Analysis = @import("Analysis.zig");

/// One fold policy's answers as two parallel arrays. A `?Const` is 24 bytes,
/// all for the string arm's slice, and nearly every fold is a number: `kind`
/// says which arm a Value folded to, `bits` holds an integer's or a real's
/// bits, or a string's index in `strs`. 9 bytes a Value instead of 24, in a
/// table codegen keeps for the whole emit. Invariant: `kind.len == bits.len`.
pub const FoldColumn = struct {
    /// Which `Const` arm each Value folded to, `.none` for no fold.
    kind: []Kind = &.{},
    /// The arm's payload; meaningless where `kind` is `.none`.
    bits: []u64 = &.{},
    /// The string folds, in the order they were found; borrowed slices.
    strs: std.ArrayList([]const u8) = .empty,

    /// Which arm of `Const` a row holds.
    pub const Kind = enum(u8) { none, int, real, str };

    /// Returns Value `v`'s fold, or null. The string arm borrows the MIR's
    /// string table. Asserts that `v` is a row of the column.
    pub fn get(c: *const FoldColumn, v: Mir.Value) ?Const {
        const i = @backingInt(v);
        assert(i < c.kind.len);
        const b = c.bits[i];
        return switch (c.kind[i]) {
            .none => null,
            .int => .{ .int = @bitCast(b) },
            .real => .{ .real = @bitCast(b) },
            .str => .{ .str = c.strs.items[@intCast(b)] },
        };
    }

    // ---- private ----

    fn set(c: *FoldColumn, arena: Allocator, i: usize, x: Const) Analysis.Error!void {
        assert(c.kind[i] == .none); // an answer is written once
        switch (x) {
            .int => |n| {
                c.kind[i] = .int;
                c.bits[i] = @bitCast(n);
            },
            .real => |r| {
                c.kind[i] = .real;
                c.bits[i] = @bitCast(r);
            },
            .str => |t| {
                c.kind[i] = .str;
                c.bits[i] = c.strs.items.len;
                try c.strs.append(arena, t);
            },
        }
        assert(c.kind[i] != .none);
    }
};

comptime {
    assert(@sizeOf(FoldColumn.Kind) == 1);
}

/// Fills both columns of `an.folds`, in `arena`. Asserts that the alias
/// snapshot is filled.
pub fn build(an: *Analysis, arena: Allocator, lowered: *const Lowered) Analysis.Error!void {
    assert(an.alias.len == an.nv);
    for (&an.folds, [_]bool{ false, true }) |*col, resolve_params| {
        col.* = try column(an, arena, lowered, resolve_params);
    }
    assert(an.folds[0].kind.len == an.nv);
    assert(an.folds[1].kind.len == an.nv);
}

/// Returns one column, to a fixpoint: an answer only goes from null to a
/// constant, and each sweep that changes something folds one more Value, so
/// at most `nv` sweeps change. `resolve_params` looks through a parameter to
/// its declared default. The column lives in `arena`.
pub fn column(an: *const Analysis, arena: Allocator, lowered: *const Lowered, resolve_params: bool) Analysis.Error!FoldColumn {
    var col: FoldColumn = .{
        .kind = try arena.alloc(FoldColumn.Kind, an.nv),
        .bits = try arena.alloc(u64, an.nv),
    };
    @memset(col.kind, .none);
    @memset(col.bits, 0);
    var sweeps: u32 = 0;
    var changed = true;
    while (changed) : (sweeps += 1) {
        assert(sweeps <= an.nv);
        changed = false;
        for (0..an.nv) |v| {
            if (col.kind[v] != .none) continue;
            const c = step(an, lowered, @fromBackingInt(@intCast(v)), &col, resolve_params) orelse continue;
            try col.set(arena, v, c);
            changed = true;
        }
    }
    assert(col.kind.len == col.bits.len);
    return col;
}

// ---- private ----

/// `v`'s fold given the current answers for its operands.
fn step(an: *const Analysis, lowered: *const Lowered, v: Mir.Value, col: *const FoldColumn, resolve_params: bool) ?Const {
    const mir = an.mir;
    switch (mir.valueDef(an.rv(v))) {
        .float_const => |x| return .{ .real = x },
        .int_const => |x| return .{ .int = x },
        // Only a Model default may look through a parameter: everywhere else
        // the value is whatever the host overrode it with.
        .param_ref => |p| return if (resolve_params) col.get(lowered.params.items[p].default) else null,
        .inst_result => |inst| switch (mir.instData(inst)) {
            .unary => |u| return Mir.opcode.fold(u.op, &.{col.get(u.operand) orelse return null}),
            .binary => |bn| return Mir.opcode.fold(bn.op, &.{
                col.get(bn.lhs) orelse return null,
                col.get(bn.rhs) orelse return null,
            }),
            // §4.2.12 `?:`, lazy as the kernel's `fold` is: only the taken
            // arm has to be foldable, so `w > 0 ? 1/w : 0` folds for w = 0.
            .ternary => |d| {
                const c = col.get(d.cond) orelse return null;
                return col.get(if (c.isTrue()) d.then_val else d.else_val);
            },
            // §9.15 `$simparam` in `Lowered.simparamAnswer`'s order. A host
            // field follows `.param_ref`'s rule: only a Model default looks
            // through it, and sees Table 9-27's declared value; every other
            // reader gets `model.<field>`, so the §3.4 field initializer and
            // the §6.3.4 `derive()` assignment split on `resolve_params`. A
            // run-time name has no card-time value.
            .call => |d| {
                if (d.callee != .@"$simparam" or d.args.len == 0) return null;
                const arg = mir.valueDef(an.rv(d.args[0]));
                if (arg != .str_const) return null;
                switch (lowered.simparamAnswer(arg.str_const, d.args.len > 1)) {
                    .host => |h| return if (resolve_params) .{ .real = h.default } else null,
                    .value => |x| return .{ .real = x },
                    .fallback => return col.get(d.args[1]),
                    .runtime, .unknown => return null,
                }
            },
            // §3.2.2 an array element is not a constant expression.
            .phi, .branch, .jump, .anew, .load, .store => return null,
        },
        .undef, .str_const, .block_param => return null,
    }
}
