//! The shared core: the job list -> `Core`, the values several units read,
//! computed once per eval: its live-out set and field order, the §5.6.1.2
//! path latches and §5.10 held values that read it, its name, and the float
//! mode it compiles in. Clauses: §4.3, §4.5, §5.6.1.2, §5.9, §5.10, §9.4.

const std = @import("std");
const Mir = @import("ir").Mir;
const proof = @import("prove").proof;
const naming = @import("ir").names;
const Input = @import("prove").Input;
const Job = @import("jobs.zig").Job;
const float_mode = @import("../float/mode.zig");
const plan_setup = @import("prove").setup;
const callee = Mir.callee;
const assert = std.debug.assert;

/// Allocation only: a name has no length bound (VAMS 2.8, VD-054).
pub const Error = std.mem.Allocator.Error;
const none_u32 = std.math.maxInt(u32);

/// The shared core's plan.
pub const Core = struct {
    /// Position of this Value in the core's returned struct, or `none_u32`.
    /// Only the unit targets cross the declaration boundary; every
    /// subexpression behind them stays a local of the core.
    lo_idx: []u32 = &.{},
    /// The returned values, in job order; `lo_idx` indexes into this.
    lo_vals: []Mir.Value = &.{},
    /// §5.6.1.2 path-integrated reactive latches: the rv-resolved operand of
    /// every `path_prev`/`path_acc`, each family deduplicated (CSE-shared
    /// sites share a latch). `*_lo[k]` is the operand's slot in `lo_vals`.
    /// `path_prev` renders `S.con(inst.pb__k)` (the operand at the last
    /// accepted solve), `path_acc` renders `S.con(inst.pq__k)` (the sum of
    /// committed operands, the charge base). `updateState` stages both
    /// operands into `State.wb__/wq__` at each accepted point; `stateCtl(.commit)`
    /// (operating-point exit and accepted transient step) latches `pb = wb`,
    /// `pq += wq` and zeroes `wq`, so a stray double commit adds 0.
    prev_vals: []Mir.Value = &.{},
    /// `prev_vals[k]`'s slot in `lo_vals`; same length as `prev_vals`.
    prev_lo: []u32 = &.{},
    /// The `path_acc` family, deduplicated like `prev_vals`.
    acc_vals: []Mir.Value = &.{},
    /// `acc_vals[k]`'s slot in `lo_vals`; same length as `acc_vals`.
    acc_lo: []u32 = &.{},
    /// Core field index holding each held variable's end-of-block value, or
    /// `none_u32` when it folded to `.f_zero`.
    held_idx: []u32 = &.{},
    /// `<module>__common__core`, or empty for a model with no targets at all.
    name: []const u8 = "",
    /// §4.3 the strictest mode of every job the core serves (`float/mode.zig`).
    mode: proof.FloatMode = .optimized,
    /// §5.10 per Value: a store into a held array that nothing `eval`/`q`
    /// returns can observe (`heldOnly`). Empty when none.
    held_only: []bool = &.{},
    /// Per Value: something `eval`/`q` returns reads it (`heldOnly`'s
    /// marking). Empty when the device stores into no held array.
    eval_need: []bool = &.{},
    /// §5.10 per `Lowered.mem_arrays` row: this slice writes the held array
    /// in place in its `Instance` field instead of copy-on-write
    /// (`state.zig` `inPlaceArrays`). Set on the `updateState` slice only,
    /// whose caller stores every held value back unconditionally. Empty: none.
    in_place: []const bool = &.{},
};

// ---------------------------------------------------- the shared core ----
//
// One declaration returns every unit target, rather than a function per
// shared value or a shared region plus per-unit tails. The shared values form
// a DAG, so a function per value recomputes each value once per path
// (exponential in depth). Tails each re-walk the whole CFG and each call the
// core, and LLVM does not merge those calls (vbic13_4t measured 30 core calls
// per `eval`), so merging gives one core per `eval` and one per `q`. The cost
// is the per-unit `@setFloatMode` (see `Core.mode`).

