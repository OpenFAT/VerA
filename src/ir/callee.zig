//! What a MIR `call` calls: every callee name lowering can emit, as an enum
//! whose tag is the spelling (`.@"$vt"`, `.@"$limit$old"`), plus per-callee
//! facts (`table`: type, arity, descriptor slot, task family). Consumers switch
//! on it instead of comparing strings. `.systf` is any unlisted name: a §2.8.3
//! user system function (§12.32) or a typo W0852 reports; such a call keeps
//! its raw name in `Mir.InstData.call.name`. `Mir.emitCall` mints it.
//!
//! LRM clauses this file's code cites: §2.9, §3.2, §3.3, §4.5, §4.5.3, §4.5.4,
//! §4.5.7, §4.5.13, §4.5.14, §4.6, §4.6.4, §5.10, §5.10.2, §5.10.3, §7.3.1, §9.4,
//! §9.4.1, §9.4.3, §9.5, §9.5.1, §9.5.2, §9.5.3, §9.5.4.1, §9.5.4.2, §9.5.5,
//! §9.5.6, §9.5.7, §9.5.8, §9.7, §9.7.1, §9.7.2, §9.7.3, §9.10, §9.11, §9.12, §9.13,
//! §9.14, §9.15, §9.17, §9.18, §9.19, §9.21, §12.22.2.
//! IEEE 1364-2005 clauses cited: §5.4, §5.5, §17.1, §17.10, §17.10.2, §17.11.

const std = @import("std");
const op = @import("op.zig");

