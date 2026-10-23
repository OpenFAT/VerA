//! Verilog source -> its IEEE 1364-2005 §17 transcript on `out`, or E1100
//! diagnostics before any process prints anything. The `Run` driver: engine
//! state, §6.2.2 per-instance names (§12.5/§12.6 hierarchical references),
//! and `elaborate`, the spine: preprocess and parse, §19.8 timescales, pass
//! one (`elab.zig`: elaboration into slots, nets and driver rows, §6.5,
//! §6.5.7.1, §19.9), pass two (every driver, switch and process compiled
//! and queued at time 0). `run` then drains the §11 scheduler.
//! Siblings: elab.zig (pass one), compile.zig (AST -> bytecode), exec.zig
//! (interpreter), evaluate.zig (expressions), net.zig (resolution tables),
//! resolution.zig (§7.9 resolution), waiters.zig (the write path), driver.zig
//! (VAMS §9.22 driver access), tchk.zig (§15), display.zig and system.zig
//! (§17), vcd.zig and evcd.zig (§18), bind.zig (§13), vpi.zig (a VPI
//! application's requests). The native emitter over a `Run` is the
//! `digital` module (src/codegen/digital/), which reads the files it names below.
const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const diag = @import("diag");
const Scheduler = @import("../scheduler.zig").Scheduler;
/// Scheduler ticks. `Time` below is the timescale module, not this.
pub const Tick = @import("../scheduler.zig").Time;
const Time = @import("../time.zig");
const deep = @import("base").deep_stack;
const compile = @import("compile.zig");
const evaluate = @import("evaluate.zig");
const display = @import("display.zig");
/// The files the native emitter (the `digital` module: `vera --emit-exe` and
/// `.v` devices) reads besides `Run`, until B4 gives it IR of its own. A
/// namespace, since `net`, `vcd` and `evcd` name locals and fields here.
pub const for_emitter = struct {
    pub const compile = @import("compile.zig");
    pub const evaluate = @import("evaluate.zig");
    pub const display = @import("display.zig");
    pub const net = @import("net.zig");
    pub const vcd = @import("vcd.zig");
    pub const evcd = @import("evcd.zig");
};
/// Public for the VPI (src/vpi/value.zig), which writes a value the way a
/// process does (`waiters.store` now, `exec.enqueue` of a `.write` later), so a
/// §12.30 put wakes waiters and value-change watchers like any other write.
pub const exec = @import("exec.zig");
/// §17 system tasks.
pub const system = @import("system.zig");
/// The descriptor table a `Run` with no `file_io` opens files through.
pub const own_files = system.own;
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

// ---- the public surface -----------------------------------------------------

/// `DigitalFailed`: a diagnostic is already in the `bag` (E1100 by default,
/// or the rule's own code through `Run.failWith`); the run stops there.
/// `WriteFailed`: the transcript writer `out` failed.
pub const Error = error{DigitalFailed} || std.mem.Allocator.Error || std.Io.Writer.Error;

