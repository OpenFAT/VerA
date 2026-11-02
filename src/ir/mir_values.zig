//! The MIR value table: a constant, string, parameter or probe in, a `Value`
//! handle out (`defs` row, `consts` bits, `alias` parent), and a handle back
//! to its `Def`. Real and integer constants are deduped by exact bits; the
//! ten commonest are sentinels with no row. The trivial-phi alias forest is a
//! union-find over the same rows.
//!
//! Cites: §2.7 (string literals), §3.4 (parameters), §4.2 (constant
//! expressions), §4.4 (probes).
//!
//! Contents:
//! - `pub fn addValue(mir: *Mir, gpa: Allocator, kind: Mir.DefKind, payload: u32) Allocator.Error!Value`
//! - `pub fn addFloatConst(mir: *Mir, gpa: Allocator, x: f64) Allocator.Error!Value`
//! - `pub fn addIntConst(mir: *Mir, gpa: Allocator, x: i64) Allocator.Error!Value`
//! - `pub fn addStrConst(mir: *Mir, gpa: Allocator, bytes: []const u8) Allocator.Error!Value`
//! - `pub fn addParamRef(mir: *Mir, gpa: Allocator, param: u32) Allocator.Error!Value`
//! - `pub fn addBlockParam(mir: *Mir, gpa: Allocator, unknown: u32) Allocator.Error!Value`
//! - `pub fn internString(mir: *Mir, gpa: Allocator, bytes: []const u8) Allocator.Error!Mir.StrId`
//! - `pub fn valueDef(mir: *const Mir, value: Value) Mir.Def`
//! - `pub fn valueKind(mir: *const Mir, value: Value) Mir.DefKind`
//! - `pub fn valueCount(mir: *const Mir) u32`
//! - `pub fn setAlias(mir: *Mir, from: Value, to: Value) void`
//! - `pub fn hasAlias(mir: *const Mir, value: Value) bool`
//! - `pub fn resolveAlias(mir: *const Mir, value: Value) Value`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Mir = @import("Mir.zig");
const Value = Mir.Value;

const fd = Value.first_dynamic;

/// Appends a dynamic Value row of `kind` and returns its handle; the result
/// of an instruction, a constant or a leaf. `alias` grows with `defs`, both
/// reserved first, so on error neither has changed. Module-internal: the
/// typed `add*` builders below and `mir_insts.zig` call it.
/// Asserts that the handle space (`Mir.values_max`) is not exhausted.
pub fn addValue(mir: *Mir, gpa: Allocator, kind: Mir.DefKind, payload: u32) Allocator.Error!Value {
    assert(mir.defs.len == mir.alias.items.len);
    assert(mir.defs.len < Mir.values_max);
    const v: Value = @fromBackingInt(@as(u32, @intCast(mir.defs.len)) + fd);
    try mir.defs.ensureUnusedCapacity(gpa, 1);
    try mir.alias.ensureUnusedCapacity(gpa, 1);
    mir.defs.appendAssumeCapacity(.{ .kind = kind, .payload = payload });
    mir.alias.appendAssumeCapacity(v); // self-parent = no alias
    assert(mir.defs.len == mir.alias.items.len);
    return v;
}

/// Returns the §4.2 real constant `x`, deduped by exact bits, so -0.0 and
/// 0.0 differ and a NaN payload survives. Common literals map onto the
/// sentinels so two spellings of `1.0` are the same Value in every
/// compilation. On error the Mir is unchanged.
pub fn addFloatConst(mir: *Mir, gpa: Allocator, x: f64) Allocator.Error!Value {
    const bits: u64 = @bitCast(x);
    if (floatSentinel(bits)) |s| return s;
    // Reserve before `addValue`, so a failed add leaves no entry behind.
    try mir.fconst_map.ensureUnusedCapacity(gpa, 1);
    if (mir.fconst_map.get(bits)) |v| return v;
    const v = try addConst(mir, gpa, .float_const, bits);
    mir.fconst_map.putAssumeCapacityNoClobber(bits, v);
    assert(@as(u64, @bitCast(valueDef(mir, v).float_const)) == bits);
    return v;
}