/// Every callee lowering can emit; `@tagName` is the source or synthetic
/// spelling, so no second name table exists.
pub const Callee = enum(u8) {
    // §4.5 analog operators (Table 4-19) and §4.5.13/§4.5.14 limexp, ddx.
    // §4.5.3/§4.5.4 ddt and idt are unknowns of the host's
    // (`Lower.NodeKind.op_state`); their rows and values read these two.
    /// §4.5.4 `idt(x, ic, assert)`'s value, from (V(s), ic, assert): ic while
    /// assert is nonzero, else V(s) less the offset latched while it was.
    @"idt$hold",
    /// 1 in the static solve an operator's DC form keys on: dt = 0 outside a
    /// small-signal analysis (DC, IC, a transient's first point).
    @"op$static",
    idtmod,
    absdelay,
    transition,
    slew,
    last_crossing,
    laplace_zd,
    laplace_zp,
    laplace_nd,
    laplace_np,
    zi_zd,
    zi_zp,
    zi_nd,
    zi_np,
    limexp,
    ddx,
    // §5.10 events; `analog_initial` is VerA's §5.10.2 first-point flag.
    cross,
    above,
    timer,
    initial_step,
    final_step,
    analog_initial,
    // §4.6 analysis-dependent functions, §4.6.4 noise.
    analysis,
    ac_stim,
    white_noise,
    flicker_noise,
    noise_table,
    noise_table_log,
    // §9.10/§9.15/§9.18/§9.19 environment, simulator and module queries.
    @"$temperature",
    @"$vt",
    @"$mfactor",
    @"$abstime",
    @"$realtime",
    @"$simparam",
    @"$simparam$str",
    @"$param_given",
    @"$port_connected",
    @"$analog_node_alias",
    @"$analog_port_alias",
    @"$test$plusargs",
    @"$value$plusargs",
    @"$xposition",
    @"$yposition",
    @"$angle",
    @"$hflip",
    @"$vflip",
    // §9.11 conversions, §9.14 $clog2.
    @"$rtoi",
    @"$itor",
    @"$realtobits",
    @"$bitstoreal",
    /// Source arity one; MIR also carries the operand's self-determined width.
    @"$clog2",
    // IEEE 1364 §17.11 math, the `$` spellings of Table 4-14/4-15.
    @"$sqrt",
    @"$exp",
    @"$expm1",
    @"$ln",
    @"$ln1p",
    @"$log",
    @"$log10",
    @"$floor",
    @"$ceil",
    @"$sin",
    @"$cos",
    @"$tan",
    @"$asin",
    @"$acos",
    @"$atan",
    @"$sinh",
    @"$cosh",
    @"$tanh",
    @"$asinh",
    @"$acosh",
    @"$atanh",
    @"$pow",
    @"$hypot",
    @"$atan2",
    // §9.4 display, §9.7 simulation control and severity.
    @"$display",
    @"$displayb",
    @"$displayo",
    @"$displayh",
    @"$write",
    @"$writeb",
    @"$writeo",
    @"$writeh",
    @"$strobe",
    @"$strobeb",
    @"$strobeo",
    @"$strobeh",
    @"$monitor",
    @"$monitoron",
    @"$monitoroff",
    @"$debug",
    @"$fatal",
    @"$error",
    @"$warning",
    @"$info",
    @"$finish",
    @"$stop",
    // §9.5 files.
    @"$fopen",
    @"$fclose",
    @"$fflush",
    @"$fdisplay",
    @"$fwrite",
    @"$fstrobe",
    @"$fmonitor",
    @"$fdebug",
    @"$fgets",
    @"$fscanf",
    @"$ftell",
    @"$fseek",
    @"$rewind",
    @"$ferror",
    @"$feof",
    // §9.5.3/§9.5.4.2 strings.
    @"$sformat",
    @"$sscanf",
    // §9.17 limiting and step control, §9.21 table model.
    @"$bound_step",
    @"$discontinuity",
    // VerA's vendor task: reject the step being accepted and retry it ending
    // at the argument (`contract.UpdateResult.request_reject_at`).
    @"$vera_reject_step",
    @"$limit",
    @"$table_model",
    // VerA-synthetic: `absdelay` under `(* vera_interp = 2 *)`: the same
    // §4.5.7 operator and state, read by 3-point Lagrange interpolation.
    @"absdelay$quad",
    // VerA-synthetic: lowering's rewrites of one source call into several.
    @"$held_int",
    @"$held_real",
    @"$held_str",
    // VerA's `vera_timepoint` (§2.9, `Lowered.TpBlock`): is the cache of
    // statement b current, and slot k of it.
    @"$tp_hit",
    @"$tp_int",
    @"$tp_real",
    // IEEE 1364-2005 §5.4/§5.5 a `reg` wider than 32 bits the analog context
    // computes (`Lower.WideNode`, `analog/wide.zig`): the value of a sized
    // expression tree `(root, operands...)`, as the `reg`'s bits or (`$int`)
    // as the §7.3.1 integer a select reads; a held one's seed; and slot k of
    // `vera_timepoint` cache b.
    @"$wide",
    @"$wide$int",
    @"$held_wide",
    @"$tp_wide",
    @"$limit$old",
    @"$limit$uf",
    @"$idx",
    @"$idx$int",
    @"$idx$str",
    @"$display$width",
    @"$monitor$arm",
    @"$fgets$str",
    @"$ferror$str",
    @"$fscanf$int",
    @"$fscanf$real",
    @"$fscanf$str",
    @"$sscanf$int",
    @"$sscanf$real",
    @"$sscanf$str",
    // §9.5.3 `$sformat` whose format_string is a string variable: (format,
    // operands...), formatted at run time (`str_kernels.zSFormatRt`).
    @"$sformat$rt",
    // §9.12 / IEEE 1364 §17.10.2 `Lower.lowerValuePlusargs`: the first
    // matching plusarg, which `$sscanf$<ty>` then converts.
    @"$plusarg$str",
    // §3.3 Table 3-3 `Lower.lowerConcat`: a concatenation with a run-time
    // string operand (its operands, in order), and a replication whose
    // multiplier or string is known only at run time (count, string).
    @"$str$cat",
    @"$str$repeat",
    // §9.13 Table 9-10, as `Lower.lowerRandom` rewrites it: one kernel per
    // distribution, its `_next` seed write-back twin, and the seed latches.
    @"$rng$auto",
    @"$rng$check",
    @"$rng$rand",
    @"$rng$rand_next",
    @"$rng$i_uniform",
    @"$rng$i_uniform_next",
    @"$rng$uniform",
    @"$rng$uniform_next",
    @"$rng$normal",
    @"$rng$normal_next",
    @"$rng$exponential",
    @"$rng$exponential_next",
    @"$rng$poisson",
    @"$rng$poisson_next",
    @"$rng$chi_square",
    @"$rng$chi_square_next",
    @"$rng$t",
    @"$rng$t_next",
    @"$rng$erlang",
    @"$rng$erlang_next",
    // §12.22.2 `Lower.lowerSysTask`: argument j of a user system task call
    // that is a variable, read back after the call as the value its calltf
    // put there: (call, j, the call's arguments...).
    @"$systf$out",
    /// Any other name: a user system function. The raw name is the call's.
    systf,

    /// The callee a source or synthetic spelling names; `.systf` for any
    /// name not listed above.
    pub fn fromName(name: []const u8) Callee {
        return by_name.get(name) orelse .systf;
    }

    /// A spelling lowering mints for its own rewrites (`$held_int` through
    /// `$systf$out`, in declaration order), never a §2.8.3 source name: a
    /// source call that spells one is refused (E1014), since its facts assume
    /// lowering's arguments. The synthetic spellings before `$held_int`
    /// (`idt$hold`, `op$static`, `absdelay$quad`) are not `$` names, so no
    /// system call can spell them.
    pub fn synthetic(c: Callee) bool {
        return @backingInt(c) >= @backingInt(Callee.@"$held_int") and c != .systf;
    }
};

