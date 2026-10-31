//! One elaborated design and its whole simulation state (`Run`): the fields
//! every file of the interpreter reads, and one declaration per method,
//! each living in the file that owns its work.
//! Cites: IEEE 1364-2005 §11, §12.
//!
//! One elaborated design and its whole simulation state: the slot space
//! every variable, net and array element lives in (`values`), the nets and
//! their drivers, the compiled processes (`code`), the waiters, and the
//! scheduler. Everything is allocated from `arena`, which must outlive the
//! `Run`; nothing is freed before the arena is. Made only by `elaborate`.
//!
//! A `Run` is one thread's: `scope`, `pc` and `ctx` are the executing
//! process's registers, so a caller outside the engine (the VPI, the mixed
//! coordinator) saves and restores `scope` around anything it evaluates.
//!
//! Contents:
//! - `pub const runUntil`
//! - `pub const upward`
//! - `pub const watchAnalog`
//! - `pub const a2dWrite`
//! - `pub const watchEvent`
//! - `pub const registerMonitor`
//! - `pub const addMonitor`
//! - `pub const monitorKind`
//! - `pub const analogTriggers`
//! - `pub const monitorSlot`
//! - `pub const monitorArg`
//! - `pub const deliverA2d`
//! - `pub const analogPoint`
//! - `pub const slotOf`
//! - `pub const slot`
//! - `pub const resolveSlot`
//! - `pub const foldSelects`
//! - `pub const elementScope`
//! - `pub const termSlot`
//! - `pub const slotType`
//! - `pub const lookupAt`
//! - `pub const instanceHides`
//! - `pub const lookup`
//! - `pub const specOf`
//! - `pub const instanceOf`
//! - `pub const vecRange`
//! - `pub const isScalar`
//! - `pub const baseSlot`
//! - `pub const chainBase`
//! - `pub const scalarSlot`
//! - `pub const indexedArray`
//! - `pub const bind`
//! - `pub const timeOf`
//! - `pub const constant`
//! - `pub const declaredBound`
//! - `pub const declaredDelay`
//! - `pub const declaredDelay3`
//! - `pub const declaredWidth`
//! - `pub const tchkLimits`
//! - `pub const tchkSite`
//! - `pub const netCold`
//! - `pub const netDrivers`
//! - `pub const driverTransition`
//! - `pub const netColdMut`
//! - `pub const fail`
//! - `pub const stage`
//! - `pub const failWith`
//! - `pub const deepFail`
//! - `pub const exprFail`
//! - `pub const vpiEval`
//! - `pub const vpiConstantIndex`
//! - `pub const vpiPutUdp`
//! - `pub const vpiAttributeValue`
//! - `pub fn reset(self: *Run) Error!void`