/// How `run`, `elaborate` and `digital.emitDevice` read the source.
pub const Options = struct {
    file_name: []const u8 = "<digital>",
    include_dirs: []const []const u8 = &.{},
    /// Only IEEE 1364-2005 §17.2.9's `$readmemb`/`$readmemh` read files while
    /// a process runs; without an `Io` those two fail with a diagnostic and
    /// nothing else changes.
    io: ?std.Io = null,
    /// VAMS §7: elaborate the DIGITAL half of a mixed-signal module. See `Mixed`.
    mixed: ?Mixed = null,
    /// The source language, `vera --std=`. See `Parser.setLanguage`.
    language: Front.token.KeywordSet = Front.token.default_keyword_set,
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
    /// Record where each statement starts (`Run.stmt_sites`), for a host's
    /// statement callbacks (IEEE 1364-2005 §27.33.1.1).
    stmt_sites: bool = false,
    /// `vera --param NAME=VALUE`: a top-level module's parameter set as an
    /// instance's `#( … )` would set it. A number's text reads as one, any
    /// other as a §3.6 string.
    params: []const @import("base").ParamOverride = &.{},
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
/// `Run.done_sites`. An `assign`/`force` reports once its process has written
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
    timescales: []const Front.Preprocessor.TimescaleEvent,
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

// ---- engine state and name resolution (§6.2.2, §12.4, §3.9) -----------------

/// One declared identifier, qualified by the §6.2.2 instance that declared it.
const Name = struct { scope: u32, str: Ast.StrId };

/// One expression in one specialization (`Run.specOf`).
pub const SpecExpr = struct { spec: u32, e: Ast.ExprId };

/// How many distinct types the specializations that typed a row gave it.
const TyState = enum(u8) { untyped, one, many };

/// §3.9 an unpacked array is `count` consecutive element slots; the declared
/// name maps to the first. `low`/`high` are the first dimension's address
/// bounds sorted, `low <= high`, whichever order the declaration wrote them
/// in: element `k` of that dimension is address `low + k`.
///
/// §4.9 a multidimensional array keeps its first dimension in `low`/`high`
/// and the others in `rest`, addressed row-major.
/// `left`/`right`: the first dimension's bounds as declared, `[left:right]`
/// (IEEE 1364-2005 §26.6.10's vpiLeftRange/vpiRightRange).
pub const Array = struct { count: u32, low: i64, high: i64, left: i64, right: i64, rest: []const Span = &.{} };
/// Sorted bounds for addressing, plus the declared direction for VPI ranges.
pub const Span = struct { low: i64, high: i64, descending: bool = false };

/// A packed vector's declared `[msb:lsb]` (§3.3).
pub const VecRange = struct {
    msb: i64,
    lsb: i64,

    /// The bit position, counted from the least significant, that declared
    /// index `index` names; outside `[0, width)` it names no bit.
    pub fn position(r: VecRange, index: i64) i64 {
        // A distant legal integer index names no bit; it cannot overflow
        // the host while deciding that (§5.2.1).
        return if (r.msb >= r.lsb) index -| r.lsb else r.lsb -| index;
    }
};

/// §17.1.3 a standing `$monitor`, or a §17.2.2 `$fmonitor`, whose
/// arguments start after its descriptor `fd`. `values` is what each argument
/// read when last evaluated (`display.monitorChanged`), null for one that
/// is never compared: a string, an empty argument or a clock query, the
/// clause's "with the exception of $time, $stime or $realtime". An
/// `$fmonitor` keeps its own watched `slots` and `hit`; `$monitor`'s are
/// `Run.monitor_slots` and `Run.monitor_slot_hit`.
pub const Standing = struct {
    args: []const Ast.ExprId,
    show: Show,
    scope: u32,
    pc: u32,
    values: []?[]u64 = &.{},
    slots: []const u32 = &.{},
    /// The slots its arguments that are not compared read: a change of one
    /// reports without a comparison.
    loose: []const u32 = &.{},
    hit: bool = false,
    fd: i64 = 0,
};

/// Who is told when a slot's value changes: one member of a slot's
/// `Run.watch` set each.
pub const Watcher = enum {
    /// IEEE 1364-2005 §17.1.3: the standing `$monitor` or an `$fmonitor`
    /// reads the slot.
    monitor,
    /// VAMS §8.5's implicit D2A: the slot is read by an analog block, so a
    /// change posts a region-3b macro-process event (`Run.watchAnalog`).
    analog,
    /// VAMS §12.31.1's cbValueChange: an application watches the slot, and a
    /// change calls `Run.vpi_change`.
    vpi,
    /// IEEE 1364-2005 §18's value change dump: the slot is dumped, so a
    /// change asks for the end-of-step section (`vcd.zig`).
    vcd,
    /// VAMS §8.5's explicit D2A: the slot is the operand of a digital event
    /// term in an analog event control (`Run.watchEvent`).
    d2a,
    /// VAMS §9.22.5: the slot feeds a driver some `@(driver_update …)`
    /// watches (`driver.arm`).
    driver_update,
    /// IEEE 1364-2005 §18.3: the slot is a port `$dumpports` dumps
    /// (`evcd.zig`).
    ports,
    /// IEEE 1364-2005 §15: a timing check's event names the slot
    /// (`tchk.changed`).
    tchk,
    /// IEEE 1364-2005 §14.3.3: the slot is a module path's source, whose last
    /// transition picks the path delay (`Run.path_changed`).
    path,
};

/// Why `runUntil` returned. `analog` is a region-3b event (VAMS §8.5.1): every
/// active, explicit D2A, inactive and nonblocking event of the current tick has
/// run, and an analog-read value changed. The caller solves NOW and calls
/// `runUntil` again, which resumes the same tick at its monitor region.
/// `explicit_d2a` is region 1b (§8.5.3.6): region 1 of the tick is done, and
/// `d2a_fired` names the analog event terms that occurred. The caller takes the
/// values the guarded statements read NOW; the tick's region-3b stop follows.
pub const Stop = enum { idle, analog, explicit_d2a, vpi_sync };

/// One analog event a digital event control waits on (`Run.registerMonitor`).
const Monitor = struct { expr: Ast.ExprId, scope: u32, slot: u32, kind: MonitorKind };

/// A.6.5 `analog_event_functions`, the four VAMS §5.10.3 events a monitor is.
const MonitorKind = enum { cross, above, timer, absdelta };

/// One digital event term of an analog event control (`Run.watchEvent`).
pub const D2aSite = struct { slot: u32, edge: waiters.Edge, site: u6 };

/// The events one time step may dispatch before `runUntil` calls it a
/// zero-delay loop. Far above any design's settling activity per step.
pub const max_events_per_tick: u64 = 10_000_000;

/// The scheduler payload of the one analog macro-process. Not a `pending`
/// row: the event carries no data, and the scheduler coalesces repeats of it
/// (§8.5.3.7) by payload.
pub const analog_payload: u32 = std.math.maxInt(u32);

/// One elaborated design and its whole simulation state: the slot space
/// every variable, net and array element lives in (`values`), the nets and
/// their drivers, the compiled processes (`code`), the waiters, and the
/// scheduler. Everything is allocated from `arena`, which must outlive the
/// `Run`; nothing is freed before the arena is. Made only by `elaborate`.
///
/// A `Run` is one thread's: `scope`, `pc` and `ctx` are the executing
/// process's registers, so a caller outside the engine (the VPI, the mixed
/// coordinator) saves and restores `scope` around anything it evaluates.
pub const Run = struct {
    arena: std.mem.Allocator,
    file: *const Ast.SourceFile,
    /// The preprocessed text `starts` indexes.
    text: []const u8 = "",
    starts: []const u32,
    bag: *diag.Bag,
    out: *std.Io.Writer,
    /// §6.2.2 names are per INSTANCE, not per module: two instances of one
    /// definition declare the same identifiers over different storage, so the
    /// key is the scope the name was declared in plus the interned name. The
    /// scope in force is `self.scope`, which the executing process carries.
    names: std.AutoHashMapUnmanaged(Name, u32) = .empty,
    scope: u32 = 0,
    /// IEEE 1364-2005 §26.6.19(e): the lexical scope of an expression a
    /// VPI application may evaluate later, keyed by (instance, expression).
    /// Populated only for a host with `systf`; obtaining an argument handle
    /// does not evaluate its expression.
    vpi_expr_scopes: std.AutoHashMapUnmanaged([2]u32, u32) = .empty,
    /// The highest scope id handed out; the root is 0.
    scopes: u32 = 0,
    /// Per scope id: the instance that minted it, its name and its module
    /// (§17.1.1.6's `%m` path and §13.6's `%l` binding). Row 0 is the root,
    /// named after its module.
    /// `lexical` marks a scope nested inside its parent's module, a task or
    /// function (§12.7), whose unresolved names are searched for in the
    /// parent; an instance is a hierarchy boundary and is searched no further.
    /// `index` marks one iteration of a §12.4.1 loop generate, the `[i]` of
    /// its block name; `implicit`, one whose block is unnamed (§12.4.3's
    /// `genblk<n>`, IEEE 1364-2005 §26.6.44's vpiImplicitDecl).
    scope_info: std.ArrayList(struct { parent: u32, name: Ast.StrId, def: u32, lexical: bool = false, index: ?i64 = null, implicit: bool = false }) = .empty,
    /// IEEE 1364-2005 §13.2.3 per `file.modules` row, the library its source
    /// file maps into; per `file.configs` row, the same.
    def_lib: []const Ast.StrId = &.{},
    cfg_lib: []const Ast.StrId = &.{},
    /// §13.5.1/§13.7.1 the library search order with no configuration.
    search: []const Ast.StrId = &.{},
    /// Per instance scope, the §13.3 state its children bind under.
    binds: std.AutoHashMapUnmanaged(u32, binding.Ctx) = .empty,
    /// The top-level modules' scopes (`isRoot`), 0 first.
    roots: []const u32 = &.{0},
    /// IEEE 1364-2005 §10 the tasks and functions of every instance.
    subs: std.ArrayList(Sub) = .empty,
    /// A subroutine by its name in the instance that declares it.
    sub_by_name: std.AutoHashMapUnmanaged(Name, u32) = .empty,
    /// Per instance scope, the index of its first `subs` row: a call site is
    /// typed once per module, so it records a module-relative index
    /// (`call_subs`) and each instance adds its own base.
    sub_base: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    call_subs: std.AutoHashMapUnmanaged(Ast.ExprId, u32) = .empty,
    /// §10.3 a `disable` of a subroutine with synchronous activations in
    /// progress: every activation returns at once until the outermost one.
    unwind: ?u32 = null,
    /// Compiling a function body, which §10.4.4 restricts.
    in_function: bool = false,
    /// §9.7.2 each event term that is an expression, by the scope it is
    /// compiled in: the hidden slot `compile.exprTerm` keeps equal to it.
    term_slots: std.AutoHashMapUnmanaged(struct { scope: u32, e: Ast.ExprId }, u32) = .empty,
    /// The storage of automatic tasks and functions, which §10.2.3 keeps
    /// out of constructs that might outlive an activation.
    auto_slots: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// The saved storage of the automatic activations in progress.
    saved_planes: std.ArrayList(u64) = .empty,
    /// §10.2.3 the activations of recursive timed tasks: the one the
    /// executing process is in (0 for none), every one in progress, and the
    /// rows free for reuse.
    ctx: u32 = 0,
    acts: std.ArrayList(exec.Act) = .empty,
    free_acts: std.ArrayList(u32) = .empty,
    /// The instruction a system task is running from, so `%m` can name the
    /// §5.3.2 named blocks around it.
    pc: u32 = 0,
    /// §12.4 one instance NAME, keyed by the scope that instantiated it, to the
    /// scope it minted. `names` cannot carry this: an instance is not storage,
    /// and a downward hierarchical reference walks these before it reaches a
    /// slot at all.
    instances: std.AutoHashMapUnmanaged(Name, u32) = .empty,
    /// §12.5 the scope of each named block that declares something, keyed by
    /// the scope it runs in and its statement (`blockScope`).
    block_scopes: std.AutoHashMapUnmanaged(struct { scope: u32, stmt: Ast.StmtId }, u32) = .empty,
    /// IEEE 1364 §19.9's regions, in text-stream order. Read once per
    /// unconnected input port; `src/analog/node.zig`'s `applyUnconnectedDrive` is
    /// the analog half of the same directive.
    drives: []const Front.Preprocessor.DriveRegion = &.{},
    /// IEEE 1364 §19.2's `default_nettype regions, in text-stream order: the
    /// type of a §4.5 implicit net.
    nettypes: []const Front.Preprocessor.NetTypeRegion = &.{},
    /// Variables, array elements and nets share one slot space, so one `store`
    /// wakes event waiters for all three.
    values: []Int.Literal,
    /// Which of `nets` a slot is, for the slots that are nets at all. Per slot
    /// and not a `net_base` boundary because §6.2.2 elaboration interleaves one
    /// instance's variables with the next one's nets.
    net_of: SlotNets = .{},
    nets: []Net = &.{},
    /// The cold rows `Net.cold` indexes.
    net_cold: std.ArrayList(NetCold) = .empty,
    /// Every net's drivers as one CSR table: net `n`'s are
    /// `net_drivers[net_driver_start[n]..net_driver_start[n + 1]]`, in
    /// declaration order (`netDrivers`). Empty until pass two groups them.
    net_driver_start: []const u32 = &.{},
    net_drivers: []const u32 = &.{},
    /// Every net's per-bit §7.10 signals, `Net.signal` the first of each.
    signals: []Signal = &.{},
    drivers: []Driver = &.{},
    /// The §6.1.3 transitions of the delayed drivers, `Driver.transition`
    /// the row of each (`driverTransition`).
    transitions: std.ArrayList(Inertial) = .empty,
    /// §7.6 every pass switch.
    trans: []Tran = &.{},
    /// Keyed by the base slot of an unpacked array (§3.9).
    arrays: std.AutoHashMapUnmanaged(u32, Array) = .empty,
    /// IEEE 1364-2005 §12.4/§26.6.44: the net declarations belonging to each
    /// elaborated generate scope, retained for its VPI object relationships.
    gen_nets: std.AutoHashMapUnmanaged(u32, []const Ast.NetDecl) = .empty,
    /// The slots that are §5.10.4 named events. They occupy a slot only so that
    /// `@(e)` and `-> e` can meet on the waiter list; nothing is ever stored
    /// there, because §5.10's events "do not hold any data". Each scalar or
    /// array element maps to its declaration's token and lexical scope.
    events: std.AutoHashMapUnmanaged(u32, struct { tok: u32, scope: u32 }) = .empty,
    /// Natural types (§5.5.1), indexed by AST ExprId. An ExprId is shared by
    /// every instance of its module, and IEEE 1364-2005 §12.2 gives each
    /// instance its own parameter values, so the truth is `spec_types`, keyed
    /// by `specOf`. `types` is the dense copy for a row every specialization
    /// typed alike (`ty_state` `.one`); `.many` rows are read from the map.
    types: []Type = &.{},
    ty_state: []TyState = &.{},
    spec_types: std.AutoHashMapUnmanaged(SpecExpr, Type) = .empty,
    /// Which system function each `.sys_call` is, indexed by AST ExprId and
    /// written by `infer`, so evaluation switches on it instead of hashing
    /// the name again. Null for every other node.
    sys_calls: []?compile.SysFn = &.{},
    replications: std.AutoHashMapUnmanaged(SpecExpr, u32) = .empty,
    code: std.ArrayList(Instruction) = .empty,
    /// The instance scope each instruction was compiled in, one row per `code`
    /// row. A process never leaves the scope it was written in, so `execute`
    /// reads this once per dispatch, an event resumption included, which
    /// re-enters at a pc in the middle of a body.
    code_scope: std.ArrayList(u32) = .empty,
    case_targets: std.ArrayList(u32) = .empty,
    /// §5.3.2 the pc range of each named sequential block, keyed per §6.2.2
    /// instance like every other declared name, so two instances of one
    /// definition disable their own copy and not each other's.
    /// `depth` is the block's statement nesting, which orders two named
    /// blocks with the same range (`begin : a begin : b ... end end`) for `%m`.
    blocks: std.AutoHashMapUnmanaged(Name, struct { start: u32, end: u32, depth: u32 }) = .empty,
    /// The `.disable_block` instructions still waiting for their range, and the
    /// name each one is waiting for. A.6.5 puts no ordering rule on a
    /// `disable`: the block it names is routinely in ANOTHER process, which may
    /// not be compiled yet, so the lookup is deferred to one pass at the end
    /// rather than failing in the middle of a dispatch.
    disables: std.ArrayList(struct { at: u32, name: Name, tok: u32 }) = .empty,
    /// One counter per lexical `repeat`: no process re-enters its own.
    repeats: std.ArrayList(u64) = .empty,
    /// §9.8.2 one counter per lexical `fork`: the arms still running. One per
    /// site is enough, since the parent waits at the site, except inside a
    /// recursive timed task's out-of-line body, which every activation runs
    /// (§10.2.3): there the counter is the activation's (`act_joins`).
    joins: std.ArrayList(u32) = .empty,
    act_joins: std.AutoHashMapUnmanaged(struct { join: u32, ctx: u32 }, u32) = .empty,
    /// §9.3 the procedural continuous assignments in effect, by slot: the
    /// process range of an `assign` and of a `force`. While one is, ordinary
    /// writes to the slot do not land (`store`); a force outranks an assign.
    overrides: std.AutoHashMapUnmanaged(u32, Overrides) = .empty,
    /// `store` from an override's own process, which the guard lets through.
    overriding: bool = false,
    /// §8.5.3.3 one parked right-hand side per lexical intra-assignment timing
    /// control. One cell per site is enough: the process that reached it is
    /// suspended there until the `deposit` consumes the value.
    holds: std.ArrayList(Int.Literal) = .empty,
    /// Payload rows, indexed by the scheduler's `payload`. Recycled through
    /// `free_rows`, so this is bounded by the most events queued at once.
    pending: std.ArrayList(Row) = .empty,
    free_rows: std.ArrayList(u32) = .empty,
    /// §9.7 the processes suspended on an event control. A row is recycled
    /// once its process resumes or is disabled.
    susps: std.ArrayList(waiters.Susp) = .empty,
    free_susps: std.ArrayList(u32) = .empty,
    /// §5.10.1 per slot, the terms of the event controls waiting on it, made
    /// on the slot's first wait (most slots are never waited on, and a list
    /// header is three words); a slot no variable owns (`driver.key`,
    /// `registerMonitor`) is in `far_terms`.
    terms: []?*std.ArrayList(waiters.Term) = &.{},
    far_terms: std.AutoHashMapUnmanaged(u32, std.ArrayList(waiters.Term)) = .empty,
    /// §6.1 / §7.6 the static fan-out (`waiters.buildFanout`): per slot
    /// `fan[fan_start[slot]..fan_start[slot + 1]]` are the pcs of the
    /// continuous drivers and controlled switches reading it, and `armed[pc]`
    /// says that process is suspended on its operands right now.
    fan_start: []u32 = &.{},
    fan: []u32 = &.{},
    armed: []bool = &.{},
    scheduler: Scheduler,
    /// The source's own path, so §17.2.9's memory file resolves beside the
    /// module that names it.
    file_name: []const u8 = "",
    io: ?std.Io = null,
    /// The ROOT module's time scale; every module's own is in `module_times`.
    scale: ?Time.Scale = null,
    /// The root module's time unit as a power of ten of a second. `Scale`
    /// stores only ratios, and `%t` needs the absolute magnitude to reach
    /// §17.3's `units_number`.
    unit_exp: i32 = 0,
    /// IEEE 1364 §19.8 each module definition's own time scale, per
    /// `file.modules` row. Read through `timeOf`.
    module_times: []const ModuleTime = &.{},
    time_format: TimeFormat = .{},
    /// IEEE 1364-2005 §26.6.41: the call that selected `time_format`, absent
    /// before execution of any $timeformat. The instance disambiguates the
    /// same source token executed in two instantiations of one definition.
    active_timeformat: ?struct { scope: u32, tok: u32 } = null,
    /// §17.3.2 Table 17-11's default `units_number`: "the smallest time
    /// precision argument of all the `timescale compiler directives".
    finest: i32 = 0,
    /// §17.1.3 the one standing monitor. A second `$monitor` replaces it;
    /// there is no stack.
    monitor: ?Standing = null,
    /// §17.2.2 the active `$fmonitor` tasks: "any number of $fmonitor tasks
    /// can be set up to be simultaneously active", each until an `$fclose`
    /// of its descriptor.
    fmonitors: std.ArrayList(Standing) = .empty,
    /// Per driver index, a `delay3` that reads a variable: A.2.2.3 lets a
    /// continuous assignment's or gate's delay be one, which §6.1.3 reads
    /// each time the driver schedules (`exec`'s `.continuous`).
    driver_delays: std.AutoHashMapUnmanaged(u32, Ast.Delay3) = .empty,
    /// IEEE 1364-2005 §14.3.3: per module path source slot (a `.path`
    /// watch), its last transition, which picks the path whose delay a
    /// destination transition takes (`waiters.store` fills it).
    path_changed: std.AutoHashMapUnmanaged(u32, @import("net.zig").PathEdge) = .empty,
    /// `display.monitorChanged` is evaluating a monitor's arguments, so a
    /// store that evaluation makes asks nothing again.
    monitor_evaluating: bool = false,
    monitor_on: bool = true,
    /// One `.monitor` event per timestep however many values moved.
    monitor_pending: bool = false,
    /// VAMS §7.3.6.3: the analog probes in the standing monitor's arguments,
    /// operands no slot holds. With any, the monitor is checked at every time
    /// step (`runUntil`), after the step's region-3b solve (§8.5.1 row 4),
    /// and at every analog solution at a tick no digital event reached
    /// (`analogPoint`), and reports when a probe's value moved
    /// (`display.monitorDue`).
    monitor_probes: []const Ast.ExprId = &.{},
    /// A watched slot changed since the monitor last reported, so the report
    /// is due without a comparison (§17.1.3). The first report is due too.
    monitor_slot_hit: bool = false,
    /// Per `monitor_probes` entry, the value it read at the last report.
    monitor_last: []f64 = &.{},
    /// The slots the standing monitor's arguments read: §17.1.3's "variable
    /// or an expression in the argument list". Clock queries read no slot,
    /// which is the clause's `$time`/`$stime`/`$realtime` exception.
    monitor_slots: std.ArrayList(u32) = .empty,
    /// Per slot, who is told when its value changes. `store` tests this on
    /// every change and nothing else: it is the one value-change hook, whose
    /// first watcher is §17.1.3's monitor; §18's value change dump and VAMS
    /// §8.5's implicit D2A are the same event, each a member of its own.
    watch: []std.EnumSet(Watcher) = &.{},
    /// One region-3b event per tick however many analog-read values moved,
    /// the same coalescing `monitor_pending` does for region 4.
    analog_pending: bool = false,
    /// §8.5 the explicit D2A terms, the ones that occurred this tick (bit =
    /// `D2aSite.site`), and the one region-1b event that reports them.
    d2a_sites: std.ArrayList(D2aSite) = .empty,
    d2a_fired: u64 = 0,
    d2a_pending: bool = false,
    /// Events dispatched at `budget_time`, against `budget`.
    budget_time: Tick = 0,
    budget_used: u64 = 0,
    budget: u64 = max_events_per_tick,
    /// Per-instruction scratch of `runUntil` (`exec.Scratch`): the fixed
    /// buffer every instruction starts from, and the arena behind it, reset
    /// at each event with its capacity kept, so a run of many calls (the
    /// mixed runner's one per tick) stops growing `arena` once the largest
    /// event has run. Both backed by `arena`.
    scratch_buf: []u8,
    scratch: std.heap.ArenaAllocator,
    /// `runUntil` is running: it is not reentrant, since a nested call would
    /// reset `scratch` under the outer one.
    running: bool = false,
    /// The stage every diagnostic raised now files under (`stage`, #72):
    /// `.lower` while `elaborate` runs, `.run` once it returns, so an error
    /// from `runUntil` or from a host (VPI) between its calls is the run's.
    /// An emitter that compiles the elaborated design instead of running it
    /// (`src/codegen/digital/emit.zig` `program`, `device`) sets it back to `.lower`.
    diag_stage: diag.Stage = .lower,
    /// `resolution.resolveJoined`'s scratch, likewise, and how deep its
    /// calls are: only the outermost resets it.
    resolve_scratch: std.heap.ArenaAllocator,
    resolve_depth: u32 = 0,
    /// VAMS §7.3.5 the analog events digital event controls wait on
    /// (`registerMonitor`). The mixed-signal kernel evaluates each against the
    /// analog solution and delivers its A2D events (`deliverA2d`).
    monitors: std.ArrayList(Monitor) = .empty,
    /// VAMS §7.3.3 / §7.3.6.3: the potential `V(a)` / `V(a, b)` of the analog
    /// solution at the current digital time. Set by the mixed-signal kernel;
    /// a digital process that probes without it fails.
    probe: ?*const fn (ctx: *anyopaque, a: []const u8, b: ?[]const u8) Error!f64 = null,
    probe_ctx: *anyopaque = undefined,
    /// `Options.systf`.
    systf: ?UserSystf = null,
    /// Every statement's sites in compile order, outer before inner, while
    /// `Options.stmt_sites`; null otherwise.
    stmt_sites: ?std.ArrayList(StmtSite) = null,
    /// Set while a host has statement callbacks. A run recording statement
    /// sites checks it before each instruction, including after a calltf
    /// registers the first callback during a process run.
    stmt_hook: ?StmtHook = null,
    /// `DoneHook`'s statements while `Options.stmt_sites`: each one's last
    /// instruction, to the site it starts at.
    done_sites: std.AutoHashMapUnmanaged(u32, StmtSite) = .empty,
    /// The host's `DoneHook` (VPI's, set when it binds the run).
    done_hook: ?DoneHook = null,
    /// An `assign`/`force` `done_hook` will report: its process's first pc
    /// (an `override_eval`) to the statement's last pc.
    done_pending: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Some digital expression probes the analog solution (`probe`).
    has_probes: bool = false,
    /// Elaborating the digital half of a mixed-signal module (`Options.mixed`).
    mixed: bool = false,
    /// `Mixed.reads`: the analog variables declared here for `a2dWrite`.
    a2d_reads: []const []const u8 = &.{},
    /// `Mixed.inserts`, and each row's segment as an identifier expression
    /// (minted before pass one, while the expression tables can still grow).
    inserts: []const Insert = &.{},
    insert_segs: []const Ast.ExprId = &.{},
    /// VAMS §9.22 driver access and §9.22.6 segregation (`driver.zig`).
    drv: driver.State = .{},
    /// §3.3 the declared `[msb:lsb]` of every packed vector, by slot, so a
    /// bit-select can name its bit (IEEE 1364-2005 §5.2.1). A slot absent from
    /// here is `[width-1:0]`.
    vec_ranges: std.AutoHashMapUnmanaged(u32, VecRange) = .empty,
    /// Called after a `.vpi`-watched slot changed value and its waiters were
    /// woken. The VPI installs it; nothing else in the engine reads it.
    vpi_change: ?*const fn (r: *Run, slot: u32) void = null,
    /// IEEE 1364-2005 §12.3.11 "the sign attribute shall not cross
    /// hierarchy": a port that COLLAPSED onto its parent's net shares the
    /// parent's slot but keeps its own declaration's signedness. Keyed by the
    /// port's name in the child, and present only where the two differ.
    port_signed: std.AutoHashMapUnmanaged(Name, bool) = .empty,
    /// Pass one's slot space while it is still growing: the view `constant`
    /// evaluates a bound or a parameter against before `values` is final.
    growing: ?*std.ArrayList(Int.Literal) = null,
    /// §10.4.5: retained constant expressions (VPI attribute metadata) may
    /// be folded after slot allocation; their calls still have no runtime
    /// side effects and start with fresh function-local storage.
    folding_constant: bool = false,
    /// IEEE 1364-2005 §12.2.1 every `defparam`, by the scope its path is
    /// relative to and that path (`bindDefparam`, `paramValue`).
    /// Each value is evaluated in `decl`, the scope that declares it.
    defparams: std.HashMapUnmanaged(PathKey, struct { d: Ast.Defparam, decl: u32 }, PathKey.Ctx, 80) = .empty,
    /// Each defparam as pass one bound it, for §12.8.2's check against the
    /// complete hierarchy (`checkDefparams`).
    bound_defparams: std.ArrayList(struct { decl: u32, path: []const u8, at: u32, rest: []const u8, tok: u32 }) = .empty,
    /// `Mixed.params`: the root's parameter values on the host's card.
    card: []const Param = &.{},
    /// `Mixed.real_params`: only the real parameters the discrete side needs.
    real_card: []const Param = &.{},
    /// §12.2 parameter slots: constants an expression may fold, never a
    /// target.
    params: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// IEEE 1364-2005 §4.10.3 the parameters that are specparams, each to
    /// its declaration's token: "declared before it is referenced".
    specparams: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// IEEE 1364-2005 §4.8 `real` variables and VAMS §3.7 `wreal` nets: slots
    /// holding a double's 64 bits, which typing, conversion and change
    /// detection read as a real.
    reals: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// §17.6 the stochastic queues, by `q_id`.
    queues: std.AutoHashMapUnmanaged(i64, system.Queue) = .empty,
    /// §17.9.1 the seed of a `$random` called without one. §17.9.3's
    /// listing starts from 0, which its `uniform` reads as 259341593.
    random_seed: i32 = 0,
    /// VAMS §9.5.1.2 the host's descriptor table, when the simulation shares
    /// one between this engine and an analog device (the mixed runner
    /// installs the device's `file_io`); null, this engine's own
    /// (`system.table`).
    file_io: ?@import("contract").FileIo = null,
    /// §5.2.1 each part-select's constant `[msb:lsb]`, folded once by `infer`.
    part_selects: std.AutoHashMapUnmanaged(SpecExpr, VecRange) = .empty,
    /// §18 the value change dump.
    vcd: @import("vcd.zig").Vcd = .{},
    /// `vcd.catalog` of this run, built at the first dump.
    vcd_catalog: ?@import("vcd.zig").Catalog = null,
    /// §18.3 the `$dumpports` calls compile has checked.
    ports_dump: @import("evcd.zig").Check = .{},
    /// §18.3 the extended dump.
    evcd: @import("evcd.zig").Evcd = .{},
    /// IEEE 1364-2005 §15 every instance's timing checks (`tchk.zig`), in
    /// elaboration order.
    tchks: std.ArrayList(tchk.Tchk) = .empty,
    /// The checks a watched slot wakes, each as `check * 2 + event`.
    tchk_by_slot: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty,
    /// Called after timing check `check` (a `tchks` row) reported a
    /// violation. The VPI installs it (VAMS 12.31.4 cbTchkViolation);
    /// nothing in the engine reads it.
    tchk_hook: ?*const fn (r: *Run, check: u32) void = null,
    /// The source and options `elaborate` ran, which IEEE 1364-2005 C.7's
    /// reset elaborates again (`reset`).
    source: []const u8 = "",
    opts: Options = .{},
    /// `slot`'s answers by (scope, expression), direct-mapped, from the end
    /// of `elaborate`: every name is bound by then, so an answer never goes
    /// stale. Empty while elaborating.
    slot_memo: []SlotMemo = &.{},

    /// VAMS §8.5 / §8.4.3.2: the analog block reads `slot` outside any event
    /// guard, so it is implicitly sensitive to it and every change is an
    /// implicit D2A. From now on a change of it makes `runUntil` stop with
    /// `.analog` at region 3b of the tick it happened in.
    pub fn watchAnalog(r: *Run, at: u32) void {
        r.watch[at].insert(.analog);
    }

    /// VAMS §7.3.6.4: an analog variable a digital expression reads takes the
    /// value the analog block left it, as a write at the current tick, so a
    /// continuous assign over it re-evaluates like over any other operand.
    /// Table 7-1 in reverse: a real "with no conversion", an integer as itself.
    /// `assigned`: an analog event statement assigned it, which §7.3.6.1 makes
    /// an event "regardless of whether the variable changes value or not".
    pub fn a2dWrite(r: *Run, at: u32, v: f64, assigned: bool) Error!void {
        const cur = r.values[at];
        const real = r.reals.contains(at);
        const lit = if (real) try evaluate.realLiteral(r.arena, v) else blk: {
            const w = try filled(r.arena, 64, true, .zero);
            w.values()[0] = @bitCast(std.math.lossyCast(i64, v));
            break :blk try evaluate.normalize(r.arena, w, .{ .width = cur.width, .signed = cur.signed });
        };
        // `store`'s own test for a change, taken before it overwrites `cur`.
        const same = if (real) @as(f64, @bitCast(cur.planes[0])) == v else std.mem.eql(u64, cur.planes, lit.planes);
        try waiters.store(r, at, lit.planes);
        if (assigned and same) try waiters.wake(r, at, .x, .x);
    }

    /// VAMS §7.3.4 / §8.5: an analog event control waits on `edge` of `slot`
    /// (a variable, net or named event), as term `site` < 64. From now on the
    /// event makes `runUntil` stop with `.explicit_d2a` at region 1b of its
    /// tick, with bit `site` set in `d2a_fired`.
    pub fn watchEvent(r: *Run, at: u32, edge: waiters.Edge, site: u6) Error!void {
        r.watch[at].insert(.d2a);
        try r.d2a_sites.append(r.arena, .{ .slot = at, .edge = edge, .site = site });
    }

    /// VAMS §7.3.5: `cross`/`above`/`absdelta` as a term of a digital event control.
    /// The process waits on a slot no variable owns (counted down from the
    /// top of the slot space), which `deliverA2d` wakes.
    pub fn registerMonitor(r: *Run, e: Ast.ExprId) Error!void {
        if (!r.mixed or monitorKind(r, e) == .timer)
            return r.exprFail(e, "only cross(), above() and absdelta() are monitored in a digital event control");
        const scope = r.instanceOf(r.scope);
        if (r.monitorSlot(e, scope) != null) return;
        try r.addMonitor(e, std.math.maxInt(u32) - 1 - @as(u32, @intCast(r.monitors.items.len)));
    }

    /// A monitor of analog event `e` whose occurrence wakes `slot`'s waiters.
    fn addMonitor(r: *Run, e: Ast.ExprId, wakes: u32) Error!void {
        const args = r.file.exprs.args(e);
        if (args.len == 0 or args[0] == .none) return r.exprFail(e, "an analog event needs its expression");
        for (args) |arg| if (arg != .none) try compile.checkExpr(r, arg);
        try r.monitors.append(r.arena, .{ .expr = e, .scope = r.instanceOf(r.scope), .slot = wakes, .kind = monitorKind(r, e) });
    }

    fn monitorKind(r: *const Run, e: Ast.ExprId) MonitorKind {
        // The parser admits exactly A.6.5's four names as an event function.
        return std.meta.stringToEnum(MonitorKind, r.file.str(r.file.exprs.strOf(e))).?;
    }

    /// VAMS §5.10.4 / §7.3.6.1: `@(timer(..)) -> ev;` (or `cross`/`above`) in
    /// the analog block, with `ev` named by a digital process. The statement
    /// runs exactly when its analog event occurs, so that event, monitored,
    /// IS the A2D: its delivery wakes `ev`'s digital waiters. Only a trigger
    /// that is the event statement itself, or a top-level statement of its
    /// block, is carried (lowering refuses the rest, E0437).
    fn analogTriggers(r: *Run, m: *const Ast.ModuleDecl, named: *const std.AutoHashMapUnmanaged(Ast.StrId, void)) Error!void {
        const W = struct {
            r: *Run,
            named: *const std.AutoHashMapUnmanaged(Ast.StrId, void),
            pub fn expr(_: @This(), _: Ast.ExprId, _: Ast.SourceFile.Edge) Error!void {}
            pub fn stmt(w: @This(), s: Ast.StmtId) Error!void {
                if (s == .none) return;
                const f = w.r.file;
                switch (f.stmt(s)) {
                    .event_control => |c| if (c.event != .none and f.exprs.tag(c.event) == .event_function) {
                        const body: []const Ast.StmtId = switch (f.stmt(c.body)) {
                            .block => |b| b.body,
                            else => &.{c.body}, // else: a single statement is its own body
                        };
                        for (body) |t| switch (f.stmt(t)) {
                            .event_trigger => |tr| if (f.exprs.tag(tr.target) == .ident and w.named.contains(f.exprs.strOf(tr.target))) {
                                const at = w.r.lookup(w.r.scope, f.exprs.strOf(tr.target)) orelse continue;
                                if (w.r.events.contains(at)) try w.r.addMonitor(c.event, at);
                            },
                            else => {}, // else: only a trigger crosses to the digital context
                        };
                    },
                    else => {}, // else: other statements are searched through their children
                }
                try f.stmtEdges(s, w);
            }
        };
        for (m.analog) |ab| try (W{ .r = r, .named = named }).stmt(ab.body);
    }

    /// The slot whose waiters monitor `e` of instance `scope` wakes, or null
    /// when that event is not monitored. O(monitors).
    pub fn monitorSlot(r: *const Run, e: Ast.ExprId, scope: u32) ?u32 {
        for (r.monitors.items) |m| if (m.expr == e and m.scope == scope) return m.slot;
        return null;
    }

    /// Argument `k` of monitor `m`, evaluated as a real in the monitor's scope
    /// (`k` = 0 is the monitored expression), or null when absent.
    pub fn monitorArg(r: *Run, m: usize, k: usize) Error!?f64 {
        const mon = r.monitors.items[m];
        const args = r.file.exprs.args(mon.expr);
        if (k >= args.len or args[k] == .none) return null;
        const saved = r.scope;
        defer r.scope = saved;
        r.scope = mon.scope;
        var scratch = std.heap.ArenaAllocator.init(r.arena);
        defer scratch.deinit();
        return try evaluate.evalReal(r, scratch.allocator(), args[k]);
    }

    /// VAMS §7.3.6.1: monitor `m`'s event occurred; wake its waiters "at the
    /// nearest digital time tick to the time of the analog event", but "not
    /// ... earlier than the last or current digital event".
    pub fn deliverA2d(r: *Run, m: usize, tick: Tick) Error!void {
        const now = r.scheduler.now;
        _ = try exec.enqueue(r, .{ .a2d = r.monitors.items[m].slot }, if (tick > now) tick - now else null, false);
    }

    /// VAMS §8.4, IEEE 1364-2005 §17.1.3: the mixed kernel accepted an analog
    /// solution at tick `k`, which no digital event has reached. A standing
    /// monitor's probes may read a new value there, and a probe has no slot
    /// to wake it, so an event at `k` makes it a time step: `runUntil(k)`
    /// brings digital time to `k` and re-checks the monitor in region 4.
    /// False, with nothing queued, when no monitor probes or `k` has run.
    pub fn analogPoint(r: *Run, k: Tick) Error!bool {
        if (r.monitor_probes.len == 0 or !r.monitor_on or k <= r.scheduler.now) return false;
        _ = try exec.enqueue(r, .analog_point, k - r.scheduler.now, false);
        return true;
    }

    /// Dispatch every event at a time <= `limit` (IEEE 1364 §11.4's loop,
    /// VAMS §8.5.1's regions), then return with the queue holding only later
    /// work. `limit = maxInt` is the whole simulation, which is `run`. Calling
    /// again with a larger limit resumes; nothing is lost between calls
    /// because every suspended process is a waiter or a queued event.
    pub fn runUntil(r: *Run, limit: Tick) Error!Stop {
        std.debug.assert(!r.running);
        r.running = true;
        defer r.running = false;
        var scratch: exec.Scratch = .init(r.scratch_buf, &r.scratch);
        while (r.scheduler.nextUntil(limit)) |event| {
            scratch.reset();
            // A zero-delay loop (`always a = ~a;`) never lets time advance
            // (IEEE 1364 §11.4 has nothing to stop it); refuse it by name
            // instead of hanging the kernel at one tick.
            if (event.time != r.budget_time) {
                r.budget_time = event.time;
                r.budget_used = 0;
                // §8.5.1: monitor events "are continuously re-enabled in
                // every successive time step"; one that probes the analog
                // solution has no slot to wake it, so each step asks.
                if (r.monitor_probes.len != 0) try waiters.requestMonitor(r);
            }
            r.budget_used += 1;
            if (r.budget_used > r.budget)
                return r.fail(0, "more than {d} events at time {d}: a zero-delay loop keeps simulation time from advancing", .{ r.budget, event.time });
            if (event.region == .analog) {
                r.analog_pending = false;
                return .analog;
            }
            // §8.4.7 "Digital to analog events shall cause an analog solution
            // of the time where they occur": 1b is always followed by 3b.
            if (event.region == .explicit_d2a) {
                r.d2a_pending = false;
                try waiters.requestAnalog(r);
                return .explicit_d2a;
            }
            const item = r.pending.items[event.payload].item;
            switch (item) {
                .run_process => |start| {
                    r.ctx = 0;
                    try exec.execute(r, &scratch, start);
                },
                .@"resume" => |x| {
                    r.ctx = x.ctx;
                    try exec.makeResident(r, x.ctx);
                    try exec.execute(r, &scratch, x.pc);
                },
                .a2d => |at| try waiters.wakeA2d(r, at),
                .write => |w| try evaluate.write(r, scratch.allocator(), .{ .slot = w.target, .sel = w.sel }, w.value),
                .strobe => |s| {
                    r.scope = s.scope;
                    r.pc = s.pc;
                    // §17.2.2 `$fstrobe`: the same line, to its descriptor.
                    if (s.show.file)
                        try system.fdisplay(r, scratch.allocator(), s.args, s.show)
                    else
                        try display.display(r, s.args, scratch.allocator(), s.show);
                },
                .monitor_tick => {
                    r.monitor_pending = false;
                    if (try display.monitorDue(r, scratch.allocator())) try display.monitorPrint(r, scratch.allocator());
                    try display.fmonitorPrint(r, scratch.allocator());
                },
                .vcd_tick => try @import("vcd.zig").tick(r, scratch.allocator()),
                // `analogPoint`: only its time, at whose arrival above the
                // probing monitor was asked for.
                .analog_point => {},
                .tchk_expiry => |t| try tchk.expired(r, t.check, t.gen),
                .tran_switch => |at| {
                    const t = &r.trans[at];
                    t.pending = null;
                    t.state = t.target;
                    try resolution.resolve(r, t.a);
                    try resolution.resolve(r, t.b);
                },
                // §6.1.3: the scheduler drops a cancelled transition, so what
                // arrives is the one still in flight.
                .drive => |at| {
                    const d = &r.drivers[at];
                    const t = &r.transitions.items[d.transition]; // a `.drive` event has its row
                    t.in_flight = null;
                    @memcpy(d.current.planes, t.target.planes);
                    d.or_z = t.or_z;
                    try resolution.resolve(r, d.net);
                },
                .net_update => |at| {
                    const n = r.nets[at];
                    const c = try r.netColdMut(at); // a delayed net has its row
                    c.transition.in_flight = null;
                    try waiters.store(r, n.slot, c.transition.target.planes);
                },
                // §3.8: the charge has been held for the decay time, and what a
                // trireg holds once it is worth nothing is x.
                .decay => |at| {
                    const n = &r.nets[at];
                    (try r.netColdMut(at)).decay_event = null; // a decaying trireg has its row
                    for (0..n.resolved.width) |i| setBit(n.resolved, @intCast(i), .x);
                    try waiters.store(r, n.slot, n.resolved.planes);
                },
            }
            // Freed only now: the `.write` planes above are this row's own, and
            // nothing dispatched may reuse them before `store` has copied them.
            try r.free_rows.append(r.arena, event.payload);
        }
        // `Scheduler.sync_at`: the queue stopped at that time's inactive point.
        if (r.scheduler.synced) {
            r.scheduler.synced = false;
            return .vpi_sync;
        }
        return .idle;
    }

    /// IEEE 1364-2005 §12.6 the scope a hierarchical name's first part
    /// names, seen from the executing instance: an instance declared there
    /// (a downward reference, step a), else in each enclosing instance in
    /// turn (steps b and c), where an enclosing instance of the module so
    /// named also answers (Syntax 12-7 `module_identifier.item_name`). The
    /// root is an instance of its module. Null when nothing up to the root
    /// has that name. A named block, task, function or generate block is a
    /// scope too (§12.5), found by its name inside the scope around it and,
    /// from within, by its own.
    pub fn upward(self: *const Run, name: Ast.StrId) ?u32 {
        var s = self.scope;
        while (true) {
            if (self.instances.get(.{ .scope = s, .str = name })) |child| return child;
            const info = self.scope_info.items[s];
            if (info.lexical) {
                if (info.name == name and info.index == null) return s;
                s = info.parent;
                continue;
            }
            if (self.file.modules[info.def].name == name) return s;
            // §12.5: a top-level module's name starts a hierarchical name
            // anywhere in the design.
            if (isRoot(self, s)) {
                for (self.roots) |t| if (self.scope_info.items[t].name == name) return t;
                return null;
            }
            s = self.instanceOf(self.scope_info.items[s].parent);
        }
    }

    /// The slot a name is stored in, or null when the design declares no such
    /// variable or net. `name` is a root-scope name or a §6.7 downward path
    /// (`u.v.q`: every part but the last an instance), which is the spelling
    /// an analog compile's flatten gives a child's name (`elaborate.sep`).
    /// `values[slot]` is its current value; this is how a caller outside the
    /// engine reads one.
    pub fn slotOf(self: *const Run, name: []const u8) ?u32 {
        var scope: u32 = 0;
        var parts = std.mem.splitScalar(u8, name, '.');
        var part = parts.first();
        while (parts.next()) |next| : (part = next) {
            const inst = self.file.strings.find(part) orelse return null;
            scope = self.instances.get(.{ .scope = scope, .str = inst }) orelse return null;
        }
        const str = self.file.strings.find(part) orelse return null;
        return self.names.get(.{ .scope = scope, .str = str });
    }

    /// Net `n`'s cold row, or `NetCold.none` when it has none.
    pub fn netCold(self: *const Run, n: Net) *const NetCold {
        return if (n.cold == no_cold) &NetCold.none else &self.net_cold.items[n.cold];
    }

    /// Net `net`'s driver rows (`drivers` indices), in declaration order;
    /// none until pass two has grouped them (`elaborate`).
    pub fn netDrivers(self: *const Run, net: u32) []const u32 {
        if (net + 1 >= self.net_driver_start.len) return &.{};
        return self.net_drivers[self.net_driver_start[net]..self.net_driver_start[net + 1]];
    }

    /// Driver `at`'s §6.1.3 transition row, made on first use. Invalidates
    /// pointers to other rows when it makes one.
    pub fn driverTransition(self: *Run, at: u32) Error!*Inertial {
        const d = &self.drivers[at];
        if (d.transition == no_transition) {
            try self.transitions.append(self.arena, .{});
            d.transition = @intCast(self.transitions.items.len - 1);
        }
        return &self.transitions.items[d.transition];
    }

    /// Net `net`'s cold row, made on first use. Invalidates pointers to
    /// other cold rows when it makes one.
    pub fn netColdMut(self: *Run, net: u32) Error!*NetCold {
        const n = &self.nets[net];
        if (n.cold == no_cold) {
            n.cold = @intCast(self.net_cold.items.len);
            try self.net_cold.append(self.arena, .{});
        }
        return &self.net_cold.items[n.cold];
    }

    /// Adds an E1100 diagnostic at token `tok` (clamped to the last token)
    /// and returns `error.DigitalFailed` for the caller to propagate.
    pub fn fail(self: *Run, tok: u32, comptime fmt: []const u8, args: anytype) Error {
        return self.failWith(.E1100, tok, fmt, args);
    }
    /// The stage a diagnostic raised now belongs to (`diag_stage`, #72).
    pub fn stage(self: *const Run) diag.Stage {
        return self.diag_stage;
    }
    /// `fail` under a rule's own code, for a refusal the analog side reports.
    pub fn failWith(self: *Run, code: diag.Code, tok: u32, comptime fmt: []const u8, args: anytype) Error {
        const start = self.starts[@min(tok, self.starts.len - 1)];
        self.bag.add(self.stage(), code, .{ .start = start, .end = start }, fmt, args) catch return error.OutOfMemory;
        return error.DigitalFailed;
    }
    /// A walk ran out of the stack `deep.runGuarded` reserved, at token `tok`.
    pub fn deepFail(self: *Run, tok: u32) Error {
        return self.fail(tok, deep.message, .{deep.mib()});
    }
    /// `fail` at expression `e`'s main token, with a fixed message.
    pub fn exprFail(self: *Run, e: Ast.ExprId, comptime msg: []const u8) Error {
        return self.fail(self.file.exprs.mainTok(e), "{s}", .{msg});
    }
    /// §12.5 a hierarchical reference: the first part is a scope `upward`
    /// finds, every later part but the last names an instance declared in
    /// the scope before it, and the last is a declared name in the scope the
    /// final instance minted.
    pub fn slot(self: *Run, e: Ast.ExprId) Error!u32 {
        if (self.slot_memo.len == 0) return self.resolveSlot(e);
        const key = @backingInt(e) *% 0x9e3779b1 ^ self.scope *% 0x85ebca6b;
        const m = &self.slot_memo[key >> (32 - memo_bits)];
        if (m.scope == self.scope and m.e == e) return m.at;
        const at = try self.resolveSlot(e);
        m.* = .{ .scope = self.scope, .e = e, .at = at };
        return at;
    }
    fn resolveSlot(self: *Run, e: Ast.ExprId) Error!u32 {
        const ex = &self.file.exprs;
        if (ex.tag(e) == .hier_ident) {
            const parts = ex.nameParts(e);
            var scope: u32 = 0;
            // §12.4.1 a select the parser could not fold (`target[i]`, `i` a
            // genvar) is spelled `name[]`, its index expressions in order.
            const indices = self.file.hierIndices(ex.mainTok(e));
            var used: usize = 0;
            for (parts[0 .. parts.len - 1], 0..) |spelled, k| {
                const text = self.file.str(spelled);
                // One `name[]`: the element's scope row, whether or not the
                // source spells `name[<v>]` anywhere.
                if (std.mem.endsWith(u8, text, "[]") and std.mem.findScalar(u8, text, '[').? == text.len - 2) {
                    scope = try self.elementScope(ex.mainTok(e), text[0 .. text.len - 2], if (k == 0) null else scope, indices, &used);
                    continue;
                }
                const part = if (std.mem.find(u8, text, "[]") == null) spelled else try self.foldSelects(ex.mainTok(e), text, indices, &used);
                const next = if (k == 0) self.upward(part) else self.instances.get(.{ .scope = scope, .str = part });
                scope = next orelse return if (std.mem.findScalar(u8, self.file.str(part), '[') != null)
                    self.fail(self.file.exprs.mainTok(e), "§12.5: `{s}`: an instance select out of range, or of no array", .{self.file.str(part)})
                else if (self.sub_by_name.get(.{ .scope = if (k == 0) self.instanceOf(self.scope) else scope, .str = part })) |idx| if (self.subs.items[idx].decl.automatic)
                    self.fail(self.file.exprs.mainTok(e), "§10.2.1: `{s}` is automatic: its items cannot be accessed by hierarchical references", .{self.file.str(part)})
                else
                    self.exprFail(e, "undeclared instance in a hierarchical reference") else self.exprFail(e, "undeclared instance in a hierarchical reference");
            }
            return self.names.get(.{ .scope = scope, .str = parts[parts.len - 1] }) orelse
                self.exprFail(e, "undeclared digital variable");
        }
        if (ex.tag(e) != .ident) return self.exprFail(e, "only whole-variable lvalues are implemented");
        return self.lookup(self.scope, ex.strOf(e)) orelse self.exprFail(e, "undeclared digital variable");
    }
    /// `text`, a part of the hierarchical name at token `tok` with `[]`
    /// selects, with each one's index from `indices` (from `used` on) folded
    /// in this scope: the spelling of an instance or generate block name
    /// (`SourceFile.hierIndices`).
    pub fn foldSelects(self: *Run, tok: u32, text: []const u8, indices: []const Ast.ExprId, used: *usize) Error!Ast.StrId {
        var out: std.Io.Writer.Allocating = .init(self.arena);
        var rest = text;
        while (std.mem.find(u8, rest, "[]")) |at| {
            if (used.* == indices.len) return self.fail(tok, "§12.5: a hierarchical select has no index", .{});
            const v = (try self.constant(indices[used.*], tok)).asInt() orelse return self.fail(tok, "§12.5: a hierarchical select's index has an x or z bit", .{});
            used.* += 1;
            try out.writer.print("{s}[{d}]", .{ rest[0..at], v });
            rest = rest[at + 2 ..];
        }
        try out.writer.writeAll(rest);
        return self.file.strings.find(out.written()) orelse
            self.fail(tok, "§12.5: `{s}`: an instance select out of range, or of no array", .{out.written()});
    }
    /// The scope of element `<next index>` of the instance array or loop
    /// generate `base` declared in `parent`, or, with no parent (the first
    /// part of a §12.5 name), in the nearest scope upward that has one.
    fn elementScope(self: *Run, tok: u32, base: []const u8, parent: ?u32, indices: []const Ast.ExprId, used: *usize) Error!u32 {
        if (used.* == indices.len) return self.fail(tok, "§12.5: a hierarchical select has no index", .{});
        const v = (try self.constant(indices[used.*], tok)).asInt() orelse return self.fail(tok, "§12.5: a hierarchical select's index has an x or z bit", .{});
        used.* += 1;
        const found: ?u32 = blk: {
            const name = self.file.strings.find(base) orelse break :blk null;
            if (parent) |p| break :blk compile.element(self, p, name, v);
            var s = self.scope;
            while (true) : (s = self.scope_info.items[s].parent) {
                if (compile.element(self, s, name, v)) |at| break :blk at;
                if (self.scope_info.items[s].parent == s) break :blk null;
            }
        };
        return found orelse self.fail(tok, "§12.5: `{s}[{d}]`: an instance select out of range, or of no array", .{ base, v });
    }
    /// The slot event term `e` watches: a name's own, or the hidden one a
    /// §9.7.2 expression term keeps (`term_slots`).
    pub fn termSlot(self: *Run, e: Ast.ExprId) Error!u32 {
        return self.term_slots.get(.{ .scope = self.scope, .e = e }) orelse self.slot(e);
    }
    /// The type a slot's value has, for an assignment to it.
    pub fn slotType(self: *const Run, at: u32) compile.Type {
        if (self.reals.contains(at)) return compile.real_type;
        return .{ .width = self.values[at].width, .signed = self.values[at].signed };
    }

    /// `vpi.zig`'s requests from a VPI application, called as methods.
    pub const vpiEval = vpi.vpiEval;
    pub const vpiConstantIndex = vpi.vpiConstantIndex;
    pub const vpiPutUdp = vpi.vpiPutUdp;
    pub const vpiAttributeValue = vpi.vpiAttributeValue;
    pub const tchkSite = vpi.tchkSite;
    /// IEEE 1364-2005 §27.31 / VAMS §12.29 vpi_put_delays on the timing check
    /// whose command token is `tok` in instance `scope`: `ticks` are its
    /// limits in A.7.5.1's written order, from the next event it judges.
    /// False when the run holds no such check.
    pub const tchkLimits = tchk.putLimits;

    /// IEEE 1364-2005 C.7 `$reset`: "return the processing of the design to
    /// its logical state at time 0": every process, override and scheduled
    /// event dropped, the time 0, "All regs and nets contain their initial
    /// values", and the first statement of every initial and always block
    /// next. The run is elaborated again from the source and options it was
    /// made from, into the same arena, so every slot, scope, pc and check
    /// keeps its number and what a host holds by number stays valid. What a
    /// host installed over the run is kept (docs/specification/Vague_Decisions.md VD-106):
    /// its hooks, its value-change watches, and the delays and timing check
    /// limits it put. Each reset leaves the old run's memory in the arena.
    pub fn reset(self: *Run) Error!void {
        // ponytail: a long run of resets wants the run in an arena of its own.
        // Its warnings are the first elaboration's again.
        var quiet = diag.Bag.init(self.arena);
        var fresh = elaborate(self.arena, self.source, self.opts, &quiet, self.out) catch |e| switch (e) {
            error.DigitalFailed => return self.fail(0, "IEEE 1364-2005 C.7: the reset could not elaborate the design again", .{}),
            else => |other| return other,
        };
        if (fresh.watch.len != self.watch.len or fresh.drivers.len != self.drivers.len or fresh.tchks.items.len != self.tchks.items.len)
            return self.fail(0, "IEEE 1364-2005 C.7: the design elaborated again into a different shape", .{});
        fresh.bag = self.bag;
        fresh.vpi_change = self.vpi_change;
        fresh.done_hook = self.done_hook;
        fresh.stmt_hook = self.stmt_hook;
        fresh.tchk_hook = self.tchk_hook;
        fresh.file_io = self.file_io;
        fresh.probe = self.probe;
        fresh.probe_ctx = self.probe_ctx;
        for (self.watch, fresh.watch) |old, *w| if (old.contains(.vpi)) w.insert(.vpi);
        for (self.drivers, fresh.drivers) |old, *d| d.delay = old.delay;
        for (self.tchks.items, fresh.tchks.items) |old, *c| c.lim = old.lim;
        self.* = fresh;
    }

    /// §12.7 a name as seen from `scope`: declared there, or in an enclosing
    /// scope of the same module, never across an instance boundary.
    pub fn lookup(self: *const Run, scope: u32, str: Ast.StrId) ?u32 {
        var s = scope;
        while (true) {
            if (self.names.get(.{ .scope = s, .str = str })) |at| return at;
            const info = self.scope_info.items[s];
            if (!info.lexical) return null;
            s = info.parent;
        }
    }
    /// The scope whose parameters decide every type, part-select bound and
    /// replication count in `scope`: the nearest instance (§12.2) or §12.4.1
    /// loop-generate iteration (its genvar is a local parameter) at or above
    /// it. A named block or a task frame declares names from its instance's
    /// parameters, so it shares its instance's types.
    pub fn specOf(self: *const Run, scope: u32) u32 {
        var s = scope;
        while (s < self.scope_info.items.len) {
            const info = self.scope_info.items[s];
            if (!info.lexical or info.index != null) break;
            s = info.parent;
        }
        return s;
    }
    /// The instance a (possibly nested) scope belongs to.
    pub fn instanceOf(self: *const Run, scope: u32) u32 {
        var s = scope;
        while (self.scope_info.items[s].lexical) s = self.scope_info.items[s].parent;
        return s;
    }
    /// IEEE 1364 §19.8 the time scale of the module `scope` is an instance
    /// (or a block) of: the one its delays, `$time` and `%t` are in. The
    /// root's when the scope is not a module instance (a UDP's).
    pub fn timeOf(self: *const Run, scope: u32) ModuleTime {
        const root_time: ModuleTime = .{ .scale = self.scale.?, .unit_exp = self.unit_exp };
        if (scope >= self.scope_info.items.len) return root_time;
        return self.module_times[self.scope_info.items[self.instanceOf(scope)].def];
    }
    /// A constant expression's value at elaboration (IEEE 1364-2005 §5.2 /
    /// §12.2): literals, parameters, operators and the constant system
    /// functions, folded by the engine's own evaluator, so a bound and a
    /// run-time expression cannot disagree about an operator. The result's
    /// planes are fresh arena memory, never a literal's own.
    pub fn constant(self: *Run, e: Ast.ExprId, tok: u32) Error!Int.Literal {
        if (self.growing) |g| self.values = g.items;
        try compile.checkExpr(self, e);
        if (!compile.constantExpression(self, e)) return self.fail(tok, "a constant expression is required here", .{});
        const v = try evaluate.eval(self, self.arena, e, 0);
        const out = try filled(self.arena, v.width, v.signed, .zero);
        @memcpy(out.planes, v.planes);
        return out;
    }
    /// One declared bound (§3.3, §4.3.1): any constant expression, of any
    /// sign (the §4.3.1 example `[-2:1]`).
    pub fn declaredBound(self: *Run, e: Ast.ExprId, tok: u32) Error!i64 {
        if (self.file.exprs.tag(e) == .int_literal) return self.file.exprs.intValue(e);
        const v = try self.constant(e, tok);
        // §4.3.1: "Both the msb constant expression and the lsb constant
        // expression shall be constant integer expressions."
        if (compile.typeOf(self, e).real) return self.fail(tok, "§4.3.1: a bound is a constant integer expression, not a real", .{});
        return v.asInt() orelse self.fail(tok, "a declaration bound cannot contain x or z", .{});
    }
    /// A.2.2.3 `delay_value ::= unsigned_number | real_number | identifier`, in
    /// scheduler ticks. Folded at elaboration: a net's or a driver's delay is
    /// fixed for the run, and only a procedural `#` re-evaluates.
    ///
    /// The `identifier` alternative names a parameter, so anything but a
    /// literal goes through `constant`.
    fn declaredDelay(self: *Run, e: Ast.ExprId, tok: u32) Error!u64 {
        const scale = self.timeOf(self.scope).scale;
        return switch (self.file.exprs.tag(e)) {
            .real_literal => scale.realDelay(self.file.exprs.realValue(e)),
            .int_literal => scale.signedDelay(self.file.exprs.intValue(e)),
            else => blk: { // else: any other form is a constant expression, which `constant` folds or refuses
                const v = try self.constant(e, tok);
                // §9.7.1: a real parameter is rounded to the precision like a
                // real literal, not truncated to the unit.
                if (compile.typeOf(self, e).real) break :blk scale.realDelay(try evaluate.evalReal(self, self.arena, e));
                break :blk scale.signedDelay(v.asInt() orelse return self.fail(tok, "a declared delay cannot contain x or z", .{}));
            },
        } catch self.fail(tok, "digital delay cannot be represented", .{});
    }

    /// One A.2.2.3 `delay3` as the three tick counts §7.14 chooses between. A
    /// two-value form's `off` is "the smallest of the delays".
    pub fn declaredDelay3(self: *Run, d: Ast.Delay3, tok: u32) Error!Delay {
        if (!d.any()) return .{};
        var out: Delay = .{ .present = true };
        out.rise = try self.declaredDelay(d.rise, tok);
        out.fall = try self.declaredDelay(d.fall, tok);
        out.off = if (d.off != .none) try self.declaredDelay(d.off, tok) else @min(out.rise, out.fall);
        return out;
    }

    /// §3.3/§6.5.2 a packed `[msb:lsb]` range as a bit width.
    pub fn declaredWidth(self: *Run, range: Ast.Dim, tok: u32) Error!u32 {
        const hi = try self.declaredBound(range.msb, tok);
        const lo = try self.declaredBound(range.lsb, tok);
        const span = @abs(@as(i128, hi) - lo);
        if (span >= std.math.maxInt(u32)) return self.fail(tok, "packed range is outside the supported u32 width", .{});
        return @intCast(span + 1);
    }
    /// Binds `name` to slot `at` in the current scope (`scope`). A second
    /// declaration of one name in one scope fails at `tok` (E1100).
    pub fn bind(self: *Run, name: Ast.StrId, at: u32, tok: u32) Error!void {
        const entry = try self.names.getOrPut(self.arena, .{ .scope = self.scope, .str = name });
        if (entry.found_existing) return self.fail(tok, "duplicate digital variable", .{});
        entry.value_ptr.* = at;
    }
    /// A vector slot's declared `[msb:lsb]` (an array's first element's is
    /// every element's), `[w-1:0]` when it declares none.
    pub fn vecRange(self: *const Run, at: u32) VecRange {
        return self.vec_ranges.get(at) orelse .{ .msb = @as(i64, self.values[at].width) - 1, .lsb = 0 };
    }
    /// §4.3: "A net or reg declaration without a range specification shall
    /// be considered 1 bit wide and is known as a scalar."
    pub fn isScalar(self: *const Run, at: u32) bool {
        return self.values[at].width == 1 and !self.vec_ranges.contains(at) and !self.params.contains(at);
    }
    /// The slot an lvalue's width comes from: an array element reference is as
    /// wide as element zero, so a parked value can be sized before §8.5.3.3
    /// resolves which element it lands in.
    pub fn baseSlot(self: *Run, e: Ast.ExprId) Error!u32 {
        const ex = &self.file.exprs;
        return if (ex.tag(e) == .index) self.slot(self.chainBase(e).base) else self.scalarSlot(e);
    }
    /// The name at the bottom of a stack of selects, `a` in `a[i][j]`, and
    /// how many selects stand on it.
    pub fn chainBase(self: *const Run, e: Ast.ExprId) struct { base: Ast.ExprId, depth: u32 } {
        const ex = &self.file.exprs;
        var x = e;
        var depth: u32 = 0;
        while (ex.tag(x) == .index) : (depth += 1) x = ex.lhs(x);
        return .{ .base = x, .depth = depth };
    }
    /// The slot of a reference to one whole value. §3.9's unpacked array has
    /// no value of its own, only its elements do, so a bare array name fails.
    pub fn scalarSlot(self: *Run, e: Ast.ExprId) Error!u32 {
        const at = try self.slot(e);
        if (self.arrays.contains(at)) return self.exprFail(e, "an unpacked array reference requires an element index");
        return at;
    }
    /// The array an `.index` names an element of (one index per dimension,
    /// §4.9), or null when it is a bit or part select.
    pub fn indexedArray(self: *Run, e: Ast.ExprId) Error!?Array {
        const ex = &self.file.exprs;
        if (ex.tag(e) != .index) return null;
        const c = self.chainBase(e);
        if (ex.tag(c.base) != .ident and ex.tag(c.base) != .hier_ident) return null;
        const arr = self.arrays.get(try self.slot(c.base)) orelse return null;
        if (c.depth != 1 + arr.rest.len) return null;
        // IEEE 1364-2005 §5.2.2: "the desired word shall first be selected by
        // supplying an address for each dimension"; a range there would
        // select several elements, which §4.9 never assigns or reads.
        var at = e;
        while (ex.tag(at) == .index) : (at = ex.lhs(at)) switch (ex.tag(ex.rhs(at))) {
            .range, .indexed_range => return self.exprFail(ex.rhs(at), "§5.2.2: each array dimension takes an index, not a part-select"),
            else => {}, // else: an element index
        };
        return arr;
    }
};

// ---- the rows and tables `Run` holds ----------------------------------------

/// A defparam path relative to a scope, spelled as `Ast.Defparam.path` is.
pub const PathKey = struct {
    scope: u32,
    path: []const u8,
    /// Hashes and compares the path's bytes, not its pointer.
    pub const Ctx = struct {
        pub fn hash(_: Ctx, k: PathKey) u64 {
            return std.hash.Wyhash.hash(k.scope, k.path);
        }
        pub fn eql(_: Ctx, a: PathKey, b: PathKey) bool {
            return a.scope == b.scope and std.mem.eql(u8, a.path, b.path);
        }
    };
};

/// Is `scope` a top-level module's instance? The first is scope 0; every
/// other is its own parent.
pub fn isRoot(r: *const Run, scope: u32) bool {
    return scope == 0 or r.scope_info.items[scope].parent == scope;
}

/// §10 one subroutine as the engine runs it: the declaration, the instance
/// that declared it, and its static frame. `entry` is the pc of its body
/// compiled for a synchronous call; a task with timing controls has none,
/// and is inlined at each enable instead (`ranges` are those copies, for
/// §10.3's `disable`).
pub const Sub = struct {
    decl: *const Ast.Subroutine,
    inst: u32,
    frame: Frame,
    /// `frame` is minted: every sub is once its instance is declared.
    framed: bool = false,
    entry: u32 = 0,
    /// `entry` is set: `compile.compileSub` has run.
    compiled: bool = false,
    timed: ?bool = null,
    /// A §10.4.5 constant function, once asked (`compile.constantFunction`).
    constant: ?bool = null,
    /// Synchronous activations in progress.
    active: u32 = 0,
    /// Being inlined right now, which a timed task reaching itself would be.
    inlining: bool = false,
    /// A timed task that reaches itself: its body compiled once out of line,
    /// over a frame of its own, entered by `.call_timed` (§10.2.3). The
    /// activation whose storage the frame holds is `resident`.
    body: ?struct { entry: u32, frame: Frame } = null,
    resident: u32 = 0,
    ranges: std.ArrayList(struct { start: u32, end: u32 }) = .empty,
};

/// One `Run.slot_memo` entry; `scope` maxInt(u32) is empty.
const SlotMemo = struct {
    scope: u32 = std.math.maxInt(u32),
    e: Ast.ExprId = .none,
    at: u32 = 0,

    // Budget: 4096 rows of 12 B, 48 KiB, inside L2.
    comptime {
        std.debug.assert(@sizeOf(SlotMemo) == 12);
    }
};

/// log2 of `Run.slot_memo`'s length: 4096 entries, 48 KiB.
const memo_bits = 12;

/// A module's §19.8 time scale, and its unit as a power of ten of a second.
const ModuleTime = struct { scale: Time.Scale, unit_exp: i32 };

/// §9.3 one slot's procedural continuous assignments: the pc range of the
/// process maintaining each.
pub const Overrides = struct {
    assign: ?PcRange = null,
    force: ?PcRange = null,
    /// IEEE 1364-2005 §9.3.2 forces of constant selects of the net, each
    /// holding its own bits.
    parts: std.ArrayList(PartForce) = .empty,
};

/// One `force` of a constant select (§9.3.2): the bits it holds and the
/// process maintaining them.
const PartForce = struct { bits: compile.Bits, range: PcRange };

/// A half-open range of `Run.code` pcs, `[start, end)`: one process body.
/// Empty for a VPI force, which no process maintains (`waiters.forceValue`).
pub const PcRange = struct { start: u32, end: u32 };

/// One activation's storage: a scope, a slot per formal, the result slot of
/// a function, and the contiguous slot range an automatic activation saves.
pub const Frame = struct { scope: u32, ports: []const u32, result: u32, first: u32, count: u32 };

/// `Run.net_of`: the net a slot is, as one `u32` a slot up to the last net's
/// slot (`none` for a variable's). Dense rather than a hash map: one net per
/// element of an unpacked net array makes nets the common slot, and a map
/// row costs twice an entry here plus the rehash garbage, for a lookup that
/// is a load instead of a probe.
const SlotNets = struct {
    of: std.ArrayList(u32) = .empty,

    const none = std.math.maxInt(u32);

    /// The net slot `slot` is, or null for a variable's slot.
    pub fn get(self: *const SlotNets, slot: u32) ?u32 {
        if (slot >= self.of.items.len) return null;
        const net = self.of.items[slot];
        return if (net == none) null else net;
    }

    /// Is slot `slot` a net's?
    pub fn contains(self: *const SlotNets, slot: u32) bool {
        return self.get(slot) != null;
    }

    /// Records that `slot` is net `net`, growing the table to `slot + 1`
    /// rows from `arena`. Asserts `net` is not the reserved maxInt(u32).
    pub fn put(self: *SlotNets, arena: std.mem.Allocator, slot: u32, net: u32) Error!void {
        std.debug.assert(net != none);
        const len = self.of.items.len;
        if (slot >= len) try self.of.appendNTimes(arena, none, slot + 1 - len);
        self.of.items[slot] = net;
    }
};

// ---- the driver (§6.2.2, §6.1, §7.9, §17.3) ---------------------------------

/// IEEE 1364-2005 §19.8: "If there is no `timescale specified or it has been
/// reset by a `resetall directive, the time unit and precision are
/// simulator-specific." Not an error: this simulator's are one second,
/// unit and precision alike, which makes every delay a whole count of units
/// and `$time`, `$realtime` and `%t` print the numbers the source wrote.
const default_quantum: Time.Quantum = .s;

/// Runs `source` to completion: `elaborate`, then every event. `arena` and
/// `bag` must outlive the call; the transcript goes to `out`.
pub fn run(arena: std.mem.Allocator, source: []const u8, opts: Options, bag: *diag.Bag, out: *std.Io.Writer) Error!void {
    return deep.runGuarded(0, runDeep, .{ arena, source, opts, bag, out });
}

fn runDeep(arena: std.mem.Allocator, source: []const u8, opts: Options, bag: *diag.Bag, out: *std.Io.Writer) Error!void {
    var r = try elaborate(arena, source, opts, bag, out);
    // Nothing is `watchAnalog`ed in a digital-only run, so it never stops early.
    _ = try r.runUntil(std.math.maxInt(Tick));
    try @import("evcd.zig").close(&r);
}

/// `Mixed.timescales` with the first event moved to offset 0. The analog
/// compile's text opens with VerA's own Annex D/E prelude, ahead of every
/// directive the source wrote, and §19.8's "some modules have a `timescale
/// specified and others do not" is about the source's modules, not those.
fn mixedTimescales(arena: std.mem.Allocator, events: []const Front.Preprocessor.TimescaleEvent) Error![]const Front.Preprocessor.TimescaleEvent {
    const out = try arena.dupe(Front.Preprocessor.TimescaleEvent, events);
    if (out.len != 0) out[0].at = 0;
    return out;
}

/// Everything `run` does before the first event dispatches: preprocess,
/// parse, §6.2.2 elaboration, and every driver and process compiled and
/// enqueued at time 0. The returned `Run` owns nothing outside `arena`, so a
/// caller that holds it may step it with `runUntil` for as long as the arena
/// lives, as a mixed-signal coordinator does.
pub fn elaborate(arena: std.mem.Allocator, source: []const u8, opts: Options, bag: *diag.Bag, out: *std.Io.Writer) Error!Run {
    return deep.runGuarded(0, elaborateDeep, .{ arena, source, opts, bag, out });
}

fn elaborateDeep(arena: std.mem.Allocator, source: []const u8, opts: Options, bag: *diag.Bag, out: *std.Io.Writer) Error!Run {
    const pp: Front.Preprocessor.Output = if (opts.mixed) |mx| .{
        .text = source,
        .directives = .{ .timescales = try mixedTimescales(arena, mx.timescales) },
    } else Front.Preprocessor.process(arena, source, .{ .file_name = opts.file_name, .include_dirs = opts.include_dirs, .std_defs = false, .more = more: {
        const more = try arena.alloc(Front.Preprocessor.File, opts.more.len);
        for (opts.more, more) |u, *f| f.* = .{ .name = u.name, .text = u.text };
        break :more more;
    }, .bag = bag }) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.PreprocessFailed => error.DigitalFailed,
    };
    const text = pp.text;
    const times = pp.directives.timescales;
    const drives = pp.directives.drives;
    var tokens = try Front.Lexer.Lexer.tokenize(arena, text);
    var parser = Front.Parser.Parser.init(arena, text, tokens.items(.tag), tokens.items(.start), bag);
    parser.digital = true;
    parser.setLanguage(opts.language);
    // A failed parse still leaves every recovered module in `parser.file`, and
    // the `wreal` refusal is itself a parse error, so the rules read that.
    // Arena-owned, not a local: the returned `Run` points at it. Elaboration
    // writes an overlay of the parse, never the parse.
    const parse = try arena.create(Ast.SourceFile);
    parse.* = parser.parseSourceFile() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseError => parser.file,
    };
    const parsed: *const Ast.SourceFile = parse;
    const file = try arena.create(Ast.SourceFile);
    file.* = parsed.overlay(.{});
    try Front.wreal.check(file, tokens.items(.start), bag);
    if (bag.failed()) return error.DigitalFailed;
    var r: Run = .{ .arena = arena, .file = file, .text = text, .starts = tokens.items(.start), .bag = bag, .out = out, .values = &.{}, .scheduler = Scheduler.init(arena), .file_name = opts.file_name, .io = opts.io, .drives = drives, .nettypes = pp.directives.nettypes, .mixed = opts.mixed != null, .a2d_reads = if (opts.mixed) |mx| mx.reads else &.{}, .card = if (opts.mixed) |mx| mx.params else &.{}, .real_card = if (opts.mixed) |mx| mx.real_params else &.{}, .budget = opts.event_budget, .systf = opts.systf, .stmt_sites = if (opts.stmt_sites) .empty else null, .source = source, .opts = opts, .scratch_buf = try arena.alloc(u8, exec.scratch_fixed_bytes), .scratch = .init(arena), .resolve_scratch = .init(arena) };
    try binding.libraries(&r, file, opts, pp.more_starts);
    // IEEE 1364-2005 §8.1's rules hold for every UDP declaration, whether or
    // not an instance uses it.
    for (file.udps) |*u| try elab.checkUdp(&r, u);
    var tops: []const u32 = &.{};
    const m = if (opts.mixed) |mx| for (file.modules) |*c| {
        if (file.strings.eql(c.name, mx.top)) break c;
    } else return r.fail(0, "the mixed-signal root module is not in the source", .{}) else blk: {
        if (file.modules.len == 0 or file.disciplines.len != 0 or file.natures.len != 0 or file.paramsets.len != 0 or file.connectrules.len != 0) return r.fail(0, "digital execution requires ordinary modules and no analog declarations", .{});
        tops = try elab.pickTops(&r, file.modules);
        break :blk &file.modules[tops[0]];
    };
    // IEEE 1364 §19.8: a `timescale applies to "all modules that follow this
    // directive until another `timescale compiler directive is read", so each
    // definition takes the last directive before it. A null value is §19.6's
    // `resetall, which returns to "none specified", the simulator-specific
    // default. The preprocessor refuses a malformed directive where it is
    // written (E0142). A mixed design's first timescale is moved to offset 0
    // (`mixedTimescales`).
    const Local = struct { unit: Time.Quantum = default_quantum, precision: Time.Quantum = default_quantum, set: bool = false };
    var finest: Time.Quantum = default_quantum;
    var set: usize = 0;
    const locals = try arena.alloc(Local, file.modules.len);
    for (file.modules, locals) |*def, *l| {
        l.* = .{};
        for (times) |event| {
            if (event.at > r.starts[def.main_tok]) continue;
            const t = event.value orelse {
                l.* = .{};
                continue;
            };
            l.* = .{
                .unit = Time.Quantum.fromSeconds(t.unit) catch return r.fail(def.main_tok, "unsupported time unit", .{}),
                .precision = Time.Quantum.fromSeconds(t.precision) catch return r.fail(def.main_tok, "unsupported time precision", .{}),
                .set = true,
            };
        }
        set += @intFromBool(l.set);
        if (@backingInt(l.precision) < @backingInt(finest)) finest = l.precision;
    }
    if (set != 0 and set != file.modules.len) return r.fail(m.main_tok, "§19.8: it shall be an error if some modules have a `timescale specified and others do not", .{});
    // "The smallest time_precision argument of all the `timescale compiler
    // directives in the design determines the precision of the time unit of
    // the simulation": that is the scheduler's tick, and every module's delays
    // are scaled to it.
    const module_times = try arena.alloc(ModuleTime, file.modules.len);
    for (file.modules, locals, module_times) |*def, l, *mt| mt.* = .{
        .scale = Time.Scale.init(l.unit, l.precision, finest) catch return r.fail(def.main_tok, "invalid timescale", .{}),
        .unit_exp = @backingInt(l.unit),
    };
    r.module_times = module_times;
    const root_time = module_times[elab.defOf(&r, m)];
    r.scale = root_time.scale;
    r.unit_exp = root_time.unit_exp;
    // §17.3: "the default ... is the smallest time precision argument of
    // all the `timescale compiler directives in the source description".
    r.time_format.units = @backingInt(finest);
    r.finest = r.time_format.units;
    // Pass one: storage. Variables, array elements and nets share one slot
    // space, so one `store` publishes all three and wakes the same event
    // waiters. §6.2.2 elaboration walks the instance tree parent-first, which
    // is what lets a port connection resolve against nets that already exist.
    var e: elab.Elab = .{};
    try r.scope_info.append(arena, .{ .parent = 0, .name = m.name, .def = elab.defOf(&r, m) });
    // IEEE 1364-2005 §12.1.1 every other top-level module is a root of its
    // own, scoped before any instance so a defparam in it that names another
    // top's parameter (§12.2.1) is registered when that parameter is set.
    if (tops.len > 1) {
        const roots = try arena.alloc(u32, tops.len);
        roots[0] = 0;
        for (tops[1..], roots[1..]) |d, *s| {
            const t = &file.modules[d];
            s.* = try elab.newScope(&r, t.main_tok);
            try r.scope_info.append(arena, .{ .parent = s.*, .name = t.name, .def = d });
            for (t.defparams) |dp| try elab.bindDefparam(&r, s.*, dp, t.instances);
        }
        r.roots = roots;
    }
    for (r.roots, 0..) |s, k| if (r.binds.get(0)) |b| if (b.cfg) |c|
        try r.binds.put(arena, s, binding.rootCtx(&r, c, if (tops.len == 0) elab.defOf(&r, m) else tops[k]));
    if (opts.mixed) |mx| {
        // VAMS §7.8.4 each bridge's segment, spelled as the flatten spells it
        // (`bridged` declares it), for the connections re-pointed at it.
        const segs = try arena.alloc(Ast.ExprId, mx.inserts.len);
        for (mx.inserts, segs) |row, *x| {
            // Every other name a row holds is the source's own.
            _ = try file.intern(arena, row.name);
            x.* = try file.exprs.add(arena, .{
                .tag = .ident,
                .main_tok = m.main_tok,
                .str = try file.intern(arena, try arena.print("{s}.{s}", .{ row.name, row.lower_port })),
            });
        }
        r.inserts = mx.inserts;
        r.insert_segs = segs;
    }
    // Allocated before pass one: a bound or a parameter is typed and folded
    // while the slot space is still growing (`Run.constant`).
    r.types = try arena.alloc(Type, file.exprs.len());
    r.ty_state = try arena.alloc(TyState, file.exprs.len());
    @memset(r.ty_state, .untyped);
    r.sys_calls = try arena.alloc(?compile.SysFn, file.exprs.len());
    @memset(r.sys_calls, null);
    r.growing = &e.values;
    try elab.declare(&r, &e, m, 0, &.{}, &.{}, 0);
    if (tops.len > 1) for (r.roots[1..], tops[1..]) |s, d| try elab.declare(&r, &e, &file.modules[d], s, &.{}, &.{}, 0);
    try elab.checkDefparams(&r);
    // A misspelt `--param` would otherwise run the default design.
    for (opts.params) |o| {
        // `tops[0]`, when there are tops, is `m`.
        const known = topDeclares(file, m, o.name) or for (tops) |d| {
            if (topDeclares(file, &file.modules[d], o.name)) break true;
        } else false;
        if (!known) return r.fail(m.main_tok, "--param {s}: no top-level module declares a parameter `{s}`", .{ o.name, o.name });
    }
    try driver.segregate(&r, &e);
    r.values = e.values.items;
    r.nets = e.nets.items;
    r.net_cold = e.net_cold;
    r.signals = e.signals.items;
    try tchk.delayedDrivers(&r, &e);
    // Pass two: drivers, then processes. §6.1 one continuous assignment is one
    // driver of one net; §7.9 resolution needs them grouped, because every
    // update reads all of a net's drivers.
    //
    // Drivers compile first so that no driver's pc can also be a process's
    // resumption point: a `wait_event` resumes at its own pc plus one, and
    // every instruction from here on belongs to a process.
    if (e.wires.items.len > std.math.maxInt(u32)) return r.fail(m.main_tok, "too many continuous assignments", .{});
    r.drivers = try arena.alloc(Driver, e.wires.items.len);
    for (e.wires.items, 0..) |a, i| {
        r.scope = a.scope;
        var watched: std.ArrayList(u32) = .empty;
        switch (a.source) {
            .bridge => |b| try watched.append(arena, b.src),
            // §7.8.5 a gate re-evaluates on any input change, exactly as a
            // continuous assignment does on any operand change.
            .gate => |g| for (g.ins) |in| {
                try compile.checkExpr(&r, in);
                const w = compile.typeOf(&r, in).width;
                if (w != 1 and !(g.lane != null and w == g.lanes)) return r.exprFail(in, "a gate's input terminal is one bit, or one per instance of an array");
                try compile.sensitivity(&r, in, &watched);
            },
            .mos => |mo| for ([_]Ast.ExprId{ mo.data, mo.gate }) |in| {
                try compile.checkExpr(&r, in);
                // §7.1.6: an instance array's member reads its bit `lane`
                // of a vector terminal, as a gate does.
                const w = compile.typeOf(&r, in).width;
                if (w != 1 and !(mo.lane != null and mo.lane.? < w)) return r.exprFail(in, "a switch terminal is one bit, or one per instance of an array");
                try compile.sensitivity(&r, in, &watched);
            },
            .udp => |u| for (u.ins) |in| {
                try compile.checkExpr(&r, in);
                if (compile.typeOf(&r, in).width != 1 and u.lane == null) return r.exprFail(in, "a UDP's input terminal is one bit, or one per instance of an array");
                try compile.sensitivity(&r, in, &watched);
            },
            .expr => |x| {
                try compile.checkExpr(&r, x.e);
                try compile.sensitivity(&r, x.e, &watched);
            },
            .pull => {},
        }
        r.drivers[i] = .{
            .net = a.net,
            .source = a.source,
            .scope = a.scope,
            .sensitivity = watched.items,
            // A sequential UDP's output is its state from the start (§8.5).
            .current = try filled(arena, r.nets[a.net].resolved.width, false, .z),
            .s0 = a.s0,
            .s1 = a.s1,
            .delay = if (try constantDelay(&r, a.delay)) try r.declaredDelay3(a.delay, a.tok) else blk: {
                try r.driver_delays.put(arena, @intCast(i), a.delay);
                break :blk .{ .present = true };
            },
            .tok = a.tok,
        };
        // A UDP's output bit starts at its state: §8.5's initial value for a
        // sequential one, x for a combinational one until its first value.
        if (a.source == .udp) setBit(r.drivers[i].current, a.source.udp.out_bit orelse 0, a.source.udp.state);
        _ = try exec.enqueue(&r, .{ .run_process = try compile.append(&r, .{ .continuous = @intCast(i) }) }, null, false);
    }
    // §7.6: each net knows the pass switches on it, and a controlled one is
    // a process that re-resolves both sides whenever its control changes.
    r.trans = try arena.alloc(Tran, e.trans.items.len);
    for (e.trans.items, r.trans, 0..) |t, *dst, i| {
        dst.* = t.tran;
        if (t.tran.ctrl == .none) continue;
        r.scope = t.scope;
        try compile.checkExpr(&r, t.tran.ctrl);
        var watched: std.ArrayList(u32) = .empty;
        try compile.sensitivity(&r, t.tran.ctrl, &watched);
        _ = try exec.enqueue(&r, .{ .run_process = try compile.append(&r, .{ .switch_ctrl = .{ .tran = @intCast(i), .slots = watched.items } }) }, null, false);
    }
    for (r.drivers) |d| if (d.source == .mos and file.exprs.tag(d.source.mos.data) == .ident) {
        r.scope = d.scope;
        if (r.net_of.get(try r.slot(d.source.mos.data))) |net| r.nets[net].strength_read = true;
    };
    // Each net's pass switches and drivers, in declaration order, as runs of
    // one flat array each (a counting sort), not a list per net: a large net
    // array is one net per element and almost none of them has either.
    {
        const at = try netRuns(arena, r.nets.len, e.trans.items.len * 2, e.trans.items, struct {
            fn each(t: anytype, k: usize) u32 {
                return if (k == 0) t.tran.a else t.tran.b;
            }
        }.each, 2);
        defer arena.free(at.start);
        for (0..r.nets.len) |net| if (at.start[net] != at.start[net + 1]) {
            (try r.netColdMut(@intCast(net))).trans = at.items[at.start[net]..at.start[net + 1]];
        };
    }
    {
        const at = try netRuns(arena, r.nets.len, e.wires.items.len, e.wires.items, struct {
            fn each(w: anytype, _: usize) u32 {
                return w.net;
            }
        }.each, 1);
        r.net_driver_start = at.start;
        r.net_drivers = at.items;
        for (r.nets, 0..) |n, net| {
            // §7.9 `uwire` is the UNRESOLVED net type: a second driver is not a
            // resolution question there, it is an error. §4.6.5's "more than
            // one driver" is per bit: drivers of disjoint selects are legal.
            if (n.kind == .uwire) {
                const ds = r.netDrivers(@intCast(net));
                for (ds, 0..) |a, i| for (ds[i + 1 ..]) |b| {
                    const x = driverBits(r.drivers[a], n.resolved.width);
                    const y = driverBits(r.drivers[b], n.resolved.width);
                    if (x[0] < y[1] and y[0] < x[1]) return r.fail(n.tok, "a uwire net accepts a single driver per bit", .{});
                };
            }
        }
    }
    // §10 subroutine bodies, each on its own pc range before any process, so
    // a synchronous call never runs into a process's code.
    try compile.compileSubs(&r);
    for (e.insts.items) |inst| {
        r.scope = inst.scope;
        try initVars(&r, inst.module.vars);
        if (r.mixed) {
            // The names the digital processes mention, for `analogTriggers`.
            var named: std.AutoHashMapUnmanaged(Ast.StrId, void) = .empty;
            const N = struct {
                f: *const Ast.SourceFile,
                out: *std.AutoHashMapUnmanaged(Ast.StrId, void),
                a: std.mem.Allocator,
                pub fn expr(w: @This(), x: Ast.ExprId, _: Ast.SourceFile.Edge) Error!void {
                    if (x == .none) return;
                    if (w.f.exprs.tag(x) == .ident) try w.out.put(w.a, w.f.exprs.strOf(x), {});
                    var buf: [3]Ast.ExprId = undefined;
                    for (w.f.exprs.children(x, &buf)) |c| try w.expr(c, .read);
                }
                pub fn stmt(w: @This(), st: Ast.StmtId) Error!void {
                    if (st != .none) try w.f.stmtEdges(st, w);
                }
            };
            for (inst.module.discrete) |process| try (N{ .f = r.file, .out = &named, .a = arena }).stmt(process.body);
            try r.analogTriggers(inst.module, &named);
        }
        try processes(&r, inst.module.discrete);
        // IEEE 1364-2005 §15: the instance's timing checks, bound to the
        // slots their events name, in a `.v` run and in the digital half of
        // a mixed-signal design alike.
        try tchk.compileChecks(&r, inst.module.timing_checks);
    }
    for (e.procs.items) |p| {
        r.scope = p.scope;
        try initVars(&r, p.vars);
        try processes(&r, p.blocks);
    }
    // A.6.5's `disable` names a block that needs no declaration before its
    // use (it may be in another process), so the ranges are bound here, once
    // every process has a pc range.
    // A block is looked for through the enclosing scopes (§12.7); a name
    // that is no block may be a task (§10.3), which has no single range.
    disabling: for (r.disables.items) |d| {
        var s = d.name.scope;
        while (true) {
            if (r.blocks.get(.{ .scope = s, .str = d.name.str })) |range| {
                r.code.items[d.at] = .{ .disable_block = .{ .start = range.start, .end = range.end } };
                continue :disabling;
            }
            if (!r.scope_info.items[s].lexical) break;
            s = r.scope_info.items[s].parent;
        }
        const idx = r.sub_by_name.get(.{ .scope = r.instanceOf(d.name.scope), .str = d.name.str }) orelse
            return r.fail(d.tok, "undeclared named block or task", .{});
        if (r.subs.items[idx].decl.is_function) return r.fail(d.tok, "§10.3: `disable` cannot name a function, only a named block within one", .{});
        r.code.items[d.at] = .{ .disable_task = idx };
    }
    // Pass two may have minted storage (an automatic task inlined at a call
    // site), so the slot space is final only now.
    r.growing = null;
    r.values = e.values.items;
    r.watch = try arena.alloc(std.EnumSet(Watcher), r.values.len);
    @memset(r.watch, .empty);
    // §14.3.3 a module path's source is watched for its last transition; a
    // §14.2.4 condition is type-checked in the scope that declares the path.
    for (r.net_cold.items) |c| for (c.paths) |p| {
        r.watch[p.src].insert(.path);
        if (p.cond != .none) {
            r.scope = p.scope;
            try compile.checkExpr(&r, p.cond);
        }
    };
    // §7.11 "a supply strength shall be reduced to a strong strength" across a
    // pass switch, and §3.7 a net type's own pull, hold from the start: a
    // switch group with no driver event (a supply net through an uncontrolled
    // `tran`) is resolved nowhere else. Every driver is still z here, so this
    // settles only what the net types assert, before anything watches a slot
    // (no event, which the native emitter would refuse). `rt.State.initIn`
    // does the same for its `%v` signals.
    for (r.nets, 0..) |n, k| if (r.netCold(n).trans.len != 0) try resolution.resolve(&r, @intCast(k));
    try tchk.arm(&r);
    try waiters.buildFanout(&r);
    try driver.arm(&r);
    r.slot_memo = try arena.alloc(SlotMemo, 1 << memo_bits);
    @memset(r.slot_memo, .{});
    r.diag_stage = .run;
    return r;
}

