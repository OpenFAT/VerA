//! Jobs: the lowered module and the plans it depends on (`Names`, `$limit`
//! sites, small-signal rows) -> every value the shared core returns, and why,
//! resolved before a unit is written. Clauses: §2.9, §4.5, §4.6.3, §4.6.4, §5.6,
//! §5.6.1.2, §5.6.1.3, §5.6.7, §5.10, §5.10.3.3, §9.4, §9.13, §9.17, §9.21.1.

const std = @import("std");
const Mir = @import("ir").Mir;
const proof = @import("prove").proof;
const OpKind = @import("ir").op.OpKind;
const naming = @import("ir").names;
const Input = @import("prove").Input;
const Names = @import("names.zig").Names;
const LimitCall = @import("limit.zig").LimitCall;
const plan_noise = @import("noise.zig");
const plan_topo = @import("topology.zig");

/// The doc line of the §9.4 display unit's declaration.
pub const display_comment = "§9.4 display tasks, in source order";

/// The planned core targets.
pub const Jobs = struct {
    /// Every unit function to emit, resolved before any of them is written.
    list: []Job = &.{},
    /// `<module>__display__tasks`, or empty when the model prints nothing (or
    /// when the §9.4 tasks are dropped). The job that renders it is queued
    /// last.
    display_name: []const u8 = "",
};

/// What `plan` reads besides the lowered module.
const From = struct {
    /// `plan/names.zig`: the canonical units, whose operators queue inputs.
    names: *const Names,
    /// `proof.Verdict.unit_modes`: the float mode of each CONTRIBUTION unit.
    unit_modes: []const proof.FloatMode,
    /// `Limits.calls`: the honoured §4.5.15 sites.
    limits: []const LimitCall,
    /// `plan/noise.zig`: the §4.6.4 generator rows and §4.6.3 stimulus rows.
    noise: *const plan_noise.Noise,
    /// `Options.display == .emit`: the §9.4 tasks become a unit of their own.
    emit_display: bool,
    /// A `.record` device has tasks its `say` records (`cg_display.planSay`):
    /// the display unit is that entry point's body.
    record_display: bool = false,
    /// `plan/qsite.zig` `QSites.sites`: the `Lowered.charge_sites` that get a
    /// `q` slot, in slot order. Each one's charge is a core live-out.
    q_sites: []const u32 = &.{},
    /// `Options.vpi_contribs`: every value `vpiContribs` and `vpiShares`
    /// report is a core live-out.
    vpi: bool = false,
};

/// One core target, resolved before anything is written.
///
/// `plan_core.plan` counts how many units share a value, and `emitUnits`
/// must emit exactly that set: a disagreement would leave a value rendered as
/// a cache read in a unit whose slice was never counted. One list, built
/// once, walked twice. Only the §9.4 display job is emitted as a declaration
/// of its own, named `Jobs.display_name` (`emitUnits`); every other job
/// exists to put its target in the core, so a row carries no name or text.
pub const Job = struct {
    kind: Kind,
    target: Mir.Value,
    mode: proof.FloatMode,

    /// Why the target is in the core. `plan` queues the kinds in this order,
    /// which is the order of the core's fields: a model that gains a target
    /// of one kind appends fields and renumbers none of the earlier kinds.
    /// The one interleave: each contribution's `.react` jobs follow its own
    /// `.resist` job.
    pub const Kind = enum {
        /// §5.6 a contribution's resistive target.
        resist,
        /// §5.6.1.2 a charge site's charge (`plan/qsite.zig`).
        react,
        /// §4.5 an analog operator's input, or a §9.17 request.
        op_input,
        /// §4.5 Table 4-20 a dynamic operator control argument.
        ctrl,
        /// §5.10 a held variable's end-of-block value.
        held,
        /// §4.5.15 a `$limit` algorithm argument.
        limit_arg,
        /// §9.17.3 a next-iteration limiter value.
        limit_old,
        /// §9.17.1 the iteration-rejection request.
        reject_iteration,
        /// §5.6.1.3 a runtime retention flag.
        retained,
        /// §4.6.4 a noise PSD, exponent or coefficient.
        noise,
        /// §4.6.3 a solve-computed AC stimulus magnitude or phase.
        ac_stim,
        /// §5.10.3.3 a timer's latest period.
        timer_period,
        /// §9.21.1/§9.13 table captures and distribution checks.
        table_effect,
        /// VerA's `vera_timepoint` (§2.9): whether a cached statement ran, and
        /// each variable it assigned, which `eval` stores into the cache.
        timepoint,
        /// VerA's `$vera_reject_step`: the retry time `updateState` returns.
        reject_step,
        /// §9.7.3 a device's status code and its arguments, which `eval`
        /// latches into `Instance` (`Lowered.status`).
        status,
        /// Clause 12 (`From.vpi`): a row's reactive half, or one instance's
        /// share of a shared row, that `vpiContribs`/`vpiShares` report.
        vpi,
        /// §9.4: the one job that is NOT folded into the core, because its
        /// body has side effects the residual must not trigger. See
        /// `plan_core.plan`.
        display,
    };
};

