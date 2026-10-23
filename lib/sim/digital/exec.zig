//! The digital interpreter's dispatch: a scheduled `Pending` row (a pc to
//! run, a write, a delayed drive) and the `Run` state -> the process run
//! until it suspends, stops or finishes, the events it queues and its
//! display output. Each instruction's work is in a sibling: `evaluate.zig`
//! (expressions), `waiters.zig` (the write path and what it wakes) and
//! `resolution.zig` (nets); this file owns the payload rows, the process
//! control and the subroutine activations.
//! Clauses: IEEE 1364-2005 §6.1/§6.1.3, §8.5.3.3/§8.5.3.4 intra-assignment
//! timing, §9.3, §9.5/§9.5.1, §9.6, §9.7.1, §9.7.5 to §9.7.7, §9.8.2,
//! §10.2.2, §10.2.3, §10.3, §10.4.2, §17.1.2, §17.1.3, §17.3.2, §17.4.1;
//! VAMS §7.3.6.1 A2D events.
const std = @import("std");
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
const driver = @import("driver.zig");
const evaluate = @import("evaluate.zig");
const resolution = @import("resolution.zig");
const waiters = @import("waiters.zig");

// ---- scheduler rows (§6.1.3, §17.1.2, §17.1.3) -------------------------------

/// One scheduled event's payload, consumed whole by its dispatch. A `.write`
/// value lives in its row's own planes (`Row`), never in variable storage.
pub const Pending = union(enum) {
    /// Run the process continuing at this pc, outside any §10.2.3 activation.
    run_process: u32,
    /// A resumption inside a §10.2.3 task activation (`Run.acts`): `pc`
    /// runs with activation `ctx`'s storage resident.
    @"resume": struct { pc: u32, ctx: u32 },
    /// §9.2.2 a nonblocking update landing: `value` into slot `target`, or
    /// into its `sel` bits only (merged with the slot as it is then).
    write: struct { target: u32, value: Int.Literal, sel: ?evaluate.Sel = null },
    /// §17.1.2 one $strobe call, evaluated when the `.monitor` region runs,
    /// not when the call executed, so it reports the settled value.
    strobe: struct { args: []const Ast.ExprId, show: Show, scope: u32, pc: u32 },
    /// §17.1.3 "something changed this timestep, ask the standing monitor".
    /// One per timestep, coalesced by `monitor_pending`.
    monitor_tick,
    /// §18.1.4 "the value change dumper records the values of the variables
    /// that change during each time increment": one per timestep, coalesced
    /// by `Vcd.pending`.
    vcd_tick,
    /// §7.6 a delayed pass switch reaching its `target` state now.
    tran_switch: u32,
    /// A.6.1's `[ delay3 ]` on a continuous assignment: this driver's
    /// `transition.target` arrives now. §6.1.3's inertial cancel is the
    /// scheduler's (`Inertial`).
    drive: u32,
    /// A.2.1.3's `[ delay3 ]` on the net declaration: the same delay one level
    /// down, on the resolved value rather than on one driver's.
    net_update: u32,
    /// A.2.1.3's third `delay3` value on a `trireg`: its held charge decays
    /// now (§3.8).
    decay: u32,
    /// VAMS §7.3.6.1 an A2D event: wake the processes waiting on this
    /// monitor slot (`Run.deliverA2d`).
    a2d: u32,
    /// VAMS §8.4 an analog solution at a tick no digital event reached
    /// (`Run.analogPoint`): it brings digital time there and does nothing
    /// else, so a monitor that probes the solution is re-checked.
    analog_point,
    /// IEEE 1364-2005 §15.3.2 a timer-based skew check's limit elapsed
    /// (`tchk.expired`), unless its `Tchk.gen` moved on since; or a
    /// §15.3.6 $nochange data event judged after the active events.
    tchk_expiry: struct { check: u32, gen: u32 },
};

/// One payload row. Rows are recycled: a row is live exactly while the
/// scheduler holds its `handle` pending, and goes back on `Run.free_rows` when
/// it dispatches or is cancelled, so the table is as large as the most events
/// ever queued at once, not as the run is long. `buf` is the row's own
/// storage for a `.write` value, kept across reuse and grown only when a wider
/// value arrives.
pub const Row = struct {
    item: Pending,
    handle: Handle = undefined,
    buf: []u64 = &.{},

    // Budget: one row per event queued at once (recycled). `Pending.write`
    // is the widest payload: a slot, a value and an optional select.
    comptime {
        std.debug.assert(@sizeOf(Row) <= 88);
    }
};

/// The per-instruction scratch `run` resets before every instruction: a
/// fixed buffer first, whose reset is one store, and an arena for the rare
/// instruction whose temporaries outgrow it (a very wide vector, a long
/// concatenation), reset only after such an instruction. `ArenaAllocator.reset`
/// walks its node lists and cost more than most instructions' own work
/// (7.8% of a counter benchmark). With an empty buffer (a nested `callSync`
/// body) every allocation is the arena's.
pub const Scratch = struct {
    fixed: std.heap.FixedBufferAllocator,
    arena: *std.heap.ArenaAllocator,
    spilled: bool = false,

    pub fn init(buffer: []u8, arena: *std.heap.ArenaAllocator) Scratch {
        return .{ .fixed = .init(buffer), .arena = arena };
    }

    pub fn allocator(self: *Scratch) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    /// Frees everything allocated since the last reset.
    pub fn reset(self: *Scratch) void {
        self.fixed.reset();
        if (self.spilled) {
            _ = self.arena.reset(.retain_capacity);
            self.spilled = false;
        }
    }

    fn alloc(ctx: *anyopaque, n: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Scratch = @ptrCast(@alignCast(ctx));
        if (std.heap.FixedBufferAllocator.alloc(&self.fixed, n, a, ra)) |p| return p;
        self.spilled = true;
        return self.arena.allocator().rawAlloc(n, a, ra);
    }

    fn resize(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Scratch = @ptrCast(@alignCast(ctx));
        if (self.fixed.ownsPtr(buf.ptr)) return std.heap.FixedBufferAllocator.resize(&self.fixed, buf, a, new_len, ra);
        return self.arena.allocator().rawResize(buf, a, new_len, ra);
    }

    fn remap(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Scratch = @ptrCast(@alignCast(ctx));
        if (self.fixed.ownsPtr(buf.ptr)) return std.heap.FixedBufferAllocator.remap(&self.fixed, buf, a, new_len, ra);
        return self.arena.allocator().rawRemap(buf, a, new_len, ra);
    }

    fn free(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Scratch = @ptrCast(@alignCast(ctx));
        if (self.fixed.ownsPtr(buf.ptr)) return std.heap.FixedBufferAllocator.free(&self.fixed, buf, a, ra);
        self.arena.allocator().rawFree(buf, a, ra);
    }
};

/// `Run.scratch_buf`'s size: the fixed half of `runUntil`'s `Scratch`.
pub const scratch_fixed_bytes: usize = 64 << 10;