/// The rows of `rows` grouped by net, as one counting sort: `items` holds
/// each row index once per net `netOf(row, k)` names (`k` < `per_row`), and
/// net `n`'s run is `items[start[n]..start[n + 1]]`, in row order. The
/// caller frees `start` when it has cut the runs; `items` is what they borrow.
fn netRuns(
    arena: std.mem.Allocator,
    n_nets: usize,
    n_items: usize,
    rows: anytype,
    comptime netOf: anytype,
    comptime per_row: usize,
) Error!struct { start: []u32, items: []u32 } {
    const start = try arena.alloc(u32, n_nets + 1);
    @memset(start, 0);
    for (rows) |row| inline for (0..per_row) |k| {
        start[netOf(row, k) + 1] += 1;
    };
    for (1..n_nets + 1) |i| start[i] += start[i - 1];
    const items = try arena.alloc(u32, n_items);
    const fill = try arena.dupe(u32, start[0..n_nets]);
    defer arena.free(fill);
    for (rows, 0..) |row, i| inline for (0..per_row) |k| {
        const net = netOf(row, k);
        items[fill[net]] = @intCast(i);
        fill[net] += 1;
    };
    return .{ .start = start, .items = items };
}

/// Whether every value of `d` is a constant expression. A.2.2.3's
/// `delay_value` and the `mintypmax_expression` in `delay3`'s parentheses may
/// read a variable too (`Run.driver_delays`).
fn constantDelay(r: *Run, d: Ast.Delay3) Error!bool {
    for ([_]Ast.ExprId{ d.rise, d.fall, d.off }) |x| if (x != .none) {
        try compile.checkExpr(r, x);
        if (!compile.constantExpression(r, x)) return false;
    };
    return true;
}

