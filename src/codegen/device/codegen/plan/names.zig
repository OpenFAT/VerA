//! Names: the lowered module -> `Names`, every identifier the device declares
//! and the unknowns behind them, decided before a byte is written. Clauses:
//! §3.4.7, §5.4.1, §5.4.2, §5.6, §5.6.7.1, §5.10, §9.19.

const std = @import("std");
const Mir = @import("ir").Mir;
const Analysis = @import("prove").Analysis;
const Lowered = @import("ir").Lowered;
const naming = @import("ir").names;
const Input = @import("prove").Input;

/// Allocation only: a name has no length bound (VAMS 2.8, VD-054).
pub const Error = std.mem.Allocator.Error;
const none_u32 = std.math.maxInt(u32);

/// Every identifier the device declares, and the unknowns behind them.
pub const Names = struct {
    /// Every source unit in the canonical order `naming.enumerateUnits`
    /// fixes: contributions, then operators.
    units: []naming.Unit = &.{},
    /// Declaration name per `units` entry.
    unit_names: [][]const u8 = &.{},
    /// Extra solver unknowns codegen appends after `Lowered.nodes`: one
    /// branch current per §5.6 potential contribution that lowering did not
    /// already give a `flow(a,b)` slot. Values are `nodes`-space indices.
    branch_u: []u32 = &.{},
    /// Unknown count: `Lowered.nodes` plus the appended branch currents.
    n_u: u32 = 0,
    /// Sanitized U-enum member name per unknown.
    u_names: [][]const u8 = &.{},
    /// Sanitized Model field name per `Lowered.params` entry.
    p_names: [][]const u8 = &.{},
    /// Sanitized Model field name per `Lowered.aliases` entry (§3.4.7).
    a_names: [][]const u8 = &.{},
    /// §5.10 `Instance` field name per `Lowered.held_vars` entry.
    held_names: [][]const u8 = &.{},
    /// Per `Lowered.params` entry: the parameter gains a `__given` flag,
    /// because §9.19 `$param_given` queries it or because it is a `derive()`
    /// target (a card parameter whose default does not fold).
    p_given: []bool = &.{},
    /// Per `Lowered.params` entry: the parameter's bit in `Model.given__`, or
    /// `none_u32` without a flag. An alias's bit is `n_given` + its index.
    given_bit: []u32 = &.{},
    /// How many parameters have a bit; the aliases' bits follow them.
    n_given: u32 = 0,

    /// The operator `call` unit `unit` was enumerated from (`naming` records
    /// it), or null for a contribution unit. Asserts `unit` indexes `units`.
    pub fn opInstOf(self: *const Names, unit: u32) ?Mir.Inst {
        const inst = self.units[unit].inst;
        return if (inst == .none) null else inst;
    }

    /// Call arguments of the operator that owns unit `i` (empty for a
    /// contribution unit). The slice borrows `mir.extra` and is invalidated
    /// by any later append to it (`Mir.instData`).
    pub fn opArgs(self: *const Names, mir: *const Mir, i: usize) []const Mir.Value {
        const inst = self.opInstOf(@intCast(i)) orelse return &.{};
        return mir.instData(inst).call.args;
    }
};