test "Scratch: the fixed buffer serves until it is full, the arena after, and reset frees both" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var buf: [64]u8 = undefined;
    var sc: Scratch = .init(&buf, &arena);
    const a = sc.allocator();
    const small = try a.alloc(u8, 48);
    try std.testing.expect(sc.fixed.ownsSlice(small) and !sc.spilled);
    const big = try a.alloc(u8, 48);
    try std.testing.expect(!sc.fixed.ownsSlice(big) and sc.spilled);
    try std.testing.expect(a.resize(big, 40));
    a.free(big);
    sc.reset();
    try std.testing.expect(!sc.spilled and sc.fixed.end_index == 0);
    try std.testing.expectEqual(@as(usize, 0), arena.queryCapacity() - arena.queryCapacity());
    var none: Scratch = .init(&.{}, &arena);
    _ = try none.allocator().alloc(u8, 1);
    try std.testing.expect(none.spilled);
}

// The VPI (src/vpi/value.zig) writes and triggers through `digital.exec`,
// as a process does; these are the entry points it reaches.

/// `evaluate.address`: the element an lvalue names right now.
pub const address = evaluate.address;
/// `waiters.store`: the one write path, which wakes what watches the slot.
pub const store = waiters.store;
/// `waiters.trigger`: §5.10.4 `-> e`.
pub const trigger = waiters.trigger;
/// `waiters.release`: §9.3 `deassign` or `release`.
pub const release = waiters.release;
/// `waiters.forceValue`: a VPI force of a constant.
pub const forceValue = waiters.forceValue;

/// Cancel one queued event and give its row back.
pub fn cancel(self: *Run, h: Handle) Error!void {
    const row = self.scheduler.payloadOf(h) orelse return;
    _ = self.scheduler.cancel(h) catch |e|
        return if (e == error.OutOfMemory) error.OutOfMemory else self.fail(0, "digital scheduling failure: {t}", .{e});
    try self.free_rows.append(self.arena, row);
}

// ---- process control and scheduling (§9.7.1, §17.1.3, 1364 §10.3) -----------

/// The run-time counterpart of `checkDelay`, in the module's precision.
fn delayOf(self: *Run, scratch: std.mem.Allocator, e: Ast.ExprId, tok: u32) Error!u64 {
    if (compile.typeOf(self, e).real) {
        return self.timeOf(self.scope).scale.realDelay(try evaluate.evalReal(self, scratch, e)) catch |err|
            return self.fail(tok, "digital delay cannot be represented: {t}", .{err});
    }
    const value = try evaluate.eval(self, scratch, e, 0);
    // §9.7.1 leaves an x/z delay undefined; zero is the reading that keeps
    // the process running rather than losing it.
    if (value.hasUnknown()) return 0;
    if (value.width > 64) return self.exprFail(e, "delay values wider than 64 bits are not implemented");
    const scale = self.timeOf(self.scope).scale;
    return (if (value.signed) scale.signedDelay(value.asInt().?) else scale.unsignedDelay(value.values()[0])) catch |err|
        return self.fail(tok, "digital delay cannot be represented: {t}", .{err});
}

/// A driver's `delay3` that reads a variable (`Run.driver_delays`), its
/// values now, defaulted as `Run.declaredDelay3` defaults a constant one.
fn variableDelay(self: *Run, scratch: std.mem.Allocator, d: Ast.Delay3, tok: u32) Error!@import("net.zig").Delay {
    var out: @import("net.zig").Delay = .{ .present = true };
    out.rise = try delayOf(self, scratch, d.rise, tok);
    out.fall = if (d.fall != .none) try delayOf(self, scratch, d.fall, tok) else out.rise;
    out.off = if (d.off != .none) try delayOf(self, scratch, d.off, tok) else @min(out.rise, out.fall);
    return out;
}

fn suspendOn(self: *Run, e: Ast.ExprId, id: u32) Error!void {
    const ex = &self.file.exprs;
    const edge: waiters.Edge = switch (ex.tag(e)) {
        .event_or => {
            try suspendOn(self, ex.lhs(e), id);
            return suspendOn(self, ex.rhs(e), id);
        },
        .event_posedge => .posedge,
        .event_negedge => .negedge,
        .event_function => {
            const slot = self.monitorSlot(e, self.instanceOf(self.scope)).?; // registered by checkEvent
            return waiters.watch(self, id, slot, .any);
        },
        // VAMS §9.22.5: woken by `driver.stored`/`driver.scheduled`.
        .event_driver_update => return waiters.watch(self, id, driver.key(try self.slot(ex.lhs(e))), .any),
        else => .any, // else: a name, or an expression checkEvent gave a slot
    };
    const watched = if (edge == .any) e else ex.lhs(e);
    if (ex.tag(watched) == .index) {
        const base = try self.slot(self.chainBase(watched).base);
        if (self.events.contains(base)) {
            const arr = self.arrays.get(base).?;
            for (0..arr.count) |k| {
                const slot = base + @as(u32, @intCast(k));
                try waiters.watch(self, id, slot, .any);
                const term = &waiters.termsOf(self, slot).?.items[waiters.termsOf(self, slot).?.items.len - 1];
                term.event_select = watched;
                term.scope = self.scope;
            }
            return;
        }
    }
    if (try compile.selectTerm(self, watched)) |sel| {
        try waiters.watch(self, id, sel.slot, edge);
        const list = waiters.termsOf(self, sel.slot).?;
        const term = &list.items[list.items.len - 1];
        const now = waiters.termBits(self.values[sel.slot], sel.first, sel.count);
        term.* = .{ .susp = term.susp, .gen = term.gen, .edge = edge, .lo = sel.first, .width = sel.count, .v = now[0], .x = now[1] };
        return;
    }
    try waiters.watch(self, id, try self.termSlot(watched), edge);
}

/// Queues `item` in the `.monitor` region of the current time, §17.1.2 and
/// §17.1.3's "end of the timestep", which the scheduler orders after active,
/// inactive and NBA.
pub fn enqueueMonitor(self: *Run, item: Pending) Error!void {
    const at = try claim(self, item);
    self.pending.items[at].handle = self.scheduler.schedule(.monitor, at) catch |e|
        return if (e == error.OutOfMemory) error.OutOfMemory else self.fail(0, "digital scheduling failure: {t}", .{e});
}

/// A row for `item`: a recycled one when there is one. A `.write` value is
/// copied into the row's own planes, so the caller's may be scratch.
fn claim(self: *Run, item: Pending) Error!u32 {
    const at: u32 = self.free_rows.pop() orelse blk: {
        if (self.pending.items.len == std.math.maxInt(u32)) return self.fail(0, "too many digital events", .{});
        try self.pending.append(self.arena, .{ .item = item });
        break :blk @intCast(self.pending.items.len - 1);
    };
    const row = &self.pending.items[at];
    row.item = item;
    switch (item) {
        .write => |w| {
            if (row.buf.len < w.value.planes.len) row.buf = try self.arena.alloc(u64, w.value.planes.len);
            const planes = row.buf[0..w.value.planes.len];
            @memcpy(planes, w.value.planes);
            row.item.write.value.planes = planes;
        },
        .run_process, .@"resume", .strobe, .monitor_tick, .vcd_tick, .tran_switch, .drive, .net_update, .decay, .a2d, .analog_point, .tchk_expiry => {},
    }
    return at;
}

