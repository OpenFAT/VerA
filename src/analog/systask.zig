//! Clause 9 system tasks in statement position: a `$task(...)` statement in,
//! its MIR `call` out, routed by family: §9.4/§9.7 prints and simulation
//! control onto the display chain (`display.zig`), §9.5 string and file I/O
//! (`string_io.zig`), §9.7.3 status (`status.zig`), §9.17 kernel control
//! (`kernel_ctl.zig`), and a user task's §12.22.2 output arguments.
//!
//! Cites: §4.2.1.1, §5.12, A.6.9, §7.3.1, §9.2, §9.4, §9.4.1, §9.4.2, §9.4.3,
//! §9.4.6, §9.5, §9.5.2, §9.5.3, §9.5.4, §9.5.4.2, §9.7, §9.7.1, §9.7.2,
//! §9.7.3, §9.13, §9.17, §9.17.1, §9.17.2, §12.22.2, §12.30, §12.32.2.
//!
//! Contents:
//! - `pub const State = struct`
//! - `pub fn lowerSysTask(self: *Lower, tok: u32, name: []const u8, args: []const Ast.ExprId) Oom!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Lower = @import("Lower.zig");
const lower_random = @import("random.zig");
const lower_sysfunc = @import("sysfunc.zig");
const Ssa = @import("ssa.zig");
const lower_lvalue = @import("lvalue.zig");
const lower_kernel_ctl = @import("kernel_ctl.zig");
const lower_status = @import("status.zig");
const lower_display = @import("display.zig");
const lower_format = @import("format.zig");
const lower_string_io = @import("string_io.zig");
const lower_clog2 = @import("clog2.zig");
const lower_sysfunc_args = @import("sysfunc_args.zig");
const lower_sysfunc_context = @import("sysfunc_context.zig");
const DeferredDisplay = lower_display.DeferredDisplay;
const Oom = Lower.Oom;
const Ty = Lower.Ty;
const Lowered = Lower.Lowered;

/// This file's private state on `Lower` (`Lower.systask_state`).
pub const State = struct {
    /// §9.4.1 display statements whose CALL is created at the end of the analog
    /// block (`finishDisplays`), in source order — see `queueDisplay` for the
    /// clause reading. Parallel-ish to `displays`: each entry names the
    /// placeholder `displays` row whose `.val` it fills.
    deferred_displays: std.ArrayList(DeferredDisplay) = .empty,
    /// §9.4.1 `$monitor`/`$fmonitor` statements lowered so far. Each one's ordinal
    /// is the key its registration (`$monitor$arm`) and its end-of-step report
    /// share — see `armMonitor`.
    monitor_sites: u32 = 0,
    /// §9.4.6 the carrier for conditional prints, which cannot be `fadd`-chained
    /// directly because a call inside an `if` arm does not dominate the chain root.
    /// An SSA place seeded `.f_zero` in `.entry`, `fadd`-ed at each guarded call
    /// site and read once at the end: the arm's phi carries the call into the live
    /// slice on the path that ran. Null: no conditional print.
    display_cond_place: ?Ssa.Place = null,
    /// §9.17.2 `$bound_step`: an SSA place seeded to +inf ("nothing asked for") in
    /// the entry block and `fmin`-ed at every call site, so a call under an `if`
    /// bounds the step only on the arm that ran. `finishKernelCtl` turns the final
    /// value into one synthetic `call` (a unit). Null: the model never called it.
    bound_step_place: ?Ssa.Place = null,
    /// VerA's `$vera_reject_step`, the same way: +inf is "no request".
    reject_step_place: ?Ssa.Place = null,
    /// §9.17.1 `$discontinuity`, the same way as `bound_step_place`.
    disc_place: ?Ssa.Place = null,
    /// §9.7.3 the status channel (`Lowered.status`): the code place, seeded 0
    /// ("nothing reported"), then its argument places, written by the FIRST
    /// `$fatal`/`$error` an evaluation reaches. Null: the model has no site.
    status_places: ?[1 + Lowered.status_arg_max]Ssa.Place = null,
    /// §9.17.1 `$discontinuity(-1)`'s flag, seeded 0 and set 1 at each call site;
    /// its final read is `out.reject_iteration`, and `out.uses.reject_iteration`
    /// says it exists.
    reject_iteration_place: ?Ssa.Place = null,
    /// §9.7.3 `$error` inside `analog initial`: an integer place seeded 0 in
    /// `.entry` and set 1 at each such call, and the first call's token.
    /// `haltAfterInitError` reads it after the block. Null: no such call.
    init_error: ?struct { place: Ssa.Place, tok: u32 } = null,
};