/// Returns every core target in queue order (`Job.Kind`); slices are owned by
/// `self.arena`. `dyn.isDynamic(v)` answers whether a §4.5 control argument
/// renders only off the core, so a test can pass a stub. Fails on
/// allocation or with `dyn`'s error.
pub fn plan(self: Input, from: From, dyn: anytype) !Jobs {
    var out: Jobs = .{};
    var jobs: std.ArrayList(Job) = .empty;
    for (self.lowered.contributions.items, 0..) |c, i| {
        const mode = unitMode(from.unit_modes, i);
        const resist = self.an.rv(c.resist_val);
        if (resist != .f_zero) try jobs.append(self.arena, .{
            .kind = .resist,
            .target = resist,
            .mode = mode,
        });
        // §5.6.1.2 its charges, one per site, beside it.
        for (from.q_sites) |k| {
            const s = self.lowered.charge_sites.items[k];
            if (s.contrib != i) continue;
            try jobs.append(self.arena, .{
                .kind = .react,
                .target = self.an.rv(s.final),
                .mode = mode,
            });
        }
    }
    for (from.names.units, 0..) |u, i| {
        if (u.role != .analog_op) continue;
        const inst = from.names.opInstOf(@intCast(i)) orelse continue;
        const args = self.mir.instData(inst).call.args;
        try jobs.append(self.arena, .{
            .kind = .op_input,
            .target = if (args.len == 0) Mir.Value.f_zero else self.an.rv(args[0]),
            .mode = unitMode(from.unit_modes, i),
        });
    }
    // §4.5 Table 4-20's dynamic control arguments: `updateState` has one core
    // sweep, so an argument it must read on the accepted solution has to be a
    // field of it. The table is normative (`absdelay`: `expr, td`; `idt`:
    // `expr, ic, assert`; `idtmod`: `expr, ic, modulus, offset`). Only
    // arguments that do not fold are queued: a literal or model parameter
    // renders over Model and puts nothing in the core.
    for (from.names.units, 0..) |u, i| {
        if (u.role != .analog_op) continue;
        const inst = from.names.opInstOf(@intCast(i)) orelse continue;
        const args = self.mir.instData(inst).call.args;
        for (0..args.len) |ai| {
            if (!isDynCtrlArg(u.op, ai)) continue;
            const v = self.an.rv(args[ai]);
            if (v == .f_zero) continue;
            if (!try dyn.isDynamic(args[ai])) continue;
            try jobs.append(self.arena, .{
                .kind = .ctrl,
                .target = v,
                .mode = unitMode(from.unit_modes, i),
            });
        }
    }
    // §5.10 the end-of-block value of every held variable, so `updateState`
    // can store it back. `.strict` unconditionally: proof.zig rates
    // contributions only.
    for (self.lowered.held_vars.items) |h| {
        try jobs.append(self.arena, .{
            .kind = .held,
            .target = self.an.rv(h.final),
            .mode = .strict,
        });
    }
    // §4.5.15 the arguments of every honoured `$limit`, so `limit` reads them
    // from the core instead of re-deriving the temperature prelude.
    for (from.limits) |lc| {
        // A literal or parameter seed is written in place (`writeArg`);
        // queued, it would make every other use of that constant read `c`.
        const seed: Mir.Value = switch (self.mir.valueDef(self.an.rv(lc.seed))) {
            .float_const, .int_const, .param_ref, .undef => .undef,
            .str_const, .block_param, .inst_result => lc.seed,
        };
        for ([_]Mir.Value{ lc.argv[0], lc.argv[1], lc.sign, seed }) |v| {
            if (v == .f_zero or v == .undef) continue;
            try jobs.append(self.arena, .{
                .kind = .limit_arg,
                .target = v,
                .mode = .strict,
            });
        }
    }
    for (self.lowered.limit_slots.items) |slot| try jobs.append(self.arena, .{
        .kind = .limit_old,
        .target = self.an.rv(slot.final),
        .mode = .strict,
    });
    if (self.lowered.uses.contains(.reject_iteration)) try jobs.append(self.arena, .{
        .kind = .reject_iteration,
        .target = self.an.rv(self.lowered.reject_iteration),
        .mode = .strict,
    });
    // §5.6.1.3 the retention flags of every runtime-selected branch row
    // (`Retention.runtime`), read by `emitEval`'s `zResidual` as core fields. A module
    // whose potential contributions are all unconditional queues nothing.
    for (self.lowered.contributions.items, 0..) |c, i| {
        if (c.kind != .direct or c.access != .potential) continue;
        const ret = plan_topo.retention(self, c);
        if (ret != .runtime) continue;
        try jobs.append(self.arena, .{
            .kind = .retained,
            .target = ret.runtime,
            .mode = unitMode(from.unit_modes, i),
        });
        if (plan_topo.switchFlowOf(self, i)) |j| {
            const fret = plan_topo.retention(self, self.lowered.contributions.items[j]);
            if (fret == .runtime) try jobs.append(self.arena, .{
                .kind = .retained,
                .target = fret.runtime,
                .mode = unitMode(from.unit_modes, j),
            });
        }
    }
    // §4.6.4 the PSD argument of every noise generator, so `noisePsd` reads
    // the model's own expression out of the core.
    //
    // The power always goes through the core, even when it folds to a model
    // constant, because generators are conditional: `if (r > 0) I(a,b) <+
    // white_noise(4kT/r)` must read back zero when the statement did not run.
    // A core live-out is seeded `S.con(0)` and assigned only inside the
    // branch; rendered outside the core, `4kT/0` would be an infinity that
    // reaches the host as NaN. The exponent and a constant §4.6.4.6
    // coefficient render inline, since they are read only on a row whose
    // power is nonzero. A bias-dependent coefficient
    // (`I(a,b) <+ V(a,b)*white_noise(p)`) is a live-out like the power.
    for (from.noise.rows) |nr| {
        for ([_]Mir.Value{ nr.pwr, nr.exp, nr.coeff }, 0..) |v, k| {
            if (v == .f_zero) continue;
            if (k != 0 and plan_noise.psdConst(self.mir, v) != null) continue;
            try jobs.append(self.arena, .{
                .kind = .noise,
                .target = v,
                .mode = .strict,
            });
        }
    }
    // §4.6.3 an `ac_stim` magnitude or phase the solve computes (A.8.2 makes
    // both `analog_expression`), so `acStim` reads it out of the core sweep
    // as `noisePsd` does. Only arguments that do not fold are queued: a
    // literal or model parameter renders over `Model`.
    for (from.noise.ac_rows) |nr| {
        for ([_]Mir.Value{ nr.pwr, nr.exp, nr.coeff }) |v| {
            if (v == .f_zero) continue;
            if (!try dyn.isDynamic(v)) continue;
            try jobs.append(self.arena, .{
                .kind = .ac_stim,
                .target = v,
                .mode = .strict,
            });
        }
    }
    // §5.10.3.3: "If the start_time or period expressions change value
    // during the evaluation of the analog block, the next event will be
    // scheduled based on the LATEST value of the start_time and period."
    // The start_time is the operator's input and already rides the core; a
    // solve-computed period is queued here. Clause-5 event arguments are
    // `analog_expression`s: §4.5.14's constant-or-parameter rule covers only
    // the clause-4 operators.
    for (from.names.units, 0..) |u, i| {
        if (u.role != .analog_op or u.op != .timer) continue;
        if (self.lowered.timer_controls.get(from.names.opInstOf(@intCast(i)).?)) |latest| {
            for (latest) |arg| {
                const v = self.an.rv(arg);
                if (v == .f_zero or self.an.foldConst(v, false) != null) continue;
                try jobs.append(self.arena, .{
                    .kind = .timer_period,
                    .target = v,
                    .mode = .strict,
                });
            }
        }
        const args = from.names.opArgs(self.mir, i);
        if (args.len < 2) continue;
        if (self.an.foldConst(args[1], false) != null) continue; // renders inline
        const v = self.an.rv(args[1]);
        if (v == .f_zero) continue;
        try jobs.append(self.arena, .{
            .kind = .timer_period,
            .target = v,
            .mode = .strict,
        });
    }
    if (self.lowered.table_effect != .f_zero) try jobs.append(self.arena, .{
        .kind = .table_effect,
        .target = self.an.rv(self.lowered.table_effect),
        .mode = .strict,
    });
    // VerA's `vera_timepoint` (§2.9): each statement's mark, then the slots
    // something reads after it. A scratch variable no later statement reads
    // is not cached: its hit-arm read is dead and is never emitted.
    const read = if (self.lowered.timepoints.items.len != 0) try readSet(self, jobs.items) else &.{};
    for (self.lowered.timepoints.items) |t| {
        if (self.an.foldConst(t.mark, false) == null) try jobs.append(self.arena, .{
            .kind = .timepoint,
            .target = self.an.rv(t.mark),
            .mode = .strict,
        });
        for (t.slots) |sl| if (read[@backingInt(self.an.rv(sl.final))]) try jobs.append(self.arena, .{
            .kind = .timepoint,
            .target = self.an.rv(sl.final),
            .mode = .strict,
        });
    }
    if (self.lowered.reject_step != .undef) try jobs.append(self.arena, .{
        .kind = .reject_step,
        .target = self.an.rv(self.lowered.reject_step),
        .mode = .strict,
    });
    // §9.7.3 a device reports `$fatal`/`$error` as a status (a printing
    // artifact runs the display chain instead). Values that fold are written
    // as constants by `zStatusStore` and need no core field.
    if (!from.emit_display and self.lowered.status != .undef) {
        const vals = [_]Mir.Value{self.lowered.status} ++ self.lowered.status_args;
        for (vals) |v| {
            if (v == .undef or self.an.foldConst(v, false) != null) continue;
            try jobs.append(self.arena, .{
                .kind = .status,
                .target = self.an.rv(v),
                .mode = .strict,
            });
        }
    }
    // Clause 12 the values a VPI device reports beside the residual: each
    // row's reactive half (a resistive half is a `.resist` job already) and
    // each instance's share of a shared row. After every kind `eval` reads,
    // so the fields before them number as they do without `vpi`.
    if (from.vpi) {
        for (self.lowered.contributions.items, 0..) |c, i| try queueVpi(self, &jobs, from, c.react_val, i);
        for (self.lowered.contrib_shares.items) |sh| {
            try queueVpi(self, &jobs, from, sh.resist_val, sh.row);
            try queueVpi(self, &jobs, from, sh.react_val, sh.row);
        }
    }
    // §9.4 the display tasks, as one unit. Queued last, so no existing job
    // (and so no declaration name) moves when a model gains or loses a
    // `$strobe`. `.strict` unconditionally: a print is not on the residual
    // path, and proof.zig rates contributions only.
    const root = self.an.rv(self.lowered.display_root);
    if ((from.emit_display or from.record_display) and root != .f_zero) {
        out.display_name = try naming.unitNameAlloc(self.arena, self.mir.name, .{
            .role = .display,
            .target = "tasks",
        });
        try jobs.append(self.arena, .{
            .kind = .display,
            .target = root,
            .mode = .strict,
        });
    }
    out.list = jobs.items;
    return out;
}

