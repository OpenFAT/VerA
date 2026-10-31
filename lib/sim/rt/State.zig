//! One run of a native design: the planes, the queue and every table a process
//! reads or writes in, the next event the design dispatches out. The
//! emitted code (src/codegen/digital/emit.zig) calls every method as
//! `s.<name>(...)`; each one lives in the file that owns its data and is
//! declared here.
//! Cites: IEEE 1364-2005 §11 (the dispatch loop), §11.4.2 (the `static` order).
//!
//! One run of a native design. Under the `fifo` schedule it is `vera
//! --run`'s queue discipline with only the process bodies compiled: the
//! same waiter lists, fan-out and nonblocking rows, so a process wakes in
//! the interpreter's order. Under `static`, combinational nodes run in one
//! `settle` event in topological order, and a process that suspends only
//! at its entry waits on a per-slot watcher list; a store wakes those
//! processes and the event controls in suspension order (`stamp`).
//!
//! Contents:
//! - `pub const get`
//! - `pub const getw`
//! - `pub const set`
//! - `pub const view`
//! - `pub const put`
//! - `pub const putWord`
//! - `pub const putWordAs`
//! - `pub const putReal`
//! - `pub const store`
//! - `pub const markReaders`
//! - `pub const sensed`
//! - `pub const dirtyReaders`
//! - `pub const nba`
//! - `pub const nbaReal`
//! - `pub const nbaValue`
//! - `pub const nbaAfter`
//! - `pub const nbaRealAfter`
//! - `pub const nbaAfterValue`
//! - `pub const disable`
//! - `pub const stop`
//! - `pub const held`
//! - `pub const overrideOn`
//! - `pub const forcedBits`
//! - `pub const overrideBits`
//! - `pub const releaseBits`
//! - `pub const putBits`
//! - `pub const forced`
//! - `pub const release`
//! - `pub const run`
//! - `pub const runIn`
//! - `pub const runPlain`
//! - `pub const schedFail`
//! - `pub const timeFail`
//! - `pub const enter`
//! - `pub const leave`
//! - `pub const callTimed`
//! - `pub const returnTimed`
//! - `pub const evict`
//! - `pub const makeResident`
//! - `pub const eventContext`
//! - `pub const selectIn`
//! - `pub const wake`
//! - `pub const wakeOf`
//! - `pub const wakeTerms`
//! - `pub const wakeWatchers`
//! - `pub const wakes`
//! - `pub const stamp`
//! - `pub const park`
//! - `pub const watch`
//! - `pub const watchSelected`
//! - `pub const watchTerm`
//! - `pub const watchBits`
//! - `pub const bits`
//! - `pub const recChanged`
//! - `pub const dropRec`
//! - `pub const retire`
//! - `pub const strobe`
//! - `pub const monitor`
//! - `pub const monitorEnable`
//! - `pub const requestMonitor`
//! - `pub const dumpFile`
//! - `pub const dumpVars`
//! - `pub const dumpControl`
//! - `pub const dumpTick`
//! - `pub const requestDump`
//! - `pub const dumpFail`
//! - `pub const dumpPlanes`
//! - `pub const fire`
//! - `pub const dumpSlot`
//! - `pub const capture`
//! - `pub const captured`
//! - `pub const chars`
//! - `pub const setChars`
//! - `pub const literal`
//! - `pub const zeroBegin`
//! - `pub const zeroEnd`
//! - `pub const value`
//! - `pub const realValue`
//! - `pub const time`
//! - `pub const timeReal`
//! - `pub const real`
//! - `pub const netStrength`
//! - `pub const strongStrength`
//! - `pub const text`
//! - `pub const units`
//! - `pub const realtime`
//! - `pub const abstime`
//! - `pub const queue`
//! - `pub const queueFull`
//! - `pub const pla`
//! - `pub const dist`
//! - `pub const readmem`
//! - `pub const random`
//! - `pub const realTicks`
//! - `pub const ticks`
//! - `pub const stopRun`
//! - `pub const finish`
//! - `pub const exit`
//! - `pub const fail`
//! - `pub const say`
//! - `pub const warn`
//! - `pub const diagnose`
//! - `pub const save`
//! - `pub const restore`
//! - `pub const drive`
//! - `pub const switchCtrl`
//! - `pub const gate`
//! - `pub const udp`
//! - `pub const mos`
//! - `pub const bridge`
//! - `pub const pull`
//! - `pub const resolve`
//! - `pub const portsSelect`
//! - `pub const portsControl`
//! - `pub const fopen`
//! - `pub const fileOp`
//! - `pub const fileLine`
//! - `pub const fileWord`
//! - `pub const fileError`
//! - `pub const fclose`
//! - `pub const scan`
//! - `pub const scanFile`
//! - `pub const finishFileScan`
//! - `pub const fshow`
//! - `pub const Format`
//! - `pub const formatOf`
//! - `pub const nextSpec`
//! - `pub const endFormat`
//! - `pub fn init(self: *State, init_: std.process.Init, d: *const Design, time_units: i32) Error!void`
//! - `pub fn initIn(self: *State, gpa: std.mem.Allocator, io: std.Io, d: *const Design, time_units: i32) Error!void`
//! - `pub fn next(self: *State, limit: u64) Error!?u32`
//! - `pub fn loopIteration(self: *State) Error!void`
//! - `pub fn quietState(a: std.mem.Allocator, d: *const Design, time_units: i32) Error!*State`

