//! A digital `Run` beside an analog solver: the slots an analog block reads (implicit D2A), the monitored analog events (`cross`, `above`, `timer`, `absdelta`), and the A2D events delivered back.
//! Cites: VAMS §5.10.3, §7.3.6, §8.4.3, §8.5.
//!
//! Contents:
//! - `pub const Link = struct`
//! - `pub fn watchAnalog(r: *Run, at: u32) void`
//! - `pub fn a2dWrite(r: *Run, at: u32, v: f64, assigned: bool) Error!void`
//! - `pub fn watchEvent(r: *Run, at: u32, edge: waiters.Edge, site: u6) Error!void`
//! - `pub fn registerMonitor(r: *Run, e: Ast.ExprId) Error!void`
//! - `pub fn addMonitor(r: *Run, e: Ast.ExprId, wakes: u32) Error!void`
//! - `pub fn monitorKind(r: *const Run, e: Ast.ExprId) MonitorKind`
//! - `pub fn analogTriggers(r: *Run, m: *const Ast.ModuleDecl, named: *const std.AutoHashMapUnmanaged(Ast.StrId, void)) Error!void`
//! - `W.expr(_: @This(), _: Ast.ExprId, _: Ast.SourceFile.Edge) Error!void {}`
//! - `W.stmt(w: @This(), s: Ast.StmtId) Error!void`
//! - `pub fn monitorSlot(r: *const Run, e: Ast.ExprId, scope: u32) ?u32`
//! - `pub fn monitorArg(r: *Run, m: usize, k: usize) Error!?f64`
//! - `pub fn deliverA2d(r: *Run, m: usize, tick: Tick) Error!void`
//! - `pub fn analogPoint(r: *Run, k: Tick) Error!bool`

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
// ---- the public surface -----------------------------------------------------
const root = @import("root.zig");
const Param = root.Param;
const Monitor = root.Monitor;
const D2aSite = root.D2aSite;
const Run = root.Run;
const Error = root.Error;
const MonitorKind = root.MonitorKind;
/// The descriptor table a `Run` with no `file_io` opens files through.
const own_files = system.own;

/// A digital run beside an analog solver (VAMS §7.3.6, §8): the monitored
/// analog events and probes, the D2A/A2D bookkeeping, and the host's
/// parameter card. Empty in a purely digital run.
pub const Link = struct {
    /// One region-3b event per tick however many analog-read values moved,
    /// the same coalescing `monitor_pending` does for region 4.
    pending: bool = false,
    /// §8.5 the explicit D2A terms, the ones that occurred this tick (bit =
    /// `D2aSite.site`), and the one region-1b event that reports them.
    d2a_sites: std.ArrayList(D2aSite) = .empty,
    d2a_fired: u64 = 0,
    d2a_pending: bool = false,
    /// VAMS §7.3.5 the analog events digital event controls wait on
    /// (`registerMonitor`). The mixed-signal kernel evaluates each against the
    /// analog solution and delivers its A2D events (`deliverA2d`).
    monitors: std.ArrayList(Monitor) = .empty,
    /// VAMS §7.3.3 / §7.3.6.3: the potential `V(a)` / `V(a, b)` of the analog
    /// solution at the current digital time. Set by the mixed-signal kernel;
    /// a digital process that probes without it fails.
    probe: ?*const fn (ctx: *anyopaque, a: []const u8, b: ?[]const u8) Error!f64 = null,
    probe_ctx: *anyopaque = undefined,
    /// Some digital expression probes the analog solution (`probe`).
    has_probes: bool = false,
    /// Elaborating the digital half of a mixed-signal module (`Options.mixed`).
    mixed: bool = false,
    /// `Mixed.reads`: the analog variables declared here for `a2dWrite`.
    a2d_reads: []const []const u8 = &.{},
    /// `Mixed.params`: the root's parameter values on the host's card.
    card: []const Param = &.{},
    /// `Mixed.real_params`: only the real parameters the discrete side needs.
    real_card: []const Param = &.{},
};

