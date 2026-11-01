//! A call's dependence on the analysis -> its text (`emitAnalysis`), whether
//! it reads state the host changes with `x` held (`readsHostState`), and the
//! text of the §4.6.1 `analysis(...)` and §4.6.3 `ac_stim(...)` activity tests.
//! Cites: §4.5.4, §4.6.1, §4.6.3, §4.6.4, §4.5, §5.2.1, §5.10.2, §9, §9.14, §9.15.
//!
//! Contents:
//! - `pub fn emitAnalysis(self: *Gen, comptime c: Mir.Callee, args: []const Mir.Value) Error!void`
//! - `pub fn readsHostState(self: *const Gen, inst: Mir.Inst) bool`
//! - `pub fn analysisMatch(self: *Gen, args: []const Mir.Value) Error!void`
//! - `pub fn acStimMatch(self: *Gen, args: []const Mir.Value) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const float_lanes = @import("float/lanes.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const Mir = @import("ir").Mir;
const Lower = @import("ir").Lowered;
const Error = codegen.Error;
const gen_call = @import("call.zig");
const operator_ctrl = @import("operator_ctrl.zig");

/// The analysis names `analysis()` recognises (LRM §4.6.1).
const analysis_names = std.StaticStringMap(void).initComptime(.{ .{"static"}, .{"ic"}, .{"nodeset"}, .{"dc"}, .{"tran"}, .{"ac"}, .{"noise"} });

/// Writes a §4.6 analysis-dependent call: the §5.2.1 `analog initial` and
/// §5.10.2 event flags, §4.5.4's static-solve test, §4.6.1 `analysis`, a
/// §4.6.4 noise source (zero in the residual) or §4.6.3 `ac_stim`.
/// Invalidates slices of `out.items` if additional memory is needed.
pub fn emitAnalysis(self: *Gen, comptime c: Mir.Callee, args: []const Mir.Value) Error!void {
    comptime assert(Mir.callee.opKind(c) == .none);
    switch (c) {
        // §5.2.1 the `analog initial` guard. Not `initial_step`: §5.2.1 re-runs
        // the block per sweep sub-task, while initial_step is the first point
        // of the whole analysis.
        .analog_initial => {
            self.cur.uses.sim = true;
            try self.b("S.con(if (sim.analog_initial) 1.0 else 0.0)", .{});
            return;
        },

        // §4.5.4/§4.5.5 the solve an operator's DC form keys on. `dt`, not
        // `analysis("static")`: a host opens a transient with its own kind and
        // dt = 0. A small-signal analysis linearizes at dt = 0 too, and there
        // the operator is its transfer function, not its DC value.
        .@"op$static" => {
            self.cur.uses.sim = true;
            try self.b("S.con(if (sim.dt == 0.0 and sim.kind != .ac and sim.kind != .noise) 1.0 else 0.0)", .{});
            return;
        },

        // §5.10.2 global events.
        .initial_step, .final_step => {
            self.cur.uses.sim = true;
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
            // A.8.2 `ac_stim ( [ "name" [ , mag [ , phase ] ] ] )`: a fourth
            // argument has no slot. Lowering does not count them.
            if (args.len > 3) return gen_call.abort(self, .E0506, "`ac_stim()` takes at most 3 argument(s), got {d} (A.8.2)", .{args.len});
            // A.8.2 gives both numeric arguments as `analog_expression`, and
            // Table 4-20 does not list ac_stim, so a solve-computed magnitude
            // is legal: `ctrlEval`, not `argF64`.
            const mag = try operator_ctrl.ctrlEval(self, args, 1, "1.0");
            const phase = try operator_ctrl.ctrlEval(self, args, 2, "0.0");
            assert(mag.len != 0);
            assert(phase.len != 0);
            try self.b("S.con(if (", .{});
            try acStimMatch(self, args);
            try self.b(") ({s}) * @cos({s}) else 0.0)", .{ mag, phase });
            return;
        },
        else => @compileError("emitAnalysis: `" ++ @tagName(c) ++ "` is not an analysis-dependent call"), // else: `dispatch` routes only this family here
    }
}

/// Returns whether this call, as `emitCall` renders it, reads state the host
/// changes between evaluations with `x` held: `SimState`, operator history,
/// the §5.2.1 sub-task flag, the Newton iteration, limiter history, a
/// §9.13.1 seed latch or a held value. For `family.constant`. A new
/// `emitCall` arm that reads such state must be listed here too.
/// Asserts that `inst` is a call.
pub fn readsHostState(self: *const Gen, inst: Mir.Inst) bool {
    assert(@backingInt(inst) < self.mir.instCount());
    assert(self.mir.instOp(inst) == .call);
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
        .@"$simparam" => Lower.simparamIsRuntime(gen_call.strArg(self, d.args, 0) orelse ""),
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

/// Writes the §4.6.1 test of `args`' analysis names against `sim.kind`,
/// or `false` when none is a string literal.
/// Invalidates slices of `out.items` if additional memory is needed.
pub fn analysisMatch(self: *Gen, args: []const Mir.Value) Error!void {
    const len_before = self.out.items.len;
    self.cur.uses.sim = true;
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
    assert(self.out.items.len > len_before);
    assert(self.cur.uses.sim);
}

/// Writes §4.6.3's activity test of `ac_stim(args...)`, `contract.acStimActive`
/// with the comparisons the name decides at compile time folded away. A
/// Table 4-21 small-signal spelling ("ac", the default, or "noise") is that
/// kind; any other name is a small-signal analysis whose host label (Table
/// 9-28 `analysis_name`, `Lower` made the device publish its fields) is that
/// name. Never a large-signal analysis, whatever its name.
/// Asserts that `args` is `ac_stim`'s list (name, magnitude, phase).
/// Invalidates slices of `out.items` if additional memory is needed.
pub fn acStimMatch(self: *Gen, args: []const Mir.Value) Error!void {
    assert(args.len <= 3); // A.8.2 `ac_stim(name, mag, phase)`.
    self.cur.uses.sim = true;
    const def = if (args.len == 0) Mir.Def{ .str_const = "ac" } else self.mir.valueDef(self.an.rv(args[0]));
    // A.8.2 quotes the name, so `Lower` refused anything else (E0521).
    if (def != .str_const) return self.b("false", .{});
    const name = def.str_const;
    if (std.mem.eql(u8, name, "ac") or std.mem.eql(u8, name, "noise")) return self.b("sim.kind == .{s}", .{name});
    self.cur.uses.inst = true;
    self.cur.uses.model = true;
    float_lanes.instPin(self);
    const at = self.out.items.len;
    try self.b("((sim.kind == .ac or sim.kind == .noise) and std.mem.eql(u8, " ++
        "contract.hostString(model.analysis_name_idx__, inst.analysis_name), \"{f}\"))", .{std.zig.fmtString(name)});
    assert(self.out.items.len > at + name.len);
}