/// Returns the §4.2 integer constant `x`, deduped; 0, 1 and -1 are sentinels.
/// On error the Mir is unchanged.
pub fn addIntConst(mir: *Mir, gpa: Allocator, x: i64) Allocator.Error!Value {
    switch (x) {
        0 => return .zero,
        1 => return .one,
        -1 => return .neg_one,
        else => {}, // else: every other integer gets a row
    }
    try mir.iconst_map.ensureUnusedCapacity(gpa, 1);
    if (mir.iconst_map.get(x)) |v| return v;
    const v = try addConst(mir, gpa, .int_const, @bitCast(x));
    mir.iconst_map.putAssumeCapacityNoClobber(x, v);
    assert(valueDef(mir, v).int_const == x);
    return v;
}

/// Returns a §2.7 string literal Value. `bytes` must outlive the Mir. The
/// string itself is deduped by the interner; the Value wrapper is not (a
/// handful per module, and identical strings are interchangeable).
pub fn addStrConst(mir: *Mir, gpa: Allocator, bytes: []const u8) Allocator.Error!Value {
    const s = try internString(mir, gpa, bytes);
    assert(s != .none);
    const v = try addValue(mir, gpa, .str_const, @backingInt(s));
    assert(valueKind(mir, v) == .str_const);
    return v;
}

/// Returns a §3.4 parameter reference. `param` indexes `Lowered.params`.
pub fn addParamRef(mir: *Mir, gpa: Allocator, param: u32) Allocator.Error!Value {
    const v = try addValue(mir, gpa, .param_ref, param);
    assert(valueDef(mir, v).param_ref == param);
    return v;
}

/// Returns a §4.4 signal-access probe. `unknown` indexes the solver unknown vector
/// (Lowered.nodes → the generated `U` enum, i.e. codegen's `x[unknown]`).
/// V(a,b) lowers to fsub of two probes; a branch-current unknown gets its own
/// `nodes` row.
pub fn addBlockParam(mir: *Mir, gpa: Allocator, unknown: u32) Allocator.Error!Value {
    const v = try addValue(mir, gpa, .block_param, unknown);
    assert(valueDef(mir, v).block_param == unknown);
    return v;
}

/// Interns a name into this Mir's table. `bytes` is borrowed and must outlive
/// the Mir. Idempotent, so the same callee name is one StrId no matter how
/// many call sites use it.
pub fn internString(mir: *Mir, gpa: Allocator, bytes: []const u8) Allocator.Error!Mir.StrId {
    const id = try mir.strings.intern(gpa, bytes);
    assert(id != .none);
    assert(std.mem.eql(u8, mir.strings.get(id), bytes));
    return id;
}

/// Returns the decoded definition of `value`. A `.str_const` slice borrows
/// the string table. Asserts that `value` is a sentinel or names a `defs`
/// row.
pub fn valueDef(mir: *const Mir, value: Value) Mir.Def {
    switch (value) {
        .undef => return .undef,
        .f_zero => return .{ .float_const = 0.0 },
        .f_one => return .{ .float_const = 1.0 },
        .f_neg_one => return .{ .float_const = -1.0 },
        .f_two => return .{ .float_const = 2.0 },
        .f_ten => return .{ .float_const = 10.0 },
        .f_inf => return .{ .float_const = std.math.inf(f64) },
        .zero => return .{ .int_const = 0 },
        .one => return .{ .int_const = 1 },
        .neg_one => return .{ .int_const = -1 },
        _ => {},
    }
    const row_index = @backingInt(value) - fd;
    assert(row_index < mir.defs.len);
    const row = mir.defs.get(row_index);
    return switch (row.kind) {
        .undef => .undef,
        .float_const => .{ .float_const = @bitCast(mir.consts.items[row.payload]) },
        .int_const => .{ .int_const = @bitCast(mir.consts.items[row.payload]) },
        .str_const => .{ .str_const = mir.strings.get(@fromBackingInt(row.payload)) },
        .param_ref => .{ .param_ref = row.payload },
        .block_param => .{ .block_param = row.payload },
        .inst_result => .{ .inst_result = @fromBackingInt(row.payload) },
    };
}

/// Returns the kind of `value`, read from the `kind` column without decoding
/// the payload. Asserts that `value` is a sentinel or names a `defs` row.
pub fn valueKind(mir: *const Mir, value: Value) Mir.DefKind {
    return switch (value) {
        .undef => .undef,
        .f_zero, .f_one, .f_neg_one, .f_two, .f_ten, .f_inf => .float_const,
        .zero, .one, .neg_one => .int_const,
        _ => blk: {
            assert(@backingInt(value) - fd < mir.defs.len);
            break :blk mir.defs.items(.kind)[@backingInt(value) - fd];
        },
    };
}

