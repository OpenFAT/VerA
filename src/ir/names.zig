//! Source units in, stable emitted declaration names out, so `zig
//! -fincremental` (which tracks declarations by name) re-analyzes only units
//! that changed. Also fixes the canonical unit order and sanitizes identifiers
//! (§2.7, §2.8.1) injectively. No name may be built from a MIR or `nodes`
//! index: inserting one source line would renumber every later name.
//!
//! Units are §5.6 contributions (named by their §4.4 access and node pair,
//! §1.3.1.1 ground as `0`) and §4.5 operator, §5.10 event and §9.17
//! kernel-control calls (named by their callee).
//!
//! It is also the one speller of the field names two stages must agree on:
//! the `Model` fields of a §7.3 discrete input (`snapField`, `wordField`,
//! `xzField`), which lowering declares and the testbench writes, and the
//! §5.10 held `Instance` field (`heldField`), which codegen declares and the
//! testbench reads.
//!
//! LRM clauses this file's code cites: §1.3.1.1, §2.8.1, §3.6.1.2, §4.4,
//! §4.5, §5.6, §5.6.7, §5.10, §7.3.1, §7.3.2, §8.5.3.6, §9.4, §9.17.

const std = @import("std");
const Mir = @import("mir.zig");
const Lowered = @import("lowered.zig");
const opdb = @import("op.zig");

/// Identifies one emitted source unit: §5.6 contribution or §4.5 analog operator.
/// One row per unit, built once per compilation by `enumerateUnits` (18 on
/// psp103, 43 on hisimhv), so its slice-wide `target` costs nothing that a
/// string handle would win back.
pub const Unit = struct {
    role: Role,
    /// Contribution: access function plus node pair (`I_drain_source`).
    /// Operator: its callee name. An ordinal appears only via `disambig`.
    ///
    /// Must already be a `_`-joined path of `sanitize`d leaves: `unitName`
    /// does not re-sanitize, because sanitizing a joined path is not
    /// injective ({"a_b","c"} and {"a","b_c"} would collide).
    target: []const u8,
    /// Nonzero only for the later members of a (role, target) collision group.
    disambig: u32 = 0,
    /// The operator `call` a `.analog_op` unit was enumerated from; `.none`
    /// for every other role.
    inst: Mir.Inst = .none,
    /// That call's operator (`Mir.callee.opKind`); `.none` for every other role.
    op: opdb.OpKind = .none,

    // Budget: the 16-byte slice, two 4-byte columns and two one-byte tags,
    // padded to the slice's 8-byte alignment.
    comptime {
        std.debug.assert(@sizeOf(Unit) <= 32);
    }
};

/// What an emitted unit is. `display` and `common` are never produced by
/// `enumerateUnits`: an entry in the canonical order would desynchronize
/// `proof.Verdict.unit_modes`. codegen names them directly with `unitName`.
pub const Role = enum {
    /// A §5.6 contribution.
    analog,
    /// A §4.5 analog operator, §5.10 event or §9.17 kernel-control call.
    analog_op,
    /// §9.4 the module's display tasks, chained into one root by
    /// `Lower.finishDisplays`; one per module.
    display,
    /// The declaration holding subexpressions shared by several units.
    common,
};

// Sanitization: Verilog-A identifier to Zig identifier, injectively.
// §2.8.1 escaped identifiers carry arbitrary printable bytes, and `_` is the
// separator alphabet. The escape marker is `Z`, so a sanitized leaf never
// begins, ends or doubles a `_`, and every name has a unique parse:
//
//   name  := leaf "__" role "__" leaf-path ("__" digits)?
//   leaf  := [A-Za-z0-9_]*   with no "__", no leading/trailing "_"
//   escape:= "Z" hex hex     (so a literal 'Z' is escaped to "Z5a")

fn hexDigit(v: u8) u8 {
    return "0123456789abcdef"[v & 0xf];
}

