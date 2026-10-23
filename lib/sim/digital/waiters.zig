//! The write path and its waiters: a value arriving at a slot -> stored,
//! and the continuous drivers, event controls and watchers it wakes
//! (`Run.susps`, `Run.terms`, `Run.fan`, `Run.watch`). The one path the
//! active and NBA regions, a net's resolution and a VPI put all take.
//! Clauses: IEEE 1364-2005 §5.10.1 edges, §5.10.4 named events, §6.1 static
//! fan-out, §9.3 procedural continuous assignments, §9.7.1-§9.7.3 event
//! controls, §10.2.1, §11.4.2, §15 timing checks, §17.1.3, §18; VAMS §8.5
//! D2A events.
const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const compile = @import("compile.zig");
const driver = @import("driver.zig");
const root = @import("root.zig");
const Error = root.Error;
const Run = root.Run;
const expectRun = root.expectRun;
const setBit = @import("net.zig").setBit;
const wordMask = @import("net.zig").wordMask;
const evaluate = @import("evaluate.zig");
const exec = @import("exec.zig");
const resolution = @import("resolution.zig");
const tchk = @import("tchk.zig");

/// §5.10.1: an edge is a change toward 1 (posedge) or away from 1 (negedge),
/// with x and z as the intermediate value on either side of the transition.
pub const Edge = enum(u2) {
    any,
    posedge,
    negedge,

    /// Whether a change of the watched bit from `before` to `after` is this
    /// edge (§9.7.2 Table 9-1). `any` is true for every change, since the
    /// caller has already proved the whole value changed.
    pub fn matches(self: Edge, before: Int.Bit, after: Int.Bit) bool {
        // A plain `@(v)` term watches the whole value, which the caller has
        // already proved changed; the other two read the LSB the table covers.
        if (self == .any) return true;
        if (before == after) return false;
        return switch (self) {
            .posedge => before == .zero or after == .one,
            .negedge => before == .one or after == .zero,
            .any => unreachable,
        };
    }
};

/// One process suspended on an event control (§9.7): where it resumes, and
/// in which task activation (`ctx`, 0 for none). The terms of its `or` all
/// name this row, and retire together when any one of them fires. `gen`
/// counts the row's retirements, so a term filed by an earlier occupant of a
/// recycled row is recognisably stale.
pub const Susp = struct {
    pc: u32,
    ctx: u32,
    gen: u32,
    alive: bool,

    // Budget: one row per suspended process, recycled (`Run.free_susps`).
    comptime {
        std.debug.assert(@sizeOf(Susp) == 16);
    }
};

/// One term of a suspension's event expression, filed under the slot it
/// watches (`Run.terms`). Live while `gen` is its suspension's.
pub const Term = struct {
    susp: u32,
    gen: u32,
    edge: Edge,
    /// §9.7.3: an event array index selects which occurrence wakes this
    /// waiter. Changing the index itself does not cause an occurrence.
    event_select: Ast.ExprId = .none,
    scope: u32 = 0,
    /// §9.7.2 a constant select term (`compile.selectTerm`): bits
    /// `[lo, lo + width)` of the slot, and their value when last tested
    /// (`v`, `x` planes); width 0 is the whole slot.
    lo: u32 = 0,
    width: u32 = 0,
    v: u64 = 0,
    x: u64 = 0,

    // Budget: one row per waiting term, walked by every `wake` of its slot.
    // The select-term fields (`lo` .. `x`) are 24 of these bytes and rare;
    // `rt` keeps them out of line (`rt.Rec`), which this row could too.
    comptime {
        std.debug.assert(@sizeOf(Term) == 48);
    }
};

/// Bits `[lo, lo + width)` of `value`, `width` at most 64, as (values,
/// unknowns) words.
pub fn termBits(value: Int.Literal, lo: u32, width: u32) [2]u64 {
    var out: [2]u64 = undefined;
    for ([_][]const u64{ value.values(), value.unknowns() }, &out) |plane, *o| {
        const w = lo / 64;
        const sh: u6 = @intCast(lo % 64);
        var bits = plane[w] >> sh;
        if (sh != 0 and w + 1 < plane.len) bits |= plane[w + 1] << @intCast(64 - @as(u7, sh));
        o.* = bits & wordMask(width, 0);
    }
    return out;
}