const std = @import("std");
const assert = std.debug.assert;
const fmt = @import("kernels").fmt;
const system = @import("../digital/system.zig");
const vcd = @import("../digital/vcd.zig");
const Scheduler = @import("../scheduler.zig").Scheduler;
const design = @import("design.zig");
const evcd = @import("evcd.zig");
const logic = @import("logic/root.zig");
const net = @import("net/root.zig");
const planes = @import("planes.zig");
const records = @import("records.zig");
const snapshot = @import("snapshot.zig");
const rt_system = @import("system.zig");
const main = @import("main.zig");
const stores = @import("stores.zig");
const nonblocking = @import("nonblocking.zig");
const holds = @import("holds.zig");
const processes = @import("processes.zig");
const waiters = @import("waiters.zig");
const observe = @import("observe.zig");
const transcript = @import("transcript.zig");
const tasks = @import("tasks.zig");
const diagnostics = @import("diagnostics.zig");
const Design = design.Design;
const Sense = design.Sense;
const Watcher = design.Watcher;
const settle_pc = design.settle_pc;
const Error = design.Error;
const overrides = design.overrides;
const activations = design.activations;
const budget = design.budget;
const wide_slot = design.wide_slot;
const Susp = records.Susp;
const Act = records.Act;
const Resume = records.Resume;
const Term = records.Term;
const Rec = records.Rec;
const Nba = records.Nba;
const Late = records.Late;
const nba_payload = records.nba_payload;
const settle_payload = records.settle_payload;
const monitor_payload = records.monitor_payload;
const vcd_payload = records.vcd_payload;
const show_base = records.show_base;
const late_base = records.late_base;
const resume_base = records.resume_base;
const Layers = records.Layers;
const Part = records.Part;
const poke = planes.poke;
const W = logic.W;
const loop = main.loop;

const testing = std.testing;

/// The allocator every table is allocated from; nothing is freed (`initIn`).
gpa: std.mem.Allocator,
v: []u64,
x: []u64,
sched: Scheduler,
/// The NBA region's rows, in the order they were queued.
rows: std.ArrayList(Nba) = .empty,
words: std.ArrayList(u64) = .empty,
susps: std.ArrayList(Susp) = .empty,
free_susps: std.ArrayList(u32) = .empty,
/// The select terms' bits (`Term.rec`), and the rows free.
recs: std.ArrayList(Rec) = .empty,
free_recs: std.ArrayList(u32) = .empty,
terms: []std.ArrayList(Term),
fan_start: []const u32,
fan: []const u32,
armed: []bool,
comb_start: []const u32,
comb: []const Sense,
/// The slots with node readers that changed since the settle event was
/// queued, each once (`pending`): a slot written many times before the
/// settle costs its fan-out once.
changed: std.ArrayList(u32) = .empty,
pending: []bool,
/// Per plane word of a slot with node readers: the bits that changed
/// since its readers were last marked.
diff: []u64,
/// One bit per combinational node, set while the settle event runs.
dirty: []u64,
settle: enum { idle, queued, running } = .idle,
watch_start: []const u32,
watchers: []const Watcher,
/// Per triggered process: the `stamp` of its suspension at its event
/// control, 0 while it runs.
waiting: []u64,
/// The last `stamp`.
seq: u64 = 0,
repeats: []u64,
/// §9.8.2: per `fork`, the arms still running.
joins: []u32,
/// §9.2.2 `<= #d` updates in flight, by `late_base` payload; a free row
/// has no words.
late: std.ArrayList(Late) = .empty,
free_late: std.ArrayList(u32) = .empty,
/// §10: per subroutine, its synchronous activations running; the one a
/// `disable` is unwinding; how deep they nest; the automatic frames
/// they set aside, both planes, innermost last.
active: []u32,
unwind: ?u32 = null,
depth: u32 = 0,
saved: std.ArrayList(u64) = .empty,
/// §10.2.3 (`activations`): the activation the running process is in
/// (0 for none); every one in progress (row 0 unused) and the rows free;
/// per task, the activation its automatic frame holds; the queued
/// continuations inside one; per slot, `Design.act_events`. `jump` is
/// the pc `dispatch` runs next, without queueing (a call or a return),
/// `returned` says the call site at that pc is being returned to.
ctx: u32 = 0,
acts: std.ArrayList(Act) = .empty,
free_acts: std.ArrayList(u32) = .empty,
resident: []u32 = &.{},
resumes: std.ArrayList(Resume) = .empty,
free_resumes: std.ArrayList(u32) = .empty,
act_events: []const u32 = &.{},
jump: ?u32 = null,
returned: bool = false,
/// §17.1.3: the standing monitor's site and the slots it watches.
monitored: []bool,
mon_site: ?u32 = null,
mon_on: bool = true,
mon_pending: bool = false,
/// §17.6 the stochastic queues, by `q_id`.
queues: system.Queues = .empty,
/// `Run.random_seed`.
random_seed: i32 = 0,
/// §9.3 per slot (empty when the design has no `assign` or `force`):
/// the pc ranges of the procedural continuous assignments holding it.
/// While one does, only its own process (`overriding`) writes the slot.
layers: []Layers,
/// `Design.part_start` and one `Part` per forced select it numbers.
part_start: []const u32 = &.{},
parts: []Part,
overriding: bool = false,
/// §18 the dump, the design's catalog, and per slot (empty without a
/// catalog) whether a change is dumped.
dump: vcd.Vcd = .{},
catalog: ?*const vcd.Catalog,
/// §18.3 the extended dump: the files, what each has written, and the
/// time its `$dumpports` calls ran at. Outside a snapshot, as `dump` is.
port_files: []const evcd.File = &.{},
port_live: []evcd.Live = &.{},
ports_at: ?u64 = null,
dumped: []bool,
/// §7.9 resolution state (`net.zig`).
nets: net.Nets,
/// `capture`'s buffer, and `scan`'s characters.
cap: std.Io.Writer.Allocating,
scratch: std.heap.ArenaAllocator,
time_format: fmt.TimeFormat,
budget_time: u64 = 0,
budget_used: u64 = 0,
/// `--state=auto` (`auto`): per plane word, the bits that must be known
/// before the 2-state phase may begin (empty: never); the phase has
/// begun (`Phase(true)`), and at which tick; the time steps begun, and
/// the count at which the planes are next looked at.
live: []u64 = &.{},
two: bool = false,
two_at: u64 = 0,
steps: u64 = 0,
look_at: u64 = 1,
stdout: std.Io.File.Writer,
/// Where the transcript goes (`stdout`, unless redirected), and where
/// it goes now: `sink`, or a `capture`.
sink: *std.Io.Writer,
out: *std.Io.Writer,
/// A '0'-flag field in progress (`zeroBegin`): where `out` pointed, and
/// the field's text.
zero_out: ?*std.Io.Writer = null,
zero_field: std.Io.Writer.Allocating = undefined,
/// A run whose effects outside `State` are dropped (`snapshot.twice`):
/// no transcript, no diagnostic, no file opened, read or written, no
/// dump. Every file descriptor reads as unknown.
quiet: bool = false,
io: std.Io,
buf: [1 << 16]u8,