/// Appends `name` to `w`, escaping every byte that would break injectivity or
/// Zig's identifier grammar.
fn sanitizeInto(w: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    for (name, 0..) |c, i| {
        const bare = switch (c) {
            'a'...'z', 'A'...'Y' => true,
            // A Zig identifier may not start with a digit.
            '0'...'9' => i != 0,
            // Interior `_` survives (`v_ds`); a leading, trailing or doubled
            // one is escaped so no leaf produces or touches the separator.
            '_' => i != 0 and i + 1 < name.len and name[i + 1] != '_',
            else => false, // 'Z' included: it is the escape marker
        };
        if (bare) {
            try w.writeByte(c);
        } else {
            try w.writeAll(&.{ 'Z', hexDigit(c >> 4), hexDigit(c) });
        }
    }
}

/// Sanitizes one identifier leaf into `buf` and returns the written prefix.
/// Injective: distinct inputs give distinct outputs. Every source name must
/// pass through this before it enters an emitted declaration name. Needs up to
/// `3 * name.len + 1` bytes; fails with `error.NoSpaceLeft` otherwise.
pub fn sanitize(buf: []u8, name: []const u8) error{NoSpaceLeft}![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    sanitizeInto(&w, name) catch return error.NoSpaceLeft;
    // Annex B does not reserve Zig keywords or primitives (`pub`, `u32`), so
    // a model may use them as names. A trailing `Z` marks them rather than
    // `@"..."`, because consumers interpolate names bare (`model.{s}`); it
    // stays injective, since `sanitizeInto` emits `Z` only as `Z<hi><lo>`.
    const leaf = w.buffered();
    if (std.zig.Token.keywords.has(leaf) or std.zig.primitives.isPrimitive(leaf))
        w.writeByte('Z') catch return error.NoSpaceLeft;
    return w.buffered();
}

/// `sanitize` into a buffer from `a` sized for `name` (3n + 1 bytes), so a
/// name of any length fits (VAMS 2.8, VD-054; #29). The result is a prefix of
/// that buffer, so `a.free` cannot take it: `a` should be an arena.
pub fn sanitizeAlloc(a: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]const u8 {
    return sanitize(try a.alloc(u8, 3 * name.len + 1), name) catch unreachable;
}

test "sanitize escapes Zig keywords and primitives" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("pubZ", try sanitize(&buf, "pub"));
    try std.testing.expectEqualStrings("fnZ", try sanitize(&buf, "fn"));
    try std.testing.expectEqualStrings("errorZ", try sanitize(&buf, "error"));
    try std.testing.expectEqualStrings("f64Z", try sanitize(&buf, "f64"));
    // Non-reserved names are untouched.
    try std.testing.expectEqualStrings("vth", try sanitize(&buf, "vth"));
    try std.testing.expectEqualStrings("public", try sanitize(&buf, "public"));
    // Injectivity at the boundary: a source name that already ends in `Z` has
    // that `Z` escaped, so it cannot collide with the keyword marker.
    const pubZ_src = try sanitize(&buf, "pubZ");
    try std.testing.expect(!std.mem.eql(u8, "pubZ", pubZ_src));
}

// The cross-stage field names. Each returns the source-level name, which the
// declaring and the reading site pass through `sanitize` like any other
// name, except `heldField`, whose two leaves it sanitizes itself.

/// §8.5.3.6 the region-1b snapshot of discrete input `name`: its `Model` field.
pub fn snapField(a: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]u8 {
    return a.print("{s}__1b", .{name});
}

/// §7.3.1 word `k` (`k >= 1`) of a `reg` input wider than 32 bits: its `Model`
/// field. Word 0 is the input's own field, `name`.
pub fn wordField(a: std.mem.Allocator, name: []const u8, k: usize) std.mem.Allocator.Error![]u8 {
    std.debug.assert(k != 0);
    return a.print("{s}__w{d}", .{ name, k });
}

/// §7.3.2 the unknown (x/z) plane of a four-state discrete input: its `Model` field.
pub fn xzField(a: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]u8 {
    return a.print("{s}__xz", .{name});
}