/// A change of a select term's bits: whether it matches `t.edge` (of the
/// select's least significant bit) and, either way, `t` now remembers them.
fn selectChanged(t: *Term, value: Int.Literal) bool {
    const now = termBits(value, t.lo, t.width);
    if (now[0] == t.v and now[1] == t.x) return false;
    const before: Int.Bit = @fromBackingInt(@intCast(@as(u2, @intCast(t.v & 1)) | @as(u2, @intCast(t.x & 1)) << 1));
    const after: Int.Bit = @fromBackingInt(@intCast(@as(u2, @intCast(now[0] & 1)) | @as(u2, @intCast(now[1] & 1)) << 1));
    t.v = now[0];
    t.x = now[1];
    return t.edge.matches(before, after);
}

// ---- the write path (§5.10.1, §9.3, VAMS §8.5) ------------------------------

/// Stores `planes` into slot `target` and wakes what watches it: the one
/// write path for the active and NBA regions, so none bypasses §5.10.1
/// resumption. A write to a slot a §9.3 override holds is dropped, unless
/// `overriding`.
pub fn store(self: *Run, target: u32, planes: []const u64) Error!void {
    // §9.3: while a procedural continuous assignment holds the slot, its own
    // process is the only writer: an `assign` over a variable, a `force`
    // over anything, including a net's resolution.
    const dest = self.values[target];
    const before = dest.bit(0);
    // §14.3.3 a module path source's transitions, by time (`resolution.pathDelay`).
    const path_source = target < self.watch.len and self.watch[target].contains(.path);
    const before_words: [2]u64 = if (path_source) .{ dest.values()[0], dest.unknowns()[0] } else undefined;
    const changed = changed: {
        if (self.overrides.count() != 0 and !self.overriding) if (self.overrides.get(target)) |o| {
            if (o.force != null or (o.assign != null and !self.net_of.contains(target))) return;
            // §9.3.2 a forced select of a net keeps its bits; the rest resolve.
            if (o.parts.items.len != 0) break :changed keepForced(dest, planes, o.parts.items);
        };
        // A real changes when its value does: -0.0 and +0.0 compare equal
        // (VAMS §3.7, IEEE 754 `==`), and a NaN never equals itself.
        const differ = !std.mem.eql(u64, dest.planes, planes);
        const changed = if (self.reals.contains(target))
            @as(f64, @bitCast(dest.planes[0])) != @as(f64, @bitCast(planes[0]))
        else
            differ;
        // "No change" governs only the event: -0.0 over +0.0 still stores its
        // bits, so `1.0/r` reads -inf (docs/specification/Vague_Decisions.md VD-032). Not
        // copied when equal, which also covers `planes` aliasing `dest.planes`
        // (`a = a`), a copy @memcpy forbids.
        if (differ) @memcpy(dest.planes, planes);
        break :changed changed;
    };
    // A §10.4.5 constant function running during elaboration: nothing
    // watches a slot yet.
    if (self.growing != null or self.folding_constant) return;
    if (!changed) return driver.stored(self, target, false);
    if (path_source) try self.path_changed.put(self.arena, target, .{ .time = self.scheduler.now, .before = before_words, .after = .{ dest.values()[0], dest.unknowns()[0] } });
    // Most slots have no watcher, so one test skips them all.
    const watchers = self.watch[target];
    if (watchers.count() != 0) {
        if (watchers.contains(.monitor)) try @import("display.zig").monitorChanged(self, target);
        if (watchers.contains(.analog)) try requestAnalog(self);
        if (watchers.contains(.vcd) or watchers.contains(.ports)) try requestVcd(self);
        if (watchers.contains(.d2a)) try requestD2a(self, target, before, dest.bit(0));
    }
    try wake(self, target, before, dest.bit(0));
    // IEEE 1364-2005 §15: a timing check whose event this slot is.
    if (watchers.contains(.tchk)) try tchk.changed(self, target, before, dest.bit(0));
    if (watchers.contains(.vpi)) if (self.vpi_change) |f| f(self, target);
    // After `wake`, so a `driver_update` process runs after the driver it
    // watches has re-evaluated (both join the same active-region FIFO).
    try driver.stored(self, target, true);
}