/// Decides what the one emitted body returns: every unit target,
/// deduplicated and in job order, plus the path-latch operands; slices are
/// owned by `in.arena`.
///
/// Job order (contributions in source order, then §4.5 operator inputs, then
/// §9.4 display) makes `f<k>` insert-tolerant the way `ir/names.zig` makes
/// declaration names: adding a contribution at the end of a module appends
/// fields and renumbers none. Fails only on allocation.
pub fn plan(in: Input, jobs: []const Job) Error!Core {
    const a = in.arena;
    var self: Core = .{};
    self.lo_idx = try a.alloc(u32, in.an.nv);
    @memset(self.lo_idx, none_u32);

    var vals: std.ArrayList(Mir.Value) = .empty;
    for (jobs) |job| {
        // §9.4 the display root stays out: the core runs once per `eval`,
        // and printing once per Newton iteration is what `emitDisplay`
        // exists to prevent. It keeps its own declaration and reads the core.
        if (job.kind == .display) continue;
        const v = in.an.rv(job.target);
        if (v == .f_zero) continue; // an operator with no input; rendered inline
        if (self.lo_idx[@backingInt(v)] != none_u32) continue;
        self.lo_idx[@backingInt(v)] = @intCast(vals.items.len);
        try vals.append(a, v);
    }
    // Path-latch operands ride the same live-out queue: `updateState`'s
    // single value-only core sweep is where their staged values come from.
    {
        var pv: std.ArrayList(Mir.Value) = .empty;
        var pl: std.ArrayList(u32) = .empty;
        var qv: std.ArrayList(Mir.Value) = .empty;
        var ql: std.ArrayList(u32) = .empty;
        // Two columns, not `insts.get` per row: the scan reads op and operand
        // only, and a whole row is 29 bytes.
        for (in.mir.insts.items(.op), in.mir.insts.items(.a)) |op, operand| {
            if (op != .path_prev and op != .path_acc) continue;
            const fam_v = if (op == .path_prev) &pv else &qv;
            const fam_l = if (op == .path_prev) &pl else &ql;
            const v = in.an.rv(@fromBackingInt(@intCast(operand)));
            // ponytail: first-seen order by a linear membership scan, O(latches²)
            // per family; a bitset over `nv` if a model carries thousands.
            if (std.mem.findScalar(Mir.Value, fam_v.items, v) != null) continue;
            if (self.lo_idx[@backingInt(v)] == none_u32) {
                self.lo_idx[@backingInt(v)] = @intCast(vals.items.len);
                try vals.append(a, v);
            }
            try fam_v.append(a, v);
            try fam_l.append(a, self.lo_idx[@backingInt(v)]);
        }
        self.prev_vals = pv.items;
        self.prev_lo = pl.items;
        self.acc_vals = qv.items;
        self.acc_lo = ql.items;
    }
    self.mode = float_mode.coreMode(jobs);
    self.lo_vals = vals.items;
    // Exit invariant: `lo_idx` and `lo_vals` are inverse on the live-outs.
    for (self.lo_vals, 0..) |v, k| assert(self.lo_idx[@backingInt(v)] == k);
    // §5.10 which core field each held variable's write-back reads. Done
    // here rather than by scanning `jobs` in `emitStateMachine`, because
    // `lo_idx` is only meaningful once every job has been folded in.
    self.held_idx = try a.alloc(u32, in.lowered.held_vars.items.len);
    for (in.lowered.held_vars.items, 0..) |h, i| {
        const v = in.an.rv(h.final);
        self.held_idx[i] = if (v == .f_zero) none_u32 else self.lo_idx[@backingInt(v)];
    }
    if (self.lo_vals.len == 0) return self;
    try heldOnly(in, jobs, &self);

    self.name = try naming.unitNameAlloc(a, in.mir.name, .{
        .role = .common,
        // A single declaration, so the target is a fixed word rather than a
        // key: `ir/names.zig`'s insert-tolerance is about the NAME not moving,
        // and this one cannot.
        .target = "core",
    });
    return self;
}

