//! A system task or function name in, its `SysFn` (argument checks, result type, the task the call becomes) out: the table of §17, §20 and VAMS §9.14's digital-context functions.
//! Cites: IEEE 1364-2005 §17.1 to §17.11, §20.4; VAMS §9.14 Table 9-11, §9.22.
//!
//! Contents:
//! - `pub const tasks`
//! - `pub const SysFn = enum`
//! - `SysFn.constant(self: SysFn) bool`
//! - `SysFn.mathArity(self: SysFn) ?u32`
//! - `SysFn.effects(self: SysFn) bool`
//! - `SysFn.dist(self: SysFn) ?system.Dist`
//! - `pub const vams_digital_unrun`
//! - `pub const sys_fns`
//! AST -> bytecode: one process body or driver expression, in its instance
//! scope, -> `Instruction` rows in `Run.code`, each expression's type in
//! `Run.types`, and the static slot lists drivers and `@*` wait on; or E1100
//! before any process has run.
//! Clauses: IEEE 1364-2005 §4.8.1, §5.1.1, §5.1.14, §5.2.1/§5.2.2, §5.5.1
//! Table 5-22, §5.10.4, §6.1, §8.5.3.3/§8.5.3.4, §9.3, §9.5, §9.6, §9.7.1 to
//! §9.7.7, §9.8.2, §10.2.2/§10.2.3, §10.4.4/§10.4.5, §12.7, §17.1 to §17.11,
//! §20.4, A.6.5; VAMS §7.3.6.3 analog probes, §9.14 Table 9-11 `$clog2`,
//! §9.22 driver access.
const std = @import("std");
const assert = std.debug.assert;
const Front = @import("frontend");
const Ast = Front.Ast;
const exec = @import("exec.zig");
const evaluate = @import("evaluate.zig");
const deep = @import("base").deep_stack;
const display = @import("display.zig");
const driver = @import("driver.zig");
const system = @import("system.zig");
const elab = @import("elab.zig");
const evcd = @import("evcd.zig");
const vcd = @import("vcd.zig");
const root = @import("root.zig");
const Error = root.Error;
const Run = root.Run;
const SpecExpr = root.SpecExpr;
const expectRun = root.expectRun;
const expectRejected = root.expectRejected;
const filled = @import("net.zig").filled;

pub const tasks = display.tasks;

