//! A §17.6 stochastic queue task in (`$q_initialize`, `$q_add`, `$q_remove`, `$q_exam`, `$q_full`), the queue table and the status codes it writes out.
//! Cites: IEEE 1364-2005 §17.6.
//!
//! Contents:
//! - `pub const QueueOp = enum`
//! - `pub const Queue = struct`
//! - `pub const empty`
//! - `pub const Queues`
//! - `pub const QueueResult = struct`
//! - `pub fn int(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!?i64`
//! - `pub fn queueTask(self: *Run, a: std.mem.Allocator, op: QueueOp, args: []const Ast.ExprId) Error!void`
//! - `pub fn queueStep(queues: *Queues, gpa: std.mem.Allocator, op: QueueOp, id: ?i64, in1: ?i64, in2: ?i64, t: u64) std.mem.Allocator.Error!QueueResult`
//! - `pub fn queueFull(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId) Error!i64`
//! - `pub fn queueIsFull(queues: *const Queues, id: ?i64) struct { status: i64, full: i64 }`
//! IEEE 1364-2005 §17 system tasks that keep state of their own: a task's
//! argument expressions and the `Run` in; values written to its output
//! arguments (and, for queues, `Run.queues`) out.
//! Clauses: §17.2 file input and output, §17.2.3 string output, §17.5
//! programmable logic arrays, §17.6 stochastic queues, §17.9 distributions.
const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const waiters = @import("waiters.zig");
const evaluate = @import("evaluate.zig");
const display = @import("display.zig");
const Error = @import("root.zig").Error;
const Run = @import("root.zig").Run;
const expectRun = @import("root.zig").expectRun;
const filled = @import("net.zig").filled;
const setBit = @import("net.zig").setBit;
const wordMask = @import("net.zig").wordMask;
const rng = @import("kernels").rng_kernels;

/// The four §17.6 queue tasks; `$q_full` is a function (`SysFn.q_full`).
pub const QueueOp = enum { initialize, add, remove, exam };

/// One §17.6.1 queue: FIFO (type 1) or LIFO (type 2) of at most `max` jobs,
/// with what §17.6.5's statistics are computed from.
pub const Queue = struct {
    lifo: bool,
    max: u64,
    jobs: std.ArrayList(Job) = .empty,
    /// §17.6.5 code 3, "the maximum queue length" reached.
    peak: u64 = 0,
    last_arrival: ?u64 = null,
    interarrivals: u64 = 0,
    interarrival_sum: u64 = 0,
    waits: u64 = 0,
    wait_sum: u64 = 0,
    wait_min: ?u64 = null,
};

/// The §17.6.3 status code of a `$q_remove` from an empty queue.
pub const empty = 3;

/// The §17.6 queues, by `q_id`.
pub const Queues = std.AutoHashMapUnmanaged(i64, Queue);

/// A queue task's status and the values its output arguments take:
/// `$q_remove`'s job id and information (`out[0]`, `out[1]`), `$q_exam`'s
/// statistic (`out[1]`).
pub const QueueResult = struct { status: i64, out: [2]?i64 = .{ null, null } };

const Job = struct { id: i64, info: i64, arrived: u64 };

// Table 17-16's status codes.
const ok = 0;

const full = 1;

const undefined_id = 2;

const bad_type = 4;

const bad_length = 5;

const duplicate_id = 6;

