//! Call rendering: a MIR `call` in, its Zig text out, for §4.5 analog
//! operators, §4.6 analysis/noise functions and Clause 9 system functions;
//! the §4.5 control-argument frames (`ctrlEval` for the residual, `ctrlStep`
//! for `updateState`) and the `systf_calls` table. A control argument's
//! host-side `f64` text is `host_expr.zig`.
//! LRM clauses cited: §2.8.3, §4.5, §4.6, §5.10.3, §6.3.4, §9, §10.3, §12.22.2, §12.32.

const std = @import("std");
const float_lanes = @import("float/lanes.zig");
const plan_args = @import("plan/args.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_dispatch = @import("dispatch.zig");
const gen_mask = @import("mask.zig");
const gen_file = @import("file.zig");
const gen_cfg = @import("cfg.zig");
const gen_render = @import("render.zig");
const gen_host = @import("host_expr.zig");
const family = @import("family.zig");
const gen_unit = @import("unit.zig");
const gen_wide = @import("wide.zig");
const Mir = @import("ir").Mir;
const cg_display = @import("../cg_display.zig");
const cg_filters = @import("../cg_filters.zig");
const cg_strcap = @import("../cg_strcap.zig");
const Lower = @import("ir").Lowered;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const OpKind = @import("ir").op.OpKind;
const diag = @import("diag");

/// The analysis names `analysis()` recognises (LRM §4.6.1).
const analysis_names = std.StaticStringMap(void).initComptime(.{ .{"static"}, .{"ic"}, .{"nodeset"}, .{"dc"}, .{"tran"}, .{"ac"}, .{"noise"} });

/// Returns a dynamic (§4.5 Table 4-20) control argument's value in the
/// residual's frame: `f64Const`'s text when it folds, else the rendered S
/// expression's `.val()`, which pins lanes. `ctrlStep` is the `updateState`
/// frame's counterpart.
fn ctrlEval(self: *Gen, args: []const Mir.Value, i: usize, dflt: []const u8) Error![]const u8 {
    if (i >= args.len) return dflt;
    if (try gen_host.f64Const(self, args[i], 0, false)) |s| return s;
    // The collapse is intended: a control argument (or §4.6.3's stimulus
    // magnitude) configures the operator and is not part of the Jacobian.
    float_lanes.pinLanes(self, self.an.rv(args[i]));
    return self.arena.print("({s}).val()", .{
        try gen_render.renderToArena(self, args[i], .real),
    });
}

/// Returns the §4.5.7 effective delay of one `absdelay` site in the caller's
/// frame (`step`: `updateState`'s, else the residual's). A frozen td reads
/// its `Instance` field; with `maxdelay`, td is clamped to it.
pub fn absdelayTd(self: *Gen, n: []const u8, args: []const Mir.Value, step: bool) Error![]const u8 {
    if (try absdelayFreezes(self, args))
        return self.arena.print("inst.{s}__td", .{n});
    const td = if (step)
        try ctrlStep(self, args, 1, "0.0")
    else
        try ctrlEval(self, args, 1, "0.0");
    if (args.len < 3) return td;
    // §4.5.7 "If td becomes greater than maxdelay, maxdelay will be used as
    // a substitute for td." Table 4-20 makes maxdelay the constant argument,
    // so it renders over Model where td renders over the core.
    return self.arena.print("@min({s}, {s})", .{
        td,
        if (try absdelayMaxdSampled(self, args))
            try self.arena.print("inst.{s}__maxd", .{n})
        else
            try gen_host.argF64(self, args, 2, "0.0"),
    });
}

/// Returns `absdelayTd` at a small-signal point: §4.5.7 "td is evaluated as a
/// constant at a particular time for any small signal analysis", so td and
/// maxdelay are read live, not from the latches `updateState` fills.
fn absdelayTdAc(self: *Gen, args: []const Mir.Value) Error![]const u8 {
    const td = try ctrlEval(self, args, 1, "0.0");
    if (args.len < 3) return td;
    return self.arena.print("@min({s}, {s})", .{ td, try ctrlEval(self, args, 2, "0.0") });
}

/// Returns `__sec`'s §4.5.14 `k` argument in the residual's frame, with its
/// leading comma, or "" for a filter that samples nothing. At a static point
/// (the `dt` test of `zLaplace` and `zZiEval`) the coefficients are read
/// live: that solve IS the start of the analysis. After it they are
/// `updateState`'s latch (`gen_state.secStep`).
fn sampledCoefs(self: *Gen, n: []const u8, p: cg_filters.FilterPlan) Error![]const u8 {
    if (p.sampled.len == 0) return "";
    var t: std.ArrayList(u8) = .empty;
    try t.print(self.arena, ", if (sim.dt > 0.0) inst.{s}__k else .{{ ", .{n});
    for (p.sampled, 0..) |v, j| {
        if (j != 0) try t.appendSlice(self.arena, ", ");
        try t.appendSlice(self.arena, try ctrlEval(self, &.{v}, 0, "0.0"));
    }
    try t.appendSlice(self.arena, " }");
    return t.items;
}

/// Returns whether a signal-valued `maxdelay` is latched into `Instance` at
/// the start of the analysis instead of refused (§4.5.14: "the value of the
/// dynamic expression at the start of the analysis defaults to the constant
/// value of the argument").
pub fn absdelayMaxdSampled(self: *Gen, args: []const Mir.Value) Error!bool {
    // ponytail: `absdelay`'s maxdelay and the filter coefficients
    // (`sampledCoefs`) only. Every other constant slot still answers a solve
    // result with E0515; the same latch is the upgrade path.
    if (args.len != 3) return false;
    return gen_host.ctrlIsDynamic(self, args[2]);
}

/// Returns whether a two-argument `absdelay`'s td is signal-valued and so
/// frozen into `Instance` (§4.5.7: "any future changes to td shall be
/// ignored").
pub fn absdelayFreezes(self: *Gen, args: []const Mir.Value) Error!bool {
    if (args.len != 2) return false;
    return gen_host.ctrlIsDynamic(self, args[1]);
}

/// Returns a control argument's value in `updateState`'s frame: `f64Const`'s
/// text, else the core field `buildJobs` queued (`m.f<k>.v`). With no field
/// it reports E0515 through `f64Expr` rather than guess.
pub fn ctrlStep(self: *Gen, args: []const Mir.Value, i: usize, dflt: []const u8) Error![]const u8 {
    if (i >= args.len) return dflt;
    if (try gen_host.f64Const(self, args[i], 0, false)) |s| return s;
    const k = self.core.lo_idx[@backingInt(self.an.rv(args[i]))];
    if (k == none_u32) return gen_host.f64Expr(self, args[i]);
    return self.arena.print("m.f{d}.v", .{k});
}

/// Returns §5.10.3.3's period as `updateState` reads it: inline when it
/// folds, else the core field `buildJobs` queued, so "the next event will be
/// scheduled based on the latest value".
pub fn timerPeriod(self: *Gen, args: []const Mir.Value) Error![]const u8 {
    if (args.len < 2) return "0.0";
    if (self.an.foldConst(args[1], false) == null) {
        const lo = self.core.lo_idx[@backingInt(self.an.rv(args[1]))];
        if (lo != none_u32) return self.arena.print("m.f{d}.v", .{lo});
    }
    return gen_host.argF64(self, args, 1, "0.0");
}

/// Returns the test "the signal crossed zero since the last accepted step, in
/// the direction argument 1 asks for" (+1 rising, -1 falling, 0 or absent
/// either), shared by §4.5.10 `last_crossing` and §5.10.3 `cross`. `in` is
/// the current input as a plain f64 expression, compared against `__prev`.
///
/// A direction that folds without parameters picks its comparison here; a
/// parameter one becomes `zCrossDir` on the card's value; a solve-time one
/// is E0515 (§4.5.14).
pub fn crossTest(self: *Gen, n: []const u8, args: []const Mir.Value, in: []const u8) Error![]const u8 {
    const arg: Mir.Value = if (args.len > 1) args[1] else .zero;
    if (self.an.foldConst(arg, false)) |c| {
        // §5.10.3.1 "For any other values of dir, the cross() function does
        // not generate an event". §4.5.10's direction is the same closed
        // set, so `last_crossing` reads it the same way.
        if (c.f == 1.0) return self.arena.print("inst.{0s}__prev <= 0.0 and {1s} > 0.0", .{ n, in });
        if (c.f == -1.0) return self.arena.print("inst.{0s}__prev >= 0.0 and {1s} < 0.0", .{ n, in });
        if (c.f != 0.0) return "false";
        return self.arena.print(
            "(inst.{0s}__prev <= 0.0 and {1s} > 0.0) or (inst.{0s}__prev >= 0.0 and {1s} < 0.0)",
            .{ n, in },
        );
    }
    return self.arena.print("zCrossDir({s}, inst.{s}__prev, {s})", .{
        try gen_host.f64Expr(self, arg), n, in,
    });
}

/// Returns the §4.5.10 crossing time inside the step ending at `sim.t`: the
/// zero of the line through (`sim.t - sim.dt`, `__prev`) and (`sim.t`, `in`),
/// the "linear interpolation" §4.5.10 names. `updateState` latches it where
/// `crossTest` holds; `eval` answers there with `zLastCross`, the same
/// operations in the same order, so the accepted point and every later one
/// read the same bits.
pub fn lastCrossTime(self: *Gen, n: []const u8, in: []const u8) Error![]const u8 {
    return self.arena.print("(sim.t - sim.dt) + inst.{0s}__prev / (inst.{0s}__prev - {1s}) * sim.dt", .{ n, in });
}

/// Returns whether a §5.10.3.1 `cross` gives its own tolerance box, so
/// `updateState` publishes where a late event should have fired
/// (`Instance.vera_cross_retry__`, `zCrossRetry`): time_tol is written and
/// both tolerances fold to card values. A dynamic tolerance, or an enable
/// that is not a nonzero literal, keeps the grid's answer (VD-066).
// ponytail: a solve-time tolerance would need its own core slot; add one
// when a model writes it.
pub fn crossLocated(self: *Gen, args: []const Mir.Value) Error!bool {
    if (args.len < 3) return false;
    for (args[2..@min(args.len, 4)]) |a| if (try gen_host.ctrlIsDynamic(self, a)) return false;
    if (args.len < 5) return true;
    const en = self.an.foldConst(args[4], false) orelse return false;
    return en.f != 0.0;
}

/// Returns whether any `cross` in the module is `crossLocated`.
pub fn anyCrossLocated(self: *Gen) Error!bool {
    for (self.names.units, 0..) |u, i| {
        if (u.role != .analog_op or u.op != .cross) continue;
        const inst = self.names.opInstOf(@intCast(i)) orelse continue;
        if (try crossLocated(self, self.mir.instData(inst).call.args)) return true;
    }
    return false;
}

/// Returns the §5.10.3 enable test for `cross`, `above` or `timer` ("If
/// enable argument is specified and it is zero, then <op>() is inactive"), or
/// `true` when absent. The enable is a live expression; `UnitPlan` gives it
/// a slot (`callArgIsValue`).
fn enableTest(self: *Gen, k: OpKind, args: []const Mir.Value) Error![]const u8 {
    const i = @import("ir").op.enableArg(k) orelse return "true";
    if (i >= args.len) return "true";
    const at = self.out.items.len;
    try gen_cfg.renderCond(self, args[i]);
    const s = try self.arena.dupe(u8, self.out.items[at..]);
    self.out.shrinkRetainingCapacity(at);
    return s;
}

/// Returns the §5.10 `held_vars` index a `$held_*` call carries as its only
/// argument, a literal lowering emitted.
pub fn heldIdx(self: *const Gen, args: []const Mir.Value) usize {
    const c = self.an.foldConst(if (args.len != 0) args[0] else .zero, false) orelse return 0;
    const i: usize = @intFromFloat(c.f);
    return @min(i, self.names.held_names.len -| 1);
}

/// The literal index at argument `i` of a lowering-minted call (`$tp_*`).
fn litArg(self: *const Gen, args: []const Mir.Value, i: usize) u32 {
    const c = self.an.foldConst(if (i < args.len) args[i] else .zero, false) orelse return 0;
    return @intFromFloat(c.f);
}

/// Returns whether this call, as `emitCall` renders it, reads state the host
/// changes between evaluations with `x` held: `SimState`, operator history,
/// the §5.2.1 sub-task flag, the Newton iteration, limiter history, a
/// §9.13.1 seed latch or a held value. For `family.constant`. A new
/// `emitCall` arm that reads such state must be listed here too.
pub fn readsHostState(self: *const Gen, inst: Mir.Inst) bool {
    const d = self.mir.instData(inst).call;
    return switch (d.callee) {
        .@"idt$hold",
        .@"op$static",
        .idtmod,
        .absdelay,
        .@"absdelay$quad",
        .transition,
        .slew,
        .last_crossing,
        .laplace_zd,
        .laplace_zp,
        .laplace_nd,
        .laplace_np,
        .zi_zd,
        .zi_zp,
        .zi_nd,
        .zi_np,
        .cross,
        .above,
        .timer,
        .@"$bound_step",
        .@"$discontinuity",
        // §5.2.1, §5.10.2, §4.6.1, §4.6.3, §9.10: the SimState or the
        // sub-task flag; `$limit$old` reads the limiter history.
        .analog_initial,
        .initial_step,
        .final_step,
        .analysis,
        .ac_stim,
        .@"$abstime",
        .@"$realtime",
        .@"$simparam$str",
        .@"$limit$old",
        // §9.13.1 the seedless draw reads the latch `updateState` advances;
        // a VPI application may answer from any state it keeps.
        // §5.10 a held value is what the last accepted step left.
        .@"$rng$auto",
        .systf,
        .@"$systf$out",
        .@"$held_real",
        .@"$held_int",
        .@"$held_str",
        .@"$held_wide",
        // VerA's `vera_timepoint`: the per-timepoint cache (`Lower.TpBlock`).
        .@"$tp_hit",
        .@"$tp_int",
        .@"$tp_real",
        .@"$tp_wide",
        => true,
        // §9.15 `$simparam("iteration")`, `$simparam("dt")`: the SimState.
        .@"$simparam" => Lower.simparamIsRuntime(strArg(self, d.args, 0) orelse ""),
        // Constants, Model reads (the card, `temperature__`), the Instance's
        // `mfactor`, fixed with the instance, and every task,
        // conversion and kernel of its operands alone.
        .limexp,
        .ddx,
        .white_noise,
        .flicker_noise,
        .noise_table,
        .noise_table_log,
        .@"$temperature",
        .@"$vt",
        .@"$mfactor",
        .@"$param_given",
        .@"$port_connected",
        .@"$analog_node_alias",
        .@"$analog_port_alias",
        .@"$test$plusargs",
        .@"$value$plusargs",
        .@"$xposition",
        .@"$yposition",
        .@"$angle",
        .@"$hflip",
        .@"$vflip",
        .@"$rtoi",
        .@"$itor",
        .@"$realtobits",
        .@"$bitstoreal",
        .@"$clog2",
        .@"$sqrt",
        .@"$exp",
        .@"$expm1",
        .@"$ln",
        .@"$ln1p",
        .@"$log",
        .@"$log10",
        .@"$floor",
        .@"$ceil",
        .@"$sin",
        .@"$cos",
        .@"$tan",
        .@"$asin",
        .@"$acos",
        .@"$atan",
        .@"$sinh",
        .@"$cosh",
        .@"$tanh",
        .@"$asinh",
        .@"$acosh",
        .@"$atanh",
        .@"$pow",
        .@"$hypot",
        .@"$atan2",
        .@"$display",
        .@"$displayb",
        .@"$displayo",
        .@"$displayh",
        .@"$write",
        .@"$writeb",
        .@"$writeo",
        .@"$writeh",
        .@"$strobe",
        .@"$strobeb",
        .@"$strobeo",
        .@"$strobeh",
        .@"$monitor",
        .@"$monitoron",
        .@"$monitoroff",
        .@"$debug",
        .@"$fatal",
        .@"$error",
        .@"$warning",
        .@"$info",
        .@"$finish",
        .@"$stop",
        .@"$fopen",
        .@"$fclose",
        .@"$fflush",
        .@"$fdisplay",
        .@"$fwrite",
        .@"$fstrobe",
        .@"$fmonitor",
        .@"$fdebug",
        .@"$fgets",
        .@"$fscanf",
        .@"$ftell",
        .@"$fseek",
        .@"$rewind",
        .@"$ferror",
        .@"$feof",
        .@"$sformat",
        .@"$sformat$rt",
        .@"$sscanf",
        .@"$limit",
        .@"$table_model",
        .@"$vera_reject_step",
        .@"$limit$uf",
        .@"$idx",
        .@"$idx$int",
        .@"$idx$str",
        // IEEE 1364 §5.4 a function of its operands alone.
        .@"$wide",
        .@"$wide$int",
        .@"$display$width",
        .@"$monitor$arm",
        .@"$fgets$str",
        .@"$ferror$str",
        .@"$fscanf$int",
        .@"$fscanf$real",
        .@"$fscanf$str",
        .@"$sscanf$int",
        .@"$sscanf$real",
        .@"$sscanf$str",
        .@"$plusarg$str",
        .@"$str$cat",
        .@"$str$repeat",
        .@"$rng$check",
        .@"$rng$rand",
        .@"$rng$rand_next",
        .@"$rng$i_uniform",
        .@"$rng$i_uniform_next",
        .@"$rng$uniform",
        .@"$rng$uniform_next",
        .@"$rng$normal",
        .@"$rng$normal_next",
        .@"$rng$exponential",
        .@"$rng$exponential_next",
        .@"$rng$poisson",
        .@"$rng$poisson_next",
        .@"$rng$chi_square",
        .@"$rng$chi_square_next",
        .@"$rng$t",
        .@"$rng$t_next",
        .@"$rng$erlang",
        .@"$rng$erlang_next",
        => false,
    };
}

/// Writes a call: system and environment functions (Clause 9), §4.5
/// operators, §4.6 functions. One exhaustive switch over `Mir.Callee`, so a
/// new callee does not compile until it has a rendering.
pub fn emitCall(self: *Gen, inst: Mir.Inst) Error!void {
    const d = self.mir.instData(inst).call;
    const c = d.callee;
    const name = d.name;
    const args = d.args;
    const k = Mir.callee.opKind(c);
    const saved_tok = self.call_tok;
    self.call_tok = self.mir.instTok(inst);
    defer self.call_tok = saved_tok;
    // idt's hold and the §4.5.11/§4.5.12 filters stay lane-exact: they
    // branch only on `dt` or a control argument and are S-linear over shared
    // state. Every other operator steers on or collapses a `.val()` of its
    // input, so it pins.
    switch (k) {
        .none, .idt_hold, .laplace, .zi, .bound_step, .discontinuity => {},
        .idtmod, .absdelay, .transition, .slew, .last_crossing, .cross, .above, .timer => for (args) |arg| float_lanes.pinLanes(self, arg),
    }
    switch (c) {
        .@"idt$hold",
        .idtmod,
        .absdelay,
        .@"absdelay$quad",
        .transition,
        .slew,
        .last_crossing,
        .laplace_zd,
        .laplace_zp,
        .laplace_nd,
        .laplace_np,
        .zi_zd,
        .zi_zp,
        .zi_nd,
        .zi_np,
        .cross,
        .above,
        .timer,
        .@"$bound_step",
        .@"$discontinuity",
        => return emitOperator(self, inst, args, k),

        // §4.5.13 limexp "returns a real value which is the exponential of
        // its single real argument", and "the simulator can only converge
        // when the output of limexp() equals the exponential of the input".
        // `eval` sees one iterate and never the previous one, so the only
        // limiting it can do that still converges to exp is none: limexp is
        // `exp`'s own text (specification/Vague_Decisions.md VD-121).
        .limexp => return gen_render.renderOp(self, .exp, if (args.len > 0) args[0] else .f_zero, .f_zero, .real),

        // §4.5.14 ddx(f, V(node)); the unknown index is an int literal. Pins:
        // `.ddxAt` reads one scalar partial.
        .ddx => {
            if (args.len > 0) float_lanes.pinLanes(self, args[0]);
            const u = if (args.len > 1) self.an.foldConst(args[1], true) else null;
            const lane = if (u) |x| std.math.lossyCast(i64, x.f) else 0;
            // The value reads a lane, so record it in `ddx_reads`.
            // An index outside the unknowns marks every lane: a superset.
            gen_mask.orIn(self.jac.ddx_reads, try gen_dispatch.bits(self, &.{if (lane >= 0 and lane < self.names.n_u) @intCast(lane) else none_u32}, &.{}));
            try self.b("S.con((", .{});
            try gen_render.renderVal(self, if (args.len > 0) args[0] else .f_zero, .real);
            // Saturating cast: bad MIR must not panic the compiler.
            try self.b(").ddxAt({d}))", .{lane});
            return;
        },

        // §5.2.1 the `analog initial` guard. Not `initial_step`: §5.2.1 re-runs
        // the block per sweep sub-task, while initial_step is the first point
        // of the whole analysis.
        .analog_initial => {
            self.uses.sim = true;
            try self.b("S.con(if (sim.analog_initial) 1.0 else 0.0)", .{});
            return;
        },

        // §4.5.4/§4.5.5 the solve an operator's DC form keys on. `dt`, not
        // `analysis("static")`: a host opens a transient with its own kind and
        // dt = 0. A small-signal analysis linearizes at dt = 0 too, and there
        // the operator is its transfer function, not its DC value.
        .@"op$static" => {
            self.uses.sim = true;
            try self.b("S.con(if (sim.dt == 0.0 and sim.kind != .ac and sim.kind != .noise) 1.0 else 0.0)", .{});
            return;
        },

        // §5.10.2 global events.
        .initial_step, .final_step => {
            self.uses.sim = true;
            const flag = if (c == .initial_step) "initial_step" else "final_step";
            try self.b("S.con(if (sim.{s}", .{flag});
            if (args.len != 0) {
                try self.b(" and (", .{});
                try analysisMatch(self, args);
                try self.b(")", .{});
            }
            try self.b(") 1.0 else 0.0)", .{});
            return;
        },

        // §4.6.1 analysis("dc"|"tran"|…).
        .analysis => {
            try self.b("S.con(if (", .{});
            try analysisMatch(self, args);
            try self.b(") 1.0 else 0.0)", .{});
            return;
        },

        // §4.6.4 noise sources contribute zero to the residual. The host
        // reads them through `noise_gens` and `noisePsd`.
        .white_noise, .flicker_noise, .noise_table, .noise_table_log => return self.b("S.con(0.0)", .{}),

        // §4.6.3 ac_stim(analysis_name, mag, phase) "returns zero (0) during
        // large-signal analyses ... as well as on all small-signal analyses
        // using names which do not match analysis_name". Defaults: "ac", 1.0,
        // 0.0. Which analysis a name matches is `contract.acStimActive`'s
        // rule (VD-064, VD-109).
        //
        // ponytail: the residual is real, so a matching analysis contributes
        // mag·cos(phase) and drops the quadrature part. Upgrade path: an
        // `ac_gens` export carrying (mag, phase) for a complex-solving host.
        .ac_stim => {
            // A.8.2 gives both numeric arguments as `analog_expression`, and
            // Table 4-20 does not list ac_stim, so a solve-computed magnitude
            // is legal: `ctrlEval`, not `argF64`.
            const mag = try ctrlEval(self, args, 1, "1.0");
            const phase = try ctrlEval(self, args, 2, "0.0");
            try self.b("S.con(if (", .{});
            try acStimMatch(self, args);
            try self.b(") ({s}) * @cos({s}) else 0.0)", .{ mag, phase });
            return;
        },

        // Clause 9 system functions.
        .@"$display$width" => return gen_render.renderVal(self, args[0], .int),
        // §9.4/§9.7.3 print only in a printing artifact; void in a device.
        .@"$display",
        .@"$displayb",
        .@"$displayo",
        .@"$displayh",
        .@"$write",
        .@"$writeb",
        .@"$writeo",
        .@"$writeh",
        .@"$strobe",
        .@"$strobeb",
        .@"$strobeo",
        .@"$strobeh",
        .@"$monitor",
        .@"$debug",
        .@"$fatal",
        .@"$error",
        .@"$warning",
        .@"$info",
        => return switch (self.display) {
            .emit => {
                const gated = try gateOpen(self, c, inst);
                try cg_display.emitDisplayTask(self, c, args, inst);
                return if (gated) gateClose(self) else {};
            },
            // A device's `say` records the task (`contract.SaySite`); a task
            // it does not record, and every other unit, renders it void.
            .record => if (self.emitting_display) cg_display.emitSay(self, inst) else voidTask(self),
            .drop => voidTask(self),
        },
        // §9.7.1/§9.7.2 same gate: in a printing artifact the run ends at the
        // call's position among the prints; in a device the call is dead.
        .@"$finish", .@"$stop" => {
            if (self.display != .emit) return voidTask(self);
            const gated = try gateOpen(self, c, inst);
            try cg_display.emitSimCtl(self, name, args, inst);
            return if (gated) gateClose(self) else {};
        },
        // §9.4.1 a monitor's registration is a side effect, performed only by
        // the display unit.
        .@"$monitor$arm" => {
            if (!self.emitting_display or self.display != .emit) return voidTask(self);
            const gated = try gateOpen(self, c, inst);
            try cg_display.emitMonitorArm(self, args);
            return if (gated) gateClose(self) else {};
        },
        .@"$monitoron", .@"$monitoroff" => return voidTask(self),
        // §9.5 the descriptor family runs only in the display unit. Everywhere
        // else, including every `.drop` build, `emitFileCallDropped` answers
        // with the call's own type (a descriptor is an i64, §9.5.1).
        .@"$fopen",
        .@"$fclose",
        .@"$fflush",
        .@"$fdisplay",
        .@"$fwrite",
        .@"$fstrobe",
        .@"$fmonitor",
        .@"$fdebug",
        .@"$fgets",
        .@"$fscanf",
        .@"$ftell",
        .@"$fseek",
        .@"$rewind",
        .@"$ferror",
        .@"$feof",
        .@"$fgets$str",
        .@"$ferror$str",
        .@"$fscanf$int",
        .@"$fscanf$real",
        .@"$fscanf$str",
        => {
            if (!self.emitting_display or self.display != .emit) return emitFileCallDropped(self, c, args, @backingInt(inst));
            const gated = try gateOpen(self, c, inst);
            try cg_display.emitFileCall(self, c, args, @backingInt(inst));
            if (!gated) return;
            try self.b(" else ", .{});
            try emitFileCallDropped(self, c, args, @backingInt(inst));
            return self.b(")", .{});
        },
        // §9.10 environment.
        .@"$temperature" => {
            self.uses.model = true;
            return self.b("S.con(model.temperature__)", .{});
        },
        .@"$vt" => {
            // §9.10 $vt = kT/q, k/q = 8.617333262e-5 V/K.
            if (args.len == 0) {
                self.uses.model = true;
                return self.b("S.con(model.temperature__ * 8.617333262145179e-5)", .{});
            }
            try self.b("(", .{});
            try gen_render.renderVal(self, args[0], .real);
            return self.b(").scale(8.617333262145179e-5)", .{});
        },
        .@"$abstime", .@"$realtime" => {
            self.uses.sim = true;
            return self.b("S.con(sim.t)", .{});
        },
        // §5.10 the retained value of an event-assigned variable: the
        // `Instance` default before the event first fires, then the last
        // accepted value.
        .@"$held_real", .@"$held_int" => {
            self.uses.inst = true;
            const f = self.names.held_names[heldIdx(self, args)];
            float_lanes.instLanes(self, c == .@"$held_int");
            return self.b("{s}(S, inst, \"{s}\")", .{ if (c == .@"$held_int") "zInstI" else "zInst", f });
        },
        // §5.10/§3.3 a held string: its `ZStrHeld` field's text, read from
        // the one instance `inst` is, so an eval-side read is not `batch_ok`.
        .@"$held_str" => {
            self.uses.inst = true;
            float_lanes.instPin(self);
            return self.b("inst.{s}.get()", .{self.names.held_names[heldIdx(self, args)]});
        },
        // IEEE 1364 §5.4 a held wide `reg`: its `ZW(n)` field, read from the
        // one instance `inst` is, as a held string is.
        .@"$held_wide" => {
            self.uses.inst = true;
            float_lanes.instPin(self);
            return self.b("inst.{s}", .{self.names.held_names[heldIdx(self, args)]});
        },
        .@"$wide" => return gen_wide.emitWide(self, args, false),
        .@"$wide$int" => return gen_wide.emitWide(self, args, true),
        // VerA's `vera_timepoint` (§2.9): is statement b's cache current, and
        // its slot k (`Lower.TpBlock`, the fields `emitInstance` declares).
        .@"$tp_hit" => {
            self.uses.inst = true;
            self.uses.sim = true;
            const b = litArg(self, args, 0);
            return self.b("@as(i64, @intFromBool(zTpHit(inst.tp{d}_t, inst.tp{d}_k, sim)))", .{ b, b });
        },
        .@"$tp_int", .@"$tp_real", .@"$tp_wide" => {
            self.uses.inst = true;
            const b = litArg(self, args, 0);
            const slot = litArg(self, args, 1);
            return if (c != .@"$tp_real")
                self.b("inst.tp{d}_s{d}", .{ b, slot })
            else
                self.b("S.con(inst.tp{d}_s{d})", .{ b, slot });
        },
        .@"$mfactor" => { // §6.3.6
            self.uses.inst = true;
            float_lanes.instLanes(self, false);
            return self.b("zInst(S, inst, \"mfactor\")", .{});
        },
        // §9.18 Table 9-29 hierarchical system parameters. The device is the
        // top level, so the "Top-Level Value" column is exact. ($mfactor is
        // the exception: the host scales the stamp, so it is an Instance field.)
        .@"$xposition", .@"$yposition" => return self.b("S.con(0.0)", .{}), // 0.0 m
        .@"$angle" => return self.b("S.con(0.0)", .{}), // 0 degrees
        .@"$hflip", .@"$vflip" => return self.b("S.con(1.0)", .{}), // +1
        // §9.15 $simparam(name [, fallback]): the known value first, the
        // fallback only "if param_name is not known". The known set is
        // `Lowered.simparamValue`, the same one E0811 checks.
        .@"$simparam" => {
            const nm = strArg(self, args, 0) orelse "";
            switch (self.lowered.simparamAnswer(nm, args.len > 1)) {
                .runtime => {
                    self.uses.sim = true;
                    if (std.mem.eql(u8, nm, "dt")) return self.b("S.con(sim.dt)", .{});
                    return self.b("S.con(@floatFromInt(sim.iteration))", .{});
                },
                .host => |h| {
                    self.uses.model = true;
                    return self.b("S.con(model.{s})", .{h.field});
                },
                .value => |v| return self.b("S.con({s})", .{try gen_file.fmtF64(self, v)}),
                .fallback => return self.b("S.con({s})", .{try gen_host.f64Expr(self, args[1])}),
                // E0811 refused it unless the name was not a literal.
                .unknown => return self.b("S.con(0.0)", .{}),
            }
        },
        // §9.15 Table 9-28 `$simparam$str`: "analysis_type" and "module" are
        // answered here, "cwd" and "analysis_name" from what the host wrote
        // (`host_strings`): its table at the `Model` row's index when nonzero,
        // else the `Instance` slice (`contract.hostString`). `Lower` answers a
        // literal "instance" or "path"; any other name reads "".
        .@"$simparam$str" => {
            // A literal name picks its row here, so the device holds only
            // that row's value. §4.6.1's analysis names are the
            // `AnalysisKind` tag spellings. `Lower` answers the hierarchy
            // rows; "module" remains for callers that build a `Gen` without
            // an elaborated unit table.
            if (strArg(self, args, 0)) |nm| {
                if (std.mem.eql(u8, nm, "analysis_type")) {
                    self.uses.sim = true;
                    return self.b("@tagName(sim.kind)", .{});
                }
                if (std.mem.eql(u8, nm, "module")) return self.b("\"{f}\"", .{std.zig.fmtString(self.mir.name)});
                const host = std.mem.eql(u8, nm, "cwd") or std.mem.eql(u8, nm, "analysis_name");
                if (!host or !self.lowered.uses.contains(.host_strings)) return self.b("\"\"", .{});
                self.uses.inst = true;
                self.uses.model = true;
                float_lanes.instPin(self);
                return self.b("contract.hostString(model.{0s}_idx__, inst.{0s})", .{nm});
            }
            // §9.15 param_name may be a string variable, so the lookup runs
            // at run time.
            self.uses.sim = true;
            try self.b("(if (std.mem.eql(u8, ", .{});
            try gen_render.renderValueRef(self, self.an.rv(args[0]));
            try self.b(", \"analysis_type\")) @tagName(sim.kind) else if (std.mem.eql(u8, ", .{});
            try gen_render.renderValueRef(self, self.an.rv(args[0]));
            try self.b(", \"module\")) \"{f}\" else ", .{std.zig.fmtString(self.mir.name)});
            if (self.lowered.uses.contains(.host_strings)) {
                self.uses.inst = true;
                self.uses.model = true;
                float_lanes.instPin(self);
                for ([_][]const u8{ "cwd", "analysis_name" }) |field| {
                    try self.b("if (std.mem.eql(u8, ", .{});
                    try gen_render.renderValueRef(self, self.an.rv(args[0]));
                    try self.b(", \"{0s}\")) contract.hostString(model.{0s}_idx__, inst.{0s}) else ", .{field});
                }
            }
            return self.b("\"\")", .{});
        },
        // §9.19 $param_given / $port_connected.
        .@"$param_given" => {
            const def = if (args.len > 0) self.mir.valueDef(self.an.rv(args[0])) else Mir.Def.undef;
            if (def == .param_ref and self.names.given_bit[def.param_ref] != none_u32) {
                self.uses.model = true;
                return self.b("@as(i64, @intFromBool(model.given__.isSet({d})))", .{self.names.given_bit[def.param_ref]});
            }
            return self.b("@as(i64, 0)", .{});
        },
        // §9.19 a top-level device's own port: lowering resolved it to its
        // ordinal k, and the host says which ports its card connects in
        // `Model.port_connected__` (all ones unless it writes it). Any other
        // form (an element expression) is connected, as before.
        .@"$port_connected" => {
            const port = if (args.len == 1) self.an.foldConst(args[0], false) else null;
            if (port) |ord| {
                self.uses.model = true;
                return self.b("@as(i64, @intFromBool((model.port_connected__ >> {d}) & 1 != 0))", .{std.math.lossyCast(u6, ord.f)});
            }
            return self.b("@as(i64, 1)", .{});
        },
        // §9.20 node aliases are resolved and folded by `Lower.bindAlias`, so
        // codegen never sees one; one that arrives is an unregistered `$name`.
        .@"$analog_node_alias", .@"$analog_port_alias" => return emitUnregistered(self, inst, name, args),
        // §9.12 / IEEE 1364 §17.10: a search of the host-written
        // `inst.plusargs`, in supplied order. `$plusarg$str` is the matched
        // plusarg that `$sscanf$<ty>` converts.
        .@"$test$plusargs", .@"$value$plusargs", .@"$plusarg$str" => {
            self.uses.inst = true;
            float_lanes.instPin(self);
            const str = c == .@"$plusarg$str";
            try self.b("{s}zPlusarg(inst.plusargs, ", .{if (str) "(" else "@as(i64, @intFromBool("});
            try gen_render.renderVal(self, if (args.len > 0) args[0] else .undef, .str);
            return self.b(", {}){s}", .{ c != .@"$test$plusargs", if (str) " orelse \"\")" else " != null))" });
        },
        // §9.22/§9.23 driver access is refused at lowering (E0818), so it
        // never reaches codegen.
        // §9.17.3 user-function `$limit`: lowering inlined the function and
        // latched its return. The result carries the access function's
        // derivative, not the limiter's. args = (vnew, vlim).
        .@"$limit$uf" => {
            if (args.len != 2) return emitUnregistered(self, inst, name, args);
            // `zLimitUf` reads `.val()` of both.
            float_lanes.pinLanes(self, args[0]);
            float_lanes.pinLanes(self, args[1]);
            return gen_render.helper2(self, "zLimitUf", args[0], args[1]);
        },
        .@"$limit$old" => {
            self.uses.inst = true;
            float_lanes.instPin(self);
            return self.b("S.con(inst.limiter_previous[{d}])", .{gen_render.intArg(self, args, 0) orelse unreachable});
        },
        // §4.5.15 the host owns the limiting algorithm (contract `limit`), so
        // the device returns the access function unchanged.
        .@"$limit" => return gen_render.renderVal(self, if (args.len > 0) args[0] else .f_zero, .real),
        .@"$clog2" => {
            try self.b("zClog2(", .{});
            try gen_render.renderVal(self, args[0], .int);
            try self.b(", ", .{});
            try gen_render.renderVal(self, args[1], .int);
            return self.b(")", .{});
        },
        // §9.11 `$rtoi` truncates (Table 9-7). Saturating, since the clause is
        // silent on overflow and `@intFromFloat` is UB under ReleaseFast.
        .@"$rtoi" => {
            if (args.len > 0) float_lanes.pinLanes(self, args[0]); // scalar collapse
            try self.b("std.math.lossyCast(i64, @trunc((", .{});
            try gen_render.renderVal(self, if (args.len > 0) args[0] else .f_zero, .real);
            return self.b(").val()))", .{});
        },
        .@"$itor" => {
            try self.b("S.con(@as(f64, @floatFromInt(", .{});
            try gen_render.renderVal(self, if (args.len > 0) args[0] else .zero, .int);
            return self.b(")))", .{});
        },
        // §9.11 Table 9-8 $realtobits/$bitstoreal: the IEEE 754 bit pattern,
        // exactly representable in the i64 lowering gives integers.
        .@"$realtobits" => {
            if (args.len > 0) float_lanes.pinLanes(self, args[0]); // scalar collapse
            try self.b("@as(i64, @bitCast((", .{});
            try gen_render.renderVal(self, if (args.len > 0) args[0] else .f_zero, .real);
            return self.b(").val()))", .{});
        },
        .@"$bitstoreal" => {
            try self.b("S.con(@as(f64, @bitCast(", .{});
            try gen_render.renderVal(self, if (args.len > 0) args[0] else .zero, .int);
            return self.b(")))", .{});
        },
        // §9.5.3 `$swrite`/`$sformat` as the synthetic `$sformat(format,
        // args...)`: lowering made it the right-hand side of an assignment to
        // the destination. The text goes into this call site's scratch row.
        .@"$sformat" => return cg_display.emitStringFormat(self, args, @backingInt(inst)),
        .@"$sformat$rt" => return cg_display.emitStringFormatRt(self, args, @backingInt(inst)),
        // §3.3 Table 3-3 a string built while the device runs, into this call
        // site's own scratch row, keyed like `$sformat`'s.
        .@"$str$cat" => {
            try self.b("zStrCat(", .{});
            try cg_display.emitRow(self, @backingInt(inst), try cg_strcap.cap(self, self.mir.instResult(inst)));
            try self.b(", &.{{", .{});
            for (args, 0..) |a, i| {
                if (i != 0) try self.b(", ", .{});
                try gen_render.renderVal(self, a, .str);
            }
            return self.b("}})", .{});
        },
        .@"$str$repeat" => {
            try self.b("zStrRepeat(", .{});
            try cg_display.emitRow(self, @backingInt(inst), try cg_strcap.cap(self, self.mir.instResult(inst)));
            try self.b(", ", .{});
            try gen_render.renderVal(self, args[0], .int);
            try self.b(", ", .{});
            try gen_render.renderVal(self, args[1], .str);
            return self.b(")", .{});
        },
        .@"$table_model" => return gen_render.emitTable(self, inst, args), // §9.21
        // Lowered to a running minimum (`lower_event.lowerKernelCtl`), never a call.
        .@"$vera_reject_step" => unreachable,
        // §3.2/§5.7 runtime array index (`emitIdx`), typed by the callee.
        .@"$idx", .@"$idx$int", .@"$idx$str" => return gen_render.emitIdx(self, args, Mir.callee.ty(c)),
        // §9.13 Table 9-10 as `Lower.lowerRandom` shapes it: the seed, then
        // the distribution's parameters. A variate is a pure function of the
        // seed and carries no derivative.
        .@"$rng$auto",
        .@"$rng$check",
        .@"$rng$rand",
        .@"$rng$rand_next",
        .@"$rng$i_uniform",
        .@"$rng$i_uniform_next",
        .@"$rng$uniform",
        .@"$rng$uniform_next",
        .@"$rng$normal",
        .@"$rng$normal_next",
        .@"$rng$exponential",
        .@"$rng$exponential_next",
        .@"$rng$poisson",
        .@"$rng$poisson_next",
        .@"$rng$chi_square",
        .@"$rng$chi_square_next",
        .@"$rng$t",
        .@"$rng$t_next",
        .@"$rng$erlang",
        .@"$rng$erlang_next",
        => return gen_render.emitRng(self, c, args),
        // §9.5.4.2 `$sscanf`: the count and three item flavours, each a pure
        // function of the two strings. `Lower.lowerScan` guards each
        // destination write with count > index.
        // §9.5.4.2 "For $sscanf, null characters shall also be considered
        // white space" — the `Nul` kernels, not the `$fscanf` ones.
        .@"$sscanf" => return gen_render.emitScan(self, "zScanNulN", args, .int),
        .@"$sscanf$int" => return gen_render.emitScan(self, "zScanNulI", args, .int),
        .@"$sscanf$real" => return gen_render.emitScan(self, "zScanNulR", args, .real),
        .@"$sscanf$str" => return gen_render.emitScan(self, "zScanNulS", args, .str),
        // IEEE 1364 §17.11 math functions are their bare spellings, resolved at
        // comptime. A wrong arity is an unregistered `$name`.
        inline .@"$sqrt",
        .@"$exp",
        .@"$expm1",
        .@"$ln",
        .@"$ln1p",
        .@"$log",
        .@"$log10",
        .@"$floor",
        .@"$ceil",
        .@"$sin",
        .@"$cos",
        .@"$tan",
        .@"$asin",
        .@"$acos",
        .@"$atan",
        .@"$sinh",
        .@"$cosh",
        .@"$tanh",
        .@"$asinh",
        .@"$acosh",
        .@"$atanh",
        .@"$pow",
        .@"$hypot",
        .@"$atan2",
        => |t| {
            // LRM Table 4-14/4-15 opcodes; `$log` is base 10, as lowering's `log`.
            const op: Mir.Opcode = comptime switch (t) {
                .@"$sqrt" => .sqrt,
                .@"$exp" => .exp,
                .@"$expm1" => .expm1,
                .@"$ln" => .ln,
                .@"$ln1p" => .ln1p,
                .@"$log", .@"$log10" => .log10,
                .@"$floor" => .floor,
                .@"$ceil" => .ceil,
                .@"$sin" => .sin,
                .@"$cos" => .cos,
                .@"$tan" => .tan,
                .@"$asin" => .asin,
                .@"$acos" => .acos,
                .@"$atan" => .atan,
                .@"$sinh" => .sinh,
                .@"$cosh" => .cosh,
                .@"$tanh" => .tanh,
                .@"$asinh" => .asinh,
                .@"$acosh" => .acosh,
                .@"$atanh" => .atanh,
                .@"$pow" => .pow,
                .@"$hypot" => .hypot,
                .@"$atan2" => .atan2,
                else => unreachable, // else: `t` is one of this prong's callees, each mapped above
            };
            if (Mir.opClass(op) == .unary and args.len >= 1) return gen_render.renderOp(self, op, args[0], .f_zero, .real);
            if (Mir.opClass(op) == .binary and args.len >= 2) return gen_render.renderOp(self, op, args[0], args[1], .real);
            return emitUnregistered(self, inst, name, args);
        },
        // §12.22.2 an output argument of the user system task `args[0]` calls.
        .@"$systf$out" => return emitSystfOut(self, args),
        // A `$name` is an unregistered system function; anything else is a
        // MIR call no clause defines.
        .systf => {
            if (name.len != 0 and name[0] == '$') return emitUnregistered(self, inst, name, args);
            return abort(self, .E1020, "VerA: unhandled call `{s}`", .{name});
        },
    }
}

/// Writes the void result of a §9.4/§9.7 task outside the printing unit.
/// Every such callee is real-valued, so one answer serves all. (§9.5
/// descriptors go through `emitFileCallDropped`, which respects their type.)
fn voidTask(self: *Gen) Error!void {
    return self.b("S.con(0.0)", .{});
}

/// Writes an unregistered system function call (W0852) as a VPI hand-off.
/// §2.8.3 makes `$name` grammatical and lets the VPI define it (§12.32), so
/// the source may not be rejected; `--deny=W0852` makes a host-less build
/// fail. Every Clause 9 name is implemented in `emitCall` or refused before
/// codegen, so only names the LRM defines nowhere arrive here. Add an
/// unimplemented LRM function to `Mir.Callee` and `emitCall`, not here.
fn emitUnregistered(self: *Gen, inst: Mir.Inst, name: []const u8, args: []const Mir.Value) Error!void {
    if (self.diags) |bag| try bag.add(
        .codegen,
        .W0852,
        self.lowered.tokenSpan(self.mir.instTok(inst)),
        "`{s}` is not a system function this compiler defines, so it is exported in " ++
            "`systf_calls` for a VPI application to supply; a host that binds none " ++
            "will not build",
        .{name},
    );
    // A systf crosses to the host through concrete f64s, so it pins.
    float_lanes.pinCrossing(self);
    return emitSystfCall(self, name, args, self.lowered.systf_tasks.contains(inst));
}

/// Reports `code` at the call being rendered (`Gen.call_tok`), marks the
/// build fatal with the first such message and writes a placeholder
/// `S.con(0.0)` so emission can continue. The diagnostic is what the user
/// sees; `fatal` only poisons the unit's generated body.
pub fn abort(self: *Gen, code: diag.Code, comptime fmt: []const u8, args: anytype) Error!void {
    const msg = try self.arena.print(fmt, args);
    if (self.diags) |bag| try bag.add(.codegen, code, self.lowered.tokenSpan(self.call_tok), "{s}", .{msg});
    self.poison(msg);
    try self.b("S.con(0.0)", .{});
}

/// Writes the §4.6.1 test of `args`' analysis names against `sim.kind`,
/// or `false` when none is a string literal.
fn analysisMatch(self: *Gen, args: []const Mir.Value) Error!void {
    self.uses.sim = true;
    var first = true;
    for (args) |a| {
        const def = self.mir.valueDef(self.an.rv(a));
        if (def != .str_const) continue;
        if (!first) try self.b(" or ", .{});
        first = false;
        const s = def.str_const;
        if (std.mem.eql(u8, s, "static")) {
            // §4.6.1 "static": any analysis that computes a DC operating point.
            try self.b("(sim.kind == .static or sim.kind == .ic or " ++
                "sim.kind == .nodeset or sim.kind == .dc)", .{});
        } else if (std.mem.eql(u8, s, "tran")) {
            // §4.6.1 "tran" covers "the initial DC and time-sweep phases of a
            // transient", so the ic phase counts.
            try self.b("(sim.kind == .tran or sim.kind == .ic)", .{});
        } else if (analysis_names.has(s)) {
            try self.b("sim.kind == .{s}", .{s});
        } else {
            try self.b("false", .{});
        }
    }
    if (first) try self.b("false", .{});
}

/// Writes §4.6.3's activity test of `ac_stim(args...)`, `contract.acStimActive`
/// with the comparisons the name decides at compile time folded away. A
/// Table 4-21 small-signal spelling ("ac", the default, or "noise") is that
/// kind; any other name is a small-signal analysis whose host label (Table
/// 9-28 `analysis_name`, `Lower` made the device publish its fields) is that
/// name. Never a large-signal analysis, whatever its name.
fn acStimMatch(self: *Gen, args: []const Mir.Value) Error!void {
    self.uses.sim = true;
    const def = if (args.len == 0) Mir.Def{ .str_const = "ac" } else self.mir.valueDef(self.an.rv(args[0]));
    // A.8.2 quotes the name, so `Lower` refused anything else (E0521).
    if (def != .str_const) return self.b("false", .{});
    const name = def.str_const;
    if (std.mem.eql(u8, name, "ac") or std.mem.eql(u8, name, "noise")) return self.b("sim.kind == .{s}", .{name});
    self.uses.inst = true;
    self.uses.model = true;
    float_lanes.instPin(self);
    try self.b("((sim.kind == .ac or sim.kind == .noise) and std.mem.eql(u8, " ++
        "contract.hostString(model.analysis_name_idx__, inst.analysis_name), \"{f}\"))", .{std.zig.fmtString(name)});
}

/// Writes one §2.8.3/§12.32 hand-off of `$name` to the host's VPI
/// application. A function pointer cannot be generic over S, so the host
/// takes f64 values and returns the value plus partials, and this rebuilds
/// S: `arg.addC(-arg.val()).scale(p)` adds p·d(arg) to the derivative and
/// zero to the value (§12.22.1's `derivtf`).
fn emitSystfCall(self: *Gen, name: []const u8, args: []const Mir.Value, task: bool) Error!void {
    const k = try systfIndex(self, name, self.call_tok, task);
    return emitHostCall(self, null, args, try self.arena.print("zsh.call(zsh.ctx, {d}, &zsv, &zsp)", .{k}));
}

/// Writes §12.22.2 output argument j of the user system task call
/// `args[0]`, whose arguments are `args[2..]`: the value its calltf put
/// there and the partials, through `SystfHost.output`. The call is rendered
/// first, so its calltf has run when the output is read.
fn emitSystfOut(self: *Gen, args: []const Mir.Value) Error!void {
    const call = systfOutCall(self, args) orelse
        return abort(self, .E1020, "VerA: `$systf$out` does not read a user system task call", .{});
    // Only a task has output arguments (`analog/systask.zig`).
    const k = try systfIndex(self, call.name, call.tok, true);
    // Crosses to the host through concrete f64s, as the call does.
    float_lanes.pinCrossing(self);
    return emitHostCall(self, args[0], args[2..], try self.arena.print("zsh.output({d}, {d}, &zsv, &zsp)", .{ k, call.j }));
}

/// The user system task call a `$systf$out` reads (its name and token) and
/// the argument position j, or null for MIR lowering never makes.
fn systfOutCall(self: *const Gen, args: []const Mir.Value) ?struct { name: []const u8, tok: u32, j: usize } {
    if (args.len < 2) return null;
    const def = self.mir.valueDef(self.an.rv(args[0]));
    if (def != .inst_result) return null;
    const d = self.mir.instData(def.inst_result);
    if (d != .call or d.call.callee != .systf) return null;
    const j = self.mir.valueDef(self.an.rv(args[1]));
    if (j != .int_const or j.int_const < 1 or j.int_const > args.len - 2) return null;
    return .{ .name = d.call.name, .tok = self.mir.instTok(def.inst_result), .j = @intCast(j.int_const) };
}

/// The `systf_calls` index of the call `name` at `tok`, added at the end
/// (a task when `task`) when it is new.
fn systfIndex(self: *Gen, name: []const u8, tok: u32, task: bool) Error!usize {
    for (self.systf_names.items, 0..) |n, i| {
        if (n.tok == tok and std.mem.eql(u8, n.name, name)) return i;
    }
    try self.systf_names.append(self.arena, .{ .name = name, .tok = tok, .task = task });
    return self.systf_names.items.len - 1;
}

/// Writes `zs<label>: { ... }`, the S value of `host` (an expression over
/// `zsh`, the f64 values `zsv` and the partials `zsp` it fills) with every
/// argument's lanes put back. `first`, when set, is rendered and discarded
/// before the arguments.
fn emitHostCall(self: *Gen, first: ?Mir.Value, args: []const Mir.Value, host: []const u8) Error!void {
    // Reads `inst`, so `emitUnit` keeps the parameter named.
    self.uses.inst = true;
    float_lanes.instPin(self);

    const label = self.systf_sites;
    self.systf_sites += 1;
    try self.b("zs{d}: {{\n", .{label});
    if (first) |f| {
        try self.b("        _ = ", .{});
        try gen_render.renderVal(self, f, .real);
        try self.b(";\n", .{});
    }
    for (args, 0..) |a, j| {
        try self.b("        const zs{d}a{d} = ", .{ label, j });
        try gen_render.renderVal(self, a, .real);
        try self.b(";\n", .{});
    }
    // `validateHost` refuses a host that binds no application, so this
    // unwrap is safe; the LRM fixes no default value to fall back to.
    try self.b("        const zsh = inst.systf.?;\n", .{});
    try self.b("        const zsv = [_]f64{{", .{});
    for (args, 0..) |_, j| try self.b("{s} zs{d}a{d}.val()", .{ if (j == 0) "" else ",", label, j });
    try self.b(" }};\n", .{});
    try self.b("        var zsp: [{d}]f64 = undefined;\n", .{args.len});
    // `zsr` holds every argument's lanes, the union of theirs.
    const m = try gen_mask.zero(self.arena, self.mw);
    for (args) |a| gen_mask.orIn(m, family.mask(self, a));
    const to = try self.arena.print("zTo(S, 0x{f}, ", .{gen_mask.hex(m, false)});
    const end = ")";
    try self.b("        var zsr = {s}S.con({s}){s};\n", .{ to, host, end });
    for (args, 0..) |_, j|
        try self.b("        zsr = {s}zsr.add(zs{d}a{d}.addC(-zsv[{d}]).scale(zsp[{d}])){s};\n", .{ to, label, j, j, j, end });
    try self.b("        break :zs{d} zsr;\n    }}", .{label});
}

/// Writes `systf_calls`, the `$name` calls this device leaves to a VPI
/// application, one per source call. Call after every unit is emitted:
/// `emitCall` fills the set.
pub fn emitSystfTable(self: *Gen) Error!void {
    if (self.systf_names.items.len == 0) return;
    try self.w(
        \\/// §2.8.3 `$name`s this device leaves to a VPI application
        \\/// (§12.32 `vpi_register_analog_systf`), one per call site. Position k
        \\/// is the `k` the device passes to `Instance.systf.?.call`. A host
        \\/// linking this device shall bind them — see `contract.validateHost`.
        \\pub const systf_calls = [_]contract.Systf{{
        \\
    , .{});
    // §12.22.2 each call's output arguments: every `$systf$out` lowering
    // made, rendered or not, so the set is the source's and not the plan's.
    const outs = try self.arena.alloc(u64, self.systf_names.items.len);
    @memset(outs, 0);
    for (0..self.mir.insts.len) |ii| {
        const inst: Mir.Inst = @fromBackingInt(@intCast(ii));
        if (self.mir.instOp(inst) != .call) continue;
        const d = self.mir.instData(inst).call;
        if (d.callee != .@"$systf$out") continue;
        const c = systfOutCall(self, d.args) orelse continue;
        if (c.j > 64) continue;
        for (self.systf_names.items, outs) |n, *o| {
            if (n.tok == c.tok and std.mem.eql(u8, n.name, c.name)) o.* |= @as(u64, 1) << @intCast(c.j - 1);
        }
    }
    for (self.systf_names.items, outs) |n, o| {
        try self.w("    .{{ .name = \"{s}\", .tok = {d}", .{ n.name, n.tok });
        if (o != 0) try self.w(", .outs = 0x{x}", .{o});
        if (n.task) try self.w(", .task = true", .{});
        try self.w(" }},\n", .{});
    }
    try self.w("}};\n\n", .{});
}

/// §9.4.6/§9.5.9 opens `(if (<cond>) ` around call `inst` in a printing
/// display unit that runs in passes (`Gen.passes`), where `<cond>` names the
/// passes of `contract.SayPass` that perform it; the caller writes the call,
/// then ` else ` and what the call answers when it is not performed, then
/// `)`. Returns false, writing nothing, outside such a unit and for a
/// §9.5.4 reader, which only reads what its count's call latched.
///   `$debug`, `$fdebug`: every pass but `.accepted` (§9.4.1 "for each
///     iteration of the analog solver"; §9.5.9 "the write operation shall
///     occur even if the evaluation occurred during an iteration that was
///     rejected").
///   one of those or a §9.5 call in `analog initial`: `.all`, and `.iteration`
///     at the first iterate, since §5.2.1 executes the block once per
///     analysis, "before a matrix solution is available".
///   every other task: every pass but `.iteration` (§9.4.6, §9.5.9).
/// `pass` is comptime, so a pass that does not perform the call compiles
/// only its other answer.
fn gateOpen(self: *Gen, c: Mir.Callee, inst: Mir.Inst) Error!bool {
    if (!self.passes or !self.emitting_display or Mir.callee.family(c) == .file_read) return false;
    self.uses.pass = true;
    // §9.7.3: `$fatal` "terminates the simulation without checking whether the
    // iteration would be rejected", so it is performed at the iterate like
    // `$debug`, not held back to the accepted point with the display tasks.
    const every = c == .@"$debug" or c == .@"$fdebug" or c == .@"$fatal";
    const init = std.mem.findScalar(Mir.Inst, self.init_calls, inst) != null and (every or Mir.callee.isFileCall(c));
    if (init) self.uses.sim = true;
    // §9.7.1/§9.7.2: a `$finish`/`$stop` that already ran means the run ends
    // at the enclosing wrapper (`zFinishPass`); no later task of this pass
    // may print, the way an immediate exit would have stopped them.
    try self.b("(if (zFinish == 0 and ({s})) ", .{if (init)
        "pass == .all or (pass == .iteration and sim.iteration == 1)"
    else if (every)
        "pass != .accepted"
    else
        "pass != .iteration"});
    return true;
}

/// Closes `gateOpen`'s `if` for a void task: not performed, it is the
/// `S.con(0.0)` every void call renders.
fn gateClose(self: *Gen) Error!void {
    try self.b(" else ", .{});
    try voidTask(self);
    return self.b(")", .{});
}

/// Writes a §9.5 call outside the display unit (every §9.5 call in a
/// `.drop` build). The result has `Mir.callee.ty`'s type; a descriptor is
/// an integer (§9.5.1).
fn emitFileCallDropped(self: *Gen, c: Mir.Callee, args: []const Mir.Value, site: usize) Error!void {
    _ = args; // `UnitPlan.dispHere` did not mark them: there is nothing here to read them
    // In a printing artifact the display unit performed the call and latched
    // its integer result, so read it back.
    if (self.display == .emit and Mir.callee.ty(c) == .int)
        return self.b("zFRes({d}).*", .{site});
    // Zero is the LRM's answer: §9.5.1 `$fopen` failure, §9.5.4.1 read
    // error, §9.5.8 no EOF, §9.5.7 no error.
    try self.b("{s}", .{switch (Mir.callee.ty(c)) {
        .real => "S.con(0.0)",
        .int => "@as(i64, 0)",
        .str => "\"\"",
        .wide => unreachable, // `Callee.table` types no file call wide
    }});
}

/// Returns the string literal at `args[i]`, or null.
pub fn strArg(self: *const Gen, args: []const Mir.Value, i: usize) ?[]const u8 {
    return @import("prove").strArg(self.input(), args, i);
}

/// Writes a §4.5 stateful analog operator call. Each operator is a named
/// unit, so its `Instance` fields and `updateState`'s read share a stable key.
fn emitOperator(self: *Gen, inst: Mir.Inst, args: []const Mir.Value, k: OpKind) Error!void {
    self.ctrl_tok = self.mir.instTok(inst); // E0515's fallback span
    const unit = gen_unit.unitOfInst(self, inst);
    if (unit == none_u32) return self.b("S.con(0.0)", .{});
    const n = self.names.unit_names[unit];
    // Render the input only when the kernel reads it, or `uses.x` would keep
    // an unreferenced parameter named.
    const needs_in = @import("ir").op.needsInput(k);
    // Every operator input is a core field, so this renders a local in the
    // core and a cache read in the display unit.
    const in0 = if (needs_in)
        try gen_render.renderToArena(self, if (args.len == 0) .f_zero else args[0], .real)
    else
        "";
    self.uses.inst = true;
    float_lanes.instPin(self); // the operator's history is the instance's
    // Every sim-state read below is spelled `sim.<field>`.
    const at = self.out.items.len;
    defer if (std.mem.find(u8, self.out.items[at..], "sim.") != null) {
        self.uses.sim = true;
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
            if (p.err) |m| return abort(self, .E0540, "{s}", .{m});
            // `__sec` always takes `model`, so keep the parameter named.
            self.uses.model = true;
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
            if (p.err) |m| return abort(self, .E0540, "{s}", .{m});
            // As for `.laplace`.
            self.uses.model = true;
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
                kS, in, n, try ctrlEval(self, args, 1, "0.0"), try ctrlEval(self, args, 2, "0.0"),
            });
            try opClose(self);
        },
        .idtmod => {
            try opOpen(self, fm);
            try self.b("zIdtmod({s}, {s}, inst.{s}__acc, sim.dt, {s}, {s}, {s})", .{
                kS,                                 in,
                n,                                  try ctrlEval(self, args, 1, "0.0"),
                try ctrlEval(self, args, 2, "0.0"), try ctrlEval(self, args, 3, "0.0"),
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
                    try absdelayTd(self, n, args, false),
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
                kS, in, n, n, try crossTest(self, n, args, v),
            });
            try opClose(self);
        },
        // §5.10.3 the event is decided here, at the point being evaluated;
        // `updateState` only advances `__prev`/`__next`. §5.10.3.1 "will not
        // generate events for non-transient analyses ... it can only generate
        // an event after the simulation time has advanced from zero": a
        // transient and a positive `dt`.
        .cross => try self.b("S.con(if (sim.kind == .tran and sim.dt > 0.0 and ({s}) and ({s})) 1.0 else 0.0)", .{
            try crossTest(self, n, args, try self.arena.print("({s}).val()", .{in0})),
            try enableTest(self, .cross, args),
        }),
        // §5.10.3.3 a change BEFORE the event test replaces its pending
        // deadline using the latest absolute start + k*period. Changes in an
        // event body cannot retroactively cancel the event already evaluated.
        .timer => try self.b("S.con(if (zTimerDue(({1s}).val(), {2s}, sim.t, inst.{0s}__start, inst.{0s}__per, inst.{0s}__next) and ({3s})) 1.0 else 0.0)", .{
            n,
            in0,
            try ctrlEval(self, args, 1, "0.0"),
            try enableTest(self, .timer, args),
        }),
        // §5.10.3.2 fires "when the expression crosses zero (0) from below":
        // edge-triggered against the last accepted value. No transient or
        // `dt` guard: above() "can generate an event during initialization"
        // and during a dc sweep. `__prev = 0.0` gives the initial event.
        .above => try self.b("S.con(if (inst.{0s}__prev <= 0.0 and ({1s}).val() > 0.0 and ({2s})) 1.0 else 0.0)", .{
            n, in0, try enableTest(self, .above, args),
        }),
        // §9.17 tasks return no value; read as one, they are zero.
        .bound_step, .discontinuity => try self.b("S.con(0.0)", .{}),
        .none => unreachable,
    }
}

