//! Per-callee facts: a `Callee` in, its value type, source arity,
//! descriptor position, §9.4/§9.5/§9.7 task family and §4.5/§5.10.3/§9.17
//! operator kind out. `table` is built with `std.EnumArray.init`, so a new
//! callee does not compile until its row exists, and every row names its
//! type and whether it owns state (`op`): neither has a default.
//!
//! Cites: §2.9, §3.2, §3.3, §4.5, §4.5.3, §4.5.4, §4.5.7, §4.5.13, §4.5.14,
//! §4.6, §4.6.4, §5.10, §5.10.2, §5.10.3, §9.4, §9.4.1, §9.4.3, §9.5,
//! §9.5.1, §9.5.2, §9.5.3, §9.5.4.1, §9.5.4.2, §9.5.5, §9.5.6, §9.5.7,
//! §9.5.8, §9.7, §9.7.1, §9.7.2, §9.7.3, §9.10, §9.11, §9.12, §9.13, §9.14,
//! §9.15, §9.17, §9.18, §9.19, §9.21, §12.22.2; IEEE 1364-2005 §5.4, §5.5,
//! §17.1, §17.10, §17.10.2, §17.11.
//!
//! Contents:
//! - `pub const Ty = enum(u8)`
//! - `pub const Arity = struct`, `Arity.unchecked`, `Arity.exactly(n: u8) Arity`, `Arity.admits(a: Arity, n: usize) bool`
//! - `pub const Family = enum(u8)`
//! - `pub const Info = struct`
//! - `pub const table: std.EnumArray(Callee, Info)`
//! - `pub fn ty(c: Callee) Ty`
//! - `pub fn arity(c: Callee) Arity`
//! - `pub fn fdArg(c: Callee) ?u3`
//! - `pub fn family(c: Callee) Family`
//! - `pub fn isFileCall(c: Callee) bool`
//! - `pub fn takesFormat(c: Callee) bool`
//! - `pub fn opKind(c: Callee) OpKind`

const std = @import("std");
const assert = std.debug.assert;
const Callee = @import("callee.zig").Callee;
const OpKind = @import("op.zig").OpKind;

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
/// them. `unchecked` is every row whose arity is judged elsewhere (the §9.13
/// distributions, §9.17, §9.21, the display family) or not at all.
/// Invariant: `min <= max`; `max` at its type's ceiling means "no upper bound".
pub const Arity = struct {
    min: u8 = 0,
    max: u8 = std.math.maxInt(u8),

    /// Any number of arguments.
    pub const unchecked: Arity = .{};

    /// Returns the arity that admits exactly `n` arguments.
    pub fn exactly(n: u8) Arity {
        assert(n < std.math.maxInt(u8)); // the ceiling means "unbounded"
        return .{ .min = n, .max = n };
    }

    /// Returns whether a call with `n` arguments is in range.
    pub fn admits(a: Arity, n: usize) bool {
        assert(a.min <= a.max);
        // `max` at its type's ceiling is "no upper bound" (`unchecked`, an
        // open display list), not a count of 255 arguments.
        return n >= a.min and (a.max == std.math.maxInt(u8) or n <= a.max);
    }
};

/// The §9.4/§9.5/§9.7 task family a callee belongs to.
pub const Family = enum(u8) {
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
    /// The call's value type.
    ty: Ty,
    /// The §4.5 operator, §5.10.3 event or §9.17 task this callee is (the
    /// unit `names.enumerateUnits` gives it), or `.none`.
    op: OpKind,
    /// The argument count Syntax 9-2..9-9, 9-5 and Table 4-14 admit.
    args: Arity = .unchecked,
    /// §9.5.1/§9.5.2: the position of the multichannel or file descriptor
    /// ("a 32-bit integer"), so a real or a string there is not a descriptor.
    /// Null for a call that takes none.
    fd: ?u3 = null,
    /// The §9.4/§9.5/§9.7 task family, `.none` for everything else.
    family: Family = .none,
};