/// Returns argument `e` as an integer, or null when it has an x or z bit.
pub fn int(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!?i64 {
    return (try evaluate.eval(self, a, e, 0)).asInt();
}

/// One queue task (§17.6.1-§17.6.3, §17.6.5): the status is the last
/// argument of all four, and is always written.
pub fn queueTask(self: *Run, a: std.mem.Allocator, op: QueueOp, args: []const Ast.ExprId) Error!void {
    const id = try int(self, a, args[0]);
    const in1: ?i64 = if (op == .initialize or op == .add or op == .exam) try int(self, a, args[1]) else null;
    const in2: ?i64 = if (op == .initialize or op == .add) try int(self, a, args[2]) else null;
    const r = try queueStep(&self.queues, self.arena, op, id, in1, in2, now(self));
    if (r.out[0]) |v| try evaluate.assignInt(self, a, args[1], v);
    if (r.out[1]) |v| try evaluate.assignInt(self, a, args[2], v);
    try evaluate.assignInt(self, a, args[3], r.status);
}

/// §17.6 queue task `op` on queue `id` at time `t` (the module's unit):
/// `in1`/`in2` are its second and third arguments where they are inputs,
/// each an integer or null for x/z. The one queue engine the interpreter
/// and a native executable share.
pub fn queueStep(queues: *Queues, gpa: std.mem.Allocator, op: QueueOp, id: ?i64, in1: ?i64, in2: ?i64, t: u64) std.mem.Allocator.Error!QueueResult {
    switch (op) {
        .initialize => {
            if (in1 != 1 and in1 != 2) return .{ .status = bad_type };
            if (in2 == null or in2.? <= 0) return .{ .status = bad_length };
            const entry = try queues.getOrPut(gpa, id orelse return .{ .status = undefined_id });
            if (entry.found_existing) return .{ .status = duplicate_id };
            entry.value_ptr.* = .{ .lifo = in1 == 2, .max = @intCast(in2.?) };
            return .{ .status = ok };
        },
        .add => {
            const q = queues.getPtr(id orelse return .{ .status = undefined_id }) orelse return .{ .status = undefined_id };
            if (q.jobs.items.len >= q.max) return .{ .status = full };
            if (q.last_arrival) |last| {
                q.interarrivals += 1;
                q.interarrival_sum += t - last;
            }
            q.last_arrival = t;
            try q.jobs.append(gpa, .{ .id = in1 orelse 0, .info = in2 orelse 0, .arrived = t });
            q.peak = @max(q.peak, q.jobs.items.len);
            return .{ .status = ok };
        },
        .remove => {
            const q = queues.getPtr(id orelse return .{ .status = undefined_id }) orelse return .{ .status = undefined_id };
            if (q.jobs.items.len == 0) return .{ .status = empty };
            const job = if (q.lifo) q.jobs.pop().? else q.jobs.orderedRemove(0);
            const wait = t - job.arrived;
            q.waits += 1;
            q.wait_sum += wait;
            q.wait_min = @min(q.wait_min orelse wait, wait);
            return .{ .status = ok, .out = .{ job.id, job.info } };
        },
        // §17.6.5 Table 17-15's statistics codes; any other is status 2
        // with no value (VD-050). The clause defines none of them further;
        // VerA computes what iverilog does (VD-052): the means truncate,
        // code 6 averages every job's wait so far, those that left and
        // those still queued, and a statistic with no population yet (no
        // second arrival, no job left, an empty queue) leaves q_stat_value
        // as it was.
        .exam => {
            const q = queues.getPtr(id orelse return .{ .status = undefined_id }) orelse return .{ .status = undefined_id };
            const value: ?u64 = switch (in1 orelse 0) {
                1 => q.jobs.items.len,
                2 => if (q.interarrivals == 0) null else q.interarrival_sum / q.interarrivals,
                3 => q.peak,
                4 => q.wait_min,
                5 => if (q.jobs.items.len == 0) null else longest: {
                    var w: u64 = 0;
                    for (q.jobs.items) |j| w = @max(w, t - j.arrived);
                    break :longest w;
                },
                6 => if (q.waits + q.jobs.items.len == 0) null else average: {
                    var sum = q.wait_sum;
                    for (q.jobs.items) |j| sum += t - j.arrived;
                    break :average sum / (q.waits + q.jobs.items.len);
                },
                else => return .{ .status = undefined_id },
            };
            return .{ .status = ok, .out = .{ null, if (value) |v| @intCast(v) else null } };
        },
    }
}

/// §17.6.4 `$q_full(q_id, status)`: 1 when the queue holds its maximum.
pub fn queueFull(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId) Error!i64 {
    const r = queueIsFull(&self.queues, try int(self, a, args[0]));
    try evaluate.assignInt(self, a, args[1], r.status);
    return r.full;
}

/// `$q_full` of queue `id`: its status and whether it holds its maximum.
pub fn queueIsFull(queues: *const Queues, id: ?i64) struct { status: i64, full: i64 } {
    const q = if (id) |i| queues.getPtr(i) else null;
    const found = q orelse return .{ .status = undefined_id, .full = 0 };
    return .{ .status = ok, .full = @intFromBool(found.jobs.items.len >= found.max) };
}

// ---- private ----

/// The simulation time in the module's unit, which §17.6's statistics are in.
fn now(self: *Run) u64 {
    return self.timeOf(self.scope).scale.unitsAt(self.scheduler.now);
}

test queueStep {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var qs: Queues = .empty;
    // Table 17-16: 4 an unsupported type, 5 a length that is not positive,
    // 2 an undefined q_id, 6 a q_id already in use, 0 OK.
    try std.testing.expectEqual(@as(i64, bad_type), (try queueStep(&qs, a, .initialize, 1, 3, 2, 0)).status);
    try std.testing.expectEqual(@as(i64, bad_type), (try queueStep(&qs, a, .initialize, 1, null, 2, 0)).status);
    try std.testing.expectEqual(@as(i64, bad_length), (try queueStep(&qs, a, .initialize, 1, 1, 0, 0)).status);
    try std.testing.expectEqual(@as(i64, undefined_id), (try queueStep(&qs, a, .initialize, null, 1, 2, 0)).status);
    try std.testing.expectEqual(@as(i64, ok), (try queueStep(&qs, a, .initialize, 1, 1, 2, 0)).status);
    try std.testing.expectEqual(@as(i64, duplicate_id), (try queueStep(&qs, a, .initialize, 1, 2, 5, 0)).status);
    // Two jobs arrive at 10 and 14; a third finds the FIFO full (status 1).
    try std.testing.expectEqual(@as(i64, ok), (try queueStep(&qs, a, .add, 1, 7, 70, 10)).status);
    try std.testing.expectEqual(@as(i64, ok), (try queueStep(&qs, a, .add, 1, 8, 80, 14)).status);
    try std.testing.expectEqual(@as(i64, full), (try queueStep(&qs, a, .add, 1, 9, 90, 15)).status);
    try std.testing.expectEqual(@as(i64, 1), queueIsFull(&qs, 1).full);
    // §17.6.5 Table 17-15 at t = 20: length 2, mean interarrival 4, peak 2,
    // no job has left (no shortest wait), longest wait 20 - 10, average
    // wait of the two queued (10 + 6) / 2 (iverilog's statistics).
    const Exam = struct { i64, ?i64 };
    for ([_]Exam{ .{ 1, 2 }, .{ 2, 4 }, .{ 3, 2 }, .{ 4, null }, .{ 5, 10 }, .{ 6, 8 } }) |e| {
        const r = try queueStep(&qs, a, .exam, 1, e[0], null, 20);
        try std.testing.expectEqual(@as(i64, ok), r.status);
        try std.testing.expectEqual(@as(?i64, e[1]), r.out[1]);
    }
    // FIFO: the first job out, having waited 20 - 10; then the second, 26 - 14.
    const first = try queueStep(&qs, a, .remove, 1, null, null, 20);
    try std.testing.expectEqual(@as(?i64, 7), first.out[0]);
    try std.testing.expectEqual(@as(?i64, 70), first.out[1]);
    const second = try queueStep(&qs, a, .remove, 1, null, null, 26);
    try std.testing.expectEqual(@as(?i64, 8), second.out[0]);
    // Shortest wait 10, mean wait (10 + 12) / 2 = 11.
    try std.testing.expectEqual(@as(?i64, 10), (try queueStep(&qs, a, .exam, 1, 4, null, 26)).out[1]);
    try std.testing.expectEqual(@as(?i64, 11), (try queueStep(&qs, a, .exam, 1, 6, null, 26)).out[1]);
    // An empty queue (3), an unknown statistic code (VD-050: 2) and an
    // unknown queue (2).
    try std.testing.expectEqual(@as(i64, empty), (try queueStep(&qs, a, .remove, 1, null, null, 30)).status);
    try std.testing.expectEqual(@as(i64, undefined_id), (try queueStep(&qs, a, .exam, 1, 9, null, 30)).status);
    try std.testing.expectEqual(@as(i64, undefined_id), (try queueStep(&qs, a, .remove, 5, null, null, 30)).status);
    try std.testing.expectEqual(@as(i64, undefined_id), queueIsFull(&qs, 5).status);
    // LIFO (type 2): the last job in is the first out.
    try std.testing.expectEqual(@as(i64, ok), (try queueStep(&qs, a, .initialize, 2, 2, 3, 0)).status);
    _ = try queueStep(&qs, a, .add, 2, 1, 0, 0);
    _ = try queueStep(&qs, a, .add, 2, 2, 0, 1);
    try std.testing.expectEqual(@as(?i64, 2), (try queueStep(&qs, a, .remove, 2, null, null, 2)).out[0]);
}

test "§17.6 queues: FIFO and LIFO order, capacity and the status codes" {
    try expectRun(
        \\module m;
        \\integer s, j, i, v;
        \\initial begin
        \\  $q_initialize(1, 1, 2, s); $write("%0d", s);
        \\  $q_initialize(1, 1, 2, s); $write("%0d", s);
        \\  $q_initialize(2, 2, 2, s); $q_initialize(3, 5, 2, s); $write("%0d", s);
        \\  $q_add(1, 7, 70, s); $q_add(1, 8, 80, s); $q_add(1, 9, 90, s); $write("%0d", s);
        \\  $q_add(2, 7, 70, s); $q_add(2, 8, 80, s);
        \\  v = $q_full(1, s); $write("%0d", v);
        \\  $q_remove(1, j, i, s); $write(" %0d/%0d", j, i);
        \\  $q_remove(2, j, i, s); $write(" %0d/%0d", j, i);
        \\  $q_exam(1, 3, v, s); $write(" %0d", v);
        \\  $q_remove(4, j, i, s); $display(" %0d", s);
        \\end
        \\endmodule
    , "06411 7/70 8/80 2 2\n");
}