const by_name = std.StaticStringMap(Callee).initComptime(blk: {
    const e = @typeInfo(Callee).@"enum";
    const n = e.field_names.len;
    // The last field is `.systf`, `fromName`'s fallback, which no name spells.
    std.debug.assert(std.mem.eql(u8, e.field_names[n - 1], "systf"));
    var kvs: [n - 1]struct { []const u8, Callee } = undefined;
    for (e.field_names[0 .. n - 1], e.field_values[0 .. n - 1], &kvs) |name, value, *kv| kv.* = .{ name, @fromBackingInt(@intCast(value)) };
    break :blk kvs;
});

/// A call's value type, read by both lowering and analysis.
/// `analysis.VTy` is this type.
pub const Ty = enum(u8) {
    real,
    int,
    str,
    /// IEEE 1364-2005 §5.4 an integer of a width wider than §3.2's 32 bits:
    /// a `reg` the analog context computes (`Lower.WideNode`). Its width is
    /// the defining call's (`Analysis.wideWidth`).
    wide,
};

/// How many arguments a source call may carry, as its clause's syntax prints
/// them. `unchecked` is every row not listed: its arity is judged elsewhere
/// (the §9.13 distributions, §9.17, §9.21, the display family) or not at all.
const Arity = struct {
    min: u8 = 0,
    max: u8 = std.math.maxInt(u8),

    const unchecked: Arity = .{};
    /// Returns the arity that admits exactly `n` arguments.
    pub fn exactly(n: u8) Arity {
        return .{ .min = n, .max = n };
    }
    /// Returns whether a call with `n` arguments is in range.
    pub fn admits(a: Arity, n: usize) bool {
        // `max` at its type's ceiling is "no upper bound" (`unchecked`, an
        // open display list), not a count of 255 arguments.
        return n >= a.min and (a.max == std.math.maxInt(u8) or n <= a.max);
    }
};

/// The §9.4/§9.5/§9.7 task family a callee belongs to.
const Family = enum(u3) {
    none,
    /// §9.4.1 display and §9.7.3 severity tasks: their whole content is text on
    /// the simulator's output. Not `$monitoron`/`$monitoroff`, which toggle a
    /// mode rather than print.
    display,
    /// §9.7.1 `$finish` and §9.7.2 `$stop`: they act on the run, print only
    /// their Table 9-25 diagnostics, and take no §9.4.3 format.
    simctl,
    /// §9.5.2's output tasks and §9.5.1/§9.5.6 `$fclose`/`$fflush`: statements
    /// that take a descriptor and return nothing.
    file_out,
    /// The §9.5 functions that return a value; each moves descriptor state.
    file_func,
    /// The readers `Lower.lowerFileRead` splits out of `$fgets`, `$fscanf` and
    /// `$ferror`.
    file_read,
};

/// One row of `table`: the facts a consumer needs about a callee.
pub const Info = struct {
    /// Everything not listed is real: §9.14/§9.15 and every §4.5 operator.
    ty: Ty = .real,
    /// The argument count Syntax 9-2..9-9, 9-5 and Table 4-14 admit.
    args: Arity = .unchecked,
    /// §9.5.1/§9.5.2: the position of the multichannel or file descriptor
    /// ("a 32-bit integer"), so a real or a string there is not a descriptor.
    /// Null for a call that takes none.
    fd: ?u3 = null,
    /// The §9.4/§9.5/§9.7 task family, `.none` for everything else.
    family: Family = .none,
};