/// Per-callee facts, total over `Callee`.
pub const table = std.EnumArray(Callee, Info).init(.{
    // §4.5 analog operators (Table 4-19): each owns per-instance state, so
    // `names.enumerateUnits` gives each occurrence a unit. §4.5.13 `limexp`
    // and §4.5.14 `ddx` are pure functions of their argument: no state, no unit.
    .@"idt$hold" = stateful(.idt_hold),
    .@"op$static" = real,
    .idtmod = stateful(.idtmod),
    .absdelay = stateful(.absdelay),
    .transition = stateful(.transition),
    .slew = stateful(.slew),
    .last_crossing = stateful(.last_crossing),
    .laplace_zd = stateful(.laplace),
    .laplace_zp = stateful(.laplace),
    .laplace_nd = stateful(.laplace),
    .laplace_np = stateful(.laplace),
    .zi_zd = stateful(.zi),
    .zi_zp = stateful(.zi),
    .zi_nd = stateful(.zi),
    .zi_np = stateful(.zi),
    .limexp = real,
    .ddx = real,
    // §5.10.3 monitored events; `analog_initial` is VerA's §5.10.2 first-point flag.
    .cross = stateful(.cross),
    .above = stateful(.above),
    .timer = stateful(.timer),
    .initial_step = real,
    .final_step = real,
    .analog_initial = real,
    // §4.6 analysis-dependent functions, §4.6.4 noise.
    .analysis = real,
    .ac_stim = real,
    .white_noise = real,
    .flicker_noise = real,
    .noise_table = real,
    .noise_table_log = real,
    // §9.10/§9.15/§9.18/§9.19 environment, simulator and module queries.
    .@"$temperature" = real,
    .@"$vt" = real,
    .@"$mfactor" = real,
    .@"$abstime" = real,
    .@"$realtime" = real,
    .@"$simparam" = real,
    .@"$simparam$str" = str,
    .@"$param_given" = int,
    .@"$port_connected" = int,
    .@"$analog_node_alias" = int,
    .@"$analog_port_alias" = int,
    // §9.12 / IEEE 1364 §17.10: `$test$plusargs(string)`,
    // `$value$plusargs(user_string, variable)`.
    .@"$test$plusargs" = .{ .ty = .int, .op = .none, .args = one },
    .@"$value$plusargs" = .{ .ty = .int, .op = .none, .args = two },
    .@"$xposition" = real,
    .@"$yposition" = real,
    .@"$angle" = real,
    .@"$hflip" = real,
    .@"$vflip" = real,
    // §9.11 conversions, §9.14 $clog2. Table 9-8: `$realtobits` yields the bit
    // PATTERN (an integer), `$bitstoreal` the real that pattern stands for (see
    // tests/conformance/tests/verilog-a/exhaustive/bit_conversions.va).
    .@"$rtoi" = .{ .ty = .int, .op = .none, .args = one },
    .@"$itor" = .{ .ty = .real, .op = .none, .args = one },
    .@"$realtobits" = .{ .ty = .int, .op = .none, .args = one },
    .@"$bitstoreal" = .{ .ty = .real, .op = .none, .args = one },
    .@"$clog2" = .{ .ty = .int, .op = .none, .args = one },
    // IEEE 1364 §17.11 math, the `$` spellings of Table 4-14/4-15. §9.14:
    // "aliases of the analog math operators described in 4.3.1", so Table
    // 4-14's arity is theirs.
    .@"$sqrt" = .{ .ty = .real, .op = .none, .args = one },
    .@"$exp" = .{ .ty = .real, .op = .none, .args = one },
    .@"$expm1" = .{ .ty = .real, .op = .none, .args = one },
    .@"$ln" = .{ .ty = .real, .op = .none, .args = one },
    .@"$ln1p" = .{ .ty = .real, .op = .none, .args = one },
    .@"$log" = .{ .ty = .real, .op = .none, .args = one },
    .@"$log10" = .{ .ty = .real, .op = .none, .args = one },
    .@"$floor" = .{ .ty = .real, .op = .none, .args = one },
    .@"$ceil" = .{ .ty = .real, .op = .none, .args = one },
    .@"$sin" = .{ .ty = .real, .op = .none, .args = one },
    .@"$cos" = .{ .ty = .real, .op = .none, .args = one },
    .@"$tan" = .{ .ty = .real, .op = .none, .args = one },
    .@"$asin" = .{ .ty = .real, .op = .none, .args = one },
    .@"$acos" = .{ .ty = .real, .op = .none, .args = one },
    .@"$atan" = .{ .ty = .real, .op = .none, .args = one },
    .@"$sinh" = .{ .ty = .real, .op = .none, .args = one },
    .@"$cosh" = .{ .ty = .real, .op = .none, .args = one },
    .@"$tanh" = .{ .ty = .real, .op = .none, .args = one },
    .@"$asinh" = .{ .ty = .real, .op = .none, .args = one },
    .@"$acosh" = .{ .ty = .real, .op = .none, .args = one },
    .@"$atanh" = .{ .ty = .real, .op = .none, .args = one },
    .@"$pow" = .{ .ty = .real, .op = .none, .args = two },
    .@"$hypot" = .{ .ty = .real, .op = .none, .args = two },
    .@"$atan2" = .{ .ty = .real, .op = .none, .args = two },
    // §9.4 display, §9.7 simulation control and severity. Syntax 9-5
    // `$finish [ ( n ) ]`; §9.7.2 gives $stop the same shape.
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
    .@"$monitoron" = real,
    .@"$monitoroff" = real,
    .@"$debug" = display,
    .@"$fatal" = display,
    .@"$error" = display,
    .@"$warning" = display,
    .@"$info" = display,
    .@"$finish" = .{ .ty = .real, .op = .none, .args = .{ .max = 1 }, .family = .simctl },
    .@"$stop" = .{ .ty = .real, .op = .none, .args = .{ .max = 1 }, .family = .simctl },
    // §9.5 files: every descriptor function is integer-valued. Syntax 9-2
    // (`$fopen(filename [, type])`, `$fclose(fd)`), Syntax 9-3 (every output
    // task's first argument is the descriptor), §9.5.6 `$fflush(mcd)`,
    // `$fflush(fd)`, `$fflush()`, and the call shapes §9.5.4.1, §9.5.4.2,
    // §9.5.5, §9.5.7 and §9.5.8 print.
    .@"$fopen" = .{ .ty = .int, .op = .none, .args = .{ .min = 1, .max = 2 }, .family = .file_func },
    .@"$fclose" = .{ .ty = .real, .op = .none, .args = one, .fd = 0, .family = .file_out },
    .@"$fflush" = .{ .ty = .real, .op = .none, .args = .{ .max = 1 }, .fd = 0, .family = .file_out },
    .@"$fdisplay" = .{ .ty = .real, .op = .none, .args = .{ .min = 1 }, .fd = 0, .family = .file_out },
    .@"$fwrite" = .{ .ty = .real, .op = .none, .args = .{ .min = 1 }, .fd = 0, .family = .file_out },
    .@"$fstrobe" = .{ .ty = .real, .op = .none, .args = .{ .min = 1 }, .fd = 0, .family = .file_out },
    .@"$fmonitor" = .{ .ty = .real, .op = .none, .args = .{ .min = 1 }, .fd = 0, .family = .file_out },
    .@"$fdebug" = .{ .ty = .real, .op = .none, .args = .{ .min = 1 }, .fd = 0, .family = .file_out },
    .@"$fgets" = .{ .ty = .int, .op = .none, .args = two, .fd = 1, .family = .file_func },
    .@"$fscanf" = .{ .ty = .int, .op = .none, .args = .{ .min = 2 }, .fd = 0, .family = .file_func },
    .@"$ftell" = .{ .ty = .int, .op = .none, .args = one, .fd = 0, .family = .file_func },
    .@"$fseek" = .{ .ty = .int, .op = .none, .args = .exactly(3), .fd = 0, .family = .file_func },
    .@"$rewind" = .{ .ty = .int, .op = .none, .args = one, .fd = 0, .family = .file_func },
    .@"$ferror" = .{ .ty = .int, .op = .none, .args = two, .fd = 0, .family = .file_func },
    .@"$feof" = .{ .ty = .int, .op = .none, .args = one, .fd = 0, .family = .file_func },
    // §9.5.3/§9.5.4.2 strings.
    .@"$sformat" = str,
    .@"$sscanf" = int,
    // §9.17 limiting and step control, §9.21 table model; `$vera_reject_step`
    // is VerA's vendor task (`contract.UpdateResult.request_reject_at`).
    .@"$bound_step" = stateful(.bound_step),
    .@"$discontinuity" = stateful(.discontinuity),
    .@"$vera_reject_step" = .{ .ty = .real, .op = .none, .args = one },
    .@"$limit" = real,
    .@"$table_model" = real,
    // VerA-synthetic: `absdelay` under `(* vera_interp = 2 *)`, the same
    // §4.5.7 operator and state, read by 3-point Lagrange interpolation.
    .@"absdelay$quad" = stateful(.absdelay),
    // VerA-synthetic: lowering's rewrites of one source call into several
    // (`Callee.synthetic`). §5.10 `Lower.holdSlot`'s seed is chosen by the
    // variable's declared type, so the name IS the type; `$tp_*` read a
    // `vera_timepoint` cache, `$wide*` an IEEE 1364-2005 §5.4/§5.5 `reg`
    // wider than 32 bits.
    .@"$held_int" = int,
    .@"$held_real" = real,
    .@"$held_str" = str,
    .@"$tp_hit" = int,
    .@"$tp_int" = int,
    .@"$tp_real" = real,
    .@"$wide" = wide,
    .@"$wide$int" = int,
    .@"$held_wide" = wide,
    .@"$tp_wide" = wide,
    .@"$limit$old" = real,
    .@"$limit$uf" = real,
    .@"$idx" = real,
    .@"$idx$int" = int,
    .@"$idx$str" = str,
    .@"$display$width" = int,
    .@"$monitor$arm" = real,
    .@"$fgets$str" = .{ .ty = .str, .op = .none, .family = .file_read },
    .@"$ferror$str" = .{ .ty = .str, .op = .none, .family = .file_read },
    .@"$fscanf$int" = .{ .ty = .int, .op = .none, .family = .file_read },
    .@"$fscanf$real" = .{ .ty = .real, .op = .none, .family = .file_read },
    .@"$fscanf$str" = .{ .ty = .str, .op = .none, .family = .file_read },
    .@"$sscanf$int" = int,
    .@"$sscanf$real" = real,
    .@"$sscanf$str" = str,
    .@"$sformat$rt" = str,
    .@"$plusarg$str" = str,
    .@"$str$cat" = str,
    .@"$str$repeat" = str,
    .@"$rng$auto" = real,
    .@"$rng$check" = real,
    .@"$rng$rand" = real,
    .@"$rng$rand_next" = real,
    .@"$rng$i_uniform" = real,
    .@"$rng$i_uniform_next" = real,
    .@"$rng$uniform" = real,
    .@"$rng$uniform_next" = real,
    .@"$rng$normal" = real,
    .@"$rng$normal_next" = real,
    .@"$rng$exponential" = real,
    .@"$rng$exponential_next" = real,
    .@"$rng$poisson" = real,
    .@"$rng$poisson_next" = real,
    .@"$rng$chi_square" = real,
    .@"$rng$chi_square_next" = real,
    .@"$rng$t" = real,
    .@"$rng$t_next" = real,
    .@"$rng$erlang" = real,
    .@"$rng$erlang_next" = real,
    .@"$systf$out" = real,
    .systf = real,
});