/// Writes `planes` into `dest` but for the bits of each forced select in
/// `parts` (a `compile.Bits` each, at `.bits`), which keep `dest`'s, and
/// returns whether `dest` changed. Word by word in place, so a net held by
/// a forced select resolves without allocating. `planes` may alias `dest`.
fn keepForced(dest: Int.Literal, planes: []const u64, parts: anytype) bool {
    std.debug.assert(planes.len == dest.planes.len);
    const words = dest.values().len;
    var differ = false;
    for (0..words) |w| {
        var keep: u64 = 0;
        for (parts) |p| keep |= selectWord(p.bits, w);
        for ([2]usize{ w, words + w }) |i| {
            const new = (planes[i] & ~keep) | (dest.planes[i] & keep);
            differ = differ or new != dest.planes[i];
            dest.planes[i] = new;
        }
    }
    return differ;
}

/// The bits of plane word `w` that `bits` covers.
fn selectWord(bits: compile.Bits, w: usize) u64 {
    const base: u64 = w * 64;
    const lo = @max(bits.lo, base);
    const hi = @min(@as(u64, bits.lo) + bits.width, base + 64);
    if (lo >= hi) return 0;
    const n = hi - lo;
    const ones = std.math.shl(u64, 1, n) -% 1;
    return ones << @intCast(lo - base);
}

/// §5.10.4 `-> e`: named event `at` occurs, resuming what waits on it.
pub fn trigger(self: *Run, at: u32) Error!void {
    if (self.watch[at].contains(.d2a)) try requestD2a(self, at, .x, .x);
    if (self.watch[at].contains(.vcd)) {
        self.vcd.fire(&self.vcd_catalog.?, at);
        try requestVcd(self);
    }
    try wake(self, at, .x, .x);
}

/// §9.3 `deassign` (`force` false) or `release` (`force` true) of `slot`.
/// Releasing what is not held is a no-op.
pub fn release(self: *Run, slot: u32, force: bool) Error!void {
    const layers = self.overrides.getPtr(slot) orelse return;
    const layer = if (force) &layers.force else &layers.assign;
    if (layer.*) |old| _ = try exec.stopRange(self, old.start, old.end);
    layer.* = null;
    const held = layers.assign;
    // A forced select is a layer of its own (§9.3.2), released only by its
    // own select: the slot stays held while one remains.
    if (layers.force == null and layers.assign == null and layers.parts.items.len == 0) _ = self.overrides.remove(slot);
    // §9.3.2: a released net is its drivers' again; a released
    // variable keeps its value, unless an assign holds it.
    if (force) {
        if (self.net_of.get(slot)) |net| try resolution.resolve(self, net) else if (held) |a| _ = try exec.enqueue(self, .{ .run_process = a.start }, null, false);
    }
}

/// §9.3.2 `release` of a forced select of net `slot`: its bits are the
/// drivers' again, at once. Releasing what is not held is a no-op.
pub fn releaseBits(self: *Run, slot: u32, bits: compile.Bits) Error!void {
    const layers = self.overrides.getPtr(slot) orelse return;
    for (layers.parts.items, 0..) |p, i| if (std.meta.eql(p.bits, bits)) {
        _ = try exec.stopRange(self, p.range.start, p.range.end);
        _ = layers.parts.orderedRemove(i);
        break;
    };
    if (layers.force == null and layers.assign == null and layers.parts.items.len == 0) _ = self.overrides.remove(slot);
    if (self.net_of.get(slot)) |net| try resolution.resolve(self, net);
}

/// VPI §12.30 vpiForceFlag: force `slot` to a constant, "same as the
/// procedural force" (§9.3.2) but with no expression to keep re-evaluating,
/// so the force layer holds an empty process range.
pub fn forceValue(self: *Run, slot: u32, planes: []const u64) Error!void {
    const entry = try self.overrides.getOrPut(self.arena, slot);
    if (!entry.found_existing) entry.value_ptr.* = .{};
    if (entry.value_ptr.force) |old| _ = try exec.stopRange(self, old.start, old.end);
    entry.value_ptr.force = .{ .start = 0, .end = 0 };
    const was = self.overriding;
    self.overriding = true;
    defer self.overriding = was;
    try store(self, slot, planes);
}