const display: Info = .{ .family = .display };

const one: Arity = .exactly(1);
const two: Arity = .exactly(2);

/// Per-callee facts; an unlisted callee gets `Info`'s defaults.
pub const table = std.EnumArray(Callee, Info).initDefault(.{}, .{
    .@"$param_given" = .{ .ty = .int },
    .@"$port_connected" = .{ .ty = .int },
    // §9.12 / IEEE 1364 §17.10: `$test$plusargs(string)`,
    // `$value$plusargs(user_string, variable)`.
    .@"$test$plusargs" = .{ .ty = .int, .args = one },
    .@"$value$plusargs" = .{ .ty = .int, .args = two },
    .@"$rtoi" = .{ .ty = .int, .args = one },
    .@"$itor" = .{ .args = one },
    .@"$bitstoreal" = .{ .args = one },
    .@"$clog2" = .{ .ty = .int, .args = one },
    // §9.14: "aliases of the analog math operators described in 4.3.1", so
    // Table 4-14's arity is theirs.
    .@"$sqrt" = .{ .args = one },
    .@"$exp" = .{ .args = one },
    .@"$expm1" = .{ .args = one },
    .@"$ln" = .{ .args = one },
    .@"$ln1p" = .{ .args = one },
    .@"$log" = .{ .args = one },
    .@"$log10" = .{ .args = one },
    .@"$floor" = .{ .args = one },
    .@"$ceil" = .{ .args = one },
    .@"$sin" = .{ .args = one },
    .@"$cos" = .{ .args = one },
    .@"$tan" = .{ .args = one },
    .@"$asin" = .{ .args = one },
    .@"$acos" = .{ .args = one },
    .@"$atan" = .{ .args = one },
    .@"$sinh" = .{ .args = one },
    .@"$cosh" = .{ .args = one },
    .@"$tanh" = .{ .args = one },
    .@"$asinh" = .{ .args = one },
    .@"$acosh" = .{ .args = one },
    .@"$atanh" = .{ .args = one },
    .@"$pow" = .{ .args = two },
    .@"$hypot" = .{ .args = two },
    .@"$atan2" = .{ .args = two },
    // Syntax 9-5 `$finish [ ( n ) ]`; §9.7.2 gives $stop the same shape.
    .@"$finish" = .{ .args = .{ .max = 1 }, .family = .simctl },
    .@"$stop" = .{ .args = .{ .max = 1 }, .family = .simctl },
    .@"$display" = display,
    .@"$displayb" = display,
    .@"$displayo" = display,
    .@"$displayh" = display,
    .@"$write" = display,
    .@"$writeb" = display,
    .@"$writeo" = display,
    .@"$writeh" = display,
    .@"$strobe" = display,
    .@"$strobeb" = display,
    .@"$strobeo" = display,
    .@"$strobeh" = display,
    .@"$monitor" = display,
    .@"$debug" = display,
    .@"$fatal" = display,
    .@"$error" = display,
    .@"$warning" = display,
    .@"$info" = display,
    // Syntax 9-2 and 9-3: `$fclose(fd)`, and every output task's first
    // argument is the descriptor.
    .@"$fclose" = .{ .args = one, .fd = 0, .family = .file_out },
    .@"$fdisplay" = .{ .args = .{ .min = 1 }, .fd = 0, .family = .file_out },
    .@"$fwrite" = .{ .args = .{ .min = 1 }, .fd = 0, .family = .file_out },
    .@"$fstrobe" = .{ .args = .{ .min = 1 }, .fd = 0, .family = .file_out },
    .@"$fmonitor" = .{ .args = .{ .min = 1 }, .fd = 0, .family = .file_out },
    .@"$fdebug" = .{ .args = .{ .min = 1 }, .fd = 0, .family = .file_out },
    // §9.5.6 `$fflush(mcd)`, `$fflush(fd)`, `$fflush()`.
    .@"$fflush" = .{ .args = .{ .max = 1 }, .fd = 0, .family = .file_out },
    // §9.11 Table 9-8: `$realtobits` yields the bit PATTERN (an integer),
    // `$bitstoreal` the real that pattern stands for (see
    // tests/conformance/tests/verilog-a/exhaustive/bit_conversions.va).
    .@"$realtobits" = .{ .ty = .int, .args = one },
    .@"$analog_node_alias" = .{ .ty = .int },
    .@"$analog_port_alias" = .{ .ty = .int },
    .@"$sscanf" = .{ .ty = .int },
    .@"$sscanf$int" = .{ .ty = .int },
    .@"$display$width" = .{ .ty = .int },
    .@"$idx$int" = .{ .ty = .int },
    // §5.10 `Lower.holdSlot`'s synthetic seed: the callee is chosen by the
    // variable's declared type, so the name IS the type.
    .@"$held_int" = .{ .ty = .int },
    .@"$held_str" = .{ .ty = .str },
    .@"$vera_reject_step" = .{ .args = one },
    .@"$tp_hit" = .{ .ty = .int },
    .@"$tp_int" = .{ .ty = .int },
    .@"$wide" = .{ .ty = .wide },
    .@"$wide$int" = .{ .ty = .int },
    .@"$held_wide" = .{ .ty = .wide },
    .@"$tp_wide" = .{ .ty = .wide },
    // §9.5: every descriptor function is integer-valued. The arities are
    // Syntax 9-2 (`$fopen(filename [, type])`) and the call shapes §9.5.4.1,
    // §9.5.4.2, §9.5.5, §9.5.7 and §9.5.8 print.
    .@"$fopen" = .{ .ty = .int, .args = .{ .min = 1, .max = 2 }, .family = .file_func },
    .@"$fgets" = .{ .ty = .int, .args = two, .fd = 1, .family = .file_func },
    .@"$fscanf" = .{ .ty = .int, .args = .{ .min = 2 }, .fd = 0, .family = .file_func },
    .@"$fscanf$int" = .{ .ty = .int, .family = .file_read },
    .@"$fscanf$real" = .{ .family = .file_read },
    .@"$ftell" = .{ .ty = .int, .args = one, .fd = 0, .family = .file_func },
    .@"$fseek" = .{ .ty = .int, .args = .exactly(3), .fd = 0, .family = .file_func },
    .@"$rewind" = .{ .ty = .int, .args = one, .fd = 0, .family = .file_func },
    .@"$ferror" = .{ .ty = .int, .args = two, .fd = 0, .family = .file_func },
    .@"$feof" = .{ .ty = .int, .args = one, .fd = 0, .family = .file_func },
    .@"$simparam$str" = .{ .ty = .str },
    .@"$sformat" = .{ .ty = .str },
    .@"$sformat$rt" = .{ .ty = .str },
    .@"$sscanf$str" = .{ .ty = .str },
    .@"$plusarg$str" = .{ .ty = .str },
    .@"$str$cat" = .{ .ty = .str },
    .@"$str$repeat" = .{ .ty = .str },
    .@"$idx$str" = .{ .ty = .str },
    .@"$fgets$str" = .{ .ty = .str, .family = .file_read },
    .@"$fscanf$str" = .{ .ty = .str, .family = .file_read },
    .@"$ferror$str" = .{ .ty = .str, .family = .file_read },
});

