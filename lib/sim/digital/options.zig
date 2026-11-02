//! What a caller of `run`/`elaborate` passes: `Options` and the host attachments, sources and parameter overrides it carries.
//! Cites: IEEE 1364-2005 §12.2 (parameter overrides), §13 (libraries), §19.3.1 (defines); VAMS §8 (`Mixed`).
//!
//! Contents:
//! - `pub const Options = struct`
//! - `pub const StmtSite = struct`
//! - `pub const StmtHook = struct`
//! - `pub const DoneHook`
//! - `pub const UserSystf = struct`
//! - `pub const UserKind = union(enum)`
//! - `pub const Unit = struct`
//! - `pub const Mixed = struct`
//! - `pub const Param = struct`
//! - `pub const Insert = struct`

const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const diag = @import("diag");
const Scheduler = @import("../scheduler.zig").Scheduler;
/// Scheduler ticks. `Time` below is the timescale module, not this.
const Tick = @import("../scheduler.zig").Time;
const Time = @import("../time.zig");
const deep = @import("base").deep_stack;
const compile = @import("compile.zig");
const evaluate = @import("evaluate.zig");
const display = @import("display.zig");
/// Public for the VPI (src/vpi/value.zig), which writes a value the way a
/// process does (`waiters.store` now, `exec.enqueue` of a `.write` later), so a
/// §12.30 put wakes waiters and value-change watchers like any other write.
const exec = @import("exec.zig");
/// §17 system tasks.
const system = @import("system.zig");
const driver = @import("driver.zig");
const binding = @import("bind.zig");
const elab = @import("elab.zig");
const waiters = @import("waiters.zig");
const resolution = @import("resolution.zig");
const tchk = @import("tchk.zig");
const vpi = @import("vpi.zig");
const Type = compile.Type;
const Instruction = compile.Instruction;
const Row = exec.Row;
const Delay = @import("net.zig").Delay;
const Net = @import("net.zig").Net;
const NetCold = @import("net.zig").NetCold;
const no_cold = @import("net.zig").no_cold;
const Tran = @import("net.zig").Tran;
const Signal = @import("net.zig").Signal;
const Inertial = @import("net.zig").Inertial;
const no_transition = @import("net.zig").no_transition;
const Driver = @import("net.zig").Driver;
const filled = @import("net.zig").filled;
const setBit = @import("net.zig").setBit;
const Show = display.Show;
const TimeFormat = display.TimeFormat;
/// One elaborated design and its whole simulation state (`Run.zig`).
const Run = @import("Run.zig");
/// The descriptor table a `Run` with no `file_io` opens files through.
const own_files = system.own;
const root = @import("root.zig");
const Error = root.Error;
const max_events_per_tick = root.max_events_per_tick;

/// How `run`, `elaborate` and `digital.emitDevice` read the source.
pub const Options = struct {
    file_name: []const u8 = "<digital>",
    include_dirs: []const []const u8 = &.{},
    /// `vera -D` macros, each `NAME` or `NAME=TEXT`, as
    /// `preprocessor.Options.defines` reads them.
    defines: []const []const u8 = &.{},
    /// Only IEEE 1364-2005 §17.2.9's `$readmemb`/`$readmemh` read files while
    /// a process runs; without an `Io` those two fail with a diagnostic and
    /// nothing else changes.
    io: ?std.Io = null,
    /// VAMS §7: elaborate the DIGITAL half of a mixed-signal module. See `Mixed`.
    mixed: ?Mixed = null,
    /// The source language, `vera --std=`. See `Parser.setLanguage`.
    language: Front.keyword.KeywordSet = Front.keyword.default_keyword_set,
    /// IEEE 1364-2005 §13.2.3 the library `source`'s cells are compiled into.
    lib: []const u8 = "work",
    /// The source files after `source`, in command-line order (§13.4.1), in
    /// one text stream with it.
    more: []const Unit = &.{},
    /// §13.5.1/§13.7.1 the libraries searched, in order, for the cell of an
    /// instance no configuration binds. Empty: every library, in the order
    /// the files first name them.
    search: []const []const u8 = &.{},
    /// Events at one time step before a zero-delay loop is refused
    /// (`vera --event-budget=`).
    event_budget: u64 = max_events_per_tick,
    /// A PLI application's system tasks and functions, which the design's
    /// `$name` calls reach before any built-in of that name.
    systf: ?UserSystf = null,
    /// Record where each statement starts (`Run.host.stmt_sites`), for a host's
    /// statement callbacks (IEEE 1364-2005 §27.33.1.1).
    stmt_sites: bool = false,
    /// `vera --param NAME=VALUE`: a top-level module's parameter set as an
    /// instance's `#( … )` would set it. A number's text reads as one, any
    /// other as a §3.6 string.
    params: []const @import("base").ParamOverride = &.{},
    /// IEEE 1364-2005 §28.2 decryption keys (`vera --protect-keys`).
    protect_keys: Front.protect.Keys = .{},
    /// IEEE 1364-2005 §15.5.4's invocation option (`vera --negative-timing`):
    /// `$setuphold` and `$recrem` take negative limits, through delayed
    /// signals (`tchk.solveNegative`). Off, a negative limit is 0.
    negative_timing: bool = false,
};