/// VAMS §8.5: "the implicit D2A event ... is created when a digital variable to
/// which an analog block is implicitly sensitive changes value". §8.5.3.7 then
/// processes the macro-process in region 3b, after every region-1..3 event of
/// the tick, and once however many inputs moved.
pub fn requestAnalog(self: *Run) Error!void {
    if (self.analog_pending) return;
    self.analog_pending = true;
    _ = self.scheduler.schedule(.analog, root.analog_payload) catch |e|
        return if (e == error.OutOfMemory) error.OutOfMemory else self.fail(0, "digital scheduling failure: {t}", .{e});
}

test "ams_implicit_d2a_queues_only_the_macro_process" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag = @import("diag").Bag.init(arena);
    var out = std.Io.Writer.Allocating.init(arena);
    var dig = try root.elaborate(arena,
        \\module implicit_queue; reg a, b; endmodule
    , .{}, &bag, &out.writer);
    try std.testing.expectEqual(root.Stop.idle, try dig.runUntil(0));
    dig.watchAnalog(dig.slotOf("a").?);
    dig.watchAnalog(dig.slotOf("b").?);
    try store(&dig, dig.slotOf("a").?, &.{ 1, 0 });
    try store(&dig, dig.slotOf("b").?, &.{ 0, 0 });
    const event = dig.scheduler.next().?;
    try std.testing.expectEqual(@import("../scheduler.zig").Region.analog, event.region);
    try std.testing.expectEqual(root.analog_payload, event.payload);
    try std.testing.expectEqual(@as(u64, 0), event.time);
    // Both implicit notifications directly request the one macro-process;
    // neither a separate active nor an explicit-D2A queue entry is added.
    try std.testing.expect(dig.scheduler.next() == null);
}

/// VAMS §8.5: an event an analog event control waits on occurred. Every term
/// it matches is marked, and ONE region-1b event reports them all once region
/// 1 of the tick is done (§8.5.3.6).
fn requestD2a(self: *Run, target: u32, before: Int.Bit, after: Int.Bit) Error!void {
    for (self.d2a_sites.items) |s| if (s.slot == target and s.edge.matches(before, after)) {
        self.d2a_fired |= @as(u64, 1) << s.site;
    };
    if (self.d2a_fired == 0 or self.d2a_pending) return;
    self.d2a_pending = true;
    _ = self.scheduler.schedule(.explicit_d2a, root.analog_payload) catch |e|
        return if (e == error.OutOfMemory) error.OutOfMemory else self.fail(0, "digital scheduling failure: {t}", .{e});
}

/// §17.1.3: "the entire argument list is displayed at the end of the time
/// step". One event however many watched values moved, and however often: a
/// value that changes and changes back within the step still "changes value",
/// so it prints, with the settled values.
pub fn requestMonitor(self: *Run) Error!void {
    if (self.monitor == null or !self.monitor_on or self.monitor_pending) return;
    self.monitor_pending = true;
    try exec.enqueueMonitor(self, .monitor_tick);
}

/// §18.1.3/§18.1.4 the dump is written at the end of the time step, once.
pub fn requestVcd(self: *Run) Error!void {
    if (self.vcd.pending) return;
    self.vcd.pending = true;
    try exec.enqueueMonitor(self, .vcd_tick);
}

/// VAMS §8.5.1: "A2D events ... are scheduled just like other event controlled
/// statements": the waiters of a monitor slot resume in the active region.
pub fn wakeA2d(self: *Run, slot: u32) Error!void {
    return wake(self, slot, .x, .x);
}

