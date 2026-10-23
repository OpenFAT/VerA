//! A native design's `State` at a tick boundary -> flat bytes (`save`), and
//! back (`restore`); `twice`, the run that proves the two lossless.
//! A boundary is where IEEE 1364-2005 §11.4 has emptied the active, NBA and
//! monitor regions of a time step, so nothing mid-step (rows, a settle, a
//! subroutine frame) is in it. Pointers in the bytes name immutable parts of
//! the executable: the §17.3.2 `$timeformat` suffix and indexed event selector
//! functions (§9.7.3). Outside them,
//! and dropped by a `quiet` run: the transcript, the §17.2 file table and
//! positions, and the §18 dump.
const std = @import("std");
const root = @import("root.zig");
const State = root.State;
const Error = root.Error;
const Dispatch = root.Dispatch;
const engine = root.engine;

/// The fixed-size fields that change while a design runs, as names of
/// `State` fields (one value or a slice each), then of `State.nets`.
const fixed = .{ "v", "armed", "waiting", "seq", "repeats", "joins", "monitored", "mon_site", "mon_on", "mon_pending", "random_seed", "layers", "parts", "time_format", "budget_time", "budget_used", "two", "two_at", "steps", "look_at" };
const nets = .{ "cur", "tgt", "or_z", "tgt_or_z", "s0", "s1", "flight", "started", "res", "ntgt", "nflight", "capacitive", "decay_ev", "sig0", "prev", "state", "tstate", "ttarget", "tpending" };

fn bytes(p: anytype) []u8 {
    return @constCast(if (@typeInfo(@TypeOf(p.*)) == .pointer) std.mem.sliceAsBytes(p.*) else std.mem.asBytes(p));
}

/// `s` at a tick boundary, appended to `w`. Its length is fixed by the
/// design, plus O(the events, suspensions, `<= #d` updates and §17.6 queue
/// entries pending); a fixed `w` bounds it. Asserts `s` is at a boundary:
/// no settle, nonblocking row, changed slot, subroutine frame, unwind or
/// override in progress.
pub fn save(s: *const State, w: *std.Io.Writer) std.Io.Writer.Error!void {
    std.debug.assert(s.settle == .idle);
    std.debug.assert(s.rows.items.len == 0);
    std.debug.assert(s.changed.items.len == 0);
    std.debug.assert(s.depth == 0);
    std.debug.assert(s.unwind == null);
    std.debug.assert(!s.overriding);
    try s.sched.save(w);
    inline for (fixed) |f| try w.writeAll(bytes(&@field(s, f)));
    if (!root.logic.two) try w.writeAll(bytes(&s.x));
    inline for (nets) |f| try w.writeAll(bytes(&@field(s.nets, f)));
    try list(w, s.susps.items);
    try list(w, s.free_susps.items);
    try list(w, s.free_late.items);
    try list(w, s.recs.items);
    try list(w, s.free_recs.items);
    try count(w, s.late.items.len);
    for (s.late.items) |l| {
        try w.writeAll(std.mem.asBytes(&[4]u32{ l.slot, l.off, l.n, @intFromBool(l.real) }));
        try list(w, l.words);
    }
    // The live terms, slot by slot in filed order: a stale one never wakes.
    var live: usize = 0;
    for (s.terms) |l| for (l.items) |t| {
        live += @intFromBool(s.susps.items[t.susp].gen == t.gen);
    };
    try count(w, live);
    for (s.terms, 0..) |l, slot| for (l.items) |t| if (s.susps.items[t.susp].gen == t.gen) {
        try w.writeAll(std.mem.asBytes(&@as(u32, @intCast(slot))));
        try w.writeAll(std.mem.asBytes(&t));
    };
    // §10.2.3 the activations in progress, each with its saved frame.
    if (root.activations) {
        try list(w, s.resident);
        try list(w, s.free_acts.items);
        try list(w, s.resumes.items);
        try list(w, s.free_resumes.items);
        try count(w, s.acts.items.len);
        for (s.acts.items) |a| {
            try w.writeAll(std.mem.asBytes(&[5]u32{ a.sub, a.ret_pc, a.ret_ctx, a.lo, a.n }));
            try list(w, a.storage);
        }
    }
    try count(w, s.queues.count());
    var it = s.queues.iterator();
    while (it.next()) |e| {
        var q = e.value_ptr.*;
        q.jobs = .empty;
        try w.writeAll(std.mem.asBytes(e.key_ptr));
        try w.writeAll(std.mem.asBytes(&q));
        try list(w, e.value_ptr.jobs.items);
    }
}

