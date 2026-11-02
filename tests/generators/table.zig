//! The driver: each generator's rows as argv lines of this executable,
//! run as children (`jobs` at a time), each judged by how it ended; then
//! the generator's `known` list. A known row that fails is XFAIL; one that
//! passes is an XPASS and fails the run, as does a `known` row that names
//! no row.
//!
//! Contents:
//! - `pub const Known = struct`
//! - `pub const Row = struct`
//! - `pub fn main(init: std.process.Init) !u8`

const std = @import("std");
const wide = @import("wide.zig");
const escaped = @import("escaped.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Known = struct { row: []const u8, why: []const u8 };
pub const Row = struct { name: []const u8, argv: []const []const u8 };

/// The rows' children and their cursor: one row per take, any number of hands.
const Pool = struct {
    arena: Allocator,
    io: Io,
    rows: []const Row,
    /// Why each row failed; null: it held.
    whys: []?[]const u8,
    next: std.atomic.Value(usize) = .init(0),
    failed: ?anyerror = null,

    fn work(pool: *Pool) void {
        while (true) {
            const i = pool.next.fetchAdd(1, .monotonic);
            if (i >= pool.rows.len) return;
            pool.whys[i] = judge(pool.arena, pool.io, pool.rows[i].argv) catch |e| {
                pool.failed = e;
                return;
            };
        }
    }
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.skip();
    const dir = args.next() orelse return error.MissingScratchDir;

    var buf: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writerStreaming(io, &buf);
    const w = &stderr.interface;
    defer w.flush() catch {};

    if (args.next()) |generator| {
        const a = args.next() orelse return error.MissingRowArgument;
        const b = args.next() orelse return error.MissingRowArgument;
        const why = if (std.mem.eql(u8, generator, "wide"))
            try wide.child(io, dir, a, b)
        else if (std.mem.eql(u8, generator, "escaped"))
            try escaped.child(io, a, b)
        else
            return error.UnknownGenerator;
        if (why.len == 0) return 0;
        try w.print("{s}\n", .{why});
        return 1;
    }
    const exe = try std.process.executablePathAlloc(io, arena);
    var bad: usize = 0;
    bad += try drive(arena, io, w, "wide", try wide.rows(arena, exe, dir), wide.known);
    bad += try drive(arena, io, w, "escaped", try escaped.rows(arena, exe, dir), escaped.known);
    return if (bad == 0) 0 else 1;
}

// ---- private ----

/// Runs `rows`, prints BAD and XFAIL lines on `w` and a census; returns
/// the BAD count.
fn drive(arena: Allocator, io: Io, w: *Io.Writer, label: []const u8, rows_: []const Row, known: []const Known) !usize {
    const whys = try arena.alloc(?[]const u8, rows_.len);
    var pool: Pool = .{ .arena = arena, .io = io, .rows = rows_, .whys = whys };
    var group: Io.Group = .init;
    const hands = @max(1, @min(8, std.Thread.getCpuCount() catch 1));
    for (0..hands) |_| group.concurrent(io, Pool.work, .{&pool}) catch break;
    pool.work();
    try group.await(io);
    if (pool.failed) |e| return e;

    // XFAIL and the census on stdout: `zig build` prints a passing step's
    // stderr as noise.
    var out_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};
    var bad: usize = 0;
    const seen = try arena.alloc(bool, known.len);
    @memset(seen, false);
    for (rows_, whys) |row, why| {
        var marked: ?[]const u8 = null;
        for (known, seen) |k, *s| if (std.mem.eql(u8, k.row, row.name)) {
            s.* = true;
            marked = k.why;
        };
        if (why) |reason| {
            if (marked) |m| {
                try out.print("XFAIL {s}: known: {s}\n", .{ row.name, m });
                continue;
            }
            try w.print("BAD {s}: {s}\n", .{ row.name, reason });
            bad += 1;
        } else if (marked != null) {
            try w.print("BAD {s}: XPASS, delete its `known` row\n", .{row.name});
            bad += 1;
        }
    }
    for (known, seen) |k, s| if (!s) {
        try w.print("BAD {s}: `known` names no row of the table\n", .{k.row});
        bad += 1;
    };
    try (if (bad == 0) out else w).print("{s}: {d} rows, {d} BAD\n", .{ label, rows_.len, bad });
    return bad;
}

fn judge(arena: Allocator, io: Io, argv: []const []const u8) !?[]const u8 {
    const r = try std.process.run(arena, io, .{ .argv = argv });
    return switch (r.term) {
        .exited => |c| if (c == 0) null else try arena.print("exit {d}: {s}", .{ c, head(r.stderr) }),
        else => try arena.print("did not exit: {any} (SEGV: a stack overflow; ABRT: a panic)\n{s}", .{ r.term, head(r.stderr) }),
    };
}

/// The first 2 KiB: an overflow's trace is thousands of frames.
fn head(text: []const u8) []const u8 {
    return text[0..@min(text.len, 2048)];
}
