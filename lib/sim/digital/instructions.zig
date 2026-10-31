//! One instruction of a process whose work is not control flow in, its
//! effect on the `Run` out: a system task call (§17), a continuous driver's
//! new contribution (§6.1, §7), and the three steps of a procedural
//! continuous assignment (§9.3). `exec.run` dispatches here.
//! Cites: IEEE 1364-2005 §6.1.3, §7.6, §8.5, §9.3, §9.3.2, §10.4.5, §17.1.2,
//! §17.1.3, §17.3.2, §17.4.1, §26.6.41; A.2.2.3, A.6.1.
//!
//! Contents:
//! - `pub const Flow = enum`
//! - `pub fn task(self: *Run, scratch: std.mem.Allocator, s: @FieldType(Instruction, "task"), pc: u32) Error!Flow`
//! - `pub fn continuous(self: *Run, scratch: std.mem.Allocator, at: u32, pc: u32) Error!void`
//! - `pub fn overrideOn(self: *Run, o: @FieldType(Instruction, "override_on"), pc: u32) Error!void`
//! - `pub fn overrideEval(self: *Run, scratch: std.mem.Allocator, o: @FieldType(Instruction, "override_eval"), pc: u32) Error!void`
//! - `pub fn overrideOff(self: *Run, o: @FieldType(Instruction, "override_off"), pc: u32) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const compile = @import("compile.zig");
const deep = @import("base").deep_stack;
const display = @import("display.zig");
const Error = @import("root.zig").Error;
const Run = @import("root.zig").Run;
const expectRun = @import("root.zig").expectRun;
const Handle = @import("../scheduler.zig").Handle;
const filled = @import("net.zig").filled;
const setBit = @import("net.zig").setBit;
const wordMask = @import("net.zig").wordMask;
const Show = display.Show;
const Overrides = @import("root.zig").Overrides;
const Frame = @import("root.zig").Frame;
const PcRange = @import("root.zig").PcRange;
const Delay = @import("net.zig").Delay;
const Tran = @import("net.zig").Tran;
const system = @import("system.zig");
const vcd = @import("vcd.zig");
const evcd = @import("evcd.zig");
const driver = @import("driver.zig");
const evaluate = @import("evaluate.zig");
const resolution = @import("resolution.zig");
const waiters = @import("waiters.zig");
const Instruction = compile.Instruction;
const exec = @import("exec.zig");
const doneFlush = exec.doneFlush;
const enqueue = exec.enqueue;
const enqueueMonitor = exec.enqueueMonitor;
const stopRange = exec.stopRange;
const variableDelay = exec.variableDelay;

/// Whether the process goes on after an instruction.
pub const Flow = enum { next, ended };