/// Whether top-level module `m` declares a parameter `--param` may set,
/// `name`: one that is not a localparam.
fn topDeclares(file: *const Ast.SourceFile, m: *const Ast.ModuleDecl, name: []const u8) bool {
    for (m.params) |p| if (!p.is_local and std.mem.eql(u8, file.str(p.name), name)) return true;
    return false;
}

/// The bits [lo, hi) of its `width`-bit net that driver `d` drives: a port
/// window's, or an instance-array member's one output bit; else all of them.
fn driverBits(d: Driver, width: u32) [2]u32 {
    const bit: ?u32 = switch (d.source) {
        .bridge => |b| return .{ b.dst_lo, b.dst_lo + b.width },
        .gate => |g| g.out_bit,
        .mos => |m| m.out_bit,
        .udp => |u| u.out_bit,
        .expr, .pull => null,
    };
    return if (bit) |b| .{ b, b + 1 } else .{ 0, width };
}

/// Compiles each of `blocks` in `r.scope` and queues it at time 0.
/// IEEE 1364-2005 §6.2.1: a variable declaration assignment "shall be the
/// same as" an initial block making the assignment, so each initializer of
/// `vars`, declared in `r.scope`, is one, queued ahead of the scope's own
/// processes. A mixed module's initialized variables are the analog block's
/// and were never declared here.
fn initVars(r: *Run, vars: []const Ast.VarDecl) Error!void {
    for (vars) |v| if (v.init != .none) {
        const at = r.names.get(.{ .scope = r.scope, .str = v.name }) orelse continue;
        try compile.checkExpr(r, v.init);
        // §6.2.1: "The assignment shall be to a constant expression."
        if (!compile.constantExpression(r, v.init)) return r.exprFail(v.init, "§6.2.1: a constant expression is required here");
        const start = try compile.append(r, .{ .init_var = .{ .slot = at, .value = v.init } });
        _ = try compile.append(r, .stop);
        _ = try exec.enqueue(r, .{ .run_process = start }, null, false);
    };
}