/// Re-run the MOS switches reading `target` (§7.11), when its strength
/// changed and its value may not have: no event control sees that.
pub fn wakeSwitches(self: *Run, target: u32) Error!void {
    if (target + 1 < self.fan_start.len) for (self.fan[self.fan_start[target]..self.fan_start[target + 1]]) |pc| if (self.armed[pc]) {
        const ins = self.code.items[pc];
        if (ins != .continuous or self.drivers[ins.continuous].source != .mos) continue;
        self.armed[pc] = false;
        _ = try exec.enqueue(self, .{ .run_process = pc }, null, false);
    };
}

/// Resume every process suspended on `target` whose edge matches. Split out
/// of `store` because §5.10.4's `-> e` resumes without publishing anything:
/// a named event has no value for a change to be detected in.
///
/// The continuous drivers and controlled switches reading `target` come
/// first, then the event controls in the order they suspended. §11.4.2 lets
/// the processes one event resumes run in any order.
pub fn wake(self: *Run, target: u32, before: Int.Bit, after: Int.Bit) Error!void {
    if (target + 1 < self.fan_start.len) for (self.fan[self.fan_start[target]..self.fan_start[target + 1]]) |pc| if (self.armed[pc]) {
        self.armed[pc] = false;
        _ = try exec.enqueue(self, .{ .run_process = pc }, null, false);
    };
    const list = termsOf(self, target) orelse return;
    const event = self.events.get(target);
    const event_ctx = if (event) |e| eventContext(self, e.scope, self.ctx) else 0;
    // Compacts as it goes: a matched term leaves with its suspension, and a
    // stale one (its suspension resumed through another slot, or was
    // disabled) is dropped.
    var keep: usize = 0;
    for (list.items) |t0| {
        var t = t0;
        const s = &self.susps.items[t.susp];
        if (s.gen != t.gen) continue;
        const selected = (if (event) |e| event_ctx == eventContext(self, e.scope, s.ctx) else true) and
            (if (t.width == 0) t.edge.matches(before, after) else selectChanged(&t, self.values[target])) and
            try selectedEvent(self, t, target);
        // An index function's blocking write can satisfy another term of
        // this event-or suspension while selectedEvent evaluates it.
        if (s.gen != t.gen) continue;
        if (!selected) {
            list.items[keep] = t;
            keep += 1;
            continue;
        }
        const pc = s.pc;
        const ctx = s.ctx;
        retire(self, t.susp);
        _ = try exec.enqueue(self, exec.resumption(pc, ctx), null, false);
    }
    list.shrinkRetainingCapacity(keep);
}

/// §10.2.1 allocates all declared items for each automatic invocation,
/// including events: a shared compiled slot is not a shared event identity.
/// Find the live activation enclosing this declaration (also for events in
/// its named blocks). Static events need no activation key; an inlined
/// automatic frame already has distinct slots.
fn eventContext(self: *const Run, declared: u32, from: u32) u32 {
    var ctx = from;
    while (ctx != 0) {
        const act = self.acts.items[ctx];
        const sub = self.subs.items[act.sub];
        if (sub.decl.automatic) {
            const frame_scope = sub.body.?.frame.scope;
            var scope = declared;
            while (true) {
                if (scope == frame_scope) return ctx;
                const info = self.scope_info.items[scope];
                if (!info.lexical) break;
                scope = info.parent;
            }
        }
        ctx = act.ret_ctx;
    }
    return 0;
}

/// §§9.7.2–9.7.3: the event expression selects an occurrence; changing
/// its index alone is not an occurrence. Test the current select only when
/// an element occurs, in the suspended reader's automatic activation.
fn selectedEvent(self: *Run, t: Term, target: u32) Error!bool {
    if (t.event_select == .none) return true;
    var scratch = std.heap.ArenaAllocator.init(self.arena);
    defer scratch.deinit();
    const scope = self.scope;
    const ctx = self.ctx;
    defer self.scope = scope;
    defer self.ctx = ctx;
    self.scope = t.scope;
    self.ctx = self.susps.items[t.susp].ctx;
    try exec.makeResident(self, self.ctx);
    const selected = try evaluate.address(self, scratch.allocator(), t.event_select);
    try exec.makeResident(self, ctx);
    return selected != null and selected.? == target;
}

