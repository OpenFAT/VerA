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
const expr_types = @import("expr_types.zig");
const bytecode = @import("bytecode.zig");
const vcd_file = @import("vcd.zig");
const activations = @import("activations.zig");
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
scope: u32 = 0,
/// The instruction a system task is running from, so `%m` can name the
/// §5.3.2 named blocks around it.
pc: u32 = 0,
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
/// §9.3 the procedural continuous assignments in effect, by slot: the
/// process range of an `assign` and of a `force`. While one is, ordinary
/// writes to the slot do not land (`store`); a force outranks an assign.
overrides: std.AutoHashMapUnmanaged(u32, Overrides) = .empty,
/// `store` from an override's own process, which the guard lets through.
overriding: bool = false,
/// The zero-delay-loop guard: events dispatched at one tick (`run_until.EventBudget`).
event_budget: run_until.EventBudget = .{},
/// §10 the subroutine activations in progress (`activations.Calls`).
calls: activations.Calls = .{},
/// What a VPI application attached to the run (`vpi.Host`).
host: vpi.Host = .{},
/// The run's side of a mixed-signal analysis (`analog_link.Link`).
analog: analog_link.Link = .{},
/// IEEE 1364-2005 §18 the value change dumps (`vcd.Dumps`).
dumps: vcd_file.Dumps = .{},
/// The state §17 system tasks keep across calls (`system.TaskState`).
tasks: system.TaskState = .{},
/// IEEE 1364-2005 §19.8 the design's timescales and §17.3 `$timeformat` (`declared.Times`).
time: declared.Times = .{},
/// The elaborated hierarchy and every name bound in it (`name_search.Hierarchy`).
hier: name_search.Hierarchy = .{},
/// §10 the tasks and functions and what calls them (`compile.Routines`).
routines: compile.Routines = .{},
/// The compiled processes (`bytecode.Program`).
program: bytecode.Program = .{},
/// Every expression's checked type and folded facts (`expr_types.Typing`).
typing: expr_types.Typing = .{},
/// Who waits on which slot (`waiters.Waits`): the write path reads this on every store.
waits: waiters.Waits = .{},
/// The scheduler's payload rows and the per-site cells processes use (`exec.Rows`).
rows: exec.Rows = .{},
/// The resolved nets, their drivers and switches (`run_nets.Netlist`).
netlist: run_nets.Netlist = .{},
scheduler: Scheduler,
/// The source's own path, so §17.2.9's memory file resolves beside the
/// module that names it.
file_name: []const u8 = "",
io: ?std.Io = null,
/// §17.1.3 the standing monitor and §17.2.2 the `$fmonitor`s (`monitor.Monitoring`).
monitoring: monitor.Monitoring = .{},
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
/// `Mixed.inserts`, and each row's segment as an identifier expression
/// (minted before pass one, while the expression tables can still grow).
inserts: []const Insert = &.{},
insert_segs: []const Ast.ExprId = &.{},
/// VAMS §9.22 driver access and §9.22.6 segregation (`driver.zig`).
drv: driver.State = .{},
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
/// IEEE 1364-2005 §15 the timing checks (`tchk.Checks`).
checks: tchk.Checks = .{},
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
    if (fresh.waits.watch.len != self.waits.watch.len or fresh.netlist.drivers.len != self.netlist.drivers.len or fresh.checks.rows.items.len != self.checks.rows.items.len)
        return self.fail(0, "IEEE 1364-2005 C.7: the design elaborated again into a different shape", .{});
    fresh.bag = self.bag;
    fresh.host.change = self.host.change;
    fresh.host.done_hook = self.host.done_hook;
    fresh.host.stmt_hook = self.host.stmt_hook;
    fresh.checks.hook = self.checks.hook;
    fresh.host.error_hook = self.host.error_hook;
    fresh.tasks.file_io = self.tasks.file_io;
    fresh.analog.probe = self.analog.probe;
    fresh.analog.probe_ctx = self.analog.probe_ctx;
    for (self.waits.watch, fresh.waits.watch) |old, *w| if (old.contains(.vpi)) w.insert(.vpi);
    for (self.netlist.drivers, fresh.netlist.drivers) |old, *d| d.delay = old.delay;
    for (self.checks.rows.items, fresh.checks.rows.items) |old, *c| c.lim = old.lim;
    self.* = fresh;
}

// ---- private ----