/// `save` into `buf`: the bytes written, or `WriteFailed` when they do not fit.
pub fn saveTo(s: *const State, buf: []u8) std.Io.Writer.Error!usize {
    if (root.prebuilt) return engine.saveTo(s, buf);
    var w: std.Io.Writer = .fixed(buf);
    try save(s, &w);
    return w.end;
}

/// The most bytes `save` writes for design `d`: the part the design fixes,
/// exactly, and an allowance for what is pending at a boundary (events,
/// suspensions, their event-control terms) of 256 bytes per process, driver
/// and net, plus 4 KiB. A `save` into a buffer this long fails rather than
/// overrun when a boundary holds more.
/// ponytail: the allowance is a guess that fits control logic; an exact bound
/// needs the scheduler's high-water mark, which only a run knows.
pub fn bound(comptime d: *const root.Design) usize {
    @setEvalBranchQuota(1 << 24);
    var drv_words: usize = 0;
    for (d.drivers) |dr| drv_words += 2 * ((d.nets[dr.net].width + 63) / 64);
    var net_words: usize = 0;
    for (d.nets) |nt| net_words += 2 * ((nt.width + 63) / 64);
    var ins: usize = 0;
    for (d.udps) |u| ins += u.ins;
    // How many elements each slice `save` writes whole holds.
    const lens = .{
        .v = d.v.len,
        .armed = d.code_len,
        .waiting = d.triggered,
        .repeats = d.repeats,
        .joins = d.joins,
        .monitored = d.slots,
        .layers = if (root.overrides) d.slots else 0,
        .parts = if (d.part_start.len == 0) 0 else d.part_start[d.part_start.len - 1],
        .cur = drv_words,
        .tgt = drv_words,
        .or_z = d.drivers.len,
        .tgt_or_z = d.drivers.len,
        .s0 = d.drivers.len,
        .s1 = d.drivers.len,
        .flight = d.drivers.len,
        .started = d.drivers.len,
        .res = net_words,
        .ntgt = net_words,
        .nflight = d.nets.len,
        .capacitive = d.nets.len,
        .decay_ev = d.nets.len,
        .sig0 = d.nets.len,
        .prev = ins,
        .state = d.udps.len,
        .tstate = d.trans.len,
        .ttarget = d.trans.len,
        .tpending = d.trans.len,
    };
    const Sched = @FieldType(State, "sched");
    var n: usize = 8;
    for (.{ "now", "heads", "tails", "free", "sequence", "phase" }) |f| n += @sizeOf(@FieldType(Sched, f));
    for (fixed) |f| n += size(@FieldType(State, f), lens, f);
    if (!root.logic.two) n += 8 * d.x.len;
    for (nets) |f| n += size(@FieldType(@FieldType(State, "nets"), f), lens, f);
    return n + 4096 + 256 * (d.order.len + d.drivers.len + d.nets.len);
}

/// The bytes `bytes` gives a field of type `T` named `f`: a slice's
/// elements (`@field(lens, f)` of them), else the value.
fn size(comptime T: type, comptime lens: anytype, comptime f: []const u8) usize {
    if (@typeInfo(T) != .pointer) return @sizeOf(T);
    return @sizeOf(@typeInfo(T).pointer.child) * @field(lens, f);
}

fn count(w: *std.Io.Writer, n: usize) std.Io.Writer.Error!void {
    try w.writeAll(std.mem.asBytes(&@as(u32, @intCast(n))));
}

fn list(w: *std.Io.Writer, items: anytype) std.Io.Writer.Error!void {
    try count(w, items.len);
    try w.writeAll(std.mem.sliceAsBytes(items));
}

/// `s` as `save` wrote it to `b`, for the same design. Bytes that end early
/// are `error.Failed` (E1100, unless `quiet`) and leave `s` partly restored:
/// it must not run on.
pub fn restore(s: *State, b: []const u8) Error!void {
    if (root.prebuilt) return engine.restore(s, b);
    var r: std.Io.Reader = .fixed(b);
    load(s, &r) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else s.fail("a saved tick boundary is truncated", .{});
}