/// Returns every declared name and the unknowns behind them; slices are owned
/// by `in.arena`. `n_unit_modes` is `Verdict.unit_modes.len`: the
/// canonical-order contract `unitMode` depends on is asserted here, where all
/// three tables are in hand. Fails only on allocation.
pub fn plan(in: Input, n_unit_modes: usize) Error!Names {
    const a = in.arena;
    const mir = in.mir;
    const an = in.an;
    const lowered = in.lowered;
    var self: Names = .{};
    self.units = try naming.enumerateUnits(a, mir, lowered);
    // The contract `unitMode` below depends on, checked once where all
    // three tables are in hand for the only time.
    naming.assertCanonicalOrder(self.units, lowered, n_unit_modes);
    self.unit_names = try a.alloc([]const u8, self.units.len);
    for (self.units, 0..) |u, i| self.unit_names[i] = try naming.unitNameAlloc(a, mir.name, u);

    // §5.6 potential contributions need a branch-current unknown. Lowering
    // allocates a `flow(a,b)` slot only where the model probes I(a,b), so
    // codegen appends the missing ones after `nodes`; every existing
    // block_param index keeps its meaning.
    const base: u32 = @intCast(lowered.nodes.len);
    self.branch_u = try a.alloc(u32, lowered.contributions.items.len);
    @memset(self.branch_u, none_u32);
    // Raw names of the unknowns appended after `nodes`, in append order.
    var extra: std.ArrayList([]const u8) = .empty;
    for (lowered.contributions.items, 0..) |c, i| {
        // A §5.6 potential source and a §5.6.7 indirect (nullor) source are
        // the same topology: a source in the branch whose current is its
        // own unknown.
        if (c.access != .potential and c.kind != .indirect) continue;
        // Reuse the §5.4.2 slot lowering already allocated because the model
        // probes I(a,b), unless an earlier contribution already drives it:
        // §5.6.7.1 permits several indirect contributions to one branch, and
        // each is a separate source with a separate current. Looked up by the
        // node pair, the identity §5.4.1 gives the branch, never by the
        // `flow(hi,lo)` spelling (a plain net named `gnd` would collide with
        // §1.3.1.1's reference node).
        var found: u32 = if (lowered.flow_unknowns.get(.{ .hi = c.hi, .lo = c.lo })) |u| u else none_u32;
        if (found != none_u32 and uIsDriven(self.branch_u, found, i)) found = none_u32;
        if (found == none_u32) {
            const nm = try a.print("flow({s},{s})", .{
                lowered.nodeName(c.hi), lowered.nodeName(c.lo),
            });
            found = base + @as(u32, @intCast(extra.items.len));
            try extra.append(a, try freshUName(a, lowered, nm, extra.items));
        }
        self.branch_u[i] = found;
    }
    self.n_u = base + @as(u32, @intCast(extra.items.len));

    self.u_names = try a.alloc([]const u8, self.n_u);
    for (lowered.nodes.items(.name), 0..) |n, i| {
        self.u_names[i] = try naming.sanitizeAlloc(a, n);
    }
    for (extra.items, 0..) |n, k| {
        self.u_names[base + k] = try naming.sanitizeAlloc(a, n);
    }

    self.p_names = try a.alloc([]const u8, lowered.params.items.len);
    for (lowered.params.items, 0..) |p, i| {
        self.p_names[i] = try naming.sanitizeAlloc(a, p.name);
    }
    self.a_names = try a.alloc([]const u8, lowered.aliases.items.len);
    for (lowered.aliases.items, 0..) |al, i| {
        self.a_names[i] = try naming.sanitizeAlloc(a, al.name);
    }

    // §5.10 held variables (`naming.heldField` says why the key is unique).
    self.held_names = try a.alloc([]const u8, lowered.held_vars.items.len);
    for (lowered.held_vars.items, self.held_names) |h, *n| n.* = try naming.heldField(a, mir.name, h.name);
    self.p_given = try a.alloc(bool, lowered.params.items.len);
    @memset(self.p_given, false);
    // A non-local parameter whose default reads another parameter is a
    // `derive()` target, and its guard (`if (!model.X__given)`) needs the
    // flag whether or not the model ever queries §9.19 (the same fold
    // condition `emitDerive` selects assignments on).
    for (lowered.params.items, 0..) |p, i| {
        if (p.is_local or Analysis.tyOfParam(p.ty) == .str) continue;
        if (an.foldConst(p.default, false) == null) self.p_given[i] = true;
    }
    // §9.19 $param_given(p): the flag lives in Model, but only for the
    // parameters actually asked about.
    for (0..an.nb) |bi| {
        for (an.blockInstsFlat(@intCast(bi))) |inst| {
            if (mir.instOp(inst) != .call) continue;
            const d = mir.instData(inst).call;
            if (d.callee != .@"$param_given") continue;
            if (d.args.len == 0) continue;
            const def = mir.valueDef(an.rv(d.args[0]));
            if (def == .param_ref) self.p_given[def.param_ref] = true;
        }
    }
    self.given_bit = try a.alloc(u32, lowered.params.items.len);
    self.n_given = 0;
    for (self.p_given, self.given_bit) |g, *b| {
        b.* = if (g) self.n_given else none_u32;
        if (g) self.n_given += 1;
    }
    return self;
}