// `stores.zig`.
/// `stores.get`: The value of at most 64 bits at word `off`
pub const get = stores.get;

/// `stores.getw`: The `n`-word value at word `off`
pub const getw = stores.getw;

/// `stores.set`: The bits `m` of the value at word `off` become `a`'s, for a slot no
pub const set = stores.set;

/// `stores.view`: The settle event's hold on the planes and dirty words
pub const view = stores.view;

/// `stores.put`: `waiters.store` of the bits `m` of `slot`, whose words start at `off`:
pub const put = stores.put;

/// `stores.putWord`: `put` of the bits `m` of word `j` alone: a bit-select of a wide slot
pub const putWord = stores.putWord;

/// `stores.putWordAs`: `putWord`; `k` as `poke`'s
pub const putWordAs = stores.putWordAs;

/// `stores.putReal`: `put` of a real (§4.8, `waiters.store`): it changes when its value
pub const putReal = stores.putReal;

/// `stores.store`: `put` of the bits `m` of an `n`-word value at runtime width
pub const store = stores.store;

/// `stores.markReaders`: Marks dirty the nodes that read a bit of `slot` changed since the
pub const markReaders = stores.markReaders;

/// `stores.sensed`: Whether a node reads some bit of `slot`
pub const sensed = stores.sensed;

/// `stores.dirtyReaders`: `slot` changed: its node readers run in the settle event, which is
pub const dirtyReaders = stores.dirtyReaders;

// `nonblocking.zig`.
/// `nonblocking.nba`: §9.2.2: schedule the bits `m` of `slot` (words from `off`) to become
pub const nba = nonblocking.nba;

/// `nonblocking.nbaReal`: §9.2.2 NBA of a §4.8 real, retaining numeric change detection
pub const nbaReal = nonblocking.nbaReal;

/// `nonblocking.nbaValue`: nbaValue
pub const nbaValue = nonblocking.nbaValue;

/// `nonblocking.nbaAfter`: §9.2.2 `<= #d`: `nba` of the update `after` ticks later. At 0 it
pub const nbaAfter = nonblocking.nbaAfter;

/// `nonblocking.nbaRealAfter`: `nbaAfter` retaining the target's real type until the update lands
pub const nbaRealAfter = nonblocking.nbaRealAfter;

/// `nonblocking.nbaAfterValue`: nbaAfterValue
pub const nbaAfterValue = nonblocking.nbaAfterValue;