/// §9.14 Table 9-11's integral system functions, the two of IEEE 1364 §17.7
/// that read the clock, and §4.2.1.4's `$signed`/`$unsigned` casts: every
/// system function an integral expression may call. `infer` resolves each
/// call once into `Run.sys_calls`; separate from `tasks` because these are
/// expressions.
pub const SysFn = enum {
    /// §17.7.1, 64 bits: "the time unit of the module that invoked it".
    time,
    /// §17.7.1's 32-bit half, "the low order 32 bits of the current
    /// simulation time".
    stime,
    /// §9.14 Table 9-11 / IEEE 1364 §17.11: ceiling of log base 2.
    clog2,
    /// §4.2.1.4 `$signed`/`$unsigned`: the operand's bits, self-determined,
    /// retyped; the width is unchanged.
    make_signed,
    make_unsigned,
    /// IEEE 1364-2005 §17.10.1/§17.10.2, the plusarg queries. `vera --run`
    /// takes no plusargs, so every query is §17.10's "no match": an integer
    /// zero, and `$value$plusargs` leaves its variable alone.
    test_plusargs,
    value_plusargs,
    /// §17.6.5 `$q_full(q_id, status)`, which also writes its status.
    q_full,
    /// VAMS §9.22/§9.23 connect-module driver access (`driver.zig`).
    driver_count,
    receiver_count,
    driver_state,
    driver_strength,
    driver_delay,
    driver_next_state,
    driver_next_strength,
    driver_type,
    /// §17.2 the file functions: open, the character, line, formatted and
    /// binary reads, positioning, end-of-file, errors, and §17.2.4.3's
    /// `$sscanf`.
    fopen,
    fgetc,
    ungetc,
    fgets,
    fscanf,
    fread,
    ftell,
    fseek,
    rewind,
    feof,
    ferror,
    sscanf,
    /// §17.7.3, the clock as a real in the module's unit.
    realtime,
    /// §17.8's conversions: `$rtoi` truncates, `$itor` converts, and
    /// `$realtobits`/`$bitstoreal` move the 64 IEEE-754 bits unchanged.
    rtoi,
    itor,
    realtobits,
    bitstoreal,
    /// §17.11.2 Table 17-17's real math functions.
    ln,
    log10,
    exp,
    sqrt,
    floor,
    ceil,
    sin,
    cos,
    tan,
    asin,
    acos,
    atan,
    sinh,
    cosh,
    tanh,
    asinh,
    acosh,
    atanh,
    pow,
    atan2,
    hypot,
    /// VAMS §9.14 Table 9-11's additions, digital context "Yes".
    ln1p,
    expm1,
    /// VAMS §9.10 Table 9-7 `$abstime`: now, in seconds, a real.
    abstime,
    /// §17.9 `$random` and the `$dist_*` functions (`system.dist`).
    random,
    dist_uniform,
    dist_normal,
    dist_exponential,
    dist_poisson,
    dist_chi_square,
    dist_t,
    dist_erlang,
    /// IEEE 1364-2005 §20.3 a PLI application's function (`Run.systf`).
    user,

    /// Is a call a constant expression when its arguments are? A replication
    /// count and a case label depend on this. A clock query, a file or queue
    /// operation, a draw from a distribution and a driver query never are.
    pub fn constant(self: SysFn) bool {
        const yes = switch (self) {
            .time, .stime, .realtime, .abstime, .test_plusargs, .value_plusargs, .q_full, .fopen, .fgetc, .ungetc, .fgets, .fscanf, .fread, .ftell, .fseek, .rewind, .feof, .ferror, .sscanf => false,
            .random, .dist_uniform, .dist_normal, .dist_exponential, .dist_poisson, .dist_chi_square, .dist_t, .dist_erlang => false,
            .driver_count, .receiver_count, .driver_state, .driver_strength, .driver_delay, .driver_next_state, .driver_next_strength, .driver_type => false,
            .user => false,
            else => true, // else: a pure function of its arguments
        };
        if (yes) assert(!self.effects());
        return yes;
    }

    /// How many real arguments a Table 17-17 function takes, or null for a
    /// function that is not one of them.
    pub fn mathArity(self: SysFn) ?u32 {
        const n: ?u32 = switch (self) {
            .pow, .atan2, .hypot => 2,
            .ln, .ln1p, .log10, .exp, .expm1, .sqrt, .floor, .ceil, .sin, .cos, .tan, .asin, .acos, .atan, .sinh, .cosh, .tanh, .asinh, .acosh, .atanh => 1,
            else => null, // else: not a math function
        };
        if (n) |k| assert(k == 1 or k == 2);
        return n;
    }

    /// Does a call change state besides giving its value: an argument it
    /// writes back, `$random`'s seed, a file's position or table?
    pub fn effects(self: SysFn) bool {
        const yes = switch (self) {
            .q_full, .sscanf, .fopen, .fgetc, .ungetc, .fgets, .fscanf, .fread, .ferror, .fseek, .rewind => true,
            .random, .dist_uniform, .dist_normal, .dist_exponential, .dist_poisson, .dist_chi_square, .dist_t, .dist_erlang => true,
            // §20.7: its application may write any argument.
            .user => true,
            else => false, // else: a function of its arguments, the clock or the design alone
        };
        if (yes) assert(self.mathArity() == null);
        return yes;
    }

    /// The §17.9 distribution a call draws from, or null for any other.
    pub fn dist(self: SysFn) ?system.Dist {
        const d: ?system.Dist = switch (self) {
            .random => .random,
            .dist_uniform => .uniform,
            .dist_normal => .normal,
            .dist_exponential => .exponential,
            .dist_poisson => .poisson,
            .dist_chi_square => .chi_square,
            .dist_t => .t,
            .dist_erlang => .erlang,
            else => null, // else: not a §17.9 function
        };
        if (d != null) assert(self.mathArity() == null);
        return d;
    }
};

// Table relations every call site relies on, checked once over every function.
comptime {
    @setEvalBranchQuota(200_000);
    for (std.enums.values(SysFn)) |f| if (f.dist() != null) assert(!f.constant()); // A draw is never folded.
    for (std.enums.values(SysFn)) |f| if (f.mathArity() != null) assert(f.constant()); // Table 17-17 is pure.
    for (std.enums.values(SysFn)) |f| if (f.effects()) assert(!f.constant()); // State changes are never folded.
    for (std.enums.values(SysFn)) |f| if (f.dist() != null) assert(f.effects()); // A draw advances its seed.
}

