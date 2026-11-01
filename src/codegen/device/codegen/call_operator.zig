//! A §4.5 analog operator call -> its text: a stateless `limexp` or `ddx`
//! (`emitPlain`), or a stateful operator's kernel call with its `Instance`
//! fields, its control arguments in the residual's frame
//! (`operator_ctrl.zig`), the §4.5.7/§4.5.11/§4.5.12 small-signal form, and
//! the §4.5.8/§4.5.9 default transition times and slew rates.
//! Cites: §4.5, §4.5.7, §4.5.8, §4.5.9, §4.5.11, §4.5.12, §4.5.13, §4.5.14, §10.3.
//!
//! Contents:
//! - `pub fn emitOperator(self: *Gen, inst: Mir.Inst, args: []const Mir.Value, k: OpKind) Error!void`
//! - `pub fn emitPlain(self: *Gen, comptime c: Mir.Callee, args: []const Mir.Value) Error!void`
//! - `pub fn transitionTimes(self: *Gen, args: []const Mir.Value) Error![2][]const u8`
//! - `pub fn slewRates(self: *Gen, args: []const Mir.Value) Error![2][]const u8`

const std = @import("std");
const assert = std.debug.assert;
const float_lanes = @import("float/lanes.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_mask = @import("mask.zig");
const gen_file = @import("file.zig");
const gen_render = @import("render.zig");
const gen_host = @import("host_expr.zig");
const family = @import("family.zig");
const gen_unit = @import("unit.zig");
const Mir = @import("ir").Mir;
const cg_filters = @import("../cg_filters.zig");
const Lower = @import("ir").Lowered;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const ir_op = @import("ir").op;
const OpKind = ir_op.OpKind;
const operator_ctrl = @import("operator_ctrl.zig");
const gen_call = @import("call.zig");
const gen_stamps = @import("stamps.zig");
const render_op = @import("render_op.zig");

/// Writes a §4.5 stateful analog operator call. Each operator is a named
/// unit, so its `Instance` fields and `updateState`'s read share a stable key.
/// Asserts that `k` is a stateful operator and that the call names a unit.
/// Invalidates slices of `out.items` if additional memory is needed.
pub fn emitOperator(self: *Gen, inst: Mir.Inst, args: []const Mir.Value, k: OpKind) Error!void {
    assert(k != .none);
    assert(self.mir.instOp(inst) == .call);
    self.cur.ctrl_tok = self.mir.instTok(inst); // E0515's fallback span
    const unit = gen_unit.unitOfInst(self, inst);
    if (unit == none_u32) return self.b("S.con(0.0)", .{});
    const n = self.names.unit_names[unit];
    assert(n.len != 0);
    // Render the input only when the kernel reads it, or `uses.x` would keep
    // an unreferenced parameter named.
    const needs_in = ir_op.needsInput(k);
    // Every operator input is a core field, so this renders a local in the
    // core and a cache read in the display unit.
    const in0 = if (needs_in)
        try gen_render.renderToArena(self, if (args.len == 0) .f_zero else args[0], .real)
    else
        "";
    self.cur.uses.inst = true;
    float_lanes.instPin(self); // the operator's history is the instance's
    // Every sim-state read below is spelled `sim.<field>`.
    const at = self.out.items.len;
    defer if (std.mem.find(u8, self.out.items[at..], "sim.") != null) {
        self.cur.uses.sim = true;
    };
    // A kernel runs at the result's mask `fm`, as `gen_render.kernelOpen`
    // says; `kS` is its scalar and `in` its input.
    const fm = family.mask(self, self.mir.instResult(inst));
    const kS = try self.arena.print("zL(S, 0x{f})", .{gen_mask.hex(fm, false)});
    const in = if (needs_in) try self.arena.print("zLw(S, 0x{f}, {s})", .{ gen_mask.hex(fm, false), in0 }) else in0;
    switch (k) {
        // §4.5.11 the cascade is linear in the current input, so its
        // Jacobian `b0/a0` is exact.
        .laplace => {
            const p = cg_filters.planOf(self, unit);
            if (p.err) |m| return gen_call.abort(self, .E0540, "{s}", .{m});
            // `__sec` always takes `model`, so keep the parameter named.
            self.cur.uses.model = true;
            const sec = try self.arena.print("{s}__sec(model{s})", .{ n, try sampledCoefs(self, n, p) });
            try opOpen(self, fm);
            try acOpen(self, kS, try self.arena.print("zAcLaplace({0s}, {1d}, {2d}, {3s}, {4s}, zLaplaceH0({1d}, {2d}, {4s}))", .{ kS, p.ns, p.deg, in, sec }));
            try self.b("zLaplace({s}, {d}, {d}, {s}, {s}, sim.dt, &inst.{s}__u, &inst.{s}__y)", .{
                kS, p.ns, p.deg, in, sec, n, n,
            });
            try opClose(self);
            try opClose(self);
        },
        // §4.5.12 "samples every T seconds and exhibits no delay": between
        // samples the output is a held constant; at a sample instant it is
        // that sample's output. `zZiEval` decides which on the same clock
        // `updateState` advances.
        .zi => {
            const p = cg_filters.planOf(self, unit);
            if (p.err) |m| return gen_call.abort(self, .E0540, "{s}", .{m});
            // As for `.laplace`.
            self.cur.uses.model = true;
            const sec = try self.arena.print("{s}__sec(model{s})", .{ n, try sampledCoefs(self, n, p) });
            try opOpen(self, fm);
            try acOpen(self, kS, try self.arena.print("zAcZi({s}, {d}, {d}, {s}, {s}, {s})", .{
                kS, p.ns, p.deg, in, sec, p.period orelse "0.0",
            }));
            if (p.tau) |tau| try self.b(
                "zZiEvalRamp({5s}, {0d}, {1d}, {2s}, {8s}, sim.dt, inst.{3s}__out, " ++
                    "inst.{3s}__from, inst.{3s}__ts, sim.t, inst.{3s}__nk, {4s}, {6s}, {7s}, &inst.{3s}__u, &inst.{3s}__y)",
                .{ p.ns, p.deg, in, n, p.period orelse "0.0", kS, p.t0.?, tau, sec },
            ) else try self.b(
                "zZiEval({5s}, {0d}, {1d}, {2s}, {6s}, sim.dt, inst.{3s}__out, " ++
                    "sim.t, inst.{3s}__nk, {4s}, &inst.{3s}__u, &inst.{3s}__y)",
                .{ p.ns, p.deg, in, n, p.period orelse "0.0", kS, sec },
            );
            try opClose(self);
            try opClose(self);
        },
        // §4.5.4 `idt(expr, ic, assert)` "returns the initial conditions ...
        // whenever assert is nonzero"; otherwise V(s) less the latched offset.
        .idt_hold => {
            try opOpen(self, fm);
            try self.b("zIdtHold({s}, {s}, inst.{s}__off, {s}, {s})", .{
                kS, in, n, try operator_ctrl.ctrlEval(self, args, 1, "0.0"), try operator_ctrl.ctrlEval(self, args, 2, "0.0"),
            });
            try opClose(self);
        },
        .idtmod => {
            try opOpen(self, fm);
            try self.b("zIdtmod({s}, {s}, inst.{s}__acc, sim.dt, {s}, {s}, {s})", .{
                kS,                                               in,
                n,                                                try operator_ctrl.ctrlEval(self, args, 1, "0.0"),
                try operator_ctrl.ctrlEval(self, args, 2, "0.0"), try operator_ctrl.ctrlEval(self, args, 3, "0.0"),
            });
            try opClose(self);
        },
        .absdelay => {
            try opOpen(self, fm);
            try acOpen(self, kS, try self.arena.print("zAcDelay({s}, {s}, {s})", .{ kS, in, try absdelayTdAc(self, args) }));
            try self.b(
                "{s}({s}, {s}, &inst.{s}__t, &inst.{s}__v, inst.{s}__head, sim.t, sim.dt, {s})",
                .{
                    if (self.mir.instData(inst).call.callee == .@"absdelay$quad") "zAbsdelayQ" else "zAbsdelay",
                    kS,
                    in,
                    n,
                    n,
                    n,
                    try operator_ctrl.absdelayTd(self, n, args, false),
                },
            );
            try opClose(self);
            try opClose(self);
        },
        // §4.5.8 the ramp's origin comes from `Instance` and its target from
        // the current input, so the companion model is linear in the
        // unknowns with the exact slope `(t-t0)/tt`.
        .transition => {
            const t = try transitionTimes(self, args);
            try opOpen(self, fm);
            try self.b(
                "zTransition({4s}, {0s}, inst.{1s}__from, inst.{1s}__to, inst.{1s}__t0, " ++
                    "sim.t, sim.dt, {2s}, {3s})",
                .{ in, n, t[0], t[1], kS },
            );
            try opClose(self);
        },
        .slew => {
            const r = try slewRates(self, args);
            try opOpen(self, fm);
            try self.b("zSlew({s}, {s}, inst.{s}__prev, sim.dt, {s}, @abs({s}))", .{
                kS, in, n, r[0], r[1],
            });
            try opClose(self);
        },
        // §4.5.10 "the simulation time when a signal expression last crossed
        // zero": §4.5's output "is a function of both the input and the
        // internal state", so a crossing between the last accepted point and
        // this one is already the last crossing here, the point where §5.10.3
        // `cross` on the same expression fires. Otherwise the latched one;
        // `sim.dt > 0` is `updateState`'s seeding rule. The interpolated
        // time moves with the current input, so `zLastCross` carries its
        // derivative; the latched one is a constant.
        .last_crossing => {
            const v = try self.arena.print("({s}).val()", .{in0});
            try opOpen(self, fm);
            try self.b("zLastCross({s}, {s}, inst.{s}__prev, sim.t, sim.dt, inst.{s}__t_last, sim.dt > 0.0 and ({s}))", .{
                kS, in, n, n, try operator_ctrl.crossTest(self, n, args, v, false),
            });
            try opClose(self);
        },
        // §5.10.3 the event is decided here, at the point being evaluated;
        // `updateState` only advances `__prev`/`__next`. §5.10.3.1 "will not
        // generate events for non-transient analyses ... it can only generate
        // an event after the simulation time has advanced from zero": a
        // transient and a positive `dt`.
        .cross => try self.b("S.con(if (sim.kind == .tran and sim.dt > 0.0 and ({s}) and ({s})) 1.0 else 0.0)", .{
            try operator_ctrl.crossTest(self, n, args, try self.arena.print("({s}).val()", .{in0}), false),
            try operator_ctrl.enableTest(self, .cross, args),
        }),
        // §5.10.3.3 a change BEFORE the event test replaces its pending
        // deadline using the latest absolute start + k*period. Changes in an
        // event body cannot retroactively cancel the event already evaluated.
        .timer => try self.b("S.con(if (zTimerDue(({1s}).val(), {2s}, sim.t, inst.{0s}__start, inst.{0s}__per, inst.{0s}__next) and ({3s})) 1.0 else 0.0)", .{
            n,
            in0,
            try operator_ctrl.ctrlEval(self, args, 1, "0.0"),
            try operator_ctrl.enableTest(self, .timer, args),
        }),
        // §5.10.3.2 fires "when the expression crosses zero (0) from below":
        // edge-triggered against the last accepted value. No transient or
        // `dt` guard: above() "can generate an event during initialization"
        // and during a dc sweep. `__prev = 0.0` gives the initial event.
        .above => try self.b("S.con(if (inst.{0s}__prev <= 0.0 and ({1s}).val() > 0.0 and ({2s})) 1.0 else 0.0)", .{
            n, in0, try operator_ctrl.enableTest(self, .above, args),
        }),
        // §9.17 tasks return no value; read as one, they are zero.
        .bound_step, .discontinuity => try self.b("S.con(0.0)", .{}),
        .none => unreachable,
    }
}

/// Writes a stateless §4.5 operator: §4.5.13 `limexp` or §4.5.14 `ddx`.
/// Invalidates slices of `out.items` if additional memory is needed.
pub fn emitPlain(self: *Gen, comptime c: Mir.Callee, args: []const Mir.Value) Error!void {
    comptime assert(Mir.callee.opKind(c) == .none); // no `Instance` history
    switch (c) {
        // §4.5.13 limexp "returns a real value which is the exponential of
        // its single real argument", and "the simulator can only converge
        // when the output of limexp() equals the exponential of the input".
        // `eval` sees one iterate and never the previous one, so the only
        // limiting it can do that still converges to exp is none: limexp is
        // `exp`'s own text (docs/specification/Vague_Decisions.md VD-121).
        .limexp => return render_op.renderOp(self, .exp, if (args.len > 0) args[0] else .f_zero, .f_zero, .real),

        // §4.5.14 ddx(f, V(node)); the unknown index is an int literal. Pins:
        // `.ddxAt` reads one scalar partial.
        .ddx => {
            if (args.len > 0) float_lanes.pinLanes(self, args[0]);
            const u = if (args.len > 1) self.an.foldConst(args[1], true) else null;
            // Saturating cast: bad MIR must not panic the compiler.
            const lane = if (u) |x| std.math.lossyCast(i64, x) else 0;
            // The value reads a lane, so record it in `ddx_reads`.
            // An index outside the unknowns marks every lane: a superset.
            gen_mask.orIn(self.jac.ddx_reads, try gen_stamps.bits(self, &.{if (lane >= 0 and lane < self.names.n_u) @intCast(lane) else none_u32}, &.{}));
            try self.b("S.con((", .{});
            try gen_render.renderVal(self, if (args.len > 0) args[0] else .f_zero, .real);
            try self.b(").ddxAt({d}))", .{lane});
            return;
        },
        else => @compileError("emitPlain: `" ++ @tagName(c) ++ "` is not a stateless operator"),
    }
}

/// Returns §4.5.8 `transition(expr, td, rise_time, fall_time)`'s rise and
/// fall times as f64 expressions. "If only a positive rise_time value is
/// specified, the simulator uses it for both"; a time that is absent or
/// "equal to zero (0.0)" takes the `default_transition` in force (§10.3).
/// A parameter time is tested for zero at run time.
/// Both results are arena-owned. Asserts that `args` is `transition`'s list
/// (input, td, rise, fall, time_tol).
pub fn transitionTimes(self: *Gen, args: []const Mir.Value) Error![2][]const u8 {
    assert(args.len <= 5);
    const dflt = try defaultTransition(self);
    const rise = try transitionTime(self, args, 2, dflt orelse "0.0");
    // An absent or zero fall time is the rise time: "If only a positive
    // rise_time value is specified, the simulator uses it for both". With no
    // rise time either, `rise` already is the directive's default.
    const fall = try transitionTime(self, args, 3, rise);
    assert(rise.len != 0);
    assert(fall.len != 0);
    return .{ rise, fall };
}

/// Returns §4.5.9's positive and negative slew limits. "If the
/// max_neg_slew_rate is not specified, it defaults to the opposite of the
/// max_pos_slew_rate": the kernel takes `@abs` of the negative limit, so the
/// positive expression is reused.
/// Both results are arena-owned. Asserts that `args` is `slew`'s list (input,
/// positive and negative limits).
pub fn slewRates(self: *Gen, args: []const Mir.Value) Error![2][]const u8 {
    assert(args.len <= 3);
    const pos = try gen_host.argF64(self, args, 1, "1e300");
    return .{ pos, try gen_host.argF64(self, args, 2, pos) };
}

// ---- private ----

/// Returns `absdelayTd` at a small-signal point: §4.5.7 "td is evaluated as a
/// constant at a particular time for any small signal analysis", so td and
/// maxdelay are read live, not from the latches `updateState` fills.
fn absdelayTdAc(self: *Gen, args: []const Mir.Value) Error![]const u8 {
    assert(args.len <= 3);
    const td = try operator_ctrl.ctrlEval(self, args, 1, "0.0");
    if (args.len < 3) return td;
    return self.arena.print("@min({s}, {s})", .{ td, try operator_ctrl.ctrlEval(self, args, 2, "0.0") });
}

/// Returns `__sec`'s §4.5.14 `k` argument in the residual's frame, with its
/// leading comma, or "" for a filter that samples nothing. At a static point
/// (the `dt` test of `zLaplace` and `zZiEval`) the coefficients are read
/// live: that solve IS the start of the analysis. After it they are
/// `updateState`'s latch (`gen_state.secStep`).
fn sampledCoefs(self: *Gen, n: []const u8, p: cg_filters.FilterPlan) Error![]const u8 {
    assert(n.len != 0);
    if (p.sampled.len == 0) return "";
    var t: std.ArrayList(u8) = .empty;
    try t.print(self.arena, ", if (sim.dt > 0.0) inst.{s}__k else .{{ ", .{n});
    for (p.sampled, 0..) |v, j| {
        if (j != 0) try t.appendSlice(self.arena, ", ");
        try t.appendSlice(self.arena, try operator_ctrl.ctrlEval(self, &.{v}, 0, "0.0"));
    }
    assert(t.items.len > ", if (sim.dt > 0.0) inst.__k else .{ ".len);
    try t.appendSlice(self.arena, " }");
    return t.items;
}

/// Opens a §4.5.7/§4.5.11/§4.5.12 kernel for both families: `ac`, the
/// operator's small-signal response, when the family is `acDyn`'s `zAc`,
/// else `zSs` around the kernel the caller writes next. `opClose` closes it.
fn acOpen(self: *Gen, kS: []const u8, ac: []const u8) Error!void {
    assert(kS.len != 0);
    assert(ac.len != 0);
    try self.b("if (comptime @hasDecl(S.Of(0), \"acMul\")) {s} else zSs({s}, sim.kind, ", .{ ac, kS });
}

/// Writes `zLu(S, m, ` around an operator kernel whose scalar is `zL(S, m)`;
/// `opClose` writes its `)`.
fn opOpen(self: *Gen, m: []const u64) Error!void {
    assert(m.len == self.mw);
    try self.b("zLu(S, 0x{f}, ", .{gen_mask.hex(m, false)});
}

fn opClose(self: *Gen) Error!void {
    try self.b(")", .{});
}

fn transitionTime(self: *Gen, args: []const Mir.Value, i: usize, dflt: []const u8) Error![]const u8 {
    // §4.5.8 the rise time is argument 2 and the fall time argument 3.
    assert(i == 2 or i == 3);
    assert(dflt.len != 0);
    if (i >= args.len) return dflt;
    // `resolve_params = false`: only a time that is zero without parameters
    // is absent at compile time; a card may override a zero default.
    if (self.an.foldConst(args[i], false)) |c| {
        if (c == 0.0) return dflt;
        return gen_host.f64Expr(self, args[i]);
    }
    const e = try gen_host.f64Expr(self, args[i]);
    // A run-time zero test for a parameter time. Skipped for the bare 0.0
    // fallback, which `zTransFrac` already reads as an instantaneous edge.
    if (std.mem.eql(u8, dflt, "0.0")) return e;
    return self.arena.print("(if (({s}) != 0.0) ({s}) else ({s}))", .{ e, e, dflt });
}

/// Returns the §10.3 `` `default_transition `` in force at the call being
/// emitted ("the directive which immediately precedes the transition
/// filter") as an f64 literal, or null. Requires `ctrl_tok` set to the
/// operator call's token.
fn defaultTransition(self: *Gen) Error!?[]const u8 {
    const list = self.lowered.default_transitions;
    if (list.len == 0) return null;
    if (self.cur.ctrl_tok == Mir.no_tok or self.cur.ctrl_tok >= self.lowered.tok_starts.len) return null;
    const t = Lower.DefaultTransition.inForce(list, self.lowered.tok_starts[self.cur.ctrl_tok], null) orelse return null;
    return try gen_file.fmtF64(self, t);
}