// `holds.zig`.
/// `holds.disable`: §10.3 `disable` of the named block or task copy at pcs `[lo, hi)`:
pub const disable = holds.disable;

/// `holds.stop`: `exec.stopRange`: end every process suspended or queued in pcs
pub const stop = holds.stop;

/// `holds.held`: §9.3: an `assign` or `force` holds `slot` and blocks every write but
pub const held = holds.held;

/// `holds.overrideOn`: `exec` `.override_on`: the `assign` (or `force`) whose process is pcs
pub const overrideOn = holds.overrideOn;

/// `holds.forcedBits`: The bits of word `j` of `slot` that a forced select holds against
pub const forcedBits = holds.forcedBits;

/// `holds.overrideBits`: `exec` `.override_on` of a forced select: `parts[k]`, bits
pub const overrideBits = holds.overrideBits;

/// `holds.releaseBits`: `waiters.releaseBits`: `parts[k]`, a select of `slot`, is its
pub const releaseBits = holds.releaseBits;

/// `holds.putBits`: A forced select's own write: bits [lo, lo + bw) of the `sw`-bit
pub const putBits = holds.putBits;

/// `holds.forced`: Is `slot` forced? An `assign` under a force keeps tracking but does
pub const forced = holds.forced;

/// `holds.release`: `waiters.release`: §9.3 `deassign` (`force` false) or `release` of
pub const release = holds.release;

// `processes.zig`.
/// `processes.run`: Queues the running process's continuation at `pc`, in its activation
pub const run = processes.run;

/// `processes.runIn`: `run` in activation `ctx` (`exec.resumption`)
pub const runIn = processes.runIn;

/// `processes.runPlain`: Queues the process at `pc` outside any activation: now (active), or
pub const runPlain = processes.runPlain;

/// `processes.schedFail`: A scheduling failure as `error.OutOfMemory`, or an E1100 refusal
pub const schedFail = processes.schedFail;

/// `processes.timeFail`: `schedFail` of a failure to schedule a delay
pub const timeFail = processes.timeFail;

/// `processes.enter`: §10.2.2 a synchronous activation of subroutine `sub` begins. An
pub const enter = processes.enter;

/// `processes.leave`: The activation `enter` began has returned. Restore the caller before
pub const leave = processes.leave;

/// `processes.callTimed`: `exec.callTimed`: §10.2.2 task `sub` begins a new activation, whose
pub const callTimed = processes.callTimed;

/// `processes.returnTimed`: `exec.returnTimed`: the running activation has ended (the emitted
pub const returnTimed = processes.returnTimed;

/// `processes.evict`: Save the resident activation of automatic task `sub`, freeing its frame
pub const evict = processes.evict;

/// `processes.makeResident`: `exec.makeResident`: activation `ctx`'s storage in its task's frame
pub const makeResident = processes.makeResident;

/// `processes.eventContext`: `waiters.eventContext`: the live activation of automatic task `sub`
pub const eventContext = processes.eventContext;

/// `processes.selectIn`: `waiters.selectedEvent`: §9.7.3 the element `select` names, read in the
pub const selectIn = processes.selectIn;

// `waiters.zig`.
/// `waiters.wake`: `waiters.wake`: the continuous drivers reading `slot` first, then the
pub const wake = waiters.wake;

/// `waiters.wakeOf`: `wake` of what `reach` names alone
pub const wakeOf = waiters.wakeOf;

/// `waiters.wakeTerms`: `wake` of the event controls filed under `slot`, in the order they
pub const wakeTerms = waiters.wakeTerms;

/// `waiters.wakeWatchers`: `wake` of the triggered processes watching `slot` that suspended
pub const wakeWatchers = waiters.wakeWatchers;

/// `waiters.wakes`: What a change of `slot` would wake now: `.any` when a continuous
pub const wakes = waiters.wakes;

/// `waiters.stamp`: The next suspension's order among all of them: `vera --run` wakes
pub const stamp = waiters.stamp;

/// `waiters.park`: `waiters.park`: suspend the running process, to resume at `pc`
pub const park = waiters.park;

/// `waiters.watch`: `waiters.watch`: file one term of suspension `id` under `slot`
pub const watch = waiters.watch;

/// `waiters.watchSelected`: §9.7.3: only an occurrence of the selected element wakes this
pub const watchSelected = waiters.watchSelected;

/// `waiters.watchTerm`: watchTerm
pub const watchTerm = waiters.watchTerm;

/// `waiters.watchBits`: §9.7.2 a constant select term: bits `[lo, lo + width)` (at most 64)
pub const watchBits = waiters.watchBits;

/// `waiters.bits`: A select term's bits now
pub const bits = waiters.bits;

/// `waiters.recChanged`: Did select term `k`'s bits change in a way `edge` matches (of their
pub const recChanged = waiters.recChanged;

/// `waiters.dropRec`: A term leaves its list: its select bits' row is free
pub const dropRec = waiters.dropRec;

/// `waiters.retire`: retire
pub const retire = waiters.retire;