/// Queues `v`, a value of contribution `row`, as a `.vpi` job unless it is 0.
fn queueVpi(self: Input, jobs: *std.ArrayList(Job), from: From, v: Mir.Value, row: usize) !void {
    const t = self.an.rv(v);
    if (t == .f_zero) return;
    try jobs.append(self.arena, .{
        .kind = .vpi,
        .target = t,
        .mode = unitMode(from.unit_modes, row),
    });
}

/// Value -> some instruction reads it, or a job in `queued` returns it. Dead
/// instructions count: the answer only has to be a superset. One sweep of
/// every instruction, O(instructions).
fn readSet(self: Input, queued: []const Job) ![]bool {
    const read = try self.arena.alloc(bool, self.an.nv);
    @memset(read, false);
    for (queued) |j| read[@backingInt(self.an.rv(j.target))] = true;
    for (0..self.mir.insts.len) |ii| {
        const inst: Mir.Inst = @fromBackingInt(@intCast(ii));
        switch (self.mir.instData(inst)) {
            .unary => |d| read[@backingInt(self.an.rv(d.operand))] = true,
            .binary => |d| for ([_]Mir.Value{ d.lhs, d.rhs }) |v| {
                read[@backingInt(self.an.rv(v))] = true;
            },
            .ternary => |d| for ([_]Mir.Value{ d.cond, d.then_val, d.else_val }) |v| {
                read[@backingInt(self.an.rv(v))] = true;
            },
            .phi => |d| for (0..d.count) |k| {
                read[@backingInt(self.an.rv(self.mir.phiPair(inst, @intCast(k)).value))] = true;
            },
            .branch => |d| read[@backingInt(self.an.rv(d.cond))] = true,
            .call => |d| for (d.args) |v| {
                read[@backingInt(self.an.rv(v))] = true;
            },
            .load => |d| for ([_]Mir.Value{ d.arr, d.index }) |v| {
                read[@backingInt(self.an.rv(v))] = true;
            },
            .store => |d| for ([_]Mir.Value{ d.arr, d.index, d.value }) |v| {
                read[@backingInt(self.an.rv(v))] = true;
            },
            .jump, .anew => {},
        }
    }
    return read;
}