// Row shorthands: every row still names its type and its operator kind.
const real: Info = .{ .ty = .real, .op = .none };
const int: Info = .{ .ty = .int, .op = .none };
const str: Info = .{ .ty = .str, .op = .none };
const wide: Info = .{ .ty = .wide, .op = .none };
const display: Info = .{ .ty = .real, .op = .none, .family = .display };
const one: Arity = .exactly(1);
const two: Arity = .exactly(2);

// Each row is self-consistent: an arity range is not empty, a descriptor
// position names an argument a call can carry, of a §9.5 descriptor family,
// and a §4.5 operator, §5.10.3 event or §9.17 task is a real-valued call
// outside every task family.
comptime {
    @setEvalBranchQuota(20_000);
    for (table.values) |info| {
        assert(info.args.min <= info.args.max);
        if (info.fd) |fd| {
            assert(fd < info.args.max);
            assert(info.family == .file_out or info.family == .file_func);
        }
        if (info.op != .none) {
            assert(info.ty == .real);
            assert(info.family == .none);
        }
    }
}

/// Returns the value type of a call to `c`.
pub fn ty(c: Callee) Ty {
    const t = table.getPtrConst(c).ty;
    if (opKind(c) != .none) assert(t == .real);
    return t;
}

/// Returns the argument count a source call to `c` may carry.
pub fn arity(c: Callee) Arity {
    const a = table.getPtrConst(c).args;
    assert(a.min <= a.max);
    return a;
}