// `observe.zig`.
/// `observe.strobe`: §17.1.2 `$strobe` site `site`: its line at the end of this timestep
pub const strobe = observe.strobe;

/// `observe.monitor`: §17.1.3 `$monitor` site `site`, watching `slots`, replaces the
pub const monitor = observe.monitor;

/// `observe.monitorEnable`: `$monitoron` / `$monitoroff`: the site whose line `$monitoron`
pub const monitorEnable = observe.monitorEnable;

/// `observe.requestMonitor`: requestMonitor
pub const requestMonitor = observe.requestMonitor;

/// `observe.dumpFile`: §18.1 `$dumpfile` of the characters of a `w`-bit `name`; `call` is
pub const dumpFile = observe.dumpFile;

/// `observe.dumpVars`: §18.1.2 one `$dumpvars` (`vcd.Vcd.select`); its dump starts at the
pub const dumpVars = observe.dumpVars;

/// `observe.dumpControl`: `$dumpoff`, `$dumpon`, `$dumpall`, `$dumpflush` (`vcd.Vcd.control`)
pub const dumpControl = observe.dumpControl;

/// `observe.dumpTick`: dumpTick
pub const dumpTick = observe.dumpTick;

/// `observe.requestDump`: One dump event per step however many dumped values moved
pub const requestDump = observe.requestDump;

/// `observe.dumpFail`: dumpFail
pub const dumpFail = observe.dumpFail;

/// `observe.dumpPlanes`: `vcd.Vcd`'s value source: catalog variable `v`'s planes
pub const dumpPlanes = observe.dumpPlanes;

/// `observe.fire`: §18.2.2 named event `slot` was triggered (`vcd.Vcd.fire`); the
pub const fire = observe.fire;

/// `observe.dumpSlot`: `vcd.Vcd`'s hook: a change of `slot` asks for a dump event
pub const dumpSlot = observe.dumpSlot;

// `transcript.zig`.
/// `transcript.capture`: Everything printed until `captured` or `fshow` goes to a buffer
pub const capture = transcript.capture;

/// `transcript.captured`: Ends a `capture`: the bytes printed since, valid until the next one
pub const captured = transcript.captured;

/// `transcript.chars`: `system.text` of a `w`-bit value
pub const chars = transcript.chars;

/// `transcript.setChars`: The characters `bytes` in the `w`-bit cell at word `off`, the last
pub const setChars = transcript.setChars;

/// `transcript.literal`: `a`'s planes as the `Literal` the interpreter formats
pub const literal = transcript.literal;

/// `transcript.zeroBegin`: The next field is a `%05d`/`%04t`: written aside until `zeroEnd`
pub const zeroBegin = transcript.zeroBegin;

/// `transcript.zeroEnd`: zeroEnd
pub const zeroEnd = transcript.zeroEnd;

/// `transcript.value`: One `%b`/`%o`/`%h`/`%d` operand (§17.1.1.3)
pub const value = transcript.value;

/// `transcript.realValue`: One `%d %h %o %b` operand of real type (`display.realRadix`)
pub const realValue = transcript.realValue;

/// `transcript.time`: One integral `%t` operand, in a module whose unit is 10^`unit_exp` s
pub const time = transcript.time;

/// `transcript.timeReal`: One `%t` operand of real type, formatted as it is (#64)
pub const timeReal = transcript.timeReal;

/// `transcript.real`: One real conversion (§17.1.1.2 `%e %f %g`, §9.4.7 `%r`): C's text
pub const real = transcript.real;

/// `transcript.netStrength`: §17.1.1.5 `%v` of the native net `k` (`Nets.sig0`, kept by the fold
pub const netStrength = transcript.netStrength;

/// `transcript.strongStrength`: §17.1.1.5 `%v` of an operand that is not a net: its bit 0, strong
pub const strongStrength = transcript.strongStrength;

/// `transcript.text`: One `%s` or `%c` operand (§17.1.1.7)
pub const text = transcript.text;

// `tasks.zig`.
/// `tasks.units`: §17.7.1 `$time`: now, in the invoking module's unit
pub const units = tasks.units;

/// `tasks.realtime`: §17.7.2 `$realtime`: now, in the invoking module's unit, unrounded
pub const realtime = tasks.realtime;

/// `tasks.abstime`: VAMS §9.10 `$abstime`: now in seconds, the tick being 10^`finest` s
pub const abstime = tasks.abstime;

/// `tasks.queue`: §17.6 queue task `op` (`system.queueStep`), at now in `scale`'s unit
pub const queue = tasks.queue;

/// `tasks.queueFull`: §17.6.5 `$q_full` of queue `id`
pub const queueFull = tasks.queueFull;

/// `tasks.pla`: §17.5 `system.plaEval` of the `nrows` `rw`-bit rows from word `off`
pub const pla = tasks.pla;

/// `tasks.dist`: §17.9 `system.dist`, with the interpreter's W1151 warning where the
pub const dist = tasks.dist;