/// VAMS §8.5 / §8.4.3.2: the analog block reads `slot` outside any event
/// guard, so it is implicitly sensitive to it and every change is an
/// implicit D2A. From now on a change of it makes `runUntil` stop with
/// `.analog` at region 3b of the tick it happened in.
pub fn watchAnalog(r: *Run, at: u32) void {
    assert(at < r.waits.watch.len);
    r.waits.watch[at].insert(.analog);
}

/// VAMS §7.3.6.4: an analog variable a digital expression reads takes the
/// value the analog block left it, as a write at the current tick, so a
/// continuous assign over it re-evaluates like over any other operand.
/// Table 7-1 in reverse: a real "with no conversion", an integer as itself.
/// `assigned`: an analog event statement assigned it, which §7.3.6.1 makes
/// an event "regardless of whether the variable changes value or not".
pub fn a2dWrite(r: *Run, at: u32, v: f64, assigned: bool) Error!void {
    assert(at < r.values.len);
    assert(r.analog.mixed);
    const cur = r.values[at];
    const real = r.decls.reals.contains(at);
    const lit = if (real) try evaluate.realLiteral(r.arena, v) else blk: {
        const w = try filled(r.arena, 64, true, .zero);
        w.values()[0] = @bitCast(std.math.lossyCast(i64, v));
        break :blk try evaluate.normalize(r.arena, w, .{ .width = cur.width, .signed = cur.signed });
    };
    // `store`'s own test for a change, taken before it overwrites `cur`.
    const same = if (real) @as(f64, @bitCast(cur.planes[0])) == v else std.mem.eql(u64, cur.planes, lit.planes);
    assert(lit.planes.len == cur.planes.len);
    try waiters.store(r, at, lit.planes);
    if (assigned and same) try waiters.wake(r, at, .x, .x);
}

/// VAMS §7.3.4 / §8.5: an analog event control waits on `edge` of `slot`
/// (a variable, net or named event), as term `site` < 64. From now on the
/// event makes `runUntil` stop with `.explicit_d2a` at region 1b of its
/// tick, with bit `site` set in `d2a_fired`.
pub fn watchEvent(r: *Run, at: u32, edge: waiters.Edge, site: u6) Error!void {
    assert(at < r.waits.watch.len);
    const sites = r.analog.d2a_sites.items.len;
    defer assert(r.analog.d2a_sites.items.len <= sites + 1);
    r.waits.watch[at].insert(.d2a);
    try r.analog.d2a_sites.append(r.arena, .{ .slot = at, .edge = edge, .site = site });
}

/// VAMS §7.3.5: `cross`/`above`/`absdelta` as a term of a digital event control.
/// The process waits on a slot no variable owns (counted down from the
/// top of the slot space), which `deliverA2d` wakes.
pub fn registerMonitor(r: *Run, e: Ast.ExprId) Error!void {
    assert(e != .none);
    if (!r.analog.mixed or monitorKind(r, e) == .timer)
        return r.exprFail(e, "only cross(), above() and absdelta() are monitored in a digital event control");
    const scope = r.instanceOf(r.scope);
    if (r.monitorSlot(e, scope) != null) return;
    assert(r.analog.monitors.items.len < std.math.maxInt(u32) / 2); // Wake slots count down from the top.
    try r.addMonitor(e, std.math.maxInt(u32) - 1 - @as(u32, @intCast(r.analog.monitors.items.len)));
}

/// A monitor of analog event `e` whose occurrence wakes `slot`'s waiters.
pub fn addMonitor(r: *Run, e: Ast.ExprId, wakes: u32) Error!void {
    assert(e != .none);
    const args = r.file.exprs.args(e);
    if (args.len == 0 or args[0] == .none) return r.exprFail(e, "an analog event needs its expression");
    for (args) |arg| if (arg != .none) try compile.checkExpr(r, arg);
    try r.analog.monitors.append(r.arena, .{ .expr = e, .scope = r.instanceOf(r.scope), .slot = wakes, .kind = monitorKind(r, e) });
    assert(r.monitorSlot(e, r.instanceOf(r.scope)) != null);
}