/// IEEE 1364-2005 §10.3 `disable`: it "terminates the activity" of a named
/// block, and "execution continues with the statement following the block".
/// Drops every resumption into [start, end) (`stopRange`) and, only if one
/// was dropped, resumes at `end` once and returns true: a block nobody is
/// suspended in has no activity, and resuming there would run the tail of a
/// body twice. A process disabling a block it runs inside stops on true, so
/// the statement after the block runs once, not once per process; on false
/// its own jump past the block is its dispatch arm's.
fn disable(self: *Run, start: u32, end: u32) Error!bool {
    // ponytail: an NBA already scheduled from inside the block still lands; it
    // is a write the block completed before it was disabled.
    if (!try stopRange(self, start, end)) return false;
    _ = try enqueue(self, .{ .run_process = end }, null, false);
    return true;
}

/// Drop every resumption point in [start, end): the waiters parked there and
/// the queued `.run_process` rows. Whether anything was.
pub fn stopRange(self: *Run, start: u32, end: u32) Error!bool {
    var hit = false;
    for (self.susps.items, 0..) |s, id| if (s.alive and s.pc >= start and s.pc < end) {
        waiters.retire(self, @intCast(id));
        hit = true;
    };
    // Only live rows: a free row's handle is stale, and so is the handle of
    // the row now dispatching, which the scheduler released before returning.
    for (self.pending.items) |row| switch (row.item) {
        .run_process => |at| if (at >= start and at < end and self.scheduler.payloadOf(row.handle) != null) {
            try cancel(self, row.handle);
            hit = true;
        },
        .@"resume" => |x| if (x.pc >= start and x.pc < end and self.scheduler.payloadOf(row.handle) != null) {
            try cancel(self, row.handle);
            hit = true;
        },
        .write, .strobe, .monitor_tick, .vcd_tick, .tran_switch, .drive, .net_update, .decay, .a2d, .analog_point, .tchk_expiry => {},
    };
    return hit;
}

/// Where a process continues at `pc`: in the activation `ctx`, if any.
pub fn resumption(pc: u32, ctx: u32) Pending {
    return if (ctx == 0) .{ .run_process = pc } else .{ .@"resume" = .{ .pc = pc, .ctx = ctx } };
}

/// Queues `item` now (active, or NBA when `nba`) or `delay` ticks later
/// (inactive, or NBA), and returns its handle.
pub fn enqueue(self: *Run, item: Pending, delay: ?u64, nba: bool) Error!Handle {
    const at = try claim(self, item);
    const h = (if (delay) |d|
        self.scheduler.scheduleAfter(d, if (nba) .nba else .inactive, at) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else self.fail(0, "digital timing failure: {t}", .{e})
    else
        self.scheduler.schedule(if (nba) .nba else .active, at) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else self.fail(0, "digital scheduling failure: {t}", .{e}));
    self.pending.items[at].handle = h;
    if (item == .write) try driver.scheduled(self, item.write.target);
    return h;
}

fn caseMatches(kind: Ast.CaseKind, value: Int.Literal, label: Int.Literal) bool {
    std.debug.assert(value.width == label.width);
    if (kind == .normal) return value.equality(.case_equal, label) == .one;
    // IEEE1364-2005 §9.5.1: wildcards apply symmetrically to either value.
    // Per plane word: z is (value 0, unknown 1), x is (1, 1).
    // Per declared word: a parsed unsized literal's planes may be longer.
    for (0..(value.width + 63) / 64) |w| {
        const av = value.values()[w];
        const au = value.unknowns()[w];
        const bv = label.values()[w];
        const bu = label.unknowns()[w];
        const wild = if (kind == .casex) au | bu else (au & ~av) | (bu & ~bv);
        if (((av ^ bv) | (au ^ bu)) & ~wild & wordMask(value.width, w) != 0) return false;
    }
    return true;
}

// ---- synchronous subroutines (IEEE 1364-2005 §10) ----------------------------

/// Runs subroutine `idx` to completion as one activation (§10.2.2, §10.4) and
/// returns a function's result, in `a`. The arguments are evaluated in the
/// caller before anything of the callee's changes (a recursive call's argument
/// reads the calling activation), copied into the formals, the body runs on a
/// scratch arena of its own, and the outputs are copied back. An automatic
/// subroutine's frame is saved, set to x, and restored after (§10.2.3, §10.4.2).
/// Nests as deep as the stack `deep.runGuarded` reserved (`deep.exhausted`). After
/// a §10.3 `disable` of the subroutine, outputs are not copied back.
pub fn callSync(self: *Run, a: std.mem.Allocator, idx: u32, args: []const Ast.ExprId) Error!Int.Literal {
    // ponytail: `repeat` counters are per site, so a recursive body that loops
    // with `repeat` across its own recursion shares one.
    // §10.4.5: a constant function call folded before pass two compiles the
    // bodies (a generate condition calling a function already framed).
    if (!self.subs.items[idx].compiled) {
        const saved = self.scope;
        defer self.scope = saved;
        try compile.compileSub(self, idx);
    }
    const sub = &self.subs.items[idx];
    const decl = sub.decl;
    const f = sub.frame;
    // An activation's frames are large: the bound is the stack itself.
    if (deep.exhausted()) return self.deepFail(decl.main_tok);
    const inputs = try a.alloc(?Int.Literal, args.len);
    for (decl.ports, args, inputs, f.ports) |p, arg, *in, slot| {
        in.* = null;
        if (p.direction == .output) continue;
        // A copy: an actual that is the callee's own formal (`f(n)` inside
        // `f`) is that frame's storage, which the automatic reset below
        // overwrites.
        in.* = try copyLiteral(a, try evaluate.evalFor(self, a, arg, self.slotType(slot)));
    }
    const saved_len = self.saved_planes.items.len;
    // §10.4.5: a call elaboration folds "has no effect on the initial values
    // of the variables used either at simulation time or among multiple
    // invocations of a function at elaboration time", so it runs as an
    // automatic one does.
    const fresh = decl.automatic or self.growing != null or self.folding_constant;
    if (fresh) for (f.first..f.first + f.count) |s| {
        const v = self.values[s];
        try self.saved_planes.appendSlice(self.arena, v.planes);
        const fill: Int.Bit = if (self.reals.contains(@intCast(s))) .zero else .x;
        @memcpy(v.planes, (try filled(a, v.width, v.signed, fill)).planes);
    };
    for (inputs, f.ports) |in, slot| if (in) |v| @memcpy(self.values[slot].planes, v.planes);
    const caller_scope = self.scope;
    const caller_pc = self.pc;
    sub.active += 1;
    {
        var body = std.heap.ArenaAllocator.init(self.arena);
        defer body.deinit();
        var body_scratch: Scratch = .init(&.{}, &body);
        try execute(self, &body_scratch, sub.entry);
    }
    sub.active -= 1;
    self.scope = caller_scope;
    self.pc = caller_pc;
    const result = if (decl.is_function) try copyLiteral(a, self.values[f.result]) else try filled(a, 1, false, .x);
    // §10.2.2, §10.2.3: capture the callee's outputs before restoring the
    // caller's automatic frame. A recursive actual may name a local in
    // that frame, including a select whose index belongs to the caller.
    // Reuse the input copies, which are no longer needed after the body.
    // §10.3: a disabled task's outputs are not copied back.
    for (decl.ports, inputs, f.ports) |p, *out, slot|
        out.* = if (p.direction != .input and self.unwind == null) try copyLiteral(a, self.values[slot]) else null;
    if (fresh) {
        var at = saved_len;
        for (f.first..f.first + f.count) |s| {
            const planes = self.values[s].planes;
            @memcpy(planes, self.saved_planes.items[at..][0..planes.len]);
            at += planes.len;
        }
        self.saved_planes.shrinkRetainingCapacity(saved_len);
    }
    for (args, inputs, f.ports) |arg, out, slot| if (out) |v|
        try evaluate.put(self, a, arg, try evaluate.convertValue(a, v, self.reals.contains(slot), try evaluate.targetType(self, arg)), false, null);
    if (self.unwind == idx and sub.active == 0) self.unwind = null;
    return result;
}

