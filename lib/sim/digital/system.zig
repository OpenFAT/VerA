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

// ---- §17.6 stochastic analysis queues ---------------------------------------

/// The four §17.6 queue tasks; `$q_full` is a function (`SysFn.q_full`).
pub const QueueOp = enum { initialize, add, remove, exam };

const Job = struct { id: i64, info: i64, arrived: u64 };

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

// Table 17-16's status codes.
const ok = 0;
const full = 1;
const undefined_id = 2;
const empty = 3;
const bad_type = 4;
const bad_length = 5;
const duplicate_id = 6;

fn int(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!?i64 {
    return (try evaluate.eval(self, a, e, 0)).asInt();
}

/// The simulation time in the module's unit, which §17.6's statistics are in.
fn now(self: *Run) u64 {
    return self.timeOf(self.scope).scale.unitsAt(self.scheduler.now);
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

/// The §17.6 queues, by `q_id`.
pub const Queues = std.AutoHashMapUnmanaged(i64, Queue);

/// A queue task's status and the values its output arguments take:
/// `$q_remove`'s job id and information (`out[0]`, `out[1]`), `$q_exam`'s
/// statistic (`out[1]`).
pub const QueueResult = struct { status: i64, out: [2]?i64 = .{ null, null } };

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
        // with no value (VD-050).
        .exam => {
            const q = queues.getPtr(id orelse return .{ .status = undefined_id }) orelse return .{ .status = undefined_id };
            const value: u64 = switch (in1 orelse 0) {
                1 => q.jobs.items.len,
                2 => mean(q.interarrival_sum, q.interarrivals),
                3 => q.peak,
                4 => q.wait_min orelse 0,
                5 => longest: {
                    var w: u64 = 0;
                    for (q.jobs.items) |j| w = @max(w, t - j.arrived);
                    break :longest w;
                },
                6 => mean(q.wait_sum, q.waits),
                else => return .{ .status = undefined_id },
            };
            return .{ .status = ok, .out = .{ null, @intCast(value) } };
        },
    }
}