/// Is unknown `u` already the current of a source from a contribution
/// before `i`? Two sources in one branch need two currents.
fn uIsDriven(branch_u: []const u32, u: u32, i: usize) bool {
    // ponytail: stdlib scans the same bounded prefix; no membership table needed.
    return std.mem.findScalar(u32, branch_u[0..i], u) != null;
}

/// `nm`, or `nm#k` for the first `k` that no unknown claims yet. `sanitize`
/// escapes `#`, so the emitted U member stays a legal, injective name. O(k ·
/// unknowns); `k` is the number of existing spellings it collides with.
fn freshUName(a: std.mem.Allocator, lowered: *const Lowered, nm: []const u8, extra: []const []const u8) Error![]const u8 {
    var name = nm;
    var k: u32 = 1;
    while (uNameTaken(lowered, name, extra)) : (k += 1) {
        name = try a.print("{s}#{d}", .{ nm, k });
    }
    return name;
}

/// Does any `nodes` row or already-appended unknown spell `nm`?
fn uNameTaken(lowered: *const Lowered, nm: []const u8, extra: []const []const u8) bool {
    for (lowered.nodes.items(.name)) |n| {
        if (std.mem.eql(u8, n, nm)) return true;
    }
    for (extra) |n| {
        if (std.mem.eql(u8, n, nm)) return true;
    }
    return false;
}

const Fixture = @import("prove").Fixture;
const Lower = @import("ir").Lowered;

test "a potential source gets a branch current; two on one branch get two" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{ "a", "b" });
    defer f.deinit();
    const a = f.alloc();
    // I(a,b) <+ …  (no unknown), V(a,b) <+ …  twice (two currents), V(b) <+ …
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 0, .lo = 1 });
    try f.lowered.contributions.append(a, .{ .access = .potential, .hi = 0, .lo = 1 });
    try f.lowered.contributions.append(a, .{ .access = .potential, .hi = 0, .lo = 1 });
    try f.lowered.contributions.append(a, .{ .access = .potential, .hi = 1, .lo = Lower.ground });
    const an = try f.analysis();

    const n = try plan(.{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered }, 4);
    try std.testing.expectEqual(@as(u32, 5), n.n_u);
    try std.testing.expectEqualSlices(u32, &.{ none_u32, 2, 3, 4 }, n.branch_u);
    // The second current on (a,b) takes the first free `#k`, sanitized.
    try std.testing.expectEqualStrings("a", n.u_names[0]);
    try std.testing.expect(!std.mem.eql(u8, n.u_names[2], n.u_names[3]));
    try std.testing.expectEqual(@as(usize, 4), n.unit_names.len);
    try std.testing.expectEqualStrings("mymod__analog__I_a_b", n.unit_names[0]);
}

