//! Call-argument facts the slice planner (`plan/unit.zig`) and the emitter
//! share: which arguments are values, and the §9.4 display mode that
//! decides some of them. Callee in, answer out. The literal-string fact the
//! setup tiers read too is `prove.strArg`. Clauses: §3.3, §4.5, §4.5.14,
//! §5.10.3, §9.4, §9.5, §9.7.3, §9.13, §9.15.

const std = @import("std");
const Mir = @import("ir").Mir;
const op = @import("ir").op;

/// What to do with the §9.4 display tasks a model contains.
///
/// A device runs in the solver's inner loop, on a batch, sometimes on a GPU,
/// where a print is a per-iteration syscall or does not compile at all
/// (SPIR-V/PTX), so a device never prints. `.record` (a device's default)
/// gives it `say` instead: one entry point, outside `eval`, that a host calls
/// at an accepted point and that records each display task it runs as a
/// site index and its numeric values in a host-lent `contract.Say`
/// (`contract.SaySite`); what cannot be recorded is told so (W0850). `.drop`
/// is a device without that entry point, every task void (W0850). `.emit` is
/// the runnable testbench (`--emit-exe`, tb.zig), where the text is the point.
pub const Display = enum { drop, record, emit };

/// Is argument `i` of this call rendered as a value the calling unit must
/// compute? The others are consumed at codegen time: analysis names (§4.6.1),
/// operator control constants (§4.5), the operator input (its own unit
/// recomputes it), and the operands of ch9 tasks that answer from `Instance`
/// or a constant. Must stay in step with `emitCall`: slicing in an argument it
/// never renders declares an unread local (a Zig error), and missing one it
/// renders leaves an undefined leaf (`S.con(0.0)` in a print).
pub fn callArgIsValue(c: Mir.Callee, i: usize, display: Display) bool {
    return switch (c) {
        // The §5.10.3 `enable` is the exception: it is a live expression the
        // event test reads every evaluation, so it needs a slot like any other
        // operand.
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
        .@"$bound_step",
        .@"$discontinuity",
        => (op.enableArg(Mir.callee.opKind(c)) orelse return false) == i,
        // §5.10.3.3 a latest period participates in the event condition too.
        .timer => i == 1 or i == 3,
        // §9.4.1/§9.7.3 the printing tasks: rendered by a printing artifact,
        // and recorded by a device's `say` (`contract.SaySite`)...
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
        .@"$debug",
        .@"$warning",
        .@"$info",
        => display != .drop,
        // ...except a monitor, whose change detection a device does not
        // keep, and the two §9.7.3 tasks a device reports as a status.
        .@"$monitor",
        .@"$fatal",
        .@"$error",
        => display == .emit,
        // §9.5 every operand is live: the path, the type, the descriptor, the
        // control string, the offset. `emitCall` renders them all, in the
        // display unit because the kernels take them and in every other unit
        // through `emitFileCallDropped`, so this answer is one rule.
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
        => display == .emit,
        .@"$rng$check" => i != 1, // prior effect and checked values
        // The automatic-seed site's index is consumed by the emitter, not at
        // runtime.
        .@"$rng$auto" => false,
        // A live variate/Next call reads its seed and numeric parameters.
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
        => true,
        .@"$idx", .@"$idx$int", .@"$idx$str" => i > 0, // index and selectable cells
        // IEEE 1364 §5.4 the operands; argument 0 is the tree's root, which
        // the emitter reads (`codegen/wide.zig`).
        .@"$wide", .@"$wide$int" => i > 0,
        // §3.3 Table 3-3: every piece, and the count.
        .@"$str$cat", .@"$str$repeat" => true,
        // §9.5.4.2 `str` "shall be a string variable, string parameter or a
        // string literal", and the format is a string expression too:
        // `gen_render.emitScan` renders the source, the format and the item
        // index, so a computed one (a `$fgets` line, a phi) must be sliced in.
        .@"$sscanf", .@"$sscanf$int", .@"$sscanf$real", .@"$sscanf$str" => true,
        .@"$limit$uf" => i < 2,
        // §9.4.3 the operand a `%d` or radix field prints (`emitCall` renders
        // it); argument 1 (and 2) are lowering's width record, read at
        // codegen time.
        .@"$display$width" => i == 0,
        // §9.15's param_name may be "a string variable", so `emitCall` renders
        // it and the unit has to compute it.
        .@"$simparam$str" => i == 0,
        .ddx, .limexp => i == 0,
        .@"$vt", .@"$limit", .@"$clog2", .@"$rtoi", .@"$itor" => i == 0,
        // §12.32 a user system function's arguments, and §12.22.2 the
        // call an output argument is read back from: `emitSystfCall` and
        // `emitSystfOut` render every one, and the call itself must be one
        // value so its calltf runs once per evaluation.
        .systf,
        .@"$systf$out",
        // IEEE 1364 §17.11 math: every operand.
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
        => true,
        // Events, noise, analysis names; and every task that answers from
        // `Instance`, `Model` or a constant, or reads its operands itself.
        .initial_step,
        .final_step,
        .analog_initial,
        .@"op$static",
        .analysis,
        .ac_stim,
        .white_noise,
        .flicker_noise,
        .noise_table,
        .noise_table_log,
        .@"$temperature",
        .@"$mfactor",
        .@"$abstime",
        .@"$realtime",
        .@"$simparam",
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
        .@"$realtobits",
        .@"$bitstoreal",
        .@"$monitoron",
        .@"$monitoroff",
        .@"$finish",
        .@"$stop",
        .@"$sformat",
        .@"$sformat$rt",
        .@"$table_model",
        .@"$vera_reject_step",
        .@"$held_int",
        .@"$held_real",
        .@"$held_str",
        .@"$held_wide",
        .@"$tp_hit",
        .@"$tp_int",
        .@"$tp_real",
        .@"$tp_wide",
        .@"$limit$old",
        .@"$monitor$arm",
        .@"$plusarg$str",
        => false,
    };
}