// ---- activations of a recursive timed task (IEEE 1364-2005 §10.2.3) ---------

/// One activation of a task that suspends and reaches itself: where its
/// caller resumes, the actuals its outputs copy back to, and its own storage,
/// saved while another activation of the same automatic task is resident.
pub const Act = struct { sub: u32, ret_pc: u32, ret_ctx: u32, args: []const Ast.ExprId, storage: []u64 = &.{} };

/// §10.2.2 enable task `idx` as a new activation: the inputs are evaluated in
/// the caller, an automatic task's frame is set aside for a fresh one
/// ("initialized to the default initialization value whenever execution
/// enters their scope"), and the body runs in this process from `Sub.body`.
/// Returns the pc to continue at.
fn callTimed(self: *Run, a: std.mem.Allocator, idx: u32, args: []const Ast.ExprId, pc: u32) Error!u32 {
    const sub = &self.subs.items[idx];
    const f = sub.body.?.frame;
    const inputs = try a.alloc(?Int.Literal, args.len);
    for (sub.decl.ports, args, inputs, f.ports) |p, arg, *in, slot|
        in.* = if (p.direction == .output) null else try copyLiteral(a, try evaluate.evalFor(self, a, arg, self.slotType(slot)));
    if (self.acts.items.len == 0) try self.acts.append(self.arena, undefined); // 0 is "no activation"
    const act: Act = .{ .sub = idx, .ret_pc = pc + 1, .ret_ctx = self.ctx, .args = args };
    const id: u32 = if (self.free_acts.pop()) |k| blk: {
        self.acts.items[k] = act;
        break :blk k;
    } else blk: {
        try self.acts.append(self.arena, act);
        break :blk @intCast(self.acts.items.len - 1);
    };
    if (sub.decl.automatic) {
        try evict(self, idx);
        for (f.first..f.first + f.count) |s| {
            const v = self.values[s];
            // `filled` keeps the bits past the width 0, as every slot's are;
            // a whole-word memset left them set.
            const fill: Int.Bit = if (self.reals.contains(@intCast(s))) .zero else .x;
            @memcpy(v.planes, (try filled(a, v.width, v.signed, fill)).planes);
        }
        sub.resident = id;
    }
    for (inputs, f.ports) |in, slot| if (in) |v| @memcpy(self.values[slot].planes, v.planes);
    self.ctx = id;
    return sub.body.?.entry;
}

/// The end of an activation's body: its outputs are read while its storage
/// is still resident, the caller's activation (if any) becomes resident, and
/// the outputs are copied to the caller's actuals in the caller's scope.
fn returnTimed(self: *Run, a: std.mem.Allocator, idx: u32) Error!u32 {
    const sub = &self.subs.items[idx];
    const f = sub.body.?.frame;
    const done = self.ctx;
    const act = self.acts.items[done];
    const outs = try a.alloc(Int.Literal, f.ports.len);
    for (f.ports, outs) |slot, *o| o.* = try copyLiteral(a, self.values[slot]);
    if (sub.resident == done) sub.resident = 0; // dead: nothing to save
    try self.free_acts.append(self.arena, done);
    self.ctx = act.ret_ctx;
    try makeResident(self, self.ctx);
    self.scope = self.code_scope.items[act.ret_pc - 1];
    for (sub.decl.ports, act.args, f.ports, outs) |p, arg, slot, v| if (p.direction != .input)
        try evaluate.put(self, a, arg, try evaluate.convertValue(a, v, self.reals.contains(slot), try evaluate.targetType(self, arg)), false, null);
    return act.ret_pc;
}

/// Save the resident activation of automatic task `idx`, freeing its frame.
fn evict(self: *Run, idx: u32) Error!void {
    const sub = &self.subs.items[idx];
    if (sub.resident == 0) return;
    const f = sub.body.?.frame;
    const act = &self.acts.items[sub.resident];
    var len: usize = 0;
    for (f.first..f.first + f.count) |s| len += self.values[s].planes.len;
    if (act.storage.len != len) act.storage = try self.arena.alloc(u64, len);
    var at: usize = 0;
    for (f.first..f.first + f.count) |s| {
        const planes = self.values[s].planes;
        @memcpy(act.storage[at..][0..planes.len], planes);
        at += planes.len;
    }
    sub.resident = 0;
}

/// Put activation `ctx`'s storage in its task's frame, if it is not there.
pub fn makeResident(self: *Run, ctx: u32) Error!void {
    if (ctx == 0) return;
    const act = self.acts.items[ctx];
    const sub = &self.subs.items[act.sub];
    if (!sub.decl.automatic or sub.resident == ctx) return;
    try evict(self, act.sub);
    const f = sub.body.?.frame;
    var at: usize = 0;
    for (f.first..f.first + f.count) |s| {
        const planes = self.values[s].planes;
        @memcpy(planes, act.storage[at..][0..planes.len]);
        at += planes.len;
    }
    sub.resident = ctx;
}

fn copyLiteral(a: std.mem.Allocator, v: Int.Literal) Error!Int.Literal {
    const out = try filled(a, v.width, v.signed, .zero);
    @memcpy(out.planes, v.planes);
    return out;
}