/// Returns the prover's float mode for unit `i`, or `.strict` for a unit
/// the prover did not rate.
fn unitMode(unit_modes: []const proof.FloatMode, i: usize) proof.FloatMode {
    // proof.zig rates the CONTRIBUTION units only (proof.unitCount ==
    // lower.contributions.len); an analog-operator unit is not covered, so
    // it takes the safe side.
    if (i >= unit_modes.len) return .strict;
    return unit_modes[i];
}

/// §4.5 Table 4-20 "Analog operator arguments": whether argument position `ai`
/// is one `updateState` reads off the core: the clause marks it DYNAMIC, or
/// §4.5.14 samples it (the input at position 0 is already a unit of its own,
/// so it is not one). Everything else stays a `constant_expression` and is
/// still E0515 when it is a solve result.
fn isDynCtrlArg(k: OpKind, ai: usize) bool {
    return switch (k) {
        // td ("dynamic: expr, td"), and maxdelay: the constant one, but §4.5.14
        // samples a dynamic value there "at the start of the analysis", which
        // `updateState` latches off this field (`absdelayMaxdSampled`).
        .absdelay => ai == 1 or ai == 2,
        .idt_hold => ai == 1 or ai == 2, // ic, assert
        .idtmod => ai >= 1 and ai <= 3, // ic, modulus, offset
        // §4.5.14 every filter coefficient, latched the same way
        // (`cg_filters.FilterPlan.sampled`). The flattened vector counts fold
        // and a moving ε is E0515 in lowering, so neither is queued; a moving
        // zi_* period, τ or t0 is queued and then refused by the plan.
        .laplace, .zi => ai >= 1,
        .none, .transition, .slew, .last_crossing, .cross, .above, .timer, .bound_step, .discontinuity => false,
    };
}