/// Returns which monitored analog function event `e` calls.
pub fn monitorKind(r: *const Run, e: Ast.ExprId) MonitorKind {
    assert(e != .none);
    assert(r.file.exprs.tag(e) == .event_function);
    // The parser admits exactly A.6.5's four names as an event function.
    return std.meta.stringToEnum(MonitorKind, r.file.str(r.file.exprs.strOf(e))).?;
}

/// VAMS §5.10.4 / §7.3.6.1: `@(timer(..)) -> ev;` (or `cross`/`above`) in
/// the analog block, with `ev` named by a digital process. The statement
/// runs exactly when its analog event occurs, so that event, monitored,
/// IS the A2D: its delivery wakes `ev`'s digital waiters. Only a trigger
/// that is the event statement itself, or a top-level statement of its
/// block, is carried (lowering refuses the rest, E0437).
pub fn analogTriggers(r: *Run, m: *const Ast.ModuleDecl, named: *const std.AutoHashMapUnmanaged(Ast.StrId, void)) Error!void {
    const W = struct {
        r: *Run,
        named: *const std.AutoHashMapUnmanaged(Ast.StrId, void),
        /// Expressions hold no statement: nothing to find.
        pub fn expr(_: @This(), _: Ast.ExprId, _: Ast.SourceFile.Edge) Error!void {}
        /// Visits statement `s`.
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
                            if (w.r.decls.events.contains(at)) try w.r.addMonitor(c.event, at);
                        },
                        else => {}, // else: only a trigger crosses to the digital context
                    };
                },
                else => {}, // else: other statements are searched through their children
            }
            try f.stmtEdges(s, w);
        }
    };
    assert(r.analog.mixed);
    const monitors = r.analog.monitors.items.len;
    for (m.analog) |ab| try (W{ .r = r, .named = named }).stmt(ab.body);
    assert(r.analog.monitors.items.len >= monitors);
}

/// The slot whose waiters monitor `e` of instance `scope` wakes, or null
/// when that event is not monitored. O(monitors).
pub fn monitorSlot(r: *const Run, e: Ast.ExprId, scope: u32) ?u32 {
    assert(e != .none);
    assert(scope < r.hier.scopes.items.len);
    for (r.analog.monitors.items) |m| if (m.expr == e and m.scope == scope) return m.slot;
    return null;
}

/// Argument `k` of monitor `m`, evaluated as a real in the monitor's scope
/// (`k` = 0 is the monitored expression), or null when absent.
pub fn monitorArg(r: *Run, m: usize, k: usize) Error!?f64 {
    assert(m < r.analog.monitors.items.len);
    const mon = r.analog.monitors.items[m];
    assert(mon.scope < r.hier.scopes.items.len);
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
    assert(m < r.analog.monitors.items.len);
    assert(r.analog.mixed);
    const now = r.scheduler.now;
    _ = try exec.enqueue(r, .{ .a2d = r.analog.monitors.items[m].slot }, if (tick > now) tick - now else null, false);
}

/// VAMS §8.4, IEEE 1364-2005 §17.1.3: the mixed kernel accepted an analog
/// solution at tick `k`, which no digital event has reached. A standing
/// monitor's probes may read a new value there, and a probe has no slot
/// to wake it, so an event at `k` makes it a time step: `runUntil(k)`
/// brings digital time to `k` and re-checks the monitor in region 4.
/// False, with nothing queued, when no monitor probes or `k` has run.
pub fn analogPoint(r: *Run, k: Tick) Error!bool {
    if (r.monitoring.probes.len == 0 or !r.monitoring.on or k <= r.scheduler.now) return false;
    assert(k > r.scheduler.now);
    _ = try exec.enqueue(r, .analog_point, k - r.scheduler.now, false);
    assert(r.monitoring.on);
    return true;
}