// ---- the interpreter loop (A.6.5, §6.1, §8.5.3.3) ---------------------------

/// Runs the process at `start` until it suspends, stops or finishes;
/// `scratch` is reset before each instruction.
pub fn execute(self: *Run, scratch: *Scratch, start: u32) Error!void {
    // A VPI calltf may register the first cbStmt while this process is
    // running. Recorded sites therefore keep dispatch available before a
    // hook exists; ordinary runs still use the branch without callbacks.
    return if (self.stmt_sites != null or self.stmt_hook != null) run(self, scratch, start, true) else run(self, scratch, start, false);
}

/// Reports the `assign`/`force` whose override process starts at `start` to
/// `Run.done_hook`, once: when the process first writes the target, or when
/// the override is undone or replaced before it ran.
fn doneFlush(self: *Run, start: u32) Error!void {
    const h = self.done_hook orelse return;
    if (self.done_pending.fetchRemove(start)) |kv| try h(self, kv.value);
}

/// One pass back to the top of a loop (a backward jump, a `repeat`'s next
/// iteration): an untimed loop never returns to the scheduler, so each pass
/// counts against the time step's event budget (`Run.budget`), and
/// `initial forever x = 1;` is refused by name instead of hanging at one
/// tick (specification/Vague_Decisions.md §7). `rt.State.loopIteration` is
/// the native executable's.
fn loopIteration(self: *Run) Error!void {
    self.budget_used += 1;
    if (self.budget_used > self.budget)
        return self.fail(0, "more than {d} loop iterations and events at time {d}: a loop with no delay keeps simulation time from advancing", .{ self.budget, self.scheduler.now });
}

