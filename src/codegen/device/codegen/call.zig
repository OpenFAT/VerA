//! A MIR `call` -> its Zig text: one exhaustive switch over `Mir.Callee`
//! (`emitCall`) that renders §4.6 analysis/noise functions, Clause 9 system
//! functions and environment queries itself, and hands the rest to their
//! files: §4.5 operators to `call_operator.zig`, user system functions to
//! `call_systf.zig`, analysis tests to `call_analysis.zig`, per-pass task
//! gates to `call_gate.zig`, display text to `cg_display.zig`. Also the
//! refusal every renderer reports through (`abort`).
//! Cites: §2.8.3, §4.5, §4.6, §5.10.3, §6.3.4, §9, §10.3, §12.22.2, §12.32.
//!
//! Contents:
//! - `pub fn heldIdx(self: *const Gen, args: []const Mir.Value) usize`
//! - `pub fn emitCall(self: *Gen, inst: Mir.Inst) Error!void`
//! - `pub fn abort(self: *Gen, code: diag.Code, comptime fmt: []const u8, args: anytype) Error!void`
//! - `pub fn strArg(self: *const Gen, args: []const Mir.Value, i: usize) ?[]const u8`

const std = @import("std");
const assert = std.debug.assert;
const float_lanes = @import("float/lanes.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_dispatch = @import("dispatch.zig");
const gen_mask = @import("mask.zig");
const gen_file = @import("file.zig");
const gen_render = @import("render.zig");
const render_sysfunc = @import("render_sysfunc.zig");
const render_op = @import("render_op.zig");
const gen_host = @import("host_expr.zig");
const gen_wide = @import("wide.zig");
const Mir = @import("ir").Mir;
const cg_display = @import("../cg_display.zig");
const cg_strcap = @import("../cg_strcap.zig");
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const diag = @import("diag");
const operator_ctrl = @import("operator_ctrl.zig");
const call_operator = @import("call_operator.zig");
const call_systf = @import("call_systf.zig");
const call_analysis = @import("call_analysis.zig");
const call_gate = @import("call_gate.zig");

/// Returns the §5.10 `held_vars` index a `$held_*` call carries as its only
/// argument, a literal lowering emitted.
/// Asserts that the model has a held variable to index and that `args` is
/// that one literal.
pub fn heldIdx(self: *const Gen, args: []const Mir.Value) usize {
    assert(self.names.held_names.len != 0);
    assert(args.len <= 1);
    const c = self.an.foldConst(if (args.len != 0) args[0] else .zero, false) orelse return 0;
    const i: usize = @intFromFloat(c);
    return @min(i, self.names.held_names.len -| 1);
}

/// Writes a call: system and environment functions (Clause 9), §4.5
/// operators, §4.6 functions. One exhaustive switch over `Mir.Callee`, so a
/// new callee does not compile until it has a rendering.
/// Asserts that `inst` is a call. Restores `cur.call_tok` on return.
/// Invalidates slices of `out.items` if additional memory is needed.
pub fn emitCall(self: *Gen, inst: Mir.Inst) Error!void {
    assert(self.mir.instOp(inst) == .call);
    const d = self.mir.instData(inst).call;
    const c = d.callee;
    const name = d.name;
    const args = d.args;
    const k = Mir.callee.opKind(c);
    const saved_tok = self.cur.call_tok;
    self.cur.call_tok = self.mir.instTok(inst);
    defer self.cur.call_tok = saved_tok;
    assert(self.cur.call_tok == self.mir.instTok(inst));
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
        => return call_operator.emitOperator(self, inst, args, k),

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
            gen_mask.orIn(self.jac.ddx_reads, try gen_dispatch.bits(self, &.{if (lane >= 0 and lane < self.names.n_u) @intCast(lane) else none_u32}, &.{}));
            try self.b("S.con((", .{});
            try gen_render.renderVal(self, if (args.len > 0) args[0] else .f_zero, .real);
            try self.b(").ddxAt({d}))", .{lane});
            return;
        },

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
                try call_analysis.analysisMatch(self, args);
                try self.b(")", .{});
            }
            try self.b(") 1.0 else 0.0)", .{});
            return;
        },

        // §4.6.1 analysis("dc"|"tran"|…).
        .analysis => {
            try self.b("S.con(if (", .{});
            try call_analysis.analysisMatch(self, args);
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
            const mag = try operator_ctrl.ctrlEval(self, args, 1, "1.0");
            const phase = try operator_ctrl.ctrlEval(self, args, 2, "0.0");
            try self.b("S.con(if (", .{});
            try call_analysis.acStimMatch(self, args);
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
                const gated = try call_gate.gateOpen(self, c, inst);
                try cg_display.emitDisplayTask(self, c, args, inst);
                return if (gated) call_gate.gateClose(self) else {};
            },
            // A device's `say` records the task (`contract.SaySite`); a task
            // it does not record, and every other unit, renders it void.
            .record => if (self.cur.emitting_display) cg_display.emitSay(self, inst) else call_gate.voidTask(self),
            .drop => call_gate.voidTask(self),
        },
        // §9.7.1/§9.7.2 same gate: in a printing artifact the run ends at the
        // call's position among the prints; in a device the call is dead.
        .@"$finish", .@"$stop" => {
            if (self.display != .emit) return call_gate.voidTask(self);
            const gated = try call_gate.gateOpen(self, c, inst);
            try cg_display.emitSimCtl(self, name, args, inst);
            return if (gated) call_gate.gateClose(self) else {};
        },
        // §9.4.1 a monitor's registration is a side effect, performed only by
        // the display unit.
        .@"$monitor$arm" => {
            if (!self.cur.emitting_display or self.display != .emit) return call_gate.voidTask(self);
            const gated = try call_gate.gateOpen(self, c, inst);
            try cg_display.emitMonitorArm(self, args);
            return if (gated) call_gate.gateClose(self) else {};
        },
        .@"$monitoron", .@"$monitoroff" => return call_gate.voidTask(self),
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
            if (!self.cur.emitting_display or self.display != .emit) return call_gate.emitFileCallDropped(self, c, args, @backingInt(inst));
            const gated = try call_gate.gateOpen(self, c, inst);
            try cg_display.emitFileCall(self, c, args, @backingInt(inst));
            if (!gated) return;
            try self.b(" else ", .{});
            try call_gate.emitFileCallDropped(self, c, args, @backingInt(inst));
            return self.b(")", .{});
        },
        // §9.10 environment.
        .@"$temperature" => {
            self.cur.uses.model = true;
            return self.b("S.con(model.temperature__)", .{});
        },
        .@"$vt" => {
            // §9.10 $vt = kT/q, k/q = 8.617333262e-5 V/K.
            if (args.len == 0) {
                self.cur.uses.model = true;
                return self.b("S.con(model.temperature__ * 8.617333262145179e-5)", .{});
            }
            try self.b("(", .{});
            try gen_render.renderVal(self, args[0], .real);
            return self.b(").scale(8.617333262145179e-5)", .{});
        },
        .@"$abstime", .@"$realtime" => {
            self.cur.uses.sim = true;
            return self.b("S.con(sim.t)", .{});
        },
        // §5.10 the retained value of an event-assigned variable: the
        // `Instance` default before the event first fires, then the last
        // accepted value.
        .@"$held_real", .@"$held_int" => {
            self.cur.uses.inst = true;
            const f = self.names.held_names[heldIdx(self, args)];
            float_lanes.instLanes(self, c == .@"$held_int");
            return self.b("{s}(S, inst, \"{s}\")", .{ if (c == .@"$held_int") "zInstI" else "zInst", f });
        },
        // §5.10/§3.3 a held string: its `ZStrHeld` field's text, read from
        // the one instance `inst` is, so an eval-side read is not `batch_ok`.
        .@"$held_str" => {
            self.cur.uses.inst = true;
            float_lanes.instPin(self);
            return self.b("inst.{s}.get()", .{self.names.held_names[heldIdx(self, args)]});
        },
        // IEEE 1364 §5.4 a held wide `reg`: its `ZW(n)` field, read from the
        // one instance `inst` is, as a held string is.
        .@"$held_wide" => {
            self.cur.uses.inst = true;
            float_lanes.instPin(self);
            return self.b("inst.{s}", .{self.names.held_names[heldIdx(self, args)]});
        },
        .@"$wide" => return gen_wide.emitWide(self, args, .bits),
        .@"$wide$int" => return gen_wide.emitWide(self, args, .int),
        // VerA's `vera_timepoint` (§2.9): is statement b's cache current, and
        // its slot k (`Lower.TpBlock`, the fields `emitInstance` declares).
        .@"$tp_hit" => {
            self.cur.uses.inst = true;
            self.cur.uses.sim = true;
            const b = litArg(self, args, 0);
            return self.b("@as(i64, @intFromBool(zTpHit(inst.tp{d}_t, inst.tp{d}_k, sim)))", .{ b, b });
        },
        .@"$tp_int", .@"$tp_real", .@"$tp_wide" => {
            self.cur.uses.inst = true;
            const b = litArg(self, args, 0);
            const slot = litArg(self, args, 1);
            return if (c != .@"$tp_real")
                self.b("inst.tp{d}_s{d}", .{ b, slot })
            else
                self.b("S.con(inst.tp{d}_s{d})", .{ b, slot });
        },
        .@"$mfactor" => { // §6.3.6
            self.cur.uses.inst = true;
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
                    self.cur.uses.sim = true;
                    if (std.mem.eql(u8, nm, "dt")) return self.b("S.con(sim.dt)", .{});
                    return self.b("S.con(@floatFromInt(sim.iteration))", .{});
                },
                .host => |h| {
                    self.cur.uses.model = true;
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
                    self.cur.uses.sim = true;
                    return self.b("@tagName(sim.kind)", .{});
                }
                if (std.mem.eql(u8, nm, "module")) return self.b("\"{f}\"", .{std.zig.fmtString(self.mir.name)});
                const host = std.mem.eql(u8, nm, "cwd") or std.mem.eql(u8, nm, "analysis_name");
                if (!host or !self.lowered.uses.contains(.host_strings)) return self.b("\"\"", .{});
                self.cur.uses.inst = true;
                self.cur.uses.model = true;
                float_lanes.instPin(self);
                return self.b("contract.hostString(model.{0s}_idx__, inst.{0s})", .{nm});
            }
            // §9.15 param_name may be a string variable, so the lookup runs
            // at run time.
            self.cur.uses.sim = true;
            try self.b("(if (std.mem.eql(u8, ", .{});
            try gen_render.renderValueRef(self, self.an.rv(args[0]));
            try self.b(", \"analysis_type\")) @tagName(sim.kind) else if (std.mem.eql(u8, ", .{});
            try gen_render.renderValueRef(self, self.an.rv(args[0]));
            try self.b(", \"module\")) \"{f}\" else ", .{std.zig.fmtString(self.mir.name)});
            if (self.lowered.uses.contains(.host_strings)) {
                self.cur.uses.inst = true;
                self.cur.uses.model = true;
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
                self.cur.uses.model = true;
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
                self.cur.uses.model = true;
                return self.b("@as(i64, @intFromBool((model.port_connected__ >> {d}) & 1 != 0))", .{std.math.lossyCast(u6, ord)});
            }
            return self.b("@as(i64, 1)", .{});
        },
        // §9.20 node aliases are resolved and folded by `Lower.bindAlias`, so
        // codegen never sees one; one that arrives is an unregistered `$name`.
        .@"$analog_node_alias", .@"$analog_port_alias" => return call_systf.emitUnregistered(self, inst, name, args),
        // §9.12 / IEEE 1364 §17.10: a search of the host-written
        // `inst.plusargs`, in supplied order. `$plusarg$str` is the matched
        // plusarg that `$sscanf$<ty>` converts.
        .@"$test$plusargs", .@"$value$plusargs", .@"$plusarg$str" => {
            self.cur.uses.inst = true;
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
            if (args.len != 2) return call_systf.emitUnregistered(self, inst, name, args);
            // `zLimitUf` reads `.val()` of both.
            float_lanes.pinLanes(self, args[0]);
            float_lanes.pinLanes(self, args[1]);
            return render_op.helper2(self, "zLimitUf", args[0], args[1]);
        },
        .@"$limit$old" => {
            self.cur.uses.inst = true;
            float_lanes.instPin(self);
            return self.b("S.con(inst.limiter_previous[{d}])", .{render_sysfunc.intArg(self, args, 0) orelse unreachable});
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
        .@"$table_model" => return render_sysfunc.emitTable(self, inst, args), // §9.21
        // Lowered to a running minimum (`lower_event.lowerKernelCtl`), never a call.
        .@"$vera_reject_step" => unreachable,
        // §3.2/§5.7 runtime array index (`emitIdx`), typed by the callee.
        .@"$idx", .@"$idx$int", .@"$idx$str" => return render_sysfunc.emitIdx(self, args, Mir.callee.ty(c)),
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
        => return render_sysfunc.emitRng(self, c, args),
        // §9.5.4.2 `$sscanf`: the count and three item flavours, each a pure
        // function of the two strings. `Lower.lowerScan` guards each
        // destination write with count > index.
        // §9.5.4.2 "For $sscanf, null characters shall also be considered
        // white space" — the `Nul` kernels, not the `$fscanf` ones.
        .@"$sscanf" => return render_sysfunc.emitScan(self, "zScanNulN", args, .int),
        .@"$sscanf$int" => return render_sysfunc.emitScan(self, "zScanNulI", args, .int),
        .@"$sscanf$real" => return render_sysfunc.emitScan(self, "zScanNulR", args, .real),
        .@"$sscanf$str" => return render_sysfunc.emitScan(self, "zScanNulS", args, .str),
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
            if (Mir.opClass(op) == .unary and args.len >= 1) return render_op.renderOp(self, op, args[0], .f_zero, .real);
            if (Mir.opClass(op) == .binary and args.len >= 2) return render_op.renderOp(self, op, args[0], args[1], .real);
            return call_systf.emitUnregistered(self, inst, name, args);
        },
        // §12.22.2 an output argument of the user system task `args[0]` calls.
        .@"$systf$out" => return call_systf.emitSystfOut(self, args),
        // A `$name` is an unregistered system function; anything else is a
        // MIR call no clause defines.
        .systf => {
            if (name.len != 0 and name[0] == '$') return call_systf.emitUnregistered(self, inst, name, args);
            return abort(self, .E1020, "VerA: unhandled call `{s}`", .{name});
        },
    }
}