// Each row is self-consistent: an arity range is not empty, and a descriptor
// position names an argument a call can carry, of a §9.5 descriptor family.
comptime {
    std.debug.assert(@backingInt(Callee.@"$held_int") < @backingInt(Callee.systf)); // `synthetic`'s range
    for (table.values) |info| {
        std.debug.assert(info.args.min <= info.args.max);
        if (info.fd) |fd| {
            std.debug.assert(fd < info.args.max);
            std.debug.assert(info.family == .file_out or info.family == .file_func);
        }
    }
}

/// Returns the value type of a call to `c`.
pub fn ty(c: Callee) Ty {
    return table.getPtrConst(c).ty;
}

/// Returns the argument count a source call to `c` may carry.
pub fn arity(c: Callee) Arity {
    return table.getPtrConst(c).args;
}

/// Returns the descriptor argument's position, or null if `c` takes none.
pub fn fdArg(c: Callee) ?u3 {
    return table.getPtrConst(c).fd;
}

/// Returns the §9.4/§9.5/§9.7 task family of `c`.
pub fn family(c: Callee) Family {
    return table.getPtrConst(c).family;
}

/// §9.5: every descriptor spelling that reaches the emitter.
pub fn isFileCall(c: Callee) bool {
    return switch (family(c)) {
        .file_out, .file_func, .file_read => true,
        .none, .display, .simctl => false,
    };
}