/// §5.10 marks the stores into a held array that nothing `eval`/`q` returns
/// can observe, per store result Value; leaves `held_only` empty when there
/// is none. Those callers read the contributions, charges, retention flags and
/// table captures (`evalRoot`); a held array's end-of-block value is
/// `updateState`'s and `acceptQ`'s. So their instantiation of the core skips
/// the stores (`held = false`), and a copy-on-write held array (`render.cow`)
/// is never copied per Newton iterate.
///
/// Aggressive dead-code marking (Cytron et al.): a value is needed when an
/// eval root, an argument of a call that is not a §4.5/§5.10 operator (those
/// take effect only through their result), or an operand of a needed
/// instruction reads it (an array load reads its version and every version
/// before it), and so is the condition of every branch a needed instruction or
/// phi edge is control-dependent on. A store nothing needed reads is
/// skippable.
fn heldOnly(in: Input, jobs: []const Job, out: *Core) Error!void {
    const a = in.arena;
    const n: u32 = @intCast(in.mir.insts.len);
    var any = false;
    for (0..n) |ii| {
        const inst: Mir.Inst = @fromBackingInt(@intCast(ii));
        if (in.mir.instOp(inst) != .store) continue;
        const id = in.an.arrOf(in.mir.instResult(inst)) orelse continue;
        if (in.lowered.mem_arrays.items[id].held != none_u32) any = true;
    }
    if (!any) return;

    const cds = try plan_setup.controlDeps(in, in.an.ipdom);
    var m: Mark = .{ .in = in, .cds = .{ .off = cds.off, .cd = cds.cd }, .need = try a.alloc(bool, in.an.nv), .blk = try a.alloc(bool, in.an.nb) };
    @memset(m.need, false);
    @memset(m.blk, false);
    for (jobs) |job| if (evalRoot(job.kind)) try m.mark(job.target);
    for (0..n) |ii| {
        const inst: Mir.Inst = @fromBackingInt(@intCast(ii));
        if (in.mir.instOp(inst) != .call) continue;
        const d = in.mir.instData(inst).call;
        if (callee.opKind(d.callee) != .none) continue;
        for (d.args) |x| try m.mark(x);
    }
    while (m.work.pop()) |v| try m.visit(v);

    const skip = try a.alloc(bool, in.an.nv);
    @memset(skip, false);
    var some = false;
    for (0..n) |ii| {
        const inst: Mir.Inst = @fromBackingInt(@intCast(ii));
        if (in.mir.instOp(inst) != .store) continue;
        const r = in.an.rv(in.mir.instResult(inst));
        const id = in.an.arrOf(r) orelse continue;
        if (in.lowered.mem_arrays.items[id].held == none_u32 or m.need[@backingInt(r)]) continue;
        skip[@backingInt(r)] = true;
        some = true;
    }
    out.eval_need = m.need;
    if (some) out.held_only = skip;
}

/// The jobs `eval`, `q` and `evalQ` read out of the core (`dispatch.zig`).
fn evalRoot(k: Job.Kind) bool {
    return switch (k) {
        .resist, .react, .retained, .table_effect, .timepoint, .status => true,
        // `updateState`/`acceptQ`, `limit`, `seed`, `advanceIteration`,
        // `noisePsd`, `acStim`, the schedule, `vpiContribs`/`vpiShares` and
        // §9.4 display read these.
        .op_input, .ctrl, .held, .limit_arg, .limit_old, .reject_iteration, .reject_step, .noise, .ac_stim, .timer_period, .vpi, .display => false,
    };
}