const std = @import("std");
const monitor = @import("monitor.zig");
const Tick = @import("../scheduler.zig").Time;
const exec = @import("exec.zig");
const system = @import("system.zig");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const diag = @import("diag");
const Scheduler = @import("../scheduler.zig").Scheduler;
const Time = @import("../time.zig");
const deep = @import("base").deep_stack;
const compile = @import("compile.zig");
const evaluate = @import("evaluate.zig");
const display = @import("display.zig");
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
const root = @import("root.zig");
const Error = root.Error;
const Options = root.Options;
const StmtSite = root.StmtSite;
const StmtHook = root.StmtHook;
const DoneHook = root.DoneHook;
const UserSystf = root.UserSystf;
const Param = root.Param;
const Insert = root.Insert;
const Name = root.Name;
const SpecExpr = root.SpecExpr;
const TyState = root.TyState;
const Array = root.Array;
const VecRange = root.VecRange;
const Standing = root.Standing;
const Watcher = root.Watcher;
const Monitor = root.Monitor;
const D2aSite = root.D2aSite;
const max_events_per_tick = root.max_events_per_tick;
const PathKey = root.PathKey;
const Sub = root.Sub;
const SlotMemo = root.SlotMemo;
const ModuleTime = root.ModuleTime;
const Overrides = root.Overrides;
const SlotNets = root.SlotNets;
const elaborate = root.elaborate;
const run_until = @import("run_until.zig");
const analog_link = @import("analog_link.zig");
const name_search = @import("name_search.zig");
const declared = @import("declared.zig");
const run_nets = @import("run_nets.zig");
const run_diag = @import("run_diag.zig");

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
/// Each `names` entry's declaration token, for `lookupAt` (by name, not
/// slot: a port's slot is its connection's, declared in another module).
bound_at: std.AutoHashMapUnmanaged(Name, u32) = .empty,
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
/// The always constructs `processes` starts first at time 0
/// (`levelControlled`), in source order, by the pc each starts at.
early: std.ArrayList(u32) = .empty,
/// The token each scope after the root was made at (`elab.newScope`),
/// which orders a scope's children as the source does (`processOrder`).
scope_toks: std.AutoHashMapUnmanaged(u32, u32) = .empty,
/// §9.7.2 an expression term that reads a timed automatic task's
/// variables, by scope, and the slots it reads: a hidden slot would be
/// shared by every activation (§10.2.1), so each waiter instead tests
/// the expression in its own activation (`waiters.TermExt.expr`).
auto_terms: std.AutoHashMapUnmanaged(struct { scope: u32, e: Ast.ExprId }, []const u32) = .empty,
/// The storage of automatic tasks and functions, which §10.2.3 keeps
/// out of constructs that might outlive an activation.
auto_slots: std.AutoHashMapUnmanaged(u32, void) = .empty,
/// The scopes whose variables are automatic: an automatic task's or
/// function's frame, and the named blocks inside it (§10.2.1: "all
/// items declared inside automatic tasks" are allocated per call).
auto_scopes: std.AutoHashMapUnmanaged(u32, void) = .empty,
/// The saved storage of the automatic activations in progress.
saved_planes: std.ArrayList(u64) = .empty,
/// §10.2.3 the activations of recursive timed tasks: the one the
/// executing process is in (0 for none), every one in progress, and the
/// rows free for reuse.
ctx: u32 = 0,
acts: std.ArrayList(@import("activations.zig").Act) = .empty,
free_acts: std.ArrayList(u32) = .empty,
/// The instruction a system task is running from, so `%m` can name the
/// §5.3.2 named blocks around it.
pc: u32 = 0,
/// §12.4 one instance NAME, keyed by the scope that instantiated it, to the
/// scope it minted. `names` cannot carry this: an instance is not storage,
/// and a downward hierarchical reference walks these before it reaches a
/// slot at all.
instances: std.AutoHashMapUnmanaged(Name, u32) = .empty,
/// IEEE 1364-2005 §12.7 the gate, switch and UDP instance names of each
/// scope, each to its token: no storage, but declared there, so they hide
/// an outer name of the same spelling from `lookupAt`, `upward` and a call
/// (iverilog refuses the hidden use the same way); `lookupAt` from the
/// instance on, a call and `upward` wherever it is.
prim_names: std.AutoHashMapUnmanaged(Name, u32) = .empty,
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
/// The select and event fields of the terms that have them
/// (`waiters.Term.ext`), and the rows free.
term_exts: std.ArrayList(waiters.TermExt) = .empty,
free_term_exts: std.ArrayList(u32) = .empty,
/// §6.1 / §7.6 the static fan-out (`waiters.buildFanout`): per slot
/// `fan[fan_start[slot]..fan_start[slot + 1]]` are the pcs of the
/// continuous drivers and controlled switches reading it, and `armed[pc]`
/// says that process is suspended on its operands right now.
fan_start: []u32 = &.{},
fan: []u32 = &.{},
armed: []bool = &.{},
/// The zero-delay-loop guard: events dispatched at one tick (`run_until.EventBudget`).
event_budget: run_until.EventBudget = .{},
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
/// §17.1.3 the standing monitor and §17.2.2 the `$fmonitor`s (`monitor.Monitoring`).
monitoring: monitor.Monitoring = .{},
/// Per driver index, a `delay3` that reads a variable: A.2.2.3 lets a
/// continuous assignment's or gate's delay be one, which §6.1.3 reads
/// each time the driver schedules (`exec`'s `.continuous`).
driver_delays: std.AutoHashMapUnmanaged(u32, Ast.Delay3) = .empty,
/// The same for a §7.6 pass switch's delays, by `trans` index.
tran_delays: std.AutoHashMapUnmanaged(u32, Ast.Delay3) = .empty,
/// IEEE 1364-2005 §14.3.3: per module path source slot (a `.path`
/// watch), its last transition, which picks the path whose delay a
/// destination transition takes (`waiters.store` fills it).
path_changed: std.AutoHashMapUnmanaged(u32, @import("net.zig").PathEdge) = .empty,
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
/// IEEE 1364-2005 §15 the timing checks (`tchk.Checks`).
checks: tchk.Checks = .{},
/// Called after a run-time error the run survives (IEEE 1364-2005
/// §17.2.9's terminated `$readmem` load, VD-134). The VPI installs it
/// (VAMS 12.31.4 cbError); nothing in the engine reads it.
error_hook: ?*const fn (r: *Run) void = null,
/// The source and options `elaborate` ran, which IEEE 1364-2005 C.7's
/// reset elaborates again (`reset`).
source: []const u8 = "",
opts: Options = .{},
/// `slot`'s answers by (scope, expression), direct-mapped, from the end
/// of `elaborate`: every name is bound by then, so an answer never goes
/// stale. Empty while elaborating.
slot_memo: []SlotMemo = &.{},