/// Writes `zLu(S, m, ` around an operator kernel whose scalar is `zL(S, m)`;
/// `opClose` writes its `)`.
/// Opens a §4.5.7/§4.5.11/§4.5.12 kernel for both families: `ac`, the
/// operator's small-signal response, when the family is `acDyn`'s `zAc`,
/// else `zSs` around the kernel the caller writes next. `opClose` closes it.
fn acOpen(self: *Gen, kS: []const u8, ac: []const u8) Error!void {
    try self.b("if (comptime @hasDecl(S.Of(0), \"acMul\")) {s} else zSs({s}, sim.kind, ", .{ ac, kS });
}

fn opOpen(self: *Gen, m: []const u64) Error!void {
    try self.b("zLu(S, 0x{f}, ", .{gen_mask.hex(m, false)});
}
fn opClose(self: *Gen) Error!void {
    try self.b(")", .{});
}

/// Returns §4.5.8 `transition(expr, td, rise_time, fall_time)`'s rise and
/// fall times as f64 expressions. "If only a positive rise_time value is
/// specified, the simulator uses it for both"; a time that is absent or
/// "equal to zero (0.0)" takes the `default_transition` in force (§10.3).
/// A parameter time is tested for zero at run time.
pub fn transitionTimes(self: *Gen, args: []const Mir.Value) Error![2][]const u8 {
    const dflt = try defaultTransition(self);
    const rise = try transitionTime(self, args, 2, dflt orelse "0.0");
    // An absent or zero fall time is the rise time: "If only a positive
    // rise_time value is specified, the simulator uses it for both". With no
    // rise time either, `rise` already is the directive's default.
    const fall = try transitionTime(self, args, 3, rise);
    return .{ rise, fall };
}

fn transitionTime(self: *Gen, args: []const Mir.Value, i: usize, dflt: []const u8) Error![]const u8 {
    if (i >= args.len) return dflt;
    // `resolve_params = false`: only a time that is zero without parameters
    // is absent at compile time; a card may override a zero default.
    if (self.an.foldConst(args[i], false)) |c| {
        if (c.f == 0.0) return dflt;
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
    if (self.ctrl_tok == Mir.no_tok or self.ctrl_tok >= self.lowered.tok_starts.len) return null;
    const t = Lower.DefaultTransition.inForce(list, self.lowered.tok_starts[self.ctrl_tok], null) orelse return null;
    return try gen_file.fmtF64(self, t);
}

/// Returns §4.5.9's positive and negative slew limits. "If the
/// max_neg_slew_rate is not specified, it defaults to the opposite of the
/// max_pos_slew_rate": the kernel takes `@abs` of the negative limit, so the
/// positive expression is reused.
pub fn slewRates(self: *Gen, args: []const Mir.Value) Error![2][]const u8 {
    const pos = try gen_host.argF64(self, args, 1, "1e300");
    return .{ pos, try gen_host.argF64(self, args, 2, pos) };
}