/// Returns the size of the Value handle space: every handle below it is a
/// sentinel or names a `defs` row. A table indexed by Value has this length.
pub fn valueCount(mir: *const Mir) u32 {
    assert(mir.defs.len <= Mir.values_max);
    const n: u32 = @intCast(mir.defs.len + fd);
    assert(n >= fd);
    return n;
}

/// Records `from` ≡ `to` (ssa.zig trivial-phi removal); overwrites.
/// Asserts that `from` is a dynamic Value (a phi result), `to` names a
/// Value of this Mir (it may be a sentinel), and `from != to`.
pub fn setAlias(mir: *Mir, from: Value, to: Value) void {
    assert(from != to); // a self-alias would make resolveAlias non-terminating
    assert(@backingInt(from) >= fd);
    assert(@backingInt(to) < valueCount(mir));
    mir.alias.items[@backingInt(from) - fd] = to;
    assert(hasAlias(mir, from));
}

/// Returns whether `value` was collapsed onto another (codegen skips its decl).
/// Asserts that `value` is a sentinel or names a `defs` row.
pub fn hasAlias(mir: *const Mir, value: Value) bool {
    const i = @backingInt(value);
    if (i < fd) return false;
    assert(i - fd < mir.alias.items.len);
    return mir.alias.items[i - fd] != value;
}

/// Returns the Value `value` aliases to at the end of its chain. Union-find
/// with path compression: amortized near O(1).
/// Takes `*const` but writes `alias` (compression), so it is not safe to call
/// concurrently on one Mir; the answer is the same either way. Asserts the
/// chain has no cycle.
pub fn resolveAlias(mir: *const Mir, value: Value) Value {
    if (@backingInt(value) < fd) return value;
    const parent = mir.alias.items;
    assert(@backingInt(value) - fd < parent.len);

    var root = value;
    var hops: usize = 0;
    while (@backingInt(root) >= fd) : (hops += 1) {
        assert(hops <= parent.len); // cycle ⇒ SSA bug
        const next = parent[@backingInt(root) - fd];
        if (next == root) break;
        root = next;
    }

    var v = value;
    var steps: usize = 0;
    while (v != root) : (steps += 1) {
        assert(steps < hops); // the second walk retraces the first
        const next = parent[@backingInt(v) - fd];
        parent[@backingInt(v) - fd] = root;
        v = next;
    }
    assert(!hasAlias(mir, root));
    return root;
}

// ---- private ----

/// Appends the bits of a real or integer constant to `consts` and a row
/// naming them. Reserves first, so on error neither table has changed.
fn addConst(mir: *Mir, gpa: Allocator, kind: Mir.DefKind, bits: u64) Allocator.Error!Value {
    assert(kind == .float_const or kind == .int_const);
    assert(mir.consts.items.len <= mir.defs.len); // every const has a row
    try mir.consts.ensureUnusedCapacity(gpa, 1);
    const v = try addValue(mir, gpa, kind, @intCast(mir.consts.items.len));
    mir.consts.appendAssumeCapacity(bits);
    return v;
}

/// The sentinel spelling `bits`, if one does.
fn floatSentinel(bits: u64) ?Value {
    return switch (bits) {
        @as(u64, @bitCast(@as(f64, 0.0))) => .f_zero,
        @as(u64, @bitCast(@as(f64, 1.0))) => .f_one,
        @as(u64, @bitCast(@as(f64, -1.0))) => .f_neg_one,
        @as(u64, @bitCast(@as(f64, 2.0))) => .f_two,
        @as(u64, @bitCast(@as(f64, 10.0))) => .f_ten,
        @as(u64, @bitCast(std.math.inf(f64))) => .f_inf,
        else => null, // else: any other bit pattern is no sentinel
    };
}