test "a probed branch's flow slot is reused; an indirect source gets one too; a spelling clash takes #k" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    // Net 2 is a plain net whose name is the spelling `flow(a,b)` (§2.8.1
    // escaped identifiers make that legal); net 3 is the §5.4.2 slot lowering
    // minted for a probe of I(b,a).
    try f.init(&.{ "a", "b", "flow(a,b)", "flow(b,a)" });
    defer f.deinit();
    const a = f.alloc();
    f.lowered.nodes.items(.kind)[3] = .{ .branch_flow = 1 };
    try f.lowered.flow_unknowns.put(a, .{ .hi = 1, .lo = 0 }, 3);
    // V(b,a) <+ …: lowering's slot 3 is its current; no new unknown.
    try f.lowered.contributions.append(a, .{ .access = .potential, .hi = 1, .lo = 0 });
    // §5.6.7 V(a,b) : … == …: an indirect source on (a,b) has no slot, and
    // the spelling `flow(a,b)` is taken by net 2, so it becomes `flow(a,b)#1`.
    try f.lowered.contributions.append(a, .{ .access = .potential, .kind = .indirect, .hi = 0, .lo = 1 });
    const an = try f.analysis();

    const n = try plan(.{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered }, 2);
    try std.testing.expectEqualSlices(u32, &.{ 3, 4 }, n.branch_u);
    try std.testing.expectEqual(@as(u32, 5), n.n_u);
    // `sanitize` is injective, so distinct raw spellings stay distinct.
    for (n.u_names, 0..) |x, i| for (n.u_names[i + 1 ..]) |y| {
        try std.testing.expect(!std.mem.eql(u8, x, y));
    };
}

test "held names, given flags: §9.19 queries and derive() targets" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{"a"});
    defer f.deinit();
    const a = f.alloc();
    // p0 folds; p1's default reads p0 (a derive() target); p2 is local; p3 a
    // string; p4 folds but the model asks $param_given(p4).
    const p0 = try f.mir.addParamRef(a, 0);
    try f.lowered.params.append(a, .{ .name = "p0", .ty = .real, .default = .f_one });
    try f.lowered.params.append(a, .{ .name = "p1", .ty = .real, .default = p0 });
    try f.lowered.params.append(a, .{ .name = "p2", .ty = .real, .default = p0, .is_local = true });
    try f.lowered.params.append(a, .{ .name = "p3", .ty = .string, .default = p0 });
    try f.lowered.params.append(a, .{ .name = "p4", .ty = .real, .default = .f_two });
    _ = try f.call("$param_given", &.{try f.mir.addParamRef(a, 4)});
    // A held variable spelled like a Zig keyword gets the `Z` marker.
    try f.lowered.held_vars.append(a, .{ .name = "pub", .ty = .real, .init = .f_zero, .seed = .f_zero });
    const an = try f.analysis();

    const n = try plan(.{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered }, 0);
    try std.testing.expectEqualSlices(bool, &.{ false, true, false, false, true }, n.p_given);
    try std.testing.expectEqual(@as(usize, 1), n.held_names.len);
    try std.testing.expectEqualStrings("mymod__held__pubZ", n.held_names[0]);
    // `$param_given` owns no state, so it is no unit.
    try std.testing.expectEqual(@as(usize, 0), n.units.len);
}

test "a source name of any length plans (VAMS 2.8, VD-054)" {
    // #29: `naming.sanitize` wrote into an 8192-byte buffer, so a
    // 9000-character net (or parameter) was NameTooLong. The buffers are
    // sized per name now; both plan, and the long name survives whole.
    const long: [9000]u8 = @splat('q');
    {
        var f: Fixture = .{ .arena = .init(std.testing.allocator) };
        try f.init(&.{&long});
        defer f.deinit();
        const an = try f.analysis();
        const n = try plan(.{ .arena = f.alloc(), .mir = &f.mir, .an = &an, .lowered = &f.lowered }, 0);
        try std.testing.expectEqualStrings(&long, n.u_names[0]);
    }
    {
        var f: Fixture = .{ .arena = .init(std.testing.allocator) };
        try f.init(&.{"a"});
        defer f.deinit();
        try f.lowered.params.append(f.alloc(), .{ .name = &long, .ty = .real, .default = .f_one });
        const an = try f.analysis();
        const n = try plan(.{ .arena = f.alloc(), .mir = &f.mir, .an = &an, .lowered = &f.lowered }, 0);
        try std.testing.expectEqualStrings(&long, n.p_names[0]);
    }
}