/// Returns the descriptor argument's position, or null if `c` takes none.
pub fn fdArg(c: Callee) ?u3 {
    const fd = table.getPtrConst(c).fd orelse return null;
    assert(isFileCall(c));
    return fd;
}

/// Returns the §9.4/§9.5/§9.7 task family of `c`.
pub fn family(c: Callee) Family {
    return table.getPtrConst(c).family;
}

/// Returns whether `c` is a §9.5 descriptor spelling that reaches the emitter.
pub fn isFileCall(c: Callee) bool {
    return switch (family(c)) {
        .file_out, .file_func, .file_read => true,
        .none, .display, .simctl => false,
    };
}

/// Returns whether §9.4.3's format rule covers `c`: the display tasks, and
/// the file output tasks §9.5.2 defines as "the same as their counterparts".
pub fn takesFormat(c: Callee) bool {
    return switch (family(c)) {
        .display, .file_out => true,
        .none, .simctl, .file_func, .file_read => false,
    };
}

/// Returns the §4.5 operator, §5.10.3 event or §9.17 task this callee is
/// (the unit `names.enumerateUnits` gives it), or `.none`.
pub fn opKind(c: Callee) OpKind {
    const k = table.getPtrConst(c).op;
    if (k != .none) assert(family(c) == .none);
    return k;
}

// ---- private ----

/// The row of a real-valued callee that owns state of operator kind `k`.
fn stateful(k: OpKind) Info {
    return .{ .ty = .real, .op = k };
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
        try std.testing.expectEqual(OpKind.none, opKind(Callee.fromName(n)));
    // Exactly those 19 spellings, plus `absdelay$quad`, own state.
    var stateful_n: u32 = 0;
    for (std.enums.values(Callee)) |c| stateful_n += @intFromBool(opKind(c) != .none);
    try std.testing.expectEqual(@as(u32, names.len + 1), stateful_n);
}

test "callee: the task families agree with the descriptor, format and operator facts" {
    for (std.enums.values(Callee)) |c| {
        errdefer std.debug.print("callee `{s}`\n", .{@tagName(c)});
        const info = table.get(c);
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
    try std.testing.expectEqual(OpKind.absdelay, opKind(.@"absdelay$quad"));
}