const Fixture = @import("prove").Fixture;

test "jobs queue in insert-tolerant order: contributions, operator inputs, held values" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{ "a", "b" });
    defer f.deinit();
    const a = f.alloc();
    const va = try f.probe(0);
    const vb = try f.probe(1);
    const q = try f.call("slew", &.{va}); // an operator unit, input V(a)
    // I(a,b) <+ V(b) + ddt(slew(V(a))): a resistive and a reactive target.
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 0, .lo = 1, .resist_val = vb, .react_val = q });
    try f.lowered.charge_sites.append(a, .{ .contrib = 0, .sign = 1, .final = q });
    try f.lowered.held_vars.append(a, .{ .name = "h", .ty = .real, .init = .f_zero, .seed = .f_zero, .final = vb });
    const an = try f.analysis();
    const in: Input = .{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered };
    const names = try @import("names.zig").plan(in, 1);
    const noise: plan_noise.Noise = .{};
    const never = struct {
        pub fn isDynamic(_: @This(), _: Mir.Value) error{}!bool {
            return false;
        }
    }{};

    const jobs = try plan(in, .{
        .names = &names,
        .unit_modes = &.{.optimized},
        .limits = &.{},
        .noise = &noise,
        .emit_display = false,
        .q_sites = &.{0},
    }, never);
    const kinds = try a.alloc(Job.Kind, jobs.list.len);
    for (jobs.list, kinds) |j, *k| k.* = j.kind;
    try std.testing.expectEqualSlices(Job.Kind, &.{ .resist, .react, .op_input, .held }, kinds);
    // The contribution keeps the prover's mode; an operator unit and a held
    // value are not rated by it and take the safe side.
    try std.testing.expectEqual(proof.FloatMode.optimized, jobs.list[0].mode);
    try std.testing.expectEqual(proof.FloatMode.strict, jobs.list[2].mode);
    try std.testing.expectEqual(va, jobs.list[2].target);
    try std.testing.expectEqualStrings("", jobs.display_name);
}