/// `tasks.readmem`: §17.2.9 `$readmemb`/`$readmemh` of the file `name` beside `source`
pub const readmem = tasks.readmem;

/// `tasks.random`: §17.9.1 a seedless `$random`
pub const random = tasks.random;

/// `tasks.realTicks`: `exec.delayOf` of a real delay (§9.7.1), rounded to the precision
pub const realTicks = tasks.realTicks;

/// `tasks.ticks`: `exec.delayOf` of an integral delay (§9.7.1): x/z reads as 0
pub const ticks = tasks.ticks;

/// `tasks.stopRun`: §17.4.2 `$stop`: a batch run has nothing to suspend into, so it ends
pub const stopRun = tasks.stopRun;

/// `tasks.finish`: §17.4.1 `$finish`: end the run after this process step
pub const finish = tasks.finish;

// `diagnostics.zig`.
/// `diagnostics.exit`: Exit status, after flushing the transcript
pub const exit = diagnostics.exit;

/// `diagnostics.fail`: A run-time refusal in `vera --run`'s words (E1100), on stderr
pub const fail = diagnostics.fail;

/// `diagnostics.say`: say
pub const say = diagnostics.say;

/// `diagnostics.warn`: A run-time warning in `vera --run`'s words, on stderr
pub const warn = diagnostics.warn;

/// `diagnostics.diagnose`: One diagnostic line on stderr, `head` then the message, after the
pub const diagnose = diagnostics.diagnose;

/// `snapshot.save`: this state as a tick boundary.
pub const save = snapshot.save;

/// `snapshot.restore`: a tick boundary `save` wrote.
pub const restore = snapshot.restore;

/// §7.9 the net-resolution entry points (`net.zig`).
pub const drive = net.drive;

/// `net.switchCtrl`: §7.6 a pass switch's control changed.
pub const switchCtrl = net.switchCtrl;

/// `net.gate`: §7.8.5 a gate's output bit.
pub const gate = net.gate;

/// `net.udp`: §8 a UDP's output bit.
pub const udp = net.udp;

/// `net.mos`: §7.6 a MOS switch's output.
pub const mos = net.mos;

/// `net.bridge`: §6.5.7.1 a port window's bits.
pub const bridge = net.bridge;

/// `net.pull`: §19.9 an `unconnected_drive` level.
pub const pull = net.pull;

/// `net.resolve`: §7.9 a net folded from its drivers and published.
pub const resolve = net.resolve;

/// `evcd.select`: §18.3 a `$dumpports` call selects its file.
pub const portsSelect = evcd.select;

/// `evcd.control`: §18.3 `$dumpportsoff`/`on`/`all`/`limit`/`flush`.
pub const portsControl = evcd.control;

/// §17.2.1 `$fopen`.
pub const fopen = rt_system.fopen;

/// The §17.2 descriptor tasks `system.fileOp` covers.
pub const fileOp = rt_system.fileOp;

/// §17.2.4.2 `$fgets`.
pub const fileLine = rt_system.fileLine;

/// §17.2.4.4 `$fread` of one word.
pub const fileWord = rt_system.fileWord;

/// §17.2.7 `$ferror`.
pub const fileError = rt_system.fileError;

/// §17.2.1 `$fclose`.
pub const fclose = rt_system.fclose;

/// §17.2.4.3 `$sscanf`.
pub const scan = rt_system.scan;

/// §17.2.4.3 `$fscanf`, ended by `finishFileScan`.
pub const scanFile = rt_system.scanFile;

/// The end of a `scanFile`.
pub const finishFileScan = rt_system.finishFileScan;

/// §17.2.2 a `capture` sent to a descriptor's channels.
pub const fshow = rt_system.fshow;

/// §17.2.3 a `$sformat` format held in a variable.
pub const Format = rt_system.Format;

/// The `Format` of a held value.
pub const formatOf = rt_system.formatOf;

/// A `Format`'s next argument-taking conversion.
pub const nextSpec = rt_system.nextSpec;

/// A `Format`'s text after its last argument.
pub const endFormat = rt_system.endFormat;

const State = @This();

/// In place: `out` points into `self`. The time-0 queue is `d.order`.
pub fn init(self: *State, init_: std.process.Init, d: *const Design, time_units: i32) Error!void {
    return self.initIn(std.heap.smp_allocator, init_.io, d, time_units);
}

