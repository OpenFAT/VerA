//! The accepted timepoint -> its work, shared by `updateState` and `acceptQ`:
//! stage the §5.6.1.2 path latches, advance every §4.5 operator's `Instance`
//! slots once (§4.5.2), latch §5.10.3 event state and §5.10 held values, and,
//! for `acceptQ`, the accepted point's charges from the same hoisted core call.
//! Cites: §2.9, §4.5.2, §4.5.7, §4.5.10, §4.5.12, §5.6.1.2, §5.10, §5.10.3,
//! §9.13.1, §9.17.
//!
//! Contents:
//! - `pub fn emitAcceptQ(self: *Gen, acc: gen_state.Accept) Error!void`
//! - `pub fn emitAcceptBody(self: *Gen, acc: gen_state.Accept) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const call_operator = @import("call_operator.zig");
const operator_ctrl = @import("operator_ctrl.zig");
const cg_strcap = @import("../cg_strcap.zig");
const gen_host = @import("host_expr.zig");
const gen_dispatch = @import("dispatch.zig");
const dispatch_q = @import("dispatch_q.zig");
const gen_instance = @import("instance.zig");
const gen_status = @import("status.zig");
const gen_unit = @import("unit.zig");
const render_array = @import("render_array.zig");
const Mir = @import("ir").Mir;
const cg_filters = @import("../cg_filters.zig");
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const gen_state = @import("state.zig");

/// Writes `acceptQ`: the accepted-point `q` and `updateState` work from one
/// hoisted `core` call (§5.6.1.2, §4.5.2). Emitted only for a device with a
/// reactive half.
pub fn emitAcceptQ(self: *Gen, acc: gen_state.Accept) Error!void {
    assert(self.core.name.len != 0 or self.core.lo_vals.len == 0);
    if (!gen_dispatch.anyQ(self)) return;
    // It returns the charges, so it has no way to carry a
    // `$vera_reject_step` request: such a host calls `q` and `updateState`.
    if (self.lowered.reject_step != .undef) return;
    // §9.7.3 a latched status leaves the state alone, which `updateState`
    // checks first; a status device calls `q` and `updateState`.
    if (gen_status.hasStatus(self)) return;
    // §9.21.1 (VD-095) `updateState` keeps a table capture from its own core
    // run; a table device's host calls `q` and `updateState`.
    if (self.lowered.table_samples.items.len != 0) return;
    self.cur.uses.x = false;
    self.cur.uses.model = false;
    self.cur.uses.inst = true; // the §9.17 resets below always write it
    self.cur.core_wanted = false;
    self.cur.core_hoisted = true;
    defer self.cur.core_hoisted = false;
    try self.w(
        \\/// §5.6.1.2 + §4.5.2 the accepted-point pass from ONE core evaluation.
        \\/// Returns `q(S, x, model, inst, sim)` and then does what
        \\/// `updateState(S, model, inst, x.*, state, sim)` does, reading the
        \\/// same core result.
        \\
    , .{});
    try self.w("pub fn acceptQ(comptime S: type, ", .{});
    const at_x = self.out.items.len;
    try self.w("x: *const [n_u]S.V, ", .{});
    const at_model = self.out.items.len;
    try self.w("model: *const Model, inst: *Instance, {s}: *State, sim: contract.SimState) contract.Sites(Self, S) {{\n", .{
        if (acc.reads_t_prev or gen_instance.pathLatches(self)) "state" else "_",
    });
    const at_core = self.out.items.len;
    // §5.6.1.2 the charges, one per site (`q`'s layout).
    self.cur.core_wanted = true;
    try self.b("    const qq = ", .{});
    try dispatch_q.writeSites(self);
    try self.b(";\n", .{});
    try emitAcceptBody(self, acc);
    try self.w("    return qq;\n}}\n\n", .{});
    if (self.cur.core_wanted or acc.uses_core) {
        self.cur.uses.x = true;
        self.cur.uses.model = true;
        try self.out.insertSlice(self.gpa, at_core, try self.arena.print("    const m = @call(.always_inline, core, .{{ S, zProbe(S, x), model, inst, sim{s} }});\n", .{self.heldArg(true)}));
    }
    if (!self.cur.uses.x) gen_unit.patchParam(self, at_x, "x".len);
    if (!self.cur.uses.model) gen_unit.patchParam(self, at_model, "model".len);
}