/// `run_until.runUntil`: Dispatch every event at a time <= `limit` (IEEE 1364 §11.4's loop,
pub const runUntil = run_until.runUntil;

/// `run_until.upward`: IEEE 1364-2005 §12.6 the scope a hierarchical name's first part
pub const upward = run_until.upward;

/// `analog_link.watchAnalog`: VAMS §8.5 / §8.4.3.2: the analog block reads `slot` outside any event
pub const watchAnalog = analog_link.watchAnalog;

/// `analog_link.a2dWrite`: VAMS §7.3.6.4: an analog variable a digital expression reads takes the
pub const a2dWrite = analog_link.a2dWrite;

/// `analog_link.watchEvent`: VAMS §7.3.4 / §8.5: an analog event control waits on `edge` of `slot`
pub const watchEvent = analog_link.watchEvent;

/// `analog_link.registerMonitor`: VAMS §7.3.5: `cross`/`above`/`absdelta` as a term of a digital event control
pub const registerMonitor = analog_link.registerMonitor;

/// `analog_link.addMonitor`: A monitor of analog event `e` whose occurrence wakes `slot`'s waiters
pub const addMonitor = analog_link.addMonitor;

/// `analog_link.monitorKind`: monitorKind
pub const monitorKind = analog_link.monitorKind;

/// `analog_link.analogTriggers`: VAMS §5.10.4 / §7.3.6.1: `@(timer(..)) -> ev;` (or `cross`/`above`) in
pub const analogTriggers = analog_link.analogTriggers;

/// `analog_link.monitorSlot`: The slot whose waiters monitor `e` of instance `scope` wakes, or null
pub const monitorSlot = analog_link.monitorSlot;

/// `analog_link.monitorArg`: Argument `k` of monitor `m`, evaluated as a real in the monitor's scope
pub const monitorArg = analog_link.monitorArg;

/// `analog_link.deliverA2d`: VAMS §7.3.6.1: monitor `m`'s event occurred; wake its waiters "at the
pub const deliverA2d = analog_link.deliverA2d;

/// `analog_link.analogPoint`: VAMS §8.4, IEEE 1364-2005 §17.1.3: the mixed kernel accepted an analog
pub const analogPoint = analog_link.analogPoint;

/// `name_search.slotOf`: The slot a name is stored in, or null when the design declares no such
pub const slotOf = name_search.slotOf;

/// `name_search.slot`: §12.5 a hierarchical reference: the first part is a scope `upward`
pub const slot = name_search.slot;

/// `name_search.resolveSlot`: resolveSlot
pub const resolveSlot = name_search.resolveSlot;

/// `name_search.foldSelects`: `text`, a part of the hierarchical name at token `tok` with `[]`
pub const foldSelects = name_search.foldSelects;

/// `name_search.elementScope`: The scope of element `<next index>` of the instance array or loop
pub const elementScope = name_search.elementScope;

/// `name_search.termSlot`: The slot event term `e` watches: a name's own, or the hidden one a
pub const termSlot = name_search.termSlot;

/// `name_search.slotType`: The type a slot's value has, for an assignment to it
pub const slotType = name_search.slotType;

/// `name_search.lookupAt`: §12.7 a name as seen from `scope`: declared there, or in an enclosing
pub const lookupAt = name_search.lookupAt;

/// `name_search.instanceHides`: Whether `lookupAt` found nothing because a primitive instance of
pub const instanceHides = name_search.instanceHides;

/// `name_search.lookup`: lookup
pub const lookup = name_search.lookup;

/// `name_search.specOf`: The scope whose parameters decide every type, part-select bound and
pub const specOf = name_search.specOf;

/// `name_search.instanceOf`: The instance a (possibly nested) scope belongs to
pub const instanceOf = name_search.instanceOf;

/// `name_search.vecRange`: A vector slot's declared `[msb:lsb]` (an array's first element's is
pub const vecRange = name_search.vecRange;

/// `name_search.isScalar`: §4.3: "A net or reg declaration without a range specification shall
pub const isScalar = name_search.isScalar;

/// `name_search.baseSlot`: The slot an lvalue's width comes from: an array element reference is as
pub const baseSlot = name_search.baseSlot;

/// `name_search.chainBase`: The name at the bottom of a stack of selects, `a` in `a[i][j]`, and
pub const chainBase = name_search.chainBase;