/// `execute`, which with `hooked` calls `Run.stmt_hook` before each
/// instruction a statement starts at.
fn run(self: *Run, per_instruction: *Scratch, start: u32, comptime hooked: bool) Error!void {
    var pc = start;
    var restarted = false;
    while (true) {
        // §10.3: a disabled subroutine's synchronous activations return at
        // once, each back into its caller, until `callSync` ends the unwind.
        if (self.unwind != null) return;
        // §6.2.2 / §12.7: the names an instruction reads are those of the
        // scope it was compiled in: its instance's, or an inlined task's.
        self.scope = self.code_scope.items[pc];
        // ponytail: a `wait` whose level is false resumes at its own pc, so
        // each re-test is one more visit.
        if (hooked) if (self.stmt_hook) |h| if (pc < h.at.bit_length and h.at.isSet(pc)) try h.fire(self, pc);
        // Each instruction completes its copies/captures before scratch is
        // reused; an untimed loop therefore retains no iteration temporaries.
        per_instruction.reset();
        const scratch = per_instruction.allocator();
        switch (self.code.items[pc]) {
            .stop => return,
            .init_var => |s| {
                try waiters.store(self, s.slot, (try evaluate.evalFor(self, scratch, s.value, self.slotType(s.slot))).planes);
                pc += 1;
                continue;
            },
            .assign => |s| {
                // §3.9: an out-of-range or X/Z index names no element, so
                // the write is discarded rather than landing somewhere.
                try evaluate.put(self, scratch, s.target, try evaluate.evalFor(self, scratch, s.value, try evaluate.targetType(self, s.target)), s.nonblocking, null);
                pc += 1;
                continue;
            },
            .delay => |s| {
                _ = try enqueue(self, resumption(pc + 1, self.ctx), try delayOf(self, scratch, s.amount, s.tok), false);
                return;
            },
            .task => |s| {
                // §10.4.5: a system task in a constant function is ignored
                // while the function folds a constant.
                if (self.growing != null or self.folding_constant) {
                    pc += 1;
                    continue;
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
                        self.monitor_on = on;
                        if (on) try display.monitorPrint(self, scratch);
                    },
                    .timeformat => {
                        if (s.args.len == 0) {
                            self.time_format = .{ .units = self.finest };
                        } else {
                            const ex = &self.file.exprs;
                            const units = try evaluate.eval(self, scratch, s.args[0], 0);
                            const precision = try evaluate.eval(self, scratch, s.args[1], 0);
                            const width = try evaluate.eval(self, scratch, s.args[3], 0);
                            self.time_format = .{
                                .units = std.math.lossyCast(i32, units.asInt() orelse 0),
                                .precision = std.math.lossyCast(u32, precision.asInt() orelse 0),
                                .suffix = self.file.str(ex.strOf(s.args[2])),
                                .width = std.math.lossyCast(u32, width.asInt() orelse 0),
                            };
                        }
                        // §26.6.41 follows execution, including a no-argument
                        // reset. A task's lexical frame is in this instance.
                        self.active_timeformat = .{ .scope = self.instanceOf(self.scope), .tok = s.tok };
                    },
                    .readmem => |radix| try display.readMemory(self, scratch, s.args, radix),
                    .queue => |op| try @import("system.zig").queueTask(self, scratch, op, s.args),
                    .pla => |p| try @import("system.zig").pla(self, scratch, p, s.args),
                    .fclose => try @import("system.zig").fclose(self, scratch, s.args),
                    .fflush => {},
                    .user => try self.systf.?.call(self, self.instanceOf(self.scope), s.tok, null),
                    .fshow => |sh| try @import("system.zig").fdisplay(self, scratch, s.args, sh),
                    .sshow => |sh| try @import("system.zig").sformat(self, scratch, s.args, sh),
                    .sformat => try @import("system.zig").sformat(self, scratch, s.args, null),
                    .printtimescale => try display.printTimescale(self, s.args),
                    .dump => |op| try @import("vcd.zig").task(self, scratch, op, s.args, s.tok),
                    .ports => |op| try @import("evcd.zig").task(self, scratch, op, s.args, s.tok),
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
                        try @import("vcd.zig").finish(self, scratch);
                        self.scheduler.finish();
                        return;
                    },
                }
                pc += 1;
                continue;
            },
            .jump => |target| {
                if (target <= pc) try loopIteration(self);
                pc = target;
                continue;
            },
            .wait_event => |e| return suspendOn(self, e, try waiters.park(self, pc + 1)),
            // §9.7.5 the implicit list is a plain `or` of value changes.
            .wait_slots => |slots| {
                const id = try waiters.park(self, pc + 1);
                for (slots) |s| try waiters.watch(self, id, s, .any);
                return;
            },
            // A.6.5 a `wait` that is already satisfied does not suspend at
            // all; one that is not comes back to this pc, not the next, so
            // the level is re-tested rather than the edge trusted.
            .wait_level => |s| {
                if (try evaluate.truthOf(self, scratch, s.cond) == .one) {
                    pc += 1;
                    continue;
                }
                const id = try waiters.park(self, pc);
                for (s.slots) |at| try waiters.watch(self, id, at, .any);
                return;
            },
            // §8.5.3.3 "computes the right-hand side value using the
            // current values, then causes the executing process to be
            // suspended". Both halves of that sentence are here.
            .sample => |s| {
                const a = self.file.stmt(s.statement).assign;
                const tok = self.file.stmtTok(s.statement);
                // The parked value takes the target's type from the lvalue's
                // base slot, not `address`, which §8.5.3.3 resolves only on
                // resumption. It outlives this dispatch, so it lives in the
                // cell's own planes, sized once per site.
                const parked = try evaluate.evalFor(self, scratch, a.value, try evaluate.targetType(self, a.target));
                const cell = &self.holds.items[s.cell];
                if (cell.planes.len != parked.planes.len) cell.planes = try self.arena.alloc(u64, parked.planes.len);
                @memcpy(cell.planes, parked.planes);
                cell.width = parked.width;
                cell.signed = parked.signed;
                cell.sized = parked.sized;
                if (compile.parksOnly(a)) {
                    pc += 1;
                    continue;
                }
                if (a.nonblocking) {
                    // §8.5.3.4 the process does not suspend; the write is
                    // one more NBA update, delayed if the control was one.
                    try evaluate.put(self, scratch, a.target, self.holds.items[s.cell], true, if (a.timing_is_delay) try delayOf(self, scratch, a.timing, tok) else null);
                    pc += 1;
                    continue;
                }
                if (a.timing_is_delay)
                    _ = try enqueue(self, resumption(pc + 1, self.ctx), try delayOf(self, scratch, a.timing, tok), false)
                else
                    try suspendOn(self, a.timing, try waiters.park(self, pc + 1));
                return;
            },
            // §8.5.3.3 "the values at the time the process resumes are used
            // to determine the target(s)": the address is resolved now,
            // though the value was fixed before the suspension.
            .deposit => |s| {
                const a = self.file.stmt(s.statement).assign;
                // §3.9: an out-of-range or X/Z index names no element, so
                // the write is discarded rather than landing somewhere.
                try evaluate.put(self, scratch, a.target, self.holds.items[s.cell], a.nonblocking, null);
                pc += 1;
                continue;
            },
            // §5.10 an event has "no time duration": the resumed processes
            // are scheduled in the active region of this same timestep, and
            // execution of the triggering process continues meanwhile.
            .trigger => |event| {
                const at = switch (event) {
                    .slot => |slot| slot,
                    .indexed => |e| try evaluate.address(self, scratch, e),
                };
                if (at) |slot| try waiters.trigger(self, slot);
                pc += 1;
                continue;
            },
            // §6.1: drive this assignment's own value, resolve the net from
            // every driver of it, then suspend on the operands. The
            // resumption point is this same pc, so a change re-drives.
            .continuous => |at| {
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
            },
            // §7.6 a controlled pass switch: read the control, re-resolve
            // both sides, then wait on the control's operands.
            .switch_ctrl => |s| {
                const t = &self.trans[s.tran];
                const c = (try evaluate.eval(self, scratch, t.ctrl, 1)).bit(0);
                const next: @import("net.zig").Tran.State = if (c == t.on) .on else if (c == .zero or c == .one) .off else .unknown;
                if (t.delay.present) try resolution.switchAfter(self, s.tran, next) else {
                    t.state = next;
                    try resolution.resolve(self, t.a);
                    try resolution.resolve(self, t.b);
                }
                self.armed[pc] = true;
                return;
            },
            .override_on => |o| {
                const entry = try self.overrides.getOrPut(self.arena, o.slot);
                if (!entry.found_existing) entry.value_ptr.* = .{};
                if (o.bits) |bits| {
                    const parts = &entry.value_ptr.parts;
                    const range: @import("root.zig").PcRange = .{ .start = o.start, .end = o.end };
                    for (parts.items) |*p| {
                        if (!std.meta.eql(p.bits, bits)) continue;
                        try doneFlush(self, p.range.start);
                        _ = try stopRange(self, p.range.start, p.range.end);
                        p.range = range;
                        break;
                    } else try parts.append(self.arena, .{ .bits = bits, .range = range });
                    _ = try enqueue(self, .{ .run_process = o.start }, null, false);
                    if (self.done_hook != null and self.done_sites.contains(pc)) try self.done_pending.put(self.arena, o.start, pc);
                    pc += 1;
                    continue;
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
                if (self.done_hook != null and self.done_sites.contains(pc)) try self.done_pending.put(self.arena, o.start, pc);
                pc += 1;
                continue;
            },
            .override_eval => |o| {
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
                try doneFlush(self, pc);
                pc += 1;
                continue;
            },
            .override_off => |o| {
                // An override undone before its process ran was still executed.
                if (self.overrides.get(o.slot)) |layers| {
                    if (o.bits) |bits| {
                        for (layers.parts.items) |p| if (std.meta.eql(p.bits, bits)) try doneFlush(self, p.range.start);
                    } else if (if (o.force) layers.force else layers.assign) |layer| try doneFlush(self, layer.start);
                }
                if (o.bits) |bits| try waiters.releaseBits(self, o.slot, bits) else try waiters.release(self, o.slot, o.force);
                if (self.done_hook) |h| if (self.done_sites.contains(pc)) try h(self, pc);
                pc += 1;
                continue;
            },
            .fork => |f| {
                if (f.arms.len == 0) {
                    pc = f.end;
                    continue;
                }
                if (self.ctx == 0)
                    self.joins.items[f.join] = @intCast(f.arms.len)
                else
                    try self.act_joins.put(self.arena, .{ .join = f.join, .ctx = self.ctx }, @intCast(f.arms.len));
                for (f.arms) |arm| _ = try enqueue(self, resumption(arm, self.ctx), null, false);
                return;
            },
            .join_arm => |j| {
                const left = if (self.ctx == 0) &self.joins.items[j.join] else self.act_joins.getPtr(.{ .join = j.join, .ctx = self.ctx }).?;
                left.* -= 1;
                if (left.* == 0) _ = try enqueue(self, resumption(j.end, self.ctx), null, false);
                return;
            },
            // §17.5 an asynchronous PLA: its own process, which evaluates and
            // waits on its inputs and personality, forever.
            .pla_start => |loop| {
                _ = try enqueue(self, .{ .run_process = loop }, null, false);
                pc += 1;
                continue;
            },
            .call => |s| {
                _ = try callSync(self, scratch, s.sub, s.args);
                pc += 1;
                continue;
            },
            // §10.2.2 copy-out: the formal assigned to the caller's lvalue,
            // under the assignment rules (§5.5.3) and in the caller's scope.
            .copy_out => |s| {
                try evaluate.put(self, scratch, s.target, try evaluate.convertSlot(self, scratch, s.slot, try evaluate.targetType(self, s.target)), false, null);
                pc += 1;
                continue;
            },
            .call_timed => |c| {
                pc = try callTimed(self, scratch, c.sub, c.args, pc);
                continue;
            },
            .task_return => |idx| {
                pc = try returnTimed(self, scratch, idx);
                continue;
            },
            // §10.3 "disabling such a task shall disable all activations of
            // the task": every inlined copy (the current one resumes after
            // itself), and every synchronous activation, which unwind.
            .disable_task => |idx| {
                const sub = &self.subs.items[idx];
                var next = pc + 1;
                var resumed = false;
                for (sub.ranges.items) |rg| {
                    const inside = pc >= rg.start and pc < rg.end;
                    if (inside) next = rg.end;
                    if (try disable(self, rg.start, rg.end) and inside) resumed = true;
                }
                if (sub.active != 0) {
                    self.unwind = idx;
                    return;
                }
                if (resumed) return;
                pc = next;
                continue;
            },
            .disable_block => |b| {
                const inside = pc >= b.start and pc < b.end;
                const resumed = try disable(self, b.start, b.end) and inside;
                if (self.done_hook) |h| if (self.done_sites.contains(pc)) try h(self, pc);
                if (resumed) return;
                // IEEE1364 §10.3: self/ancestor disable resumes AFTER the
                // target block, while a sibling disable continues here.
                pc = if (inside) b.end else pc + 1;
                continue;
            },
            .restart => |s| {
                // A suspension returns from this dispatch, so reaching the
                // restart a second time within one proves a whole body ran
                // with no timing control. That spins the scheduler forever
                // at one timestamp, so it is reported instead of hanging.
                if (restarted) return self.fail(s.tok, "this always process completed an iteration without suspending; it needs a delay or event control", .{});
                restarted = true;
                pc = s.target;
                continue;
            },
            .branch => |s| {
                pc = if (try evaluate.truthOf(self, scratch, s.condition) == .one) pc + 1 else s.otherwise;
                continue;
            },
            .repeat_start => |s| {
                const value = try evaluate.eval(self, scratch, s.count, 0);
                // §9.6/§9.7.7: x, z or a negative count of any width is zero
                // times; past 64 bits saturates, as 2^64 passes never end.
                const words = value.values();
                const count: u64 = if (value.hasUnknown() or (value.signed and value.bit(value.width - 1) == .one))
                    0
                else if (std.mem.allEqual(u64, words[1..], 0)) words[0] else std.math.maxInt(u64);
                self.repeats.items[s.counter] = count;
                pc = if (count == 0) s.end else pc + 1;
                continue;
            },
            .repeat_next => |s| {
                self.repeats.items[s.counter] -= 1;
                if (self.repeats.items[s.counter] != 0) try loopIteration(self);
                pc = if (self.repeats.items[s.counter] != 0) s.body else pc + 1;
                continue;
            },
            .case_select => |s| {
                const case = self.file.stmt(s.statement).case_stmt;
                const value = try evaluate.evalContext(self, scratch, case.scrutinee, s.ty);
                pc = s.fallback;
                search: for (case.arms, 0..) |arm, i| {
                    for (arm.labels) |label| {
                        const item = try evaluate.evalContext(self, scratch, label, s.ty);
                        if (caseMatches(case.kind, value, item)) {
                            pc = self.case_targets.items[s.targets + i];
                            break :search;
                        }
                    }
                }
                continue;
            },
        }
    }
}