/// Lowers a §5.12/ch9 system task in statement position. Display and file tasks
/// are void calls codegen may drop; the unsupported set is rejected by name.
pub fn lowerSysTask(self: *Lower, tok: u32, name: []const u8, args: []const Ast.ExprId) Oom!void {
    assert(self.blockValid(self.cur));
    assert(name.len != 0);
    if (try lower_sysfunc.refuseReserved(self, tok, name)) return;
    const c: Mir.Callee = .fromName(name);
    const family = Mir.callee.family(c);
    const formats = Mir.callee.takesFormat(c);
    if (lower_sysfunc_context.isDigitalOnlySysFunc(name)) { // §9.2
        try self.err(tok, .E0806, "`{s}`", .{name});
        return;
    }
    // §9.7.2, final sentence: "The $stop task shall not be used within an
    // analog initial block." Positional, not a support question — $stop in an
    // ordinary analog block is legal.
    if (self.in_analog_initial and std.mem.eql(u8, name, "$stop")) {
        try self.err(tok, .E0807, "", .{});
        return;
    }
    if (try lower_sysfunc_args.checkArity(self, tok, name, args)) return;
    if (c == .@"$clog2") {
        _ = try lower_clog2.lowerClog2(self, tok, args[0]);
        return;
    }
    // §9.13 Table 9-10 in statement position. They are FUNCTIONS, so a bare
    // `$random(s);` is only ever written for the seed's inout side effect — which
    // is exactly what `lowerRandom` performs; the variate is dropped.
    if (try lower_random.lowerRandom(self, tok, name, args)) |_| return;
    // §9.4.3's pairing rule is stated for the display tasks and §9.5.2 defines
    // the file ones as "the same as their counterparts", so it covers both.
    // `checkFormatPairing` takes the first argument that folds to a string,
    // which steps over the descriptor.
    if (formats) try lower_format.checkFormatPairing(self, tok, args);
    // §9.5.3/§9.5.4.2: all three of these write through an argument, which is
    // not something a `call` result can do — see `lowerStringWrite`/`lowerScan`.
    if (std.mem.eql(u8, name, "$swrite") or std.mem.eql(u8, name, "$sformat"))
        return lower_string_io.lowerStringWrite(self, tok, name, args);
    if (std.mem.eql(u8, name, "$sscanf")) {
        _ = try lower_string_io.lowerScan(self, tok, args); // the count is the value; a statement drops it
        return;
    }
    // §9.5.4: the same shape as `$sscanf` for the same reason — a destination
    // argument. In statement position the count is dropped, the write is not.
    if (try lower_string_io.lowerFileRead(self, tok, name, args)) |_| return;
    if (try lower_kernel_ctl.lowerKernelCtl(self, tok, name, args)) return; // §9.17
    if (c == .@"$fatal" and try lower_status.badFinishNumber(self, args)) return;
    if (c == .@"$fatal" or c == .@"$error") try lower_status.lowerStatus(self, tok, c == .@"$fatal", args);
    if (c == .@"$error" and self.in_analog_initial) {
        const ie = self.systask_state.init_error orelse blk: {
            const p = self.builder.newPlace();
            try self.builder.writeVariable(p, .entry, .zero);
            self.systask_state.init_error = .{ .place = p, .tok = tok };
            break :blk self.systask_state.init_error.?;
        };
        try self.builder.writeVariable(ie.place, self.cur, .one);
    }
    // §9.4.1 `$monitor` and its §9.5.2 file twin: registered HERE, reported at
    // the end of every accepted step from then on — see `armMonitor`.
    const mon: ?Mir.Value = if (c == .@"$monitor" or c == .@"$fmonitor") try lower_display.armMonitor(self, name) else null;
    if (mon != null and self.restrict == null) return lower_display.queueDisplay(self, tok, name, args, mon);
    // §9.4.1 the display/severity/control family on the unconditional spine:
    // its call is minted at the end of the block, where an operand that reads a
    // branch flow is evaluated (see `queueDisplay`). Conditional and restricted
    // cases mint the call at the statement: a guarded call has to stay in its
    // arm, and E0421 fires where `restrict` is still set.
    if ((family == .display or family == .simctl) and
        self.cond_depth == 0 and self.restrict == null)
        return lower_display.queueDisplay(self, tok, name, args, null);
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    var live: std.ArrayList(Ast.ExprId) = .empty;
    defer live.deinit(self.arena);
    var tys: std.ArrayList(Ty) = .empty;
    defer tys.deinit(self.arena);
    for (args, 0..) |a, i| {
        if (a == .none) {
            // A.6.9 empty argument slot: §9.4.1's space for a formatting task,
            // nothing for any other. A descriptor has no space to print.
            if (!formats) continue;
            if (Mir.callee.fdArg(c)) |fd| if (fd == i) {
                try self.err(tok, .E0888, "`{s}`'s descriptor argument is a null argument", .{name});
                return;
            };
        }
        const tv = if (a == .none) try lower_display.nullArg(self) else try lower_sysfunc_args.lowerTaskArg(self, a, name);
        if (try lower_sysfunc_args.checkDescriptor(self, name, i, a, tv)) return;
        try vals.append(self.arena, tv.v);
        try live.append(self.arena, a);
        try tys.append(self.arena, tv.ty);
    }
    if (family == .file_out) {
        self.out.uses.insert(.file_tasks);
        // The §9.4.3 formatter renders into a scratch row before the write, so a
        // module with a §9.5.2 output task needs the string kernels too.
        self.out.uses.insert(.str_tasks);
    }
    if (formats) {
        // §9.4.3's other pairing half — each conversion against its operand's
        // TYPE. After the loop, because the types are what lowering computed.
        try lower_format.prepareFormatArgs(self, tok, live.items, tys.items, vals.items, lower_format.messageStart(c, tys.items));
    }
    // A restricted context's monitor reports at the statement: its operands
    // are diagnosed there, and an inlined function's locals end with the body.
    if (mon) |k| try vals.insert(self.arena, 0, k);
    const v = try self.call(name, vals.items);
    if (c == .systf) {
        try self.out.systf_tasks.put(self.arena, self.mir.valueDef(v).inst_result, {});
        try systfOutputs(self, v, live.items, vals.items);
    }
    // ponytail: printing and simulation control share one display-chain append.
    if (formats or family == .simctl) {
        // §9.7.1/§9.7.2 simulation control joins the per-accepted-point
        // display phase: both clauses tie the task to "an accepted iteration",
        // and §9.7.3's $fatal already travels this way. The printing artifact
        // stops the run at its position among the prints (cg_display.emitSimCtl);
        // a device drops it with W0850, because eval has no channel to stop a
        // host's solve. A conditional call travels `display_cond_place` like a
        // conditional $strobe (§9.4.6).
        const cond = self.cond_depth != 0;
        if (cond) try lower_display.chainCondDisplay(self, v);
        try self.out.displays.append(self.arena, .{
            .val = v,
            .name = name,
            .tok = tok,
            .conditional = cond,
            .analog_initial = self.in_analog_initial,
        });
    }
}