fn processes(r: *Run, blocks: []const Ast.DiscreteBlock) Error!void {
    for (blocks) |process| {
        const start: u32 = @intCast(r.code.items.len);
        try compile.compileStmt(r, process.body, 0);
        _ = try compile.append(r, if (process.is_always)
            .{ .restart = .{ .target = start, .tok = process.main_tok } }
        else
            .stop);
        _ = try exec.enqueue(r, .{ .run_process = start }, null, false);
    }
}

// ---- tests ------------------------------------------------------------------

test {
    _ = elab;
    _ = system;
    _ = @import("vcd.zig");
    _ = @import("evcd.zig");
    _ = @import("driver.zig");
    _ = tchk;
}

/// Test helper: runs `source` and expects its transcript to be `expected`
/// exactly; on a refusal prints the rendered diagnostics, then fails.
pub fn expectRun(source: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    run(arena.allocator(), source, .{}, &bag, &output.writer) catch |e| {
        var messages = std.Io.Writer.Allocating.init(arena.allocator());
        try diag.render(&bag, &messages.writer, .{});
        std.debug.print("{s}", .{messages.written()});
        return e;
    };
    try std.testing.expectEqualStrings(expected, output.written());
}

test "a zero-delay loop fails by name instead of hanging at one tick" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    var r = try elaborate(arena.allocator(),
        \\module m; reg a; initial a = 0; always #0 a = ~a; endmodule
    , .{}, &bag, &output.writer);
    r.budget = 1000;
    try std.testing.expectError(error.DigitalFailed, r.runUntil(std.math.maxInt(Tick)));
    try std.testing.expectEqual(@as(Tick, 0), r.scheduler.now);
}