/// A system task call (`.task`): its effect, and whether the process goes on
/// (`$finish` and `$stop` end it). A task in a constant function being folded
/// does nothing (§10.4.5).
pub fn task(self: *Run, scratch: std.mem.Allocator, s: @FieldType(Instruction, "task"), pc: u32) Error!Flow {
    assert(pc < self.code.items.len);
    // §10.4.5: a system task in a constant function is ignored
    // while the function folds a constant.
    if (self.growing != null or self.folding_constant) {
        return .next;
    }
    self.pc = pc;
    switch (s.task) {
        .show => |sh| try display.display(self, s.args, scratch, sh),
        // §17.1.2: the arguments are NOT captured, the call is.
        // What it reports is the value at the end of the timestep,
        // so evaluation waits for the `.monitor` region.
        .strobe => |sh| try enqueueMonitor(self, .{ .strobe = .{ .args = s.args, .show = sh, .scope = self.scope, .pc = pc } }),
        // §17.1.3 one standing monitor: a new one replaces the
        // old, watch list and all; §17.2.2 any number of
        // $fmonitors.
        .monitor => |sh| try display.install(self, scratch, s.args, sh, pc),
        // "$monitoron shall produce a display immediately after
        // it is invoked, regardless of whether a value change has
        // taken place", so whether it was already on is not asked.
        // Turning it off is silent.
        .monitor_enable => |on| {
            self.monitoring.on = on;
            if (on) try display.monitorPrint(self, scratch);
        },
        .timeformat => {
            if (s.args.len == 0) {
                self.time.format = .{ .units = self.time.finest };
            } else {
                const ex = &self.file.exprs;
                const units = try evaluate.eval(self, scratch, s.args[0], 0);
                const precision = try evaluate.eval(self, scratch, s.args[1], 0);
                const width = try evaluate.eval(self, scratch, s.args[3], 0);
                self.time.format = .{
                    .units = std.math.lossyCast(i32, units.asInt() orelse 0),
                    .precision = std.math.lossyCast(u32, precision.asInt() orelse 0),
                    .suffix = self.file.str(ex.strOf(s.args[2])),
                    .width = std.math.lossyCast(u32, width.asInt() orelse 0),
                };
            }
            // §26.6.41 follows execution, including a no-argument
            // reset. A task's lexical frame is in this instance.
            self.time.active_format = .{ .scope = self.instanceOf(self.scope), .tok = s.tok };
        },
        .readmem => |radix| try display.readMemory(self, scratch, s.args, radix),
        .queue => |op| try system.queueTask(self, scratch, op, s.args),
        .pla => |p| try system.pla(self, scratch, p, s.args),
        .fclose => try system.fclose(self, scratch, s.args),
        .fflush => {},
        .user => try self.host.systf.?.call(self, self.instanceOf(self.scope), s.tok, null),
        .fshow => |sh| try system.fdisplay(self, scratch, s.args, sh),
        .sshow => |sh| try system.sformat(self, scratch, s.args, sh),
        .sformat => try system.sformat(self, scratch, s.args, null),
        .printtimescale => try display.printTimescale(self, s.args),
        .sdf_annotate => try @import("sdf.zig").annotate(self, scratch, s.args, s.tok),
        .dump => |op| try vcd.task(self, scratch, op, s.args, s.tok),
        .ports => |op| try evcd.task(self, scratch, op, s.args, s.tok),
        .finish => |stop| {
            // An x/z level has no verbosity to select; the fullest
            // report is the reading that loses nothing.
            const verbose = s.args.len == 0 or ((try evaluate.eval(self, scratch, s.args[0], 0)).asInt() orelse 1) != 0;
            if (verbose) {
                const start_byte = self.starts[s.tok];
                const loc = self.bag.locate(.{ .start = start_byte, .end = start_byte }, null);
                const fmt_s = "{s} at tick {d}, {s} byte {d}\n";
                const args = .{ if (stop) "$stop" else "$finish", self.scheduler.now, self.bag.fileName(loc.file), loc.offset };
                if (stop) std.debug.print(fmt_s, args) else try self.out.print(fmt_s, args);
            }
            // iverilog's reading of §17.4.1's "exit": the rest of
            // this time step (other processes, NBA updates, the
            // monitor, the dump) runs, no later one does; this
            // process ends here (monitor4, pr243).
            self.scheduler.finishStep();
            return .ended;
        },
    }
    return .next;
}

/// A continuous driver's turn (`.continuous`): its value now, contributed to
/// its net at once or after its delay, and the driver armed again. The
/// process always ends here.
pub fn continuous(self: *Run, scratch: std.mem.Allocator, at: u32, pc: u32) Error!void {
    assert(at < self.drivers.len);
    assert(pc < self.armed.len);
    const d = &self.drivers[at];
    // A driver's names resolve in the scope that wrote the
    // assignment, which for a port connection is the parent of
    // the net it feeds, not the dispatch's scope.
    self.scope = d.scope;
    // A.2.2.3: a delay that reads a variable is read when the
    // driver schedules (§6.1.3).
    const timing = if (self.driver_delays.get(at)) |d3| try variableDelay(self, scratch, d3, d.tok) else d.delay;
    var or_z = false;
    const value = switch (d.source) {
        .bridge => |b| try resolution.window(self, scratch, b, d.current.width),
        .gate => |g| try resolution.gateValue(self, scratch, g, d.current.width, &or_z),
        .udp => |u| try resolution.udpValue(self, scratch, u, d.current.width),
        .mos => |mo| try resolution.mosValue(self, scratch, at, mo, &or_z),
        .pull => |b| try filled(scratch, d.current.width, false, b),
        .expr => |x| blk: {
            if (x.slice) |sl| {
                const whole = try evaluate.eval(self, scratch, x.e, sl.total);
                const part = try filled(scratch, d.current.width, false, .z);
                evaluate.copyBits(part, 0, whole, sl.lo, d.current.width);
                break :blk part;
            }
            break :blk try evaluate.evalFor(self, scratch, x.e, self.slotType(self.nets[d.net].slot));
        },
    };
    // A.6.1's `[ delay3 ]` delays what this driver contributes,
    // not what the net shows: the other drivers are unaffected
    // and the net re-resolves when the delayed value lands.
    // §8.5: a UDP's initial output is published at time 0; only
    // later transitions wait for the instance delay.
    const first_udp = if (d.source == .udp) d.source.udp.sequential and !d.source.udp.started else false;
    // A combinational one's output is x until its first delayed value.
    if (d.source == .udp and !d.source.udp.started and !first_udp and timing.present) try resolution.resolve(self, d.net);
    if (d.source == .udp) d.source.udp.started = true;
    if (timing.present and !first_udp) {
        const st = try self.driverTransition(at);
        if (try resolution.schedule(self, d.current, d.or_z, value, or_z, st)) {
            const delay = switch (d.source) {
                .expr => timing.continuous(d.current.truth(), st.target),
                .gate => |g| timing.to(st.target.bit(g.out_bit orelse 0)),
                .udp => |u| timing.to(st.target.bit(u.out_bit orelse 0)),
                .mos => |mo| timing.to(st.target.bit(mo.out_bit orelse 0)),
                .bridge, .pull => timing.to(st.target.bit(0)),
            };
            st.in_flight = try enqueue(self, .{ .drive = at }, delay, false);
        }
    } else {
        @memcpy(d.current.planes, value.planes);
        d.or_z = or_z;
        try resolution.resolve(self, d.net);
    }
    self.armed[pc] = true;
    return;
}