/// A §17.6.5 mean as an integer: §3.5.3 rounds a real to the nearest
/// integer "rather than by truncating it", ties away from zero (VD-052); 0
/// over an empty population.
fn mean(sum: u64, n: u64) u64 {
    return if (n == 0) 0 else (2 * sum + n) / (2 * n);
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

// ---- §17.9 probabilistic distribution functions -----------------------------

const rng = @import("kernels").rng_kernels;

/// §17.9.3 Table 17-17: `$random` and the seven `$dist_*` functions.
pub const Dist = enum { random, uniform, normal, exponential, poisson, chi_square, t, erlang };

/// A draw's value and the seed its inout argument is written back with.
pub const Draw = struct { value: i32, seed: i32 };

/// §17.9.3's `rtl_dist_*` over the listing's 32-bit `long` seed; `a` and `b`
/// are the arguments after the seed. Null where the listing prints its
/// "must have positive" warning instead of drawing: the value is 0 and the
/// seed is left as it was (§17.9.2: mean, degree_of_freedom and k_stage
/// "shall be greater than 0").
pub fn dist(f: Dist, seed: i32, a: i32, b: i32) ?Draw {
    const bad = switch (f) {
        .random, .uniform, .normal => false,
        .exponential, .poisson, .chi_square, .t => a <= 0,
        .erlang => a <= 0 or b <= 0,
    };
    if (bad) return null;
    const s: i64 = seed;
    const x: f64 = @floatFromInt(a);
    const y: f64 = @floatFromInt(b);
    // Each kernel is a pure function of the seed; its `Next` twin replays
    // the same draw for the written-back seed.
    const r: f64, const next: f64 = switch (f) {
        .random => .{ rng.zRngRand(s), rng.zRngRandNext(s) },
        .uniform => .{ rng.zRngIUniform(s, x, y), rng.zRngIUniformNext(s, x, y) },
        .normal => .{ rng.zRngNormal(s, x, y), rng.zRngNormalNext(s, x, y) },
        .exponential => .{ rng.zRngExponential(s, x), rng.zRngExponentialNext(s, x) },
        .poisson => .{ rng.zRngPoisson(s, x), rng.zRngPoissonNext(s, x) },
        .chi_square => .{ rng.zRngChiSquare(s, x), rng.zRngChiSquareNext(s, x) },
        .t => .{ rng.zRngT(s, x), rng.zRngTNext(s, x) },
        .erlang => .{ rng.zRngErlang(s, x, y), rng.zRngErlangNext(s, x, y) },
    };
    // The listing's `(long)(r + 0.5)`, mirrored for a negative r; the
    // integer-valued draws are unchanged by it.
    const m = @trunc(@abs(r) + 0.5);
    return .{ .value = std.math.lossyCast(i32, if (r >= 0) m else -m), .seed = @intFromFloat(next) };
}

/// The seed or integer argument `e` as the listing's 32-bit `long`: its
/// low 32 bits, 0 when it holds an x or z bit.
fn long(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!i32 {
    return @truncate(try int(self, a, e) orelse 0);
}

/// §17.9 one call of `$random` or a `$dist_*` function. A seed argument is
/// read and written back (§17.9.1, §17.9.2: "an inout argument"); a
/// seedless `$random` advances `Run.random_seed`.
pub fn random(self: *Run, a: std.mem.Allocator, f: Dist, args: []const Ast.ExprId, tok: u32) Error!i32 {
    if (args.len == 0) {
        const d = dist(.random, self.random_seed, 0, 0).?;
        self.random_seed = d.seed;
        return d.value;
    }
    const seed = try long(self, a, args[0]);
    const x = if (args.len > 1) try long(self, a, args[1]) else 0;
    const y = if (args.len > 2) try long(self, a, args[2]) else 0;
    const d = dist(f, seed, x, y) orelse {
        const start = self.starts[@min(tok, self.starts.len - 1)];
        try self.bag.add(self.stage(), .W1151, .{ .start = start, .end = start }, dist_warning, .{});
        return 0;
    };
    try evaluate.assignInt(self, a, args[0], d.seed);
    return d.value;
}

/// The text of the listing's `print_error` for a non-positive argument.
pub const dist_warning = "a $dist_ mean, degree of freedom or k_stage is not positive: the result is 0 and the seed is unchanged";

// ---- §17.2 file input and output --------------------------------------------

const contract = @import("contract");
const fk = @import("kernels").file_kernels;

/// This engine's own descriptor table: `file_kernels`, the table the analog
/// devices run, so both engines answer §17.2 one way (IEEE 1364-2005 §17.2.1's
/// encodings: an mcd's bit 0 is standard output, an fd has bit 31 set and
/// 0..2 are the standard streams).
pub const own: contract.FileIo = .{ .open = fk.zFOpen, .close = fk.zFClose, .put = fk.zFPut, .getc = fk.zFGetc, .ungetc = fk.zFUngetc, .tell = fk.zFTell, .seek = fk.zFSeek, .eof = fk.zFEof, .err = fk.zFError };

/// VAMS §9.5.1.2: one descriptor table per simulation, the host's
/// (`Run.file_io`: a mixed simulation's device table), else this engine's
/// own, which only an engine given filesystem access (`Options.io`) opens
/// files through.
fn table(self: *Run) ?contract.FileIo {
    return self.file_io orelse if (self.io != null) own else null;
}

/// The §17.2 functions an expression can call.
pub const FileFn = enum { fopen, fgetc, ungetc, fgets, fscanf, fread, ftell, fseek, rewind, feof, ferror, sscanf };

/// The characters an operand holds (§17.1.1.7's reading: 8 bits each, leading
/// NULs dropped), or null when any bit is x or z.
pub fn text(a: std.mem.Allocator, v: Int.Literal) Error!?[]const u8 {
    if (v.hasUnknown()) return null;
    const bytes = (v.width + 7) / 8;
    var out: std.ArrayList(u8) = .empty;
    var n = bytes;
    while (n != 0) {
        n -= 1;
        // A byte never straddles a word; the bits above `width` are 0.
        const c: u8 = @truncate(v.values()[n / 8] >> @intCast(n % 8 * 8));
        if (c == 0 and out.items.len == 0) continue;
        try out.append(a, c);
    }
    return out.items;
}

/// A descriptor is "a 32-bit value" (§17.2.1): its low 32 bits, however the
/// variable holding it is signed (`integer fd` is the clause's own example).
fn descriptor(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!?i64 {
    return low32(try int(self, a, e));
}

fn low32(d: ?i64) ?i64 {
    return (d orelse return null) & 0xffff_ffff;
}

/// One §17.2 function call; every one of them returns an integer.
pub fn fileCall(self: *Run, a: std.mem.Allocator, f: FileFn, args: []const Ast.ExprId) Error!i64 {
    if (f == .sscanf) return scanCall(self, a, args);
    const t = table(self) orelse return switch (f) {
        .fopen, .fgets, .fread, .ferror => 0,
        else => -1, // else: EOF, the error answer of the rest
    };
    switch (f) {
        .fopen => {
            const name = try text(a, try evaluate.eval(self, a, args[0], 0));
            const mode = if (args.len == 1) null else try text(a, try evaluate.eval(self, a, args[1], 0));
            return fopen(t, a, self.file_name, name, mode, args.len == 1);
        },
        .fgets => return fgets(self, a, t, args),
        .fscanf => return fscanf(self, a, t, args),
        .fread => return fread(self, a, t, args),
        // §17.2.7: the code, and its description in `str`, cleared when 0.
        .ferror => {
            const code = if (t.err) |err| err((try descriptor(self, a, args[0])) orelse 0) else 0;
            try evaluate.assign(self, a, args[1], try evaluate.stringLiteral(a, fk.zFErrorStr(code, 0)));
            return code;
        },
        else => {}, // else: `fileOp`'s
    }
    var v: [3]?i64 = .{ null, null, null };
    for (args, 0..) |arg, i| v[i] = try int(self, a, arg);
    return fileOp(t, f, v[0], v[1], v[2]);
}

/// §17.2.1 `$fopen(name)` (`mcd`) or `$fopen(name, type)` on the table `t`
/// of a source `file_name`: no type opens for writing and returns a
/// multichannel descriptor, one bit above bit 0; a Table 17-7 type returns
/// a file descriptor. 0 when the file cannot be opened, or `name` or `mode`
/// is null (an x or z bit).
pub fn fopen(t: contract.FileIo, a: std.mem.Allocator, file_name: []const u8, name: ?[]const u8, mode: ?[]const u8, mcd: bool) std.mem.Allocator.Error!i64 {
    const path = name orelse return 0;
    const ty = if (mcd) "w" else mode orelse return 0;
    if (!fileType(ty)) return 0;
    // A file read is looked for beside the source first, as `$readmemh`
    // looks (`display.sideFile`).
    if (ty[0] == 'r') if (std.Io.Dir.path.dirname(file_name)) |dir| {
        const d = t.open(try std.Io.Dir.path.join(a, &.{ dir, path }), ty, mcd);
        if (d != 0) return d;
    };
    return t.open(path, ty, mcd);
}

/// Is `ty` one of §17.2.1 Table 17-7's file types? The list is lowering's
/// too (`kernels.fopen_types`).
pub fn fileType(ty: []const u8) bool {
    return @import("kernels").fopen_types.has(ty);
}

/// §17.2.4.1 / §17.2.4.2 / §17.2.5 / §17.2.8 on the table `t`, C's
/// semantics: `x`, `y`, `z` are the call's arguments in order, null where an
/// argument has an x or z bit (or is absent). EOF (-1) for an unknown one.
pub fn fileOp(t: contract.FileIo, f: FileFn, x: ?i64, y: ?i64, z: ?i64) i64 {
    const eof: i64 = -1;
    switch (f) {
        .fgetc => return t.getc(low32(x) orelse return eof),
        .ungetc => return t.ungetc(x orelse return eof, low32(y) orelse return eof),
        .ftell => return t.tell(low32(x) orelse return eof),
        // §17.2.5: whence 0 from the start, 1 from here, 2 from the end.
        .fseek, .rewind => {
            const d = low32(x) orelse return eof;
            if (f == .rewind) return t.seek(d, 0, 0);
            const offset = y orelse return eof;
            const whence = z orelse return eof;
            if (whence < 0 or whence > 2) return eof;
            return t.seek(d, offset, whence);
        },
        .feof => return t.eof(low32(x) orelse return eof),
        .fopen, .sscanf, .fgets, .fscanf, .fread, .ferror => unreachable, // `fileCall`'s own
    }
}

/// §17.2.4.2 `$fgets(str, fd)`: characters into `str` "until str is filled,
/// or a newline character is read and transferred to str, or an EOF
/// condition is encountered"; a partial top byte of `str` holds none. The
/// count, 0 when nothing was read (and `str` is left alone).
fn fgets(self: *Run, a: std.mem.Allocator, t: contract.FileIo, args: []const Ast.ExprId) Error!i64 {
    const d = (try descriptor(self, a, args[1])) orelse return 0;
    const room = (try evaluate.targetType(self, args[0])).width / 8;
    const line = try readLine(a, t, d, room);
    if (line.len != 0) try evaluate.assign(self, a, args[0], try evaluate.stringLiteral(a, line));
    return @intCast(line.len);
}

/// §17.2.4.2's byte read, shared by the interpreter and emitted executable.
/// Include the newline, respect the destination's complete-byte capacity,
/// and return no bytes on EOF/error so the caller leaves its target alone.
pub fn readLine(a: std.mem.Allocator, t: contract.FileIo, d: i64, room: u32) std.mem.Allocator.Error![]const u8 {
    var line: std.ArrayList(u8) = .empty;
    while (line.items.len < room) {
        const c = t.getc(d);
        if (c < 0) break;
        try line.append(a, @intCast(c));
        if (c == '\n') break;
    }
    return line.items;
}

/// §17.2.4.3 `$fscanf(fd, format, args...)`: `$sscanf` over the file from its
/// position, which then stands after the characters the scan used: "the
/// offending input character is left unread in the input stream".
fn fscanf(self: *Run, a: std.mem.Allocator, t: contract.FileIo, args: []const Ast.ExprId) Error!i64 {
    const d = (try descriptor(self, a, args[0])) orelse return -1;
    const format = try text(a, try evaluate.eval(self, a, args[1], 0));
    var file = try fileScan(a, t, d, format, args.len - 2);
    try scanContext(self, a, &file.scan, args[2..]);
    try scanAssign(self, a, &file.scan, args[2..]);
    return finishFileScan(t, file, file.scan);
}

/// §17.2.4.3's input snapshot and original descriptor position. The native
/// executable and interpreter use the same scanner and restore only the
/// consumed prefix, so a failed conversion leaves the offending byte unread.
/// `pushed`: how many of the input's first bytes are §17.2.4.1 pushback
/// that differs from the file under it, which a reposition would lose.
pub const FileScan = struct { scan: Scan, descriptor: ?i64 = null, start: i64 = 0, input_len: usize = 0, pushed: usize = 0 };

/// Starts a `$fscanf` on descriptor `descriptor_`: the rest of the file is
/// read into `a` and the descriptor left at its end until `finishFileScan`
/// puts it back. A null, x or unreadable descriptor scans no input (EOF).
pub fn fileScan(a: std.mem.Allocator, t: contract.FileIo, descriptor_: ?i64, format: ?[]const u8, outs: usize) std.mem.Allocator.Error!FileScan {
    const no_input: FileScan = .{ .scan = .init(null, format, outs) };
    const d = low32(descriptor_) orelse return no_input;
    const start = t.tell(d);
    if (start < 0) return no_input;
    // ponytail: reads the rest of the file per call; a streaming scan when a
    // model reads large files this way.
    var rest: std.ArrayList(u8) = .empty;
    while (true) {
        const c = t.getc(d);
        if (c < 0) break;
        try rest.append(a, @intCast(c));
    }
    // `$ungetc`'s characters came first (VD-084). The file's own bytes under
    // them (at most 16, `file_kernels.ZFSlot.back`) tell which ones
    // `finishFileScan` must push back after it repositions.
    _ = t.seek(d, start, 0);
    var pushed: usize = 0;
    for (rest.items[0..@min(rest.items.len, 16)], 0..) |c, i| {
        if (t.getc(d) != c) pushed = i + 1;
    }
    return .{ .scan = .init(rest.items, format, outs), .descriptor = d, .start = start, .input_len = rest.items.len, .pushed = pushed };
}

/// Ends a `fileScan`: the descriptor is repositioned just past what `scan`
/// consumed, and `$fscanf`'s value (`Scan.result`) returned. Must follow
/// every `fileScan` whose descriptor was readable.
pub fn finishFileScan(t: contract.FileIo, file: FileScan, scan: Scan) i64 {
    const d = file.descriptor orelse return scan.result;
    if (scan.at < file.pushed) {
        // The pushback the scan left unread stays the next input.
        _ = t.seek(d, file.start + @as(i64, @intCast(file.pushed)), 0);
        var k = file.pushed;
        while (k > scan.at) {
            k -= 1;
            _ = t.ungetc(scan.input[k], d);
        }
        return scan.result;
    }
    _ = t.seek(d, file.start + @as(i64, @intCast(scan.at)), 0);
    // A scan that ran to the end of the input met EOF (§17.2.8), which the
    // repositioning cleared.
    if (scan.at == file.input_len) _ = t.getc(d);
    return scan.result;
}

/// §17.2.4.4 `$fread(myreg, fd)` / `$fread(mem, fd, start, count)`: whole
/// words of ceil(width/8) bytes each, the first byte the most significant;
/// a memory from `start` (default its lowest address) for at most `count`
/// words (default to its end). The count of characters read, 0 on none.
fn fread(self: *Run, a: std.mem.Allocator, t: contract.FileIo, args: []const Ast.ExprId) Error!i64 {
    const d = (try descriptor(self, a, args[1])) orelse return 0;
    const ex = &self.file.exprs;
    const base = if (ex.tag(args[0]) == .ident) try self.slot(args[0]) else 0;
    const arr = (if (ex.tag(args[0]) == .ident) self.arrays.get(base) else null) orelse {
        const width = (try evaluate.targetType(self, args[0])).width;
        const w = try readWord(a, t, d, width);
        if (w.value) |v| try evaluate.assign(self, a, args[0], v);
        return w.n;
    };
    var at = if (args.len > 2 and args[2] != .none) (try int(self, a, args[2])) orelse return 0 else arr.low;
    var left = if (args.len > 3) (try int(self, a, args[3])) orelse return 0 else std.math.maxInt(i64);
    var read: i64 = 0;
    while (at >= arr.low and at <= arr.high and left > 0) {
        const w = try readWord(a, t, d, self.values[base].width);
        read += w.n;
        try waiters.store(self, base + @as(u32, @intCast(at - arr.low)), (w.value orelse break).planes);
        if (at == arr.high) break;
        at += 1;
        left -= 1;
    }
    return read;
}

/// One `$fread` word: ceil(width/8) characters, big-endian, into `width`
/// bits; the value is null when the file ends first. `n` is the characters
/// read.
pub fn readWord(a: std.mem.Allocator, t: contract.FileIo, d: i64, width: u32) Error!struct { value: ?Int.Literal, n: i64 } {
    const bytes = (width + 7) / 8;
    const v = try filled(a, width, false, .zero);
    for (0..bytes) |k| {
        const c = t.getc(d);
        if (c < 0) return .{ .value = null, .n = @intCast(k) };
        const lo = (bytes - 1 - k) * 8;
        v.values()[lo / 64] |= @as(u64, @intCast(c)) << @intCast(lo % 64);
    }
    // The top byte's bits above `width` are dropped.
    const top = v.values().len - 1;
    v.values()[top] &= wordMask(width, top);
    return .{ .value = v, .n = bytes };
}

/// §17.2.7 `$fclose` of a file descriptor, or of every file a multichannel
/// descriptor's bits name.
pub fn fclose(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId) Error!void {
    const d = (try descriptor(self, a, args[0])) orelse return;
    display.cancelFile(self, d);
    if (table(self)) |t| _ = t.close(d);
}

/// §17.2.2 `$fdisplay`/`$fwrite` and their radix forms: the `$display` text
/// of the arguments after the descriptor, to every channel it names.
pub fn fdisplay(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId, show: display.Show) Error!void {
    const d = (try descriptor(self, a, args[0])) orelse return;
    return fdisplayTo(self, a, d, args, show);
}

/// `fdisplay` to descriptor `d`, already read from `args[0]`.
pub fn fdisplayTo(self: *Run, a: std.mem.Allocator, d: i64, args: []const Ast.ExprId, show: display.Show) Error!void {
    var sh = show;
    sh.file = false;
    var buf: std.Io.Writer.Allocating = .init(a);
    const saved = self.out;
    self.out = &buf.writer;
    defer self.out = saved;
    try display.display(self, args[1..], a, sh);
    self.out = saved;
    if (try channels(table(self), self.io, self.out, d, buf.written())) {
        const start = self.starts[@min(self.file.exprs.mainTok(args[0]), self.starts.len - 1)];
        try self.bag.add(self.stage(), .W1154, .{ .start = start, .end = start }, unwritten, .{});
    }
}

/// The W1154 text.
pub const unwritten = "no file this descriptor names is open for writing: the output is not written";

/// `bytes` to every channel descriptor `d` names: bit 0 of an mcd and fd 1
/// (STDOUT) are the transcript `out`; fd 2 is STDERR; every other channel
/// is the table's. True when the table's channels took none of `bytes`:
/// each is closed (§17.2.1: `$fclose` "does not allow any further output to
/// the closed channels") or not open for writing.
pub fn channels(t: ?contract.FileIo, io: ?std.Io, out: *std.Io.Writer, d: i64, bytes: []const u8) std.Io.Writer.Error!bool {
    const fd = d & (@as(i64, 1) << 31) != 0;
    const ch = d & 0x7fff_ffff;
    if ((fd and ch == 1) or (!fd and d & 1 != 0)) try out.writeAll(bytes);
    if (fd and ch == 2) if (io) |i| std.Io.File.stderr().writeStreamingAll(i, bytes) catch {};
    const files = if (fd) (if (ch > 2) d else 0) else d & ~@as(i64, 1);
    if (files == 0 or bytes.len == 0) return false;
    const tt = t orelse return false;
    return tt.put(files, bytes) == 0;
}

/// §17.2.4.3 `$sscanf(str, format, args...)` in the interpreter (`Scan`).
fn scanCall(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId) Error!i64 {
    const input = try text(a, try evaluate.eval(self, a, args[0], 0));
    const format = try text(a, try evaluate.eval(self, a, args[1], 0));
    var sc: Scan = .init(input, format, args.len - 2);
    try scanContext(self, a, &sc, args[2..]);
    try scanAssign(self, a, &sc, args[2..]);
    return sc.result;
}

/// What `%u`/`%z` (the output widths) and `%t` (the time scale) read.
fn scanContext(self: *Run, a: std.mem.Allocator, sc: *Scan, outs: []const Ast.ExprId) Error!void {
    const widths = try a.alloc(u32, outs.len);
    for (outs, widths) |e, *w| w.* = (try evaluate.targetType(self, e)).width;
    sc.widths = widths;
    sc.time = .{ .units = self.time_format.units, .precision = self.time_format.precision, .unit_exp = self.timeOf(self.scope).unit_exp };
}

fn scanAssign(self: *Run, a: std.mem.Allocator, sc: *Scan, outs: []const Ast.ExprId) Error!void {
    while (sc.next()) |x| switch (x.value) {
        .bits => |b| {
            const v = try filled(a, 64, true, .zero);
            v.values()[0] = b[0];
            v.unknowns()[0] = b[1];
            try evaluate.assign(self, a, outs[x.arg], v);
        },
        .chars => |c| try evaluate.assign(self, a, outs[x.arg], try evaluate.stringLiteral(a, c)),
        .real => |r| try evaluate.assignReal(self, a, outs[x.arg], r),
    };
}

/// §17.2.4.3 `$sscanf(str, format, args...)`: C's scanf over the characters
/// of `str`. Each `next` is one assignment to an output argument, in order;
/// once it returns null, `result` is how many were assigned, or EOF (-1)
/// when the input ends before the first conversion, and (the clause's own
/// rule) when either `str` or `format` has an x or z bit (null here).
/// A conversion is `%`, an optional `*` (match, do not assign or count), an
/// optional maximum field width, and one of %b %o %d %h %x %c %s %f %e %g.
pub const Scan = struct {
    // ponytail: %v %m stop the scan; add them when a source reads them.
    input: []const u8,
    format: []const u8,
    /// Output arguments the call has.
    outs: usize,
    at: usize = 0,
    i: usize = 0,
    result: i64 = 0,
    done: bool = false,
    /// §17.2.4.3 `%u`/`%z` read "sufficient data from the input to fill the
    /// target reg": each output argument's width in bits. Without one, or
    /// past 64 bits, the conversion stops the scan.
    widths: []const u32 = &.{},
    /// §17.2.4.3 `%t`'s scale; null stops the scan at a `%t`.
    time: ?Time = null,

    /// `$timeformat`'s units and precision and the module's time unit, all
    /// as the exponents (precision: digits) §17.3.2 gives them.
    pub const Time = struct {
        units: i32,
        precision: u32,
        unit_exp: i32,

        /// "The value matched is then scaled and rounded according to the
        /// current time scale as set by $timeformat": `v` in $timeformat's
        /// units, rounded to its precision, in the module's time unit
        /// (the clause's example: 10.345 at -3, 2 is 10350000.0 in 1ns).
        pub fn scale(t: Time, v: f64) f64 {
            const p: i32 = @intCast(t.precision);
            return @round(v * std.math.pow(f64, 10, @floatFromInt(p))) * std.math.pow(f64, 10, @floatFromInt(t.units - p - t.unit_exp));
        }
    };

    /// Output argument `arg` (0 = the first after the format) takes a 64-bit
    /// 4-state value (`bits`: value and unknown planes, signed), characters
    /// (`%s`, `%c`) or a real (`%f %e %g`).
    pub const Assign = struct { arg: usize, value: union(enum) { bits: [2]u64, chars: []const u8, real: f64 } };

    /// The scan of `input` by `format`; a null one ends it at once with EOF.
    pub fn init(input: ?[]const u8, format: ?[]const u8, outs: usize) Scan {
        if (input == null or format == null) return .{ .input = "", .format = "", .outs = outs, .result = -1, .done = true };
        return .{ .input = input.?, .format = format.?, .outs = outs };
    }

    fn stop(self: *Scan, eof: bool) ?Assign {
        if (eof and self.result == 0) self.result = -1;
        self.done = true;
        return null;
    }

    /// The next assignment, or null once the scan is over and `result` is
    /// final. Null for good after the first null.
    pub fn next(self: *Scan) ?Assign {
        if (self.done) return null;
        const input = self.input;
        const format = self.format;
        while (self.i < format.len) : (self.i += 1) {
            const c = format[self.i];
            if (std.ascii.isWhitespace(c)) {
                while (self.at < input.len and std.ascii.isWhitespace(input[self.at])) self.at += 1;
                continue;
            }
            if (c != '%' or self.i + 1 == format.len) {
                if (self.at >= input.len) return self.stop(true);
                if (input[self.at] != c) return self.stop(false);
                self.at += 1;
                continue;
            }
            self.i += 1;
            if (format[self.i] == '%') {
                if (self.at >= input.len or input[self.at] != '%') return self.stop(false);
                self.at += 1;
                continue;
            }
            const suppress = format[self.i] == '*';
            if (suppress) self.i += 1;
            var width: usize = 0;
            while (self.i < format.len and std.ascii.isDigit(format[self.i])) : (self.i += 1) width = width *| 10 +| (format[self.i] - '0');
            if (self.i == format.len) return self.stop(false);
            const conv = std.ascii.toLower(format[self.i]);
            // §17.2.4.3 `%u`/`%z` match binary data, whose bytes may be white space.
            if (conv == 'u' or conv == 'z') {
                if (suppress or width != 0) return self.stop(false);
                const arg: usize = @intCast(self.result);
                if (arg >= self.widths.len or arg >= self.outs) return self.stop(false);
                const bits = unformatted(input[self.at..], self.widths[arg], conv == 'z') orelse return self.stop(true);
                self.at += @intCast(bits[2]);
                self.i += 1;
                self.result += 1;
                return .{ .arg = arg, .value = .{ .bits = .{ bits[0], bits[1] } } };
            }
            if (conv != 'c') while (self.at < input.len and std.ascii.isWhitespace(input[self.at])) : (self.at += 1) {};
            if (self.at >= input.len) return self.stop(true);
            // "it extends to the next inappropriate character or until the
            // maximum field width, if one is specified, is exhausted".
            const field = input[self.at..if (width == 0) input.len else @min(input.len, self.at + width)];
            const n, const value: @FieldType(Assign, "value") = switch (conv) {
                'c' => .{ 1, .{ .bits = .{ field[0], 0 } } },
                's' => blk: {
                    const len = std.mem.findAny(u8, field, &std.ascii.whitespace) orelse field.len;
                    break :blk .{ len, .{ .chars = field[0..len] } };
                },
                'd', 'h', 'x', 'o', 'b' => number(field, conv) orelse return self.stop(false),
                'f', 'e', 'g' => float(field) orelse return self.stop(false),
                't' => blk: {
                    const t = self.time orelse return self.stop(false);
                    const n, const v = float(field) orelse return self.stop(false);
                    break :blk .{ n, .{ .real = t.scale(v.real) } };
                },
                else => return self.stop(false),
            };
            self.at += n;
            if (suppress) continue;
            const arg: usize = @intCast(self.result);
            if (arg >= self.outs) return self.stop(false);
            self.i += 1;
            self.result += 1;
            return .{ .arg = arg, .value = value };
        }
        return self.stop(false);
    }

    /// §17.2.4.3 `%u` (`four` false) / `%z` of a `width`-bit target: 32-bit
    /// words, the least significant first, each little-endian (the native
    /// order of every target VerA builds for); a `%z` word is §27.14's
    /// s_vpi_vecval, aval then bval. The value and unknown planes and the
    /// bytes used, or null when `input` ends first or `width` passes 64.
    fn unformatted(input: []const u8, width: u32, four: bool) ?[3]u64 {
        if (width > 64) return null;
        const words: usize = @max(1, (width + 31) / 32);
        const per: usize = if (four) 8 else 4;
        if (input.len < words * per) return null;
        var v: u64 = 0;
        var u: u64 = 0;
        for (0..words) |k| {
            const w = input[k * per ..][0..per];
            v |= @as(u64, std.mem.readInt(u32, w[0..4], .little)) << @intCast(32 * k);
            if (four) u |= @as(u64, std.mem.readInt(u32, w[4..8], .little)) << @intCast(32 * k);
        }
        return .{ v, u, words * per };
    }

    /// The characters of `field` one integral conversion matches, and their
    /// value, or null on a matching failure. `%d` is an optional sign and
    /// decimal digits, or a single x, z or ?; the others take their radix's
    /// digits and x, z, ?, which give §3.5.1's bits (an x or z leftmost pads
    /// the value with itself). `_` separates digits in every radix.
    fn number(field: []const u8, conv: u8) ?struct { usize, @FieldType(Assign, "value") } {
        if (conv == 'd') {
            const neg = field[0] == '-';
            const sign: usize = @intFromBool(neg or field[0] == '+');
            if (sign == 0) switch (std.ascii.toLower(field[0])) {
                'x' => return .{ 1, .{ .bits = .{ ~@as(u64, 0), ~@as(u64, 0) } } },
                'z', '?' => return .{ 1, .{ .bits = .{ 0, ~@as(u64, 0) } } },
                else => {},
            };
            var n = sign;
            var acc: u64 = 0;
            while (n < field.len and (std.ascii.isDigit(field[n]) or field[n] == '_')) : (n += 1) {
                if (field[n] != '_') acc = acc *% 10 +% (field[n] - '0');
            }
            if (std.mem.findNone(u8, field[sign..n], "_") == null) return null;
            return .{ n, .{ .bits = .{ if (neg) 0 -% acc else acc, 0 } } };
        }
        const per: u6 = switch (conv) {
            'b' => 1,
            'o' => 3,
            else => 4, // else: 'h' and 'x'
        };
        var n: usize = 0;
        var v: u64 = 0;
        var u: u64 = 0;
        var top: ?[2]u64 = null;
        const ones = (@as(u64, 1) << per) - 1;
        while (n < field.len) : (n += 1) {
            const ch = std.ascii.toLower(field[n]);
            if (ch == '_') continue;
            const digit: [2]u64 = switch (ch) {
                'x' => .{ ones, ones },
                'z', '?' => .{ 0, ones },
                else => .{ (std.fmt.charToDigit(ch, @as(u8, 1) << @intCast(per)) catch break), 0 },
            };
            top = top orelse digit;
            v = v << per | digit[0];
            u = u << per | digit[1];
        }
        const first = top orelse return null;
        // §3.5.1: an unknown leftmost digit pads to the left with itself.
        if (first[1] != 0) {
            var bits: u32 = 0;
            for (field[0..n]) |ch| bits += if (ch == '_') 0 else per;
            if (bits < 64) {
                const pad = ~@as(u64, 0) << @intCast(bits);
                u |= pad;
                if (first[0] != 0) v |= pad;
            }
        }
        return .{ n, .{ .bits = .{ v, u } } };
    }

    /// "Matches a floating point number": C's sign, digits, fraction and
    /// exponent.
    fn float(field: []const u8) ?struct { usize, @FieldType(Assign, "value") } {
        var n: usize = @intFromBool(field[0] == '+' or field[0] == '-');
        var digits: usize = 0;
        while (n < field.len and std.ascii.isDigit(field[n])) : (n += 1) digits += 1;
        if (n < field.len and field[n] == '.') {
            n += 1;
            while (n < field.len and std.ascii.isDigit(field[n])) : (n += 1) digits += 1;
        }
        if (digits == 0) return null;
        if (n < field.len and (field[n] == 'e' or field[n] == 'E')) {
            var k = n + 1;
            if (k < field.len and (field[k] == '+' or field[k] == '-')) k += 1;
            if (k < field.len and std.ascii.isDigit(field[k])) {
                while (k < field.len and std.ascii.isDigit(field[k])) k += 1;
                n = k;
            }
        }
        return .{ n, .{ .real = std.fmt.parseFloat(f64, field[0..n]) catch return null } };
    }
};

/// §17.2.3 `$swrite` (`show` set: `$fwrite`'s text) / `$sformat` (null:
/// `display.sformat`'s) of the arguments after the first, assigned to the
/// first "using the string assignment to variable rules".
pub fn sformat(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId, show: ?display.Show) Error!void {
    var buf: std.Io.Writer.Allocating = .init(a);
    const saved = self.out;
    self.out = &buf.writer;
    defer self.out = saved;
    if (show) |sh| try display.display(self, args[1..], a, sh) else try display.sformat(self, args[1..], a);
    self.out = saved;
    try evaluate.assign(self, a, args[0], try evaluate.stringLiteral(a, buf.written()));
}

// ---- §17.5 programmable logic arrays ----------------------------------------

/// One of §17.5's sixteen PLA tasks: `$async$and$array` and the rest. The
/// logic is applied to each personality row's selected inputs.
pub const Pla = struct {
    logic: enum { @"and", @"or", nand, nor },
    /// `plane` (§17.5.4): 0 selects the complement, 1 the input, x an
    /// unknown term (`plaEval`), z/? nothing.
    /// `array`: 1 selects the input, 0 nothing.
    plane: bool,
    /// `async` re-evaluates whenever an input or the personality changes.
    async_: bool,
};

/// The sixteen §17.5 PLA task names, each with its `Pla`.
pub const pla_tasks = blk: {
    var list: [16]struct { []const u8, Pla } = undefined;
    var n = 0;
    for (.{ "async", "sync" }) |timing| for (.{ "and", "or", "nand", "nor" }) |logic| for (.{ "array", "plane" }) |form| {
        list[n] = .{ "$" ++ timing ++ "$" ++ logic ++ "$" ++ form, .{
            .logic = @field(@FieldType(Pla, "logic"), logic),
            .plane = std.mem.eql(u8, form, "plane"),
            .async_ = std.mem.eql(u8, timing, "async"),
        } };
        n += 1;
    };
    break :blk list;
};

/// §17.5 one evaluation in the interpreter (`plaEval`).
pub fn pla(self: *Run, a: std.mem.Allocator, p: Pla, args: []const Ast.ExprId) Error!void {
    const base = try self.slot(args[0]);
    const arr = self.arrays.get(base).?; // compile proved it is an array
    const in = try evaluate.eval(self, a, args[1], 0);
    const out = try filled(a, (try evaluate.targetType(self, args[2])).width, false, .x);
    plaEval(p, self.values[base..][0..arr.count], in, out);
    try evaluate.assign(self, a, args[2], out);
}

/// §17.5 one evaluation into `out`, which starts all x: row k of the
/// personality `rows` (lowest address first) computes output bit k; within
/// a row, bit j of the personality governs input j, both counted from the
/// left. An unknown input selected by a row makes it unknown unless the
/// row's controlling value decides it.
pub fn plaEval(p: Pla, rows: []const Int.Literal, in: Int.Literal, out: Int.Literal) void {
    // ponytail: rows are taken lowest address first, which is the declaration
    // order of the ascending memories §17.5's examples use.
    const and_like = p.logic == .@"and" or p.logic == .nand;
    for (0..@min(rows.len, out.width)) |k| {
        const row = rows[k];
        var unknown = false;
        var decided = false;
        for (0..@min(row.width, in.width)) |j| {
            const sel = row.bit(@intCast(row.width - 1 - j));
            var b = in.bit(@intCast(in.width - 1 - j));
            if (p.plane) {
                // x is "the worst case of the input value": it may be
                // the true or the complemented input, which differ for
                // every input value, so the term is x. z is "do-not-care".
                if (sel == .zero) b = switch (b) {
                    .zero => .one,
                    .one => .zero,
                    else => .x,
                } else if (sel == .x) b = .x else if (sel != .one) continue;
            } else if (sel == .zero) continue else if (sel != .one) b = .x;
            // `and` is decided by a 0, `or` by a 1.
            if (b == (if (and_like) Int.Bit.zero else Int.Bit.one)) decided = true;
            if (b == .x or b == .z) unknown = true;
        }
        const value: Int.Bit = if (decided) (if (and_like) .zero else .one) else if (unknown) .x else (if (and_like) .one else .zero);
        const inverted = p.logic == .nand or p.logic == .nor;
        setBit(out, @intCast(out.width - 1 - k), if (!inverted) value else switch (value) {
            .zero => .one,
            .one => .zero,
            else => .x,
        });
    }
}

// ---- tests ------------------------------------------------------------------

test "§17.2.4.3 $sscanf: conversions, a mismatch stops, unknown input is EOF" {
    try expectRun(
        \\module m;
        \\integer n, a, b; reg [15:0] w;
        \\initial begin
        \\  n = $sscanf("12 ff z", "%d %h %s", a, b, w); $write("%0d %0d %0d %s ", n, a, b, w);
        \\  n = $sscanf("7-8", "%d+%d", a, b); $write("%0d %0d ", n, a);
        \\  n = $sscanf(16'h31xx, "%d", a); $display("%0d", n);
        \\end
        \\endmodule
    , "3 12 255 z 1 7 -1\n");
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

test "§17.5 a synchronous PLA evaluates only when called, an asynchronous one tracks" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\reg [1:2] mem [1:2]; reg [1:2] in; reg [1:2] s, y;
        \\initial begin
        \\  mem[1] = 2'b11; mem[2] = 2'b10; in = 2'b10;
        \\  $sync$or$array(mem, in, s); $async$nand$plane(mem, in, y);
        \\  #1 in = 2'b01; #1 $display("%b %b", s, y);
        \\end
        \\endmodule
    , "11 11\n");
}

test "§17.9.1 a seedless $random is the listing's stream from seed 0" {
    try expectRun(
        \\module m;
        \\integer a, b;
        \\initial begin a = $random; b = $random; $display("%0d %0d", a, b); end
        \\endmodule
    , "303379748 -1064739199\n");
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
    // no wait yet (0 shortest, 0 mean), longest wait 20 - 10.
    const Exam = struct { i64, i64 };
    for ([_]Exam{ .{ 1, 2 }, .{ 2, 4 }, .{ 3, 2 }, .{ 4, 0 }, .{ 5, 10 }, .{ 6, 0 } }) |e| {
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

test mean {
    // §3.5.3: to the nearest integer, ties away from zero (VD-052).
    try std.testing.expectEqual(@as(u64, 0), mean(0, 0));
    try std.testing.expectEqual(@as(u64, 3), mean(5, 2));
    try std.testing.expectEqual(@as(u64, 2), mean(3, 2));
    try std.testing.expectEqual(@as(u64, 0), mean(1, 3));
    try std.testing.expectEqual(@as(u64, 1), mean(2, 3));
}

test dist {
    // §17.9.2: a mean, degree of freedom or k_stage that is not positive
    // draws nothing.
    try std.testing.expect(dist(.exponential, 1, 0, 0) == null);
    try std.testing.expect(dist(.poisson, 1, -3, 0) == null);
    try std.testing.expect(dist(.chi_square, 1, 0, 0) == null);
    try std.testing.expect(dist(.t, 1, 0, 0) == null);
    try std.testing.expect(dist(.erlang, 1, 2, 0) == null);
    try std.testing.expect(dist(.erlang, 1, 0, 2) == null);
    // A draw is a pure function of its seed: the same seed, the same draw.
    const d1 = dist(.uniform, 42, 0, 100).?;
    const d2 = dist(.uniform, 42, 0, 100).?;
    try std.testing.expectEqual(d1, d2);
    try std.testing.expect(d1.value >= 0 and d1.value <= 100);
    try std.testing.expect(dist(.random, 0, 0, 0) != null);
}

test text {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // §17.1.1.7: 8 bits a character, leading NULs dropped, others kept.
    const v = try filled(a, 32, false, .zero);
    v.values()[0] = 0x0061_0062;
    try std.testing.expectEqualStrings("a\x00b", (try text(a, v)).?);
    // A partial top byte is a character of the bits it has.
    const w = try filled(a, 12, false, .zero);
    w.values()[0] = 0x141;
    try std.testing.expectEqualStrings("\x01A", (try text(a, w)).?);
    // All zero is no character; an x or z bit is no text at all.
    try std.testing.expectEqualStrings("", (try text(a, try filled(a, 16, false, .zero))).?);
    setBit(w, 3, .z);
    try std.testing.expect((try text(a, w)) == null);
}

test fileType {
    // §17.2.1 Table 17-7, every row.
    for ([_][]const u8{ "r", "rb", "w", "wb", "a", "ab", "r+", "r+b", "rb+", "w+", "w+b", "wb+", "a+", "a+b", "ab+" }) |ty|
        try std.testing.expect(fileType(ty));
    for ([_][]const u8{ "", "R", "rw", "rb+b", "x", "r +" }) |ty| try std.testing.expect(!fileType(ty));
}

test "§4.2.3 a string as a value: the last character in the low byte, an empty one a NUL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // §4.2.3: the last character in the low byte.
    const ab = try evaluate.stringLiteral(a, "AB");
    try std.testing.expectEqual(@as(u32, 16), ab.width);
    try std.testing.expectEqual(@as(?i64, 0x4142), ab.asInt());
    // An empty string is one NUL character.
    const none = try evaluate.stringLiteral(a, "");
    try std.testing.expectEqual(@as(u32, 8), none.width);
    try std.testing.expectEqual(@as(?i64, 0), none.asInt());
}

test "§17.2.4.3 Scan: %u, %z and %t" {
    // %u: a 32-bit word, little-endian; white space is data, not skipped.
    var u: Scan = .init("\x20\x56\x34\x12", "%u", 1);
    u.widths = &.{32};
    try std.testing.expectEqual([2]u64{ 0x12345620, 0 }, u.next().?.value.bits);
    // %z: aval then bval; z is (0, 1), x is (1, 1).
    var z: Scan = .init("\x01\x00\x00\x00\x03\x00\x00\x00", "%z", 1);
    z.widths = &.{8};
    try std.testing.expectEqual([2]u64{ 1, 3 }, z.next().?.value.bits);
    // Too few bytes for the target is EOF before the first conversion.
    var short: Scan = .init("\x01\x02", "%u", 1);
    short.widths = &.{32};
    try std.testing.expect(short.next() == null);
    try std.testing.expectEqual(@as(i64, -1), short.result);
    // 8.125 at $timeformat(-3, 2) rounds to 8.13ms, 8130000 in 1ns.
    var t: Scan = .init("8.125", "%t", 1);
    t.time = .{ .units = -3, .precision = 2, .unit_exp = -9 };
    try std.testing.expectEqual(@as(f64, 8130000), t.next().?.value.real);
    // With no width or scale the conversion stops the scan.
    var none: Scan = .init("1234", "%u", 1);
    try std.testing.expect(none.next() == null);
}

test "§17.2.4.3 Scan: C's conversions over a string" {
    // One call: the assignments `next` gives, then its `result`.
    const S = struct {
        fn bits(input: []const u8, format: []const u8) ![2]u64 {
            var sc: Scan = .init(input, format, 1);
            const x = sc.next() orelse return error.NoAssignment;
            return x.value.bits;
        }
        fn result(input: ?[]const u8, format: ?[]const u8, outs: usize) i64 {
            var sc: Scan = .init(input, format, outs);
            while (sc.next()) |_| {}
            return sc.result;
        }
    };
    try std.testing.expectEqual([2]u64{ @bitCast(@as(i64, -12)), 0 }, try S.bits("  -12", "%d"));
    try std.testing.expectEqual([2]u64{ 255, 0 }, try S.bits("fF", "%x"));
    try std.testing.expectEqual([2]u64{ 5, 0 }, try S.bits("1_01", "%b"));
    try std.testing.expectEqual([2]u64{ 0o17, 0 }, try S.bits("17", "%o"));
    // A maximum field width stops the number.
    try std.testing.expectEqual([2]u64{ 123, 0 }, try S.bits("12345", "%3d"));
    // §3.5.1: an x leftmost pads the value with x; a known digit does not.
    try std.testing.expectEqual([2]u64{ ~@as(u64, 0), ~@as(u64, 0) << 1 }, try S.bits("x1", "%b"));
    try std.testing.expectEqual([2]u64{ 0b11, 0b01 }, try S.bits("1x", "%b"));
    // %d reads one x or z as the whole value.
    try std.testing.expectEqual([2]u64{ 0, ~@as(u64, 0) }, try S.bits("z", "%d"));
    // %c takes the next character, white space included.
    try std.testing.expectEqual([2]u64{ ' ', 0 }, try S.bits(" a", "%c"));
    // The count of assignments; `*` matches without assigning.
    try std.testing.expectEqual(@as(i64, 1), S.result("1 2", "%*d %d", 1));
    try std.testing.expectEqual(@as(i64, 2), S.result("7+8", "%d+%d", 2));
    // A literal that does not match stops the scan with what it assigned.
    try std.testing.expectEqual(@as(i64, 1), S.result("7-8", "%d+%d", 2));
    try std.testing.expectEqual(@as(i64, 0), S.result("b1", "a%d", 1));
    // Input that ends before the first conversion is EOF (-1), and so is
    // an x or z in the string or the format.
    try std.testing.expectEqual(@as(i64, -1), S.result("", "%d", 1));
    try std.testing.expectEqual(@as(i64, -1), S.result("   ", "%d", 1));
    try std.testing.expectEqual(@as(i64, -1), S.result(null, "%d", 1));
    try std.testing.expectEqual(@as(i64, -1), S.result("1", null, 1));
    // More conversions than outputs stop at the outputs.
    try std.testing.expectEqual(@as(i64, 1), S.result("1 2", "%d %d", 1));
    // A literal `%` and the strings.
    try std.testing.expectEqual(@as(i64, 1), S.result("%5", "%%%d", 1));
    {
        var sc: Scan = .init("  ab cd", "%s", 1);
        try std.testing.expectEqualStrings("ab", sc.next().?.value.chars);
        try std.testing.expectEqual(@as(usize, 4), sc.at);
    }
    {
        var sc: Scan = .init("1.5e3x -.25 e5", "%f %g %e", 3);
        try std.testing.expectEqual(@as(f64, 1500), sc.next().?.value.real);
        // The `x` after the number is no part of it, and no format character
        // matches it either.
        try std.testing.expect(sc.next() == null);
        try std.testing.expectEqual(@as(i64, 1), sc.result);
    }
    {
        var sc: Scan = .init("-0.25", "%g", 1);
        try std.testing.expectEqual(@as(f64, -0.25), sc.next().?.value.real);
    }
}

/// A one-file `contract.FileIo` over `data`, for the descriptor-level
/// helpers. Its state is global: one test at a time uses it.
const FakeFile = struct {
    var data: []const u8 = "";
    var pos: usize = 0;
    var put_bytes: usize = 0;

    fn reset(bytes: []const u8) void {
        data = bytes;
        pos = 0;
        put_bytes = 0;
    }
    /// A read opens beside the source when it can (`dir/f.txt`, 7), and
    /// anything else as itself (3).
    fn open(path: []const u8, _: []const u8, _: bool) i64 {
        return if (path.len > "f.txt".len and std.mem.endsWith(u8, path, "f.txt")) 7 else 3;
    }
    fn close(_: i64) i64 {
        return 0;
    }
    /// Takes none of the bytes, as a file not open for writing.
    fn put(_: i64, bytes: []const u8) i64 {
        put_bytes += bytes.len;
        return 0;
    }
    fn getc(_: i64) i64 {
        if (pos == data.len) return -1;
        pos += 1;
        return data[pos - 1];
    }
    fn ungetc(c: i64, _: i64) i64 {
        pos -= 1;
        return c;
    }
    fn tell(_: i64) i64 {
        return @intCast(pos);
    }
    fn seek(_: i64, off: i64, _: i64) i64 {
        pos = @intCast(off);
        return 0;
    }
    fn eof(_: i64) i64 {
        return @intFromBool(pos == data.len);
    }
    const io: contract.FileIo = .{ .open = open, .close = close, .put = put, .getc = getc, .ungetc = ungetc, .tell = tell, .seek = seek, .eof = eof };
};

test readLine {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    FakeFile.reset("ab\ncd");
    // §17.2.4.2: through the newline, then to EOF, then nothing.
    try std.testing.expectEqualStrings("ab\n", try readLine(a, FakeFile.io, 1, 8));
    try std.testing.expectEqualStrings("cd", try readLine(a, FakeFile.io, 1, 8));
    try std.testing.expectEqualStrings("", try readLine(a, FakeFile.io, 1, 8));
    // "until str is filled".
    FakeFile.reset("abc");
    try std.testing.expectEqualStrings("a", try readLine(a, FakeFile.io, 1, 1));
}

test readWord {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // §17.2.4.4: ceil(12 / 8) = 2 bytes, the first the most significant,
    // and only the low 12 bits of them kept: 0x1234 -> 0x234.
    FakeFile.reset("\x12\x34\x56");
    const w = try readWord(a, FakeFile.io, 1, 12);
    try std.testing.expectEqual(@as(i64, 2), w.n);
    try std.testing.expectEqual(@as(?i64, 0x234), w.value.?.asInt());
    // The file ends inside the next word: one byte read, no value.
    const short = try readWord(a, FakeFile.io, 1, 12);
    try std.testing.expectEqual(@as(i64, 1), short.n);
    try std.testing.expect(short.value == null);
}

test fileOp {
    FakeFile.reset("xy");
    // An x or z descriptor or argument is EOF, as is a whence outside 0..2.
    try std.testing.expectEqual(@as(i64, -1), fileOp(FakeFile.io, .fgetc, null, null, null));
    try std.testing.expectEqual(@as(i64, -1), fileOp(FakeFile.io, .fseek, 1, 0, 3));
    try std.testing.expectEqual(@as(i64, -1), fileOp(FakeFile.io, .fseek, 1, null, 0));
    try std.testing.expectEqual(@as(i64, -1), fileOp(FakeFile.io, .ungetc, null, 1, null));
    try std.testing.expectEqual(@as(i64, 'x'), fileOp(FakeFile.io, .fgetc, 1, null, null));
    try std.testing.expectEqual(@as(i64, 1), fileOp(FakeFile.io, .ftell, 1, null, null));
    try std.testing.expectEqual(@as(i64, 0), fileOp(FakeFile.io, .rewind, 1, null, null));
    try std.testing.expectEqual(@as(i64, 0), fileOp(FakeFile.io, .feof, 1, null, null));
    try std.testing.expectEqual(@as(i64, 0), fileOp(FakeFile.io, .fseek, 1, 2, 0));
    try std.testing.expectEqual(@as(i64, 1), fileOp(FakeFile.io, .feof, 1, null, null));
    // §17.2.1: a descriptor is its low 32 bits, however it is signed, so
    // -1 is a descriptor like any other and not EOF.
    try std.testing.expectEqual(@as(i64, 2), fileOp(FakeFile.io, .ftell, -1, null, null));
}

test fopen {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A file read is looked for beside the source first; a write is not.
    try std.testing.expectEqual(@as(i64, 7), try fopen(FakeFile.io, a, "dir/src.v", "f.txt", "r", false));
    try std.testing.expectEqual(@as(i64, 3), try fopen(FakeFile.io, a, "dir/src.v", "f.txt", "w", false));
    // An mcd open is a write.
    try std.testing.expectEqual(@as(i64, 3), try fopen(FakeFile.io, a, "dir/src.v", "f.txt", null, true));
    // No name, no type, or a type outside Table 17-7: 0.
    try std.testing.expectEqual(@as(i64, 0), try fopen(FakeFile.io, a, "src.v", null, "r", false));
    try std.testing.expectEqual(@as(i64, 0), try fopen(FakeFile.io, a, "src.v", "f.txt", null, false));
    try std.testing.expectEqual(@as(i64, 0), try fopen(FakeFile.io, a, "src.v", "f.txt", "rw", false));
}

test "§17.2.4.3 a file scan leaves the descriptor just past what it used" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    FakeFile.reset("12 ab");
    var file = try fileScan(arena.allocator(), FakeFile.io, 1, "%d", 1);
    const x = file.scan.next().?;
    try std.testing.expectEqual(@as(u64, 12), x.value.bits[0]);
    try std.testing.expect(file.scan.next() == null);
    try std.testing.expectEqual(@as(i64, 1), finishFileScan(FakeFile.io, file, file.scan));
    // "12" consumed: the next read is the space after it.
    try std.testing.expectEqual(@as(usize, 2), FakeFile.pos);
    // A descriptor with an x bit scans no input: EOF.
    const none = try fileScan(arena.allocator(), FakeFile.io, null, "%d", 1);
    try std.testing.expectEqual(@as(i64, -1), finishFileScan(FakeFile.io, none, none.scan));
}

test channels {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    const fd: i64 = @as(i64, 1) << 31;
    // §17.2.1: an mcd's bit 0 and fd 1 are standard output, the transcript.
    try std.testing.expect(!try channels(null, null, &out.writer, 1, "a"));
    try std.testing.expect(!try channels(null, null, &out.writer, fd | 1, "b"));
    // Without a table the other channels have no one to refuse them.
    try std.testing.expect(!try channels(null, null, &out.writer, 3, "c"));
    try std.testing.expect(!try channels(null, null, &out.writer, fd | 3, "-"));
    try std.testing.expectEqualStrings("abc", out.written());
    // A table that takes none of the bytes: W1154's case. Empty text
    // reports nothing.
    FakeFile.reset("");
    try std.testing.expect(try channels(FakeFile.io, null, &out.writer, fd | 3, "d"));
    try std.testing.expect(try channels(FakeFile.io, null, &out.writer, 2, "e"));
    try std.testing.expect(!try channels(FakeFile.io, null, &out.writer, 2, ""));
    try std.testing.expectEqual(@as(usize, 2), FakeFile.put_bytes);
    try std.testing.expectEqualStrings("abc", out.written());
}

/// A literal from its bits written most significant first: 0, 1, x or z.
fn testLiteral(a: std.mem.Allocator, bits: []const u8) !Int.Literal {
    const v = try filled(a, @intCast(bits.len), false, .zero);
    for (bits, 0..) |c, i| setBit(v, @intCast(bits.len - 1 - i), switch (c) {
        '0' => .zero,
        '1' => .one,
        'x' => .x,
        else => .z,
    });
    return v;
}

test plaEval {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const P = struct {
        fn run(alloc: std.mem.Allocator, p: Pla, rows: []const []const u8, in: []const u8, width: u32) ![]const u8 {
            const lits = try alloc.alloc(Int.Literal, rows.len);
            for (rows, lits) |r, *l| l.* = try testLiteral(alloc, r);
            const out = try filled(alloc, width, false, .x);
            plaEval(p, lits, try testLiteral(alloc, in), out);
            const text_out = try alloc.alloc(u8, width);
            for (text_out, 0..) |*c, i| c.* = switch (out.bit(@intCast(width - 1 - i))) {
                .zero => '0',
                .one => '1',
                .x => 'x',
                .z => 'z',
            };
            return text_out;
        }
    };
    // §17.5: row k is output bit k from the left; within a row, personality
    // bit j governs input j, both from the left. An array's 1 selects.
    const and_array: Pla = .{ .logic = .@"and", .plane = false, .async_ = true };
    try std.testing.expectEqualStrings("10", try P.run(a, and_array, &.{ "110", "011" }, "110", 2));
    // A plane's 0 selects the complement and its z ("do not care") nothing;
    // an x personality bit is an unknown term.
    const or_plane: Pla = .{ .logic = .@"or", .plane = true, .async_ = true };
    try std.testing.expectEqualStrings("10x", try P.run(a, or_plane, &.{ "0zz", "z0z", "1zx" }, "010", 3));
    // An unknown input the row's controlling value does not decide is x,
    // inverted or not; one it does decide is not.
    const nand_array: Pla = .{ .logic = .nand, .plane = false, .async_ = false };
    try std.testing.expectEqualStrings("x0", try P.run(a, nand_array, &.{ "11", "10" }, "1x", 2));
    try std.testing.expectEqualStrings("1", try P.run(a, nand_array, &.{"11"}, "0x", 1));
    // More rows than output bits: the extra rows drive nothing.
    try std.testing.expectEqualStrings("1", try P.run(a, and_array, &.{ "1", "0" }, "1", 1));
}

test pla_tasks {
    // §17.5: sixteen names, `$` timing `$` logic `$` form.
    try std.testing.expectEqual(@as(usize, 16), pla_tasks.len);
    for (pla_tasks) |t| {
        const name, const p = t;
        try std.testing.expect(std.mem.startsWith(u8, name, if (p.async_) "$async$" else "$sync$"));
        try std.testing.expect(std.mem.endsWith(u8, name, if (p.plane) "$plane" else "$array"));
    }
}
