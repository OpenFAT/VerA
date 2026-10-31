//! What a MIR `call` calls: a callee name in, a `Callee` out. Every name
//! lowering can emit is a tag whose `@tagName` is the spelling (`.@"$vt"`,
//! `.@"$limit$old"`); consumers switch on it instead of comparing strings.
//! `.systf` is any unlisted name: a §2.8.3 user system function (§12.32) or a
//! typo W0852 reports; such a call keeps its raw name in
//! `Mir.InstData.call.name`. `Mir.emitCall` mints it. The per-callee facts
//! are `callee_table.zig`'s, re-exported here.
//!
//! Cites: §2.8.3, §2.9, §4.5, §4.5.3, §4.5.4, §4.5.7, §4.5.13, §4.5.14, §4.6,
//! §4.6.3, §4.6.4, §5.10, §5.10.2, §9.4, §9.5, §9.5.3, §9.7, §9.10, §9.11,
//! §9.12, §9.13, §9.14, §9.15, §9.17, §9.18, §9.19, §9.21, §12.22.2, §12.32,
//! §3.3; IEEE 1364-2005 §5.4, §5.5, §7.3.1, §17.10.2, §17.11.
//!
//! Contents:
//! - `pub const Callee = enum(u8)`, `Callee.fromName(name: []const u8) Callee`, `Callee.synthetic(c: Callee) bool`
//! - `pub const Ty`, `pub const Arity`, `pub const Family`, `pub const Info`, `pub const table`
//! - `pub const ty`, `pub const arity`, `pub const fdArg`, `pub const family`,
//!   `pub const isFileCall`, `pub const takesFormat`, `pub const opKind`

const std = @import("std");
const assert = std.debug.assert;
const facts = @import("callee_table.zig");

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

    /// Returns the callee a source or synthetic spelling names; `.systf`
    /// for any name not listed above.
    pub fn fromName(name: []const u8) Callee {
        const c = by_name.get(name) orelse return .systf;
        assert(c != .systf);
        assert(std.mem.eql(u8, @tagName(c), name));
        return c;
    }

    /// Returns whether `c` is a spelling lowering mints for its own rewrites
    /// (`$held_int` through `$systf$out`, in declaration order), never a
    /// §2.8.3 source name: a source call that spells one is refused (E1014),
    /// since its facts assume lowering's arguments. The synthetic spellings
    /// before `$held_int` (`idt$hold`, `op$static`, `absdelay$quad`) are not
    /// `$` names, so no system call can spell them.
    pub fn synthetic(c: Callee) bool {
        const s = @backingInt(c) >= @backingInt(Callee.@"$held_int") and c != .systf;
        if (s) assert(@tagName(c)[0] == '$');
        return s;
    }
};

/// A call's value type (`callee_table.Ty`).
pub const Ty = facts.Ty;
/// A source call's argument count range (`callee_table.Arity`).
pub const Arity = facts.Arity;
/// The §9.4/§9.5/§9.7 task family (`callee_table.Family`).
pub const Family = facts.Family;
/// One row of the per-callee fact table (`callee_table.Info`).
pub const Info = facts.Info;
/// Per-callee facts, total over `Callee` (`callee_table.table`).
pub const table = facts.table;
/// Returns the value type of a call.
pub const ty = facts.ty;
/// Returns the argument count a source call may carry.
pub const arity = facts.arity;
/// Returns the descriptor argument's position, or null.
pub const fdArg = facts.fdArg;
/// Returns the §9.4/§9.5/§9.7 task family.
pub const family = facts.family;
/// Returns whether a callee is a §9.5 descriptor spelling.
pub const isFileCall = facts.isFileCall;
/// Returns whether §9.4.3's format rule covers a callee.
pub const takesFormat = facts.takesFormat;
/// Returns the §4.5 operator, §5.10.3 event or §9.17 task a callee is.
pub const opKind = facts.opKind;

const by_name = std.StaticStringMap(Callee).initComptime(blk: {
    const e = @typeInfo(Callee).@"enum";
    const n = e.field_names.len;
    // The last field is `.systf`, `fromName`'s fallback, which no name spells.
    assert(std.mem.eql(u8, e.field_names[n - 1], "systf"));
    var kvs: [n - 1]struct { []const u8, Callee } = undefined;
    for (e.field_names[0 .. n - 1], e.field_values[0 .. n - 1], &kvs) |name, value, *kv| kv.* = .{ name, @fromBackingInt(@intCast(value)) };
    break :blk kvs;
});

comptime {
    assert(@sizeOf(Callee) == 1);
    assert(@backingInt(Callee.@"$held_int") < @backingInt(Callee.systf)); // `synthetic`'s range
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

test {
    _ = facts;
}