const Mark = struct {
    in: Input,
    cds: struct { off: []const u32, cd: []const plan_setup.Cd },
    need: []bool,
    blk: []bool,
    work: std.ArrayList(Mir.Value) = .empty,
    /// Blocks marked by `block` whose controlling branches are not yet.
    blk_work: std.ArrayList(u32) = .empty,

    fn mark(m: *Mark, v0: Mir.Value) Error!void {
        const v = m.in.an.rv(v0);
        if (m.need[@backingInt(v)]) return;
        m.need[@backingInt(v)] = true;
        try m.work.append(m.in.arena, v);
    }

    /// Block `b` runs only as the branches it is control-dependent on say.
    /// A worklist, not a recursion: a chain of control dependences is as
    /// deep as the source nests its `if`s, which has no bound.
    fn block(m: *Mark, b: u32) Error!void {
        try m.pushBlock(b);
        while (m.blk_work.pop()) |bb| for (m.cds.cd[m.cds.off[bb]..m.cds.off[bb + 1]]) |c| {
            try m.mark(plan_setup.branchCond(m.in, c.a).?);
            try m.pushBlock(c.a);
        };
    }

    fn pushBlock(m: *Mark, b: u32) Error!void {
        if (b >= m.blk.len or m.blk[b]) return;
        m.blk[b] = true;
        try m.blk_work.append(m.in.arena, b);
    }

    fn visit(m: *Mark, v: Mir.Value) Error!void {
        const def = m.in.mir.valueDef(v);
        if (def != .inst_result) return;
        const inst = def.inst_result;
        try m.block(m.in.an.def_block[@backingInt(v)]);
        switch (m.in.mir.instData(inst)) {
            .unary => |d| try m.mark(d.operand),
            .binary => |d| {
                try m.mark(d.lhs);
                try m.mark(d.rhs);
            },
            .ternary => |d| {
                try m.mark(d.cond);
                try m.mark(d.then_val);
                try m.mark(d.else_val);
            },
            .call => |d| for (d.args) |x| try m.mark(x),
            .load => |d| {
                try m.mark(d.arr);
                try m.mark(d.index);
            },
            .store => |d| {
                try m.mark(d.arr);
                try m.mark(d.index);
                try m.mark(d.value);
            },
            // A phi's value is its operand on the edge taken, and the edge
            // taken is its predecessor's branch.
            .phi => |d| for (0..d.count) |j| {
                const p = m.in.mir.phiPair(inst, @intCast(j));
                try m.mark(p.value);
                const pb: u32 = @backingInt(p.block);
                try m.block(pb);
                if (plan_setup.branchCond(m.in, pb)) |c| try m.mark(c);
            },
            .anew, .branch, .jump => {},
        }
    }
};

const Fixture = @import("prove").Fixture;

test "live-outs are deduplicated in job order; display stays out; held values index them" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{ "a", "b" });
    defer f.deinit();
    const a = f.alloc();
    const va = try f.probe(0);
    const vb = try f.probe(1);
    try f.lowered.held_vars.append(a, .{ .name = "h", .ty = .real, .init = .f_zero, .seed = .f_zero, .final = vb });
    const an = try f.analysis();
    const jobs = [_]Job{
        .{ .kind = .resist, .target = vb, .mode = .optimized, .comment = "" },
        .{ .kind = .react, .target = va, .mode = .optimized, .comment = "" },
        .{ .kind = .held, .target = vb, .mode = .strict, .comment = "" }, // shared with job 0
        .{ .kind = .display, .target = va, .mode = .strict, .comment = "" },
    };

    const c = try plan(.{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered }, &jobs);
    try std.testing.expectEqualSlices(Mir.Value, &.{ vb, va }, c.lo_vals);
    try std.testing.expectEqual(@as(u32, 0), c.lo_idx[@backingInt(vb)]);
    try std.testing.expectEqualSlices(u32, &.{0}, c.held_idx);
    // One `.strict` consumer makes the shared body strict (§4.3); the display
    // job is not a consumer.
    try std.testing.expectEqual(proof.FloatMode.strict, c.mode);
    try std.testing.expectEqualStrings("mymod__common__core", c.name);
}