// ponytail: each row is one `SysFn` and its two evaluators (interpreter,
// `src/codegen/digital/emit_expr.zig`) away from running.
/// VAMS §9.2's functions whose "Supported in digital context" cell is Yes
/// and that the digital engine does not run, each with its table: refused by
/// name (E0829), never as an unknown form.
pub const vams_digital_unrun = std.StaticStringMap([]const u8).initComptime(.{
    .{ "$arandom", "9-10" },
    .{ "$rdist_chi_square", "9-10" },
    .{ "$rdist_exponential", "9-10" },
    .{ "$rdist_poisson", "9-10" },
    .{ "$rdist_uniform", "9-10" },
    .{ "$rdist_erlang", "9-10" },
    .{ "$rdist_normal", "9-10" },
    .{ "$rdist_t", "9-10" },
    .{ "$min", "9-11" },
    .{ "$max", "9-11" },
    .{ "$abs", "9-11" },
    .{ "$temperature", "9-12" },
    .{ "$vt", "9-12" },
    .{ "$simparam", "9-12" },
    .{ "$simparam$str", "9-12" },
    .{ "$mfactor", "9-15" },
    .{ "$xposition", "9-15" },
    .{ "$yposition", "9-15" },
    .{ "$angle", "9-15" },
    .{ "$hflip", "9-15" },
    .{ "$vflip", "9-15" },
    .{ "$table_model", "9-18" },
});

pub const sys_fns = std.StaticStringMap(SysFn).initComptime(.{
    .{ "$time", .time },
    .{ "$stime", .stime },
    .{ "$clog2", .clog2 },
    .{ "$signed", .make_signed },
    .{ "$unsigned", .make_unsigned },
    .{ "$test$plusargs", .test_plusargs },
    .{ "$value$plusargs", .value_plusargs },
    .{ "$q_full", .q_full },
    .{ "$driver_count", .driver_count },
    .{ "$receiver_count", .receiver_count },
    .{ "$driver_state", .driver_state },
    .{ "$driver_strength", .driver_strength },
    .{ "$driver_delay", .driver_delay },
    .{ "$driver_next_state", .driver_next_state },
    .{ "$driver_next_strength", .driver_next_strength },
    .{ "$driver_type", .driver_type },
    .{ "$fopen", .fopen },
    .{ "$fgetc", .fgetc },
    .{ "$ungetc", .ungetc },
    .{ "$fgets", .fgets },
    .{ "$fscanf", .fscanf },
    .{ "$fread", .fread },
    .{ "$ferror", .ferror },
    .{ "$ftell", .ftell },
    .{ "$fseek", .fseek },
    .{ "$rewind", .rewind },
    .{ "$feof", .feof },
    .{ "$sscanf", .sscanf },
    .{ "$realtime", .realtime },
    .{ "$rtoi", .rtoi },
    .{ "$itor", .itor },
    .{ "$realtobits", .realtobits },
    .{ "$bitstoreal", .bitstoreal },
    .{ "$ln", .ln },
    .{ "$log10", .log10 },
    .{ "$exp", .exp },
    .{ "$sqrt", .sqrt },
    .{ "$floor", .floor },
    .{ "$ceil", .ceil },
    .{ "$sin", .sin },
    .{ "$cos", .cos },
    .{ "$tan", .tan },
    .{ "$asin", .asin },
    .{ "$acos", .acos },
    .{ "$atan", .atan },
    .{ "$sinh", .sinh },
    .{ "$cosh", .cosh },
    .{ "$tanh", .tanh },
    .{ "$asinh", .asinh },
    .{ "$acosh", .acosh },
    .{ "$atanh", .atanh },
    .{ "$pow", .pow },
    .{ "$atan2", .atan2 },
    .{ "$hypot", .hypot },
    .{ "$ln1p", .ln1p },
    .{ "$expm1", .expm1 },
    .{ "$abstime", .abstime },
    .{ "$random", .random },
    .{ "$dist_uniform", .dist_uniform },
    .{ "$dist_normal", .dist_normal },
    .{ "$dist_exponential", .dist_exponential },
    .{ "$dist_poisson", .dist_poisson },
    .{ "$dist_chi_square", .dist_chi_square },
    .{ "$dist_t", .dist_t },
    .{ "$dist_erlang", .dist_erlang },
});