// ---- private ----

/// §12.22.2 a user system task's output arguments: `$resistor(curr, V(p, n),
/// r)`'s calltf puts `curr` (§12.30) and its partials (§12.32.2), and the
/// next statement reads it. Every argument that is a real or integer variable
/// is read back after `call` as `$systf$out(call, j, args...)`, j 1-based as
/// §12.32.2 numbers arguments; an argument calltf did not put keeps its value
/// (`contract.SystfHost.output`). An integer takes the real §4.2.1.1 rounds.
fn systfOutputs(self: *Lower, call: Mir.Value, live: []const Ast.ExprId, vals: []const Mir.Value) Oom!void {
    assert(self.valueValid(call));
    assert(self.blockValid(self.cur));
    const ex = &self.file.exprs;
    for (live, 0..) |a, j| {
        if (a == .none or ex.tag(a) != .ident) continue;
        const s = self.vars.get(self.file.str(ex.strOf(a))) orelse continue;
        // A `reg` (§7.3.1) keeps its width rule; a string has no partials.
        if (s.ty == .string or s.regWidth() != null) continue;
        const args = try self.arena.alloc(Mir.Value, vals.len + 2);
        args[0] = call;
        args[1] = try self.mir.addIntConst(self.arena, @intCast(j + 1));
        @memcpy(args[2..], vals);
        const out = try self.call("$systf$out", args);
        const lv: lower_lvalue.Lvalue = .{ .ty = s.ty, .at = .{ .place = s.place } };
        try lower_lvalue.writeLvalue(self, lv, if (s.ty == .integer) try self.emit(.fi_cast, &.{out}) else out);
    }
}