/// The terms filed under `slot`, or null when nothing has ever waited on it.
/// A slot below `Run.terms.len` keeps its list at a stable address; one
/// above it (`driver.key`, a monitor's slot) is in `Run.far_terms`, whose
/// rows a later `watch` of another far slot may move.
pub fn termsOf(self: *Run, slot: u32) ?*std.ArrayList(Term) {
    return if (slot < self.terms.len) self.terms[slot] else self.far_terms.getPtr(slot);
}

/// Suspend the executing process at `pc` (§9.7). Its terms are filed with
/// `watch` under the id returned. Invalidates pointers into `Run.susps`
/// when no row is free for reuse.
pub fn park(self: *Run, pc: u32) Error!u32 {
    const id = self.free_susps.pop() orelse blk: {
        try self.susps.append(self.arena, .{ .pc = 0, .ctx = 0, .gen = 0, .alive = false });
        // Room for every row on the free list, so `retire` cannot fail.
        try self.free_susps.ensureTotalCapacity(self.arena, self.susps.items.len);
        break :blk @as(u32, @intCast(self.susps.items.len - 1));
    };
    const s = &self.susps.items[id];
    s.pc = pc;
    s.ctx = self.ctx;
    s.alive = true;
    return id;
}

/// File one term of suspension `id` under `slot`. A slot's first wait
/// beyond `Run.terms` adds a `Run.far_terms` row, which invalidates
/// pointers to the other far lists (`termsOf`).
pub fn watch(self: *Run, id: u32, slot: u32, edge: Edge) Error!void {
    const list = termsOf(self, slot) orelse if (slot < self.terms.len) blk: {
        // Made on the slot's first wait, at an address that stays put.
        const l = try self.arena.create(std.ArrayList(Term));
        l.* = .empty;
        self.terms[slot] = l;
        break :blk l;
    } else blk: {
        const g = try self.far_terms.getOrPut(self.arena, slot);
        g.value_ptr.* = .empty;
        break :blk g.value_ptr;
    };
    // Stale terms stay until their slot is next woken, which a slot that
    // never changes never is: sweep them before the list grows, and grow
    // anyway past half full so a sweep is paid for by as many appends.
    if (list.items.len == list.capacity and list.capacity != 0) {
        var keep: usize = 0;
        for (list.items) |t| if (self.susps.items[t.susp].gen == t.gen) {
            list.items[keep] = t;
            keep += 1;
        };
        list.shrinkRetainingCapacity(keep);
        if (keep > list.capacity / 2) try list.ensureTotalCapacity(self.arena, list.capacity * 2);
    }
    try list.append(self.arena, .{ .susp = id, .gen = self.susps.items[id].gen, .edge = edge });
}

/// The process at suspension `id` is no longer waiting: every term it filed
/// goes stale, and the row is free.
pub fn retire(self: *Run, id: u32) void {
    const s = &self.susps.items[id];
    s.alive = false;
    s.gen +%= 1;
    self.free_susps.appendAssumeCapacity(id);
}

/// The static fan-out of every continuous driver and controlled switch
/// (§6.1, §7.6): their operands are fixed at compile time, so each slot's
/// list of them is built once, and a flag per pc stands for the whole
/// sensitivity list the process would otherwise re-register per evaluation.
/// Called once the slot space and the code are final.
pub fn buildFanout(r: *Run) Error!void {
    const n = r.values.len;
    const start = try r.arena.alloc(u32, n + 1);
    @memset(start, 0);
    for (r.code.items) |ins| for (staticSlots(r, ins)) |at| {
        start[at + 1] += 1;
    };
    for (1..n + 1) |i| start[i] += start[i - 1];
    const fill = try r.arena.dupe(u32, start[0..n]);
    const fan = try r.arena.alloc(u32, start[n]);
    for (r.code.items, 0..) |ins, pc| for (staticSlots(r, ins)) |at| {
        fan[fill[at]] = @intCast(pc);
        fill[at] += 1;
    };
    r.arena.free(fill); // the cursor is spent; a large one goes back now
    r.fan_start = start;
    r.fan = fan;
    r.armed = try r.arena.alloc(bool, r.code.items.len);
    @memset(r.armed, false);
    r.terms = try r.arena.alloc(?*std.ArrayList(Term), n);
    @memset(r.terms, null);
}