test addFloatConst {
    const gpa = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(gpa);

    // The six real sentinels spend no `defs` row.
    const sentinels = [_]struct { f64, Value }{
        .{ 0.0, .f_zero },
        .{ 1.0, .f_one },
        .{ -1.0, .f_neg_one },
        .{ 2.0, .f_two },
        .{ 10.0, .f_ten },
        .{ std.math.inf(f64), .f_inf },
    };
    for (sentinels) |s| try std.testing.expectEqual(s[1], try mir.addFloatConst(gpa, s[0]));
    try std.testing.expectEqual(@as(usize, 0), mir.defs.len);

    // -inf and -0.0 are not sentinels: each gets one row and keeps its bits.
    const neg_inf = try mir.addFloatConst(gpa, -std.math.inf(f64));
    const neg_zero = try mir.addFloatConst(gpa, -0.0);
    try std.testing.expect(neg_inf != neg_zero);
    try std.testing.expectEqual(@as(u64, 0x8000_0000_0000_0000), @as(u64, @bitCast(mir.valueDef(neg_zero).float_const)));
    try std.testing.expectEqual(neg_zero, try mir.addFloatConst(gpa, -0.0));

    // Dedup is by bits, so two NaN payloads are two Values and one payload is
    // one, and the payload survives the round trip.
    const nan_a: f64 = @bitCast(@as(u64, 0x7ff8_0000_0000_0001));
    const nan_b: f64 = @bitCast(@as(u64, 0x7ff8_0000_0000_0002));
    const va = try mir.addFloatConst(gpa, nan_a);
    const vb = try mir.addFloatConst(gpa, nan_b);
    try std.testing.expect(va != vb);
    try std.testing.expectEqual(va, try mir.addFloatConst(gpa, nan_a));
    try std.testing.expectEqual(@as(u64, 0x7ff8_0000_0000_0001), @as(u64, @bitCast(mir.valueDef(va).float_const)));
    try std.testing.expectEqual(@as(usize, 4), mir.defs.len);
    try std.testing.expectEqual(Mir.DefKind.float_const, mir.valueKind(va));
}

test addIntConst {
    const gpa = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(gpa);

    try std.testing.expectEqual(Value.zero, try mir.addIntConst(gpa, 0));
    try std.testing.expectEqual(Value.one, try mir.addIntConst(gpa, 1));
    try std.testing.expectEqual(Value.neg_one, try mir.addIntConst(gpa, -1));
    try std.testing.expectEqual(@as(usize, 0), mir.defs.len);

    // The i64 extremes round-trip, and each is one Value however often asked.
    for ([_]i64{ std.math.maxInt(i64), std.math.minInt(i64), 2 }) |x| {
        const v = try mir.addIntConst(gpa, x);
        try std.testing.expectEqual(v, try mir.addIntConst(gpa, x));
        try std.testing.expectEqual(x, mir.valueDef(v).int_const);
        try std.testing.expectEqual(Mir.DefKind.int_const, mir.valueKind(v));
    }
    try std.testing.expectEqual(@as(usize, 3), mir.defs.len);
    // An integer 2 is not the real sentinel `f_two`.
    try std.testing.expect(try mir.addIntConst(gpa, 2) != Value.f_two);
}

test "consts: a real and an integer with the same bits are two Values, each keeping its kind" {
    // The 5-byte row moves the bits to `consts`; the oracle is the bit
    // pattern itself: 0x4000_0000_0000_0000 is 2.0 as a real and 2^62 as an
    // integer, so a pool that conflated the two kinds would decode one as
    // the other.
    const gpa = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(gpa);
    const bits: u64 = 0x4000_0000_0000_0001;
    const r = try mir.addFloatConst(gpa, @bitCast(bits));
    const i = try mir.addIntConst(gpa, @bitCast(bits));
    try std.testing.expect(r != i);
    try std.testing.expectEqual(bits, @as(u64, @bitCast(mir.valueDef(r).float_const)));
    try std.testing.expectEqual(@as(i64, @bitCast(bits)), mir.valueDef(i).int_const);
    try std.testing.expectEqual(@as(usize, 2), mir.consts.items.len);
    // A string, a parameter and a probe take a row but no pool word.
    _ = try mir.addStrConst(gpa, "x");
    _ = try mir.addParamRef(gpa, 3);
    try std.testing.expectEqual(@as(usize, 2), mir.consts.items.len);
    try std.testing.expectEqual(@as(u32, Value.first_dynamic + 4), mir.valueCount());
}