/// Writes the accepted-step body shared by `updateState` and `acceptQ`:
/// stages the path latches, advances every operator, writes the held
/// variables back. The emitted code reads the core result `m`.
pub fn emitAcceptBody(self: *Gen, acc: gen_state.Accept) Error!void {
    assert(self.core.prev_lo.len == self.core.prev_vals.len);
    assert(self.core.acc_lo.len == self.core.acc_vals.len);
    assert(self.core.held_idx.len == self.lowered.held_vars.items.len);
    const val = ".val()";
    const uses_dt = acc.uses_dt;
    // VerA's `vera_timepoint` (§2.9): the held values below move, and a
    // static solve iterates again at the same time when asked to.
    if (self.lowered.timepoints.items.len != 0) try self.w("    zTpDrop(inst);\n", .{});
    // §5.6.1.2 stage the path-latch operands. They commit only at
    // stateCtl(.commit), so a rejected attempt leaves pb/pq untouched and
    // the retry reopens on the accepted charge.
    for (self.core.prev_lo, 0..) |lo, k| {
        try self.w("    state.wb__{d} = m.f{d}{s}; // path_prev staging\n", .{ k, lo, val });
    }
    for (self.core.acc_lo, 0..) |lo, k| {
        try self.w("    state.wq__{d} = m.f{d}{s}; // path_acc staging\n", .{ k, lo, val });
    }
    if (uses_dt) try self.w("    const dt = sim.t - state.t_prev;\n", .{});
    // §9.17 reset first, unconditionally: a `$bound_step` that fired on one
    // arm last step must not keep bounding this one.
    try self.w(
        \\    inst.bound_step = std.math.inf(f64); // §9.17.2
        \\    inst.discontinuity_order = -1; // §9.17.1
        \\
    , .{});
    if (try operator_ctrl.anyCrossLocated(self)) try self.w("    inst.vera_cross_retry__ = std.math.inf(f64); // §5.10.3.1\n", .{});
    // §9.13.1 the internal seed advances only here, once per accepted point,
    // so the residual it feeds is fixed across the Newton loop.
    if (self.lowered.rng_auto_seeds.items.len != 0) try self.w(
        \\    // §9.13.1 "this internal seed gets updated every time the call
        \\    // to $arandom is made" — once per ACCEPTED point, per call site.
        \\    for (&inst.rng_auto) |*rs| rs.* = @intFromFloat(zRngNext(rs.*));
        \\
    , .{});
    for (self.names.units, 0..) |u, i| {
        const k = u.op;
        if (u.role != .analog_op or k == .none) continue;
        const n = self.names.unit_names[i];
        assert(n.len != 0);
        const inst = self.names.opInstOf(@intCast(i)) orelse continue;
        self.cur.ctrl_tok = self.mir.instTok(inst); // E0515's fallback span
        const original_args = self.mir.instData(inst).call.args;
        const latest = self.lowered.timer_controls.get(inst);
        const args: []const Mir.Value = if (latest) |*v| v else original_args;
        const lo = gen_unit.opInputIdx(self, @intCast(i));
        if (latest != null) {
            try self.w("    {{\n        const in = {s};\n", .{try operator_ctrl.ctrlStep(self, args, 0, "0.0")});
        } else if (lo == none_u32) {
            try self.w("    {{\n        const in: f64 = 0.0;\n", .{});
        } else {
            try self.w("    {{\n        const in = m.f{d}{s};\n", .{ lo, val });
        }
        switch (k) {
            // §4.5.4 "Once assert becomes zero, idt() returns the integral
            // of the argument starting from the last instant where assert
            // was nonzero": the row holds s still while assert is nonzero,
            // and the offset latched then makes the value ic(ta) + ∫ from ta.
            .idt_hold => try self.w("        if (({s}) != 0.0) inst.{s}__off = in - ({s});\n", .{
                try operator_ctrl.ctrlStep(self, args, 2, "0.0"), n, try operator_ctrl.ctrlStep(self, args, 1, "0.0"),
            }),
            .idtmod => try self.w("        inst.{s}__acc = zWrap(zIdtAcc(in, inst.{s}__acc, dt, {s}), {s}, {s});\n", .{
                n,                                                n,
                try operator_ctrl.ctrlStep(self, args, 1, "0.0"), try operator_ctrl.ctrlStep(self, args, 2, "0.0"),
                try operator_ctrl.ctrlStep(self, args, 3, "0.0"),
            }),
            .absdelay => {
                // §4.5.7 a full ring keeps its window (`zHistThin`); a revert
                // undoes a thinning push (`zHistRevert`).
                try self.w("        zHistThin(\"{s}.{s}\", &inst.{s}__t, &inst.{s}__v, &inst.{s}__head, sim.t, inst.{s}__w);\n", .{ self.mir.name, n, n, n, n, n });
                try self.w("        zHistPush(&inst.{s}__t, &inst.{s}__v, &inst.{s}__head, sim.t, in);\n", .{ n, n, n });
                // §4.5.7 the window a full ring keeps (`zHistThin`): maxdelay
                // bounds every lookback; without one, td is the lookback.
                try self.w("        inst.{s}__w = {s};\n", .{ n, if (args.len >= 3)
                    (if (try operator_ctrl.absdelayMaxdSampled(self, args))
                        try self.arena.print("inst.{s}__maxd", .{n})
                    else
                        try gen_host.argF64(self, args, 2, "0.0"))
                else
                    try operator_ctrl.absdelayTd(self, n, args, true) });
                // §4.5.7 "the value of td when the absdelay() is first
                // evaluated shall be used": the static point is that first
                // evaluation, and `zAbsdelay` passes its input through there.
                if (try operator_ctrl.absdelayFreezes(self, args)) try self.w(
                    "        if (sim.t <= state.t_prev) inst.{s}__td = {s};\n",
                    .{ n, try operator_ctrl.ctrlStep(self, args, 1, "0.0") },
                );
                // §4.5.14 a dynamic maxdelay: its value at the start of the
                // analysis, latched at the same first evaluation.
                if (try operator_ctrl.absdelayMaxdSampled(self, args)) try self.w(
                    "        if (sim.t <= state.t_prev) inst.{s}__maxd = {s};\n",
                    .{ n, try operator_ctrl.ctrlStep(self, args, 2, "0.0") },
                );
                // §9.17.2 bound the step at td, as the §4.5.12 filter does
                // with its period: a wider step flattens the delay and the
                // ring records nothing finer than the steps taken. `td` may
                // be a model expression, so the bound is computed at run
                // time; only a positive one binds, since 0 would stop time.
                try self.w(
                    "        const zad_td = {s};\n        if (zad_td > 0.0) inst.bound_step = @min(inst.bound_step, zad_td);\n",
                    .{try operator_ctrl.absdelayTd(self, n, args, true)},
                );
            },
            .transition => {
                const t = try call_operator.transitionTimes(self, args);
                try self.w(
                    "        zTransStep(in, &inst.{0s}__from, &inst.{0s}__to, &inst.{0s}__t0, " ++
                        "sim.t, dt, {1s}, {2s}, {3s});\n",
                    .{ n, try gen_host.argF64(self, args, 1, "0.0"), t[0], t[1] },
                );
            },
            .slew => {
                const r = try call_operator.slewRates(self, args);
                try self.w("        inst.{s}__prev = zSlew(zL(S, 0), zL(S, 0).con(in), inst.{s}__prev, dt, {s}, @abs({s})).val();\n", .{
                    n, n, r[0], r[1],
                });
            },
            // §4.5.10 `last_crossing(expr, direction)`: the direction is
            // decoded as §5.10.3 `cross`'s is (+1 rising, -1 falling, 0
            // either). `dt > 0.0` is the seeding rule: `__prev` starts at
            // 0.0, a value the signal never had, so the DC point (dt = 0)
            // only seeds the history. Otherwise a signal at -1 V would read
            // as a crossing at t = 0, not the "negative value" §4.5.10
            // requires before the first real crossing. The time is
            // `lastCrossTime`, the value `eval` already answered with at this
            // point, so the latch never moves it by a rounding.
            .last_crossing => try self.w(
                \\        if (dt > 0.0 and ({1s})) inst.{0s}__t_last = {2s};
                \\        inst.{0s}__prev = in;
                \\
            , .{ n, try operator_ctrl.crossTest(self, n, args, "in", true), try operator_ctrl.lastCrossTime(self, n, "in") }),
            // §5.10.3 only the history moves here; `eval` raises the event,
            // so nothing is observed one timepoint late. `enable` gates the
            // event, not the record, so a re-enabled operator never compares
            // against a stale sample.
            // §5.10.3.1 a `cross` with its own tolerance box also says where
            // an event this point found outside the box should have fired,
            // read against `__prev` before it moves.
            .cross, .above => {
                if (k == .cross and try operator_ctrl.crossLocated(self, args)) try self.w(
                    \\        if (sim.kind == .tran and sim.dt > 0.0 and ({1s})) if (zCrossRetry(inst.{0s}__prev, in, sim.t, sim.dt, {2s}, {3s})) |r| {{
                    \\            inst.vera_cross_retry__ = @min(inst.vera_cross_retry__, r);
                    \\        }};
                    \\
                , .{
                    n,
                    try operator_ctrl.crossTest(self, n, args, "in", true),
                    try operator_ctrl.ctrlStep(self, args, 2, "0.0"),
                    try operator_ctrl.ctrlStep(self, args, 3, "0.0"),
                });
                try self.w("        inst.{s}__prev = in;\n", .{n});
            },
            // §5.10.3.3 the latest start and period define the absolute grid,
            // including changes BETWEEN fires. Count rather than accumulate,
            // advancing even while enable suppresses delivery.
            .timer => try self.w(
                \\        const period = {1s};
                \\        inst.{0s}__start = in;
                \\        inst.{0s}__per = period;
                \\        inst.{0s}__next = zNextTimer(in, period, sim.t) orelse z_inf;
                \\
            , .{ n, try operator_ctrl.timerPeriod(self, args) }),
            // §9.17.2 "no larger than the smallest $bound_step() argument
            // currently active". `in` is already the minimum over every
            // executed `$bound_step` (lowering accumulates it); `@min` folds
            // it with the §4.5.12 sampling periods written earlier.
            .bound_step => try self.w("        inst.bound_step = @min(inst.bound_step, in);\n", .{}),
            // §9.17.1 `inf` means no announcement. `lossyCast` saturates a
            // huge degree instead of UB in a ReleaseFast artifact.
            .discontinuity => try self.w(
                "        inst.discontinuity_order = if (std.math.isFinite(in)) std.math.lossyCast(i32, in) else -1;\n",
                .{},
            ),
            // §4.5.11 advance the cascade on the accepted solution.
            .laplace => {
                const p = cg_filters.planOf(self, i);
                if (p.err == null) try self.w(
                    "        zLaplaceStep({d}, {d}, in, {s}, dt, &inst.{s}__u, &inst.{s}__y);\n",
                    .{ p.ns, p.deg, try gen_state.secStep(self, n, p, "dt"), n, n },
                );
            },
            // §4.5.12 the filter runs on its own timebase: sample when the
            // accepted time reaches the next multiple of T, hold between.
            // The step bound keeps the solver from stepping over a sample.
            .zi => {
                const p = cg_filters.planOf(self, i);
                const sec = if (p.err == null) try gen_state.secStep(self, n, p, "sim.dt") else "";
                // §4.5.12 τ/t0: the samples fall on t0 + k·T, and each starts a
                // τ-long transition from wherever the previous one had reached
                // (`zZiRamp`). Before a positive t0 the output holds the
                // operating point's value, H(1)·in. The step bound keeps the
                // solver inside a transition as well as between samples.
                if (p.err == null and p.tau != null) try self.w(
                    \\        const period = {1s};
                    \\        const zi_t0: f64 = {4s};
                    \\        const zi_tau: f64 = {5s};
                    \\        if (!(sim.dt > 0.0) and inst.{0s}__nk == 0.0 and zi_t0 > 0.0) {{
                    \\            inst.{0s}__out = in * zZiGain({2d}, {3d}, {6s});
                    \\            inst.{0s}__from = inst.{0s}__out;
                    \\        }}
                    \\        var zi_k = zZiDue(sim.t - zi_t0, inst.{0s}__nk, period);
                    \\        if (zi_k > 0) {{
                    \\            const zi_ts = zi_t0 + (inst.{0s}__nk + @as(f64, @floatFromInt(zi_k)) - 1.0) * period;
                    \\            inst.{0s}__from = zZiRamp(inst.{0s}__from, inst.{0s}__out, inst.{0s}__ts, zi_tau, zi_ts);
                    \\            inst.{0s}__ts = zi_ts;
                    \\            inst.{0s}__nk += @as(f64, @floatFromInt(zi_k));
                    \\            while (zi_k > 0) : (zi_k -= 1)
                    \\                inst.{0s}__out = zZiStep({2d}, {3d}, in, {6s}, &inst.{0s}__u, &inst.{0s}__y);
                    \\            // §9.17.1: a step in value, or with τ > 0 a corner in slope.
                    \\            const zi_order: i32 = if (zi_tau > 0.0) 1 else 0;
                    \\            if (inst.discontinuity_order < 0 or inst.discontinuity_order > zi_order) inst.discontinuity_order = zi_order;
                    \\        }}
                    \\        inst.bound_step = @min(inst.bound_step, period);
                    \\        if (zi_tau > 0.0) inst.bound_step = @min(inst.bound_step, zi_tau);
                    \\
                , .{ n, p.period orelse "0.0", p.ns, p.deg, p.t0.?, p.tau.?, sec }) else if (p.err == null) try self.w(
                    \\        const period = {1s};
                    \\        // §4.5.12: "T specifies the sampling period of the filter".
                    \\        // The recurrence runs once per T of SIMULATED TIME, so a step that
                    \\        // crosses k sample instants runs it k times. Stepping it ONCE per
                    \\        // evaluation — which is what this did — makes the output a function
                    \\        // of how densely the host happened to place its timepoints, and the
                    \\        // same filter at the same T returned bit-identical values for 20 us
                    \\        // and 200 us of elapsed time.
                    \\        //
                    \\        // `zZiDue` counts off the k*T GRID, and `eval` calls the identical
                    \\        // function: the two halves of the operator cannot disagree about
                    \\        // which timepoint is a sample instant. A `__next` time re-armed by
                    \\        // `+= zn*T` could and did — three additions of 1e-9 overshoot the
                    \\        // double nearest 3e-9, and the sample at t = 3T was lost for good.
                    \\        var zi_k = zZiDue(sim.t, inst.{0s}__nk, period);
                    \\        if (zi_k > 0) {{
                    \\            inst.{0s}__nk += @as(f64, @floatFromInt(zi_k));
                    \\            while (zi_k > 0) : (zi_k -= 1)
                    \\                inst.{0s}__out = zZiStep({2d}, {3d}, in, {4s}, &inst.{0s}__u, &inst.{0s}__y);
                    \\            inst.discontinuity_order = 0; // §9.17.1 the held output steps
                    \\        }}
                    \\        inst.bound_step = @min(inst.bound_step, period);
                    \\
                , .{ n, p.period orelse "0.0", p.ns, p.deg, sec });
            },
            .none => {},
        }
        try self.w("    }}\n", .{});
    }
    // §5.10 store every held variable back, only here: writing from `eval`
    // would latch a Newton iterate the solver may discard.
    //
    // A string's new text may be a slice of another held string's field
    // (`b = a; a = "x";` in one event body), so every string is copied out
    // before any is stored (#19).
    for (self.lowered.held_vars.items, 0..) |h, i| {
        const k = self.core.held_idx[i];
        assert(k == none_u32 or k < self.core.lo_vals.len);
        if (h.ty == .string and h.array == none_u32 and k != none_u32) {
            try self.w("    const zs{d} = ", .{i});
            try cg_strcap.emitHeldCopy(self, i);
            try self.w("m.f{d});\n", .{k});
        }
    }
    for (self.lowered.held_vars.items, 0..) |h, i| {
        const k = self.core.held_idx[i];
        const n = self.names.held_names[i];
        if (k == none_u32) {
            // Folded away: never assigned outside the §5.10 body, whose
            // value is a literal zero.
            if (h.ty == .wide)
                try self.w("    inst.{s} = zwZero({d});\n", .{ n, h.width })
            else
                try self.w("    inst.{s} = 0;\n", .{n});
        } else if (h.array != none_u32) {
            // §3.2.2 a held array's core field is already its plain values;
            // an in-place one is already in `inst`.
            if (render_array.inPlace(self, h.array)) continue;
            try self.w("    inst.{s} = m.f{d};\n", .{ n, k });
            if (gen_instance.dirtyTracked(self, h.array))
                try self.w("    inst.{s}__dirty = .{{ 0, {d} }};\n", .{ n, self.lowered.mem_arrays.items[h.array].len - 1 });
        } else {
            // The core field is typed by `vty`, not the declared type, and
            // the two can disagree (a join left at `.real`). The declared
            // type picks the destination, with the §4.2.1 conversion.
            const core_int = self.an.tyOf(self.core.lo_vals[k]) == .int;
            switch (h.ty) {
                .integer => if (core_int)
                    try self.w("    inst.{s} = m.f{d};\n", .{ n, k })
                else
                    try self.w("    inst.{s} = std.math.lossyCast(i64, @round(m.f{d}{s}));\n", .{ n, k, val }),
                .string => try self.w("    inst.{s} = zs{d};\n", .{ n, i }),
                .wide => try self.w("    inst.{s} = m.f{d};\n", .{ n, k }),
                .real => if (core_int)
                    try self.w("    inst.{s} = @floatFromInt(m.f{d});\n", .{ n, k })
                else
                    try self.w("    inst.{s} = m.f{d}{s};\n", .{ n, k, val }),
            }
        }
    }
    if (acc.reads_t_prev) try self.w("    state.t_prev = sim.t;\n", .{});
}