test "an untimed loop inside one process fails by name instead of hanging at one tick" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    var r = try elaborate(arena.allocator(),
        \\module m; reg x; initial forever x = 1; endmodule
    , .{}, &bag, &output.writer);
    r.budget = 1000;
    try std.testing.expectError(error.DigitalFailed, r.runUntil(std.math.maxInt(Tick)));
    try std.testing.expectEqual(@as(Tick, 0), r.scheduler.now);
    try std.testing.expect(std.mem.indexOf(u8, bag.at(0).message, "more than 1000 loop iterations and events at time 0") != null);
}

test "a finite untimed loop under the budget runs to its end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    var r = try elaborate(arena.allocator(),
        \\module m; integer i, n; initial begin n = 0; for (i = 0; i < 900; i = i + 1) n = n + 1; end endmodule
    , .{}, &bag, &output.writer);
    r.budget = 1000;
    _ = try r.runUntil(std.math.maxInt(Tick));
    try std.testing.expectEqual(@as(?i64, 900), r.values[r.slotOf("n").?].asInt());
}

test "many runUntil calls over a switch-joined net and an extended dump stop growing the run arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The mixed runner calls runUntil once per tick; every toggle of `c`
    // resolves the `tran` group again and changes the dumped port's state.
    const source = try arena.allocator().print(
        \\`timescale 1ns/1ns
        \\module top; reg c; wire a, b; assign a = c; tran t(a, b); leaf u(b);
        \\initial c = 0; always #1 c = ~c;
        \\initial $dumpports(u, ".zig-cache/tmp/{s}/p.evcd");
        \\endmodule
        \\module leaf(p); inout p; wire p; endmodule
    , .{tmp.sub_path});
    var r = try elaborate(arena.allocator(), source, .{ .io = std.testing.io }, &bag, &output.writer);
    var at_warm: usize = 0;
    for (1..2001) |k| {
        _ = try r.runUntil(k);
        if (k == 200) at_warm = arena.queryCapacity();
    }
    try std.testing.expectEqual(at_warm, arena.queryCapacity());
}

test "elaborate + runUntil step the engine one bounded horizon at a time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    var r = try elaborate(arena.allocator(),
        \\`timescale 1ns/1ns
        \\module m;
        \\reg [3:0] code;
        \\initial begin code = 4'd1; #10 code = 4'd5; #10 code = 4'd9; end
        \\endmodule
    , .{}, &bag, &output.writer);
    const at = r.slotOf("code").?;
    try std.testing.expectEqual(@as(?u32, null), r.slotOf("nope"));
    // Nothing has run: the reg is still §3.2's x.
    try std.testing.expect(r.values[at].hasUnknown());
    _ = try r.runUntil(0);
    try std.testing.expectEqual(@as(?i64, 1), r.values[at].asInt());
    try std.testing.expectEqual(@as(?Tick, 10), r.scheduler.peekTime());
    _ = try r.runUntil(9);
    try std.testing.expectEqual(@as(?i64, 1), r.values[at].asInt());
    _ = try r.runUntil(10);
    try std.testing.expectEqual(@as(?i64, 5), r.values[at].asInt());
    _ = try r.runUntil(std.math.maxInt(Tick));
    try std.testing.expectEqual(@as(?i64, 9), r.values[at].asInt());
    try std.testing.expectEqual(@as(?Tick, null), r.scheduler.peekTime());
}