test "no targets: an empty core with no name; a zero target stays out" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{"a"});
    defer f.deinit();
    const a = f.alloc();
    const an = try f.analysis();
    // An operator with no input queues `.f_zero`, which renders inline.
    const jobs = [_]Job{.{ .kind = .op_input, .target = .f_zero, .mode = .strict, .comment = "" }};
    const c = try plan(.{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered }, &jobs);
    try std.testing.expectEqual(@as(usize, 0), c.lo_vals.len);
    try std.testing.expectEqualStrings("", c.name);
    try std.testing.expectEqual(@as(usize, 0), c.held_only.len);
}

test "§5.6.1.2 path latches: one latch per operand, a target's slot reused, a new operand appended" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{"a"});
    defer f.deinit();
    const a = f.alloc();
    const va = try f.probe(0);
    const x = try f.mir.emit(a, .entry, .fmul, &.{ va, va });
    const y = try f.mir.emit(a, .entry, .fadd, &.{ va, .f_one });
    _ = try f.mir.emit(a, .entry, .path_prev, &.{x});
    _ = try f.mir.emit(a, .entry, .path_prev, &.{x}); // CSE-shared: the same latch
    _ = try f.mir.emit(a, .entry, .path_acc, &.{y});
    const an = try f.analysis();
    const jobs = [_]Job{.{ .kind = .resist, .target = x, .mode = .strict, .comment = "" }};

    const c = try plan(.{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered }, &jobs);
    try std.testing.expectEqualSlices(Mir.Value, &.{ x, y }, c.lo_vals);
    try std.testing.expectEqualSlices(Mir.Value, &.{x}, c.prev_vals);
    try std.testing.expectEqualSlices(u32, &.{0}, c.prev_lo);
    try std.testing.expectEqualSlices(Mir.Value, &.{y}, c.acc_vals);
    try std.testing.expectEqualSlices(u32, &.{1}, c.acc_lo);
}

test "§5.10 a held-array store only updateState reads is held-only; one eval loads from is not" {
    // h[0] = V(a) into a held array; eval returns V(b), or a load of h.
    for ([_]bool{ false, true }) |eval_loads| {
        var f: Fixture = .{ .arena = .init(std.testing.allocator) };
        try f.init(&.{ "a", "b" });
        defer f.deinit();
        const a = f.alloc();
        const va = try f.probe(0);
        const vb = try f.probe(1);
        try f.lowered.mem_arrays.append(a, .{ .name = "h", .len = 2, .ty = .real, .held = 0 });
        const h0 = try f.mir.emitAnew(a, .entry, 0);
        const st = try f.mir.emit(a, .entry, .store, &.{ h0, .zero, va });
        try f.lowered.held_vars.append(a, .{ .name = "h", .ty = .real, .init = .f_zero, .seed = h0, .final = st, .array = 0 });
        const ld = try f.mir.emit(a, .entry, .fload, &.{ st, .zero });
        const an = try f.analysis();
        const jobs = [_]Job{
            .{ .kind = .resist, .target = if (eval_loads) ld else vb, .mode = .strict, .comment = "" },
            .{ .kind = .held, .target = st, .mode = .strict, .comment = "" },
        };

        const c = try plan(.{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered }, &jobs);
        try std.testing.expectEqual(@as(usize, an.nv), c.eval_need.len);
        try std.testing.expectEqual(eval_loads, c.eval_need[@backingInt(st)]);
        if (eval_loads) {
            // Something eval returns reads the store, so nothing is skippable.
            try std.testing.expectEqual(@as(usize, 0), c.held_only.len);
        } else {
            try std.testing.expect(c.held_only[@backingInt(st)]);
            try std.testing.expect(c.eval_need[@backingInt(vb)]);
        }
    }
}