/// §5.10 held variable `name` of module `module`: its `Instance` field,
/// `<module>__held__<name>`, both leaves `sanitize`d. The grammar `unitName`
/// builds, with `held` where a role word would go: `Role` deliberately
/// excludes it (a held variable is not an emitted source unit), and no
/// enumerated unit can spell that segment, so the two name spaces cannot
/// meet. A leaf is injective and a module variable's name is unique in its
/// scope, so the whole key is. Leaves its two sanitized leaves allocated in
/// `a` beside the result: `a` should be an arena.
pub fn heldField(a: std.mem.Allocator, module: []const u8, name: []const u8) std.mem.Allocator.Error![]u8 {
    return a.print("{s}__held__{s}", .{ try sanitizeAlloc(a, module), try sanitizeAlloc(a, name) });
}

test "the cross-stage field names" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("myZ20mod__held__pubZ", try heldField(a, "my mod", "pub"));
    try std.testing.expectEqualStrings("x__1b", try snapField(a, "x"));
    try std.testing.expectEqualStrings("x__w2", try wordField(a, "x", 2));
    try std.testing.expectEqualStrings("x__xz", try xzField(a, "x"));
}

/// Writes `<module>__<role>__<target>[__<disambig>]` into `buf` and returns it.
/// No part is a position, and the suffix appears only for `disambig > 0`, so
/// a collision group's first member keeps its name when another is added.
/// Fails with `error.NoSpaceLeft` past `buf.len`; `unitNameAlloc` sizes it.
pub fn unitName(
    buf: []u8,
    module: []const u8,
    unit: Unit,
) error{NoSpaceLeft}![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    sanitizeInto(&w, module) catch return error.NoSpaceLeft;
    // `role` is a closed set, already a legal leaf; `target` is pre-sanitized
    // (see Unit.target).
    w.print("__{t}__{s}", .{ unit.role, unit.target }) catch return error.NoSpaceLeft;
    if (unit.disambig != 0) w.print("__{d}", .{unit.disambig}) catch return error.NoSpaceLeft;
    return w.buffered();
}

/// `unitName` into a buffer from `a` sized for this name, so a module name
/// of any length fits (VAMS 2.8, VD-054; #29). The result is a prefix of
/// that buffer, so `a.free` cannot take it: `a` should be an arena.
pub fn unitNameAlloc(a: std.mem.Allocator, module: []const u8, unit: Unit) std.mem.Allocator.Error![]const u8 {
    // The module at 3x, the role and target between `__`s, and a u32's digits.
    const n = 3 * module.len + 2 + @tagName(unit.role).len + 2 + unit.target.len + 2 + 10;
    return unitName(try a.alloc(u8, n), module, unit) catch unreachable;
}

/// Writes §5.6 contribution `c`'s unit target, `V_<hi>_<lo>` or `I_<hi>_<lo>`.
fn contribTarget(w: *std.Io.Writer, lowered: *const Lowered, c: Lowered.Contribution) std.Io.Writer.Error!void {
    // §4.4: the two access roles are closed even when a user nature renames
    // the access identifier (§3.6.1.2), so V/I is the canonical spelling.
    try w.writeAll(switch (c.access) {
        .potential => "V",
        .flow => "I",
    });
    for ([2]u32{ c.hi, c.lo }) |n| {
        try w.writeByte('_');
        // §1.3.1.1 ground is not a `nodes` row. "0" cannot collide: a real
        // net's leading digit is escaped.
        if (n == Lowered.ground) try w.writeByte('0') else try sanitizeInto(w, lowered.nodeName(n));
    }
}

