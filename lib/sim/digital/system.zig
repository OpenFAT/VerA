//! IEEE 1364-2005 §17 system tasks that keep state of their own: a task's
//! argument expressions and the `Run` in; values written to its output
//! arguments (and, for queues, `Run.queues`) out.
//! Queues live in queues.zig, files in files.zig and scanning in scan.zig;
//! this file re-exports their names, which rt/ and the emitter read here.
//! Cites: §17.2 file input and output, §17.2.3 string output, §17.5
//! programmable logic arrays, §17.6 stochastic queues, §17.9 distributions.
//!
//! Contents:
//! - `pub const QueueOp`
//! - `pub const Queue`
//! - `pub const queueTask`
//! - `pub const Queues`
//! - `pub const QueueResult`
//! - `pub const queueStep`
//! - `pub const queueFull`
//! - `pub const queueIsFull`
//! - `pub const own`
//! - `pub const FileFn`
//! - `pub const fileCall`
//! - `pub const fopen`
//! - `pub const fileType`
//! - `pub const fileOp`
//! - `pub const readLine`
//! - `pub const FileScan`
//! - `pub const fileScan`
//! - `pub const finishFileScan`
//! - `pub const readWord`
//! - `pub const overWord`
//! - `pub const fclose`
//! - `pub const fdisplay`
//! - `pub const fdisplayTo`
//! - `pub const unwritten`
//! - `pub const channels`
//! - `pub const Scan`
//! - `pub const Dist = enum`
//! - `pub const Draw = struct`
//! - `pub const dist_warning`
//! - `pub const Pla = struct`
//! - `pub const pla_tasks`
//! - `pub const TaskState = struct`
//! - `pub fn dist(f: Dist, seed: i32, a: i32, b: i32) ?Draw`
//! - `pub fn random(self: *Run, a: std.mem.Allocator, f: Dist, args: []const Ast.ExprId, tok: u32) Error!i32`
//! - `pub fn text(a: std.mem.Allocator, v: Int.Literal) Error!?[]const u8`
//! - `pub fn sformat(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId, show: ?display.Show) Error!void`
//! - `pub fn pla(self: *Run, a: std.mem.Allocator, p: Pla, args: []const Ast.ExprId) Error!void`
//! - `pub fn plaEval(p: Pla, rows: []const Int.Literal, in: Int.Literal, out: Int.Literal) void`

const std = @import("std");
const assert = std.debug.assert;
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
const files = @import("files.zig");
const queues = @import("queues.zig");
const scanf = @import("scanf.zig");
const empty = queues.empty;
const int = queues.int;

/// `queues.QueueOp`.
pub const QueueOp = queues.QueueOp;

/// `queues.Queue`.
pub const Queue = queues.Queue;

/// `queues.queueTask`.
pub const queueTask = queues.queueTask;

/// `queues.Queues`.
pub const Queues = queues.Queues;

/// `queues.QueueResult`.
pub const QueueResult = queues.QueueResult;

/// `queues.queueStep`.
pub const queueStep = queues.queueStep;

/// `queues.queueFull`.
pub const queueFull = queues.queueFull;

/// `queues.queueIsFull`.
pub const queueIsFull = queues.queueIsFull;

/// `files.own`.
pub const own = files.own;

/// `files.FileFn`.
pub const FileFn = files.FileFn;

/// `files.fileCall`.
pub const fileCall = files.fileCall;

/// `files.fopen`.
pub const fopen = files.fopen;

/// `files.fileType`.
pub const fileType = files.fileType;

/// `files.fileOp`.
pub const fileOp = files.fileOp;

/// `files.readLine`.
pub const readLine = files.readLine;

/// `files.FileScan`.
pub const FileScan = files.FileScan;

/// `files.fileScan`.
pub const fileScan = files.fileScan;

/// `files.finishFileScan`.
pub const finishFileScan = files.finishFileScan;

/// `files.readWord`.
pub const readWord = files.readWord;

/// `files.overWord`.
pub const overWord = files.overWord;

/// `files.fclose`.
pub const fclose = files.fclose;

/// `files.fdisplay`.
pub const fdisplay = files.fdisplay;

/// `files.fdisplayTo`.
pub const fdisplayTo = files.fdisplayTo;

/// `files.unwritten`.
pub const unwritten = files.unwritten;

/// `files.channels`.
pub const channels = files.channels;

/// `scan.Scan`.
pub const Scan = scanf.Scan;

/// §17.9.3 Table 17-17: `$random` and the seven `$dist_*` functions.
pub const Dist = enum { random, uniform, normal, exponential, poisson, chi_square, t, erlang };

/// A draw's value and the seed its inout argument is written back with.
pub const Draw = struct { value: i32, seed: i32 };

/// The text of the listing's `print_error` for a non-positive argument.
pub const dist_warning = "a $dist_ mean, degree of freedom or k_stage is not positive: the result is 0 and the seed is unchanged";

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

/// What a run's §17 system tasks keep between calls: the §17.6 queues by
/// `q_id`, §17.9.1's seedless `$random` stream, and the host's file I/O
/// (null: the run opens files itself, `files.own`).
pub const TaskState = struct {
    /// §17.6 the stochastic queues, by `q_id`.
    queues: std.AutoHashMapUnmanaged(i64, Queue) = .empty,
    /// §17.9.1 the seed of a `$random` called without one. §17.9.3's
    /// listing starts from 0, which its `uniform` reads as 259341593.
    random_seed: i32 = 0,
    /// VAMS §9.5.1.2 the host's descriptor table, when the simulation shares
    /// one between this engine and an analog device (the mixed runner
    /// installs the device's `file_io`); null, this engine's own
    /// (`system.table`).
    file_io: ?@import("contract").FileIo = null,
};

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

/// §17.9 one call of `$random` or a `$dist_*` function. A seed argument is
/// read and written back (§17.9.1, §17.9.2: "an inout argument"); a
/// seedless `$random` advances `Run.random_seed`.
pub fn random(self: *Run, a: std.mem.Allocator, f: Dist, args: []const Ast.ExprId, tok: u32) Error!i32 {
    assert(tok < self.starts.len);
    if (args.len == 0) {
        const d = dist(.random, self.tasks.random_seed, 0, 0).?;
        self.tasks.random_seed = d.seed;
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

/// §17.5 one evaluation in the interpreter (`plaEval`).
pub fn pla(self: *Run, a: std.mem.Allocator, p: Pla, args: []const Ast.ExprId) Error!void {
    const base = try self.slot(args[0]);
    const arr = self.decls.arrays.get(base).?; // compile proved it is an array
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

// ---- private ----

/// The seed or integer argument `e` as the listing's 32-bit `long`: its
/// low 32 bits, 0 when it holds an x or z bit.
fn long(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!i32 {
    assert(e != .none);
    return @truncate(try int(self, a, e) orelse 0);
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