/// A `dyn` stub: every §4.5 control argument and §4.6.3 stimulus reads the solve.
const always = struct {
    pub fn isDynamic(_: @This(), _: Mir.Value) error{}!bool {
        return true;
    }
}{};

test "§4.5 Table 4-20: an absdelay's td and maxdelay are queued only when they render off the core" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{ "a", "b" });
    defer f.deinit();
    const a = f.alloc();
    const va = try f.probe(0);
    const vb = try f.probe(1);
    const maxd = try f.mir.addFloatConst(a, 1e-9);
    // absdelay(V(a), V(b), 1n): input, then `td` and `maxdelay`.
    _ = try f.call("absdelay", &.{ va, vb, maxd });
    const an = try f.analysis();
    const in: Input = .{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered };
    const names = try @import("names.zig").plan(in, 0);
    const noise: plan_noise.Noise = .{};
    const from: From = .{ .names = &names, .unit_modes = &.{}, .limits = &.{}, .noise = &noise, .emit_display = false };
    try std.testing.expectEqualSlices(Mir.Value, &.{ va, vb, maxd }, names.opArgs(&f.mir, 0));

    const dyn_jobs = try plan(in, from, always);
    try std.testing.expectEqual(@as(usize, 3), dyn_jobs.list.len);
    try std.testing.expectEqual(Job.Kind.op_input, dyn_jobs.list[0].kind);
    try std.testing.expectEqual(Job.Kind.ctrl, dyn_jobs.list[1].kind);
    try std.testing.expectEqual(vb, dyn_jobs.list[1].target);
    try std.testing.expectEqual(maxd, dyn_jobs.list[2].target);

    const never = struct {
        pub fn isDynamic(_: @This(), _: Mir.Value) error{}!bool {
            return false;
        }
    }{};
    const host_jobs = try plan(in, from, never);
    try std.testing.expectEqual(@as(usize, 1), host_jobs.list.len);
}