/// Returns the module's units in the canonical order, which
/// `proof.Verdict.unit_modes` and codegen's declaration emission both index:
///
///   1. every `Lowered.contributions[i]` in table order, role `.analog`
///      (§5.6.7 indirect statements are never deduped, so several to one
///      branch form a collision group);
///   2. every §4.5 operator, §5.10 event and §9.17 kernel-control `call`, in
///      block creation order then `Mir.blockInsts` order, role `.analog_op`. The
///      §9.17 `$bound_step`/`$discontinuity` calls come last, in that order.
///
/// The order is a pure function of the source; `disambig` counts 0, 1, 2 in
/// it. The slice and every `Unit.target` are allocated from `gpa`, which
/// should be the per-compilation arena.
pub fn enumerateUnits(gpa: std.mem.Allocator, mir: *const Mir, lowered: *const Lowered) ![]Unit {
    var units: std.ArrayList(Unit) = .empty;
    errdefer units.deinit(gpa);

    // (1) §5.6 contributions: node names, never `nodes` rows.
    for (lowered.contributions.items) |c| {
        var w: std.Io.Writer.Allocating = .init(gpa);
        contribTarget(&w.writer, lowered, c) catch return error.OutOfMemory;
        try units.append(gpa, .{ .role = .analog, .target = try w.toOwnedSlice() });
    }

    // (2) §4.5 stateful operators. `Instance` state fields are keyed on these
    // names, so adding an unrelated operator must not rename existing state.
    for (0..mir.blockCount()) |bi| {
        const block: Mir.Block = @fromBackingInt(@intCast(bi));
        var insts = mir.blockInsts(block);
        while (insts.next()) |inst| {
            if (mir.instOp(inst) != .call) continue;
            const callee = mir.instData(inst).call.callee;
            // An `OpKind` other than `.none` owns state or a monitored event.
            const k = Mir.callee.opKind(callee);
            if (k == .none) continue;
            // The `$` of a §9.17 task is dropped rather than escaped to `Z24`.
            // No collision: every other target here is an annex B keyword.
            const spelling = @tagName(callee);
            const bare = if (spelling[0] == '$') spelling[1..] else spelling;
            // A synthetic variant `op$variant` (`absdelay$quad`) shares `op`'s
            // state, so it takes `op`'s name: hosts find state by field name.
            const op_name = bare[0 .. std.mem.findScalar(u8, bare, '$') orelse bare.len];
            const t = try sanitizeAlloc(gpa, op_name);
            try units.append(gpa, .{ .role = .analog_op, .target = t, .inst = inst, .op = k });
        }
    }

    assignDisambig(units.items);
    return units.toOwnedSlice(gpa);
}

/// Asserts the canonical order `enumerateUnits` documents: (a) proof rated
/// exactly the contribution units, (b) they are the prefix of `units`, and
/// (c) only `.analog_op` units follow. A violation would make codegen read
/// another unit's float mode, and `.optimized` on an unproven unit is
/// undefined behaviour in release builds. Debug-only, O(units).
pub fn assertCanonicalOrder(units: []const Unit, lowered: *const Lowered, unit_modes_len: usize) void {
    const n_contrib = lowered.contributions.items.len;
    std.debug.assert(unit_modes_len == n_contrib); // (a)
    std.debug.assert(units.len >= n_contrib);
    for (units[0..n_contrib]) |u| std.debug.assert(u.role == .analog); // (b)
    for (units[n_contrib..]) |u| std.debug.assert(u.role == .analog_op); // (c)
}

/// Sets each unit's `disambig` to the number of earlier units sharing its
/// (role, target).
// ponytail: O(n²) over units. A module has tens of them; switch to a
// StringHashMap keyed on role++target if a model ever shows up with thousands.
fn assignDisambig(units: []Unit) void {
    for (units, 0..) |*u, i| {
        var n: u32 = 0;
        for (units[0..i]) |prev| {
            if (prev.role == u.role and std.mem.eql(u8, prev.target, u.target)) n += 1;
        }
        u.disambig = n;
    }
}

// ponytail: an operator's target is its callee name, so N `ddt`s in one module
// take disambig 0..N-1 and inserting one renames the later ones. Qualifying the
// target with the enclosing contribution needs lower.zig to record that link.

/// The part of `prove.Fixture` these tests read, a hand-built `Mir` and
/// `Lowered`: `prove` imports `ir`, so its fixture is out of reach here.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    mir: Mir = .{ .name = "mymod" },
    lowered: Lowered = undefined,

    fn init(f: *Fixture, net_names: []const []const u8) !void {
        f.lowered = .{};
        const a = f.arena.allocator();
        for (net_names) |n|
            try f.lowered.nodes.append(a, .{ .name = n, .kind = .net, .disc = "", .dir = .unspecified });
        _ = try f.mir.addBlock(a);
    }

    fn deinit(f: *Fixture) void {
        f.arena.deinit();
    }

    fn alloc(f: *Fixture) std.mem.Allocator {
        return f.arena.allocator();
    }
};
const nets = [_][]const u8{ "drain", "gate", "source" };