test "an error raised once elaboration finished, between runUntil calls too, is the run's (#72)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    // An elaboration failure is still a compile error. It has its own bag:
    // `elaborate` refuses to start on a bag that has already failed.
    var compile_bag = diag.Bag.init(arena.allocator());
    try std.testing.expectError(error.DigitalFailed, elaborate(arena.allocator(), "module m; initial disable nope; endmodule\n", .{}, &compile_bag, &output.writer));
    try std.testing.expectEqual(diag.Stage.lower, compile_bag.at(compile_bag.count() - 1).stage);
    var text = std.Io.Writer.Allocating.init(arena.allocator());
    try diag.render(&compile_bag, &text.writer, .{});
    try std.testing.expect(std.mem.find(u8, text.written(), "could not compile due to") != null);
    var bag = diag.Bag.init(arena.allocator());
    var r = try elaborate(arena.allocator(), "module m; reg a; initial #5 a = 1; endmodule\n", .{}, &bag, &output.writer);
    _ = try r.runUntil(1);
    // What a VPI host raises between two `runUntil` calls (`vpi/run.zig`
    // `timeSteps`'s callback-pass cap), and after the last one.
    try std.testing.expectEqual(error.DigitalFailed, r.fail(0, "between", .{}));
    try std.testing.expectEqual(diag.Stage.run, bag.at(bag.count() - 1).stage);
    _ = try r.runUntil(std.math.maxInt(Tick));
    try std.testing.expectEqual(error.DigitalFailed, r.fail(0, "after", .{}));
    try std.testing.expectEqual(diag.Stage.run, bag.at(bag.count() - 1).stage);
    // The run's two errors are no compile failure. A bag holding both kinds
    // counts the compile errors only: tests/unit.zig's "render: a
    // run-time error is no compile failure (#72)".
    var run_text = std.Io.Writer.Allocating.init(arena.allocator());
    try diag.render(&bag, &run_text.writer, .{});
    try std.testing.expect(bag.failed());
    try std.testing.expect(std.mem.find(u8, run_text.written(), "could not compile") == null);
}

test "IEEE 1364 §5.2.1 a bit-select names its bit against the declared range" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\reg [3:0] a; reg [0:3] b; wire [3:0] w; wire hi;
        \\integer i;
        \\assign w = a;
        \\assign hi = w[3];
        \\initial begin
        \\  a = 4'b1010; b = 4'b1000; i = 1;
        \\  #0 $display("%b%b %b %b%b %b %b", a[1], a[0], hi, b[0], b[3], a[i], a[4]);
        \\end
        \\endmodule
    , "10 1 10 1 x\n");
}