/// `init` with its storage from `gpa`, printing through `io`. Every
/// table is allocated from `gpa` and none is freed: a `State` has no
/// `deinit`, so give it an arena, or let the process exit reclaim it.
/// The time-0 processes (`d.order`) are queued, not run.
pub fn initIn(self: *State, gpa: std.mem.Allocator, io: std.Io, d: *const Design, time_units: i32) Error!void {
    assert(d.v.len == d.x.len);
    assert(d.code_len < show_base); // Every pc is a payload below the display band.
    if (d.nodes != 0) assert(d.comb_start.len == d.slots + 1);
    self.* = .{
        .gpa = gpa,
        .v = try gpa.dupe(u64, d.v),
        .x = try gpa.dupe(u64, d.x),
        .sched = .empty,
        .terms = try gpa.alloc(std.ArrayList(Term), d.slots),
        .fan_start = d.fan_start,
        .fan = d.fan,
        .armed = try gpa.alloc(bool, d.code_len),
        .comb_start = d.comb_start,
        .comb = d.comb,
        .pending = try gpa.alloc(bool, if (d.nodes == 0) 0 else d.slots),
        .diff = try gpa.alloc(u64, if (d.nodes == 0) 0 else d.v.len),
        .dirty = try gpa.alloc(u64, (d.nodes + 63) / 64),
        .watch_start = d.watch_start,
        .watchers = d.watchers,
        .waiting = try gpa.alloc(u64, d.triggered),
        .repeats = try gpa.alloc(u64, d.repeats),
        .joins = try gpa.alloc(u32, d.joins),
        .active = try gpa.alloc(u32, d.subs),
        .resident = try gpa.alloc(u32, if (activations) d.subs else 0),
        .act_events = d.act_events,
        .monitored = try gpa.alloc(bool, d.slots),
        .time_format = .{ .units = time_units },
        .cap = .init(gpa),
        .layers = try gpa.alloc(Layers, if (overrides) d.slots else 0),
        .part_start = d.part_start,
        .parts = try gpa.alloc(Part, if (d.part_start.len == 0) 0 else d.part_start[d.part_start.len - 1]),
        .catalog = d.vcd,
        .port_files = d.ports_dump,
        .port_live = try gpa.alloc(evcd.Live, d.ports_dump.len),
        .dumped = try gpa.alloc(bool, if (d.vcd != null) d.slots else 0),
        .nets = try .init(gpa, d.nets, d.drivers, d.udps, d.trans),
        .scratch = .init(gpa),
        .stdout = undefined,
        .sink = undefined,
        .out = undefined,
        .io = io,
        .buf = undefined,
    };
    self.stdout = std.Io.File.stdout().writerStreaming(io, &self.buf);
    try net.seedPaths(&self.nets, gpa, d.v, d.x);
    self.sink = &self.stdout.interface;
    self.out = self.sink;
    @memset(self.terms, .empty);
    @memset(self.armed, false);
    @memset(self.pending, false);
    // Each slot at most once (`pending`): `changed` never grows.
    try self.changed.ensureTotalCapacityPrecise(gpa, self.pending.len);
    @memset(self.diff, 0);
    @memset(self.dirty, 0);
    @memset(self.waiting, 0);
    @memset(self.repeats, 0);
    @memset(self.joins, 0);
    @memset(self.active, 0);
    @memset(self.resident, 0);
    @memset(self.monitored, false);
    @memset(self.layers, .{});
    @memset(self.parts, .{});
    @memset(self.dumped, false);
    @memset(self.port_live, .{});
    // §7.11: the switch groups `Run.elaborate` settled, again, so each
    // has its signal (`Nets.sig0`, `%v`) before any process runs.
    for (self.nets.on_net, 0..) |l, k| if (l.len != 0) try net.resolve(self, @intCast(k));
    for (d.order) |pc| try self.runPlain(pc, null);
    assert(self.out == self.sink);
    assert(self.sched.now == 0);
}

/// The next process to dispatch, at the pc it resumes at, or
/// `settle_pc`, or `show_base + k`; null once the queue is empty or
/// `$finish` ran, or when the next event is past tick `limit`
/// (`Scheduler.nextUntil`). Nonblocking updates are applied here.
pub fn next(self: *State, limit: u64) Error!?u32 {
    assert(self.settle != .queued or self.changed.items.len != 0);
    while (self.sched.nextUntil(limit)) |event| {
        assert(event.time <= limit);
        try self.count(event.time);
        if (event.payload >= late_base) {
            const k = event.payload - late_base;
            const row = self.late.items[k];
            assert(row.words.len == 3 * row.n); // Freed only here, once.
            if (row.real)
                try self.putReal(row.slot, row.off, .{ .v = row.words[0], .x = 0 }, row.words[2])
            else
                try self.store(row.slot, row.off, row.words[0..row.n], row.words[row.n..][0..row.n], row.words[2 * row.n ..]);
            self.gpa.free(row.words);
            self.late.items[k].words = &.{};
            try self.free_late.append(self.gpa, k);
            continue;
        }
        if (activations and event.payload >= resume_base) {
            const k = event.payload - resume_base;
            const row = self.resumes.items[k];
            assert(row.live);
            self.resumes.items[k].live = false;
            try self.free_resumes.append(self.gpa, k);
            self.ctx = row.ctx;
            try self.makeResident(row.ctx);
            return row.pc;
        }
        if (event.payload == vcd_payload) {
            try self.dumpTick();
            continue;
        }
        if (event.payload == monitor_payload) {
            self.mon_pending = false;
            // Requested while on, so it reports though a `$monitoroff`
            // followed (`display.monitorPrint`).
            if (self.mon_site) |k| return show_base + k;
            continue;
        }
        if (event.payload == settle_payload) {
            for (self.changed.items) |slot| {
                self.pending[slot] = false;
                self.markReaders(slot);
            }
            self.changed.clearRetainingCapacity();
            self.settle = .running;
            if (activations) self.ctx = 0;
            return settle_pc;
        }
        if (event.payload >= net.drive_base and event.payload < nba_payload) {
            try net.arrive(self, event.payload);
            continue;
        }
        if (event.payload != nba_payload) {
            if (activations) self.ctx = 0;
            return event.payload;
        }
        assert(self.rows.items.len != 0); // Queued with the first row (`nbaValue`).
        for (self.rows.items, 0..) |*row, i| {
            if (i != 0) try self.count(event.time);
            const w: []const u64 = if (row.n == 1) &row.one else self.words.items[row.at..][0 .. 3 * row.n];
            if (row.real) {
                try self.putReal(row.slot, row.off, .{ .v = w[0], .x = 0 }, w[2]);
            } else if (row.quiet) {
                if (self.held(row.slot)) continue;
                if (row.n != 1) {
                    poke(logic.two, self.v.ptr, self.x.ptr, row.off, .{ .v = w[0..row.n], .x = w[row.n..][0..row.n] }, w[2 * row.n ..]);
                } else if (self.two) {
                    // `Phase(true).nba` let no x into the row.
                    poke(true, self.v.ptr, self.x.ptr, row.off, W{ .v = row.one[0], .x = 0 }, row.one[2]);
                } else self.set(row.off, W{ .v = row.one[0], .x = row.one[1] }, row.one[2]);
            } else try self.store(row.slot, row.off, w[0..row.n], w[row.n..][0..row.n], w[2 * row.n ..]);
        }
        self.rows.clearRetainingCapacity();
        self.words.clearRetainingCapacity();
    }
    return null;
}