fn names(f: *Fixture, out: *std.ArrayList([]const u8)) !void {
    const a = f.alloc();
    const units = try enumerateUnits(a, &f.mir, &f.lowered);
    for (units) |u| {
        try out.append(a, try unitNameAlloc(a, f.mir.name, u));
    }
}

test "inserting a contribution for a different target renames nothing" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&nets);
    defer f.deinit();
    const a = f.arena.allocator();

    // I(drain,source) and V(gate,gnd)
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 0, .lo = 2 });
    try f.lowered.contributions.append(a, .{ .access = .potential, .hi = 1, .lo = Lowered.ground });

    var before: std.ArrayList([]const u8) = .empty;
    try names(&f, &before);
    try std.testing.expectEqualStrings("mymod__analog__I_drain_source", before.items[0]);
    try std.testing.expectEqualStrings("mymod__analog__V_gate_0", before.items[1]);

    // Every pre-existing name must come back byte-identical.
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 1, .lo = 2 });

    var after: std.ArrayList([]const u8) = .empty;
    try names(&f, &after);
    try std.testing.expectEqual(@as(usize, 3), after.items.len);
    for (before.items, after.items[0..before.items.len]) |b, x| {
        try std.testing.expectEqualStrings(b, x);
    }
    try std.testing.expectEqualStrings("mymod__analog__I_gate_source", after.items[2]);
}

test "same-target collisions take group-local ordinals, first stays bare" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&nets);
    defer f.deinit();
    const a = f.arena.allocator();

    const slew = try f.mir.internString(a, "slew");
    const transition = try f.mir.internString(a, "transition");
    const ln = try f.mir.internString(a, "ln"); // not an analog operator: no unit
    _ = try f.mir.emitCall(a, .entry, slew, &.{});
    _ = try f.mir.emitCall(a, .entry, ln, &.{});
    _ = try f.mir.emitCall(a, .entry, transition, &.{});
    _ = try f.mir.emitCall(a, .entry, slew, &.{});

    var got: std.ArrayList([]const u8) = .empty;
    try names(&f, &got);
    try std.testing.expectEqual(@as(usize, 3), got.items.len);
    try std.testing.expectEqualStrings("mymod__analog_op__slew", got.items[0]);
    try std.testing.expectEqualStrings("mymod__analog_op__transition", got.items[1]);
    try std.testing.expectEqualStrings("mymod__analog_op__slew__1", got.items[2]);
}

test "sanitize is injective on the names that would otherwise collide" {
    var b0: [64]u8 = undefined;
    var b1: [64]u8 = undefined;

    // readable common case survives untouched
    try std.testing.expectEqualStrings("v_ds", try sanitize(&b0, "v_ds"));

    // pairs that a naive `_`-join would map together
    const pairs = [_][2][]const u8{
        .{ "a_b", "a" }, // vs a later leaf "b"
        .{ "_a", "Za" },
        .{ "a_", "a" },
        .{ "a__b", "a_b" },
        .{ "bus[0]", "bus0" },
        .{ "Z", "Z5a" },
        .{ "0", "Z30" },
    };
    for (pairs) |p| {
        const s0 = try sanitize(&b0, p[0]);
        const s1 = try sanitize(&b1, p[1]);
        try std.testing.expect(!std.mem.eql(u8, s0, s1));
        // and no sanitized leaf may contain the "__" separator or touch its edges
        try std.testing.expect(std.mem.find(u8, s0, "__") == null);
        try std.testing.expect(s0[0] != '_' and s0[s0.len - 1] != '_');
    }
}

test "names never overflow silently" {
    var small: [8]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, unitName(&small, "a_very_long_module", .{
        .role = .analog,
        .target = "I_a_b",
    }));
}