// ---- tests ------------------------------------------------------------------

test "§9.5.1 casez/casex per plane word agree with the per-bit wildcard rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng = std.Random.DefaultPrng.init(0x9051);
    const rand = prng.random();
    for ([_]u32{ 1, 3, 64, 70 }) |width| for (0..500) |_| {
        const v = try filled(a, width, false, .zero);
        const l = try filled(a, width, false, .zero);
        for (0..width) |i| {
            // Mostly 0/1 so that some pairs match.
            setBit(v, @intCast(i), if (rand.uintLessThan(u8, 4) == 0) rand.enumValue(Int.Bit) else .zero);
            setBit(l, @intCast(i), if (rand.uintLessThan(u8, 4) == 0) rand.enumValue(Int.Bit) else .zero);
        }
        for ([_]Ast.CaseKind{ .casez, .casex }) |kind| {
            const want = for (0..width) |i| {
                const x = v.bit(@intCast(i));
                const y = l.bit(@intCast(i));
                if (x == .z or y == .z or (kind == .casex and (x == .x or y == .x))) continue;
                if (x != y) break false;
            } else true;
            try std.testing.expectEqual(want, caseMatches(kind, v, l));
        }
    };
}

test "§9.8.2 fork starts every arm at once and join waits for the last" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\initial begin
        \\  fork #3 $write("a%0d ", $time); begin #1 $write("b%0d ", $time); #1 $write("c%0d ", $time); end join
        \\  fork join
        \\  $display("end%0d", $time);
        \\end
        \\endmodule
    , "b1 c2 a3 end3\n");
}

test "wait constant true and constant expression continue immediately" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\initial begin
        \\  wait (1) $display("literal t=%0d", $time);
        \\  wait ((2 + 3) == 5) $display("expression t=%0d", $time);
        \\  wait (1);
        \\  $display("null body t=%0d", $time);
        \\end
        \\endmodule
    , "literal t=0\nexpression t=0\nnull body t=0\n");
}

test "wait constant false suspends without blocking other processes" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\initial begin
        \\  $display("armed");
        \\  wait (0) $display("wrong literal");
        \\  $display("wrong continuation");
        \\end
        \\initial begin
        \\  wait (7 == 8) $display("wrong expression");
        \\end
        \\initial begin
        \\  #2 $display("other t=%0d", $time);
        \\  $finish(0);
        \\end
        \\endmodule
    , "armed\nother t=2\n");
}

test "wait dependent condition still retests and resumes at true level" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\integer count;
        \\initial begin
        \\  count = 0;
        \\  wait (count == 2) $display("resumed count=%0d t=%0d", count, $time);
        \\end
        \\initial begin
        \\  #1 count = 1;
        \\  #1 count = 2;
        \\  #1 $finish(0);
        \\end
        \\endmodule
    , "resumed count=2 t=2\n");
}