fn staticSlots(r: *const Run, ins: compile.Instruction) []const u32 {
    return switch (ins) {
        .continuous => |i| r.drivers[i].sensitivity,
        .switch_ctrl => |s| s.slots,
        else => &.{}, // else: every other instruction suspends through `park`
    };
}

// ---- tests ------------------------------------------------------------------

test "§9.3 force over assign, release back to the assign, deassign keeps" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\reg a, b, v;
        \\initial begin
        \\  a = 0; b = 1;
        \\  assign v = a; #1 $write("%b", v);
        \\  force v = b; #1 $write("%b", v);
        \\  a = 1; b = 0; #1 $write("%b", v);
        \\  release v; #1 $write("%b", v);
        \\  deassign v; a = 0; v = 0; #1 $display("%b%b", v, a);
        \\end
        \\endmodule
    , "010100\n");
}

test "an always process resumes on each posedge of a clock it does not drive" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg clk;
        \\reg [3:0] n;
        \\initial begin clk = 0; n = 0; end
        \\always #5 clk = ~clk;
        \\always @(posedge clk) begin n = n + 1; $display("tick %b", n); end
        \\initial #28 $finish(0);
        \\endmodule
    , "tick 0001\ntick 0010\ntick 0011\n");
}

test "a negedge term ignores the opposite transition" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg clk;
        \\reg [3:0] n;
        \\initial begin clk = 0; n = 0; end
        \\always #5 clk = ~clk;
        \\always @(negedge clk) begin n = n + 1; $display("fall %b", n); end
        \\initial #28 $finish(0);
        \\endmodule
    , "fall 0001\nfall 0010\n");
}

test "every term of one event expression retires when any of them fires" {
    // Both waiters belong to one process: a second resumption per change would
    // double every line below.
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a;
        \\reg b;
        \\reg [1:0] hits;
        \\initial begin a = 0; b = 0; hits = 0; end
        \\always @(a or b) begin hits = hits + 1; $display("hit %b", hits); end
        \\initial begin #5 a = 1; #5 b = 1; #5 a = 0; #5 $finish(0); end
        \\endmodule
    , "hit 01\nhit 10\nhit 11\n");
}

test "a write that does not change the value resumes nothing" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a;
        \\reg [1:0] hits;
        \\initial begin a = 0; hits = 0; end
        \\always @(a) begin hits = hits + 1; $display("hit %b", hits); end
        \\initial begin #5 a = 0; #5 a = 1; #5 $finish(0); end
        \\endmodule
    , "hit 01\n");
}

test "a nonblocking write resumes a waiting process from the NBA region" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a;
        \\reg [1:0] hits;
        \\initial begin a = 0; hits = 0; end
        \\always @(posedge a) begin hits = hits + 1; $display("nba %b", hits); end
        \\initial begin #5 a <= 1; #5 $finish(0); end
        \\endmodule
    , "nba 01\n");
}

test "§9.7.2 Table 9-1: which transitions are a posedge and which a negedge" {
    // IEEE 1364-2005 §9.7.2 Table 9-1: a posedge is 0->x, 0->z, 0->1, x->1
    // and z->1; a negedge is 1->x, 1->z, 1->0, x->0 and z->0. No other
    // change (x and z between themselves among them) is either.
    const B = Int.Bit;
    const pos = [_][2]B{ .{ .zero, .x }, .{ .zero, .z }, .{ .zero, .one }, .{ .x, .one }, .{ .z, .one } };
    const neg = [_][2]B{ .{ .one, .x }, .{ .one, .z }, .{ .one, .zero }, .{ .x, .zero }, .{ .z, .zero } };
    const all = [_]B{ .zero, .one, .z, .x };
    for (all) |from| for (all) |to| {
        const want_pos = for (pos) |p| {
            if (p[0] == from and p[1] == to) break true;
        } else false;
        const want_neg = for (neg) |n| {
            if (n[0] == from and n[1] == to) break true;
        } else false;
        try std.testing.expectEqual(want_pos, Edge.posedge.matches(from, to));
        try std.testing.expectEqual(want_neg, Edge.negedge.matches(from, to));
        try std.testing.expect(Edge.any.matches(from, to));
    };
}