test "limit arguments, noise PSDs, the retry time, the status and the display unit queue in Kind order" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{ "a", "b" });
    defer f.deinit();
    const a = f.alloc();
    const va = try f.probe(0);
    const vb = try f.probe(1);
    const vt = try f.mir.addFloatConst(a, 0.025);
    const lit = try f.mir.addFloatConst(a, 0.6);
    const pwr = try f.mir.addFloatConst(a, 1.6e-21);
    const ex = try f.mir.addFloatConst(a, 1.5);
    const retry = try f.mir.addFloatConst(a, 1e-6);
    const code = try f.mir.addIntConst(a, 42);
    f.lowered.reject_step = retry;
    f.lowered.status = vb; // a status the solve decides
    f.lowered.status_args[0] = code; // folds: written as a constant
    f.lowered.display_root = va;
    const an = try f.analysis();
    const in: Input = .{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered };
    const names = try @import("names.zig").plan(in, 0);
    // A literal seed is written in place; a solve-valued one is queued. A
    // zero vcrit or sign is not an argument at all.
    const limits = [_]LimitCall{
        .{ .alg = .pnjlim, .hi = 0, .lo = 1, .argv = .{ vt, .f_zero }, .seed = lit },
        .{ .alg = .pnjlim, .hi = 0, .lo = 1, .argv = .{ vt, .f_zero }, .seed = vb },
    };
    // §4.6.4: the power always rides the core (a conditional generator must
    // read back 0); a constant exponent renders inline; a bias-dependent
    // coefficient rides the core.
    var rows = [_]plan_noise.NoiseRow{.{ .row = 0, .col = 1, .kind = .flicker, .source = 0, .pwr = pwr, .exp = ex, .coeff = vb }};
    const noise: plan_noise.Noise = .{ .rows = &rows };

    const jobs = try plan(in, .{
        .names = &names,
        .unit_modes = &.{},
        .limits = &limits,
        .noise = &noise,
        .emit_display = false,
        .record_display = true,
    }, always);
    const kinds = try a.alloc(Job.Kind, jobs.list.len);
    const targets = try a.alloc(Mir.Value, jobs.list.len);
    for (jobs.list, kinds, targets) |j, *k, *t| {
        k.* = j.kind;
        t.* = j.target;
    }
    try std.testing.expectEqualSlices(Job.Kind, &.{ .limit_arg, .limit_arg, .limit_arg, .noise, .noise, .reject_step, .status, .display }, kinds);
    try std.testing.expectEqualSlices(Mir.Value, &.{ vt, vt, vb, pwr, vb, retry, vb, va }, targets);
    try std.testing.expectEqualStrings("mymod__display__tasks", jobs.display_name);
    // Every job but the contributions' is `.strict`: proof rates contributions only.
    for (jobs.list) |j| try std.testing.expectEqual(proof.FloatMode.strict, j.mode);
}

test "a printing artifact keeps the §9.7.3 status off the core; a device that drops its prints has no display unit" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{"a"});
    defer f.deinit();
    const a = f.alloc();
    const va = try f.probe(0);
    f.lowered.status = va;
    f.lowered.display_root = va;
    const an = try f.analysis();
    const in: Input = .{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered };
    const names = try @import("names.zig").plan(in, 0);
    const noise: plan_noise.Noise = .{};
    var from: From = .{ .names = &names, .unit_modes = &.{}, .limits = &.{}, .noise = &noise, .emit_display = true };
    const emit = try plan(in, from, always);
    try std.testing.expectEqual(@as(usize, 1), emit.list.len);
    try std.testing.expectEqual(Job.Kind.display, emit.list[0].kind);
    from.emit_display = false;
    const drop = try plan(in, from, always);
    try std.testing.expectEqual(@as(usize, 1), drop.list.len);
    try std.testing.expectEqual(Job.Kind.status, drop.list[0].kind);
    try std.testing.expectEqualStrings("", drop.display_name);
}

test unitMode {
    try std.testing.expectEqual(proof.FloatMode.optimized, unitMode(&.{ .optimized, .strict }, 0));
    try std.testing.expectEqual(proof.FloatMode.strict, unitMode(&.{ .optimized, .strict }, 1));
    // An analog-operator unit the prover never rated takes the safe side.
    try std.testing.expectEqual(proof.FloatMode.strict, unitMode(&.{}, 0));
    try std.testing.expectEqual(proof.FloatMode.strict, unitMode(&.{.optimized}, 1));
}