test "§12.4 a downward hierarchical reference reads the named instance's net" {
    try expectRun(
        \\`timescale 1ns/1ps
        \\module child(a, y);
        \\input a;
        \\output y;
        \\wire a, y;
        \\assign y = ~a;
        \\endmodule
        \\module top;
        \\reg r;
        \\wire w;
        \\child u(r, w);
        \\initial begin r = 1'b0; #0 $display("a=%b y=%b", u.a, u.y); end
        \\endmodule
    , "a=0 y=1\n");
}

test "§12.4 a hierarchical path descends one instance per part" {
    try expectRun(
        \\`timescale 1ns/1ps
        \\module leaf(a);
        \\input a;
        \\wire a;
        \\endmodule
        \\module mid(a);
        \\input a;
        \\wire a;
        \\leaf d(a);
        \\endmodule
        \\module top;
        \\reg r;
        \\mid u(r);
        \\initial begin r = 1'b1; #0 $display("%b", u.d.a); end
        \\endmodule
    , "1\n");
}

// §10: an untimed task runs in place, a timed one suspends its caller; a
// static task's storage outlives its activation and an automatic one's does
// not; recursion gets a frame per activation; `disable` of a task ends every
// activation, and the caller resumes after its enable.
test "§10 tasks and functions: copy in/out, lifetimes, recursion, disable" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\reg [7:0] a, b, c; integer n, tails;
        \\function automatic integer fib(input integer k);
        \\  fib = k < 2 ? k : fib(k - 1) + fib(k - 2);
        \\endfunction
        \\function [3:0] low(input [7:0] x); low = x; endfunction
        \\task count(input clr, output [7:0] o); reg [7:0] kept; begin if (clr) kept = 0; kept = kept + 1; o = kept; end endtask
        \\task late(input [7:0] i, output [7:0] o); #2 o = i + 1; endtask
        \\task automatic dive(input integer d); begin if (d == 0) disable dive; else dive(d - 1); tails = tails + 1; end endtask
        \\initial begin
        \\  n = fib(10); a = low(8'hab) + 8'h10;
        \\  count(1'b1, b); count(1'b0, b);
        \\  tails = 0; dive(3);
        \\  late(a, c);
        \\  $display("%0d %h %0d %h %0d %0d", n, a, b, c, tails, $time);
        \\end
        \\endmodule
    , "55 1b 2 1c 0 2\n");
}

// §10.2.3: each activation of an automatic task that suspends and reaches
// itself has its own storage, even while another caller's activations are
// alive; and an actual that is the callee's own formal is read before the
// new activation's frame is initialized.
test "§10.2.3 recursive timed automatic tasks and a formal passed to itself" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\integer ra, rb;
        \\task automatic sum(input integer n, input integer d, output integer t);
        \\  integer b; begin if (n == 0) t = 0; else begin #d sum(n - 1, d, b); t = b + n; end end
        \\endtask
        \\function automatic integer f(input integer n, input integer k); f = k == 0 ? n : f(n, k - 1); endfunction
        \\initial begin sum(2, 2, ra); $display("%0d ra=%0d", $time, ra); end
        \\initial begin sum(3, 3, rb); $display("%0d rb=%0d f=%0d", $time, rb, f(7, 3)); end
        \\endmodule
    , "4 ra=3\n9 rb=6 f=7\n");
}

// §6.2.1: the initializer is an initial-block assignment at time 0, so a
// net assigned from the variable tracks it, and a later write replaces it.
test "§6.2.1 a variable declaration assignment is a time-0 write" {
    try expectRun(
        \\module m;
        \\reg [7:0] v = 2*3+1; integer i = -5; time t = 64'd9;
        \\wire [7:0] w = v;
        \\initial begin #1 $display("%0d %0d %0d %0d", v, w, i, t); v = 12; #1 $display("%0d", w); end
        \\endmodule
    , "7 7 -5 9\n12\n");
}

/// Test helper: expects `source` to fail before printing anything, with a
/// rendered diagnostic containing `message`.
pub fn expectRejected(source: []const u8, message: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    try std.testing.expectError(error.DigitalFailed, run(arena.allocator(), source, .{}, &bag, &output.writer));
    try std.testing.expectEqualStrings("", output.written());
    var messages = std.Io.Writer.Allocating.init(arena.allocator());
    try diag.render(&bag, &messages.writer, .{});
    try std.testing.expect(std.mem.find(u8, messages.written(), message) != null);
}

test "§19.8 no timescale is the simulator's own unit, not an error" {
    // "If there is no `timescale specified or it has been reset by a
    // `resetall directive, the time unit and precision are simulator-specific."
    try expectRun("module m; wire w; reg a; assign #3 w = a; initial begin a = 1; #2 $display(\"%b %0d\", w, $time); #1 $display(\"%b %t\", w, $time); end endmodule", "z 2\n1                    3\n");
    try expectRun("`timescale 1ns/1ps\n`resetall\nmodule m; initial #1 $display(\"%0d %g\", $time, $realtime); endmodule", "1 1\n");
}

test "timescale provenance rejects malformed or later directives" {
    // The preprocessor refuses all three (E0142), so the message names the
    // directive rather than the consumer that could not use it.
    try expectRejected("`timescale 2ns/1ps\nmodule m; initial #1 ; endmodule", "is not a `timescale");
    try expectRejected("`timescale 1ns/1ps junk\nmodule m; initial #1 ; endmodule", "is not a `timescale");
    try expectRejected("`timescale 1ps/1ns\nmodule m; initial #1 ; endmodule", "coarser than the time unit");
    try expectRejected("`timescale 1ns/1ns\nmodule m; initial #(128'd1) ; endmodule", "wider than 64");
    // §19.8: "It shall be an error if some modules have a `timescale
    // specified and others do not": here `resetall takes it from `top`.
    try expectRejected("`timescale 1ns/1ns\nmodule a; endmodule\n`resetall\nmodule top; a u(); endmodule", "others do not");
}

// IEEE 1364 §19.8: a `timescale applies to the modules that follow it, until
// the next one; the simulation's tick is the finest precision of all (1 ps).
// `top`'s #3 is 3 ns. `sub`'s #0.004 is 4 ns, which its $realtime reads in its
// own 1 us unit as 0.004; its #1 more is 1004 ns, and $time rounds 1.004 us to
// 1. A directive after the last module applies to nothing and is not an error.
test "§19.8 each module definition runs in the timescale written before it" {
    try expectRun(
        \\`timescale 1ns/1ps
        \\module top;
        \\  sub u();
        \\  initial #3 $display("top %0d", $time);
        \\endmodule
        \\`timescale 1us/1ps
        \\module sub;
        \\  initial begin #0.004 $display("sub %g", $realtime); #1 $display("sub %0d", $time); end
        \\endmodule
        \\`timescale 1ms/1us
    , "top 3\nsub 0.004\nsub 1\n");
}

fn testConcatRunAllocation(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    try run(arena.allocator(), "module m; reg [7:0] a; initial begin a={{0{$signed(65'bz)}},{(1+1){4'b10xz}}}; $display(\"%b\",a); end endmodule", .{}, &bag, &output.writer);
    try std.testing.expectEqualStrings("10xz10xz\n", output.written());
}

test "VAMS §7.3.6.4 an analog variable a continuous assign reads is declared and written by the coordinator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var out = std.Io.Writer.Allocating.init(arena.allocator());
    var r = try elaborate(arena.allocator(), "module m; real level; wire hi; assign hi = level > 0.5; endmodule\n", .{ .mixed = .{ .top = "m", .timescales = &.{}, .reads = &.{"level"} } }, &bag, &out.writer);
    _ = try r.runUntil(0);
    try r.a2dWrite(r.slotOf("level").?, 0.75, false);
    _ = try r.runUntil(0);
    try std.testing.expectEqual(@as(?i64, 1), r.values[r.slotOf("hi").?].asInt());
}

test "source concat allocation failures clean up preflight and execution arenas" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testConcatRunAllocation, .{});
}

test "VecRange.position counts from the least significant declared bit" {
    const down: VecRange = .{ .msb = 7, .lsb = 0 };
    const up: VecRange = .{ .msb = 0, .lsb = 7 };
    const off: VecRange = .{ .msb = 10, .lsb = 3 };
    try std.testing.expectEqual(@as(i64, 7), down.position(7));
    try std.testing.expectEqual(@as(i64, 0), down.position(0));
    try std.testing.expectEqual(@as(i64, 7), up.position(0));
    try std.testing.expectEqual(@as(i64, 0), up.position(7));
    try std.testing.expectEqual(@as(i64, 0), off.position(3));
    try std.testing.expectEqual(@as(i64, 7), off.position(10));
    // Outside the range: a position outside [0, width).
    try std.testing.expectEqual(@as(i64, -1), off.position(2));
    try std.testing.expectEqual(@as(i64, 8), off.position(11));
    // §5.2.1: a distant index saturates rather than overflowing.
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), off.position(std.math.minInt(i64)));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), up.position(std.math.minInt(i64)));
}

test SlotNets {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t: SlotNets = .{};
    try std.testing.expectEqual(@as(?u32, null), t.get(0));
    try t.put(a, 3, 7);
    // The rows it grew over are variables' slots, not net 0's.
    try std.testing.expectEqual(@as(?u32, null), t.get(0));
    try std.testing.expectEqual(@as(?u32, null), t.get(2));
    try std.testing.expectEqual(@as(?u32, 7), t.get(3));
    try std.testing.expectEqual(@as(?u32, null), t.get(4));
    try t.put(a, 1, 0);
    try std.testing.expect(t.contains(1));
    try std.testing.expectEqual(@as(?u32, 0), t.get(1));
    try std.testing.expect(!t.contains(2));
}

test netRuns {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Pair = struct { a: u32, b: u32 };
    const rows = [_]Pair{ .{ .a = 2, .b = 0 }, .{ .a = 0, .b = 2 }, .{ .a = 2, .b = 1 } };
    // Grouped by `a`: net 0 holds row 1, net 1 nothing, net 2 rows 0 and 2,
    // each run in row order.
    const by_a = try netRuns(a, 3, rows.len, &rows, struct {
        fn each(r: anytype, _: usize) u32 {
            return r.a;
        }
    }.each, 1);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 1, 3 }, by_a.start);
    try std.testing.expectEqualSlices(u32, &.{ 1, 0, 2 }, by_a.items);
    // Two nets per row (a pass switch's two terminals): a row is in each
    // net's run once.
    const both = try netRuns(a, 3, rows.len * 2, &rows, struct {
        fn each(r: anytype, k: usize) u32 {
            return if (k == 0) r.a else r.b;
        }
    }.each, 2);
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 3, 6 }, both.start);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 0, 1, 2 }, both.items);
}

test PathKey {
    var buf = "u.p".*;
    const key: PathKey = .{ .scope = 1, .path = "u.p" };
    const ctx: PathKey.Ctx = .{};
    // The path's bytes are the key, not where they live.
    try std.testing.expect(ctx.eql(key, .{ .scope = 1, .path = &buf }));
    try std.testing.expectEqual(ctx.hash(key), ctx.hash(.{ .scope = 1, .path = &buf }));
    try std.testing.expect(!ctx.eql(key, .{ .scope = 2, .path = "u.p" }));
    try std.testing.expect(!ctx.eql(key, .{ .scope = 1, .path = "u.q" }));
}

test "§12.7 a name resolves outward through blocks and stops at the instance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    const r = try elaborate(arena.allocator(),
        \\module m; reg a; initial begin : b reg c; c = a; end endmodule
    , .{}, &bag, &output.writer);
    const a_str = r.file.strings.find("a").?;
    const b_str = r.file.strings.find("b").?;
    const c_str = r.file.strings.find("c").?;
    const block = r.instances.get(.{ .scope = 0, .str = b_str }).?;
    // From the block, `a` is the instance's; from the instance, `c` is no
    // name at all (§12.7: a block's names are not its parent's).
    try std.testing.expectEqual(r.slotOf("a"), r.lookup(block, a_str));
    try std.testing.expect(r.lookup(block, c_str) != null);
    try std.testing.expectEqual(@as(?u32, null), r.lookup(0, c_str));
    try std.testing.expectEqual(@as(?u32, null), r.slotOf("c"));
    // A block shares its instance's parameters and is part of it.
    try std.testing.expectEqual(@as(u32, 0), r.instanceOf(block));
    try std.testing.expectEqual(@as(u32, 0), r.specOf(block));
    try std.testing.expect(isRoot(&r, 0));
}

test "§12.1.1 every module nothing instantiates is a root of its own" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    var r = try elaborate(arena.allocator(),
        \\module a; reg x; endmodule
        \\module b; reg y; endmodule
    , .{}, &bag, &output.writer);
    try std.testing.expectEqual(@as(usize, 2), r.roots.len);
    for (r.roots) |s| try std.testing.expect(isRoot(&r, s));
    // From inside one root, the other is found by its module's name.
    r.scope = r.roots[0];
    const other = r.upward(r.scope_info.items[r.roots[1]].name).?;
    try std.testing.expectEqual(r.roots[1], other);
}

test "§3.3 a packed range wider than u32 bits is refused, not wrapped" {
    try expectRejected("module m; reg [4294967295:0] a; endmodule", "packed range is outside the supported u32 width");
}

test "A.2.2.3 a driver's variable delay is read when the driver schedules" {
    // y follows x 3 units late, then 1 unit late once d is 1: at t5, where
    // the first delay would still hold it until t6.
    try expectRun(
        \\module m;
        \\reg [31:0] d; reg x; wire y;
        \\assign #d y = x;
        \\initial begin
        \\  d = 3; x = 0;
        \\  #2 $display("%b", y);
        \\  #1 $display("%b", y);
        \\  d = 1; x = 1;
        \\  #2 $display("%b", y);
        \\  $finish(0);
        \\end
        \\endmodule
    , "z\n0\n1\n");
}

test "§12.4.1 a genvar-indexed hierarchical name finds its iteration's scope unspelled" {
    // No `g[0]` or `g[1]` appears in the source.
    try expectRun(
        \\module m;
        \\  genvar i;
        \\  generate for (i = 0; i < 2; i = i + 1) begin : g reg r; end endgenerate
        \\  generate for (i = 0; i < 2; i = i + 1) begin : s
        \\    initial begin g[i].r = i; #1 $display("%0d %b", i, g[i].r); end
        \\  end endgenerate
        \\endmodule
    , "0 0\n1 1\n");
    try expectRejected(
        \\module m;
        \\  genvar i;
        \\  generate for (i = 0; i < 2; i = i + 1) begin : g reg r; end endgenerate
        \\  generate for (i = 1; i < 3; i = i + 1) begin : s initial g[i].r = 0; end endgenerate
        \\endmodule
    , "`g[2]`: an instance select out of range");
}

test "§4.6.5 uwire drivers of disjoint bits are legal" {
    try expectRun(
        \\module m;
        \\uwire [3:0] w;
        \\assign w[1:0] = 2'b01; assign w[3:2] = 2'b10;
        \\initial #1 $display("%b", w);
        \\endmodule
    , "1001\n");
    try expectRejected("module m; uwire [3:0] w; assign w[2:0] = 0; assign w[3:2] = 0; endmodule", "single driver per bit");
}

test "§7.9 a uwire with two drivers is an error, not a resolution" {
    try expectRejected("module m; uwire w; assign w = 1'b0; assign w = 1'b1; endmodule", "a uwire net accepts a single driver per bit");
}