test termBits {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try @import("net.zig").filled(arena.allocator(), 130, false, .zero);
    setBit(v, 60, .one);
    setBit(v, 63, .x);
    setBit(v, 64, .z);
    setBit(v, 67, .one);
    // Bits 60..67 across the word boundary: 1 at 0, x at 3, z at 4, 1 at 7.
    // An x is set in both planes and a z in the unknown plane only.
    try std.testing.expectEqual([2]u64{ 0x89, 0x18 }, termBits(v, 60, 8));
    // A window that starts a word: z at 0, 1 at 3.
    try std.testing.expectEqual([2]u64{ 0x8, 0x1 }, termBits(v, 64, 4));
    // One bit at the top of the last word.
    try std.testing.expectEqual([2]u64{ 0, 0 }, termBits(v, 129, 1));
}

// IEEE 1364-2005 §9.3.2 `force` of a constant select holds those bits; it
// is a layer of its own, so `release w` releases only the whole-net force,
// of which there is none here: bit 0 stays 1 while bit 1 follows its
// driver. The native runtime keeps a select's layer the same way
// (`rt.State.release` leaves `State.parts` alone), which makes this the
// interpreter-against-executable oracle.
test "§9.3.2 releasing a net whole keeps the forced select it did not force" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\reg a; wire [1:0] w;
        \\assign w = {a, a};
        \\initial begin
        \\  a = 0; force w[0] = 1'b1;
        \\  #1 $write("%b", w);
        \\  release w; a = 1; #1 $write("%b", w);
        \\  a = 0; #1 $display("%b", w);
        \\end
        \\endmodule
    , "011101\n");
}

test "§9.3 an assign holds a variable against an ordinary write, and deassign keeps its value" {
    // `assign v = a` makes `v = 1` land nowhere; the held value tracks `a`.
    // After `deassign`, v keeps the last value the assign gave it (0) until
    // the next ordinary write.
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\reg a, v;
        \\initial begin
        \\  a = 0; assign v = a;
        \\  #1 v = 1; #1 $write("%b", v);
        \\  a = 1; #1 $write("%b", v);
        \\  a = 0; #1 deassign v; a = 1; #1 $write("%b", v);
        \\  v = 1; #1 $display("%b", v);
        \\end
        \\endmodule
    , "0101\n");
}

test "§9.7 an event control on a named event resumes on each trigger and only then" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\event e; integer n;
        \\initial n = 0;
        \\always @(e) n = n + 1;
        \\initial begin #1 -> e; #1 -> e; #1 $display("%0d", n); end
        \\endmodule
    , "2\n");
}

test keepForced {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const filled = @import("net.zig").filled;
    const P = struct { bits: compile.Bits };
    // Selects inside one word, across the word boundary, and touching the
    // top bit: the forced bits keep x, the rest take the new 1s.
    for ([_][]const P{
        &.{.{ .bits = .{ .lo = 3, .width = 2 } }},
        &.{.{ .bits = .{ .lo = 60, .width = 10 } }},
        &.{ .{ .bits = .{ .lo = 0, .width = 1 } }, .{ .bits = .{ .lo = 129, .width = 1 } } },
        &.{.{ .bits = .{ .lo = 0, .width = 130 } }},
    }) |parts| {
        const dest = try filled(arena.allocator(), 130, false, .x);
        const ones = try filled(arena.allocator(), 130, false, .one);
        const all_forced = parts[0].bits.width == 130;
        try std.testing.expectEqual(!all_forced, keepForced(dest, ones.planes, parts));
        for (0..130) |i| {
            const held = for (parts) |p| {
                if (i >= p.bits.lo and i < p.bits.lo + p.bits.width) break true;
            } else false;
            try std.testing.expectEqual(if (held) Int.Bit.x else Int.Bit.one, dest.bit(@intCast(i)));
        }
        // The same write again changes nothing; so does `dest` over itself.
        try std.testing.expect(!keepForced(dest, ones.planes, parts));
        try std.testing.expect(!keepForced(dest, dest.planes, parts));
    }
}