test "§9.4/§9.7/§9.17 system tasks: arguments a task refuses, and their neighbours" {
    try Lower.expectBodies(&.{
        // §9.7.3 `finish_number ::= 0 | 1 | 2`.
        .{ .src = "analog begin $fatal(3); I(p) <+ V(p); end", .code = .E0824 },
        .{ .src = "analog begin $fatal(1, \"stop\"); I(p) <+ V(p); end", .code = null },
        // §9.17.2 "The expression argument shall be non-negative."
        .{ .src = "analog begin $bound_step(-1.0); I(p) <+ V(p); end", .code = .E0803 },
        .{ .src = "analog begin $bound_step(1n); I(p) <+ V(p); end", .code = null },
        // §9.17.1: "i must be a non-negative integer"; -1 is the special form.
        .{ .src = "analog begin $discontinuity(-2); I(p) <+ V(p); end", .code = .E0820 },
        .{ .src = "analog begin $discontinuity(-1); I(p) <+ V(p); end", .code = null },
        // §9.17.1's argument is a constant_expression.
        .{ .src = "analog begin x = V(p); $discontinuity(x); I(p) <+ V(p); end", .code = .E0805 },
        // §9.4.3: one argument per consuming conversion; `%%` consumes none.
        .{ .src = "analog begin $strobe(\"%d %d\", 1); I(p) <+ V(p); end", .code = .E0810 },
        .{ .src = "analog begin $strobe(\"%d%%\", 1); I(p) <+ V(p); end", .code = null },
        .{ .src = "analog begin $strobe(\"%s\", 1.5); I(p) <+ V(p); end", .code = .E0819 },
        // #41: '#' is a flag, so `%#g` is still `%g` and a string under it
        // is E0819; '#' itself is §9.4.3's C form on %e/%f/%g only (E0825).
        .{ .src = "analog begin $strobe(\"%#g\", sv); I(p) <+ V(p); end", .code = .E0819 },
        .{ .src = "analog begin $strobe(\"%#e\", sv); I(p) <+ V(p); end", .code = .E0819 },
        .{ .src = "analog begin $strobe(\"%#g %#e %#10.0f\", 1.5, 2.5, 3.5); I(p) <+ V(p); end", .code = null },
        .{ .src = "analog begin $strobe(\"%#x\", iv); I(p) <+ V(p); end", .code = .E0825 },
        .{ .src = "analog begin $strobe(\"%#m%d\", 1); I(p) <+ V(p); end", .code = .E0825 },
        .{ .src = "analog begin $strobe(\"%#r\", 1.5); I(p) <+ V(p); end", .code = .E0825 },
        // #42: §9.4.2's `%%` takes no flag, width or precision (E0826),
        // and the refused `%-%` consumes nothing (no E0810 beside it).
        .{ .src = "analog begin $strobe(\"%5%\"); I(p) <+ V(p); end", .code = .E0826 },
        .{ .src = "analog begin $strobe(\"%-%%d\", 1); I(p) <+ V(p); end", .code = .E0826 },
        .{ .src = "analog begin $strobe(\"%#%\"); I(p) <+ V(p); end", .code = .E0826 },
        // #45: a width or precision of 2^30 = 1073741824 is the limit
        // (`max_format_field`); one more, or one that overflows a u64, is
        // E0828, never the unchecked arithmetic codegen used to reach.
        .{ .src = "analog begin $strobe(\"%1073741824d|%10.1073741824f\", 1, 1.5); I(p) <+ V(p); end", .code = null },
        .{ .src = "analog begin $strobe(\"%1073741825d\", 1); I(p) <+ V(p); end", .code = .E0828 },
        .{ .src = "analog begin $strobe(\"%.1073741825f\", 1.5); I(p) <+ V(p); end", .code = .E0828 },
        .{ .src = "analog begin $strobe(\"%-099999999999999999999999e\", 1.5); I(p) <+ V(p); end", .code = .E0828 },
        // §9.5.3: `$swrite` writes into a string variable.
        .{ .src = "analog begin $swrite(x, \"a\"); I(p) <+ V(p); end", .code = .E0813 },
        // §9.5.4.2's six conversion codes, and nothing else.
        .{ .src = "analog begin iv = $sscanf(\"1\", \"%q\", r); I(p) <+ V(p); end", .code = .E0813 },
        .{ .src = "analog begin iv = $sscanf(\"1\", \"%d\", r); I(p) <+ V(p) * r; end", .code = null },
        // §9.7.2 "The $stop task shall not be used within an analog initial block."
        .{ .src = "analog initial begin $stop; end\nanalog I(p) <+ V(p);", .code = .E0807 },
    });
}