/// One pass back to the top of a loop in the emitted process: counted
/// against the same budget as the step's events, so an untimed loop is
/// refused by name instead of hanging (`exec.loopIteration`'s rule and
/// message), in the count `next` keeps for the current time.
pub fn loopIteration(self: *State) Error!void {
    assert(self.budget_time == self.sched.now or self.budget_used == 0);
    self.budget_used += 1;
    if (self.budget_used > budget)
        return self.fail("more than {d} loop iterations and events at time {d}: a loop with no delay keeps simulation time from advancing", .{ budget, self.sched.now });
}

/// A `State` over `d` whose effects stay inside it (`State.quiet`): no
/// diagnostic, no file, no dump, and its transcript in memory
/// (`sink.buffered()`). `time_units` is `init`'s. Everything is
/// allocated from `a` and never freed (`State.initIn`): give it an arena.
/// The contract device opens its engine this way (`device.zig`).
pub fn quietState(a: std.mem.Allocator, d: *const Design, time_units: i32) Error!*State {
    assert(time_units <= 2); // A §19.8 exponent.
    assert(time_units >= -15);
    const s = try a.create(State);
    try s.initIn(a, std.Io.failing, d, time_units);
    const memory = try a.create(std.Io.Writer.Allocating);
    memory.* = .init(a);
    s.quiet = true;
    s.sink = &memory.writer;
    s.out = s.sink;
    assert(s.quiet);
    return s;
}

// ---- private ----

/// `Run.runUntil`'s zero-delay-loop guard, counted the same way: one
/// event per nonblocking row.
inline fn count(self: *State, at: u64) Error!void {
    assert(at >= self.budget_time);
    if (at != self.budget_time) {
        // §18.4: the extended dump's changes at the end of the step.
        if (self.port_live.len != 0) try evcd.tick(self, self.budget_time);
        self.budget_time = at;
        self.budget_used = 0;
        if (self.live.len != 0 and !self.two) self.boundary(at);
    }
    self.budget_used += 1;
    if (self.budget_used > budget)
        return self.fail("more than {d} events at time {d}: a zero-delay loop keeps simulation time from advancing", .{ budget, at });
}

/// A time step begins and every process is suspended: if no bit `live`
/// names is x or z, the 2-state phase begins. The x left in the other
/// words (`Design.dead`) is never read before it is overwritten. Looked
/// at on the 1st, 2nd, 4th, ... step, so a design that keeps an x costs
/// a scan per doubling.
fn boundary(self: *State, at: u64) void {
    assert(!self.two);
    assert(self.live.len == self.x.len);
    self.steps += 1;
    if (self.steps != self.look_at) return;
    self.look_at *= 2;
    var any: u64 = 0;
    for (self.x, self.live) |x, l| any |= x & l;
    if (any != 0) return;
    @memset(self.x, 0);
    self.two = true;
    self.two_at = at;
}

fn initOnce(gpa: std.mem.Allocator, d: *const Design) !void {
    // `State` frees nothing itself (`initIn`): its arena does.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    _ = try quietState(arena.allocator(), d, -9);
}

test "State.initIn fails cleanly at every allocation" {
    try testing.checkAllAllocationFailures(testing.allocator, initOnce, .{&wide_slot});
}
