//! The row types of `Run`'s tables: names and scopes, arrays and vector ranges, monitors and watchers, subroutines, overrides and frames. Data only.
//! Cites: IEEE 1364-2005 §4.9, §5.2.1, §9.3, §10, §12.5, §17.1.3; VAMS §5.10.3, §8.5.
//!
//! Contents:
//! - `pub const Name = struct`
//! - `pub const SpecExpr = struct`
//! - `pub const TyState = enum(u8)`
//! - `pub const Array = struct`
//! - `pub const Span = struct`
//! - `pub const VecRange = struct`
//! - `VecRange.position(r: VecRange, index: i64) i64`
//! - `pub const Standing = struct`
//! - `pub const Watcher = enum`
//! - `pub const Stop = enum`
//! - `pub const Monitor = struct`
//! - `pub const MonitorKind = enum`
//! - `pub const D2aSite = struct`
//! - `pub const PathKey = struct`
//! - `PathKey.Ctx = struct`
//! - `PathKey.Ctx.hash(_: Ctx, k: PathKey) u64`
//! - `PathKey.Ctx.eql(_: Ctx, a: PathKey, b: PathKey) bool`
//! - `pub const Sub = struct`
//! - `pub const SlotMemo = struct`
//! - `pub const memo_bits`
//! - `pub const ModuleTime = struct`
//! - `pub const Overrides = struct`
//! - `pub const PcRange = struct`
//! - `pub const Frame = struct`
//! - `pub const SlotNets = struct`
//! - `SlotNets.get(self: *const SlotNets, slot: u32) ?u32`
//! - `SlotNets.contains(self: *const SlotNets, slot: u32) bool`
//! - `SlotNets.put(self: *SlotNets, arena: std.mem.Allocator, slot: u32, net: u32) Error!void`
//! - `pub const default_quantum: Time.Quantum`
//! - `pub fn isRoot(r: *const Run, scope: u32) bool`

const std = @import("std");
const assert = std.debug.assert;
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

/// One declared identifier, qualified by the §6.2.2 instance that declared it.
pub const Name = struct { scope: u32, str: Ast.StrId };

/// One expression in one specialization (`Run.specOf`).
pub const SpecExpr = struct { spec: u32, e: Ast.ExprId };

/// How many distinct types the specializations that typed a row gave it.
pub const TyState = enum(u8) { untyped, one, many };

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
        const p = if (r.msb >= r.lsb) index -| r.lsb else r.lsb -| index;
        if (index == r.lsb) assert(p == 0);
        if (index == r.msb) assert(p == if (r.msb >= r.lsb) r.msb -| r.lsb else r.lsb -| r.msb);
        return p;
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
pub const Monitor = struct { expr: Ast.ExprId, scope: u32, slot: u32, kind: MonitorKind };

/// A.6.5 `analog_event_functions`, the four VAMS §5.10.3 events a monitor is.
pub const MonitorKind = enum { cross, above, timer, absdelta };

/// One digital event term of an analog event control (`Run.watchEvent`).
pub const D2aSite = struct { slot: u32, edge: waiters.Edge, site: u6 };

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
pub const SlotMemo = struct {
    scope: u32 = std.math.maxInt(u32),
    e: Ast.ExprId = .none,
    at: u32 = 0,

    // Budget: 4096 rows of 12 B, 48 KiB, inside L2.
    comptime {
        std.debug.assert(@sizeOf(SlotMemo) == 12);
    }
};

/// log2 of `Run.slot_memo`'s length: 4096 entries, 48 KiB.
pub const memo_bits = 12;

/// A module's §19.8 time scale, and its unit as a power of ten of a second.
pub const ModuleTime = struct { scale: Time.Scale, unit_exp: i32 };

/// §9.3 one slot's procedural continuous assignments: the pc range of the
/// process maintaining each.
pub const Overrides = struct {
    assign: ?PcRange = null,
    force: ?PcRange = null,
    /// IEEE 1364-2005 §9.3.2 forces of constant selects of the net, each
    /// holding its own bits.
    parts: std.ArrayList(PartForce) = .empty,
};

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
pub const SlotNets = struct {
    of: std.ArrayList(u32) = .empty,

    const none = std.math.maxInt(u32);

    /// The net slot `slot` is, or null for a variable's slot.
    pub fn get(self: *const SlotNets, slot: u32) ?u32 {
        std.debug.assert(slot != none);
        if (slot >= self.of.items.len) return null;
        std.debug.assert(slot < self.of.items.len);
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
        std.debug.assert(self.of.items.len >= slot + 1);
        std.debug.assert(self.get(slot).? == net);
    }
};

/// IEEE 1364-2005 §19.8: "If there is no `timescale specified or it has been
/// reset by a `resetall directive, the time unit and precision are
/// simulator-specific." Not an error: this simulator's are one second,
/// unit and precision alike, which makes every delay a whole count of units
/// and `$time`, `$realtime` and `%t` print the numbers the source wrote.
pub const default_quantum: Time.Quantum = .s;

/// One `force` of a constant select (§9.3.2): the bits it holds and the
/// process maintaining them.
const PartForce = struct { bits: compile.Bits, range: PcRange };

/// Is `scope` a top-level module's instance? The first is scope 0; every
/// other is its own parent.
pub fn isRoot(r: *const Run, scope: u32) bool {
    std.debug.assert(scope < r.hier.scopes.items.len);
    std.debug.assert(r.hier.scopes.items[scope].parent < r.hier.scopes.items.len);
    return scope == 0 or r.hier.scopes.items[scope].parent == scope;
}