/// `name_search.scalarSlot`: The slot of a reference to one whole value. §3.9's unpacked array has
pub const scalarSlot = name_search.scalarSlot;

/// `name_search.indexedArray`: The array an `.index` names an element of (one index per dimension,
pub const indexedArray = name_search.indexedArray;

/// `name_search.bind`: Binds `name` to slot `at` in the current scope (`scope`). A second
pub const bind = name_search.bind;

/// `declared.timeOf`: IEEE 1364 §19.8 the time scale of the module `scope` is an instance
pub const timeOf = declared.timeOf;

/// `declared.constant`: A constant expression's value at elaboration (IEEE 1364-2005 §5.2 /
pub const constant = declared.constant;

/// `declared.declaredBound`: One declared bound (§3.3, §4.3.1): any constant expression, of any
pub const declaredBound = declared.declaredBound;

/// `declared.declaredDelay`: A.2.2.3 `delay_value ::= unsigned_number | real_number | identifier`, in
pub const declaredDelay = declared.declaredDelay;

/// `declared.declaredDelay3`: One A.2.2.3 `delay3` as the three tick counts §7.14 chooses between. A
pub const declaredDelay3 = declared.declaredDelay3;

/// `declared.declaredWidth`: §3.3/§6.5.2 a packed `[msb:lsb]` range as a bit width
pub const declaredWidth = declared.declaredWidth;

/// `declared.tchkLimits`: IEEE 1364-2005 §27.31 / VAMS §12.29 vpi_put_delays on the timing check
pub const tchkLimits = declared.tchkLimits;

/// `declared.tchkSite`: tchkSite
pub const tchkSite = declared.tchkSite;

/// `run_nets.netCold`: Net `n`'s cold row, or `NetCold.none` when it has none
pub const netCold = run_nets.netCold;

/// `run_nets.netDrivers`: Net `net`'s driver rows (`drivers` indices), in declaration order;
pub const netDrivers = run_nets.netDrivers;

/// `run_nets.driverTransition`: Driver `at`'s §6.1.3 transition row, made on first use. Invalidates
pub const driverTransition = run_nets.driverTransition;

/// `run_nets.netColdMut`: Net `net`'s cold row, made on first use. Invalidates pointers to
pub const netColdMut = run_nets.netColdMut;

/// `run_diag.fail`: Adds an E1100 diagnostic at token `tok` (clamped to the last token)
pub const fail = run_diag.fail;

/// `run_diag.stage`: The stage a diagnostic raised now belongs to (`diag_stage`, #72)
pub const stage = run_diag.stage;

/// `run_diag.failWith`: `fail` under a rule's own code, for a refusal the analog side reports
pub const failWith = run_diag.failWith;

/// `run_diag.deepFail`: A walk ran out of the stack `deep.runGuarded` reserved, at token `tok`
pub const deepFail = run_diag.deepFail;

/// `run_diag.exprFail`: `fail` at expression `e`'s main token, with a fixed message
pub const exprFail = run_diag.exprFail;

/// `vpi.zig`'s requests from a VPI application, called as methods.
pub const vpiEval = vpi.vpiEval;

/// `vpi.vpiConstantIndex`: a constant index the VPI names, folded.
pub const vpiConstantIndex = vpi.vpiConstantIndex;

/// `vpi.vpiPutUdp`: a VPI write of a UDP's state.
pub const vpiPutUdp = vpi.vpiPutUdp;

/// `vpi.vpiAttributeValue`: an attribute's value for `vpi_get_value`.
pub const vpiAttributeValue = vpi.vpiAttributeValue;

const Run = @This();

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
    if (fresh.watch.len != self.watch.len or fresh.drivers.len != self.drivers.len or fresh.checks.rows.items.len != self.checks.rows.items.len)
        return self.fail(0, "IEEE 1364-2005 C.7: the design elaborated again into a different shape", .{});
    fresh.bag = self.bag;
    fresh.vpi_change = self.vpi_change;
    fresh.done_hook = self.done_hook;
    fresh.stmt_hook = self.stmt_hook;
    fresh.checks.hook = self.checks.hook;
    fresh.error_hook = self.error_hook;
    fresh.file_io = self.file_io;
    fresh.probe = self.probe;
    fresh.probe_ctx = self.probe_ctx;
    for (self.watch, fresh.watch) |old, *w| if (old.contains(.vpi)) w.insert(.vpi);
    for (self.drivers, fresh.drivers) |old, *d| d.delay = old.delay;
    for (self.checks.rows.items, fresh.checks.rows.items) |old, *c| c.lim = old.lim;
    self.* = fresh;
}

// ---- private ----