test "source processes suspend at zero delay and NBA captures RHS in lexical order" {
    try expectRun(
        \\`timescale 1ns/1ps
        \\module example;
        \\reg [3:0] a, b;
        \\initial begin
        \\  $display("initial %b",a);
        \\  a = 4'b0001;
        \\  b <= a;
        \\  b <= 4'b0011;
        \\  a = 4'b0010;
        \\  #0 $display("inactive %b %b",a,b);
        \\  #1 $display("after %b %b",a,b);
        \\  $finish(0);
        \\end
        \\initial begin #0 $display("peer %b",a); end
        \\endmodule
    , "initial xxxx\ninactive 0010 xxxx\npeer 0010\nafter 0010 0011\n");
}

test "§9.7.1 a real delay rounds to the precision instead of truncating to the unit" {
    // `#0.5` under 10ns/100ps is 50 precision units, half a time unit, not
    // zero. Truncating it, or ignoring the fraction, would print `0 0`; only
    // rounding gives 1.
    try expectRun(
        \\`timescale 10ns/100ps
        \\module m; initial begin #0.5 $display("%0d %g", $time, $realtime); end endmodule
        \\
    , "1 0.5\n");
}

test "unknown delay is zero and finish discards pending later processes" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a;
        \\initial begin
        \\  a = 0; a <= 1;
        \\  #(1'bx) $display("unknown-delay %b",a);
        \\  #1 $display("later %b",a);
        \\  $finish(0);
        \\end
        \\initial begin #2 $display("not run"); end
        \\endmodule
    , "unknown-delay 0\nlater 1\n");
}

test "disable terminates a named block and resumes after it" {
    // Both halves of IEEE 1364 §10.3's sentence: a `disable` that only
    // cancelled would print 0001, and one that only resumed would let the
    // block's own `#4` write 0010 land first.
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg [3:0] r;
        \\initial begin
        \\  r = 4'b0001;
        \\  begin : work
        \\    #4 r = 4'b0010;
        \\  end
        \\  r = 4'b0100;
        \\end
        \\initial begin
        \\  #2 disable work;
        \\  #4 $display("after %b", r);
        \\  $finish(0);
        \\end
        \\endmodule
    , "after 0100\n");
}

test "disable self and ancestor skip the active target remainder" {
    try expectRun(
        \\module m;
        \\integer r;
        \\initial begin
        \\  r=0;
        \\  begin : outer
        \\    begin : inner
        \\      r=1; disable inner; r=99;
        \\    end
        \\    r=r+2;
        \\  end
        \\  $display("inner=%0d",r);
        \\  begin : ancestor
        \\    begin : descendant
        \\      r=1; disable ancestor; r=99;
        \\    end
        \\    r=88;
        \\  end
        \\  r=r+4; $display("ancestor=%0d",r);
        \\end
        \\endmodule
    , "inner=3\nancestor=5\n");
}

test "disable loop ancestor after suspension leaves unrelated processes alive" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\integer count,tail,resumed,sibling;
        \\initial begin
        \\  count=0; tail=0; resumed=0;
        \\  begin : stop_loop
        \\    repeat(3) begin
        \\      #1; count=count+1;
        \\      if(count==2) disable stop_loop;
        \\      tail=tail+1;
        \\    end
        \\  end
        \\  resumed=1;
        \\end
        \\initial begin sibling=0; #3; sibling=1; end
        \\initial begin
        \\  #4; $display("loop=%0d tail=%0d resumed=%0d sibling=%0d",count,tail,resumed,sibling);
        \\end
        \\endmodule
    , "loop=2 tail=1 resumed=1 sibling=1\n");
}

test "disable self allows later reentry and inactive sibling stays inactive" {
    try expectRun(
        \\module m;
        \\integer count;
        \\initial begin
        \\  count=0;
        \\  repeat(2) begin : work
        \\    count=count+1; disable work; count=99;
        \\  end
        \\  disable work;
        \\  $display("reentry=%0d",count);
        \\end
        \\endmodule
    , "reentry=2\n");
}

test "finish verbosity reports exact local precision ticks and mapped source" {
    const source = "`timescale 1ns/1ps\nmodule m; initial #1 $finish; endmodule";
    const offset = std.mem.find(u8, source, "$finish").?;
    var expected: [128]u8 = undefined;
    try expectRun(source, try std.mem.print(&expected, "$finish at tick 1000, <digital> byte {d}\n", .{offset}));
}

test "nested expressions preserve NBA snapshot and evaluate delay at suspension" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\reg [3:0] a,b;
        \\integer n;
        \\initial begin
        \\  a=4'h3; n=0;
        \\  b <= (a+4'h1)*4'h2;
        \\  a=4'hf;
        \\  #(n+1) $display("nested-nba %b",b);
        \\  $finish(0);
        \\end
        \\endmodule
    , "nested-nba 1000\n");
}

test "§9.6 an x count repeats nothing, a real count rounds (§4.8.2)" {
    // n: 0 for the x count, 0 for the zero count, 3 for the count 3, and 3
    // for 2.5 rounded away from zero.
    try expectRun(
        \\module m; integer n;
        \\initial begin
        \\  n = 0; repeat (1'bx) n = n + 1; repeat (0) n = n + 1; repeat (3) n = n + 1; $display("%0d", n);
        \\  n = 0; repeat (2.5) n = n + 1; $display("%0d", n);
        \\end
        \\endmodule
    , "3\n3\n");
}

test "§9.5 case matches x and z exactly, casez/casex take them as wildcards, the first matching arm wins" {
    // case (2'bx1): 2'b01 differs in an x bit, 2'bx1 matches it exactly.
    // casez: the scrutinee's z bit is a wildcard, 1?01 matches 1101.
    // casex: its x bit is one, 1?01 matches 1001.
    // 2'b10 matches the first label of the first arm; 2'b11 matches no arm
    // and there is no default, so nothing runs.
    try expectRun(
        \\module m;
        \\initial begin
        \\  case (2'bx1) 2'b01: $display("no"); 2'bx1: $display("x1"); default: $display("default"); endcase
        \\  casez (4'b1z01) 4'b1101: $display("z-wild"); default: $display("no"); endcase
        \\  casex (4'b1x01) 4'b1001: $display("x-wild"); default: $display("no"); endcase
        \\  case (2'b10) 2'b10, 2'b1x: $display("first"); 2'b10: $display("second"); endcase
        \\  case (2'b11) 2'b00: $display("no"); endcase
        \\  $display("end");
        \\end
        \\endmodule
    , "x1\nz-wild\nx-wild\nfirst\nend\n");
}

test "§10.3 disabling a fork from one of its arms ends the others and resumes the parent once" {
    // t=1 the first arm prints; t=2 the third disables f, which ends the
    // second (due at t=3), and "execution continues with the statement
    // following the block" once: `after 2`, a single time.
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\initial begin
        \\  fork : f
        \\    #1 $display("a %0d", $time);
        \\    #3 $display("b %0d", $time);
        \\    #2 disable f;
        \\  join
        \\  $display("after %0d", $time);
        \\end
        \\endmodule
    , "a 1\nafter 2\n");
}

test "§17.4.1 $finish reports by its argument; an x argument reports" {
    try expectRun("module m; initial $finish(0); endmodule", "");
    const source = "module m; initial $finish(1'bx); endmodule";
    const offset = std.mem.find(u8, source, "$finish").?;
    var expected: [128]u8 = undefined;
    try expectRun(source, try std.mem.print(&expected, "$finish at tick 0, <digital> byte {d}\n", .{offset}));
}

test "repeat accepts all 64 count bits and finish stops without an iteration clamp" {
    try expectRun("module m; initial repeat(64'hffffffffffffffff) begin $display(\"first\"); $finish(0); end endmodule", "first\n");
    try expectRun("module m; integer i; initial begin i=0; while(i<70001) i=i+1; $display(\"%b\",i); end endmodule", "00000000000000010001000101110001\n");
}