/// `.override_on`: the `assign` or `force` whose process is `[o.start,
/// o.end)` now holds its target, replacing the one before it (§9.3).
pub fn overrideOn(self: *Run, o: @FieldType(Instruction, "override_on"), pc: u32) Error!void {
    assert(o.start < o.end);
    const entry = try self.overrides.getOrPut(self.arena, o.slot);
    if (!entry.found_existing) entry.value_ptr.* = .{};
    if (o.bits) |bits| {
        const parts = &entry.value_ptr.parts;
        const range: PcRange = .{ .start = o.start, .end = o.end };
        for (parts.items) |*p| {
            if (!std.meta.eql(p.bits, bits)) continue;
            try doneFlush(self, p.range.start);
            _ = try stopRange(self, p.range.start, p.range.end);
            p.range = range;
            break;
        } else try parts.append(self.arena, .{ .bits = bits, .range = range });
        _ = try enqueue(self, .{ .run_process = o.start }, null, false);
        if (self.host.done_hook != null and self.host.done_sites.contains(pc)) try self.host.done_pending.put(self.arena, o.start, pc);
        return;
    }
    const layer = if (o.force) &entry.value_ptr.force else &entry.value_ptr.assign;
    if (layer.*) |old| {
        try doneFlush(self, old.start);
        _ = try stopRange(self, old.start, old.end);
    }
    layer.* = .{ .start = o.start, .end = o.end };
    _ = try enqueue(self, .{ .run_process = o.start }, null, false);
    // The host hears of it once the process has written the
    // target (`doneFlush`).
    if (self.host.done_hook != null and self.host.done_sites.contains(pc)) try self.host.done_pending.put(self.arena, o.start, pc);
    return;
}

/// `.override_eval`: the holding process writes its value, past the hold
/// it owns (`Run.overriding`).
pub fn overrideEval(self: *Run, scratch: std.mem.Allocator, o: @FieldType(Instruction, "override_eval"), pc: u32) Error!void {
    assert(!self.overriding);
    const layers = self.overrides.get(o.slot) orelse Overrides{};
    // An assign under a force keeps tracking but does not write.
    if (o.force or layers.force == null) {
        const w = if (o.bits) |b| b.width else self.values[o.slot].width;
        const value = if (o.slice) |sl|
            try evaluate.bitsOf(scratch, try evaluate.evalFor(self, scratch, o.value, .{ .width = sl.of, .signed = false }), sl.lo, w)
        else if (o.bits != null)
            try evaluate.evalFor(self, scratch, o.value, .{ .width = w, .signed = false })
        else
            try evaluate.evalFor(self, scratch, o.value, self.slotType(o.slot));
        self.overriding = true;
        defer self.overriding = false;
        if (o.bits) |b|
            try evaluate.write(self, scratch, .{ .slot = o.slot, .sel = .{ .first = b.lo, .count = b.width } }, value)
        else
            try waiters.store(self, o.slot, value.planes);
    }
    // A forced net drives the switch-connected nets joined to it
    // (`resolution.resolveJoined`), which follow its new value.
    if (o.force and o.bits == null) if (self.net_of.get(o.slot)) |net| if (self.netCold(self.nets[net]).trans.len != 0)
        try resolution.resolve(self, net);
    try doneFlush(self, pc);
    return;
}

/// `.override_off`: `deassign` or `release` of the target (§9.3).
pub fn overrideOff(self: *Run, o: @FieldType(Instruction, "override_off"), pc: u32) Error!void {
    assert(pc < self.code.items.len);
    // An override undone before its process ran was still executed.
    if (self.overrides.get(o.slot)) |layers| {
        if (o.bits) |bits| {
            for (layers.parts.items) |p| if (std.meta.eql(p.bits, bits)) try doneFlush(self, p.range.start);
        } else if (if (o.force) layers.force else layers.assign) |layer| try doneFlush(self, layer.start);
    }
    if (o.bits) |bits| try waiters.releaseBits(self, o.slot, bits) else try waiters.release(self, o.slot, o.force);
    if (self.host.done_hook) |h| if (self.host.done_sites.contains(pc)) try h(self, pc);
    return;
}