test valueDef {
    // Every sentinel decodes without a `defs` row: an empty Mir has none.
    const mir: Mir = .{};
    const want = [_]struct { Value, Mir.Def }{
        .{ .undef, .undef },
        .{ .f_zero, .{ .float_const = 0.0 } },
        .{ .f_one, .{ .float_const = 1.0 } },
        .{ .f_neg_one, .{ .float_const = -1.0 } },
        .{ .f_two, .{ .float_const = 2.0 } },
        .{ .f_ten, .{ .float_const = 10.0 } },
        .{ .f_inf, .{ .float_const = std.math.inf(f64) } },
        .{ .zero, .{ .int_const = 0 } },
        .{ .one, .{ .int_const = 1 } },
        .{ .neg_one, .{ .int_const = -1 } },
    };
    try std.testing.expectEqual(@as(usize, Value.first_dynamic), want.len);
    for (want, 0..) |w, i| {
        try std.testing.expectEqual(@as(u32, @intCast(i)), @backingInt(w[0]));
        try std.testing.expectEqual(w[1], mir.valueDef(w[0]));
        try std.testing.expectEqual(std.meta.activeTag(w[1]), mir.valueKind(w[0]));
        try std.testing.expect(!mir.hasAlias(w[0]));
    }
}

test "mir: string, parameter and probe Values round-trip their payloads" {
    const gpa = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(gpa);

    // The text is interned once; the Value wrapper is not deduped.
    const a = try mir.addStrConst(gpa, "tran");
    const b = try mir.addStrConst(gpa, "tran");
    try std.testing.expect(a != b);
    try std.testing.expectEqualStrings("tran", mir.valueDef(a).str_const);
    try std.testing.expectEqual(@as(usize, 1), mir.strings.texts.items.len);

    const p = try mir.addParamRef(gpa, 7);
    const u = try mir.addBlockParam(gpa, std.math.maxInt(u32));
    try std.testing.expectEqual(@as(u32, 7), mir.valueDef(p).param_ref);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), mir.valueDef(u).block_param);
    try std.testing.expectEqual(Mir.DefKind.param_ref, mir.valueKind(p));
    try std.testing.expectEqual(Mir.DefKind.block_param, mir.valueKind(u));
    // Dynamic Values number from `first_dynamic` in creation order.
    try std.testing.expectEqual(@as(u32, Value.first_dynamic), @backingInt(a));
    try std.testing.expectEqual(@as(u32, Value.first_dynamic + 3), @backingInt(u));
}

test resolveAlias {
    // Model-based: the union-find against a naive walk of the same parents.
    // As in ssa.zig and ifconv.zig, only a root (an unaliased Value) is ever
    // aliased, and only onto an older Value or a sentinel, so no cycle forms.
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xa11a5);
    const r = prng.random();
    var mir: Mir = .{};
    defer mir.deinit(gpa);
    const n = 64;
    var naive: [n]Value = undefined;
    for (&naive, 0..) |*p, i| {
        p.* = try mir.addFloatConst(gpa, @floatFromInt(i + 100));
        try std.testing.expectEqual(@as(u32, @intCast(i + Value.first_dynamic)), @backingInt(p.*));
    }
    for (0..200) |_| {
        const i = r.uintLessThan(usize, n);
        const from: Value = @fromBackingInt(@intCast(i + Value.first_dynamic));
        if (naive[i] != from) continue; // not a root
        const j = r.uintLessThan(usize, i + 1);
        const to: Value = if (j == i) .f_one else @fromBackingInt(@intCast(j + Value.first_dynamic));
        try std.testing.expect(!mir.hasAlias(from));
        mir.setAlias(from, to);
        naive[i] = to;
        try std.testing.expect(mir.hasAlias(from));
        for (0..n) |k| {
            const v: Value = @fromBackingInt(@intCast(k + Value.first_dynamic));
            var root = v;
            while (@backingInt(root) >= Value.first_dynamic) {
                const next = naive[@backingInt(root) - Value.first_dynamic];
                if (next == root) break;
                root = next;
            }
            try std.testing.expectEqual(root, mir.resolveAlias(v));
            // Path compression: after a resolve, the row names its root.
            if (root != v) try std.testing.expectEqual(root, mir.alias.items[k]);
        }
    }
    // A sentinel resolves to itself and is never aliased.
    try std.testing.expectEqual(Value.f_inf, mir.resolveAlias(.f_inf));
}
