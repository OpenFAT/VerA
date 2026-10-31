//! The scheduler drained in, the events of a `Run` dispatched in §11 order out: `runUntil`, the one loop that hands each payload to `exec`, and the upward name search it uses.
//! Cites: IEEE 1364-2005 §11, §11.4; VAMS §8.5.1.
//!
//! Contents:
//! - `pub const EventBudget = struct`
//! - `pub fn runUntil(r: *Run, limit: Tick) Error!Stop`
//! - `pub fn upward(self: *const Run, name: Ast.StrId) ?u32`

const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const diag = @import("diag");
const Scheduler = @import("../scheduler.zig").Scheduler;
/// Scheduler ticks. `Time` below is the timescale module, not this.
const Tick = @import("../scheduler.zig").Time;
const max_events_per_tick = root.max_events_per_tick;
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
const Run = root.Run;
const Error = root.Error;
const Stop = root.Stop;
const isRoot = root.isRoot;

/// The descriptor table a `Run` with no `file_io` opens files through.
const own_files = system.own;

/// The zero-delay-loop guard of a run: the events dispatched at tick `time`,
/// against `max` (`Options.event_budget`).
pub const EventBudget = struct {
    /// Events dispatched at `budget_time`, against `budget`.
    time: Tick = 0,
    used: u64 = 0,
    max: u64 = max_events_per_tick,
};

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
        if (event.time != r.event_budget.time) {
            r.event_budget.time = event.time;
            r.event_budget.used = 0;
            // §8.5.1: monitor events "are continuously re-enabled in
            // every successive time step"; one that probes the analog
            // solution has no slot to wake it, so each step asks.
            if (r.monitoring.probes.len != 0) try waiters.requestMonitor(r);
        }
        r.event_budget.used += 1;
        if (r.event_budget.used > r.event_budget.max)
            return r.fail(0, "more than {d} events at time {d}: a zero-delay loop keeps simulation time from advancing", .{ r.event_budget.max, event.time });
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
                r.calls.ctx = 0;
                try exec.execute(r, &scratch, start);
            },
            .@"resume" => |x| {
                r.calls.ctx = x.ctx;
                try @import("activations.zig").makeResident(r, x.ctx);
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
                r.monitoring.pending = false;
                if (try display.monitorDue(r, scratch.allocator())) try display.monitorPrint(r, scratch.allocator());
                try display.fmonitorPrint(r, scratch.allocator());
            },
            .vcd_tick => try @import("vcd.zig").tick(r, scratch.allocator()),
            // `analogPoint`: only its time, at whose arrival above the
            // probing monitor was asked for.
            .analog_point => {},
            .tchk_expiry => |t| try tchk.expired(r, t.check, t.gen),
            .tchk_event => |t| try tchk.delivered(r, t.code, t.bit),
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
        if (self.prim_names.contains(.{ .scope = s, .str = name })) return null;
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