/// Reports `code` at the call being rendered (`Gen.call_tok`), marks the
/// build fatal with the first such message and writes a placeholder
/// `S.con(0.0)` so emission can continue. The diagnostic is what the user
/// sees; `fatal` only poisons the unit's generated body.
pub fn abort(self: *Gen, code: diag.Code, comptime fmt: []const u8, args: anytype) Error!void {
    const len_before = self.out.items.len;
    const msg = try self.arena.print(fmt, args);
    if (self.diags) |bag| try bag.add(.codegen, code, self.lowered.tokenSpan(self.cur.call_tok), "{s}", .{msg});
    self.poison(msg);
    try self.b("S.con(0.0)", .{});
    assert(self.cur.fatal != null);
    assert(self.out.items.len == len_before + "S.con(0.0)".len);
}

/// Returns the string literal at `args[i]`, or null.
pub fn strArg(self: *const Gen, args: []const Mir.Value, i: usize) ?[]const u8 {
    assert(args.len <= std.math.maxInt(u32));
    return @import("prove").strArg(self.input(), args, i);
}

// ---- private ----

/// The literal index at argument `i` of a lowering-minted call (`$tp_*`).
fn litArg(self: *const Gen, args: []const Mir.Value, i: usize) u32 {
    const c = self.an.foldConst(if (i < args.len) args[i] else .zero, false) orelse return 0;
    return @intFromFloat(c);
}