/// §9.4.3's format rule covers the display tasks, and §9.5.2 defines the file
/// output tasks as "the same as their counterparts".
pub fn takesFormat(c: Callee) bool {
    return switch (family(c)) {
        .display, .file_out => true,
        .none, .simctl, .file_func, .file_read => false,
    };
}

/// Returns the §4.5 operator, §5.10.3 event or §9.17 task this callee is
/// (the unit `names.enumerateUnits` gives it), or `.none`. Written out with
/// no `else`, so a new callee must state whether it owns state.
pub fn opKind(c: Callee) op.OpKind {
    return switch (c) {
        .@"idt$hold" => .idt_hold,
        .idtmod => .idtmod,
        .absdelay, .@"absdelay$quad" => .absdelay,
        .transition => .transition,
        .slew => .slew,
        .last_crossing => .last_crossing,
        .cross => .cross,
        .above => .above,
        .timer => .timer,
        .@"$bound_step" => .bound_step,
        .@"$discontinuity" => .discontinuity,
        .laplace_zd, .laplace_zp, .laplace_nd, .laplace_np => .laplace,
        .zi_zd, .zi_zp, .zi_nd, .zi_np => .zi,
        // §4.5.13/§4.5.14 are pure (no state, no unit), and nothing else
        // here owns per-instance state or a monitored event.
        .limexp,
        .ddx,
        .@"op$static",
        .initial_step,
        .final_step,
        .analog_initial,
        .analysis,
        .ac_stim,
        .white_noise,
        .flicker_noise,
        .noise_table,
        .noise_table_log,
        .@"$temperature",
        .@"$vt",
        .@"$mfactor",
        .@"$abstime",
        .@"$realtime",
        .@"$simparam",
        .@"$simparam$str",
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
        .@"$held_int",
        .@"$held_real",
        .@"$held_str",
        .@"$tp_hit",
        .@"$tp_int",
        .@"$tp_real",
        .@"$wide",
        .@"$wide$int",
        .@"$held_wide",
        .@"$tp_wide",
        .@"$limit$old",
        .@"$limit$uf",
        .@"$idx",
        .@"$idx$int",
        .@"$idx$str",
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
        .@"$systf$out",
        .systf,
        => .none,
    };
}

test "a callee name round-trips; anything else is .systf" {
    for (std.meta.tags(Callee)) |c| {
        if (c == .systf) continue;
        try std.testing.expectEqual(c, Callee.fromName(@tagName(c)));
    }
    try std.testing.expectEqual(Callee.systf, Callee.fromName("$resistor"));
    try std.testing.expectEqual(Callee.systf, Callee.fromName("systf"));
    try std.testing.expectEqual(Ty.int, ty(.@"$held_int"));
    try std.testing.expectEqual(Ty.real, ty(.@"$held_real"));
    try std.testing.expectEqual(Ty.real, ty(.systf));
}

test "opKind: every stateful spelling maps to a kind, and the pure ones do not" {
    const names = [_][]const u8{
        "idt$hold",   "idtmod",        "absdelay",       "transition",
        "slew",       "last_crossing", "laplace_zd",     "laplace_zp",
        "laplace_nd", "laplace_np",    "zi_zd",          "zi_zp",
        "zi_nd",      "zi_np",         "cross",          "above",
        "timer",      "$bound_step",   "$discontinuity",
    };
    for (names) |n| try std.testing.expect(opKind(Callee.fromName(n)) != .none);

    // §4.5.13/§4.5.14 are pure and must NOT acquire a unit.
    for ([_][]const u8{ "limexp", "ddx", "V", "" }) |n|
        try std.testing.expectEqual(op.OpKind.none, opKind(Callee.fromName(n)));
}

test "Callee.synthetic: lowering's own `$` spellings, never an LRM name" {
    // E1014's text names these as VerA's own.
    for ([_]Callee{ .@"$held_real", .@"$idx", .@"$limit$old", .@"$str$cat", .@"$rng$auto", .@"$rng$erlang_next", .@"$systf$out" }) |c|
        try std.testing.expect(c.synthetic());
    // LRM spellings, some with an inner `$`, are not reserved; nor is the
    // catch-all, which is any name the user may register.
    for ([_]Callee{ .@"$simparam$str", .@"$test$plusargs", .@"$value$plusargs", .@"$limit", .@"$table_model", .@"$bound_step", .@"$display", .@"$vera_reject_step", .systf }) |c|
        try std.testing.expect(!c.synthetic());
    // E1014 is reported for a system call, so every reserved spelling must
    // be a `$` name or the refusal could never fire.
    for (std.enums.values(Callee)) |c| if (c.synthetic()) try std.testing.expectEqual('$', @tagName(c)[0]);
}