fn load(s: *State, r: *std.Io.Reader) (std.Io.Reader.Error || std.mem.Allocator.Error)!void {
    const gpa = s.gpa;
    try s.sched.restore(r);
    inline for (fixed) |f| try r.readSliceAll(bytes(&@field(s, f)));
    if (!root.logic.two) try r.readSliceAll(bytes(&s.x));
    inline for (nets) |f| try r.readSliceAll(bytes(&@field(s.nets, f)));
    try reload(r, gpa, &s.susps);
    try reload(r, gpa, &s.free_susps);
    // `park` grows the free list so `retire` never fails.
    try s.free_susps.ensureTotalCapacity(gpa, s.susps.items.len);
    try reload(r, gpa, &s.free_late);
    try reload(r, gpa, &s.recs);
    try reload(r, gpa, &s.free_recs);
    try s.free_recs.ensureTotalCapacity(gpa, s.recs.items.len);
    for (s.late.items) |l| gpa.free(l.words);
    try s.late.resize(gpa, try take(r));
    for (s.late.items) |*l| {
        var h: [4]u32 = undefined;
        try r.readSliceAll(std.mem.asBytes(&h));
        const words = try gpa.alloc(u64, try take(r));
        try r.readSliceAll(std.mem.sliceAsBytes(words));
        l.* = .{ .slot = h[0], .off = h[1], .n = h[2], .real = h[3] != 0, .words = words };
    }
    for (s.terms) |*l| l.clearRetainingCapacity();
    for (0..try take(r)) |_| {
        var slot: u32 = undefined;
        var t: @TypeOf(s.terms[0].items[0]) = undefined;
        try r.readSliceAll(std.mem.asBytes(&slot));
        try r.readSliceAll(std.mem.asBytes(&t));
        try s.terms[slot].append(gpa, t);
    }
    if (root.activations) {
        if (try take(r) != s.resident.len) return error.EndOfStream;
        try r.readSliceAll(std.mem.sliceAsBytes(s.resident));
        try reload(r, gpa, &s.free_acts);
        try reload(r, gpa, &s.resumes);
        try reload(r, gpa, &s.free_resumes);
        for (s.acts.items) |a| gpa.free(a.storage);
        try s.acts.resize(gpa, try take(r));
        for (s.acts.items) |*a| {
            var h: [5]u32 = undefined;
            try r.readSliceAll(std.mem.asBytes(&h));
            const storage = try gpa.alloc(u64, try take(r));
            try r.readSliceAll(std.mem.sliceAsBytes(storage));
            a.* = .{ .sub = h[0], .ret_pc = h[1], .ret_ctx = h[2], .lo = h[3], .n = h[4], .storage = storage };
        }
    }
    var it = s.queues.valueIterator();
    while (it.next()) |q| q.jobs.deinit(gpa);
    s.queues.clearRetainingCapacity();
    for (0..try take(r)) |_| {
        var id: i64 = undefined;
        var q: @import("../digital/system.zig").Queue = undefined;
        try r.readSliceAll(std.mem.asBytes(&id));
        try r.readSliceAll(std.mem.asBytes(&q));
        q.jobs = .empty;
        try reload(r, gpa, &q.jobs);
        try s.queues.put(gpa, id, q);
    }
}

fn take(r: *std.Io.Reader) std.Io.Reader.Error!u32 {
    var n: u32 = undefined;
    try r.readSliceAll(std.mem.asBytes(&n));
    return n;
}

fn reload(r: *std.Io.Reader, gpa: std.mem.Allocator, l: anytype) (std.Io.Reader.Error || std.mem.Allocator.Error)!void {
    try l.resize(gpa, try take(r));
    try r.readSliceAll(std.mem.sliceAsBytes(l.items));
}

/// What `twice` saw.
pub const Stats = struct { ticks: u64 = 0, bytes: usize = 0 };

/// `root.loop`, with every tick run twice from its boundary: first
/// `quiet`, then `restore`d and run for real. A field `save` misses carries
/// the quiet run's effect into the real one, and the transcript differs
/// from `root.loop`'s.
pub fn twice(s: *State, comptime four: Dispatch, comptime two_: ?Dispatch, stats: *Stats) ?Error {
    var at: std.Io.Writer.Allocating = .init(s.gpa);
    defer at.deinit();
    var drop_buf: [64]u8 = undefined;
    var drop: std.Io.Writer.Discarding = .init(&drop_buf);
    const sink = s.sink;
    while (true) {
        const t = s.sched.peekTime() orelse return null;
        at.clearRetainingCapacity();
        save(s, &at.writer) catch return error.OutOfMemory;
        stats.ticks += 1;
        stats.bytes = @max(stats.bytes, at.written().len);
        s.quiet = true;
        s.sink = &drop.writer;
        s.out = s.sink;
        _ = root.loop(s, four, two_, t);
        s.quiet = false;
        s.sink = sink;
        s.out = sink;
        restore(s, at.written()) catch |e| return e;
        if (root.loop(s, four, two_, t)) |e| return e;
    }
}