test "§9.17 kernel-control units drop the `$` and stay after the operator units" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&nets);
    defer f.deinit();
    const a = f.arena.allocator();

    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 0, .lo = 2 });
    const slew = try f.mir.internString(a, "slew");
    const bs = try f.mir.internString(a, "$bound_step");
    const disc = try f.mir.internString(a, "$discontinuity");
    _ = try f.mir.emitCall(a, .entry, slew, &.{});
    // `Lower.finishKernelCtl` appends these last, in this order.
    _ = try f.mir.emitCall(a, .entry, bs, &.{});
    _ = try f.mir.emitCall(a, .entry, disc, &.{});

    var got: std.ArrayList([]const u8) = .empty;
    try names(&f, &got);
    try std.testing.expectEqual(@as(usize, 4), got.items.len);
    // Contributions first: proof indexes `unit_modes` by this order.
    try std.testing.expectEqualStrings("mymod__analog__I_drain_source", got.items[0]);
    try std.testing.expectEqualStrings("mymod__analog_op__slew", got.items[1]);
    // The `$` is dropped, not escaped to `Z24`.
    try std.testing.expectEqualStrings("mymod__analog_op__bound_step", got.items[2]);
    try std.testing.expectEqualStrings("mymod__analog_op__discontinuity", got.items[3]);
}

/// Fails unless `s` is a sanitized leaf: a Zig identifier that is neither a
/// keyword nor a primitive, with no `__` and no `_` at either end.
fn expectLeaf(s: []const u8) !void {
    try std.testing.expect(std.zig.isValidId(s));
    try std.testing.expect(!std.zig.primitives.isPrimitive(s));
    try std.testing.expect(std.mem.find(u8, s, "__") == null);
    try std.testing.expect(s[0] != '_' and s[s.len - 1] != '_');
}

test "sanitize is injective and legal over every one-byte name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var buf: [8]u8 = undefined;
    for (0..256) |c| {
        const byte: [1]u8 = .{@intCast(c)};
        const s = try a.dupe(u8, try sanitize(&buf, &byte));
        try expectLeaf(s);
        try seen.put(a, s, {});
    }
    // 256 inputs, 256 distinct outputs.
    try std.testing.expectEqual(@as(u32, 256), seen.count());
}

test "sanitize is injective over every short name of the colliding bytes" {
    // `_` (the separator), `Z` (the escape marker), a digit (illegal first),
    // a byte outside the identifier alphabet, and a plain letter: every
    // string of one to three of them, 5 + 25 + 125 = 155 names.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const alphabet = "a_Z0.";
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var buf: [16]u8 = undefined;
    var n: u32 = 0;
    for (1..4) |len| {
        var digits: [3]usize = @splat(0);
        while (true) {
            var name: [3]u8 = undefined;
            for (name[0..len], digits[0..len]) |*ch, d| ch.* = alphabet[d];
            const s = try a.dupe(u8, try sanitize(&buf, name[0..len]));
            try expectLeaf(s);
            try seen.put(a, s, {});
            n += 1;
            // Next string: count in base `alphabet.len`.
            var k: usize = 0;
            while (k < len) : (k += 1) {
                digits[k] += 1;
                if (digits[k] < alphabet.len) break;
                digits[k] = 0;
            }
            if (k == len) break;
        }
    }
    try std.testing.expectEqual(@as(u32, 155), n);
    try std.testing.expectEqual(n, seen.count());
}

test "sanitize fails at the exact byte it cannot write" {
    var buf: [4]u8 = undefined;
    // `pub` takes three bytes and its keyword marker a fourth.
    try std.testing.expectError(error.NoSpaceLeft, sanitize(buf[0..3], "pub"));
    try std.testing.expectEqualStrings("pubZ", try sanitize(buf[0..4], "pub"));
    // An escape takes three bytes.
    try std.testing.expectError(error.NoSpaceLeft, sanitize(buf[0..2], "Z"));
    try std.testing.expectEqualStrings("Z5a", try sanitize(buf[0..3], "Z"));
    try std.testing.expectEqualStrings("", try sanitize(buf[0..0], ""));
}