test "callee: the task families agree with the descriptor, format and operator facts" {
    for (std.enums.values(Callee)) |c| {
        errdefer std.debug.print("callee `{s}`\n", .{@tagName(c)});
        const info = table.getPtrConst(c).*;
        // §9.5.1/§9.5.2: only a file call has a descriptor argument.
        if (info.fd != null) try std.testing.expect(isFileCall(c));
        // §9.4.3 formats the display tasks; §9.5.2 makes the file output
        // tasks "the same as their counterparts".
        try std.testing.expectEqual(info.family == .display or info.family == .file_out, takesFormat(c));
        // A §4.5 operator, §5.10.3 event or §9.17 task is a real-valued call
        // outside every task family.
        if (opKind(c) != .none) {
            try std.testing.expectEqual(Ty.real, ty(c));
            try std.testing.expectEqual(Family.none, family(c));
        }
        try std.testing.expect(info.args.min <= info.args.max);
        try std.testing.expectEqual(info.args, arity(c));
        try std.testing.expectEqual(info.fd, fdArg(c));
    }
}

test "Arity.admits: the clause's counts, and no cap on an open list" {
    // Syntax 9-2: `$fopen(filename [, type])`.
    try std.testing.expect(!arity(.@"$fopen").admits(0));
    try std.testing.expect(arity(.@"$fopen").admits(1) and arity(.@"$fopen").admits(2));
    try std.testing.expect(!arity(.@"$fopen").admits(3));
    // §9.5.7 `$fseek(fd, offset, operation)`.
    try std.testing.expect(arity(.@"$fseek").admits(3) and !arity(.@"$fseek").admits(2));
    // Syntax 9-5 `$finish [ ( n ) ]`.
    try std.testing.expect(arity(.@"$finish").admits(0) and arity(.@"$finish").admits(1));
    try std.testing.expect(!arity(.@"$finish").admits(2));
    // A display or file output task takes any number of arguments (IEEE 1364
    // §17.1 bounds none), and neither does an unlisted user system function:
    // the u8 maximum is the "no upper bound" sentinel, not a count of 255.
    for ([_]Callee{ .@"$display", .@"$strobe", .@"$fdisplay", .@"$fwrite", .systf }) |c| {
        try std.testing.expect(arity(c).admits(255));
        try std.testing.expect(arity(c).admits(256));
        try std.testing.expect(arity(c).admits(100_000));
    }
    try std.testing.expect(!arity(.@"$fdisplay").admits(0)); // the descriptor is required
}

test "callee: spot facts the clauses state" {
    // §9.5.4.1 `$fgets(str, fd)`: the descriptor is the second argument.
    try std.testing.expectEqual(@as(?u3, 1), fdArg(.@"$fgets"));
    try std.testing.expectEqual(@as(?u3, 0), fdArg(.@"$fscanf"));
    try std.testing.expectEqual(@as(?u3, null), fdArg(.@"$fopen"));
    // §9.11 Table 9-8: `$realtobits` is an integer pattern, `$bitstoreal` a real.
    try std.testing.expectEqual(Ty.int, ty(.@"$realtobits"));
    try std.testing.expectEqual(Ty.real, ty(.@"$bitstoreal"));
    try std.testing.expectEqual(Ty.str, ty(.@"$sformat"));
    // §9.7.1/§9.7.2 act on the run; `$monitoron` toggles a mode, prints nothing.
    try std.testing.expectEqual(Family.simctl, family(.@"$finish"));
    try std.testing.expectEqual(Family.none, family(.@"$monitoron"));
    try std.testing.expect(!takesFormat(.@"$fopen") and isFileCall(.@"$fopen"));
    try std.testing.expect(!isFileCall(.@"$display"));
    // `absdelay$quad` is the same §4.5.7 operator, so it shares the unit kind.
    try std.testing.expectEqual(op.OpKind.absdelay, opKind(.@"absdelay$quad"));
}