test "callArgIsValue: the display-gated prongs are the printing and §9.5 families" {
    // Only the §9.4.1/§9.7.3 printing tasks and the §9.5 family answer
    // differently under `.emit` and `.drop`; that is how `emitCall` gates them.
    for (std.meta.tags(Mir.Callee)) |c| {
        const want = Mir.callee.family(c) == .display or Mir.callee.isFileCall(c);
        try std.testing.expectEqual(want, callArgIsValue(c, 5, .emit) and !callArgIsValue(c, 5, .drop));
    }
    // `.record` keeps what a device's `say` records, and none of the §9.5
    // family, `$monitor` or the §9.7.3 status pair.
    try std.testing.expect(callArgIsValue(.@"$strobe", 0, .record));
    try std.testing.expect(callArgIsValue(.@"$warning", 0, .record));
    for ([_]Mir.Callee{ .@"$monitor", .@"$fatal", .@"$error", .@"$fdisplay" }) |c|
        try std.testing.expect(!callArgIsValue(c, 0, .record));
}

test "callArgIsValue: an event operator keeps only its enable (and a timer its period) live" {
    const t = std.testing;
    // For every position up to one past the longest list, exactly the
    // positions the clause makes a runtime expression answer true.
    for (0..6) |i| {
        try t.expectEqual(i == 4, callArgIsValue(.cross, i, .drop));
        try t.expectEqual(i == 3, callArgIsValue(.above, i, .drop));
        // §5.10.3.3 "the next event will be scheduled based on the LATEST
        // value of the start_time and period": the period is live too.
        try t.expectEqual(i == 1 or i == 3, callArgIsValue(.timer, i, .drop));
        // §4.5.8 has no enable, and its input is its own unit's.
        try t.expect(!callArgIsValue(.transition, i, .emit));
        // §4.5.14 `ddx(expr, probe)`: the probe names a lane, it is not a value.
        try t.expectEqual(i == 0, callArgIsValue(.ddx, i, .drop));
        // IEEE 1364 §17.11 math reads every operand.
        try t.expect(callArgIsValue(.@"$hypot", i, .drop));
    }
    // A checked draw's argument 1 is consumed by the emitter, the rest are live.
    try t.expect(callArgIsValue(.@"$rng$check", 0, .drop));
    try t.expect(!callArgIsValue(.@"$rng$check", 1, .drop));
    try t.expect(callArgIsValue(.@"$rng$check", 2, .drop));
    // A user `$limit` function reads its two leading operands.
    try t.expect(callArgIsValue(.@"$limit$uf", 1, .drop));
    try t.expect(!callArgIsValue(.@"$limit$uf", 2, .drop));
}