test unitName {
    var buf: [64]u8 = undefined;
    const u: Unit = .{ .role = .analog_op, .target = "ddt", .disambig = 2 };
    // The module leaf is sanitized; the role and the pre-sanitized target are not.
    const want = "myZ20mod__analog_op__ddt__2";
    try std.testing.expectEqualStrings(want, try unitName(&buf, "my mod", u));
    try std.testing.expectEqualStrings(want, try unitName(buf[0..want.len], "my mod", u));
    try std.testing.expectError(error.NoSpaceLeft, unitName(buf[0 .. want.len - 1], "my mod", u));
    // The roles codegen names directly print the same way.
    try std.testing.expectEqualStrings("m__display__x", try unitName(&buf, "m", .{ .role = .display, .target = "x" }));
    try std.testing.expectEqualStrings("m__common__x", try unitName(&buf, "m", .{ .role = .common, .target = "x" }));
}

test "a synthetic operator variant shares its operator's name and state" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&nets);
    defer f.deinit();
    const a = f.arena.allocator();

    _ = try f.mir.emitCall(a, .entry, try f.mir.internString(a, "absdelay"), &.{});
    _ = try f.mir.emitCall(a, .entry, try f.mir.internString(a, "absdelay$quad"), &.{});

    const units = try enumerateUnits(a, &f.mir, &f.lowered);
    try std.testing.expectEqual(@as(usize, 2), units.len);
    for (units, 0..) |u, i| {
        try std.testing.expectEqual(Role.analog_op, u.role);
        try std.testing.expectEqualStrings("absdelay", u.target);
        try std.testing.expectEqual(opdb.OpKind.absdelay, u.op);
        try std.testing.expectEqual(@as(u32, @intCast(i)), u.disambig);
        try std.testing.expect(u.inst != .none);
    }
    assertCanonicalOrder(units, &f.lowered, 0);
}

test "contribution targets: ground is 0, a net is sanitized, a `_`-join collision stays unique" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{ "0", "a_b", "c", "a", "b_c" });
    defer f.deinit();
    const a = f.arena.allocator();

    // I(<net "0">) and V(a_b, c), V(a, b_c): the last two join to the same
    // `V_a_b_c`, and `disambig` keeps their names apart.
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 0, .lo = Lowered.ground });
    try f.lowered.contributions.append(a, .{ .access = .potential, .hi = 1, .lo = 2 });
    try f.lowered.contributions.append(a, .{ .access = .potential, .hi = 3, .lo = 4 });

    var got: std.ArrayList([]const u8) = .empty;
    try names(&f, &got);
    try std.testing.expectEqual(@as(usize, 3), got.items.len);
    // A net's leading digit is escaped, so it never reads as ground's `0`.
    try std.testing.expectEqualStrings("mymod__analog__I_Z30_0", got.items[0]);
    try std.testing.expectEqualStrings("mymod__analog__V_a_b_c", got.items[1]);
    try std.testing.expectEqualStrings("mymod__analog__V_a_b_c__1", got.items[2]);
    assertCanonicalOrder(try enumerateUnits(a, &f.mir, &f.lowered), &f.lowered, 3);
}

test "the allocating spellers fail cleanly at every allocation" {
    // Their contract is an arena (each leaves scratch or a prefix behind),
    // so the arena over the failing allocator is what must free everything.
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&nets);
    defer f.deinit();
    const a = f.alloc();
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 0, .lo = 2 });
    _ = try f.mir.emitCall(a, .entry, try f.mir.internString(a, "slew"), &.{});

    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator, mir: *const Mir, lowered: *const Lowered) !void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const aa = arena.allocator();
            const units = try enumerateUnits(aa, mir, lowered);
            try std.testing.expectEqual(@as(usize, 2), units.len);
            for (units) |u| _ = try unitNameAlloc(aa, mir.name, u);
            try std.testing.expectEqualStrings("mZ5f__held__x", try heldField(aa, "m_", "x"));
            _ = try snapField(aa, "x");
            _ = try wordField(aa, "x", 1);
            _ = try xzField(aa, "x");
        }
    }.run, .{ &f.mir, &f.lowered });
}

test "unitNameAlloc sizes the worst name it can be given" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // Every module byte escaped to three, the longest role, the widest ordinal.
    const name = try unitNameAlloc(arena.allocator(), "_._", .{ .role = .analog_op, .target = "t", .disambig = std.math.maxInt(u32) });
    try std.testing.expectEqualStrings("Z5fZ2eZ5f__analog_op__t__4294967295", name);
}