/// Where statement `stmt` of instance `scope` is reached: its first
/// instruction, or a `for`'s increment or a `repeat`'s next-iteration test,
/// which Table 27-6 also calls it at.
pub const StmtSite = struct { scope: u32, stmt: Ast.StmtId, pc: u32 };

/// A host's statement callbacks (IEEE 1364-2005 §27.33.1.1): `fire` runs
/// "just before the indicated statement executes", at each pc set in `at`.
pub const StmtHook = struct {
    at: *const std.bit_set.Dynamic,
    fire: *const fn (r: *Run, pc: u32) Error!void,
};

/// A host's callback after a statement IEEE 1364-2005 §27.33.1 reports
/// completed: a §9.3 `assign`, `deassign`, `force` or `release` (cbAssign,
/// cbDeassign, cbForce, cbRelease: "after ... has been executed") or a §10.3
/// `disable` (cbDisable). `pc` is the statement's last instruction, a key of
/// `Run.host.done_sites`. An `assign`/`force` reports once its process has written
/// the target, so the value the host reads is the one it put there; one
/// undone or replaced before its process ran reports then (`exec.doneFlush`).
pub const DoneHook = *const fn (r: *Run, pc: u32) Error!void;

/// A PLI application's system tasks and functions (IEEE 1364-2005 §20.3):
/// "the user-provided C application shall override the built-in system
/// task/function" of its name (§20.4).
pub const UserSystf = struct {
    /// What `name` is registered as, or null when it is not.
    kind: *const fn (name: []const u8) ?UserKind,
    /// Runs the application behind the call whose main token is `tok`, in
    /// instance `scope`. A function's value is written into `result`, which
    /// arrives x (0.0 for a real) and as wide as its `UserKind` says.
    call: *const fn (r: *Run, scope: u32, tok: u32, result: ?Int.Literal) Error!void,
};

/// A registered PLI name: a task, or a function and the type its call
/// returns (§20.3's sized function).
pub const UserKind = union(enum) { task, func: Type };

/// One more source file and the library it maps into (`vera --libmap`).
pub const Unit = struct { name: []const u8, text: []const u8, lib: []const u8 };

/// The digital half of a design an analog compile already accepted (VAMS
/// §7.2.2's discrete context of an analog module). Elaboration then skips
/// what belongs to the continuous side instead of refusing it: `analog`
/// blocks, disciplined (continuous) nets and ports, analog-only parameters, analog
/// functions, and every variable the digital engine cannot hold. A digital
/// process that names one of those still fails, as an undeclared name.
pub const Mixed = struct {
    /// The module the analog compile lowered: the design's root.
    top: []const u8,
    /// `source` is the analog compile's own PREPROCESSED text, so it is not
    /// preprocessed again and the `timescale events it consumed come in
    /// here, at their offsets into `source`.
    timescales: []const Front.directive_events.TimescaleEvent,
    /// VAMS §7.8.4 the connect modules the analog compile inserted: they are
    /// in its flattened design and not in `source`'s hierarchy.
    inserts: []const Insert = &.{},
    /// VAMS §7.3.6.4 / §7.3.1: the root's analog variables a digital
    /// expression reads. Each is declared here anyway, and the coordinator
    /// writes it (`a2dWrite`) after every accepted analog solution.
    reads: []const []const u8 = &.{},
    /// VAMS §6.3 the root's parameters as the host's card set them (the
    /// values the device's `Model` holds), so both halves read one value.
    params: []const Param = &.{},
    /// §6.3.4 effective real parameters the discrete source reads, copied
    /// from the derived Model at the start of this analysis. Their defaults
    /// may use analog constant functions outside this executor's subset.
    /// Names use the flattened instance path, like `u.delta`.
    real_params: []const Param = &.{},
};

/// One numeric parameter value from the host (`Mixed.params` / `real_params`).
pub const Param = struct { name: []const u8, value: f64 };

/// One port VAMS §7.8.4 re-pointed at an inserted connect module, as the
/// analog compile's flatten reports it (`ir` `Lowered.Inserted`, the same
/// fields, since `sim` cannot import `ir`). In the instance at `path`
/// (instance prefix, `.` included, empty at the root), port `port` of child
/// `inst` connects to the segment `name.lower_port` instead of its upper
/// connection, and the bridge `name`, an instance of `module`, takes that
/// upper connection on `upper_port`. Merged ports repeat `name`.
pub const Insert = struct {
    path: []const u8,
    inst: []const u8,
    port: []const u8,
    module: []const u8,
    name: []const u8,
    upper_port: []const u8,
    lower_port: []const u8,
};
